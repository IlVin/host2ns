# 4. Установка

## 4.1. Две фазы

| Фаза | Команда | Пароль | Что делает |
| --- | --- | --- | --- |
| подготовка | `make bootstrap-host HOST=x` | да | код в `/usr/local/lib/<NAME>`, правило sudo |
| применение | `make host2ns` | нет | ключ, имена, политика, юниты, публикация |

Разделение введено потому, что обновление привилегированного кода и изменение
данных — разные операции с разной ценой ошибки. Пароль остался только на первой.

`bootstrap-host` нужен **каждому** хосту, включая NS: он кладёт диспетчер и
приёмник. `bootstrap-nsd` — отдельный шаг, только установка и настройка NSD.

## 4.2. Что делает `bootstrap-host`

1. Копирует `scripts/` на хост (в `/tmp`, без sudo).
2. Через `sudo` кладёт файлы в `/usr/local/lib/<NAME>` (root:root 755).
3. Создаёт `/usr/local/bin/<NAME>-install.sh` — диспетчер `sender|ns`.
4. Пишет `/etc/sudoers.d/90-<NAME>-install`:

       <user> ALL=(root) NOPASSWD: /usr/local/bin/<NAME>-install.sh

5. Проверяет правило через `visudo -cf` до вступления в силу.

## 4.3. Что делает `host2ns`

Для NS-хоста: `sudo -n <NAME>-install.sh ns` — приёмник, генератор зон, юнит
`<NAME>-zones.service`, связка с `nsd`, sudoers приёмника и файл
`/etc/<NAME>/base` с базой имён.

Для каждого хоста реестра: `sudo -n <NAME>-install.sh sender --ns … --names … --family …` —
ключ, `id`, `names`, `family`, отправитель, таймер, немедленная публикация.

Ошибка службы публикации останавливает установку: вывод журнала печатается,
код выхода ненулевой.

## 4.4. Идемпотентность

Повторный запуск не пересоздаёт ключ, не теряет состояние и не плодит юниты.
`bootstrap-host` перезаписывает код и правило sudo; `host2ns` — данные.

## 4.5. Имя и пути

Всё параметризовано одной переменной `NAME` (по умолчанию `host2ns`):

    /etc/<NAME>/..., /var/lib/<NAME>/..., /usr/local/lib/<NAME>/
    /etc/<NAME>/base — база имён, общая для юнита и приёмника
    <NAME>.service, <NAME>.timer, <NAME>-zones.service

## 4.6. Где упоминается имя

| Место | Что именно |
| --- | --- |
| файлы и каталоги | `/etc/<NAME>`, `/var/lib/<NAME>`, `/usr/local/lib/<NAME>` |
| юниты systemd | `<NAME>.service`, `<NAME>.timer`, `<NAME>-zones.service` |
| drop-in NSD | `/etc/systemd/system/nsd.service.d/10-<NAME>-zones.conf` |
| ключи хостов | `command="sudo -n /usr/local/bin/<NAME>-recv.sh"` в `authorized_keys` |
| sudoers | `90-<NAME>` (приёмник), `90-<NAME>-install` (диспетчер) |
| конфиг зон | `/etc/nsd/nsd.conf.d/10-<NAME>-zones.conf` |
| скрипты на хосте | `/usr/local/bin/<NAME>*` |

Проверка после переименования:

    grep -rl "host2ddns\|yach" /etc/systemd/system /etc/sudoers.d /etc/nsd 2>/dev/null
    grep -o 'command="[^"]*"' ~/.ssh/authorized_keys | sort -u