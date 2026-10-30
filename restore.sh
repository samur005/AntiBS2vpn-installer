#!/usr/bin/env bash
# =============================================================================
#  AntiBS2vpn — восстановление из бэкапа.
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/restore.sh) [backup.zip]
#
#  Поддерживаемые бэкапы:
#    antibs2vpn-fullbackup_*.zip — полный (db.dump + code.tgz с .env)  ← рекомендуется
#    *.dump                      — дамп pg_dump -Fc
#    bot_backup_*.zip            — частичный JSON-бэкап бота (7 таблиц)
#
#  Бот не установлен  → запускается install.sh --restore (установка + восстановление).
#  Бот установлен     → восстановление поверх текущей установки
#                       (с предварительным страховочным дампом текущей БД).
#  Флаги: --dir DIR (по умолч. /opt/AntiBS2vpn), -y (без подтверждений), -h
# =============================================================================
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/AntiBS2vpn}"
INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/install.sh}"
PG=antibs2vpn-postgres
ASSUME_YES=0
FILE=""

c_g=$'\e[1;32m'; c_y=$'\e[1;33m'; c_r=$'\e[1;31m'; c_b=$'\e[1;36m'; c_0=$'\e[0m'
log()  { printf '%s[+]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$c_r" "$c_0" "$*" >&2; }
step() { printf '\n%s==== %s ====%s\n' "$c_b" "$*" "$c_0"; }
die()  { err "$*"; exit 1; }
trap 'err "Ошибка в строке $LINENO: $BASH_COMMAND"' ERR

TTY=/dev/tty; [ -r "$TTY" ] || TTY=/dev/stdin
read_tty() { local v; IFS= read -r v <"$TTY" || true; printf '%s' "$v"; }
confirm() { # confirm "вопрос" [y|n]
  local d="${2:-n}" a
  [ "$ASSUME_YES" = 1 ] && { [ "$d" = y ]; return; }
  printf '%s [%s]: ' "$1" "$([ "$d" = y ] && echo Y/n || echo y/N)" >"$TTY"
  a="$(read_tty)"; a="${a:-$d}"; [[ "$a" =~ ^[YyДд] ]]
}
env_get() { [ -f "$1" ] && grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- | tr -d '\r"' || true; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) APP_DIR="$2"; shift 2;;
    -y|--yes) ASSUME_YES=1; shift;;
    -h|--help) sed -n '2,17p' "$0" 2>/dev/null || true; exit 0;;
    -*) die "Неизвестный параметр: $1";;
    *) FILE="$1"; shift;;
  esac
done
CAB_DIR="$APP_DIR/AntiBS2vpn-cabinet"

[ "$(id -u)" = 0 ] || die "Запустите от root (sudo)."
command -v unzip >/dev/null || { apt-get update -qq && apt-get install -y -qq unzip >/dev/null; } || die "Нужен unzip"

# --- 1. файл бэкапа и его тип ------------------------------------------------
while :; do
  if [ -z "$FILE" ]; then printf 'Путь к файлу бэкапа: ' >"$TTY"; FILE="$(read_tty)"; fi
  FILE="${FILE/#\~/$HOME}"
  if [ -f "$FILE" ] && [ -s "$FILE" ]; then FILE="$(readlink -f "$FILE")"; break; fi
  warn "Файл не найден или пуст: $FILE"; FILE=""
  [ "$ASSUME_YES" = 1 ] && exit 1
done

KIND=""
if [[ "$FILE" == *.dump ]]; then
  head -c 5 "$FILE" | grep -q PGDMP || die "Это не дамп pg_dump -Fc"; KIND=dump
elif unzip -l "$FILE" 2>/dev/null | grep -q ' db.dump$'; then KIND=full
elif unzip -l "$FILE" 2>/dev/null | grep -qE 'bot_backup_.*\.json$'; then KIND=json
else die "Неизвестный формат. Ожидается antibs2vpn-fullbackup_*.zip, *.dump или bot_backup_*.zip"; fi
case "$KIND" in
  full) log "Полный бэкап (БД + код + .env): $(basename "$FILE")";;
  dump) log "Дамп БД: $(basename "$FILE")";;
  json) warn "Частичный JSON-бэкап: восстановятся только users, tariffs, subscriptions, payments, transactions, promocodes, settings.";;
