#!/usr/bin/env bash
# bootstrap-nsd.sh — установка и настройка NSD на NS-хосте. Идемпотентен.
# Обычно вызывается через make bootstrap-nsd HOST=<ns>: скрипт копируется
# по scp и запускается по SSH под sudo. Прямой запуск на NS тоже возможен.
set -euo pipefail

NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
CONF="/etc/nsd/nsd.conf.d/00-$NAME.conf"
ZONESDIR="${ZONESDIR:-/var/lib/nsd/zones}"

die() { echo "ОШИБКА: $*" >&2; exit 2; }

# nsd_listen — адреса, на которых слушает NSD.
# Не 0.0.0.0: на Ubuntu/Debian 127.0.0.53/54 держит systemd-resolved, и
# wildcard-биндинг конфликтует с ним. Слушаем реальные адреса хоста + loopback.
nsd_listen() {
    local addrs a
    if ! command -v ip >/dev/null 2>&1; then
        printf '\tip-address: 0.0.0.0@53\n'
        printf '\tip-address: ::@53\n'
        return 0
    fi
    # только реальные внешние интерфейсы: docker/br/veth не нужны, а
    # temporary/deprecated/tentative IPv6 меняются под ногами
    addrs="$(ip -o addr show scope global 2>/dev/null \
        | awk '$2 ~ /^(docker|br-|veth|virbr|tap|vnet)/ { next }
               /temporary|deprecated|tentative|dadfailed/ { next }
               { split($4, a, "/"); print a[1] }' | sort -u)"
    if [ -z "$addrs" ]; then
        printf '\tip-address: 0.0.0.0@53\n'
        printf '\tip-address: ::@53\n'
        return 0
    fi
    while read -r a; do
        [ -n "$a" ] || continue
        printf '\tip-address: %s@53\n' "$a"
    done <<< "$addrs"
    printf '\tip-address: 127.0.0.1@53\n'
    if ip -o addr show scope host 2>/dev/null | grep -q 'inet6 ::1/'; then
        printf '\tip-address: ::1@53\n'
    fi
}

# nsd_config — конфиг NSD, который пишет установщик. Печатается в stdout,
# чтобы тесты могли проверить его через nsd-checkconf без root.
nsd_config() {
    printf 'server:\n'
    printf '\tdo-ip4: yes\n'
    printf '\tdo-ip6: yes\n'
    nsd_listen
    printf '\tzonesdir: "%s"\n' "$ZONESDIR"
    printf '\n'
    printf 'remote-control:\n'
    printf '\tcontrol-enable: yes\n'
}

case "${1:-}" in
    --print-config) nsd_config; exit 0 ;;
    '') ;;
    *) echo "использование: $0 [--print-config]" >&2; exit 2 ;;
esac

[ "$(id -u)" = "0" ] || die "нужен root: sudo $0"

echo "== пакеты"
if ! command -v nsd >/dev/null; then
    # сторонние репозитории часто ломают update; это не повод не ставить nsd
    apt-get update || echo "предупреждение: apt-get update завершился с ошибкой, продолжаем" >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y nsd \
        || die "не удалось установить nsd: исправьте apt-get update (см. вывод выше)"
fi

echo "== каталоги"
install -d -m 755 /var/lib/nsd "$ZONESDIR" /etc/nsd/nsd.conf.d "/var/lib/$NAME" "/var/lib/$NAME/state"
chown nsd:nsd /var/lib/nsd "$ZONESDIR"

echo "== конфиг"
# временный файл рядом с целевым: замена атомарна для NSD
tmp_conf="$(mktemp "$(dirname "$CONF")/.00-$NAME.XXXXXX")"
nsd_config > "$tmp_conf"
chmod 644 "$tmp_conf"
config_changed=1
if [ -f "$CONF" ] && cmp -s "$tmp_conf" "$CONF"; then
    config_changed=0
    rm -f "$tmp_conf"
    echo "  конфиг не изменился"
else
    mv -f "$tmp_conf" "$CONF"
    echo "  конфиг обновлён"
fi

echo "== ключи nsd-control"
# в дистрибутивах ключи обычно создаёт postinst; повторный вызов безвреден
nsd-control-setup >/dev/null 2>&1 || true

echo "== проверка конфигурации"
nsd-checkconf /etc/nsd/nsd.conf
got="$(nsd-checkconf -o zonesdir /etc/nsd/nsd.conf)"
[ "$got" = "$ZONESDIR" ] || die "конфиг не подхвачен: zonesdir=$got (проверьте include в /etc/nsd/nsd.conf)"

# show_port_owner — кто держит 53 и что с этим делать.
show_port_owner() {
    local out
    command -v ss >/dev/null 2>&1 || return 0
    out="$( { ss -lnup 'sport = :53' 2>/dev/null; ss -lntp 'sport = :53' 2>/dev/null; } | grep -v '^State' )"
    [ -n "$out" ] || return 0
    echo "порт 53 занят:" >&2
    printf '%s\n' "$out" >&2
    if grep -q 'ip-address: 0\.0\.0\.0@53' "$CONF" 2>/dev/null; then
        # wildcard-конфиг (fallback без iproute2): виноват резолвер
        case "$out" in
            *systemd-resolve*)
                echo "NSD биндит 0.0.0.0@53, а его держит systemd-resolved." >&2
                echo "Перезапустите установку: новый конфиг биндит конкретные адреса." >&2
                ;;
            *nsd*)
                echo "это NSD: служба не остановилась или процесс запущен вне systemd." >&2
                echo "  sudo systemctl status nsd; sudo journalctl -u nsd -n 30" >&2
                ;;
        esac
    else
        echo "NSD биндит конкретные адреса хоста; в journal видно, какой адрес не забиндился." >&2
    fi
}

echo "== запуск"
systemctl enable nsd >/dev/null 2>&1 || true
# после неудачных стартов systemd держит start-limit; снимаем его перед попыткой
systemctl reset-failed nsd >/dev/null 2>&1 || true
if [ "$config_changed" = "0" ] && systemctl is-active --quiet nsd; then
    # повторный запуск не должен трогать работающий NSD
    echo "  NSD уже работает, конфиг не менялся — перезапуск не нужен"
elif systemctl is-active --quiet nsd; then
    systemctl restart nsd >/dev/null 2>&1 || true
else
    systemctl start nsd >/dev/null 2>&1 || true
fi

if ! systemctl is-active --quiet nsd; then
    show_port_owner
    journalctl -u nsd -n 20 --no-pager >&2 || true
    die "NSD не поднялся: journalctl -u nsd"
fi
echo "готово: NSD настроен (NAME=$NAME, BASE=$BASE)"
