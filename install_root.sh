#!/usr/bin/env bash
# Server initial setup (Этап 1) с восстановленным созданием пользователя и улучшенной настройкой psad
#
# ШАГИ:
#   1) curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_root.sh -o install_root.sh
#   2) chmod +x install_root.sh
#   3) sudo ./install_root.sh
#
# ОСОБЕННОСТИ:
#   - Принудительно оставляет вход root по паролю (PermitRootLogin yes, PasswordAuthentication yes)
#   - Создаёт пользователя из config.json (username, user_password)
#   - Настраивает SSH порт из config.json
#   - Настраивает ключи SSH (priority: public_key_content -> ./id_ed25519.pub -> /root/.ssh/authorized_keys)
#   - Устанавливает и включает выбранные сервисы (ufw, fail2ban, rkhunter, nmap, psad)
#   - Улучшенная функция setup_psad()
#   - Настройка cron-задач (если monitoring_enabled = true)
#
# ВНИМАНИЕ:#!/usr/bin/env bash
# Этап 1 (root): создание пользователя, загрузка config, базовые привилегии.
# После успешного выполнения: зайти под пользователем и запустить ./install_user.sh
set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

REPO_OWNER="Igrom4ik"
REPO_NAME="Server_Setup"

# Пути и ресурсы
CONFIG_RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/config.json"
CONFIG_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/config.json"
USER_SCRIPT_RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/install_user.sh"
USER_SCRIPT_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/install_user.sh"

CONFIG_DIR="/etc/server_setup"
CONFIG_FILE="${CONFIG_DIR}/config.json"
LEGACY_CONFIG_LINK="/usr/local/bin/config.json"  # Для совместимости со старыми скриптами
STATE_DIR="/var/lib/server_setup"
LOG="/var/log/install_root.log"

GITHUB_TOKEN="${1:-${GITHUB_TOKEN:-}}"

mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOG"
}

fail() {
  log "❌ $*"
  exit 1
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "📦 Устанавливаю пакет: $pkg"
    apt-get install -y "$pkg" >/dev/null
  fi
}

fetch_file() {
  # $1 raw_url, $2 api_url, $3 dest, $4 logical_name
  local RAW="$1" API="$2" DEST="$3" NAME="$4"
  if [[ -f "./$NAME" ]]; then
    log "📦 Использую локальный файл $NAME"
    cp "./$NAME" "$DEST"
    return 0
  fi
  if [[ -n "$GITHUB_TOKEN" ]]; then
    log "🔐 Пытаюсь скачать $NAME через GitHub API"
    if curl -fsSL -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github.v3.raw" "$API" -o "$DEST"; then
      log "✅ $NAME скачан через API"
      return 0
    else
      log "⚠️ API не сработал — fallback на raw"
    fi
  fi
  log "🌐 Скачиваю $NAME по прямой ссылке"
  curl -fsSL --retry 3 --retry-delay 2 "$RAW" -o "$DEST"
  log "✅ $NAME скачан (raw)"
}

prepare_system() {
  if [[ -f "$STATE_DIR/01.system.prepared" ]]; then
    log "⏩ Шаг already done: prepare_system"
    return
  fi
  log "🔧 Обновление индексов apt"
  apt-get update -y
  for p in curl jq sudo wget gnupg ca-certificates iproute2; do
    ensure_pkg "$p"
  done
  touch "$STATE_DIR/01.system.prepared"
  log "✅ Базовые зависимости готовы"
}

