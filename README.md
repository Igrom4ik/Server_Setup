# Server Setup (Двухэтапная установка)

Этот репозиторий содержит автоматизацию базовой безопасной подготовки сервера (root этап) и пользовательской настройки (user этап) + опциональные компоненты (Gitea в двух вариантах: бинарь и Docker Compose).

---
## 🚀 Быстрый старт (удалённый запуск из GitHub)

### Этап 1 (root)
На чистом сервере под root (или через sudo):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_root.sh)
```
Альтернатива (wget):
```bash
wget -qO- https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_root.sh | bash
```

### Этап 2 (user)
После завершения этапа 1 скрипт напечатает имя созданного пользователя. Переходим под него и запускаем второй этап (можно тоже удалённо):
```bash
su - <username>
curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_user.sh -o install_user.sh
bash install_user.sh
```
Или в одну строку (осознанно — меньше прозрачности):
```bash
su - <username> -c 'bash <(curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_user.sh)'
```

### 💡 Закрепление версии (безопаснее)
Чтобы защититься от внезапных изменений, можно указать конкретный хэш коммита:
```bash
COMMIT=<hash>
bash <(curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/$COMMIT/install_root.sh)
```
Найдите нужный хэш на странице коммитов репозитория.

---
## 📂 Что делает root этап
- Загружает/валидирует `config.json`
- Создаёт пользователя и его `authorized_keys`
- Настраивает sudo / polkit / passwordless при необходимости
- Жёстко настраивает SSH (основной порт + дублирование 22 при политике dual-port)
- Настраивает базовые security пакеты (частично)
- Скачивает `install_user.sh` в домашний каталог пользователя

После выполнения:
```bash
su - <username>
./install_user.sh
```

---
## 👤 Что делает user этап (`install_user.sh`)
- Доводит SSH настройки (порт, root login, password auth)
- Устанавливает и настраивает: ufw, fail2ban, rkhunter (timer), psad, nmap
- Настраивает Docker + Portainer
- (Опционально) Netdata мониторинг
- Telegram бот (команды) + PAM-уведомления о SSH входах
- Логирование iptables для psad
- Cron / systemd timers (security check, weekly update)
- Финальный чеклист (в Telegram)

Повторный запуск пропускает уже завершённые шаги через state-файлы: `~/.local/share/server_setup_state/`.

---
## ⚙️ config.json
Хранится в `/etc/server_setup/config.json` (+ совместимый symlink `/usr/local/bin/config.json`).
Пример (фрагмент):
```json
{
	"username": "deploy",
	"port": 5075,
	"sudo_nopasswd": true,
	"monitoring_enabled": true,
	"services": { "ufw": true, "fail2ban": true, "psad": true, "rkhunter": true, "nmap": false },
	"telegram_bot_token": "123:ABC",
	"telegram_chat_id": "0000000",
	"psad_auto_ids_regex": "Y",
	"gitea": { "http_port": 3000, "ssh_port": 2222, "image": "gitea/gitea:1.22-rootless" }
}
```

---
## 🔐 Безопасность
- Рекомендуется держать BOT_TOKEN / CHAT_ID вне основного конфига (например, `root:root 600`) и подставлять при запуске.
- Пересмотрите необходимость `sudo_nopasswd=true` (расширяет поверхность атак).
- Для production фиксируйте хэш коммита при удалённом запуске.

---
## ♻️ Повторный прогон / очистка state
Удалите отдельные файлы в `~/.local/share/server_setup_state/` либо весь каталог — нужные шаги выполнятся снова.

---
## 🧩 Gitea (варианты установки)

### 1. Бинарный (systemd) — `install_gitea.sh`
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_gitea.sh)
```
Особенности:
- Скачивает последний релиз (или `GITEA_VERSION=1.22.3` для фиксации)
- Создаёт пользователя `gitea`, systemd unit `gitea.service`
- Данные: `/var/lib/gitea`  | Конфиг: `/etc/gitea/app.ini`
- Повторный запуск безопасен (state-файл `/var/lib/server_setup/10.gitea.installed`)

### 2. Docker Compose — `install_gitea_compose.sh`
```bash
curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_gitea_compose.sh -o install_gitea_compose.sh
bash install_gitea_compose.sh
```
Или одномоментно:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_gitea_compose.sh)
```
Параметры читаются из `config.json` секции `gitea` (порты, образ, domain, root_url, опционально DB). Данные по умолчанию: `~/gitea/data`.
Резервная копия данных:
```bash
bash install_gitea_compose.sh backup
```

---
## 🛠️ Кратко про `install_gitea.sh`
Выполняет:
- Определение последней версии через GitHub API (или fallback)
- Создание системного пользователя `gitea`
- Скачивание бинаря в `/usr/local/bin/gitea`
- Создание каталогов `/var/lib/gitea/{data,log,custom}` и `/etc/gitea/app.ini`
- Настройку systemd unit `gitea.service`
- (Опционально) capability на прослушивание портов <1024

После установки: открыть `http://<ip>:3000` и завершить первичную настройку.

---
## ✅ Итог
1. Root этап (удалённо через curl) → создаёт пользователя и базовую защиту.
2. User этап → расширяет защиту и сервисы.
3. (Опционально) Gitea: бинарь или Docker Compose.

При необходимости — закрепляйте версию на коммите и изучайте скрипт перед запуском.