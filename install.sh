#!/usr/bin/env bash
# =============================================================================
#  AntiBS2vpn — интерактивный установщик «с нуля до запуска».
#
#  Одной командой (на чистом Ubuntu 22.04+/Debian 11+ под root):
#    bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/install.sh)
#
#  Флаги:
#    --dir DIR            каталог установки (по умолчанию /opt/AntiBS2vpn)
#    --branch BR          ветка git (main)
#    --repo URL           git-репозиторий
#    --token TOKEN        GitHub-токен для приватного репозитория бота (или env GITHUB_TOKEN)
#    --env-file FILE      файл KEY=VALUE с ответами (для неинтерактивного режима)
#    -y|--yes             неинтерактивно: брать значения из --env-file/окружения/по умолчанию
#    --restore FILE       восстановить БД из бэкапа (*.zip бота, full-backup *.zip или db.dump)
#    --no-caddy           не настраивать Caddy/HTTPS
#    --check              только проверить работу уже установленного бота
#    -h|--help            справка
#  Повторный запуск безопасен: существующие .env читаются, значения предлагаются по умолчанию.
# =============================================================================
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/samur005/AntiBS2vpn-bot.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/opt/AntiBS2vpn}"
PROXY_DIR="${PROXY_DIR:-/opt/antibs-proxy}"
NET="antibs2vpn"
ENV_FILE_IN=""
ASSUME_YES=0
RESTORE_FILE=""
USE_CADDY=1
ONLY_CHECK=0
GH_TOKEN_VAL="${GITHUB_TOKEN:-}"
TOKEN_FILE="/etc/antibs2vpn/github_token"

c_g=$'\e[1;32m'; c_y=$'\e[1;33m'; c_r=$'\e[1;31m'; c_b=$'\e[1;36m'; c_0=$'\e[0m'
log()  { printf '%s[+]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$c_r" "$c_0" "$*" >&2; }
step() { printf '\n%s==== %s ====%s\n' "$c_b" "$*" "$c_0"; }
die()  { err "$*"; exit 1; }
trap 'err "Ошибка в строке $LINENO: $BASH_COMMAND"' ERR

usage() { sed -n '2,20p' "$0" 2>/dev/null || true; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) APP_DIR="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --repo) REPO_URL="$2"; shift 2;;
    --token) GH_TOKEN_VAL="$2"; shift 2;;
    --env-file) ENV_FILE_IN="$2"; shift 2;;
    -y|--yes) ASSUME_YES=1; shift;;
    --restore) RESTORE_FILE="$(readlink -f "$2")"; shift 2;;
    --no-caddy) USE_CADDY=0; shift;;
    --check) ONLY_CHECK=1; shift;;
    -h|--help) usage;;
    *) die "Неизвестный параметр: $1 (см. --help)";;
  esac
done
CAB_DIR="$APP_DIR/AntiBS2vpn-cabinet"

# --- ввод с терминала (скрипт может быть запущен через curl | bash) ----------
TTY=/dev/tty
if [ "$ASSUME_YES" = 0 ] && ! { : <"$TTY"; } 2>/dev/null; then
  warn "Нет терминала — включаю неинтерактивный режим (-y)."; ASSUME_YES=1
fi
read_tty() { local __v; IFS= read -r ${2:+-s} __v <"$TTY" || true; [ -n "${2:-}" ] && echo >"$TTY"; printf '%s' "$__v"; }

confirm() { # confirm "вопрос" [default y|n]
  local def="${2:-n}" a
  [ "$ASSUME_YES" = 1 ] && { [ "$def" = y ]; return; }
  printf '%s [%s]: ' "$1" "$([ "$def" = y ] && echo Д/н || echo д/Н)" >"$TTY"
  a="$(read_tty)"; a="${a:-$def}"
  [[ "$a" =~ ^([YyДд]|yes|да|Да)$ ]]
}

# --- хранение ответов ----------------------------------------------------------
declare -A V=()
env_get() { [ -f "$1" ] && grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- | tr -d '\r' || true; }
load_env_into_V() { # файл
  [ -f "$1" ] || return 0
  local k v
  while IFS= read -r line; do
    [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
    k="${line%%=*}"; v="${line#*=}"; v="${v%$'\r'}"
    v="${v#\"}"; v="${v%\"}"
    [ -n "$v" ] && V[$k]="$v"
  done <"$1"
}

# ask VAR "подсказка" "default" validator [secret] [optional]
ask() {
  local var="$1" prompt="$2" def="${3:-}" val="${4:-}" secret="${5:-}" optional="${6:-}" ans shown
  [ -n "${V[$var]:-}" ] && def="${V[$var]}"
  [ -n "${!var:-}" ] 2>/dev/null && def="${!var}"
  while :; do
    if [ "$ASSUME_YES" = 1 ]; then
      ans="$def"
    else
      shown="$def"; [ -n "$secret" ] && [ -n "$def" ] && shown="(сохранено, Enter — оставить)"
      printf '%s%s%s%s: ' "$c_b" "$prompt" "$c_0" "${shown:+ [$shown]}" >"$TTY"
      ans="$(read_tty "" ${secret:+s})"; ans="${ans:-$def}"
    fi
    if [ -z "$ans" ]; then
      [ -n "$optional" ] && { V[$var]=""; return 0; }
      [ "$ASSUME_YES" = 1 ] && die "Не задано обязательное значение $var (передайте через --env-file)"
      warn "Значение обязательно."; continue
    fi
    if [ -n "$val" ] && ! "$val" "$ans"; then
      [ "$ASSUME_YES" = 1 ] && die "$var: значение не прошло проверку"
      confirm "Значение не прошло проверку. Всё равно использовать?" n || continue
    fi
    V[$var]="$ans"; return 0
  done
}

gen_secret() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}" || true; }

