#!/usr/bin/env bash
# =============================================================================
#  AntiBS2vpn — функции расширенных пунктов меню antibs.sh.
#  Подключается из antibs.sh (source); отдельно не запускается.
#  Использует из antibs.sh: APP_DIR CAB_DIR PROXY_DIR STATE_DIR PG RAW TTY,
#  msg yesno input pause choose say warn ok_ dc each_stack env_get db_user db_name a_backup
# =============================================================================
# shellcheck disable=SC2154

BK_ENV="$STATE_DIR/backup.env"
PASS_FILE="$STATE_DIR/backup.pass"
YA_TOKEN_FILE="$STATE_DIR/yadisk.token"

secure_dir() { mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"; }
kv_set() { # kv_set file KEY VALUE
  local f="$1" k="$2" v="$3"; touch "$f"; chmod 600 "$f"
  if grep -qE "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else printf '%s=%s\n' "$k" "$v" >>"$f"; fi
}
read_secret() { # read_secret "prompt" -> stdout
  if [ "$PLAIN" = 0 ]; then whiptail --title "AntiBS2vpn" --passwordbox "$1" 10 72 3>&1 1>"$TTY" 2>&3 <"$TTY"; return; fi
  local s; printf '%s: ' "$1" >"$TTY"; IFS= read -rs s <"$TTY" || true; echo >"$TTY"; printf '%s' "$s"
}
psql_q() { docker exec -i "$PG" psql -U "$(db_user)" -d "$(db_name)" -v ON_ERROR_STOP=1 -tAq "$@"; }
setting_get() { psql_q -c "select value from settings where key='$1'" 2>/dev/null; }
setting_set() { psql_q -v k="$1" -v v="$2" <<'SQL'
INSERT INTO settings(key, value) VALUES (:'k', :'v') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SQL
}
domain_of() { local u="${1#*://}"; u="${u%%/*}"; echo "${u%%:*}"; }
server_ip() { curl -4fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }

# ============================ БЭКАПЫ =========================================
t_encrypt() {
  secure_dir
  local cur; cur="$(env_get "$BK_ENV" ENCRYPT)"
  if [ "$cur" = 1 ] && yesno "Шифрование включено. Выключить?\n(Новые бэкапы будут без пароля.)"; then
    kv_set "$BK_ENV" ENCRYPT 0; msg "Шифрование выключено."; return
  fi
  local p1 p2
  p1="$(read_secret "Пароль для бэкапов (мин. 10 символов). Запишите его — без него бэкап не восстановить!")" || return
  [ "${#p1}" -ge 10 ] || { msg "Слишком короткий пароль."; return; }
  p2="$(read_secret "Повторите пароль")" || return
  [ "$p1" = "$p2" ] || { msg "Пароли не совпадают."; return; }
  ( umask 077; printf '%s' "$p1" >"$PASS_FILE" ); unset p1 p2
  kv_set "$BK_ENV" ENCRYPT 1
  msg "Готово. Новые full-бэкапы шифруются AES-256 (файл *.zip.enc).\nПароль хранится в $PASS_FILE (только root).\nrestore.sh спросит пароль при восстановлении на другом сервере.\n\nВажно: нужен обновлённый scripts/backup_full.sh (меню «Обновить»)."
}
t_yadisk() {
  secure_dir
  if [ "$(env_get "$BK_ENV" YADISK)" = 1 ] && yesno "Копия на Яндекс.Диск включена. Выключить?"; then
    kv_set "$BK_ENV" YADISK 0; msg "Выключено."; return
  fi
  msg "Нужен OAuth-токен Яндекс.Диска:\n1) https://oauth.yandex.ru/client/new — создайте приложение, доступ «Яндекс.Диск REST API: запись/чтение», Redirect URI: https://oauth.yandex.ru/verification_code\n2) Откройте https://oauth.yandex.ru/authorize?response_type=token&client_id=<ClientID>\n3) Скопируйте токен."
  local tok dir code
  tok="$(read_secret "OAuth-токен Яндекс.Диска")" || return
  [ -n "$tok" ] || return
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 -H "Authorization: OAuth $tok" https://cloud-api.yandex.net/v1/disk/)"
  [ "$code" = 200 ] || { msg "Токен не подошёл (HTTP $code)."; return; }
  dir="$(input "Папка на Диске" "AntiBS2vpn-backups")" || return
  ( umask 077; printf '%s' "$tok" >"$YA_TOKEN_FILE" ); unset tok
  kv_set "$BK_ENV" YADISK 1; kv_set "$BK_ENV" YADISK_DIR "${dir:-AntiBS2vpn-backups}"
  msg "Готово. Каждый full-бэкап будет копироваться в disk:/${dir:-AntiBS2vpn-backups}.\nСтарые файлы на Диске не удаляются автоматически."
}
t_schedule() {
  local full db keep jkeep
  full="$(setting_get full_bk_time)"; db="$(setting_get db_bk_time)"
  keep="$(env_get "$BK_ENV" KEEP)"; jkeep="$(env_get "$APP_DIR/.env" BACKUP_KEEP)"
  msg "Время бэкапов хранится в настройках бота (админка → Бэкапы).\nБот каждые 20 с переписывает backups/full_backup.conf из своих настроек, поэтому меняем именно настройки бота (в БД) — cron трогать не нужно: он запускает backup_full.sh каждые 5 мин, а тот сверяет время МСК.\n\nСейчас: full ${full:-00:05} МСК, JSON ${db:-03:05} МСК\nХранить: full ${keep:-7} шт., JSON ${jkeep:-7} шт."
  local nf nd nk nj
  nf="$(input "Время full-бэкапа, ЧЧ:ММ МСК (кратно 5 мин)" "${full:-00:05}")" || return
  nd="$(input "Время JSON-бэкапа, ЧЧ:ММ МСК" "${db:-03:05}")" || return
  nk="$(input "Сколько full-бэкапов хранить на сервере" "${keep:-7}")" || return
  nj="$(input "Сколько JSON-бэкапов хранить" "${jkeep:-7}")" || return
  local re='^([01][0-9]|2[0-3]):[0-5][05]$'
  [[ "$nf" =~ $re ]] && [[ "$nd" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { msg "Неверный формат времени (full — минуты кратны 5)."; return; }
  [[ "$nk" =~ ^[1-9][0-9]?$ ]] && [[ "$nj" =~ ^[1-9][0-9]?$ ]] || { msg "Количество: 1..99"; return; }
  setting_set full_bk_time "$nf" && setting_set db_bk_time "$nd" || { msg "Не удалось записать настройки в БД."; return; }
  [ -f "$APP_DIR/backups/full_backup.conf" ] && sed -i "s|^TIME_MSK=.*|TIME_MSK=$nf|" "$APP_DIR/backups/full_backup.conf"
  secure_dir; kv_set "$BK_ENV" KEEP "$nk"
  if [ "$nj" != "${jkeep:-7}" ]; then kv_set "$APP_DIR/.env" BACKUP_KEEP "$nj"; dc "$APP_DIR" up -d bot >/dev/null 2>&1; fi
  crontab -l 2>/dev/null | grep -q 'scripts/backup_full.sh' || warn "cron для backup_full.sh не найден — запустите «Установить»"
  msg "Сохранено: full $nf МСК (хранить $nk), JSON $nd МСК (хранить $nj).\nИзменения из админки бота имеют приоритет и перезапишут время."
}

# ============================ ОБНОВЛЕНИЯ ======================================
t_rollback() {
  local f="$STATE_DIR/last_update"
  [ -f "$f" ] || { msg "Нет данных о прошлом обновлении (они появляются после «Обновить»)."; return; }
  local pc pd at cur
  pc="$(env_get "$f" PREV_COMMIT)"; pd="$(env_get "$f" PREV_DUMP)"; at="$(env_get "$f" UPDATED_AT)"
  cur="$(git -C "$APP_DIR" rev-parse --short HEAD)"
  yesno "Откатить код к версии до обновления от $at?\n\nСейчас: $cur → будет: ${pc:0:7}\nКод будет пересобран, .env не меняется." || return
  clear
  git -C "$APP_DIR" cat-file -e "$pc^{commit}" 2>/dev/null || { warn "Коммит $pc не найден"; pause; return; }
  git -C "$APP_DIR" reset --hard -q "$pc" && say "Код: $(git -C "$APP_DIR" log -1 --format='%h %s')"
  dc "$APP_DIR" up -d --build; dc "$CAB_DIR" up -d --build
  if [ -n "$pd" ] && [ -f "$pd" ] && yesno "Восстановить также БД из дампа перед обновлением?\n$(basename "$pd")\n\nДанные, появившиеся после обновления, будут потеряны (сначала будет страховочный дамп)."; then
    local p; p="$(script restore.sh)" && bash "$p" --dir "$APP_DIR" "$pd"
  fi
  say "Чтобы снова обновиться до последней версии — пункт «Обновить»."; pause
}
t_selfupdate() {
  local tmp rv
  tmp="$(mktemp)"; curl -fsSL "$RAW/antibs.sh" -o "$tmp" || { msg "Не удалось скачать antibs.sh"; rm -f "$tmp"; return; }
  rv="$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)"
  if [ -x "$BIN" ] && cmp -s "$tmp" "$BIN"; then msg "Установлена последняя версия ($VERSION)."; rm -f "$tmp"; return; fi
  if yesno "Доступна версия меню: ${rv:-?} (текущая $VERSION).\nУстановить в $BIN?"; then
    bash -n "$tmp" && install -m 755 "$tmp" "$BIN" && { rm -f "$tmp"; msg "Обновлено. Меню перезапустится."; exec "$BIN"; }
    msg "Ошибка установки."
  fi
  rm -f "$tmp"
}

# ============================ ДОМЕНЫ / HTTPS =================================
caddy_domains() { [ -f "$PROXY_DIR/Caddyfile" ] && sed -n '/# >>> antibs2vpn/,/# <<< antibs2vpn/p' "$PROXY_DIR/Caddyfile" | grep -E '^[A-Za-z0-9.-]+ \{' | awk '{print $1}'; }
caddy_reload() { docker exec antibs-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || dc "$PROXY_DIR" restart >/dev/null 2>&1; }
t_domains_change() {
  [ -f "$PROXY_DIR/Caddyfile" ] || { msg "Caddy не настроен установщиком ($PROXY_DIR). Домены меняются через «Установить / перенастроить»."; return; }
  local oa ol na nl ip
  oa="$(domain_of "$(env_get "$APP_DIR/.env" WEBAPP_URL)")"; ol="$(domain_of "$(env_get "$APP_DIR/.env" CABINET_PUBLIC_URL)")"
  na="$(input "Домен Mini App (сейчас ${oa:-—})" "$oa")" || return
  nl="$(input "Домен Личного кабинета (сейчас ${ol:-—})" "$ol")" || return
  [ "$na" = "$oa" ] && [ "$nl" = "$ol" ] && { msg "Ничего не изменилось."; return; }
  ip="$(server_ip)"
  local d r warnings=""
  for d in "$na" "$nl"; do
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9-]+)+$ ]] || { msg "Неверный домен: $d"; return; }
    r="$(getent ahostsv4 "$d" | awk 'NR==1{print $1}')"
    [ "$r" = "$ip" ] || warnings+="$d → ${r:-не резолвится} (сервер $ip)\n"
  done
  [ -z "$warnings" ] || yesno "DNS ещё не указывает на этот сервер:\n$warnings\nСертификат не выпустится, пока DNS не обновится. Продолжить?" || return
  local f ts; ts="$(date +%s)"
  for f in "$APP_DIR/.env" "$CAB_DIR/.env" "$PROXY_DIR/Caddyfile"; do
    [ -f "$f" ] || continue; cp -p "$f" "$f.bak.$ts"
    [ -n "$oa" ] && [ "$oa" != "$na" ] && sed -i "s/$(printf '%s' "$oa" | sed 's/\./\\./g')/$na/g" "$f"
    [ -n "$ol" ] && [ "$ol" != "$nl" ] && sed -i "s/$(printf '%s' "$ol" | sed 's/\./\\./g')/$nl/g" "$f"
  done
  clear; caddy_reload; each_stack up -d
  msg "Домены изменены: $na, $nl (резервные копии *.bak.$ts).\nНе забудьте обновить URL вебхуков в ЮKassa/Platega и Mini App в @BotFather."
}
t_cert_reissue() {
  local doms d; doms="$(caddy_domains)"; [ -n "$doms" ] || { msg "Домены Caddy не найдены."; return; }
  yesno "Перевыпустить сертификаты для:\n$doms\n\nСтарые сертификаты будут удалены. Let's Encrypt ограничивает частоту (5 в неделю на домен)." || return
  for d in $doms; do find "$PROXY_DIR/data/caddy/certificates" -maxdepth 2 -type d -name "$d" -exec rm -rf {} + 2>/dev/null; done
  clear; dc "$PROXY_DIR" restart; sleep 20; t_cert_show
}
t_cert_show() {
  local d out=""
  for d in $(caddy_domains) $(domain_of "$(env_get "$APP_DIR/.env" WEBAPP_URL)"); do
    [[ "$out" == *"$d:"* ]] && continue
    out+="$d: $(echo | timeout 10 openssl s_client -servername "$d" -connect "$d:443" 2>/dev/null | openssl x509 -noout -enddate -issuer 2>/dev/null | sed 's/notAfter=/до /;s/issuer=.*O = /выдан: /;s/, CN.*//' | tr '\n' ' ' || echo 'нет ответа')\n"
  done
  msg "Сертификаты HTTPS:\n\n${out:-домены не найдены}"
}

