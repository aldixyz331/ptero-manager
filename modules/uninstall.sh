#!/bin/bash

function deep_uninstall() {
    require_root || return 1
    header
    echo -e "${RED}PERINGATAN: Ini akan menghapus panel, Wings, database, volume server, dan service terkait.${NC}"
    confirm_action "Uninstall total akan menghapus semua data Pterodactyl." \
        || { echo "Uninstall dibatalkan."; pause; return 1; }
    read -r -p "Ketik 'yakin' untuk hapus total: " CONFIRM
    if [ "$CONFIRM" = "yakin" ]; then
        systemctl stop wings pteroq cloudflared nginx mariadb redis-server 2>/dev/null || true
        systemctl disable wings pteroq cloudflared 2>/dev/null || true
        rm -rf "$PANEL_DIR" "$WINGS_DIR" /var/lib/pterodactyl \
            /usr/local/bin/wings \
            /etc/systemd/system/wings.service /etc/systemd/system/pteroq.service \
            /etc/cloudflared /root/.cloudflared \
            /usr/local/sbin/ptero-auto-backup.sh /etc/cron.d/ptero-manager-backup
        rm -f /etc/nginx/sites-enabled/pterodactyl.conf \
              /etc/nginx/sites-available/pterodactyl.conf
        ask_mysql_root_password
        mysql_root -e "
            DROP DATABASE IF EXISTS $DB_NAME;
            DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';
            FLUSH PRIVILEGES;
        " 2>/dev/null || true
        if command -v docker >/dev/null 2>&1; then
            mapfile -t containers < <(docker ps -aq 2>/dev/null)
            if [ "${#containers[@]}" -gt 0 ]; then
                docker stop "${containers[@]}" 2>/dev/null || true
                docker rm "${containers[@]}" 2>/dev/null || true
            fi
        fi
        systemctl daemon-reload
        if nginx -t >/dev/null 2>&1; then
            systemctl restart nginx 2>/dev/null || true
        fi
        log_msg "Deep uninstall selesai"
        echo -e "${GREEN}Pterodactyl berhasil dihapus.${NC}"
    else
        echo -e "${YELLOW}Uninstall dibatalkan.${NC}"
    fi
    pause
}
