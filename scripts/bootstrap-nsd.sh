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

# main_ip_addrs — ip-address, уже заданные в main-конфиге и чужих
# drop-in'ах. Свой 00-файл на время чтения убираем, иначе увидим сами себя.
main_ip_addrs() {
    command -v nsd-checkconf >/dev/null 2>&1 || return 0
    [ -f /etc/nsd/nsd.conf ] || return 0
    local tmp="" out
    if [ -f "$CONF" ]; then
        tmp="$(mktemp "$(dirname "$CONF")/.00-$NAME-addr.XXXXXX")" || return 0
        mv -f "$CONF" "$tmp"
    fi
    out="$(nsd-checkconf -o ip-address /etc/nsd/nsd.conf 2>/dev/null || true)"
    [ -z "$tmp" ] || mv -f "$tmp" "$CONF"
    printf '%s\n' "$out" | sed 's/@.*//' | tr '\n' ' '
}

# nsd_config — конфиг NSD, который пишет установщик. Печатается в stdout,
# чтобы тесты могли проверить его через nsd-checkconf без root.
# Адреса, уже заданные в main-конфиге (старая установка), не повторяем:
# иначе NSD биндит адрес дважды и падает с EADDRINUSE, а в ss пусто.
nsd_config() {
    local exclude line addr
    exclude="$(main_ip_addrs)"
    printf 'server:\n'
    printf '\tdo-ip4: yes\n'
    printf '\tdo-ip6: yes\n'
    case " $exclude " in
        *" 0.0.0.0 "*|*" :: "*)
            # main уже биндит wildcard; добавлять конкретные адреса нельзя
            ;;
        *)
            nsd_listen | while IFS= read -r line; do
                addr="${line#*ip-address: }"
                addr="${addr%@53}"
                case " $exclude " in
                    *" $addr "*) continue ;;
                esac
                printf '%s\n' "$line"
            done
            ;;
    esac
    printf '\tzonesdir: "%s"\n' "$ZONESDIR"
    printf '\n'
    printf 'remote-control:\n'
    printf '\tcontrol-enable: yes\n'
}

# all_netns_port_lines — слушатели 53 во ВСЕХ network namespace'ах хоста.
# Нужно, когда старый DNS виден не из host-ss: сокет живёт в netns
# контейнера/unit'а. Печатает netns, представителя и строки ss.
all_netns_port_lines() {
    local nsp pid ino out
    declare -A seen=()
    command -v nsenter >/dev/null 2>&1 || return 0
    for nsp in /proc/[0-9]*/ns/net; do
        [ -r "$nsp" ] || continue
        pid="${nsp#/proc/}"; pid="${pid%%/*}"
        ino="$(stat -Lc %i "$nsp" 2>/dev/null || true)"
        [ -n "$ino" ] || continue
        [ -n "${seen[$ino]:-}" ] && continue
        seen["$ino"]=1
        out="$(nsenter --net="$nsp" sh -c "ss -lnup 'sport = :53' 2>/dev/null; ss -lntp 'sport = :53' 2>/dev/null" 2>/dev/null | grep -v '^State')" || true
        [ -z "$out" ] || printf 'netns %s (pid %s)\n%s\n' "$ino" "$pid" "$out"
    done
}

case "${1:-}" in
    --print-config) nsd_config; exit 0 ;;
    --who-has-53)
        [ "$(id -u)" = "0" ] || die "нужен root: sudo $0 --who-has-53"
        out="$(all_netns_port_lines)"
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
        else
            echo "порт 53 нигде не занят"
        fi
        exit 0
        ;;
    '') ;;
    *) echo "использование: $0 [--print-config|--who-has-53]" >&2; exit 2 ;;
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
old_conf=""
if [ -f "$CONF" ] && cmp -s "$tmp_conf" "$CONF"; then
    config_changed=0
    rm -f "$tmp_conf"
    echo "  конфиг не изменился"
else
    if [ -f "$CONF" ]; then
        old_conf="$(mktemp "$(dirname "$CONF")/.00-$NAME-old.XXXXXX")"
        cp -p "$CONF" "$old_conf"
    fi
    mv -f "$tmp_conf" "$CONF"
    echo "  конфиг обновлён"
fi

echo "== ключи nsd-control"
# в дистрибутивах ключи обычно создаёт postinst; повторный вызов безвреден
nsd-control-setup >/dev/null 2>&1 || true

echo "== проверка конфигурации"
if ! nsd-checkconf /etc/nsd/nsd.conf; then
    if [ -n "$old_conf" ] && [ -f "$old_conf" ]; then
        cp -p "$old_conf" "$CONF"
        rm -f "$old_conf"
        echo "  конфиг не прошёл проверку; оставлен прежний" >&2
    fi
    die "nsd-checkconf отверг конфиг"
fi
got="$(nsd-checkconf -o zonesdir /etc/nsd/nsd.conf)"
if [ "$got" != "$ZONESDIR" ]; then
    if [ -n "$old_conf" ] && [ -f "$old_conf" ]; then
        cp -p "$old_conf" "$CONF"
        rm -f "$old_conf"
        echo "  конфиг не подхвачен; оставлен прежний" >&2
    fi
    die "конфиг не подхвачен: zonesdir=$got (проверьте include в /etc/nsd/nsd.conf)"
