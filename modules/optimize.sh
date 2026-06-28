#!/bin/bash

function discord_setup() {
    require_root || return 1
    header
    echo -e "${BLUE}Setup Discord Webhook${NC}"
    echo -e "Webhook saat ini: ${CYAN}${DISCORD_WEBHOOK:-belum diset}${NC}"
    echo
    echo "1) Set/ubah URL webhook"
    echo "2) Test kirim pesan"
    echo "3) Hapus webhook"
    echo "0) Kembali"
    read -r -p "Pilih [0-3]: " WH_OPT
    case "$WH_OPT" in
        1)
            read -r -p "URL webhook Discord: " NEW_URL
            if ! echo "$NEW_URL" | grep -Eq '^https://discord(app)?\.com/api/webhooks/'; then
                fail "URL webhook tidak valid."; pause; return 1
            fi
            DISCORD_WEBHOOK="$NEW_URL"
            save_config
            echo -e "${GREEN}Webhook tersimpan.${NC}"
            ;;
        2)
            if [ -z "$DISCORD_WEBHOOK" ]; then
                fail "Webhook belum diset."; pause; return 1
            fi
            notify_detail "TEST" "Pesan test dari Ptero Manager V$SCRIPT_VERSION"
            echo -e "${GREEN}Pesan test dikirim. Cek channel Discord Anda.${NC}"
            ;;
        3)
            DISCORD_WEBHOOK=""
            save_config
            echo -e "${GREEN}Webhook dihapus.${NC}"
            ;;
        *) return 0 ;;
    esac
    pause
}

function restart_all_services() {
    require_root || return 1
    echo -e "${BLUE}[*] Restart semua service Pterodactyl...${NC}"
    for svc in mariadb redis-server "php${PHP_VERSION}-fpm" nginx pteroq wings cloudflared; do
        if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
            echo -n "  - $svc ... "
            if systemctl restart "$svc" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}GAGAL${NC}"
            fi
        fi
    done
    if [ -f "$PANEL_DIR/artisan" ]; then
        cd "$PANEL_DIR" && php artisan queue:restart >/dev/null 2>&1 || true
    fi
    log_msg "Restart semua service"
    pause
}

function check_script_update() {
    require_root || return 1
    header
    if [ -z "$SCRIPT_UPDATE_URL" ]; then
        echo -e "${YELLOW}URL update belum diset.${NC}"
        echo
        read -r -p "Masukkan URL raw script (contoh https://.../ptero.sh) atau kosong untuk batal: " URL
        if [ -z "$URL" ]; then return 0; fi
        SCRIPT_UPDATE_URL="$URL"
        save_config
    fi
    echo -e "${BLUE}Cek versi terbaru dari $SCRIPT_UPDATE_URL ...${NC}"
    local tmp="/tmp/ptero.sh.new"
    if ! curl -fsSL "$SCRIPT_UPDATE_URL" -o "$tmp"; then
        rm -f "$tmp"; fail "Gagal download script terbaru."; pause; return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"; fail "Script terbaru rusak (syntax error)."; pause; return 1
    fi
    local new_ver
    new_ver=$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)
    echo -e "Versi sekarang : ${CYAN}$SCRIPT_VERSION${NC}"
    echo -e "Versi terbaru  : ${CYAN}${new_ver:-unknown}${NC}"
    if [ "$new_ver" = "$SCRIPT_VERSION" ]; then
        echo -e "${GREEN}Sudah versi terbaru.${NC}"
        rm -f "$tmp"; pause; return 0
    fi
    confirm_action "Update script ke versi $new_ver?" || { rm -f "$tmp"; pause; return 0; }
    local current
    current=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    cp -f "$current" "${current}.bak"
    mv -f "$tmp" "$current"
    chmod +x "$current"
    log_msg "Script di-update ke versi $new_ver"
    echo -e "${GREEN}Script berhasil di-update. Backup lama: ${current}.bak${NC}"
    echo -e "${YELLOW}Jalankan ulang script untuk memuat versi baru.${NC}"
    pause
    return 0
}

function generate_wings_config_api() {
    require_root || return 1
    require_panel || return 1
    install_wings_binary || return 1
    header
    echo -e "${BLUE}Generate Wings config.yml dari Panel API${NC}"
    echo -e "${YELLOW}Ambil token konfigurasi dari: Panel > Admin > Nodes > [node] > Configuration > Generate Token${NC}"
    echo
    read -r -p "Panel URL (contoh https://panel.domain.com): " P_URL
    read -r -p "Node ID (angka, lihat di URL admin/nodes/<id>): " N_ID
    read -r -s -p "Token konfigurasi node: " N_TOKEN
    echo
    if [ -z "$P_URL" ] || [ -z "$N_ID" ] || [ -z "$N_TOKEN" ]; then
        fail "Panel URL, Node ID, dan token wajib diisi."; pause; return 1
    fi
    mkdir -p "$WINGS_DIR"
    if ! curl -fsSL -H "Authorization: Bearer $N_TOKEN" -H "Accept: application/vnd.pterodactyl.v1+json" \
            "${P_URL%/}/api/application/nodes/$N_ID/configuration" \
            -o "$WINGS_DIR/config.yml"; then
        fail "Gagal mengambil config dari panel. Cek URL/token/Node ID."; pause; return 1
    fi
    if [ ! -s "$WINGS_DIR/config.yml" ] || ! grep -q '^token:' "$WINGS_DIR/config.yml"; then
        fail "Config yang diterima tidak valid."
        rm -f "$WINGS_DIR/config.yml"; pause; return 1
    fi
    chmod 600 "$WINGS_DIR/config.yml"
    systemctl restart wings 2>/dev/null || true
    log_msg "Wings config.yml di-generate via API untuk node $N_ID"
    echo -e "${GREEN}Wings config tersimpan di $WINGS_DIR/config.yml${NC}"
    pause
}

