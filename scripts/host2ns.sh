#!/usr/bin/env bash
# host2ns.sh — отправитель: публикует адреса и имена хоста на NS-хосте.
# Политика FAMILY (список через запятую): auto|ipv6|ipv4|nat
#   ipv6 — свои AAAA; ipv4 — свои A; nat — IPv4, который видит NS; auto — свои оба.
set -euo pipefail

NAME="${NAME:-host2ns}"
CFG="${CFG:-/etc/$NAME}"
STATE="${STATE:-/var/lib/$NAME/last}"
NS="${NS:-@NS@}"
KEY="$CFG/key"
ID_FILE="$CFG/id"
NAMES_FILE="$CFG/names"

if [ ! -e "$NAMES_FILE" ]; then exit 0; fi
if [ ! -r "$NAMES_FILE" ]; then
    echo "нет доступа к $NAMES_FILE" >&2
    exit 2
fi



FAMILY="${FAMILY:-ipv6,ipv4}"
[ -f "$CFG/family" ] && FAMILY="$(cat "$CFG/family")"

pub6=0; pub4=0; nat=0
IFS=',' read -r -a TOK <<< "$FAMILY"
for t in "${TOK[@]}"; do
    case "$t" in
        ipv6) pub6=1 ;;
        ipv4) pub4=1 ;;
        nat)  nat=1 ;;
        *) echo "неизвестное значение FAMILY: $t (допустимо ipv4, ipv6, nat)" >&2; exit 2 ;;
    esac
done

id="$(cat "$ID_FILE" 2>/dev/null || hostname -s)"
addr6="$(ip -6 -o addr show scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
addr4="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
[ "$pub6" = "1" ] || addr6=""
[ "$pub4" = "1" ] || addr4=""
# приватный IPv4 в DNS не публикуем: снаружи бесполезен
case "$addr4" in
    10.*|192.168.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) addr4="" ;;
esac
[ -n "$addr6" ] || [ -n "$addr4" ] || [ "$nat" = "1" ] || exit 0

names="$(tr '\n' ',' < "$NAMES_FILE")"
cur="v2|$id|$addr6|$addr4|$nat|$FAMILY|$names"

if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$cur" ]; then exit 0; fi

{
  printf 'host %s\n' "$id"
  printf 'policy %s\n' "$FAMILY"
  while read -r n; do
    [ -z "$n" ] && continue
    printf '%s %s %s\n' "$n" "$addr6" "$addr4"
  done < "$NAMES_FILE"
} | ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 "$NS"

mkdir -p "$(dirname "$STATE")"
printf '%s\n' "$cur" > "$STATE"