#!/usr/bin/env bash
# receiver.sh — приём имён от хоста и запись в состояние.
#
# Протокол по stdin:
#   host <id>
#   policy <ipv6|ipv4|nat>[,<...>]
#   <имя> <адрес> [<адрес>...]
#
# Токен nat: к именам добавляется IPv4, который видит NS в SSH_CONNECTION —
# это публичный адрес роутера для хоста за NAT. Имена без собственных адресов
# сохраняются: иначе nat-хосту не к чему было бы приклеить адрес.
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
# имена без адресов: отдельный каталог, чтобы не попасть в обход файлов зон
META="$TMPD/.meta"
mkdir -p "$META"
trap 'rm -rf "$TMPD"' EXIT

add_record() { printf '%s %s\n' "$2" "$3" >> "$TMPD/$1"; }

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
    zone="$zlabel.$BASE"
    grep -qxF "$rel" "$META/$zone" 2>/dev/null || printf '%s\n' "$rel" >> "$META/$zone"
    for addr in $addrs; do
        [ -z "$addr" ] && continue
        [[ "$addr" =~ ^[0-9a-fA-F:]+$ || "$addr" =~ ^[0-9.]+$ ]] || { echo "плохой адрес: $addr" >&2; exit 2; }
        add_record "$zone" "$rel" "$addr"
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
        *)  for mf in "$META"/*; do
                [ -f "$mf" ] || continue
                zone="$(basename "$mf")"
                while read -r rel; do
                    [ -z "$rel" ] && continue
                    add_record "$zone" "$rel" "$seen"
                done < "$mf"
            done ;;
    esac
fi

# Своих записей нет — значит, набор имён пуст.
if [ -z "$(find "$TMPD" -maxdepth 1 -mindepth 1 -type f -print -quit)" ]; then
    for d in "$STATE"/*/; do
        [ -d "$d" ] || continue
        rm -f "$d/$ID"
    done
    zones_apply
    echo "ok: $ID -> все имена удалены"
    exit 0
fi

for f in "$TMPD"/*; do
    [ -f "$f" ] || continue
    zone="$(basename "$f")"
    mkdir -p "$STATE/$zone"
    sort -u -o "$f" "$f"
    install -m 644 "$f" "$STATE/$zone/$ID"
done

zones_apply
echo "ok: $ID -> $(find "$TMPD" -maxdepth 1 -mindepth 1 -type f -printf '%f ' | sed 's/ $//')"
