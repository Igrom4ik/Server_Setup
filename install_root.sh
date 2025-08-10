```bash
#!/bin/bash
set -e

# Установка необходимых пакетов
echo "Installing dependencies..."
sudo apt update -y
sudo apt install -y apt-utils jq curl gawk sudo gnupg lsb-release software-properties-common

# Проверка зависимостей
for cmd in jq curl gawk sudo; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: $cmd is not installed. Please install it before running."
    exit 1
  fi
done

# Запрос на удаление старых скриптов
read -p "Find and remove old versions of Telegram bot and cron scripts? [y/N]: " DEL_OLD
if [[ "$DEL_OLD" =~ ^[Yy]$ ]]; then
  echo "Removing old scripts..."
  sudo systemctl stop telegram_command_listener.service 2>/dev/null || true
  sudo systemctl disable telegram_command_listener.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/telegram_command_listener.service
  sudo rm -f /usr/local/bin/telegram_command_listener.sh
  sudo rm -f /usr/local/bin/telegram_ssh_notify.sh
  sudo rm -f /etc/cron.d/cron-security-check /etc/cron.d/cron-clear-security-log /etc/cron.d/cron-weekly-update
  sudo rm -f /usr/local/bin/cron_security_check.sh /usr/local/bin/cron_clear_security_log.sh /usr/local/bin/cron_weekly_update.sh
  sudo rm -rf /root/.cache/telegram_* /home/*/.cache/telegram_* ~/.local/share/telegram_bot/
  echo "Old scripts removed"
else
  echo "Skipping removal of old scripts"
fi

CONFIG_FILE="/usr/local/bin/config.json"
CONFIG_URL="https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/config.json"
TMP_CONFIG="$(mktemp)"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "config.json not found. Downloading from GitHub..."
  TMP_CONFIG="$(mktemp "$HOME/config.json.XXXX")"
  if curl -fsSL "$CONFIG_URL" -o "$TMP_CONFIG"; then
    sudo mv "$TMP_CONFIG" "$CONFIG_FILE"
    sudo chmod 644 "$CONFIG_FILE"
    echo "config.json downloaded successfully"
  else
    echo "Error: Failed to download config.json from $CONFIG_URL"
    exit 1
  fi
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Configuration file $CONFIG_FILE not found"
  exit 1
fi

PUBKEY=$(jq -r '.public_key_content' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")
SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root' "$CONFIG_FILE")
SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth' "$CONFIG_FILE")
SUDO_NOPASSWD=$(jq -r '.sudo_nopasswd' "$CONFIG_FILE")
MONITORING_ENABLED=$(jq -r '.monitoring_enabled' "$CONFIG_FILE")
BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
ENABLE_AUTO_IDS_REGEX=$(jq -r '.psad_auto_ids_regex // "N"' "$CONFIG_FILE")
USERNAME=$(whoami)
USER_HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)

# Функция логгирования
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1"
}

# 1. Настройка пользователя и SSH
log "Creating ~/.ssh and setting up keys"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
log "Installing public SSH key"
echo "$PUBKEY" > ~/.ssh/authorized_keys
log "Configuring /etc/ssh/sshd_config"
sudo sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
if [[ "$SSH_DISABLE_ROOT" == "true" ]]; then
  sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
fi
if [[ "$SSH_PASSWORD_AUTH" == "false" ]]; then
  sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
fi
log "Restarting SSH"
sudo service ssh restart
log "Setting up sudo without password (if specified)"
if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/90-$USERNAME" > /dev/null
  sudo chmod 440 "/etc/sudoers.d/90-$USERNAME"
fi
log "User setup completed. Proceeding to security and bot setup"

# 2. Системная защита: установка и активация сервисов
log "Installing and configuring system security"
for SERVICE in ufw fail2ban rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    sudo apt install -y "$SERVICE"
    if systemctl list-unit-files | grep -q "^$SERVICE.service"; then
      sudo systemctl enable --now "$SERVICE"
      log "$SERVICE activated"
    else
      log "$SERVICE does not use systemd — skipped"
    fi
  else
    log "$SERVICE disabled in config.json"
  fi
done

# Установка и настройка psad
if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  log "Installing psad"
  if ! sudo apt install -y psad; then
    log "Error: Failed to install psad"
    exit 1
  fi
  log "Configuring psad"
  echo "Configuring psad.conf and logs..."
  sudo sed -i 's/^ENABLE_AUTO_IDS.*/ENABLE_AUTO_IDS Y;/g' /etc/psad/psad.conf
  sudo grep -q '^ENABLE_AUTO_IDS' /etc/psad/psad.conf || echo "ENABLE_AUTO_IDS Y;" | sudo tee -a /etc/psad/psad.conf > /dev/null
  sudo sed -i 's/^ENABLE_EMAIL_ALERTS.*/ENABLE_EMAIL_ALERTS Y;/g' /etc/psad/psad.conf
  sudo grep -q '^ENABLE_EMAIL_ALERTS' /etc/psad/psad.conf || echo "ENABLE_EMAIL_ALERTS Y;" | sudo tee -a /etc/psad/psad.conf > /dev/null
  log "Checking psad status..."
  if pgrep -f /usr/sbin/psad > /dev/null; then
    log "Detected running psad process. Terminating..."
    if ! sudo pkill -f /usr/sbin/psad; then
      log "Error: Failed to terminate psad process"
      exit 1
    fi
    sleep 1
    if [ -f /var/run/psad/psad.pid ]; then
      if ! sudo rm -f /var/run/psad/psad.pid; then
        log "Error: Failed to remove psad PID file"
        exit 1
      fi
      log "psad PID file removed"
    fi
  else
    log "psad process not running, skipping termination"
  fi
  log "Restarting psad service..."
  if ! sudo systemctl restart psad; then
    log "Error: Failed to restart psad. Check logs: journalctl -xeu psad.service"
    exit 1
  fi
  if systemctl is-active --quiet psad; then
    log "psad started successfully"
  else
    log "Error: psad is not active. Check logs: journalctl -xeu psad.service"
    exit 1
  fi
else
  log "psad disabled in config.json, skipping"
fi

# Настройка cron-задач
log "Setting up cron tasks"
sudo tee /usr/local/bin/cron_security_check.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
send_telegram() {
    local MESSAGE="\$1"
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
         -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" \\
         --data-urlencode text="\${MESSAGE}" > /dev/null
}
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}
echo "\$(timestamp) | Starting security check" >> "\$LOG_FILE"
RKHUNTER_RESULT=\$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "\$RKHUNTER_RESULT" ]; then
    send_telegram "⚠️ *RKHunter detected suspicious elements:*\n\`\`\`\n\$RKHUNTER_RESULT\n\`\`\`"
    echo "\$(timestamp) | ⚠️ RKHunter: Suspicious elements found" >> "\$LOG_FILE"
else
    send_telegram "✅ *RKHunter*: No violations detected"
    echo "\$(timestamp) | ✅ RKHunter: All clear" >> "\$LOG_FILE"
fi
PSAD_ALERTS=\$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
if echo "\$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD warning:*\n\`\`\`\n\$PSAD_ALERTS\n\`\`\`"
    echo "\$(timestamp) | 🚨 PSAD: Threats detected" >> "\$LOG_FILE"
else
    send_telegram "✅ *PSAD*: No suspicious activity detected"
    echo "\$(timestamp) | ✅ PSAD: All quiet" >> "\$LOG_FILE"
fi
echo "\$(timestamp) | Check completed" >> "\$LOG_FILE"
EOF
sudo chmod +x /usr/local/bin/cron_security_check.sh
echo "0 7 * * * root /usr/local/bin/cron_security_check.sh" | sudo tee /etc/cron.d/cron-security-check > /dev/null
sudo tee /usr/local/bin/cron_clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Clearing security log (weekly)" > "\$LOG_FILE"
EOF
sudo chmod +x /usr/local/bin/cron_clear_security_log.sh
echo "0 6 * * 1 root /usr/local/bin/cron_clear_security_log.sh" | sudo tee /etc/cron.d/cron-clear-security-log > /dev/null
sudo tee /usr/local/bin/cron_weekly_update.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/weekly_update.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
send_telegram() {
    local MESSAGE="\$1"
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
         -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" \\
         --data-urlencode text="\${MESSAGE}" > /dev/null
}
log_and_echo() {
    echo "\$1" | tee -a "\$LOG_FILE"
}
log_and_echo "===== \$(date '+%Y-%m-%d %H:%M:%S') | Starting update ====="
apt update >> "\$LOG_FILE" 2>&1
apt upgrade -y >> "\$LOG_FILE" 2>&1
apt full-upgrade -y >> "\$LOG_FILE" 2>&1
apt autoremove -y >> "\$LOG_FILE" 2>&1
apt autoclean >> "\$LOG_FILE" 2>&1
log_and_echo "✅ \$(date '+%Y-%m-%d %H:%M:%S') | Update completed"
log_and_echo ""
TAIL_LOG=\$(tail -n 40 "\$LOG_FILE")
send_telegram "🧰 *Weekly server update completed:*
\`\`\`
\${TAIL_LOG}
\`\`\`"
EOF
sudo chmod +x /usr/local/bin/cron_weekly_update.sh
echo "30 5 * * 1 root /usr/local/bin/cron_weekly_update.sh" | sudo tee /etc/cron.d/cron-weekly-update > /dev/null
log "Setup completed"
```
