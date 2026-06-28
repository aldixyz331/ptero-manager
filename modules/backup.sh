#!/bin/bash

function _detect_domain_from_nginx() {
    local f="/etc/nginx/sites-available/pterodactyl.conf"
    [[ -f "$f" ]] || return 1
    local sn
    sn=$(grep -m1 -oP 'server_name\s+\K[^ ;]+' "$f" 2>/dev/null | head -1)
    if [[ -n "$sn" && "$sn" != "_" && "$sn" != "localhost" ]]; then
        printf '%s' "$sn"
        return 0
    fi
    return 1
}

function _ensure_panel_domain() {
    local current="${PANEL_DOMAIN:-}"
    if [[ -n "$current" && "$current" != "localhost" ]]; then
        return 0
    fi
    local detected=""
    if detected=$(_detect_domain_from_nginx); then
        PANEL_DOMAIN="$detected"
        echo -e "${GREEN}[*] Domain panel auto-detect dari nginx: $PANEL_DOMAIN${NC}"
        save_config
        return 0
    fi
    if [[ "${1:-interactive}" != "interactive" ]]; then
        return 1
    fi
    echo
    echo -e "${YELLOW}Domain panel belum di-set (saat ini: '${current:-kosong}').${NC}"
    echo -e "Domain ini akan ditulis ke backup.meta — dipakai saat restore untuk generate nginx config."
    local tries=0
    while (( tries < 3 )); do
        read -r -p "Domain panel (contoh: panel.example.com) [skip=localhost]: " RAW
        if [[ -z "$RAW" || "$RAW" == "skip" ]]; then
            echo -e "${YELLOW}Lewati. backup.meta akan berisi PANEL_DOMAIN=localhost.${NC}"
            return 1
        fi
        local v
        if v=$(validate_domain "$RAW"); then
            PANEL_DOMAIN="$v"
            save_config
            echo -e "${GREEN}Domain diset: $PANEL_DOMAIN${NC}"
            return 0
        fi
        echo -e "${RED}Format domain tidak valid.${NC}"
        tries=$((tries+1))
    done
    return 1
}

function _copy_wings_config() {
    local src="$1"
    local dest="$2"
    [[ -d "$src" ]] || return 0
    mkdir -p "$dest"
    local copied=0
    local patterns="config.yml config.yaml"
    local p
    for p in $patterns; do
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            local rel="${f#"$src"/}"
            mkdir -p "$dest/$(dirname "$rel")"
            cp -a "$f" "$dest/$rel" 2>/dev/null && copied=$((copied+1))
        done < <(find "$src" -maxdepth 3 -type f -name "$p" 2>/dev/null)
    done
    return 0
}

function _zip_create() {
    local workdir="$1" src="$2" out="$3"
    shift 3
    local zlvl="${BACKUP_COMPRESSION_LEVEL:-6}" rc=1
    _zip_interrupted=0
    trap '_zip_interrupted=1; rm -f "$out" 2>/dev/null; echo -e "    ${RED}✗ Backup dibatalkan (signal)${NC}"' SIGINT SIGTERM
    if (cd "$workdir" && zip -"${zlvl}" -r "$out" "$src" "$@" 2>/dev/null) \
        && unzip -tq "$out" >/dev/null 2>&1; then
        rc=0
    else
        rm -f "$out" 2>/dev/null
        echo -e "    ${RED}✗ Zip gagal/corrupt: $(basename "$out")${NC}"
    fi
    trap - SIGINT SIGTERM
    [ "$_zip_interrupted" -eq 1 ] && return 130
    return $rc
}

function _check_disk_space() {
    local target_dir="$1"
    local min_gb="${BACKUP_MIN_DISK_GB:-2}"
    local free_kb
    free_kb=$(df -Pk "$target_dir" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -z "$free_kb" ]]; then
        return 0
    fi
    local free_gb=$((free_kb / 1024 / 1024))
    if (( free_gb < min_gb )); then
        echo -e "${RED}Disk space tidak cukup di $target_dir.${NC}"
        echo -e "  Free : ${YELLOW}${free_gb}GB${NC}"
        echo -e "  Min  : ${min_gb}GB (BACKUP_MIN_DISK_GB)"
        echo -e "  Set BACKUP_MIN_DISK_GB=0 di config untuk skip check."
        return 1
    fi
    return 0
}

function backup_db_only() {
    require_root || return 1
    read -r -s -p "Password database user $DB_USER: " DB_PASS
    echo
    if [ -z "$DB_PASS" ]; then
        fail "Password database tidak boleh kosong."
        pause
        return 1
    fi
    local dest
    dest="$BACKUP_ROOT/db_only_$(date +%F_%H-%M-%S).sql"
    mkdir -p "$BACKUP_ROOT"
    echo -e "${BLUE}[*] Backup database saja...${NC}"
    if mysqldump_secure "$DB_USER" "$DB_PASS" -h 127.0.0.1 "$DB_NAME" > "$dest"; then
        local size
        size=$(du -sh "$dest" | awk '{print $1}')
        log_msg "Backup DB only sukses: $dest ($size)"
        notify_detail "BACKUP DB" "Backup database selesai: $(basename "$dest") ($size)"
        echo -e "${GREEN}Backup database selesai: $dest ($size)${NC}"
    else
        rm -f "$dest"
        fail "Backup database gagal."
    fi
    pause
}

function backup_system() {
    require_root || return 1
    read -r -s -p "Password database user $DB_USER: " DB_PASS
    echo
    backup_system_with_password "$DB_PASS" "yes"
}

