#!/usr/bin/env bash
# =============================================================================
#  AntiBS2vpn — меню управления (установка, бэкапы, обновления, домены, безопасность...).
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/antibs.sh)
#
#  После установки в /usr/local/bin достаточно набрать: antibs
#  Действия выполняют отдельные скрипты install.sh / restore.sh / update.sh /
#  uninstall.sh и antibs-tools.sh (берутся рядом с этим файлом или скачиваются).
#  Флаги: --dir DIR (по умолч. /opt/AntiBS2vpn), --plain (без whiptail), --version
# =============================================================================
set -uo pipefail
VERSION="2.0.0"

APP_DIR="${APP_DIR:-/opt/AntiBS2vpn}"
PROXY_DIR="${PROXY_DIR:-/opt/antibs-proxy}"
RAW="${ANTIBS_RAW:-https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main}"
BIN=/usr/local/bin/antibs
STATE_DIR=/etc/antibs2vpn
PLAIN=0
PG=antibs2vpn-postgres

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) APP_DIR="$2"; shift 2;;
    --plain) PLAIN=1; shift;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) sed -n '2,11p' "$0" 2>/dev/null || true; exit 0;;
    *) echo "Неизвестный параметр: $1"; exit 1;;
  esac
done
CAB_DIR="$APP_DIR/AntiBS2vpn-cabinet"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo /nonexistent)"

c_g=$'\e[1;32m'; c_y=$'\e[1;33m'; c_b=$'\e[1;36m'; c_d=$'\e[2m'; c_0=$'\e[0m'
TTY=/dev/tty; [ -r "$TTY" ] || TTY=/dev/stdin
trap ':' INT   # Ctrl+C прерывает только текущее действие (логи), не меню
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

