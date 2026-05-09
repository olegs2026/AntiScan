#!/bin/bash
# install-antiscanner.sh — установщик AntiScanner v3.3.3 для Ubuntu 24.04
# Все фиксы: pipefail+grep, check_internet, UFW cleanup, version compare, netcat
set -eE
set -o pipefail

BOLD='\033[1m'; DIM='\033[2m'
B_CYAN='\033[1;36m'; B_GREEN='\033[1;32m'; B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'; B_MAGENTA='\033[1;35m'; B_WHITE='\033[1;37m'; NC='\033[0m'

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

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PWD_DIR="$(pwd)"

EXISTING_ARTIFACTS=()
MODE=""
HONEYPOT_PORTS=""

ok()    { echo -e "  ${B_GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${B_RED}✗${NC} $*" >&2; }
warn()  { echo -e "  ${B_YELLOW}⚠${NC} $*"; }
info()  { echo -e "  ${DIM}ⓘ${NC} $*"; }
step()  { echo -e "\n${B_CYAN}▶ $*${NC}"; }

die() {
    echo -e "\n${B_RED}✗ ОШИБКА: $*${NC}" >&2
    echo -e "${B_YELLOW}Установка прервана на строке ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}
trap 'die "Команда упала с кодом $?: \"$BASH_COMMAND\""' ERR

# =============== Проверка Ubuntu 24.x ===============
check_ubuntu_24() {
    step "Проверка ОС — требуется Ubuntu 24.x"

    if [ ! -f /etc/os-release ]; then
        die "Файл /etc/os-release не найден"
    fi

    set +u
    . /etc/os-release
    set -u

    if [ "${ID:-}" != "ubuntu" ]; then
        echo
        echo -e "${B_YELLOW}⚠ ОС: ${PRETTY_NAME:-${ID:-?}} (не Ubuntu)${NC}"
        read -rp "Продолжить на свой риск? [y/N]: " a
        [[ ! "$a" =~ ^[Yy]$ ]] && { echo "Отмена"; exit 0; }
        return 0
    fi

    if [[ "${VERSION_ID:-}" =~ ^24\. ]]; then
        ok "Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-}) — полностью поддерживается"
    elif [[ "${VERSION_ID:-}" =~ ^22\. ]]; then
        warn "Ubuntu ${VERSION_ID} — должно работать, но не тестировалось"
        read -rp "Продолжить? [Y/n]: " a
        [[ "$a" =~ ^[Nn]$ ]] && { echo "Отмена"; exit 0; }
    else
        warn "Ubuntu ${VERSION_ID:-?} — не 24.x"
        read -rp "Продолжить? [y/N]: " a
        [[ ! "$a" =~ ^[Yy]$ ]] && { echo "Отмена"; exit 0; }
    fi

    info "Ядро: $(uname -r)"
    info "Архитектура: $(uname -m)"
}

# =============== Fallback-проверка интернета ===============
check_internet() {
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then return 0; fi
        if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then return 0; fi
    fi
    if command -v curl >/dev/null 2>&1; then
        if curl -s --max-time 5 --connect-timeout 3 -o /dev/null http://archive.ubuntu.com 2>/dev/null; then return 0; fi
        if curl -s --max-time 5 --connect-timeout 3 -o /dev/null https://1.1.1.1 2>/dev/null; then return 0; fi
    fi
    if command -v getent >/dev/null 2>&1; then
        if getent hosts archive.ubuntu.com >/dev/null 2>&1; then return 0; fi
    fi
    return 1
}

# =============== Поиск + сравнение версий основного скрипта ===============
ensure_main_script() {
    step "Проверка основного скрипта antiscanner"

    local candidates=(
        "$PWD_DIR/antiscanner"
        "$PWD_DIR/antiscanner.sh"
        "$INSTALLER_DIR/antiscanner"
        "$INSTALLER_DIR/antiscanner.sh"
    )
    local src="" c
    for c in "${candidates[@]}"; do
        [ -f "$c" ] && [ "$c" != "$BIN" ] && { src="$c"; break; }
    done

    _get_ver() {
        grep -oE 'antiscanner v[0-9]+\.[0-9]+(\.[0-9]+)?' "$1" 2>/dev/null \
            | head -1 | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "?"
    }

    # Вариант А: $BIN существует
    if [ -f "$BIN" ]; then
        local installed_ver; installed_ver=$(_get_ver "$BIN")

        if [ -n "$src" ]; then
            local new_ver; new_ver=$(_get_ver "$src")

            if ! cmp -s "$src" "$BIN"; then
                echo
                warn "$BIN существует, но отличается от $src"
                info "Установлена:      ${B_YELLOW}${installed_ver}${NC}"
                info "Локальная копия:  ${B_GREEN}${new_ver}${NC}"
                echo
                read -rp "Обновить $BIN из $src? [Y/n]: " upd
                if [[ ! "$upd" =~ ^[Nn]$ ]]; then
                    cp "$src" "$BIN" || die "Не смог cp $src → $BIN"
                    chmod +x "$BIN"
                    ok "Обновлён до ${new_ver}: $src → $BIN"
                else
                    warn "Оставлена старая версия — возможны ошибки"
                fi
            else
                ok "Основной скрипт (${installed_ver}) идентичен $src"
            fi
        else
            ok "Основной скрипт уже установлен: $BIN (${installed_ver})"
            if [[ "$installed_ver" =~ ^v3\.[0-2] ]]; then
                warn "Версия ${installed_ver} устарела — рекомендуется v3.3.x"
            fi
        fi

        [ -x "$BIN" ] || chmod +x "$BIN" || die "Не смог chmod +x $BIN"
        return 0
    fi

    # Вариант Б: $BIN нет, но есть локальная копия
    if [ -n "$src" ]; then
        info "Найден: $src"
        if ! head -5 "$src" 2>/dev/null | grep -q 'antiscanner'; then
            warn "Файл не похож на antiscanner — продолжаем с риском"
        fi
        mkdir -p "$(dirname "$BIN")"
        cp "$src" "$BIN" || die "Не смог cp $src → $BIN"
        chmod +x "$BIN" || die "Не смог chmod +x $BIN"
        local new_ver; new_ver=$(_get_ver "$BIN")
        ok "Скопирован (${new_ver}): $src → $BIN"
        return 0
    fi

    # Вариант В: ничего нет
    echo
    echo -e "${B_RED}╔══════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${B_RED}║  ✗ ОШИБКА: основной скрипт antiscanner не найден          ║${NC}" >&2
    echo -e "${B_RED}╚══════════════════════════════════════════════════════════╝${NC}" >&2
    echo >&2
    echo -e "${B_YELLOW}Проверены пути:${NC}" >&2
    echo -e "  • $BIN" >&2
    for c in "${candidates[@]}"; do echo -e "  • $c" >&2; done
    echo >&2
    echo -e "${B_WHITE}Как исправить:${NC}" >&2
    echo -e "  ${B_GREEN}1)${NC} ${DIM}cp antiscanner $INSTALLER_DIR/ && sudo bash $0${NC}" >&2
    echo -e "  ${B_GREEN}2)${NC} ${DIM}sudo cp antiscanner $BIN && sudo chmod +x $BIN${NC}" >&2
    exit 1
}

# =============== Пре-реквизиты ===============
check_prerequisites() {
    step "Проверка пререквизитов"

    [ "$EUID" -ne 0 ] && die "Нужны root. Запустите: sudo bash $0"
    ok "Root права OK"

    if ! command -v apt-get >/dev/null 2>&1; then
        die "apt-get не найден — только для Debian/Ubuntu"
    fi
    ok "Пакетный менеджер apt-get найден"

    if check_internet; then
        ok "Интернет доступен"
    else
        die "Нет подключения к интернету"
    fi

    info "Директория установщика: $INSTALLER_DIR"
    info "Текущая директория: $PWD_DIR"
}

# =============== Детект существующей установки ===============
detect_existing_install() {
    local found=()
    [ -f "$BIN_REPORT_OLD" ]         && found+=("$BIN_REPORT_OLD")
    [ -d "$CONF_DIR" ]               && found+=("$CONF_DIR/ ($(ls -1 "$CONF_DIR" 2>/dev/null | wc -l) файлов)")
    [ -f "$RSYSLOG_CONF" ]           && found+=("$RSYSLOG_CONF")
    [ -f "$LOGROTATE_CONF" ]         && found+=("$LOGROTATE_CONF")
    [ -f "$LOGROTATE_CONF_OLD" ]     && found+=("$LOGROTATE_CONF_OLD")

    for unit in antiscanner-update.service antiscanner-fail2ban.service \
                antiscanner-honeypot.service antiscanner-unban.service \
                antiscanner-unban.timer; do
        [ -f "$SD_DIR/$unit" ] && found+=("systemd: $unit")
    done

    local cron_content=""
    cron_content=$(crontab -l 2>/dev/null || true)
    if [ -n "$cron_content" ] && echo "$cron_content" | grep -q 'antiscanner'; then
        local n; n=$(echo "$cron_content" | grep -c 'antiscanner' || true)
        found+=("cron: ${n:-0} задач")
    fi

    if command -v ipset >/dev/null 2>&1; then
        ipset list "$IPSET_F2B" &>/dev/null && found+=("ipset: $IPSET_F2B")
        ipset list "$IPSET_HP"  &>/dev/null && found+=("ipset: $IPSET_HP")
    fi

    if iptables -L "$IPT_CHAIN" -n &>/dev/null; then
        local cnt=""
        cnt=$(iptables -S "$IPT_CHAIN" 2>/dev/null | grep -c '^-A' || true)
        found+=("iptables chain $IPT_CHAIN (${cnt:-0} правил)")
    fi

    local rl_check=""
    rl_check=$(iptables-save 2>/dev/null | grep 'AntiScanner-RateLimit' || true)
    [ -n "$rl_check" ] && found+=("iptables: rate-limit правила")

    if command -v ufw >/dev/null 2>&1; then
        local ufw_check=""
        ufw_check=$(ufw status numbered 2>/dev/null | grep 'AntiScanner-Block' || true)
        if [ -n "$ufw_check" ]; then
            local ufw_cnt; ufw_cnt=$(echo "$ufw_check" | wc -l || echo 0)
            found+=("UFW: ${ufw_cnt:-0} правил")
        fi
    fi

    local logs=(/var/log/antiscanner_*.log)
    [ -e "${logs[0]}" ] && found+=("логи: ${#logs[@]} файлов")

    EXISTING_ARTIFACTS=("${found[@]}")
}

# =============== Полная очистка ===============
purge_existing() {
    step "Полная очистка предыдущей установки"

    # 1. Systemd
    for s in antiscanner-fail2ban antiscanner-honeypot antiscanner-update \
             antiscanner-unban.service antiscanner-unban.timer; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$s"; then
            systemctl disable --now "$s" 2>/dev/null || true
        fi
    done
    rm -f "$SD_DIR"/antiscanner-*.service "$SD_DIR"/antiscanner-*.timer
    systemctl daemon-reload
    ok "Systemd юниты удалены"

    # 2. ipset (сначала убрать iptables-ссылки)
    iptables -D INPUT -m set --match-set "$IPSET_F2B" src -j DROP 2>/dev/null || true
    iptables -D INPUT -m set --match-set "$IPSET_HP"  src -j DROP 2>/dev/null || true
    ipset destroy "$IPSET_F2B" 2>/dev/null || true
    ipset destroy "$IPSET_HP"  2>/dev/null || true
    ok "ipsets удалены"

    # 3. Rate-limit (через переменную, защита от pipefail)
    if command -v iptables-save >/dev/null 2>&1; then
        local rl_rules=""
        rl_rules=$(iptables-save 2>/dev/null | grep 'AntiScanner-RateLimit' || true)
        if [ -n "$rl_rules" ]; then
            local rl_count=0
            while IFS= read -r rule; do
                [ -z "$rule" ] && continue
                local del_rule; del_rule=$(echo "$rule" | sed 's/^-A /-D /' || true)
                if [ -n "$del_rule" ] && eval "iptables $del_rule" 2>/dev/null; then
                    rl_count=$((rl_count+1))
                fi
            done <<< "$rl_rules"
            [ "$rl_count" -gt 0 ] && ok "Rate-limit: удалено $rl_count правил"
        fi
    fi

    # 4. iptables chains
    for c in iptables ip6tables; do
        $c -D INPUT -j "$IPT_CHAIN" 2>/dev/null || true
        $c -F "$IPT_CHAIN" 2>/dev/null || true
        $c -X "$IPT_CHAIN" 2>/dev/null || true
    done
    ok "iptables цепочки удалены"

    [ -d /etc/iptables ] && {
        iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    }

    # 5. UFW (через переменную)
    if command -v ufw >/dev/null 2>&1; then
        local ufw_lines=""
        ufw_lines=$(ufw status numbered 2>/dev/null | grep 'AntiScanner' | tac || true)
        if [ -n "$ufw_lines" ]; then
            local removed=0 num line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                num=$(echo "$line" | grep -oE '^$$\s*[0-9]+$$' | tr -d '[] ' || true)
                if [ -n "$num" ] && ufw --force delete "$num" >/dev/null 2>&1; then
                    removed=$((removed+1))
                fi
            done <<< "$ufw_lines"
            [ "$removed" -gt 0 ] && ok "UFW: удалено $removed правил"
            ufw reload >/dev/null 2>&1 || true
        fi
    fi

    # 6. CRON (через переменную)
    local old_cron=""
    old_cron=$(crontab -l 2>/dev/null || true)
    if [ -n "$old_cron" ]; then
        local new_cron=""
        new_cron=$(echo "$old_cron" | grep -vF 'antiscanner' || true)
        if [ -n "$new_cron" ]; then
            echo "$new_cron" | crontab - 2>/dev/null || true
        else
            crontab -r 2>/dev/null || true
        fi
    fi
    ok "CRON очищен"

    # 7. Файлы
    rm -f "$RSYSLOG_CONF"
    systemctl restart rsyslog 2>/dev/null || true
    rm -f "$LOGROTATE_CONF" "$LOGROTATE_CONF_OLD"
    rm -rf "$CONF_DIR"
    rm -f /var/log/antiscanner_*.log "$BIN_REPORT_OLD"
    ok "Конфиги и логи удалены"
    info "Основной скрипт $BIN сохранён"
}

handle_existing() {
    detect_existing_install
    if [ "${#EXISTING_ARTIFACTS[@]}" -eq 0 ]; then
        ok "Предыдущая установка не обнаружена"
        return 0
    fi

    echo
    echo -e "${B_YELLOW}⚠ Обнаружены признаки предыдущей установки:${NC}"
    local i
    for i in "${EXISTING_ARTIFACTS[@]}"; do
        echo -e "  ${B_YELLOW}•${NC} $i"
    done
    echo
    echo -e "${B_WHITE}Варианты:${NC}"
    echo -e "  ${B_GREEN}1)${NC} Удалить всё и переустановить с нуля ${B_CYAN}(рекомендуется)${NC}"
    echo -e "  ${B_YELLOW}2)${NC} Продолжить поверх"
    echo -e "  ${B_RED}3)${NC} Отмена"
    echo
    read -rp "Ваш выбор [1/2/3]: " choice

    case "$choice" in
        1)
            read -rp "$(echo -e ${B_RED}Подтвердите [yes]:${NC} )" confirm
            [ "$confirm" != "yes" ] && { echo "Отмена"; exit 0; }
            if [ -d "$CONF_DIR" ]; then
                local backup="/root/antiscanner-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
                if tar czf "$backup" -C / "etc/antiscanner" 2>/dev/null; then
                    ok "Бэкап: $backup"
                else
                    warn "Бэкап не создан"
                fi
            fi
            purge_existing
            ;;
        2) warn "Продолжаем поверх" ;;
        *) echo "Отмена"; exit 0 ;;
    esac
}

detect_firewall_mode() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qiE '^\s*Status:\s*active'; then
        MODE="ufw"
    else
        MODE="iptables"
    fi
    info "Режим фаервола: ${B_MAGENTA}$MODE${NC}"
}

