# Server Setup (Двухэтапная установка)

## Этап 1 (root)
Запускайте на чистом сервере под root:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_root.sh)
```
(или загрузите файл и выполните `bash install_root.sh`)

Он выполнит:
- Загрузку config.json
- Создание пользователя
- Установку SSH ключа
- Настройку sudo / polkit
- Загрузку `install_user.sh`

После завершения:
```bash
su - <username>
./install_user.sh
```

## Этап 2 (user)
`install_user.sh`:
- Настройка SSH (порт, root login, password auth)
- Установка и настройка: ufw, fail2ban, rkhunter (timer), psad, nmap
- Docker + Portainer
- Netdata (если включено)
- Telegram бот + SSH уведомления
- iptables LOG (с лимитом)
- Cron задачи (security check / weekly update)
- Финальный чеклист → Telegram

Повторный запуск — пропускает уже выполненные шаги (state-файлы в `~/.local/share/server_setup_state/`).

## Конфиг
`config.json` хранится: `/etc/server_setup/config.json` + symlink `/usr/local/bin/config.json` (для обратной совместимости).

## Безопасность
- Желательно вынести BOT_TOKEN и CHAT_ID в отдельный файл с правами `600`.
- Пересмотрите необходимость `sudo_nopasswd=true`.

## Удаление state (для повторного прогона шагов)
Удалите файлы в `~/.local/share/server_setup_state/` (или выборочно).