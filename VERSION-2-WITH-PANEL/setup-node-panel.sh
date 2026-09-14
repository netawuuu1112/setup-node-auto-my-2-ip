#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="2.4.0-end2end-safe"
APP="Kosmo Remnawave Node Setup"
BASE_DIR="${KOSMO_SETUP_DIR:-/opt/remnanode/.kosmo-setup}"
SETTINGS="$BASE_DIR/settings.json"
STATE="$BASE_DIR/state.json"
TXN="$BASE_DIR/last-transaction.json"
BACKUPS="$BASE_DIR/backups"
LOCK="$BASE_DIR/lock"
PROFILE_DIR="/opt/remnanode/kosmo-profiles"
COMPOSE_DIR="/opt/remnanode"
CONTAINER="remnanode"
NODE_PORT=2222
REALITY_TARGET="ads.x5.ru"
TCP_PORT=443
H2_PORT=443
XHTTP_PORT_COMBO=8443
HYSTERIA_CERT="/opt/hysteria/certs/fullchain.pem"
HYSTERIA_KEY="/opt/hysteria/certs/privkey.pem"
REMNANODE_IMAGE="${REMNANODE_IMAGE:-remnawave/node:latest}"
COMPOSE_SERVICE="remnanode"
BASE_COMPOSE_FILE=""
KOSMO_OVERRIDE_FILE=""
COMPOSE_ARGS=()
CREATED_HOST_UUIDS="[]"
NODE_SWITCHED=0

PANEL_URL="${REMNAWAVE_BASE_URL:-}"
PANEL_COOKIE=""
PANEL_TOKEN="${REMNAWAVE_TOKEN:-}"
AUTH_MODE="login"
DOMAIN="${NODE_DOMAIN:-}"
INSTALL_MODE="auto"
TRANSPORT_MODE="3"
SQUAD_SELECTION=""

C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_BOLD='\033[1m'
log(){ printf '%b\n' "$*"; }
ok(){ log "${C_GREEN}[OK]${C_RESET} $*"; }
info(){ log "${C_BLUE}[INFO]${C_RESET} $*"; }
warn(){ log "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
err(){ log "${C_RED}[ERR]${C_RESET} $*" >&2; }
die(){ err "$*"; exit 1; }
pause(){ read -r -p $'\nEnter — продолжить...' _ || true; }

cleanup(){ :; }
trap cleanup EXIT

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти от root: sudo bash $0"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || return 1; }

banner(){
  clear 2>/dev/null || true
  log "${C_BOLD}$APP${C_RESET}  v$VERSION"
  echo "Безопасная модель: snapshot -> create-new -> additive squad -> switch-last; DELETE запрещён."
  echo
}

init_dirs(){
  mkdir -p "$BASE_DIR" "$BACKUPS" "$PROFILE_DIR" "$COMPOSE_DIR"
  chmod 700 "$BASE_DIR" "$BACKUPS" "$PROFILE_DIR" 2>/dev/null || true
  exec 9>"$LOCK"
  flock -n 9 || die "Уже запущен другой экземпляр скрипта"
  printf '%s\n' "$$" 1>&9
}

os_preflight(){
  [[ -r /etc/os-release ]] || die "Не удалось определить ОС"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) die "Поддерживаются Ubuntu/Debian. Обнаружено: ${ID:-unknown}";; esac
  ok "ОС: ${PRETTY_NAME:-$ID}"
}

install_base_packages(){
  local missing=()
  for c in curl jq openssl getent ip ss awk sed grep flock; do need_cmd "$c" || missing+=("$c"); done
  if ((${#missing[@]})); then
    info "Устанавливаю только недостающие системные пакеты (без apt upgrade)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl jq openssl ca-certificates gnupg dnsutils iproute2 util-linux coreutils >/dev/null
  fi
  for c in curl jq openssl getent ip ss awk sed grep; do need_cmd "$c" || die "Не найдена команда после установки: $c"; done
}

install_docker_if_needed(){
  if need_cmd docker && docker compose version >/dev/null 2>&1; then ok "Docker/Compose уже установлен"; return 0; fi
  info "Устанавливаю Docker из официального apt-репозитория Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  local arch codename
  arch="$(dpkg --print-architecture)"; codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || true)}"
  [[ -n "$codename" ]] || die "Не удалось определить codename ОС"
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $codename stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Docker Compose не установился"
  ok "Docker установлен"
}

load_settings(){
  [[ -s "$SETTINGS" ]] || return 0
  [[ -n "$PANEL_URL" ]] || PANEL_URL="$(jq -r '.panelUrl // empty' "$SETTINGS")"
  [[ -n "$DOMAIN" ]] || DOMAIN="$(jq -r '.domain // empty' "$SETTINGS")"
  REALITY_TARGET="$(jq -r '.realityTarget // "ads.x5.ru"' "$SETTINGS")"
  AUTH_MODE="$(jq -r '.authMode // "login"' "$SETTINGS")"
  TRANSPORT_MODE="$(jq -r '.transportMode // "3"' "$SETTINGS")"
}

save_settings(){
  jq -n --arg p "$PANEL_URL" --arg d "$DOMAIN" --arg r "$REALITY_TARGET" --arg a "$AUTH_MODE" --arg m "$TRANSPORT_MODE" \
    '{panelUrl:$p,domain:$d,realityTarget:$r,authMode:$a,transportMode:$m}' > "$SETTINGS"
  chmod 600 "$SETTINGS"
}

normalize_panel_url(){
  local raw="$1" q=""
  [[ "$raw" =~ ^https?:// ]] || raw="https://$raw"
  if [[ "$raw" == *\?* ]]; then q="${raw#*\?}"; raw="${raw%%\?*}"; fi
  raw="$(printf '%s' "$raw" | sed -E 's#^(https?://[^/]+).*$#\1#')"
  PANEL_URL="${raw%/}"
  PANEL_COOKIE=""
  if [[ -n "$q" && "$q" == *=* ]]; then
    PANEL_COOKIE="${q%%&*}"
  fi
  if [[ "$PANEL_URL" != https://* && "$PANEL_URL" != http://127.0.0.1* && "$PANEL_URL" != http://localhost* ]]; then
    die "Для удалённой панели разрешён только HTTPS"
  fi
}

panel_host(){ printf '%s' "$PANEL_URL" | sed -E 's#^https?://([^/:]+).*#\1#'; }
panel_api(){ echo "${PANEL_URL%/}/api"; }

curl_common(){
  local args=(--silent --show-error --connect-timeout 8 --max-time 45 --retry 2 --retry-delay 1 -H 'Accept: application/json' -H 'X-Remnawave-Client-Type: browser')
  [[ -n "$PANEL_COOKIE" ]] && args+=(-H "Cookie: $PANEL_COOKIE")
  printf '%s\0' "${args[@]}"
}

_api(){
  local method="$1" endpoint="$2" body="${3:-}" outfile code url
  case "$method" in
    GET|POST) ;;
    PATCH) [[ "$endpoint" == "internal-squads" || "$endpoint" == "hosts" ]] || die "Защита: PATCH разрешён только для additive Internal Squad или созданных этим запуском Hosts" ;;
    DELETE|PUT) die "Защита: $method запрещён этим скриптом";;
    *) die "Неизвестный HTTP method: $method";;
  esac
  url="$(panel_api)/$endpoint"; outfile="$(mktemp)"
  local args=()
  while IFS= read -r -d '' x; do args+=("$x"); done < <(curl_common)
  [[ -n "$PANEL_TOKEN" ]] && args+=(-H "Authorization: Bearer $PANEL_TOKEN")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
  code="$(curl "${args[@]}" -o "$outfile" -w '%{http_code}' -X "$method" "$url" || true)"
  if [[ ! "$code" =~ ^2 ]]; then
    err "API $method /api/$endpoint -> HTTP ${code:-000}"
    sed -E 's/(accessToken|token|password)"?:"?[^",}]*/\1":"***"/g' "$outfile" >&2 || true
    rm -f "$outfile"; return 1
  fi
  cat "$outfile"; rm -f "$outfile"
}
api_get(){ _api GET "$1"; }
api_post(){ _api POST "$1" "$2"; }
api_patch_squad(){ _api PATCH internal-squads "$1"; }
api_patch_owned_host(){
  local uuid="$1" body="$2"
  jq -e --arg u "$uuid" 'index($u)!=null' <<<"$CREATED_HOST_UUIDS" >/dev/null || die "Safety: запрещён PATCH Host $uuid — он не создан текущим запуском"
  _api PATCH hosts "$body"
}

panel_auth(){
  local raw
  if [[ -z "$PANEL_URL" ]]; then
    read -r -p "Ссылка панели: " raw
    normalize_panel_url "$raw"
  else
    raw="$PANEL_URL"
    normalize_panel_url "$raw"
  fi
  local status
  status="$(_api GET auth/status 2>/dev/null || true)"
  if [[ -z "$status" ]]; then
    warn "Панель не ответила. Если используется cookie-защита eGames, вставь полную ссылку входа с ?COOKIE=VALUE."
    read -r -p "Полная ссылка панели [Enter=отмена]: " raw
    [[ -n "$raw" ]] || die "Панель не отвечает: $PANEL_URL"
    normalize_panel_url "$raw"
    status="$(_api GET auth/status 2>/dev/null || true)"
  fi
  [[ -n "$status" ]] || die "Панель не отвечает: $PANEL_URL"
  if [[ -n "$PANEL_TOKEN" ]]; then
    api_get config-profiles >/dev/null || die "REMNAWAVE_TOKEN недействителен"
    AUTH_MODE="token"; ok "Доступ к панели по API token"
    return 0
  fi
  echo "Доступ к панели:"
  echo "  1) Логин + пароль (пароль и JWT на диск не сохраняются)"
  echo "  2) API token"
  local ch; read -r -p "Выбор [${AUTH_MODE/login/1}]: " ch; ch="${ch:-$([[ "$AUTH_MODE" == token ]] && echo 2 || echo 1)}"
  if [[ "$ch" == "2" ]]; then
    AUTH_MODE="token"
    read -r -s -p "API token: " PANEL_TOKEN; echo
    [[ -n "$PANEL_TOKEN" ]] || die "Пустой token"
  else
    AUTH_MODE="login"
    local user pass body resp
    read -r -p "Логин панели: " user
    read -r -s -p "Пароль панели: " pass; echo
    body="$(jq -n --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')"
    resp="$(_api POST auth/login "$body" || true)"; unset pass
    PANEL_TOKEN="$(jq -r '.response.accessToken // .accessToken // empty' <<<"$resp" 2>/dev/null || true)"
    if [[ -z "$PANEL_TOKEN" ]]; then
      warn "Вход логин/пароль не удался (возможен OAuth/Passkey-only режим)."
      read -r -s -p "Введи API token панели: " PANEL_TOKEN; echo
      AUTH_MODE="token"
    fi
  fi
  api_get config-profiles >/dev/null || die "Авторизация панели не прошла"
  ok "Панель авторизована"
}

ask_domain(){
  [[ -n "$DOMAIN" ]] || read -r -p "Домен этой ноды: " DOMAIN
  DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN%.}"
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$DOMAIN" == *.* ]] || die "Некорректный домен: $DOMAIN"
}