load_config() {
  if [[ -f "$STATE_DIR/02.config.loaded" ]]; then
    log "⏩ Шаг already done: load_config"
  else
    log "📁 Подготовка каталога конфига"
    mkdir -p "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
    fetch_file "$CONFIG_RAW_URL" "$CONFIG_API_URL" "$CONFIG_FILE" "config.json"
    [[ -s "$CONFIG_FILE" ]] || fail "config.json пуст"
    jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || fail "config.json невалидный JSON"
    chmod 640 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    # Совместимость: создаём/обновляем symlink
    mkdir -p "$(dirname "$LEGACY_CONFIG_LINK")"
    ln -sf "$CONFIG_FILE" "$LEGACY_CONFIG_LINK"
    touch "$STATE_DIR/02.config.loaded"
    log "✅ Конфиг загружен"
  fi

  USERNAME=$(jq -r '.username // empty' "$CONFIG_FILE")
  PASSWORD=$(jq -r '.user_password // empty' "$CONFIG_FILE")
  PUBKEY=$(jq -r '.public_key_content // empty' "$CONFIG_FILE")
  SUDO_NOPASSWD=$(jq -r '.sudo_nopasswd // "false"' "$CONFIG_FILE")
  DISABLE_USER_PASSWORD=$(jq -r '.disable_user_password // "false"' "$CONFIG_FILE")
  PRESERVE_PORT_22=$(jq -r '.preserve_port_22 // "true"' "$CONFIG_FILE")
  PRESERVE_ROOT_PASSWORD=$(jq -r '.preserve_root_password // "true"' "$CONFIG_FILE")

  # === ЖЁСТКИЙ РЕЖИМ: отключаем пароли ТОЛЬКО для обычного пользователя, root не трогаем если preserve_root_password=true ===
  DISABLE_USER_PASSWORD="true"
  SUDO_NOPASSWD="true"
  PRESERVE_PORT_22="true"  # всегда держим 22 как резерв
  if [[ "$PRESERVE_ROOT_PASSWORD" == "true" ]]; then
    log "🔐 Режим: пользователь без пароля; root пароль НЕ трогаем"
  else
    log "🔐 Режим: пользователь без пароля; root пароль будет заблокирован"
  fi
  PRESERVE_PORT_22=$(jq -r '.preserve_port_22 // "true"' "$CONFIG_FILE")

  if [[ "$DISABLE_USER_PASSWORD" == "true" ]]; then
    [[ -n "$USERNAME" && -n "$PUBKEY" ]] || fail "При disable_user_password=true требуются username и public_key_content"
    if [[ -z "$PASSWORD" ]]; then
      log "ℹ️ Пароль пропущен (disable_user_password=true)"
    fi
  else
    [[ -n "$USERNAME" && -n "$PASSWORD" && -n "$PUBKEY" ]] || fail "Недостаточно полей в config.json (username, user_password, public_key_content)"
  fi
  if [[ "$USERNAME" == "root" ]]; then
    fail "username=root запрещено"
  fi
}

create_user() {
  : "${DISABLE_USER_PASSWORD:=true}"  # принудительно true в режиме без паролей
  if [[ -f "$STATE_DIR/03.user.created" ]]; then
    log "⏩ Шаг already done: create_user"
    return
  fi
  if id "$USERNAME" >/dev/null 2>&1; then
    log "ℹ️ Пользователь $USERNAME уже существует — принудительно удаляю и блокирую пароль"
    passwd -d "$USERNAME" 2>/dev/null || true
    usermod -L "$USERNAME" 2>/dev/null || true
  else
    log "👤 Создаю пользователя $USERNAME"
    adduser --disabled-password --gecos "" "$USERNAME"
    log "🔒 Пароль не устанавливается (режим passwordless)"
  fi
  # Расширенные группы
  for g in sudo adm systemd-journal syslog docker lxd netdev; do
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$USERNAME" || true
  done
  # Если пароль отключён — форсируем NOPASSWD один раз (уже сделали выше в блоке создания/обновления)
  # Всегда NOPASSWD в этом режиме
  SUDO_NOPASSWD="true"
  # Немедленная настройка sudoers (раньше было отдельным шагом)
  local SUDO_FILE="/etc/sudoers.d/90-$USERNAME"
  log "🛡 (inline) NOPASSWD для $USERNAME (ALL:ALL)"
  echo "$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL" > "$SUDO_FILE"
  chmod 440 "$SUDO_FILE"
  if ! visudo -cf "$SUDO_FILE" >/dev/null; then
    rm -f "$SUDO_FILE"
    fail "Файл sudoers (inline) не прошёл проверку"
  fi
  # Отмечаем сразу выполнение sudoers шага
  touch "$STATE_DIR/05.sudoers.done"
  touch "$STATE_DIR/03.user.created"
  log "✅ Пользователь готов"
}

install_ssh_key() {
  if [[ -f "$STATE_DIR/04.sshkey.installed" ]]; then
    log "⏩ Шаг already done: install_ssh_key"
    return
  fi
  local HOME_DIR
  HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)
  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/.ssh"
  if ! grep -qF "$PUBKEY" "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null; then
    echo "$PUBKEY" >> "$HOME_DIR/.ssh/authorized_keys"
  fi
  chown "$USERNAME:$USERNAME" "$HOME_DIR/.ssh/authorized_keys"
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"
  touch "$STATE_DIR/04.sshkey.installed"
  log "✅ SSH ключ установлен"
}

