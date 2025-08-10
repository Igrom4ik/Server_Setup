#!/bin/bash
set -euo pipefail

# =====================
# Базовые настройки
# =====================
GITEA_DIR="${GITEA_DIR:-$HOME/gitea}"  # можно переопределить извне
HTTP_PORT="${HTTP_PORT:-3000}"
SSH_PORT="${SSH_PORT:-222}"

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

# =====================
# Подготовка каталога
# =====================
mkdir -p "$GITEA_DIR"
cd "$GITEA_DIR"

# =====================
# Генерация docker-compose.yml
# =====================
cat > docker-compose.yml <<EOF
version: "3"

networks:
  gitea:
    external: false

services:
  server:
    image: gitea/gitea:latest
    container_name: gitea
    environment:
      - USER_UID=1000
      - USER_GID=1000
    restart: always
    networks:
      - gitea
    volumes:
      - ./gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${HTTP_PORT}:3000"
      - "${SSH_PORT}:22"
EOF

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
docker compose pull server >/dev/null 2>&1 || true
docker compose up -d

IP=$(hostname -I | awk '{print $1}')
echo "✅ Gitea работает."
echo "🌐 Web:  http://$IP:${HTTP_PORT}"
echo "🔑 Git SSH порт: ${SSH_PORT} (ssh://git@<host>:${SSH_PORT}/<owner>/<repo>.git)"

if [[ ${EUID} -ne 0 ]]; then
  echo "ℹ️ Если требуются bind-порты <1024 или управление системой — перезапустите скрипт от root."
fi
