#!/bin/bash
set -e

# === Настройки ===
GITEA_DIR="$HOME/gitea"
HTTP_PORT=3000
SSH_PORT=222

# === Проверка прав ===
if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Скрипт нужно запускать от root: sudo $0"
    exit 1
fi

# === Установка Docker и Compose ===
if ! command -v docker >/dev/null 2>&1; then
    echo "📦 Устанавливаю Docker..."
    apt update
    apt install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
fi

# === Создание папки для Gitea ===
mkdir -p "$GITEA_DIR"
cd "$GITEA_DIR"

# === docker-compose.yml ===
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

# === Открытие портов (если UFW включён) ===
if command -v ufw >/dev/null 2>&1; then
    echo "🔓 Открываю порты ${HTTP_PORT} и ${SSH_PORT}..."
    ufw allow ${HTTP_PORT}/tcp
    ufw allow ${SSH_PORT}/tcp
fi

# === Запуск Gitea ===
echo "🚀 Запускаю Gitea..."
docker compose up -d

IP=$(hostname -I | awk '{print $1}')
echo "✅ Gitea установлена и запущена."
echo "🌐 Веб-интерфейс: http://$IP:${HTTP_PORT}"
echo "🔑 SSH-доступ к репозиториям: порт ${SSH_PORT}"
