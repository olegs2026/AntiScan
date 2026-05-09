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

- 🚫 **Блокирует** известных злоумышленников по обновляемому блоклисту
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

