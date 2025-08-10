#!/bin/bash
# Server setup & security + Telegram bot installer
# Safe for both: direct execution (./install_user.sh) and pipe (curl ... | bash)

set -e

# =========================
# 0. Предварительная проверка
# =========================
for cmd in jq curl awk sudo; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Ошибка: $cmd не установлен. Установите его перед запуском."
    exit 1
  fi
done

# =========================#!/usr/bin/env bash
# Этап 2 (под новым пользователем): безопасность, сервисы, бот, мониторинг.
# Идемпотентные шаги с STATE каталогом.
set -euo pipefail
IFS=$'\n\t'

STATE_DIR="$HOME/.local/share/server_setup_state"
LOG_DIR="$HOME/.local/share/telegram_bot/logs"
CACHE_DIR="$HOME/.local/share/telegram_bot/cache"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$CACHE_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

CONFIG_FILE="/usr/local/bin/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="/etc/server_setup/config.json"
[[ -f "$CONFIG_FILE" ]] || { log "❌ config.json не найден"; exit 1; }

# Чтение конфига
PUBKEY=$(jq -r '.public_key_content' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")
SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root // "true"' "$CONFIG_FILE")
SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth // "false"' "$CONFIG_FILE")
SUDO_NOPASSWD=$(jq -r '.sudo_nopasswd // "false"' "$CONFIG_FILE")
MONITORING_ENABLED=$(jq -r '.monitoring_enabled // "false"' "$CONFIG_FILE")
BOT_TOKEN=$(jq -r '.telegram_bot_token // empty' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id // empty' "$CONFIG_FILE")
ENABLE_AUTO_IDS_REGEX=$(jq -r '.psad_auto_ids_regex // "N"' "$CONFIG_FILE")

# Функция "уже выполнено?"
done_flag() {
  [[ -f "$STATE_DIR/$1.done" ]]
}
mark_done() {
  touch "$STATE_DIR/$1.done"
}

require_cmds() {
  local missing=()
  for c in jq curl awk sudo sed systemctl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    log "❌ Отсутствуют команды: ${missing[*]}"
    exit 1
  fi
}

setup_ssh_and_user() {
  done_flag "01.ssh_user" && { log "⏩ SSH/User уже настроены"; return; }
  log "🔧 Настройка SSH и authorized_keys"
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  if ! grep -qF "$PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "$PUBKEY" >> ~/.ssh/authorized_keys
  fi
  chmod 600 ~/.ssh/authorized_keys

  sudo sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
  if [[ "$SSH_DISABLE_ROOT" == "true" ]]; then
    sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
  fi
  if [[ "$SSH_PASSWORD_AUTH" == "false" ]]; then
    sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
  fi
  sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh || true
  mark_done "01.ssh_user"
  log "✅ SSH/User настройка завершена"
}

setup_sudo_nopasswd_if_needed() {
  done_flag "02.sudo_adjust" && { log "⏩ sudo уже обработан"; return; }
  if [[ "$SUDO_NOPASSWD" == "true" ]]; then
    log "🛡 Проверка sudo NOPASSWD (устанавливается на root-этапе, здесь только верификация)"
    if ! sudo -n true 2>/dev/null; then
      echo "$(whoami) ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/91-$(whoami)" >/dev/null
      sudo chmod 440 "/etc/sudoers.d/91-$(whoami)"
    fi
  fi
  mark_done "02.sudo_adjust"
}

install_security_packages() {
  done_flag "03.security_pkgs" && { log "⏩ security packages уже"; return; }
  log "🛡 Установка ufw, fail2ban, rkhunter, nmap по config.json"
  for svc in ufw fail2ban rkhunter nmap; do
    if [[ "$(jq -r ".services.$svc // \"false\"" "$CONFIG_FILE")" == "true" ]]; then
      sudo apt-get update -y
      sudo apt-get install -y "$svc"
      if systemctl list-unit-files | grep -q "^$svc.service"; then
        sudo systemctl enable --now "$svc" || true
      fi
      log "✔️ $svc установлен"
    else
      log "ℹ️ $svc выключен в config.json"
    fi
  done
  # psad отдельно
  if [[ "$(jq -r '.services.psad // "false"' "$CONFIG_FILE")" == "true" ]]; then
    sudo apt-get install -y psad
  fi
  mark_done "03.security_pkgs"
}

configure_psad() {
  done_flag "04.psad_cfg" && { log "⏩ psad уже настроен"; return; }
  if [[ "$(jq -r '.services.psad // "false"' "$CONFIG_FILE")" != "true" ]]; then
    log "ℹ️ psad выключен — пропуск"
    mark_done "04.psad_cfg"
    return
  fi
  log "🔧 Настройка psad"
  sudo sed -i 's/^ENABLE_AUTO_IDS.*/ENABLE_AUTO_IDS           Y;/' /etc/psad/psad.conf
  sudo grep -q '^ENABLE_AUTO_IDS' /etc/psad/psad.conf || echo "ENABLE_AUTO_IDS           Y;" | sudo tee -a /etc/psad/psad.conf >/dev/null
  sudo sed -i 's/^ENABLE_EMAIL_ALERTS.*/ENABLE_EMAIL_ALERTS        Y;/' /etc/psad/psad.conf
  sudo sed -i 's/^ALERT_ALL.*/ALERT_ALL                 Y;/' /etc/psad/psad.conf
  sudo sed -i 's/^ENABLE_DEBUG_OUTPUT.*/ENABLE_DEBUG_OUTPUT        Y;/' /etc/psad/psad.conf
  sudo sed -i 's/^ENABLE_AUTO_IDS_EMAILS.*/ENABLE_AUTO_IDS_EMAILS     Y;/' /etc/psad/psad.conf
  sudo sed -i "s/^HOSTNAME.*/HOSTNAME                    $(hostname);/" /etc/psad/psad.conf
  sudo sed -i "s/^EMAIL_ADDRESSES.*/EMAIL_ADDRESSES             root@localhost;/" /etc/psad/psad.conf
  if [[ "$ENABLE_AUTO_IDS_REGEX" != "N" ]]; then
    sudo sed -i "s|^ENABLE_AUTO_IDS_REGEX.*|ENABLE_AUTO_IDS_REGEX       $ENABLE_AUTO_IDS_REGEX;|" /etc/psad/psad.conf || true
  fi
  sudo touch /var/log/psad/alert
  sudo chmod 640 /var/log/psad/alert
  sudo psad -R && sudo psad -H && sudo psad --sig-update || true
  sudo systemctl restart psad || true
  mark_done "04.psad_cfg"
  log "✅ psad настроен"
}

configure_rkhunter() {
  done_flag "05.rkhunter_cfg" && { log "⏩ rkhunter уже настроен"; return; }
  if [[ "$(jq -r '.services.rkhunter // "false"' "$CONFIG_FILE")" != "true" ]]; then
    log "ℹ️ rkhunter выключен"
    mark_done "05.rkhunter_cfg"
    return
  fi
  log "🔧 Настройка rkhunter"
  local conf="/etc/rkhunter.conf"
  sudo sed -i 's|^WEB_CMD=.*|WEB_CMD=/usr/bin/wget|' "$conf" || true
  sudo sed -i 's/^UPDATE_MIRRORS=.*/UPDATE_MIRRORS=0/' "$conf" || true
  sudo sed -i 's/^MIRRORS_MODE=.*/MIRRORS_MODE=0/' "$conf" || true
  if ! grep -q '^MIRROR_SITE=' "$conf"; then
    echo "MIRROR_SITE=http://rkhunter.sourceforge.net" | sudo tee -a "$conf" >/dev/null
  else
    sudo sed -i 's|^MIRROR_SITE=.*|MIRROR_SITE=http://rkhunter.sourceforge.net|' "$conf"
  fi
  sudo rkhunter --update || true
  # propupd вызывать только первый раз (при чистой системе)
  if [[ ! -f "$STATE_DIR/.rkhunter.initial_propupd" ]]; then
    sudo rkhunter --propupd -q || true
    touch "$STATE_DIR/.rkhunter.initial_propupd"
  fi

  # Systemd unit + timer (более корректно, чем permanent service)
  sudo tee /etc/systemd/system/rkhunter-check.service >/dev/null <<'EOF'
[Unit]
Description=RKHunter Scan

[Service]
Type=oneshot
ExecStart=/usr/bin/rkhunter --check --cronjob --rwo
EOF

  sudo tee /etc/systemd/system/rkhunter-check.timer >/dev/null <<'EOF'
[Unit]
Description=Daily RKHunter Scan

[Timer]
OnCalendar=03:15
Persistent=true

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now rkhunter-check.timer
  mark_done "05.rkhunter_cfg"
  log "✅ rkhunter настроен (timer)"
}

install_docker_portainer() {
  done_flag "06.docker_portainer" && { log "⏩ Docker/Portainer уже"; return; }
  if ! command -v docker >/dev/null 2>&1; then
    log "🐳 Установка Docker"
    sudo apt-get update -y
    sudo apt-get install -y docker.io
    sudo systemctl enable --now docker
  else
    log "🐳 Docker уже установлен"
  fi
  if command -v docker >/dev/null 2>&1; then
    if ! sudo docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
      log "📦 Установка Portainer контейнера"
      sudo docker volume create portainer_data >/dev/null || true
      sudo docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data \
        portainer/portainer-ce:lts || log "⚠️ Не удалось запустить Portainer"
    fi
  fi
  mark_done "06.docker_portainer"
}

install_netdata() {
  done_flag "07.netdata" && { log "⏩ Netdata уже"; return; }
  if [[ "$MONITORING_ENABLED" != "true" ]]; then
    log "ℹ️ Мониторинг отключён"
    mark_done "07.netdata"
    return
  fi
  if sudo docker ps -a --format '{{.Names}}' | grep -q '^netdata$'; then
    log "📊 Контейнер Netdata уже существует"
  else
    log "📊 Запуск Netdata (docker)"
    sudo docker run -d --name=netdata \
      --hostname="$(hostname)" \
      --pid=host --network=host \
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
      netdata/netdata || log "⚠️ Не удалось запустить Netdata"
  fi
  mark_done "07.netdata"
}

setup_telegram_bot() {
  done_flag "08.telegram_bot" && { log "⏩ Бот уже настроен"; return; }
  if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    log "ℹ️ BOT_TOKEN или CHAT_ID пусты — бот пропущен"
    mark_done "08.telegram_bot"
    return
  fi
  log "🤖 Установка Telegram бота"
  local BOT_SCRIPT="/usr/local/bin/telegram_command_listener.sh"

  sudo tee "$BOT_SCRIPT" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
HOME_DIR="$(getent passwd "$(whoami)" | cut -d: -f6)"
export HOME="\$HOME_DIR"
TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LOG_FILE="\$HOME/.local/share/telegram_bot/logs/bot_debug.log"
CACHE_DIR="\$HOME/.local/share/telegram_bot/cache"
mkdir -p "\$(dirname "\$LOG_FILE")" "\$CACHE_DIR"

OFFSET_FILE="\$CACHE_DIR/offset"
PROCESSED_FILE="\$CACHE_DIR/processed_ids"
LAST_COMMAND_FILE="\$CACHE_DIR/last_command"

touch "\$PROCESSED_FILE"

get_updates() {
  curl -s "https://api.telegram.org/bot\$TOKEN/getUpdates?timeout=30&offset=\$(cat "\$OFFSET_FILE" 2>/dev/null || echo 0)"
}

send_html() {
  local txt="\$1"
  curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
    --data-urlencode chat_id="\$CHAT_ID" \
    --data-urlencode parse_mode="HTML" \
    --data-urlencode text="\$txt" >/dev/null
}

escape_html() {
  sed 's/&/\\&/g; s/</\\</g; s/>/\\>/g'
}

rate_limit() {
  local now=\$(date +%s)
  local last=\$(cat "\$LAST_COMMAND_FILE" 2>/dev/null || echo 0)
  local diff=\$((now-last))
  if (( diff < 2 )); then
    return 1
  fi
  echo "\$now" > "\$LAST_COMMAND_FILE"
  return 0
}

while true; do
  RESP=\$(get_updates)
  RESULT_LEN=\$(echo "\$RESP" | jq '.result | length')
  if (( RESULT_LEN == 0 )); then
    sleep 2
    continue
  fi

  for ((i=0; i<RESULT_LEN; i++)); do
    UPD=\$(echo "\$RESP" | jq -c ".result[\$i]")
    ID=\$(echo "\$UPD" | jq '.update_id')
    echo "\$ID" > "\$OFFSET_FILE"
    MSG=\$(echo "\$UPD" | jq -r '.message.text // .callback_query.data // empty')
    [[ -z "\$MSG" ]] && continue
    rate_limit || continue

    case "\$MSG" in
      /start)
        send_html "<b>Команды:</b> /uptime /disk /mem /top /ip /who /security /update /reboot /botlog /help"
        ;;
      /uptime) send_html "<pre>\$(uptime | escape_html)</pre>" ;;
      /disk) send_html "<pre>\$(df -h / | tail -n1 | escape_html)</pre>" ;;
      /mem) send_html "<pre>\$(free -h | escape_html)</pre>" ;;
      /top) send_html "<pre>\$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 10 | escape_html)</pre>" ;;
      /ip)
        IP_EXT=\$(curl -s ifconfig.me || echo "N/A")
        IP_INT=\$(hostname -I | awk '{print \$1}')
        GEO=\$(curl -s "http://ip-api.com/json/\$IP_EXT" | jq -r '.country + ", " + .city + " (" + (.isp // "n/a") + ")"' 2>/dev/null || echo "n/a")
        send_html "<b>Внутренний:</b> <code>\$IP_INT</code>\n<b>Внешний:</b> <code>\$IP_EXT</code>\n<b>Гео:</b> \$GEO"
        ;;
      /who)
        W=\$(who)
        if [[ -z "\$W" ]]; then send_html "<i>Нет активных пользователей</i>"; else
          send_html "<pre>\$(echo "\$W" | escape_html)</pre>"
        fi
        ;;
      /botlog)
        DATA=\$(tail -n 40 "\$LOG_FILE" 2>/dev/null | escape_html)
        send_html "<b>Логи:</b>\n<pre>\$DATA</pre>"
        ;;
      /reboot)
        send_html "Подтвердите: /confirm_reboot"
        ;;
      /confirm_reboot)
        send_html "Перезагрузка..."
        sudo reboot
        ;;
      /update)
        send_html "Подтвердите обновление: /confirm_update"
        ;;
      /confirm_update)
        send_html "Обновление..."
        (sudo apt-get update -y && sudo apt-get upgrade -y && send_html "✅ Обновлено" || send_html "⚠️ Ошибка apt") &
        ;;
      /security)
        RKH=""
        if command -v rkhunter >/dev/null 2>&1; then
          RKH=\$(timeout 45s sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null | tail -n 50 | escape_html || true)
        fi
        PS=\$(sudo psad -S 2>/dev/null | head -n 40 | escape_html || true)
        send_html "<b>RKHunter:</b>\n<pre>\$RKH</pre>\n<b>PSAD:</b>\n<pre>\$PS</pre>"
        ;;
      /help)
        send_html "<pre>/start /uptime /disk /mem /top /ip /who /security /update /reboot /botlog /help</pre>"
        ;;
      *) send_html "Неизвестно. /help";;
    esac
  done
