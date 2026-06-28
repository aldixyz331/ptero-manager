#!/bin/bash

function verify_backup() {
    require_root || return 1
    header
    echo -e "${BLUE}Verify Backup Integrity${NC}"
    echo -e "${YELLOW}Cek apakah arsip backup masih utuh & bisa dibaca (deteksi korup sebelum kepepet restore).${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        fail "Folder backup belum ada: $BACKUP_ROOT"; pause; return 1
    fi
    mapfile -t BACKUPS < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        fail "Tidak ada backup tersedia."; pause; return 1
    fi

    echo "1) Verifikasi 1 backup (pilih)"
    echo "2) Verifikasi SEMUA backup (lebih lama)"
    echo "0) Batal"
    read -r -p "Pilih [0-2]: " VOPT
    local targets=()
    case "$VOPT" in
        1)
            local pick
            pick=$(pick_from_list "Pilih backup:" "${BACKUPS[@]}") || {
                fail "Pilihan tidak valid."; pause; return 1
            }
            targets=("$pick")
            ;;
        2) targets=("${BACKUPS[@]}") ;;
        *) echo "Dibatalkan."; pause; return 0 ;;
    esac

    local total=${#targets[@]} ok=0 bad=0 i=0
    for b in "${targets[@]}"; do
        i=$((i+1))
        echo
        echo -e "${CYAN}[$i/$total] $(basename "$b")${NC}"
        local b_ok=1

        local f
        for f in panel_files.zip server_volumes.zip wings_config.zip; do
            if [ -f "$b/$f" ]; then
                if unzip -tq "$b/$f" >/dev/null 2>&1; then
                    echo -e "  ${GREEN}[OK]${NC}    $f ($(du -sh "$b/$f" 2>/dev/null | awk '{print $1}'))"
                else
                    echo -e "  ${RED}[KORUP]${NC} $f"
                    b_ok=0
                fi
            fi
        done

        if [ -f "$b/panel_db.sql" ]; then
            if [ ! -s "$b/panel_db.sql" ]; then
                echo -e "  ${RED}[KORUP]${NC} panel_db.sql kosong"
                b_ok=0
            elif ! head -c 4096 "$b/panel_db.sql" | grep -qiE 'mysql dump|mariadb dump|^-- |create table|insert into'; then
                echo -e "  ${YELLOW}[WARN]${NC} panel_db.sql tidak terlihat seperti SQL dump valid"
                b_ok=0
            else
                echo -e "  ${GREEN}[OK]${NC}    panel_db.sql ($(du -sh "$b/panel_db.sql" 2>/dev/null | awk '{print $1}'))"
            fi
        fi

        if [ -d "$b/wings_config" ]; then
            if [ -f "$b/wings_config/config.yml" ] && grep -q '^token:' "$b/wings_config/config.yml" 2>/dev/null; then
                echo -e "  ${GREEN}[OK]${NC}    wings_config/config.yml"
            else
                echo -e "  ${YELLOW}[WARN]${NC} wings_config tanpa config.yml valid"
            fi
        fi

        if [ "$b_ok" -eq 1 ]; then
            ok=$((ok+1))
            echo -e "  ${GREEN}=> SEHAT${NC}"
        else
            bad=$((bad+1))
            echo -e "  ${RED}=> BERMASALAH${NC}"
        fi
    done

    echo
    echo -e "${BLUE}Ringkasan: ${GREEN}$ok sehat${NC}, ${RED}$bad bermasalah${NC} (dari $total).${NC}"
    log_msg "Verify backup: $ok OK / $bad bad / $total total"
    if [ "$bad" -gt 0 ]; then
        notify_detail "BACKUP CORRUPT" "$bad backup terdeteksi korup. Cek menu Verify Backup."
    fi
    pause
}