# =============== Установка зависимостей ===============
install_dependencies() {
    step "Установка зависимостей (Ubuntu 24.04)"

    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get update -qq 2>&1 | tail -5; then
        warn "apt-get update дал предупреждения"
    fi

    local base_pkgs="curl python3 rsyslog ipset netcat-traditional iputils-ping cron hostname"
    local fw_pkgs=""

    if [ "$MODE" = "iptables" ]; then
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        fw_pkgs="iptables iptables-persistent"
    else
        if dpkg -l 2>/dev/null | grep -q iptables-persistent; then
            apt-get purge -y -qq iptables-persistent >/dev/null 2>&1 || true
            info "iptables-persistent удалён (конфликт с UFW)"
        fi
    fi

    if ! apt-get install -y -qq $base_pkgs $fw_pkgs 2>&1 | tail -10; then
        die "Не удалось установить пакеты"
    fi

    # Переключаем nc на traditional (НЕ удаляя openbsd — может быть зависимостью)
    if [ -x /bin/nc.traditional ] && command -v update-alternatives >/dev/null 2>&1; then
        if update-alternatives --set nc /bin/nc.traditional >/dev/null 2>&1; then
            ok "nc → /bin/nc.traditional"
        else
            update-alternatives --install /usr/bin/nc nc /bin/nc.traditional 60 >/dev/null 2>&1 || true
            update-alternatives --set nc /bin/nc.traditional >/dev/null 2>&1 || warn "Не смог переключить alternative"
        fi
    fi

    for pkg in curl python3 ipset iptables ss; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            die "Команда '$pkg' не найдена после установки"
        fi
    done
    ok "Базовые пакеты установлены"

    if [ -x /bin/nc.traditional ]; then
        ok "netcat-traditional: /bin/nc.traditional"
    else
        die "netcat-traditional не установился — honeypot работать не будет"
    fi

    systemctl enable --now cron >/dev/null 2>&1 || warn "cron не стартанул"

    if [ "$MODE" = "iptables" ]; then
        ok "iptables-persistent установлен"
    fi
}