function backup_system_with_password() {
    local backup_password="$1"
    local interactive="${2:-no}"

    if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt install -y zip unzip >/dev/null 2>&1 || true
    fi

    acquire_lock || { [ "$interactive" = "yes" ] && pause; return 1; }
    trap 'release_lock' EXIT

    [ "$interactive" = "yes" ] && _ensure_panel_domain interactive

    mkdir -p "$BACKUP_ROOT"
    if [ "${BACKUP_MIN_DISK_GB:-2}" -gt 0 ]; then
        if ! _check_disk_space "$BACKUP_ROOT"; then
            release_lock; trap - EXIT
            [ "$interactive" = "yes" ] && pause
            return 1
        fi
    fi

    local dest_dir dest start_ts end_ts duration
    dest_dir="ptero_$(date +%F_%H-%M-%S)"
    dest="$BACKUP_ROOT/$dest_dir"
    mkdir -p "$dest"
    start_ts=$(date +%s)

    log_msg "Backup dimulai: $dest"
    qprint "${BLUE}[*] Memulai backup database, panel, Wings, dan volume...${NC}"

    if mysqldump_secure "$DB_USER" "$backup_password" -h 127.0.0.1 "$DB_NAME" \
            > "$dest/panel_db.sql"; then

        echo "PANEL_DOMAIN=${PANEL_DOMAIN:-localhost}" > "$dest/backup.meta"

        local zlvl="${BACKUP_COMPRESSION_LEVEL:-6}"
        _zip_create /var/www pterodactyl "$dest/panel_files.zip" || true
        if [ -d "$WINGS_DIR" ]; then
            _copy_wings_config "$WINGS_DIR" "$dest/wings_config"
            local wc
            wc=$(find "$dest/wings_config" -type f 2>/dev/null | wc -l)
            log_msg "Wings config: $wc file(s) copied (config.yml only)"
            echo -e "    ${GREEN}+ wings_config: $wc file (config.yml only, cert excluded)${NC}"
        fi
        if [ -d /var/lib/pterodactyl/volumes ]; then
            _zip_create /var/lib pterodactyl/volumes "$dest/server_volumes.zip" || true
        fi

        local total_size
        total_size=$(du -sh "$dest" | awk '{print $1}')

        local failed=0
        for f in panel_db.sql panel_files.zip server_volumes.zip; do
            if [ -f "$dest/$f" ] && [ ! -s "$dest/$f" ]; then
                qprint "${RED}PERINGATAN: $f kosong!${NC}"
                log_msg "PERINGATAN: backup file $f kosong"
                failed=$((failed+1))
            fi
        done

        local rclone_status="skip"
        if command -v rclone >/dev/null 2>&1 && [ -f /root/.ptero_rclone ]; then
            local r_info
            r_info=$(cat /root/.ptero_rclone)
            qprint "${BLUE}[*] Upload backup ke cloud...${NC}"
            if rclone copy "$dest" "$r_info/$dest_dir" --progress 2>&1; then
                rclone_status="ok"
                notify_detail "BACKUP CLOUD" "Backup cloud OK: $dest_dir ($total_size)"
            else
                rclone_status="fail"
                qprint "${RED}Upload cloud GAGAL.${NC}"
                log_msg "Upload cloud gagal untuk $dest_dir"
                notify_detail "BACKUP CLOUD GAGAL" "Upload cloud gagal: $dest_dir"
            fi
        fi

        cleanup_old_backups
        end_ts=$(date +%s)
        duration=$((end_ts - start_ts))
        log_msg "Backup sukses: $dest ($total_size, ${duration}s, cloud=$rclone_status)"

        if [ "$failed" -eq 0 ]; then
            notify_detail "BACKUP OK" "Backup lokal selesai: $dest_dir ($total_size, ${duration}s)"
            qprint "${GREEN}Backup selesai di $dest ($total_size, ${duration}s)${NC}"
        else
            notify_detail "BACKUP WARN" "Backup selesai DENGAN PERINGATAN: $dest_dir"
            qprint "${YELLOW}Backup selesai tapi ada file yang kosong. Cek di $dest${NC}"
        fi
    else
        rm -rf "$dest"
        log_msg "Backup gagal"
        notify_detail "BACKUP GAGAL" "Backup database gagal! Periksa password."
        fail "Backup database gagal. Periksa password database."
    fi

    release_lock
    trap - EXIT

    if [ "$interactive" = "yes" ]; then
        pause
    fi
}

function preview_backup() {
    local b="$1"
    echo -e "${BLUE}=== Preview Backup ===${NC}"
    echo -e "Path     : $b"
    echo -e "Tanggal  : $(stat -c %y "$b" 2>/dev/null | cut -d. -f1)"
    echo -e "Total    : $(du -sh "$b" 2>/dev/null | awk '{print $1}')"
    echo
    if [ -f "$b/panel_db.sql" ]; then
        echo -e "  ${GREEN}[v]${NC} Database  : $(du -sh "$b/panel_db.sql" | awk '{print $1}')"
    fi
    if [ -f "$b/panel_files.zip" ]; then
        echo -e "  ${GREEN}[v]${NC} Panel     : $(du -sh "$b/panel_files.zip" | awk '{print $1}')"
    fi
    if [ -d "$b/wings_config" ]; then
        echo -e "  ${GREEN}[v]${NC} Wings cfg : $(du -sh "$b/wings_config" | awk '{print $1}')"
    fi
    if [ -f "$b/server_volumes.zip" ]; then
        echo -e "  ${GREEN}[v]${NC} Volume    : $(du -sh "$b/server_volumes.zip" | awk '{print $1}')"
    fi
    if [ -f "$b/backup.meta" ]; then
        local _domain
        _domain=$(grep -oP '^PANEL_DOMAIN=\K.*' "$b/backup.meta" 2>/dev/null || echo "?")
        echo -e "  ${GREEN}[v]${NC} Domain    : $_domain"
    fi
    echo
}