done
EOF

  sudo chmod +x "$BOT_SCRIPT"

  sudo tee /etc/systemd/system/telegram_command_listener.service >/dev/null <<EOF
[Unit]
Description=Telegram Command Listener
After=network.target

[Service]
User=$(whoami)
ExecStart=$BOT_SCRIPT
Restart=always
RestartSec=5
WorkingDirectory=$HOME
StandardOutput=append:$LOG_DIR/service.out
StandardError=append:$LOG_DIR/service.err
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now telegram_command_listener.service
  mark_done "08.telegram_bot"
  log "✅ Бот установлен"
}

setup_ssh_login_notify() {
  done_flag "09.ssh_notify" && { log "⏩ SSH notify уже"; return; }
  if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    log "ℹ️ Пропуск SSH notify (нет токена)"
    mark_done "09.ssh_notify"
    return
  fi
  local SCRIPT="/usr/local/bin/telegram_ssh_notify.sh"
  sudo tee "$SCRIPT" >/dev/null <<EOF
#!/usr/bin/env bash
[[ "\$PAM_TYPE" != "open_session" ]] && exit 0
[[ -z "\$PAM_USER" || "\$PAM_USER" == "sshd" ]] && exit 0
TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
USER="\$PAM_USER"
IP=\$(echo \$SSH_CONNECTION | awk '{print \$1}')
CACHE_FILE="/tmp/ssh_notify_\${USER}_\${IP}"
NOW=\$(date +%s)
if [[ -f "\$CACHE_FILE" ]]; then
  LAST=\$(cat "\$CACHE_FILE")
  (( NOW - LAST < 10 )) && exit 0
fi
echo "\$NOW" > "\$CACHE_FILE"
GEO=\$(curl -m 3 -s ipinfo.io/\$IP | jq -r '.city + ", " + .region + ", " + .country + " (" + (.org // "n/a") + ")"' 2>/dev/null || echo "n/a")
TEXT="🔐 SSH вход: *\$USER*
📡 IP: \$IP
🌍 Гео: \$GEO
🕒 \$(date '+%F %T')"
curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" --data-urlencode text="\$TEXT" >/dev/null
EOF
  sudo chmod +x "$SCRIPT"
  if ! grep -q "telegram_ssh_notify.sh" /etc/pam.d/sshd; then
    echo "session optional pam_exec.so $SCRIPT" | sudo tee -a /etc/pam.d/sshd >/dev/null
  fi
  mark_done "09.ssh_notify"
  log "✅ SSH notify настроен"
}