create_config() {
    step "Создание конфига"
    mkdir -p "$CONF_DIR"
    chmod 755 "$CONF_DIR"

    for f in whitelist.txt current.list previous.list watch.state \
             alerts.seen fail2ban.state fail2ban.bans geoip.cache \
             protected.list last.diff; do
        touch "$CONF_DIR/$f"
    done

    if [ ! -f "$CONFIG" ]; then
        cat > "$CONFIG" << 'CFG'
# === AntiScanner v3.3.3 Configuration (Ubuntu 24.04) ===

# --- Real-time alerts (watch) ---
ALERT_THRESHOLD=3
ALERT_WINDOW=300
ALERT_COOLDOWN=3600

# --- Fail2ban ---
F2B_MAX_FAILS=3
F2B_WINDOW=600
F2B_BAN_SECONDS=86400

# --- Honeypot ---
HONEYPOT_PORTS="23 2222 3389 8080"

# --- Rate limiting ---
RATELIMIT_ENABLED=true
RATELIMIT_PORTS="22"
RATELIMIT_RATE="10/min"
RATELIMIT_BURST=15

# --- Флаги уведомлений (true/false) ---
NOTIFY_ALERTS=true
NOTIFY_REPORT=true
NOTIFY_HONEYPOT=false
NOTIFY_FAIL2BAN=false

# --- Блоклист ---
BLOCKLIST_URL="https://gist.githubusercontent.com/sngvy/07cee7ac810c9d222fbebddff8c1d1b8/raw/blacklist.txt"

# --- Telegram (IPv4 для обхода DPI) ---
TG_API_IPV4="149.154.167.220"
CFG
        chmod 640 "$CONFIG"
        ok "Создан $CONFIG"
    else
        info "Конфиг уже существует"
        local migrated=0
        for pair in "NOTIFY_ALERTS=true" "NOTIFY_REPORT=true" \
                    "NOTIFY_HONEYPOT=false" "NOTIFY_FAIL2BAN=false"; do
            local key="${pair%%=*}"
            if ! grep -q "^${key}=" "$CONFIG" 2>/dev/null; then
                echo "$pair" >> "$CONFIG"
                migrated=1
            fi
        done
        [ "$migrated" = "1" ] && ok "Миграция: добавлены NOTIFY_* флаги"
    fi

    for f in update blocked alerts fail2ban honeypot; do
        touch "/var/log/antiscanner_${f}.log"
        chmod 644 "/var/log/antiscanner_${f}.log"
    done
    ok "Лог-файлы созданы"
}