function restore_system() {
    require_root || return 1
    if ! command -v unzip >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt install -y unzip >/dev/null 2>&1 || true
    fi
    header
    echo -e "${YELLOW}PERINGATAN: Restore akan menimpa data panel sesuai komponen yang dipilih.${NC}"

    local BACKUP_PATH="${1:-}"
    if [ -z "$BACKUP_PATH" ]; then
        mapfile -t BACKUPS < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
        if [ "${#BACKUPS[@]}" -eq 0 ]; then
            fail "Tidak ada backup tersedia di $BACKUP_ROOT."
            pause
            return 1
        fi
        echo -e "${BLUE}Daftar backup tersedia:${NC}"
        BACKUP_PATH=$(pick_from_list "Pilih nomor backup:" "${BACKUPS[@]}") || {
            fail "Pilihan tidak valid."; pause; return 1
        }
    fi
    echo
    preview_backup "$BACKUP_PATH"

    if [ -f "$BACKUP_PATH/backup.meta" ]; then
        local _bkdomain
        _bkdomain=$(grep -oP '^PANEL_DOMAIN=\K.*' "$BACKUP_PATH/backup.meta" 2>/dev/null || echo "")
        if [ "$_bkdomain" = "localhost" ] || [ -z "$_bkdomain" ]; then
            echo -e "${YELLOW}PERINGATAN: backup.meta berisi PANEL_DOMAIN='${_bkdomain:-kosong}'.${NC}"
            echo -e "Restore akan generate nginx config dengan domain ini. Untuk fix, gunakan menu 'Fix Backup Domain'."
            confirm_action "Lanjut restore dengan domain '$_bkdomain'?" || { pause; return 1; }
        fi
    fi

    echo -e "${CYAN}Komponen yang ingin di-restore:${NC}"
    echo "1) Lengkap (database + panel + wings + volume)"
    echo "2) Database saja"
    echo "3) Panel files saja"
    echo "4) Wings config saja"
    echo "5) Server volumes saja"
    echo "0) Batal"
    read -r -p "Pilih [0-5]: " RMODE
    [ "$RMODE" = "0" ] && { echo "Dibatalkan."; pause; return 0; }
    if ! echo "$RMODE" | grep -Eq '^[1-5]$'; then
        fail "Pilihan tidak valid."; pause; return 1
    fi

    confirm_action "Lanjut restore mode $RMODE dari: $BACKUP_PATH ?" \
        || { echo "Dibatalkan."; pause; return 1; }

    if [ ! -d "$BACKUP_PATH" ]; then
        fail "Folder backup tidak ditemukan."; pause; return 1
    fi

    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT

    case "$RMODE" in
        1)
            for required in panel_db.sql panel_files.zip; do
                if [ ! -f "$BACKUP_PATH/$required" ]; then
                    fail "File backup wajib tidak ada: $required"
                    release_lock; trap - EXIT; pause; return 1
                fi
            done
            ;;
        2) [ -f "$BACKUP_PATH/panel_db.sql" ] || { fail "panel_db.sql tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
         3) [ -f "$BACKUP_PATH/panel_files.zip" ] || { fail "panel_files.zip tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
         4) [ -d "$BACKUP_PATH/wings_config" ] || { fail "wings_config tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
         5) [ -f "$BACKUP_PATH/server_volumes.zip" ] || { fail "server_volumes.zip tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
    esac

    ask_mysql_root_password
    read -r -s -p "Password database untuk user $DB_USER: " DB_PASS
    echo
    local db_pass_sql
    db_pass_sql=$(printf "%s" "$DB_PASS" | sed "s/'/''/g")

    log_msg "Restore dimulai dari: $BACKUP_PATH (mode $RMODE)"
    systemctl stop wings pteroq nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true

    _restore_abort() {
        fail "$1"
        systemctl start "php${PHP_VERSION}-fpm" nginx pteroq wings 2>/dev/null || true
        notify_detail "RESTORE GAGAL" "Restore mode $RMODE dari $(basename "$BACKUP_PATH") gagal: $1"
        release_lock; trap - EXIT; pause; return 1
    }

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "2" ]; then
        mysql_root -e "
            DROP DATABASE IF EXISTS $DB_NAME;
            CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
            CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
            ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
            GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'127.0.0.1';
            FLUSH PRIVILEGES;
        " || { _restore_abort "Gagal menyiapkan database (cek password root)."; return 1; }
        mysql_secure "$DB_USER" "$DB_PASS" -h 127.0.0.1 "$DB_NAME" < "$BACKUP_PATH/panel_db.sql" \
            || { _restore_abort "Restore database gagal."; return 1; }
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "3" ]; then
        rm -rf "$PANEL_DIR"
        unzip -o "$BACKUP_PATH/panel_files.zip" -d /var/www \
            || { _restore_abort "Ekstrak panel_files.zip gagal."; return 1; }
        chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
        chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
        set_env_value TRUSTED_PROXIES "*"
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "4" ]; then
        mkdir -p "$WINGS_DIR"
        [ -d "$BACKUP_PATH/wings_config" ] && cp -a "$BACKUP_PATH/wings_config/." "$WINGS_DIR/"
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "5" ]; then
        mkdir -p /var/lib/pterodactyl/volumes
        if [ -f "$BACKUP_PATH/server_volumes.zip" ]; then
            unzip -o "$BACKUP_PATH/server_volumes.zip" -d /var/lib \
                || { _restore_abort "Ekstrak server_volumes.zip gagal."; return 1; }
        fi
    fi

    # --- Nginx config (sama kaya install.sh, pake domain dari backup) ---
    mkdir -p /etc/certs/panel /etc/nginx/sites-available /etc/nginx/sites-enabled
    local DOMAIN="localhost"
    if [ -f "$BACKUP_PATH/backup.meta" ]; then
        DOMAIN=$(grep -oP '^PANEL_DOMAIN=\K.*' "$BACKUP_PATH/backup.meta" 2>/dev/null || echo "localhost")
    fi
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=NA/ST=NA/L=NA/O=NA/CN=${DOMAIN}" \
        -keyout /etc/certs/panel/privkey.pem -out /etc/certs/panel/fullchain.pem 2>/dev/null || true
    cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    root /var/www/pterodactyl/public;
    index index.php;
    ssl_certificate /etc/certs/panel/fullchain.pem;
    ssl_certificate_key /etc/certs/panel/privkey.pem;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location ~ /\.ht { deny all; }
}
NGINX
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true
    fi

    systemctl start pteroq wings 2>/dev/null || true
    log_msg "Restore selesai dari: $BACKUP_PATH (mode $RMODE)"
    notify_detail "RESTORE OK" "Restore mode $RMODE dari $(basename "$BACKUP_PATH") selesai."
    echo -e "${GREEN}Restore selesai.${NC}"
    release_lock
    trap - EXIT
    pause
}

function list_backups() {
    require_root || return 1
    header
    echo -e "${BLUE}Daftar backup di $BACKUP_ROOT:${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."
    else
        local i=0
        while IFS= read -r bdir; do
            i=$((i+1))
            local size
            size=$(du -sh "$bdir" 2>/dev/null | awk '{print $1}')
            echo -e "  ${CYAN}[$i]${NC} $(basename "$bdir")  ${YELLOW}($size)${NC}"
        done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ptero_*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
        [ "$i" -eq 0 ] && echo "Backup belum ada."
    fi
    echo
    pause
}

function cleanup_old_backups() {
    [ -d "$BACKUP_ROOT" ] || return 0
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ptero_*' \
        -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -rf {} \; 2>/dev/null || true
    local count
    count=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ptero_*' 2>/dev/null | wc -l)
    if [ "$count" -gt "$BACKUP_MAX_COUNT" ]; then
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ptero_*' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | tail -n +"$((BACKUP_MAX_COUNT + 1))" | cut -d' ' -f2- | xargs -r rm -rf
    fi
}

function delete_backup() {
    require_root || return 1
    header
    mapfile -t BACKUPS < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ptero_*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        echo -e "${YELLOW}Belum ada backup.${NC}"
        pause
        return 0
    fi
    echo -e "${BLUE}Pilih backup yang akan dihapus:${NC}"
    local target
    target=$(pick_from_list "Nomor backup:" "${BACKUPS[@]}") || {
        echo -e "${YELLOW}Dibatalkan.${NC}"; pause; return 0;
    }
    confirm_action "Hapus permanen: $target?" || { echo "Batal."; pause; return 0; }
    rm -rf "$target"
    log_msg "Backup dihapus: $target"
    echo -e "${GREEN}Backup dihapus.${NC}"
    pause
}

