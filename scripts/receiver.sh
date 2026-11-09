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

# --- проверка адресов --------------------------------------------------------
# Строка из зоны должна быть настоящим глобальным адресом: иначе одна
# опечатка делает зону невалидной и NSD перестаёт её загружать.
is_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $ip; do
        [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        [ "$o" -le 255 ] || return 1
    done
}

is_public_ipv4() {
    case "$1" in
        0.*|10.*|127.*|169.254.*|192.168.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
        22[4-9].*|23[0-9].*|24[0-9].*|25[0-5].*) return 1 ;;
    esac
}

is_ipv6() {
    # Разбираем сами: getent зависит от включённого IPv6 в ядре, а NS может
    # жить с выключенным IPv6 и всё равно обслуживать зоны с AAAA.
    awk -v ip="$1" 'BEGIN {
        if (ip == "" || ip !~ /^[0-9A-Fa-f:]+$/ || ip !~ /:/) exit 1
        n = split(ip, parts, "::")
        if (n > 2) exit 1
        total = 0
        for (i = 1; i <= n; i++) {
            if (parts[i] == "") continue
            m = split(parts[i], group, ":")
            for (j = 1; j <= m; j++) {
                if (group[j] == "" || length(group[j]) > 4 || group[j] !~ /^[0-9A-Fa-f]+$/) exit 1
                total++
            }
        }
        if (n == 1) exit (total == 8 ? 0 : 1)
        exit (total < 8 ? 0 : 1)
    }'
}

is_public_ipv6() {
    case "$1" in
        ::|::1) return 1 ;;
        [fF][cCdD]*) return 1 ;;                                   # fc00::/7
        [fF][eE]8*|[fF][eE]9*|[fF][eE][aA]*|[fF][eE][bB]*) return 1 ;; # fe80::/10
        [fF][fF]*) return 1 ;;                                     # ff00::/8
    esac
}

addr_ok() {
    if [[ "$1" == *:* ]]; then
        is_ipv6 "$1" && is_public_ipv6 "$1"
    else
        is_ipv4 "$1" && is_public_ipv4 "$1"
    fi
}

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
        addr_ok "$addr" || { echo "плохой адрес: $addr" >&2; exit 2; }
        add_record "$zone" "$rel" "$addr"
    done
done

ID="$(printf '%s' "$ID" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
[ -n "$ID" ] || { echo "пустой id" >&2; exit 2; }
POLICY="$(printf '%s' "$POLICY" | tr -d '[:space:]')"

# nat: публичный IPv4, который видит NS. Берём из SSH_CONNECTION (ставит sshd).
if printf '%s' "$POLICY" | tr ',' '\n' | grep -qx nat; then
    seen="${SSH_CONNECTION:-}"
    seen="${seen%% *}"
    # IPv6 и приватный IPv4 из SSH_CONNECTION в DNS не публикуем
    if [[ "$seen" != *:* ]] && is_ipv4 "$seen" && is_public_ipv4 "$seen"; then
        for mf in "$META"/*; do
            [ -f "$mf" ] || continue
            zone="$(basename "$mf")"
            while read -r rel; do
                [ -z "$rel" ] && continue
                add_record "$zone" "$rel" "$seen"
            done < "$mf"
        done
    fi
fi

# Зоны, которые хост объявил в этом сеансе.
declare -A DECLARED=()
for mf in "$META"/*; do
    [ -f "$mf" ] || continue
    DECLARED["$(basename "$mf")"]=1
done

# Файл состояния в каждой объявленной зоне: новый набор заменяет прежний,
# пустой — удаляет. Имена без адресов (например, неудачный nat) файла не дают.
for zone in "${!DECLARED[@]}"; do
    f="$TMPD/$zone"
    if [ -s "$f" ]; then
        mkdir -p "$STATE/$zone"
        sort -u -o "$f" "$f"
        install -m 644 "$f" "$STATE/$zone/$ID"
    else
        rm -f "$STATE/$zone/$ID"
    fi
done

# В зонах, которые хост больше не объявляет, его записей быть не должно.
for d in "$STATE"/*/; do
    [ -d "$d" ] || continue
    zone="$(basename "$d")"
    [ -n "${DECLARED[$zone]:-}" ] || rm -f "$d/$ID"
done

# Пустой каталог зоны не нужен: он попал бы в конфиг NSD пустой зоной.
for d in "$STATE"/*/; do
    [ -d "$d" ] || continue
    rmdir "$d" 2>/dev/null || true
done

zones_apply
records="$(find "$TMPD" -maxdepth 1 -mindepth 1 -type f -printf '%f ' | sed 's/ $//')"
if [ -z "$records" ]; then
    echo "ok: $ID -> все имена удалены"
else
    echo "ok: $ID -> $records"
fi