public_ipv4s(){
  { ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1; curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true; } | sed '/^$/d' | sort -u
}
resolve4(){ getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; }

check_domain_strict(){
  local dns ips x found=0
  dns="$(resolve4 "$DOMAIN")"; ips="$(public_ipv4s)"
  [[ -n "$dns" ]] || die "Домен $DOMAIN не имеет IPv4 A-записи"
  info "DNS $DOMAIN -> $(tr '\n' ' ' <<<"$dns")"
  info "IPv4 сервера -> $(tr '\n' ' ' <<<"$ips")"
  while read -r x; do grep -Fxq "$x" <<<"$ips" && found=1; done <<<"$dns"
  ((found)) || die "A-запись $DOMAIN не указывает на этот сервер. Исправь DNS и повтори."
  ok "DNS домена соответствует серверу"
}

check_reality_target(){
  (has_tcp || has_xhttp) || return 0
  local out
  out="$(timeout 8 openssl s_client -connect "$REALITY_TARGET:443" -servername "$REALITY_TARGET" </dev/null 2>/dev/null | head -n 2 || true)"
  [[ -n "$out" ]] || die "Reality target $REALITY_TARGET:443 не проходит TLS-проверку"
  ok "Reality target $REALITY_TARGET:443 доступен по TLS"
}

container_exists(){ docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER"; }
container_running(){ docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER"; }
existing_compose_dir(){
  if container_exists; then docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$CONTAINER" 2>/dev/null || true; fi
}
existing_compose_service(){
  if container_exists; then docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$CONTAINER" 2>/dev/null || true; fi
}
existing_compose_config_files(){
  if container_exists; then docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$CONTAINER" 2>/dev/null || true; fi
}
detect_base_compose(){
  local f
  BASE_COMPOSE_FILE=""
  for f in "$COMPOSE_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yaml" "$COMPOSE_DIR/compose.yml" "$COMPOSE_DIR/compose.yaml"; do
    [[ -f "$f" ]] && { BASE_COMPOSE_FILE="$f"; break; }
  done
  [[ -n "$BASE_COMPOSE_FILE" ]] || return 1
  KOSMO_OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.kosmo.yml"
}
build_existing_compose_args(){
  COMPOSE_ARGS=()
  local label f seen="," raw
  label="$(existing_compose_config_files)"
  if [[ -n "$label" ]]; then
    IFS=',' read -ra raw <<<"$label"
    for f in "${raw[@]}"; do
      f="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$f")"
      [[ -f "$f" ]] || continue
      [[ "$seen" == *",$f,"* ]] && continue
      COMPOSE_ARGS+=(-f "$f"); seen+="$f,"
    done
  fi
  if ((${#COMPOSE_ARGS[@]}==0)); then
    detect_base_compose || return 1
    COMPOSE_ARGS=(-f "$BASE_COMPOSE_FILE"); seen+= "$BASE_COMPOSE_FILE,"
    for f in "$COMPOSE_DIR/docker-compose.override.yml" "$COMPOSE_DIR/docker-compose.override.yaml" "$COMPOSE_DIR/compose.override.yml" "$COMPOSE_DIR/compose.override.yaml"; do
      [[ -f "$f" ]] || continue
      [[ "$seen" == *",$f,"* ]] && continue
      COMPOSE_ARGS+=(-f "$f"); seen+="$f,"
    done
  else
    BASE_COMPOSE_FILE="${COMPOSE_ARGS[1]}"
    KOSMO_OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.kosmo.yml"
  fi
  if [[ -n "$KOSMO_OVERRIDE_FILE" && -f "$KOSMO_OVERRIDE_FILE" && "$seen" != *",$KOSMO_OVERRIDE_FILE,"* ]]; then
    COMPOSE_ARGS+=(-f "$KOSMO_OVERRIDE_FILE")
  fi
}

choose_install_mode(){
  if container_exists || [[ -f "$COMPOSE_DIR/docker-compose.yml" ]] || [[ -f "$COMPOSE_DIR/docker-compose.yaml" ]] || [[ -f "$COMPOSE_DIR/compose.yml" ]] || [[ -f "$COMPOSE_DIR/compose.yaml" ]]; then
    INSTALL_MODE="existing"
    local d img svc
    d="$(existing_compose_dir)"; [[ -n "$d" && -d "$d" ]] && COMPOSE_DIR="$d"
    detect_base_compose || die "Существующая RemnaNode найдена, но compose-файл не обнаружен в $COMPOSE_DIR"
    if container_exists; then
      img="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
      [[ -n "$img" ]] && REMNANODE_IMAGE="$img"
      svc="$(existing_compose_service)"; [[ -n "$svc" ]] && COMPOSE_SERVICE="$svc"
    fi
    if [[ -z "${svc:-}" ]]; then
      local services count
      services="$(docker compose -f "$BASE_COMPOSE_FILE" config --services 2>/dev/null || true)"
      count="$(sed '/^$/d' <<<"$services" | wc -l)"
      [[ "$count" == 1 ]] && COMPOSE_SERVICE="$(sed '/^$/d' <<<"$services")"
    fi
    ok "Обнаружена существующая RemnaNode — base compose не перезаписывается (dir=$COMPOSE_DIR, service=$COMPOSE_SERVICE, image=$REMNANODE_IMAGE)"
  else
    INSTALL_MODE="new"; BASE_COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"; KOSMO_OVERRIDE_FILE=""; info "RemnaNode не найдена — режим новой установки"
  fi
}

mode_desc(){
  case "$1" in
    1) echo "VLESS TCP Reality";;
    2) echo "Hysteria2";;
    3) echo "VLESS TCP Reality + Hysteria2";;
    4) echo "VLESS XHTTP Reality";;
    5) echo "VLESS TCP Reality + XHTTP Reality";;
    6) echo "Hysteria2 + XHTTP Reality";;
    7) echo "TCP Reality + Hysteria2 + XHTTP Reality";;
    *) return 1;;
  esac
}
has_tcp(){ [[ "$TRANSPORT_MODE" =~ ^(1|3|5|7)$ ]]; }
has_h2(){ [[ "$TRANSPORT_MODE" =~ ^(2|3|6|7)$ ]]; }
has_xhttp(){ [[ "$TRANSPORT_MODE" =~ ^(4|5|6|7)$ ]]; }
xhttp_port(){ if has_tcp; then echo "$XHTTP_PORT_COMBO"; else echo 443; fi; }