# ============================ СЕРВЕР =========================================
t_monitor() {
  clear
  say "== Нагрузка ==";  uptime
  say "== CPU ==";       top -bn1 | sed -n '3p'
  say "== Память ==";    free -h
  say "== Диск ==";      df -h / "$APP_DIR" 2>/dev/null | awk '!s[$0]++'
  say "== Контейнеры (CPU/RAM) =="; docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null
  say "== Docker (место) =="; docker system df 2>/dev/null
  say "== Логи =="
  local c; for c in $(docker ps -a --format '{{.Names}}' | grep -i antibs); do
    printf '  %-24s %s\n' "$c" "$(du -h "$(docker inspect -f '{{.LogPath}}' "$c" 2>/dev/null)" 2>/dev/null | cut -f1)"; done
  du -ch /var/log/antibs2vpn_*.log 2>/dev/null | tail -1 | sed 's/^/  лог бэкапов: /'
  du -sh "$APP_DIR/backups" 2>/dev/null | sed 's/^/  backups: /'
  pause
}
t_prune() {
  clear; docker system df
  yesno "Удалить неиспользуемые образы, остановленные контейнеры, кэш сборки?\n(Тома с данными НЕ удаляются.)" || return
  clear; docker system prune -af; docker builder prune -af; pause
}
t_logrotate() {
  local dj=/etc/docker/daemon.json
  if [ -f "$dj" ] && grep -q '"log-opts"' "$dj"; then msg "В $dj уже есть log-opts:\n$(cat "$dj")"
  elif yesno "Ограничить логи контейнеров: 10 МБ × 3 файла на контейнер?\nПотребуется перезапуск Docker (контейнеры перезапустятся, ~30 с простоя)."; then
    if [ -f "$dj" ] && [ -s "$dj" ]; then
      cp -p "$dj" "$dj.bak.$(date +%s)"
      python3 - "$dj" <<'PY' || { msg "Не удалось изменить $dj"; return; }
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["log-driver"]="json-file"; d["log-opts"]={"max-size":"10m","max-file":"3"}; json.dump(d,open(p,"w"),indent=2)
PY
    else printf '{\n  "log-driver": "json-file",\n  "log-opts": {"max-size": "10m", "max-file": "3"}\n}\n' >"$dj"; fi
    clear; systemctl restart docker && sleep 5
    each_stack up -d --force-recreate; [ -f "$PROXY_DIR/docker-compose.yml" ] && dc "$PROXY_DIR" up -d --force-recreate; pause
  fi
  cat >/etc/logrotate.d/antibs2vpn <<'LR'
/var/log/antibs2vpn_*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
LR
  msg "logrotate для /var/log/antibs2vpn_*.log настроен (еженедельно, 4 архива)."
}

