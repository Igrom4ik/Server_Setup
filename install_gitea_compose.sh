#!/bin/bash
set -euo pipefail

#############################################
# Gitea (docker compose) installer
# Опционально: PostgreSQL, Caddy reverse proxy
# Автор: (refactored)
#############################################

### Defaults (can be overridden by environment) ###
GITEA_DIR="${GITEA_DIR:-$HOME/gitea}"
HTTP_PORT="${HTTP_PORT:-3000}"
SSH_PORT="${SSH_PORT:-2222}"              # external SSH (host) port
INTERNAL_SSH_PORT="${INTERNAL_SSH_PORT:-22}" # inside container
GIT_SSH_ENABLED=${GIT_SSH_ENABLED:-true}
DB_ENABLED=${DB_ENABLED:-true}
CADDY_ENABLED=${CADDY_ENABLED:-true}
PURGE_EXISTING=${PURGE_EXISTING:-true}
SELF_DELETE=${SELF_DELETE:-false}

GITEA_IMAGE="${GITEA_IMAGE:-gitea/gitea:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15-alpine}"

DB_NAME="${DB_NAME:-gitea}"
DB_USER="${DB_USER:-gitea}"
DB_PASSWD="${DB_PASSWD:-}"

GITEA_DOMAIN="${GITEA_DOMAIN:-$(hostname -f 2>/dev/null || hostname)}"
ROOT_URL="${ROOT_URL:-https://${GITEA_DOMAIN}}"

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DB_PASS_FILE="${GITEA_DIR}/secret_db_password"
GENERATED_DB_PASS=false

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --no-purge            Не удалять предыдущие контейнеры (по умолчанию удаляем)
  --purge               Принудительно удалить предыдущие контейнеры
  --no-ssh              Отключить SSH (не публиковать порт, disable internal server)
  --internal-ssh-port=N Внутренний ssh порт в контейнере (default: 22)
  --no-db               Использовать встроенную sqlite БД вместо Postgres
  --no-caddy            Не запускать Caddy; пробросить HTTP порт напрямую
  --db-pass=PWD         Пароль Postgres (если не указан — будет сгенерирован)
  --domain=NAME         Домен (авто ROOT_URL = https://NAME)
  --root-url=URL        Явно указать ROOT_URL
  --self-delete|--rm-self  Удалить скрипт после успешного запуска
  -h, --help            Показать эту справку

Environment overrides: GITEA_DIR HTTP_PORT SSH_PORT DB_NAME DB_USER DB_PASSWD GITEA_IMAGE POSTGRES_IMAGE
EOF
}

### Parse arguments ###
for arg in "$@"; do
  case "$arg" in
    --no-purge) PURGE_EXISTING=false ;;
    --purge) PURGE_EXISTING=true ;;
    --no-ssh) GIT_SSH_ENABLED=false ;;
    --internal-ssh-port=*) INTERNAL_SSH_PORT="${arg#*=}" ;;
    --no-db) DB_ENABLED=false ;;
    --no-caddy) CADDY_ENABLED=false ;;
    --db-pass=*) DB_PASSWD="${arg#*=}" ;;
    --domain=*) GITEA_DOMAIN="${arg#*=}"; ROOT_URL="https://${GITEA_DOMAIN}" ;;
    --root-url=*) ROOT_URL="${arg#*=}" ;;
    --self-delete|--rm-self) SELF_DELETE=true ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; show_help; exit 1 ;;
  esac
done

### Re-evaluate ROOT_URL if domain changed earlier via env only ###
if [[ -z "${ROOT_URL}" ]]; then
  ROOT_URL="https://${GITEA_DOMAIN}"
fi

### Generate / load DB password if needed ###
if ${DB_ENABLED} && [[ -z "$DB_PASSWD" ]]; then
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

