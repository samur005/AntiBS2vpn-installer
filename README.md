# AntiBS2vpn — установщик

Telegram-бот AntiBS2vpn (бот + PostgreSQL + Личный кабинет + HTTPS через Caddy) на сервер Ubuntu 22.04+/Debian 11+.

## Быстрый старт — одна команда (от root)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/antibs.sh)
```

Откроется меню (whiptail; если его нет — ставится автоматически, иначе текстовое меню с номерами). У каждого пункта — короткое пояснение. После каждого действия меню возвращается. При первом запуске меню предложит установить себя как команду `antibs`.

### Дерево меню

Пока бот не установлен: **Установить** · **Восстановить из бэкапа** (установка + данные) · **Обновить меню** · **Выход**.

После установки:
```
AntiBS2vpn
├─ Бот
│  ├─ Статус                 — контейнеры, число пользователей, версия кода
│  ├─ Запустить / Остановить / Перезапустить
│  ├─ Логи бота / Логи кабинета — в реальном времени (Ctrl+C — назад)
│  ├─ Редактировать .env     — с резервной копией и перезапуском
│  ├─ Консоль БД             — psql
│  └─ Проверка               — health check (install.sh --check)
├─ Бэкапы
│  ├─ Сделать бэкап сейчас   — полный (БД + код + .env) → Telegram
│  ├─ Список бэкапов
│  ├─ Восстановить           — restore.sh (расшифрует *.enc)
│  ├─ Расписание             — время (МСК) и сколько хранить
│  ├─ Шифрование             — пароль AES-256 (/etc/antibs2vpn/backup.pass, только root)
│  └─ Яндекс.Диск            — копия каждого бэкапа (OAuth-токен)
├─ Обновления
│  ├─ Обновить бота          — git pull + пересборка, перед этим дамп БД
│  ├─ Откатить обновление    — прошлый коммит + (по желанию) дамп БД до обновления
│  └─ Обновить меню          — новая версия antibs
├─ Домены / HTTPS
│  ├─ Сменить домены         — .env + Caddyfile, перезагрузка Caddy
│  ├─ Сертификаты            — сроки действия
│  └─ Перевыпустить сертификаты
├─ Сервер
│  ├─ Мониторинг             — CPU, RAM, диск, Docker, размер логов
│  ├─ Очистка Docker         — docker system prune (с подтверждением)
│  ├─ Ротация логов          — лимит логов Docker 10 МБ×3, logrotate
│  └─ Уведомления            — Telegram при падении/восстановлении (systemd timer)
├─ Безопасность
│  ├─ Firewall (ufw)         — SSH-порт, 22, 80, 443
│  ├─ Fail2ban               — защита SSH от перебора
│  └─ SSH только по ключу    — с проверкой ключей и автооткатом через 5 мин
├─ Перенос на сервер         — бэкап → scp на новый сервер → restore там
├─ Установить / перенастроить
└─ Удалить
```

Пояснения:
- **Расписание.** Время бэкапов хранится в настройках бота (админка → Бэкапы); бот каждые 20 с переписывает `backups/full_backup.conf`. Меню меняет именно эти настройки, поэтому изменения из админки имеют приоритет. Cron не меняется: он запускает `backup_full.sh` каждые 5 минут, скрипт сам сверяет время МСК.
- **Шифрование/Яндекс.Диск/хранение** — `/etc/antibs2vpn/backup.env` (читает `scripts/backup_full.sh`; нужна свежая версия бота — «Обновить бота»).
- **Уведомления** — `/usr/local/sbin/antibs-watchdog` + `antibs-watchdog.timer`; сообщение только при смене состояния.
- Логика пунктов — в `antibs-tools.sh`; установка/восстановление/обновление/удаление — отдельные скрипты ниже.

## Отдельные скрипты (запускать от root)


```bash
# Установка (или повторная настройка)
bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/install.sh)

# Обновление
bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/update.sh)

# Проверка работы
bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/install.sh) --check