# ============================ УВЕДОМЛЕНИЯ ====================================
WD_BIN=/usr/local/sbin/antibs-watchdog
t_alerts() {
  if systemctl is-active -q antibs-watchdog.timer 2>/dev/null; then
    yesno "Уведомления включены. Выключить?" && { systemctl disable --now antibs-watchdog.timer >/dev/null 2>&1; msg "Выключено."; }
    return
  fi
  local chat n
  chat="$(input "Telegram ID получателя (по умолчанию — первый админ)" "$(env_get "$APP_DIR/.env" ADMIN_IDS | cut -d, -f1)")" || return
  [[ "$chat" =~ ^-?[0-9]+$ ]] || { msg "Нужен числовой ID."; return; }
  n="$(input "Проверять каждые N минут" "5")" || return
  [[ "$n" =~ ^[1-9][0-9]?$ ]] || { msg "1..99"; return; }
  secure_dir
  printf 'APP_DIR=%s\nCHAT=%s\n' "$APP_DIR" "$chat" >"$STATE_DIR/watchdog.env"; chmod 600 "$STATE_DIR/watchdog.env"
  cat >"$WD_BIN" <<'WD'
#!/usr/bin/env bash
# AntiBS2vpn watchdog: проверка и уведомление в Telegram только при смене состояния.
set -uo pipefail
. /etc/antibs2vpn/watchdog.env
ST=/var/lib/antibs2vpn-watchdog.state
TOKEN="$(grep -E '^BOT_TOKEN=' "$APP_DIR/.env" | cut -d= -f2- | tr -d '\r"')"
problems=()
for c in antibs2vpn-bot antibs2vpn-postgres antibs2vpn_cabinet; do
  s="$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo 'нет')"
  case "$s" in running|running/healthy|running/starting) ;; *) problems+=("$c: $s");; esac
