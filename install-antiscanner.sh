#!/bin/bash
# install-antiscanner.sh — установщик AntiScanner v3.3.6


set -eE

BOLD='\033[1m'; DIM='\033[2m'
B_CYAN='\033[1;36m'; B_GREEN='\033[1;32m'; B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'; B_MAGENTA='\033[1;35m'; B_WHITE='\033[1;37m'; NC='\033[0m'

AS_VERSION="3.3.6"
BIN="/usr/local/bin/antiscanner"
BIN_REPORT_OLD="/usr/local/bin/antiscanner-report"
CONF_DIR="/etc/antiscanner"
CONFIG="$CONF_DIR/config.conf"
RSYSLOG_CONF="/etc/rsyslog.d/10-antiscanner.conf"
LOGROTATE_CONF="/etc/logrotate.d/antiscanner"
LOGROTATE_CONF_OLD="/etc/logrotate.d/antiscanner-report"
SD_DIR="/etc/systemd/system"
IPT_CHAIN="SCANNERS-BLOCK"
IPSET_F2B="antiscanner-f2b"
IPSET_HP="antiscanner-honeypot"

PWD_DIR="$(pwd)"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
MODE=""
EXISTING_ARTIFACTS=()

# =============== Helpers ===============
ok()    { echo -e "  ${B_GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${B_YELLOW}⚠${NC} $*"; }
info()  { echo -e "  ${DIM}ⓘ${NC} $*"; }
step()  { echo -e "\n${B_CYAN}▶ $*${NC}"; }

die() {
    echo -e "\n${B_RED}✗ ОШИБКА: $*${NC}" >&2
    exit 1
}
trap 'die "Команда упала с кодом $?: \"$BASH_COMMAND\""' ERR

# =============== Безопасный счётчик ipset ===============
ipset_count() {
    local set_name="$1"
    local cnt=0
    if ipset list "$set_name" &>/dev/null; then
        cnt=$(ipset list "$set_name" 2>/dev/null | grep -cE '^[0-9]' 2>/dev/null || true)
        cnt="${cnt//[^0-9]/}"
        cnt=${cnt:-0}
    fi
    echo "$cnt"
}

# =============== Проверка версии установленного скрипта ===============
get_installed_version() {
    if [ -f "$BIN" ]; then
        grep -oP 'antiscanner v\K[0-9]+\.[0-9]+\.[0-9]+' "$BIN" 2>/dev/null | head -1 || echo "unknown"
    else
        echo "none"
    fi
}

# =============== ПОЛНОЕ УДАЛЕНИЕ ===============
full_uninstall() {
    echo
    echo -e "${B_RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${B_RED}║         ПОЛНОЕ УДАЛЕНИЕ ANTISCANNER v${AS_VERSION}                 ║${NC}"
    echo -e "${B_RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo
    read -rp "Введите yes для подтверждения: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Отмена."
        return 1
    fi

    step "Остановка сервисов"
    systemctl disable --now antiscanner-fail2ban antiscanner-honeypot \
                       antiscanner-update antiscanner-unban.timer 2>/dev/null || true

    step "Удаление systemd юнитов"
    rm -f "$SD_DIR"/antiscanner-*.service "$SD_DIR"/antiscanner-*.timer 2>/dev/null || true
    systemctl daemon-reload || true

    step "Очистка iptables и ipset"
    iptables -D INPUT -m set --match-set "$IPSET_F2B" src -j DROP 2>/dev/null || true
    iptables -D INPUT -m set --match-set "$IPSET_HP" src -j DROP 2>/dev/null || true
    ipset destroy "$IPSET_F2B" 2>/dev/null || true
    ipset destroy "$IPSET_HP" 2>/dev/null || true

    if command -v iptables-save >/dev/null 2>&1; then
        local rl_rules=""
        rl_rules=$(iptables-save 2>/dev/null | grep 'AntiScanner-RateLimit' || true)
        if [ -n "$rl_rules" ]; then
            echo "$rl_rules" | sed 's/^-A /-D /' | while read -r rule; do
                eval "iptables $rule" 2>/dev/null || true
            done
            ok "Rate-limit правила удалены"
        fi
    fi

    for c in iptables ip6tables; do
        $c -D INPUT -j "$IPT_CHAIN" 2>/dev/null || true
        $c -F "$IPT_CHAIN" 2>/dev/null || true
        $c -X "$IPT_CHAIN" 2>/dev/null || true
    done
    ok "iptables цепочка $IPT_CHAIN удалена"

    if command -v ufw >/dev/null 2>&1; then
        local ufw_lines=""
        ufw_lines=$(ufw status numbered 2>/dev/null | grep 'AntiScanner' || true)
        if [ -n "$ufw_lines" ]; then
            local removed=0 num
            while IFS= read -r line; do
                num=$(echo "$line" | grep -oE '^$$\s*[0-9]+$$' | tr -d '[] ' 2>/dev/null || true)
                if [ -n "$num" ]; then
                    ufw --force delete "$num" >/dev/null 2>&1 && removed=$((removed+1)) || true
                fi
            done <<< "$ufw_lines"
            [ "$removed" -gt 0 ] && ok "UFW: удалено $removed правил" || true
            ufw reload >/dev/null 2>&1 || true
        fi
    fi

    step "Очистка CRON, rsyslog, logrotate и файлов"
    (crontab -l 2>/dev/null | grep -vF 'antiscanner' || true) | crontab - 2>/dev/null || true
    rm -f "$RSYSLOG_CONF" "$LOGROTATE_CONF" "$LOGROTATE_CONF_OLD" 2>/dev/null || true
    systemctl restart rsyslog 2>/dev/null || true
    rm -rf "$CONF_DIR" 2>/dev/null || true
    rm -f /var/log/antiscanner_*.log "$BIN" "$BIN_REPORT_OLD" 2>/dev/null || true

    echo
    echo -e "${B_GREEN}AntiScanner полностью удалён${NC}"
}

# =============== Проверка ОС (изолированно от os-release) ===============
check_ubuntu() {
    step "Проверка операционной системы"

    if [ ! -f /etc/os-release ]; then
        die "Не удалось определить ОС"
    fi

    # Изолированное чтение чтобы не загрязнять пространство имён установщика
    local os_id os_ver os_pretty
    os_id=$(. /etc/os-release && echo "${ID:-}")
    os_ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
    os_pretty=$(. /etc/os-release && echo "${PRETTY_NAME:-}")

    if [ "$os_id" = "ubuntu" ]; then
        if [[ "$os_ver" =~ ^24 ]]; then
            ok "Ubuntu ${os_ver} — полностью поддерживается"
        elif [[ "$os_ver" =~ ^22 ]]; then
            ok "Ubuntu ${os_ver} — поддерживается"
        else
            warn "Ubuntu ${os_ver:-?} — рекомендуется 22.04 или 24.04"
        fi
    elif [ "$os_id" = "debian" ]; then
        ok "Debian ${os_ver:-?} — поддерживается"
    else
        warn "Обнаружена ${os_pretty:-неизвестная ОС}"
    fi
}

check_internet() {
    step "Проверка интернета"
    if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 || curl -s --max-time 4 http://archive.ubuntu.com >/dev/null 2>&1; then
        ok "Интернет доступен"
    else
        die "Нет подключения к интернету"
    fi
}

ensure_main_script() {
    if [ -f "$BIN" ]; then
        local installed; installed=$(get_installed_version)
        if [ "$installed" = "$AS_VERSION" ]; then
            ok "Основной скрипт актуален (v$AS_VERSION)"
        else
            warn "Установлена v$installed, рядом v$AS_VERSION (можно обновить)"
        fi
        return 0
    fi

    local candidates=(
        "$PWD_DIR/antiscanner"
        "$PWD_DIR/antiscanner.sh"
        "$INSTALLER_DIR/antiscanner"
        "$INSTALLER_DIR/antiscanner.sh"
    )

    local src=""
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            src="$c"
            break
        fi
    done

    if [ -n "$src" ]; then
        info "Найден: $src"
        mkdir -p "$(dirname "$BIN")"
        cp "$src" "$BIN"
        chmod +x "$BIN"
        ok "Скопирован в $BIN"
        return 0
    fi

    echo -e "${B_RED}✗ Основной скрипт antiscanner не найден!${NC}"
    echo -e "Поместите файл рядом с установщиком и попробуйте снова."
    return 1
}

detect_existing_install() {
    local found=()
    [ -f "$BIN" ] && found+=("$BIN (v$(get_installed_version))") || true
    [ -d "$CONF_DIR" ] && found+=("$CONF_DIR ($(ls -1 "$CONF_DIR" 2>/dev/null | wc -l) файлов)") || true
    [ -f "$RSYSLOG_CONF" ] && found+=("$RSYSLOG_CONF") || true
    [ -f "$LOGROTATE_CONF" ] && found+=("$LOGROTATE_CONF") || true

    for unit in antiscanner-update.service antiscanner-fail2ban.service \
                antiscanner-honeypot.service antiscanner-unban.timer; do
        [ -f "$SD_DIR/$unit" ] && found+=("systemd: $unit") || true
    done

    if crontab -l 2>/dev/null | grep -q 'antiscanner'; then
        local n; n=$(crontab -l 2>/dev/null | grep -c 'antiscanner' || true)
        found+=("cron: ${n:-0} задач")
    fi

    if command -v ipset >/dev/null 2>&1; then
        local f2b_cnt hp_cnt
        f2b_cnt=$(ipset_count "$IPSET_F2B")
        hp_cnt=$(ipset_count "$IPSET_HP")
        ipset list "$IPSET_F2B" &>/dev/null && found+=("ipset: $IPSET_F2B (забанено: $f2b_cnt)") || true
        ipset list "$IPSET_HP" &>/dev/null && found+=("ipset: $IPSET_HP (забанено: $hp_cnt)") || true
    fi

    if iptables -L "$IPT_CHAIN" -n &>/dev/null; then
        local cnt; cnt=$(iptables -S "$IPT_CHAIN" 2>/dev/null | grep -c '^-A .* -j DROP' || echo 0)
        found+=("iptables: $IPT_CHAIN ($cnt правил)")
    fi

    if iptables-save 2>/dev/null | grep -q 'AntiScanner-RateLimit'; then
        found+=("iptables: rate-limit правила")
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status numbered 2>/dev/null | grep -q 'AntiScanner'; then
        found+=("UFW правила")
    fi

    local logs=(/var/log/antiscanner_*.log)
    [ -e "${logs[0]}" ] && found+=("логи antiscanner") || true

    EXISTING_ARTIFACTS=("${found[@]}")
}

purge_existing() {
    step "Очистка предыдущей установки"

    for s in antiscanner-fail2ban antiscanner-honeypot antiscanner-update \
             antiscanner-unban.service antiscanner-unban.timer; do
        systemctl disable --now "$s" 2>/dev/null || true
    done
    rm -f "$SD_DIR"/antiscanner-*.service "$SD_DIR"/antiscanner-*.timer 2>/dev/null || true
    systemctl daemon-reload || true

    iptables -D INPUT -m set --match-set "$IPSET_F2B" src -j DROP 2>/dev/null || true
    iptables -D INPUT -m set --match-set "$IPSET_HP" src -j DROP 2>/dev/null || true
    ipset destroy "$IPSET_F2B" 2>/dev/null || true
    ipset destroy "$IPSET_HP" 2>/dev/null || true

    if command -v iptables-save >/dev/null 2>&1; then
        local rl_rules=""
        rl_rules=$(iptables-save 2>/dev/null | grep 'AntiScanner-RateLimit' || true)
        if [ -n "$rl_rules" ]; then
            echo "$rl_rules" | sed 's/^-A /-D /' | while read -r rule; do
                eval "iptables $rule" 2>/dev/null || true
            done
        fi
    fi

    for c in iptables ip6tables; do
        $c -D INPUT -j "$IPT_CHAIN" 2>/dev/null || true
        $c -F "$IPT_CHAIN" 2>/dev/null || true
        $c -X "$IPT_CHAIN" 2>/dev/null || true
    done

    if command -v ufw >/dev/null 2>&1; then
        local ufw_lines=""
        ufw_lines=$(ufw status numbered 2>/dev/null | grep 'AntiScanner' || true)
        if [ -n "$ufw_lines" ]; then
            local num
            while IFS= read -r line; do
                num=$(echo "$line" | grep -oE '^$$\s*[0-9]+$$' | tr -d '[] ' 2>/dev/null || true)
                [ -n "$num" ] && ufw --force delete "$num" >/dev/null 2>&1 || true
            done <<< "$ufw_lines"
            ufw reload >/dev/null 2>&1 || true
        fi
    fi

    (crontab -l 2>/dev/null | grep -vF 'antiscanner' || true) | crontab - 2>/dev/null || true
    rm -f "$RSYSLOG_CONF" "$LOGROTATE_CONF" "$LOGROTATE_CONF_OLD" 2>/dev/null || true
    systemctl restart rsyslog 2>/dev/null || true
    rm -rf "$CONF_DIR" 2>/dev/null || true
    rm -f /var/log/antiscanner_*.log "$BIN_REPORT_OLD" 2>/dev/null || true

    ok "Предыдущая установка очищена"
}

detect_firewall_mode() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qiE '^\s*Status:\s*active'; then
        MODE="ufw"
    else
        MODE="iptables"
    fi
    info "Режим фаервола: ${B_MAGENTA}$MODE${NC}"
}

install_dependencies() {
    step "Установка зависимостей"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local pkgs="curl python3 rsyslog ipset netcat-traditional iputils-ping cron"
    if [ "$MODE" = "iptables" ]; then
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        pkgs="$pkgs iptables iptables-persistent"
    fi
    apt-get install -y -qq $pkgs
    ok "Зависимости установлены"
}

create_config() {
    step "Создание конфигурации"
    mkdir -p "$CONF_DIR"
    chmod 755 "$CONF_DIR"

    for f in whitelist.txt current.list previous.list watch.state alerts.seen \
             fail2ban.state fail2ban.bans geoip.cache protected.list last.diff; do
        touch "$CONF_DIR/$f"
    done

    if [ ! -f "$CONFIG" ]; then
        cat > "$CONFIG" << CFG
# === AntiScanner v${AS_VERSION} Configuration ===
ALERT_THRESHOLD=3
ALERT_WINDOW=300
ALERT_COOLDOWN=3600
F2B_MAX_FAILS=3
F2B_WINDOW=600
F2B_BAN_SECONDS=86400
HONEYPOT_PORTS="23 2222 3389 8080"
HONEYPOT_COOLDOWN=25
RATELIMIT_ENABLED=true
RATELIMIT_PORTS="22"
RATELIMIT_RATE="10/min"
RATELIMIT_BURST=15
NOTIFY_ALERTS=true
NOTIFY_REPORT=true
NOTIFY_HONEYPOT=false
NOTIFY_FAIL2BAN=false
BLOCKLIST_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/blacklist.txt"
TG_API_IPV4="149.154.167.220"
CFG
        chmod 640 "$CONFIG"
        ok "Создан конфиг $CONFIG"
    else
        if ! grep -q 'HONEYPOT_COOLDOWN' "$CONFIG"; then
            echo 'HONEYPOT_COOLDOWN=25' >> "$CONFIG"
            ok "Добавлен HONEYPOT_COOLDOWN в существующий конфиг"
        fi
        ok "Конфиг сохранён"
    fi

    for f in update blocked alerts fail2ban honeypot; do
        touch "/var/log/antiscanner_${f}.log"
        chmod 644 "/var/log/antiscanner_${f}.log"
    done
    ok "Логи созданы"
}

setup_rsyslog() {
    step "Настройка rsyslog"
    cat > "$RSYSLOG_CONF" << 'RS'
if ($msg contains "HONEYPOT-HIT") then { action(type="omfile" file="/var/log/antiscanner_honeypot.log") stop }
if ($msg contains "ANTISCANNER-BLOCK") then { action(type="omfile" file="/var/log/antiscanner_blocked.log") stop }
if ($msg contains "[UFW BLOCK]") then { action(type="omfile" file="/var/log/antiscanner_blocked.log") }
RS
    systemctl restart rsyslog 2>/dev/null || true
    ok "rsyslog настроен"
}

setup_logrotate() {
    step "Настройка logrotate"
    cat > "$LOGROTATE_CONF" << 'LR'
/var/log/antiscanner_*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
LR
    ok "logrotate настроен"
}

setup_systemd() {
    step "Создание systemd сервисов"
    cat > "$SD_DIR/antiscanner-fail2ban.service" << 'SD'
[Unit]
Description=AntiScanner Fail2ban watcher
After=network-online.target rsyslog.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/antiscanner fail2ban run
Restart=always
RestartSec=10
StandardOutput=append:/var/log/antiscanner_fail2ban.log
StandardError=append:/var/log/antiscanner_fail2ban.log
[Install]
WantedBy=multi-user.target
SD

    cat > "$SD_DIR/antiscanner-honeypot.service" << 'SD'
[Unit]
Description=AntiScanner Honeypot listener
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/antiscanner honeypot run
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SD

    cat > "$SD_DIR/antiscanner-update.service" << 'SD'
[Unit]
Description=AntiScanner blocklist update
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/antiscanner update
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
SD

    cat > "$SD_DIR/antiscanner-unban.service" << 'SD'
[Unit]
Description=AntiScanner auto-unban
[Service]
Type=oneshot
ExecStart=/usr/local/bin/antiscanner fail2ban unban-expired
SD

    cat > "$SD_DIR/antiscanner-unban.timer" << 'SD'
[Unit]
Description=AntiScanner unban timer
[Timer]
OnCalendar=*:0/10
Persistent=true
[Install]
WantedBy=timers.target
SD

    systemctl daemon-reload
    ok "Systemd сервисы созданы"
}

setup_cron() {
    step "Настройка CRON"
    local lines="20 3 * * * /usr/local/bin/antiscanner update >> /var/log/antiscanner_update.log 2>&1
0 9 * * * /usr/local/bin/antiscanner report >> /var/log/antiscanner_update.log 2>&1
*/5 * * * * /usr/local/bin/antiscanner watch >> /var/log/antiscanner_alerts.log 2>&1"
    (crontab -l 2>/dev/null | grep -vF 'antiscanner' || true; echo "$lines") | crontab -
    ok "CRON настроен"
}

first_blocklist_run() {
    step "Первичная загрузка блоклиста"
    info "Скачивание и применение правил..."
    if "$BIN" update; then
        ok "Блоклист загружен и применён"
    else
        warn "Не удалось загрузить блоклист"
        warn "Запустите вручную: sudo antiscanner update"
    fi
}

activate_services() {
    step "Активация сервисов"

    if systemctl enable antiscanner-update.service 2>/dev/null; then
        ok "antiscanner-update.service: включён для автозапуска"
    fi

    if systemctl enable --now antiscanner-unban.timer 2>/dev/null; then
        ok "antiscanner-unban.timer: запущен"
    fi

    echo
    read -rp "Включить Fail2ban (защита от brute-force SSH)? [Y/n]: " a
    if [[ ! "$a" =~ ^[Nn]$ ]]; then
        if systemctl enable --now antiscanner-fail2ban.service 2>/dev/null; then
            ok "Fail2ban запущен"
        else
            warn "Не удалось запустить Fail2ban"
        fi
    else
        info "Fail2ban пропущен (включить позже: antiscanner fail2ban enable)"
    fi

    read -rp "Включить Honeypot (ловушка на портах 23 2222 3389 8080)? [Y/n]: " a
    if [[ ! "$a" =~ ^[Nn]$ ]]; then
        "$BIN" honeypot setup >/dev/null 2>&1 || true
        if systemctl enable --now antiscanner-honeypot.service 2>/dev/null; then
            ok "Honeypot запущен"
        else
            warn "Не удалось запустить Honeypot"
        fi
    else
        info "Honeypot пропущен (включить позже: antiscanner honeypot enable)"
    fi

    read -rp "Включить Rate-limit на SSH (10 запросов/мин)? [Y/n]: " a
    if [[ ! "$a" =~ ^[Nn]$ ]]; then
        if "$BIN" ratelimit setup >/dev/null 2>&1; then
            ok "Rate-limit настроен"
        else
            warn "Не удалось настроить rate-limit"
        fi
    else
        info "Rate-limit пропущен"
    fi
}

interactive_telegram() {
    step "Настройка Telegram (опционально)"
    if [ ! -f "$CONF_DIR/telegram.conf" ]; then
        read -rp "Настроить Telegram уведомления сейчас? [y/N]: " tg
        if [[ "$tg" =~ ^[Yy]$ ]]; then
            "$BIN" telegram setup || warn "Настройка Telegram пропущена"
        else
            info "Пропущено (настроить позже: antiscanner telegram setup)"
        fi
    else
        ok "Telegram уже настроен"
    fi
}

# =============== ПОЛНАЯ УСТАНОВКА ===============
do_install() {
    check_internet
    ensure_main_script || return 1

    detect_existing_install
    if [ "${#EXISTING_ARTIFACTS[@]}" -gt 0 ]; then
        echo
        echo -e "${B_YELLOW}Обнаружена предыдущая установка:${NC}"
        for i in "${EXISTING_ARTIFACTS[@]}"; do
            echo -e "  ${B_YELLOW}•${NC} $i"
        done
        echo
        read -rp "Очистить и установить заново? [y/N]: " a
        if [[ ! "$a" =~ ^[Yy]$ ]]; then
            echo "Отмена."
            return 1
        fi
        purge_existing
        ensure_main_script || return 1
    fi

    detect_firewall_mode
    install_dependencies
    create_config
    setup_rsyslog
    setup_logrotate
    setup_systemd
    setup_cron

    first_blocklist_run
    activate_services
    interactive_telegram

    step "Финальная диагностика"
    "$BIN" test || true
    echo
    "$BIN" status || true

    echo
    echo -e "${B_GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${B_GREEN}║          Установка AntiScanner v${AS_VERSION} завершена          ║${NC}"
    echo -e "${B_GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
}

# =============== ОБНОВЛЕНИЕ ОСНОВНОГО СКРИПТА ===============
do_update_main() {
    step "Обновление основного скрипта antiscanner"

    local candidates=(
        "$PWD_DIR/antiscanner"
        "$PWD_DIR/antiscanner.sh"
        "$INSTALLER_DIR/antiscanner"
        "$INSTALLER_DIR/antiscanner.sh"
    )

    local src=""
    for c in "${candidates[@]}"; do
        if [ -f "$c" ] && [ "$c" != "$BIN" ]; then
            src="$c"
            break
        fi
    done

    if [ -z "$src" ]; then
        echo -e "${B_RED}Файл antiscanner не найден рядом с установщиком${NC}"
        return 1
    fi

    local old_ver new_ver
    old_ver=$(get_installed_version)
    new_ver=$(grep -oP 'antiscanner v\K[0-9]+\.[0-9]+\.[0-9]+' "$src" 2>/dev/null | head -1 || echo "?")

    info "Источник: $src"
    info "Текущая версия:    v$old_ver"
    info "Новая версия:      v$new_ver"

    cp "$src" "$BIN"
    chmod +x "$BIN"
    ok "Основной скрипт обновлён до v$new_ver"

    if [ -f "$CONFIG" ] && ! grep -q 'HONEYPOT_COOLDOWN' "$CONFIG"; then
        echo 'HONEYPOT_COOLDOWN=25' >> "$CONFIG"
        ok "Добавлен HONEYPOT_COOLDOWN в конфиг"
    fi

    echo
    "$BIN" test || true
}

show_quick_stats() {
    if [ ! -f "$BIN" ]; then
        echo -e "${B_RED}AntiScanner не установлен${NC}"
        return
    fi

    local f2b_cnt hp_cnt
    f2b_cnt=$(ipset_count "$IPSET_F2B")
    hp_cnt=$(ipset_count "$IPSET_HP")

    echo
    echo -e "${B_CYAN}═══ Быстрая статистика ═══${NC}"
    echo -e "  Версия:               ${B_GREEN}$(get_installed_version)${NC}"
    echo -e "  Fail2ban забанено:    ${B_YELLOW}${f2b_cnt}${NC}"
    echo -e "  Honeypot забанено:    ${B_YELLOW}${hp_cnt}${NC}"

    if iptables -L "$IPT_CHAIN" -n &>/dev/null; then
        local rules; rules=$(iptables -S "$IPT_CHAIN" 2>/dev/null | grep -c '^-A .* -j DROP' || echo 0)
        echo -e "  Блоклист правил:      ${B_YELLOW}${rules}${NC}"
    fi

    if [ -f /var/log/antiscanner_blocked.log ]; then
        local today_blocked; today_blocked=$(grep -c "$(date '+%b %e')" /var/log/antiscanner_blocked.log 2>/dev/null || echo 0)
        echo -e "  Атак сегодня:         ${B_YELLOW}${today_blocked}${NC}"
    fi

    echo
}

# =============== МЕНЮ ===============
show_main_menu() {
    echo
    echo -e "${B_CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${B_CYAN}║${B_WHITE}                ANTISCANNER v${AS_VERSION}                        ${B_CYAN}║${NC}"
    echo -e "${B_CYAN}║${B_WHITE}              Главное меню действий                       ${B_CYAN}║${NC}"
    echo -e "${B_CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

    if [ -f "$BIN" ]; then
        local installed; installed=$(get_installed_version)
        if [ "$installed" = "$AS_VERSION" ]; then
            echo -e "  Установлено: ${B_GREEN}v${installed}${NC} (актуальная)"
        else
            echo -e "  Установлено: ${B_YELLOW}v${installed}${NC} (доступна v${AS_VERSION})"
        fi
    else
        echo -e "  Установлено: ${B_RED}не установлено${NC}"
    fi

    echo
    echo -e "  ${B_GREEN}1)${NC} Установить AntiScanner (полная установка)"
    echo -e "  ${B_GREEN}2)${NC} Переустановить (удалить старое + установить)"
    echo -e "  ${B_GREEN}3)${NC} Обновить только основной скрипт"
    echo -e "  ${B_RED}4)${NC} Полностью удалить AntiScanner"
    echo -e "  ${B_CYAN}5)${NC} Показать статус"
    echo -e "  ${B_CYAN}6)${NC} Запустить диагностику"
    echo -e "  ${B_CYAN}7)${NC} Обновить блоклист сейчас"
    echo -e "  ${B_CYAN}8)${NC} Быстрая статистика"
    echo -e "  ${B_YELLOW}0)${NC} Выход"
    echo
}

run_menu() {
    while true; do
        show_main_menu
        read -rp "Выберите действие [0-8]: " choice
        echo

        case "$choice" in
            1)
                do_install || true
                read -rp "Нажмите Enter для возврата в меню..."
                ;;
            2)
                detect_existing_install
                if [ "${#EXISTING_ARTIFACTS[@]}" -gt 0 ]; then
                    echo -e "${B_YELLOW}Будет удалена предыдущая установка${NC}"
                    read -rp "Подтвердите [yes]: " c
                    if [ "$c" = "yes" ]; then
                        purge_existing
                        do_install || true
                    else
                        echo "Отмена."
                    fi
                else
                    do_install || true
                fi
                read -rp "Нажмите Enter для возврата в меню..."
                ;;
            3)
                do_update_main || true
                read -rp "Нажмите Enter для возврата в меню..."
                ;;
            4)
                full_uninstall || true
                read -rp "Нажмите Enter для возврата в меню..."
                ;;
            5)
                if [ -f "$BIN" ]; then
                    "$BIN" status || true
                else
                    echo -e "${B_RED}AntiScanner не установлен${NC}"
                fi
                read -rp "Нажмите Enter для возврата в меню..."
                ;;
            6)
                if [ -f "$BIN" ]; then
                    "$BIN" test || true
                else
                    echo -e "${B_RED}AntiScanner не установлен${NC}"
                fi
                read -rp "Нажмите Enter для возврата в меню..."
                ;;
            7)
                if [ -f "$BIN" ]; then
                    "$BIN" update || true
                else
                    echo -e "${B_RED}AntiScanner не установлен${NC}"
                fi
                read -rp "Нажмите Enter для возврата в меню..."
                ;;
            8)
                show_quick_stats
                read -rp "Нажмите Enter для возврата в меню..."
                ;;
            0|q|Q|exit|quit)
                echo "До свидания!"
                exit 0
                ;;
            *)
                echo -e "${B_RED}Неверный выбор${NC}"
                sleep 1
                ;;
        esac
    done
}

