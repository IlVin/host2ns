#!/usr/bin/env bash
# install-ns.sh — установка приёмника и генератора зон на NS-хосте.
# Запускается с sudo; на вход получает каталог с исходниками (SRC).
set -euo pipefail

NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
RUN_USER="${RUN_USER:-root}"
SRC="${SRC:-/tmp/$NAME-pkg/scripts}"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    --src)  SRC="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

[ -f "$SRC/zonegen.sh" ] || { echo "нет исходников в $SRC" >&2; exit 2; }

echo "  каталоги"
install -d -m 755 "/var/lib/$NAME/state" /etc/nsd/nsd.conf.d
if [ -d /var/lib/yach/ddns ] && [ ! -e "/var/lib/$NAME/state/.migrated" ]; then
    cp -a /var/lib/yach/ddns/. "/var/lib/$NAME/state/" 2>/dev/null || true
    touch "/var/lib/$NAME/state/.migrated"
    echo "  состояние перенесено из /var/lib/yach/ddns"
fi
chown -R "$RUN_USER" "/var/lib/$NAME"

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
Environment=BASE=$BASE
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

systemctl disable --now yach-ddns-restore.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/yach-ddns-restore.service
systemctl daemon-reload
systemctl enable "$NAME-zones.service" >/dev/null 2>&1 || true
echo "  ключи хостов: путь к приёмнику"
AK="/home/$RUN_USER/.ssh/authorized_keys"
if [ -f "$AK" ]; then
    cp -a "$AK" "$AK.bak.$(date +%s)"
    RECV="/usr/local/bin/$NAME-recv.sh"
    # одна замена закрывает все варианты: старый путь, литерал $NAME, без -n
    sed -i "s|command=\"[^\"]*-recv\.sh\"|command=\"sudo -n $RECV\"|g" "$AK"
    echo "  обновлено в $AK"
fi
echo "  sudoers для приёмника"
cat > "/etc/sudoers.d/90-$NAME" <<SUDO
# host2ns: приёмник запускается forced command в authorized_keys
Defaults!/usr/local/bin/$NAME-recv.sh env_keep += "SSH_CONNECTION"
$RUN_USER ALL=(root) NOPASSWD: /usr/local/bin/$NAME-recv.sh
SUDO
chmod 440 "/etc/sudoers.d/90-$NAME"
visudo -cf "/etc/sudoers.d/90-$NAME" >/dev/null || { rm -f "/etc/sudoers.d/90-$NAME"; echo "sudoers не прошёл проверку" >&2; exit 1; }
rm -f /etc/sudoers.d/90-yach-ddns
echo "  приёмник установлен"
