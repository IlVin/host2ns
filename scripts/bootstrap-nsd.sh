#!/usr/bin/env bash
# bootstrap-nsd.sh — установка и настройка NSD на NS-хосте. Идемпотентен.
# Запускать на NS-хосте: sudo ./scripts/bootstrap-nsd.sh
set -euo pipefail

NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
[ "$(id -u)" = "0" ] || { echo "нужен root: sudo $0" >&2; exit 2; }

echo "== пакеты"
command -v nsd >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y nsd

echo "== каталоги"
install -d -m 755 /var/lib/nsd /var/lib/nsd/zones /etc/nsd/nsd.conf.d
install -d -m 755 "/var/lib/$NAME" "/var/lib/$NAME/state"
chown nsd:nsd /var/lib/nsd /var/lib/nsd/zones

echo "== конфиг"
cat > /etc/nsd/nsd.conf.d/00-host2ns.conf <<CONF
server:
\tdo-ip4: yes
\tdo-ip6: yes
\tlisten: 0.0.0.0@53
\tlisten: ::@53
\tzonesdir: "/var/lib/nsd/zones"
CONF
chmod 644 /etc/nsd/nsd.conf.d/00-host2ns.conf

echo "== проверка конфигурации"
nsd-checkconf /etc/nsd/nsd.conf

echo "== запуск"
systemctl enable nsd >/dev/null 2>&1 || true
systemctl is-active --quiet nsd || systemctl start nsd || true
systemctl is-active --quiet nsd || { echo "NSD не поднялся: journalctl -u nsd" >&2; exit 1; }
echo "готово: NSD настроен (NAME=$NAME, BASE=$BASE)"
