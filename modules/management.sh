#!/bin/bash

function create_admin_user() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    php artisan p:user:make
    log_msg "Create user panel dijalankan"
    pause
}

function reset_admin_password() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    read -r -p "Username atau email admin: " ADMIN_USER
    if [ -z "$ADMIN_USER" ]; then
        fail "Username tidak boleh kosong."
        pause
        return 1
    fi
    php artisan p:user:edit "$ADMIN_USER"
    log_msg "Reset password admin: $ADMIN_USER"
    pause
}

function change_db_password() {
    require_root || return 1
    require_panel || return 1
    ask_mysql_root_password
    read -r -s -p "Password database BARU untuk user $DB_USER (min 8 char): " NEW_DB_PASS
    echo
    if ! validate_db_password "$NEW_DB_PASS" 8; then
        pause
        return 1
    fi
    if [ -z "$NEW_DB_PASS" ]; then
        fail "Password tidak boleh kosong."
        pause
        return 1
    fi
    local db_pass_sql
    db_pass_sql=$(printf "%s" "$NEW_DB_PASS" | sed "s/'/''/g")
    mysql_root -e "
        ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
        FLUSH PRIVILEGES;
    " || { fail "Gagal mengubah password di MariaDB."; pause; return 1; }
    set_env_value DB_PASSWORD "$NEW_DB_PASS"
    cd "$PANEL_DIR" || return 1
    php artisan config:clear >/dev/null 2>&1 || true
    php artisan queue:restart >/dev/null 2>&1 || true
    chown www-data:www-data "$PANEL_DIR/.env" 2>/dev/null || true
    systemctl restart pteroq "php${PHP_VERSION}-fpm" 2>/dev/null || true

    if [ -f "$AUTO_BACKUP_CNF" ] || [ -f "$AUTO_BACKUP_SCRIPT" ]; then
        mkdir -p "$(dirname "$AUTO_BACKUP_CNF")"
        chmod 700 "$(dirname "$AUTO_BACKUP_CNF")"
        local _old_umask
        _old_umask=$(umask); umask 077
        {
            printf '[client]\n'
            printf 'user=%s\n' "$DB_USER"
            printf 'password=%s\n' "$NEW_DB_PASS"
            printf 'host=127.0.0.1\n'
        } > "$AUTO_BACKUP_CNF"
        chmod 600 "$AUTO_BACKUP_CNF"
        umask "$_old_umask"
        local script_path
        script_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
        cat > "$AUTO_BACKUP_SCRIPT" <<AUTO
#!/bin/bash
exec bash '$script_path' --auto-backup --cnf '$AUTO_BACKUP_CNF'
AUTO
        chmod 700 "$AUTO_BACKUP_SCRIPT"
        echo -e "${GREEN}Kredensial auto-backup juga diperbarui.${NC}"
    fi

    log_msg "Password database $DB_USER diubah"
    echo -e "${GREEN}Password database berhasil diubah dan .env diperbarui.${NC}"
    pause
}

function panel_maintenance_mode() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    local status="UP (online)"
    if [ -f "$PANEL_DIR/storage/framework/down" ] || [ -f "$PANEL_DIR/storage/framework/maintenance.php" ]; then
        status="${YELLOW}DOWN (maintenance)${NC}"
    else
        status="${GREEN}UP (online)${NC}"
    fi
    echo -e "Status panel saat ini: $status"
    echo
    echo -e "${CYAN}1) Aktifkan Maintenance Mode (panel down)${NC}"
    echo -e "${CYAN}2) Nonaktifkan Maintenance Mode (panel up)${NC}"
    read -r -p "Pilih [1/2]: " MM_OPT
    case "$MM_OPT" in
        1)
            read -r -p "Pesan maintenance [Sedang maintenance, kembali lagi nanti.]: " MM_MSG
            MM_MSG=${MM_MSG:-Sedang maintenance, kembali lagi nanti.}
            php artisan down --message="$MM_MSG"
            log_msg "Panel maintenance mode diaktifkan"
            echo -e "${YELLOW}Panel sekarang dalam mode maintenance.${NC}"
            ;;
        2)
            php artisan up
            log_msg "Panel maintenance mode dinonaktifkan"
            echo -e "${GREEN}Panel kembali online.${NC}"
            ;;
        *)
            echo -e "${YELLOW}Pilihan tidak valid.${NC}"
            ;;
    esac
    pause
}

