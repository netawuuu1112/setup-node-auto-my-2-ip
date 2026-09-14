#!/usr/bin/env bash
set -Eeuo pipefail

VER="2.3.0-menu-safe"
PORT=443
TARGET="ads.x5.ru"
CONTAINER="remnanode"
CERT="/opt/hysteria/certs/fullchain.pem"
KEY="/opt/hysteria/certs/privkey.pem"
PANEL_INPUT="${REMNAWAVE_BASE_URL:-}"
PANEL_URL=""
PANEL_COOKIE=""
TOKEN="${REMNAWAVE_TOKEN:-}"
AUTH_MODE="${REMNAWAVE_AUTH_MODE:-}"
USERNAME="${REMNAWAVE_USERNAME:-}"
DOMAIN="${NODE_DOMAIN:-}"
DIR="${HOME:-/root}/.setup-node-panel-v2"
CFG="$DIR/settings.json"
STATE="$DIR/state.json"
PLAN_FILE="$DIR/plan.json"
BK="$DIR/backups"
LOG="$DIR/setup.log"
LOCK="$DIR/run.lock"

C0='\033[0m'; CG='\033[1;32m'; CY='\033[1;33m'; CR='\033[1;31m'; CC='\033[1;36m'
ok(){ echo -e "${CG}[OK]${C0} $*"; }
info(){ echo -e "${CC}[INFO]${C0} $*"; }
warn(){ echo -e "${CY}[WARN]${C0} $*" >&2; }
er(){ echo -e "${CR}[ERR]${C0} $*" >&2; }
log(){ mkdir -p "$DIR"; printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >>"$LOG"; }
pause(){ read -r -p $'\nEnter...' _ || true; }

cleanup(){ :; }
trap cleanup EXIT
trap 'er "Ошибка на строке $LINENO. Панель автоматически не откатываю и ничего не удаляю."; log "ERROR line=$LINENO"' ERR

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { er "Запусти скрипт от root."; exit 1; }; }
check_os(){
  [[ -r /etc/os-release ]] || { er "Не найден /etc/os-release"; exit 1; }
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) :;; *) er "Поддерживаются Debian/Ubuntu. Обнаружено: ${ID:-unknown}"; exit 1;; esac
}
missing_deps(){
  local out=() x
  for x in curl jq docker openssl getent ip timeout flock sha256sum; do command -v "$x" >/dev/null 2>&1 || out+=("$x"); done
  printf '%s\n' "${out[@]:-}"
}
install_deps(){
  local m; m="$(missing_deps | sed '/^$/d' | xargs || true)"
  [[ -z "$m" ]] && { ok "Зависимости установлены"; return 0; }
  warn "Не хватает: $m"
  read -r -p "Установить недостающее через apt? [Y/n]: " a
  [[ "${a,,}" == "n" ]] && return 1
  apt-get update
  apt-get install -y curl jq docker.io openssl dnsutils iproute2 coreutils util-linux
  m="$(missing_deps | sed '/^$/d' | xargs || true)"
  [[ -z "$m" ]] || { er "После установки всё ещё не хватает: $m"; return 1; }
  ok "Зависимости готовы"
}
prepare(){
  require_root; check_os
  mkdir -p "$DIR" "$BK"; chmod 700 "$DIR" "$BK"
  touch "$LOG"; chmod 600 "$LOG"
  exec 9>"$LOCK"
  flock -n 9 || { er "Скрипт уже запущен в другом процессе."; exit 1; }
  local m; m="$(missing_deps | sed '/^$/d' | xargs || true)"
  [[ -z "$m" ]] || install_deps
}