function container_resource_stats() {
    require_root || return 1
    header
    echo -e "${BLUE}Resource Pakai per Container Pterodactyl${NC}"
    echo
    if ! command -v docker >/dev/null 2>&1; then
        fail "Docker belum terpasang."; pause; return 1
    fi
    local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    mapfile -t containers < <(docker ps --format '{{.Names}}' 2>/dev/null \
                              | awk -v re="$uuid_re" '$0 ~ re')
    if [ "${#containers[@]}" -eq 0 ]; then
        echo -e "${YELLOW}Tidak ada container Pterodactyl yang sedang berjalan.${NC}"
        pause; return 0
    fi

    echo -e "${CYAN}== docker stats (snapshot) ==${NC}"
    docker stats --no-stream \
        --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' \
        "${containers[@]}" 2>/dev/null

    echo
    echo -e "${CYAN}== Disk per server volume ==${NC}"
    local vol_root="/var/lib/pterodactyl/volumes"
    if [ -d "$vol_root" ]; then
        printf "  %-40s %10s\n" "UUID" "SIZE"
        local c size
        for c in "${containers[@]}"; do
            if [ -d "$vol_root/$c" ]; then
                size=$(du -sh "$vol_root/$c" 2>/dev/null | awk '{print $1}')
                printf "  %-40s %10s\n" "$c" "${size:-?}"
            fi
        done
    else
        echo -e "  ${YELLOW}Folder volume tidak ditemukan: $vol_root${NC}"
    fi

    echo
    echo -e "${CYAN}== Top 5 CPU ==${NC}"
    docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' "${containers[@]}" 2>/dev/null \
        | sort -k2 -hr | head -5 | sed 's/^/  /'

    echo
    echo -e "${CYAN}== Top 5 Memori ==${NC}"
    docker stats --no-stream --format '{{.Name}} {{.MemPerc}}' "${containers[@]}" 2>/dev/null \
        | sort -k2 -hr | head -5 | sed 's/^/  /'

    log_msg "Container resource stats dijalankan (${#containers[@]} container)"
    pause
}

function clear_panel_cache() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${BLUE}Clear Panel Cache${NC}"
    echo -e "${YELLOW}Bersihkan cache Laravel, view, config, route, OPcache, lalu re-cache untuk produksi.${NC}"
    echo
    cd "$PANEL_DIR" || { fail "Folder panel tidak ditemukan."; pause; return 1; }

    local steps_ok=0 steps_fail=0
    _do() {
        local label="$1"; shift
        if "$@" >/dev/null 2>&1; then
            echo -e "  ${GREEN}[OK]${NC}    $label"
            steps_ok=$((steps_ok+1))
        else
            echo -e "  ${YELLOW}[SKIP]${NC}  $label"
            steps_fail=$((steps_fail+1))
        fi
    }

    _panel_clear_artisan_cache "$PANEL_DIR" "1"
    local artisan_ok=$?
    steps_ok=$((steps_ok + artisan_ok))

    _do "event:clear"  php artisan event:clear

    _do "config:cache" php artisan config:cache
    _do "route:cache"  php artisan route:cache

    _panel_opcache_reset

    chown -R www-data:www-data "$PANEL_DIR/bootstrap/cache" "$PANEL_DIR/storage" 2>/dev/null || true

    echo
    echo -e "${BLUE}Selesai: ${GREEN}${steps_ok} OK${NC}, ${YELLOW}${steps_fail} dilewati${NC}.${NC}"
    log_msg "Clear panel cache ($steps_ok OK / $steps_fail skip)"
    pause
}

