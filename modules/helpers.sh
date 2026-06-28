#!/bin/bash

E_FAILURE=1

function die() {
    local msg="$1"
    local code="${2:-$E_FAILURE}"
    echo -e "${RED}FATAL: $msg${NC}" >&2
    log_msg "FATAL: $msg"
    exit "$code"
}

function pause() {
    read -r -p "Tekan Enter untuk lanjut..."
}

function log_msg() {
    local message="$1"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%F %T')] $message" >> "$LOG_FILE" 2>/dev/null || true
}

function status_short() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        printf "${GREEN}UP${NC}"
    elif systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
        printf "${RED}DOWN${NC}"
    else
        printf "${YELLOW}MISS${NC}"
    fi
}

function header() {
    clear 2>/dev/null || true
    local disk_usage mem_usage
    disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo '-')
    mem_usage=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || echo '-')

    local w=63
    local bar; bar=$(printf '─%.0s' $(seq 1 $w))

    echo -e "${CYAN}╭${bar}╮${NC}"
    if [ -n "$CUSTOM_BANNER" ]; then
        printf "${CYAN}│${NC}  ${BOLD}PTERO-MANAGER${NC} ${BLUE}v${SCRIPT_VERSION}${NC}  ${CUSTOM_BANNER}%-*s${CYAN}│${NC}\n" \
            $((w - ${#CUSTOM_BANNER} - 22)) ""
    else
        printf "${CYAN}│${NC}  ${BOLD}PTERO-MANAGER${NC} ${BLUE}v${SCRIPT_VERSION}${NC}  ${DIM}Pterodactyl & Wings Management${NC}%-*s${CYAN}│${NC}\n" \
            $((w - 50)) ""
    fi
    echo -e "${CYAN}╰${bar}╯${NC}"

    local s_wings s_nginx s_db s_redis s_cf s_panel_domain s_backups
    s_wings=$(status_short wings)
    s_nginx=$(status_short nginx)
    s_db=$(status_short mariadb)
    s_redis=$(status_short redis-server)
    s_cf=$(status_short cloudflared)
    s_panel_domain="${PANEL_DOMAIN:-${BLUE}localhost${NC}}"
    if [ -d "$BACKUP_ROOT" ] 2>/dev/null; then
        s_backups=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'ptero_*' 2>/dev/null | wc -l)
    else
        s_backups=0
    fi
    [ -f "$S3_CONFIG" ] && s_s3="${GREEN}configured${NC}" || s_s3="${DIM}not configured${NC}"

    echo -e "${BLUE}╭─ System Status ─${bar:15}╮${NC}"
    printf "${BLUE}│${NC}  ${BOLD}%-10s${NC} %s\n" "Uptime:" "$(uptime -p 2>/dev/null || echo '-')"
    printf "${BLUE}│${NC}  ${BOLD}%-10s${NC} %s\n" "RAM:" "$mem_usage"
    printf "${BLUE}│${NC}  ${BOLD}%-10s${NC} %s\n" "Disk:" "$disk_usage"
    printf "${BLUE}│${NC}  ${BOLD}%-10s${NC} %s\n" "Domain:" "$s_panel_domain"
    printf "${BLUE}│${NC}  ${BOLD}%-10s${NC} W:%s  N:%s  DB:%s  R:%s  CF:%s\n" "Services:" \
        "$s_wings" "$s_nginx" "$s_db" "$s_redis" "$s_cf"
    printf "${BLUE}│${NC}  ${BOLD}%-10s${NC} %s local backup(s)  |  S3: %b\n" "Backups:" "$s_backups" "$s_s3"
    if command -v ifstat >/dev/null 2>&1; then
        printf "${BLUE}│${NC}  ${BOLD}%-10s${NC} %s\n" "Traffic:" "$(ifstat 1 1 2>/dev/null | tail -1 | awk '{print "IN: "$1" KB/s | OUT: "$2" KB/s"}')"
    fi
    echo -e "${BLUE}╰${bar}╯${NC}"
    echo
}

function print_section() {
    local title="$1"
    local w=63
    local inner=$((w - ${#title} - 4))
    if [ $inner -lt 0 ]; then inner=0; fi
    local left=$((inner / 2))
    local right=$((inner - left))
    local lbar rbar
    lbar=$(printf '─%.0s' $(seq 1 $left))
    rbar=$(printf '─%.0s' $(seq 1 $right))
    echo -e "${MAGENTA}╭─${lbar} ${BOLD}${title}${NC} ${MAGENTA}${rbar}╮${NC}"
}

function print_footer() {
    local w=63
    local bar; bar=$(printf '─%.0s' $(seq 1 $w))
    echo -e "${DIM}${bar}${NC}"
    printf "  ${GREEN}v${SCRIPT_VERSION}${NC}  ${DIM}│${NC}  Pilih nomor  ${DIM}│${NC}  ${YELLOW}q${NC}=quit  ${DIM}│${NC}  ${YELLOW}0${NC}=back\n"
}

function notify() {
    local message="$1"
    command -v curl >/dev/null 2>&1 || return 0
    if [ -n "$DISCORD_WEBHOOK" ]; then
        local escaped
        escaped=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
        curl -fsS -H "Content-Type: application/json" -X POST \
            -d "{\"content\": \"$escaped\"}" "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
    fi
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -fsS -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
            --data-urlencode "text=$message" \
            --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi
}

function acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    if ! command -v flock >/dev/null 2>&1; then
        if [ -e "$LOCK_FILE" ]; then
            local pid
            pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                fail "Operasi lain sedang berjalan (PID $pid). Tunggu selesai atau hapus $LOCK_FILE."
                return 1
            fi
        fi
        echo "$$" > "$LOCK_FILE"
        return 0
    fi
    exec 9>"$LOCK_FILE" || { fail "Tidak bisa membuka lock file $LOCK_FILE."; return 1; }
    if ! flock -n 9; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        fail "Operasi lain sedang berjalan${pid:+ (PID $pid)}. Tunggu selesai dulu."
        exec 9>&-
        return 1
    fi
    echo "$$" >&9
    return 0
}

function release_lock() {
    exec 9>&- 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

function sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        echo "-"
    fi
}

function qprint() {
    [ "$QUIET_MODE" = "1" ] && return 0
    echo -e "$@"
}

function notify_detail() {
    local title="$1"
    local body="$2"
    local disk_info mem_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo '-')
    mem_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || echo '-')
    notify "**[$title]** $body | Disk: $disk_info | RAM: $mem_info | $(date '+%F %T')"
}

function fail() {
    echo -e "${RED}ERROR: $1${NC}"
    log_msg "ERROR: $1"
    return 1
}

function confirm_action() {
    local prompt="$1"
    local answer
    echo -e "${YELLOW}$prompt${NC}"
    read -r -p "Ketik 'lanjut' untuk melanjutkan: " answer
    [ "$answer" = "lanjut" ]
}

function require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Jalankan script sebagai root: sudo bash ptero.sh"
        return 1
    fi
}

