#!/bin/bash

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
for module in config helpers install update backup cloudflare monitoring management optimize repair features extras uninstall remote-node eggs migration wings config-manual-wings config-auto-wings addons; do
    if [ -f "$MODULES_DIR/$module.sh" ]; then
        source "$MODULES_DIR/$module.sh"
    else
        echo "ERROR: Module $module.sh not found in $MODULES_DIR"
        exit 1
    fi
done

# ====================================================
# MAIN MENU
# ====================================================

# ====================================================
# MAIN MENU
# ====================================================

function menu_install_update() {
    while true; do
        header
        print_section "INSTALL & UPDATE"
        echo "  1) Full Install Panel + Wings"
        echo "  2) Update Panel"
        echo "  3) Update Wings"
        echo "  4) Provision Web & Services"
        echo "  5) Deep Maintenance"
        echo "  6) Cek Update Script"
        print_footer
        read -r -p "Pilih [0-6]: " opt
        case $opt in
            1) install_pterodactyl ;;
            2) update_panel ;;
            3) update_wings_only ;;
            4) if provision_services; then
                   if nginx -t >/dev/null 2>&1; then
                       systemctl restart nginx wings pteroq 2>/dev/null || true
                   else
                       fail "Nginx config invalid. Skip restart nginx."
                       systemctl restart wings pteroq 2>/dev/null || true
                   fi
               fi
               pause ;;
            5) deep_maintenance ;;
            6) check_script_update ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_cloudflare() {
    while true; do
        header
        print_section "CLOUDFLARE"
        echo "  1) Setup Cloudflare Connector Token"
        echo "  2) Setup Cloudflare Named Tunnel"
        echo "  3) Set Domain Panel Cloudflare"
        echo "  4) Generate Wings config.yml dari API"
        print_footer
        read -r -p "Pilih [0-4]: " opt
        case $opt in
            1) setup_cloudflare_tunnel ;;
            2) setup_cloudflare_named_tunnel ;;
            3) set_panel_domain ;;
            4) generate_wings_config_api ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_backup() {
    while true; do
        header
        print_section "BACKUP & RESTORE"
        echo "  1) Backup System Lengkap"
        echo "  2) Backup Database Saja"
        echo "  3) Restore dari Backup"
        echo "  4) List Backup"
        echo "  5) Hapus Backup"
        echo "  6) Backup Otomatis Terjadwal"
        echo "  7) Setup S3 Destination"
        echo "  8) Backup & Upload ke S3"
        echo "  9) Restore dari S3"
        echo " 10) List S3 Backups"
        echo " 11) Hapus S3 Backup"
        echo " 12) Prune S3 Backups (retensi)"
        echo " 13) Verify S3 Backup Integrity"
        echo " 14) Verify Backup Integrity (lokal)"
        echo " 15) Cleanup Orphan Backups"
        echo " 16) Prune Old Backups"
        echo " 17) Backup Statistics"
        echo " 18) Set Backup Options"
        echo " 19) Fix Backup Domain"
        print_footer
        read -r -p "Pilih [0-19]: " opt
        case $opt in
            1) backup_system ;;
            2) backup_db_only ;;
            3) restore_system ;;
            4) list_backups ;;
            5) delete_backup ;;
            6) schedule_auto_backup ;;
            7) backup_s3_setup ;;
            8) backup_to_s3 ;;
            9) s3_restore_backup ;;
            10) s3_list_backups ;;
            11) s3_delete_backup ;;
            12) s3_prune_old_backups ;;
            13) s3_verify_backup ;;
            14) verify_backup ;;
            15) cleanup_orphan_backups ;;
            16) prune_old_backups_now ;;
            17) backup_stats ;;
            18) set_backup_options ;;
            19) fix_backup_domain ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_monitoring() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}           MONITORING             ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════╝${NC}"
        echo " 1) Health Check Service"
        echo " 2) Informasi Sistem"
        echo " 3) Lihat Log Real-time"
        echo " 4) Cek Koneksi Wings ke Panel"
        echo " 5) Setup Discord Webhook"
        echo " 6) Live Container Stats"
        echo ""
        echo " 0) Kembali"
        echo ""
        read -r -p "Pilih [0-6]: " opt
        case $opt in
            1) health_check ;;
            2) info_system ;;
            3) view_logs_menu ;;
            4) check_wings_connection ;;
            5) discord_setup ;;
            6) container_resource_stats ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_management() {
    while true; do
        header
        print_section "MANAGEMENT"
        echo "  1) Buat User/Admin Panel"
        echo "  2) Reset Password Admin"
        echo "  3) Ganti Password Database"
        echo "  4) Maintenance Mode Panel"
        echo "  5) Export Konfigurasi"
        echo "  6) Manajemen User Panel"
        echo "  7) Bulk Action Server"
        echo "  8) List Admin Users"
        echo "  9) Clear Panel Cache"
        echo " 10) Auto-Fix Panel"
        echo " 11) Flush Redis Cache"
        echo " 12) Set Panel Domain"
        print_footer
        read -r -p "Pilih [0-12]: " opt
        case $opt in
            1) create_admin_user ;;
            2) reset_admin_password ;;
            3) change_db_password ;;
            4) panel_maintenance_mode ;;
            5) export_config ;;
            6) panel_user_manager ;;
            7) bulk_server_action ;;
            8) list_admin_users ;;
            9) clear_panel_cache ;;
            10) auto_fix_panel ;;
            11) flush_redis_cache ;;
            12) set_panel_domain ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_server_security() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}        SERVER & SECURITY         ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════╝${NC}"
        echo " 1) Repair Menu"
        echo " 2) Setup UFW Firewall"
        echo " 3) Setup Rclone Storage"
        echo " 4) Create Swap"
        echo " 5) Optimasi Server"
        echo " 6) Restart Semua Service"
        echo " 7) Security Audit"
        echo " 8) Optimasi Database"
        echo " 9) Setup Wings Watchdog"
        echo "10) Hapus Wings Watchdog"
        echo "11) Pilih Mode Deploy"
        echo "12) Setup HTTPS Let's Encrypt"
        echo "13) Setup Fail2ban"
        echo "14) Status Fail2ban"
        echo "15) Cloudflare Origin Cert"
        echo "16) Setup Telegram Notifikasi"
        echo "17) Set Custom Banner"
        echo ""
        echo " 0) Kembali"
        echo ""
        read -r -p "Pilih [0-17]: " opt
        case $opt in
            1) repair_menu ;;
            2) setup_firewall ;;
            3) setup_rclone_storage ;;
            4) create_swap ;;
            5) optimize_server ;;
            6) restart_all_services ;;
            7) security_audit ;;
            8) db_optimize ;;
            9) wings_watchdog_setup ;;
            10) wings_watchdog_remove ;;
            11) select_deploy_mode ;;
            12) setup_letsencrypt ;;
            13) setup_fail2ban ;;
            14) fail2ban_status ;;
            15) install_cf_origin_cert ;;
            16) telegram_setup ;;
            17) set_custom_banner ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_wings() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}             WINGS                ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════╝${NC}"
        echo " 1) Install Wings Daemon"
        echo " 2) Config Wings Manual"
        echo " 3) Wings Control Center"
        echo " 4) Remote Wings Installer"
        echo " 5) Cek Status Wings Remote"
        echo ""
        echo " 0) Kembali"
        echo ""
        read -r -p "Pilih [0-5]: " opt
        case $opt in
            1) wings_installer ;;
            2) wings_config_manual ;;
            3) wings_control_center ;;
            4) remote_install_wings ;;
            5) remote_wings_status ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_eggs_migration() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}         EGGS & MIGRATION         ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════╝${NC}"
        echo " 1) Egg Manager"
        echo " 2) Server Migration Tool"
        echo ""
        echo " 0) Kembali"
        echo ""
        read -r -p "Pilih [0-2]: " opt
        case $opt in
            1) egg_list_available ;;
            2) migrate_server ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_security_updates() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}        SECURITY UPDATES          ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════╝${NC}"
        echo " 1) Cek Update Keamanan"
        echo " 2) Setup Auto Security Updates"
        echo ""
        echo " 0) Kembali"
        echo ""
        read -r -p "Pilih [0-2]: " opt
        case $opt in
            1) check_updates_manual ;;
            2) setup_auto_updates ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_tools_help() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}          TOOLS & HELP            ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════╝${NC}"
        echo " 1) Bantuan / Help Screen"
        echo " 2) Script Rollback (.bak)"
        echo " 3) Addon Manager (install/lihat addon)"
        echo ""
        echo " 0) Kembali"
        echo ""
        read -r -p "Pilih [0-3]: " opt
        case $opt in
            1) help_screen ;;
            2) script_rollback ;;
            3) addon_manager ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

