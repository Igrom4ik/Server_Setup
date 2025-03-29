#!/bin/bash
set -e

CONFIG_FILE="/usr/local/bin/config.json"
PUBKEY=$(jq -r '.public_key_content' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")
SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root' "$CONFIG_FILE")
SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth' "$CONFIG_FILE")
SUDO_NOPASSWD=$(jq -r '.sudo_nopasswd' "$CONFIG_FILE")
MONITORING_ENABLED=$(jq -r '.monitoring_enabled' "$CONFIG_FILE")
# Новые переменные для Telegram-бота (токен и чат ID из config.json)
BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")

USERNAME=$(whoami)
USER_HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)

# Функция логгирования
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1"
}

# 1. Настройка пользователя и SSH
log "📁 Создание ~/.ssh и настройка ключей"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

log "🔑 Установка публичного SSH-ключа"
echo "$PUBKEY" > ~/.ssh/authorized_keys

log "🛠 Настройка /etc/ssh/sshd_config"
sudo sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
if [[ "$SSH_DISABLE_ROOT" == "true" ]]; then
  sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
fi
if [[ "$SSH_PASSWORD_AUTH" == "false" ]]; then
  sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
fi

log "🔄 Перезапуск SSH"
sudo service ssh restart

log "🔓 Настройка sudo без пароля (если предусмотрено)"
if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/90-$USERNAME" > /dev/null
  sudo chmod 440 "/etc/sudoers.d/90-$USERNAME"
fi

log "✅ Настройка пользователя завершена. Переходим к настройке безопасности и бота"

# 2. Системная защита: установка и активация сервисов
log "🛡 Установка и настройка системной защиты"
for SERVICE in ufw fail2ban psad rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    sudo apt install -y "$SERVICE"
    if systemctl list-unit-files | grep -q "^$SERVICE.service"; then
      sudo systemctl enable --now "$SERVICE"
      log "$SERVICE активирован"
    else
      log "$SERVICE не использует systemd — пропущено"
    fi
  else
    log "$SERVICE отключён в config.json"
  fi
done

log "📦 Настройка rkhunter"
sudo rkhunter --propupd || true
# Создание и активация сервиса для регулярной проверки rkhunter
sudo tee /etc/systemd/system/rkhunter.service > /dev/null <<EOF
[Unit]
Description=Rootkit Hunter Service
After=network.target

[Service]
ExecStart=/usr/bin/rkhunter --cronjob --rwo
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now rkhunter.service
# Ежедневный запуск rkhunter через cron (1:00 ночи)
echo "0 1 * * * root /usr/bin/rkhunter --check --cronjob --rwo" | sudo tee /etc/cron.d/rkhunter-daily > /dev/null

# 3. Проверка и установка Docker + Portainer
log "🐳 Проверка Docker и Portainer"
if ! command -v docker &> /dev/null; then
  log "Docker не найден, выполняется установка Docker..."
  sudo apt update -y
  sudo apt install -y docker.io || log "⚠️ Не удалось установить Docker"
  sudo systemctl enable --now docker && log "Docker запущен"
else
  log "Docker уже установлен"
fi

if command -v docker &> /dev/null; then
  if ! sudo docker container inspect portainer &> /dev/null; then
    log "Portainer не установлен, запускается установка Portainer..."
    sudo docker volume create portainer_data > /dev/null || true
    sudo docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data \
      portainer/portainer-ce:lts || log "⚠️ Не удалось запустить Portainer"
    if sudo docker ps -q -f name=portainer &> /dev/null; then
      log "Portainer установлен (Web UI: https://$(hostname -I | awk '{print $1}'):9443)"
    fi
  else
    # Если контейнер существует, убедимся, что он запущен
    if ! sudo docker ps -q -f name=portainer > /dev/null; then
      sudo docker start portainer && log "Portainer запущен" || log "⚠️ Portainer установлен, но не удалось запустить"
    fi
    log "Portainer уже установлен"
  fi
fi

# 4. Установка Netdata (в Docker, если не установлена нативно)
if [[ "$MONITORING_ENABLED" == "true" ]]; then
  log "📊 Установка системы мониторинга Netdata"
  if command -v netdata &> /dev/null; then
    log "Netdata уже установлена в системе, пропускаем установку Docker-версии"
  elif ! sudo docker container inspect netdata &> /dev/null; then
    log "Netdata не найдена, развёртывание Netdata в Docker..."
    sudo docker run -d --name=netdata \
      --hostname="$(hostname)" \
      --pid=host \
      --network=host \
      -v netdataconfig:/etc/netdata \
      -v netdatalib:/var/lib/netdata \
      -v netdatacache:/var/cache/netdata \
      -v /etc/passwd:/host/etc/passwd:ro \
      -v /etc/group:/host/etc/group:ro \
      -v /etc/os-release:/host/etc/os-release:ro \
      -v /proc:/host/proc:ro \
      -v /sys:/host/sys:ro \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      --restart unless-stopped \
      --cap-add SYS_PTRACE --cap-add SYS_ADMIN \
      --security-opt apparmor=unconfined \
      netdata/netdata || log "⚠️ Не удалось запустить Netdata в Docker"
  else
    log "Контейнер Netdata уже существует"
  fi
else
  log "Мониторинг Netdata отключён в config.json"
fi

# 5. Установка и настройка Telegram-бота
log "