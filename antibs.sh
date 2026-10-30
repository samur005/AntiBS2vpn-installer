#!/usr/bin/env bash
# =============================================================================
#  AntiBS2vpn — меню управления (установка, восстановление, обновление, логи...).
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/antibs.sh)
#
#  После установки в /usr/local/bin достаточно набрать: antibs
#  Действия выполняют отдельные скрипты install.sh / restore.sh / update.sh /
#  uninstall.sh (берутся рядом с этим файлом или скачиваются из репозитория).
#  Флаги: --dir DIR (по умолч. /opt/AntiBS2vpn), --plain (без whiptail)
# =============================================================================
set -uo pipefail

APP_DIR="${APP_DIR:-/opt/AntiBS2vpn}"
RAW="${ANTIBS_RAW:-https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main}"
BIN=/usr/local/bin/antibs
STATE_DIR=/etc/antibs2vpn
PLAIN=0
PG=antibs2vpn-postgres

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) APP_DIR="$2"; shift 2;;
    --plain) PLAIN=1; shift;;
    -h|--help) sed -n '2,11p' "$0" 2>/dev/null || true; exit 0;;
    *) echo "Неизвестный параметр: $1"; exit 1;;
  esac
done
CAB_DIR="$APP_DIR/AntiBS2vpn-cabinet"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo /nonexistent)"