main() {
    [ "$EUID" -ne 0 ] && die "Запустите с sudo: sudo bash $0"

    clear
    cat << BANNER
  ┌─────────────────────────────────────────────────────────┐
  │   ╔═╗┌┐┌┌┬┐┬╔═╗┌─┐┌─┐┌┐┌┌┐┌┌─┐┬─┐                       │
  │   ╠═╣│││ │ │╚═╗│  ├─┤│││││││├┤├┬┘                       │
  │   ╩ ╩┘└┘ ┴ ┴╚═╝└─┘┴ ┴┘└┘┘└┘└─┘┴└─  v${AS_VERSION}               │
  │                                                         │
  │       Установщик с главным меню                         │
  └─────────────────────────────────────────────────────────┘
BANNER

    if [[ "${1:-}" == "--uninstall" || "${1:-}" == "uninstall" ]]; then
        full_uninstall
        exit 0
    fi
    if [[ "${1:-}" == "--install" || "${1:-}" == "install" ]]; then
        check_ubuntu
        do_install
        exit 0
    fi
    if [[ "${1:-}" == "--update" || "${1:-}" == "update" ]]; then
        do_update_main
        exit 0
    fi
    if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
        echo "Installer: v${AS_VERSION}"
        echo "Installed: v$(get_installed_version)"
        exit 0
    fi

    check_ubuntu
    run_menu
}

main "$@"
