#!/bin/bash

function install_cloudflared() {
    require_root || return 1
    require_debian_family || return 1
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Menginstall cloudflared...${NC}"
        curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
            -o /tmp/cloudflared.deb
        apt install -y /tmp/cloudflared.deb
        rm -f /tmp/cloudflared.deb
    else
        echo -e "${YELLOW}cloudflared sudah terpasang.${NC}"
    fi
}

function setup_cloudflare_tunnel() {
    require_root || return 1
    install_cloudflared || return 1
    echo -e "${YELLOW}Ambil token dari: Cloudflare Zero Trust > Networks > Tunnels > Connector.${NC}"
    echo -e "${YELLOW}Public hostname di Cloudflare arahkan ke service: http://localhost:80${NC}"
    read -r -p "Token Cloudflare Tunnel: " CF_TOKEN
    if [ -z "$CF_TOKEN" ]; then
        fail "Token tidak boleh kosong."
        pause
        return 1
    fi
    cloudflared service install "$CF_TOKEN"
    systemctl enable --now cloudflared
    log_msg "Cloudflare Connector token dipasang"
    echo -e "${GREEN}Cloudflare Connector aktif.${NC}"
    pause
}

function setup_cloudflare_named_tunnel() {
    require_root || return 1
    require_debian_family || return 1
    install_cloudflared || return 1
    read -r -p "Nama tunnel [pterodactyl-local]: " TUNNEL_NAME
    TUNNEL_NAME=${TUNNEL_NAME:-pterodactyl-local}
    read -r -p "Domain panel Cloudflare, contoh panel.domain.com: " TUNNEL_DOMAIN
    TUNNEL_DOMAIN=$(validate_domain "$TUNNEL_DOMAIN") || {
        fail "Format domain tidak valid."
        pause
        return 1
    }

    echo -e "${YELLOW}Jika belum login, browser akan diminta untuk authorize akun Cloudflare.${NC}"
    cloudflared tunnel login || return 1

    if ! cloudflared tunnel list | awk '{print $2}' | grep -qx "$TUNNEL_NAME"; then
        cloudflared tunnel create "$TUNNEL_NAME" || return 1
    fi

    local tunnel_id credentials_file
    tunnel_id=$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$2 == name {print $1; exit}')
    credentials_file="/root/.cloudflared/${tunnel_id}.json"
    mkdir -p /etc/cloudflared
    cat > /etc/cloudflared/config.yml <<CFCONFIG
tunnel: $tunnel_id
credentials-file: $credentials_file

ingress:
  - hostname: $TUNNEL_DOMAIN
    service: https://localhost:443
    originRequest:
      noTLSVerify: true
      httpHostHeader: $TUNNEL_DOMAIN
  - service: http_status:404
CFCONFIG

    cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_DOMAIN" || true
    cloudflared service install >/dev/null 2>&1 || true
    systemctl enable --now cloudflared

    if [ -f "$PANEL_DIR/.env" ]; then
        set_env_value APP_URL "https://$TUNNEL_DOMAIN"
        set_env_value TRUSTED_PROXIES "*"
        cd "$PANEL_DIR" || return 1
        php artisan config:clear >/dev/null 2>&1 || true
        php artisan cache:clear >/dev/null 2>&1 || true
    fi
    PANEL_DOMAIN="$TUNNEL_DOMAIN"
    save_config
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        sed -i "s/server_name .*/server_name $TUNNEL_DOMAIN;/" \
            /etc/nginx/sites-available/pterodactyl.conf
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx
        fi
    fi
    log_msg "Named tunnel $TUNNEL_NAME aktif untuk $TUNNEL_DOMAIN"
    echo -e "${GREEN}Named Tunnel aktif: https://$TUNNEL_DOMAIN -> http://localhost:80${NC}"
    pause
}

function set_panel_domain() {
    require_root || return 1
    read -r -p "Domain panel Cloudflare, contoh panel.domain.com: " RAW_DOMAIN
    local domain_only
    domain_only=$(validate_domain "$RAW_DOMAIN") || {
        fail "Format domain tidak valid."
        pause
        return 1
    }
    local panel_url="https://$domain_only"
    PANEL_DOMAIN="$domain_only"
    save_config
    if [ -f "$PANEL_DIR/.env" ]; then
        set_env_value APP_URL "$panel_url"
        set_env_value TRUSTED_PROXIES "*"
        cd "$PANEL_DIR" || return 1
        php artisan config:clear >/dev/null 2>&1 || true
        php artisan cache:clear >/dev/null 2>&1 || true
        php artisan queue:restart >/dev/null 2>&1 || true
        chown www-data:www-data "$PANEL_DIR/.env" 2>/dev/null || true
    fi
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        sed -i "s/server_name .*/server_name $domain_only;/" \
            /etc/nginx/sites-available/pterodactyl.conf
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx
        fi
    fi
    log_msg "Domain panel diset ke $panel_url"
    echo -e "${GREEN}Domain panel diset ke $panel_url.${NC}"
    pause
}

