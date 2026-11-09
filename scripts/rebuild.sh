#!/usr/bin/env bash
# rebuild.sh — восстановление зон из сохранённого состояния.
# Запускается отдельным юнитом ПЕРЕД nsd: внутри песочницы nsd писать нельзя.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${NAME:-host2ns}"
STATE="${STATE:-/var/lib/$NAME/state}"
if [ -f "$HERE/zonegen.sh" ]; then
    . "$HERE/zonegen.sh"
else
    . "$HERE/$NAME-zonegen.sh"
fi

NO_RESTART=1 zones_apply
echo "ok: зоны применены из $STATE"