load_settings(){
  [[ -f "$CFG" ]] || return 0
  [[ -n "$PANEL_INPUT" ]] || PANEL_INPUT="$(jq -r '.panelInput//empty' "$CFG")"
  [[ -n "$DOMAIN" ]] || DOMAIN="$(jq -r '.domain//empty' "$CFG")"
  [[ -n "$AUTH_MODE" ]] || AUTH_MODE="$(jq -r '.authMode//empty' "$CFG")"
  [[ -n "$USERNAME" ]] || USERNAME="$(jq -r '.username//empty' "$CFG")"
  TARGET="$(jq -r '.target//"ads.x5.ru"' "$CFG")"
}
save_settings(){
  jq -n --arg p "$PANEL_INPUT" --arg d "$DOMAIN" --arg a "$AUTH_MODE" --arg u "$USERNAME" --arg t "$TARGET" \
    '{panelInput:$p,domain:$d,authMode:$a,username:$u,target:$t}' >"$CFG"
  chmod 600 "$CFG"
}
parse_panel_link(){
  local in="$PANEL_INPUT" origin q pair
  [[ "$in" =~ ^https?:// ]] || { er "Ссылка панели должна начинаться с http:// или https://"; return 1; }
  origin="$(printf '%s' "$in" | sed -E 's#^(https?://[^/]+).*$#\1#')"
  PANEL_URL="$origin"
  PANEL_COOKIE=""
  if [[ "$in" == *\?* ]]; then
    q="${in#*\?}"; pair="${q%%&*}"
    if [[ "$pair" == *=* && -n "${pair%%=*}" && -n "${pair#*=}" ]]; then
      PANEL_COOKIE="$pair"
    fi
  fi
}
base(){ echo "${PANEL_URL%/}/api"; }
auth_header(){ [[ "$TOKEN" == Bearer\ * ]] && echo "$TOKEN" || echo "Bearer $TOKEN"; }

curl_common(){
  local -n arr=$1
  arr=(curl -sS --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 1 --retry-connrefused \
      -H 'Accept: application/json' -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
      -H 'X-Remnawave-Client-Type: browser')
  [[ -z "$PANEL_COOKIE" ]] || arr+=(-H "Cookie: $PANEL_COOKIE")
}
raw_request(){
  local method="$1" path="$2" body="${3:-}" use_auth="${4:-yes}" f code
  [[ "$method" == GET || "$method" == POST ]] || { er "Безопасность: метод $method запрещён. Разрешены только GET/POST."; return 1; }
  f="$(mktemp)"
  local a; curl_common a
  a+=(-o "$f" -w '%{http_code}' -X "$method" "$(base)/$path")
  if [[ "$use_auth" == yes ]]; then
    [[ -n "$TOKEN" ]] || { rm -f "$f"; er "Нет токена сессии"; return 1; }
    a+=(-H "Authorization: $(auth_header)")
  fi
  [[ -z "$body" ]] || a+=(-H 'Content-Type: application/json' --data-binary "$body")
  code="$("${a[@]}" 2>>"$LOG" || true)"
  if [[ ! "$code" =~ ^2 ]]; then
    er "HTTP $code: $method /api/$path"
    jq . "$f" 2>/dev/null || cat "$f" >&2
    rm -f "$f"
    return 1
  fi
  cat "$f"; rm -f "$f"
}
get(){ raw_request GET "$1"; }
post(){ raw_request POST "$1" "$2"; }

choose_auth(){
  [[ "$AUTH_MODE" == api || "$AUTH_MODE" == login ]] && return 0
  echo
  echo "Доступ к панели:"
  echo "1) API token (рекомендуется для постоянной автоматизации)"
  echo "2) Логин + пароль панели (временный JWT, пароль не сохраняется)"
  read -r -p "Выбор [2]: " a
  case "${a:-2}" in 1) AUTH_MODE=api;;2) AUTH_MODE=login;;*) er "Неверный выбор"; return 1;;esac
}
authenticate(){
  parse_panel_link
  choose_auth
  if [[ "$AUTH_MODE" == api ]]; then
    [[ -n "$TOKEN" ]] || { read -r -s -p "API token: " TOKEN; echo; }
  else
    [[ -n "$USERNAME" ]] || read -r -p "Логин панели: " USERNAME
    local pw body r
    read -r -s -p "Пароль панели: " pw; echo
    body="$(jq -n --arg u "$USERNAME" --arg p "$pw" '{username:$u,password:$p}')"
    r="$(raw_request POST auth/login "$body" no)" || { pw=""; return 1; }
    TOKEN="$(echo "$r" | jq -r '.response.accessToken // .accessToken // empty')"
    pw=""
    [[ -n "$TOKEN" ]] || { er "Панель не вернула accessToken. Возможно, вход по паролю отключён."; return 1; }
  fi
  local test
  test="$(get config-profiles)" || { TOKEN=""; er "Авторизация не прошла проверку GET /config-profiles"; return 1; }
  echo "$test" | jq -e '(.response.configProfiles // .configProfiles // []) | type=="array"' >/dev/null || { er "Неожиданный ответ панели"; return 1; }
  ok "Авторизация панели работает (${AUTH_MODE})"
  [[ -z "$PANEL_COOKIE" ]] || info "Используется cookie-защита из ссылки входа (eGames-совместимо)"
  save_settings
}
ensure_inputs(){
  [[ -n "$PANEL_INPUT" ]] || read -r -p "Ссылка панели (можно полную ссылку входа eGames): " PANEL_INPUT
  [[ -n "$DOMAIN" ]] || read -r -p "Домен этой ноды: " DOMAIN
  [[ -n "$PANEL_INPUT" && -n "$DOMAIN" ]] || { er "Нужны ссылка панели и домен ноды"; return 1; }
  names; authenticate
}

