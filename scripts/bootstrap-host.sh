#!/usr/bin/env bash
# bootstrap-host.sh — одноразовая подготовка хоста под host2ns.
# Запускается с sudo. Кладёт скрипты в /usr/local/lib/host2ns, создаёт
# host2ns-install.sh и правило NOPASSWD только для него.
set -euo pipefail

NAME="${NAME:-host2ns}"
SENDER="${SUDO_USER:-${1:-}}"
[ -n "$SENDER" ] || { echo "не удалось определить пользователя" >&2; exit 2; }

SRC="$(cd "$(dirname "$0")" && pwd)"
LIB="/usr/local/lib/$NAME"
FILES="host2ns.sh install-sender.sh install-ns.sh receiver.sh rebuild.sh zonegen.sh"

# комплект проверяем до root-действий: неполный тарбол не должен ставить
# половину установщика и рапортовать успех
for f in $FILES; do
    [ -f "$SRC/$f" ] || { echo "нет $SRC/$f — неполный комплект установщика" >&2; exit 1; }
done
[ -f "$SRC/host2ns-install.sh" ] || { echo "нет $SRC/host2ns-install.sh" >&2; exit 1; }

[ "$(id -u)" = "0" ] || { echo "нужен root" >&2; exit 2; }

install -d -m 755 "$LIB"
for f in $FILES; do
    install -m 755 -o root -g root "$SRC/$f" "$LIB/$f"
done

install -m 755 -o root -g root "$SRC/host2ns-install.sh" "/usr/local/bin/$NAME-install.sh"

cat > "/etc/sudoers.d/90-$NAME-install" <<SUDO
# host2ns: установка без пароля, только эта команда
$SENDER ALL=(root) NOPASSWD: /usr/local/bin/$NAME-install.sh
SUDO
chmod 440 "/etc/sudoers.d/90-$NAME-install"
visudo -cf "/etc/sudoers.d/90-$NAME-install" >/dev/null || {
    rm -f "/etc/sudoers.d/90-$NAME-install"; echo "sudoers не прошёл проверку" >&2; exit 1;
}
echo "хост подготовлен: $LIB, /usr/local/bin/$NAME-install.sh"
