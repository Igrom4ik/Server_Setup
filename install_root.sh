set -e
export DEBIAN_FRONTEND=noninteractive

# Токен GitHub из аргумента или переменной окружения
GITHUB_TOKEN="${1:-$GITHUB_TOKEN}"
REPO_OWNER="Igrom4ek"
REPO_NAME="Server_Setup"
CONFIG_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/config.json"
CONFIG_API_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/config.json"
USER_SCRIPT_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/install_user.sh"
USER_SCRIPT_API_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/contents/install_user.sh"
CONFIG_FILE="/usr/local/bin/config.json"
LOG="/var/log/install_root.log"
TARGET_PATH="/home/igrom/install_user.sh"

# Функция логирования
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

# Проверка зависимостей
log "🔍 Проверяем зависимости (curl, jq, sudo)"
for cmd in curl jq sudo; do
  if ! command -v "$cmd" &> /dev/null; then
    log "❌ Ошибка: $cmd не установлен. Устанавливаем..."
    if ! apt install -y "$cmd"; then
      log "❌ Ошибка: Не удалось установить $cmd"
      exit 1
    fi
  fi
done

# Обновление системы
log "📦 Обновляем систему (root)"
if ! apt clean all; then
  log "❌ Ошибка при очистке кэша apt"
  exit 1
fi
if ! apt update; then
  log "❌ Ошибка при обновлении списка пакетов"
  exit 1
fi
if ! apt dist-upgrade -y; then
  log "❌ Ошибка при обновлении системы"
  exit 1
fi

# Скачивание config.json
log "⬇️ Скачиваем config.json"
if [ -f "./config.json" ]; then
  log "📦 Используем локальный config.json"
  if ! cp ./config.json "$CONFIG_FILE"; then
    log "❌ Ошибка при копировании локального config.json"
    exit 1
  fi
else
  if [[ -n "$GITHUB_TOKEN" ]]; then
    log "🔐 Пробуем скачать через API с токеном"
    if curl -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3.raw" \
            -fsSL "$CONFIG_API_URL" -o "$CONFIG_FILE"; then
      log "✅ config.json успешно скачан через API"
    else
      log "⚠️ Не удалось скачать через API, пробуем прямую ссылку"
      if curl -fsSL "$CONFIG_URL" -o "$CONFIG_FILE"; then
        log "✅ config.json успешно скачан через прямую ссылку"
      else
        log "❌ Ошибка: Не удалось скачать config.json (проверьте токен или доступность репо)"
        exit 1
      fi
    fi
  else
    log "🌐 Пробуем скачать через прямую ссылку (публичный репо)"
    if curl -fsSL "$CONFIG_URL" -o "$CONFIG_FILE"; then
      log "✅ config.json успешно скачан"
    else
      log "❌ Ошибка: Не удалось скачать config.json (проверьте доступ или укажите токен)"
      exit 1
    fi
  fi
fi

# Проверка файла config.json
if [ ! -s "$CONFIG_FILE" ]; then
  log "❌ Ошибка: config.json не существует или пуст"
  exit 1
fi
if ! chmod 644 "$CONFIG_FILE"; then
  log "❌ Ошибка при установке прав для config.json"
  exit 1
fi

# Извлечение данных из config.json
USERNAME=$(jq -r '.username // empty' "$CONFIG_FILE")
PASSWORD=$(jq -r '.user_password // empty' "$CONFIG_FILE")
PUBKEY=$(jq -r '.public_key_content // empty' "$CONFIG_FILE")
if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] || [ -z "$PUBKEY" ]; then
  log "❌ Ошибка: Не удалось извлечь username, password или public_key из config.json"
  exit 1
fi

# Создание пользователя
log "👤 Создаём пользователя $USERNAME"
if id "$USERNAME" &>/dev/null; then
  log "⚠️ Пользователь $USERNAME уже существует, обновляем пароль"
  echo "$USERNAME:$PASSWORD" | chpasswd
else
  if ! adduser --disabled-password --gecos "" "$USERNAME"; then
    log "❌ Ошибка при создании пользователя $USERNAME"
    exit 1
  fi
  if ! echo "$USERNAME:$PASSWORD" | chpasswd; then
    log "❌ Ошибка при установке пароля для $USERNAME"
    exit 1
  fi
fi
if ! usermod -aG sudo,adm,systemd-journal,syslog "$USERNAME"; then
  log "❌ Ошибка при добавлении $USERNAME в группы"
  exit 1
fi
if getent group docker > /dev/null; then
  if ! usermod -aG docker "$USERNAME"; then
    log "❌ Ошибка при добавлении $USERNAME в группу docker"
    exit 1
  fi
