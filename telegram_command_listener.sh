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

send_message() {
  local text="$1"
  if [[ -z "$text" ]]; then
    echo "[⚠️] Пустой текст — сообщение не отправлено" >> "$LOG_FILE"
    return
  fi

  SAFE_TEXT=$(echo "$text" | iconv -f utf-8 -t utf-8 -c)

  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode chat_id="${CHAT_ID}" \
    --data-urlencode parse_mode="Markdown" \
    --data-urlencode text="${SAFE_TEXT}" > /dev/null
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
      UPDATE_TYPE="callback"
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

    echo "MESSAGE: $MESSAGE | TYPE: $UPDATE_TYPE" >> "$HOME/debug_bot.log"

    case "$MESSAGE" in
      /start)
        PAYLOAD='{
          "chat_id": "'"$CHAT_ID"'",
          "text": "Добро пожаловать! Выберите команду:",
          "reply_markup": {
            "inline_keyboard": [
              [{"text": "⏱ Аптайм", "callback_data": "uptime"}, {"text": "💽 Диск", "callback_data": "disk"}],
              [{"text": "🧠 Память", "callback_data": "mem"}, {"text": "🔥 TOP", "callback_data": "top"}],
              [{"text": "🛡 Безопасность", "callback_data": "security"}, {"text": "📋 Чек-лист", "callback_data": "checklist"}],
              [{"text": "🧹 Очистка логов", "callback_data": "clearlogs"}, {"text": "📂 Лог бота", "callback_data": "botlog"}],
              [{"text": "🌐 IP", "callback_data": "ip"}, {"text": "👤 Сессии", "callback_data": "who"}],
              [{"text": "♻️ Перезагрузка", "callback_data": "reboot"}, {"text": "🔄 Перезапуск", "callback_data": "restart_bot"}],
              [{"text": "❓ Помощь", "callback_data": "help"}]
            ]
          }
        }'

        curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
          -H "Content-Type: application/json" \
          -d "$PAYLOAD" > /dev/null
        ;;
      /uptime)
        send_message "*Аптайм:* $(uptime -p)"
        ;;
      /disk)
        send_message "```\n$(df -h /)\n```"
        ;;
      /mem)
        send_message "```\n$(free -h)\n```"
        ;;
      /top)
        send_message "```\n$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10)\n```"
        ;;
      /botlog)
        LOG=$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo "Лог отсутствует.")
        send_message "*Лог бота:*\n\`\`\`\n$LOG\n\`\`\`"
        ;;
      /checklist)
        CHECKLIST_MSG=$(cat /tmp/install_checklist.txt 2>/dev/null || echo 'Нет сохранённого чек-листа.')
        send_message "*📋 Системный чек-лист:*\n\`\`\`\n$CHECKLIST_MSG\n\`\`\`"
        ;;
      /clearlogs)
        rm -f "$LOG_FILE" "$HOME/.local/share/telegram_bot/logs/"*.log
        send_message "🧹 Логи Telegram-бота очищены."
        ;;
      /help)
        send_message "*Команды:*
/uptime — аптайм
/disk — информация о диске
/mem — использование памяти
/top — топ процессов
/who — активные сессии пользователей
/ip — внешний IP + гео
/security — rkhunter, psad
/reboot — запрос перезагрузки
/confirm_reboot — подтвердить перезагрузку
/restart_bot — перезапуск бота
/botlog — лог Telegram-бота
/checklist — системный чек-лист
/clearlogs — удалить логи
/help — справка"
        ;;
      /ip)
        IP_INT=$(hostname -I | awk '{print $1}')
        IP_EXT=$(curl -s ifconfig.me)
        GEO=$(curl -s ipinfo.io/$IP_EXT | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
        send_message "*Внутренний IP:* \`$IP_INT\`\n*Внешний IP:* \`$IP_EXT\`\n🌍 *Гео:* $GEO"
        ;;
      /who)
        WHO_WITH_GEO=""
        while read -r user tty date time ip; do
          IP_ADDR=$(echo "$ip" | tr -d '()')
          GEO=$(curl -s ipinfo.io/$IP_ADDR | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"' || echo "н/д")
          WHO_WITH_GEO+="👤 $user — $IP_ADDR\n🌍 $GEO\n\n"
        done <<< "$(who | awk '{print $1, $2, $3, $4, $5}')"
        send_message "*Сессии пользователей:*\n\n$WHO_WITH_GEO"
        ;;
      /security)
        send_message "⏳ Проверка безопасности (rkhunter, psad)..."
        OUT=$(timeout 90s sudo rkhunter --check --sk --nocolors --rwo)
        EXIT_CODE=$?
        if [[ "$EXIT_CODE" -eq 124 ]]; then
          RKHUNTER_RESULT="⚠️ rkhunter не ответил за 90 секунд"
        else
          RKHUNTER_RESULT=$(echo "$OUT" | tail -n 100)
        fi
        PSAD_LOG="/var/log/psad/alert"
        if [[ -s "$PSAD_LOG" ]]; then
          PSAD_RESULT=$(grep "Danger level" "$PSAD_LOG" | tail -n 5)
          [[ -z "$PSAD_RESULT" ]] && PSAD_RESULT="psad: событий нет"
        else
          PSAD_RESULT="psad: лог пуст или не создан"
        fi
        send_message "*RKHunter:*\n\`\`\`\n$RKHUNTER_RESULT\n\`\`\`"
        send_message "*PSAD:*\n\`\`\`\n$PSAD_RESULT\n\`\`\`"
        ;;
      /reboot)
        echo "1" > "$REBOOT_FLAG_FILE"
        send_message "⚠️ Подтвердите перезагрузку серверa: /confirm_reboot"
        ;;
      /confirm_reboot)
        if [[ -f "$REBOOT_FLAG_FILE" ]]; then
          send_message "♻️ Перезагрузка сервера..."
          rm -f "$REBOOT_FLAG_FILE"
          sleep 2
          sudo reboot
        else
          send_message "Нет активного запроса на перезагрузку."
        fi
        ;;
      /restart_bot)
        send_message "🔄 Перезапуск Telegram-бота..."
        sleep 1
        sudo systemctl restart telegram_command_listener.service
        exit 0
        ;;
      *)
        send_message "Неизвестная команда. Напиши /start или /help"
        ;;
    esac
  done
  sleep 2
done
