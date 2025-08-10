# Server_Setup

Автоматическая настройка Linux-сервера в два этапа: создание пользователя, настройка SSH, защита, Telegram-бот, мониторинг Netdata и cron-задачи.

---

## 🚀 Установка (2 этапа)

### 🔹 Этап 1 — от имени `root`

```bash
curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_root.sh | sudo bash


```

**Что делает:**
- создаёт пользователя из `config.json`,
- копирует публичный SSH-ключ,
- настраивает порт SSH и `grub` (quiet mode),
- настраивает доступ по паролю для root (esli ukazano),
- завершает работу с инструкцией запуска второго этапа.

---

### 🔹 Этап 2 — от имени нового пользователя (\u043Dапр., `igrom`)

```bash
curl -fsSL https://raw.githubusercontent.com/Igrom4ik/Server_Setup/main/install_user.sh | sudo bash


```

**Что делает:**
- устанавливает и запускает Telegram-бота (c inline-кнопками),
- настраивает защиту (`ufw`, `fail2ban`, `psad`, `rkhunter`, `nmap`),
- устанавливает Docker, Portainer и Netdata,
- добавляет Telegram-уведомления о входах по SSH,
- создаёт cron-задачи (проверка, очистка, обновления),
- выводит чеклист и отсылает его в Telegram.

---

## 🔧 Структура проекта

| Файл                            | Назначение |
|-----------------------------------|-------------|
| `install_root.sh`                | Этап 1: от имени root |
| `install_user.sh`                | Этап 2: от пользователя |
| `telegram_command_listener.sh`   | Telegram-бот c командами |
| `config.json`                    | Конфигурация установки |
| `id_ed25519.pub`                 | Публичный SSH-ключ |

---

## 🔐 Защита

- **UFW** — портовый файрвол
- **Fail2Ban** — блокировка подбора паролей
- **PSAD** — сетевой интрудер-детектор
- **RKHunter** — поиск rootkit
- **Nmap** — диагностика сети
- **Telegram-бот**:
  - уведомления о SSH-входах
  - отчёты о защите (cron и /security)

---

## 📲 Telegram-бот

- Работает как `systemd`-сервис
- Инлайн-меню `/start`
- Команды:
  - `/uptime`, `/disk`, `/mem`, `/top`
  - `/ip`, `/who`, `/security`, `/update`
  - `/checklist`, `/clearlogs`, `/botlog`, `/reboot`, `/restart_bot`, `/help`
- Логирует себя и действия
- Автостарт и кэш состояния

---

## 📊 Мониторинг

- **Netdata** запускается в Docker
- Доступ: `http://<IP>:19999`
- Показывает нагрузку, память, диски, процессы

---

## ✅ Проверка установки

Автоматически выполняется в финале `install_user.sh`:

- статус служб `ufw`, `fail2ban`, `psad`, `rkhunter`
- доступ Telegram-бота и отчёт `/checklist`
- Docker, Portainer, Netdata
- cron-задачи
- логи PSAD и RKHunter

---

## 📌 Требования

- Ubuntu 22.04+
- root-доступ по SSH
- корректный `config.json`, например:

```json
{
  "username": "igrom",
  "user_password": "СЛОЖНЫЙ_ПАРОЛЬ",
  "port": 2222,
  "telegram_bot_token": "1234:ABC...",
  "telegram_chat_id": 123456789,
  "ssh_disable_root": true,
  "ssh_password_auth": false,
  "sudo_nopasswd": true,
  "monitoring_enabled": true,
  "services": {
    "ufw": true,
    "fail2ban": true,
    "psad": true,
    "rkhunter": true,
    "nmap": true
  }
}
```

---

