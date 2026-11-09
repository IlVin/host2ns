#!/usr/bin/env bash
# prune.sh — удалить имена хостов, которых больше нет в реестре.
#
# Состояние на NS перечисляет id хостов; всё, чего нет в ~/.host2ns/hosts,
# удаляется пустым набором через приёмник. Хосты при этом не опрашиваются.
set -euo pipefail

NAME="${NAME:-host2ns}"
H2H="${HOST2NS_HOME:-$HOME/.$NAME}"
HOSTS="$H2H/hosts"
RECV="/usr/local/bin/$NAME-recv.sh"

[ -f "$HOSTS" ] || { echo "нет $HOSTS — скопируйте registry.example" >&2; exit 2; }
[ -f "$H2H/config" ] || { echo "нет $H2H/config — скопируйте config.example" >&2; exit 2; }
. "$H2H/config"
[ -n "${NS:-}" ] || { echo "в config нет NS" >&2; exit 2; }
[[ "$NS" != -* && "$NS" =~ ^[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$ ]] \
    || { echo "плохой NS в config: $NS" >&2; exit 2; }

# приёмник приводит id к имени файла; для сравнения делаем то же
sanitize_id() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-'; }

declare -A wanted=()
while IFS= read -r line; do
    line="${line%%#*}"
    read -r host _ <<< "$line"
    [ -n "${host:-}" ] || continue
    wanted["$(sanitize_id "$host")"]=1
done < "$HOSTS"

ids="$(ssh -n "$NS" "find /var/lib/$NAME/state -mindepth 2 -maxdepth 2 -type f -printf '%f\\n' 2>/dev/null" | sort -u)" || {
    echo "не удалось прочитать состояние на $NS" >&2
    exit 1
}
if [ -z "$ids" ]; then
    echo "состояние на $NS пусто"
    exit 0
fi

removed=0
for id in $ids; do
    [ -n "${wanted[$id]:-}" ] && continue
    printf '  удаляю: %s\n' "$id"
    printf 'host %s\npolicy ipv6,ipv4\n' "$id" | ssh "$NS" "sudo -n $RECV" || {
        echo "не удалось удалить $id" >&2
        exit 1
    }
    removed=$((removed + 1))
done
echo "удалено хостов: $removed"