choose_transport(){
  echo "Выбери рабочую схему:"
  echo "  1) VLESS TCP Reality (проверенная базовая)"
  echo "  2) Hysteria2"
  echo "  3) TCP Reality + Hysteria2 (оба на 443: TCP+UDP) [рекомендуется]"
  echo "  4) XHTTP + Reality"
  echo "  5) TCP Reality + XHTTP Reality (XHTTP на 8443)"
  echo "  6) Hysteria2 + XHTTP Reality (оба на 443: UDP+TCP)"
  echo "  7) TCP Reality + Hysteria2 + XHTTP Reality (XHTTP 8443)"
  local m; read -r -p "Выбор [$TRANSPORT_MODE]: " m; TRANSPORT_MODE="${m:-$TRANSPORT_MODE}"
  mode_desc "$TRANSPORT_MODE" >/dev/null || die "Неверный режим"
  ok "Схема: $(mode_desc "$TRANSPORT_MODE")"
}

ensure_hysteria_cert(){
  has_h2 || return 0
  mkdir -p "$(dirname "$HYSTERIA_CERT")"; chmod 700 "$(dirname "$HYSTERIA_CERT")"
  if [[ -s "$HYSTERIA_CERT" && -s "$HYSTERIA_KEY" ]] && openssl x509 -in "$HYSTERIA_CERT" -noout -checkend 86400 >/dev/null 2>&1; then
    ok "Hysteria TLS-сертификат уже есть и не истекает в ближайшие 24ч"; return 0
  fi
  local le="/etc/letsencrypt/live/$DOMAIN"
  if [[ -s "$le/fullchain.pem" && -s "$le/privkey.pem" ]]; then
    cp -L "$le/fullchain.pem" "$HYSTERIA_CERT"; cp -L "$le/privkey.pem" "$HYSTERIA_KEY"; chmod 600 "$HYSTERIA_CERT" "$HYSTERIA_KEY"; ok "Использован существующий Let's Encrypt сертификат"; return 0
  fi
  if ss -lnt '( sport = :80 )' | grep -q LISTEN; then
    die "Для Hysteria2 нужен TLS-сертификат, а TCP/80 занят. Скрипт ничего не будет останавливать автоматически. Освободи 80 или установи сертификат в $HYSTERIA_CERT/$HYSTERIA_KEY."
  fi
  need_cmd certbot || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot >/dev/null; }
  info "Получаю Let's Encrypt сертификат для $DOMAIN через standalone HTTP-01..."
  certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN" || die "Let's Encrypt не выдал сертификат"
  cp -L "$le/fullchain.pem" "$HYSTERIA_CERT"; cp -L "$le/privkey.pem" "$HYSTERIA_KEY"; chmod 600 "$HYSTERIA_CERT" "$HYSTERIA_KEY"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/kosmo-remnanode-hysteria.sh <<HOOK
#!/usr/bin/env bash
set -e
cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem $HYSTERIA_CERT
cp -L /etc/letsencrypt/live/$DOMAIN/privkey.pem $HYSTERIA_KEY
chmod 600 $HYSTERIA_CERT $HYSTERIA_KEY
docker restart $CONTAINER >/dev/null 2>&1 || true
HOOK
  chmod 700 /etc/letsencrypt/renewal-hooks/deploy/kosmo-remnanode-hysteria.sh
  ok "Hysteria TLS-сертификат установлен + renewal hook"
}

pull_node_image(){
  if [[ "$INSTALL_MODE" == "new" ]]; then
    docker pull "$REMNANODE_IMAGE" >/dev/null
    local pinned
    pinned="$(docker image inspect "$REMNANODE_IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
    if [[ -n "$pinned" && "$pinned" == *@sha256:* ]]; then
      REMNANODE_IMAGE="$pinned"
      ok "Образ RemnaNode загружен и зафиксирован по digest: ${pinned#*@}"
    else
      warn "Не удалось получить RepoDigest; используется $REMNANODE_IMAGE"
    fi
  fi
}

gen_reality_keys(){
  if ! has_tcp && ! has_xhttp; then PRIVATE_KEY=""; PUBLIC_KEY=""; SID_TCP=""; SID_XHTTP=""; return 0; fi
  local raw
  if container_running; then raw="$(docker exec "$CONTAINER" rw-core x25519 2>&1)" || true
  else raw="$(docker run --rm --entrypoint rw-core "$REMNANODE_IMAGE" x25519 2>&1)" || true; fi
  PRIVATE_KEY="$(awk -F': ' 'tolower($1) ~ /privatekey|private key/ {print $2;exit}' <<<"$raw")"
  PUBLIC_KEY="$(awk -F': ' 'tolower($1) ~ /password|publickey|public key/ {print $2;exit}' <<<"$raw")"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "Не удалось получить пару X25519 из rw-core"
  SID_TCP="$(openssl rand -hex 8)"; SID_XHTTP="$(openssl rand -hex 8)"
  ok "Reality X25519 ключи сгенерированы"
}

make_names(){
  local base suffix code
  base="$(tr '[:lower:]' '[:upper:]' <<<"${DOMAIN%%.*}" | sed -E 's/[^A-Z0-9]+/-/g' | cut -c1-14)"; [[ -n "$base" ]] || base="NODE"
  suffix="$(openssl rand -hex 2 | tr '[:lower:]' '[:upper:]')"
  code="M$TRANSPORT_MODE"
  PROFILE_NAME="KOSMO-${base}-${code}-${suffix}"
  TCP_TAG="${base}-TCP-${suffix}"; H2_TAG="${base}-H2-${suffix}"; XHTTP_TAG="${base}-XH-${suffix}"
  TCP_HOST="${base} TCP ${suffix}"; H2_HOST="${base} Hysteria ${suffix}"; XHTTP_HOST="${base} XHTTP ${suffix}"
  NODE_DEFAULT_NAME="KOSMO-${base}"
  XHTTP_PATH="/api/v1/$(openssl rand -hex 8)/"
}