# Удаление
bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/uninstall.sh)
```

## Доступ к приватному репозиторию бота

Код бота лежит в **приватном** репозитории, поэтому установщику нужен GitHub-токен только для чтения:

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token** (https://github.com/settings/personal-access-tokens/new).
2. Token name: `antibs2vpn-server`, Expiration — на ваше усмотрение (например, 1 год).
3. **Repository access → Only select repositories →** выберите репозиторий бота.
4. **Permissions → Repository permissions → Contents: Read-only** (Metadata: Read-only выставится автоматически). Больше ничего не нужно.
5. Generate token и скопируйте значение `github_pat_...`.

Как передать токен:
- установщик спросит его сам (ввод скрыт), или
- `GITHUB_TOKEN=github_pat_... bash <(curl ...install.sh)`, или
- `bash <(curl ...install.sh) --token github_pat_...` (попадёт в историю shell — менее безопасно).

Токен **не записывается** в URL репозитория и `.git/config`: он передаётся git только на время команды (HTTP-заголовок через переменные окружения). Установщик предлагает сохранить его в `/etc/antibs2vpn/github_token` (права 600, только root), чтобы `update.sh` работал без вопросов. Если не сохранять — `update.sh` спросит токен снова. Отозвать токен можно в любой момент на странице токенов GitHub.

## Что делает install.sh

1. Проверяет root, ОС, ОЗУ/диск (при нехватке ОЗУ создаёт swap).
2. Ставит curl, git, cron, Docker + compose plugin; запускает Docker.
3. Клонирует бота в `/opt/AntiBS2vpn` (или обновляет существующую копию).
4. Спрашивает настройки с проверками: токен бота (через Telegram `getMe`), ID админов, домены (должны указывать на IP сервера), URL панелей (доступность), платёжные ключи. Необязательное можно пропустить Enter.
5. Генерирует пароль БД и секреты, пишет `.env` бота и кабинета (chmod 600). При повторном запуске предлагает оставить текущие значения.
6. Освобождает порты 80/443, открывает их в ufw, настраивает Caddy (HTTPS Let's Encrypt) в `/opt/antibs-proxy`.
7. Собирает и запускает контейнеры; с `--restore` берёт `.env` из full-бэкапа и восстанавливает БД (см. раздел RESTORE).
8. Ставит systemd-сервис `antibs-recreate-watch` и cron ежедневного бэкапа.
9. Проверяет: контейнеры, PostgreSQL, таблицы, `getMe`, логи на ошибки, `/health`, HTTPS. При проблемах пробует исправить и выводит диагностику.

### Что понадобится
- Токен бота от @BotFather и ваш Telegram ID (@userinfobot).
- GitHub-токен (см. выше).
- Рекомендуется: 2 поддомена (Mini App и Личный кабинет) с A-записью на IP сервера, свободные порты 80/443.
- Необязательно: данные VPN-панелей (OLCWave / Remnawave / WDTT), ЮKassa, Platega — можно добавить позже.

### Параметры
```
--dir DIR          каталог установки (/opt/AntiBS2vpn)
--branch BR        ветка (main)
--repo URL         репозиторий бота
--token TOKEN      GitHub-токен (или env GITHUB_TOKEN)
--env-file FILE    файл KEY=VALUE с ответами
-y, --yes          без вопросов
--restore FILE     восстановить БД: full-backup *.zip, db.dump или bot_backup_*.zip
--no-caddy         без HTTPS/Caddy
--check            только проверка
```

Подробная инструкция с описанием всех переменных — `INSTALL.md` в репозитории бота.

## Восстановление из бэкапа на новом сервере (RESTORE)

Подробная инструкция: [BACKUP_RESTORE.md](BACKUP_RESTORE.md)

### Отдельный скрипт восстановления `restore.sh`
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/restore.sh) /root/antibs2vpn-fullbackup_XXXX.zip
```
Путь к бэкапу можно не указывать — скрипт спросит. Он определит тип бэкапа (полный zip / `db.dump` / частичный JSON) и:
- если бот **не установлен** в `/opt/AntiBS2vpn` — скачает и запустит `install.sh --restore` (установка + восстановление);
- если бот **установлен** — после подтверждения сделает страховочный дамп текущей БД (`backups/pre_restore_*.dump`), покажет различия `.env` (только имена ключей) и предложит заменить их, остановит бота и кабинет, пересоздаст БД, выполнит `pg_restore` (для JSON — штатный `scripts.restore_backup`), запустит всё и проверит через `install.sh --check`.

