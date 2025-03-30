#!/bin/bash
set -e

# Функция для вывода сообщений
log() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') | \e[34m$1\e[0m"
}

error() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') | \e[31m$1\e[0m"
}

success() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') | \e[32m$1\e[0m"
}

# Запрос подтверждения перед удалением
echo -e "\e[33m⚠️  ВНИМАНИЕ: Этот скрипт удалит все компоненты, установленные через install_user.sh\e[0m"
echo -e "\e[33m⚠️  Будут удалены: Docker, Portainer, Netdata, Telegram-бот, и настройки безопасности\e[0m"
read -p "Продолжить? (y/N): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  error "Операция отменена пользователем"
  exit 1
fi

log "🧹 Начинаем очистку системы..."

# 1. Остановка и удаление системных сервисов
log "🛑 Останавливаем системные сервисы..."
sudo systemctl stop telegram_command_listener.service 2>/dev/null || true
sudo systemctl disable telegram_command_listener.service 2>/dev/null || true
sudo systemctl stop rkhunter.service 2>/dev/null || true
sudo systemctl disable rkhunter.service 2>/dev/null || true
sudo systemctl stop psad.service 2>/dev/null || true
sudo systemctl disable psad.service 2>/dev/null || true
sudo systemctl stop fail2ban.service 2>/dev/null || true
sudo systemctl disable fail2ban.service 2>/dev/null || true
sudo systemctl stop ufw.service 2>/dev/null || true
sudo systemctl disable ufw.service 2>/dev/null || true

# 2. Удаление контейнеров Docker и самого Docker
log "🐳 Удаление Docker-контейнеров и Docker..."
if command -v docker &>/dev/null; then
  # Остановка и удаление контейнеров
  sudo docker stop portainer 2>/dev/null || true
  sudo docker rm portainer 2>/dev/null || true
  sudo docker stop netdata 2>/dev/null || true
  sudo docker rm netdata 2>/dev/null || true
  
  # Удаление volumes
  sudo docker volume rm portainer_data 2>/dev/null || true
  sudo docker volume rm netdataconfig 2>/dev/null || true
  sudo docker volume rm netdatalib 2>/dev/null || true
  sudo docker volume rm netdatacache 2>/dev/null || true
  
  # Очистка оставшихся контейнеров и образов
  sudo docker system prune -af --volumes || true
  
  # Удаление Docker
  log "🗑️ Удаление Docker..."
  sudo apt-get remove -y docker.io docker-compose || true
  sudo apt-get autoremove -y || true
fi

# 3. Удаление установленных пакетов
log "📦 Удаление установленных пакетов..."
for PACKAGE in ufw fail2ban rkhunter psad nmap netdata; do
  if dpkg -l | grep -q "$PACKAGE"; then
    log "🗑️ Удаление пакета $PACKAGE..."
    sudo apt-get remove -y "$PACKAGE" || true
  fi
done

# 4. Удаление скриптов и конфигурационных файлов
log "🗑️ Удаление скриптов и конфигурационных файлов..."
sudo rm -f /etc/systemd/system/telegram_command_listener.service
sudo rm -f /etc/systemd/system/rkhunter.service
sudo rm -f /usr/local/bin/telegram_command_listener.sh
sudo rm -f /usr/local/bin/telegram_ssh_notify.sh
sudo rm -f /etc/cron.d/cron-security-check 
sudo rm -f /etc/cron.d/cron-clear-security-log 
sudo rm -f /etc/cron.d/cron-weekly-update
sudo rm -f /etc/cron.d/rkhunter-daily
sudo rm -f /usr/local/bin/cron_security_check.sh 
sudo rm -f /usr/local/bin/cron_clear_security_log.sh 
sudo rm -f /usr/local/bin/cron_weekly_update.sh
sudo rm -f /usr/local/bin/config.json

# 5. Удаление директорий и кэшей
log "🗑️ Удаление директорий и кэшей..."
sudo rm -rf /root/.cache/telegram_* 
sudo rm -rf /home/*/.cache/telegram_* 
sudo rm -rf ~/.local/share/telegram_bot/
sudo rm -rf /var/log/psad/
sudo rm -rf /var/lib/psad/
sudo rm -rf /var/log/security_monitor.log
sudo rm -rf /var/log/weekly_update.log

# 6. Восстановление конфигурации SSH
log "🔄 Восстановление стандартной конфигурации SSH..."
if [[ -f /etc/ssh/sshd_config ]]; then
  # Восстановление стандартного порта
  sudo sed -i 's/^Port [0-9]*/Port 22/' /etc/ssh/sshd_config
  
  # Восстановление доступа root (если был отключен)
  sudo sed -i 's/^PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
  
  # Восстановление аутентификации по паролю (если была отключена)
  sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
  
  # Перезапуск SSH для применения изменений
  sudo service ssh restart
fi

# 7. Удаление сообщений из PAM
log "🔄 Удаление уведомлений о SSH из PAM..."
if grep -q "telegram_ssh_notify.sh" /etc/pam.d/sshd; then
  sudo sed -i '/telegram_ssh_notify.sh/d' /etc/pam.d/sshd
fi

# 8. Удаление правил iptables
log "🔥 Очистка правил iptables..."
sudo iptables -F
sudo iptables -X PSAD_BLOCK_INPUT 2>/dev/null || true
sudo iptables -X PSAD_BLOCK_OUTPUT 2>/dev/null || true
sudo iptables -X PSAD_BLOCK_FORWARD 2>/dev/null || true

# 9. Удаление настроек sudo
log "🔄 Восстановление настроек sudo..."
# Удаление NOPASSWD для текущего пользователя
USERNAME=$(whoami)
sudo rm -f "/etc/sudoers.d/90-$USERNAME"

# Удаление правила для rkhunter
sudo sed -i "/$USERNAME ALL=(ALL) NOPASSWD: \/usr\/bin\/rkhunter/d" /etc/sudoers 2>/dev/null || true

# 10. Перезагрузка systemd
log "🔄 Перезагрузка systemd..."
sudo systemctl daemon-reload

success "✅ Система успешно очищена от всех установленных компонентов!"
echo ""
echo -e "\e[33mВнимание: Для полного применения изменений рекомендуется перезагрузить систему.\e[0m"
read -p "Перезагрузить систему сейчас? (y/N): " REBOOT

if [[ "$REBOOT" == "y" || "$REBOOT" == "Y" ]]; then
  log "🔄 Перезагрузка системы..."
  sudo reboot
else
  success "🏁 Скрипт завершен. Система не будет перезагружена."
fi