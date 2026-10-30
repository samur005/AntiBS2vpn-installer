#!/usr/bin/env bash
# Обновление AntiBS2vpn: git pull + пересборка, .env и БД сохраняются.
#   bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/update.sh)
# Токен: --token TOKEN | env GITHUB_TOKEN | /etc/antibs2vpn/github_token | запрос.
set -euo pipefail
APP_DIR="${APP_DIR:-/opt/AntiBS2vpn}"; BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main"
TOKEN_FILE="/etc/antibs2vpn/github_token"
TOK="${GITHUB_TOKEN:-}"
while [ $# -gt 0 ]; do case "$1" in --token) TOK="$2"; shift 2;; --dir) APP_DIR="$2"; shift 2;; *) echo "Неизвестный параметр $1"; exit 1;; esac; done
[ "$(id -u)" = 0 ] || { echo "Запустите от root"; exit 1; }
[ -d "$APP_DIR/.git" ] || { echo "$APP_DIR не git-репозиторий. Сначала установите (install.sh)"; exit 1; }
[ -z "$TOK" ] && [ -f "$TOKEN_FILE" ] && TOK="$(cat "$TOKEN_FILE")"
git_auth() {
  if [ -n "$TOK" ]; then
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraHeader" \
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$TOK" | base64 -w0)" git "$@"
  else GIT_TERMINAL_PROMPT=0 git "$@"; fi
}
cd "$APP_DIR"
until git_auth ls-remote -q origin HEAD >/dev/null 2>&1; do
  printf 'GitHub-токен для приватного репозитория (ввод скрыт): ' >/dev/tty
  IFS= read -rs TOK </dev/tty || exit 1; echo >/dev/tty
done
echo "[+] Бэкап БД перед обновлением"
mkdir -p backups
U="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2-)"; D="$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2-)"
PRE="$APP_DIR/backups/pre_update_$(date +%Y%m%d_%H%M%S).dump"
docker exec antibs2vpn-postgres pg_dump -U "${U:-vpn_bot}" -Fc "${D:-vpn_bot}" > "$PRE" && chmod 600 "$PRE" || { echo "[!] дамп не удался"; PRE=""; }
OLD="$(git rev-parse --short HEAD)"
# для отката из меню antibs: предыдущий коммит + дамп БД
mkdir -p /etc/antibs2vpn
printf 'PREV_COMMIT=%s\nPREV_DUMP=%s\nUPDATED_AT=%s\n' "$(git rev-parse HEAD)" "$PRE" "$(date '+%F %T %Z')" >/etc/antibs2vpn/last_update
git_auth fetch -q origin "$BRANCH" && git merge --ff-only "origin/$BRANCH" || { echo "[x] git: есть локальные изменения (git status). Отмена."; exit 1; }
echo "[+] $OLD → $(git rev-parse --short HEAD)"
docker compose up -d --build
(cd AntiBS2vpn-cabinet && docker compose up -d --build)
if [ -f deploy/antibs-recreate-watch.sh ]; then
  sed "s#/opt/AntiBS2vpn#$APP_DIR#g" deploy/antibs-recreate-watch.sh > /usr/local/bin/antibs-recreate-watch.sh
  systemctl restart antibs-recreate-watch || true
fi
sleep 15
bash <(curl -fsSL "$RAW/install.sh") --check --dir "$APP_DIR"