function schedule_auto_backup() {
    require_root || return 1
    read -r -s -p "Password database $DB_USER untuk auto backup: " AUTO_DB_PASS
    echo
    if ! validate_db_password "$AUTO_DB_PASS" 8; then
        pause
        return 1
    fi
    read -r -p "Jam backup harian [03:00]: " BACKUP_TIME
    BACKUP_TIME=${BACKUP_TIME:-03:00}
    if ! echo "$BACKUP_TIME" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
        fail "Format jam tidak valid (00:00–23:59). Gunakan HH:MM, contoh 03:00."
        pause
        return 1
    fi

    local enable_s3="no"
    if [ -f "$S3_CONFIG" ]; then
        read -r -p "Aktifkan auto-backup ke S3 juga? [y/N]: " ANS
        echo "$ANS" | grep -Eq '^[Yy]$' && enable_s3="yes"
    fi

    local hour minute script_path
    hour=${BACKUP_TIME%:*}
    minute=${BACKUP_TIME#*:}
    script_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    mkdir -p "$(dirname "$AUTO_BACKUP_CNF")"
    chmod 700 "$(dirname "$AUTO_BACKUP_CNF")"
    local _old_umask
    _old_umask=$(umask); umask 077
    {
        printf '[client]\n'
        printf 'user=%s\n' "$DB_USER"
        printf 'password=%s\n' "$AUTO_DB_PASS"
        printf 'host=127.0.0.1\n'
    } > "$AUTO_BACKUP_CNF"
    chmod 600 "$AUTO_BACKUP_CNF"
    umask "$_old_umask"

    local s3_flag=""
    [ "$enable_s3" = "yes" ] && s3_flag="--auto-s3-backup"
    cat > "$AUTO_BACKUP_SCRIPT" <<AUTO
#!/bin/bash
exec bash '$script_path' --auto-backup --cnf '$AUTO_BACKUP_CNF' $s3_flag >> '$LOG_FILE' 2>&1
AUTO
    chmod 700 "$AUTO_BACKUP_SCRIPT"
    setup_logrotate
    cat > /etc/cron.d/ptero-manager-backup <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$minute $hour * * * root $AUTO_BACKUP_SCRIPT >> $LOG_FILE 2>&1
CRON
    systemctl restart cron 2>/dev/null || true
    log_msg "Backup otomatis dijadwalkan setiap $BACKUP_TIME (S3=$enable_s3)"
    echo -e "${GREEN}Backup otomatis aktif setiap jam $BACKUP_TIME.${NC}"
    if [ "$enable_s3" = "yes" ]; then
        echo -e "${GREEN}Auto-upload ke S3 juga aktif.${NC}"
    fi
    echo -e "${YELLOW}Kredensial DB tersimpan di $AUTO_BACKUP_CNF (root-only, mode 600).${NC}"
    pause
}

# Non-interactive S3 backup, called by cron when --auto-s3-backup is passed
function auto_backup_s3() {
    local db_pass="$1"
    if [ ! -f "$S3_CONFIG" ]; then
        echo "S3 config not found, skip S3 auto-backup" >> "$LOG_FILE"
        return 1
    fi
    if ! _ensure_panel_domain; then
        echo "S3 auto-backup SKIP: domain panel tidak valid" >> "$LOG_FILE"
        notify_detail "AUTO S3 BACKUP SKIP" "Domain panel belum di-set. Run menu 'Set Panel Domain' atau 'Backup & Restore > Set Backup Options'."
        return 1
    fi
    source "$S3_CONFIG"
    local backup_name="ptero_s3_$(date +%F_%H-%M-%S)"
    local tmp_dir="/tmp/$backup_name"
    mkdir -p "$tmp_dir"

    if [ "${BACKUP_MIN_DISK_GB:-2}" -gt 0 ] && ! _check_disk_space "$tmp_dir" >/dev/null 2>&1; then
        local free_gb=$(df -Pk "$tmp_dir" 2>/dev/null | tail -1 | awk '{print int($4/1024/1024)}')
        echo "S3 auto-backup SKIP: disk space ${free_gb}GB < ${BACKUP_MIN_DISK_GB}GB" >> "$LOG_FILE"
        notify_detail "AUTO S3 BACKUP SKIP" "Disk penuh (${free_gb}GB < ${BACKUP_MIN_DISK_GB}GB). Backup lokal sudah selesai, S3 dilewati."
        rm -rf "$tmp_dir"
        return 1
    fi

    local zlvl="${BACKUP_COMPRESSION_LEVEL:-6}"
    if mysqldump_secure "$DB_USER" "$db_pass" -h 127.0.0.1 "$DB_NAME" > "$tmp_dir/panel_db.sql" 2>/dev/null; then
        _zip_create /var/www pterodactyl "$tmp_dir/panel_files.zip" || true
        if [ -d "$WINGS_DIR" ]; then
            _copy_wings_config "$WINGS_DIR" "$tmp_dir/wings_config"
            _zip_create "$tmp_dir" wings_config "$tmp_dir/wings_config.zip" || true
        fi

        if [ -d /var/lib/pterodactyl/volumes ]; then
            _zip_create /var/lib pterodactyl/volumes "$tmp_dir/server_volumes.zip" || true
        fi
        echo "PANEL_DOMAIN=${PANEL_DOMAIN:-localhost}" > "$tmp_dir/backup.meta"

        local prefix="${S3_PREFIX:+$S3_PREFIX/}"
        local failed=0 uploaded=0
        for f in panel_db.sql panel_files.zip wings_config.zip server_volumes.zip backup.meta; do
            if [ -f "$tmp_dir/$f" ] && [ -s "$tmp_dir/$f" ]; then
                if _s3_upload_file "$tmp_dir/$f" "${prefix}${backup_name}/$f" >/dev/null 2>&1; then
                    uploaded=$((uploaded + 1))
                else
                    failed=$((failed + 1))
                    echo "S3 auto-backup upload FAIL: $f" >> "$LOG_FILE"
                fi
            fi
        done
        rm -rf "$tmp_dir"
        if [ "$failed" -eq 0 ]; then
            echo "S3 auto-backup OK: $backup_name ($uploaded files)" >> "$LOG_FILE"
            log_msg "S3 auto-backup OK: $backup_name"
        else
            echo "S3 auto-backup PARTIAL: $backup_name ($uploaded ok, $failed fail)" >> "$LOG_FILE"
            log_msg "S3 auto-backup PARTIAL: $backup_name"
            notify_detail "AUTO S3 BACKUP WARN" "S3 auto-backup $backup_name: $uploaded ok, $failed fail."
        fi
    else
        rm -rf "$tmp_dir"
        echo "S3 auto-backup FAIL: mysqldump gagal" >> "$LOG_FILE"
        notify_detail "AUTO S3 BACKUP FAIL" "mysqldump gagal, S3 auto-backup dilewati."
        return 1
    fi
}

function set_panel_domain() {
    require_root || return 1
    header
    echo -e "${BLUE}Set Panel Domain${NC}"
    echo
    local detected=""
    detected=$(_detect_domain_from_nginx 2>/dev/null || true)
    if [[ -n "$detected" ]]; then
        echo -e "  Auto-detect dari nginx: ${CYAN}$detected${NC}"
    fi
    echo -e "  Saat ini            : ${CYAN}${PANEL_DOMAIN:-<kosong>}${NC}"
    echo
    echo -e "Domain ini akan dipakai untuk:"
    echo -e "  - Backup meta (saat restore, generate nginx config)"
    echo -e "  - Let's Encrypt cert path"
    echo -e "  - TRUSTED_PROXIES / set_env_value"
    echo
    read -r -p "Domain panel (contoh: panel.example.com): " RAW
    if [[ -z "$RAW" ]]; then
        if [[ -n "$detected" ]]; then
            PANEL_DOMAIN="$detected"
            save_config
            echo -e "${GREEN}Set ke auto-detect: $PANEL_DOMAIN${NC}"
        else
            echo -e "${YELLOW}Tidak diubah.${NC}"
        fi
        pause
        return
    fi
    local v
    if v=$(validate_domain "$RAW"); then
        PANEL_DOMAIN="$v"
        save_config
        echo -e "${GREEN}Domain diset: $PANEL_DOMAIN${NC}"
        log_msg "Panel domain diset ke $PANEL_DOMAIN"
    else
        fail "Format domain tidak valid: $RAW"
    fi
    pause
}

function fix_backup_domain() {
    require_root || return 1
    if [ -z "$PANEL_DOMAIN" ] || [ "$PANEL_DOMAIN" = "localhost" ]; then
        fail "PANEL_DOMAIN belum di-set. Jalankan menu 'Set Panel Domain' dulu."
        pause
        return 1
    fi
    header
    echo -e "${BLUE}Fix Backup Domain (rewrite backup.meta)${NC}"
    echo -e "Domain target: ${CYAN}$PANEL_DOMAIN${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        fail "Folder backup belum ada: $BACKUP_ROOT"; pause; return 1
    fi
    mapfile -t BACKUPS < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        echo -e "${YELLOW}Belum ada backup.${NC}"
        pause; return 0
    fi

    echo "Pilih mode:"
    echo "1) Fix SEMUA backup"
    echo "2) Fix backup tertentu (pilih nomor)"
    echo "3) Tampilkan backup dengan PANEL_DOMAIN=localhost (lokal & S3)"
    echo "0) Batal"
    read -r -p "Pilih [0-3]: " MODE
    case "$MODE" in
        1)
            confirm_action "Rewrite backup.meta SEMUA ${#BACKUPS[@]} backup ke '$PANEL_DOMAIN'?" || { pause; return; }
            local fixed=0
            for b in "${BACKUPS[@]}"; do
                if [ -d "$b" ]; then
                    echo "PANEL_DOMAIN=$PANEL_DOMAIN" > "$b/backup.meta"
                    fixed=$((fixed+1))
                fi
            done
            echo -e "${GREEN}$fixed backup diperbaiki.${NC}"
            log_msg "Fix backup domain: $fixed backup rewritten to $PANEL_DOMAIN"
            ;;
        2)
            local pick
            pick=$(pick_from_list "Pilih backup:" "${BACKUPS[@]}") || { pause; return; }
            echo "PANEL_DOMAIN=$PANEL_DOMAIN" > "$pick/backup.meta"
            echo -e "${GREEN}$(basename "$pick") diperbaiki.${NC}"
            log_msg "Fix backup domain: $(basename "$pick") → $PANEL_DOMAIN"
            ;;
        3)
            echo
            local total=0 bad=0
            for b in "${BACKUPS[@]}"; do
                total=$((total+1))
                local d
                d=$(grep -oP '^PANEL_DOMAIN=\K.*' "$b/backup.meta" 2>/dev/null || echo "?")
                if [ "$d" = "localhost" ] || [ "$d" = "?" ] || [ -z "$d" ]; then
                    bad=$((bad+1))
                    echo -e "  ${RED}$(basename "$b"): $d${NC}"
                fi
            done
            if [ "$total" -gt 0 ] && [ -f /root/.ptero-s3.conf ]; then
                source /root/.ptero-s3.conf
                local s3_total
                s3_total=$(_s3_exec_cmd ls "s3://$S3_BUCKET/${S3_PREFIX:+$S3_PREFIX/}" 2>/dev/null \
                    | grep -oP 'ptero_s3_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | sort -u | wc -l)
                echo -e "  S3 backups: ${CYAN}${s3_total:-0}${NC} (domain tidak bisa di-edit dari script; download-edit-upload manual)"
            fi
            echo
            echo -e "Summary: ${RED}$bad${NC} dari $total backup lokal perlu di-fix."
            ;;
        0) return ;;
    esac
    pause
}

