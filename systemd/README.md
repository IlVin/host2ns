# systemd

| Юнит | Где | Зачем |
| --- | --- | --- |
| `<NAME>.service` | хост | однократная публикация (oneshot) |
| `<NAME>.timer` | хост | запуск при загрузке и каждые 10 минут |
| `<NAME>-zones.service` | NS | генерация зон **до** старта NSD |

Почему генерация отдельным юнитом: у `nsd.service` включён
`ProtectSystem=strict`, и запись в `/var/lib/nsd` из `ExecStartPre` запрещена
даже root-у. Отдельный юнит с `Before=nsd.service` работает вне песочницы.

Связка на NS задаётся drop-in-ом `/etc/systemd/system/nsd.service.d/10-<NAME>-zones.conf`:

    [Unit]
    Wants=<NAME>-zones.service
    After=<NAME>-zones.service

Юнит отправителя получает политику семейства в окружении:

    Environment=NAME=<NAME>
    Environment=FAMILY=ipv6,ipv4

Рабочие файлы создаёт установщик; этот каталог — справочный.