function panel_user_manager() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    while true; do
        header
        echo -e "${BLUE}Manajemen User Panel${NC}"
        echo "1) List semua user"
        echo "2) Buat user baru"
        echo "3) Edit user (reset pass / set admin)"
        echo "4) Hapus user"
        echo "0) Kembali"
        read -r -p "Pilih [0-4]: " UO
        case "$UO" in
            1) php artisan p:user:list 2>/dev/null || echo "Command p:user:list tidak tersedia di versi panel ini."; pause ;;
            2) php artisan p:user:make; pause ;;
            3)
                read -r -p "Username/email: " U
                [ -n "$U" ] && php artisan p:user:edit "$U"
                pause
                ;;
            4)
                read -r -p "Username/email yang akan dihapus: " U
                if [ -n "$U" ]; then
                    confirm_action "Hapus user $U? Tidak bisa di-undo." && php artisan p:user:delete "$U"
                fi
                pause
                ;;
            0) return 0 ;;
        esac
    done
}

function bulk_server_action() {
    require_root || return 1
    require_panel || return 1
    cd "$PANEL_DIR" || return 1
    header
    echo -e "${BLUE}Bulk Action Server Pterodactyl${NC}"
    echo "1) Suspend semua server"
    echo "2) Unsuspend semua server"
    echo "3) Restart semua container Wings"
    echo "0) Batal"
    read -r -p "Pilih [0-3]: " BO
    case "$BO" in
        1)
            confirm_action "Suspend SEMUA server panel?" || { pause; return 0; }
            php artisan tinker --execute='Pterodactyl\Models\Server::query()->update(["suspended" => true]); echo "OK";' 2>&1 | tail -3
            log_msg "Bulk suspend semua server"
            ;;
        2)
            confirm_action "Unsuspend SEMUA server panel?" || { pause; return 0; }
            php artisan tinker --execute='Pterodactyl\Models\Server::query()->update(["suspended" => false]); echo "OK";' 2>&1 | tail -3
            log_msg "Bulk unsuspend semua server"
            ;;
        3)
            confirm_action "Restart SEMUA container Pterodactyl di Docker?" || { pause; return 0; }
            mapfile -t containers < <(
                docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null \
                    | awk '$2 ~ /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/ {print $1}'
            )
            if [ "${#containers[@]}" -eq 0 ]; then
                echo "Tidak ada container Pterodactyl yang berjalan."
            else
                docker restart "${containers[@]}"
                echo -e "${GREEN}${#containers[@]} container di-restart.${NC}"
                log_msg "Bulk restart ${#containers[@]} container"
            fi
            ;;
    esac
    pause
}

function list_admin_users() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${BLUE}Daftar User Panel (admin & root admin)${NC}"
    echo
    read -r -s -p "Password database $DB_USER: " DBP
    echo
    if [ -z "$DBP" ]; then
        fail "Password kosong."; pause; return 1
    fi

    local sql='
        SELECT
            id,
            username,
            email,
            CASE WHEN root_admin=1 THEN "YES" ELSE "no" END AS root,
            CASE WHEN use_totp=1 THEN "YES" ELSE "no" END AS twofa,
            COALESCE(DATE_FORMAT(updated_at, "%Y-%m-%d %H:%i"), "-") AS last_update,
            COALESCE(DATE_FORMAT(created_at, "%Y-%m-%d"), "-") AS created
        FROM users
        ORDER BY root_admin DESC, id ASC;
    '
    local out
    if ! out=$(mysql_secure "$DB_USER" "$DBP" -h 127.0.0.1 -D "$DB_NAME" \
                            --batch --table -e "$sql" 2>&1); then
        fail "Query gagal. Cek password DB / nama DB."
        echo "$out" | head -3 | sed 's/^/  /'
        pause; return 1
    fi
    echo "$out"
    echo
    local total admins twofa_on
    total=$(echo "$out" | grep -cE '^\| +[0-9]+ +\|')
    admins=$(echo "$out" | awk -F'|' 'NR>3 && $5 ~ /YES/ {c++} END{print c+0}')
    twofa_on=$(echo "$out" | awk -F'|' 'NR>3 && $6 ~ /YES/ {c++} END{print c+0}')
    echo -e "${CYAN}Total user : ${total}${NC}"
    echo -e "${CYAN}Root admin : ${admins}${NC}"
    echo -e "${CYAN}Pakai 2FA  : ${twofa_on}${NC}"
    if [ "$admins" -gt 0 ] && [ "$twofa_on" -lt "$admins" ]; then
        echo -e "${YELLOW}PERINGATAN: ada admin tanpa 2FA aktif.${NC}"
    fi
    log_msg "List admin users dijalankan ($total user, $admins admin)"
    pause
}
