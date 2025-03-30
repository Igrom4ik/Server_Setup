#!/bin/bash
set -e

# Проверка зависимостей
for cmd in jq curl awk sudo; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Ошибка: $cmd не установлен. Установите его перед запуском."
    exit 1
  fi
done

# Запрос на удаление старых скриптов
read -p "🔍 Найти и удалить старые версии Telegram-бота и cron-скриптов? [y/N]: " DEL_OLD
if [[ "$DEL_OLD" =~ ^[Yy]$ ]]; then
  echo "🧹 Удаление старых скриптов..."
  sudo systemctl stop telegram_command_listener.service 2>/dev/null || true
  sudo systemctl disable telegram_command_listener.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/telegram_command_listener.service
  sudo rm -f /usr/local/bin/telegram_command_listener.sh
  sudo rm -f /usr/local/bin/telegram_ssh_notify.sh
  sudo rm -f /etc/cron.d/cron-security-check /etc/cron.d/cron-clear-security-log /etc/cron.d/cron-weekly-update
  sudo rm -f /usr/local/bin/cron_security_check.sh /usr/local/bin/cron_clear_security_log.sh /usr/local/bin/cron_weekly_update.sh
  sudo rm -rf /root/.cache/telegram_* /home/*/.cache/telegram_* ~/.local/share/telegram_bot/
  echo "✅ Старые скрипты удалены"
else
  echo "⏩ Пропуск удаления старых скриптов"
fi

CONFIG_FILE="/usr/local/bin/config.json"
CONFIG_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/config.json"

TMP_CONFIG="$(mktemp)"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "⚠️ config.json не найден. Загружаем с GitHub..."
  TMP_CONFIG="$(mktemp "$HOME/config.json.XXXX")"
  if curl -fsSL "$CONFIG_URL" -o "$TMP_CONFIG"; then
    sudo mv "$TMP_CONFIG" "$CONFIG_FILE"
    sudo chmod 644 "$CONFIG_FILE"
    echo "✅ config.json успешно загружен"
  else
    echo "❌ Ошибка: не удалось загрузить config.json с $CONFIG_URL"
    exit 1
  fi
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Ошибка: файл конфигурации $CONFIG_FILE не найден"
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

# 2. Системная защита: установка и активация сервисов (без psad)
log "🛡 Установка и настройка системной защиты"
for SERVICE in ufw fail2ban rkhunter nmap; do
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

# Установка и настройка psad отдельно
if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  log "📦 Установка psad"
  sudo apt install -y psad
fi

# Настройка psad
if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  log "📦 Настройка psad"
  echo "[*] Настройка psad.conf и логов..."

  # Проверяем и добавляем необходимые параметры, если их нет
  sudo sed -i 's/^ENABLE_AUTO_IDS.*/ENABLE_AUTO_IDS           Y;/g' /etc/psad/psad.conf
  sudo grep -q '^ENABLE_AUTO_IDS' /etc/psad/psad.conf || echo "ENABLE_AUTO_IDS           Y;" | sudo tee -a /etc/psad/psad.conf > /dev/null
  sudo sed -i 's/^ENABLE_EMAIL_ALERTS.*/ENABLE_EMAIL_ALERTS        Y;/g' /etc/psad/psad.conf
  sudo grep -q '^ENABLE_EMAIL_ALERTS' /etc/psad/psad.conf || echo "ENABLE_EMAIL_ALERTS        Y;" | sudo tee -a /etc/psad/psad.conf > /dev/null
  sudo sed -i 's/^ALERT_ALL.*/ALERT_ALL                 Y;/g' /etc/psad/psad.conf
  sudo grep -q '^ALERT_ALL' /etc/psad/psad.conf || echo "ALERT_ALL                 Y;" | sudo tee -a /etc/psad/psad.conf > /dev/null
  sudo sed -i 's/^ENABLE_DEBUG_OUTPUT.*/ENABLE_DEBUG_OUTPUT        Y;/g' /etc/psad/psad.conf
  sudo grep -q '^ENABLE_DEBUG_OUTPUT' /etc/psad/psad.conf || echo "ENABLE_DEBUG_OUTPUT        Y;" | sudo tee -a /etc/psad/psad.conf > /dev/null
  sudo sed -i 's/^ENABLE_AUTO_IDS_EMAILS.*/ENABLE_AUTO_IDS_EMAILS     Y;/g' /etc/psad/psad.conf
  sudo grep -q '^ENABLE_AUTO_IDS_EMAILS' /etc/psad/psad.conf || echo "ENABLE_AUTO_IDS_EMAILS     Y;" | sudo tee -a /etc/psad/psad.conf > /dev/null

  sudo sed -i "s/^HOSTNAME.*/HOSTNAME                    $(hostname);/g" /etc/psad/psad.conf
  sudo grep -q '^HOSTNAME' /etc/psad/psad.conf || echo "HOSTNAME                    $(hostname);" | sudo tee -a /etc/psad/psad.conf > /dev/null
  sudo sed -i "s/^EMAIL_ADDRESSES.*/EMAIL_ADDRESSES             root@localhost;/g" /etc/psad/psad.conf
  sudo grep -q '^EMAIL_ADDRESSES' /etc/psad/psad.conf || echo "EMAIL_ADDRESSES             root@localhost;" | sudo tee -a /etc/psad/psad.conf > /dev/null

  sudo touch /var/log/psad/alert
  sudo chmod 640 /var/log/psad/alert
  sudo chown root:root /var/log/psad/alert

  sudo psad -R && sudo psad -H && sudo psad --sig-update
  sudo systemctl enable --now psad
  log "✅ psad успешно настроен"
