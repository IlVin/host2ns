#!/usr/bin/env bash
# install-ns.sh — установка приёмника и генератора зон на NS-хосте.
# Запускается с sudo; на вход получает каталог с исходниками (SRC).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
RUN_USER="${RUN_USER:-root}"
# SRC задаёт диспетчер (root-каталог); --src не принимаем, чтобы нельзя было
# подсунуть код из /tmp через NOPASSWD-вызов.
SRC="${SRC:-$HERE}"

die() { echo "ОШИБКА: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

# параметры идут в root-пути: без проверки --name '..' уводит chown куда угодно
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || die "плохое NAME: $NAME"
[[ "$BASE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "плохая BASE: $BASE"
[[ "$RUN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && id -u "$RUN_USER" >/dev/null 2>&1 \
    || die "нет такого пользователя: $RUN_USER"
[ "$(id -u)" = "0" ] || die "нужен root"
command -v nsd >/dev/null || die "NSD не установлен: сначала make bootstrap-nsd HOST=<ns>"
[ -f "$SRC/zonegen.sh" ] || die "нет исходников в $SRC"

echo "  каталоги"
install -d -m 755 "/var/lib/$NAME/state" "/etc/$NAME" /etc/nsd/nsd.conf.d
chown -R "$RUN_USER" "/var/lib/$NAME"

echo "  база имён"
# приёмник и генератор читают BASE отсюда: окружения юнита им не хватает
printf '%s\n' "$BASE" > "/etc/$NAME/base"
chmod 644 "/etc/$NAME/base"

echo "  скрипты"
install -m 755 -o root -g root "$SRC/zonegen.sh"  "/usr/local/bin/$NAME-zonegen.sh"
install -m 755 -o root -g root "$SRC/receiver.sh" "/usr/local/bin/$NAME-recv.sh"
install -m 755 -o root -g root "$SRC/rebuild.sh"  "/usr/local/bin/$NAME-rebuild.sh"

echo "  юнит генерации зон"
cat > "/etc/systemd/system/$NAME-zones.service" <<UNIT
[Unit]
Description=host2ns: генерация зон NSD из состояния
Before=nsd.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=NAME=$NAME
Environment=NO_RESTART=1
ExecStart=/usr/local/bin/$NAME-rebuild.sh

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "/etc/systemd/system/$NAME-zones.service"

echo "  связка с nsd"
mkdir -p /etc/systemd/system/nsd.service.d
printf '[Unit]\nWants=%s-zones.service\nAfter=%s-zones.service\n' "$NAME" "$NAME" \
    > "/etc/systemd/system/nsd.service.d/10-$NAME-zones.conf"
chmod 644 "/etc/systemd/system/nsd.service.d/10-$NAME-zones.conf"

systemctl daemon-reload
systemctl enable "$NAME-zones.service" >/dev/null 2>&1 || true
echo "  sudoers для приёмника"
cat > "/etc/sudoers.d/90-$NAME" <<SUDO
# host2ns: приёмник запускается forced command в authorized_keys
Defaults!/usr/local/bin/$NAME-recv.sh env_keep += "SSH_CONNECTION"
$RUN_USER ALL=(root) NOPASSWD: /usr/local/bin/$NAME-recv.sh
SUDO
chmod 440 "/etc/sudoers.d/90-$NAME"
visudo -cf "/etc/sudoers.d/90-$NAME" >/dev/null || { rm -f "/etc/sudoers.d/90-$NAME"; echo "sudoers не прошёл проверку" >&2; exit 1; }
echo "  приёмник установлен"
