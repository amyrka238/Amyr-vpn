# 🚀 SubManager — Installer Guide

## Быстрый старт

```bash
sudo bash <(curl -sL https://your-domain.com/install.sh)
```

или

```bash
sudo curl -sL https://your-domain.com/install.sh | bash
```

## Что происходит при установке?

### 1️⃣ Проверки
- Проверка что вы root
- Определение OS (Ubuntu/Debian)
- Проверка есть ли уже установка

### 2️⃣ Setup Wizard (интерактивный)
Скрипт спросит вас:

```
┌─────────────────────────────────────────┐
│ Server IP: 123.45.67.89                 │
│                                         │
│ Panel username [admin]: myusername      │
│ Panel password [auto-generate]: ****    │
│ Panel port [1088]: 1088                 │
│ Panel title [VPN Sub Manager]: My Panel │
│ Domain [none]: panel.example.com        │
│ Proceed with installation? [Y/n]: Y     │
└─────────────────────────────────────────┘
```

**Объяснение:**
- **username** — логин для входа в панель
- **password** — пароль (оставь пустым для авто-генерации)
- **port** — на каком порту слушать панель (по умолчанию 1088)
- **title** — название панели (отображается в браузере)
- **domain** — домен для HTTPS (если есть, автоматически установится SSL)

### 3️⃣ Автоматическая установка
Скрипт установит:
- ✅ Python3, pip
- ✅ Nginx (обратный прокси)
- ✅ UFW (firewall)
- ✅ Certbot (SSL сертификаты)
- ✅ Flask, gunicorn, psutil
- ✅ Systemd сервис для автозагрузки
- ✅ Приложение в `/opt/submanager`
- ✅ CLI-команда `submanager` для управления

### 4️⃣ SSL (если указал домен)
Если ты указал домен, скрипт автоматически:
- Запросит сертификат Let's Encrypt
- Настроит nginx на HTTPS
- Настроит автообновление сертификата (cron)
- Переведёт HTTP на HTTPS

## Примеры установки

### Вариант 1️⃣: С доменом (HTTPS)
```
Server IP: 89.107.10.206
username: admin
password: [авто-генерируется]
port: 1088
title: VPN Manager
domain: vpn.example.com

Результат:
✅ https://vpn.example.com (HTTPS с SSL)
```

### Вариант 2️⃣: Только по IP (HTTP)
```
Server IP: 89.107.10.206
username: admin
password: MyPassword123
port: 1088
title: My Panel
domain: [оставить пустым]

Результат:
✅ http://89.107.10.206:1088 (без SSL)
```

### Вариант 3️⃣: На нестандартном порту
```
Server IP: 89.107.10.206
username: myuser
password: MySecure123
port: 8080
title: Secret Panel
domain: [пусто или домен]

Результат:
✅ http://89.107.10.206:8080 или https://domain.com
```

## После установки

### ✅ Успешная установка выглядит так:
```
═══════════════════════════════════════════════════════════
        ✅  SubManager installed successfully!            
═══════════════════════════════════════════════════════════

  Panel URL:   https://vpn.example.com
  Username:    admin
  Password:    xK8mN2pQ9rL5
  
  Management:  submanager
  Service:     systemctl status submanager
  Logs:        journalctl -u submanager -f

  ⚠  Save your credentials! They won't be shown again.

═══════════════════════════════════════════════════════════
```

## Управление через CLI

После установки используй команду:

```bash
submanager
```

Откроется меню:

```
╔═══════════════════════════════════════════════╗
║       ⚡ SubManager Control Panel ⚡          ║
╚═══════════════════════════════════════════════╝

  Status:    ● Running
  Version:   2.0.0
  Server IP: 123.45.67.89
  Port:      1088
  Username:  admin
  Title:     VPN Sub Manager
  Panel URL: http://123.45.67.89:1088

━━━ Actions ━━━

  1) Start / Restart panel
  2) Stop panel
  3) View logs

━━━ Settings ━━━

  4) Change username & password
  5) Change port
  6) Change domain / Setup SSL
  7) Change panel title
  8) Change base URL

━━━ Maintenance ━━━

  9) Backup database
 10) Restore database
 11) Reset database (fresh start)
 12) Open firewall port
 13) Update SubManager

 14) Uninstall SubManager
  0) Exit
```

## Основные команды

```bash
# Статус сервиса
systemctl status submanager

# Посмотреть логи в реальном времени
journalctl -u submanager -f

# Рестарт панели
systemctl restart submanager

# Остановить
systemctl stop submanager

# Запустить
systemctl start submanager

# Открыть управление
submanager

# Путь к конфигу
cat /opt/submanager/config.json

# Путь к БД
ls -la /opt/submanager/db.sqlite
```

## Если что-то сломалось

### Переустановка файлов (базу оставляет):
```bash
sudo bash <(curl -sL https://your-domain.com/install.sh)
# Выбрать "2) Update"
```

### Полное удаление:
```bash
submanager
# Выбрать "14) Uninstall SubManager"
# или запустить:
sudo bash <(curl -sL https://your-domain.com/install.sh)
# Выбрать "3) Uninstall"
```

### Проблемы с портом:
Если порт занят другой программой, измени через:
```bash
submanager
# Выбрать "5) Change port"
```

### SSL сертификат не установился:
```bash
certbot --nginx -d your-domain.com
```

## Структура установки

```
/opt/submanager/
├── app.py              # Основное приложение Flask
├── plugin.py           # Дополнительные функции
├── config.json         # Конфиг (логин, пароль, порт, домен)
├── db.sqlite           # База данных (пользователи, узлы)
├── templates/
│   ├── index.html      # Главная страница панели
│   └── login.html      # Страница входа
├── venv/               # Python virtual environment
└── logs/               # Логи (если использует gunicorn)

/etc/systemd/system/
└── submanager.service  # Systemd сервис

/etc/nginx/sites-available/
└── submanager         # Nginx конфиг (если используется с доменом)

/usr/local/bin/
└── submanager         # CLI-утилита управления
```

## FAQ

**Q: Можно ли потом поменять пароль?**
A: Да, через команду `submanager` → "4) Change username & password"

**Q: Нужен ли домен?**
A: Нет, можно использовать IP-адрес. Домен нужен только если хочешь HTTPS.

**Q: Где хранятся данные?**
A: Всё в `/opt/submanager/` — БД, конфиг, приложение.

**Q: Будет ли панель запускаться после перезагрузки?**
A: Да, systemd сервис автоматически её запустит.

**Q: Как бэкапить базу?**
A: Команда `submanager` → "9) Backup database"

**Q: Потеряю ли данные при переустановке?**
A: Нет, БД сохранится. Выбери опцию "Update" при повторном запуске.

**Q: Несколько панелей на одном сервере?**
A: Можно, но нужно менять порт для каждой и редактировать скрипт.

---

**Создано:** SubManager Installer v2.0  
**Лицензия:** MIT  
**Поддержка:** Встроенное меню управления