else
  log "ℹ️ psad отключён в config.json — настройка пропущена"
fi

log "📦 Настройка rkhunter"
RKHUNTER_CONF="/etc/rkhunter.conf"
RKHUNTER_BIN="/usr/bin/rkhunter"
RKHUNTER_LOG="$USER_HOME_DIR/.local/share/telegram_bot/logs/rkhunter_autofix.log"

mkdir -p "$(dirname "$RKHUNTER_LOG")"

log_rkhunter() {
  echo -e "[$(date '+%F %T')] $1" | tee -a "$RKHUNTER_LOG"
}

log_rkhunter "⚙️ Обновление конфигурации rkhunter..."

if grep -q "^WEB_CMD=" "$RKHUNTER_CONF"; then
  sudo sed -i 's|^WEB_CMD=.*|WEB_CMD=/usr/bin/wget|' "$RKHUNTER_CONF"
  log_rkhunter "✔️ WEB_CMD → /usr/bin/wget"
else
  echo "WEB_CMD=/usr/bin/wget" | sudo tee -a "$RKHUNTER_CONF"
  log_rkhunter "✔️ Добавлен WEB_CMD"
fi

sudo sed -i 's/^UPDATE_MIRRORS=.*/UPDATE_MIRRORS=0/' "$RKHUNTER_CONF"
sudo sed -i 's/^MIRRORS_MODE=.*/MIRRORS_MODE=0/' "$RKHUNTER_CONF"
if grep -q "^MIRROR_SITE=" "$RKHUNTER_CONF"; then
  sudo sed -i 's|^MIRROR_SITE=.*|MIRROR_SITE=http://rkhunter.sourceforge.net|' "$RKHUNTER_CONF"
else
  echo "MIRROR_SITE=http://rkhunter.sourceforge.net" | sudo tee -a "$RKHUNTER_CONF"
fi

log_rkhunter "🔄 Обновление баз данных..."
sudo "$RKHUNTER_BIN" --update >> "$RKHUNTER_LOG" 2>&1