# --- валидаторы ------------------------------------------------------------------
BOT_USER_FROM_API=""
v_token() {
  [[ "$1" =~ ^[0-9]{5,12}:[A-Za-z0-9_-]{30,}$ ]] || { warn "Формат токена: 123456789:AA..."; return 1; }
  local r; r="$(curl -fsS -m 15 "https://api.telegram.org/bot$1/getMe" 2>/dev/null || true)"
  if [[ "$r" == *'"ok":true'* ]]; then
    BOT_USER_FROM_API="$(sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<<"$r")"
    log "Токен рабочий: @$BOT_USER_FROM_API"; return 0
  fi
  warn "Telegram getMe не принял токен (или нет доступа к api.telegram.org)."; return 1
}
v_ids()  { [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]] || { warn "Нужны числовые ID через запятую (узнать: @userinfobot)"; return 1; }; }
v_int()  { [[ "$1" =~ ^[0-9]+$ ]] || { warn "Нужно целое число"; return 1; }; }
v_bool() { [[ "$1" =~ ^(true|false)$ ]] || { warn "true или false"; return 1; }; }
v_url()  {
  [[ "$1" =~ ^https?://[^[:space:]]+$ ]] || { warn "Нужен URL вида https://..."; return 1; }
  curl -ksS -o /dev/null -m 10 "$1" 2>/dev/null || { warn "URL $1 недоступен с этого сервера"; return 1; }
}
v_suburl() { [[ "$1" == http*'{uuid}'* ]] || { warn "Шаблон должен содержать {uuid}, напр. https://sub.example.com/s/{uuid}"; return 1; }; }
SERVER_IP=""
v_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { warn "Нужен домен вида app.example.com"; return 1; }
  local ips; ips="$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  [ -n "$ips" ] || { warn "$1 не резолвится. Создайте A-запись на $SERVER_IP"; return 1; }
  [[ " $ips " == *" $SERVER_IP "* ]] || { warn "$1 → $ips, а IP сервера $SERVER_IP (если Cloudflare-proxy — выключите его на время выпуска сертификата)"; return 1; }
}

# --- 1. окружение --------------------------------------------------------------
check_system() {
  step "Проверка системы"
  [ "$(id -u)" = 0 ] || die "Запустите от root (sudo -i)."
  . /etc/os-release 2>/dev/null || die "Не удалось определить ОС"
  case "${ID:-}${ID_LIKE:-}" in *ubuntu*|*debian*) log "ОС: $PRETTY_NAME";; *) warn "ОС $PRETTY_NAME не тестировалась (нужен Debian/Ubuntu)"; confirm "Продолжить?" n || exit 1;; esac
  local mem; mem="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
  [ "$mem" -ge 900 ] || warn "ОЗУ ${mem}MB — рекомендуется ≥1GB (сборка образов может упасть). Добавлю swap при необходимости."
  if [ "$mem" -lt 1500 ] && ! swapon --show | grep -q .; then
    log "Создаю swap 2G"; { fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048; } 2>/dev/null
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  fi
  local free; free="$(df -Pm / | awk 'NR==2{print $4}')"
  [ "$free" -ge 3000 ] || warn "Свободно ${free}MB на / — нужно ≥3GB"
}

