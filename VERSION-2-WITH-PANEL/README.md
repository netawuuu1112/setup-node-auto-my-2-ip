# VERSION 2 — WITH PANEL / INTERACTIVE SAFE

В папке один рабочий исполняемый скрипт:

`setup-node-panel.sh`

Запуск:

```bash
chmod +x setup-node-panel.sh
./setup-node-panel.sh
```

Без аргументов открывается меню. Для обычного запуска достаточно в первый раз указать только:

- URL панели Remnawave;
- API token;
- домен ноды.

Остальное зашито по проверенной схеме:

- Hysteria — UDP/443;
- VLESS TCP Reality — TCP/443;
- Reality target/SNI — `ads.x5.ru`;
- fingerprint — `chrome`;
- `network: tcp`;
- `sockopt.mark: 255`;
- `tcpNoDelay: true`;
- `tcpFastOpen: true`;
- Remnawave автоматически добавляет `xtls-rprx-vision`;
- SelfSteal не используется.

Меню:

1. Быстрая безопасная настройка.
2. Проверка + PLAN без изменений панели.
3. Диагностика RemnaNode / effective config.
4. Расширенные настройки.
5. Просмотр state созданных объектов.
6. Self-test.

Безопасность:

- скрипт работает в режиме CREATE-ONLY;
- существующие Profile, Host, Internal Squad и inbound не обновляются;
- при совпадении имени/tag выполнение останавливается;
- перед записью сохраняется snapshot панели;
- DELETE/PATCH существующих объектов не выполняются;
- API token не сохраняется на диск;
- рабочая Node автоматически не переключается;
- при ошибке уже созданные объекты автоматически не удаляются.

CLI также поддерживает:

```bash
./setup-node-panel.sh --plan
./setup-node-panel.sh --quick
./setup-node-panel.sh --doctor
./setup-node-panel.sh --self-test
```

Версия 1 в соседней папке остаётся независимой и не подключается к панели.