configure_sudoers() {
  if [[ -f "$STATE_DIR/05.sudoers.done" ]]; then
    log "⏩ Шаг already done: configure_sudoers"
    return
  fi
  local SUDO_FILE="/etc/sudoers.d/90-$USERNAME"
  log "🛡 (passwordless mode) NOPASSWD для $USERNAME (ALL:ALL)"
  echo "$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL" > "$SUDO_FILE"
  chmod 440 "$SUDO_FILE"
  if ! visudo -cf "$SUDO_FILE" >/dev/null; then
    rm -f "$SUDO_FILE"
    fail "Файл sudoers не прошёл проверку"
  fi
  touch "$STATE_DIR/05.sudoers.done"
  log "✅ sudoers готов"
}

configure_polkit() {
  if [[ -f "$STATE_DIR/06.polkit.done" ]]; then
    log "⏩ Шаг already done: configure_polkit"
    return
  fi
  # Устанавливаем policykit-1 если отсутствует (минимальные образы часто без него)
  if ! dpkg -s policykit-1 >/dev/null 2>&1; then
    log "📦 Устанавливаю policykit-1 (polkit)"
    if ! apt-get update -y && apt-get install -y policykit-1; then
      log "⚠️ Не удалось установить policykit-1 — пропуск создания polkit правила"
      touch "$STATE_DIR/06.polkit.done"
      return 0
    fi
  fi
  mkdir -p /etc/polkit-1/rules.d
  local RULE="/etc/polkit-1/rules.d/49-sudo-nopasswd.rules"
  cat <<'EOF' > "$RULE"
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
  chmod 644 "$RULE"
  systemctl daemon-reexec || true
  touch "$STATE_DIR/06.polkit.done"
  log "✅ polkit правило создано (все пользователи sudo получают YES)"
}

download_user_script() {
  if [[ -f "$STATE_DIR/07.user_script.ready" ]]; then
    log "⏩ Шаг already done: download_user_script"
    return
  fi
  local HOME_DIR
  HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)
  if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
    log "⚠️ Не удалось определить домашний каталог пользователя $USERNAME (HOME_DIR='$HOME_DIR') — fallback в /root"
    HOME_DIR="/root"
  fi
  local DEST="${HOME_DIR}/install_user.sh"
  fetch_file "$USER_SCRIPT_RAW_URL" "$USER_SCRIPT_API_URL" "$DEST" "install_user.sh"
  [[ -s "$DEST" ]] || fail "install_user.sh пуст"
  chown "$USERNAME:$USERNAME" "$DEST" 2>/dev/null || true
  chmod +x "$DEST"
  touch "$STATE_DIR/07.user_script.ready"
  log "✅ install_user.sh готов для запуска под $USERNAME"
}

final_message() {
  log "🎉 Этап root завершён. Далее:"
  echo
  echo "  su - $USERNAME"    
  echo "  # Локальный файл уже скачан в домашний каталог (install_user.sh)"
  echo "  sudo ./install_user.sh"    
  echo
  echo "Если видите запрос пароля при sudo и хотите отключить его:"
  echo "  1) В config.json установите \"sudo_nopasswd\": true"
  echo "  2) Перезапустите скрипт (или вручную: echo '$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/90-$USERNAME >/dev/null; sudo chmod 440 /etc/sudoers.d/90-$USERNAME)"
  echo
}

