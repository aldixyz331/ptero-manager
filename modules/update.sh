#!/bin/bash

function update_panel() {
    require_root || return 1
    require_panel || return 1
    acquire_lock || { pause; return 1; }
    trap '
        cd "$PANEL_DIR" 2>/dev/null && php artisan up >/dev/null 2>&1 || true
        release_lock
    ' EXIT INT TERM

    if [ "${AUTO_BACKUP_BEFORE_UPDATE:-1}" = "1" ] && [ -f "$AUTO_BACKUP_CNF" ]; then
        echo -e "${BLUE}[*] Pre-update backup otomatis...${NC}"
        local _pre_pass
        _pre_pass=$(awk -F= '/^[[:space:]]*password[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, "", $0); print; exit}' "$AUTO_BACKUP_CNF")
        if [ -n "$_pre_pass" ]; then
            backup_system_with_password "$_pre_pass" "no"
            local _bprc=$?
            _pre_pass=""
            if [ $_bprc -ne 0 ]; then
                echo -e "${YELLOW}Pre-update backup gagal. Lanjut update? (tidak disarankan)${NC}"
                confirm_action "Lanjut update tanpa backup?" || { release_lock; trap - EXIT INT TERM; return 1; }
            fi
        fi
    fi

    cd "$PANEL_DIR" || { release_lock; trap - EXIT INT TERM; return 1; }

    local tmp="/tmp/panel.tar.gz.new"
    rm -f "$tmp"
    echo -e "${BLUE}[*] Download panel terbaru...${NC}"
    if ! curl -fsSL --retry 3 --max-time 300 \
            https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
            -o "$tmp"; then
        rm -f "$tmp"
        fail "Gagal download panel.tar.gz. Update dibatalkan, panel TIDAK diubah."
        return 1
    fi
    if ! tar -tzf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        fail "panel.tar.gz rusak/tidak valid. Update dibatalkan, panel TIDAK diubah."
        return 1
    fi

    php artisan down --message="Sedang update, tunggu sebentar." >/dev/null 2>&1 || true

    if ! tar -xzf "$tmp" -C "$PANEL_DIR"; then
        rm -f "$tmp"
        fail "Ekstrak panel.tar.gz gagal."
        return 1
    fi
    rm -f "$tmp"

    chmod -R 755 storage bootstrap/cache 2>/dev/null || true
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader \
        || { fail "composer install gagal."; return 1; }
    php artisan view:clear >/dev/null 2>&1 || true
    php artisan config:clear >/dev/null 2>&1 || true
    if ! php artisan migrate --seed --force; then
        fail "Migrasi database gagal. Panel akan dikembalikan ke mode online."
        return 1
    fi
    php artisan queue:restart >/dev/null 2>&1 || true
    chown -R www-data:www-data "$PANEL_DIR"
    php artisan up >/dev/null 2>&1 || true
    systemctl restart pteroq nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true

    log_msg "Panel diupdate"
    notify_detail "UPDATE PANEL" "Update panel selesai sukses."
    echo -e "${GREEN}Panel berhasil diupdate.${NC}"
    release_lock
    trap - EXIT INT TERM
    pause
}

function update_wings_only() {
    require_root || return 1
    if [ "${AUTO_BACKUP_BEFORE_UPDATE:-1}" = "1" ] && [ -f "$AUTO_BACKUP_CNF" ]; then
        echo -e "${BLUE}[*] Pre-update backup wings_config...${NC}"
        local _pre_pass
        _pre_pass=$(awk -F= '/^[[:space:]]*password[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, "", $0); print; exit}' "$AUTO_BACKUP_CNF")
        if [ -n "$_pre_pass" ]; then
            backup_system_with_password "$_pre_pass" "no"
            _pre_pass=""
        fi
    fi
    echo -e "${BLUE}[*] Update Wings ke versi terbaru...${NC}"
    local was_running=0
    systemctl is-active --quiet wings && was_running=1
    systemctl stop wings 2>/dev/null || true
    if ! install_wings_binary; then
        if [ "$was_running" = "1" ]; then
            systemctl start wings 2>/dev/null || true
        fi
        return 1
    fi
    systemctl start wings 2>/dev/null || true
    log_msg "Wings diupdate"
    echo -e "${GREEN}Wings berhasil diupdate.${NC}"
    pause
}