yesno() {
  if [ "$PLAIN" = 0 ]; then whiptail --title "AntiBS2vpn" --yesno "$1" 18 76 <"$TTY" >"$TTY" 2>&1; return; fi
  local a; printf '%b [y/N]: ' "$1" >"$TTY"; read -r a <"$TTY" || true; [[ "$a" =~ ^[YyДд] ]]
}
msg() {
  if [ "$PLAIN" = 0 ]; then whiptail --title "AntiBS2vpn" --msgbox "$1" 20 78 <"$TTY" >"$TTY" 2>&1; else printf '%b\n' "$1"; pause; fi
}
input() {
  if [ "$PLAIN" = 0 ]; then whiptail --title "AntiBS2vpn" --inputbox "$1" 10 76 "${2:-}" 3>&1 1>"$TTY" 2>&3 <"$TTY"; return; fi
  local a; printf '%s [%s]: ' "$1" "${2:-}" >"$TTY"; read -r a <"$TTY" || true; printf '%s' "${a:-${2:-}}"
}
# choose "Заголовок" "текст" ПУНКТ "пояснение" ПУНКТ "пояснение" ... → выбранный ПУНКТ (пусто = назад)
choose() {
  local title="$1" text="$2"; shift 2
  if [ "$PLAIN" = 0 ]; then
    whiptail --title "$title" --menu "$text" 24 100 15 "$@" 3>&1 1>"$TTY" 2>&3 <"$TTY" || true; return
  fi
  local items=("$@") i=0 n=1 sel
  { clear; printf '%s=== %s ===%s\n%b\n\n' "$c_b" "$title" "$c_0" "$text"
    while [ $i -lt ${#items[@]} ]; do printf '%2d) %s %s— %s%s\n' "$n" "${items[$i]}" "$c_d" "${items[$((i+1))]}" "$c_0"; i=$((i+2)); n=$((n+1)); done
    printf ' 0) Назад / Выход\n\nВыбор: '; } >"$TTY"
  read -r sel <"$TTY" || sel=0
  if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ $((sel*2)) -le ${#items[@]} ]; then printf '%s' "${items[$(((sel-1)*2))]}"; fi
}

# --- вспомогательные скрипты: локальная копия рядом или скачивание ------------------
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
script() {
  local n="$1"
  if [ -f "$SELF_DIR/$n" ] && [ "$SELF_DIR" != /usr/local/bin ]; then echo "$SELF_DIR/$n"; return 0; fi
  [ -s "$TMPD/$n" ] || curl -fsSL "$RAW/$n" -o "$TMPD/$n" || { warn "Не удалось скачать $n"; return 1; }
  echo "$TMPD/$n"
}
run_script() { local p; p="$(script "$1")" || { pause; return; }; shift; clear; bash "$p" "$@"; pause; }

installed() { [ -f "$APP_DIR/docker-compose.yml" ] && [ -f "$APP_DIR/.env" ] && command -v docker >/dev/null 2>&1; }
dc() { [ -f "$1/docker-compose.yml" ] || return 0; (cd "$1" && shift && docker compose "$@"); }
env_get() { [ -f "$1" ] && grep -E "^$2=" "$1" | tail -1 | cut -d= -f2- | tr -d '\r"' || true; }
db_user() { local u; u="$(env_get "$APP_DIR/.env" POSTGRES_USER)"; echo "${u:-vpn_bot}"; }
db_name() { local d; d="$(env_get "$APP_DIR/.env" POSTGRES_DB)"; echo "${d:-vpn_bot}"; }
each_stack() { dc "$APP_DIR" "$@"; dc "$CAB_DIR" "$@"; return 0; }

TOOLS="$(script antibs-tools.sh)" || { echo "Нет antibs-tools.sh"; exit 1; }
# shellcheck source=antibs-tools.sh
. "$TOOLS"

# --- базовые действия -----------------------------------------------------------------
a_install()  { run_script install.sh --dir "$APP_DIR"; }
a_restore()  { local f; f="$(input "Путь к файлу бэкапа (пусто — выбрать из $APP_DIR/backups)" "")" || return
  if [ -z "$f" ] && [ -d "$APP_DIR/backups" ]; then f="$(pick_backup)" || return; fi
  run_script restore.sh --dir "$APP_DIR" ${f:+"$f"}; }
a_update()   { run_script update.sh --dir "$APP_DIR"; }
a_uninstall(){ yesno "Удалить AntiBS2vpn? Скрипт удаления задаст уточняющие вопросы." && run_script uninstall.sh; }
a_check()    { run_script install.sh --dir "$APP_DIR" --check; }
a_status()   { clear; docker ps -a --filter name=antibs --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  say ""; say "Пользователей в БД: $(docker exec "$PG" psql -U "$(db_user)" -d "$(db_name)" -tAc 'select count(*) from users' 2>/dev/null || echo '?')"
  say "Версия кода: $(git -C "$APP_DIR" log -1 --format='%h %cd %s' --date=short 2>/dev/null)"
  say "Меню: $VERSION"; pause; }
a_start()    { clear; each_stack up -d; pause; }
a_stop()     { yesno "Остановить бота и кабинет?" || return; clear; each_stack stop; pause; }
a_restart()  { clear; each_stack restart; pause; }
a_logs_bot() { clear; say "${c_b}Логи бота (Ctrl+C — выход)${c_0}"; ( docker logs -f --tail 200 antibs2vpn-bot ); pause; }
a_logs_cab() { clear; local c; c="$(docker ps -a --format '{{.Names}}' | grep -m1 -i cabinet)"
  [ -n "$c" ] || { msg "Контейнер кабинета не найден"; return; }
  say "${c_b}Логи кабинета (Ctrl+C — выход)${c_0}"; ( docker logs -f --tail 200 "$c" ); pause; }
a_backup_now() { local rc=0
  if [ -f "$APP_DIR/scripts/backup_full.sh" ]; then
    : >"$APP_DIR/backups/full_backup.now"
    bash "$APP_DIR/scripts/backup_full.sh" || rc=$?
    if [ "$rc" = 0 ]; then say "${c_g}Бэкап создан и отправлен в Telegram.${c_0}"; else warn "Код $rc: см. вывод выше (копия всё равно в backups/)."; fi
  else
    local f; f="$APP_DIR/backups/manual_$(date +%Y%m%d_%H%M%S).dump"; mkdir -p "$APP_DIR/backups"
    docker exec "$PG" pg_dump -U "$(db_user)" -Fc "$(db_name)" >"$f" && chmod 600 "$f" && say "Дамп БД: $f"
  fi; return "$rc"; }
a_backup()   { clear; a_backup_now; pause; }
a_list()     { clear; say "${c_b}Бэкапы в $APP_DIR/backups:${c_0}"
  find "$APP_DIR/backups" -maxdepth 1 \( -name '*.zip' -o -name '*.dump' -o -name '*.enc' \) -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' 2>/dev/null | sort -r | grep . || say "(нет)"
  say ""; du -sh "$APP_DIR/backups" 2>/dev/null; pause; }
pick_backup() {
  local files=() f items=()
  while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$APP_DIR"/backups/*.zip "$APP_DIR"/backups/*.enc "$APP_DIR"/backups/*.dump 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || { msg "В $APP_DIR/backups нет бэкапов"; return 1; }
  for f in "${files[@]}"; do items+=("$(basename "$f")" "$(du -h "$f" | cut -f1)"); done
  f="$(choose "Выбор бэкапа" "Рекомендуется antibs2vpn-fullbackup_*" "${items[@]}")"
  [ -n "$f" ] && echo "$APP_DIR/backups/$f"
}
a_env()      { local f="$APP_DIR/.env" ed
  if [ -f "$CAB_DIR/.env" ]; then
    f="$(choose ".env" "Какой файл редактировать?" "$APP_DIR/.env" "настройки бота" "$CAB_DIR/.env" "настройки кабинета")"; [ -n "$f" ] || return
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

# --- подменю ------------------------------------------------------------------------------
loop() { local fn="$1" r; while :; do r="$("$fn")"; [ -z "$r" ] && return; dispatch "$r"; done; }

m_bot() { choose "Бот" "Управление контейнерами бота и кабинета" \
  "Статус"          "контейнеры, число пользователей, версия кода" \
  "Запустить"       "поднять бота, БД и кабинет" \
  "Остановить"      "остановить бота и кабинет (данные сохраняются)" \
  "Перезапустить"   "перезапуск всех контейнеров" \
  "Логи бота"       "последние 200 строк и далее в реальном времени" \
  "Логи кабинета"   "журнал Личного кабинета" \
  "Редактировать .env" "изменить настройки бота/кабинета в редакторе" \
  "Консоль БД"      "psql внутри контейнера PostgreSQL" \
  "Проверка"        "health check: контейнеры, БД, Telegram, HTTPS"; }
m_backup() { choose "Бэкапы" "Создание, хранение и восстановление" \
  "Сделать бэкап сейчас" "полный бэкап (БД + код + .env) и отправка в Telegram" \
  "Список бэкапов"  "файлы в backups/, размер и дата" \
  "Восстановить"    "восстановить данные из бэкапа (restore.sh)" \
  "Расписание"      "время бэкапов (МСК) и сколько хранить" \
  "Шифрование"      "пароль AES-256 для бэкапов (вкл/выкл)" \
  "Яндекс.Диск"     "копировать бэкапы на Яндекс.Диск (OAuth-токен)"; }
m_update() { choose "Обновления" "Код бота и это меню" \
  "Обновить бота"   "git pull + пересборка; перед этим дамп БД" \
  "Откатить обновление" "вернуть прошлую версию кода и (по желанию) БД" \
  "Обновить меню"   "проверить новую версию antibs (сейчас $VERSION)"; }
m_domain() { choose "Домены / HTTPS" "Caddy и сертификаты Let's Encrypt" \
  "Сменить домены"  "новые домены Mini App и кабинета (.env + Caddy)" \
  "Сертификаты"     "показать сроки действия сертификатов" \
  "Перевыпустить сертификаты" "удалить и получить сертификаты заново"; }
m_server() { choose "Сервер" "Ресурсы, очистка, уведомления" \
  "Мониторинг"      "CPU, RAM, диск, место Docker, размер логов" \
  "Очистка Docker"  "удалить неиспользуемые образы и кэш (с подтверждением)" \
  "Ротация логов"   "ограничить размер логов Docker и бэкап-лога" \
  "Уведомления"     "сообщения в Telegram, если бот упал (вкл/выкл)"; }
m_security() { choose "Безопасность" "Защита сервера" \
  "Firewall (ufw)"  "открыть только SSH, 80, 443 — остальное закрыть" \
  "Fail2ban"        "бан IP после 5 неудачных входов по SSH" \
  "SSH только по ключу" "запретить вход по паролю (с автооткатом через 5 мин)"; }

dispatch() {
  case "$1" in
    "Установить"|"Установить / перенастроить") a_install;;
    "Восстановить"|"Восстановить из бэкапа") a_restore;;
    "Статус") a_status;; "Запустить") a_start;; "Остановить") a_stop;; "Перезапустить") a_restart;;
    "Логи бота") a_logs_bot;; "Логи кабинета") a_logs_cab;; "Редактировать .env") a_env;;
    "Консоль БД") a_psql;; "Проверка") a_check;;
    "Сделать бэкап сейчас") a_backup;; "Список бэкапов") a_list;;
    "Расписание") t_schedule;; "Шифрование") t_encrypt;; "Яндекс.Диск") t_yadisk;;
    "Обновить бота") a_update;; "Откатить обновление") t_rollback;; "Обновить меню") t_selfupdate;;
    "Сменить домены") t_domains_change;; "Сертификаты") t_cert_show;; "Перевыпустить сертификаты") t_cert_reissue;;
    "Мониторинг") t_monitor;; "Очистка Docker") t_prune;; "Ротация логов") t_logrotate;; "Уведомления") t_alerts;;
    "Firewall (ufw)") t_ufw;; "Fail2ban") t_fail2ban;; "SSH только по ключу") t_ssh_keys;;
    "Перенос на сервер") t_migrate;; "Удалить") a_uninstall;;
    "Бот") loop m_bot;; "Бэкапы") loop m_backup;; "Обновления") loop m_update;;
    "Домены / HTTPS") loop m_domain;; "Сервер") loop m_server;; "Безопасность") loop m_security;;
    *) ;;
  esac
}