function menu_danger() {
    while true; do
        clear
        echo -e "${RED}╔══════════════════════════════════╗${NC}"
        echo -e "${RED}║${NC}          DANGER ZONE             ${RED}║${NC}"
        echo -e "${RED}╚══════════════════════════════════╝${NC}"
        echo -e "${RED} 1) Drop & Reset Database Panel${NC}"
        echo -e "${RED} 2) Deep Uninstall (Hapus Bersih)${NC}"
        echo ""
        echo " 0) Kembali"
        echo ""
        read -r -p "Pilih [0-2]: " opt
        case $opt in
            1) drop_reset_database ;;
            2) deep_uninstall ;;
            0) break ;;
            *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
        esac
    done
}

# ====================================================
# SELF-CHECK
# ====================================================

function self_check() {
    bash -n "$0" 2>/dev/null || return 1
    local missing=0 fn
    for fn in install_pterodactyl \
              update_panel update_wings_only provision_services write_nginx_config \
              deep_maintenance check_script_update setup_cloudflare_tunnel \
              setup_cloudflare_named_tunnel set_panel_domain generate_wings_config_api \
              backup_system backup_db_only restore_system list_backups delete_backup \
              schedule_auto_backup health_check info_system view_logs_menu \
              check_wings_connection discord_setup create_admin_user \
              reset_admin_password change_db_password panel_maintenance_mode \
              export_config panel_user_manager bulk_server_action repair_menu \
              setup_firewall setup_rclone_storage create_swap optimize_server \
              restart_all_services security_audit db_optimize wings_watchdog_setup \
              wings_watchdog_remove telegram_setup set_custom_banner backup_stats \
              script_rollback help_screen deep_uninstall \
              select_deploy_mode setup_letsencrypt setup_fail2ban fail2ban_status \
              ensure_self_signed_cert install_cf_origin_cert \
              _mk_mysql_cnf mysql_secure mysqldump_secure mysqlcheck_secure \
              validate_db_password safe_reload_nginx \
              acquire_lock release_lock sha256_of qprint preview_backup \
              load_config save_config notify_detail \
              verify_backup list_admin_users container_resource_stats \
              clear_panel_cache auto_fix_panel cleanup_orphan_backups \
              drop_reset_database flush_redis_cache prune_old_backups_now \
               remote_install_wings remote_wings_status \
               egg_list_available egg_list_installed \
               backup_s3_setup backup_s3_test_upload backup_to_s3 \
                s3_restore_backup s3_list_backups s3_delete_backup s3_prune_old_backups s3_verify_backup \
                auto_backup_s3 set_backup_options set_panel_domain fix_backup_domain \
                _ensure_panel_domain _detect_domain_from_nginx \
              migrate_server \
               _check_new_panel_version _check_new_wings_version \
               check_updates_manual setup_auto_updates \
               wings_installer wings_config_manual wings_control_center \
               menu_install_update menu_cloudflare menu_backup \
               menu_monitoring menu_management menu_server_security \
               menu_wings menu_eggs_migration menu_security_updates \
               menu_tools_help menu_danger \
               addon_manager; do
        if ! declare -F "$fn" >/dev/null; then
            echo "MISSING: $fn"; missing=$((missing+1))
        fi
    done
    if [ "$missing" -gt 0 ]; then
        echo "Self-check GAGAL: $missing fungsi hilang."
        return 1
    fi
    echo "Sintaks OK. Semua fitur V$SCRIPT_VERSION tersedia."
    echo "Catatan: Jalankan di Ubuntu/Debian sebagai root."
}

