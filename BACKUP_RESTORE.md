# Бэкап и восстановление AntiBS2vpn

## Как работают ежедневные бэкапы

### 1. Полный бэкап (основной) — 00:05 МСК
- Запускается через cron: `scripts/backup_full.sh` вызывается каждые 5 минут и срабатывает в заданное в админке время (по умолчанию 00:05 МСК).
- Создаёт `antibs2vpn-fullbackup_ГГГГММДД_ЧЧММСС.zip`:
  - `db.dump` — полный дамп PostgreSQL (`pg_dump -Fc`, все таблицы);
  - `code.tgz` — код бота и личного кабинета **вместе с файлами `.env`** (бота и кабинета);
  - `README.md` и вспомогательный `install.sh`.
- Отправляется в Telegram администраторам (чаты задаются в админке бота).
- Локально хранятся последние 7 архивов в `/opt/AntiBS2vpn/backups/`.
- Лог: `/var/log/antibs2vpn_backup.log`.

### 2. Встроенный JSON-бэкап бота — 03:05 МСК
- Делает сам бот: `bot_backup_ГГГГ-ММ-ДД_ЧЧММСС.zip` с JSON только 7 таблиц: users, tariffs, subscriptions, payments, transactions, promocodes, settings.
- Отправляется в Telegram и хранится в `backups/`.
- **Не подходит для переноса на новый сервер**: в нём нет панелей, доп. услуг, текстов и картинок экранов, админов и др. Используйте полный бэкап.

## Восстановление на новом сервере (пошагово)
1. Подготовьте чистый сервер (Ubuntu/Debian) и переведите A-записи ваших доменов на IP нового сервера.
2. Скачайте из Telegram последний `antibs2vpn-fullbackup_*.zip` и загрузите его на сервер:
   ```bash
   scp antibs2vpn-fullbackup_XXXX.zip root@<IP_нового_сервера>:/root/
   ```
3. **Остановите бота на старом сервере** (два бота с одним токеном будут конфликтовать):
   ```bash
   cd /opt/AntiBS2vpn && docker compose stop bot
   ```
4. На новом сервере запустите установщик с бэкапом:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/install.sh -o install.sh
   sudo bash install.sh --restore /root/antibs2vpn-fullbackup_XXXX.zip
   ```
   Понадобится GitHub-токен для доступа к приватному репозиторию бота (см. README).
5. Установщик возьмёт `.env` бота и кабинета из `code.tgz` — на вопросы просто жмите **Enter**, чтобы оставить значения из бэкапа.
6. Установщик поднимет PostgreSQL, восстановит `db.dump` в пустую БД до первого запуска бота, затем запустит бота, кабинет и Caddy (HTTPS-сертификаты выпустятся заново).
7. Проверки:
   - `/start` в боте и вход в админку;
   - `docker ps` — контейнеры `antibs2vpn-bot`, `antibs2vpn-postgres`, кабинет и Caddy запущены;
   - `docker logs antibs2vpn-bot --tail 50` — без ошибок;
   - открываются Mini App и личный кабинет по HTTPS;
   - `sudo bash install.sh --check` — автоматическая проверка.

## Ручное восстановление (бот уже установлен)
```bash
cd /opt/AntiBS2vpn
unzip -o /root/antibs2vpn-fullbackup_XXXX.zip db.dump -d /tmp/rb
docker compose stop bot
docker cp /tmp/rb/db.dump antibs2vpn-postgres:/tmp/db.dump
docker exec antibs2vpn-postgres pg_restore -U vpn_bot -d vpn_bot --clean --if-exists --no-owner --no-privileges /tmp/db.dump
docker exec antibs2vpn-postgres rm -f /tmp/db.dump
docker compose start bot
rm -rf /tmp/rb
```
Если нужны старые настройки — достаньте `.env` из архива: `unzip -p backup.zip code.tgz | tar xzf - -C /tmp/rb ./.env ./AntiBS2vpn-cabinet/.env` и сравните с текущими.

Только JSON-бэкап (частичное восстановление, бот должен быть запущен):
```bash
cp bot_backup_XXXX.zip /opt/AntiBS2vpn/backups/
cd /opt/AntiBS2vpn && docker compose exec bot python -m scripts.restore_backup /app/backups/bot_backup_XXXX.zip
docker compose restart bot
```

## Риски и ограничения
- **Секреты в открытом виде**: полный zip содержит `.env` (токен бота, пароль БД, ключи платёжных систем). Храните архив как пароль, не пересылайте в общие чаты.
- **Единственная внешняя копия — Telegram**. Локальные копии лежат на том же сервере. Рекомендуется периодически сохранять бэкап в отдельное хранилище.
- **Картинки экранов** хранятся как Telegram `file_id` — работают только с тем же токеном бота. При смене бота загрузите картинки заново.
- **Caddy** (конфиг и сертификаты в `/opt/antibs-proxy`) не входит в бэкап: установщик создаёт конфиг заново, сертификаты Let's Encrypt выпускаются автоматически (домены должны указывать на новый сервер, порты 80/443 открыты).
- JSON-бэкап — частичный, для переноса не используйте.