setup_firewall_logging() {
  done_flag "10.iptables_log" && { log "⏩ iptables log уже"; return; }
  log "🧱 Настройка iptables LOG с лимитом"
  # Проверка на существование правила (используем -C)
  if ! sudo iptables -C INPUT -j LOG --log-prefix "IPT-IN: " 2>/dev/null; then
    sudo iptables -I INPUT -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "IPT-IN: "
  fi
  if ! sudo iptables -C FORWARD -j LOG --log-prefix "IPT-FWD: " 2>/dev/null; then
    sudo iptables -I FORWARD -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "IPT-FWD: "
  fi
  mark_done "10.iptables_log"
  log "✅ iptables LOG настроен"
}

add_rkhunter_sudoers() {
  done_flag "11.rkhunter_sudo" && { log "⏩ sudo rkhunter уже"; return; }
  if [[ "$(jq -r '.services.rkhunter // "false"' "$CONFIG_FILE")" == "true" ]]; then
    if ! sudo grep -q "/usr/bin/rkhunter" /etc/sudoers; then
      echo "$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/rkhunter" | sudo tee /etc/sudoers.d/92-rkhunter >/dev/null
      sudo chmod 440 /etc/sudoers.d/92-rkhunter
    fi
  fi
  mark_done "11.rkhunter_sudo"
  log "✅ sudoers для rkhunter"
}