function deep_maintenance() {
    require_root || return 1
    echo -e "${BLUE}[*] Membersihkan log, cache, Docker, dan update Wings...${NC}"
    find "$PANEL_DIR/storage/logs" -type f -name '*.log' -delete 2>/dev/null || true
    find /var/lib/docker/containers -type f -name '*-json.log' \
        -exec truncate -s 0 {} \; 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true
    systemctl stop wings 2>/dev/null || true
    pkill -9 wings 2>/dev/null || true
    install_wings_binary || return 1
    provision_services || return 1
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx "php${PHP_VERSION}-fpm" pteroq wings 2>/dev/null || true
    else
        fail "Nginx config invalid. Skip restart nginx."
        systemctl restart "php${PHP_VERSION}-fpm" pteroq wings 2>/dev/null || true
    fi
    log_msg "Deep maintenance selesai"
    echo -e "${GREEN}Maintenance selesai.${NC}"
    pause
}

AUTO_UPDATE_SCRIPT="/usr/local/sbin/ptero-auto-update.sh"

function _check_new_panel_version() {
    local tmp="/tmp/ptero-latest-version.json"
    curl -fsSL --max-time 10 "https://api.github.com/repos/pterodactyl/panel/releases/latest" -o "$tmp" 2>/dev/null || return 1
    local ver
    ver=$(jq -r '.tag_name // empty' "$tmp" 2>/dev/null)
    rm -f "$tmp"
    [ -n "$ver" ] && echo "$ver" || return 1
}

function _check_new_wings_version() {
    local tmp="/tmp/ptero-wings-latest.json"
    curl -fsSL --max-time 10 "https://api.github.com/repos/pterodactyl/wings/releases/latest" -o "$tmp" 2>/dev/null || return 1
    local ver
    ver=$(jq -r '.tag_name // empty' "$tmp" 2>/dev/null)
    rm -f "$tmp"
    [ -n "$ver" ] && echo "$ver" || return 1
}

function check_updates_manual() {
    require_root || return 1
    header
    echo -e "${BLUE}Cek Update Keamanan${NC}"
    echo

    echo -e "${CYAN}Panel:${NC}"
    local panel_latest
    panel_latest=$(_check_new_panel_version)
    if [ -n "$panel_latest" ]; then
        local panel_current
        panel_current=$(cd "$PANEL_DIR" 2>/dev/null && php artisan tinker --execute='echo app()->version();' 2>/dev/null | tail -1 || echo "?")
        echo -e "  Terinstall : ${YELLOW}$panel_current${NC}"
        echo -e "  Terbaru    : ${GREEN}$panel_latest${NC}"
        if [ "$panel_current" != "$panel_latest" ] && [ "$panel_latest" != "?" ]; then
            echo -e "  ${YELLOW}>>> Update tersedia!${NC}"
        fi
    else
        echo -e "  ${RED}[FAIL]${NC} Gagal cek versi panel."
    fi

    echo
    echo -e "${CYAN}Wings:${NC}"
    local wings_latest
    wings_latest=$(_check_new_wings_version)
    if [ -n "$wings_latest" ]; then
        local wings_current
        wings_current=$(/usr/local/bin/wings --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "?")
        echo -e "  Terinstall : ${YELLOW}$wings_current${NC}"
        echo -e "  Terbaru    : ${GREEN}$wings_latest${NC}"
        if [ "$wings_current" != "$wings_latest" ] && [ "$wings_latest" != "?" ]; then
            echo -e "  ${YELLOW}>>> Update tersedia!${NC}"
        fi
    else
        echo -e "  ${RED}[FAIL]${NC} Gagal cek versi wings."
    fi

    echo
    echo "1) Update Panel sekarang"
    echo "2) Update Wings sekarang"
    echo "0) Kembali"
    read -r -p "Pilih [0-2]: " UO
    case "$UO" in
        1) update_panel ;;
        2) update_wings_only ;;
    esac
    pause
}

