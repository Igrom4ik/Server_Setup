#!/bin/bash
USER_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
export HOME="$USER_HOME"
TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"
LOG_FILE="$HOME/.local/share/telegram_bot/logs/bot_debug.log"
OFFSET_FILE="$HOME/.local/share/telegram_bot/cache/offset"
LAST_COMMAND_FILE="$HOME/.local/share/telegram_bot/cache/last_command"
REBOOT_FLAG_FILE="$HOME/.local/share/telegram_bot/cache/confirm_reboot"
CHECKLIST_FILE="$HOME/.local/share/telegram_bot/cache/checklist"
UPDATE_FLAG_FILE="$HOME/.local/share/telegram_bot/cache/confirm_update"

mkdir -p "$HOME/.local/share/telegram_bot/logs"
mkdir -p "$HOME/.local/share/telegram_bot/cache"
touch "$OFFSET_FILE.processed"

  # Создаем чеклист по умолчанию, если его нет
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

# Функция для корректного экранирования HTML-тегов
escape_html() {
  echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
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
        UPTIME_DATA=$(uptime)
        send_message_html "<pre>$(escape_html "$UPTIME_DATA")</pre>"
        ;;
      /disk)
        DISK_DATA=$(df -h / | tail -n 1)
        send_message_html "<pre>$(escape_html "$DISK_DATA")</pre>"
        ;;
      /mem)
        MEM_DATA=$(free -h)
        send_message_html "<pre>$(escape_html "$MEM_DATA")</pre>"
        ;;
      /top)
        TOP_DATA=$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 10)
        send_message_html "<pre>$(escape_html "$TOP_DATA")</pre>"
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
        # Получаем логи
        LOG_DATA=$(tail -n 20 "$LOG_FILE" | grep -v "get_updates" | head -c 4000)
        if [[ -z "$LOG_DATA" ]]; then
          send_message_html "<b>📝 Логи Telegram-бота</b>\n\n<i>Файл логов пуст</i>"
        else
          # Экранирование HTML-тегов
          LOG_ESCAPED=$(escape_html "$LOG_DATA")
          
          # Формируем сообщение в соответствии со вторым изображением
          send_message_html "<b>📝 Логи Telegram-бота</b>

Последние действия:
<pre class=\"shell\">$LOG_ESCAPED</pre>

<b>🤖 Статус бота:</b>
✅ Telegram-бот активен и отвечает на команды
⏱️ Время работы: $(uptime -p)
🔄 Последний перезапуск: $(uptime -s)"
        fi
        ;;
      /checklist)
        # Проверяем существование чек-листа и выводим его содержимое
        if [[ -f "$CHECKLIST_FILE" && -s "$CHECKLIST_FILE" ]]; then
          # Создаем сообщение в соответствии со вторым изображением
          CHECKLIST_CONTENT=$(cat "$CHECKLIST_FILE")
          
          send_message_html "<b>📝 Чек-лист сервера</b>

<pre>$CHECKLIST_CONTENT</pre>

<i>Используйте /add_checklist для добавления пунктов
/clear_checklist для очистки списка</i>"
        else
          send_message_html "<b>📝 Чек-лист сервера</b>

<i>Чек-лист пуст или не существует</i>