function auto_fix_panel() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${BLUE}Auto-Fix Panel (panel doctor)${NC}"
    echo -e "${YELLOW}Perbaiki ownership, permission, cache, restart service, lalu uji koneksi.${NC}"
    echo
    local fixed=0

    echo -e "${CYAN}== 1. Ownership & permission ==${NC}"
    if chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} chown www-data $PANEL_DIR"
        fixed=$((fixed+1))
    fi
    if chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} chmod 755 storage & bootstrap/cache"
        fixed=$((fixed+1))
    fi
    if [ -f "$PANEL_DIR/.env" ]; then
        chmod 640 "$PANEL_DIR/.env" 2>/dev/null && \
            echo -e "  ${GREEN}[OK]${NC} chmod 640 .env" && fixed=$((fixed+1))
        chown root:www-data "$PANEL_DIR/.env" 2>/dev/null && \
            echo -e "  ${GREEN}[OK]${NC} chown root:www-data .env" && fixed=$((fixed+1))
    fi

    echo
    echo -e "${CYAN}== 2. Clear cache ==${NC}"
    cd "$PANEL_DIR" || { fail "Folder panel hilang."; pause; return 1; }
    _panel_clear_artisan_cache "$PANEL_DIR" "0"
    fixed=$((fixed + $?))
    _panel_opcache_reset

    echo
    echo -e "${CYAN}== 3. Validasi konfigurasi Nginx ==${NC}"
    if nginx -t >/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} nginx -t valid"
    else
        echo -e "  ${RED}[FAIL]${NC} nginx -t invalid:"
        nginx -t 2>&1 | sed 's/^/    /'
    fi

    echo
    echo -e "${CYAN}== 4. Restart service ==${NC}"
    local svc
    for svc in redis-server "php${PHP_VERSION}-fpm" nginx pteroq; do
        if systemctl restart "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC} restart $svc"
            fixed=$((fixed+1))
        else
            echo -e "  ${YELLOW}[SKIP]${NC} $svc (tidak ada / gagal)"
        fi
    done

    echo
    echo -e "${CYAN}== 5. Uji koneksi panel ==${NC}"
    local app_url code
    app_url=$(grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    if [ -n "$app_url" ]; then
        code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "$app_url" 2>/dev/null || echo "000")
        if echo "$code" | grep -Eq '^(200|301|302)$'; then
            echo -e "  ${GREEN}[OK]${NC} $app_url -> HTTP $code"
        else
            echo -e "  ${RED}[FAIL]${NC} $app_url -> HTTP $code"
            echo -e "  ${YELLOW}Cek tunnel/DNS atau lihat log: journalctl -u nginx -n 30${NC}"
        fi
    else
        echo -e "  ${YELLOW}[SKIP]${NC} APP_URL belum diset di .env"
    fi

    echo
    echo -e "${CYAN}== 6. Status service ==${NC}"
    for svc in nginx "php${PHP_VERSION}-fpm" mariadb redis-server pteroq wings; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}[OK]${NC}    $svc"
        else
            echo -e "  ${YELLOW}[STOP]${NC}  $svc"
        fi
    done

    echo
    echo -e "${GREEN}Auto-fix selesai. Total $fixed langkah perbaikan dijalankan.${NC}"
    log_msg "Auto-fix panel dijalankan ($fixed langkah)"
    notify_detail "PANEL FIX" "Auto-fix panel dijalankan ($fixed langkah)."
    pause
}