function set_backup_options() {
    require_root || return 1
    header
    echo -e "${BLUE}Set Backup Options${NC}"
    echo
    echo -e "  Disk min free      : ${CYAN}${BACKUP_MIN_DISK_GB}GB${NC} (0 = skip check)"
    echo -e "  Compression level  : ${CYAN}${BACKUP_COMPRESSION_LEVEL}${NC} (1=fast, 6=default, 9=max)"
    echo -e "  Auto-backup pre-update: ${CYAN}$([ "${AUTO_BACKUP_BEFORE_UPDATE:-1}" = "1" ] && echo yes || echo no)${NC}"
    echo
    echo "1) Ubah disk minimum"
    echo "2) Ubah compression level"
    echo "3) Toggle auto-backup pre-update"
    echo "0) Kembali"
    read -r -p "Pilih [0-3]: " opt
    case "$opt" in
        1)
            read -r -p "Disk minimum free (GB) [${BACKUP_MIN_DISK_GB}]: " V
            [[ "$V" =~ ^[0-9]+$ ]] || { fail "Harus angka."; pause; return; }
            BACKUP_MIN_DISK_GB=$V
            save_config
            echo -e "${GREEN}Set: BACKUP_MIN_DISK_GB=$V${NC}"
            ;;
        2)
            read -r -p "Compression level (1-9) [${BACKUP_COMPRESSION_LEVEL}]: " V
            [[ "$V" =~ ^[1-9]$ ]] || { fail "Harus 1-9."; pause; return; }
            BACKUP_COMPRESSION_LEVEL=$V
            save_config
            echo -e "${GREEN}Set: BACKUP_COMPRESSION_LEVEL=$V${NC}"
            echo -e "${YELLOW}1=fast/poor, 6=balanced, 9=max/slow${NC}"
            ;;
        3)
            if [ "${AUTO_BACKUP_BEFORE_UPDATE:-1}" = "1" ]; then
                AUTO_BACKUP_BEFORE_UPDATE=0
                echo -e "${YELLOW}Auto-backup sebelum update: OFF${NC}"
            else
                AUTO_BACKUP_BEFORE_UPDATE=1
                echo -e "${GREEN}Auto-backup sebelum update: ON${NC}"
                echo -e "${CYAN}Butuh AUTO_BACKUP_CNF ter-setup.${NC}"
            fi
            save_config
            ;;
        0) return ;;
    esac
    pause
}

S3_CONFIG="/root/.ptero-s3.conf"

function backup_s3_setup() {
    require_root || return 1
    header
    echo -e "${BLUE}Setup S3-Compatible Backup Destination${NC}"
    echo -e "${YELLOW}Mendukung: AWS S3, Wasabi, Backblaze B2, MinIO, DO Spaces, dll.${NC}"
    echo

    if [ -f "$S3_CONFIG" ]; then
        echo -e "Konfigurasi S3 saat ini: ${GREEN}(tersimpan)${NC}"
        echo "1) Ubah konfigurasi"
        echo "2) Hapus konfigurasi"
        echo "3) Test upload"
        echo "0) Kembali"
        read -r -p "Pilih [0-3]: " SO
        case "$SO" in
            2) rm -f "$S3_CONFIG"; echo -e "${GREEN}Konfigurasi S3 dihapus.${NC}"; pause; return 0 ;;
            3) backup_s3_test_upload; return 0 ;;
            0) return 0 ;;
        esac
    fi

    echo -e "${CYAN}Masukkan detail S3:${NC}"
    read -r -p "Endpoint URL (contoh https://s3.amazonaws.com): " S3_ENDPOINT
    [ -z "$S3_ENDPOINT" ] && { fail "Endpoint wajib diisi."; pause; return 1; }
    read -r -p "Access Key ID: " S3_ACCESS_KEY
    [ -z "$S3_ACCESS_KEY" ] && { fail "Access Key wajib diisi."; pause; return 1; }
    read -r -s -p "Secret Access Key: " S3_SECRET_KEY
    echo
    [ -z "$S3_SECRET_KEY" ] && { fail "Secret Key wajib diisi."; pause; return 1; }
    read -r -p "Bucket name: " S3_BUCKET
    [ -z "$S3_BUCKET" ] && { fail "Bucket wajib diisi."; pause; return 1; }
    read -r -p "Path prefix (opsional, contoh: backups/ptero): " S3_PREFIX
    read -r -p "Region (opsional, default: us-east-1): " S3_REGION
    S3_REGION=${S3_REGION:-us-east-1}

    if [ -d /var/lib/pterodactyl/volumes ]; then
        local vol_size
        vol_size=$(du -sh /var/lib/pterodactyl/volumes 2>/dev/null | awk '{print $1}')
        echo
        echo -e "${YELLOW}Server volumes terdeteksi: $vol_size${NC}"
        echo -e "Backup S3 akan otomatis include server_volumes (mirip backup lokal)."
    fi

    local _old_umask
    _old_umask=$(umask); umask 077
    cat > "$S3_CONFIG" <<S3CONF
