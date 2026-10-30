#!/usr/bin/env bash
# Удаление AntiBS2vpn.
#   bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/uninstall.sh)
set -euo pipefail
APP_DIR="${APP_DIR:-/opt/AntiBS2vpn}"; PROXY_DIR="${PROXY_DIR:-/opt/antibs-proxy}"
[ "$(id -u)" = 0 ] || { echo "Запустите от root"; exit 1; }
ask() { local a; read -r -p "$1 [д/Н]: " a </dev/tty; [[ "$a" =~ ^([YyДд]|yes|да)$ ]]; }
ask "Остановить и удалить контейнеры бота, кабинета и Caddy?" || exit 0
if [ -d "$APP_DIR" ] && ask "Сделать дамп БД в /root перед удалением?"; then
  docker exec antibs2vpn-postgres pg_dump -U vpn_bot -Fc vpn_bot > "/root/antibs2vpn_$(date +%Y%m%d_%H%M%S).dump" && echo "[+] дамп сохранён в /root" || true
fi
systemctl disable --now antibs-recreate-watch 2>/dev/null || true
rm -f /etc/systemd/system/antibs-recreate-watch.service /usr/local/bin/antibs-recreate-watch.sh; systemctl daemon-reload
( crontab -l 2>/dev/null | grep -v 'scripts/backup_full.sh' ) | crontab - || true
[ -d "$APP_DIR/AntiBS2vpn-cabinet" ] && (cd "$APP_DIR/AntiBS2vpn-cabinet" && docker compose down) || true
[ -f "$PROXY_DIR/docker-compose.yml" ] && ask "Удалить Caddy ($PROXY_DIR, сертификаты)?" && { (cd "$PROXY_DIR" && docker compose down); rm -rf "$PROXY_DIR"; }
if [ -d "$APP_DIR" ]; then
  if ask "УДАЛИТЬ БАЗУ ДАННЫХ (том postgres) безвозвратно?"; then (cd "$APP_DIR" && docker compose down -v); else (cd "$APP_DIR" && docker compose down); fi
  ask "Удалить каталог $APP_DIR (код, .env, backups)?" && rm -rf "$APP_DIR"
fi
ask "Удалить сохранённый GitHub-токен /etc/antibs2vpn?" && rm -rf /etc/antibs2vpn
docker network rm antibs2vpn 2>/dev/null || true
echo "[+] Готово"
