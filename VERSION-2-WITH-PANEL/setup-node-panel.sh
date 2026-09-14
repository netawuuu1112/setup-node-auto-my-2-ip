#!/usr/bin/env bash
set -Eeuo pipefail

VER="2.2.1-menu-safe"
PORT=443; TARGET="ads.x5.ru"; C="remnanode"
CERT="/opt/hysteria/certs/fullchain.pem"; KEY="/opt/hysteria/certs/privkey.pem"
URL="${REMNAWAVE_BASE_URL:-}"; TOKEN="${REMNAWAVE_TOKEN:-}"; DOMAIN="${NODE_DOMAIN:-}"
DIR="${HOME:-/root}/.setup-node-panel-v2"; CFG="$DIR/settings.json"; STATE="$DIR/state.json"; BK="$DIR/backups"
ok(){ echo "[OK] $*"; }; er(){ echo "[ERR] $*" >&2; }; waitx(){ read -r -p $'\nEnter...' _||true; }

need(){ for x in curl jq docker openssl getent ip timeout; do command -v "$x" >/dev/null||{ er "Нет $x"; exit 1;}; done; mkdir -p "$DIR" "$BK"; chmod 700 "$DIR" "$BK"; }
load(){ [[ -f "$CFG" ]]||return; [[ -n "$URL" ]]||URL="$(jq -r '.url//empty' "$CFG")"; [[ -n "$DOMAIN" ]]||DOMAIN="$(jq -r '.domain//empty' "$CFG")"; TARGET="$(jq -r '.target//"ads.x5.ru"' "$CFG")"; }
save(){ jq -n --arg u "$URL" --arg d "$DOMAIN" --arg t "$TARGET" '{url:$u,domain:$d,target:$t}' >"$CFG"; chmod 600 "$CFG"; }
names(){ local n; n="$(printf '%s' "${DOMAIN%%.*}"|tr '[:lower:]' '[:upper:]'|sed -E 's/[^A-Z0-9]+/-/g'|cut -c1-10)"; P="AUTO-${n}-H2R"; S="$P"; HT="${n}-HYSTERIA"; RT="${n}-REALITY"; HH="${n} Hysteria"; RH="${n} Reality"; }
ask(){ [[ -n "$URL" ]]||read -r -p "URL панели: " URL; [[ -n "$TOKEN" ]]||{ read -r -s -p "API token: " TOKEN; echo; }; [[ -n "$DOMAIN" ]]||read -r -p "Домен ноды: " DOMAIN; [[ -n "$URL"&&-n "$TOKEN"&&-n "$DOMAIN" ]]||return 1; names; save; }
base(){ local u="${URL%/}"; [[ "$u" == */api ]]&&echo "$u"||echo "$u/api"; }
auth(){ [[ "$TOKEN" == Bearer\ * ]]&&echo "$TOKEN"||echo "Bearer $TOKEN"; }
api(){ local m="$1" p="$2" b="${3:-}" f code; f="$(mktemp)"; local a=(curl -sS -o "$f" -w '%{http_code}' -X "$m" "$(base)/$p" -H "Authorization: $(auth)" -H 'Accept: application/json'); [[ -z "$b" ]]||a+=(-H 'Content-Type: application/json' --data-binary "$b"); code="$("${a[@]}"||true)"; [[ "$code" =~ ^2 ]]||{ er "API $m $p HTTP $code"; cat "$f" >&2; rm -f "$f"; return 1;}; cat "$f"; rm -f "$f"; }
get(){ api GET "$1"; }; post(){ api POST "$1" "$2"; }
fetch(){ PR="$(get config-profiles)"; HR="$(get hosts)"; SR="$(get internal-squads)"; IR="$(get config-profiles/inbounds)"; }
pa(){ echo "$PR"|jq -c '(.response//.)|(.configProfiles//[])'; }; ha(){ echo "$HR"|jq -c '(.response//.)|if type=="array" then . else (.hosts//[]) end'; }; sa(){ echo "$SR"|jq -c '(.response//.)|(.internalSquads//[])'; }; ia(){ echo "$IR"|jq -c '(.response//.)|if type=="array" then . else (.inbounds//[]) end'; }
check(){ docker ps --format '{{.Names}}'|grep -Fxq "$C"||{ er "$C не запущен"; return 1;}; docker exec "$C" test -f "$CERT"||{ er "Нет $CERT"; return 1;}; docker exec "$C" test -f "$KEY"||{ er "Нет $KEY"; return 1;}; local d i h=0 x; d="$(getent ahostsv4 "$DOMAIN"|awk '{print $1}'|sort -u)"; i="$(ip -4 -o addr show scope global|awk '{print $4}'|cut -d/ -f1)"; while read -r x; do grep -Fxq "$x"<<<"$i"&&h=1; done<<<"$d"; ((h))||{ er "DNS домена не совпадает с IP сервера"; return 1;}; timeout 5 bash -c "</dev/tcp/$TARGET/443" 2>/dev/null||{ er "$TARGET:443 недоступен"; return 1;}; ok "Проверки сервера пройдены"; }
collide(){ pa|jq -e --arg n "$P" 'any(.[];.name==$n)' >/dev/null&&return 1||true; sa|jq -e --arg n "$S" 'any(.[];.name==$n)' >/dev/null&&return 1||true; ha|jq -e --arg n "$HH" 'any(.[];.remark==$n)' >/dev/null&&return 1||true; ha|jq -e --arg n "$RH" 'any(.[];.remark==$n)' >/dev/null&&return 1||true; ia|jq -e --arg t "$HT" 'any(.[];.tag==$t)' >/dev/null&&return 1||true; ia|jq -e --arg t "$RT" 'any(.[];.tag==$t)' >/dev/null&&return 1||true; }
plan(){ ask; check; fetch; collide||{ er "Найдены совпадающие AUTO-объекты. Ничего не меняю."; return 1;}; cat <<E

=== PLAN ===
CREATE-ONLY, без удаления/обновления существующих объектов
Profile: $P
Squad:   $S
Hosts:   $HH / $RH
Hysteria UDP/443
Reality TCP/443, SNI=$TARGET, fp=chrome, flow=Vision(auto)
Рабочая Node автоматически НЕ переключается
E
}
backup(){ local d="$BK/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$d"; printf '%s' "$PR">"$d/profiles.json"; printf '%s' "$HR">"$d/hosts.json"; printf '%s' "$SR">"$d/squads.json"; printf '%s' "$IR">"$d/inbounds.json"; chmod -R go-rwx "$d"; LAST="$d"; ok "Snapshot: $d"; }
profile(){ local r; r="$(docker exec "$C" rw-core x25519 2>&1)"; PRIV="$(echo "$r"|awk -F': ' 'tolower($1)~/private/{print $2;exit}')"; PUB="$(echo "$r"|awk -F': ' 'tolower($1)~/public|password/{print $2;exit}')"; SID="$(openssl rand -hex 8)"; [[ -n "$PRIV" ]]||return 1; X="$(jq -n --arg h "$HT" --arg r "$RT" --arg c "$CERT" --arg k "$KEY" --arg t "$TARGET" --arg p "$PRIV" --arg s "$SID" '{log:{loglevel:"warning"},dns:{servers:["1.1.1.1","8.8.8.8"],queryStrategy:"UseIPv4"},inbounds:[{tag:$h,port:443,listen:"0.0.0.0",protocol:"hysteria",settings:{users:[],clients:[],version:2},streamSettings:{network:"hysteria",security:"tls",tlsSettings:{alpn:["h3"],certificates:[{keyFile:$k,certificateFile:$c}]},hysteriaSettings:{version:2}}},{tag:$r,port:443,listen:"0.0.0.0",protocol:"vless",settings:{clients:[],decryption:"none"},sniffing:{enabled:true,routeOnly:true,destOverride:["http","tls","quic"]},streamSettings:{network:"tcp",sockopt:{mark:255,tcpNoDelay:true,tcpFastOpen:true},security:"reality",tcpSettings:{header:{type:"none"},acceptProxyProtocol:false},realitySettings:{dest:($t+":443"),show:false,xver:0,spiderX:"",shortIds:[$s],privateKey:$p,serverNames:[$t]}}}],outbounds:[{tag:"DIRECT",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},{tag:"BLOCK",protocol:"blackhole"}],routing:{rules:[{type:"field",protocol:["bittorrent"],outboundTag:"BLOCK"}],domainStrategy:"IPIfNonMatch"}}')"; }
uuid(){ jq -r '(.response//.)|.uuid//empty'; }
runcreate(){ plan; local q; read -r -p "Введите СОЗДАТЬ: " q; [[ "$q" == "СОЗДАТЬ" ]]||return 0; fetch; collide||{ er "Состояние панели изменилось. Стоп."; return 1;}; backup; profile; local b r pu inb hu ru su rh hh; b="$(jq -n --arg n "$P" --argjson c "$X" '{name:$n,config:$c}')"; r="$(post config-profiles "$b")"; pu="$(echo "$r"|uuid)"; [[ -n "$pu" ]]||return 1; inb="$(get "config-profiles/$pu/inbounds")"; hu="$(echo "$inb"|jq -r --arg t "$HT" '(.response//.)|map(select(.tag==$t))[0].uuid//empty')"; ru="$(echo "$inb"|jq -r --arg t "$RT" '(.response//.)|map(select(.tag==$t))[0].uuid//empty')"; r="$(post internal-squads "$(jq -n --arg n "$S" --arg h "$hu" --arg r "$ru" '{name:$n,inbounds:[$h,$r]}')")"; su="$(echo "$r"|uuid)"; r="$(post hosts "$(jq -n --arg p "$pu" --arg i "$ru" --arg n "$RH" --arg a "$DOMAIN" --arg s "$TARGET" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$n,address:$a,port:443,sni:$s,fingerprint:"chrome",nodes:[] }')")"; rh="$(echo "$r"|uuid)"; r="$(post hosts "$(jq -n --arg p "$pu" --arg i "$hu" --arg n "$HH" --arg a "$DOMAIN" '{inbound:{configProfileUuid:$p,configProfileInboundUuid:$i},remark:$n,address:$a,port:443,sni:$a,nodes:[] }')")"; hh="$(echo "$r"|uuid)"; jq -n --arg pu "$pu" --arg hu "$hu" --arg ru "$ru" --arg su "$su" --arg rh "$rh" --arg hh "$hh" --arg pub "$PUB" --arg sid "$SID" --arg bk "$LAST" '{profileUuid:$pu,hysteriaInboundUuid:$hu,realityInboundUuid:$ru,squadUuid:$su,realityHostUuid:$rh,hysteriaHostUuid:$hh,publicKey:$pub,shortId:$sid,backup:$bk}' >"$STATE"; chmod 600 "$STATE"; ok "Создано. Node НЕ переключалась"; echo "PublicKey: $PUB"; echo "ShortID: $SID"; }
doctor(){ ask; names; ss -lntup|grep ':443' || true; docker exec "$C" cli --dump-config-raw 2>/dev/null|jq --arg h "$HT" --arg r "$RT" '[.inbounds[]|select(.tag==$h or .tag==$r)|{tag,flow:.settings.flow,network:.streamSettings.network,security:.streamSettings.security,dest:.streamSettings.realitySettings.dest}]'; }
settings(){ ask; while true; do clear||true; echo "1) Domain: $DOMAIN"; echo "2) Panel: $URL"; echo "3) Reality target: $TARGET"; echo "0) Назад"; read -r -p "Выбор: " n; case "$n" in 1) read -r -p "Domain: " DOMAIN;;2) read -r -p "Panel: " URL;;3) read -r -p "Target: " TARGET;;0) save; return;;esac; save; names; done; }
selftest(){ local d="$DOMAIN" u="$URL"; DOMAIN="pl2-kosmo-vpn.mooo.com"; URL="https://panel.example.com"; names; [[ "$P" == AUTO-PL2-KOSMO-* && "$(base)" == "https://panel.example.com/api" ]]||return 1; DOMAIN="$d"; URL="$u"; ok "Self-test OK"; }
menu(){ while true; do clear||true; cat <<E
Remnawave Node Auto Setup v2 ($VER)
1) Быстрая безопасная настройка
2) Проверка + PLAN
3) Диагностика RemnaNode
4) Настройки
5) Показать state
6) Self-test
0) Выход

Стандарт зашит: Hysteria UDP/443 + VLESS TCP Reality/443 + ads.x5.ru + chrome + Vision(auto), без SelfSteal.
E
read -r -p "Выбор: " n; case "$n" in 1) runcreate;waitx;;2) plan;waitx;;3) doctor;waitx;;4) settings;;5) [[ -f "$STATE" ]]&&jq . "$STATE"||echo "State нет";waitx;;6) selftest;waitx;;0) exit;;esac; done; }

if [[ "${1:-}" == "--self-test" ]]; then command -v jq >/dev/null||exit 1; selftest; exit; fi
need; load
case "${1:-}" in --plan) plan;;--quick) runcreate;;--doctor) doctor;;*) menu;;esac