install_deps() {
  step "Установка зависимостей"
  local need=()
  for b in curl git openssl unzip tar cron; do command -v "$b" >/dev/null 2>&1 || need+=("$b"); done
  command -v crontab >/dev/null 2>&1 || need+=(cron)
  command -v getent >/dev/null 2>&1 || need+=(libc-bin)
  if [ ${#need[@]} -gt 0 ]; then
    log "apt install: ${need[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq "${need[@]}" ca-certificates >/dev/null
  fi
  if ! command -v docker >/dev/null 2>&1; then
    log "Устанавливаю Docker (get.docker.com)"
    curl -fsSL https://get.docker.com | sh >/dev/null || die "Не удалось установить Docker"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    log "Устанавливаю docker compose plugin"
    apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh >/dev/null
    docker compose version >/dev/null 2>&1 || die "docker compose недоступен"
  fi
  if ! docker info >/dev/null 2>&1; then
    warn "Docker не запущен — запускаю"; systemctl enable --now docker >/dev/null 2>&1 || service docker start || true
    sleep 3; docker info >/dev/null 2>&1 || die "Docker не стартует: journalctl -u docker -n 50"
  fi
  log "Docker $(docker version --format '{{.Server.Version}}'), $(docker compose version --short)"
  SERVER_IP="$(curl -4 -fsS -m 10 https://api.ipify.org 2>/dev/null || curl -4 -fsS -m 10 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
  log "Внешний IP сервера: $SERVER_IP"
}

# git с токеном: заголовок передаётся только в окружении этой команды,
# в .git/config и URL remote токен не попадает.
git_auth() {
  if [ -n "$GH_TOKEN_VAL" ]; then
    local b; b="$(printf 'x-access-token:%s' "$GH_TOKEN_VAL" | base64 -w0)"
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraHeader" \
      GIT_CONFIG_VALUE_0="Authorization: Basic $b" git "$@"
  else
    GIT_TERMINAL_PROMPT=0 git "$@"
  fi
}

get_token() {
  [ -z "$GH_TOKEN_VAL" ] && [ -f "$TOKEN_FILE" ] && GH_TOKEN_VAL="$(cat "$TOKEN_FILE")"
  if git_auth ls-remote -q "$REPO_URL" HEAD >/dev/null 2>&1; then return 0; fi
  [ "$ASSUME_YES" = 1 ] && die "Нет доступа к $REPO_URL. Передайте --token или GITHUB_TOKEN (см. README установщика)"
  echo "Репозиторий бота приватный. Нужен GitHub fine-grained токен (Contents: Read-only)." >"$TTY"
  while :; do
    printf '%sGitHub-токен (ввод скрыт)%s: ' "$c_b" "$c_0" >"$TTY"
    GH_TOKEN_VAL="$(read_tty "" s)"
    [ -n "$GH_TOKEN_VAL" ] || continue
    git_auth ls-remote -q "$REPO_URL" HEAD >/dev/null 2>&1 && { log "Доступ к репозиторию есть"; break; }
    warn "Токен не дал доступ к $REPO_URL (проверьте срок действия и выбранный репозиторий)"
  done
  if [ ! -f "$TOKEN_FILE" ] && confirm "Сохранить токен в $TOKEN_FILE (root, 600) для update.sh?" y; then
    mkdir -p "$(dirname "$TOKEN_FILE")"; chmod 700 "$(dirname "$TOKEN_FILE")"
    ( umask 077; printf '%s' "$GH_TOKEN_VAL" >"$TOKEN_FILE" )
  fi
}

fetch_code() {
  step "Код бота → $APP_DIR"
  get_token
  if [ -d "$APP_DIR/.git" ]; then
    log "Репозиторий уже есть — обновляю"
    git -C "$APP_DIR" remote set-url origin "$REPO_URL"
    git_auth -C "$APP_DIR" fetch -q origin "$BRANCH" && git -C "$APP_DIR" merge -q --ff-only "origin/$BRANCH" \
      || warn "git pull не удался (локальные правки?) — продолжаю с текущим кодом"
  elif [ -f "$APP_DIR/docker-compose.yml" ]; then
    warn "$APP_DIR существует без git — использую как есть"
  else
    mkdir -p "$(dirname "$APP_DIR")"
    git_auth clone -q -b "$BRANCH" "$REPO_URL" "$APP_DIR" || die "git clone $REPO_URL не удался"
  fi
  mkdir -p "$APP_DIR/backups"
}

# Из full-бэкапа (zip с code.tgz) берём старые .env бота и кабинета, чтобы не вводить всё заново.
preload_env_from_backup() {
  [ -n "$RESTORE_FILE" ] || return 0
  [ -f "$RESTORE_FILE" ] || die "Нет файла бэкапа $RESTORE_FILE"
  case "$RESTORE_FILE" in *.zip) ;; *) return 0;; esac
  unzip -l "$RESTORE_FILE" 2>/dev/null | grep -q ' code.tgz$' || return 0
  step "Чтение .env из бэкапа"
  local tmp; tmp="$(mktemp -d)"
  unzip -qo "$RESTORE_FILE" code.tgz -d "$tmp"
  tar xzf "$tmp/code.tgz" -C "$tmp" ./.env ./AntiBS2vpn-cabinet/.env 2>/dev/null || true
  local src dst
  for src in .env AntiBS2vpn-cabinet/.env; do
    dst="$APP_DIR/$src"; [ -s "$tmp/$src" ] || continue
    if [ -f "$dst" ] && ! confirm "Заменить текущий $dst значениями из бэкапа?" y; then continue; fi
    [ -f "$dst" ] && cp -p "$dst" "$dst.bak.$(date +%s)"
    install -m 600 "$tmp/$src" "$dst"; log "$src восстановлен из бэкапа"
  done
  if docker volume inspect antibs2vpn_bot_postgres_data >/dev/null 2>&1; then
    warn "Том БД уже существует: если пароль БД в бэкапе другой, бот не подключится."
    if confirm "Удалить текущий том БД (данные в нём будут заменены бэкапом)?" n; then
      (cd "$APP_DIR" && docker compose down -v) >/dev/null 2>&1 || docker volume rm -f antibs2vpn_bot_postgres_data >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$tmp"
}

