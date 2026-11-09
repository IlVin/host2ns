#!/usr/bin/env bash
# authorize.sh — разрешить публичный ключ отправителя на NS-хосте.
#
#   ./scripts/authorize.sh <user@ns> '<ssh-ed25519 AAAA...>'
#   ./scripts/authorize.sh --print-line '<ssh-ed25519 AAAA...>'
#
# Ключ получает forced command: по нему нельзя открыть шелл, только передать
# данные приёмнику. Строка заменяет прежнюю запись с тем же ключом.
set -euo pipefail

NAME="${NAME:-host2ns}"
RECV="/usr/local/bin/$NAME-recv.sh"
die() { echo "ОШИБКА: $*" >&2; exit 2; }

is_pubkey() {
    local pub="$1" tmp
    case "$pub" in
        'ssh-ed25519 '*|'ssh-rsa '*|'ecdsa-sha2-'*' '*|'sk-ssh-ed25519@openssh.com '*|'sk-ecdsa-sha2-'*' '*) ;;
        *) return 1 ;;
    esac
    case "$pub" in *"'"*|*$'\n'*|*$'\r'*) return 1 ;; esac
    # окончательная проверка — тем же инструментом, что и у sshd
    tmp="$(mktemp)"
    printf '%s\n' "$pub" > "$tmp"
    if ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

print_line() {
    local pub="$1"
    is_pubkey "$pub" || die "не похоже на открытый ключ: $pub"
    printf 'restrict,command="sudo -n %s" %s\n' "$RECV" "$pub"
}

case "${1:-}" in
    --print-line)
        [ $# -eq 2 ] || die "использование: $0 --print-line '<ключ>'"
        print_line "$2"
        exit 0
        ;;
    ''|--help|-h)
        echo "использование: $0 <user@ns> '<ssh-ed25519 ...>'" >&2
        exit 2
        ;;
esac

[ $# -eq 2 ] || die "использование: $0 <user@ns> '<ключ>'"
NS="$1"; PUB="$2"
LINE="$(print_line "$PUB")"
BODY="$(printf '%s\n' "$PUB" | awk '{print $1" "$2}')"
BODY_Q="$(printf '%q' "$BODY")"
LINE_Q="$(printf '%q' "$LINE")"

printf '  ключ %s -> %s\n' "${BODY#* }" "$NS" >&2
ssh "$NS" "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; tmp=\$(mktemp); grep -vF -- $BODY_Q ~/.ssh/authorized_keys > \"\$tmp\" || true; printf '%s\n' $LINE_Q >> \"\$tmp\"; mv \"\$tmp\" ~/.ssh/authorized_keys"
