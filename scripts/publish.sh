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

declare -A FAM
if [ -f "$H2H/policy" ]; then
    while read -r h f; do
        case "$h" in ''|\#*) continue ;; esac
        FAM["$h"]="$f"
    done < "$H2H/policy"
fi
fam_of() { printf '%s' "${FAM[$1]:-$FAMILY}"; }

mapfile -t LINES < "$HOSTS"
NS_HOST="${NS#*@}"
RUNNER="/usr/local/bin/$NAME-install.sh"

need_bootstrap() {
    echo "нет доступа на $1: сделайте make bootstrap-host HOST=$1" >&2
    exit 1
}

echo "== $NS_HOST: приёмник"
ssh -n "$NS_HOST" "sudo -n $RUNNER ns --name '$NAME' --base '$BASE'" \
    || need_bootstrap "$NS_HOST"

for line in "${LINES[@]}"; do
    [ -z "${line:-}" ] && continue
    case "$line" in \#*) continue ;; esac
    read -r host names <<< "$line"
    [ -n "$host" ] || continue
    fam="$(fam_of "$host")"
    echo "== $host: $names (family=$fam)"
    ssh -n "$host" "sudo -n $RUNNER sender --ns '$NS' --id '$host' --names '$names' --name '$NAME' --family '$fam'" \
        || need_bootstrap "$host"
done

echo "реестр применён"