esac

# --- 2. бот не установлен → полная установка с восстановлением -----------------
installed() { [ -f "$APP_DIR/docker-compose.yml" ] && [ -f "$APP_DIR/.env" ] && command -v docker >/dev/null; }
get_installer() { local t; t="$(mktemp)"; curl -fsSL "$INSTALLER_URL" -o "$t" || die "Не удалось скачать install.sh"; echo "$t"; }

if ! installed; then
  step "Бот не найден в $APP_DIR — установка с восстановлением"
  [ "$KIND" = json ] && warn "Для переноса лучше использовать полный бэкап."
  confirm "Запустить установку с восстановлением из бэкапа?" y || exit 0
  INST="$(get_installer)"
  exec bash "$INST" --dir "$APP_DIR" --restore "$FILE"
fi

# --- 3. восстановление поверх существующей установки -------------------------------
DB_USER="$(env_get "$APP_DIR/.env" POSTGRES_USER)"; DB_USER="${DB_USER:-vpn_bot}"
DB_NAME="$(env_get "$APP_DIR/.env" POSTGRES_DB)";   DB_NAME="${DB_NAME:-vpn_bot}"
compose() { (cd "$1" && shift && docker compose "$@"); }
psqlc() { docker exec "$PG" psql -U "$DB_USER" -d "${2:-$DB_NAME}" -tAc "$1"; }
wait_pg() { local _i; for _i in $(seq 1 40); do docker exec "$PG" pg_isready -U "$DB_USER" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
users_count() { psqlc 'select count(*) from users' 2>/dev/null || echo '?'; }

step "Восстановление поверх текущей установки ($APP_DIR)"
compose "$APP_DIR" up -d postgres >/dev/null
wait_pg || die "PostgreSQL не запускается: docker logs $PG"
printf '%s' "$c_r" >"$TTY"
cat >"$TTY" <<W
  ВНИМАНИЕ! Текущие данные бота будут ЗАМЕНЕНЫ данными из бэкапа.
  Сейчас пользователей в БД: $(users_count)
  Перед восстановлением будет сделан страховочный дамп текущей БД.
W
printf '%s' "$c_0" >"$TTY"
confirm "Продолжить?" n || { log "Отменено."; exit 0; }

step "Страховочный дамп текущей БД"
mkdir -p "$APP_DIR/backups"
SAFE="$APP_DIR/backups/pre_restore_$(date +%Y%m%d_%H%M%S).dump"
docker exec "$PG" pg_dump -U "$DB_USER" -Fc "$DB_NAME" >"$SAFE" || die "Не удалось сделать страховочный дамп — восстановление прервано"
chmod 600 "$SAFE"
log "Сохранено: $SAFE ($(du -h "$SAFE" | cut -f1))"
log "Откат при необходимости: повторно запустите restore.sh $SAFE"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- .env из полного бэкапа (показываем только ключи, не значения) --------------
ENV_CHANGED=0
if [ "$KIND" = full ] && unzip -l "$FILE" | grep -q ' code.tgz$'; then
  unzip -qo "$FILE" code.tgz -d "$TMP"
  tar xzf "$TMP/code.tgz" -C "$TMP" ./.env ./AntiBS2vpn-cabinet/.env 2>/dev/null || true
  for rel in .env AntiBS2vpn-cabinet/.env; do
    src="$TMP/$rel"; dst="$APP_DIR/$rel"; [ -s "$src" ] || continue
    keys() { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null | cut -d= -f1 | sort -u; }
    step "Сравнение $rel (только имена ключей)"
    added="$(comm -13 <(keys "$dst") <(keys "$src") | tr '\n' ' ')"
    removed="$(comm -23 <(keys "$dst") <(keys "$src") | tr '\n' ' ')"
    changed=""
    while IFS= read -r k; do
      [ "$(env_get "$dst" "$k")" = "$(env_get "$src" "$k")" ] || changed+="$k "
    done < <(comm -12 <(keys "$dst") <(keys "$src"))
    echo "  только в бэкапе:   ${added:-—}"
    echo "  только в текущем:  ${removed:-—}"
    echo "  отличаются:        ${changed:-—}"
    if [ -z "$added$removed$changed" ]; then log "$rel совпадает"; continue; fi
    if confirm "Заменить $rel версией из бэкапа (текущий сохранится как .bak)?" n; then
      cp -p "$dst" "$dst.bak.$(date +%s)" 2>/dev/null || true
      install -m 600 "$src" "$dst"; ENV_CHANGED=1; log "$rel заменён"
      [[ " $changed " == *" POSTGRES_PASSWORD "* ]] && warn "Пароль БД в бэкапе другой — он будет установлен для пользователя БД."
    fi
  done
fi

# --- остановка, пересоздание БД, восстановление ---------------------------------
step "Остановка бота и кабинета"
compose "$APP_DIR" stop bot >/dev/null 2>&1 || true
[ -f "$CAB_DIR/docker-compose.yml" ] && { compose "$CAB_DIR" stop >/dev/null 2>&1 || true; }

if [ "$KIND" = json ]; then
  step "Восстановление из JSON (штатный механизм бота)"
  cp "$FILE" "$APP_DIR/backups/"
  compose "$APP_DIR" run --rm -T bot python -m scripts.restore_backup "/app/backups/$(basename "$FILE")" \
    || die "Ошибка restore_backup. Откат: restore.sh $SAFE"
else
  DUMP="$FILE"
  [ "$KIND" = full ] && { unzip -qo "$FILE" db.dump -d "$TMP"; DUMP="$TMP/db.dump"; }
  step "Пересоздание БД $DB_NAME"
  psqlc "select pg_terminate_backend(pid) from pg_stat_activity where datname='$DB_NAME' and pid<>pg_backend_pid()" postgres >/dev/null || true
  docker exec "$PG" dropdb -U "$DB_USER" --if-exists "$DB_NAME" --maintenance-db=postgres
  docker exec "$PG" createdb -U "$DB_USER" -O "$DB_USER" "$DB_NAME" --maintenance-db=postgres
  step "pg_restore"
  docker cp "$DUMP" "$PG:/tmp/restore.dump"
  if docker exec "$PG" pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-privileges /tmp/restore.dump; then
    log "pg_restore: OK"
  else warn "pg_restore завершился с предупреждениями — проверьте вывод выше"; fi
  docker exec "$PG" rm -f /tmp/restore.dump || true
fi

if [ "$ENV_CHANGED" = 1 ]; then
  NEWPW="$(env_get "$APP_DIR/.env" POSTGRES_PASSWORD)"
  if [ -n "$NEWPW" ]; then
    docker exec -i "$PG" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -q >/dev/null <<SQL
ALTER USER "$DB_USER" WITH PASSWORD '${NEWPW//\'/\'\'}';
SQL
  fi
fi

# --- запуск и проверка -----------------------------------------------------------
step "Запуск"
compose "$APP_DIR" up -d >/dev/null
[ -f "$CAB_DIR/docker-compose.yml" ] && { compose "$CAB_DIR" up -d >/dev/null || warn "Кабинет не запустился"; }
sleep 15
[ "$KIND" = json ] && compose "$APP_DIR" restart bot >/dev/null
log "Пользователей в БД: $(users_count)"

step "Проверка (install.sh --check)"
INST="$(get_installer)"
if bash "$INST" --dir "$APP_DIR" --check; then
  log "Восстановление завершено успешно."
else
  warn "Проверка нашла проблемы. Логи: docker logs antibs2vpn-bot --tail 100"
  warn "Откат к состоянию до восстановления: restore.sh $SAFE"
fi
rm -f "$INST"
