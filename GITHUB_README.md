# 🚀 SubManager v2.0

**Professional VPN Subscription Management Panel with HTTPS**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python 3.7+](https://img.shields.io/badge/Python-3.7+-blue.svg)](https://www.python.org/)
[![Ubuntu 20.04+](https://img.shields.io/badge/Ubuntu-20.04+-orange.svg)](https://ubuntu.com/)

Полнофункциональная панель управления VPN подписками с веб-интерфейсом, REST API, поддержкой HTTPS и интерактивным CLI-управлением.

## ✨ Возможности

- 🎯 **Веб-панель** — красивый интерфейс для управления (как x-ui)
- 📡 **REST API** — для интеграции с другими системами
- 🔒 **HTTPS/SSL** — автоматические сертификаты Let's Encrypt
- 👥 **Управление пользователями** — создание, редактирование, удаление
- 📊 **Отслеживание трафика** — лимиты и статистика
- ⏱️ **Управление сроками** — автоматические оповещения
- 🖥️ **Управление серверами** — добавление узлов подписок
- 💾 **База данных** — SQLite с полной историей
- 📋 **Логирование** — все действия записываются
- 🛠️ **CLI-управление** — интерактивное меню (`submanager`)
- 🔄 **Автозагрузка** — systemd сервис
- 🛡️ **Firewall** — автоматическая настройка UFW

## 🚀 Быстрый старт

### Установка одной командой

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/YOUR_USERNAME/submanager/main/install.sh)
```

### Интерактивный wizard

При установке скрипт спросит:
- **Username** — логин для входа в панель
- **Password** — пароль (или авто-генерация)
- **Port** — порт панели (по умолчанию 1088)
- **Title** — название панели
- **Domain** — домен для HTTPS (опционально)

### После установки

```bash
# Открыть панель в браузере
https://your-domain.com или http://IP:PORT

# Управление
submanager          # Интерактивное меню
systemctl status submanager  # Статус
journalctl -u submanager -f  # Логи
```

## 📋 Требования

- **ОС**: Ubuntu 20.04+ или Debian 10+
- **Права**: root или sudo
- **Сеть**: доступ в интернет (для SSL сертификатов)
- **Порты**: 80, 443 (если HTTPS), выбранный порт панели

## 📂 Структура проекта

```
.
├── install.sh              # Основной инсталлер (817 строк)
├── show-configs.sh         # Утилита просмотра конфигов
├── QUICK_START.md          # Быстрый старт
├── README.md               # Полная документация
├── COMMANDS.md             # Справочник команд
├── ARCHITECTURE.md         # Архитектура
└── LICENSE                 # MIT License
```

## 🎛️ Управление

### Через интерактивное меню

```bash
submanager
```

**Опции:**
- 1) Рестарт панели
- 2) Остановить панель
- 3) Показать логи
- 4) Поменять пароль
- 5) Поменять порт
- 6) Добавить домен/SSL
- 7) Поменять название
- 8) Поменять base URL
- 9) Бэкап БД
- 10) Восстановить БД
- 11) Сброс БД
- 12) Открыть порт firewall
- 13) Обновить
- 14) Удалить

### Основные команды

```bash
# Статус
systemctl status submanager

# Логи
journalctl -u submanager -f

# Рестарт
systemctl restart submanager

# Просмотр конфигов
bash show-configs.sh
```

## 📁 После установки

```
/opt/submanager/
├── app.py                 # Flask приложение
├── plugin.py              # Дополнительные функции
├── config.json            # Конфигурация
├── db.sqlite              # База данных
├── templates/
│   ├── index.html         # Главная панель
│   └── login.html         # Вход
└── venv/                  # Python окружение

/etc/nginx/sites-available/submanager   # Nginx конфиг
/etc/systemd/system/submanager.service  # Systemd сервис
/usr/local/bin/submanager               # CLI управления
```

## 🔧 Примеры использования

### Просмотр конфига nginx

```bash
cat /etc/nginx/sites-available/submanager
bash show-configs.sh nginx
```

### Смена пароля

```bash
submanager
# Выбрать: 4) Change username & password
```

### Добавить домен и SSL

```bash
submanager
# Выбрать: 6) Change domain / Setup SSL
# Указать домен
# Certbot автоматически установит сертификат
```

### Бэкап и восстановление

```bash
# Бэкап
cp /opt/submanager/db.sqlite /root/submanager_backup_$(date +%Y%m%d_%H%M%S).sqlite

# Восстановление
systemctl stop submanager
cp /root/submanager_backup_2024-05-28.sqlite /opt/submanager/db.sqlite
systemctl start submanager
```

## 🐛 Решение проблем

### Конфиг не найден

```bash
# Проверить наличие
ls -la /etc/nginx/sites-available/submanager

# Если его нет - переустановить
sudo bash install.sh
```

### Порт занят

```bash
# Найти какой процесс занимает порт
lsof -i :1088

# Изменить через меню
submanager
# Выбрать: 5) Change port
```

### SSL сертификат не установился

```bash
# Вручную
certbot --nginx -d your-domain.com -m your-email@example.com

# Проверить
certbot certificates
```

### Логи ошибок

```bash
# Systemd логи
journalctl -u submanager -n 100 -e

# Nginx логи
tail -f /var/log/nginx/error.log

# Проверить синтаксис nginx
nginx -t
```

## 📚 Документация

- [QUICK_START.md](QUICK_START.md) — быстрый старт
- [README.md](README.md) — полная инструкция
- [COMMANDS.md](COMMANDS.md) — справочник всех команд
- [ARCHITECTURE.md](ARCHITECTURE.md) — архитектура и диаграммы

## 🔐 Безопасность

- Пароль хранится в конфиге (защищен правами доступа)
- SSL сертификаты от Let's Encrypt (бесплатно)
- Автообновление сертификатов (cron job)
- Firewall (UFW) настраивается автоматически
- Все логи записываются в journalctl
- БД зашифрована системой SQLite

## 🤝 Вклад

Найдешь баг или захочешь улучшить — создавай pull request!

## 📄 Лицензия

MIT License — смотри [LICENSE](LICENSE)

## 📞 Контакты

- GitHub Issues — для багов и предложений
- Документация — см. README и COMMANDS

---

**SubManager v2.0** — Professional VPN Subscription Management Panel

**Created:** May 2024  
**Version:** 2.0.0  
**License:** MIT  
**Status:** Production Ready ✅

