#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"
CONTAINER="${CONTAINER:-remnanode}"
PORT="${PORT:-443}"
REALITY_TARGET="${REALITY_TARGET:-ads.x5.ru}"
REALITY_TAG="${REALITY_TAG:-REALITY-TCP}"
HYSTERIA_TAG="${HYSTERIA_TAG:-HYSTERIA-BBR}"
HYSTERIA_CERT="${HYSTERIA_CERT:-/opt/hysteria/certs/fullchain.pem}"
HYSTERIA_KEY="${HYSTERIA_KEY:-/opt/hysteria/certs/privkey.pem}"
OUTPUT="${OUTPUT:-/root/remnawave-profile.json}"
STATE="${STATE:-/root/.remnawave-node-quicksetup.env}"

ok(){ echo "[OK] $*"; }
warn(){ echo "[WARN] $*" >&2; }
die(){ echo "[ERR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }

usage(){ cat <<'EOF'
VERSION 1 — WITHOUT PANEL API

Команды:
  generate      сгенерировать полный профиль
  doctor        проверить активную RemnaNode
  show-config   показать сохранённый профиль
  show-host     показать параметры Reality Host

Пример:
  ./setup-node.sh generate --domain node.example.com \
    --reality-tag PL-002-REALITY \
    --hysteria-tag HYSTERIA-BBR-PL
EOF
}

load_state(){ [[ -f "$STATE" ]] || die "Нет state. Сначала generate"; source "$STATE"; }

docker_ok(){ docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER"; }

resolve4(){ getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; }
local4(){ ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | sort -u; }

check_dns(){
  local d l
  d="$(resolve4 "$DOMAIN" || true)"; l="$(local4 || true)"
  echo "DNS A: ${d:-нет}"
  echo "Server IPv4: ${l:-нет}"
  [[ -n "$d" ]] || warn "Домен не резолвится в IPv4"
}

check_target(){
  timeout 5 bash -c "</dev/tcp/${REALITY_TARGET}/443" 2>/dev/null && ok "Reality target ${REALITY_TARGET}:443 доступен" || warn "Reality target недоступен"
}

gen_keys(){
  local raw
  raw="$(docker exec "$CONTAINER" rw-core x25519 2>&1)" || die "Не удалось выполнить rw-core x25519"
  PRIVATE_KEY="$(printf '%s\n' "$raw" | awk -F': ' '/PrivateKey|Private key/{print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "$raw" | awk -F': ' '/Password|PublicKey|Public key/{print $2; exit}')"
  [[ -n "$PRIVATE_KEY" ]] || die "Не удалось получить PrivateKey"
  SHORT_ID="$(openssl rand -hex 8)"
}

save_state(){
  cat >"$STATE" <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
PORT=$(printf '%q' "$PORT")
CONTAINER=$(printf '%q' "$CONTAINER")
REALITY_TARGET=$(printf '%q' "$REALITY_TARGET")
REALITY_TAG=$(printf '%q' "$REALITY_TAG")
HYSTERIA_TAG=$(printf '%q' "$HYSTERIA_TAG")
HYSTERIA_CERT=$(printf '%q' "$HYSTERIA_CERT")
HYSTERIA_KEY=$(printf '%q' "$HYSTERIA_KEY")
PRIVATE_KEY=$(printf '%q' "$PRIVATE_KEY")
PUBLIC_KEY=$(printf '%q' "$PUBLIC_KEY")
SHORT_ID=$(printf '%q' "$SHORT_ID")
OUTPUT=$(printf '%q' "$OUTPUT")
EOF
  chmod 600 "$STATE"
}

generate_json(){
cat >"$OUTPUT" <<EOF
{
  "log": {"loglevel": "warning"},
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "$HYSTERIA_TAG",
      "port": $PORT,
      "listen": "0.0.0.0",
      "protocol": "hysteria",
      "settings": {"users": [], "clients": [], "version": 2},
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [{"keyFile": "$HYSTERIA_KEY", "certificateFile": "$HYSTERIA_CERT"}]
        },
        "hysteriaSettings": {"version": 2}
      }
    },
    {
      "tag": "$REALITY_TAG",
      "port": $PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "sniffing": {"enabled": true, "routeOnly": true, "destOverride": ["http", "tls", "quic"]},
      "streamSettings": {
        "network": "tcp",
        "sockopt": {"mark": 255, "tcpNoDelay": true, "tcpFastOpen": true},
        "security": "reality",
        "tcpSettings": {"header": {"type": "none"}, "acceptProxyProtocol": false},
        "realitySettings": {
          "dest": "$REALITY_TARGET:443",
          "show": false,
          "xver": 0,
          "spiderX": "",
          "shortIds": ["$SHORT_ID"],
          "privateKey": "$PRIVATE_KEY",
          "serverNames": ["$REALITY_TARGET"]
        }
      }
    }
  ],
  "outbounds": [
    {"tag": "DIRECT", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {"tag": "BLOCK", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [{"type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK"}],
    "domainStrategy": "IPIfNonMatch"
  }
}
EOF
python3 -m json.tool "$OUTPUT" >/dev/null || die "Некорректный JSON"
chmod 600 "$OUTPUT"
ok "Профиль сохранён: $OUTPUT"
}