setup_rsyslog() {
    step "Настройка rsyslog (RainerScript)"
    cat > "$RSYSLOG_CONF" << 'RS'
if ($msg contains "HONEYPOT-HIT") then {
    action(type="omfile" file="/var/log/antiscanner_honeypot.log")
    stop
}
if ($msg contains "ANTISCANNER-BLOCK") then {
    action(type="omfile" file="/var/log/antiscanner_blocked.log")
    stop
}
if ($msg contains "[UFW BLOCK]") then {
    action(type="omfile" file="/var/log/antiscanner_blocked.log")
}
RS

    local rsyslog_check=""
    rsyslog_check=$(rsyslogd -N1 2>&1 || true)
    if echo "$rsyslog_check" | grep -qi 'error\|invalid'; then
        warn "rsyslog config имеет предупреждения"
    fi
    systemctl restart rsyslog || warn "rsyslog не перезапустился"
    ok "rsyslog настроен"

    logger -t antiscanner "HONEYPOT-HIT: SRC=0.0.0.0 DPT=0 (install test)" 2>/dev/null || true
    sleep 1
    if grep -q "install test" /var/log/antiscanner_honeypot.log 2>/dev/null; then
        ok "Запись через rsyslog работает"
        sed -i '/install test/d' /var/log/antiscanner_honeypot.log 2>/dev/null || true
    else
        info "rsyslog не записал — honeypot будет писать напрямую (это OK)"
    fi
}