function require_debian_family() {
    if ! command -v apt >/dev/null 2>&1; then
        fail "Script ini ditujukan untuk Ubuntu/Debian yang memakai apt."
        return 1
    fi
}

function validate_domain() {
    local d="$1"
    d=$(printf '%s' "$d" | sed -E 's#^https?://##; s#/.*$##')
    if echo "$d" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
        printf '%s' "$d"
        return 0
    fi
    return 1
}

function pick_from_list() {
    local prompt="$1"; shift
    local arr=("$@")
    local i=0
    if [ "${#arr[@]}" -eq 0 ]; then
        return 1
    fi
    for item in "${arr[@]}"; do
        i=$((i+1))
        echo -e "  ${CYAN}[$i]${NC} $item" >&2
    done
    local pick
    read -r -p "$prompt " pick
    if ! echo "$pick" | grep -Eq '^[0-9]+$'; then
        return 1
    fi
    if [ "$pick" -lt 1 ] || [ "$pick" -gt "${#arr[@]}" ]; then
        return 1
    fi
    printf '%s' "${arr[$((pick-1))]}"
    return 0
}

function require_panel() {
    if [ ! -f "$PANEL_DIR/artisan" ]; then
        fail "Panel belum ditemukan di $PANEL_DIR."
        pause
        return 1
    fi
}

