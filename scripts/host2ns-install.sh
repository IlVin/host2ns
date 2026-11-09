#!/usr/bin/env bash
# host2ns-install.sh — единственная команда, разрешённая без пароля.
# Лежит /usr/local/bin, вызывает установщики из /usr/local/lib/host2ns.
#
#   sudo -n host2ns-install.sh sender --ns user@host --names "a.b c.d"
#   sudo -n host2ns-install.sh ns     --ns user@host
set -euo pipefail

LIB="/usr/local/lib/host2ns"
RUN_USER="${SUDO_USER:-root}"
export RUN_USER
ACTION="${1:-}"
shift || true

case "$ACTION" in
    sender) exec bash "$LIB/install-sender.sh" "$@" ;;
    ns)     exec env SRC="$LIB" bash "$LIB/install-ns.sh" "$@" ;;
    *)
        echo "использование: host2ns-install.sh sender|ns [параметры]" >&2
        exit 2
        ;;
esac