build_profile(){
  local inbounds='[]' p xp
  if has_tcp; then
    p="$(jq -n --arg tag "$TCP_TAG" --arg target "$REALITY_TARGET" --arg pk "$PRIVATE_KEY" --arg sid "$SID_TCP" '{tag:$tag,port:443,listen:"0.0.0.0",protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,routeOnly:true,destOverride:["http","tls","quic"]},streamSettings:{network:"tcp",sockopt:{mark:255,tcpNoDelay:true,tcpFastOpen:true},security:"reality",tcpSettings:{header:{type:"none"},acceptProxyProtocol:false},realitySettings:{dest:($target+":443"),show:false,xver:0,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$target]}}}')"
    inbounds="$(jq --argjson x "$p" '. + [$x]' <<<"$inbounds")"
  fi
  if has_h2; then
    p="$(jq -n --arg tag "$H2_TAG" --arg cert "$HYSTERIA_CERT" --arg key "$HYSTERIA_KEY" '{tag:$tag,port:443,listen:"0.0.0.0",protocol:"hysteria",settings:{users:[],clients:[],version:2},streamSettings:{network:"hysteria",security:"tls",tlsSettings:{alpn:["h3"],certificates:[{keyFile:$key,certificateFile:$cert}]},hysteriaSettings:{version:2}}}')"
    inbounds="$(jq --argjson x "$p" '. + [$x]' <<<"$inbounds")"
  fi
  if has_xhttp; then
    xp="$(xhttp_port)"
    p="$(jq -n --arg tag "$XHTTP_TAG" --arg target "$REALITY_TARGET" --arg pk "$PRIVATE_KEY" --arg sid "$SID_XHTTP" --arg path "$XHTTP_PATH" --argjson port "$xp" '{tag:$tag,port:$port,listen:"0.0.0.0",protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,routeOnly:true,destOverride:["http","tls","quic"]},streamSettings:{network:"xhttp",security:"reality",xhttpSettings:{host:$target,mode:"packet-up",path:$path},realitySettings:{dest:($target+":443"),show:false,xver:0,spiderX:"",shortIds:[$sid],privateKey:$pk,serverNames:[$target]}}}')"
    inbounds="$(jq --argjson x "$p" '. + [$x]' <<<"$inbounds")"
  fi
  PROFILE_JSON="$(jq -n --argjson ib "$inbounds" '{log:{loglevel:"warning"},dns:{servers:["1.1.1.1","8.8.8.8"],queryStrategy:"UseIPv4"},inbounds:$ib,outbounds:[{tag:"DIRECT",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}],domainStrategy:"IPIfNonMatch"}}')"
  PROFILE_FILE="$PROFILE_DIR/${PROFILE_NAME}.json"
  printf '%s\n' "$PROFILE_JSON" | jq . > "$PROFILE_FILE"; chmod 600 "$PROFILE_FILE"
  ok "Профиль собран: $PROFILE_FILE"
}

validate_profile_shape(){
  jq -e '.inbounds|length>0' "$PROFILE_FILE" >/dev/null || die "Пустой профиль"
  if has_tcp; then jq -e --arg t "$TCP_TAG" '.inbounds[]|select(.tag==$t)|.streamSettings.network=="tcp" and .streamSettings.security=="reality" and (.settings|has("flow")|not)' "$PROFILE_FILE" >/dev/null || die "TCP Reality профиль не прошёл self-check"; fi
  if has_h2; then jq -e --arg t "$H2_TAG" '.inbounds[]|select(.tag==$t)|.protocol=="hysteria" and .streamSettings.network=="hysteria"' "$PROFILE_FILE" >/dev/null || die "Hysteria профиль не прошёл self-check"; fi
  if has_xhttp; then jq -e --arg t "$XHTTP_TAG" '.inbounds[]|select(.tag==$t)|.streamSettings.network=="xhttp" and .streamSettings.security=="reality" and .streamSettings.xhttpSettings.mode=="packet-up"' "$PROFILE_FILE" >/dev/null || die "XHTTP профиль не прошёл self-check"; fi
  ok "Структура профиля проверена"
}

validate_profile_xray(){
  local mounts=(-v "$PROFILE_FILE:/tmp/kosmo-profile.json:ro")
  has_h2 && mounts+=(-v "/opt/hysteria/certs:/opt/hysteria/certs:ro")
  local out rc=0
  out="$(docker run --rm --entrypoint rw-core "${mounts[@]}" "$REMNANODE_IMAGE" run -test -c /tmp/kosmo-profile.json 2>&1)" || rc=$?
  if ((rc!=0)); then
    warn "rw-core -test не принял профиль. Вывод:"
    echo "$out" >&2
    die "Профиль не будет отправлен в панель"
  fi
  ok "Профиль принят реальным rw-core"
}

panel_discover(){
  PROFILES_JSON="$(api_get config-profiles)"
  HOSTS_JSON="$(api_get hosts)"
  SQUADS_JSON="$(api_get internal-squads)"
  NODES_JSON="$(api_get nodes)"
  INBOUNDS_JSON="$(api_get config-profiles/inbounds)"
}
profiles_arr(){ jq -c '(.response//.)|(.configProfiles//[])' <<<"$PROFILES_JSON"; }
hosts_arr(){ jq -c '(.response//.)|if type=="array" then . else (.hosts//[]) end' <<<"$HOSTS_JSON"; }
squads_arr(){ jq -c '(.response//.)|(.internalSquads//[])' <<<"$SQUADS_JSON"; }
nodes_arr(){ jq -c '(.response//.)|if type=="array" then . else (.nodes//[]) end' <<<"$NODES_JSON"; }
inbounds_arr(){ jq -c '(.response//.)|if type=="array" then . else (.inbounds//[]) end' <<<"$INBOUNDS_JSON"; }

collision_guard(){
  profiles_arr | jq -e --arg n "$PROFILE_NAME" 'any(.[];.name==$n)' >/dev/null && die "Profile $PROFILE_NAME уже существует"
  local h
  for h in "$TCP_HOST" "$H2_HOST" "$XHTTP_HOST"; do
    [[ -n "$h" ]] || continue
    hosts_arr | jq -e --arg n "$h" 'any(.[];.remark==$n)' >/dev/null && die "Host '$h' уже существует"
  done
  ok "Коллизий с создаваемыми объектами нет"
}

snapshot_panel(){
  local d="$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$d"; chmod 700 "$d"
  printf '%s\n' "$PROFILES_JSON" > "$d/profiles.json"
  printf '%s\n' "$HOSTS_JSON" > "$d/hosts.json"
  printf '%s\n' "$SQUADS_JSON" > "$d/squads.json"
  printf '%s\n' "$NODES_JSON" > "$d/nodes.json"
  printf '%s\n' "$INBOUNDS_JSON" > "$d/inbounds.json"
  (cd "$d" && sha256sum *.json > SHA256SUMS)
  SNAPSHOT_DIR="$d"; ok "Snapshot панели: $d"
}

backup_local(){
  local d="$BACKUPS/local-$(date -u +%Y%m%dT%H%M%SZ)-$$"; mkdir -p "$d"; chmod 700 "$d"
  local f
  for f in "$COMPOSE_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yaml" "$COMPOSE_DIR/compose.yml" "$COMPOSE_DIR/compose.yaml" "$COMPOSE_DIR/docker-compose.override.yml" "$COMPOSE_DIR/docker-compose.kosmo.yml"; do
    [[ -f "$f" ]] && cp -a "$f" "$d/"
  done
  LOCAL_BACKUP="$d"; ok "Локальный backup compose: $d"
}

panel_fingerprint(){
  { profiles_arr; hosts_arr; squads_arr; nodes_arr; inbounds_arr; } | sha256sum | awk '{print $1}'
}

get_panel_secret(){
  local r
  r="$(api_get keygen)" || die "Не удалось получить SECRET_KEY панели"
  NODE_SECRET="$(jq -r '.response.secretKey // .response.pubKey // empty' <<<"$r")"
  [[ -n "$NODE_SECRET" ]] || die "Панель не вернула secretKey/pubKey"
  ok "SECRET_KEY панели получен (не выводится)"
}

write_new_compose(){
  backup_local
  cat > "$COMPOSE_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    image: "$REMNANODE_IMAGE"
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
    environment:
      NODE_PORT: "2222"
      SECRET_KEY: "$NODE_SECRET"
EOF
  if has_h2; then
    cat >> "$COMPOSE_DIR/docker-compose.yml" <<'EOF'
    volumes:
      - /opt/hysteria/certs:/opt/hysteria/certs:ro
EOF
  fi
  chmod 600 "$COMPOSE_DIR/docker-compose.yml"
  (cd "$COMPOSE_DIR" && docker compose -f "$COMPOSE_DIR/docker-compose.yml" config >/dev/null) || die "Новый docker-compose.yml невалиден"
  BASE_COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  ok "Новый RemnaNode compose подготовлен"
}