function validate_db_password() {
    local pass="$1"
    local min="${2:-8}"
    local len=${#pass}
    if [ "$len" -lt "$min" ]; then
        fail "Password terlalu pendek (minimal $min karakter)."
        return 1
    fi
    if [ "$len" -gt 64 ]; then
        fail "Password terlalu panjang (maksimal 64 karakter)."
        return 1
    fi
    if [[ "$pass" =~ [[:space:]] ]]; then
        fail "Password tidak boleh mengandung spasi/tab/newline."
        return 1
    fi
    if [[ ! "$pass" =~ ^[A-Za-z0-9_.@#%+=:,/!~^*()\[\]{}\<\>?\|\;\&-]+$ ]]; then
        fail "Password mengandung karakter terlarang. Hindari: ' \" \` \$ \\ dan whitespace."
        return 1
    fi
    return 0
}

function safe_reload_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        return 0
    fi
    if ! nginx -t >/dev/null 2>&1; then
        fail "Nginx config invalid — tidak di-reload. Jalankan 'nginx -t' untuk detail."
        return 1
    fi
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
}

function _mk_mysql_cnf() {
    local user="$1" pass="$2" host="${3:-127.0.0.1}"
    local cnf
    cnf=$(mktemp /tmp/.ptmycnf.XXXXXX) || return 1
    chmod 600 "$cnf"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$user"
        printf 'password=%s\n' "$pass"
        printf 'host=%s\n' "$host"
    } > "$cnf"
    printf '%s' "$cnf"
}

function mysql_secure() {
    local user="$1" pass="$2"; shift 2
    local cnf rc
    cnf=$(_mk_mysql_cnf "$user" "$pass") || return 1
    mysql --defaults-extra-file="$cnf" "$@"
    rc=$?
    rm -f "$cnf"
    return $rc
}

function mysqldump_secure() {
    local user="$1" pass="$2"; shift 2
    local cnf rc
    cnf=$(_mk_mysql_cnf "$user" "$pass") || return 1
    mysqldump --defaults-extra-file="$cnf" "$@"
    rc=$?
    rm -f "$cnf"
    return $rc
}

function mysqlcheck_secure() {
    local user="$1" pass="$2"; shift 2
    local cnf rc
    cnf=$(_mk_mysql_cnf "$user" "$pass") || return 1
    mysqlcheck --defaults-extra-file="$cnf" "$@"
    rc=$?
    rm -f "$cnf"
    return $rc
}

function mysql_root() {
    if [ -n "$MYSQL_ROOT_PASS" ]; then
        mysql_secure root "$MYSQL_ROOT_PASS" "$@"
    else
        mysql "$@"
    fi
}

function ask_mysql_root_password() {
    read -r -s -p "Password root MariaDB/MySQL (kosongkan jika tanpa password): " MYSQL_ROOT_PASS
    echo
}

function set_env_value() {
    local key="$1"
    local value="$2"
    local file="${3:-$PANEL_DIR/.env}"
    local escaped
    escaped=$(printf '%s' "$value" | sed 's/[&]/\\&/g; s|[/]|\\/|g')
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${escaped}/" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

function service_status_line() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  ${GREEN}[RUNNING]${NC} $service"
    elif systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${service}.service"; then
        echo -e "  ${RED}[STOPPED]${NC} $service"
    else
        echo -e "  ${YELLOW}[MISSING]${NC} $service"
    fi
}

function _panel_clear_artisan_cache() {
    local panel_dir="${1:-$PANEL_DIR}"
    local quiet="${2:-0}"
    local count=0
    cd "$panel_dir" 2>/dev/null || return 0
    local cmd
    for cmd in "view:clear" "cache:clear" "config:clear" "route:clear"; do
        if php artisan "$cmd" >/dev/null 2>&1; then
            count=$((count+1))
            [ "$quiet" = "0" ] && echo -e "  ${GREEN}[OK]${NC} php artisan $cmd"
        else
            [ "$quiet" = "0" ] && echo -e "  ${YELLOW}[SKIP]${NC} php artisan $cmd"
        fi
    done
    rm -f "$panel_dir"/bootstrap/cache/{config,routes,packages,services,events}.php 2>/dev/null || true
    php artisan queue:restart >/dev/null 2>&1 || true
    return "$count"
}

function _panel_opcache_reset() {
    if php -m 2>/dev/null | grep -qi opcache; then
        php -r 'function_exists("opcache_reset") && opcache_reset();' 2>/dev/null || true
        systemctl reload "php${PHP_VERSION}-fpm" 2>/dev/null || true
    fi
}

# ====================================================
# Shared from install.sh (dipakai modul lain)
# ====================================================

function install_wings_binary() {
    echo -e "${BLUE}[*] Menginstall / update Wings...${NC}"
    mkdir -p "$WINGS_DIR"
    local tmp="/tmp/wings.new"
    if ! curl -fsSL -o "$tmp" \
            "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"; then
        rm -f "$tmp"
        fail "Gagal download Wings binary."
        return 1
    fi
    chmod +x "$tmp"
    if ! "$tmp" --version >/dev/null 2>&1; then
        rm -f "$tmp"
        fail "Wings binary baru rusak/tidak valid. Binary lama tidak diganti."
        return 1
    fi
    mv -f "$tmp" /usr/local/bin/wings
    echo -e "${GREEN}[OK]${NC} Wings $(/usr/local/bin/wings --version 2>/dev/null | head -1)"
}

function ensure_self_signed_cert() {
    local cn="${1:-localhost}"
    local dir="/etc/ssl/ptero"
    local crt="$dir/fullchain.pem"
    local key="$dir/privkey.pem"
    mkdir -p "$dir"
    chmod 750 "$dir"
    local need=0
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        need=1
    else
        if ! openssl x509 -in "$crt" -noout -subject 2>/dev/null | grep -q "CN *= *$cn"; then
            need=1
        fi
        if openssl x509 -in "$crt" -noout -checkend $((30*86400)) >/dev/null 2>&1; then
            :
        else
            need=1
        fi
    fi
    if [ "$need" -eq 1 ]; then
        command -v openssl >/dev/null 2>&1 || \
            DEBIAN_FRONTEND=noninteractive apt install -y openssl >/dev/null 2>&1 || true
        openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
            -keyout "$key" -out "$crt" \
            -subj "/CN=$cn/O=Pterodactyl Local/OU=ptero-manager" \
            -addext "subjectAltName=DNS:$cn,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 || true
        chmod 600 "$key"
        chmod 644 "$crt"
    fi
}

function write_nginx_config() {
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    local mode="${DEPLOY_MODE:-tunnel}"
    local server_name="${PANEL_DOMAIN:-_}"

    if [ "$mode" = "public" ]; then
        local cert_path="/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem"
        local key_path="/etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem"
        if [ -z "$PANEL_DOMAIN" ] || [ ! -f "$cert_path" ]; then
            DEBIAN_FRONTEND=noninteractive apt install -y ssl-cert >/dev/null 2>&1 || true
            cert_path="/etc/ssl/certs/ssl-cert-snakeoil.pem"
            key_path="/etc/ssl/private/ssl-cert-snakeoil.key"
        fi
        cat > /etc/nginx/sites-available/pterodactyl.conf <<'NGINX'
server {
    listen 80;
    server_name __PANEL_SERVER_NAME__;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name __PANEL_SERVER_NAME__;

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate __SSL_CERT__;
    ssl_certificate_key __SSL_KEY__;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M";
        fastcgi_param PHP_VALUE "post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTPS on;
    }

    location ~ /\.ht { deny all; }
}
NGINX
        sed -i \
            -e "s|__PANEL_SERVER_NAME__|$server_name|g" \
            -e "s|__SSL_CERT__|$cert_path|g" \
            -e "s|__SSL_KEY__|$key_path|g" \
            /etc/nginx/sites-available/pterodactyl.conf
    else
        local cert_path="/etc/ssl/ptero/fullchain.pem"
        local key_path="/etc/ssl/ptero/privkey.pem"
        ensure_self_signed_cert "$server_name"
        cat > /etc/nginx/sites-available/pterodactyl.conf <<'NGINX'
server {
    listen 80;
    server_name __PANEL_SERVER_NAME__;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name __PANEL_SERVER_NAME__;

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate __SSL_CERT__;
    ssl_certificate_key __SSL_KEY__;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M";
        fastcgi_param PHP_VALUE "post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTPS on;
    }

    location ~ /\.ht { deny all; }
}
NGINX
        sed -i \
            -e "s|__PANEL_SERVER_NAME__|$server_name|g" \
            -e "s|__SSL_CERT__|$cert_path|g" \
            -e "s|__SSL_KEY__|$key_path|g" \
            /etc/nginx/sites-available/pterodactyl.conf
    fi
}

function provision_services() {
    require_root || return 1
    echo -e "${BLUE}[*] Membuat service systemd dan konfigurasi Nginx...${NC}"
    mkdir -p /etc/systemd/system /etc/nginx/sites-available /etc/nginx/sites-enabled "$WINGS_DIR"

    cat > /etc/systemd/system/wings.service <<UNIT
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=$WINGS_DIR
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/pteroq.service <<UNIT
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service mariadb.service
StartLimitIntervalSec=180
StartLimitBurst=30

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php $PANEL_DIR/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

    write_nginx_config

    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    rm -f /etc/nginx/sites-enabled/default
    systemctl daemon-reload
    systemctl enable wings pteroq >/dev/null 2>&1 || true
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true
    fi
    echo -e "${GREEN}[OK] Service dan Nginx sudah diprovision (mode: ${DEPLOY_MODE:-tunnel}).${NC}"
}

function setup_logrotate() {
    [ "$(id -u)" -eq 0 ] || return 0
    cat > /etc/logrotate.d/ptero-manager <<LOGROT
$LOG_FILE {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
LOGROT
}