log_rkhunter "🔐 Обновление контрольных сумм (propupd)..."
sudo "$RKHUNTER_BIN" --propupd -q
log_rkhunter "✅ rkhunter готов к использованию."

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
    if ! sudo docker ps -q -f name=portainer > /dev/null; then
      sudo docker start portainer && log "Portainer запущен" || log "⚠️ Portainer установлен, но не удалось запустить"
    fi
    log "Portainer уже установлен"
  fi
fi

# 4. Установка Netdata
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
      -v /sys_oc:/host/sys:ro \
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

# 5. Установка и настройка Telegram-бота (новая версия)
log "🤖 Установка и настройка Telegram-бота"
sudo tee /usr/local/bin/telegram_command_listener.sh > /dev/null <<'EOF'
#!/bin/bash
USER_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
export HOME="$USER_HOME"
TOKEN="'"$BOT_TOKEN"'"
CHAT_ID="'"$CHAT_ID"'"
LOG_FILE="$HOME/.local/share/telegram_bot/logs/bot_debug.log"
OFFSET_FILE="$HOME/.local/share/telegram_bot/cache/offset"
LAST_COMMAND_FILE="$HOME/.local/share/telegram_bot/cache/last_command"
REBOOT_FLAG_FILE="$HOME/.local/share/telegram_bot/cache/confirm_reboot"
CHECKLIST_FILE="$HOME/.local/share/telegram_bot/cache/checklist"
UPDATE_FLAG_FILE="$HOME/.local/share/telegram_bot/cache/confirm_update"

mkdir -p "$HOME/.local/share/telegram_bot/logs"
mkdir -p "$HOME/.local/share/telegram_bot/cache"
touch "$OFFSET_FILE.processed"

if [[ ! -f "$CHECKLIST_FILE" ]]; then
  echo -e "✅ Сервер активен.\n🔐 Защита работает.\n📡 Мониторинг включен." > "$CHECKLIST_FILE"
fi

exec >>"$LOG_FILE" 2>&1
set -x

OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

send_message_html() {
  local text="$1"
  [[ -z "$text" ]] && return
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode chat_id="${CHAT_ID}" \
    --data-urlencode parse_mode="HTML" \
    --data-urlencode text="$text" > /dev/null
}

send_message() {
  local text="$1"
  [[ -z "$text" ]] && return
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode chat_id="${CHAT_ID}" \
    --data-urlencode parse_mode="Markdown" \
    --data-urlencode text="$text" > /dev/null
}

get_updates() {
  curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET"
}

escape_html() {
  echo "$1" | sed 's/&/\&/g; s/</\</g; s/>/\>/g; s/"/\"/g'
}