Откат: `bash <(curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/restore.sh) /opt/AntiBS2vpn/backups/pre_restore_XXXX.dump`


### Какие бэкапы делает бот
| Файл | Когда (по умолч.) | Что внутри | Куда |
|---|---|---|---|
| `antibs2vpn-fullbackup_ГГГГММДД_ЧЧММСС.zip` | ежедневно 00:05 МСК (cron, `scripts/backup_full.sh`) | `db.dump` — **полный** дамп PostgreSQL (`pg_dump -Fc`, все таблицы); `code.tgz` — код бота и кабинета **вместе с `.env`**; README | в Telegram админам (настройка в админке) + `/opt/AntiBS2vpn/backups/` (хранится 7 шт.) |
| `bot_backup_ГГГГ-ММ-ДД_ЧЧММСС.zip` | ежедневно 03:05 МСК (внутри бота) | JSON только 7 таблиц: users, tariffs, subscriptions, payments, transactions, promocodes, settings | в Telegram + `backups/` |

**Для переноса используйте full-бэкап** — JSON-бэкап не содержит панелей, доп. услуг, текстов/картинок экранов и др.
⚠ Full-бэкап содержит секреты (`.env`: токен бота, пароль БД, ключи платёжек) — храните его как пароль.

### Пошагово
1. Новый сервер (Ubuntu/Debian), DNS-записи доменов переведите на новый IP.
2. Скачайте из Telegram последний `antibs2vpn-fullbackup_*.zip` и загрузите на сервер:
   ```bash
   scp antibs2vpn-fullbackup_*.zip root@НОВЫЙ_IP:/root/
   ```
3. **Остановите бота на старом сервере** (иначе два бота с одним токеном будут конфликтовать):
   ```bash
   cd /opt/AntiBS2vpn && docker compose stop bot
   ```
4. Запустите установщик с бэкапом:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/samur005/AntiBS2vpn-installer/main/install.sh -o install.sh
   sudo bash install.sh --restore /root/antibs2vpn-fullbackup_XXXX.zip
   ```
   Установщик сам: возьмёт `.env` бота и кабинета из `code.tgz` (вопросы будут с уже заполненными ответами — жмите Enter), поднимет PostgreSQL, восстановит `db.dump` через `pg_restore` в пустую БД **до** первого запуска бота, затем запустит бота, кабинет и Caddy (сертификаты HTTPS выпустятся заново) и проверит работу.
5. Проверьте: `/start` в боте, админка, `docker logs antibs2vpn-bot --tail 50`.

### Вручную (если установщик уже отработал без бэкапа)
```bash
cd /opt/AntiBS2vpn
unzip -o /root/antibs2vpn-fullbackup_XXXX.zip db.dump -d /tmp/rb
docker compose stop bot
docker cp /tmp/rb/db.dump antibs2vpn-postgres:/tmp/db.dump
docker exec antibs2vpn-postgres pg_restore -U vpn_bot -d vpn_bot --clean --if-exists --no-owner --no-privileges /tmp/db.dump
docker compose start bot
```
Только JSON-бэкап (частично): `docker compose exec bot python -m scripts.restore_backup /app/backups/bot_backup_XXXX.zip` (бот должен быть уже запущен — таблицы создаются при старте).

Также поддерживается `--restore db.dump` и `--restore bot_backup_*.zip`.
