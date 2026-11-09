#!/usr/bin/env bash
# bootstrap-nsd.sh — установка и настройка NSD на NS-хосте. Идемпотентен.
# Запускать на NS-хосте: sudo ./scripts/bootstrap-nsd.sh
set -euo pipefail

NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
CONF="/etc/nsd/nsd.conf.d/00-$NAME.conf"
ZONESDIR="${ZONESDIR:-/var/lib/nsd/zones}"

die() { echo "ОШИБКА: $*" >&2; exit 2; }

# nsd_config — конфиг NSD, который пишет установщик. Печатается в stdout,
# чтобы тесты могли проверить его через nsd-checkconf без root.
nsd_config() {
    printf 'server:\n'
    printf '\tdo-ip4: yes\n'
    printf '\tdo-ip6: yes\n'
    printf '\tip-address: 0.0.0.0@53\n'
    printf '\tip-address: ::@53\n'
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
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nsd
fi

echo "== каталоги"
install -d -m 755 /var/lib/nsd "$ZONESDIR" /etc/nsd/nsd.conf.d "/var/lib/$NAME" "/var/lib/$NAME/state"
chown nsd:nsd /var/lib/nsd "$ZONESDIR"

echo "== конфиг"
# временный файл рядом с целевым: замена атомарна для NSD
nsd_config > "$CONF.tmp"
chmod 644 "$CONF.tmp"
mv -f "$CONF.tmp" "$CONF"

echo "== ключи nsd-control"
# в дистрибутивах ключи обычно создаёт postinst; повторный вызов безвреден
nsd-control-setup >/dev/null 2>&1 || true

echo "== проверка конфигурации"
nsd-checkconf /etc/nsd/nsd.conf
got="$(nsd-checkconf -o zonesdir /etc/nsd/nsd.conf)"
[ "$got" = "$ZONESDIR" ] || die "конфиг не подхвачен: zonesdir=$got (проверьте include в /etc/nsd/nsd.conf)"

echo "== запуск"
systemctl enable nsd >/dev/null 2>&1 || true
# конфиг мог измениться: перезапуск применяет его и к уже работающему NSD
systemctl restart nsd >/dev/null 2>&1 || systemctl start nsd >/dev/null 2>&1 || true
systemctl is-active --quiet nsd || die "NSD не поднялся: journalctl -u nsd"
echo "готово: NSD настроен (NAME=$NAME, BASE=$BASE)"
