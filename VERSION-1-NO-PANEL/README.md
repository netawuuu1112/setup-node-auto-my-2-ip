# VERSION 1 — без панели

Эта версия не использует API панели. Она запускается на сервере ноды и генерирует полный JSON-профиль для двух inbound на порту 443: Hysteria по UDP и VLESS Reality по TCP.

Запуск:

```bash
chmod +x setup-node.sh
sudo ./setup-node.sh generate --domain node.example.com
```

Профиль сохраняется в `/root/remnawave-profile.json` и вставляется в панель вручную.

После применения профиля:

```bash
sudo ./setup-node.sh doctor
```

Для Reality используются `network=tcp`, внешний target/SNI `ads.x5.ru`, `sockopt.mark=255`, `tcpNoDelay=true`, `tcpFastOpen=true`. SelfSteal не используется. `flow` вручную не задаётся; в effective config ожидается автоматический `xtls-rprx-vision` от Remnawave.
