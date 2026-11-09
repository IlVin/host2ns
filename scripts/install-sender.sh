#!/usr/bin/env bash
# install-sender.sh — установка host2ns на хосте-отправителе (локальная часть).
# Приёмник на NS-хосте ставится отдельно (install-ns.sh), см. publish.sh.
set -euo pipefail

NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
NS=""; NAMES=""; FAMILY="${FAMILY:-ipv6,ipv4}"; ID="$(hostname -s)"; RUN_USER="$(id -un)"
HERE="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns) NS="$2"; shift 2 ;;
    --names) NAMES="$2"; shift 2 ;;
    --id) ID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --family) FAMILY="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
[ -n "$NS" ] || { echo "нужен --ns user@host" >&2; exit 2; }

CFG="/etc/$NAME"
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 2; }

echo "  отправитель на $(hostname -s)"
sudo -v || die "нужны права sudo"

sudo -n install -d -m 755 -o "$RUN_USER" -g "$(id -gn)" "/var/lib/$NAME"
sudo -n install -d -m 755 "$CFG"

if [ ! -f "$CFG/key" ]; then
  if [ -f "/etc/yach/ddns-key" ]; then
    sudo -n install -m 400 -o "$RUN_USER" -g "$(id -gn)" /etc/yach/ddns-key "$CFG/key"
    sudo -n rm -f /etc/yach/ddns-key /etc/yach/ddns-key.pub
    echo "  ключ перенесён из /etc/yach"
  else
    ssh-keygen -t ed25519 -N "" -C "$NAME@$ID" -f "/tmp/$NAME-key" >/dev/null
    sudo -n install -m 400 -o "$RUN_USER" -g "$(id -gn)" "/tmp/$NAME-key" "$CFG/key"
    sudo -n install -m 644 -o "$RUN_USER" -g "$(id -gn)" "/tmp/$NAME-key.pub" "$CFG/key.pub"
    rm -f "/tmp/$NAME-key" "/tmp/$NAME-key.pub"
  fi
fi

printf '%s\n' "$ID" | sudo -n tee "$CFG/id" >/dev/null
if [ -n "$NAMES" ]; then printf '%s\n' $NAMES | sudo -n tee "$CFG/names" >/dev/null; fi
printf '%s\n' "$FAMILY" | sudo -n tee "$CFG/family" >/dev/null
sudo -n chmod 644 "$CFG/id"; sudo -n chmod 644 "$CFG/names" 2>/dev/null || true

sed "s|@NS@|$NS|" "$HERE/host2ns.sh" > "/tmp/$NAME-sender.sh"
sudo -n install -m 755 -o root -g root "/tmp/$NAME-sender.sh" "/usr/local/bin/$NAME.sh"
rm -f "/tmp/$NAME-sender.sh"

sudo -n tee "/etc/systemd/system/$NAME.service" >/dev/null <<UNIT
[Unit]
Description=host2ns: публикация адресов хоста в DNS
After=network-online.target

[Service]
Type=oneshot
User=$RUN_USER
Environment=NAME=$NAME
Environment=FAMILY=$FAMILY
ExecStart=/usr/local/bin/$NAME.sh
UNIT
sudo -n tee "/etc/systemd/system/$NAME.timer" >/dev/null <<UNIT
[Unit]
Description=host2ns: периодическая публикация

[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
AccuracySec=1min

[Install]
WantedBy=timers.target
UNIT
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now "$NAME.timer" >/dev/null
sudo -n systemctl start "$NAME.service" || { sudo -n journalctl -u "$NAME.service" -n 10 --no-pager >&2; die "служба публикации упала"; }

sleep 1
sudo -n test -s "/var/lib/$NAME/last" || {
  sudo -n journalctl -u "$NAME.service" -n 5 --no-pager >&2 || true
  die "отправитель не опубликовал данные"
}
echo "  готово: $ID ($NAMES)"
