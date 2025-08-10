#!/usr/bin/env bash
# install_gitea.sh - Опциональная установка Gitea (self-hosted Git) на Ubuntu/Debian
# Идемпотентный: повторный запуск не переустанавливает при наличии state-файла.
# Можно переопределить версии через переменную окружения GITEA_VERSION.
# Пример запуска:
#   sudo bash install_gitea.sh
#   GITEA_VERSION=1.22.3 sudo bash install_gitea.sh
# После установки откройте http://<IP>:3000 для первичной настройки.

set -euo pipefail
IFS=$'\n\t'

STATE_DIR="/var/lib/server_setup"
STATE_FILE="$STATE_DIR/10.gitea.installed"
mkdir -p "$STATE_DIR"

log(){ printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail(){ log "❌ $*"; exit 1; }

need_root(){ [[ $EUID -eq 0 ]] || fail "Запустите от root (sudo)."; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || fail "Нужна команда: $1"; }

need_root
for c in curl jq tar; do
  if ! command -v "$c" >/dev/null 2>&1; then
    log "📦 Устанавливаю пакет для: $c"
    apt-get update -y >/dev/null
    apt-get install -y curl jq tar ca-certificates >/dev/null || fail "Не удалось установить зависимости"
    break
  fi
done

GITEA_USER="gitea"
GITEA_GROUP="gitea"
GITEA_HOME="/var/lib/gitea"
GITEA_CUSTOM="${GITEA_HOME}/custom"
GITEA_DATA="${GITEA_HOME}/data"
GITEA_LOG="${GITEA_HOME}/log"
GITEA_ETC="/etc/gitea"
GITEA_BIN="/usr/local/bin/gitea"
GITEA_SERVICE="/etc/systemd/system/gitea.service"

VERSION="${GITEA_VERSION:-}"
FALLBACK_VERSION="1.22.3"

if [[ -f "$STATE_FILE" ]]; then
  log "⏩ Gitea уже установлена (state). Для переустановки удалите $STATE_FILE и бинарь $GITEA_BIN"
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  log "🔍 Получаю последнюю стабильную версию Gitea через GitHub API"
  VERSION=$(curl -fsSL https://api.github.com/repos/go-gitea/gitea/releases/latest | jq -r '.tag_name' || true)
  VERSION=${VERSION#v}
  if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
    VERSION="$FALLBACK_VERSION"
    log "⚠️ Не удалось получить версию через API — использую fallback $VERSION"
  else
    log "➡️ Используется версия $VERSION"
  fi
else
  VERSION=${VERSION#v}
  log "➡️ Используется заданная версия $VERSION"
fi

ARCH="linux-amd64"
URL="https://dl.gitea.io/gitea/${VERSION}/gitea-${VERSION}-${ARCH}"
TMP_BIN="/tmp/gitea-${VERSION}-${ARCH}"

log "⬇️ Скачиваю Gitea: $URL"
curl -fsSL "$URL" -o "$TMP_BIN" || fail "Не удалось скачать бинарь Gitea"
chmod +x "$TMP_BIN"

if id "$GITEA_USER" >/dev/null 2>&1; then
  log "ℹ️ Пользователь $GITEA_USER уже существует"
else
  log "👤 Создаю системного пользователя $GITEA_USER"
  adduser --system --group --home "$GITEA_HOME" --shell /bin/bash "$GITEA_USER" || fail "Не удалось создать пользователя"
fi

log "📁 Создаю каталоги"
install -d -o "$GITEA_USER" -g "$GITEA_GROUP" -m 750 "$GITEA_HOME" "$GITEA_CUSTOM" "$GITEA_DATA" "$GITEA_LOG"
install -d -o root -g "$GITEA_GROUP" -m 770 "$GITEA_ETC"

log "🚚 Перемещаю бинарь в $GITEA_BIN"
mv "$TMP_BIN" "$GITEA_BIN"
chown root:root "$GITEA_BIN"
chmod 0755 "$GITEA_BIN"

# Возможность слушать порт <1024> (если понадобится)
if command -v setcap >/dev/null 2>&1; then
  setcap 'cap_net_bind_service=+ep' "$GITEA_BIN" || log "⚠️ setcap не применён (не критично)"
else
  apt-get install -y libcap2-bin >/dev/null 2>&1 || true
  command -v setcap >/dev/null 2>&1 && setcap 'cap_net_bind_service=+ep' "$GITEA_BIN" || true
fi

APP_INI="$GITEA_ETC/app.ini"
if [[ ! -f "$APP_INI" ]]; then
  log "📝 Создаю базовый app.ini"
  cat >"$APP_INI" <<EOF
[server]
APP_NAME = Gitea
RUN_MODE = prod
DOMAIN = localhost
ROOT_URL = http://localhost:3000/
HTTP_PORT = 3000
SSH_PORT = 22
DISABLE_SSH = false
START_SSH_SERVER = false
LFS_START_SERVER = true
LFS_CONTENT_PATH = ${GITEA_DATA}/lfs

[database]
; Будет настроено через web UI при первом запуске.
DB_TYPE = sqlite3
PATH = ${GITEA_DATA}/gitea.db

[log]
MODE = file
LEVEL = Info
ROOT_PATH = ${GITEA_LOG}
EOF
fi

chown -R "$GITEA_USER:$GITEA_GROUP" "$GITEA_HOME" "$GITEA_ETC"
chmod -R 750 "$GITEA_HOME"
chmod 640 "$APP_INI"
chmod 770 "$GITEA_ETC"

log "🛠️ Создаю systemd unit"
cat >"$GITEA_SERVICE" <<'EOF'
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target
Requires=network.target

[Service]
Type=simple
User=gitea
Group=gitea
WorkingDirectory=/var/lib/gitea
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
RestartSec=5s
Environment=USER=gitea HOME=/var/lib/gitea GITEA_WORK_DIR=/var/lib/gitea
# Более высокие лимиты файлов
LimitNOFILE=1048576
LimitNPROC=1048576
# Безопасность
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

log "🔄 Перезагружаю systemd и запускаю сервис"
systemctl daemon-reload
systemctl enable --now gitea.service || fail "Не удалось запустить gitea.service"

sleep 2
if systemctl is-active --quiet gitea.service; then
  log "✅ Gitea запущена"
else
  journalctl -u gitea --no-pager | tail -n 50 >&2 || true
  fail "Gitea не активна"
fi

echo "Версия: $VERSION" > "$STATE_FILE"
log "📌 State записан: $STATE_FILE"

log "🎉 Установка завершена. Откройте http://<IP_АДРЕС>:3000 для настройки через Web UI."
log "При необходимости поменяйте ROOT_URL и HTTP_PORT в $APP_INI и перезапустите: systemctl restart gitea"
