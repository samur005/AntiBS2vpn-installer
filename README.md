# AntiBS2vpn — установщик

Скрипты установки, обновления и удаления Telegram-бота AntiBS2vpn (бот + PostgreSQL + Личный кабинет + HTTPS через Caddy) на чистый сервер Ubuntu 22.04+/Debian 11+.

## Команды (запускать от root)

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
7. Собирает и запускает контейнеры (с повторами при сбое сборки), по желанию восстанавливает БД из бэкапа.
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
