#!/usr/bin/env bash
# host2ns.sh — отправитель: публикует адреса и имена хоста на NS-хосте.
# Политика FAMILY (список через запятую): ipv6|ipv4|nat
#   ipv6 — свои AAAA; ipv4 — свои A; nat — IPv4, который видит NS.
set -euo pipefail

# --- выбор адреса ------------------------------------------------------------
# temporary/deprecated IPv6 меняются под ногами: публикуем стабильный адрес.
ipv6_candidates() {
    awk '/temporary|deprecated/ { next } { split($4, a, "/"); print a[1] }'
}

ipv4_candidates() {
    awk '{ split($4, a, "/"); print a[1] }'
}

is_ula_v6() {
    case "$1" in
        [fF][cCdD]*) return 0 ;;
    esac
    return 1
}

is_private_v4() {
    case "$1" in
        0.*|10.*|127.*|169.254.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        22[4-9].*|23[0-9].*|24[0-9].*|25[0-5].*) return 0 ;;
    esac
    return 1
}

first_public_v6() {
    local ip
    while read -r ip; do
        [ -n "$ip" ] || continue
        is_ula_v6 "$ip" && continue
        printf '%s\n' "$ip"
        return 0
    done
}

first_public_v4() {
    local ip
    while read -r ip; do
        [ -n "$ip" ] || continue
        is_private_v4 "$ip" && continue
        printf '%s\n' "$ip"
        return 0
    done
}

# parse_family выводит "pub6 pub4 nat" или возвращает 2.
parse_family() {
    local family="$1" t pub6=0 pub4=0 nat=0
    local -a tok=()
    IFS=',' read -r -a tok <<< "$family"
    for t in "${tok[@]}"; do
        case "$t" in
            ipv6) pub6=1 ;;
            ipv4) pub4=1 ;;
            nat)  nat=1 ;;
            *)
                echo "неизвестное значение FAMILY: $t (допустимо ipv4, ipv6, nat)" >&2
                return 2
                ;;
        esac
    done
    printf '%s %s %s\n' "$pub6" "$pub4" "$nat"
}

main() {
    local NAME="${NAME:-host2ns}"
    local CFG="${CFG:-/etc/$NAME}"
    local STATE="${STATE:-/var/lib/$NAME/last}"
    local NS="${NS:-@NS@}"
    local KEY="$CFG/key" ID_FILE="$CFG/id" NAMES_FILE="$CFG/names"
    local FAMILY="${FAMILY:-ipv6,ipv4}"
    local id addr6="" addr4="" pub6 pub4 nat parsed
    local -a names_arr=()
    local n names=""

    if [ ! -e "$NAMES_FILE" ]; then exit 0; fi
    if [ ! -r "$NAMES_FILE" ]; then
        echo "нет доступа к $NAMES_FILE" >&2
        exit 2
    fi
    command -v ip >/dev/null || { echo "нет команды ip (iproute2)" >&2; exit 2; }

    [ -f "$CFG/family" ] && FAMILY="$(tr -d '[:space:]' < "$CFG/family")"
    [ -n "$FAMILY" ] || { echo "пустой FAMILY в $CFG/family" >&2; exit 2; }
    [ -n "$NS" ] && [ "$NS" != "@NS@" ] \
        || { echo "не задан NS: шаблон @NS@ не заменён установщиком" >&2; exit 2; }
    parsed="$(parse_family "$FAMILY")" || exit 2
    read -r pub6 pub4 nat <<< "$parsed"

    id="$(cat "$ID_FILE" 2>/dev/null || hostname -s)"
    [ -n "$id" ] || { echo "пустой id в $ID_FILE" >&2; exit 2; }
    if [ "$pub6" = "1" ]; then
        addr6="$(ip -6 -o addr show scope global 2>/dev/null | ipv6_candidates | first_public_v6)"
    fi
    if [ "$pub4" = "1" ]; then
        addr4="$(ip -4 -o addr show scope global 2>/dev/null | ipv4_candidates | first_public_v4)"
    fi
    # Пустой набор адресов — тоже состояние: приёмник удалит прежние записи.
    # Иначе имя продолжало бы указывать на уже несуществующий адрес.

    while IFS= read -r n; do
        n="${n%%#*}"
        n="${n//[[:space:]]/}"
        [ -n "$n" ] && names_arr+=("$n")
    done < "$NAMES_FILE"
    if [ "${#names_arr[@]}" -gt 0 ]; then
        for n in "${names_arr[@]}"; do names+="$n,"; done
    fi

    # NS в ключе: смена приёмника должна вызвать переотправку
    local cur="v3|$id|$NS|$addr6|$addr4|$nat|$FAMILY|$names"
    if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$cur" ]; then exit 0; fi

    {
        printf 'host %s\n' "$id"
        printf 'policy %s\n' "$FAMILY"
        if [ "${#names_arr[@]}" -gt 0 ]; then
            for n in "${names_arr[@]}"; do
                printf '%s %s %s\n' "$n" "$addr6" "$addr4"
            done
        fi
    } | ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 "$NS"

    mkdir -p "$(dirname "$STATE")"
    printf '%s\n' "$cur" > "$STATE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