function setup_auto_updates() {
    require_root || return 1
    header
    echo -e "${BLUE}Setup Auto Security Updates${NC}"
    echo
    echo -e "${YELLOW}Aktifkan cron job untuk otomatis:${NC}"
    echo -e "  - Cek versi baru Panel & Wings setiap hari"
    echo -e "  - Apply update jika ada versi baru"
    echo -e "  - Kirim notifikasi via Telegram/Discord"
    echo

    if [ -f /etc/cron.d/ptero-auto-update ]; then
        echo -e "${GREEN}Auto-update sudah aktif.${NC}"
        echo "1) Nonaktifkan auto-update"
        echo "0) Kembali"
        read -r -p "Pilih [0-1]: " AO
        [ "$AO" = "1" ] && {
            rm -f /etc/cron.d/ptero-auto-update "$AUTO_UPDATE_SCRIPT"
            systemctl restart cron 2>/dev/null || true
            log_msg "Auto security updates dinonaktifkan"
            echo -e "${YELLOW}Auto-update dinonaktifkan.${NC}"
        }
        pause
        return 0
    fi

    confirm_action "Aktifkan auto security updates?" || { pause; return 0; }

    local script_path
    script_path=$(readlink -f "$(dirname "$0")/../ptero.sh" 2>/dev/null || printf '%s' "$0")

    cat > "$AUTO_UPDATE_SCRIPT" <<'AUTO'
#!/bin/bash
LOG=/var/log/ptero-manager.log
LOCK=/var/run/ptero-auto-update.lock

exec 9>"$LOCK" || exit 1
flock -n 9 || exit 0

PANEL_DIR="/var/www/pterodactyl"
WINGS_BIN="/usr/local/bin/wings"

notify_msg() {
    local msg="$1"
    echo "[$(date '+%F %T')] $msg" >> "$LOG"
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$msg" \
        --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1 || true
    curl -fsS -H "Content-Type: application/json" -X POST \
        -d "{\"content\": \"$msg\"}" "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
}

# Check Panel
PANEL_LATEST=$(curl -fsSL --max-time 10 "https://api.github.com/repos/pterodactyl/panel/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
if [ -n "$PANEL_LATEST" ] && [ -f "$PANEL_DIR/artisan" ]; then
    cd "$PANEL_DIR"
    PANEL_CURRENT=$(php artisan tinker --execute='echo app()->version();' 2>/dev/null | tail -1)
    if [ -n "$PANEL_CURRENT" ] && [ "$PANEL_CURRENT" != "$PANEL_LATEST" ]; then
        php artisan down --message="Auto update..." >/dev/null 2>&1 || true
        curl -fsSL --retry 3 --max-time 300 "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" -o /tmp/panel.tar.gz.new 2>/dev/null && \
        tar -xzf /tmp/panel.tar.gz.new -C "$PANEL_DIR" 2>/dev/null && \
        composer install --no-dev --optimize-autoloader 2>/dev/null && \
        php artisan migrate --seed --force 2>/dev/null && \
        chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null && \
        notify_msg "*AUTO UPDATE* Panel diupdate ke $PANEL_LATEST" || \
        notify_msg "*AUTO UPDATE GAGAL* Panel $PANEL_LATEST"
        rm -f /tmp/panel.tar.gz.new
        php artisan up >/dev/null 2>&1 || true
    fi
fi

# Check Wings
WINGS_LATEST=$(curl -fsSL --max-time 10 "https://api.github.com/repos/pterodactyl/wings/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
if [ -n "$WINGS_LATEST" ] && [ -f "$WINGS_BIN" ]; then
    WINGS_CURRENT=$("$WINGS_BIN" --version 2>/dev/null | head -1)
    if [ -n "$WINGS_CURRENT" ] && [ "$WINGS_CURRENT" != "$WINGS_LATEST" ]; then
        systemctl stop wings 2>/dev/null || true
        curl -fsSL -o /tmp/wings.new "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64" 2>/dev/null && \
        chmod +x /tmp/wings.new && mv /tmp/wings.new "$WINGS_BIN" && \
        systemctl start wings 2>/dev/null && \
        notify_msg "*AUTO UPDATE* Wings diupdate ke $WINGS_LATEST" || \
        notify_msg "*AUTO UPDATE GAGAL* Wings $WINGS_LATEST"
    fi
fi

rm -f "$LOCK"
AUTO
    chmod 700 "$AUTO_UPDATE_SCRIPT"

    cat > /etc/cron.d/ptero-auto-update <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 6 * * * root /usr/local/sbin/ptero-auto-update.sh >> /var/log/ptero-manager.log 2>&1
CRON
    systemctl restart cron 2>/dev/null || true

    log_msg "Auto security updates diaktifkan"
    echo -e "${GREEN}Auto security updates aktif (cek setiap jam 06:00).${NC}"
    echo -e "${YELLOW}Notifikasi dikirim via Telegram/Discord jika dikonfigurasi.${NC}"
    pause
}