show_host(){
  cat <<EOF
Reality Host:
  Address: $DOMAIN
  Port: $PORT
  SNI: $REALITY_TARGET
  Fingerprint: chrome
  Security Layer: Как в инбаунде
  PublicKey: $PUBLIC_KEY
  ShortID: $SHORT_ID
  Expected flow: xtls-rprx-vision (Remnawave auto)
EOF
}

cmd_generate(){
  need docker; need python3; need openssl; need ip; need getent; need timeout
  DOMAIN=""; ASSUME=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="$2"; shift 2;;
      --reality-target) REALITY_TARGET="$2"; shift 2;;
      --reality-tag) REALITY_TAG="$2"; shift 2;;
      --hysteria-tag) HYSTERIA_TAG="$2"; shift 2;;
      --hysteria-cert) HYSTERIA_CERT="$2"; shift 2;;
      --hysteria-key) HYSTERIA_KEY="$2"; shift 2;;
      --output) OUTPUT="$2"; shift 2;;
      --yes) ASSUME=1; shift;;
      *) die "Неизвестный параметр: $1";;
    esac
  done
  if [[ -z "$DOMAIN" && "$ASSUME" == 0 ]]; then read -r -p "Домен ноды: " DOMAIN; fi
  [[ -n "$DOMAIN" ]] || die "Нужен --domain"
  docker_ok || die "Контейнер $CONTAINER не запущен"
  check_dns; check_target
  docker exec "$CONTAINER" test -f "$HYSTERIA_CERT" && ok "Hysteria cert найден" || warn "Не найден $HYSTERIA_CERT"
  docker exec "$CONTAINER" test -f "$HYSTERIA_KEY" && ok "Hysteria key найден" || warn "Не найден $HYSTERIA_KEY"
  gen_keys; generate_json; save_state; show_host
}

cmd_doctor(){
  load_state; docker_ok || die "Контейнер $CONTAINER не запущен"
  docker exec "$CONTAINER" rw-core version | head -n1 || true
  ss -lntup | grep ':443' || true
  docker exec "$CONTAINER" cli --dump-config-raw >/tmp/rw-effective.json
  python3 - "$REALITY_TAG" "$HYSTERIA_TAG" <<'PY'
import json,sys
rtag,htag=sys.argv[1:]
d=json.load(open('/tmp/rw-effective.json'))
ib={x.get('tag'):x for x in d.get('inbounds',[])}
for tag in (htag,rtag): print('[OK]' if tag in ib else '[ERR]', tag)
r=ib.get(rtag,{})
ss=r.get('streamSettings',{})
rs=ss.get('realitySettings',{})
print('network=',ss.get('network'))
print('security=',ss.get('security'))
print('flow=',r.get('settings',{}).get('flow'))
print('dest=',rs.get('dest'))
PY
}

case "${1:-help}" in
  generate) shift; cmd_generate "$@";;
  doctor) cmd_doctor;;
  show-config) load_state; cat "$OUTPUT";;
  show-host) load_state; show_host;;
  help|-h|--help) usage;;
  *) usage; exit 1;;
esac
