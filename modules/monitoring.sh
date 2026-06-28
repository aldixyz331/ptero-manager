#!/bin/bash

function health_check() {
    require_root || return 1
    header
    echo -e "${BLUE}Status Service:${NC}"
    service_status_line nginx
    service_status_line "php${PHP_VERSION}-fpm"
    service_status_line mariadb
    service_status_line redis-server
    service_status_line docker
    service_status_line wings
    service_status_line pteroq
    service_status_line cloudflared

    echo
    echo -e "${BLUE}Port Aktif:${NC}"
    ss -lntp 2>/dev/null | grep -E ':(80|443|8080|2022|3306|6379)\b' \
        || echo "  Tidak ada port penting yang terdeteksi."

    echo
    echo -e "${BLUE}Disk & RAM:${NC}"
    df -h / | awk 'NR==2 {printf "  Disk: %s / %s (%s)\n", $3, $2, $5}'
    free -h | awk '/^Mem:/ {printf "  RAM:  %s / %s\n", $3, $2}'

    local disk_pct
    disk_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    if [ -n "$disk_pct" ] && [ "$disk_pct" -ge 85 ]; then
        echo -e "  ${RED}PERINGATAN: Disk sudah ${disk_pct}% penuh!${NC}"
        notify_detail "DISK WARNING" "Disk server ${disk_pct}% penuh!"
    fi

    echo
    echo -e "${BLUE}Panel & Wings:${NC}"
    if [ -f "$PANEL_DIR/artisan" ]; then
        echo -e "  ${GREEN}[OK]${NC} Panel ditemukan di $PANEL_DIR"
        grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | sed 's/^/  /'
        grep '^TRUSTED_PROXIES=' "$PANEL_DIR/.env" 2>/dev/null | sed 's/^/  /'
    else
        echo -e "  ${RED}[MISSING]${NC} Panel tidak ditemukan"
    fi
    if [ -f "$WINGS_DIR/config.yml" ]; then
        echo -e "  ${GREEN}[OK]${NC} Config Wings ditemukan"
    else
        echo -e "  ${YELLOW}[INFO]${NC} Config Wings belum ditemukan (generate dari panel)"
    fi

    echo
    echo -e "${BLUE}Cloudflare Tunnel:${NC}"
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared tunnel list 2>/dev/null \
            || echo "  Cloudflared terpasang. Jika memakai token connector, cek dashboard Cloudflare."
    else
        echo -e "  ${YELLOW}Cloudflared belum terpasang.${NC}"
    fi

    echo
    echo -e "${BLUE}Cek konektivitas panel via tunnel:${NC}"
    if [ -f "$PANEL_DIR/.env" ]; then
        local app_url
        app_url=$(grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
        if [ -n "$app_url" ] && [ "$app_url" != "http://localhost" ]; then
            local code
            code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "$app_url" 2>/dev/null || echo "000")
            if echo "$code" | grep -Eq '^(200|302|301)$'; then
                echo -e "  ${GREEN}[OK]${NC} $app_url -> HTTP $code"
            else
                echo -e "  ${RED}[GAGAL]${NC} $app_url -> HTTP $code"
            fi
        else
            echo -e "  ${YELLOW}APP_URL belum dikonfigurasi.${NC}"
        fi
    fi

    log_msg "Health check dijalankan"
    pause
}