# --- 2. вопросы ----------------------------------------------------------------
collect() {
  step "Настройки (Enter — значение по умолчанию в [скобках])"
  load_env_into_V "$APP_DIR/.env"
  load_env_into_V "$CAB_DIR/.env"
  [ -n "$ENV_FILE_IN" ] && { [ -f "$ENV_FILE_IN" ] || die "Нет файла $ENV_FILE_IN"; load_env_into_V "$ENV_FILE_IN"; }
  if [ -f "$APP_DIR/.env" ]; then
    log "Найден существующий $APP_DIR/.env"
    if confirm "Оставить текущие значения без вопросов (спрашивать только недостающие)?" y; then KEEP=1; else KEEP=0; fi
  else KEEP=0; fi

  q() { if [ "$KEEP" = 1 ] && [ -n "${V[$1]:-}" ]; then return 0; fi; ask "$@"; }

  echo "— Telegram —" >"$TTY" 2>/dev/null || true
  q BOT_TOKEN "Токен бота от @BotFather" "" v_token s
  [ -z "${V[BOT_USERNAME]:-}" ] && [ -n "$BOT_USER_FROM_API" ] && V[BOT_USERNAME]="$BOT_USER_FROM_API"
  if [ -z "${V[BOT_USERNAME]:-}" ]; then v_token "${V[BOT_TOKEN]}" >/dev/null 2>&1 || true; V[BOT_USERNAME]="$BOT_USER_FROM_API"; fi
  q BOT_USERNAME "Username бота без @" "${V[BOT_USERNAME]:-}"
  q ADMIN_IDS "Telegram ID админов через запятую" "" v_ids

  echo "— База данных (пароль сгенерирован) —" >"$TTY" 2>/dev/null || true
  V[POSTGRES_HOST]="postgres"; V[POSTGRES_PORT]="5432"
  V[POSTGRES_DB]="${V[POSTGRES_DB]:-vpn_bot}"; V[POSTGRES_USER]="${V[POSTGRES_USER]:-vpn_bot}"
  if [ -z "${V[POSTGRES_PASSWORD]:-}" ] || [ "${V[POSTGRES_PASSWORD]}" = change_me ]; then
    if docker volume inspect antibs2vpn_bot_postgres_data >/dev/null 2>&1; then
      warn "Том БД antibs2vpn_bot_postgres_data уже есть, а пароля в .env нет — пароль внутри тома НЕ изменится!"
      ask POSTGRES_PASSWORD "Введите существующий пароль БД" "" "" s
    else V[POSTGRES_PASSWORD]="$(gen_secret 32)"; fi
  fi

  echo "— Домены и HTTPS (Mini App и Личный кабинет) —" >"$TTY" 2>/dev/null || true
  if [ "$USE_CADDY" = 1 ] && ! confirm "Настроить HTTPS (Caddy) для Mini App и Личного кабинета? Нужны 2 домена с A-записями на $SERVER_IP" y; then USE_CADDY=0; fi
  local d_app="${V[WEBAPP_URL]:-}" d_lk="${V[CABINET_PUBLIC_URL]:-}"
  d_app="${d_app#https://}"; d_lk="${d_lk#https://}"
  [[ "$d_app" == *example* ]] && d_app=""
  [[ "$d_lk" == *example* ]] && d_lk=""
  if [ "$USE_CADDY" = 1 ]; then
    ask APP_DOMAIN "Домен Mini App (бот, вебхуки оплат), напр. app.example.com" "$d_app" v_domain
    ask LK_DOMAIN  "Домен Личного кабинета, напр. lk.example.com" "$d_lk" v_domain
    ask ACME_EMAIL "E-mail для Let's Encrypt (необязательно)" "" "" "" o
    V[WEBAPP_ENABLED]=true; V[WEBAPP_URL]="https://${V[APP_DOMAIN]}"; V[LK_URL]="https://${V[LK_DOMAIN]}"
    V[CABINET_PUBLIC_URL]="https://${V[LK_DOMAIN]}"
  else
    q WEBAPP_ENABLED "Включить встроенный веб-сервер бота (Mini App/вебхуки, порт 8080)? true/false" "false" v_bool
    [ "${V[WEBAPP_ENABLED]}" = true ] && q WEBAPP_URL "Публичный https-URL Mini App" "" v_url
    q CABINET_PUBLIC_URL "Публичный URL кабинета (https://...)" "http://$SERVER_IP:8090"
  fi
  V[WEBAPP_JWT_SECRET]="${V[WEBAPP_JWT_SECRET]:-$(gen_secret 48)}"
  V[CABINET_JWT_SECRET]="${V[CABINET_JWT_SECRET]:-$(gen_secret 48)}"
  [ "${V[CABINET_JWT_SECRET]}" = change-me-please ] && V[CABINET_JWT_SECRET]="$(gen_secret 48)"
  if [ -z "${V[WEBAPP_ADMIN_PASSWORD]:-}" ]; then V[WEBAPP_ADMIN_PASSWORD]="$(gen_secret 16)"; GEN_ADMIN_PW=1; fi

  echo "— VPN-панели (можно пропустить Enter и добавить позже в админке бота) —" >"$TTY" 2>/dev/null || true
  q SUB_URL_TEMPLATE "Шаблон ссылки подписки с {uuid}" "" v_suburl "" o
  q OLCWAVE_URL "URL панели OLCWave" "" v_url "" o
  if [ -n "${V[OLCWAVE_URL]}" ]; then
    q OLCWAVE_ADMIN_USERNAME "Логин админа OLCWave" "admin"
    q OLCWAVE_ADMIN_PASSWORD "Пароль админа OLCWave" "" "" s
    q OLCWAVE_LOCAL_MODE "OLCWave в автономном режиме (без Remnawave)? true/false" "true" v_bool
  fi
  q REMNAWAVE_URL "URL Remnawave (необязательно)" "" v_url "" o
  if [ -n "${V[REMNAWAVE_URL]}" ]; then
    q REMNAWAVE_API_TOKEN "API-токен Remnawave" "" "" s
    q REMNAWAVE_SQUAD_UUID "UUID сквада Remnawave" "" "" "" o
  fi
  q WDTT_URL "URL панели WDTT (необязательно)" "" v_url "" o
  if [ -n "${V[WDTT_URL]}" ]; then
    q WDTT_USERNAME "Логин WDTT"; q WDTT_PASSWORD "Пароль WDTT" "" "" s
  fi

  echo "— Оплата (необязательно) —" >"$TTY" 2>/dev/null || true
  q YOOKASSA_SHOP_ID "ЮKassa shopId" "" v_int "" o
  [ -n "${V[YOOKASSA_SHOP_ID]}" ] && q YOOKASSA_SECRET_KEY "ЮKassa секретный ключ (live_... / test_...)" "" "" s
  q PLATEGA_MERCHANT_ID "Platega Merchant ID" "" "" "" o
  [ -n "${V[PLATEGA_MERCHANT_ID]}" ] && q PLATEGA_SECRET "Platega secret" "" "" s

  echo "— Прочее —" >"$TTY" 2>/dev/null || true
  q SUPPORT_URL "Ссылка на поддержку (https://t.me/...)" "" "" "" o
  q CURRENCY "Валюта" "RUB"
  q DISPLAY_TZ "Часовой пояс" "Europe/Moscow"
  q REFERRAL_PERCENT "Реферальный %" "10" v_int
  q DEFAULT_TARIFFS "Тарифы при первом запуске дни:цена:ГБ,..." "7:99:100,30:199:300,90:499:1000,365:1499:4000"
}