# ====================================================
# CLI HANDLER
# ====================================================

if [ "${1:-}" = "--self-check" ]; then
    self_check
    exit $?
fi

for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET_MODE=1 ;;
    esac
done

if [[ " $* " == *" --auto-backup "* ]]; then
    require_root || exit 1
    AUTO_PASS=""
    AUTO_CNF=""
    prev=""
    for arg in "$@"; do
        if [ "$prev" = "--cnf" ]; then
            AUTO_CNF="$arg"
        fi
        prev="$arg"
    done
    [ -z "$AUTO_CNF" ] && [ -f "$AUTO_BACKUP_CNF" ] && AUTO_CNF="$AUTO_BACKUP_CNF"
    if [ -n "$AUTO_CNF" ] && [ -f "$AUTO_CNF" ]; then
        AUTO_PASS=$(awk -F= '
            /^[[:space:]]*password[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, "", $0); print; exit
            }' "$AUTO_CNF")
    fi
    [ -z "$AUTO_PASS" ] && AUTO_PASS="${PTERO_DB_PASS:-}"
    if [ -z "$AUTO_PASS" ]; then
        fail "Kredensial DB tidak ditemukan untuk auto-backup (cnf: ${AUTO_CNF:-none})."
        exit 1
    fi
    backup_system_with_password "$AUTO_PASS" "no"
    rc=$?
    AUTO_PASS=""
    if [ $rc -ne 0 ]; then
        exit $rc
    fi
    if [[ " $* " == *" --auto-s3-backup "* ]]; then
        # Re-read password for S3 step (already cleared in backup_system_with_password)
        if [ -n "$AUTO_CNF" ] && [ -f "$AUTO_CNF" ]; then
            AUTO_PASS=$(awk -F= '
                /^[[:space:]]*password[[:space:]]*=/ {
                    sub(/^[^=]*=[[:space:]]*/, "", $0); print; exit
                }' "$AUTO_CNF")
        fi
        if [ -n "$AUTO_PASS" ]; then
            auto_backup_s3 "$AUTO_PASS"
        else
            echo "S3 auto-backup SKIP: password tidak tersedia" >> "$LOG_FILE"
        fi
        AUTO_PASS=""
    fi
    exit 0
fi

while true; do
    header
    print_section "CATEGORY MENU"
    echo "  1) Install & Update"
    echo "  2) Cloudflare"
    echo "  3) Backup & Restore"
    echo "  4) Monitoring"
    echo "  5) Management"
    echo "  6) Server & Security"
    echo "  7) Wings"
    echo "  8) Eggs & Migration"
    echo "  9) Security Updates"
    echo " 10) Tools & Help"
    echo -e " ${RED}11) Danger Zone${NC}"
    print_footer
    read -r -p "Pilih [0-11]: " OPT
    case "$OPT" in
        1) menu_install_update ;;
        2) menu_cloudflare ;;
        3) menu_backup ;;
        4) menu_monitoring ;;
        5) menu_management ;;
        6) menu_server_security ;;
        7) menu_wings ;;
        8) menu_eggs_migration ;;
        9) menu_security_updates ;;
        10) menu_tools_help ;;
        11) menu_danger ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}Pilihan tidak valid.${NC}"; sleep 1 ;;
    esac
done
