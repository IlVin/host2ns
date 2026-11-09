#!/usr/bin/env bash
# zonegen.sh — генерация зон NSD из состояния и применение конфига.
# Подключается приёмником и восстановлением; сама ничего не решает.
set -u

NAME="${NAME:-host2ns}"
BASE_FILE="${BASE_FILE:-/etc/$NAME/base}"
BASE="${BASE:-iv77msk.ru}"
# BASE живёт в файле, а не в окружении: приёмник запускается из forced command,
# где окружение установщика недоступно.
if [ -f "$BASE_FILE" ]; then
    BASE="$(tr -d '[:space:]' < "$BASE_FILE")"
fi
[ -n "$BASE" ] || { echo "ОШИБКА: пустой BASE ($BASE_FILE)" >&2; exit 2; }
STATE="${STATE:-/var/lib/$NAME/state}"
ZONEDIR="${ZONEDIR:-/var/lib/nsd/zones}"
ZONES_CONF="${ZONES_CONF:-/etc/nsd/nsd.conf.d/10-$NAME-zones.conf}"
ZONELIST="${ZONELIST:-/run/nsd/zone.list}"
ZONELIST_CONF="${ZONELIST_CONF:-/etc/nsd/nsd.conf.d/zonelistfile.conf}"
DRY="${DRY:-0}"

# zone_render <каталог состояния зоны> <файл зоны>
zone_render() {
    local d="$1" zf="$2" f n a tmp
    # пишем рядом и переименовываем: NSD не должен увидеть половину файла
    tmp="$(mktemp "$(dirname "$zf")/.$(basename "$zf").XXXXXX")"
    if ! {
        printf '$TTL 60\n'
        printf '@ IN SOA ns.%s. admin.%s. ( %s 3600 600 604800 60 )\n' "$BASE" "$BASE" "$(date +%s)"
        printf '@ IN NS ns.%s.\n' "$BASE"
        for f in "$d"/*; do
            [ -f "$f" ] || continue
            while read -r n a; do
                [ -z "$n" ] && continue
                case "$a" in
                    *:*) printf '%s IN AAAA %s\n' "$n" "$a" ;;
                    *)   printf '%s IN A %s\n' "$n" "$a" ;;
                esac
            done < "$f"
        done
    } > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp"
    chown nsd:nsd "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$zf"
}

# zones_apply — перегенерировать зоны и применить конфиг.
# NO_RESTART=1 — только файлы (режим юнита перед nsd).
zones_apply() {
    local d zone zf conf_tmp
    local -A keep=()
    mkdir -p "$STATE" "$ZONEDIR"
    install -d -m 755 "$(dirname "$ZONES_CONF")"
    conf_tmp="$(mktemp "$(dirname "$ZONES_CONF")/.$NAME-zones.XXXXXX")"

    for d in "$STATE"/*/; do
        [ -d "$d" ] || continue
        # пустая зона — не зона: не рендерим и не пишем в конфиг
        if [ -z "$(find "$d" -maxdepth 1 -type f -print -quit)" ]; then
            continue
        fi
        zone="$(basename "$d")"
        keep["$zone"]=1
        zf="$ZONEDIR/$zone.zone"
        zone_render "$d" "$zf"
        if [ "$DRY" = "1" ]; then printf '[dry] %s\n' "$zf"; continue; fi
        printf 'zone:\n\tname: "%s"\n\tzonefile: "%s.zone"\n\n' "$zone" "$zone" >> "$conf_tmp"
    done

    if [ "$DRY" = "1" ]; then rm -f "$conf_tmp"; return 0; fi

    # конфиг тоже заменяем атомарно
    chmod 644 "$conf_tmp"
    mv -f "$conf_tmp" "$ZONES_CONF"

    # zonelistfile — в /run: каталог принадлежит NSD
    if [ ! -f "$ZONELIST_CONF" ]; then
        printf 'server:\n\tzonelistfile: "%s"\n' "$ZONELIST" > "$ZONELIST_CONF"
        chmod 644 "$ZONELIST_CONF"
    fi
    # файлы удалённых зон не должны оставаться в zonesdir
    for zf in "$ZONEDIR"/*.zone; do
        [ -f "$zf" ] || continue
        zone="$(basename "$zf" .zone)"
        [ -n "${keep[$zone]:-}" ] || rm -f "$zf"
    done

    if [ -f "$ZONELIST" ]; then
        : > "$ZONELIST"
        chown nsd:nsd "$ZONELIST" 2>/dev/null || true
    fi
    chown -R nsd:nsd "$ZONEDIR" 2>/dev/null || true

    if [ "${NO_RESTART:-0}" = "1" ]; then return 0; fi

    if systemctl is-active --quiet nsd 2>/dev/null; then
        # reconfig перечитывает состав зон, но не их данные: для данных reload
        nsd-control reconfig >/dev/null 2>&1 || true
        if ! nsd-control reload >/dev/null 2>&1; then
            systemctl restart nsd >/dev/null 2>&1 || return 1
        fi
    else
        systemctl reset-failed nsd >/dev/null 2>&1 || true
        systemctl start nsd >/dev/null 2>&1 || return 1
    fi
    # «ok» имеет смысл только если NSD действительно работает с новыми данными
    systemctl is-active --quiet nsd 2>/dev/null
}