S3_ENDPOINT="$S3_ENDPOINT"
S3_ACCESS_KEY="$S3_ACCESS_KEY"
S3_SECRET_KEY="$S3_SECRET_KEY"
S3_BUCKET="$S3_BUCKET"
S3_PREFIX="$S3_PREFIX"
S3_REGION="$S3_REGION"
S3CONF
    chmod 600 "$S3_CONFIG"
    umask "$_old_umask"

    if ! command -v s3cmd >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Install s3cmd...${NC}"
        DEBIAN_FRONTEND=noninteractive apt install -y s3cmd >/dev/null 2>&1 || true
    fi
    if ! command -v s3cmd >/dev/null 2>&1; then
        echo -e "${YELLOW}s3cmd tidak bisa diinstall. Coba: apt install s3cmd${NC}"
    fi

    log_msg "S3 backup destination configured: $S3_ENDPOINT/$S3_BUCKET"
    echo -e "${GREEN}S3 configuration saved.${NC}"
    echo
    echo "1) Test upload sekarang"
    echo "0) Kembali"
    read -r -p "Pilih [0-1]: " TOPT
    case "$TOPT" in
        1) backup_s3_test_upload ;;
    esac
}

function _s3_upload_file() {
    local local_path="$1"
    local remote_path="$2"
    [ -f "$local_path" ] || return 1

    if [ ! -f "$S3_CONFIG" ]; then
        echo "  ${RED}S3 config not found${NC}"
        return 1
    fi

    source "$S3_CONFIG"

    if ! command -v s3cmd >/dev/null 2>&1; then
        echo "  ${RED}s3cmd tidak terinstall. Jalankan: apt install s3cmd${NC}"
        return 1
    fi

    local ep
    ep=$(echo "$S3_ENDPOINT" | sed 's|/$||')
    local ep_host
    ep_host=$(echo "$ep" | sed 's|https\?://||')
    local host_bucket="%(bucket)s.$ep_host"

    local tmpcfg
    tmpcfg=$(mktemp /tmp/ptero-s3cfg-XXXXXX)
    cat > "$tmpcfg" <<S3CFG
[default]
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY
host_base = $ep_host
host_bucket = $host_bucket
bucket_location = ${S3_REGION:-us-east-1}
use_https = True
check_ssl_certificate = False
check_ssl_hostname = False
S3CFG

    local rc
    s3cmd -c "$tmpcfg" put "$local_path" "s3://$S3_BUCKET/$remote_path" 2>&1
    rc=$?
    rm -f "$tmpcfg"
    return $rc
}

function backup_s3_test_upload() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu."
        pause
        return 1
    fi

    source "$S3_CONFIG"
    echo -e "${BLUE}[*] Test upload ke S3 via s3cmd...${NC}"
    echo -e "  Endpoint : ${CYAN}$S3_ENDPOINT${NC}"
    echo -e "  Bucket   : ${CYAN}$S3_BUCKET${NC}"
    echo -e "  Region   : ${CYAN}${S3_REGION:-US}${NC}"
    echo

    local test_file="/tmp/ptero-s3-test-$(date +%s).txt"
    echo "Ptero Manager S3 test at $(date)" > "$test_file"

    local output
    output=$(_s3_upload_file "$test_file" "test/ptero-s3-test.txt" 2>&1)
    local rc=$?

    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}[OK] Upload test berhasil.${NC}"
        log_msg "S3 test upload OK"
        notify_detail "S3 TEST" "S3 backup destination test berhasil."
        echo
        echo "1) Hapus file test dari S3"
        read -r -p "Pilih [0-1]: " DEL
        if [ "$DEL" = "1" ]; then
            local ep=$(echo "$S3_ENDPOINT" | sed 's|/$||')
            local ep_host=$(echo "$ep" | sed 's|https\?://||')
            local host_bucket="%(bucket)s.$ep_host"
            local tmpcfg=$(mktemp /tmp/ptero-s3cfg-XXXXXX)
            cat > "$tmpcfg" <<S3CFG
[default]
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY
host_base = $ep_host
host_bucket = $host_bucket
bucket_location = ${S3_REGION:-us-east-1}
use_https = True
check_ssl_certificate = False
check_ssl_hostname = False
S3CFG
            s3cmd -c "$tmpcfg" del "s3://$S3_BUCKET/test/ptero-s3-test.txt" >/dev/null 2>&1
            rm -f "$tmpcfg"
        fi
    else
        echo -e "${RED}[FAIL] Upload test gagal (rc=$rc).${NC}"
        echo
        echo -e "${YELLOW}Error dari s3cmd:${NC}"
        echo "$output" | sed 's/^/  /'
        echo
        echo -e "${YELLOW}Penyebab umum:${NC}"
        echo -e "  1. Endpoint salah"
        echo -e "     B2: https://s3.<region>.backblazeb2.com"
        echo -e "     AWS: https://s3.<region>.amazonaws.com"
        echo -e "     Wasabi: https://s3.<region>.wasabisys.com"
        echo -e "  2. Bucket belum dibuat di dashboard"
        echo -e "  3. Access Key / Secret Key tidak punya akses ke bucket"
        echo -e "  4. Region tidak sesuai endpoint"
        echo
        echo -e "${YELLOW}Coba test manual:${NC}"
        echo -e "  apt install s3cmd"
        echo -e "  s3cmd --host=$S3_ENDPOINT --access_key=$S3_ACCESS_KEY ls"
    fi
    rm -f "$test_file"
    pause
}