ensure_existing_h2_mount(){
  has_h2 || return 0
  [[ "$INSTALL_MODE" == existing ]] || return 0
  detect_base_compose || die "Не найден base compose для существующей Node"
  KOSMO_OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.kosmo.yml"
  backup_local
  if docker inspect "$CONTAINER" --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' 2>/dev/null | grep -Fq -- '-> /opt/hysteria/certs'; then
    ok "Hysteria cert volume уже подключён"; return 0
  fi
  if [[ -f "$KOSMO_OVERRIDE_FILE" ]]; then
    grep -Fq '/opt/hysteria/certs:/opt/hysteria/certs:ro' "$KOSMO_OVERRIDE_FILE" || die "$KOSMO_OVERRIDE_FILE уже существует и не является нашим ожидаемым override. Не перезаписываю."
    info "Использую ранее созданный Kosmo override: $KOSMO_OVERRIDE_FILE"
  else
    local tmp="$COMPOSE_DIR/.docker-compose.kosmo.yml.$$"
    cat > "$tmp" <<EOF
services:
  $COMPOSE_SERVICE:
    volumes:
      - /opt/hysteria/certs:/opt/hysteria/certs:ro
EOF
    # Сначала проверяем во временном файле вместе со ВСЕМИ compose-файлами текущего проекта.
    local saved="$KOSMO_OVERRIDE_FILE"
    KOSMO_OVERRIDE_FILE="$tmp"; build_existing_compose_args || { rm -f "$tmp"; KOSMO_OVERRIDE_FILE="$saved"; die "Не удалось определить compose stack"; }
    (cd "$COMPOSE_DIR" && docker compose "${COMPOSE_ARGS[@]}" config >/dev/null) || { rm -f "$tmp"; KOSMO_OVERRIDE_FILE="$saved"; die "Kosmo override невалиден; существующие compose-файлы НЕ менялись"; }
    KOSMO_OVERRIDE_FILE="$saved"; mv "$tmp" "$KOSMO_OVERRIDE_FILE"; chmod 600 "$KOSMO_OVERRIDE_FILE"
    ok "Создан отдельный $KOSMO_OVERRIDE_FILE; чужие override не перезаписываются"
  fi
  build_existing_compose_args || die "Не удалось собрать compose stack"
}

compose_up_existing(){
  build_existing_compose_args || die "Не найден compose stack"
  (cd "$COMPOSE_DIR" && docker compose "${COMPOSE_ARGS[@]}" up -d)
}

start_node_local(){
  (cd "$COMPOSE_DIR" && docker compose -f "$COMPOSE_DIR/docker-compose.yml" up -d) || die "Не удалось поднять RemnaNode"
  local i
  for i in {1..20}; do container_running && break; sleep 1; done
  container_running || die "Контейнер remnanode не запустился"
  docker exec "$CONTAINER" rw-core version | head -n1 || true
  ok "RemnaNode запущена"
}

panel_node_matches(){
  local ips; ips="$(public_ipv4s | jq -R . | jq -s .)"
  nodes_arr | jq -c --arg d "$DOMAIN" --argjson ips "$ips" '[.[]|select(.address==$d or (.address as $a|$ips|index($a)))]'
}

select_or_create_node_plan(){
  local arr exact ipmatches count ips
  arr="$(nodes_arr)"
  exact="$(jq -c --arg d "$DOMAIN" '[.[]|select(.address==$d)]' <<<"$arr")"
  count="$(jq 'length' <<<"$exact")"
  if ((count==1)); then
    NODE_ACTION="reuse"; NODE_UUID="$(jq -r '.[0].uuid' <<<"$exact")"; NODE_NAME="$(jq -r '.[0].name' <<<"$exact")"; NODE_ADDRESS="$(jq -r '.[0].address' <<<"$exact")"
    OLD_PROFILE_UUID="$(jq -r '.[0].configProfile.activeConfigProfileUuid // empty' <<<"$exact")"; OLD_INBOUNDS="$(jq -c '.[0].configProfile.activeInbounds // []' <<<"$exact")"
    info "Панель: найдена точная Node '$NODE_NAME' по домену $DOMAIN — переключение профиля будет последним шагом"
    return 0
  elif ((count>1)); then
    die "В панели несколько Node с точным address=$DOMAIN. Автовыбор запрещён."
  fi
  ips="$(public_ipv4s | jq -R . | jq -s .)"
  ipmatches="$(jq -c --argjson ips "$ips" '[.[]|select(.address as $a|$ips|index($a))]' <<<"$arr")"
  count="$(jq 'length' <<<"$ipmatches")"
  if ((count==1)); then
    echo "Панель содержит Node на IP этого сервера, но address не равен домену:"
    jq -r '.[0]|"  \(.name) | \(.address):\(.port) | \(.uuid)"' <<<"$ipmatches"
    local a; read -r -p "Использовать эту существующую Node? [y/N]: " a
    if [[ "${a,,}" == y || "${a,,}" == yes ]]; then
      NODE_ACTION="reuse"; NODE_UUID="$(jq -r '.[0].uuid' <<<"$ipmatches")"; NODE_NAME="$(jq -r '.[0].name' <<<"$ipmatches")"; NODE_ADDRESS="$(jq -r '.[0].address' <<<"$ipmatches")"
      OLD_PROFILE_UUID="$(jq -r '.[0].configProfile.activeConfigProfileUuid // empty' <<<"$ipmatches")"; OLD_INBOUNDS="$(jq -c '.[0].configProfile.activeInbounds // []' <<<"$ipmatches")"
      return 0
    fi
  elif ((count>1)); then
    warn "На публичных IP сервера найдено несколько Panel Node; ни одна автоматически не изменяется."
  fi
  NODE_ACTION="create"; NODE_NAME="$NODE_DEFAULT_NAME"; NODE_ADDRESS="$DOMAIN"; NODE_UUID=""; OLD_PROFILE_UUID=""; OLD_INBOUNDS='[]'
  info "Панель: точная Node для $DOMAIN не выбрана — будет создана новая '$NODE_NAME'"
}

choose_squads(){
  local arr n
  arr="$(squads_arr)"; n="$(jq 'length' <<<"$arr")"
  if ((n==0)); then SQUAD_UUIDS='[]'; warn "Internal Squad отсутствуют. Скрипт создаст отдельную squad, но пользователей в неё автоматически не добавляет."; return; fi
  if ((n==1)); then SQUAD_UUIDS="$(jq '[.[0].uuid]' <<<"$arr")"; info "Internal Squad: $(jq -r '.[0].name' <<<"$arr") (автовыбор)"; return; fi
  echo "Internal Squads (куда добавить новые inbound, только additive):"
  jq -r 'to_entries[]|"  \(.key+1)) \(.value.name) [\(.value.inbounds|length) inbound]"' <<<"$arr"
  echo "  a) во все squads"
  local s; read -r -p "Выбор [1]: " s; s="${s:-1}"
  if [[ "$s" == a || "$s" == A ]]; then SQUAD_UUIDS="$(jq '[.[].uuid]' <<<"$arr")"
  elif [[ "$s" =~ ^[0-9]+$ ]] && ((s>=1 && s<=n)); then SQUAD_UUIDS="$(jq --argjson i "$((s-1))" '[.[$i].uuid]' <<<"$arr")"
  else die "Неверный выбор squad"; fi
}