c_g=$'\e[1;32m'; c_y=$'\e[1;33m'; c_b=$'\e[1;36m'; c_d=$'\e[2m'; c_0=$'\e[0m'
TTY=/dev/tty; [ -r "$TTY" ] || TTY=/dev/stdin
say()  { printf '%s\n' "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
pause() { printf '\n%sНажмите Enter, чтобы вернуться в меню...%s' "$c_d" "$c_0"; read -r _ <"$TTY" || true; }

[ "$(id -u)" = 0 ] || { echo "Запустите от root (sudo)."; exit 1; }

# --- интерфейс: whiptail или обычное меню ------------------------------------------
if [ "$PLAIN" = 0 ] && ! command -v whiptail >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  echo "Устанавливаю whiptail для меню..."
  { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whiptail; } >/dev/null 2>&1 || true
fi
command -v whiptail >/dev/null 2>&1 || PLAIN=1

yesno() { # yesno "текст" -> 0 да
  if [ "$PLAIN" = 0 ]; then whiptail --title "AntiBS2vpn" --yesno "$1" 12 70 <"$TTY" >"$TTY" 2>&1; return; fi
  local a; printf '%s [y/N]: ' "$1" >"$TTY"; read -r a <"$TTY" || true; [[ "$a" =~ ^[YyДд] ]]
}
msg() {
  if [ "$PLAIN" = 0 ]; then whiptail --title "AntiBS2vpn" --msgbox "$1" 14 72 <"$TTY" >"$TTY" 2>&1; else say "$1"; pause; fi
}
input() { # input "вопрос" "по умолч."
  if [ "$PLAIN" = 0 ]; then whiptail --title "AntiBS2vpn" --inputbox "$1" 10 72 "${2:-}" 3>&1 1>"$TTY" 2>&3 <"$TTY"; return; fi
  local a; printf '%s [%s]: ' "$1" "${2:-}" >"$TTY"; read -r a <"$TTY" || true; printf '%s' "${a:-${2:-}}"
}

# --- вспомогательные скрипты: локальная копия рядом или скачивание ------------------
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
script() { # script name.sh -> путь
  local n="$1"
  if [ -f "$SELF_DIR/$n" ] && [ "$SELF_DIR" != /usr/local/bin ]; then echo "$SELF_DIR/$n"; return 0; fi
  [ -s "$TMPD/$n" ] || curl -fsSL "$RAW/$n" -o "$TMPD/$n" || { warn "Не удалось скачать $n"; return 1; }
  echo "$TMPD/$n"
}
run_script() { local p; p="$(script "$1")" || { pause; return; }; shift; clear; bash "$p" "$@"; pause; }

installed() { [ -f "$APP_DIR/docker-compose.yml" ] && [ -f "$APP_DIR/.env" ] && command -v docker >/dev/null 2>&1; }
dc() { (cd "$1" && shift && docker compose "$@"); }
env_get() { [ -f "$1" ] && grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- | tr -d '\r"' || true; }
db_user() { local u; u="$(env_get "$APP_DIR/.env" POSTGRES_USER)"; echo "${u:-vpn_bot}"; }
db_name() { local d; d="$(env_get "$APP_DIR/.env" POSTGRES_DB)"; echo "${d:-vpn_bot}"; }
each_stack() { dc "$APP_DIR" "$@"; [ -f "$CAB_DIR/docker-compose.yml" ] && dc "$CAB_DIR" "$@"; return 0; }

# --- действия ---------------------------------------------------------------------------
a_install()  { run_script install.sh --dir "$APP_DIR"; }
a_restore()  { local f; f="$(input "Путь к файлу бэкапа (пусто — выбрать из $APP_DIR/backups):" "")" || return
  if [ -z "$f" ] && [ -d "$APP_DIR/backups" ]; then f="$(pick_backup)" || return; fi
  run_script restore.sh --dir "$APP_DIR" ${f:+"$f"}; }
a_update()   { run_script update.sh; }
a_uninstall(){ yesno "Удалить AntiBS2vpn? Скрипт удаления задаст уточняющие вопросы." && run_script uninstall.sh; }
a_check()    { run_script install.sh --dir "$APP_DIR" --check; }
a_status()   { clear; docker ps -a --filter name=antibs --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  say ""; say "Пользователей в БД: $(docker exec "$PG" psql -U "$(db_user)" -d "$(db_name)" -tAc 'select count(*) from users' 2>/dev/null || echo '?')"
  say "Диск: $(df -h "$APP_DIR" | awk 'NR==2{print $4" свободно из "$2}')"; pause; }
a_start()    { clear; each_stack up -d; pause; }
a_stop()     { yesno "Остановить бота и кабинет?" || return; clear; each_stack stop; pause; }
a_restart()  { clear; each_stack restart; pause; }
a_logs_bot() { clear; say "${c_b}Логи бота (Ctrl+C — выход)${c_0}"; docker logs -f --tail 200 antibs2vpn-bot; pause; }
a_logs_cab() { clear; local c; c="$(docker ps -a --format '{{.Names}}' | grep -m1 -i cabinet)"
  [ -n "$c" ] || { msg "Контейнер кабинета не найден"; return; }
  say "${c_b}Логи кабинета (Ctrl+C — выход)${c_0}"; docker logs -f --tail 200 "$c"; pause; }
a_backup()   { clear
  if [ -x "$APP_DIR/scripts/backup_full.sh" ] || [ -f "$APP_DIR/scripts/backup_full.sh" ]; then
    : >"$APP_DIR/backups/full_backup.now"
    bash "$APP_DIR/scripts/backup_full.sh"; rc=$?
    [ "$rc" = 0 ] && say "${c_g}Бэкап создан и отправлен в Telegram.${c_0}" || warn "Код $rc: проверьте лог выше (при ошибке отправки копия всё равно в backups/)."
  else
    local f; f="$APP_DIR/backups/manual_$(date +%Y%m%d_%H%M%S).dump"; mkdir -p "$APP_DIR/backups"
    docker exec "$PG" pg_dump -U "$(db_user)" -Fc "$(db_name)" >"$f" && chmod 600 "$f" && say "Дамп БД: $f"
  fi
  ls -lht "$APP_DIR/backups" 2>/dev/null | head -5; pause; }
a_list()     { clear; say "${c_b}Бэкапы в $APP_DIR/backups:${c_0}"
  find "$APP_DIR/backups" -maxdepth 1 \( -name '*.zip' -o -name '*.dump' \) -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' 2>/dev/null | sort -r | grep . || say "(нет)"; say ""; du -sh "$APP_DIR/backups" 2>/dev/null; pause; }
pick_backup() {
  local files=() f items=()
  while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$APP_DIR"/backups/*.zip "$APP_DIR"/backups/*.dump 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || { msg "В $APP_DIR/backups нет бэкапов"; return 1; }
  if [ "$PLAIN" = 0 ]; then
    for f in "${files[@]}"; do items+=("$(basename "$f")" "$(du -h "$f" | cut -f1)"); done
    f="$(whiptail --title "Выбор бэкапа" --menu "Рекомендуется antibs2vpn-fullbackup_*.zip" 20 76 12 "${items[@]}" 3>&1 1>"$TTY" 2>&3 <"$TTY")" || return 1
    echo "$APP_DIR/backups/$f"
  else
    local i=1; for f in "${files[@]}"; do printf '%2d) %s\n' "$i" "$(basename "$f")" >"$TTY"; i=$((i+1)); done
    printf 'Номер: ' >"$TTY"; read -r i <"$TTY" || return 1
    [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#files[@]}" ] || return 1
    echo "${files[$((i-1))]}"
  fi
}
a_env()      { local f="$APP_DIR/.env" ed
  if [ -f "$CAB_DIR/.env" ]; then
    if [ "$PLAIN" = 0 ]; then
      f="$(whiptail --title ".env" --menu "Какой файл?" 12 70 2 "$APP_DIR/.env" "бот" "$CAB_DIR/.env" "кабинет" 3>&1 1>"$TTY" 2>&3 <"$TTY")" || return
    else yesno "Редактировать .env кабинета (нет — бота)?" && f="$CAB_DIR/.env"; fi
  fi
  ed="${EDITOR:-$(command -v nano || command -v vi)}"; cp -p "$f" "$f.bak.$(date +%s)"
  "$ed" "$f" <"$TTY" >"$TTY"
  yesno "Перезапустить сервисы, чтобы применить изменения?" && { clear; each_stack up -d; pause; }; }
a_psql()     { clear; say "${c_b}Консоль PostgreSQL (\\q — выход)${c_0}"
  docker exec -it "$PG" psql -U "$(db_user)" -d "$(db_name)" <"$TTY" >"$TTY"; }

# --- установка себя как команды antibs --------------------------------------------------
offer_self_install() {
  [ -x "$BIN" ] && return 0
  [ -f "$STATE_DIR/antibs_noinstall" ] && return 0
  if yesno "Установить меню как команду «antibs»?\n\nПотом достаточно набрать: antibs"; then
    if curl -fsSL "$RAW/antibs.sh" -o "$BIN.tmp" && bash -n "$BIN.tmp"; then
      install -m 755 "$BIN.tmp" "$BIN"; rm -f "$BIN.tmp"; msg "Готово. Запуск: antibs"
    else rm -f "$BIN.tmp"; warn "Не удалось скачать antibs.sh"; pause; fi
  else mkdir -p "$STATE_DIR"; : >"$STATE_DIR/antibs_noinstall"; fi
}

# --- меню -----------------------------------------------------------------------------------
menu() {
  local inst=0 st="не установлен" items=() ch
  installed && { inst=1; st="установлен в $APP_DIR"; docker ps --format '{{.Names}}' | grep -qx antibs2vpn-bot && st="$st, бот работает" || st="$st, бот остановлен"; }
  if [ "$inst" = 1 ]; then
    items=(install "Установить / перенастроить" restore "Восстановить из бэкапа" update "Обновить"
      status "Статус" start "Запустить" stop "Остановить" restart "Перезапустить"
      logbot "Логи бота" logcab "Логи кабинета" backup "Сделать бэкап сейчас" list "Список бэкапов"
      check "Проверка (health check)" env "Редактировать .env" psql "Консоль БД" uninstall "Удалить" exit "Выход")
  else
    items=(install "Установить" restore "Восстановить из бэкапа (установка + данные)" exit "Выход")
  fi
  if [ "$PLAIN" = 0 ]; then
    ch="$(whiptail --title "AntiBS2vpn" --menu "Статус: $st" 24 70 16 "${items[@]}" 3>&1 1>"$TTY" 2>&3 <"$TTY")" || ch="exit"
  else
    clear; printf '%s=== AntiBS2vpn ===%s\nСтатус: %s\n\n' "$c_b" "$c_0" "$st"
    local i=0 n=1; while [ $i -lt ${#items[@]} ]; do printf '%2d) %s\n' "$n" "${items[$((i+1))]}"; i=$((i+2)); n=$((n+1)); done
    [ "$inst" = 0 ] && printf '%s   (остальные пункты доступны после установки)%s\n' "$c_d" "$c_0"
    printf '\nВыбор: '; read -r n <"$TTY" || n=0
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ $((n*2)) -le ${#items[@]} ]; then ch="${items[$(((n-1)*2))]}"; else ch=""; fi
  fi
  case "$ch" in
    install) a_install;; restore) a_restore;; update) a_update;; status) a_status;;
    start) a_start;; stop) a_stop;; restart) a_restart;; logbot) a_logs_bot;; logcab) a_logs_cab;;
    backup) a_backup;; list) a_list;; check) a_check;; env) a_env;; psql) a_psql;;
    uninstall) a_uninstall;; exit) clear; exit 0;; *) ;;
  esac
}

offer_self_install
while :; do menu; done
