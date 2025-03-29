# Еженедельное обновление системы с отчётом в Telegram
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

log_and_echo "🕖 ===== \$(date '+%Y-%m-%d %H:%M:%S') | Начало обновления ====="
apt update >> "\$LOG_FILE" 2>&1
apt upgrade -y >> "\$LOG_FILE" 2>&1
apt full-upgrade -y >> "\$LOG_FILE" 2>&1
apt autoremove -y >> "\$LOG_FILE" 2>&1
apt autoclean >> "\$LOG_FILE" 2>&1
log_and_echo "✅ \$(date '+%Y-%m-%d %H:%M:%S') | Обновление завершено"
log_and_echo ""

TAIL_LOG=\$(tail -n 40 "\$LOG_FILE")
send_telegram "🧰 *Еженедельное обновление сервера завершено:*
\`\`\`
\${TAIL_LOG}
\`\`\`"
EOF
  sudo chmod +x /usr/local/bin/cron_weekly_update.sh
# Дополнительные улучшения
log "🔧 Дополнительные улучшения и оптимизации"

# Создание cron-задачи для мониторинга работы бота
echo "*/5 * * * * $USERNAME systemctl is-active --quiet telegram_command_listener.service || curl -s 'https://api.telegram.org/bot$BOT_TOKEN/sendMessage?chat_id=$CHAT_ID&text=⚠️+Бот+не+работает'" | sudo tee /etc/cron.d/telegram-bot-monitor > /dev/null

# Добавление записи в cron для ротации логов
echo "0 0 * * 0 $USERNAME find ~/.local/share/telegram_bot/logs -name \"*.log\" -size +10M -exec sh -c 'cp {} {}.old && cat /dev/null > {}' \\;" | sudo tee /etc/cron.d/telegram-logs-rotate > /dev/null

# Создаем файл с инструкциями по работе с ботом
cat > "$USER_HOME_DIR/telegram-bot-help.txt" <<EOL
==== Инструкция по работе с Telegram-ботом ====

1. Основные команды:
   - /start - запуск бота с кнопками
   - /help - список всех команд
   - /checklist - быстрая проверка системы
   - /security - полная проверка безопасности
   - /resetcache - сбросить кеш бота (при проблемах)

2. При проблемах с ботом:
   - Проверьте статус: sudo systemctl status telegram_command_listener.service
   - Перезапустите: sudo systemctl restart telegram_command_listener.service
   - Сбросьте кеш: sudo /usr/local/bin/reset_telegram_bot_cache.sh
   - Проверьте логи: tail -n 30 ~/.local/share/telegram_bot/logs/bot_debug.log

3. Мониторинг работы бота настроен с проверкой каждые 5 минут.

4. Для обновления бота скопируйте новую версию скрипта в:
   /usr/local/bin/telegram_command_listener.sh

5. Инлайн-кнопки должны работать после нажатия без необходимости
   вводить команды вручную.

6. Все логи хранятся в: ~/.local/share/telegram_bot/logs/
EOL

# Уведомляем в Telegram о завершении настройки улучшенного бота
if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
  MSG="✅ *Установка улучшенного Telegram-бота завершена!*

🚀 Версия: 2.0 (с инлайн-кнопками)
🔐 Пользователь: $USERNAME
🌐 Сервер: $(hostname -I | awk '{print $1}')
📝 Инструкция: ~/telegram-bot-help.txt

_Нажмите кнопку ниже для проверки:_"

  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "parse_mode=Markdown" \
    -d "text=$MSG" \
    -d "reply_markup={\"inline_keyboard\":[[{\"text\":\"🔄 Проверка бота\",\"callback_data\":\"help\"}]]}" > /dev/null
fi

log "✅ Настройка cron-задач и дополнительных улучшений завершена"
log "📋 Справка по работе с ботом: $USER_HOME_DIR/telegram-bot-help.txt"

# Создание cron-задачи для еженедельного обновления
if [[ -f "/usr/local/bin/cron_weekly_update.sh" ]]; then
  echo "30 5 * * 1 root /usr/local/bin/cron_weekly_update.sh" | sudo tee /etc/cron.d/cron-weekly-update > /dev/null
  log "✅ Cron-задача еженедельного обновления настроена"
else
  log "⚠️ Пропуск настройки cron-задачи (файл скрипта не найден)"
fi.log"
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

log_and_echo "🕖 ===== \$(date '+%Y-%m-%d %H:%M:%S') | Начало обновления ====="
apt update >> "\$LOG_FILE" 2>&1
apt upgrade -y >> "\$LOG_FILE" 2>&1
apt full-upgrade -y >> "\$LOG_FILE" 2>&1
apt autoremove -y >> "\$LOG_FILE" 2>&1
apt autoclean >> "\$LOG_FILE" 2>&1
log_and_echo "✅ \$(date '+%Y-%m-%d %H:%M:%S') | Обновление завершено"
log_and_echo ""

TAIL_LOG=\$(tail -n 40 "\$LOG_FILE")
send_telegram "🧰 *Еженедельное обновление сервера завершено:*
\`\`\`
\${TAIL_LOG}
\`\`\`"
EOF

# Проверка создания файла и установка прав
if [[ -f "/usr/local/bin/cron_weekly_update.sh" ]]; then
  sudo chmod +x /usr/local/bin/cron_weekly_update.sh
  log "✅ Скрипт еженедельного обновления создан успешно"
else
  log "⚠️ Ошибка: не удалось создать скрипт еженедельного обновления"
  sudo mkdir -p /usr/local/bin/
  sudo chmod 755 /usr/local/bin/ 
  sudo tee /usr/local/bin/cron_weekly_update.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/weekly_update#!/bin/bash
set -e

# Функция логгирования определена в начале
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1"
}

# Запрос на удаление старых скриптов
read -p "🔍 Найти и удалить старые версии Telegram-бота и cron-скриптов? [y/N]: " DEL_OLD
if [[ "$DEL_OLD" =~ ^[Yy]$ ]]; then
  log "🧹 Удаление старых скриптов..."
  sudo systemctl stop telegram_command_listener.service 2>/dev/null || true
  sudo systemctl disable telegram_command_listener.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/telegram_command_listener.service
  sudo rm -f /usr/local/bin/telegram_command_listener.sh
  sudo rm -f /usr/local/bin/telegram_ssh_notify.sh
  sudo rm -f /etc/cron.d/cron-security-check /etc/cron.d/cron-clear-security-log /etc/cron.d/cron-weekly-update
  sudo rm -f /usr/local/bin/cron_security_check.sh /usr/local/bin/cron_clear_security_log.sh /usr/local/bin/cron_weekly_update.sh
  sudo rm -rf /root/.cache/telegram_* /home/*/.cache/telegram_* ~/.local/share/telegram_bot/
  log "✅ Старые скрипты удалены"
else
  log "⏩ Пропуск удаления старых скриптов"
# Настройка логирования psad и iptables
log "🧱 Настройка логирования psad и iptables"
sudo iptables -C INPUT -j LOG 2>/dev/null || sudo iptables -A INPUT -j LOG
sudo iptables -C FORWARD -j LOG 2>/dev/null || sudo iptables -A FORWARD -j LOG

if ! grep -q "psad" /etc/rsyslog.conf; then
  echo ':msg, contains, "psad" /var/log/psad/alert' | sudo tee -a /etc/rsyslog.conf > /dev/null
  echo '& stop' | sudo tee -a /etc/rsyslog.conf > /dev/null
  sudo systemctl restart rsyslog
# Настройка sudo для rkhunter и psad (без пароля для вызова ботом)
log "🛡 Настройка sudo для системных утилит (без пароля для бота)"
if ! sudo grep -q "/usr/bin/rkhunter" /etc/sudoers; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/rkhunter" | sudo tee -a /etc/sudoers > /dev/null
  log "Добавлено правило sudoers для rkhunter"
else
  log "Правило sudoers для rkhunter уже существует — пропущено"
# Еженедельная очистка лога безопасности
sudo tee /usr/local/bin/cron_clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Очистка лога безопасности (еженедельно)" > "\$LOG_FILE"
EOF

# Проверка создания файла и установка прав
if [[ -f "/usr/local/bin/cron_clear_security_log.sh" ]]; then
  sudo chmod +x /usr/local/bin/cron_clear_security_log.sh
  log "✅ Скрипт очистки логов создан успешно"
else
  log "⚠️ Ошибка: не удалось создать скрипт очистки логов"
  # Повторная попытка создания файла
  sudo mkdir -p /usr/local/bin/
  sudo chmod 755 /usr/local/bin/
  sudo tee /usr/local/bin/cron_clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Очистка лога безопасности (еженедельно)" > "\$LOG_FILE"
EOF
  sudo chmod +x /usr/local/bin/cron_clear_security_log.sh
fi

# Создание cron-задачи для очистки логов
if [[ -f "/usr/local/bin/cron_clear_security_log.sh" ]]; then
  echo "0 6 * * 1 root /usr/local/bin/cron_clear_security_log.sh" | sudo tee /etc/cron.d/cron-clear-security-log > /dev/null
  log "✅ Cron-задача очистки логов настроена"
else
  log "⚠️ Пропуск настройки cron-задачи (файл скрипта не найден)"
fi

if ! sudo grep -q "/usr/sbin/psad" /etc/sudoers; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/sbin/psad" | sudo tee -a /etc/sudoers > /dev/null
  log "Добавлено правило sudoers для psad"
else
  log "Правило sudoers для psad уже существует — пропущено"
fi

# Создаем дополнительный скрипт для сброса кеша бота
log "🧹 Создание скрипта для сброса кеша бота"
sudo tee /usr/local/bin/reset_telegram_bot_cache.sh > /dev/null <<EOF
#!/bin/bash
# Скрипт для сброса кеша Telegram-бота в случае проблем
# Использование: sudo reset_telegram_bot_cache.sh [username]

USERNAME=\${1:-$USERNAME}
USER_HOME=\$(getent passwd "\$USERNAME" | cut -d: -f6)

if [[ -z "\$USER_HOME" ]]; then
  echo "⚠️ Ошибка: пользователь \$USERNAME не найден"
  exit 1
fi

echo "🔄 Останавливаем сервис бота..."
systemctl stop telegram_command_listener.service

echo "🧹 Очищаем кеш бота..."
rm -rf "\$USER_HOME/.local/share/telegram_bot/cache/"*
mkdir -p "\$USER_HOME/.local/share/telegram_bot/cache"
touch "\$USER_HOME/.local/share/telegram_bot/cache/offset"
echo "0" > "\$USER_HOME/.local/share/telegram_bot/cache/offset"
chown -R "\$USERNAME:\$USERNAME" "\$USER_HOME/.local/share/telegram_bot"

echo "🚀 Перезапускаем сервис бота..."
systemctl start telegram_command_listener.service
sleep 2
systemctl status telegram_command_listener.service | head -n 20

echo "✅ Готово! Бот перезапущен с чистым кешем."
EOF

# 6. Финальный чек-лист
log "📬 Финальный чек-лист установки"
CHECKLIST="/tmp/install_checklist.txt"

# Собираем информацию для чек-листа
echo "Чеклист установки:" > "$CHECKLIST"
echo "Пользователь: $USERNAME" >> "$CHECKLIST"
echo "SSH порт: $PORT" >> "$CHECKLIST"
echo "Службы:" >> "$CHECKLIST"
for SERVICE in ufw fail2ban psad rkhunter; do
  sudo systemctl is-active --quiet "$SERVICE" && echo "  [+] $SERVICE" >> "$CHECKLIST" || echo "  [ ] $SERVICE" >> "$CHECKLIST"
done
echo "Telegram-бот: включён" >> "$CHECKLIST"
if command -v docker &> /dev/null; then
  echo "Docker: установлен" >> "$CHECKLIST"
  if sudo docker ps -q -f name=portainer &> /dev/null; then
    echo "Portainer: https://$(hostname -I | awk '{print $1}'):9443" >> "$CHECKLIST"
  else
    echo "Portainer: не запущен" >> "$CHECKLIST"
  fi
else
  echo "Docker: не установлен" >> "$CHECKLIST"
fi
if [[ "$MONITORING_ENABLED" == "true" ]]; then
  if command -v netdata &> /dev/null; then
    echo "Netdata: http://$(hostname -I | awk '{print $1}'):19999 (в системе)" >> "$CHECKLIST"
  elif sudo docker ps -q -f name=netdata &> /dev/null; then
    echo "Netdata: http://$(hostname -I | awk '{print $1}'):19999 (Docker)" >> "$CHECKLIST"
  else
    echo "Netdata: ошибка установки" >> "$CHECKLIST"
  fi
else
  echo "Netdata: отключена" >> "$CHECKLIST"
fi
if [[ "$(jq -r '.services.rkhunter' "$CONFIG_FILE")" == "true" ]]; then
  # Используем timeout для предотвращения зависания
  RKHUNTER_OUTPUT=$(timeout 10s sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || echo "Timeout при выполнении rkhunter")
  if [[ -n "$RKHUNTER_OUTPUT" && "$RKHUNTER_OUTPUT" != "Timeout при выполнении rkhunter" ]]; then
    echo "RKHunter: ОБНАРУЖЕНЫ предупреждения:" >> "$CHECKLIST"
    RKHUNTER_LAST=$(echo "$RKHUNTER_OUTPUT" | tail -n 10)
    echo "$RKHUNTER_LAST" >> "$CHECKLIST"
  elif [[ "$RKHUNTER_OUTPUT" == "Timeout при выполнении rkhunter" ]]; then
    echo "RKHunter: Превышено время ожидания при проверке" >> "$CHECKLIST"
  else
    echo "RKHunter: OK (нарушений не обнаружено)" >> "$CHECKLIST"
  fi
fi
if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  if [[ -f /var/log/psad/alert ]]; then
    PSAD_ALERTS=$(sudo grep "Danger level" /var/log/psad/alert 2>/dev/null | tail -n 5 || true)
    if [[ -n "$PSAD_ALERTS" ]]; then
      echo "PSAD: обнаружена подозрительная активность:" >> "$CHECKLIST"
      echo "$PSAD_ALERTS" >> "$CHECKLIST"
    else
      echo "PSAD: OK (подозрительной активности не выявлено)" >> "$CHECKLIST"
    fi
  else
    echo "PSAD: OK (лог пуст)" >> "$CHECKLIST"
  fi
fi

# Выводим чек-лист в терминал
cat "$CHECKLIST"

# 7. Настройка cron-задач (безопасность, обновление, очистка)
log "🕒 Настройка cron-задач: ежедневная проверка, очистка логов, обновления"

# Ежедневная проверка безопасности (rkhunter + psad) с оповещением в Telegram
sudo tee /usr/local/bin/cron_security_check.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

send_telegram() {
    MESSAGE="\$1"
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" --data-urlencode text="\${MESSAGE}" > /dev/null
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}
echo "\$(timestamp) | 🚀 Запуск проверки безопасности" >> "\$LOG_FILE"

RKHUNTER_RESULT=\$(timeout 30s sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || echo "Timeout при выполнении rkhunter")
if [ -n "\$RKHUNTER_RESULT" ] && [ "\$RKHUNTER_RESULT" != "Timeout при выполнении rkhunter" ]; then
    send_telegram "⚠️ *RKHunter обнаружил подозрительные элементы:*\n\`\`\`\n\$RKHUNTER_RESULT\n\`\`\`"
    echo "\$(timestamp) | ⚠️ RKHunter: найдены подозрения" >> "\$LOG_FILE"
elif [ "\$RKHUNTER_RESULT" == "Timeout при выполнении rkhunter" ]; then
    send_telegram "⚠️ *RKHunter:* превышено время ожидания (30 секунд)"
    echo "\$(timestamp) | ⚠️ RKHunter: превышено время ожидания" >> "\$LOG_FILE"
else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
    echo "\$(timestamp) | ✅ RKHunter: всё чисто" >> "\$LOG_FILE"
fi

PSAD_ALERTS=\$(sudo grep "Danger level" /var/log/psad/alert 2>/dev/null | tail -n 5 || echo "")
if echo "\$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n\$PSAD_ALERTS\n\`\`\`"
    echo "\$(timestamp) | 🚨 PSAD: найдены угрозы" >> "\$LOG_FILE"
else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
    echo "\$(timestamp) | ✅ PSAD: всё спокойно" >> "\$LOG_FILE"
fi
echo "\$(timestamp) | ✅ Проверка завершена" >> "\$LOG_FILE"
EOF

# Проверка создания файла и установка прав
if [[ -f "/usr/local/bin/cron_security_check.sh" ]]; then
  sudo chmod +x /usr/local/bin/cron_security_check.sh
  log "✅ Скрипт ежедневной проверки создан успешно"
else
  log "⚠️ Ошибка: не удалось создать скрипт ежедневной проверки"
  sudo mkdir -p /usr/local/bin/
  sudo chmod 755 /usr/local/bin/
  sudo tee /usr/local/bin/cron_security_check.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

send_telegram() {
    MESSAGE="\$1"
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" --data-urlencode text="\${MESSAGE}" > /dev/null
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}
echo "\$(timestamp) | 🚀 Запуск проверки безопасности" >> "\$LOG_FILE"

RKHUNTER_RESULT=\$(timeout 30s sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || echo "Timeout при выполнении rkhunter")
if [ -n "\$RKHUNTER_RESULT" ] && [ "\$RKHUNTER_RESULT" != "Timeout при выполнении rkhunter" ]; then
    send_telegram "⚠️ *RKHunter обнаружил подозрительные элементы:*\n\`\`\`\n\$RKHUNTER_RESULT\n\`\`\`"
    echo "\$(timestamp) | ⚠️ RKHunter: найдены подозрения" >> "\$LOG_FILE"
elif [ "\$RKHUNTER_RESULT" == "Timeout при выполнении rkhunter" ]; then
    send_telegram "⚠️ *RKHunter:* превышено время ожидания (30 секунд)"
    echo "\$(timestamp) | ⚠️ RKHunter: превышено время ожидания" >> "\$LOG_FILE"
else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
    echo "\$(timestamp) | ✅ RKHunter: всё чисто" >> "\$LOG_FILE"
fi

PSAD_ALERTS=\$(sudo grep "Danger level" /var/log/psad/alert 2>/dev/null | tail -n 5 || echo "")
if echo "\$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n\$PSAD_ALERTS\n\`\`\`"
    echo "\$(timestamp) | 🚨 PSAD: найдены угрозы" >> "\$LOG_FILE"
else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
    echo "\$(timestamp) | ✅ PSAD: всё спокойно" >> "\$LOG_FILE"
fi
echo "\$(timestamp) | ✅ Проверка завершена" >> "\$LOG_FILE"
EOF
  sudo chmod +x /usr/local/bin/cron_security_check.sh
fi

# Создание cron-задачи для ежедневной проверки
if [[ -f "/usr/local/bin/cron_security_check.sh" ]]; then
  echo "0 7 * * * root /usr/local/bin/cron_security_check.sh" | sudo tee /etc/cron.d/cron-security-check > /dev/null
  log "✅ Cron-задача ежедневной проверки настроена"
else
  log "⚠️ Пропуск настройки cron-задачи (файл скрипта не найден)"
fi

if grep -q "IPT_SYSLOG_FILE" /etc/psad/psad.conf; then
  sudo sed -i "s|^IPT_SYSLOG_FILE.*|IPT_SYSLOG_FILE             /var/log/kern.log;|" /etc/psad/psad.conf
  sudo systemctl restart psad
  log "psad сконфигурирован"
fi

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
SERVER_LABEL=$(jq -r '.telegram_server_label // "Сервер"' "$CONFIG_FILE")

USERNAME=$(whoami)
USER_HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)

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
sudo tee /etc/systemd/system/rkhunter.service > /dev/null <<# Заменяем плейсхолдеры в скрипте на реальные значения
sudo sed -i "s|USER_HOME_PLACEHOLDER|$USER_HOME_DIR|g" /usr/local/bin/telegram_command_listener.sh
sudo sed -i "s|BOT_TOKEN_PLACEHOLDER|$BOT_TOKEN|g" /usr/local/bin/telegram_command_listener.sh
sudo sed -i "s|CHAT_ID_PLACEHOLDER|$CHAT_ID|g" /usr/local/bin/telegram_command_listener.sh
sudo sed -i "s|SERVER_LABEL_PLACEHOLDER|$SERVER_LABEL|g" /usr/local/bin/telegram_command_listener.sh

# Создание systemd unit для бота
sudo tee /etc/systemd/system/telegram_command_listener.service > /dev/null <<EOF
[Unit]
Description=Telegram Command Listener Bot Service
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
RestartSec=10
User=$USERNAME
# Дополнительные настройки для надежности
Environment=LANG=en_US.UTF-8
StandardOutput=append:/var/log/telegram_bot.log
StandardError=append:/var/log/telegram_bot.error.log

# Ограничения безопасности
ProtectSystem=full
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
# Уведомления о SSH-подключениях через PAM
log "🔔 Настройка уведомлений о входе по SSH"
sudo tee /usr/local/bin/telegram_ssh_notify.sh > /dev/null <<EOF
#!/bin/bash
[[ "\$PAM_TYPE" != "open_session" ]] && exit 0
[[ -z "\$PAM_USER" || "\$PAM_USER" == "sshd" ]] && exit 0

TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

USER="\$PAM_USER"
IP=\$(echo \$SSH_CONNECTION | awk '{print \$1}')
CACHE_FILE="/tmp/ssh_notify_\${USER}_\${IP}"

# Если уже отправляли уведомление за последние 10 секунд — пропускаем
if [[ -f "\$CACHE_FILE" ]]; then
  LAST_TIME=\$(cat "\$CACHE_FILE")
  NOW=\$(date +%s)
  DIFF=\$((NOW - LAST_TIME))
  if [[ "\$DIFF" -lt 10 ]]; then
    exit 0
  fi
fi

date +%s > "\$CACHE_FILE"

GEO=\$(curl -s -m 5 ipinfo.io/\$IP | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
TEXT="🔐 SSH вход: *\$USER*
📡 IP: \`\$IP\`
🌍 Местоположение: \$GEO
🕒 Время: \$(date +'%Y-%m-%d %H:%M:%S')"

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
  -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$TEXT" > /dev/null
EOF

sudo chmod +x /usr/local/bin/telegram_ssh_notify.sh

# Подключение скрипта к PAM
if ! grep -q "telegram_ssh_notify.sh" /etc/pam.d/sshd; then
  echo "session optional pam_exec.so /usr/local/bin/telegram_ssh_notify.sh" | sudo tee -a /etc/pam.d/sshd > /dev/null
fi
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

# 5. Установка и настройка Telegram-бота (улучшенная версия)
log "
🤖 Установка и настройка Telegram-бота"

# Исправлено: убраны подстановки внутри heredoc, которые могут вызывать ошибки синтаксиса
# Использованы одинарные кавычки для heredoc и заменены переменные на конкретные значения
sudo tee /usr/local/bin/telegram_command_listener.sh > /dev/null << 'EOF'
#!/bin/bash
# Конфигурация и начальные переменные
USER_HOME_DIR="USER_HOME_PLACEHOLDER"
export HOME="$USER_HOME_DIR"

# Получение токена и chat_id из config.json
CONFIG_FILE="/usr/local/bin/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
    TOKEN="BOT_TOKEN_PLACEHOLDER"
    CHAT_ID="CHAT_ID_PLACEHOLDER"
    SERVER_LABEL="SERVER_LABEL_PLACEHOLDER"
else
    # Если файл конфигурации не найден, используем переменные окружения или значения по умолчанию
    TOKEN="${BOT_TOKEN:-"BOT_TOKEN_PLACEHOLDER"}"
    CHAT_ID="${CHAT_ID:-"CHAT_ID_PLACEHOLDER"}"
    SERVER_LABEL="${SERVER_LABEL:-"SERVER_LABEL_PLACEHOLDER"}"
fi

# Пути для хранения данных бота
LOG_FILE="$HOME/.local/share/telegram_bot/logs/bot_debug.log"
OFFSET_FILE="$HOME/.local/share/telegram_bot/cache/offset"
LAST_COMMAND_FILE="$HOME/.local/share/telegram_bot/cache/last_command"
REBOOT_FLAG_FILE="$HOME/.local/share/telegram_bot/cache/confirm_reboot"

# Создание необходимых директорий
mkdir -p "$HOME/.local/share/telegram_bot/logs"
mkdir -p "$HOME/.local/share/telegram_bot/cache"

# Перенаправление вывода в лог-файл
exec >>"$LOG_FILE" 2>&1
set -x

# Функция для отправки сообщений
send_message() {
  local text="$1"
  local reply_markup="$2"
  
  if [ -n "$reply_markup" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${CHAT_ID}" \
      --data-urlencode "parse_mode=Markdown" \
      --data-urlencode "text=${text}" \
      --data-urlencode "reply_markup=${reply_markup}" > /dev/null
  else
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${CHAT_ID}" \
      --data-urlencode "parse_mode=Markdown" \
      --data-urlencode "text=${text}" > /dev/null
  fi
}

# Функция получения обновлений
get_updates() {
  # Проверяем, существует ли файл кеша offset и создаем его при необходимости
  if [ ! -f "$OFFSET_FILE" ]; then
    mkdir -p "$(dirname "$OFFSET_FILE")"
    echo "0" > "$OFFSET_FILE"
  fi
  
  # Перечитываем OFFSET на случай, если он был изменен вручную
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
  
  # Используем меньший timeout (10 секунд) для предотвращения зависания
  curl -s -m 20 "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=10&allowed_updates=[\"message\",\"callback_query\"]"
}

# Клавиатура с инлайн-кнопками
MAIN_KEYBOARD='{
  "inline_keyboard": [
    [{"text": "🖥 Аптайм", "callback_data": "uptime"}, {"text": "💾 Диск", "callback_data": "disk"}],
    [{"text": "📈 Память", "callback_data": "mem"}, {"text": "🔥 Топ", "callback_data": "top"}],
    [{"text": "👤 Пользователи", "callback_data": "who"}, {"text": "🌐 IP", "callback_data": "ip"}],
    [{"text": "🔐 Безопасность", "callback_data": "security"}, {"text": "📋 Чеклист", "callback_data": "checklist"}],
    [{"text": "🧹 Очистка логов", "callback_data": "clearlogs"}, {"text": "📜 Лог бота", "callback_data": "botlog"}]
  ]
}'

# Функция для обработки команд
process_command() {
  local cmd="$1"
  
  # Записываем время последней команды
  echo "$(date +%s)" > "$LAST_COMMAND_FILE"
  
  # Логируем команду
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Выполняется команда: $cmd" >> "$LOG_FILE"
  
  case "$cmd" in
    "start" | "/start")
      send_message "Добро пожаловать! Выберите команду:" "$MAIN_KEYBOARD"
      ;;
    "help" | "/help")
      send_message "*Команды:*
/uptime — аптайм
/disk — информация о диске
/mem — использование памяти
/top — топ процессов
/who — активные сессии пользователей
/ip — внутренний и внешний IP + геолокация
/security — проверка системы (rkhunter, psad)
/reboot — перезагрузка сервера
/confirm_reboot — подтвердить перезагрузку
/restart_bot — перезапуск бота
/botlog — последние логи бота
/checklist — быстрый системный чек-лист
/fullchecklist — полный системный чек-лист
/clearlogs — очистить логи бота
/resetcache — сброс кеша бота" "$MAIN_KEYBOARD"
      ;;
    "uptime" | "/uptime")
      send_message "*Аптайм:* $(uptime -p)" "$MAIN_KEYBOARD"
      ;;
    "disk" | "/disk")
      send_message "\`\`\`
$(df -h /)
\`\`\`" "$MAIN_KEYBOARD"
      ;;
    "mem" | "/mem")
      send_message "\`\`\`
$(free -h)
\`\`\`" "$MAIN_KEYBOARD"
      ;;
    "top" | "/top")
      send_message "\`\`\`
$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10)
\`\`\`" "$MAIN_KEYBOARD"
      ;;
    "who" | "/who")
      WHO_WITH_GEO=""
      # Используем sort -u для исключения дубликатов по IP
      while read -r user ip; do
        IP_ADDR=$(echo "$ip" | tr -d '()')
        [[ -z "$IP_ADDR" ]] && continue
        GEO=$(curl -s -m 5 ipinfo.io/$IP_ADDR | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
        WHO_WITH_GEO+="👤 $user — $IP_ADDR
🌍 $GEO

"
      done <<< "$(who | awk '{print $1, $5}' | grep -v "^$" | sort -u)"
      send_message "*Сессии пользователей:*

$WHO_WITH_GEO" "$MAIN_KEYBOARD"
      ;;
    "ip" | "/ip")
      IP_INT=$(hostname -I | awk '{print $1}')
      IP_EXT=$(curl -s -m 5 ifconfig.me || curl -s -m 5 ipinfo.io/ip || echo "Не удалось определить")
      GEO=$(curl -s -m 5 ipinfo.io/$IP_EXT | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
      send_message "*Внутренний IP:* \`$IP_INT\`
*Внешний IP:* \`$IP_EXT\`
🌍 *Геолокация:* $GEO" "$MAIN_KEYBOARD"
      ;;
    "security" | "/security")
      send_message "⏳ Выполняется проверка безопасности (rkhunter, psad)..." 
      echo "[BOT] Запускается rkhunter..." >> "$LOG_FILE"
      # Уменьшаем таймаут rkhunter для более быстрого ответа
      OUT=$(timeout 15s sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || echo "Ошибка запуска rkhunter")
      EXIT_CODE=$?
      if [[ "$EXIT_CODE" -eq 124 ]]; then
        RKHUNTER_RESULT="⚠️ rkhunter не ответил за 15 секунд"
      else
        RKHUNTER_RESULT=$(echo "$OUT" | tail -n 50)
      fi
      
      if [[ -f /var/log/psad/alert ]]; then
        PSAD_RESULT=$(grep "Danger level" /var/log/psad/alert 2>/dev/null | tail -n 5 || echo "")
        [[ -z "$PSAD_RESULT" ]] && PSAD_RESULT="psad лог пуст"
      else
        PSAD_RESULT="psad лог отсутствует"
      fi
      
      PSAD_STATUS=$(sudo psad -S 2>/dev/null | head -n 20 || echo "Ошибка запуска psad -S")
      TOP_IPS=$(sudo grep -i "Danger level" /var/log/psad/alert 2>/dev/null | tail -n 10 || echo "")
      [[ -z "$TOP_IPS" ]] && TOP_IPS="Нет записей о сканированиях."

      send_message "*RKHunter (последние строки):*
\`\`\`
$RKHUNTER_RESULT
\`\`\`

*PSAD:*
\`\`\`
$PSAD_RESULT
\`\`\`" "$MAIN_KEYBOARD"

      send_message "*Статус PSAD:*
\`\`\`
$PSAD_STATUS
\`\`\`"

      send_message "*Топ 10 IP-адресов (PSAD):*
\`\`\`
$TOP_IPS
\`\`\`"
      
      PSAD_LOG="/var/log/psad/alert"
      if [[ -f "$PSAD_LOG" ]]; then
        PSAD_RECENT=$(awk -v d1="$(date --date='-24 hours' +'%b %e')" '$0 ~ d1' "$PSAD_LOG" 2>/dev/null | tail -n 10 || echo "")
        [[ -z "$PSAD_RECENT" ]] && PSAD_RECENT="Нет записей за последние 24 часа"
      else
        PSAD_RECENT="Файл лога PSAD не найден"
      fi
      
      send_message "*📌 Последние события PSAD (24ч):*
\`\`\`
$PSAD_RECENT
\`\`\`" "$MAIN_KEYBOARD"
      ;;
    "reboot" | "/reboot")
      echo "1" > "$REBOOT_FLAG_FILE"
      send_message "⚠️ Подтвердите перезагрузку сервера командой */confirm_reboot*" "$MAIN_KEYBOARD"
      ;;
    "confirm_reboot" | "/confirm_reboot")
      if [[ -f "$REBOOT_FLAG_FILE" ]]; then
        send_message "♻️ Перезагрузка сервера..."
        rm -f "$REBOOT_FLAG_FILE"
        sleep 2
        sudo reboot
      else
        send_message "Нет активного запроса на перезагрузку." "$MAIN_KEYBOARD"
      fi
      ;;
    "restart_bot" | "/restart_bot")
      send_message "🔄 Перезапуск Telegram-бота..."
      sleep 1
      sudo systemctl restart telegram_command_listener.service
      exit 0
      ;;
    "botlog" | "/botlog")
      LOG=$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo "Лог отсутствует.")
      send_message "*Лог бота:*
\`\`\`
$LOG
\`\`\`" "$MAIN_KEYBOARD"
      ;;
    "checklist" | "/checklist")
      send_message "⏳ Формирование чек-листа..."
      
      # Формируем быстрый чек-лист
      CHECKLIST="/tmp/quick_checklist.txt"
      echo "Чеклист установки (быстрая версия):" > "$CHECKLIST"
      echo "Пользователь: $(whoami)" >> "$CHECKLIST"
      echo "SSH порт: $(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")" >> "$CHECKLIST"
      echo "Службы:" >> "$CHECKLIST"
      for SERVICE in ufw fail2ban psad rkhunter; do
        systemctl is-active --quiet "$SERVICE" 2>/dev/null && echo "  [+] $SERVICE" >> "$CHECKLIST" || echo "  [ ] $SERVICE" >> "$CHECKLIST"
      done
      
      # Проверяем Docker и Portainer
      if command -v docker &> /dev/null; then
        echo "Docker: установлен" >> "$CHECKLIST"
        if docker ps -q -f name=portainer &> /dev/null; then
          echo "Portainer: запущен" >> "$CHECKLIST"
        else
          echo "Portainer: не запущен" >> "$CHECKLIST"
        fi
      else
        echo "Docker: не установлен" >> "$CHECKLIST"
      fi
      
      # Проверяем Netdata
      if command -v netdata &> /dev/null || docker ps -q -f name=netdata &> /dev/null; then
        echo "Netdata: запущен" >> "$CHECKLIST"
      else
        echo "Netdata: не установлен" >> "$CHECKLIST"
      fi
      
      # Выводим чек-лист
      CHECKLIST_MSG=$(cat "$CHECKLIST" 2>/dev/null || echo 'Ошибка создания чек-листа.')
      send_message "*📋 Системный чек-лист:*
\`\`\`
$CHECKLIST_MSG
\`\`\`" "$MAIN_KEYBOARD"
      
      # Если есть сохраненный полный чек-лист, предлагаем его отдельно
      if [[ -f "/tmp/install_checklist.txt" ]]; then
        send_message "📄 *Примечание:* Доступен полный чек-лист. Отправить? (Введите */fullchecklist*)" 
      fi
      
      # Очищаем временный файл
      rm -f "$CHECKLIST"
      ;;
    "fullchecklist" | "/fullchecklist")
      FULL_CHECKLIST=$(cat /tmp/install_checklist.txt 2>/dev/null || echo 'Полный чек-лист не найден.')
      # Отправляем чек-лист частями, чтобы избежать задержек при большом объеме
      CHECKLIST_LENGTH=${#FULL_CHECKLIST}
      if [ "$CHECKLIST_LENGTH" -gt 3000 ]; then
        PART1=$(echo "$FULL_CHECKLIST" | head -n 20)
        PART2=$(echo "$FULL_CHECKLIST" | tail -n +21)
        send_message "*📋 Полный системный чек-лист (часть 1):*
\`\`\`
$PART1
\`\`\`"
        sleep 1
        send_message "*📋 Полный системный чек-лист (часть 2):*
\`\`\`
$PART2
\`\`\`" "$MAIN_KEYBOARD"
      else
        send_message "*📋 Полный системный чек-лист:*
\`\`\`
$FULL_CHECKLIST
\`\`\`" "$MAIN_KEYBOARD"
      fi
      ;;
    "clearlogs" | "/clearlogs")
      rm -f "$LOG_FILE" "$HOME/.local/share/telegram_bot/logs/"*.log
      send_message "🧹 Логи Telegram-бота и безопасности очищены." "$MAIN_KEYBOARD"
      ;;
    "resetcache" | "/resetcache")
      # Команда для очистки кеша offset
      rm -f "$OFFSET_FILE" "$LAST_COMMAND_FILE" "$REBOOT_FLAG_FILE"
      mkdir -p "$HOME/.local/share/telegram_bot/cache"
      touch "$OFFSET_FILE" "$LAST_COMMAND_FILE"
      echo "0" > "$OFFSET_FILE"
      send_message "🔄 Кеш бота очищен. Offset сброшен." "$MAIN_KEYBOARD"
      ;;
    *)
      send_message "Неизвестная команда. Напишите /help для списка." "$MAIN_KEYBOARD"
      ;;
  esac
}

# Основной цикл бота
echo "$(date '+%Y-%m-%d %H:%M:%S') | 🚀 Telegram-бот запущен. $SERVER_LABEL" >> "$LOG_FILE"

# Отправляем сообщение о запуске бота
send_message "🚀 *Telegram-бот перезапущен*
$SERVER_LABEL
$(date '+%Y-%m-%d %H:%M:%S')"

# Инициализация offset, если файл не существует
if [ ! -f "$OFFSET_FILE" ]; then
  mkdir -p "$(dirname "$OFFSET_FILE")"
  echo "0" > "$OFFSET_FILE"
fi
OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

while true; do
  # Получаем обновления от Telegram API
  RESPONSE=$(get_updates)
  
  # Если ответ пустой или содержит ошибку, делаем паузу и продолжаем
  if ! echo "$RESPONSE" | grep -q "\"ok\":true"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ⚠️ Ошибка при получении обновлений: $RESPONSE" >> "$LOG_FILE"
    sleep 5
    continue
  fi
  
  # Извлекаем обновления и их количество
  UPDATES=$(echo "$RESPONSE" | jq -c '.result')
  LENGTH=$(echo "$UPDATES" | jq 'length')
  
  # Если обновлений нет, делаем паузу и продолжаем
  [[ "$LENGTH" -eq 0 ]] && sleep 2 && continue

  # Обработка каждого обновления
  for ((i = 0; i < $LENGTH; i++)); do
    UPDATE=$(echo "$UPDATES" | jq -c ".[$i]")
    UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
    OFFSET=$((UPDATE_ID + 1))
    
    # Сохраняем новый offset
    echo "$OFFSET" > "$OFFSET_FILE"

    # Проверяем тип обновления: сообщение или callback_query
    MESSAGE_TEXT=$(echo "$UPDATE" | jq -r '.message.text // empty')
    CALLBACK_DATA=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
    
    if [[ -n "$MESSAGE_TEXT" ]]; then
      # Проверяем задержку между командами
      NOW=$(date +%s)
      LAST_CMD=$(cat "$LAST_COMMAND_FILE" 2>/dev/null || echo "0")
      DIFF=$((NOW - LAST_CMD))
      
      # Если интервал между командами менее 3 секунд, пропускаем команду
      if [[ "$DIFF" -lt 3 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Слишком частые запросы: $MESSAGE_TEXT (интервал $DIFF секунд)" >> "$LOG_FILE"
        continue
      fi
      
      # Обработка обычного сообщения
      process_command "$MESSAGE_TEXT"
    elif [[ -n "$CALLBACK_DATA" ]]; then
      # Обработка нажатия на инлайн-кнопку
      # Получаем callback_query_id для подтверждения нажатия
      CALLBACK_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')
      
      # Отправляем уведомление о получении callback_query
      curl -s -X POST "https://api.telegram.org/bot${TOKEN}/answerCallbackQuery" \
        -d "callback_query_id=$CALLBACK_ID" \
        -d "text=Выполняется команда..." > /dev/null
      
      # Проверяем задержку между командами callback
      NOW=$(date +%s)
      LAST_CMD=$(cat "$LAST_COMMAND_FILE" 2>/dev/null || echo "0")
      DIFF=$((NOW - LAST_CMD))
      
      # Более короткий интервал для callback (1 секунда)
      if [[ "$DIFF" -lt 1 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Слишком частые callback: $CALLBACK_DATA (интервал $DIFF секунд)" >> "$LOG_FILE"
        continue
      fi
      
      # Обрабатываем команду из callback_data
      process_command "$CALLBACK_DATA"
    fi
  done
  sleep 1
done
EOF