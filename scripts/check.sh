#!/usr/bin/env bash
# check.sh — локальная проверка генерации зон. Не требует хостов и root.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "ОШИБКА: $*" >&2; exit 1; }

# recv_run <каталог> [VAR=value...] — приёмник в изолированном окружении.
# BASE задаётся файлом <каталог>/base, как на NS.
recv_run() {
    local root="$1"; shift
    mkdir -p "$root"
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        NAME=check BASE_FILE="$root/base" STATE="$root/state" ZONEDIR="$root/zones" \
        ZONES_CONF="$root/zones.conf" ZONELIST="$root/zone.list" \
        ZONELIST_CONF="$root/zonelist.conf" NO_RESTART=1 "$@" \
        bash "$HERE/receiver.sh"
}

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

# BASE из файла: окружение установщика до приёмника не доходит.
R="$T/recv-base"
mkdir -p "$R"
printf 'other.example\n' > "$R/base"
recv_run "$R" <<'EOF' || fail "приёмник не отработал с BASE из файла"
host h1
policy ipv6
tg.d.plb 2a02:2168::1111
EOF
[ -d "$R/state/plb.other.example" ] || fail "BASE из файла не применён"
grep -q 'name: "plb.other.example"' "$R/zones.conf" || fail "зона не попала в конфиг"

# nat без собственных адресов: имя должно дожить до подклейки адреса.
R="$T/recv-nat"
mkdir -p "$R"
printf 'example.ru\n' > "$R/base"
recv_run "$R" SSH_CONNECTION='203.0.113.7 1234 198.51.100.1 22' <<'EOF' \
    || fail "nat-хост не опубликовался"
host h-nat
policy nat
tg.d.plb
EOF
[ -f "$R/state/plb.example.ru/h-nat" ] || fail "nat: имя потеряно"
grep -qx 'tg.d 203.0.113.7' "$R/state/plb.example.ru/h-nat" || fail "nat: нет A"

# nat вместе со своим IPv6: обе записи на имя.
R="$T/recv-nat6"
mkdir -p "$R"
printf 'example.ru\n' > "$R/base"
recv_run "$R" SSH_CONNECTION='203.0.113.8 1234 198.51.100.1 22' <<'EOF' \
    || fail "nat+ipv6 не опубликовался"
host h-nat6
policy nat,ipv6
tg.d.plb 2a02:2168::1111
EOF
grep -qx 'tg.d 203.0.113.8' "$R/state/plb.example.ru/h-nat6" || fail "nat+ipv6: нет A"
grep -qx 'tg.d 2a02:2168::1111' "$R/state/plb.example.ru/h-nat6" || fail "nat+ipv6: нет AAAA"

# пустой набор удаляет имена хоста.
recv_run "$R" <<'EOF' || fail "пустой набор не отработал"
host h-nat6
policy ipv6
EOF
[ ! -e "$R/state/plb.example.ru/h-nat6" ] || fail "пустой набор не удалил имена"

# authorize.sh: строка authorized_keys с forced command.
ssh-keygen -t ed25519 -N "" -C "check@test" -f "$T/ak" >/dev/null 2>&1 || fail "ssh-keygen"
line="$(NAME=check bash "$HERE/authorize.sh" --print-line "$(cat "$T/ak.pub")")"
case "$line" in
    'restrict,command="sudo -n /usr/local/bin/check-recv.sh" ssh-ed25519 '*) ;;
    *) fail "authorize: плохая строка: $line" ;;
esac
if NAME=check bash "$HERE/authorize.sh" --print-line "not a key" >/dev/null 2>&1; then
    fail "authorize: принял мусор вместо ключа"
fi

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
