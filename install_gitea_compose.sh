#!/bin/bash
set -euo pipefail

# =====================
# Базовые настройки
# =====================
GITEA_DIR="${GITEA_DIR:-$HOME/gitea}"  # базовый рабочий каталог
HTTP_PORT="${HTTP_PORT:-3000}"          # внутренний HTTP порт Gitea
SSH_PORT="${SSH_PORT:-2222}"            # внешний SSH порт Git
GITEA_DOMAIN="${GITEA_DOMAIN:-$(hostname -f 2>/dev/null || hostname)}"
ROOT_URL="${ROOT_URL:-https://${GITEA_DOMAIN}}"
DB_ENABLED=true
CADDY_ENABLED=true
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:14}"
GITEA_IMAGE="${GITEA_IMAGE:-gitea/gitea:latest}"
DB_NAME="${DB_NAME:-gitea}"
DB_USER="${DB_USER:-gitea}"
DB_PASSWD="${DB_PASSWD:-}"

# =====================
# Аргументы
# =====================
SELF_DELETE=false
SHOW_HELP=false
PURGE_EXISTING=true
GIT_SSH_ENABLED=true
INTERNAL_SSH_PORT="${INTERNAL_SSH_PORT:-22}"  # внутренний порт ssh в контейнере
for arg in "$@"; do
  case "$arg" in
    --self-delete|--rm-self)
      SELF_DELETE=true
      ;;
    --no-purge)
      PURGE_EXISTING=false
      ;;
      --no-ssh)
        GIT_SSH_ENABLED=false
        ;;
    --internal-ssh-port=*)
      INTERNAL_SSH_PORT="${arg#*=}"
      ;;
    --no-db)
      DB_ENABLED=false
      ;;
    --no-caddy)
      CADDY_ENABLED=false
      ;;
    --db-pass=*)
      DB_PASSWD="${arg#*=}"
      ;;
    --domain=*)
      GITEA_DOMAIN="${arg#*=}"; ROOT_URL="https://${GITEA_DOMAIN}";
      ;;
    --root-url=*)
      ROOT_URL="${arg#*=}"
      ;;
    --purge)
      PURGE_EXISTING=true
      ;;
    -h|--help)
      SHOW_HELP=true
      ;;
    *)
      echo "Неизвестный аргумент: $arg" >&2; SHOW_HELP=true ;;
  esac
done

if $SHOW_HELP; then
  cat <<USAGE