function backup_to_s3() {
    require_root || return 1
    if ! command -v zip >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt install -y zip >/dev/null 2>&1 || true
    fi
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu (menu 64)."
        pause
        return 1
    fi

    source "$S3_CONFIG"
    local backup_name="ptero_s3_$(date +%F_%H-%M-%S)"
    local tmp_dir="/tmp/$backup_name"
    mkdir -p "$tmp_dir"

    if [ "${BACKUP_MIN_DISK_GB:-2}" -gt 0 ]; then
        if ! _check_disk_space "$tmp_dir"; then
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    _ensure_panel_domain interactive

    echo -e "${BLUE}[*] Backup & upload ke S3: $S3_ENDPOINT/$S3_BUCKET${NC}"

    read -r -s -p "Password database $DB_USER: " DBP
    echo

    local start_ts end_ts duration
    start_ts=$(date +%s)
    local zlvl="${BACKUP_COMPRESSION_LEVEL:-6}"

    if mysqldump_secure "$DB_USER" "$DBP" -h 127.0.0.1 "$DB_NAME" > "$tmp_dir/panel_db.sql"; then
        _zip_create /var/www pterodactyl "$tmp_dir/panel_files.zip" || true
        if [ -d "$WINGS_DIR" ]; then
            _copy_wings_config "$WINGS_DIR" "$tmp_dir/wings_config"
            _zip_create "$tmp_dir" wings_config "$tmp_dir/wings_config.zip" || true
        fi

        if [ -d /var/lib/pterodactyl/volumes ]; then
            local vol_bytes vol_human
            vol_bytes=$(du -sb /var/lib/pterodactyl/volumes 2>/dev/null | awk '{print $1}')
            vol_human=$(du -sh /var/lib/pterodactyl/volumes 2>/dev/null | awk '{print $1}')
            local skip_volumes=0
            if [ -n "$vol_bytes" ] && [ "$vol_bytes" -gt 10737418240 ]; then
                echo -e "${YELLOW}PERINGATAN: server_volumes berukuran $vol_human (>10GB).${NC}"
                echo -e "Upload ke S3 akan memakan waktu & biaya bandwidth besar."
                confirm_action "Lanjut backup server_volumes ($vol_human)?" || skip_volumes=1
            fi
            if [ "$skip_volumes" -eq 0 ]; then
                echo -e "${BLUE}[*] Zip server_volumes ($vol_human)...${NC}"
                _zip_create /var/lib pterodactyl/volumes "$tmp_dir/server_volumes.zip" || true
            fi
        fi

        echo "PANEL_DOMAIN=${PANEL_DOMAIN:-localhost}" > "$tmp_dir/backup.meta"

        local prefix="${S3_PREFIX:+$S3_PREFIX/}"
        local failed=0
        local uploaded=0

        for f in panel_db.sql panel_files.zip wings_config.zip server_volumes.zip backup.meta; do
            if [ -f "$tmp_dir/$f" ]; then
                if [ ! -s "$tmp_dir/$f" ]; then
                    qprint "${RED}PERINGATAN: $f kosong, skip upload.${NC}"
                    log_msg "S3 backup skip empty: $f"
                    continue
                fi
                echo -n "  Upload $f ... "
                if _s3_upload_file "$tmp_dir/$f" "${prefix}${backup_name}/$f"; then
                    echo -e "${GREEN}OK${NC}"
                    uploaded=$((uploaded + 1))
                else
                    echo -e "${RED}FAIL${NC}"
                    failed=$((failed + 1))
                fi
            fi
        done

        local total_size
        total_size=$(du -sh "$tmp_dir" 2>/dev/null | awk '{print $1}')
        rm -rf "$tmp_dir"

        end_ts=$(date +%s)
        duration=$((end_ts - start_ts))

        if [ "$failed" -eq 0 ]; then
            log_msg "S3 backup sukses: $backup_name ($total_size, ${duration}s, ${uploaded} file)"
            notify_detail "S3 BACKUP" "Backup ke S3 selesai: $backup_name ($total_size, ${duration}s)"
            echo -e "${GREEN}Backup S3 selesai: $backup_name ($total_size, ${duration}s)${NC}"
        else
            log_msg "S3 backup partial: $backup_name (${uploaded} uploaded, ${duration}s)"
            notify_detail "S3 BACKUP WARN" "Backup S3 selesai dengan error: $backup_name"
            echo -e "${YELLOW}Backup S3 selesai tapi ada file gagal upload.${NC}"
        fi
    else
        rm -rf "$tmp_dir"
        fail "Backup database gagal."
    fi
    pause
}

function _s3_exec_cmd() {
    source "$S3_CONFIG"
    local ep=$(echo "$S3_ENDPOINT" | sed 's|/$||')
    local ep_host=$(echo "$ep" | sed 's|https\?://||')
    local host_bucket="%(bucket)s.$ep_host"
    local tmpcfg=$(mktemp /tmp/ptero-s3cfg-XXXXXX)
    cat > "$tmpcfg" <<S3CFG
[default]
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY
host_base = $ep_host
host_bucket = $host_bucket
bucket_location = ${S3_REGION:-us-east-1}
use_https = True
check_ssl_certificate = False
check_ssl_hostname = False
S3CFG
    s3cmd -c "$tmpcfg" "$@"
    local rc=$?
    rm -f "$tmpcfg"
    return $rc
}

function s3_list_backups() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu (menu 64)."
        pause
        return 1
    fi
    source "$S3_CONFIG"
    local prefix="${S3_PREFIX:+$S3_PREFIX/}"
    echo -e "${BLUE}Daftar backup di S3: $S3_ENDPOINT/$S3_BUCKET${NC}"
    echo
    local output
    output=$(_s3_exec_cmd ls "s3://$S3_BUCKET/$prefix" 2>&1)
    if echo "$output" | grep -q "No such bucket\|ERROR\|Error"; then
        echo -e "${RED}Gagal:${NC}"
        echo "$output" | sed 's/^/  /'
    elif [ -z "$output" ]; then
        echo -e "${YELLOW}Tidak ada backup di S3.${NC}"
    else
        echo "$output" | sed 's/^/  /'
    fi
    pause
}

function s3_delete_backup() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu."
        pause; return 1
    fi
    source "$S3_CONFIG"
    local prefix="${S3_PREFIX:+$S3_PREFIX/}"

    echo -e "${BLUE}Mengambil daftar backup dari S3...${NC}"
    local lines
    lines=$(_s3_exec_cmd ls "s3://$S3_BUCKET/$prefix" 2>&1 | grep -oP 'ptero_s3_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | sort -u)
    if [ -z "$lines" ]; then
        fail "Tidak ada backup S3 ditemukan."
        pause; return 1
    fi
    mapfile -t backups <<< "$lines"
    local pick
    pick=$(pick_from_list "Pilih backup yang akan dihapus:" "${backups[@]}") || {
        echo "Dibatalkan."; pause; return 0
    }

    confirm_action "Hapus permanen backup S3: $pick ?" || { echo "Batal."; pause; return 0; }

    echo -e "${BLUE}[*] Hapus semua file $pick dari S3...${NC}"
    local failed=0
    for f in panel_db.sql panel_files.zip wings_config.zip server_volumes.zip backup.meta; do
        if _s3_exec_cmd del "s3://$S3_BUCKET/$prefix$pick/$f" >/dev/null 2>&1; then
            echo -e "  ${GREEN}[hapus]${NC} $f"
        else
            echo -e "  ${YELLOW}[skip]${NC}  $f (tidak ada / sudah terhapus)"
        fi
    done
    log_msg "S3 backup dihapus: $pick"
    echo -e "${GREEN}Selesai.${NC}"
    pause
}

