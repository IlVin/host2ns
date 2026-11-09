#!/usr/bin/env bash
# receiver.sh — приём имён от хоста и запись в состояние.
#
# Протокол по stdin:
#   host <id>
#   policy <auto|ipv6|ipv4|nat>[,<...>]
#   <имя> <адрес> [<адрес>...]
#
# Токен nat: к именам добавляется IPv4, который видит NS в SSH_CONNECTION —
# это публичный адрес роутера для хоста за NAT.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${NAME:-host2ns}"
STATE="${STATE:-/var/lib/$NAME/state}"
if [ -f "$HERE/zonegen.sh" ]; then
    . "$HERE/zonegen.sh"
else
    . "$HERE/$NAME-zonegen.sh"
fi

LABEL_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'

ID=""; POLICY=""
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

while read -r a b rest; do
    [ -z "${a:-}" ] && continue
    case "$a" in
        host)   ID="${b:-}"; continue ;;
        policy) POLICY="${b:-}"; continue ;;
    esac
    name="$(printf '%s' "$a" | tr 'A-Z' 'a-z')"
    addrs="${b:-} ${rest:-}"
    [[ "$name" == *.* ]] || { echo "имя без зоны: $name" >&2; exit 2; }
    zlabel="${name##*.}"; rel="${name%.*}"
    [[ "$zlabel" =~ $LABEL_RE ]] || { echo "плохая зона: $zlabel" >&2; exit 2; }
    [[ "$rel" =~ $LABEL_RE ]] || { echo "плохая запись: $rel" >&2; exit 2; }
    for addr in $addrs; do
        [ -z "$addr" ] && continue
        [[ "$addr" =~ ^[0-9a-fA-F:]+$ || "$addr" =~ ^[0-9.]+$ ]] || { echo "плохой адрес: $addr" >&2; exit 2; }
        printf '%s %s\n' "$rel" "$addr" >> "$TMPD/$zlabel.$BASE"
    done
done

ID="$(printf '%s' "$ID" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
[ -n "$ID" ] || { echo "пустой id" >&2; exit 2; }

# nat: публичный IPv4, который видит NS. Берём из SSH_CONNECTION (ставит sshd).
if printf '%s' "$POLICY" | tr ',' '\n' | grep -qx nat; then
    seen="${SSH_CONNECTION:-}"
    seen="${seen%% *}"
    case "$seen" in
        *:*) : ;;                       # IPv6 — не наш случай
        '') : ;;
        *)  for f in "$TMPD"/*; do
                [ -f "$f" ] || continue
                awk -v a="$seen" '{ print $0; print $1, a }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            done ;;
    esac
fi

if [ -z "$(ls -A "$TMPD")" ]; then
    for d in "$STATE"/*/; do
        [ -d "$d" ] || continue
        rm -f "$d/$ID"
    done
    zones_apply
    echo "ok: $ID -> все имена удалены"
    exit 0
fi

for f in "$TMPD"/*; do
    zone="$(basename "$f")"
    mkdir -p "$STATE/$zone"
    sort -u -o "$f" "$f"
    install -m 644 "$f" "$STATE/$zone/$ID"
done

zones_apply
echo "ok: $ID -> $(ls "$TMPD" | tr '\n' ' ')"