fi

# Настройка polkit
log "🔒 Настраиваем polkit для группы sudo"
if [[ -f /etc/polkit-1/rules.d/49-nopasswd.rules ]]; then
  if ! sudo rm -f /etc/polkit-1/rules.d/49-nopasswd.rules; then
    log "❌ Ошибка при удалении старых правил polkit"
    exit 1
  fi
  log "Удалены старые правила polkit"
fi
if ! sudo mkdir -p /etc/polkit-1/rules.d; then
  log "❌ Ошибка при создании директории polkit"
  exit 1
fi
if ! cat <<EOF | sudo tee /etc/polkit-1/rules.d/49-nopasswd.rules > /dev/null
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
then
  log "❌ Ошибка при создании правил polkit"
  exit 1
fi
if ! sudo systemctl daemon-reexec; then
  log "❌ Ошибка при выполнении daemon-reexec"
  exit 1
fi
log "✅ Политика polkit обновлена"

# Настройка sudo без пароля
if ! echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USERNAME > /dev/null; then
  log "❌ Ошибка при настройке sudoers"
  exit 1
fi
if ! sudo chmod 440 /etc/sudoers.d/90-$USERNAME; then
  log "❌ Ошибка при установке прав для sudoers"
  exit 1
fi
log "🔧 Настроено sudo без пароля для пользователя $USERNAME"

# Настройка SSH-ключа
log "📁 Установка SSH-ключа в /home/$USERNAME/.ssh"
if ! sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.ssh"; then
  log "❌ Ошибка при создании директории .ssh"
  exit 1
fi
if ! echo "$PUBKEY" | sudo tee "/home/$USERNAME/.ssh/authorized_keys" > /dev/null; then
  log "❌ Ошибка при записи SSH-ключа"
  exit 1
fi
if ! sudo chmod 700 "/home/$USERNAME/.ssh"; then
  log "❌ Ошибка при установке прав для .ssh"
  exit 1
fi
if ! sudo chmod 600 "/home/$USERNAME/.ssh/authorized_keys"; then
  log "❌ Ошибка при установке прав для authorized_keys"
  exit 1
fi
if ! sudo chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"; then
  log "❌ Ошибка при установке владельца для .ssh"
  exit 1
fi

# Обработка install_user.sh
log "📁 Проверяем наличие install_user.sh"
if [ -f "./install_user.sh" ]; then
  log "📦 Копируем локальный install_user.sh в $TARGET_PATH"
  if ! cp ./install_user.sh "$TARGET_PATH"; then
    log "❌ Ошибка при копировании install_user.sh"
    exit 1
  fi
  log "✅ Файл успешно скопирован"
else
  log "⬇️ Скачиваем install_user.sh из GitHub"
  if [[ -n "$GITHUB_TOKEN" ]]; then
    log "🔐 Пробуем скачать через API с токеном"
    if curl -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3.raw" \
            -fsSL "$USER_SCRIPT_API_URL" -o "$TARGET_PATH"; then
      log "✅ Файл успешно скачан через API"
    else
      log "⚠️ Не удалось скачать через API, пробуем прямую ссылку"
      if curl -fsSL "$USER_SCRIPT_URL" -o "$TARGET_PATH"; then
        log "✅ Файл успешно скачан через прямую ссылку"
      else
        log "❌ Ошибка: Не удалось скачать install_user.sh (проверьте токен или доступность репо)"
        exit 1
      fi
    fi
  else
    log "🌐 Пробуем скачать через прямую ссылку (публичный репо)"
    if curl -fsSL "$USER_SCRIPT_URL" -o "$TARGET_PATH"; then
      log "✅ Файл успешно скачан"
    else
      log "❌ Ошибка: Не удалось скачать install_user.sh (проверьте доступ или укажите токен)"
      exit 1
    fi
  fi
fi

# Проверка файла install_user.sh
if [ ! -s "$TARGET_PATH" ]; then
  log "❌ Ошибка: $TARGET_PATH не существует или пуст"
  exit 1
fi

# Настройка прав для install_user.sh
log "🔧 Назначаем владельца и права для $TARGET_PATH"
if ! chown "$USERNAME:$USERNAME" "$TARGET_PATH" || ! chmod +x "$TARGET_PATH"; then
  log "❌ Ошибка при настройке прав для $TARGET_PATH"
  exit 1
fi
log "✅ Скрипт install_user.sh готов к запуску пользователем $USERNAME"

log "✅ Установка завершена. Теперь войдите под $USERNAME и выполните:"
echo
echo "  su - $USERNAME"
echo "  bash install_user.sh"