main_menu() {
  local st r
  if installed; then
    st="установлен в $APP_DIR"
    if docker ps --format '{{.Names}}' | grep -qx antibs2vpn-bot; then st="$st, бот работает"; else st="$st, бот ОСТАНОВЛЕН"; fi
    r="$(choose "AntiBS2vpn $VERSION" "Статус: $st" \
      "Бот"            "статус, запуск/остановка, логи, .env, консоль БД" \
      "Бэкапы"         "создать, список, восстановить, расписание, шифрование, Я.Диск" \
      "Обновления"     "обновить бота, откатить обновление, обновить меню" \
      "Домены / HTTPS" "сменить домены, сроки и перевыпуск сертификатов" \
      "Сервер"         "мониторинг, очистка Docker, ротация логов, уведомления" \
      "Безопасность"   "firewall, fail2ban, SSH только по ключу" \
      "Перенос на сервер" "бэкап → копия на новый сервер → восстановление там" \
      "Установить / перенастроить" "повторно пройти установщик (значения сохраняются)" \
      "Удалить"        "удалить бота с сервера (с вопросами)" \
      "Выход"          "закрыть меню")"
  else
    r="$(choose "AntiBS2vpn $VERSION" "Бот не установлен в $APP_DIR.\nОстальные пункты появятся после установки." \
      "Установить"     "установка с нуля: Docker, бот, БД, кабинет, HTTPS" \
      "Восстановить из бэкапа" "установка + данные из бэкапа (перенос со старого сервера)" \
      "Обновить меню"  "проверить новую версию antibs" \
      "Выход"          "закрыть меню")"
  fi
  case "$r" in ""|"Выход") clear; exit 0;; *) dispatch "$r";; esac
}

offer_self_install
while :; do main_menu; done