final_checklist() {
  done_flag "12.checklist" && { log "⏩ Чеклист уже отправлен (повтор можно вручную удалить флаг)"; return; }
  log "📬 Генерация финального чеклиста"
  local TMP="/tmp/install_checklist.txt"
  {
    echo "Чеклист установки:"
    echo "Пользователь: $(whoami)"
    echo "SSH порт: $PORT"
    echo "Службы:"
    for S in ufw fail2ban psad rkhunter; do
      sudo systemctl is-active --quiet "$S" 2>/dev/null && echo "  [+] $S" || echo "  [ ] $S"
    done
    if command -v docker >/dev/null 2>&1; then
      echo "Docker: установлен"
      sudo docker ps -q -f name=portainer >/dev/null 2>&1 && \
        echo "Portainer: https://$(hostname -I | awk '{print $1}'):9443" || echo "Portainer: не запущен"
    else
      echo "Docker: не установлен"
    fi
    if [[ "$MONITORING_ENABLED" == "true" ]]; then
      if sudo docker ps -q -f name=netdata >/dev/null 2>&1; then
        echo "Netdata: http://$(hostname -I | awk '{print $1}'):19999 (Docker)"
      else
        echo "Netdata: ошибка/не запущена"
      fi
    else
      echo "Netdata: отключена"
    fi
    if [[ "$(jq -r '.services.psad // "false"' "$CONFIG_FILE")" == "true" ]]; then
      if [[ -f /var/log/psad/alert ]]; then
        echo "PSAD alert tail:"
        sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true
      fi
    fi
  } > "$TMP"

  cat "$TMP"
  if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
    esc=$(sed 's/`/\\`/g' "$TMP")
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
      -d chat_id="$CHAT_ID" -d parse_mode="Markdown" \
      --data-urlencode text="\`\`\`$esc\`\`\`" >/dev/null || true
  fi
  rm -f "$TMP"
  mark_done "12.checklist"
  log "✅ Чеклист готов"
}