### sudo helper ###
if [[ ${EUID} -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

### Docker install (Debian/Ubuntu) if missing ###
install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then return 0; fi
  if [[ ${EUID} -ne 0 ]]; then
    echo "❌ Docker не найден и нет root прав. Запустите: sudo $0" >&2; exit 1
  fi
  echo "📦 Устанавливаю Docker..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  echo "✅ Docker установлен"
}
install_docker_if_needed

### Compose plugin check ###
if ! docker compose version >/dev/null 2>&1; then
  echo "❌ Docker Compose plugin не найден." >&2; exit 1
fi

### Determine docker command (with sudo fallback) ###
if docker info >/dev/null 2>&1; then
  DOCKER_CMD="docker"
elif $SUDO docker info >/dev/null 2>&1; then
  DOCKER_CMD="$SUDO docker"
else
  echo "❌ Нет доступа к docker." >&2; exit 1
fi

### Port validation ###
if ${GIT_SSH_ENABLED}; then
  if ! [[ "$INTERNAL_SSH_PORT" =~ ^[0-9]+$ ]] || (( INTERNAL_SSH_PORT < 22 || INTERNAL_SSH_PORT > 65535 )); then
    echo "❌ Некорректный INTERNAL_SSH_PORT=$INTERNAL_SSH_PORT" >&2; exit 1
  fi
  for fp in 22 5075 222; do
    if [[ "$SSH_PORT" == "$fp" ]]; then
      echo "❌ Запрещён SSH_PORT=$SSH_PORT. Выберите другой (напр. 2222, 3022)." >&2; exit 1
    fi
  done
fi

### Cleanup old containers/network ###
cleanup_existing() {
  local removed=0
  local c_ids
  c_ids=$($DOCKER_CMD ps -a --format '{{.ID}} {{.Image}} {{.Names}}' | awk '/gitea\/gitea|gitea$/{print $1}') || true
  if [[ -n "$c_ids" ]]; then
    echo "🧹 Удаляю старые контейнеры Gitea..."
    while read -r cid; do
      [[ -z "$cid" ]] && continue
      $DOCKER_CMD rm -f "$cid" >/dev/null 2>&1 && removed=1 || true
    done <<<"$c_ids"
  fi
  for net in gitea_gitea gitea_net; do
    if $DOCKER_CMD network ls --format '{{.Name}}' | grep -qx "$net"; then
      $DOCKER_CMD network rm "$net" >/dev/null 2>&1 || true
    fi
  done
  [[ $removed -eq 1 ]] && echo "✅ Старые контейнеры удалены" || echo "ℹ️ Старых контейнеров не найдено"
}
if ${PURGE_EXISTING}; then cleanup_existing; else echo "ℹ️ Пропуск очистки (--no-purge)"; fi

### Prepare directory ###
mkdir -p "$GITEA_DIR" && cd "$GITEA_DIR"

### SSH env block ###
if ${GIT_SSH_ENABLED}; then
  ENV_SSH_BLOCK="      - GITEA__server__START_SSH_SERVER=true\n      - GITEA__server__SSH_PORT=${INTERNAL_SSH_PORT}"
  SSH_PORT_MAPPING="      - \"${SSH_PORT}:${INTERNAL_SSH_PORT}\""
else
  ENV_SSH_BLOCK="      - GITEA__server__DISABLE_SSH=true"
  SSH_PORT_MAPPING=""
fi

### DB env & service blocks ###
if ${DB_ENABLED}; then
  ENV_DB_BLOCK=$(cat <<EOF
      - DB_TYPE=postgres
      - DB_HOST=gitea-db:5432
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWD=${DB_PASSWD}
EOF
  )
  SERVICE_DB_BLOCK=$(cat <<EOF
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
EOF
  )
  DEPENDS_DB_BLOCK="      gitea-db:\n        condition: service_healthy"
else
  ENV_DB_BLOCK="      - DB_TYPE=sqlite3"
  SERVICE_DB_BLOCK=""
  DEPENDS_DB_BLOCK=""
fi

### Caddy service block ###
if ${CADDY_ENABLED}; then
  SERVICE_CADDY_BLOCK=$(cat <<EOF
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
EOF
  )
  EXPOSE_HTTP_BLOCK="    expose:\n      - ${HTTP_PORT}"
else
  SERVICE_CADDY_BLOCK=""
  EXPOSE_HTTP_BLOCK=""
fi

### Ports block for gitea ###
PORTS_BLOCK=""
if ! ${CADDY_ENABLED}; then
  PORTS_BLOCK+="      - \"${HTTP_PORT}:${HTTP_PORT}\"\n"
fi
if ${GIT_SSH_ENABLED}; then
  PORTS_BLOCK+="${SSH_PORT_MAPPING}\n"
fi
if [[ -n "$PORTS_BLOCK" ]]; then
  PORTS_BLOCK="    ports:\n${PORTS_BLOCK%\\n}"
fi

### Write docker-compose.yml ###
cat > docker-compose.yml <<EOF
version: "3.9"
networks:
  gitea:
    driver: bridge

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
      - GITEA__server__HTTP_PORT=${HTTP_PORT}
    volumes:
      - ./gitea-data:/data
    restart: always
    healthcheck:
      test: ["CMD-SHELL","wget -q -O /dev/null http://localhost:${HTTP_PORT}/api/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
    depends_on:
${DEPENDS_DB_BLOCK:-      }
    networks:
      - gitea
${PORTS_BLOCK}
${EXPOSE_HTTP_BLOCK}
${SERVICE_DB_BLOCK}
${SERVICE_CADDY_BLOCK}

volumes:
  gitea-data:
  gitea-db:
  caddy_data:
  caddy_config:

networks:
  gitea:
    external: false
EOF

### Generate Caddyfile if needed ###
if ${CADDY_ENABLED}; then
  cat > Caddyfile <<EOF
${GITEA_DOMAIN} {
  encode gzip
  reverse_proxy gitea:${HTTP_PORT}
}
EOF
fi

echo "📝 docker-compose.yml создан"

### Run containers ###
echo "🚀 Запускаю (обновляю) Gitea контейнер..."
$DOCKER_CMD compose pull >/dev/null 2>&1 || true
$DOCKER_CMD compose up -d

IP=$(hostname -I | awk '{print $1}') || IP="localhost"
echo "✅ Gitea работает."
if ${CADDY_ENABLED}; then
  echo "🌐 Web (via Caddy):  ${ROOT_URL}"
else
  echo "🌐 Web:  http://${IP}:${HTTP_PORT}"
fi
if ${GIT_SSH_ENABLED}; then
  echo "🔑 Git SSH: ssh://git@${GITEA_DOMAIN}:${SSH_PORT}/<owner>/<repo>.git"
fi
if ${DB_ENABLED} && ${GENERATED_DB_PASS}; then
  echo "🔐 Пароль БД (также сохранён в ${DB_PASS_FILE}): ${DB_PASSWD}"
fi

if ${SELF_DELETE}; then
  if [[ "$SCRIPT_PATH" =~ ^/dev/fd/ ]]; then
    echo "ℹ️ Скрипт запущен не с файловой системы — пропуск удаления"
  else
    echo "🧹 Удаляю скрипт $SCRIPT_PATH"; rm -f -- "$SCRIPT_PATH" || echo "⚠️ Не удалось удалить $SCRIPT_PATH" >&2
  fi
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "ℹ️ Для привязки к портам <1024 перезапустите от root"
fi