done
docker exec antibs2vpn-postgres pg_isready -q 2>/dev/null || problems+=("PostgreSQL не отвечает")
url="$(grep -E '^WEBAPP_URL=' "$APP_DIR/.env" | cut -d= -f2- | tr -d '\r"')"
if [[ "$url" == https://* ]]; then curl -fsS -m 15 -o /dev/null "$url/health" || problems+=("$url/health недоступен"); fi
free_pct="$(df --output=pcent / | tail -1 | tr -dc 0-9)"; [ "${free_pct:-0}" -ge 95 ] && problems+=("Диск заполнен на ${free_pct}%")
if [ ${#problems[@]} -eq 0 ]; then state=OK; text="✅ AntiBS2vpn ($(hostname)): всё снова работает"
else state="FAIL:$(printf '%s;' "${problems[@]}")"; text="🚨 AntiBS2vpn ($(hostname)): проблема"$'\n'"$(printf '• %s\n' "${problems[@]}")"; fi
prev="$(cat "$ST" 2>/dev/null || echo OK)"
[ "$state" = "$prev" ] && exit 0
echo "$state" >"$ST"
[ "$state" = OK ] && [ "$prev" = OK ] && exit 0
curl -sS -m 20 -o /dev/null --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$text" "https://api.telegram.org/bot$TOKEN/sendMessage" || true
WD
  chmod 755 "$WD_BIN"
  cat >/etc/systemd/system/antibs-watchdog.service <<EOS
[Unit]
Description=AntiBS2vpn watchdog
[Service]
Type=oneshot
ExecStart=$WD_BIN
EOS
  cat >/etc/systemd/system/antibs-watchdog.timer <<EOS
[Unit]
Description=AntiBS2vpn watchdog every $n min
[Timer]
OnBootSec=3min
OnUnitActiveSec=${n}min
[Install]
WantedBy=timers.target
EOS
  systemctl daemon-reload && systemctl enable --now antibs-watchdog.timer >/dev/null 2>&1
  local tk; tk="$(env_get "$APP_DIR/.env" BOT_TOKEN)"
  curl -sS -m 20 -o /dev/null --data-urlencode "chat_id=$chat" --data-urlencode "text=🔔 Уведомления AntiBS2vpn включены: проверка каждые $n мин." "https://api.telegram.org/bot$tk/sendMessage" || true
  msg "Включено: проверка каждые $n мин (контейнеры, БД, /health, диск).\nСообщение приходит только при смене состояния (сбой / восстановление).\nТестовое сообщение отправлено — проверьте Telegram."
}

# ============================ БЕЗОПАСНОСТЬ ===================================
ssh_ports() { sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -u; }
t_ufw() {
  command -v ufw >/dev/null || { apt-get install -y -qq ufw >/dev/null 2>&1 || { msg "Не удалось установить ufw"; return; }; }
  local ports p extra=""; ports="$(ssh_ports)"; ports="${ports:-22}"
  grep -q ':8090' "$CAB_DIR/.env" 2>/dev/null && extra="8090"
  yesno "Включить firewall ufw?\nБудут открыты: SSH ($(echo "$ports" | tr '\n' ' ')), 22, 80, 443 ${extra:+, $extra (кабинет по http)}\nВсё остальное входящее — закрыто.\n\nПримечание: порты, опубликованные Docker, ufw не закрывает." || return
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  for p in $ports 22 80 443 $extra; do ufw allow "$p/tcp" >/dev/null; done
  ufw --force enable >/dev/null
  msg "ufw включён:\n$(ufw status | head -20)"
}
t_fail2ban() {
  yesno "Установить fail2ban для SSH?\n5 неудачных входов за 10 мин → бан IP на 1 час." || return
  clear; apt-get install -y -qq fail2ban >/dev/null 2>&1 || { msg "Не удалось установить fail2ban"; return; }
  local ports; ports="$(ssh_ports | paste -sd, -)"
  cat >/etc/fail2ban/jail.d/antibs-sshd.conf <<EOF2
[sshd]
enabled = true
port = ${ports:-ssh}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF2
  systemctl enable --now fail2ban >/dev/null 2>&1; systemctl restart fail2ban
  sleep 2; msg "fail2ban работает:\n$(fail2ban-client status sshd 2>&1 | head -10)"
}
t_ssh_keys() {
  local ak=/root/.ssh/authorized_keys u="${SUDO_USER:-}" n=0 conf=/etc/ssh/sshd_config.d/00-antibs-keyonly.conf
  if [ -f "$conf" ]; then
    yesno "Вход только по ключу уже включён. Вернуть вход по паролю?" && { rm -f "$conf"; systemctl reload ssh 2>/dev/null || systemctl reload sshd; msg "Вход по паролю снова разрешён."; }
    return
  fi
  [ -s "$ak" ] && n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$ak")"
  [ -n "$u" ] && [ -s "/home/$u/.ssh/authorized_keys" ] && n=$((n + $(grep -cE '^(ssh-|ecdsa-|sk-)' "/home/$u/.ssh/authorized_keys")))
  if [ "$n" -lt 1 ]; then
    msg "Ключей SSH не найдено ($ak пуст).\nСначала добавьте ключ: на своём компьютере выполните\n  ssh-copy-id root@<IP_сервера>\nи убедитесь, что вход по ключу работает. Отмена."
    return
  fi
  grep -qiE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config || { msg "В sshd_config нет Include sshd_config.d — настройте вручную. Отмена."; return; }
  yesno "⚠ ОПАСНО: вход по паролю по SSH будет ЗАПРЕЩЁН.\nНайдено ключей: $n.\n\nЕсли ваш ключ не работает — вы потеряете доступ к серверу!\nЗащита: через 5 минут настройка автоматически откатится, если вы не подтвердите вход из НОВОГО окна терминала.\n\nПродолжить?" || return
  printf '# antibs: только вход по ключу\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nChallengeResponseAuthentication no\nPermitRootLogin prohibit-password\nPubkeyAuthentication yes\n' >"$conf"
  if ! sshd -t 2>/dev/null; then rm -f "$conf"; msg "Конфиг sshd невалиден — изменения отменены."; return; fi
  systemd-run --unit antibs-ssh-revert --on-active=300 /bin/sh -c "rm -f $conf; systemctl reload ssh || systemctl reload sshd" >/dev/null 2>&1 \
    || { rm -f "$conf"; msg "Не удалось поставить таймер автоотката — отмена ради безопасности."; return; }
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  local eff; eff="$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
  if yesno "Применено (passwordauthentication=$eff).\n\nСЕЙЧАС откройте НОВОЕ окно терминала и войдите на сервер по ключу.\nНЕ закрывайте это окно!\n\nВход по ключу в новом окне работает?"; then
    systemctl stop antibs-ssh-revert.timer >/dev/null 2>&1
    msg "Готово: вход только по ключу. Автооткат отменён."
  else
    systemctl stop antibs-ssh-revert.timer >/dev/null 2>&1; rm -f "$conf"; systemctl reload ssh 2>/dev/null || systemctl reload sshd
    msg "Откатено: вход по паролю снова разрешён."
  fi
}

# ============================ ПЕРЕНОС ========================================
t_migrate() {
  msg "Перенос на другой сервер:\n1) делается свежий full-бэкап;\n2) он копируется на новый сервер (scp);\n3) по желанию там запускается restore.sh (установка + восстановление).\n\nDNS доменов переключите на новый IP; старого бота остановите после проверки нового."
  local host user port f rf
  host="$(input "IP или хост нового сервера" "")" || return; [ -n "$host" ] || return
  user="$(input "Пользователь SSH" "root")" || return
  port="$(input "Порт SSH" "22")" || return
  [[ "$port" =~ ^[0-9]+$ ]] || { msg "Неверный порт"; return; }
  clear; say "== Шаг 1: бэкап =="
  a_backup_now || true
  f="$(ls -1t "$APP_DIR"/backups/antibs2vpn-fullbackup_*.zip* 2>/dev/null | head -1)"
  [ -n "$f" ] || { warn "Full-бэкап не найден"; pause; return; }
  say "Файл: $(basename "$f") ($(du -h "$f" | cut -f1))"
  say "== Шаг 2: копирование на $user@$host (пароль или ключ SSH спросит ssh) =="
  rf="/root/$(basename "$f")"; [ "$user" != root ] && rf="/tmp/$(basename "$f")"
  scp -P "$port" -o StrictHostKeyChecking=accept-new "$f" "$user@$host:$rf" <"$TTY" >"$TTY" 2>&1 || { warn "scp не удался"; pause; return; }
  say "Скопировано в $rf"
  if yesno "Запустить восстановление на новом сервере сейчас?\n(Сначала остановите бота здесь, иначе два бота будут конфликтовать — предложу следующим шагом.)"; then
    yesno "Остановить бота на ЭТОМ сервере перед запуском нового?" && dc "$APP_DIR" stop bot
    local sudo=""; [ "$user" != root ] && sudo="sudo "
    ssh -t -p "$port" "$user@$host" "${sudo}bash -c 'bash <(curl -fsSL $RAW/restore.sh) $rf'" <"$TTY" >"$TTY" 2>&1 || warn "Удалённое восстановление завершилось с ошибкой"
  else
    say "На новом сервере выполните:"; say "  bash <(curl -fsSL $RAW/restore.sh) $rf"
  fi
  pause
}