while true; do
  RESPONSE=$(get_updates)
  UPDATES=$(echo "$RESPONSE" | jq -c '.result')
  LENGTH=$(echo "$UPDATES" | jq 'length')
  [[ "$LENGTH" -eq 0 ]] && sleep 2 && continue

  for ((i = 0; i < LENGTH; i++)); do
    UPDATE=$(echo "$UPDATES" | jq -c ".[$i]")
    UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')

    if grep -q "$UPDATE_ID" "$OFFSET_FILE.processed" 2>/dev/null; then
      continue
    fi

    echo "$UPDATE_ID" >> "$OFFSET_FILE.processed"
    OFFSET=$((UPDATE_ID + 1))
    echo "$OFFSET" > "$OFFSET_FILE"

    CALLBACK_DATA=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
    if [[ -n "$CALLBACK_DATA" && "$CALLBACK_DATA" != "null" ]]; then
      MESSAGE="/$CALLBACK_DATA"
      CALLBACK_QUERY_ID=$(echo "$UPDATE" | jq -r '.callback_query.id')
      curl -s -X POST "https://api.telegram.org/bot${TOKEN}/answerCallbackQuery" \
        -d callback_query_id="$CALLBACK_QUERY_ID" > /dev/null
    else
      MESSAGE=$(echo "$UPDATE" | jq -r '.message.text // empty')
    fi

    [[ -z "$MESSAGE" ]] && continue

    NOW=$(date +%s)
    LAST_CMD=$(cat "$LAST_COMMAND_FILE" 2>/dev/null || echo "0")
    DIFF=$((NOW - LAST_CMD))
    [[ "$DIFF" -lt 2 ]] && continue
    echo "$NOW" > "$LAST_COMMAND_FILE"

    case "$MESSAGE" in
      /start)
        curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
          -H "Content-Type: application/json" \
          -d '{
            "chat_id": "'"$CHAT_ID"'",
            "text": "Выберите команду:",
            "reply_markup": {
              "inline_keyboard": [
                [{"text": "🛡 Безопасность", "callback_data": "security"}],
                [{"text": "📊 Загрузка", "callback_data": "top"}],
                [{"text": "🕒 Аптайм", "callback_data": "uptime"}],
                [{"text": "💾 Диск", "callback_data": "disk"}],
                [{"text": "📈 Память", "callback_data": "mem"}],
                [{"text": "📡 IP", "callback_data": "ip"}],
                [{"text": "🔍 Кто в системе", "callback_data": "who"}],
                [{"text": "🔄 Обновление", "callback_data": "update"}],
                [{"text": "♻️ Перезагрузка", "callback_data": "reboot"}],
                [{"text": "📝 Чеклист", "callback_data": "checklist"}],
                [{"text": "🧹 Логи", "callback_data": "botlog"}],
                [{"text": "❓ Помощь", "callback_data": "help"}]
              ]
            }
          }' > /dev/null
        ;;
      /uptime)
        send_message_html "<pre>$(escape_html "$(uptime)")</pre>"
        ;;
      /disk)
        send_message_html "<pre>$(escape_html "$(df -h / | tail -n 1)")</pre>"
        ;;
      /mem)
        send_message_html "<pre>$(escape_html "$(free -h)")</pre>"
        ;;
      /top)
        send_message_html "<pre>$(escape_html "$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 10)")</pre>"
        ;;
      /ip)
        IP_EXTERNAL=$(curl -s ifconfig.me)
        IP_INTERNAL=$(hostname -I | awk '{print $1}')
        GEO_INFO=$(curl -s "http://ip-api.com/json/$IP_EXTERNAL")
        COUNTRY=$(echo "$GEO_INFO" | jq -r '.country // "Неизвестно"')
        CITY=$(echo "$GEO_INFO" | jq -r '.city // "Неизвестно"')
        ISP=$(echo "$GEO_INFO" | jq -r '.isp // "Неизвестно"')

        IP_MESSAGE="<b>🌐 Информация об IP-адресах</b>

<b>🏠 Внутренний IP:</b> <code>$IP_INTERNAL</code>
<b>🌍 Внешний IP:</b> <code>$IP_EXTERNAL</code>

<b>📍 Геолокация:</b>
  <b>Страна:</b> $COUNTRY
  <b>Город:</b> $CITY
  <b>Провайдер:</b> $ISP"

        send_message_html "$IP_MESSAGE"
        ;;
      /who)
        WHO_OUTPUT=$(who)
        if [[ -z "$WHO_OUTPUT" ]]; then
          WHO_MESSAGE="<b>👤 Пользователи в системе</b>
          
<i>В настоящее время нет активных пользователей</i>"
        else
          WHO_MESSAGE="<b>👤 Пользователи в системе</b>"
          while IFS= read -r line; do
            USER=$(echo "$line" | awk '{print $1}')
            TTY=$(echo "$line" | awk '{print $2}')
            FROM=$(echo "$line" | awk '{print $5}' | tr -d '()')
            TIME=$(echo "$line" | awk '{print $3, $4}')
            [[ -z "$FROM" || "$FROM" == "*" ]] && FROM="локальный вход"

            WHO_MESSAGE+="

