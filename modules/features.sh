#!/bin/bash

function telegram_setup() {
    require_root || return 1
    header
    echo -e "${BLUE}Setup Telegram Notifikasi${NC}"
    echo -e "Bot Token saat ini: ${CYAN}${TELEGRAM_BOT_TOKEN:+(terisi)}${TELEGRAM_BOT_TOKEN:-belum diset}${NC}"
    echo -e "Chat ID saat ini  : ${CYAN}${TELEGRAM_CHAT_ID:-belum diset}${NC}"
    echo
    echo "1) Set Bot Token + Chat ID"
    echo "2) Test kirim pesan"
    echo "3) Hapus konfigurasi Telegram"
    echo "0) Kembali"
    read -r -p "Pilih [0-3]: " TG
    case "$TG" in
        1)
            read -r -p "Bot Token (dari @BotFather): " T_TOKEN
            read -r -p "Chat ID (kirim pesan ke bot, lalu cek getUpdates): " T_CHAT
            if [ -z "$T_TOKEN" ] || [ -z "$T_CHAT" ]; then
                fail "Token dan Chat ID wajib diisi."; pause; return 1
            fi
            TELEGRAM_BOT_TOKEN="$T_TOKEN"
            TELEGRAM_CHAT_ID="$T_CHAT"
            save_config
            echo -e "${GREEN}Konfigurasi Telegram tersimpan.${NC}"
            ;;
        2)
            if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
                fail "Belum dikonfigurasi."; pause; return 1
            fi
            notify_detail "TEST TG" "Pesan test dari Ptero Manager V$SCRIPT_VERSION"
            echo -e "${GREEN}Pesan test dikirim ke Telegram.${NC}"
            ;;
        3)
            TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
            save_config
            echo -e "${GREEN}Konfigurasi Telegram dihapus.${NC}"
            ;;
    esac
    pause
}

function set_custom_banner() {
    require_root || return 1
    echo -e "Banner saat ini: ${CYAN}${CUSTOM_BANNER:-(kosong)}${NC}"
    read -r -p "Banner baru (kosongkan untuk hapus): " NB
    CUSTOM_BANNER="$NB"
    save_config
    echo -e "${GREEN}Banner tersimpan.${NC}"
    pause
}

function script_rollback() {
    require_root || return 1
    local current bak
    current=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    bak="${current}.bak"
    if [ ! -f "$bak" ]; then
        fail "File backup tidak ditemukan: $bak"; pause; return 1
    fi
    confirm_action "Rollback script ke versi sebelum self-update?" \
        || { echo "Batal."; pause; return 0; }
    cp -f "$current" "${current}.tmp"
    mv -f "$bak" "$current"
    mv -f "${current}.tmp" "$bak"
    chmod +x "$current"
    log_msg "Script di-rollback dari .bak"
    echo -e "${GREEN}Rollback selesai. Jalankan ulang script.${NC}"
    pause
    return 0
}

function security_audit() {
    require_root || return 1
    header
    echo -e "${BLUE}Security Audit${NC}"
    echo
    local issues=0

    if [ -f "$PANEL_DIR/.env" ]; then
        local perm owner
        perm=$(stat -c %a "$PANEL_DIR/.env" 2>/dev/null)
        owner=$(stat -c %U "$PANEL_DIR/.env" 2>/dev/null)
        if [ "$perm" != "640" ] && [ "$perm" != "600" ]; then
            echo -e "  ${YELLOW}[WARN]${NC} .env permission $perm (rekomendasi 640)"
            issues=$((issues+1))
        else
            echo -e "  ${GREEN}[OK]${NC} .env permission $perm"
        fi
        if [ "$owner" != "www-data" ] && [ "$owner" != "root" ]; then
            echo -e "  ${YELLOW}[WARN]${NC} .env owner: $owner"
            issues=$((issues+1))
        fi
    fi

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q 'Status: active'; then
            echo -e "  ${GREEN}[OK]${NC} UFW aktif"
        else
            echo -e "  ${RED}[FAIL]${NC} UFW tidak aktif"
            issues=$((issues+1))
        fi
    fi

    if [ -f /etc/ssh/sshd_config ]; then
        if grep -Eq '^\s*PermitRootLogin\s+yes' /etc/ssh/sshd_config; then
            echo -e "  ${YELLOW}[WARN]${NC} SSH PermitRootLogin yes (rekomendasi prohibit-password)"
            issues=$((issues+1))
        else
            echo -e "  ${GREEN}[OK]${NC} SSH root login restricted"
        fi
        if grep -Eq '^\s*PasswordAuthentication\s+yes' /etc/ssh/sshd_config; then
            echo -e "  ${YELLOW}[WARN]${NC} SSH password auth aktif"
            issues=$((issues+1))
        fi
    fi

    if [ -f "$PANEL_DIR/.env" ]; then
        local dbpw
        dbpw=$(grep '^DB_PASSWORD=' "$PANEL_DIR/.env" | cut -d= -f2-)
        if [ "${#dbpw}" -lt 12 ]; then
            echo -e "  ${RED}[FAIL]${NC} DB password terlalu pendek (${#dbpw} karakter)"
            issues=$((issues+1))
        else
            echo -e "  ${GREEN}[OK]${NC} DB password panjang ${#dbpw} karakter"
        fi
    fi

    local php_v
    php_v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
    if [ -n "$php_v" ]; then
        if echo "$php_v" | awk -F. '{ exit !($1 < 8 || ($1 == 8 && $2 < 1)) }'; then
            echo -e "  ${YELLOW}[WARN]${NC} PHP $php_v sudah tua"
            issues=$((issues+1))
        else
            echo -e "  ${GREEN}[OK]${NC} PHP versi $php_v"
        fi
    fi

    local open_ports
    open_ports=$(ss -lntH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort -un | tr '\n' ' ')
    echo -e "  ${BLUE}[INFO]${NC} Port listen: $open_ports"

    echo
    if [ "$issues" -eq 0 ]; then
        echo -e "${GREEN}Tidak ada masalah keamanan terdeteksi.${NC}"
    else
        echo -e "${YELLOW}Ditemukan $issues isu keamanan.${NC}"
    fi
    log_msg "Security audit dijalankan ($issues isu)"
    pause
}