fi

# адрес, продублированный в main и drop-in, NSD биндит дважды: второй bind
# даёт EADDRINUSE, процесс выходит, и в ss не остаётся никого
dup="$(nsd-checkconf -o ip-address /etc/nsd/nsd.conf 2>/dev/null | sort | uniq -d)"
if [ -n "$dup" ]; then
    if [ -n "$old_conf" ] && [ -f "$old_conf" ]; then
        cp -p "$old_conf" "$CONF"
        rm -f "$old_conf"
        echo "  ip-address дублируется; оставлен прежний конфиг" >&2
    fi
    die "ip-address дублируется: $dup (уберите дубль из /etc/nsd/nsd.conf или drop-in)"
fi

# show_port_owner — кто держит 53 и что с этим делать.
show_port_owner() {
    local out
    command -v ss >/dev/null 2>&1 || return 0
    out="$( { ss -lnup 'sport = :53' 2>/dev/null; ss -lntp 'sport = :53' 2>/dev/null; } | grep -v '^State' )"
    [ -n "$out" ] || return 0
    echo "порт 53 в host netns:" >&2
    printf '%s\n' "$out" >&2
    local all
    all="$(all_netns_port_lines)"
    if [ -n "$all" ]; then
        echo "порт 53 во всех netns:" >&2
        printf '%s\n' "$all" >&2
    fi
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

# nsd_pids_on_53 — PID'ы процессов, слушающих 53 (UDP и TCP).
nsd_pids_on_53() {
    command -v ss >/dev/null 2>&1 || return 0
    { ss -lnup 'sport = :53' 2>/dev/null; ss -lntp 'sport = :53' 2>/dev/null; } \
        | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}

# nsd_pids — PID'ы NSD из сокетов (host и все netns) и из таблицы процессов.
# Старый NSD может держать адрес в другом network namespace: в host-ss его
# нет, но сокет виден в его netns, а процесс — в /proc.
nsd_pids() {
    {
        nsd_pids_on_53
        all_netns_port_lines | grep -o 'pid=[0-9]*' | cut -d= -f2 || true
        if command -v pgrep >/dev/null 2>&1; then
            pgrep -f '(^|/)nsd( |$)' 2>/dev/null || true
        else
            ps -eo pid=,args= 2>/dev/null | awk '$0 ~ /(^|[\/ ])nsd( |$)/ { print $1 }'
        fi
    } | sort -u
}

# stop_existing_nsd — освободить 53 от прежнего NSD: управляемого unit'а
# или процесса старой установки. NSD переименовывает потоки в "nsd: main",
# поэтому pgrep -x nsd его не находит; берём PID из ss и проверяем exe.
stop_existing_nsd() {
    systemctl stop nsd >/dev/null 2>&1 || true
    local pids="" pid exe alive
    for pid in $(nsd_pids); do
        [ -d "/proc/$pid" ] || continue
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        case "$exe" in
            */nsd*) pids="$pids $pid" ;;
        esac
    done
    [ -n "$pids" ] || return 0
    echo "  останавливаю существующий NSD (pids:$pids)" >&2
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in $(seq 1 20); do
        alive=0
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && alive=1
        done
        [ "$alive" = "0" ] && break
        sleep 0.25
    done
    for pid in $pids; do
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 0.5
}

echo "== запуск"
systemctl enable nsd >/dev/null 2>&1 || true
if [ "$config_changed" = "0" ] && systemctl is-active --quiet nsd; then
    # повторный запуск не должен трогать работающий NSD
    echo "  NSD уже работает, конфиг не менялся — перезапуск не нужен"
else
    # обновление существующей установки: старый NSD (unit или процесс) убираем,
    # иначе новый не сможет занять его адреса
    stop_existing_nsd
    # после неудачных стартов systemd держит start-limit; снимаем его
    systemctl reset-failed nsd >/dev/null 2>&1 || true
    systemctl start nsd >/dev/null 2>&1 || true
fi

if ! systemctl is-active --quiet nsd; then
    if [ -n "$old_conf" ] && [ -f "$old_conf" ]; then
        cp -p "$old_conf" "$CONF"
        stop_existing_nsd
        systemctl reset-failed nsd >/dev/null 2>&1 || true
        systemctl start nsd >/dev/null 2>&1 || true
        if systemctl is-active --quiet nsd; then
            echo "восстановлен прежний конфиг, NSD работает" >&2
            rm -f "$old_conf"
            die "новый конфиг не применён; NSD работает со старым"
        fi
    fi
    rm -f "$old_conf"
    show_port_owner
    journalctl -u nsd -n 20 --no-pager >&2 || true
    die "NSD не поднялся: journalctl -u nsd"
fi
rm -f "$old_conf"
echo "готово: NSD настроен (NAME=$NAME, BASE=$BASE)"
