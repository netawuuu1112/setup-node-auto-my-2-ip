# Remnawave Node Auto Setup

Репозиторий специально разделён на **две независимые версии** для тестирования.

## VERSION-1-NO-PANEL

`VERSION-1-NO-PANEL/` — не подключается к API панели. Генерирует готовый JSON-профиль для рабочей схемы:

- Hysteria2 — UDP/443
- VLESS TCP Reality — TCP/443
- Reality target/SNI — `ads.x5.ru`
- `network: tcp`
- `sockopt.mark: 255`
- Remnawave автоматически добавляет `xtls-rprx-vision`
- SelfSteal не используется

Профиль после генерации вручную вставляется в Remnawave.

## VERSION-2-WITH-PANEL

`VERSION-2-WITH-PANEL/` — отдельная экспериментальная версия с подключением к Remnawave Panel через официальный Python SDK и API token.

Она умеет:

- сгенерировать Reality keys и Short ID;
- собрать полный профиль Hysteria2 + VLESS TCP Reality;
- подключиться к панели по URL + Bearer API token;
- создать новый Config Profile либо обновить существующий по имени;
- найти UUID созданных inbound;
- создать/обновить Internal Squad и включить в него оба inbound;
- создать/обновить Hosts для Reality и Hysteria;
- при указании UUID ноды добавить её в `nodes` Host;
- сохранить локальную копию JSON и state-файл;
- выполнить локальный `doctor` RemnaNode.

**Версии намеренно не объединены.** Сначала протестировать каждую отдельно.

> Не публикуйте API token панели, Reality PrivateKey или state-файлы. `.gitignore` уже исключает типичные секреты.