Usage: ${0##*/} [--self-delete] [--no-purge|--purge] [--no-ssh] [--internal-ssh-port=N] [--no-db] [--no-caddy] [--db-pass=PWD] [--domain=NAME] [--root-url=URL]

Options:
  --self-delete   Удалить файл скрипта после успешного деплоя (игнорируется если запущен через process substitution)
  --no-purge            Не удалять существующие контейнеры/сети gitea перед запуском
  --purge               (По умолчанию) Удалить старые контейнеры gitea
  --no-ssh              Отключить SSH доступ к репозиториям (не публиковать порт)
  --internal-ssh-port=N Внутренний порт ssh в контейнере (по умолчанию 22)
  --no-db               Без PostgreSQL (sqlite внутри /data)
  --no-caddy            Без Caddy reverse proxy
  --db-pass=PWD         Пароль Postgres (если не задан — генерируется)
  --domain=NAME         Домен для ROOT_URL (авто https://NAME)
  --root-url=URL        Явно указать ROOT_URL
  -h, --help      Показать эту справку

Переменные окружения (override): GITEA_DIR HTTP_PORT SSH_PORT
USAGE
  exit 0
fi
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

DB_PASS_FILE="${GITEA_DIR}/secret_db_password"
GENERATED_DB_PASS=false

# Генерация/загрузка пароля для БД если включен Postgres и пароль не передан
if $DB_ENABLED && [[ -z "$DB_PASSWD" ]]; then
  if [[ -f "$DB_PASS_FILE" ]]; then
    DB_PASSWD=$(<"$DB_PASS_FILE")
  else
    mkdir -p "$GITEA_DIR"
    if command -v openssl >/dev/null 2>&1; then
      DB_PASSWD=$(openssl rand -base64 18 | tr -d '=+/ ' | cut -c1-24)
    else
      DB_PASSWD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c24)
    fi
    echo "$DB_PASSWD" > "$DB_PASS_FILE"
    chmod 600 "$DB_PASS_FILE" 2>/dev/null || true
    GENERATED_DB_PASS=true
  fi
fi

# =====================
# Привилегии / sudo
# =====================
if [[ ${EUID} -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

# =====================
# Проверка docker
# =====================
install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  if [[ ${EUID} -ne 0 ]]; then
    echo "❌ Docker не установлен и нет root прав. Запустите: sudo $0" >&2
    exit 1
  fi
  echo "📦 Устанавливаю Docker (требуются root права)..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  echo "✅ Docker установлен"
}

install_docker_if_needed

# Проверка доступа к docker (если не root)
if [[ ${EUID} -ne 0 ]]; then
  if ! groups "$USER" | grep -q '\bdocker\b'; then
    if ! $SUDO docker info >/dev/null 2>&1; then
      echo "⚠️ Пользователь не в группе docker. Добавить: sudo usermod -aG docker $USER && newgrp docker" >&2
    fi
  fi
fi

# Проверяем наличие compose plugin
if ! docker compose version >/dev/null 2>&1; then
  echo "❌ Docker Compose plugin не найден. Установите Docker >= 20.10." >&2
  exit 1
fi

# Определяем команду docker (fallback на sudo если сокет недоступен)
if docker info >/dev/null 2>&1; then
  DOCKER_CMD="docker"
elif $SUDO docker info >/dev/null 2>&1; then
  DOCKER_CMD="$SUDO docker"
else
  echo "❌ Нет доступа к docker (даже через sudo)." >&2; exit 1
fi

# =====================
# Валидация порта SSH для Gitea
# =====================
FORBIDDEN_SSH_HOST_PORTS="22 5075 222"
for fp in $FORBIDDEN_SSH_HOST_PORTS; do
  if [[ "$SSH_PORT" == "$fp" ]]; then
    echo "❌ Нельзя использовать SSH_PORT=$SSH_PORT (запрещён / конфликтует). Выберите другой (например 2222, 3022)." >&2
    exit 1
  fi
done
if $GIT_SSH_ENABLED; then
  FORBIDDEN_SSH_HOST_PORTS="22 5075 222"
  for fp in $FORBIDDEN_SSH_HOST_PORTS; do
    if [[ "$SSH_PORT" == "$fp" ]]; then
      echo "❌ Нельзя использовать SSH_PORT=$SSH_PORT (запрещён / конфликтует). Выберите другой (например 2222, 3022)." >&2
      exit 1
    fi
  done
  if ! [[ "$INTERNAL_SSH_PORT" =~ ^[0-9]+$ ]] || (( INTERNAL_SSH_PORT < 22 || INTERNAL_SSH_PORT > 65535 )); then
    echo "❌ Некорректный INTERNAL_SSH_PORT=$INTERNAL_SSH_PORT" >&2; exit 1
  fi
fi

# =====================
# Очистка предыдущих экземпляров Gitea (контейнер / сеть)
# =====================
cleanup_existing() {
  local removed=0
  # Ищем контейнеры по имени gitea или по образу содержащему gitea/gitea
  local c_ids
  c_ids=$($DOCKER_CMD ps -a --format '{{.ID}} {{.Image}} {{.Names}}' | awk '/gitea\/gitea|gitea$/{print $1}') || true
  if [[ -n "$c_ids" ]]; then
    echo "🧹 Удаляю старые контейнеры Gitea..."
    while read -r cid; do
      [[ -z "$cid" ]] && continue
      $DOCKER_CMD rm -f "$cid" >/dev/null 2>&1 && removed=1 || true
    done <<<"$c_ids"
  fi
  # Удаляем зависшую сеть gitea_gitea (старый формат) или gitea_net
  for net in gitea_gitea gitea_net; do
    if $DOCKER_CMD network ls --format '{{.Name}}' | grep -qx "$net"; then
      $DOCKER_CMD network rm "$net" >/dev/null 2>&1 || true
    fi
  done
  [[ $removed -eq 1 ]] && echo "✅ Старые контейнеры удалены" || echo "ℹ️ Старых контейнеров Gitea не найдено"
}

if $PURGE_EXISTING; then
  cleanup_existing
else
  echo "ℹ️ Пропуск очистки старых контейнеров (--no-purge)"
fi

# =====================
# Подготовка каталога
# =====================
mkdir -p "$GITEA_DIR"
cd "$GITEA_DIR"

# =====================
# Генерация docker-compose.yml (Gitea + optional Postgres + Caddy)
# =====================

# SSH публикация/переменные
if $GIT_SSH_ENABLED; then
  SSH_PORTS_LINE="      - \"${SSH_PORT}:${INTERNAL_SSH_PORT}\""
  read -r -d '' ENV_SSH_BLOCK <<'EOF_ENV_SSH'
      - GITEA__server__START_SSH_SERVER=true
EOF_ENV_SSH
else
  SSH_PORTS_LINE=""
  read -r -d '' ENV_SSH_BLOCK <<'EOF_ENV_SSH'
      - GITEA__server__DISABLE_SSH=true
EOF_ENV_SSH
fi

# DB блок
if $DB_ENABLED; then
  read -r -d '' ENV_DB_BLOCK <<EOF_ENV_DB
      - DB_TYPE=postgres
      - DB_HOST=gitea-db:5432
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWD=${DB_PASSWD}
EOF_ENV_DB

  read -r -d '' SERVICE_DB_BLOCK <<EOF_DB_SVC
  gitea-db:
    image: ${POSTGRES_IMAGE}
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWD}
    volumes:
      - ./gitea-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: always
EOF_DB_SVC

  DEPENDS_DB_BLOCK="      gitea-db:
        condition: service_healthy
        required: true"
else
  read -r -d '' ENV_DB_BLOCK <<'EOF_ENV_DB'
      - DB_TYPE=sqlite3
EOF_ENV_DB
  SERVICE_DB_BLOCK=""
  DEPENDS_DB_BLOCK=""
fi

# HTTP публикация/проброс
if $CADDY_ENABLED; then
  EXPOSE_HTTP_BLOCK="    expose:
      - \"${HTTP_PORT}\""
  read -r -d '' SERVICE_CADDY_BLOCK <<'EOF_CADDY'
  caddy:
    image: caddy:latest
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    restart: always
    depends_on:
      gitea:
        condition: service_started
EOF_CADDY
else
  EXPOSE_HTTP_BLOCK=""
  # если нет caddy — пробрасываем HTTP наружу в общий блок ports
fi

# Собираем единый блок ports для gitea
PORTS_BLOCK=""

# HTTP наружу — только если Caddy отключён
if ! $CADDY_ENABLED; then
  PORTS_BLOCK="${PORTS_BLOCK}      - \"${HTTP_PORT}:${HTTP_PORT}\"\n"
fi

# SSH наружу — если включён
if $GIT_SSH_ENABLED; then
  PORTS_BLOCK="${PORTS_BLOCK}${SSH_PORTS_LINE}\n"
fi

# Если что-то накопили — завернём в ports:
if [[ -n "$PORTS_BLOCK" ]]; then
  PORTS_BLOCK="    ports:\n${PORTS_BLOCK%\\n}"
fi

# Пишем docker-compose.yml
cat > docker-compose.yml <<EOF
networks:
  gitea:
    external: false

services:
  gitea:
    image: ${GITEA_IMAGE}
    container_name: gitea
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__server__DOMAIN=${GITEA_DOMAIN}
      - GITEA__server__ROOT_URL=${ROOT_URL}
${ENV_SSH_BLOCK}
${ENV_DB_BLOCK}
      - GITEA__security__INSTALL_LOCK=false
    volumes:
      - ./gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    restart: always
    healthcheck:
      test: ["CMD-SHELL","wget -q -O /dev/null http://localhost:${HTTP_PORT}/api/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    depends_on:
${DEPENDS_DB_BLOCK}
${EXPOSE_HTTP_BLOCK}
${PORTS_BLOCK}
${SERVICE_DB_BLOCK}
${SERVICE_CADDY_BLOCK}

volumes:
  caddy_data:
  caddy_config:
EOF

# Генерируем Caddyfile при необходимости
if $CADDY_ENABLED && [[ ! -f Caddyfile ]]; then
  cat > Caddyfile <<CADDYFILE
${GITEA_DOMAIN} {
  encode gzip
  reverse_proxy gitea:${HTTP_PORT}
}
CADDYFILE
fi

# =====================
# Открытие портов (если UFW включён) — не критично при отсутствии прав
# =====================
if command -v ufw >/dev/null 2>&1; then
  if $SUDO ufw status >/dev/null 2>&1; then
    echo "🔓 Открываю порты ${HTTP_PORT} и ${SSH_PORT} (ufw)";
    $SUDO ufw allow ${HTTP_PORT}/tcp || true
    $SUDO ufw allow ${SSH_PORT}/tcp || true
  fi
fi

# =====================
# Запуск / обновление контейнера
# =====================
echo "🚀 Запускаю (обновляю) Gitea контейнер..."
$DOCKER_CMD compose pull >/dev/null 2>&1 || true
$DOCKER_CMD compose up -d

IP=$(hostname -I | awk '{print $1}')
echo "✅ Gitea работает."
if $CADDY_ENABLED; then
  echo "🌐 Web (via Caddy):  ${ROOT_URL}"
else
  echo "🌐 Web:  http://$IP:${HTTP_PORT}"
fi
if $GIT_SSH_ENABLED; then
  echo "🔑 Git SSH порт: ${SSH_PORT} (ssh://git@${GITEA_DOMAIN}:${SSH_PORT}/<owner>/<repo>.git)"
fi
if $DB_ENABLED && $GENERATED_DB_PASS; then
  echo "🔐 Сгенерированный пароль БД: ${DB_PASSWD}" | sed 's/.*/& (сохраните его безопасно)/'
fi

if $SELF_DELETE; then
  if [[ "$SCRIPT_PATH" =~ ^/dev/fd/ ]]; then
    echo "ℹ️ Запущено из process substitution — удалять нечего"
  else
    echo "🧹 Удаляю скрипт: $SCRIPT_PATH"
    rm -f -- "$SCRIPT_PATH" || echo "⚠️ Не удалось удалить $SCRIPT_PATH" >&2
  fi
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "ℹ️ Если требуются bind-порты <1024 или управление системой — перезапустите скрипт от root."
fi
