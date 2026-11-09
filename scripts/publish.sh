#!/usr/bin/env bash
# publish.sh — применить реестр через установщик на хостах (NOPASSWD).
#
# Пароля нет: /usr/local/bin/<NAME>-install.sh разрешён в sudoers на один
# вызов. Код установщика лежит в root-каталоге /usr/local/lib/<NAME> и
# обновляется командой bootstrap-host (там пароль нужен).
#
# Семейство: FAMILY из config, перекрывается ~/.host2ns/policy.
set -euo pipefail

NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
FAMILY="${FAMILY:-ipv6,ipv4}"
H2H="${HOST2NS_HOME:-$HOME/.$NAME}"
HOSTS="$H2H/hosts"

[ -f "$HOSTS" ] || { echo "нет $HOSTS — скопируйте registry.example" >&2; exit 2; }
[ -f "$H2H/config" ] || { echo "нет $H2H/config — скопируйте config.example" >&2; exit 2; }
. "$H2H/config"

# значения уходят в ssh-команды на хостах: проверяем до подключения
[ -n "${NS:-}" ] || { echo "в config нет NS" >&2; exit 2; }
[[ "$NS" != -* && "$NS" =~ ^[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$ ]] \
    || { echo "плохой NS в config: $NS" >&2; exit 2; }
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "плохое NAME: $NAME" >&2; exit 2; }
[[ "$BASE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { echo "плохая BASE: $BASE" >&2; exit 2; }

declare -A FAM
if [ -f "$H2H/policy" ]; then
    while read -r line; do
        line="${line%%#*}"
        read -r h f <<< "$line"
        [ -n "${h:-}" ] || continue
        FAM["$h"]="$(printf '%s' "${f:-}" | tr -d '[:space:]')"
    done < "$H2H/policy"
fi
fam_of() { printf '%s' "${FAM[$1]:-$FAMILY}" | tr -d '[:space:]'; }

HERE="$(cd "$(dirname "$0")" && pwd)"
mapfile -t LINES < "$HOSTS"
RUNNER="/usr/local/bin/$NAME-install.sh"
CFG="/etc/$NAME"

install_failed() {
    echo "установщик на $1 завершился с ошибкой (вывод выше)" >&2
    echo "если хост ещё не подготовлен: make bootstrap-host HOST=$1" >&2
    exit 1
}

echo "== $NS: приёмник"
ssh -n "$NS" "sudo -n $RUNNER ns --name '$NAME' --base '$BASE'" \
    || install_failed "$NS"

install_sender() { # <хост> [доп. аргументы установщика]
    local extra="${2:-}"
    ssh -n "$1" "sudo -n $RUNNER sender --ns '$NS' --id '$1' --names '$names' --name '$NAME' --family '$fam' $extra" \
        || install_failed "$1"
}

for line in "${LINES[@]}"; do
    line="${line%%#*}"
    read -r host names <<< "$line"
    [ -n "${host:-}" ] || continue
    [[ "$host" != -* && "$host" =~ ^[A-Za-z0-9._-]+$ ]] \
        || { echo "плохой хост в реестре: $host" >&2; exit 2; }
    for n in $names; do
        [[ "$n" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
            || { echo "плохое имя в реестре: $n" >&2; exit 2; }
    done
    fam="$(fam_of "$host")"
    [[ "$fam" =~ ^(ipv6|ipv4|nat)(,(ipv6|ipv4|nat))*$ ]] \
        || { echo "плохая политика для $host: $fam" >&2; exit 2; }
    echo "== $host: $names (family=$fam)"

    # 1. данные и ключ, без запуска публикации
    install_sender "$host" --defer-publish

    # 2. ключ хоста разрешаем на NS (forced command приёмника)
    pub="$(ssh -n "$host" "cat '$CFG/key.pub'" 2>/dev/null)" || {
        echo "не удалось прочитать $CFG/key.pub на $host" >&2
        exit 1
    }
    NAME="$NAME" "$HERE/authorize.sh" "$NS" "$pub" || {
        echo "не удалось разрешить ключ $host на $NS" >&2
        exit 1
    }

    # 3. публикация: теперь ключ на NS принят
    install_sender "$host"
done

echo "реестр применён"