setup_logrotate() {
    step "Настройка logrotate"
    cat > "$LOGROTATE_CONF" << 'LR'
/var/log/antiscanner_update.log
/var/log/antiscanner_blocked.log
/var/log/antiscanner_alerts.log
/var/log/antiscanner_fail2ban.log
/var/log/antiscanner_honeypot.log
{
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
Description=AntiScanner Fail2ban watcher (SSH)
After=network-online.target rsyslog.service ssh.service
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
Description=AntiScanner blocklist update on boot
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
Description=AntiScanner auto-unban expired IPs

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
    ok "Systemd юниты созданы"
}

# =============== CRON (через переменные) ===============
setup_cron() {
    step "Настройка CRON"

    local cron_lines="20 3 * * * /usr/local/bin/antiscanner update >> /var/log/antiscanner_update.log 2>&1
0 9 * * * /usr/local/bin/antiscanner report >> /var/log/antiscanner_update.log 2>&1
*/5 * * * * /usr/local/bin/antiscanner watch >> /var/log/antiscanner_alerts.log 2>&1"

    local current_cron=""
    current_cron=$(crontab -l 2>/dev/null || true)

    local filtered_cron=""
    if [ -n "$current_cron" ]; then
        filtered_cron=$(echo "$current_cron" | grep -vF 'antiscanner' || true)
    fi

    if [ -n "$filtered_cron" ]; then
        printf '%s\n%s\n' "$filtered_cron" "$cron_lines" | crontab -
    else
        echo "$cron_lines" | crontab -
    fi

    ok "CRON: 03:20 update, 09:00 report, */5мин watch"
}

fix_hostname() {
    step "Проверка /etc/hosts"
    if ! grep -q "$(hostname)" /etc/hosts 2>/dev/null; then
        echo "127.0.1.1 $(hostname)" >> /etc/hosts
        ok "Добавлена запись в /etc/hosts"
    else
        info "hostname уже в /etc/hosts"
    fi
}

interactive_setup() {
    step "Настройка Telegram (опционально)"
    if [ ! -f "$CONF_DIR/telegram.conf" ]; then
        read -rp "Настроить Telegram уведомления? [Y/n]: " tg
        if [[ ! "$tg" =~ ^[Nn]$ ]]; then
            "$BIN" telegram setup || warn "Настройка пропущена"
        fi
    else
        ok "Telegram уже настроен"
    fi

    step "Активация модулей защиты"

    read -rp "Honeypot (порты ${HONEYPOT_PORTS:-23 2222 3389 8080})? [Y/n]: " hp
    if [[ ! "$hp" =~ ^[Nn]$ ]]; then
        "$BIN" honeypot setup >/dev/null 2>&1 || true
        systemctl enable --now antiscanner-honeypot.service 2>/dev/null || warn "Honeypot не запустился"
        ok "Honeypot включён"
    fi

    read -rp "Rate-limit на SSH (22, 10/мин)? [Y/n]: " rl
    if [[ ! "$rl" =~ ^[Nn]$ ]]; then
        "$BIN" ratelimit setup >/dev/null 2>&1 || warn "Rate-limit не настроен"
        ok "Rate-limit включён"
    fi

    read -rp "Fail2ban (3 fail / 10мин)? [Y/n]: " f2b
    if [[ ! "$f2b" =~ ^[Nn]$ ]]; then
        systemctl enable --now antiscanner-fail2ban.service 2>/dev/null || warn "Fail2ban не запустился"
        ok "Fail2ban включён"
    fi

    read -rp "Авто-обновление блоклиста при загрузке? [Y/n]: " aup
    if [[ ! "$aup" =~ ^[Nn]$ ]]; then
        systemctl enable antiscanner-update.service 2>/dev/null || warn "Auto-update не активирован"
        ok "Auto-update включён"
    fi

    systemctl enable --now antiscanner-unban.timer 2>/dev/null || true
    ok "Auto-unban таймер активирован"

    if [ -f "$CONF_DIR/telegram.conf" ]; then
        step "Шумность уведомлений в Telegram"
        info "По умолчанию: alerts/report — вкл; honeypot/fail2ban — молчат"
        echo
        read -rp "Слать КАЖДОЕ попадание в Honeypot в TG? [y/N]: " nhp
        if [[ "$nhp" =~ ^[Yy]$ ]]; then
            sed -i 's/^NOTIFY_HONEYPOT=.*/NOTIFY_HONEYPOT=true/' "$CONFIG"
            ok "NOTIFY_HONEYPOT=true"
        else
            info "Honeypot молчит. Включить: antiscanner honeypot verbose"
        fi

        read -rp "Слать КАЖДЫЙ бан Fail2ban в TG? [y/N]: " nf2b
        if [[ "$nf2b" =~ ^[Yy]$ ]]; then
            sed -i 's/^NOTIFY_FAIL2BAN=.*/NOTIFY_FAIL2BAN=true/' "$CONFIG"
            ok "NOTIFY_FAIL2BAN=true"
        else
            info "Fail2ban молчит. Включить: antiscanner fail2ban verbose"
        fi
    fi
}

first_run() {
    step "Первичная загрузка блоклиста"
    if "$BIN" update; then
        ok "Блоклист загружен"
    else
        warn "Первичная загрузка не удалась — запустите 'antiscanner update' вручную"
    fi
}

final_check() {
    step "Самодиагностика"
    "$BIN" test || warn "В тесте есть предупреждения"
    echo
    "$BIN" status || true
}

main() {
    clear
    cat << 'BANNER'

  ┌─────────────────────────────────────────────────────────┐
  │   ╔═╗┌┐┌┌┬┐┬╔═╗┌─┐┌─┐┌┐┌┌┐┌┌─┐┬─┐                      │
  │   ╠═╣│││ │ │╚═╗│  ├─┤│││││││├┤ ├┬┘                     │
  │   ╩ ╩┘└┘ ┴ ┴╚═╝└─┘┴ ┴┘└┘┘└┘└─┘┴└─  v3.3.3               │
  │                                                         │
  │   Для Ubuntu 24.04 LTS                                  │
  │   blocklist + fail2ban + honeypot + ratelimit +         │
  │   geoip + telegram + notify-flags                       │
  └─────────────────────────────────────────────────────────┘

BANNER

    check_ubuntu_24
    check_prerequisites
    ensure_main_script
    handle_existing
    detect_firewall_mode
    fix_hostname
    install_dependencies
    create_config
    setup_rsyslog
    setup_logrotate
    setup_systemd
    setup_cron

    HONEYPOT_PORTS=$(grep '^HONEYPOT_PORTS=' "$CONFIG" 2>/dev/null | cut -d'"' -f2 || echo "23 2222 3389 8080")

    interactive_setup
    first_run
    final_check

    echo
    echo -e "${B_GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${B_GREEN}║         ✔ УСТАНОВКА ЗАВЕРШЕНА (v3.3.3 / Ubuntu 24)        ║${NC}"
    echo -e "${B_GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${B_WHITE}Команды:${NC}"
    echo -e "  ${B_MAGENTA}antiscanner status${NC}              — статус"
    echo -e "  ${B_MAGENTA}antiscanner report --24h${NC}        — отчёт за сутки"
    echo -e "  ${B_MAGENTA}antiscanner honeypot list${NC}       — пойманные honeypot"
    echo -e "  ${B_MAGENTA}antiscanner fail2ban list${NC}       — забаненные f2b"
    echo -e "  ${B_MAGENTA}antiscanner test${NC}                — самодиагностика"
    echo
    echo -e "${B_WHITE}Управление:${NC}"
    echo -e "  ${B_MAGENTA}antiscanner notify status${NC}              — шум/тишина"
    echo -e "  ${B_MAGENTA}antiscanner honeypot silent|verbose${NC}"
    echo -e "  ${B_MAGENTA}antiscanner fail2ban silent|verbose${NC}"
    echo -e "  ${B_MAGENTA}antiscanner honeypot enable|disable${NC}"
    echo -e "  ${B_MAGENTA}antiscanner fail2ban enable|disable${NC}"
    echo
    echo -e "  ${B_MAGENTA}antiscanner help${NC}                — всё"
    echo
    echo -e "${B_WHITE}Конфиг:${NC}     ${DIM}$CONFIG${NC}"
    echo -e "${B_WHITE}Логи:${NC}       ${DIM}/var/log/antiscanner_*.log${NC}"
    echo
    echo -e "${B_CYAN}Удачи! 🛡️${NC}"
    echo
}

main "$@"
