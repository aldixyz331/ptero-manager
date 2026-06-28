#!/bin/bash

function fix_permissions() {
    require_root || return 1
    if [ ! -d "$PANEL_DIR" ]; then
        fail "Folder panel tidak ditemukan: $PANEL_DIR"
        pause
        return 1
    fi
    chown -R www-data:www-data "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
    systemctl restart pteroq nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true
    echo -e "${GREEN}Permission panel diperbaiki.${NC}"
    pause
}

function fix_nginx_config() {
    require_root || return 1
    provision_services
    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}Nginx diperbaiki/restart.${NC}"
    else
        fail "Nginx config invalid — tidak di-restart. Cek output 'nginx -t' di atas."
    fi
}

function fix_queue_worker() {
    require_root || return 1
    provision_services
    systemctl restart pteroq 2>/dev/null || true
    if [ -f "$PANEL_DIR/artisan" ]; then
        cd "$PANEL_DIR" || return 1
        php artisan queue:restart 2>/dev/null || true
    fi
    echo -e "${GREEN}Queue worker diperbaiki/restart.${NC}"
}

function fix_redis_service() {
    require_root || return 1
    systemctl enable --now redis-server
    systemctl restart redis-server
    echo -e "${GREEN}Redis diperbaiki/restart.${NC}"
}

function fix_wings_service() {
    require_root || return 1
    install_wings_binary || return 1
    provision_services || return 1
    systemctl restart wings 2>/dev/null || true
    echo -e "${GREEN}Wings diperbaiki/restart.${NC}"
}

function reset_node_network() {
    require_root || return 1
    if ! command -v docker >/dev/null 2>&1; then
        fail "Docker belum terinstall."; pause; return 1
    fi
    confirm_action "Reset Docker network 'pterodactyl_nw'? Semua container Wings akan di-restart." \
        || { echo "Dibatalkan."; pause; return 0; }

    systemctl stop wings 2>/dev/null || true

    local attached
    mapfile -t attached < <(docker network inspect pterodactyl_nw \
        -f '{{range $k,$v := .Containers}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null)
    for c in "${attached[@]}"; do
        [ -n "$c" ] && docker network disconnect -f pterodactyl_nw "$c" 2>/dev/null || true
    done

    docker network rm pterodactyl_nw 2>/dev/null || true
    if ! docker network create \
            --driver bridge \
            --subnet 172.18.0.0/16 \
            --gateway 172.18.0.1 \
            -o "com.docker.network.bridge.name=pterodactyl0" \
            -o "com.docker.network.driver.mtu=1500" \
            -o "com.docker.network.bridge.enable_icc=true" \
            -o "com.docker.network.bridge.enable_ip_masquerade=true" \
            -o "com.docker.network.bridge.host_binding_ipv4=0.0.0.0" \
            pterodactyl_nw 2>/dev/null; then
        fail "Gagal membuat ulang network pterodactyl_nw. Cek 'docker network ls'."
        systemctl start wings 2>/dev/null || true
        pause; return 1
    fi
    systemctl start wings 2>/dev/null || true
    log_msg "Docker network pterodactyl_nw direset"
    echo -e "${GREEN}Network node direset dengan opsi resmi Pterodactyl.${NC}"
    pause
}

function repair_menu() {
    require_root || return 1
    while true; do
        header
        echo "1) Fix Permission Panel"
        echo "2) Fix Nginx Config (Cloudflare-ready)"
        echo "3) Fix Queue Worker"
        echo "4) Fix Redis"
        echo "5) Fix Wings Service (reinstall + restart)"
        echo "6) Reset Docker Network Node"
        echo "7) Update Wings Saja"
        echo "8) Fix Trusted Proxy (TRUSTED_PROXIES)"
        echo "9) Revert Optimasi Server"
        echo "10) Restart Semua Service"
        echo "0) Kembali"
        read -r -p "Pilih [0-10]: " REPAIR_OPT
        case "$REPAIR_OPT" in
            1) fix_permissions ;;
            2) fix_nginx_config; pause ;;
            3) fix_queue_worker; pause ;;
            4) fix_redis_service; pause ;;
            5) fix_wings_service; pause ;;
            6) reset_node_network ;;
            7) update_wings_only ;;
            8)
                require_panel || continue
                set_env_value TRUSTED_PROXIES "*"
                cd "$PANEL_DIR" && php artisan config:clear >/dev/null 2>&1 || true
                echo -e "${GREEN}TRUSTED_PROXIES diset ke *.${NC}"; pause
                ;;
            9) optimize_revert ;;
            10) restart_all_services ;;
            0) return 0 ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function setup_rclone_storage() {
    require_root || return 1
    if ! command -v rclone >/dev/null 2>&1; then
        curl -fsSL https://rclone.org/install.sh | bash
    fi
    echo -e "${YELLOW}Pastikan remote sudah dibuat dengan: rclone config${NC}"
    read -r -p "Remote name: " RN
    read -r -p "Folder tujuan: " RF
    if [ -z "$RN" ] || [ -z "$RF" ]; then
        fail "Remote name dan folder wajib diisi."
        pause
        return 1
    fi
    echo "$RN:$RF" > /root/.ptero_rclone
    chmod 600 /root/.ptero_rclone
    echo -e "${GREEN}Rclone storage tersimpan.${NC}"
    pause
}
