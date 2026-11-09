#!/usr/bin/env bash
# check.sh — локальная проверка генерации зон. Не требует хостов и root.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "ОШИБКА: $*" >&2; exit 1; }

export NAME=check BASE=example.ru
export STATE="$T/state" ZONEDIR="$T/zones"
export ZONES_CONF="$T/10-check-zones.conf" ZONELIST="$T/zone.list"
export ZONELIST_CONF="$T/zonelistfile.conf"

mkdir -p "$STATE/plb.example.ru" "$STATE/h.example.ru"
printf 'tg.d 2a02:2168::1111\n' > "$STATE/plb.example.ru/host-a"
printf 'ssh 2a02:2168::1111\nbackup 2a02:2168::1111\n' > "$STATE/h.example.ru/host-b"

# shellcheck disable=SC1091
. "$HERE/zonegen.sh"
NO_RESTART=1 zones_apply

zf="$ZONEDIR/plb.example.ru.zone"
[ -f "$zf" ] || fail "зона не создана: $zf"
grep -q 'tg.d IN AAAA 2a02:2168::1111' "$zf" || fail "нет записи tg.d"
[ -f "$ZONEDIR/h.example.ru.zone" ] || fail "нет зоны h"
grep -q 'name: "plb.example.ru"' "$ZONES_CONF" || fail "нет блока зоны в конфиге"
[ ! -s "$ZONELIST" ] || fail "рантайм-список должен быть пуст"

# Конфиг NSD из bootstrap-nsd: проверяем настоящим nsd-checkconf, если он есть.
bash "$HERE/bootstrap-nsd.sh" --print-config > "$T/00-check.conf"
grep -q $'^\tdo-ip4: yes$' "$T/00-check.conf" || fail "в конфиге NSD нет реальной табуляции"
grep -q $'^\tip-address: 0.0.0.0@53$' "$T/00-check.conf" || fail "в конфиге NSD нет ip-address"
if grep -q 'listen:' "$T/00-check.conf"; then fail "в конфиге NSD остался listen:"; fi
if command -v nsd-checkconf >/dev/null; then
    printf 'include: "%s"\n' "$T/00-check.conf" > "$T/nsd.conf"
    nsd-checkconf "$T/nsd.conf" || fail "nsd-checkconf отверг конфиг"
    [ "$(nsd-checkconf -o zonesdir "$T/nsd.conf")" = "/var/lib/nsd/zones" ] \
        || fail "nsd-checkconf не видит zonesdir"
else
    echo "  пропущено: nsd-checkconf не установлен"
fi

echo "проверка пройдена: 2 зоны, записи на месте, конфиг сформирован"
