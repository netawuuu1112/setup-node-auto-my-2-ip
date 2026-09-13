# VERSION 2

Отдельная тестовая версия с подключением к Remnawave Panel через официальный Python SDK.

Файлы:
- `setup-node-panel.py` — генерация профиля и автоматизация панели.
- `install.sh` — создание venv и установка зависимостей.
- `requirements.txt` — зависимость SDK.

Команды программы: `generate`, `apply`, `doctor`.

`generate` только создаёт локальный профиль. `apply` создаёт или обновляет объекты панели. `doctor` проверяет effective config RemnaNode.

При существующем профиле обновление разрешается только с флагом `--update-existing`.

Схема v2 намеренно совпадает с проверенной схемой v1: Hysteria UDP/443 + VLESS TCP Reality TCP/443, target `ads.x5.ru`, без SelfSteal.