function info_system() {
    require_root || return 1
    header
    echo -e "${BLUE}Informasi Sistem Lengkap:${NC}"
    echo
    echo -e "${CYAN}OS:${NC}"
    grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | sed 's/^/  /'
    uname -r | sed 's/^/  Kernel: /'
    echo
    echo -e "${CYAN}Versi Komponen:${NC}"
    printf "  %-18s %s\n" "PHP:" "$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '-')"
    printf "  %-18s %s\n" "Nginx:" "$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "MariaDB/MySQL:" "$(mysql --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "Redis:" "$(redis-cli --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "Docker:" "$(docker --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "Composer:" "$(composer --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    printf "  %-18s %s\n" "Cloudflared:" "$(cloudflared --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    if [ -f /usr/local/bin/wings ]; then
        printf "  %-18s %s\n" "Wings:" "$(/usr/local/bin/wings --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '-')"
    else
        printf "  %-18s %s\n" "Wings:" "tidak terpasang"
    fi
    echo
    echo -e "${CYAN}Panel:${NC}"
    if [ -f "$PANEL_DIR/artisan" ]; then
        printf "  %-18s %s\n" "Version:" "$(cd "$PANEL_DIR" && php artisan tinker --execute='echo app()->version();' 2>/dev/null | tail -1 || echo '-')"
        grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | sed 's/^/  /'
    else
        echo "  Panel belum terpasang."
    fi
    pause
}

function view_logs_menu() {
    require_root || return 1
    while true; do
        header
        echo "1) Log Wings (real-time)"
        echo "2) Log Queue Worker (real-time)"
        echo "3) Log Nginx error"
        echo "4) Log Panel Laravel"
        echo "5) Log Manager Script"
        echo "0) Kembali"
        read -r -p "Pilih [0-5]: " LOG_OPT
        case "$LOG_OPT" in
            1)
                if command -v journalctl >/dev/null 2>&1; then
                    journalctl -fu wings --no-pager
                elif [ -f /var/log/syslog ]; then
                    tail -f /var/log/syslog
                else
                    echo "Log Wings tidak tersedia (journalctl & /var/log/syslog tidak ada)."
                fi
                ;;
            2)
                if command -v journalctl >/dev/null 2>&1; then
                    journalctl -fu pteroq --no-pager
                else
                    echo "journalctl tidak tersedia."
                fi
                ;;
            3) tail -f /var/log/nginx/error.log 2>/dev/null || echo "Log Nginx tidak ditemukan." ;;
            4)
                local plog
                plog=$(ls -t "$PANEL_DIR/storage/logs/"*.log 2>/dev/null | head -1)
                if [ -n "$plog" ]; then
                    tail -f "$plog"
                else
                    echo "Log panel tidak ditemukan."
                fi
                ;;
            5) tail -f "$LOG_FILE" 2>/dev/null || echo "Log manager belum ada." ;;
            0) return 0 ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function check_wings_connection() {
    require_root || return 1
    header
    echo -e "${BLUE}Memeriksa koneksi Wings ke Panel...${NC}"
    echo
    if ! systemctl is-active --quiet wings; then
        echo -e "${RED}Wings tidak berjalan.${NC}"
    else
        echo -e "${GREEN}Wings sedang berjalan.${NC}"
    fi
    if [ -f "$WINGS_DIR/config.yml" ]; then
        echo -e "${GREEN}Config Wings ditemukan.${NC}"
        local panel_url
        panel_url=$(grep 'remote:' "$WINGS_DIR/config.yml" 2>/dev/null | awk '{print $2}')
        [ -n "$panel_url" ] && echo -e "  Panel URL di config Wings: $panel_url"
    else
        echo -e "${RED}Config Wings tidak ditemukan di $WINGS_DIR/config.yml${NC}"
        echo -e "${YELLOW}Generate config Wings dari: Panel > Admin > Nodes > [nama node] > Configuration${NC}"
    fi
    echo
    echo -e "${BLUE}Log Wings terbaru:${NC}"
    journalctl -u wings --no-pager -n 20 2>/dev/null \
        || echo "Log Wings tidak tersedia via journalctl."
    log_msg "Check Wings connection dijalankan"
    pause
}

function backup_stats() {
    require_root || return 1
    header
    echo -e "${BLUE}Statistik Backup${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."; pause; return 0
    fi
    local total count
    count=$(ls -1d "$BACKUP_ROOT"/ptero_* 2>/dev/null | wc -l)
    total=$(du -sh "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}')
    echo -e "Jumlah backup : ${CYAN}$count${NC}"
    echo -e "Total ukuran  : ${CYAN}$total${NC}"
    if [ "$count" -gt 0 ]; then
        local newest oldest biggest smallest
        newest=$(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null | head -1)
        oldest=$(ls -1dtr "$BACKUP_ROOT"/ptero_* 2>/dev/null | head -1)
        biggest=$(du -s "$BACKUP_ROOT"/ptero_* 2>/dev/null | sort -rn | head -1)
        smallest=$(du -s "$BACKUP_ROOT"/ptero_* 2>/dev/null | sort -n | head -1)
        echo -e "Terbaru       : $(basename "$newest") ($(stat -c %y "$newest" 2>/dev/null | cut -d. -f1))"
        echo -e "Tertua        : $(basename "$oldest") ($(stat -c %y "$oldest" 2>/dev/null | cut -d. -f1))"
        echo -e "Terbesar      : $(basename "$(echo "$biggest" | awk '{print $2}')") ($(echo "$biggest" | awk '{printf "%.1fM", $1/1024}'))"
        echo -e "Terkecil      : $(basename "$(echo "$smallest" | awk '{print $2}')") ($(echo "$smallest" | awk '{printf "%.1fM", $1/1024}'))"
        echo
        echo -e "Retensi  : $BACKUP_RETENTION_DAYS hari (max $BACKUP_MAX_COUNT backup)"
    fi
    if [ -f /etc/cron.d/ptero-manager-backup ]; then
        echo
        echo -e "${BLUE}Jadwal backup otomatis:${NC}"
        grep -E '^[0-9]' /etc/cron.d/ptero-manager-backup | sed 's/^/  /'
    fi
    if [ -f /root/.ptero-s3.conf ]; then
        echo
        echo -e "${BLUE}S3 Backup Destination:${NC}"
        source /root/.ptero-s3.conf
        echo -e "  Endpoint : ${CYAN}$S3_ENDPOINT${NC}"
        echo -e "  Bucket   : ${CYAN}$S3_BUCKET${NC}"
        echo -e "  Prefix   : ${CYAN}${S3_PREFIX:-<none>}${NC}"
        echo -e "  Include volumes: ${CYAN}${S3_INCLUDE_VOLUMES:-no}${NC}"
        local s3_count
        s3_count=$(_s3_exec_cmd ls "s3://$S3_BUCKET/${S3_PREFIX:+$S3_PREFIX/}" 2>/dev/null \
            | grep -oP 'ptero_s3_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | sort -u | wc -l)
        echo -e "  Jumlah backup S3: ${CYAN}${s3_count:-0}${NC} (max retensi: $BACKUP_MAX_COUNT)"
        if [ "${s3_count:-0}" -gt "$BACKUP_MAX_COUNT" ]; then
            echo -e "  ${YELLOW}PERINGATAN: melebihi retensi. Jalankan menu Prune S3 (menu Backup & Restore).${NC}"
        fi
    fi
    pause
}