<b>👤 $USER</b>
   📱 Терминал: <code>$TTY</code>
   🖥️ Подключен с: <code>$FROM</code>
   🕒 Время входа: <code>$TIME</code>"
          done <<< "$WHO_OUTPUT"
        fi
        send_message_html "$WHO_MESSAGE"
        ;;
      /botlog)
        LOG_DATA=$(tail -n 20 "$LOG_FILE" | grep -v "get_updates" | head -c 4000)
        [[ -z "$LOG_DATA" ]] && send_message_html "<b>📝 Логи Telegram-бота</b>\n\n<i>Файл логов пуст</i>" && continue
        LOG_ESCAPED=$(escape_html "$LOG_DATA")
        send_message_html "<b>📝 Логи Telegram-бота</b>\n<pre>$LOG_ESCAPED</pre>\n<b>🤖 Бот активен</b>"
        ;;
      /checklist)
        if [[ -f "$CHECKLIST_FILE" && -s "$CHECKLIST_FILE" ]]; then
          CHECKLIST_CONTENT=$(cat "$CHECKLIST_FILE")
          send_message_html "<b>📝 Чек-лист сервера</b>\n<pre>$CHECKLIST_CONTENT</pre>\n<i>/add_checklist для добавления</i>"
        else
          send_message_html "<b>📝 Чек-лист сервера</b>\n<i>Чек-лист пуст</i>"
        fi
        ;;
      /clearlogs)
        > "$LOG_FILE"
        send_message_html "🧹 <b>Логи Telegram-бота очищены</b>"
        ;;
      /restart_bot)
        send_message_html "🔄 <b>Перезапуск Telegram-бота...</b>"
        systemctl restart telegram_command_listener.service
        ;;
      /reboot)
        send_message_html "⚠️ <b>Подтвердите перезагрузку:</b> /confirm_reboot"
        ;;
      /confirm_reboot)
        send_message_html "♻️ <b>Перезагружаем сервер...</b>"
        sudo reboot
        ;;
      /update)
        send_message_html "⚠️ <b>Подтвердите обновление системы:</b> /confirm_update"
        ;;
      /confirm_update)
        touch "$UPDATE_FLAG_FILE"
        send_message_html "🔄 <b>Начинаем обновление системы...</b>"
        {
          sudo apt update -y && sudo apt upgrade -y
          send_message_html "✅ <b>Система успешно обновлена</b>"
          [[ -f /var/run/reboot-required ]] && send_message_html "⚠️ <b>Требуется перезагрузка</b>"
          rm -f "$UPDATE_FLAG_FILE"
        } &
        ;;
      /security)
        send_message_html "<b>⏳ Проверка безопасности...</b>"
        RKHUNTER_OUTPUT=$(timeout 60s sudo rkhunter --check --sk --nocolors --rwo 2>&1)
        PSAD_OUTPUT=$(sudo psad -S 2>/dev/null)
        send_message_html "<b>RKHunter:</b>\n<pre>$(escape_html "$RKHUNTER_OUTPUT" | tail -n 80)</pre>"
        send_message_html "<b>PSAD:</b>\n<pre>$(escape_html "$PSAD_OUTPUT" | head -n 50)</pre>"
        ;;
      /help)
        send_message_html "<b>📚 Доступные команды:</b>
<pre>/start, /uptime, /disk, /mem, /top
/ip, /who, /security, /update
/checklist, /clearlogs, /botlog
/reboot, /confirm_reboot, /restart_bot, /help</pre>"
        ;;
      *)
        send_message "Неизвестная команда. Напиши /start для меню."
        ;;
    esac
  done
  sleep 2
done
EOF

sudo chmod +x /usr/local/bin/telegram_command_listener.sh

sudo tee /etc/systemd/system/telegram_command_listener.service > /dev/null <<EOF
[Unit]
Description=Telegram Command Listener Bot Service
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
User=$USERNAME

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now telegram_command_listener.service

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

if [[ -f "\$CACHE_FILE" ]]; then
  LAST_TIME=\$(cat "\$CACHE_FILE")
  NOW=\$(date +%s)
  DIFF=\$((\$NOW - \$LAST_TIME))
  if [[ "\$DIFF" -lt 10 ]]; then
    exit 0
  fi
