#!/usr/bin/env bash
# host2ns-install.sh — единственная команда, разрешённая без пароля.
# Лежит /usr/local/bin, вызывает установщики из /usr/local/lib/host2ns.
#
# Имя проекта берётся из имени самого файла: <NAME>-install.sh.
#   sudo -n host2ns-install.sh sender --ns user@host --names "a.b c.d"
#   sudo -n host2ns-install.sh ns     --base example.ru
set -euo pipefail

SELF="${0##*/}"
NAME="${SELF%-install.sh}"
[[ "$NAME" != "$SELF" && "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || {
    echo "плохое имя диспетчера: $SELF (ожидается <name>-install.sh)" >&2
    exit 2
}
LIB="/usr/local/lib/$NAME"
RUN_USER="${SUDO_USER:-root}"
export NAME RUN_USER

ACTION="${1:-}"
shift || true

case "$ACTION" in
    sender|ns)
        INSTALLER="$LIB/install-$ACTION.sh"
        [ -f "$INSTALLER" ] || {
            echo "нет $INSTALLER: сделайте make bootstrap-host HOST=${HOST:-<хост>}" >&2
            exit 2
        }
        [ "$(id -u)" = "0" ] || { echo "нужен root: запускайте через sudo" >&2; exit 2; }
        if [ "$ACTION" = "ns" ]; then
            exec env SRC="$LIB" bash "$INSTALLER" "$@"
        fi
        exec bash "$INSTALLER" "$@"
        ;;
    *)
        echo "использование: $SELF sender|ns [параметры]" >&2
        exit 2
        ;;
esac
