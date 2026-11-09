#!/usr/bin/env bash
# check.sh — локальная проверка генерации зон. Не требует хостов и root.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "ОШИБКА: $*" >&2; exit 1; }

# синтаксис всех скриптов — до любых запусков
for f in "$HERE"/*.sh; do
    bash -n "$f" || fail "bash -n: $f"
done
echo "  синтаксис: ok"

# recv_run <каталог> [VAR=value...] — приёмник в изолированном окружении.
# BASE задаётся файлом <каталог>/base, как на NS.
recv_run() {
    local root="$1"; shift
    mkdir -p "$root"
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        NAME=check BASE_FILE="$root/base" STATE="$root/state" ZONEDIR="$root/zones" \
        ZONES_CONF="$root/zones.conf" ZONELIST="$root/zone.list" \
        ZONELIST_CONF="$root/zonelist.conf" NO_RESTART=1 "$@" \
        bash "$HERE/receiver.sh"
}

export NAME=check BASE=example.ru
export STATE="$T/state" ZONEDIR="$T/zones"
export ZONES_CONF="$T/10-check-zones.conf" ZONELIST="$T/zone.list"
export ZONELIST_CONF="$T/zonelistfile.conf"

mkdir -p "$STATE/plb.example.ru" "$STATE/h.example.ru"
printf 'tg.d 2a02:2168::1111\n' > "$STATE/plb.example.ru/host-a"
printf 'ssh 2a02:2168::1111\nbackup 2a02:2168::1111\n' > "$STATE/h.example.ru/host-b"

# shellcheck disable=SC1091
. "$HERE/zonegen.sh"
: > "$ZONELIST"   # NSD мог создать его раньше; генерация обязана обнулить
NO_RESTART=1 zones_apply

zf="$ZONEDIR/plb.example.ru.zone"
[ -f "$zf" ] || fail "зона не создана: $zf"
serial="$(awk '/IN SOA/ { print $7 }' "$zf")"
[[ "$serial" =~ ^[0-9]+$ ]] || fail "SOA serial не число: $serial"
now="$(date +%s)"
[ "$serial" -le "$now" ] && [ $((now - serial)) -lt 120 ] \
    || fail "SOA serial не epoch: $serial (сейчас $now)"
grep -q 'tg.d IN AAAA 2a02:2168::1111' "$zf" || fail "нет записи tg.d"
[ -f "$ZONEDIR/h.example.ru.zone" ] || fail "нет зоны h"
grep -q 'name: "plb.example.ru"' "$ZONES_CONF" || fail "нет блока зоны в конфиге"
[ ! -s "$ZONELIST" ] || fail "рантайм-список должен быть пуст"
grep -q 'zonelistfile' "$ZONELIST_CONF" || fail "нет zonelistfile в конфиге"
[ "$(stat -c %a "$zf")" = 644 ] || fail "файл зоны не 644"
if find "$ZONEDIR" -maxdepth 1 -name '.*' -type f | grep -q .; then
    fail "остался временный файл зоны"
fi
if find "$T" -maxdepth 1 -name '.check-zones.*' -type f | grep -q .; then
    fail "остался временный файл конфига"
fi

# запись зоны не зависит от umask вызывающего
U="$T/umask"
mkdir -p "$U/state/plb.example.ru"
printf 'tg.d 2a02:2168::1111\n' > "$U/state/plb.example.ru/h1"
(
    umask 077
    export NAME=check BASE=example.ru BASE_FILE="$T/no-base" STATE="$U/state" ZONEDIR="$U/zones" \
        ZONES_CONF="$U/zones.conf" ZONELIST="$U/zl" ZONELIST_CONF="$U/zlc" NO_RESTART=1
    # shellcheck disable=SC1091
    . "$HERE/zonegen.sh"
    zones_apply
)
[ "$(stat -c %a "$U/zones/plb.example.ru.zone")" = 644 ] || fail "зона не 644 при umask 077"

# BASE из файла: окружение установщика до приёмника не доходит.
R="$T/recv-base"
mkdir -p "$R"
printf 'other.example\n' > "$R/base"
recv_run "$R" <<'EOF' || fail "приёмник не отработал с BASE из файла"
host h1
policy ipv6
tg.d.plb 2a02:2168::1111
EOF
[ -d "$R/state/plb.other.example" ] || fail "BASE из файла не применён"
grep -q 'name: "plb.other.example"' "$R/zones.conf" || fail "зона не попала в конфиг"

# nat без собственных адресов: имя должно дожить до подклейки адреса.
R="$T/recv-nat"
mkdir -p "$R"
printf 'example.ru\n' > "$R/base"
recv_run "$R" SSH_CONNECTION='203.0.113.7 1234 198.51.100.1 22' <<'EOF' \
    || fail "nat-хост не опубликовался"
host h-nat
policy nat
tg.d.plb
EOF
[ -f "$R/state/plb.example.ru/h-nat" ] || fail "nat: имя потеряно"
grep -qx 'tg.d 203.0.113.7' "$R/state/plb.example.ru/h-nat" || fail "nat: нет A"

# nat вместе со своим IPv6: обе записи на имя.
R="$T/recv-nat6"
mkdir -p "$R"
printf 'example.ru\n' > "$R/base"
recv_run "$R" SSH_CONNECTION='203.0.113.8 1234 198.51.100.1 22' <<'EOF' \
    || fail "nat+ipv6 не опубликовался"
host h-nat6
policy nat,ipv6
tg.d.plb 2a02:2168::1111
EOF
grep -qx 'tg.d 203.0.113.8' "$R/state/plb.example.ru/h-nat6" || fail "nat+ipv6: нет A"
grep -qx 'tg.d 2a02:2168::1111' "$R/state/plb.example.ru/h-nat6" || fail "nat+ipv6: нет AAAA"

# пустой набор удаляет имена хоста и саму опустевшую зону.
recv_run "$R" <<'EOF' || fail "пустой набор не отработал"
host h-nat6
policy ipv6
EOF
[ ! -e "$R/state/plb.example.ru/h-nat6" ] || fail "пустой набор не удалил имена"
[ ! -d "$R/state/plb.example.ru" ] || fail "пустая зона осталась в состоянии"
[ ! -e "$R/zones/plb.example.ru.zone" ] || fail "файл пустой зоны остался"
grep -q 'name: "plb.example.ru"' "$R/zones.conf" && fail "пустая зона осталась в конфиге"

# переезд имени между зонами: в прежней зоне записей быть не должно.
R="$T/recv-move"
mkdir -p "$R"
printf 'example.ru\n' > "$R/base"
recv_run "$R" <<'EOF' || fail "переезд: первый шаг"
host h-move
policy ipv6
tg.d.plb 2a02:2168::1111
EOF
recv_run "$R" <<'EOF' || fail "переезд: второй шаг"
host h-move
policy ipv6
tg.d.h 2a02:2168::1111
EOF
[ -f "$R/state/h.example.ru/h-move" ] || fail "переезд: нет записи в новой зоне"
[ ! -e "$R/state/plb.example.ru/h-move" ] || fail "переезд: запись осталась в старой зоне"
[ ! -d "$R/state/plb.example.ru" ] || fail "переезд: старая зона осталась"
[ ! -e "$R/zones/plb.example.ru.zone" ] || fail "переезд: файл старой зоны остался"
grep -q 'name: "plb.example.ru"' "$R/zones.conf" && fail "переезд: старая зона в конфиге"

# установщики отвергают опасные аргументы до root-действий
if bash "$HERE/install-ns.sh" --src /tmp/x >/dev/null 2>&1; then fail "install-ns принял --src"; fi
if NAME='../x' bash "$HERE/install-ns.sh" >/dev/null 2>&1; then fail "install-ns принял NAME с .."; fi
if bash "$HERE/install-ns.sh" --base 'bad base' >/dev/null 2>&1; then fail "install-ns принял плохую BASE"; fi
if bash "$HERE/install-sender.sh" --ns '-oProxyCommand=x' >/dev/null 2>&1; then fail "install-sender принял NS-опцию"; fi
if bash "$HERE/install-sender.sh" --ns user@ns --family auto >/dev/null 2>&1; then fail "install-sender принял FAMILY=auto"; fi
P="$T/pub-bad"; mkdir -p "$P/home" "$P/bin"
printf 'NS=user@ns\nBASE=example.ru\n' > "$P/home/config"
printf 'web1 "bad;name"\n' > "$P/home/hosts"
printf '#!/bin/sh\nexit 0\n' > "$P/bin/ssh"; chmod +x "$P/bin/ssh"
if HOST2NS_HOME="$P/home" PATH="$P/bin:$PATH" NAME=check bash "$HERE/publish.sh" >/dev/null 2>&1; then
    fail "publish принял плохое имя из реестра"
fi

# bootstrap-host: неполный комплект отвергается до root-действий
B="$T/boot"; mkdir -p "$B/ok" "$B/bad"
for f in host2ns.sh install-sender.sh install-ns.sh receiver.sh rebuild.sh zonegen.sh host2ns-install.sh bootstrap-host.sh; do
    cp "$HERE/$f" "$B/ok/$f"
done
out="$(SUDO_USER=alice bash "$B/ok/bootstrap-host.sh" 2>&1 || true)"
case "$out" in *"нужен root"*) ;; *) fail "bootstrap-host: не дошёл до проверки root: $out" ;; esac
cp "$HERE/bootstrap-host.sh" "$B/bad/bootstrap-host.sh"
out="$(SUDO_USER=alice bash "$B/bad/bootstrap-host.sh" 2>&1 || true)"
case "$out" in *"неполный комплект"*) ;; *) fail "bootstrap-host: принял неполный комплект: $out" ;; esac

# dispatcher: NAME и LIB берутся из имени файла.
ln -s "$HERE/host2ns-install.sh" "$T/foo-install.sh"
out="$(bash "$T/foo-install.sh" sender 2>&1 || true)"
case "$out" in *"/usr/local/lib/foo/install-sender.sh"*) ;; *) fail "dispatcher: LIB не из argv[0]: $out" ;; esac
out="$(bash "$HERE/host2ns-install.sh" 2>&1 || true)"
case "$out" in *"sender|ns"*) ;; *) fail "dispatcher: нет подсказки по использованию" ;; esac

# install-sender: пользователь сервиса не теряется под sudo.
[ "$(RUN_USER=alice bash "$HERE/install-sender.sh" --print-user)" = "alice" ] \
    || fail "install-sender: RUN_USER из окружения потерян"
[ "$(bash "$HERE/install-sender.sh" --print-user)" = "$(id -un)" ] \
    || fail "install-sender: RUN_USER по умолчанию"

# ошибка применения зон не должна выглядеть успехом
R="$T/recv-fail"
mkdir -p "$R" "$T/fakebin"
printf 'example.ru\n' > "$R/base"
printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/systemctl"
printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/nsd-control"
chmod +x "$T/fakebin/systemctl" "$T/fakebin/nsd-control"
if recv_run "$R" PATH="$T/fakebin:/usr/bin:/bin" NO_RESTART=0 >/dev/null 2>&1 <<'EOF'
host h-fail
policy ipv6
tg.d.plb 2a02:2168::1111
EOF
then
    fail "приёмник вернул успех, когда NSD не перечитал зоны"
fi

# отправитель: выбор стабильного адреса и разбор FAMILY
# shellcheck disable=SC1091
. "$HERE/host2ns.sh"
[ "$(parse_family ipv6,ipv4)" = "1 1 0" ] || fail "parse_family ipv6,ipv4"
[ "$(parse_family nat,ipv6)" = "1 0 1" ] || fail "parse_family nat,ipv6"
if parse_family auto >/dev/null 2>&1; then fail "parse_family принял auto"; fi
v6_fixture='2: eth0    inet6 2001:db8::1/64 scope global temporary dynamic
2: eth0    inet6 2001:db8::2/64 scope global deprecated dynamic
2: eth0    inet6 fd00::1/64 scope global
2: eth0    inet6 2001:db8::3/64 scope global mngtmpaddr noprefixroute'
[ "$(printf '%s\n' "$v6_fixture" | ipv6_candidates | first_public_v6)" = "2001:db8::3" ] \
    || fail "выбор IPv6: temporary/deprecated/ULA не отфильтрованы"
v4_fixture='2: eth0    inet 10.0.0.5/24 scope global dynamic eth0
2: eth0    inet 203.0.113.7/24 scope global eth0
2: eth0    inet 100.64.0.9/10 scope global'
[ "$(printf '%s\n' "$v4_fixture" | ipv4_candidates | first_public_v4)" = "203.0.113.7" ] \
    || fail "выбор IPv4: приватный адрес не отфильтрован"

# отправитель целиком: фейковые ip и ssh, без сети и root
S="$T/sender"
mkdir -p "$S/bin" "$S/etc" "$S/var"
cat > "$S/bin/ip" <<'EOS'
#!/bin/sh
case " $* " in
  *" -6 "*) printf '%s\n' '2: eth0    inet6 2001:db8::1/64 scope global temporary dynamic' \
                          '2: eth0    inet6 fd00::1/64 scope global' \
                          '2: eth0    inet6 2001:db8::3/64 scope global mngtmpaddr noprefixroute' ;;
  *" -4 "*) printf '%s\n' '2: eth0    inet 10.0.0.5/24 scope global dynamic eth0' \
                          '2: eth0    inet 203.0.113.7/24 scope global eth0' ;;
esac
EOS
cat > "$S/bin/ssh" <<'EOS'
#!/bin/sh
cat > "$SSH_CAPTURE"
EOS
chmod +x "$S/bin/ip" "$S/bin/ssh"
printf 'h1\n' > "$S/etc/id"
printf 'tg.d.plb\nhub.d.plb\n' > "$S/etc/names"
printf 'ipv6,ipv4\n' > "$S/etc/family"
: > "$S/etc/key"
sender_run() {
    env PATH="$S/bin:$PATH" SSH_CAPTURE="$S/capture" NAME=check \
        CFG="$S/etc" STATE="$S/var/last" NS=user@ns bash "$HERE/host2ns.sh"
}
sender_run || fail "отправитель не отработал"
grep -q '^tg.d.plb 2001:db8::3 203.0.113.7$' "$S/capture" || fail "отправитель: неверный адрес"
: > "$S/capture"
sender_run || fail "повторный запуск отправителя"
[ -s "$S/capture" ] && fail "отправитель повторно отправил неизменное состояние"
printf 'nat\n' > "$S/etc/family"
rm -f "$S/var/last"; : > "$S/capture"
sender_run || fail "отправитель с FAMILY=nat"
grep -q '^policy nat$' "$S/capture" || fail "отправитель: нет policy nat"
printf 'auto\n' > "$S/etc/family"
if sender_run >/dev/null 2>&1; then fail "отправитель принял FAMILY=auto"; fi
printf 'ipv6,ipv4\n' > "$S/etc/family"

# отправитель без адресов присылает пустой набор, а приёмник удаляет имена
mkdir -p "$S/bin-empty"
cat > "$S/bin-empty/ip" <<'EOS'
#!/bin/sh
case " $* " in
  *" -6 "*) printf '%s\n' '2: eth0    inet6 fd00::1/64 scope global' ;;
  *" -4 "*) printf '%s\n' '2: eth0    inet 10.0.0.5/24 scope global' ;;
esac
EOS
chmod +x "$S/bin-empty/ip"
R="$T/recv-no-addr"
mkdir -p "$R" "$R/state/plb.example.ru"
printf 'example.ru\n' > "$R/base"
printf 'tg.d 2a02:2168::1111\n' > "$R/state/plb.example.ru/h1"
printf 'ipv6,ipv4\n' > "$S/etc/family"
rm -f "$S/var/last"; : > "$S/capture"
env PATH="$S/bin-empty:$S/bin:$PATH" SSH_CAPTURE="$S/capture" NAME=check \
    CFG="$S/etc" STATE="$S/var/last" NS=user@ns bash "$HERE/host2ns.sh" \
    || fail "отправитель без адресов упал"
grep -q '^policy ipv6,ipv4$' "$S/capture" || fail "пустой набор: нет policy"
[ -s "$S/var/last" ] || fail "пустой набор: состояние не сохранено"
recv_run "$R" < "$S/capture" >/dev/null || fail "приёмник не принял пустой набор"
[ ! -e "$R/state/plb.example.ru/h1" ] || fail "пустой набор не удалил имена"

# смена NS должна вызвать переотправку, даже если адреса не менялись
: > "$S/capture"
env PATH="$S/bin-empty:$S/bin:$PATH" SSH_CAPTURE="$S/capture" NAME=check \
    CFG="$S/etc" STATE="$S/var/last" NS=user2@ns bash "$HERE/host2ns.sh" \
    || fail "отправитель не отработал после смены NS"
[ -s "$S/capture" ] || fail "смена NS не вызвала переотправку"
grep -q '^host h1$' "$S/capture" || fail "после смены NS нет данных"

# приёмник отвергает не-IP и служебные диапазоны
R="$T/recv-bad"
mkdir -p "$R"
printf 'example.ru\n' > "$R/base"
for bad in 999.999.999.999 1.2.3.4.5 ::: 10.0.0.1 192.168.1.5 172.20.0.1 \
           100.64.0.1 fe80::1 fc00::1 ff02::1 0.0.0.0 example.com; do
    if recv_run "$R" >/dev/null 2>&1 <<EOF
host h-bad
policy ipv6,ipv4
tg.d.plb $bad
EOF
    then
        fail "приёмник принял адрес $bad"
    fi
done
# nat с приватным адресом из SSH_CONNECTION не публикуется
R="$T/recv-nat-private"
mkdir -p "$R"
printf 'example.ru\n' > "$R/base"
recv_run "$R" SSH_CONNECTION='10.0.0.5 1234 10.0.0.1 22' >/dev/null <<'EOF' \
    || fail "nat с приватным адресом упал"
host h-priv
policy nat
tg.d.plb
EOF
[ ! -e "$R/state/plb.example.ru/h-priv" ] || fail "nat опубликовал приватный адрес"

# publish: NS с пользователем из config, ошибка установщика не маскируется
P="$T/pub-fail"
mkdir -p "$P/home" "$P/bin"
printf 'NS=user@ns\nBASE=example.ru\n' > "$P/home/config"
printf 'web1 tg.d.plb\n' > "$P/home/hosts"
cat > "$P/bin/ssh" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
for a in "$@"; do case "$a" in *sender*) exit 1 ;; esac; done
exit 0
EOS
chmod +x "$P/bin/ssh"
rc=0
out="$(HOST2NS_HOME="$P/home" PATH="$P/bin:$PATH" SSH_LOG="$P/log" NAME=check bash "$HERE/publish.sh" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "publish: ожидался код 1, получен $rc"
case "$out" in *"make bootstrap-host HOST=web1"*) ;; *) fail "publish: нет подсказки про bootstrap-host" ;; esac
case "$out" in *"нет доступа"*) fail "publish: ошибка установщика замаскирована" ;; esac
grep -q 'user@ns' "$P/log" || fail "publish: NS без пользователя из config"

# publish: комментарии в реестре и policy не попадают в аргументы
P="$T/pub-ok"
mkdir -p "$P/home" "$P/bin"
ssh-keygen -t ed25519 -N "" -C check -f "$P/k" >/dev/null 2>&1 || fail "ssh-keygen"
printf 'NS=user@ns\nBASE=example.ru\n' > "$P/home/config"
printf 'web1 tg.d.plb # основной\n' > "$P/home/hosts"
printf 'web1 ipv4 # только v4\n' > "$P/home/policy"
cat > "$P/bin/ssh" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
case "$*" in *key.pub*) cat "$FAKE_PUB" ;; esac
exit 0
EOS
chmod +x "$P/bin/ssh"
HOST2NS_HOME="$P/home" PATH="$P/bin:$PATH" SSH_LOG="$P/log" FAKE_PUB="$P/k.pub" \
    NAME=check bash "$HERE/publish.sh" >/dev/null || fail "publish с комментариями упал"
grep -q "sender.*--names 'tg.d.plb'.*--family 'ipv4'" "$P/log" \
    || fail "publish: комментарий попал в --names/--family"
if grep -q '#' "$P/log"; then fail "publish: комментарий ушёл на хост"; fi

# status: комментарии в реестре, политика, пропуск самого NS
P="$T/status"
mkdir -p "$P/home" "$P/bin"
printf 'NS=user@ns.example\nBASE=example.ru\nFAMILY=ipv6,ipv4\n' > "$P/home/config"
printf 'web1 tg.d.plb # основной\nns.example ns.a\n' > "$P/home/hosts"
printf 'ns.example ipv4 # шлюз\n' > "$P/home/policy"
cat > "$P/bin/ssh" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
case "$*" in
  *"ls -1 "*) printf 'plb.example.ru\n' ;;
  *"find "*) : ;;
  *"stat -c "*) printf '2026-11-09 15:00:00.000000000 +0300\n' ;;
esac
EOS
cat > "$P/bin/dig" <<'EOS'
#!/bin/sh
case "$*" in
  *AAAA*tg.d.plb*) printf '2a02:2168::1111\n' ;;
  *" A "*tg.d.plb*) printf '203.0.113.7\n' ;;
  *" A "*ns.a*) printf '203.0.113.7\n' ;;
esac
EOS
chmod +x "$P/bin/ssh" "$P/bin/dig"
rc=0
out="$(HOST2NS_HOME="$P/home" NAME=check PATH="$P/bin:$PATH" SSH_LOG="$P/log" bash "$HERE/status.sh" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "status: ожидался код 0, получен $rc: $out"
case "$out" in *"tg.d.plb.example.ru"*) ;; *) fail "status: нет имени из реестра" ;; esac
case "$out" in *"comment"*|*"# "* ) fail "status: комментарий попал в имена" ;; esac
grep -q 'web1.*stat -c' "$P/log" || fail "status: не проверил свежесть web1"
if grep -q 'ns.example.*stat -c' "$P/log"; then fail "status: полез на сам NS"; fi

# prune: удаляет только хост, которого нет в реестре
P="$T/prune"
mkdir -p "$P/home" "$P/bin"
printf 'NS=user@ns\n' > "$P/home/config"
printf 'host-a a.example\n' > "$P/home/hosts"
cat > "$P/bin/ssh" <<'EOS'
#!/bin/sh
case "$*" in
  *find*) printf 'host-a\nhost-b\n' ;;
  *) cat >> "$SSH_LOG"; printf '\n---\n' >> "$SSH_LOG" ;;
esac
EOS
chmod +x "$P/bin/ssh"
HOST2NS_HOME="$P/home" NAME=check PATH="$P/bin:$PATH" SSH_LOG="$P/log" \
    bash "$HERE/prune.sh" >/dev/null || fail "prune.sh упал"
grep -q '^host host-b$' "$P/log" || fail "prune: host-b не удалён"
if grep -q '^host host-a$' "$P/log"; then fail "prune: удалил хост из реестра"; fi
if grep -q '^tg' "$P/log"; then fail "prune: отправил имена вместо пустого набора"; fi

# authorize.sh: строка authorized_keys с forced command.
ssh-keygen -t ed25519 -N "" -C "check@test" -f "$T/ak" >/dev/null 2>&1 || fail "ssh-keygen"
line="$(NAME=check bash "$HERE/authorize.sh" --print-line "$(cat "$T/ak.pub")")"
case "$line" in
    'restrict,command="sudo -n /usr/local/bin/check-recv.sh" ssh-ed25519 '*) ;;
    *) fail "authorize: плохая строка: $line" ;;
esac
if NAME=check bash "$HERE/authorize.sh" --print-line "not a key" >/dev/null 2>&1; then
    fail "authorize: принял мусор вместо ключа"
fi

# Конфиг NSD из bootstrap-nsd: проверяем настоящим nsd-checkconf, если он есть.
bash "$HERE/bootstrap-nsd.sh" --print-config > "$T/00-check.conf"
grep -q $'^\tdo-ip4: yes$' "$T/00-check.conf" || fail "в конфиге NSD нет реальной табуляции"
grep -q $'^\tip-address: 0.0.0.0@53$' "$T/00-check.conf" || fail "в конфиге NSD нет ip-address"
if grep -q 'listen:' "$T/00-check.conf"; then fail "в конфиге NSD остался listen:"; fi
if command -v nsd-checkconf >/dev/null; then
    printf 'include: "%s"\n' "$T/00-check.conf" > "$T/nsd.conf"
    nsd-checkconf "$T/nsd.conf" || fail "nsd-checkconf отверг конфиг"
    [ "$(nsd-checkconf -o zonesdir "$T/nsd.conf")" = "/var/lib/nsd/zones" ] \
        || fail "nsd-checkconf не видит zonesdir"
else
    echo "  пропущено: nsd-checkconf не установлен"
fi

echo "проверка пройдена: 2 зоны, записи на месте, конфиг сформирован"