show_plan(){
  echo
  log "${C_BOLD}=== PLAN (до подтверждения панель не меняется) ===${C_RESET}"
  echo "Сервер:        $INSTALL_MODE"
  echo "Node domain:   $DOMAIN"
  echo "Panel:         $PANEL_URL"
  echo "Схема:        $(mode_desc "$TRANSPORT_MODE")"
  echo "Profile NEW:   $PROFILE_NAME"
  has_tcp && echo "TCP Reality:   443/tcp, tag=$TCP_TAG, SNI=$REALITY_TARGET, flow=Vision(auto)"
  has_h2 && echo "Hysteria2:     443/udp, tag=$H2_TAG, TLS=$DOMAIN"
  has_xhttp && echo "XHTTP Reality: $(xhttp_port)/tcp, tag=$XHTTP_TAG, mode=packet-up, ALPN=h2, path=$XHTTP_PATH"
  echo "Node action:   $NODE_ACTION ${NODE_UUID:+($NODE_UUID)}"
  echo "Panel policy:  create NEW Profile/Hosts/Node; Squad PATCH только ADD; DELETE=NEVER"
  [[ "$NODE_ACTION" == reuse ]] && echo "Node switch:   САМЫЙ ПОСЛЕДНИЙ шаг; старый profile UUID сохранён для rollback"
  echo "Snapshot:      будет создан до первой записи"
  echo
}

create_profile_panel(){
  local body r
  body="$(jq -n --arg n "$PROFILE_NAME" --argjson c "$PROFILE_JSON" '{name:$n,config:$c}')"
  r="$(api_post config-profiles "$body")" || die "Не удалось создать Config Profile"
  PROFILE_UUID="$(jq -r '.response.uuid // .uuid // empty' <<<"$r")"
  [[ -n "$PROFILE_UUID" ]] || die "Панель не вернула profile UUID"
  echo "$(date -u +%FT%TZ) profile $PROFILE_UUID" >> "$BASE_DIR/created.log"
  local ib; ib="$(api_get "config-profiles/$PROFILE_UUID/inbounds")"
  INBOUND_ROWS="$(jq -c '(.response//.)|if type=="array" then . else (.inbounds//[]) end' <<<"$ib")"
  TCP_UUID=""; H2_UUID=""; XHTTP_UUID=""
  has_tcp && TCP_UUID="$(jq -r --arg t "$TCP_TAG" '.[]|select(.tag==$t)|.uuid' <<<"$INBOUND_ROWS" | head -n1)"
  has_h2 && H2_UUID="$(jq -r --arg t "$H2_TAG" '.[]|select(.tag==$t)|.uuid' <<<"$INBOUND_ROWS" | head -n1)"
  has_xhttp && XHTTP_UUID="$(jq -r --arg t "$XHTTP_TAG" '.[]|select(.tag==$t)|.uuid' <<<"$INBOUND_ROWS" | head -n1)"
  if has_tcp && [[ -z "$TCP_UUID" ]]; then die "Не получен TCP inbound UUID"; fi
  if has_h2 && [[ -z "$H2_UUID" ]]; then die "Не получен Hysteria inbound UUID"; fi
  if has_xhttp && [[ -z "$XHTTP_UUID" ]]; then die "Не получен XHTTP inbound UUID"; fi
  ACTIVE_INBOUNDS="$(printf '%s\n' "$TCP_UUID" "$H2_UUID" "$XHTTP_UUID" | sed '/^$/d' | jq -R . | jq -s .)"
  ok "Panel Config Profile создан: $PROFILE_UUID"
}

create_node_panel(){
  [[ "$NODE_ACTION" == create ]] || return 0
  local b r
  b="$(jq -n --arg n "$NODE_NAME" --arg a "$NODE_ADDRESS" --arg p "$PROFILE_UUID" --argjson ib "$ACTIVE_INBOUNDS" '{name:$n,address:$a,port:2222,configProfile:{activeConfigProfileUuid:$p,activeInbounds:$ib},isTrafficTrackingActive:false,trafficLimitBytes:0,notifyPercent:0,trafficResetDay:31,countryCode:"XX",consumptionMultiplier:1.0}')"
  r="$(api_post nodes "$b")" || die "Не удалось создать Node в панели"
  NODE_UUID="$(jq -r '.response.uuid // .uuid // empty' <<<"$r")"; [[ -n "$NODE_UUID" ]] || die "Панель не вернула Node UUID"
  echo "$(date -u +%FT%TZ) node $NODE_UUID" >> "$BASE_DIR/created.log"
  ok "Panel Node создана: $NODE_UUID"
}

create_host(){
  local kind="$1" inbound_uuid="$2" remark="$3" port="$4" body r disabled=false
  [[ "$NODE_ACTION" == reuse ]] && disabled=true
  case "$kind" in
    tcp)
      body="$(jq -n --arg p "$PROFILE_UUID" --arg i "$inbound_uuid" --arg n "$remark" --arg a "$DOMAIN" --arg s "$REALITY_TARGET" --arg node "$NODE_UUID" --argjson disabled "$disabled" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$n,address:$a,port:443,sni:$s,fingerprint:"chrome",securityLayer:"DEFAULT",isDisabled:$disabled,isHidden:false,nodes:[$node]}')";;
    h2)
      body="$(jq -n --arg p "$PROFILE_UUID" --arg i "$inbound_uuid" --arg n "$remark" --arg a "$DOMAIN" --arg node "$NODE_UUID" --argjson disabled "$disabled" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$n,address:$a,port:443,sni:$a,securityLayer:"DEFAULT",isDisabled:$disabled,isHidden:false,nodes:[$node]}')";;
    xhttp)
      body="$(jq -n --arg p "$PROFILE_UUID" --arg i "$inbound_uuid" --arg n "$remark" --arg a "$DOMAIN" --arg s "$REALITY_TARGET" --arg h "$REALITY_TARGET" --arg path "$XHTTP_PATH" --arg node "$NODE_UUID" --argjson port "$port" --argjson disabled "$disabled" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$n,address:$a,port:$port,path:$path,host:$h,sni:$s,alpn:"h2",fingerprint:"chrome",securityLayer:"DEFAULT",isDisabled:$disabled,isHidden:false,nodes:[$node]}')";;
  esac
  r="$(api_post hosts "$body")" || die "Не удалось создать Host '$remark'"
  local u; u="$(jq -r '.response.uuid // .uuid // empty' <<<"$r")"; [[ -n "$u" ]] || die "Host '$remark' не вернул UUID"
  CREATED_HOST_UUIDS="$(jq --arg u "$u" '. + [$u] | unique' <<<"$CREATED_HOST_UUIDS")"
  echo "$(date -u +%FT%TZ) host $u $remark" >> "$BASE_DIR/created.log"; ok "Host создан: $remark$([[ "$disabled" == true ]] && echo ' [пока disabled до успешного doctor]')"
}

enable_created_hosts(){
  [[ "$NODE_ACTION" == reuse ]] || return 0
  local u body
  while read -r u; do
    [[ -n "$u" ]] || continue
    body="$(jq -n --arg u "$u" '{uuid:$u,isDisabled:false}')"
    api_patch_owned_host "$u" "$body" >/dev/null || return 1
  done < <(jq -r '.[]' <<<"$CREATED_HOST_UUIDS")
  ok "Новые Hosts включены только после успешной проверки Node"
}

create_hosts_panel(){
  has_tcp && create_host tcp "$TCP_UUID" "$TCP_HOST" 443
  has_h2 && create_host h2 "$H2_UUID" "$H2_HOST" 443
  has_xhttp && create_host xhttp "$XHTTP_UUID" "$XHTTP_HOST" "$(xhttp_port)"
}

additive_squads(){
  local n; n="$(jq 'length' <<<"$SQUAD_UUIDS")"
  if ((n==0)); then
    local body r su
    body="$(jq -n --arg n "KOSMO-${PROFILE_NAME}" --argjson ib "$ACTIVE_INBOUNDS" '{name:$n,inbounds:$ib}')"
    r="$(api_post internal-squads "$body")" || die "Не удалось создать Internal Squad"
    su="$(jq -r '.response.uuid // .uuid // empty' <<<"$r")"; echo "$(date -u +%FT%TZ) squad $su" >> "$BASE_DIR/created.log"; ok "Создана новая Internal Squad: $su"; return
  fi
  local arr uuid current merged before after body
  arr="$(squads_arr)"
  while read -r uuid; do
    current="$(jq -c --arg u "$uuid" '[.[]|select(.uuid==$u)|(.inbounds // [])[]|.uuid]' <<<"$arr")"
    merged="$(jq -n --argjson a "$current" --argjson b "$ACTIVE_INBOUNDS" '$a+$b|unique')"
    before="$(jq 'length' <<<"$current")"; after="$(jq 'length' <<<"$merged")"
    ((after>=before)) || die "Safety: squad update пытался уменьшить список inbound"
    body="$(jq -n --arg u "$uuid" --argjson ib "$merged" '{uuid:$u,inbounds:$ib}')"
    api_patch_squad "$body" >/dev/null || die "Не удалось additive-обновить squad $uuid"
    ok "Squad $uuid: $before -> $after inbound (удалено 0)"
  done < <(jq -r '.[]' <<<"$SQUAD_UUIDS")
}

