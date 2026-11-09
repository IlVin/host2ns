#!/usr/bin/env bash
# install-sender.sh — установка host2ns на хосте-отправителе (локальная часть).
# Приёмник на NS-хосте ставится отдельно (install-ns.sh), см. publish.sh.
set -euo pipefail

NAME="${NAME:-host2ns}"
NS=""; NAMES=""; FAMILY="${FAMILY:-ipv6,ipv4}"; ID="$(hostname -s)"; RUN_USER="${RUN_USER:-$(id -un)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
NAMES_SET=0; DEFER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ns) NS="$2"; shift 2 ;;
    --names) NAMES="$2"; NAMES_SET=1; shift 2 ;;
    --id) ID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --family) FAMILY="$2"; shift 2 ;;
    --defer-publish) DEFER=1; shift ;;
    # диагностика: от чьего имени пойдёт сервис публикации
    --print-user) printf '%s\n' "$RUN_USER"; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
CFG="/etc/$NAME"
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 2; }

# значения попадают в ssh-команды и пути: проверяем до sudo
[ -n "$NS" ] || die "нужен --ns user@host"
[[ "$NS" != -* && "$NS" =~ ^[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$ ]] || die "плохой NS: $NS"
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || die "плохое NAME: $NAME"
[[ "$ID" != -* && "$ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "плохой id: $ID"
FAMILY="$(printf '%s' "$FAMILY" | tr -d '[:space:]')"
[[ "$FAMILY" =~ ^(ipv6|ipv4|nat)(,(ipv6|ipv4|nat))*$ ]] \
    || die "плохая FAMILY: $FAMILY (допустимо ipv6, ipv4, nat)"
# без файла имён отправитель молча ничего не публикует
if [ "$NAMES_SET" = "0" ] && [ ! -f "$CFG/names" ]; then
    die "не заданы имена: передайте --names (пустая строка — удалить имена)"
fi

echo "  отправитель на $(hostname -s)"
sudo -v || die "нужны права sudo"

sudo -n install -d -m 755 -o "$RUN_USER" -g "$(id -gn)" "/var/lib/$NAME"
# на NS-хосте каталог уже создан установщиком приёмника (root). Файл last
# должен быть записываем пользователю сервиса, даже если каталог root-овый.
sudo -n touch "/var/lib/$NAME/last"
# установка — повод опубликовать заново: состояние на NS могло быть очищено
# prune'ом или восстановлением, а локальный last об этом не знает
sudo -n truncate -s 0 "/var/lib/$NAME/last"
sudo -n chown "$RUN_USER" "/var/lib/$NAME/last"
sudo -n install -d -m 755 "$CFG"

if [ ! -f "$CFG/key" ]; then
  ssh-keygen -t ed25519 -N "" -C "$NAME@$ID" -f "/tmp/$NAME-key" >/dev/null
  sudo -n install -m 400 -o "$RUN_USER" -g "$(id -gn)" "/tmp/$NAME-key" "$CFG/key"
  sudo -n install -m 644 -o "$RUN_USER" -g "$(id -gn)" "/tmp/$NAME-key.pub" "$CFG/key.pub"
  rm -f "/tmp/$NAME-key" "/tmp/$NAME-key.pub"
fi

# публичный ключ нужен NS: publish.sh забирает его и разрешает приёмник
if [ ! -f "$CFG/key.pub" ]; then
  ssh-keygen -y -f "$CFG/key" | sudo -n tee "$CFG/key.pub" >/dev/null
  sudo -n chmod 644 "$CFG/key.pub"
fi

printf '%s\n' "$ID" | sudo -n tee "$CFG/id" >/dev/null
if [ "$NAMES_SET" = "1" ]; then
  if [ -n "$NAMES" ]; then
    printf '%s\n' $NAMES | sudo -n tee "$CFG/names" >/dev/null
  else
    # пустой список — осознанное удаление всех имён хоста
    : | sudo -n tee "$CFG/names" >/dev/null
  fi
fi
printf '%s\n' "$FAMILY" | sudo -n tee "$CFG/family" >/dev/null
sudo -n chmod 644 "$CFG/id"; sudo -n chmod 644 "$CFG/names" 2>/dev/null || true

sed "s|@NS@|$NS|" "$HERE/host2ns.sh" > "/tmp/$NAME-sender.sh"
sudo -n install -m 755 -o root -g root "/tmp/$NAME-sender.sh" "/usr/local/bin/$NAME.sh"
rm -f "/tmp/$NAME-sender.sh"

sudo -n tee "/etc/systemd/system/$NAME.service" >/dev/null <<UNIT
[Unit]
Description=host2ns: публикация адресов хоста в DNS
Wants=network-online.target
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
if [ "$DEFER" = "1" ]; then
  echo "  таймер не включён: сначала разрешите ключ на NS"
  exit 0
fi
sudo -n systemctl enable --now "$NAME.timer" >/dev/null
sudo -n systemctl start "$NAME.service" || { sudo -n journalctl -u "$NAME.service" -n 10 --no-pager >&2; die "служба публикации упала"; }

sleep 1
sudo -n test -s "/var/lib/$NAME/last" || {
  sudo -n journalctl -u "$NAME.service" -n 5 --no-pager >&2 || true
  die "отправитель не опубликовал данные"
}
echo "  готово: $ID ($NAMES)"