function export_config() {
    require_root || return 1
    save_config
    local out="/root/ptero-manager-export-$(date +%F_%H-%M-%S).conf"
    cp "$CONFIG_FILE" "$out" 2>/dev/null || true
    {
        echo "# Pterodactyl Manager Export"
        echo "# Versi: $SCRIPT_VERSION  Tanggal: $(date)"
        echo
        [ -f "$PANEL_DIR/.env" ] && grep -E '^(APP_URL|APP_TIMEZONE|DB_DATABASE|DB_USERNAME|TRUSTED_PROXIES)=' "$PANEL_DIR/.env"
        echo
        echo "# Cron auto-backup:"
        cat /etc/cron.d/ptero-manager-backup 2>/dev/null
    } >> "$out"
    chmod 600 "$out"
    echo -e "${GREEN}Konfigurasi diekspor ke: $out${NC}"
    pause
}

function optimize_server() {
    require_root || return 1
    header
    echo -e "${BLUE}[*] Mengoptimasi server untuk mesin kecil...${NC}"
    echo

    local php_ini="/etc/php/${PHP_VERSION}/fpm/conf.d/99-ptero-tuning.ini"
    cat > "$php_ini" <<PHPINI
memory_limit = 256M
upload_max_filesize = 100M
post_max_size = 100M
max_execution_time = 120
opcache.enable = 1
opcache.memory_consumption = 128
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 0
PHPINI
    echo -e "  ${GREEN}[OK]${NC} PHP tuning: $php_ini"

    local my_cnf="/etc/mysql/conf.d/ptero-tuning.cnf"
    cat > "$my_cnf" <<MYCNF
[mysqld]
innodb_buffer_pool_size = 128M
query_cache_type = 1
query_cache_size = 32M
max_connections = 100
wait_timeout = 60
interactive_timeout = 60
MYCNF
    echo -e "  ${GREEN}[OK]${NC} MariaDB tuning: $my_cnf"

    local redis_conf="/etc/redis/conf.d/ptero-tuning.conf"
    mkdir -p /etc/redis/conf.d
    cat > "$redis_conf" <<REDISCONF
maxmemory 128mb
maxmemory-policy allkeys-lru
REDISCONF
    if ! grep -q "include /etc/redis/conf.d" /etc/redis/redis.conf 2>/dev/null; then
        echo "include /etc/redis/conf.d/*.conf" >> /etc/redis/redis.conf
    fi
    echo -e "  ${GREEN}[OK]${NC} Redis tuning: $redis_conf"

    systemctl restart "php${PHP_VERSION}-fpm" mariadb redis-server 2>/dev/null || true
    log_msg "Optimasi server kecil diterapkan"
    echo
    echo -e "${GREEN}Optimasi selesai.${NC} (revert via menu Repair > Revert Optimasi)"
    pause
}

function optimize_revert() {
    require_root || return 1
    echo -e "${BLUE}[*] Membatalkan tuning optimasi...${NC}"
    rm -f "/etc/php/${PHP_VERSION}/fpm/conf.d/99-ptero-tuning.ini"
    rm -f /etc/mysql/conf.d/ptero-tuning.cnf
    rm -f /etc/redis/conf.d/ptero-tuning.conf
    sed -i '\#include /etc/redis/conf.d/\*\.conf#d' /etc/redis/redis.conf 2>/dev/null || true
    systemctl restart "php${PHP_VERSION}-fpm" mariadb redis-server 2>/dev/null || true
    log_msg "Optimasi server di-revert"
    echo -e "${GREEN}Tuning dibatalkan, kembali ke default.${NC}"
    pause
}

function create_swap() {
    require_root || return 1
    if swapon --show | grep -q '/swapfile'; then
        echo -e "${YELLOW}Swapfile sudah aktif.${NC}"
        pause
        return 0
    fi
    read -r -p "Size swap, contoh 2G: " SS
    if [ -z "$SS" ]; then
        fail "Size swap wajib diisi."
        pause
        return 1
    fi
    fallocate -l "$SS" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo -e "${GREEN}Swap aktif.${NC}"
    pause
}

function db_optimize() {
    require_root || return 1
    require_panel || return 1
    read -r -s -p "Password database $DB_USER: " DBP
    echo
    echo -e "${BLUE}[*] Menjalankan OPTIMIZE TABLE + auto-repair...${NC}"
    if mysqlcheck_secure "$DB_USER" "$DBP" -h 127.0.0.1 --auto-repair --optimize "$DB_NAME"; then
        log_msg "Database $DB_NAME dioptimasi"
        echo -e "${GREEN}Optimasi database selesai.${NC}"
    else
        fail "Optimasi gagal. Periksa password / kredensial."
    fi
    pause
}