switch_existing_node_last(){
  [[ "$NODE_ACTION" == reuse ]] || return 0
  local body
  body="$(jq -n --arg u "$NODE_UUID" --arg p "$PROFILE_UUID" --argjson ib "$ACTIVE_INBOUNDS" '{uuids:[$u],configProfile:{activeConfigProfileUuid:$p,activeInbounds:$ib}}')"
  api_post nodes/bulk-actions/profile-modification "$body" >/dev/null || die "Не удалось переключить существующую Node; старый профиль остался активен"
  NODE_SWITCHED=1
  ok "Existing Node переключена на новый профиль последним шагом"
}

rollback_node_binding(){
  [[ -n "${NODE_UUID:-}" && -n "${OLD_PROFILE_UUID:-}" ]] || { warn "Нет сохранённого предыдущего binding"; return 1; }
  local body
  body="$(jq -n --arg u "$NODE_UUID" --arg p "$OLD_PROFILE_UUID" --argjson ib "${OLD_INBOUNDS:-[]}" '{uuids:[$u],configProfile:{activeConfigProfileUuid:$p,activeInbounds:$ib}}')"
  api_post nodes/bulk-actions/profile-modification "$body" >/dev/null || return 1
  ok "Node возвращена на предыдущий profile $OLD_PROFILE_UUID"
}

firewall_add_only(){
  need_cmd ufw || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || { info "UFW выключен — скрипт его не включает и не сбрасывает"; return 0; }
  if has_h2; then ufw allow 443/udp comment 'Kosmo Hysteria2' >/dev/null || true; fi
  if has_tcp || has_xhttp; then ufw allow 443/tcp comment 'Kosmo VLESS' >/dev/null || true; fi
  if has_xhttp && [[ "$(xhttp_port)" != 443 ]]; then ufw allow "$(xhttp_port)/tcp" comment 'Kosmo XHTTP' >/dev/null || true; fi
  # Не сужаем 2222 до IP домена панели автоматически: панель может быть за CDN/reverse-proxy,
  # а исходящее соединение к Node придёт с origin-IP. Добавляем правило, но никогда не reset/delete UFW.
  ufw allow 2222/tcp comment 'Remnawave Node API' >/dev/null || true
  ok "UFW: добавлены только необходимые allow; существующие правила не удалялись"
  ufw reload >/dev/null 2>&1 || true
}

postcheck(){
  info "Финальная проверка effective config..."
  local i dump=""
  for i in {1..20}; do
    dump="$(docker exec "$CONTAINER" cli --dump-config-raw 2>/dev/null || true)"
    [[ -n "$dump" ]] && break
    sleep 2
  done
  [[ -n "$dump" ]] || { warn "cli --dump-config-raw пуст: профиль ещё не применился или Node API не готов"; return 2; }
  printf '%s\n' "$dump" | jq . > "$BASE_DIR/effective-last.json" || { warn "effective config не JSON"; return 2; }
  local fail=0
  if has_tcp; then jq -e --arg t "$TCP_TAG" --arg d "$REALITY_TARGET:443" '.inbounds[]|select(.tag==$t)|.streamSettings.network=="tcp" and .streamSettings.security=="reality" and .streamSettings.realitySettings.dest==$d' "$BASE_DIR/effective-last.json" >/dev/null || fail=1; fi
  if has_h2; then jq -e --arg t "$H2_TAG" '.inbounds[]|select(.tag==$t)|.protocol=="hysteria" and .streamSettings.network=="hysteria"' "$BASE_DIR/effective-last.json" >/dev/null || fail=1; fi
  if has_xhttp; then jq -e --arg t "$XHTTP_TAG" --arg p "$XHTTP_PATH" '.inbounds[]|select(.tag==$t)|.streamSettings.network=="xhttp" and .streamSettings.security=="reality" and .streamSettings.xhttpSettings.path==$p' "$BASE_DIR/effective-last.json" >/dev/null || fail=1; fi
  ss -lntup | grep -E ':(443|8443)\b' || true
  if ((fail)); then warn "Effective config отличается от ожидаемого"; return 2; fi
  ok "Effective config содержит все выбранные inbound"
  if has_tcp; then
    local flow; flow="$(jq -r --arg t "$TCP_TAG" '.inbounds[]|select(.tag==$t)|.settings.flow // empty' "$BASE_DIR/effective-last.json")"
    [[ "$flow" == "xtls-rprx-vision" ]] && ok "TCP flow автоматически: xtls-rprx-vision" || warn "TCP flow: '${flow:-пусто}'"
  fi
  return 0
}

save_state(){
  jq -n \
    --arg v "$VERSION" --arg d "$DOMAIN" --arg p "$PANEL_URL" --arg mode "$TRANSPORT_MODE" --arg install "$INSTALL_MODE" --arg image "$REMNANODE_IMAGE" \
    --arg profile "$PROFILE_UUID" --arg node "$NODE_UUID" --arg pub "$PUBLIC_KEY" --arg sidTcp "$SID_TCP" --arg sidXh "$SID_XHTTP" \
    --arg oldp "${OLD_PROFILE_UUID:-}" --argjson oldi "${OLD_INBOUNDS:-[]}" --arg snap "$SNAPSHOT_DIR" --arg file "$PROFILE_FILE" \
    '{version:$v,domain:$d,panel:$p,transportMode:$mode,installMode:$install,nodeImage:$image,profileUuid:$profile,nodeUuid:$node,publicKey:$pub,tcpShortId:$sidTcp,xhttpShortId:$sidXh,previousProfileUuid:$oldp,previousActiveInbounds:$oldi,snapshot:$snap,profileFile:$file,createdAt:(now|todate)}' > "$STATE"
  chmod 600 "$STATE"
}

write_txn(){
  local status="$1"
  jq -n --arg s "$status" --arg t "$(date -u +%FT%TZ)" --arg p "${PROFILE_UUID:-}" --arg n "${NODE_UUID:-}" --arg snap "${SNAPSHOT_DIR:-}" '{status:$s,time:$t,profileUuid:$p,nodeUuid:$n,snapshot:$snap}' > "$TXN"; chmod 600 "$TXN"
}