write_envs() {
  step "Запись .env"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  for f in "$APP_DIR/.env" "$CAB_DIR/.env"; do [ -f "$f" ] && cp -p "$f" "$f.bak.$ts" && chmod 600 "$f.bak.$ts"; done
  local bot_keys=(BOT_TOKEN ADMIN_IDS BOT_USERNAME POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD
    SUB_URL_TEMPLATE OLCWAVE_URL OLCWAVE_ADMIN_USERNAME OLCWAVE_ADMIN_PASSWORD OLCWAVE_LOCAL_MODE
    REMNAWAVE_URL REMNAWAVE_API_TOKEN REMNAWAVE_SQUAD_UUID WDTT_URL WDTT_USERNAME WDTT_PASSWORD
    YOOKASSA_SHOP_ID YOOKASSA_SECRET_KEY PLATEGA_MERCHANT_ID PLATEGA_SECRET
    PANEL_YOOKASSA_WEBHOOK_URL PANEL_PLATEGA_WEBHOOK_URL
    BOT_HTTP_PORT WEBAPP_ENABLED WEBAPP_URL LK_URL WEBAPP_MENU_BUTTON WEBAPP_ADMIN_PASSWORD WEBAPP_JWT_SECRET
    CURRENCY SUPPORT_URL DEFAULT_TARIFFS REFERRAL_PERCENT DISPLAY_TZ BACKUP_HOUR BACKUP_MINUTE BACKUP_KEEP)
  V[BOT_HTTP_PORT]="${V[BOT_HTTP_PORT]:-8080}"; V[WEBAPP_MENU_BUTTON]="${V[WEBAPP_MENU_BUTTON]:-true}"
  V[BACKUP_HOUR]="${V[BACKUP_HOUR]:-0}"; V[BACKUP_MINUTE]="${V[BACKUP_MINUTE]:-5}"; V[BACKUP_KEEP]="${V[BACKUP_KEEP]:-7}"
  # По умолчанию в коде прописан проксирующий вебхук на панель автора — на новом сервере отключаем.
  V[PANEL_YOOKASSA_WEBHOOK_URL]="${V[PANEL_YOOKASSA_WEBHOOK_URL]:-}"; V[PANEL_PLATEGA_WEBHOOK_URL]="${V[PANEL_PLATEGA_WEBHOOK_URL]:-}"
  V[LK_URL]="${V[LK_URL]:-${V[CABINET_PUBLIC_URL]:-}}"
  # сохраняем неизвестные ключи из старого .env
  local extra=""; if [ -f "$APP_DIR/.env" ]; then
    extra="$(grep -E '^[A-Z_][A-Z0-9_]*=' "$APP_DIR/.env" | grep -vE "^($(IFS='|'; echo "${bot_keys[*]}"))=" || true)"; fi
  umask 077
  { echo "# Сгенерировано install.sh $(date -Is)"; for k in "${bot_keys[@]}"; do printf '%s=%s\n' "$k" "${V[$k]:-}"; done
    [ -n "$extra" ] && { echo "# --- прочие ключи из предыдущего .env ---"; echo "$extra"; }; } >"$APP_DIR/.env"
  local cab_keys=(BOT_TOKEN BOT_USERNAME ADMIN_IDS POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD
    CABINET_PUBLIC_URL CABINET_JWT_SECRET WEBAPP_JWT_SECRET YOOKASSA_SHOP_ID YOOKASSA_SECRET_KEY YOOKASSA_RETURN_URL
    PLATEGA_MERCHANT_ID PLATEGA_SECRET SUB_URL_TEMPLATE REFERRAL_PERCENT DISPLAY_TZ SUPPORT_URL)
  V[YOOKASSA_RETURN_URL]="${V[YOOKASSA_RETURN_URL]:-${V[CABINET_PUBLIC_URL]}/cabinet}"
  { echo "# Сгенерировано install.sh $(date -Is)"; echo "POSTGRES_HOST=antibs2vpn-postgres"
    for k in "${cab_keys[@]}"; do printf '%s=%s\n' "$k" "${V[$k]:-}"; done
    [ "$USE_CADDY" = 0 ] && [[ "${V[CABINET_PUBLIC_URL]}" != https://* ]] && echo "CABINET_SECURE_COOKIE=false"; } >"$CAB_DIR/.env"
  umask 022
  chmod 600 "$APP_DIR/.env" "$CAB_DIR/.env"
  log ".env бота и кабинета записаны (chmod 600)"
}

# --- 3. сеть, порты, firewall ------------------------------------------------------
prepare_host() {
  step "Подготовка хоста"
  docker network inspect "$NET" >/dev/null 2>&1 || { docker network create "$NET" >/dev/null; log "Создана сеть $NET"; }
  if [ "$USE_CADDY" = 1 ]; then
    for p in 80 443; do
      local who; who="$(ss -ltnpH "sport = :$p" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)"
      [ -z "$who" ] && continue
      [[ "$who" == docker-proxy ]] && docker ps --format '{{.Names}}' | grep -qx antibs-caddy && continue
      warn "Порт $p занят процессом: $who"
      case "$who" in
        nginx|apache2|httpd|caddy)
          if confirm "Остановить и отключить $who (он мешает выпуску HTTPS)?" y; then
            systemctl disable --now "$who" >/dev/null 2>&1 || true
          fi;;
        *) warn "Освободите порт $p вручную или запустите с --no-caddy";;
      esac
    done
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    log "ufw активен — открываю 22,80,443"; ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  fi
}

setup_caddy() {
  [ "$USE_CADDY" = 1 ] || return 0
  step "Caddy (HTTPS) → $PROXY_DIR"
  mkdir -p "$PROXY_DIR/data" "$PROXY_DIR/config"
  local cf="$PROXY_DIR/Caddyfile" tmp; tmp="$(mktemp)"
  {
    [ -n "${V[ACME_EMAIL]:-}" ] && printf '{\n\temail %s\n}\n\n' "${V[ACME_EMAIL]}"
    printf '# >>> antibs2vpn (install.sh)\n%s {\n\tencode zstd gzip\n\treverse_proxy antibs2vpn-bot:8080\n}\n\n%s {\n\tencode zstd gzip\n\treverse_proxy antibs2vpn_cabinet:8090\n}\n# <<< antibs2vpn\n' "${V[APP_DOMAIN]}" "${V[LK_DOMAIN]}"
  } >"$tmp"
  if [ -f "$cf" ] && ! grep -q '# >>> antibs2vpn' "$cf"; then
    cp "$cf" "$cf.bak.$(date +%s)"; { cat "$cf"; echo; sed '/^{/,/^}/d' "$tmp"; } >"$cf.new"; mv "$cf.new" "$cf"
    warn "Существующий Caddyfile дополнен нашими доменами (бэкап рядом)"
  elif [ -f "$cf" ]; then
    sed -i '/# >>> antibs2vpn/,/# <<< antibs2vpn/d' "$cf"; sed '/^{/,/^}/d' "$tmp" >>"$cf"
  else mv "$tmp" "$cf"; fi
  rm -f "$tmp"
  cat >"$PROXY_DIR/docker-compose.yml" <<'EOF'
services:
  caddy:
    image: caddy:2
    container_name: antibs-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
    networks:
      - antibs2vpn
networks:
  antibs2vpn:
    external: true
EOF
  docker run --rm -v "$cf:/etc/caddy/Caddyfile:ro" caddy:2 caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    || { err "Caddyfile невалиден:"; docker run --rm -v "$cf:/etc/caddy/Caddyfile:ro" caddy:2 caddy validate --config /etc/caddy/Caddyfile || true; }
}

install_services() {
  step "systemd: antibs-recreate-watch (перезапуск бота из админки)"
  sed "s#/opt/AntiBS2vpn#$APP_DIR#g" "$APP_DIR/deploy/antibs-recreate-watch.sh" >/usr/local/bin/antibs-recreate-watch.sh
  chmod 755 /usr/local/bin/antibs-recreate-watch.sh
  cp "$APP_DIR/deploy/antibs-recreate-watch.service" /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now antibs-recreate-watch.service >/dev/null 2>&1 \
    && systemctl restart antibs-recreate-watch.service && log "antibs-recreate-watch запущен" || warn "Не удалось запустить antibs-recreate-watch"
  chmod +x "$APP_DIR"/scripts/*.sh 2>/dev/null || true
  if confirm "Включить ежедневный full-бэкап (код+.env+БД) с отправкой первому админу в Telegram?" y; then
    printf 'ENABLED=1\nTIME_MSK="00:05"\nCHAT="%s"\n' "${V[ADMIN_IDS]%%,*}" >"$APP_DIR/backups/full_backup.conf"
    local line="*/5 * * * * $APP_DIR/scripts/backup_full.sh >> /var/log/antibs2vpn_backup.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'scripts/backup_full.sh'; echo "$line" ) | crontab -
    systemctl enable --now cron >/dev/null 2>&1 || true
    log "cron бэкапа установлен (00:05 МСК)"
  fi
}