function cleanup_orphan_backups() {
    require_root || return 1
    header
    echo -e "${BLUE}Cleanup Orphan / Partial Backups${NC}"
    echo -e "${YELLOW}Cari folder backup yang gagal di tengah jalan (tidak lengkap atau terlalu kecil).${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."; pause; return 0
    fi

    mapfile -t BACKUPS < <(ls -1d "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        echo "Tidak ada backup tersedia."; pause; return 0
    fi

    local orphans=() reasons=()
    local b size_kb has_db has_files
    for b in "${BACKUPS[@]}"; do
        [ -d "$b" ] || continue
        size_kb=$(du -sk "$b" 2>/dev/null | awk '{print $1}')
        size_kb=${size_kb:-0}
        has_db=0; has_files=0
        [ -s "$b/panel_db.sql" ]         && has_db=1
        [ -s "$b/panel_files.zip" ]     && has_files=1

        if [ "$has_db" -eq 0 ] && [ "$has_files" -eq 0 ]; then
            orphans+=("$b")
            reasons+=("kosong: tidak ada panel_db.sql & panel_files.zip")
        elif [ "$size_kb" -lt 1024 ]; then
            orphans+=("$b")
            reasons+=("terlalu kecil (${size_kb} KB) — kemungkinan backup gagal di tengah")
        fi
    done

    if [ "${#orphans[@]}" -eq 0 ]; then
        echo -e "${GREEN}Tidak ada backup orphan/partial. Semua backup terlihat lengkap.${NC}"
        pause; return 0
    fi

    echo -e "${YELLOW}Ditemukan ${#orphans[@]} backup mencurigakan:${NC}"
    echo
    local i
    for i in "${!orphans[@]}"; do
        printf "  %2d) %s\n      ${RED}%s${NC}\n" \
            "$((i+1))" "$(basename "${orphans[$i]}")" "${reasons[$i]}"
    done
    echo
    local total_kb=0
    for b in "${orphans[@]}"; do
        size_kb=$(du -sk "$b" 2>/dev/null | awk '{print $1}')
        total_kb=$((total_kb + ${size_kb:-0}))
    done
    local total_mb=$((total_kb / 1024))
    echo -e "${CYAN}Total disk yang akan dibebaskan: ~${total_mb} MB${NC}"
    echo

    if ! confirm_action "Hapus semua ${#orphans[@]} folder backup mencurigakan di atas?"; then
        echo "Dibatalkan."; pause; return 0
    fi

    local removed=0
    for b in "${orphans[@]}"; do
        if rm -rf -- "$b" 2>/dev/null; then
            removed=$((removed+1))
            echo -e "  ${GREEN}[hapus]${NC} $(basename "$b")"
        else
            echo -e "  ${RED}[gagal]${NC} $(basename "$b")"
        fi
    done
    log_msg "Cleanup orphan backup: $removed/${#orphans[@]} dihapus (~${total_mb} MB)"
    echo
    echo -e "${GREEN}$removed folder dihapus, ~${total_mb} MB dibebaskan.${NC}"
    pause
}

function drop_reset_database() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${RED}===== DROP & RESET DATABASE PANEL =====${NC}"
    echo -e "${YELLOW}Operasi ini akan MENGHAPUS database panel '$DB_NAME' dan membuatnya ulang KOSONG.${NC}"
    echo -e "${YELLOW}Semua user, server, node, lokasi, schedule, dll. akan HILANG.${NC}"
    echo -e "${YELLOW}Tapi server runtime di Wings (volumes) tidak ikut terhapus.${NC}"
    echo
    echo -e "${CYAN}Database target : ${RED}$DB_NAME${NC}"
    echo -e "${CYAN}DB user         : $DB_USER${NC}"
    echo

    read -r -p "Untuk konfirmasi, ketik nama database persis ('$DB_NAME'): " TYPED
    if [ "$TYPED" != "$DB_NAME" ]; then
        fail "Nama database tidak cocok. Dibatalkan."; pause; return 1
    fi
    confirm_action "BENERAN drop database '$DB_NAME' & reset semua data panel?" \
        || { echo "Dibatalkan."; pause; return 0; }

    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT

    echo
    echo -e "${BLUE}[*] Backup DB dulu sebelum drop (safety net)...${NC}"
    read -r -s -p "Password database $DB_USER (untuk backup): " DBP
    echo
    if [ -z "$DBP" ]; then
        fail "Password kosong. Drop dibatalkan."
        release_lock; trap - EXIT; return 1
    fi
    mkdir -p "$BACKUP_ROOT"
    local safety_dir="$BACKUP_ROOT/ptero_PRE_DROP_$(date +%F_%H-%M-%S)"
    mkdir -p "$safety_dir"
    if ! mysqldump_secure "$DB_USER" "$DBP" -h 127.0.0.1 \
            --single-transaction --routines --triggers \
            "$DB_NAME" > "$safety_dir/panel_db.sql" 2>/dev/null; then
        rm -rf "$safety_dir"
        fail "Backup pra-drop GAGAL (password salah?). Drop dibatalkan demi keamanan."
        release_lock; trap - EXIT; return 1
    fi
    if [ ! -s "$safety_dir/panel_db.sql" ]; then
        rm -rf "$safety_dir"
        fail "Backup pra-drop kosong. Drop dibatalkan demi keamanan."
        release_lock; trap - EXIT; return 1
    fi
    echo -e "  ${GREEN}[OK]${NC} Backup pra-drop: $safety_dir"

    echo
    cd "$PANEL_DIR" 2>/dev/null && \
        php artisan down --message="Database sedang di-reset." >/dev/null 2>&1 || true

    echo -e "${BLUE}[*] Drop & recreate database...${NC}"
    ask_mysql_root_password
    if ! mysql_root -e "
        DROP DATABASE IF EXISTS \`$DB_NAME\`;
        CREATE DATABASE \`$DB_NAME\`
            CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
        FLUSH PRIVILEGES;
    "; then
        fail "DROP/CREATE database gagal. Coba restore dari: $safety_dir/panel_db.sql"
        ( cd "$PANEL_DIR" && php artisan up >/dev/null 2>&1 ) || true
        release_lock; trap - EXIT; return 1
    fi
    echo -e "  ${GREEN}[OK]${NC} Database '$DB_NAME' di-recreate kosong."

    echo
    echo -e "${BLUE}[*] Migrate fresh + seed...${NC}"
    cd "$PANEL_DIR" || { fail "Folder panel hilang."; release_lock; trap - EXIT; return 1; }
    if ! php artisan migrate --seed --force; then
        fail "Migrasi gagal. DB sudah kosong. Restore dari: $safety_dir/panel_db.sql"
        php artisan up >/dev/null 2>&1 || true
        release_lock; trap - EXIT; return 1
    fi

    php artisan config:clear >/dev/null 2>&1 || true
    php artisan cache:clear  >/dev/null 2>&1 || true
    php artisan queue:restart >/dev/null 2>&1 || true
    php artisan up >/dev/null 2>&1 || true

    echo
    echo -e "${GREEN}Database panel berhasil di-reset.${NC}"
    echo -e "${YELLOW}Backup pra-drop tersimpan di: $safety_dir${NC}"
    echo -e "${YELLOW}Buat ulang akun admin via menu 22 (Buat User/Admin Panel).${NC}"
    log_msg "Database $DB_NAME di-drop & reset (backup: $safety_dir)"
    notify_detail "DB RESET" "Database panel direset. Backup: $safety_dir"
    release_lock
    trap - EXIT
    pause
}

function flush_redis_cache() {
    require_root || return 1
    if ! command -v redis-cli >/dev/null 2>&1; then
        fail "redis-cli tidak ditemukan."; pause; return 1
    fi
    if ! redis-cli ping 2>/dev/null | grep -q PONG; then
        fail "Redis tidak merespon (service mati / port lain?)."; pause; return 1
    fi

    header
    echo -e "${BLUE}Flush Redis Cache${NC}"
    echo -e "${YELLOW}Bersihkan session, queue, dan cache panel di Redis.${NC}"
    echo -e "${YELLOW}Efek: semua user akan ke-logout, queue job pending HILANG.${NC}"
    echo
    echo -e "${CYAN}Info Redis:${NC}"
    local used keys_total
    used=$(redis-cli info memory 2>/dev/null | awk -F: '/^used_memory_human/ {gsub(/\r/,"",$2); print $2}')
    keys_total=$(redis-cli info keyspace 2>/dev/null | awk -F'[=,]' '/^db/ {sum+=$2} END{print sum+0}')
    echo -e "  Memori : ${used:-?}"
    echo -e "  Keys   : ${keys_total:-0}"
    redis-cli info keyspace 2>/dev/null | grep '^db' | sed 's/^/  /'
    echo

    echo "1) Flush DB 0 saja (paling aman, biasanya cukup)"
    echo "2) FLUSHALL — hapus SEMUA database Redis (lebih agresif)"
    echo "0) Batal"
    read -r -p "Pilih [0-2]: " FOPT
    case "$FOPT" in
        1)
            confirm_action "Flush Redis DB 0 sekarang?" \
                || { echo "Dibatalkan."; pause; return 0; }
            if redis-cli -n 0 FLUSHDB >/dev/null 2>&1; then
                echo -e "${GREEN}[OK] Redis DB 0 di-flush.${NC}"
                log_msg "Redis FLUSHDB 0 dijalankan"
            else
                fail "FLUSHDB gagal."
            fi
            ;;
        2)
            confirm_action "FLUSHALL — hapus SEMUA database Redis sekarang?" \
                || { echo "Dibatalkan."; pause; return 0; }
            if redis-cli FLUSHALL >/dev/null 2>&1; then
                echo -e "${GREEN}[OK] Semua Redis DB di-flush.${NC}"
                log_msg "Redis FLUSHALL dijalankan"
            else
                fail "FLUSHALL gagal."
            fi
            ;;
        *) echo "Dibatalkan."; pause; return 0 ;;
    esac

    if [ -f "$PANEL_DIR/artisan" ]; then
        ( cd "$PANEL_DIR" && php artisan queue:restart >/dev/null 2>&1 ) || true
    fi
    systemctl restart pteroq 2>/dev/null || true
    echo -e "${YELLOW}Queue worker (pteroq) di-restart. User perlu login ulang.${NC}"
    pause
}

function prune_old_backups_now() {
    require_root || return 1
    header
    echo -e "${BLUE}Prune Old Backups (manual)${NC}"
    echo -e "${YELLOW}Aplikasikan retention sekarang juga, tidak nunggu cron.${NC}"
    echo -e "${CYAN}Retention: $BACKUP_RETENTION_DAYS hari, max $BACKUP_MAX_COUNT backup.${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."; pause; return 0
    fi

    mapfile -t old_by_age < <(find "$BACKUP_ROOT" -maxdepth 1 -type d \
        -name 'ptero_*' -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null)

    mapfile -t all_sorted < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    local old_by_count=()
    if [ "${#all_sorted[@]}" -gt "$BACKUP_MAX_COUNT" ]; then
        local idx
        for idx in "${!all_sorted[@]}"; do
            if [ "$idx" -ge "$BACKUP_MAX_COUNT" ]; then
                old_by_count+=("${all_sorted[$idx]}")
            fi
        done
    fi

    declare -A seen=()
    local victims=() v
    for v in "${old_by_age[@]}" "${old_by_count[@]}"; do
        [ -z "$v" ] && continue
        if [ -z "${seen[$v]:-}" ]; then
            seen[$v]=1
            victims+=("$v")
        fi
    done

    if [ "${#victims[@]}" -eq 0 ]; then
        echo -e "${GREEN}Tidak ada backup yang melanggar retention. Tidak ada yang dihapus.${NC}"
        echo -e "  Total backup saat ini: ${#all_sorted[@]} (limit: $BACKUP_MAX_COUNT)"
        pause; return 0
    fi

    echo -e "${YELLOW}Backup yang akan DIHAPUS (${#victims[@]} folder):${NC}"
    local total_kb=0 size_kb age
    for v in "${victims[@]}"; do
        size_kb=$(du -sk "$v" 2>/dev/null | awk '{print $1}')
        size_kb=${size_kb:-0}
        total_kb=$((total_kb + size_kb))
        age=$(stat -c %y "$v" 2>/dev/null | cut -d. -f1)
        printf "  - %-40s  %6s MB  (%s)\n" "$(basename "$v")" \
            "$((size_kb/1024))" "${age:-?}"
    done
    local total_mb=$((total_kb / 1024))
    echo
    echo -e "${CYAN}Total disk yang akan dibebaskan: ~${total_mb} MB${NC}"
    echo

    if ! confirm_action "Hapus ${#victims[@]} backup di atas sekarang?"; then
        echo "Dibatalkan."; pause; return 0
    fi

    local removed=0
    for v in "${victims[@]}"; do
        if rm -rf -- "$v" 2>/dev/null; then
            removed=$((removed+1))
            echo -e "  ${GREEN}[hapus]${NC} $(basename "$v")"
        else
            echo -e "  ${RED}[gagal]${NC} $(basename "$v")"
        fi
    done
    echo
    echo -e "${GREEN}$removed/${#victims[@]} backup dihapus, ~${total_mb} MB dibebaskan.${NC}"
    log_msg "Prune backup manual: $removed dihapus (~${total_mb} MB)"
    pause
}
