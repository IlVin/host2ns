#!/usr/bin/env bash
# install.sh — установка host2ns на хосте-отправителе.
#
#   ./scripts/install.sh --ns user@ns-host --names "tg.d.plb hub.d.plb" [--id host]
#
# На NS-хост кладёт приёмник через ssh (sudo спросит пароль один раз).
set -euo pipefail

NAME="${NAME:-host2ns}"
BASE="${BASE:-iv77msk.ru}"
NS=""; NAMES=""; ID="$(hostname -s)"; RUN_USER="$(id -un)"
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="/tmp/$NAME-pkg"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns) NS="$2"; shift 2 ;;
    --names) NAMES="$2"; shift 2 ;;
    --id) ID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
[ -n "$NS" ] || { echo "нужен --ns user@host" >&2; exit 2; }

CFG="/etc/$NAME"
SSH="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 2; }

echo "== $NAME: установка на $NS"

# один пароль на хост: дальше sudo работает по кэшу
sudo -v || die "нужны права sudo на этом хосте"

# 1. исходники на NS (без sudo, обычный stdin)
tar -czf - -C "$HERE" . | ssh $SSH "$NS" "rm -rf '$PKG' && mkdir -p '$PKG' && tar -xzf - -C '$PKG'" \
  || die "не удалось положить исходники на $NS"

# 2. приёмник (одна сессия, один пароль)
ssh -t $SSH "$NS" "sudo NAME='$NAME' BASE='$BASE' RUN_USER='$RUN_USER' SRC='$PKG' bash '$PKG/install-ns.sh'" \
  || die "не удалось настроить NS-хост"

# 3. ключ и данные отправителя
sudo -n install -d -m 755 "$CFG" "/var/lib/$NAME"
if [ ! -f "$CFG/key" ]; then
  if [ -f "/etc/yach/ddns-key" ]; then
    sudo -n install -m 400 /etc/yach/ddns-key "$CFG/key"
    sudo -n rm -f /etc/yach/ddns-key /etc/yach/ddns-key.pub
    echo "  ключ перенесён из /etc/yach"
  else
    ssh-keygen -t ed25519 -N "" -C "$NAME@$ID" -f "/tmp/$NAME-key" >/dev/null
    sudo -n install -m 400 "/tmp/$NAME-key" "$CFG/key"
    sudo -n install -m 644 "/tmp/$NAME-key.pub" "$CFG/key.pub"
    rm -f "/tmp/$NAME-key" "/tmp/$NAME-key.pub"
  fi
fi
printf '%s\n' "$ID" | sudo -n tee "$CFG/id" >/dev/null
[ -n "$NAMES" ] && printf '%s\n' $NAMES | sudo -n tee "$CFG/names" >/dev/null
sudo -n chmod 644 "$CFG/id" "$CFG/names" 2>/dev/null || true

# 4. отправитель и таймер
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
sudo -n systemctl start "$NAME.service" || true

# 5. проверка
sleep 1
sudo -n test -s "/var/lib/$NAME/last" || {
  sudo -n journalctl -u "$NAME.service" -n 5 --no-pager >&2 || true
  die "отправитель не опубликовал данные"
}
echo "готово: $ID -> $NS ($NAMES)"