# Проверка статуса паролей и портов
verify_passwordless_and_ports() {
  echo
  log "🔎 Верификация режима без паролей и портов SSH"
  local user_status root_status
  user_status=$(passwd -S "$USERNAME" 2>/dev/null || true)
  root_status=$(passwd -S root 2>/dev/null || true)
  log "👤 passwd -S $USERNAME => ${user_status}" 
  log "👑 passwd -S root    => ${root_status}" 
  # Предупреждения если вдруг ещё P (password set)
  if echo "$user_status" | grep -q ' P '; then log "⚠️  У пользователя $USERNAME ещё установлен пароль"; fi
  if echo "$root_status" | grep -q ' P '; then
    if [[ "${PRESERVE_ROOT_PASSWORD:-true}" == "true" ]]; then
      log "ℹ️ Root пароль намеренно сохранён (preserve_root_password=true)"
    else
      log "⚠️  Root пароль ещё установлен (ожидалось удаление)"
    fi
  fi
  # Вывод hash из /etc/shadow (нельзя получить исходный пароль, только hash). Удобно для копирования/аудита.
  local user_hash root_hash
  user_hash=$(grep "^$USERNAME:" /etc/shadow 2>/dev/null | cut -d: -f2)
  root_hash=$(grep '^root:' /etc/shadow 2>/dev/null | cut -d: -f2)
  log "🔑 hash $USERNAME: ${user_hash:-<none>}"
  log "🔑 hash root: ${root_hash:-<none>}"
  if [[ "$user_hash" == '!'* || "$user_hash" == '*'* || -z "$user_hash" ]]; then
    log "ℹ️ Hash пользователя показывает блокировку ('!' или '*') — пароль неактивен"
  fi
  if [[ "$root_hash" == '!'* || "$root_hash" == '*'* || -z "$root_hash" ]]; then
    log "ℹ️ Hash root показывает блокировку ('!' или '*') либо пуст — пароль может быть отключён"
  fi
  # Список портов из конфига и фактическое прослушивание
  local cfg_ports
  cfg_ports=$(grep -E '^Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | sort -u | xargs)
  log "🗂 Порты в sshd_config: ${cfg_ports:-none}"
  local listening
  listening=$(ss -tln 2>/dev/null | awk 'NR>1{print $4}' | sed -n 's/.*:\([0-9]\+\)$/\1/p' | sort -u | grep -E '^(22|'"$PORT"')$' || true)
  log "📡 Фактически слушаются (22/$PORT): ${listening:-not-listening}" 
  if ! echo "$cfg_ports" | grep -qw '22'; then log "⚠️  Port 22 отсутствует в sshd_config (ожидался резерв)"; fi
  if ! echo "$cfg_ports" | grep -qw "$PORT"; then log "⚠️  Основной порт $PORT не найден в sshd_config"; fi
  echo
}

main() {
  log "🚀 Запуск install_root.sh"
  prepare_system
  load_config
  create_user
  install_ssh_key
  configure_sudoers
  # Сначала скачиваем пользовательский скрипт, чтобы сбой polkit не мешал дальнейшим шагам
  download_user_script
  configure_polkit
  verify_passwordless_and_ports
  final_message
}

main "$@"
#   Если нужно запретить root вход / отключить пароль — вручную поменяйте configure_sshd().
#
# ТРЕБУЕМЫЕ ПАКЕТЫ (если минимальный образ):
#   apt-get update && apt-get install -y jq curl sudo awk ca-certificates
#
# НЕ ЗАПУСКАТЬ через pipe (curl | bash) для корректной обработки ошибок.

set -euo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

CONFIG_FILE="/usr/local/bin/config.json"
# Обрати внимание: в оригинале был опечатанный владелец (Igrom4ek). Здесь используем корректный.
CONFIG_URL_PRIMARY="https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/config.json"
CONFIG_URL_FALLBACK="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/config.json"

# ---------- ЛОГИРОВАНИЕ ----------
log()      { printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_ok()   { printf '%s | ✅ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn() { printf '%s | ⚠️  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()      { printf '%s | ❌ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

trap 'die "Ошибка на строке $LINENO (команда: ${BASH_COMMAND:-N/A})"' ERR

# ---------- ПРОВЕРКА ROOT ----------
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

# ---------- ПРОВЕРКА/УСТАНОВКА ЗАВИСИМОСТЕЙ ----------
require_cmd() {
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    log_warn "Отсутствуют зависимости: ${missing[*]} — устанавливаю"
    apt-get update -y
    apt-get install -y "${missing[@]}" || die "Не удалось установить: ${missing[*]}"
  fi
}

# ---------- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ (из config.json) ----------
PUBKEY=""
PORT="22"
SSH_DISABLE_ROOT=""       # Игнорируется
SSH_PASSWORD_AUTH=""      # Игнорируется
SUDO_NOPASSWD=""
MONITORING_ENABLED=""
BOT_TOKEN=""
CHAT_ID=""
ENABLE_AUTO_IDS_REGEX=""
SERVICES_UFW=""
SERVICES_FAIL2BAN=""
SERVICES_RKHUNTER=""
SERVICES_NMAP=""
SERVICES_PSAD=""
USERNAME=""
USER_PASSWORD=""
DISABLE_USER_PASSWORD="${DISABLE_USER_PASSWORD:-false}"
PRESERVE_PORT_22=""

# ---------- ЗАГРУЗКА / ПРОЧТЕНИЕ КОНФИГА ----------
ensure_config() {
  if [[ ! -f $CONFIG_FILE ]]; then
    log_warn "config.json не найден. Пытаюсь скачать..."
    local tmp
    tmp="$(mktemp /tmp/config.json.XXXXXX)"
    if curl -fsSL "$CONFIG_URL_PRIMARY" -o "$tmp"; then
      :
    elif curl -fsSL "$CONFIG_URL_FALLBACK" -o "$tmp"; then
      log_warn "Использован fallback URL (возможно опечатка владельца репо)"
    else
      die "Не удалось скачать config.json ни с $CONFIG_URL_PRIMARY ни с fallback"
    fi
    mv "$tmp" "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    log_ok "config.json сохранён в $CONFIG_FILE"
  fi

  jq empty "$CONFIG_FILE" 2>/dev/null || die "config.json повреждён (невалидный JSON)"

  PUBKEY=$(jq -r '.public_key_content // ""' "$CONFIG_FILE")
  PORT=$(jq -r '.port // "22"' "$CONFIG_FILE")
  SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root // "false"' "$CONFIG_FILE")
  SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth // "true"' "$CONFIG_FILE")
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

  USERNAME=$(jq -r '.username // ""' "$CONFIG_FILE")
  USER_PASSWORD=$(jq -r '.user_password // ""' "$CONFIG_FILE")
  DISABLE_USER_PASSWORD=$(jq -r '.disable_user_password // "false"' "$CONFIG_FILE")
  PRESERVE_PORT_22=$(jq -r '.preserve_port_22 // "true"' "$CONFIG_FILE")

  [[ -n "$USERNAME" && "$USERNAME" != "null" ]] || die "В config.json отсутствует поле 'username'"
  [[ "$USERNAME" != "root" ]] || die "username в config.json не должен быть 'root'"
}

# ---------- УДАЛЕНИЕ СТАРЫХ АРТЕФАКТОВ (ОПЦИОНАЛЬНО) ----------
maybe_delete_old() {
  local DEL_OLD="n"
  if [[ -t 0 ]]; then
    read -r -p "🔍 Найти и удалить старые версии Telegram-бота и cron-скриптов? [y/N]: " DEL_OLD || true
  else
    log "stdin не TTY — пропуск запроса удаления"
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

# ---------- СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ----------
create_app_user() {
  : "${DISABLE_USER_PASSWORD:=false}"  # безопасное значение по умолчанию для второй части
  if id -u "$USERNAME" >/dev/null 2>&1; then
    log "Пользователь $USERNAME уже существует — пропуск создания"
  else
    log "Создаю пользователя $USERNAME..."
    useradd -m -s /bin/bash "$USERNAME"
    if getent group sudo >/dev/null 2>&1; then
      usermod -aG sudo "$USERNAME"
    elif getent group wheel >/dev/null 2>&1; then
      usermod -aG wheel "$USERNAME"
    fi
    log_ok "Пользователь $USERNAME создан"
  fi

  # Respect DISABLE_USER_PASSWORD (new unified passwordless policy from early phase)
  if [[ "$DISABLE_USER_PASSWORD" == "true" ]]; then
    log "🔒 disable_user_password=true — не устанавливаю пароль (если был — удаляю)"
    passwd -d "$USERNAME" 2>/dev/null || true
    usermod -L "$USERNAME" 2>/dev/null || true
  elif [[ -n "$USER_PASSWORD" && "$USER_PASSWORD" != "null" ]]; then
    log "Устанавливаю пароль пользователю $USERNAME (disable_user_password!=true)"
    echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
  else
    log "Пароль не задан (оставляем только ключевой доступ для $USERNAME)"
  fi

  local home_dir
  home_dir=$(eval echo "~$USERNAME")
  local ssh_dir="${home_dir}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$ssh_dir"

  if [[ -n "$PUBKEY" && "$PUBKEY" != "null" ]]; then
    printf '%s\n' "$PUBKEY" > "$auth_keys"
    log "SSH ключ для $USERNAME взят из public_key_content"
  elif [[ -f ./id_ed25519.pub ]]; then
    cat ./id_ed25519.pub > "$auth_keys"
    log "SSH ключ для $USERNAME взят из ./id_ed25519.pub"
  elif [[ -f /root/.ssh/authorized_keys ]]; then
    grep -E 'ssh-(ed25519|rsa|ecdsa)' /root/.ssh/authorized_keys > "$auth_keys" || true
    log "SSH ключ(и) для $USERNAME скопированы из /root/.ssh/authorized_keys"
  else
    log_warn "Не найден источник публичного ключа для $USERNAME — authorized_keys пуст"
    : > "$auth_keys"
  fi

  chown "$USERNAME:$USERNAME" "$auth_keys"
  chmod 600 "$auth_keys"

  if [[ "$SUDO_NOPASSWD" == "true" ]]; then
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-${USERNAME}"
    chmod 440 "/etc/sudoers.d/90-${USERNAME}"
    log_ok "Выдано sudo NOPASSWD для $USERNAME"
  fi

  log_ok "SSH доступ настроен для $USERNAME"
}

# ---------- НАСТРОЙКА ROOT SSH / КЛЮЧЕЙ ----------
setup_root_ssh_and_keys() {
  log "Настройка root SSH authorized_keys"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  if [[ -n "$PUBKEY" && "$PUBKEY" != "null" ]]; then
    if [[ "${PRESERVE_ROOT_AUTH_KEYS:-true}" == "true" ]]; then
      if ! grep -qF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
        log "➕ Добавляю ключ в /root/.ssh/authorized_keys (append, без перезаписи)"
        printf '%s\n' "$PUBKEY" >> /root/.ssh/authorized_keys
      else
        log "ℹ️ Ключ уже присутствует в root authorized_keys"
      fi
    else
      log "⚠️ PERMISSIVE: overwrite root authorized_keys (preserve_root_authorized_keys=false)"
      printf '%s\n' "$PUBKEY" | tr -d '\r' > /root/.ssh/authorized_keys
    fi
  else
    log_warn "public_key_content пуст — пропуск изменения root authorized_keys"
  fi
  # Блокируем пароль root только если явно не сохранён
  if [[ "${PRESERVE_ROOT_PASSWORD:-true}" != "true" ]]; then
    passwd -d root 2>/dev/null || true
    usermod -L root 2>/dev/null || true
    log "🔒 Root пароль удалён (preserve_root_password=false)"
  else
    log "ℹ️ Root пароль сохранён (preserve_root_password=true)"
  fi
  echo "root ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-root-nopasswd"
  chmod 440 "/etc/sudoers.d/90-root-nopasswd"
}

# ---------- НАСТРОЙКА SSHD ----------
configure_sshd() {
  log "Настройка sshd_config (Port=$PORT, preserve_root_ssh=${PRESERVE_ROOT_SSH:-true})"
  local f=/etc/ssh/sshd_config
  [[ -f $f ]] || die "Файл $f не найден"
  # Backup один раз
  if [[ ! -f ${f}.orig ]]; then
    cp -a "$f" ${f}.orig
    log "🗃️ Backup sshd_config -> ${f}.orig"
  fi
  # Порты
  if [[ "${PRESERVE_PORT_22:-true}" != "true" ]]; then
    # Удаляем все Port строки и задаём только наш
    sed -i '/^Port[[:space:]]\+[0-9]\+/d' "$f" || true
    echo "Port $PORT" >> "$f"
  else
    # Добавляем недостающие
    if ! grep -Eq '^Port[[:space:]]+'"$PORT" "$f"; then echo "Port $PORT" >> "$f"; fi
    if [[ "$PORT" != "22" ]] && ! grep -Eq '^Port[[:space:]]+22(\s|$)' "$f"; then echo "Port 22" >> "$f"; fi
  fi
  # Новое требование: всегда отключаем парольную аутентификацию (только ключи)
  sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$f" || true
  grep -qi '^PasswordAuthentication' "$f" || echo "PasswordAuthentication no" >> "$f"
  # Разрешаем root вход только по ключу (пароль root может существовать локально, но не для SSH)
  sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" "$f" || true
  grep -qi '^PermitRootLogin' "$f" || echo "PermitRootLogin prohibit-password" >> "$f"
  log "🔐 SSH: принудительно PasswordAuthentication no; PermitRootLogin prohibit-password (только ключи)"
  if systemctl restart ssh 2>/dev/null; then
    log_ok "SSH перезапущен"
  elif service ssh restart 2>/dev/null; then
    log_ok "SSH перезапущен (service)"
  else
    log_warn "Не удалось перезапустить ssh стандартными командами"
  fi
}

# ---------- УСТАНОВКА БАЗОВЫХ СЕРВИСОВ ----------
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
    log "Нет сервисов для установки согласно config.json"
  fi

  for svc in "${to_install[@]}"; do
    if systemctl list-unit-files | grep -q "^${svc}.service"; then
      systemctl enable --now "$svc" || log_warn "Не удалось enable/start $svc"
    fi
  done

  if [[ "$SERVICES_UFW" == "true" ]] && command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT"/tcp || log_warn "Не удалось открыть порт $PORT в ufw"
    if [[ "${PRESERVE_PORT_22:-true}" == "true" && "$PORT" != "22" ]]; then
      ufw allow 22/tcp || log_warn "Не удалось открыть порт 22 в ufw"
    fi
    ufw --force enable || log_warn "Не удалось включить ufw"
  fi
}

# ---------- УЛУЧШЕННАЯ НАСТРОЙКА PSAD ----------
setup_psad() {
  if [[ "$SERVICES_PSAD" != "true" ]]; then
    log "⏩ psad отключён (services.psad != true)"
    return 0
  fi

  log "🛡 Установка/настройка psad"
  require_cmd apt-get

  if ! command -v psad >/dev/null 2>&1; then
    log "📦 Установка psad"
    apt-get update -y
    apt-get install -y psad || die "Не удалось установить psad"
    log_ok "psad установлен"
  else
    log "ℹ️ psad уже установлен"
  fi

  local PSAD_CONF="/etc/psad/psad.conf"
  [[ -f $PSAD_CONF ]] || die "psad.conf не найден после установки"

  if [[ ! -f /etc/psad/psad.conf.orig ]]; then
    cp -a "$PSAD_CONF" /etc/psad/psad.conf.orig
    log_ok "Создан backup psad.conf.orig"
  fi

  ensure_psad_conf() {
    local key="$1"
    local value="$2" # значение с ';'
    local esc_key
    esc_key=$(printf '%s' "$key" | sed 's/[\/&]/\\&/g')
    local esc_value
    esc_value=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')
    if grep -Eq "^${esc_key}\b" "$PSAD_CONF"; then
      sed -i "s|^${esc_key}.*|${esc_key} ${esc_value}|g" "$PSAD_CONF"
    else
      echo "${key} ${value}" >> "$PSAD_CONF"
    fi
  }

  log "🔧 Обновление директив psad.conf"
  ensure_psad_conf "ENABLE_AUTO_IDS" "Y;"
  ensure_psad_conf "ENABLE_EMAIL_ALERTS" "Y;"
  ensure_psad_conf "ENABLE_AUTO_IDS_EMAILS" "Y;"
  ensure_psad_conf "ENABLE_AUTO_IDS_REGEX" "${ENABLE_AUTO_IDS_REGEX:-N};"
  ensure_psad_conf "EMAIL_ADDRESSES" "root@localhost;"
  ensure_psad_conf "HOSTNAME" "$(hostname);"

  if [[ -f /proc/sys/net/ipv4/conf/all/log_martians ]]; then
    echo 1 >/proc/sys/net/ipv4/conf/all/log_martians 2>/dev/null || log_warn "Не удалось включить log_martians"
  fi

  if ! command -v iptables >/dev/null 2>&1; then
    log_warn "iptables не найден — устанавливаю"
    apt-get install -y iptables || die "Не удалось установить iptables"
  fi

  add_log_rule() {
    local chain="$1"
    if ! iptables -L "$chain" -n -v 2>/dev/null | grep -q 'LOG.*PSAD:'; then
      iptables -A "$chain" -j LOG --log-prefix "PSAD: " --log-level 7 || log_warn "Не удалось добавить LOG правило $chain"
    else
      log "ℹ️ LOG правило уже присутствует в $chain"
    fi
  }
  log "🔧 Добавление LOG правил iptables"
  add_log_rule INPUT
  add_log_rule FORWARD

  local UFW_WAS_ACTIVE="false"
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw; then
    UFW_WAS_ACTIVE="true"
    log "⚠️ Останавливаю ufw временно"
    systemctl stop ufw || log_warn "Не удалось остановить ufw"
  fi

  log "🔍 Проверка и остановка зависших процессов psad"
  if pgrep -x psad >/dev/null 2>&1; then
    pkill -x psad || true
    sleep 1
  fi
  if [[ -f /var/run/psad/psad.pid ]]; then
    local OLD_PID
    OLD_PID=$(cat /var/run/psad/psad.pid 2>/dev/null || true)
    if [[ -n "$OLD_PID" && -d /proc/$OLD_PID ]]; then
      kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f /var/run/psad/psad.pid || true
  fi

  log "🧹 Очистка логов/баз psad"
  find /var/log/psad -type f -exec truncate -s 0 {} \; 2>/dev/null || true
  find /var/lib/psad -type f -exec rm -f {} \; 2>/dev/null || true

  log "📥 Обновление сигнатур psad"
  if ! psad --sig-update; then
    log_warn "Ошибка sig-update — повтор"
    sleep 2
    psad --sig-update || log_warn "Повторное sig-update не удалось (продолжаем)"
  fi

  log "🔁 Перезапуск psad"
  systemctl restart psad || die "Не удалось перезапустить psad"
  sleep 1
  systemctl is-active --quiet psad || {
    systemctl status psad --no-pager | tail -n 40 >&2 || true
    psad --Status 2>&1 | tail -n 60 >&2 || true
    journalctl -u psad --since "5 minutes ago" --no-pager | tail -n 60 >&2 || true
    die "psad не активен после restart"
  }

  local STATUS_OUT
  STATUS_OUT=$(psad --Status 2>&1 || true)
  if echo "$STATUS_OUT" | grep -qi "error"; then
    log_warn "Статус psad содержит 'error' — проверь вывод вручную"
  fi

  if [[ "$UFW_WAS_ACTIVE" == "true" ]]; then
    log "🔄 Возврат ufw"
    systemctl start ufw || log_warn "Не удалось стартовать ufw"
    systemctl enable ufw >/dev/null 2>&1 || true
  fi

  local RECENT_ERR
  RECENT_ERR=$(journalctl -u psad --since "-2 minutes" --no-pager 2>/dev/null | grep -i "error" || true)
  [[ -z "$RECENT_ERR" ]] || log_warn "Ошибки в журнале psad (2 мин):\n$RECENT_ERR"

  log_ok "psad настроен и работает"
}

# ---------- CRON / MONITORING ----------
setup_cron() {
  if [[ "$MONITORING_ENABLED" != "true" ]]; then
    log "Monitoring отключён (monitoring_enabled != true)"
    return 0
  fi

  if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" || "$BOT_TOKEN" == "null" || "$CHAT_ID" == "null" ]]; then
    log_warn "BOT_TOKEN/CHAT_ID не заданы — Telegram уведомления cron не будут отправляться"
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
    echo "\$(timestamp) | ✅ RKHunter: чисто" >> "\$LOG_FILE"
  fi
else
  echo "\$(timestamp) | RKHunter не установлен" >> "\$LOG_FILE"
fi
if [[ -f /var/log/psad/alert ]]; then
  PSAD_ALERTS=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
  if echo "\$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n\$PSAD_ALERTS\n\`\`\`"
    echo "\$(timestamp) | 🚨 PSAD: угрозы" >> "\$LOG_FILE"
  else
    send_telegram "✅ *PSAD*: подозрительной активности нет"
    echo "\$(timestamp) | ✅ PSAD: спокойно" >> "\$LOG_FILE"
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

# ---------- ФИНАЛЬНЫЕ ИНСТРУКЦИИ ----------
print_next_steps() {
  cat <<EOF

================= ЭТАП 1 ЗАВЕРШЁН =================
Создан пользователь: $USERNAME
SSH порт: $PORT

Проверить вход:
  ssh $USERNAME@<IP_СЕРВЕРА> -p $PORT

Если задан пароль — при необходимости смените (passwd) после входа.

Далее Этап 2 (запуск НЕ от root, а от $USERNAME):
  curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_user.sh | sudo bash

===================================================

EOF
}

# ---------- MAIN ----------
main() {
  ensure_root "$@"
  require_cmd jq curl awk
  maybe_delete_old
  ensure_config
  create_app_user
  setup_root_ssh_and_keys
  configure_sshd
  setup_services
  setup_psad
  setup_cron
  log_ok "Этап 1 завершён успешно"
  print_next_steps
}

main "$@"