# --- 4. запуск ----------------------------------------------------------------------
compose_up() { # dir [extra]
  local d="$1" i
  for i in 1 2 3; do
    if (cd "$d" && docker compose up -d --build --remove-orphans); then return 0; fi
    warn "docker compose up в $d не удался (попытка $i/3)"
    case $i in
      1) docker builder prune -f >/dev/null 2>&1 || true;;
      2) (cd "$d" && docker compose build --no-cache --pull) || true;;
    esac
    sleep 5
  done
  return 1
}

wait_pg() {
  local i
  for i in $(seq 1 60); do
    docker exec antibs2vpn-postgres pg_isready -U "${V[POSTGRES_USER]}" -d "${V[POSTGRES_DB]}" >/dev/null 2>&1 && return 0
    sleep 2
  done; return 1
}

RESTORE_KIND=""
detect_restore() {
  [ -n "$RESTORE_FILE" ] || return 0
  if [[ "$RESTORE_FILE" == *.dump ]]; then RESTORE_KIND=dump
  elif unzip -l "$RESTORE_FILE" 2>/dev/null | grep -q ' db.dump$'; then RESTORE_KIND=fullzip
  elif unzip -l "$RESTORE_FILE" 2>/dev/null | grep -qE 'bot_backup_.*\.json$'; then RESTORE_KIND=json
  else die "Неизвестный формат бэкапа: $RESTORE_FILE (ожидается antibs2vpn-fullbackup_*.zip, db.dump или bot_backup_*.zip)"; fi
  log "Формат бэкапа: $RESTORE_KIND"
  [ "$RESTORE_KIND" = json ] && warn "bot_backup_*.zip содержит только 7 таблиц (users, tariffs, subscriptions, payments, transactions, promocodes, settings). Панели, доп. услуги, тексты экранов и пр. НЕ восстановятся — используйте full-бэкап, если он есть."
  return 0
}

