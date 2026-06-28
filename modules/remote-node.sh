#!/bin/bash

function remote_install_wings() {
    require_root || return 1
    header
    echo -e "${BLUE}Remote Wings Installer${NC}"
    echo -e "${YELLOW}Install Wings di server lain via SSH.${NC}"
    echo

    read -r -p "IP/Host remote: " REMOTE_HOST
    [ -z "$REMOTE_HOST" ] && { fail "IP wajib diisi."; pause; return 1; }
    read -r -p "SSH user [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}
    read -r -s -p "SSH password (kosongkan jika pakai key): " REMOTE_PASS
    echo

    local ssh_base="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
    [ -n "$REMOTE_PASS" ] && ssh_base="sshpass -p '$REMOTE_PASS' $ssh_base"

    echo -e "${BLUE}[*] Cek koneksi ke $REMOTE_HOST...${NC}"
    if ! eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'echo OK'" 2>/dev/null; then
        fail "Tidak bisa terkoneksi ke $REMOTE_HOST. Cek IP/user/password."
        pause
        return 1
    fi

    echo -e "${BLUE}[*] Install Docker di remote...${NC}"
    eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'curl -fsSL https://get.docker.com/ | CHANNEL=stable bash'" 2>&1 || {
        fail "Gagal install Docker di remote."; pause; return 1
    }
    eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'systemctl enable --now docker'" 2>/dev/null || true

    echo -e "${BLUE}[*] Install Wings binary...${NC}"
    eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'mkdir -p /etc/pterodactyl && curl -fsSL -o /tmp/wings.new https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 && chmod +x /tmp/wings.new && /tmp/wings.new --version >/dev/null 2>&1 && mv /tmp/wings.new /usr/local/bin/wings'" 2>&1 || {
        fail "Gagal install Wings binary (verifikasi gagal)."; pause; return 1
    }

    echo -e "${BLUE}[*] Setup systemd service...${NC}"
    eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'cat > /etc/systemd/system/wings.service << \"UNIT\"
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable wings'" 2>&1 || {
        fail "Gagal setup systemd."; pause; return 1
    }

    echo -e "${BLUE}[*] Install UFW + buka port Wings...${NC}"
    eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'ufw allow 22/tcp && ufw allow 8080/tcp && ufw allow 2022/tcp && ufw --force enable'" 2>/dev/null || true

    echo -e "${GREEN}=== Remote Wings selesai terinstall! ===${NC}"
    echo -e "${YELLOW}Langkah selanjutnya:${NC}"
    echo -e "  1. Di Panel: Admin > Nodes > Tambah node baru"
    echo -e "  2. Generate token config -> simpan di remote: /etc/pterodactyl/config.yml"
    echo -e "  3. Start Wings di remote: systemctl start wings"
    echo -e ""
    echo -e "  Atau kirim config.yml langsung dari sini:"
    read -r -p "  Kirim config.yml dari panel ini? [y/N]: " SEND_CONFIG
    if [[ "$SEND_CONFIG" =~ ^[Yy]$ ]]; then
        if [ -f "$WINGS_DIR/config.yml" ]; then
            eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'cat > /etc/pterodactyl/config.yml'" < "$WINGS_DIR/config.yml" 2>/dev/null && {
                echo -e "${GREEN}config.yml terkirim.${NC}"
                eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'systemctl start wings'" 2>/dev/null || true
            }
        else
            echo -e "${YELLOW}Tidak ada config.yml di $WINGS_DIR. Generate dulu lewat menu 10.${NC}"
        fi
    fi

    log_msg "Remote Wings installed: $REMOTE_HOST"
    notify_detail "REMOTE WINGS" "Wings terinstall di $REMOTE_HOST"
    pause
}

function remote_wings_status() {
    require_root || return 1
    header
    read -r -p "IP/Host remote: " REMOTE_HOST
    [ -z "$REMOTE_HOST" ] && { fail "IP wajib diisi."; pause; return 1; }
    read -r -p "SSH user [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}
    read -r -s -p "SSH password (kosongkan jika pakai key): " REMOTE_PASS
    echo

    local ssh_base="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
    [ -n "$REMOTE_PASS" ] && ssh_base="sshpass -p '$REMOTE_PASS' $ssh_base"

    echo -e "${BLUE}Status Wings di $REMOTE_HOST:${NC}"
    eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'systemctl status wings --no-pager -n 10 2>&1 || echo service not found'" 2>/dev/null || echo "Koneksi gagal."
    echo
    eval "$ssh_base ${REMOTE_USER}@${REMOTE_HOST} 'wings --version 2>/dev/null || echo wings binary not found'" 2>/dev/null
    pause
}