function wings_watchdog_setup() {
    require_root || return 1
    echo -e "${BLUE}Setup Wings Watchdog${NC}"
    echo "Watchdog akan cek Wings tiap 5 menit dan restart jika DOWN."
    confirm_action "Pasang watchdog?" || { pause; return 0; }
    cat > /usr/local/sbin/ptero-wings-watchdog.sh <<'WATCH'
#!/bin/bash
LOG=/var/log/ptero-manager.log
if ! systemctl is-active --quiet wings; then
    echo "[$(date '+%F %T')] Watchdog: Wings DOWN, mencoba restart..." >> "$LOG"
    systemctl restart wings
fi
WATCH
    chmod 700 /usr/local/sbin/ptero-wings-watchdog.sh
    cat > /etc/cron.d/ptero-wings-watchdog <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/sbin/ptero-wings-watchdog.sh
CRON
    systemctl restart cron 2>/dev/null || true
    log_msg "Wings watchdog dipasang"
    echo -e "${GREEN}Watchdog aktif (cek tiap 5 menit).${NC}"
    pause
}

function wings_watchdog_remove() {
    require_root || return 1
    rm -f /usr/local/sbin/ptero-wings-watchdog.sh /etc/cron.d/ptero-wings-watchdog
    systemctl restart cron 2>/dev/null || true
    log_msg "Wings watchdog dihapus"
    echo -e "${GREEN}Watchdog dihapus.${NC}"
    pause
}

function help_screen() {
    header
    cat <<HELP
${BLUE}=== BANTUAN PTERO MANAGER V$SCRIPT_VERSION ===${NC}

${CYAN}Konsep dasar:${NC}
  Mendukung 2 mode deploy:
    - tunnel  : server lokal/VPS tanpa IP publik, akses via Cloudflare Tunnel.
    - public  : server dengan IP publik, akses via HTTPS Let's Encrypt langsung.
  Pilih mode dulu di menu 47 sebelum install/regenerate Nginx.

${CYAN}Alur instalasi mode TUNNEL (tanpa IP publik):${NC}
  Nginx tetap pakai HTTPS di port 443 loopback (default self-signed cert).
  Cloudflared diarahkan ke https://localhost:443 dengan noTLSVerify, jadi
  Cloudflare bisa pakai SSL mode 'Full' atau 'Full (Strict)' end-to-end.
  1. Menu 47 -> Pilih mode 'tunnel'
  2. Menu 1  -> Full Install Panel + Wings (auto-generate self-signed cert)
  3. Menu 7/8 -> Setup Cloudflare Tunnel (token connector ATAU named tunnel)
  4. Menu 9  -> Set domain panel
  5. Menu 10 -> Generate config Wings dari Panel API
  6. Menu 30 -> Setup UFW (otomatis blokir 80/443 publik)
  7. Menu 51 -> (opsional) Pasang Cloudflare Origin Cert utk Full (Strict)
  8. Menu 16 -> Aktifkan backup otomatis terjadwal

${CYAN}Alur instalasi mode PUBLIC (dengan IP publik):${NC}
  1. Menu 47 -> Pilih mode 'public'
  2. Pastikan A-record domain mengarah ke IP server (bisa cek di menu 48)
  3. Menu 1  -> Full Install Panel + Wings
  4. Menu 48 -> Setup HTTPS Let's Encrypt (auto certbot + auto-renew)
  5. Menu 10 -> Generate config Wings dari Panel API
  6. Menu 30 -> Setup UFW (otomatis buka 80/443)
  7. Menu 49 -> Setup Fail2ban (proteksi brute-force SSH/HTTP)
  8. Menu 16 -> Aktifkan backup otomatis terjadwal

${CYAN}Tips harian:${NC}
  - Pakai menu 17 (Health Check) untuk cek service & konektivitas tunnel
  - Pakai menu 19 (Log real-time) untuk debug Wings/queue/nginx
  - Backup sebelum update: menu 11 -> menu 2 (update panel)
  - Restore selektif: hanya database / panel / wings / volume saja

${CYAN}Keamanan:${NC}
  - Jalankan menu 35 (Security Audit) berkala
  - File config tersimpan di \$CONFIG_FILE (root only)
  - Lock file: \$LOCK_FILE (mencegah backup paralel)

${CYAN}File penting:${NC}
  - Script         : $0
  - Panel          : $PANEL_DIR
  - Wings config   : $WINGS_DIR/config.yml
  - Backup         : $BACKUP_ROOT
  - Log manager    : $LOG_FILE

${CYAN}Mode quiet (untuk cron):${NC}
  bash ptero.sh --quiet --auto-backup
HELP
    pause
}
