#!/bin/bash
USER_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
export HOME="$USER_HOME"
TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"
LOG_FILE="$HOME/.local/share/telegram_bot/logs/bot_debug.log"
OFFSET_FILE="$HOME/.local/share/telegram_bot/cache/offset"
LAST_COMMAND_FILE="$HOME/.local/share/telegram_bot/cache/last_command"
REBOOT_FLAG_FILE="$HOME/.local/share/telegram_bot/cache/confirm_reboot"

mkdir -p "$HOME/.local/share/telegram_bot/logs"
mkdir -p "$HOME/.local/share/telegram_bot/cache"
touch "$OFFSET_FILE.processed"

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
                [{"text": "♻️ Перезагрузка", "callback_data": "reboot"}],
                [{"text": "📝 Чеклист", "callback_data": "checklist"}],
                [{"text": "🧹 Логи", "callback_data": "botlog"}],
                [{"text": "❓ Помощь", "callback_data": "help"}]
              ]
            }
          }' > /dev/null
        ;;
      /uptime)
        send_message_html "<pre>$(uptime)</pre>"
        ;;
      /disk)
        send_message_html "<pre>$(df -h / | tail -n 1)</pre>"
        ;;
      /mem)
        send_message_html "<pre>$(free -h)</pre>"
        ;;
      /top)
        send_message_html "<pre>$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 10)</pre>"
        ;;
      /ip)
        IP_EXTERNAL=$(curl -s ifconfig.me)
        IP_INTERNAL=$(hostname -I | awk '{print $1}')
        
        # Получаем геолокацию
        GEO_INFO=$(curl -s "http://ip-api.com/json/$IP_EXTERNAL")
        COUNTRY=$(echo "$GEO_INFO" | jq -r '.country // "Неизвестно"')
        CITY=$(echo "$GEO_INFO" | jq -r '.city // "Неизвестно"')
        ISP=$(echo "$GEO_INFO" | jq -r '.isp // "Неизвестно"')
        
        # Формируем красивый HTML-вывод
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
        # Получаем информацию о пользователях в системе
        WHO_OUTPUT=$(who)
        
        if [[ -z "$WHO_OUTPUT" ]]; then
          WHO_MESSAGE="<b>👤 Пользователи в системе</b>
          
<i>В настоящее время нет активных пользователей</i>"
        else
          # Преобразуем вывод who в удобочитаемый формат HTML
          WHO_MESSAGE="<b>👤 Пользователи в системе</b>"
          
          # Обрабатываем каждую строку вывода who
          while IFS= read -r line; do
            USER=$(echo "$line" | awk '{print $1}')
            TTY=$(echo "$line" | awk '{print $2}')
            FROM=$(echo "$line" | awk '{print $5}' | tr -d '()')
            TIME=$(echo "$line" | awk '{print $3, $4}')
            
            # Если IP не найден, используем "локальный вход"
            if [[ -z "$FROM" || "$FROM" == "*" ]]; then
              FROM="локальный вход"
            fi
            
            # Добавляем строку в сообщение с иконкой статуса
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
        send_message_html "<pre>$(tail -n 50 "$LOG_FILE" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')</pre>"
        ;;
      /checklist)
        send_message_html "✅ Сервер активен.<br>🔐 Защита работает.<br>📡 Мониторинг включен."
        ;;
      /clearlogs)
        > "$LOG_FILE"
        send_message_html "🧹 Логи очищены"
        ;;
      /restart_bot)
        send_message_html "🔁 Перезапуск Telegram-бота..."
        sudo systemctl restart telegram_command_listener.service
        ;;
      /reboot)
        send_message_html "⚠️ Подтвердите перезагрузку: /confirm_reboot"
        ;;
      /confirm_reboot)
        send_message_html "♻️ Перезагружаем сервер..."
        sudo reboot
        ;;
      /help)
        send_message "Доступные команды: /start /security /uptime /disk /mem /top /ip /who /checklist /botlog /clearlogs /restart_bot /reboot /help"
        ;;
      /security)
        send_message_html "<b>⏳ Проверка безопасности (rkhunter, psad)...</b>"

        RKHUNTER_OUTPUT=$(timeout --foreground 60s sudo rkhunter --check --sk --nocolors --rwo 2>&1)
        RKHUNTER_EXIT=$?

        if [[ "$RKHUNTER_EXIT" -eq 124 ]]; then
          RKHUNTER_RESULT="⚠️ <b>rkhunter не ответил за 60 секунд</b>"
        elif [[ -z "$RKHUNTER_OUTPUT" ]]; then
          RKHUNTER_RESULT="✅ <b>Нет предупреждений от rkhunter</b>"
        else
          RKHUNTER_RESULT="<b>RKHunter:</b>\n<pre>$(echo "$RKHUNTER_OUTPUT" | tail -n 100 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')</pre>"
        fi

        # Улучшенный вывод PSAD
        PSAD_OUTPUT=$(sudo psad -S 2>/dev/null)
        if [[ -n "$PSAD_OUTPUT" ]]; then
          # Выделим информацию о процессах psad
          PSAD_PROCESSES=$(echo "$PSAD_OUTPUT" | grep -E '^\[\+\] psad' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')
          
          # Выделим информацию о запуске
          PSAD_RUNNING=$(echo "$PSAD_OUTPUT" | grep -E 'Running since:' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')
          
          # Выделим настройки email
          PSAD_EMAIL=$(echo "$PSAD_OUTPUT" | grep -E 'Alert email' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')
          
          # Формируем красивый отчет (исправленное форматирование)
          PSAD_RESULT="<b>🔍 Статус PSAD (Система обнаружения вторжений)</b>

<b>🔄 Активные процессы:</b>
<pre>$PSAD_PROCESSES</pre>

<b>⏱️ Время работы:</b>
<pre>$PSAD_RUNNING</pre>

<b>📧 Оповещения:</b>
<pre>$PSAD_EMAIL</pre>

<b>📋 Полный вывод команды:</b>
<pre>$(echo "$PSAD_OUTPUT" | head -n 80 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')</pre>"
        else
          PSAD_RESULT="ℹ️ <b>psad:</b> нет вывода команды psad -S"
        fi

        send_message_html "$RKHUNTER_RESULT"
        send_message_html "$PSAD_RESULT"
        ;;
      *)
        send_message "Неизвестная команда. Напиши /start для меню."
        ;;
    esac
  done
  sleep 2
done