# Полный дамп pg_dump -Fc: восстанавливаем в пустую БД ДО первого старта бота.
restore_dump() {
  local f="$RESTORE_FILE" tmp=""
  if [ "$RESTORE_KIND" = fullzip ]; then tmp="$(mktemp -d)"; unzip -qo "$RESTORE_FILE" db.dump -d "$tmp"; f="$tmp/db.dump"; fi
  step "Восстановление БД из $(basename "$RESTORE_FILE")"
  (cd "$APP_DIR" && docker compose stop bot >/dev/null 2>&1) || true
  docker cp "$f" antibs2vpn-postgres:/tmp/restore.dump
  if docker exec antibs2vpn-postgres pg_restore -U "${V[POSTGRES_USER]}" -d "${V[POSTGRES_DB]}" --clean --if-exists --no-owner --no-privileges /tmp/restore.dump; then
    log "pg_restore: OK"
  else warn "pg_restore завершился с предупреждениями — проверьте вывод выше"; fi
  docker exec antibs2vpn-postgres rm -f /tmp/restore.dump || true
  local n; n="$(docker exec antibs2vpn-postgres psql -U "${V[POSTGRES_USER]}" -d "${V[POSTGRES_DB]}" -tAc 'select count(*) from users' 2>/dev/null || echo '?')"
  log "Пользователей в восстановленной БД: $n"
  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}

# JSON-бэкап бота: таблицы должны быть уже созданы ботом, поэтому — ПОСЛЕ старта.
restore_json() {
  step "Восстановление из JSON-бэкапа бота"
  cp "$RESTORE_FILE" "$APP_DIR/backups/"
  local i; for i in $(seq 1 30); do docker logs antibs2vpn-bot 2>&1 | grep -q 'bot starting' && break; sleep 3; done
  (cd "$APP_DIR" && docker compose exec -T bot python -m scripts.restore_backup "/app/backups/$(basename "$RESTORE_FILE")") \
    || warn "restore_backup завершился с ошибкой"
  (cd "$APP_DIR" && docker compose restart bot) >/dev/null || true
}

start_all() {
  step "Сборка и запуск контейнеров"
  detect_restore
  if [ "$RESTORE_KIND" = dump ] || [ "$RESTORE_KIND" = fullzip ]; then
    (cd "$APP_DIR" && docker compose up -d postgres) || die "PostgreSQL не запустился"
    wait_pg || die "PostgreSQL не готов: docker logs antibs2vpn-postgres"
    restore_dump
  fi
  compose_up "$APP_DIR" || die "Не удалось запустить бота. Логи: cd $APP_DIR && docker compose logs --tail 100"
  wait_pg || die "PostgreSQL не готов: docker logs antibs2vpn-postgres"
  [ "$RESTORE_KIND" = json ] && restore_json
  compose_up "$CAB_DIR" || warn "Кабинет не запустился: cd $CAB_DIR && docker compose logs --tail 100"
  if [ "$USE_CADDY" = 1 ]; then compose_up "$PROXY_DIR" || warn "Caddy не запустился: docker logs antibs-caddy"; fi
}

# --- 5. проверки и автоисправления -----------------------------------------------
FAILS=0
ok()  { printf '  %s✔%s %s\n' "$c_g" "$c_0" "$*"; }
bad() { printf '  %s✘%s %s\n' "$c_r" "$c_0" "$*"; FAILS=$((FAILS+1)); }