function s3_prune_old_backups() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu."
        pause; return 1
    fi
    source "$S3_CONFIG"
    local prefix="${S3_PREFIX:+$S3_PREFIX/}"

    echo -e "${BLUE}Prune S3 backups (max $BACKUP_MAX_COUNT backup, retention $BACKUP_RETENTION_DAYS hari)${NC}"

    local lines
    lines=$(_s3_exec_cmd ls "s3://$S3_BUCKET/$prefix" 2>&1 | grep -oP 'ptero_s3_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | sort -u)
    if [ -z "$lines" ]; then
        echo -e "${YELLOW}Tidak ada backup S3.${NC}"
        pause; return 0
    fi
    mapfile -t backups <<< "$lines"
    local count=${#backups[@]}
    echo -e "  Total di S3: ${CYAN}$count${NC}"
    echo

    if [ "$count" -le "$BACKUP_MAX_COUNT" ]; then
        echo -e "${GREEN}Tidak ada backup yang melanggar retention.${NC}"
        pause; return 0
    fi

    local excess=$((count - BACKUP_MAX_COUNT))
    echo -e "${YELLOW}Akan hapus $excess backup tertua dari S3.${NC}"
    local to_delete=("${backups[@]:0:$excess}")
    printf '  - %s\n' "${to_delete[@]}"
    echo
    confirm_action "Lanjut hapus $excess backup S3 di atas?" || { echo "Batal."; pause; return 0; }

    local removed=0
    for b in "${to_delete[@]}"; do
        if _s3_exec_cmd del --recursive "s3://$S3_BUCKET/$prefix$b/" >/dev/null 2>&1; then
            echo -e "  ${GREEN}[hapus]${NC} $b"
            removed=$((removed + 1))
        else
            echo -e "  ${RED}[gagal]${NC} $b"
        fi
    done
    log_msg "S3 prune: $removed/$excess dihapus"
    echo
    echo -e "${GREEN}$removed backup S3 dihapus.${NC}"
    pause
}

function s3_verify_backup() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu."
        pause; return 1
    fi
    source "$S3_CONFIG"
    local prefix="${S3_PREFIX:+$S3_PREFIX/}"

    echo -e "${BLUE}[*] Mengambil daftar backup dari S3...${NC}"
    local lines
    lines=$(_s3_exec_cmd ls "s3://$S3_BUCKET/$prefix" 2>&1 | grep -oP 'ptero_s3_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | sort -u)
    if [ -z "$lines" ]; then
        fail "Tidak ada backup S3 ditemukan."; pause; return 1
    fi
    mapfile -t backups <<< "$lines"
    local pick
    pick=$(pick_from_list "Pilih backup untuk verify:" "${backups[@]}") || { pause; return 0; }

    echo -e "${BLUE}[*] Verify backup S3: $pick${NC}"
    echo -e "  Endpoint: $S3_ENDPOINT/$S3_BUCKET"
    echo

    local fail_count=0
    local total_size=0
    for f in panel_db.sql panel_files.zip wings_config.zip server_volumes.zip backup.meta; do
        local remote_path="$prefix$pick/$f"
        echo -n "  $f ... "
        local ls_out
        ls_out=$(_s3_exec_cmd ls -l "s3://$S3_BUCKET/$remote_path" 2>&1)
        if echo "$ls_out" | grep -q "NoSuchKey\|ERROR\|404"; then
            echo -e "${YELLOW}skip (tidak ada di S3)${NC}"
            continue
        fi
        local remote_size
        remote_size=$(echo "$ls_out" | head -1 | awk '{print $3}')
        if [ -z "$remote_size" ] || ! [[ "$remote_size" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW}skip (tidak bisa baca size)${NC}"
            continue
        fi
        local tmpf="/tmp/s3-verify-$$-$f"
        if _s3_exec_cmd get "s3://$S3_BUCKET/$remote_path" "$tmpf" >/dev/null 2>&1; then
            local local_size
            local_size=$(stat -c %s "$tmpf" 2>/dev/null || echo 0)
            if [ "$local_size" -eq "$remote_size" ]; then
                if [[ "$f" == *.zip ]] && ! unzip -tq "$tmpf" >/dev/null 2>&1; then
                    echo -e "${RED}SIZE OK tapi ZIP CORRUPT ($local_size bytes)${NC}"
                    fail_count=$((fail_count+1))
                else
                    echo -e "${GREEN}OK ($local_size bytes)${NC}"
                    total_size=$((total_size + local_size))
                fi
            else
                echo -e "${RED}SIZE MISMATCH (remote=$remote_size, local=$local_size)${NC}"
                fail_count=$((fail_count+1))
            fi
        else
            echo -e "${RED}DOWNLOAD FAILED${NC}"
            fail_count=$((fail_count+1))
        fi
        rm -f "$tmpf"
    done

    echo
    if [ "$fail_count" -eq 0 ]; then
        local total_human=$(numfmt --to=iec "$total_size" 2>/dev/null || echo "${total_size} bytes")
        echo -e "${GREEN}✓ Backup S3 SEHAT — total $total_human${NC}"
        log_msg "S3 verify OK: $pick ($total_size bytes)"
    else
        echo -e "${RED}✗ Backup S3 BERMASALAH — $fail_count file gagal${NC}"
        log_msg "S3 verify FAIL: $pick ($fail_count files)"
        notify_detail "S3 VERIFY FAIL" "Backup S3 $pick bermasalah ($fail_count file gagal)."
    fi
    pause
}

function s3_restore_backup() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu (menu 64)."
        pause
        return 1
    fi

    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT

    source "$S3_CONFIG"
    local prefix="${S3_PREFIX:+$S3_PREFIX/}"

    echo -e "${BLUE}[*] Mengambil daftar backup dari S3...${NC}"
    echo
    local lines
    lines=$(_s3_exec_cmd ls "s3://$S3_BUCKET/$prefix" 2>&1 | grep -oP 'ptero_s3_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | sort -u)
    if [ -z "$lines" ]; then
        fail "Tidak ada backup S3 ditemukan."
        pause
        return 1
    fi

    mapfile -t backups <<< "$lines"
    local pick
    pick=$(pick_from_list "Pilih backup:" "${backups[@]}") || {
        echo "Dibatalkan."; pause; return 0
    }

    local tmp_dir="/tmp/s3-restore-$pick"
    mkdir -p "$tmp_dir"

    echo -e "${BLUE}[*] Download backup $pick dari S3...${NC}"
    local failed=0
    for f in panel_db.sql panel_files.zip wings_config.zip server_volumes.zip backup.meta; do
        echo -n "  Download $f ... "
        if _s3_exec_cmd get "s3://$S3_BUCKET/$prefix$pick/$f" "$tmp_dir/$f" >/dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}skip (tidak ada)${NC}"
        fi
    done

    if [ ! -f "$tmp_dir/panel_db.sql" ]; then
        rm -rf "$tmp_dir"
        fail "panel_db.sql tidak ada. Backup S3 mungkin korup."
        pause
        return 1
    fi

    # Restore system expect folder wings_config/, tapi S3 backup simpan sbg zip
    # Ekstrak zip → folder supaya mode 1 (lengkap) & mode 4 (wings) bisa kerja
    if [ -f "$tmp_dir/wings_config.zip" ] && [ ! -d "$tmp_dir/wings_config" ]; then
        if ! unzip -oq "$tmp_dir/wings_config.zip" -d "$tmp_dir"; then
            echo -e "${YELLOW}Gagal extract wings_config.zip. Mode wings akan dilewati.${NC}"
        fi
    fi

    # backup.meta dari S3 sudah ada; fallback kalau tidak ada di S3
    if [ ! -f "$tmp_dir/backup.meta" ]; then
        echo "PANEL_DOMAIN=${PANEL_DOMAIN:-localhost}" > "$tmp_dir/backup.meta"
    fi

    echo
    echo -e "${GREEN}Download selesai. Memulai restore...${NC}"
    sleep 1

    restore_system "$tmp_dir"

    rm -rf "$tmp_dir"
}
