#!/bin/bash

function migrate_server() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${BLUE}Server Migration Tool${NC}"
    echo -e "${YELLOW}Pindahin server dari satu node ke node lain.${NC}"
    echo

    read -r -s -p "Password database $DB_USER: " DBP
    echo

    read -r -p "Server UUID (contoh: 12345678-1234-1234-1234-123456789abc): " SERVER_UUID
    [ -z "$SERVER_UUID" ] && { fail "Server UUID wajib."; pause; return 1; }

    local server_check
    server_check=$(mysql_secure "$DB_USER" "$DBP" -h 127.0.0.1 -D "$DB_NAME" \
        --batch -e "SELECT id, name, node_id FROM servers WHERE uuid='$SERVER_UUID'" 2>/dev/null)

    if ! echo "$server_check" | grep -qE '^[0-9]'; then
        fail "Server '$SERVER_UUID' tidak ditemukan di database."
        pause
        return 1
    fi

    local server_id server_name current_node_id
    server_id=$(echo "$server_check" | awk 'NR==2{print $1}')
    server_name=$(echo "$server_check" | awk 'NR==2{print $2}')
    current_node_id=$(echo "$server_check" | awk 'NR==2{print $3}')

    local current_node_name
    current_node_name=$(mysql_secure "$DB_USER" "$DBP" -h 127.0.0.1 -D "$DB_NAME" \
        --batch -e "SELECT name FROM nodes WHERE id=$current_node_id" 2>/dev/null | awk 'NR==2{print $1}')

    echo -e "Server  : ${CYAN}$server_name${NC} (ID: $server_id)"
    echo -e "Node    : ${CYAN}$current_node_name${NC} (ID: $current_node_id)"
    echo

    local nodes
    nodes=$(mysql_secure "$DB_USER" "$DBP" -h 127.0.0.1 -D "$DB_NAME" \
        --batch -e "SELECT id, name, daemon_listen FROM nodes WHERE id != $current_node_id ORDER BY name" 2>/dev/null)

    if [ -z "$nodes" ] || [ "$(echo "$nodes" | wc -l)" -le 1 ]; then
        fail "Tidak ada node lain tersedia untuk migrasi."
        pause
        return 1
    fi

    echo -e "${CYAN}Pilih node tujuan:${NC}"
    local node_list=()
    while IFS='|' read -r nid nname nlisten; do
        [ -z "$nid" ] || [ "$nid" = "id" ] && continue
        node_list+=("$nid|$nname|$nlisten")
        echo "  ${#node_list[@]}) $nname (ID: $nid)"
    done <<< "$nodes"

    read -r -p "Nomor node tujuan: " NDEST
    local dest_idx=$((NDEST-1))
    [ "$dest_idx" -lt 0 ] || [ "$dest_idx" -ge "${#node_list[@]}" ] && {
        fail "Nomor tidak valid."; pause; return 1
    }

    local dest_info="${node_list[$dest_idx]}"
    local dest_node_id dest_node_name dest_node_listen
    dest_node_id=$(echo "$dest_info" | cut -d'|' -f1)
    dest_node_name=$(echo "$dest_info" | cut -d'|' -f2)
    dest_node_listen=$(echo "$dest_info" | cut -d'|' -f3)

    echo
    echo -e "${YELLOW}Rencana migrasi:${NC}"
    echo -e "  Server  : $server_name ($SERVER_UUID)"
    echo -e "  Dari    : $current_node_name (ID: $current_node_id)"
    echo -e "  Ke      : $dest_node_name (ID: $dest_node_id)"
    echo
    confirm_action "Lanjutkan migrasi?" || { pause; return 0; }

    acquire_lock || { pause; return 1; }
    trap 'release_lock; systemctl start wings 2>/dev/null || true' EXIT

    # Stop Wings dulu biar konsisten
    echo -e "${BLUE}[*] Stop Wings...${NC}"
    systemctl stop wings 2>/dev/null || true

    # Backup volume server
    local vol_src="/var/lib/pterodactyl/volumes/$SERVER_UUID"
    local vol_dest="/tmp/ptero-migrate-$SERVER_UUID.tar.gz"
    if [ -d "$vol_src" ]; then
        echo -e "${BLUE}[*] Backup volume server...${NC}"
        tar -czf "$vol_dest" -C "/var/lib/pterodactyl/volumes" "$SERVER_UUID" 2>/dev/null || {
            fail "Gagal backup volume."
            systemctl start wings 2>/dev/null || true
            release_lock; trap - EXIT; pause; return 1
        }
    else
        echo -e "  ${YELLOW}Tidak ada volume untuk server ini.${NC}"
        vol_dest=""
    fi

    # Update database
    echo -e "${BLUE}[*] Update node assignment di database...${NC}"
    mysql_secure "$DB_USER" "$DBP" -h 127.0.0.1 -D "$DB_NAME" \
        -e "UPDATE servers SET node_id=$dest_node_id WHERE id=$server_id" 2>/dev/null || {
        fail "Gagal update database."
        rm -f "$vol_dest" 2>/dev/null || true
        systemctl start wings 2>/dev/null || true
        release_lock; trap - EXIT; pause; return 1
    }
    echo -e "  ${GREEN}[OK]${NC} Database updated."

    # Restart Wings untuk apply config
    echo -e "${BLUE}[*] Restart Wings...${NC}"
    systemctl start wings 2>/dev/null || true
    sleep 2

    # Copy volume ke node tujuan via SCP (kalo ada info koneksi)
    if [ -n "$vol_dest" ] && [ -f "$vol_dest" ]; then
        echo -e "${YELLOW}Volume tersimpan di: $vol_dest${NC}"
        echo -e "${YELLOW}Langkah manual untuk node $dest_node_name:${NC}"
        echo -e "  1. Copy file ke node tujuan:"
        echo -e "     scp $vol_dest root@<IP_NODE>:/var/lib/pterodactyl/volumes/"
        echo -e "  2. Extract di node tujuan:"
        echo -e "     tar -xzf $SERVER_UUID.tar.gz -C /var/lib/pterodactyl/volumes/"
        echo -e "  3. Restart Wings di node tujuan"
        echo
        echo -e "${CYAN}Atau, masukkan IP node tujuan untuk auto-copy:${NC}"
        read -r -p "IP node $dest_node_name (kosongkan untuk skip): " DEST_IP
        if [ -n "$DEST_IP" ]; then
            read -r -p "SSH user [root]: " DEST_USER
            DEST_USER=${DEST_USER:-root}
            read -r -s -p "SSH password: " DEST_PASS
            echo
            local scp_cmd="scp -o StrictHostKeyChecking=no"
            [ -n "$DEST_PASS" ] && {
                command -v sshpass >/dev/null 2>&1 || apt install -y sshpass >/dev/null 2>&1 || true
                scp_cmd="sshpass -p '$DEST_PASS' $scp_cmd"
            }
            echo -e "${BLUE}[*] Copy volume ke $DEST_IP...${NC}"
            if eval "$scp_cmd '$vol_dest' ${DEST_USER}@${DEST_IP}:/var/lib/pterodactyl/volumes/" 2>/dev/null; then
                eval "ssh ${DEST_USER}@${DEST_IP} 'tar -xzf /var/lib/pterodactyl/volumes/$(basename "$vol_dest") -C /var/lib/pterodactyl/volumes/ && rm -f /var/lib/pterodactyl/volumes/$(basename "$vol_dest") && systemctl restart wings'" 2>/dev/null || true
                echo -e "  ${GREEN}[OK]${NC} Volume terkirim & Wings di-restart."
                rm -f "$vol_dest"
            else
                echo -e "  ${RED}[FAIL]${NC} Gagal copy. File masih di $vol_dest"
            fi
        fi
    fi

    log_msg "Server $server_name ($SERVER_UUID) migrated from node $current_node_id to $dest_node_id"
    notify_detail "MIGRASI" "Server '$server_name' dipindahkan dari $current_node_name ke $dest_node_name."
    echo -e "${GREEN}Migrasi selesai.${NC}"
    release_lock
    trap - EXIT
    pause
}