function setup_letsencrypt() {
    require_root || return 1
    require_debian_family || return 1
    if [ "${DEPLOY_MODE:-tunnel}" != "public" ]; then
        echo -e "${YELLOW}Mode saat ini '${DEPLOY_MODE:-tunnel}'. Let's Encrypt biasanya dipakai pada mode 'public'.${NC}"
        echo -e "${YELLOW}Pertimbangkan ganti mode dulu via menu Pilih Mode Deploy.${NC}"
        confirm_action "Lanjut tetap setup HTTPS sekarang?" || { pause; return 0; }
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Install certbot...${NC}"
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y certbot python3-certbot-nginx
    fi

    read -r -p "Domain panel (contoh panel.domain.com) [${PANEL_DOMAIN:-}]: " RAW
    RAW=${RAW:-$PANEL_DOMAIN}
    local domain
    domain=$(validate_domain "$RAW") || { fail "Format domain tidak valid."; pause; return 1; }
    read -r -p "Email untuk notifikasi LE [${LE_EMAIL:-}]: " EMAIL
    EMAIL=${EMAIL:-$LE_EMAIL}
    if [ -z "$EMAIL" ]; then
        fail "Email wajib diisi."; pause; return 1
    fi

    local server_ip resolved_ip
    server_ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    resolved_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1; exit}')
    echo -e "${CYAN}IP server      : ${server_ip:-tidak terdeteksi}${NC}"
    echo -e "${CYAN}A-record domain: ${resolved_ip:-tidak terdeteksi}${NC}"
    if [ -n "$server_ip" ] && [ -n "$resolved_ip" ] && [ "$server_ip" != "$resolved_ip" ]; then
        echo -e "${YELLOW}DNS belum mengarah ke server ini. Cert HTTP-01 kemungkinan gagal.${NC}"
        confirm_action "Lanjutkan tetap?" || { pause; return 1; }
    fi

    if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ':80$'; then
        echo -e "${BLUE}[*] Nginx belum listen :80, generate config dasar...${NC}"
        PANEL_DOMAIN="$domain"
        DEPLOY_MODE="public"
        save_config
        provision_services
    fi

    PANEL_DOMAIN="$domain"
    LE_EMAIL="$EMAIL"
    DEPLOY_MODE="public"
    save_config

    write_nginx_config
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi

    if certbot --nginx --non-interactive --agree-tos -m "$EMAIL" -d "$domain" --redirect --keep-until-expiring; then
        write_nginx_config
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx 2>/dev/null || true
        fi
        systemctl enable --now certbot.timer 2>/dev/null || true

        if [ -f "$PANEL_DIR/.env" ]; then
            set_env_value APP_URL "https://$domain"
            set_env_value TRUSTED_PROXIES "127.0.0.1"
            if cd "$PANEL_DIR"; then
                php artisan config:clear >/dev/null 2>&1 || true
            fi
        fi
        log_msg "Let's Encrypt cert diterbitkan untuk $domain"
        notify_detail "HTTPS OK" "Sertifikat Let's Encrypt aktif untuk $domain"
        echo -e "${GREEN}HTTPS aktif: https://$domain${NC}"
        echo -e "${CYAN}Auto-renewal via systemd timer 'certbot.timer'.${NC}"
    else
        fail "Penerbitan cert gagal. Cek DNS, port 80 terbuka di firewall, dan /var/log/letsencrypt/."
    fi
    pause
}

function install_cf_origin_cert() {
    require_root || return 1
    header
    echo -e "${BLUE}Pasang Cloudflare Origin Certificate (mode tunnel, Full Strict)${NC}"
    echo -e "${YELLOW}Ambil dari: Cloudflare Dashboard > SSL/TLS > Origin Server > Create Certificate.${NC}"
    echo -e "${YELLOW}Pilih PEM, salin certificate (full chain) dan private key.${NC}"
    echo
    local dir="/etc/ssl/ptero"
    mkdir -p "$dir"
    chmod 750 "$dir"
    echo -e "${CYAN}Tempel CERTIFICATE (akhiri dengan baris berisi: END)${NC}"
    : > "$dir/fullchain.pem"
    while IFS= read -r line; do
        [ "$line" = "END" ] && break
        printf '%s\n' "$line" >> "$dir/fullchain.pem"
    done
    echo -e "${CYAN}Tempel PRIVATE KEY (akhiri dengan baris berisi: END)${NC}"
    : > "$dir/privkey.pem"
    while IFS= read -r line; do
        [ "$line" = "END" ] && break
        printf '%s\n' "$line" >> "$dir/privkey.pem"
    done
    if ! openssl x509 -in "$dir/fullchain.pem" -noout >/dev/null 2>&1; then
        fail "Certificate yang ditempel tidak valid."
        rm -f "$dir/fullchain.pem" "$dir/privkey.pem"
        pause
        return 1
    fi
    if ! openssl rsa -in "$dir/privkey.pem" -check -noout >/dev/null 2>&1 \
         && ! openssl pkey -in "$dir/privkey.pem" -noout >/dev/null 2>&1; then
        fail "Private key tidak valid."
        rm -f "$dir/fullchain.pem" "$dir/privkey.pem"
        pause
        return 1
    fi
    chmod 644 "$dir/fullchain.pem"
    chmod 600 "$dir/privkey.pem"
    DEPLOY_MODE="tunnel"
    save_config
    write_nginx_config
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
    log_msg "Cloudflare Origin Certificate dipasang"
    echo -e "${GREEN}Origin Certificate aktif. Set Cloudflare SSL/TLS mode ke 'Full (Strict)'.${NC}"
    pause
}