setup_cron_jobs() {
  done_flag "13.cron_jobs" && { log "⏩ cron уже"; return; }
  log "🕒 Настройка cron задач"
  # security check
  sudo tee /usr/local/bin/cron_security_check.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -e
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
send() {
  [[ -z "\$BOT_TOKEN" || -z "\$CHAT_ID" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \
    -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" --data-urlencode text="\$1" >/dev/null
}
R=\$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [[ -n "\$R" ]]; then send "⚠️ *RKHunter предупреждения:*\n\`\`\`\n\$R\n\`\`\`"; else send "✅ *RKHunter*: чисто"; fi
if [[ -f /var/log/psad/alert ]]; then
  P=\$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
  if echo "\$P" | grep -q "Danger level"; then send "🚨 *PSAD:*\n\`\`\`\n\$P\n\`\`\`"; else send "✅ *PSAD*: спокойно"; fi
fi
EOF
  sudo chmod +x /usr/local/bin/cron_security_check.sh
  echo "0 7 * * * root /usr/local/bin/cron_security_check.sh" | sudo tee /etc/cron.d/cron-security-check >/dev/null

  # weekly log clear
  sudo tee /usr/local/bin/cron_clear_security_log.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
echo "$(date '+%F %T') | Очистка security логов" > /var/log/security_monitor.log
EOF
  sudo chmod +x /usr/local/bin/cron_clear_security_log.sh
  echo "0 6 * * 1 root /usr/local/bin/cron_clear_security_log.sh" | sudo tee /etc/cron.d/cron-clear-security-log >/dev/null

  # weekly update
  sudo tee /usr/local/bin/cron_weekly_update.sh >/dev/null <<EOF
#!/usr/bin/env bash
LOG_FILE="/var/log/weekly_update.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
{
  echo "==== \$(date '+%F %T') START WEEKLY UPDATE ===="
  apt-get update
  apt-get -y upgrade
  apt-get -y autoremove
  apt-get -y autoclean
  echo "==== \$(date '+%F %T') END ===="
} >> "\$LOG_FILE" 2>&1
if [[ -n "\$BOT_TOKEN" && -n "\$CHAT_ID" ]]; then
  TAIL=\$(tail -n 40 "\$LOG_FILE")
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" --data-urlencode text="🧰 *Weekly update:*\n\`\`\`\n\$TAIL\n\`\`\`" >/dev/null
fi
EOF
  sudo chmod +x /usr/local/bin/cron_weekly_update.sh
  echo "30 5 * * 1 root /usr/local/bin/cron_weekly_update.sh" | sudo tee /etc/cron.d/cron-weekly-update >/dev/null

  mark_done "13.cron_jobs"
  log "✅ Cron задачи настроены"
}

main() {
  require_cmds
  setup_ssh_and_user
  setup_sudo_nopasswd_if_needed
  install_security_packages
  configure_psad
  configure_rkhunter
  install_docker_portainer
  install_netdata
  setup_telegram_bot
  setup_ssh_login_notify
  setup_firewall_logging
  add_rkhunter_sudoers
  final_checklist
  setup_cron_jobs
  log "🎉 Этап user завершён"
}

main "$@"
# 1. Запрос на удаление старых скриптов (безопасно при pipe)
# =========================
if [[ -t 0 ]]; then
  read -p "🔍 Найти и удалить старые версии Telegram-бота и cron-скриптов? [y/N]: " DEL_OLD
else
  DEL_OLD="y"
  echo "ℹ️ Нетерминальный ввод (pipe). Автоматически выбран ответ: y"
fi

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
# ИСПРАВЛЕНО: раньше было Igrom4ek → заменено на правильный ник Igrom4ik
CONFIG_URL="https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/config.json"

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
ENABLE_AUTO_IDS_REGEX=$(jq -r '.psad_auto_ids_regex // "N"' "$CONFIG_FILE")

USERNAME=$(whoami)
USER_HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1"
}

# =========================
# 2. Настройка SSH / пользователя
# =========================
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
sudo service ssh restart || sudo systemctl restart ssh || true

log "🔓 Настройка sudo без пароля (если предусмотрено)"
if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/90-$USERNAME" > /dev/null
  sudo chmod 440 "/etc/sudoers.d/90-$USERNAME"
fi

log "✅ Настройка пользователя завершена. Переходим к настройке безопасности и бота"

# =========================
# 3. Установка сервисов безопасности
# =========================
log "🛡 Установка и настройка системной защиты"
for SERVICE in ufw fail2ban rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    sudo apt update -y
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

# PSAD
if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  log "📦 Установка psad"
  sudo apt install -y psad
fi

if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  log "📦 Настройка psad"
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
  sudo sed -i "s/^ENABLE_AUTO_IDS_REGEX.*/ENABLE_AUTO_IDS_REGEX       $ENABLE_AUTO_IDS_REGEX;/g" /etc/psad/psad.conf || true
  sudo grep -q '^ENABLE_AUTO_IDS_REGEX' /etc/psad/psad.conf || echo "ENABLE_AUTO_IDS_REGEX       $ENABLE_AUTO_IDS_REGEX;" | sudo tee -a /etc/psad/psad.conf > /dev/null
  sudo sed -i "s/^HOSTNAME.*/HOSTNAME                    $(hostname);/g" /etc/psad/psad.conf
  sudo grep -q '^HOSTNAME' /etc/psad/psad.conf || echo "HOSTNAME                    $(hostname);" | sudo tee -a /etc/psad/psad.conf > /dev/null
  sudo sed -i "s/^EMAIL_ADDRESSES.*/EMAIL_ADDRESSES             root@localhost;/g" /etc/psad/psad.conf
  sudo grep -q '^EMAIL_ADDRESSES' /etc/psad/psad.conf || echo "EMAIL_ADDRESSES             root@localhost;" | sudo tee -a /etc/psad/psad.conf > /dev/null

  sudo touch /var/log/psad/alert
  sudo chmod 640 /var/log/psad/alert
  sudo chown root:root /var/log/psad/alert

  sudo pkill -f /usr/sbin/psad || true
  sudo psad -R && sudo psad -H && sudo psad --sig-update
  sudo systemctl restart psad
  log "✅ psad успешно настроен"
else
  log "ℹ️ psad отключён в config.json — настройка пропущена"
fi

# =========================
# 4. Настройка rkhunter
# =========================
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

# =========================
# 5. Docker + Portainer
# =========================
log "🐳 Проверка Docker и Portainer"
if ! command -v docker &> /dev/null; then
  log "Docker не найден, выполняется установка..."
  sudo apt update -y
  sudo apt install -y docker.io || log "⚠️ Не удалось установить Docker"
  sudo systemctl enable --now docker && log "Docker запущен"
else
  log "Docker уже установлен"
fi

if command -v docker &> /dev/null; then
  if ! sudo docker container inspect portainer &> /dev/null; then
    log "Portainer не установлен, установка..."
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

# =========================
# 6. Netdata (Docker)
# =========================
if [[ "$MONITORING_ENABLED" == "true" ]]; then
  log "📊 Установка системы мониторинга Netdata"
  if command -v netdata &> /dev/null; then
    log "Netdata уже установлена в системе"
  elif ! sudo docker container inspect netdata &> /dev/null; then
    log "Запуск Netdata в Docker..."
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
      netdata/netdata || log "⚠️ Не удалось запустить Netdata"
  else
    log "Контейнер Netdata уже существует"
  fi
else
  log "Мониторинг Netdata отключён в config.json"
fi

# =========================
# 7. Telegram Bot
# =========================
log "🤖 Установка и настройка Telegram-бота"
sudo tee /usr/local/bin/telegram_command_listener.sh > /dev/null <<EOF
#!/bin/bash
USER_HOME=\$(getent passwd "\$(whoami)" | cut -d: -f6)
export HOME="\$USER_HOME"
TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"
LOG_FILE="\$HOME/.local/share/telegram_bot/logs/bot_debug.log"
OFFSET_FILE="\$HOME/.local/share/telegram_bot/cache/offset"
LAST_COMMAND_FILE="\$HOME/.local/share/telegram_bot/cache/last_command"
REBOOT_FLAG_FILE="\$HOME/.local/share/telegram_bot/cache/confirm_reboot"
CHECKLIST_FILE="\$HOME/.local/share/telegram_bot/cache/checklist"
UPDATE_FLAG_FILE="\$HOME/.local/share/telegram_bot/cache/confirm_update"

mkdir -p "\$HOME/.local/share/telegram_bot/logs"
mkdir -p "\$HOME/.local/share/telegram_bot/cache"
touch "\$OFFSET_FILE.processed"

if [[ ! -f "\$CHECKLIST_FILE" ]]; then
  echo -e "✅ Сервер активен.\n🔐 Защита работает.\n📡 Мониторинг включен." > "\$CHECKLIST_FILE"
fi

exec >>"\$LOG_FILE" 2>&1
set -x

OFFSET=\$(cat "\$OFFSET_FILE" 2>/dev/null || echo 0)

send_message_html() {
  local text="\$1"
  [[ -z "\$text" ]] && return
  curl -s -X POST "https://api.telegram.org/bot\${TOKEN}/sendMessage" \
    --data-urlencode chat_id="\${CHAT_ID}" \
    --data-urlencode parse_mode="HTML" \
    --data-urlencode text="\$text" > /dev/null
}

send_message() {
  local text="\$1"
  [[ -z "\$text" ]] && return
  curl -s -X POST "https://api.telegram.org/bot\${TOKEN}/sendMessage" \
    --data-urlencode chat_id="\${CHAT_ID}" \
    --data-urlencode parse_mode="Markdown" \
    --data-urlencode text="\$text" > /dev/null
}

get_updates() {
  curl -s "https://api.telegram.org/bot\$TOKEN/getUpdates?offset=\$OFFSET"
}

escape_html() {
  echo "\$1" | sed 's/&/\\\&/g; s/</\\</g; s/>/\\>/g; s/"/\\"/g'
}

while true; do
  RESPONSE=\$(get_updates)
  UPDATES=\$(echo "\$RESPONSE" | jq -c '.result')
  LENGTH=\$(echo "\$UPDATES" | jq 'length')
  [[ "\$LENGTH" -eq 0 ]] && sleep 2 && continue

  for ((i = 0; i < LENGTH; i++)); do
    UPDATE=\$(echo "\$UPDATES" | jq -c ".[\$i]")
    UPDATE_ID=\$(echo "\$UPDATE" | jq '.update_id')

    if grep -q "\$UPDATE_ID" "\$OFFSET_FILE.processed" 2>/dev/null; then
      continue
    fi

    echo "\$UPDATE_ID" >> "\$OFFSET_FILE.processed"
    OFFSET=\$((\$UPDATE_ID + 1))
    echo "\$OFFSET" > "\$OFFSET_FILE"

    CALLBACK_DATA=\$(echo "\$UPDATE" | jq -r '.callback_query.data // empty')
    if [[ -n "\$CALLBACK_DATA" && "\$CALLBACK_DATA" != "null" ]]; then
      MESSAGE="/\$CALLBACK_DATA"
      CALLBACK_QUERY_ID=\$(echo "\$UPDATE" | jq -r '.callback_query.id')
      curl -s -X POST "https://api.telegram.org/bot\${TOKEN}/answerCallbackQuery" \
        -d callback_query_id="\$CALLBACK_QUERY_ID" > /dev/null
    else
      MESSAGE=\$(echo "\$UPDATE" | jq -r '.message.text // empty')
    fi

    [[ -z "\$MESSAGE" ]] && continue

    NOW=\$(date +%s)
    LAST_CMD=\$(cat "\$LAST_COMMAND_FILE" 2>/dev/null || echo "0")
    DIFF=\$((\$NOW - \$LAST_CMD))
    [[ "\$DIFF" -lt 2 ]] && continue
    echo "\$NOW" > "\$LAST_COMMAND_FILE"

    case "\$MESSAGE" in
      /start)
        curl -s -X POST "https://api.telegram.org/bot\${TOKEN}/sendMessage" \
          -H "Content-Type: application/json" \
          -d '{
            "chat_id": "'${CHAT_ID}'",
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
      /uptime) send_message_html "<pre>\$(escape_html "\$(uptime)")</pre>" ;;
      /disk)   send_message_html "<pre>\$(escape_html "\$(df -h / | tail -n 1)")</pre>" ;;
      /mem)    send_message_html "<pre>\$(escape_html "\$(free -h)")</pre>" ;;
      /top)    send_message_html "<pre>\$(escape_html "\$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 10)")</pre>" ;;
      /ip)
        IP_EXTERNAL=\$(curl -s ifconfig.me)
        IP_INTERNAL=\$(hostname -I | awk '{print \$1}')
        GEO_INFO=\$(curl -s "http://ip-api.com/json/\$IP_EXTERNAL")
        COUNTRY=\$(echo "\$GEO_INFO" | jq -r '.country // "Неизвестно"')
        CITY=\$(echo "\$GEO_INFO" | jq -r '.city // "Неизвестно"')
        ISP=\$(echo "\$GEO_INFO" | jq -r '.isp // "Неизвестно"')
        send_message_html "<b>🌐 Информация об IP-адресах</b>

<b>🏠 Внутренний IP:</b> <code>\$IP_INTERNAL</code>
<b>🌍 Внешний IP:</b> <code>\$IP_EXTERNAL</code>

<b>📍 Геолокация:</b>
  <b>Страна:</b> \$COUNTRY
  <b>Город:</b> \$CITY
  <b>Провайдер:</b> \$ISP"
        ;;
      /who)
        WHO_OUTPUT=\$(who)
        if [[ -z "\$WHO_OUTPUT" ]]; then
          send_message_html "<b>👤 Пользователи в системе</b>

<i>В настоящее время нет активных пользователей</i>"
        else
          WHO_MESSAGE="<b>👤 Пользователи в системе</b>"
          while IFS= read -r line; do
            USER=\$(echo "\$line" | awk '{print \$1}')
            TTY=\$(echo "\$line" | awk '{print \$2}')
            FROM=\$(echo "\$line" | awk '{print \$5}' | tr -d '()')
            TIME=\$(echo "\$line" | awk '{print \$3, \$4}')
            [[ -z "\$FROM" || "\$FROM" == "*" ]] && FROM="локальный вход"
            WHO_MESSAGE+="

<b>👤 \$USER</b>
   📱 Терминал: <code>\$TTY</code>
   🖥️ Подключен с: <code>\$FROM</code>
   🕒 Время входа: <code>\$TIME</code>"
          done <<< "\$WHO_OUTPUT"
          send_message_html "\$WHO_MESSAGE"
        fi
        ;;
      /botlog)
        LOG_DATA=\$(tail -n 20 "\$LOG_FILE" | grep -v "get_updates" | head -c 4000)
        [[ -z "\$LOG_DATA" ]] && send_message_html "<b>📝 Логи Telegram-бота</b>\n\n<i>Файл логов пуст</i>" && continue
        LOG_ESCAPED=\$(escape_html "\$LOG_DATA")
        send_message_html "<b>📝 Логи Telegram-бота</b>\n<pre>\$LOG_ESCAPED</pre>\n<b>🤖 Бот активен</b>"
        ;;
      /checklist)
        if [[ -f "\$CHECKLIST_FILE" && -s "\$CHECKLIST_FILE" ]]; then
          CHECKLIST_CONTENT=\$(cat "\$CHECKLIST_FILE")
          send_message_html "<b>📝 Чек-лист сервера</b>\n<pre>\$CHECKLIST_CONTENT</pre>\n<i>/add_checklist для добавления</i>"
        else
          send_message_html "<b>📝 Чек-лист сервера</b>\n<i>Чек-лист пуст</i>"
        fi
        ;;
      /clearlogs)
        > "\$LOG_FILE"
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
        touch "\$UPDATE_FLAG_FILE"
        send_message_html "🔄 <b>Начинаем обновление системы...</b>"
        {
          sudo apt update -y && sudo apt upgrade -y
          send_message_html "✅ <b>Система успешно обновлена</b>"
          [[ -f /var/run/reboot-required ]] && send_message_html "⚠️ <b>Требуется перезагрузка</b>"
          rm -f "\$UPDATE_FLAG_FILE"
        } &
        ;;
      /security)
        send_message_html "<b>⏳ Проверка безопасности...</b>"
        RKHUNTER_OUTPUT=\$(timeout 60s sudo rkhunter --check --sk --nocolors --rwo 2>&1)
        PSAD_OUTPUT=\$(sudo psad -S 2>/dev/null)
        send_message_html "<b>RKHunter:</b>\n<pre>\$(escape_html "\$RKHUNTER_OUTPUT" | tail -n 80)</pre>"
        send_message_html "<b>PSAD:</b>\n<pre>\$(escape_html "\$PSAD_OUTPUT" | head -n 50)</pre>"
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

# =========================
# 8. SSH login notification
# =========================
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

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
  -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$TEXT" > /dev/null
EOF

sudo chmod +x /usr/local/bin/telegram_ssh_notify.sh
if ! grep -q "telegram_ssh_notify.sh" /etc/pam.d/sshd; then
  echo "session optional pam_exec.so /usr/local/bin/telegram_ssh_notify.sh" | sudo tee -a /etc/pam.d/sshd > /dev/null
fi

# =========================
# 9. psad + iptables logging
# =========================
log "🧱 Настройка логирования psad и iptables"
sudo iptables -C INPUT -j LOG 2>/dev/null || sudo iptables -I INPUT -j LOG
sudo iptables -C FORWARD -j LOG 2>/dev/null || sudo iptables -I FORWARD -j LOG

if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  if [[ "$ENABLE_AUTO_IDS_REGEX" != "N" ]]; then
    log "🔧 Применение ENABLE_AUTO_IDS_REGEX из config.json"
    sudo sed -i "s|^ENABLE_AUTO_IDS_REGEX.*|ENABLE_AUTO_IDS_REGEX       $ENABLE_AUTO_IDS_REGEX;|" /etc/psad/psad.conf
    sudo psad -R && sudo psad -H
    log "✅ ENABLE_AUTO_IDS_REGEX установлен в $ENABLE_AUTO_IDS_REGEX"
  else
    log "ℹ️ ENABLE_AUTO_IDS_REGEX не задан, используется значение по умолчанию (N)"
  fi
fi

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

# =========================
# 10. sudoers для rkhunter
# =========================
log "🛡 Настройка sudo для rkhunter (без пароля для бота)"
if ! sudo grep -q "/usr/bin/rkhunter" /etc/sudoers; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/rkhunter" | sudo tee -a /etc/sudoers > /dev/null
  log "Добавлено правило sudoers для rkhunter"
else
  log "Правило sudoers для rkhunter уже существует — пропущено"
fi

# =========================
# 11. Финальный чек-лист
# =========================
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

# =========================
# 12. Cron задачи
# =========================
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

sudo chmod +x /usr/local/bin/cron_security_check.sh
echo "0 7 * * * root /usr/local/bin/cron_security_check.sh" | sudo tee /etc/cron.d/cron-security-check > /dev/null

sudo tee /usr/local/bin/cron_clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Очистка лога безопасности (еженедельно)" > "\$LOG_FILE"
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
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
         -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" \
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

log "✅ Установка завершена"
echo "🎉 Все задачи завершены."

# =========================
# 13. Итоговая верификация паролей и SSH (лог)
# =========================
{
  echo ""
  echo "🔎 Верификация (user stage)"
  ME_USER="$(whoami)"
  USR_STATUS=$(passwd -S "$ME_USER" 2>/dev/null || true)
  ROOT_STATUS=$(sudo passwd -S root 2>/dev/null || true)
  echo "👤 passwd -S $ME_USER => $USR_STATUS"
  echo "👑 passwd -S root    => $ROOT_STATUS"
  USR_HASH=$(sudo grep "^$ME_USER:" /etc/shadow 2>/dev/null | cut -d: -f2)
  ROOT_HASH=$(sudo grep '^root:' /etc/shadow 2>/dev/null | cut -d: -f2)
  echo "🔑 hash $ME_USER: ${USR_HASH:-<none>}"
  echo "🔑 hash root: ${ROOT_HASH:-<none>}"
  [[ "$USR_HASH" == '!'* || "$USR_HASH" == '*'* || -z "$USR_HASH" ]] && echo "ℹ️ Пользовательский пароль отключён/заблокирован"
  # Проверка sshd_config
  SSH_CFG=/etc/ssh/sshd_config
  if sudo test -f "$SSH_CFG"; then
    PA_LINE=$(sudo grep -E '^PasswordAuthentication' "$SSH_CFG" | tail -n1 || true)
    PRL_LINE=$(sudo grep -E '^PermitRootLogin' "$SSH_CFG" | tail -n1 || true)
    PORTS=$(sudo grep -E '^Port[[:space:]]+' "$SSH_CFG" | awk '{print $2}' | sort -u | xargs)
    echo "⚙️  sshd: ${PA_LINE:-PasswordAuthentication ?} | ${PRL_LINE:-PermitRootLogin ?}"
    echo "🗂 Порты sshd_config: ${PORTS:-none}"
  fi
  # Фактические слушающие порты 22 и основной (если известен)
  if command -v ss >/dev/null 2>&1; then
    LISTEN=$(ss -tln 2>/dev/null | awk 'NR>1{print $4}' | sed -n 's/.*:\([0-9]\+\)$/\1/p' | sort -u | xargs)
    echo "📡 Слушающие TCP порты: ${LISTEN:-none}"
  fi
} | tee -a "$LOG_DIR/verification.log" >/dev/null