<i>Используйте /add_checklist для добавления пунктов</i>"
        fi
        ;;
      /add_checklist)
        # Добавить новый пункт в чек-лист (пример использования)
        CHECK_ITEM=$(echo "$MESSAGE" | cut -d' ' -f2-)
        if [[ -n "$CHECK_ITEM" ]]; then
          echo "✅ $CHECK_ITEM" >> "$CHECKLIST_FILE"
          send_message_html "<b>✅ Добавлен новый пункт в чек-лист:</b> $CHECK_ITEM"
        else
          send_message_html "<i>⚠️ Использование:</i> <code>/add_checklist Текст пункта</code>"
        fi
        ;;
      /clear_checklist)
        # Очистить чек-лист
        > "$CHECKLIST_FILE"
        send_message_html "<b>🧹 Чек-лист очищен</b>"
        ;;
      /clearlogs)
        > "$LOG_FILE"
        send_message_html "🧹 <b>Логи очищены</b>"
        ;;
      /restart_bot)
        send_message_html "🔁 <b>Перезапуск Telegram-бота...</b>"
        sudo systemctl restart telegram_command_listener.service
        ;;
      /update)
        send_message_html "⚠️ <b>Подтвердите обновление системы:</b> /confirm_update"
        ;;
      /confirm_update)
        # Создаем флаг, что обновление началось
        touch "$UPDATE_FLAG_FILE"
        
        send_message_html "🔄 <b>Начинаем обновление системы...</b>"
        
        # Запускаем обновление в фоновом режиме и отправляем результаты
        {
          UPDATE_LOG=$(mktemp)
          send_message_html "<b>📥 Обновление списка пакетов...</b>"
          sudo apt update -y &> "$UPDATE_LOG"
          APT_UPDATE_EXIT=$?
          
          if [[ "$APT_UPDATE_EXIT" -eq 0 ]]; then
            UPDATE_RESULT="✅ <b>Список пакетов успешно обновлен</b>"
          else
            UPDATE_LOG_CONTENT=$(cat "$UPDATE_LOG" | head -n 30 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')
            UPDATE_RESULT="❌ <b>Ошибка при обновлении списка пакетов:</b>\n<pre>$UPDATE_LOG_CONTENT</pre>"
            send_message_html "$UPDATE_RESULT"
            rm -f "$UPDATE_LOG" "$UPDATE_FLAG_FILE"
            exit 1
          fi
          send_message_html "$UPDATE_RESULT"
          
          # Проверяем наличие обновлений
          UPGRADE_COUNT=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)
          
          if [[ "$UPGRADE_COUNT" -eq 0 ]]; then
            send_message_html "✅ <b>Система полностью обновлена. Новых пакетов не обнаружено.</b>"
            rm -f "$UPDATE_LOG" "$UPDATE_FLAG_FILE"
            exit 0
          fi
          
          # Выводим список пакетов для обновления
          UPGRADABLE_PACKAGES=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | head -n 15 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')
          TOTAL_UPGRADE="$UPGRADE_COUNT"
          if [[ "$UPGRADE_COUNT" -gt 15 ]]; then
            UPGRADABLE_PACKAGES="$UPGRADABLE_PACKAGES\n...(и еще $((UPGRADE_COUNT - 15)) пакетов)"
          fi
          
          send_message_html "<b>🔍 Доступно обновлений:</b> $TOTAL_UPGRADE пакетов

<pre>$UPGRADABLE_PACKAGES</pre>

<b>⏳ Началась установка обновлений...</b>"
          
          # Выполняем обновление
          > "$UPDATE_LOG"
          sudo apt upgrade -y &> "$UPDATE_LOG"
          APT_UPGRADE_EXIT=$?
          
          if [[ "$APT_UPGRADE_EXIT" -eq 0 ]]; then
            send_message_html "✅ <b>Обновление системы успешно завершено!</b>"
            
            # Проверяем, требуется ли перезагрузка
            if [ -f /var/run/reboot-required ]; then
              send_message_html "⚠️ <b>Требуется перезагрузка сервера для завершения обновления.</b>
              
Используйте команду /reboot для перезагрузки."
            fi
          else
            UPGRADE_LOG_CONTENT=$(cat "$UPDATE_LOG" | tail -n 30 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g;')
            send_message_html "❌ <b>Возникли ошибки при обновлении системы:</b>

<pre>$UPGRADE_LOG_CONTENT</pre>"
          fi
          
          # Удаляем временные файлы
          rm -f "$UPDATE_LOG" "$UPDATE_FLAG_FILE"
        } &
        ;;
      /reboot)
        send_message_html "⚠️ <b>Подтвердите перезагрузку:</b> /confirm_reboot"
        ;;
      /confirm_reboot)
        send_message_html "♻️ <b>Перезагружаем сервер...</b>"
        sudo reboot
        ;;
      /help)
        HELP_MESSAGE="<b>📚 Доступные команды:</b>

/start - Основное меню
/security - Проверка безопасности
/uptime - Время работы системы
/disk - Использование диска
/mem - Использование памяти
/top - Загрузка системы
/ip - Информация об IP
/who - Кто в системе
/update - Обновление системы
/checklist - Показать чек-лист
/add_checklist [текст] - Добавить пункт в чек-лист
/clear_checklist - Очистить чек-лист
/botlog - Показать логи бота
/clearlogs - Очистить логи
/restart_bot - Перезапустить бота
/reboot - Перезагрузить сервер
/help - Это сообщение"

        send_message_html "$HELP_MESSAGE"
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