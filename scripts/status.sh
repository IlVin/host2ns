#!/usr/bin/env bash
# status.sh — состояние host2ns: зоны, имена с политикой, свежесть публикаций.
#   ./scripts/status.sh
#   NS=user@host BASE=iv77msk.ru ./scripts/status.sh
set -uo pipefail

NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
FAMILY="${FAMILY:-ipv6,ipv4}"
CFG_DIR="${HOST2NS_HOME:-$HOME/.$NAME}"
NS="${NS:-}"
[ -f "$CFG_DIR/config" ] && . "$CFG_DIR/config"
[ -n "$NS" ] || { echo "нет NS в $CFG_DIR/config" >&2; exit 2; }
FAMILY="$(printf '%s' "$FAMILY" | tr -d '[:space:]')"
BASE="$(printf '%s' "$BASE" | tr -d '[:space:]')"
HOSTS_FILE="${HOSTS_FILE:-$CFG_DIR/hosts}"
NS_ADDR="${NS#*@}"
BAD=0

declare -A FAM
if [ -f "$CFG_DIR/policy" ]; then
    while read -r line; do
        line="${line%%#*}"
        read -r h f <<< "$line"
        [ -n "${h:-}" ] || continue
        FAM["$h"]="$(printf '%s' "${f:-}" | tr -d '[:space:]')"
    done < "$CFG_DIR/policy"
fi
fam_of() { printf '%s' "${FAM[$1]:-$FAMILY}" | tr -d '[:space:]'; }
wants() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

echo "== зоны на NS ($NS)"
zones="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$NS" "ls -1 /var/lib/$NAME/state 2>/dev/null" || true)"
if [ -n "$zones" ]; then printf '%s\n' "$zones" | sed 's/^/  /'; else echo "  нет зон"; BAD=1; fi

echo
printf "== имена (политика из config: FAMILY=$FAMILY)\n"
printf '  %-28s %-12s %-46s %s\n' "DOMAIN" "POLICY" "IPv6" "IPv4"
if [ -f "$HOSTS_FILE" ]; then
  while read -r line; do
    line="${line%%#*}"
    read -r host names <<< "$line"
    [ -n "${host:-}" ] || continue
    fam="$(fam_of "$host")"
    for n in $names; do
      v6="$(dig +time=1 +tries=1 +short AAAA "$n.$BASE" @"$NS_ADDR" 2>/dev/null | head -1)"
      v4="$(dig +time=1 +tries=1 +short A "$n.$BASE" @"$NS_ADDR" 2>/dev/null | head -1)"
      printf "  %-28s %-12s %-46s %s\n" "$n.$BASE" "$fam" "${v6:--}" "${v4:--}"
      [ -n "$v6" ] || [ -n "$v4" ] || BAD=1
      # сверка с политикой
      if [ -n "$v6" ] && ! wants "$fam" ipv6; then
          printf '      ! IPv6 есть, но политика не включает ipv6\n'; BAD=1; fi
      if [ -n "$v4" ] && ! wants "$fam" ipv4 && ! wants "$fam" nat; then
          printf '      ! IPv4 есть, но политика не включает ipv4/nat\n'; BAD=1; fi
      if wants "$fam" nat && [ -z "$v4" ]; then
          printf '      ! политика ждёт nat, но IPv4 нет\n'; BAD=1; fi
      if wants "$fam" ipv6 && [ -z "$v6" ]; then
          printf '      ! политика ждёт ipv6, но AAAA нет\n'; BAD=1; fi
      if wants "$fam" ipv4 && ! wants "$fam" nat && [ -z "$v4" ]; then
          printf '      ! политика ждёт ipv4, но A нет\n'; BAD=1; fi
    done
  done < "$HOSTS_FILE"
else
  echo "  нет $HOSTS_FILE"; BAD=1
fi

echo
echo "== записи в состоянии"
ssh -n "$NS" "find /var/lib/$NAME/state -mindepth 2 -maxdepth 2 -type f -printf '%P\n'" 2>/dev/null \
  | awk -F/ '{ z=$1; sub(/^[^\/]*\//,""); a[z]=a[z] " " $0 } END { for (z in a) printf "  %s:%s\n", z, a[z] }'

echo
echo "== последняя публикация"
if [ -f "$HOSTS_FILE" ]; then
  while read -r line; do
    line="${line%%#*}"
    read -r host names <<< "$line"
    [ -n "${host:-}" ] || continue
    [ "$host" = "$NS_ADDR" ] && continue
    ts="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "stat -c %y /var/lib/$NAME/last 2>/dev/null" 2>/dev/null)"
    printf '  %-24s %-12s %s\n' "$host" "$(fam_of "$host")" "${ts:-нет данных}"
  done < "$HOSTS_FILE"
fi

echo
if [ "$BAD" = "0" ]; then echo "ИТОГ: всё на месте и соответствует политике"; exit 0; fi
echo "ИТОГ: есть замечания"; exit 1