names(){
  local n
  n="$(printf '%s' "${DOMAIN%%.*}" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | cut -c1-12)"
  [[ -n "$n" ]] || n="NODE"
  PROFILE="AUTO-${n}-H2R"; SQUAD="$PROFILE"; HT="${n}-HYSTERIA"; RT="${n}-REALITY"; HH="${n} Hysteria"; RH="${n} Reality"
}

server_check(){
  docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER" || { er "Контейнер $CONTAINER не запущен"; return 1; }
  docker exec "$CONTAINER" test -f "$CERT" || { er "Не найден $CERT"; return 1; }
  docker exec "$CONTAINER" test -f "$KEY" || { er "Не найден $KEY"; return 1; }
  local d i hit=0 x
  d="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)"
  i="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | sort -u)"
  [[ -n "$d" ]] || { er "Домен $DOMAIN не имеет IPv4 A-записи"; return 1; }
  while read -r x; do [[ -z "$x" ]] || grep -Fxq "$x" <<<"$i" && hit=1; done <<<"$d"
  ((hit)) || { er "DNS $DOMAIN не совпадает ни с одним IPv4 этого сервера"; echo "DNS: $d"; echo "Server: $i"; return 1; }
  timeout 5 bash -c "</dev/tcp/$TARGET/443" 2>/dev/null || { er "$TARGET:443 недоступен"; return 1; }
  ok "Сервер, DNS, сертификаты и Reality target проверены"
}

fetch_panel(){
  PR="$(get config-profiles)"
  HR="$(get hosts)"
  SR="$(get internal-squads)"
  NR="$(get nodes)"
  IR="$(get config-profiles/inbounds)"
}
pa(){ echo "$PR" | jq -c '(.response//.)|(.configProfiles//[])'; }
ha(){ echo "$HR" | jq -c '(.response//.)|if type=="array" then . else (.hosts//[]) end'; }
sa(){ echo "$SR" | jq -c '(.response//.)|(.internalSquads//[])'; }
na(){ echo "$NR" | jq -c '(.response//.)|if type=="array" then . else (.nodes//[]) end'; }
ia(){ echo "$IR" | jq -c '(.response//.)|if type=="array" then . else (.inbounds//[]) end'; }

