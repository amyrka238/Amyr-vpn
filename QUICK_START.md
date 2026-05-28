# ⚡ SubManager — Быстрый старт

## 1. Установка (выбирай вариант)

### Вариант A: HTTPS с доменом
```bash
sudo bash <(curl -sL https://your-domain.com/install.sh)
```
При вопросе про домен — укажи свой домен (должен быть привязан к IP сервера)

### Вариант B: HTTP по IP
```bash
sudo bash <(curl -sL https://your-domain.com/install.sh)
```
При вопросе про домен — нажми Enter (пусто)

## 2. После установки

Скрипт покажет:
```
Panel URL:   https://your-domain.com или http://IP:PORT
Username:    admin (или твой логин)
Password:    xK8mN2pQ9rL5 (СОХРАНИ!)
```

**Открой в браузере** → введи логин/пароль → начни управлять!

## 3. Главные команды

```bash
# Управление панелью
submanager

# Статус
systemctl status submanager

# Логи
journalctl -u submanager -f

# Рестарт
systemctl restart submanager
```

## 4. Часто используемые опции в `submanager`

| Номер | Что делает |
|-------|-----------|
| 1 | Рестарт панели |
| 2 | Остановить панель |
| 3 | Показать логи |
| 4 | Поменять пароль |
| 5 | Поменять порт |
| 6 | Добавить SSL/домен |
| 9 | Бэкап БД |
| 14 | Удалить всё |

## 5. Если не работает

```bash
# Проверь статус
systemctl status submanager

# Посмотри ошибки
journalctl -u submanager -n 100

# Рестарт
systemctl restart submanager

# Проверь конфиг
cat /opt/submanager/config.json
```

## 6. Где всё находится

| Что | Где |
|-----|-----|
| Приложение | `/opt/submanager/` |
| БД (данные) | `/opt/submanager/db.sqlite` |
| Конфиг | `/opt/submanager/config.json` |
| Управление | Команда `submanager` |
| Логи | `journalctl -u submanager` |

## 7. Переустановка / обновление

Запусти установку ещё раз:
```bash
sudo bash <(curl -sL https://your-domain.com/install.sh)
```

Выбери:
- **1** → переустановить свежую
- **2** → обновить файлы (БД сохранится)
- **3** → удалить всё
- **4** → открыть управление

---

**Всё! Теперь у тебя есть полностью рабочая VPN-панель управления подписками с HTTPS, автоматическими сертификатами и CLI-управлением.**

Дальше добавляй юзеров через web-интерфейс панели 👇