function select_deploy_mode() {
    require_root || return 1
    header
    echo -e "${BLUE}Mode Deploy${NC}"
    echo -e "Mode saat ini: ${CYAN}${DEPLOY_MODE:-tunnel}${NC}"
    echo
    echo "1) tunnel  -> Server lokal/VPS tanpa IP publik (Cloudflare Tunnel terminasi TLS)"
    echo "2) public  -> Server dengan IP publik + HTTPS Let's Encrypt langsung"
    echo "0) Batal"
    read -r -p "Pilih [0-2]: " M
    case "$M" in
        1) DEPLOY_MODE="tunnel" ;;
        2) DEPLOY_MODE="public" ;;
        *) echo "Dibatalkan."; pause; return 0 ;;
    esac
    save_config

    if [ -f "$PANEL_DIR/.env" ]; then
        if [ "$DEPLOY_MODE" = "public" ]; then
            set_env_value TRUSTED_PROXIES "127.0.0.1"
        else
            set_env_value TRUSTED_PROXIES "*"
        fi
        if cd "$PANEL_DIR"; then
            php artisan config:clear >/dev/null 2>&1 || true
        fi
    fi

    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        if confirm_action "Generate ulang konfigurasi Nginx untuk mode '$DEPLOY_MODE'?"; then
            write_nginx_config
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
            fi
        fi
    fi
    log_msg "Mode deploy diset: $DEPLOY_MODE"
    echo -e "${GREEN}Mode di-set ke: $DEPLOY_MODE${NC}"
    pause
}

function setup_firewall() {
    require_root || return 1
    local mode="${DEPLOY_MODE:-tunnel}"
    echo -e "${BLUE}[*] Mengkonfigurasi UFW (mode: $mode)...${NC}"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "SSH"
    if [ "$mode" = "public" ]; then
        ufw allow 80/tcp  comment "HTTP (Let's Encrypt + redirect)"
        ufw allow 443/tcp comment "HTTPS Panel"
    else
        ufw allow from 127.0.0.1 to any port 80  comment "HTTP loopback (tunnel)"
        ufw allow from 127.0.0.1 to any port 443 comment "HTTPS loopback (tunnel)"
        ufw deny  80/tcp  comment "Block HTTP publik (tunnel mode)"
        ufw deny  443/tcp comment "Block HTTPS publik (tunnel mode)"
    fi
    ufw allow 8080/tcp comment "Wings HTTP"
    ufw allow 2022/tcp comment "Wings SFTP"
    ufw --force enable
    ufw status verbose
    log_msg "UFW dikonfigurasi (mode $mode)"
    pause
}

function setup_fail2ban() {
    require_root || return 1
    require_debian_family || return 1
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Install fail2ban...${NC}"
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y fail2ban
    fi
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/ptero-manager.conf <<'F2B'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ssh

[nginx-http-auth]
enabled  = true
filter   = nginx-http-auth
port     = http,https
logpath  = /var/log/nginx/error.log

[nginx-botsearch]
enabled  = true
filter   = nginx-botsearch
port     = http,https
logpath  = /var/log/nginx/access.log
F2B
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    log_msg "Fail2ban dipasang"
    echo -e "${GREEN}Fail2ban aktif (jail: sshd, nginx-http-auth, nginx-botsearch).${NC}"
    fail2ban-client status 2>/dev/null | sed 's/^/  /'
    pause
}

function fail2ban_status() {
    require_root || return 1
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${YELLOW}Fail2ban belum terpasang.${NC}"; pause; return 0
    fi
    header
    echo -e "${BLUE}Status Fail2ban${NC}"
    fail2ban-client status 2>/dev/null | sed 's/^/  /'
    echo
    for jail in sshd nginx-http-auth nginx-botsearch; do
        if fail2ban-client status "$jail" >/dev/null 2>&1; then
            echo -e "${CYAN}== $jail ==${NC}"
            fail2ban-client status "$jail" | sed 's/^/  /'
            echo
        fi
    done
    pause
}