run_full_setup(){
  banner; need_root; os_preflight; install_base_packages; install_docker_if_needed; load_settings
  panel_auth; ask_domain; choose_transport; save_settings
  check_domain_strict; check_reality_target; choose_install_mode
  ensure_hysteria_cert; pull_node_image; make_names; gen_reality_keys; build_profile; validate_profile_shape; validate_profile_xray
  panel_discover; collision_guard; select_or_create_node_plan; choose_squads
  local fp1 fp2; fp1="$(panel_fingerprint)"; show_plan
  local q; read -r -p "Для начала записи введи СОЗДАТЬ: " q; [[ "$q" == "СОЗДАТЬ" ]] || { info "Отменено. Панель не менялась."; return 0; }
  panel_discover; fp2="$(panel_fingerprint)"; [[ "$fp1" == "$fp2" ]] || die "Панель изменилась после PLAN. Ничего не записано; запусти ещё раз."
  snapshot_panel; write_txn "started"
  if [[ "$INSTALL_MODE" == new ]]; then get_panel_secret; write_new_compose; else ensure_existing_h2_mount; fi
  create_profile_panel
  if [[ "$INSTALL_MODE" == new ]]; then
    start_node_local
  else
    if has_h2 && [[ -n "$KOSMO_OVERRIDE_FILE" && -f "$KOSMO_OVERRIDE_FILE" ]]; then
      compose_up_existing >/dev/null || die "Не удалось безопасно применить Hysteria volume override"
    elif ! container_running; then
      docker start "$CONTAINER" >/dev/null || die "Не удалось запустить существующий контейнер $CONTAINER"
    fi
  fi
  firewall_add_only
  create_node_panel
  create_hosts_panel
  additive_squads
  switch_existing_node_last
  sleep 3
  local pc=0; postcheck || pc=$?
  if ((pc==0)); then
    enable_created_hosts || pc=3
  fi
  if ((pc!=0)) && [[ "$NODE_ACTION" == reuse && "$NODE_SWITCHED" == 1 && -n "${OLD_PROFILE_UUID:-}" ]]; then
    warn "Новая конфигурация не прошла финальную проверку — автоматически возвращаю существующую Node на прежний profile binding (объекты не удаляются)."
    rollback_node_binding || warn "Автоматический rollback binding не удался; используй пункт меню rollback."
    NODE_SWITCHED=0
  fi
  save_state; write_txn "$([[ $pc -eq 0 ]] && echo success || echo warning)"
  echo
  if ((pc==0)); then ok "ГОТОВО: Node настроена, effective config подтверждён, Hosts активированы"; else warn "Созданные новые объекты сохранены для аудита, но существующая Node возвращена на старый profile при возможности. DELETE не выполнялся."; fi
  echo "Profile UUID: $PROFILE_UUID"
  echo "Node UUID:    $NODE_UUID"
  (has_tcp || has_xhttp) && echo "PublicKey:    $PUBLIC_KEY"
  has_tcp && echo "TCP ShortID:  $SID_TCP"
  has_xhttp && echo "XHTTP ShortID:$SID_XHTTP"
  has_xhttp && echo "XHTTP path:   $XHTTP_PATH"
  echo "Snapshot:     $SNAPSHOT_DIR"
  echo "State:        $STATE"
}

doctor_readonly(){
  banner; need_root; install_base_packages; load_settings
  echo "=== Docker ==="; docker ps --filter name="$CONTAINER" || true
  echo; echo "=== Ports ==="; ss -lntup | grep -E ':(443|8443|2222)\b' || true
  echo; echo "=== rw-core ==="; docker exec "$CONTAINER" rw-core version | head -n1 || true
  echo; echo "=== Effective inbounds ==="
  docker exec "$CONTAINER" cli --dump-config-raw 2>/dev/null | jq '[.inbounds[]|{tag,protocol,port,listen,network:.streamSettings.network,security:.streamSettings.security,flow:.settings.flow,dest:.streamSettings.realitySettings.dest,xhttpPath:.streamSettings.xhttpSettings.path}]' || true
  echo; [[ -s "$STATE" ]] && { echo "=== Managed state ==="; jq '{version,domain,transportMode,profileUuid,nodeUuid,previousProfileUuid,createdAt}' "$STATE"; }
}

panel_audit(){
  banner; need_root; install_base_packages; load_settings; panel_auth; panel_discover
  echo "Profiles: $(profiles_arr | jq 'length')"
  echo "Hosts:    $(hosts_arr | jq 'length')"
  echo "Nodes:    $(nodes_arr | jq 'length')"
  echo "Squads:   $(squads_arr | jq 'length')"
  echo; echo "Nodes:"
  nodes_arr | jq -r '.[]|"- \(.name) | \(.address):\(.port) | \(.uuid) | profile=\(.configProfile.activeConfigProfileUuid // "-")"'
}

rollback_menu(){
  banner; need_root; install_base_packages; load_settings
  [[ -s "$STATE" ]] || die "Нет state предыдущей установки"
  PANEL_URL="$(jq -r '.panel' "$STATE")"; DOMAIN="$(jq -r '.domain' "$STATE")"; panel_auth
  NODE_UUID="$(jq -r '.nodeUuid' "$STATE")"; OLD_PROFILE_UUID="$(jq -r '.previousProfileUuid // empty' "$STATE")"; OLD_INBOUNDS="$(jq -c '.previousActiveInbounds // []' "$STATE")"
  [[ -n "$OLD_PROFILE_UUID" ]] || die "Эта Node была создана с нуля; предыдущего binding нет"
  echo "Будет восстановлен ТОЛЬКО предыдущий profile binding Node $NODE_UUID -> $OLD_PROFILE_UUID. Ничего не удаляется."
  local q; read -r -p "Введите ВЕРНУТЬ: " q; [[ "$q" == "ВЕРНУТЬ" ]] || return 0
  rollback_node_binding
}

settings_menu(){
  load_settings
  while true; do
    banner
    echo "1) Panel URL:       ${PANEL_URL:-не задан}"
    echo "2) Node domain:     ${DOMAIN:-не задан}"
    echo "3) Reality target:  $REALITY_TARGET"
    echo "4) Default scheme:  $TRANSPORT_MODE ($(mode_desc "$TRANSPORT_MODE" 2>/dev/null || echo '?'))"
    echo "0) Назад"
    local n; read -r -p "Выбор: " n
    case "$n" in
      1) read -r -p "Panel URL: " PANEL_URL; normalize_panel_url "$PANEL_URL";;
      2) read -r -p "Node domain: " DOMAIN;;
      3) read -r -p "Reality target: " REALITY_TARGET;;
      4) choose_transport;;
      0) save_settings; return 0;;
    esac
    save_settings
  done
}

selftest(){
  local oldd="$DOMAIN" oldm="$TRANSPORT_MODE" oldt="$REALITY_TARGET"
  DOMAIN="node.example.com"; REALITY_TARGET="ads.x5.ru"; TRANSPORT_MODE=7; make_names
  [[ "$PROFILE_NAME" == KOSMO-NODE-M7-* ]] || return 1
  [[ "$(xhttp_port)" == 8443 ]] || return 1
  TRANSPORT_MODE=6; [[ "$(xhttp_port)" == 443 ]] || return 1
  DOMAIN="$oldd"; TRANSPORT_MODE="$oldm"; REALITY_TARGET="$oldt"; ok "Self-test OK"
}

ci_build(){
  local m="$1" out="$2"
  DOMAIN="node.example.com"; REALITY_TARGET="ads.x5.ru"; TRANSPORT_MODE="$m"; PROFILE_DIR="$(dirname "$out")"; mkdir -p "$PROFILE_DIR"
  HYSTERIA_CERT="/opt/hysteria/certs/fullchain.pem"; HYSTERIA_KEY="/opt/hysteria/certs/privkey.pem"; make_names
  PRIVATE_KEY="${CI_PRIVATE_KEY:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA}"; PUBLIC_KEY="${CI_PUBLIC_KEY:-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB}"; SID_TCP=0123456789abcdef; SID_XHTTP=fedcba9876543210
  build_profile; cp "$PROFILE_FILE" "$out"; jq . "$out" >/dev/null
}

main_menu(){
  need_root; init_dirs; load_settings
  while true; do
    banner
    echo "1) Установить/настроить Node полностью (новый сервер ИЛИ поверх существующей)"
    echo "2) Диагностика Node — только чтение"
    echo "3) Аудит панели — только чтение"
    echo "4) Вернуть предыдущий профиль Node (без удаления объектов)"
    echo "5) Настройки"
    echo "6) Self-test скрипта"
    echo "0) Выход"
    echo
    echo "Схемы: TCP Reality | Hysteria2 | TCP+H2 | XHTTP Reality | комбинации."
    local n; read -r -p "Выбор: " n
    case "$n" in
      1) run_full_setup; pause;;
      2) doctor_readonly; pause;;
      3) panel_audit; pause;;
      4) rollback_menu; pause;;
      5) settings_menu;;
      6) selftest; pause;;
      0) exit 0;;
      *) warn "Неверный пункт"; sleep 1;;
    esac
  done
}

case "${1:-}" in
  --self-test) selftest;;
  --doctor) init_dirs; doctor_readonly;;
  --ci-build) [[ $# -eq 3 ]] || die "--ci-build MODE OUTPUT"; ci_build "$2" "$3";;
  "") main_menu;;
  *) echo "Usage: $0 [--self-test|--doctor|--ci-build MODE OUTPUT]"; exit 1;;
esac
