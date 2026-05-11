# 🛡️ AntiScan v3.3.6

**Комплексная защита Linux-сервера от сканеров портов, brute-force и автоматических атак.**

[![Version](https://img.shields.io/badge/version-3.3.6-blue.svg)](https://github.com/olegs2026/AntiScan)
[![Bash](https://img.shields.io/badge/bash-5.0+-green.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![OS](https://img.shields.io/badge/OS-Ubuntu%2022.04%20%7C%2024.04-orange.svg)](https://ubuntu.com/)
[![GitHub stars](https://img.shields.io/github/stars/olegs2026/AntiScan?style=social)](https://github.com/olegs2026/AntiScan/stargazers)

---

## 📋 Что это такое?

**AntiScan** — это автономный bash-скрипт, превращающий обычный Ubuntu-сервер в крепость:

- 🚫 **Блокирует** известных злоумышленников из РКН по обновляемому блоклисту
- 🍯 **Ловит сканеры** на honeypot-портах и автоматически банит
- 🔒 **Защищает SSH** от brute-force через fail2ban-логику
- ⏱ **Ограничивает** частоту подключений (rate-limit)
- 📨 **Уведомляет** в Telegram о всех событиях
- 🌍 **Геолокация** атакующих IP с флагами стран
- 📊 **Ежедневные отчёты** статистики атак

---

## ⚡ Быстрый старт

```bash
# Клонирование репозитория
git clone https://github.com/olegs2026/AntiScan.git
cd AntiScan

# Запуск установщика с интерактивным меню
sudo bash install-antiscanner.sh
```

---

## 🎯 Возможности

| Модуль | Описание |
|--------|---------|
| **Blocklist** | Автоматическое скачивание и применение списка ~150-200 IP сканеров. Обновление по cron в 03:20 |
| **Honeypot** | Открытые порты 23, 2222, 3389, 8080 как ловушки. Любое подключение → бан на 24 часа |
| **Fail2ban** | Анализ SSH-логов в реальном времени. 3 неудачных попытки за 10 мин → бан на 24 часа |
| **Rate-limit** | Не более 10 SSH-подключений в минуту с одного IP |
| **GeoIP** | Определение страны атакующего через ipinfo.io / ip-api.com с эмодзи флагов |
| **Telegram** | Гибкие уведомления: alerts/report включены, honeypot/fail2ban — по желанию |
| **Whitelist** | IP/CIDR не подвергаются блокировке, защита от самоблокировки SSH |
| **Reports** | Ежедневный отчёт в TG: TOP-10 атакующих, TOP стран, TOP портов |

---

## 📦 Структура проекта

```
AntiScan/
├── antiscanner                # Основной скрипт (~900 строк)
├── install-antiscanner.sh     # Установщик с интерактивным меню
├── README.md                  # Этот файл
└── LICENSE                    # MIT License
```

---

## 🔧 Системные требования

- **OS:** Ubuntu 22.04 / 24.04 LTS (или Debian 11+)
- **CPU:** любой (минимум 1 ядро)
- **RAM:** 256 МБ
- **Disk:** 50 МБ (логи + кеш)
- **Привилегии:** root (для управления iptables/ipset)

### Зависимости (ставятся автоматически):
- `curl`, `python3`, `rsyslog`, `cron`
- `iptables`, `iptables-persistent`, `ipset`
- `netcat-traditional` (важно для honeypot!)
- `iputils-ping`

---

## 📥 Установка

### Способ 1: Через установщик (рекомендуется)

```bash
git clone https://github.com/olegs2026/AntiScan.git
cd AntiScan
sudo bash install-antiscanner.sh
```

Появится главное меню:

```
╔══════════════════════════════════════════════════════════╗
║                ANTISCANNER v3.3.6                        ║
║              Главное меню действий                       ║
╚══════════════════════════════════════════════════════════╝

  1) Установить AntiScanner (полная установка)
  2) Переустановить (удалить старое + установить)
  3) Обновить только основной скрипт
  4) Полностью удалить AntiScanner
  5) Показать статус
  6) Запустить диагностику
  7) Обновить блоклист сейчас
  8) Быстрая статистика
  0) Выход
```

### Способ 2: Прямые команды (для автоматизации)

```bash
# Установка
sudo bash install-antiscanner.sh --install

# Удаление
sudo bash install-antiscanner.sh --uninstall

# Обновление основного скрипта
sudo bash install-antiscanner.sh --update

# Версии
sudo bash install-antiscanner.sh --version
```

### Способ 3: Скачать через wget (без git)

```bash
wget https://raw.githubusercontent.com/olegs2026/AntiScan/main/antiscanner
wget https://raw.githubusercontent.com/olegs2026/AntiScan/main/install-antiscanner.sh
chmod +x install-antiscanner.sh
sudo bash install-antiscanner.sh
```

---

## 🚀 Использование

### Основные команды

```bash
antiscanner status           # Полный статус системы
antiscanner test             # Самодиагностика (30+ проверок)
antiscanner update           # Обновить блоклист сейчас
antiscanner help             # Справка
```

### Управление модулями

#### Honeypot
```bash
antiscanner honeypot status
antiscanner honeypot enable    # включить
antiscanner honeypot disable   # отключить
antiscanner honeypot silent    # без TG-уведомлений
antiscanner honeypot verbose   # с TG-уведомлениями
antiscanner honeypot list      # список забаненных IP
```

#### Fail2ban
```bash
antiscanner fail2ban status
antiscanner fail2ban list
antiscanner fail2ban unban 1.2.3.4  # снять блокировку
```

#### Rate-limit
```bash
antiscanner ratelimit status
antiscanner ratelimit setup
antiscanner ratelimit remove
```

### Уведомления в Telegram

```bash
# Настройка бота (один раз)
antiscanner telegram setup

# Управление шумностью
antiscanner notify status                # текущие настройки
antiscanner notify alerts on             # alerts (всплески атак)
antiscanner notify report on             # daily-report
antiscanner notify honeypot on/off       # каждый бан honeypot
antiscanner notify fail2ban on/off       # каждый бан fail2ban
```

### Whitelist (защита от самоблокировки)

```bash
antiscanner whitelist list
antiscanner whitelist add 192.168.1.100
antiscanner whitelist add 10.0.0.0/24      # CIDR тоже работает
antiscanner whitelist del 192.168.1.100
```

### GeoIP

```bash
antiscanner geoip lookup 8.8.8.8     # проверить страну IP
antiscanner geoip cache              # кеш проверенных IP
antiscanner geoip clear              # очистить кеш
```

### Отчёты

```bash
antiscanner report              # за период с последнего отчёта
antiscanner report --24h        # за 24 часа
antiscanner report --7d         # за неделю
antiscanner report --all        # за всё время
```

### Логи

```bash
antiscanner logs update          # лог обновлений блоклиста
antiscanner logs blocked         # лог блокировок
antiscanner logs honeypot        # лог honeypot
antiscanner logs fail2ban        # лог fail2ban
antiscanner logs alerts          # лог уведомлений
```
