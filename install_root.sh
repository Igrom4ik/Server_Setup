#!/usr/bin/env bash
# Hardened server setup script
# 1) Скачайте скрипт: curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_root.sh -o install_root.sh
# 2) chmod +x install_root.sh
# 3) sudo ./install_root.sh
#
# Требуемые зависимости до запуска (на мини-системе):
#   apt-get update && apt-get install -y jq curl sudo awk ca-certificates
#
# Скрипт читает настройки из /usr/local/bin/config.json или скачивает их с CONFIG_URL.
# Не запускайте через pipe (curl | bash), чтобы избежать смешения stdout/stderr и интерактива.

set -euo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

CONFIG_FILE="/usr/local/bin/config.json"
CONFIG_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/config.json"

# --- logging helpers ---
log() {
  # Neutral log
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}
log_ok() {
  printf '%s | ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}
log_warn() {
  printf '%s | ⚠️  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}
die() {
  printf '%s | ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

trap 'die "Ошибка на строке $LINENO (команда: ${BASH_COMMAND:-N/A})"' ERR

# --- root / sudo check ---
ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      log "Перезапуск от root через sudo..."
      exec sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE,BOT_TOKEN,CHAT_ID bash "$0" "$@"
    else
      die "Скрипт должен выполняться от root (sudo отсутствует)."
    fi
  fi
}

# --- dependencies ---
require_cmd() {
  local missing=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if ((${#missing[@]})); then
    log_warn "Отсутствуют зависимости: ${missing[*]}. Пытаемся установить..."
    apt-get update -y
    apt-get install -y "${missing[@]}" || die "Не удалось установить: ${missing[*]}"
  fi
}

# --- load / fetch config ---
ensure_config() {
  if [[ ! -f $CONFIG_FILE ]]; then
    log_warn "config.json не найден. Скачиваем..."
    local tmp
    tmp="$(mktemp /tmp/config.json.XXXXXX)"
    if curl -fsSL "$CONFIG_URL" -o "$tmp"; then
      mv "$tmp" "$CONFIG_FILE"
      chmod 644 "$CONFIG_FILE"
      log_ok "config.json загружен"
    else
      die "Не удалось скачать config.json с $CONFIG_URL"
    fi
  fi

  if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    die "config.json повреждён или невалиден JSON"
  fi

  PUBKEY=$(jq -r '.public_key_content // ""' "$CONFIG_FILE")
  PORT=$(jq -r '.port // "22"' "$CONFIG_FILE")
  SSH_DISABLE_ROOT=$(jq -r 'if .ssh_disable_root == null then false else .ssh_disable_root end' "$CONFIG_FILE")
  SSH_PASSWORD_AUTH=$(jq -r 'if .ssh_password_auth == null then true else .ssh_password_auth end' "$CONFIG_FILE")
  SSH_ROOT_PASSWORD_AUTH=$(jq -r 'if .ssh_root_password_auth == null then true else .ssh_root_password_auth end' "$CONFIG_FILE")
  SUDO_NOPASSWD=$(jq -r '.sudo_nopasswd // "false"' "$CONFIG_FILE")
  MONITORING_ENABLED=$(jq -r '.monitoring_enabled // "false"' "$CONFIG_FILE")
  BOT_TOKEN=$(jq -r '.telegram_bot_token // ""' "$CONFIG_FILE")
  CHAT_ID=$(jq -r '.telegram_chat_id // ""' "$CONFIG_FILE")
  ENABLE_AUTO_IDS_REGEX=$(jq -r '.psad_auto_ids_regex // "N"' "$CONFIG_FILE")

  SERVICES_UFW=$(jq -r '.services.ufw // "false"' "$CONFIG_FILE")
  SERVICES_FAIL2BAN=$(jq -r '.services.fail2ban // "false"' "$CONFIG_FILE")
  SERVICES_RKHUNTER=$(jq -r '.services.rkhunter // "false"' "$CONFIG_FILE")
  SERVICES_NMAP=$(jq -r '.services.nmap // "false"' "$CONFIG_FILE")
  SERVICES_PSAD=$(jq -r '.services.psad // "false"' "$CONFIG_FILE")
}

# --- delete old artifacts ---
maybe_delete_old() {
  local DEL_OLD="n"
  if [[ -t 0 ]]; then
    read -r -p "🔍 Найти и удалить старые версии Telegram-бота и cron-скриптов? [y/N]: " DEL_OLD
  else
    log "stdin не TTY — пропускаем запрос на удаление (по умолчанию: N)"
  fi
  if [[ "$DEL_OLD" =~ ^[Yy]$ ]]; then
    log "Удаление старых скриптов..."
    systemctl stop telegram_command_listener.service 2>/dev/null || true
    systemctl disable telegram_command_listener.service 2>/dev/null || true
    rm -f /etc/systemd/system/telegram_command_listener.service
    rm -f /usr/local/bin/telegram_command_listener.sh
    rm -f /usr/local/bin/telegram_ssh_notify.sh
    rm -f /etc/cron.d/cron-security-check /etc/cron.d/cron-clear-security-log /etc/cron.d/cron-weekly-update
    rm -f /usr/local/bin/cron_security_check.sh /usr/local/bin/cron_clear_security_log.sh /usr/local/bin/cron_weekly_update.sh
    rm -rf /root/.cache/telegram_* /home/*/.cache/telegram_* ~/.local/share/telegram_bot/ 2>/dev/null || true
    log_ok "Старые скрипты удалены"
  else
    log "Пропуск удаления старых скриптов"
  fi
}

# --- SSH / user configuration ---
setup_user_ssh() {
  local username home_dir
  username=$(whoami)
  home_dir=$(getent passwd "$username" | cut -d: -f6)

  log "Создание ~/.ssh и настройка ключей"
  mkdir -p "$home_dir/.ssh"
  chmod 700 "$home_dir/.ssh"
  touch "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"

  if [[ -n "$PUBKEY" && "$PUBKEY" != "null" ]]; then
    # Удалим возможные \r
    echo "$PUBKEY" | tr -d '\r' > "$home_dir/.ssh/authorized_keys"
  else
    log_warn "public_key_content пустой — authorized_keys не переписан"
  fi

  log "Настройка /etc/ssh/sshd_config (порт: $PORT)"
  sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config

  if [[ "$SSH_DISABLE_ROOT" == "true" ]]; then
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
  else
    # Root login is allowed, determine the method
    if [[ "$SSH_ROOT_PASSWORD_AUTH" == "true" ]]; then
      sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config
    else
      sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
    fi
  fi

  if [[ "$SSH_PASSWORD_AUTH" == "false" ]]; then
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
  else
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
  fi

  systemctl restart ssh || service ssh restart || log_warn "Не удалось перезапустить SSH стандартным способом"

  if [[ "$SUDO_NOPASSWD" == "true" ]]; then
    echo "$username ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-$username"
    chmod 440 "/etc/sudoers.d/90-$username"
    log_ok "Пользователю $username выдано sudo без пароля"
  fi
}

# --- services installation ---
setup_services() {
  local to_install=()
  [[ "$SERVICES_UFW" == "true" ]] && to_install+=("ufw")
  [[ "$SERVICES_FAIL2BAN" == "true" ]] && to_install+=("fail2ban")
  [[ "$SERVICES_RKHUNTER" == "true" ]] && to_install+=("rkhunter")
  [[ "$SERVICES_NMAP" == "true" ]] && to_install+=("nmap")

  if ((${#to_install[@]})); then
    log "Установка сервисов: ${to_install[*]}"
    apt-get update -y
    apt-get install -y "${to_install[@]}"
  else
    log "Все сервисы отключены в config.json"
  fi

  for svc in "${to_install[@]}"; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      systemctl enable --now "$svc" || log_warn "Не удалось активировать $svc"
    else
      log_warn "$svc не предоставляет systemd unit — пропуск enable"
    fi
  done

  if [[ "$SERVICES_UFW" == "true" ]]; then
    if command -v ufw >/dev/null 2>&1; then
      ufw allow "$PORT"/tcp || log_warn "Не удалось открыть порт $PORT в ufw"
      ufw --force enable || log_warn "Не удалось включить ufw"
    fi
  fi
}

# --- psad configuration ---
setup_psad() {
  if [[ "$SERVICES_PSAD" != "true" ]]; then
    log "psad отключён в config.json"
    return 0
  fi

  log "Установка psad"
  apt-get install -y psad || die "Не удалось установить psad"

  log "Настройка psad.conf"
  # Пример минимальных настроек:
  sed -i 's/^ENABLE_AUTO_IDS.*/ENABLE_AUTO_IDS           Y;/' /etc/psad/psad.conf || true
  grep -q '^ENABLE_AUTO_IDS' /etc/psad/psad.conf || echo "ENABLE_AUTO_IDS           Y;" >> /etc/psad/psad.conf
  sed -i 's/^ENABLE_EMAIL_ALERTS.*/ENABLE_EMAIL_ALERTS        Y;/' /etc/psad/psad.conf || true
  grep -q '^ENABLE_EMAIL_ALERTS' /etc/psad/psad.conf || echo "ENABLE_EMAIL_ALERTS        Y;" >> /etc/psad/psad.conf

  # Если процесс завис — убиваем и удаляем PID
  if pgrep -f /usr/sbin/psad >/dev/null 2>&1; then
    log_warn "Обнаружен работающий psad — перезапуск"
    pkill -f /usr/sbin/psad || true
    sleep 1
    rm -f /var/run/psad/psad.pid 2>/dev/null || true
  fi

  systemctl restart psad || die "Не удалось перезапустить psad (journalctl -xeu psad.service)"
  systemctl is-active --quiet psad && log_ok "psad активно" || die "psad не активен"
}

# --- cron jobs for monitoring ---
setup_cron() {
  if [[ "$MONITORING_ENABLED" != "true" ]]; then
    log "Monitoring (cron + telegram) отключён (monitoring_enabled != true)"
    return 0
  fi

  if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" || "$BOT_TOKEN" == "null" || "$CHAT_ID" == "null" ]]; then
    log_warn "BOT_TOKEN или CHAT_ID не заданы — cron уведомления Telegram не будут работать"
  fi

  log "Создание cron задач"

  cat >/usr/local/bin/cron_security_check.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="/var/log/security_monitor.log"
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"

send_telegram() {
  local MESSAGE="\$1"
  if [[ -n "\$BOT_TOKEN" && -n "\$CHAT_ID" && "\$BOT_TOKEN" != "null" && "\$CHAT_ID" != "null" ]]; then
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
      -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" \
      --data-urlencode text="\${MESSAGE}" >/dev/null || true
  fi
}

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

echo "\$(timestamp) | Начало проверки безопасности" >> "\$LOG_FILE"

if command -v rkhunter >/dev/null 2>&1; then
  RKHUNTER_RESULT=\$(rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
  if [[ -n "\$RKHUNTER_RESULT" ]]; then
    send_telegram "⚠️ *RKHunter обнаружил подозрительные элементы:*\n\`\`\`\n\$RKHUNTER_RESULT\n\`\`\`"
    echo "\$(timestamp) | ⚠️ RKHunter: найдены подозрения" >> "\$LOG_FILE"
  else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
    echo "\$(timestamp) | ✅ RKHunter: всё чисто" >> "\$LOG_FILE"
  fi
else
  echo "\$(timestamp) | RKHunter не установлен" >> "\$LOG_FILE"
fi

if [[ -f /var/log/psad/alert ]]; then
  PSAD_ALERTS=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
  if echo "\$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n\$PSAD_ALERTS\n\`\`\`"
    echo "\$(timestamp) | 🚨 PSAD: найдены угрозы" >> "\$LOG_FILE"
  else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
    echo "\$(timestamp) | ✅ PSAD: всё спокойно" >> "\$LOG_FILE"
  fi
else
  echo "\$(timestamp) | PSAD лог отсутствует" >> "\$LOG_FILE"
fi
echo "\$(timestamp) | ✅ Проверка завершена" >> "\$LOG_FILE"
EOF
  chmod +x /usr/local/bin/cron_security_check.sh
  echo "0 7 * * * root /usr/local/bin/cron_security_check.sh" >/etc/cron.d/cron-security-check

  cat >/usr/local/bin/cron_clear_security_log.sh <<'EOF'
#!/usr/bin/env bash
set -e
LOG_FILE="/var/log/security_monitor.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') | Очистка лога безопасности (еженедельно)" > "$LOG_FILE"
EOF
  chmod +x /usr/local/bin/cron_clear_security_log.sh
  echo "0 6 * * 1 root /usr/local/bin/cron_clear_security_log.sh" >/etc/cron.d/cron-clear-security-log

  cat >/usr/local/bin/cron_weekly_update.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="/var/log/weekly_update.log"
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"

send_telegram() {
  local MESSAGE="\$1"
  if [[ -n "\$BOT_TOKEN" && -n "\$CHAT_ID" && "\$BOT_TOKEN" != "null" && "\$CHAT_ID" != "null" ]]; then
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
      -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" \
      --data-urlencode text="\${MESSAGE}" >/dev/null || true
  fi
}

log_and_echo() { echo "\$1" | tee -a "\$LOG_FILE"; }

log_and_echo "🕖 ===== \$(date '+%Y-%m-%d %H:%M:%S') | Начало обновления ====="
apt-get update -y >>"\$LOG_FILE" 2>&1
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y >>"\$LOG_FILE" 2>&1
apt-get autoremove -y >>"\$LOG_FILE" 2>&1
apt-get autoclean -y >>"\$LOG_FILE" 2>&1
log_and_echo "✅ \$(date '+%Y-%m-%d %H:%M:%S') | Обновление завершено"
log_and_echo ""

TAIL_LOG=\$(tail -n 40 "\$LOG_FILE")
send_telegram "🧰 *Еженедельное обновление сервера завершено:*
\`\`\`
\${TAIL_LOG}
\`\`\`"
EOF
  chmod +x /usr/local/bin/cron_weekly_update.sh
  echo "30 5 * * 1 root /usr/local/bin/cron_weekly_update.sh" >/etc/cron.d/cron-weekly-update

  log_ok "Cron задачи настроены"
}

main() {
  ensure_root "$@"
  require_cmd jq curl awk
  maybe_delete_old
  ensure_config
  setup_user_ssh
  setup_services
  setup_psad
  setup_cron
  log_ok "Установка завершена"
}

main "$@"
