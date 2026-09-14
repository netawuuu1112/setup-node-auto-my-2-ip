# Remnawave Node Auto Setup

Репозиторий разделён на две независимые версии для тестирования.

## VERSION-1-NO-PANEL

Не подключается к панели. Генерирует готовый профиль вручную для схемы:

- Hysteria2 — UDP/443
- VLESS TCP Reality — TCP/443
- Reality target/SNI — `ads.x5.ru`
- `network: tcp`
- `sockopt.mark: 255`
- Remnawave автоматически добавляет `xtls-rprx-vision`
- SelfSteal не используется

## VERSION-2-WITH-PANEL

Интерактивная shell-версия с подключением к Remnawave Panel API.

Основной файл:

`VERSION-2-WITH-PANEL/setup-node-panel.sh`

Запуск:

```bash
cd VERSION-2-WITH-PANEL
chmod +x setup-node-panel.sh
./setup-node-panel.sh
```

При первом запуске обычно нужно ввести только URL панели, API token и домен ноды. Остальные рабочие параметры зашиты в скрипт.

V2 работает безопасно:

- сначала выполняет проверки и PLAN;
- не обновляет и не удаляет существующие Profile / Host / Internal Squad;
- останавливается при совпадении AUTO-имён или inbound tag;
- перед созданием сохраняет snapshot панели;
- API token не сохраняет;
- рабочую Node автоматически не переключает;
- создаёт только новые объекты панели.

**Версии намеренно не объединены.** Сначала протестировать каждую отдельно.