collisions(){
  local out=()
  pa | jq -e --arg n "$PROFILE" 'any(.[];.name==$n)' >/dev/null && out+=("profile:$PROFILE") || true
  sa | jq -e --arg n "$SQUAD" 'any(.[];.name==$n)' >/dev/null && out+=("squad:$SQUAD") || true
  ha | jq -e --arg n "$HH" 'any(.[];.remark==$n)' >/dev/null && out+=("host:$HH") || true
  ha | jq -e --arg n "$RH" 'any(.[];.remark==$n)' >/dev/null && out+=("host:$RH") || true
  ia | jq -e --arg t "$HT" 'any(.[];.tag==$t)' >/dev/null && out+=("inbound:$HT") || true
  ia | jq -e --arg t "$RT" 'any(.[];.tag==$t)' >/dev/null && out+=("inbound:$RT") || true
  if ((${#out[@]})); then printf '%s\n' "${out[@]}"; return 1; fi
}
panel_fingerprint(){
  { printf '%s' "$PR"; printf '%s' "$HR"; printf '%s' "$SR"; printf '%s' "$NR"; printf '%s' "$IR"; } | sha256sum | awk '{print $1}'
}
write_plan(){
  local fp="$1"
  jq -n --arg fp "$fp" --arg d "$DOMAIN" --arg p "$PROFILE" --arg s "$SQUAD" --arg hh "$HH" --arg rh "$RH" --arg ht "$HT" --arg rt "$RT" --arg t "$TARGET" \
    '{fingerprint:$fp,domain:$d,profile:$p,squad:$s,hysteriaHost:$hh,realityHost:$rh,hysteriaTag:$ht,realityTag:$rt,target:$t,createdAt:(now|todate)}' >"$PLAN_FILE"
  chmod 600 "$PLAN_FILE"
}
plan(){
  ensure_inputs; server_check; fetch_panel
  local c fp
  if ! c="$(collisions)"; then er "Найдены совпадения. Ничего не меняю:"; echo "$c" >&2; return 1; fi
  fp="$(panel_fingerprint)"; write_plan "$fp"
  cat <<E

=== SAFE PLAN ===
Режим: CREATE-ONLY
Панель сейчас НЕ изменяется.
Удаление: ЗАПРЕЩЕНО
PATCH/обновление существующих объектов: ЗАПРЕЩЕНО
Переключение рабочей Node: ЗАПРЕЩЕНО

Profile:  $PROFILE
Squad:    $SQUAD
Hosts:    $HH / $RH
Hysteria: UDP/443
Reality:  TCP/443, SNI=$TARGET, fp=chrome, Vision(auto)

PLAN fingerprint: $fp
E
  ok "PLAN сохранён: $PLAN_FILE"
}

backup(){
  local d="$BK/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$d"; chmod 700 "$d"
  printf '%s' "$PR" >"$d/profiles.json"; printf '%s' "$HR" >"$d/hosts.json"; printf '%s' "$SR" >"$d/squads.json"; printf '%s' "$NR" >"$d/nodes.json"; printf '%s' "$IR" >"$d/inbounds.json"
  (cd "$d" && sha256sum *.json > SHA256SUMS)
  chmod -R go-rwx "$d"; LAST_BACKUP="$d"; ok "Snapshot: $d"
}
generate_profile(){
  local r
  r="$(docker exec "$CONTAINER" rw-core x25519 2>&1)" || return 1
  PRIV="$(echo "$r" | awk -F': ' 'tolower($1)~/private/{print $2;exit}')"
  PUB="$(echo "$r" | awk -F': ' 'tolower($1)~/public|password/{print $2;exit}')"
  SID="$(openssl rand -hex 8)"
  [[ -n "$PRIV" ]] || { er "Не удалось получить Reality PrivateKey"; return 1; }
  PROFILE_JSON="$(jq -n --arg h "$HT" --arg r "$RT" --arg c "$CERT" --arg k "$KEY" --arg t "$TARGET" --arg p "$PRIV" --arg s "$SID" '{log:{loglevel:"warning"},dns:{servers:["1.1.1.1","8.8.8.8"],queryStrategy:"UseIPv4"},inbounds:[{tag:$h,port:443,listen:"0.0.0.0",protocol:"hysteria",settings:{users:[],clients:[],version:2},streamSettings:{network:"hysteria",security:"tls",tlsSettings:{alpn:["h3"],certificates:[{keyFile:$k,certificateFile:$c}]},hysteriaSettings:{version:2}}},{tag:$r,port:443,listen:"0.0.0.0",protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,routeOnly:true,destOverride:["http","tls","quic"]},streamSettings:{network:"tcp",sockopt:{mark:255,tcpNoDelay:true,tcpFastOpen:true},security:"reality",tcpSettings:{header:{type:"none"},acceptProxyProtocol:false},realitySettings:{dest:($t+":443"),show:false,xver:0,spiderX:"",shortIds:[$s],privateKey:$p,serverNames:[$t]}}}],outbounds:[{tag:"DIRECT",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}],domainStrategy:"IPIfNonMatch"}}')"
}
uuid(){ jq -r '(.response//.)|.uuid//empty'; }
init_journal(){
  jq -n --arg v "$VER" --arg d "$DOMAIN" --arg b "$LAST_BACKUP" '{version:$v,domain:$d,backup:$b,status:"started",created:{}}' >"$STATE"; chmod 600 "$STATE"
}
record_uuid(){ local k="$1" v="$2"; jq --arg k "$k" --arg v "$v" '.created[$k]=$v' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"; chmod 600 "$STATE"; }
finish_journal(){ jq --arg pub "$PUB" --arg sid "$SID" '.status="complete"|.publicKey=$pub|.shortId=$sid' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"; chmod 600 "$STATE"; }

execute_create(){
  plan
  echo
  warn "Будут только СОЗДАНЫ новые объекты. Существующие объекты не изменяются."
  local q; read -r -p "Для продолжения введи СОЗДАТЬ: " q
  [[ "$q" == "СОЗДАТЬ" ]] || { info "Отменено. Панель не изменялась."; return 0; }
  fetch_panel
  local c fp oldfp
  if ! c="$(collisions)"; then er "После PLAN появились совпадения. STOP:"; echo "$c" >&2; return 1; fi
  fp="$(panel_fingerprint)"; oldfp="$(jq -r '.fingerprint//empty' "$PLAN_FILE" 2>/dev/null || true)"
  [[ -n "$oldfp" && "$fp" == "$oldfp" ]] || { er "Состояние панели изменилось после PLAN. Запусти PLAN заново."; return 1; }
  backup; generate_profile; init_journal

  local body r pu inb hu ru su rh hh
  body="$(jq -n --arg n "$PROFILE" --argjson c "$PROFILE_JSON" '{name:$n,config:$c}')"
  r="$(post config-profiles "$body")"; pu="$(echo "$r"|uuid)"; [[ -n "$pu" ]] || { er "Не получен UUID Profile"; return 1; }; record_uuid profileUuid "$pu"
  inb="$(get "config-profiles/$pu/inbounds")"
  hu="$(echo "$inb"|jq -r --arg t "$HT" '(.response//.)|map(select(.tag==$t))[0].uuid//empty')"
  ru="$(echo "$inb"|jq -r --arg t "$RT" '(.response//.)|map(select(.tag==$t))[0].uuid//empty')"
  [[ -n "$hu" && -n "$ru" ]] || { er "Панель не вернула оба inbound UUID. Ничего не удаляю; см. $STATE"; return 1; }
  record_uuid hysteriaInboundUuid "$hu"; record_uuid realityInboundUuid "$ru"

  r="$(post internal-squads "$(jq -n --arg n "$SQUAD" --arg h "$hu" --arg r "$ru" '{name:$n,inbounds:[$h,$r]}')")"; su="$(echo "$r"|uuid)"; [[ -n "$su" ]] || return 1; record_uuid squadUuid "$su"

  r="$(post hosts "$(jq -n --arg p "$pu" --arg i "$ru" --arg n "$RH" --arg a "$DOMAIN" --arg s "$TARGET" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$n,address:$a,port:443,sni:$s,fingerprint:"chrome",nodes:[],isDisabled:false,isHidden:false}')")"; rh="$(echo "$r"|uuid)"; [[ -n "$rh" ]] || return 1; record_uuid realityHostUuid "$rh"

  r="$(post hosts "$(jq -n --arg p "$pu" --arg i "$hu" --arg n "$HH" --arg a "$DOMAIN" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$n,address:$a,port:443,sni:$a,nodes:[],isDisabled:false,isHidden:false}')")"; hh="$(echo "$r"|uuid)"; [[ -n "$hh" ]] || return 1; record_uuid hysteriaHostUuid "$hh"

  finish_journal
  ok "Создание завершено. Рабочая Node НЕ переключалась."
  echo "PublicKey: $PUB"
  echo "ShortID:   $SID"
  echo "State:     $STATE"
  info "Следующий шаг вручную/отдельным безопасным режимом — назначение профиля ноде после проверки."
}

panel_audit(){
  ensure_inputs; fetch_panel
  echo "=== READ-ONLY PANEL AUDIT ==="
  echo "Profiles: $(pa|jq 'length')"
  echo "Hosts:    $(ha|jq 'length')"
  echo "Squads:   $(sa|jq 'length')"
  echo "Nodes:    $(na|jq 'length')"
  local c
  if c="$(collisions)"; then ok "Конфликтов с AUTO-именами нет"; else warn "Есть совпадения:"; echo "$c"; fi
}
doctor(){
  [[ -n "$DOMAIN" ]] && names || true
  echo "=== LOCAL REMNANODE DOCTOR ==="
  docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|remnanode' || true
  ss -lntup | grep ':443' || true
  if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER"; then
    docker exec "$CONTAINER" rw-core version 2>/dev/null | head -n1 || true
    docker exec "$CONTAINER" cli --dump-config-raw 2>/dev/null | jq '[.inbounds[]|select(.protocol=="hysteria" or (.protocol=="vless" and .streamSettings.security=="reality"))|{tag,protocol,flow:.settings.flow,network:.streamSettings.network,security:.streamSettings.security,dest:.streamSettings.realitySettings.dest}]' || true
  fi
}
show_state(){ [[ -f "$STATE" ]] && jq . "$STATE" || info "State ещё не создан"; }

settings_menu(){
  while true; do
    clear || true
    echo "=== НАСТРОЙКИ ==="
    echo "1) Ссылка панели: ${PANEL_INPUT:-<не задана>}"
    echo "2) Домен ноды:   ${DOMAIN:-<не задан>}"
    echo "3) Авторизация:  ${AUTH_MODE:-<выбрать автоматически>}"
    echo "4) Логин:        ${USERNAME:-<не задан>}"
    echo "5) Reality SNI:  $TARGET"
    echo "6) Сбросить секрет текущей сессии"
    echo "0) Назад"
    read -r -p "Выбор: " n
    case "$n" in
      1) read -r -p "Ссылка панели (можно auth/login?COOKIE=VALUE): " PANEL_INPUT; TOKEN="";;
      2) read -r -p "Домен ноды: " DOMAIN;;
      3) AUTH_MODE=""; choose_auth; TOKEN="";;
      4) read -r -p "Логин панели: " USERNAME; TOKEN="";;
      5) read -r -p "Reality target/SNI [$TARGET]: " x; TARGET="${x:-$TARGET}";;
      6) TOKEN=""; ok "Токен текущей сессии очищен";;
      0) save_settings; return;;
    esac
    [[ -n "$DOMAIN" ]] && names || true
    save_settings
  done
}
connection_setup(){ ensure_inputs; ok "Подключение к панели настроено. Секреты на диск не сохраняются."; }
selftest(){
  local d="$DOMAIN" pi="$PANEL_INPUT" pu="$PANEL_URL" pc="$PANEL_COOKIE" u="$USERNAME" a="$AUTH_MODE"
  DOMAIN="pl2-kosmo-vpn.mooo.com"; PANEL_INPUT="https://panel.example.com/auth/login?abc=xyz"; names; parse_panel_link
  [[ "$PROFILE" == AUTO-PL2-KOSMO-VP-H2R && "$PANEL_URL" == "https://panel.example.com" && "$PANEL_COOKIE" == "abc=xyz" ]] || { er "Self-test failed"; return 1; }
  DOMAIN="$d"; PANEL_INPUT="$pi"; PANEL_URL="$pu"; PANEL_COOKIE="$pc"; USERNAME="$u"; AUTH_MODE="$a"
  ok "Self-test OK"
}
menu(){
  while true; do
    clear || true
    cat <<E
Remnawave Node Auto Setup v2 ($VER)

1) Быстрая безопасная настройка
2) Проверка + PLAN (только чтение)
3) Настроить/проверить доступ к панели
4) Диагностика RemnaNode (только чтение)
5) Аудит панели (только чтение)
6) Последняя транзакция / созданные UUID
7) Настройки
8) Self-test
0) Выход

Зашито: Hysteria UDP/443 + VLESS TCP Reality/443 + $TARGET + chrome + Vision(auto), без SelfSteal.
Безопасность: только GET/POST; PATCH/DELETE запрещены; рабочая Node автоматически не переключается.
E
    read -r -p "Выбор: " n
    case "$n" in
      1) execute_create; pause;;
      2) plan; pause;;
      3) connection_setup; pause;;
      4) doctor; pause;;
      5) panel_audit; pause;;
      6) show_state; pause;;
      7) settings_menu;;
      8) selftest; pause;;
      0) exit 0;;
      *) warn "Неверный пункт"; pause;;
    esac
  done
}

if [[ "${1:-}" == "--self-test" ]]; then
  command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }
  selftest; exit
fi
prepare
load_settings
case "${1:-}" in
  --plan) plan;;
  --quick) execute_create;;
  --doctor) doctor;;
  --audit) panel_audit;;
  *) menu;;
esac