health() {
  step "Проверка работоспособности"
  FAILS=0
  load_env_into_V "$APP_DIR/.env"
  local c st
  for c in antibs2vpn-postgres antibs2vpn-bot antibs2vpn_cabinet $([ -f "$PROXY_DIR/docker-compose.yml" ] && [ "$USE_CADDY" = 1 ] && echo antibs-caddy); do
    st="$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}} restarts={{.RestartCount}}' "$c" 2>/dev/null || echo missing)"
    [[ "$st" == running* && "$st" != *unhealthy* ]] && ok "$c: $st" || bad "$c: $st"
  done
  wait_pg && ok "PostgreSQL принимает подключения" || bad "PostgreSQL не отвечает"
  local n; n="$(docker exec antibs2vpn-postgres psql -U "${V[POSTGRES_USER]}" -d "${V[POSTGRES_DB]}" -tAc "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt 0 ] && ok "Таблиц в БД: $n" || bad "Таблицы в БД не созданы (бот не стартовал?)"
  curl -fsS -m 15 "https://api.telegram.org/bot${V[BOT_TOKEN]}/getMe" 2>/dev/null | grep -q '"ok":true' && ok "Telegram getMe OK" || bad "Telegram getMe не прошёл"
  local logs; logs="$(docker logs --tail 300 antibs2vpn-bot 2>&1 || true)"
  grep -q 'bot starting' <<<"$logs" && ok "Бот запущен (bot starting)" || bad "В логах нет 'bot starting'"
  if grep -qE 'Traceback|CRITICAL|Error:' <<<"$logs"; then
    bad "В логах бота есть ошибки:"; grep -nE -A3 'Traceback|CRITICAL|Error:' <<<"$logs" | tail -20 | sed 's/^/      /'
    grep -q 'TelegramConflictError\|terminated by other getUpdates' <<<"$logs" && warn "Этот токен уже используется другим сервером — остановите старого бота."
    grep -q 'password authentication failed' <<<"$logs" && warn "Пароль БД в .env не совпадает с томом. Укажите старый пароль или удалите том (docker volume rm antibs2vpn_bot_postgres_data — ДАННЫЕ ПРОПАДУТ)."
  else ok "Ошибок в логах бота нет"; fi
  docker exec antibs2vpn_cabinet curl -fsS -m 5 http://127.0.0.1:8090/health >/dev/null 2>&1 && ok "Кабинет /health OK" || bad "Кабинет /health не отвечает"
  if [ "${V[WEBAPP_ENABLED]:-false}" = true ]; then
    docker exec antibs2vpn_cabinet curl -fsS -m 5 http://antibs2vpn-bot:8080/health >/dev/null 2>&1 && ok "Бот HTTP /health OK" || bad "Бот HTTP :8080 не отвечает"
  fi
  if [ "$USE_CADDY" = 1 ] && [ -n "${V[WEBAPP_URL]:-}" ]; then
    local u
    for u in "${V[WEBAPP_URL]}/health" "${V[LK_URL]:-${V[CABINET_PUBLIC_URL]:-}}/health"; do
      local i r=1; for i in 1 2 3 4 5 6; do curl -fsS -m 10 "$u" >/dev/null 2>&1 && { r=0; break; }; sleep 10; done
      [ $r = 0 ] && ok "HTTPS $u" || { bad "HTTPS $u не отвечает"; docker logs --tail 15 antibs-caddy 2>&1 | grep -iE 'error|challenge' | tail -5 | sed 's/^/      /'; }
    done
  fi
  systemctl is-active --quiet antibs-recreate-watch && ok "antibs-recreate-watch active" || bad "antibs-recreate-watch не активен"
}

autofix() {
  [ "$FAILS" -gt 0 ] || return 0
  step "Попытка автоисправления"
  docker info >/dev/null 2>&1 || systemctl restart docker
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
  (cd "$APP_DIR" && docker compose up -d --force-recreate) || true
  (cd "$CAB_DIR" && docker compose up -d --force-recreate) || true
  [ "$USE_CADDY" = 1 ] && [ -f "$PROXY_DIR/docker-compose.yml" ] && (cd "$PROXY_DIR" && docker compose up -d --force-recreate) || true
  systemctl restart antibs-recreate-watch 2>/dev/null || true
  sleep 20; health
}

summary() {
  step "Итог"
  if [ "$FAILS" = 0 ]; then log "Всё работает! Откройте бота: https://t.me/${V[BOT_USERNAME]:-}"; else
    err "Проверок не пройдено: $FAILS. Диагностика:"
    echo "  cd $APP_DIR && docker compose logs --tail 100 bot"
    echo "  cd $CAB_DIR && docker compose logs --tail 100"
    echo "  docker logs antibs-caddy --tail 50"
    echo "  Повторный запуск установщика безопасен (команда из README установщика)"
  fi
  [ -n "${V[WEBAPP_URL]:-}" ] && echo "  Mini App:        ${V[WEBAPP_URL]}  (админка: ${V[WEBAPP_URL]}/admin)"
  echo "  Личный кабинет:  ${V[CABINET_PUBLIC_URL]:-}"
  [ "${GEN_ADMIN_PW:-0}" = 1 ] && echo "  Пароль веб-админки сгенерирован: WEBAPP_ADMIN_PASSWORD в $APP_DIR/.env"
  [ -n "${V[YOOKASSA_SHOP_ID]:-}" ] && [ -n "${V[WEBAPP_URL]:-}" ] && echo "  Вебхук ЮKassa (указать в ЛК ЮKassa): ${V[WEBAPP_URL]}/yookassa/webhook"
  [ -n "${V[PLATEGA_MERCHANT_ID]:-}" ] && [ -n "${V[WEBAPP_URL]:-}" ] && echo "  Callback Platega: ${V[WEBAPP_URL]}/api/platega/callback"
  echo "  Обновление: bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/update.sh)"
}

main() {
  if [ "$ONLY_CHECK" = 1 ]; then [ -d "$PROXY_DIR" ] || USE_CADDY=0; health; summary; exit $(( FAILS > 0 )); fi
  check_system
  install_deps
  fetch_code
  preload_env_from_backup
  collect
  write_envs
  prepare_host
  setup_caddy
  start_all
  install_services
  sleep 15
  health
  autofix
  summary
  [ "$FAILS" = 0 ]
}
main "$@"
