# VERSION 2 — WITH PANEL (SAFE SINGLE FILE)

В этой папке используется один исполняемый файл:

`setup-node-panel-safe.py`

Это безопасная тестовая версия с подключением к Remnawave Panel API без внешних Python-зависимостей: используется только стандартная библиотека Python.

Основные команды:

```bash
chmod +x setup-node-panel-safe.py
./setup-node-panel-safe.py self-test
./setup-node-panel-safe.py plan --domain node.example.com
./setup-node-panel-safe.py execute --domain node.example.com --confirm CREATE-ONLY
./setup-node-panel-safe.py doctor --reality-tag REALITY-TCP-TEST --hysteria-tag HYSTERIA-BBR-TEST
```

Перед `plan`/`execute`:

```bash
export REMNAWAVE_BASE_URL='https://panel.example.com'
export REMNAWAVE_TOKEN='API_TOKEN'
```

Безопасность v2:

- `plan` только читает панель и ничего не изменяет;
- `execute` разрешён только после предварительного `plan`;
- перед созданием объектов сохраняется локальный snapshot состояния панели;
- существующие Profile / Host / Internal Squad не обновляются;
- при совпадении имён скрипт останавливается;
- DELETE и PATCH в скрипте запрещены;
- рабочая Node автоматически не переключается;
- автоматического удаления при ошибке нет;
- по умолчанию разрешены только TEST-имена;
- конфигурация: Hysteria UDP/443 + VLESS TCP Reality TCP/443, `ads.x5.ru`, без SelfSteal.

Версия 1 в соседней папке остаётся полностью отдельной и не подключается к панели.