fi

date +%s > "\$CACHE_FILE"

GEO=\$(curl -s ipinfo.io/\$IP | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
TEXT="🔐 SSH вход: *\$USER*
📡 IP: \\\$IP\\\n
🌍 Местоположение: \$GEO
🕒 Время: \$(date +'%Y-%m-%d %H:%M:%S')"

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \\
  -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$TEXT" > /dev/null
EOF

sudo chmod +x /usr/local/bin/telegram_ssh_notify.sh
if ! grep -q "telegram_ssh_notify.sh" /etc/pam.d/sshd; then
  echo "session optional pam_exec.so /usr/local/bin/telegram_ssh_notify.sh" | sudo tee -a /etc/pam.d/sshd > /dev/null
fi

# Настройка логирования psad и iptables
log "🧱 Настройка логирования psad и iptables"
sudo iptables -C INPUT -j LOG 2>/dev/null || sudo iptables -I INPUT -j LOG
sudo iptables -C FORWARD -j LOG 2>/dev/null || sudo iptables -I FORWARD -j LOG

if ! grep -q "psad" /etc/rsyslog.conf; then
  echo ':msg, contains, "psad" /var/log/psad/alert' | sudo tee -a /etc/rsyslog.conf > /dev/null
  echo '& stop' | sudo tee -a /etc/rsyslog.conf > /dev/null
  sudo systemctl restart rsyslog
fi

if grep -q "IPT_SYSLOG_FILE" /etc/psad/psad.conf; then
  sudo sed -i "s|^IPT_SYSLOG_FILE.*|IPT_SYSLOG_FILE             /var/log/kern.log;|" /etc/psad/psad.conf
  sudo systemctl restart psad
  log "psad сконфигурирован"
fi

log "🛡 Настройка sudo для rkhunter (без пароля для бота)"
if ! sudo grep -q "/usr/bin/rkhunter" /etc/sudoers; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/rkhunter" | sudo tee -a /etc/sudoers > /dev/null
  log "Добавлено правило sudoers для rkhunter"
else
  log "Правило sudoers для rkhunter уже существует — пропущено"
fi

# 6. Финальный чек-лист
log "📬 Финальный чек-лист установки"
CHECKLIST="/tmp/install_checklist.txt"

if [[ "$(jq -r '.services.rkhunter' "$CONFIG_FILE")" == "true" ]]; then
  sudo rkhunter --check --sk --nocolors --rwo > /tmp/rkhunter_check_output 2>/dev/null &
fi

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
  wait
  RKHUNTER_OUTPUT=$(cat /tmp/rkhunter_check_output 2>/dev/null || echo "")
  if [[ -n "$RKHUNTER_OUTPUT" ]]; then
    echo "RKHunter: ОБНАРУЖЕНЫ предупреждения:" >> "$CHECKLIST"
    RKHUNTER_LAST=$(echo "$RKHUNTER_OUTPUT" | tail -n 10)
    echo "$RKHUNTER_LAST" >> "$CHECKLIST"
  else
    echo "RKHunter: OK (нарушений не обнаружено)" >> "$CHECKLIST"
  fi
  rm -f /tmp/rkhunter_check_output
fi
if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  if [[ -f /var/log/psad/alert ]]; then
    PSAD_ALERTS=$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
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

cat "$CHECKLIST"
CHECK_MSG=$(sed 's/`/\\`/g' "$CHECKLIST")
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" -d parse_mode="Markdown" \
  --data-urlencode text="\`\`\`$CHECK_MSG\`\`\`" > /dev/null

rm -f "$CHECKLIST"

# 7. Настройка cron-задач
log "🕒 Настройка cron-задач: ежедневная проверка, очистка логов, обновления"

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

RKHUNTER_RESULT=\$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "\$RKHUNTER_RESULT" ]; then
    send_telegram "⚠️ *RKHunter обнаружил подозрительные элементы:*\n\`\`\`\n\$RKHUNTER_RESULT\n\`\`\`"
    echo "\$(timestamp) | ⚠️ RKHunter: найдены подозрения" >> "\$LOG_FILE"
else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
    echo "\$(timestamp) | ✅ RKHunter: всё чисто" >> "\$LOG_FILE"
fi

PSAD_ALERTS=\$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
if echo "\$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n\$PSAD_ALERTS\n\`\`\`"
    echo "\$(timestamp) | 🚨 PSAD: найдены угрозы" >> "\$LOG_FILE"
else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
    echo "\$(timestamp) | ✅ PSAD: всё спокойно" >> "\$LOG_FILE"
fi
echo "\$(timestamp) | ✅ Проверка завершена" >> "\$LOG_FILE"
EOF

if [[ -f "/usr/local/bin/cron_security_check.sh" ]]; then
  sudo chmod +x /usr/local/bin/cron_security_check.sh
  log "✅ Скрипт cron_security_check.sh создан успешно"
  echo "0 7 * * * root /usr/local/bin/cron_security_check.sh" | sudo tee /etc/cron.d/cron-security-check > /dev/null
  log "✅ Cron-задача ежедневной проверки настроена"
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

RKHUNTER_RESULT=\$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "\$RKHUNTER_RESULT" ]; then
    send_telegram "⚠️ *RKHunter обнаружил подозрительные элементы:*\n\`\`\`\n\$RKHUNTER_RESULT\n\`\`\`"
    echo "\$(timestamp) | ⚠️ RKHunter: найдены подозрения" >> "\$LOG_FILE"
else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
    echo "\$(timestamp) | ✅ RKHunter: всё чисто" >> "\$LOG_FILE"
fi

PSAD_ALERTS=\$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
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
  echo "0 7 * * * root /usr/local/bin/cron_security_check.sh" | sudo tee /etc/cron.d/cron-security-check > /dev/null
fi

sudo tee /usr/local/bin/cron_clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Очистка лога безопасности (еженедельно)" > "\$LOG_FILE"
EOF

if [[ -f "/usr/local/bin/cron_clear_security_log.sh" ]]; then
  sudo chmod +x /usr/local/bin/cron_clear_security_log.sh
  log "✅ Скрипт очистки логов создан успешно"
  echo "0 6 * * 1 root /usr/local/bin/cron_clear_security_log.sh" | sudo tee /etc/cron.d/cron-clear-security-log > /dev/null
  log "✅ Cron-задача очистки логов настроена"
else
  log "⚠️ Ошибка: не удалось создать скрипт очистки логов"
  sudo mkdir -p /usr/local/bin/
  sudo chmod 755 /usr/local/bin/
  sudo tee /usr/local/bin/cron_clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Очистка лога безопасности (еженедельно)" > "\$LOG_FILE"
EOF
  sudo chmod +x /usr/local/bin/cron_clear_security_log.sh
  echo "0 6 * * 1 root /usr/local/bin/cron_clear_security_log.sh" | sudo tee /etc/cron.d/cron-clear-security-log > /dev/null
fi

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

if [[ -f "/usr/local/bin/cron_weekly_update.sh" ]]; then
  sudo chmod +x /usr/local/bin/cron_weekly_update.sh
  log "✅ Скрипт еженедельного обновления создан успешно"
  echo "30 5 * * 1 root /usr/local/bin/cron_weekly_update.sh" | sudo tee /etc/cron.d/cron-weekly-update > /dev/null
  log "✅ Cron-задача еженедельного обновления настроена"
else
  log "⚠️ Ошибка: не удалось создать скрипт еженедельного обновления"
  sudo mkdir -p /usr/local/bin/
  sudo chmod 755 /usr/local/bin/
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
  echo "30 5 * * 1 root /usr/local/bin/cron_weekly_update.sh" | sudo tee /etc/cron.d/cron-weekly-update > /dev/null
fi

log "✅ Установка завершена"