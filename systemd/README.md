# systemd

| Юнит | Где | Зачем |
| --- | --- | --- |
| `<NAME>.service` | хост | однократная публикация (oneshot) |
| `<NAME>.timer` | хост | запуск при загрузке и каждые 10 минут |
| `<NAME>-zones.service` | NS | генерация зон **до** старта NSD |

Почему генерация отдельным юнитом: юнит должен отработать **до** NSD, а
`ExecStartPre` внутри `nsd.service` связан с его песочницей и порядком
запуска. Отдельный юнит с `Before=nsd.service` проще проверить и перезапустить.

`BASE` в юнит не передаётся: генератор читает её из `/etc/<NAME>/base`, который
пишет установщик. Так приёмник, запускаемый из `authorized_keys`, видит ту же
базу, что и юнит.

Связка на NS задаётся drop-in-ом `/etc/systemd/system/nsd.service.d/10-<NAME>-zones.conf`:

    [Unit]
    Wants=<NAME>-zones.service
    After=<NAME>-zones.service

Юнит отправителя получает только имя проекта и тянет сеть:

    Wants=network-online.target
    After=network-online.target
    Environment=NAME=<NAME>

Политику семейства отправитель читает из `/etc/<NAME>/family`: файл — один
источник и для ручного запуска, и для юнита.

`make restore` перезапускает зоны-юнит и следом делает `nsd-control reconfig`
и `reload`: сам юнит пишет файлы с `NO_RESTART=1` и NSD не трогает.

Рабочие файлы создаёт установщик; этот каталог — справочный.