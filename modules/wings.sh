_wings_header() {
    echo -e "\n${MAGENTA}╔══════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}${CYAN}   $1${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════╝${NC}"
}

_wings_status() {
    echo -e "${YELLOW}➤ $1...${NC}"
}

_wings_ok() {
    echo -e "${GREEN}✓ $1${NC}"
}

_wings_err() {
    echo -e "${RED}✗ $1${NC}"
}

function wings_installer() {
    require_root || return 1

    clear
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}${CYAN}     PTERODACTYL WINGS INSTALLER     ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"

    if [ "$(id -u)" -ne 0 ]; then
        _wings_err "Jalankan sebagai root"
        return 1
    fi

    _wings_header "INSTALLING DOCKER"
    _wings_status "Installing Docker"
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash >/dev/null 2>&1
    _wings_ok "Docker installed"

    _wings_status "Starting Docker service"
    systemctl enable --now docker >/dev/null 2>&1
    _wings_ok "Docker service started"

    _wings_header "UPDATING SYSTEM"
    local grub="/etc/default/grub"
    if [ -f "$grub" ]; then
        _wings_status "Updating GRUB"
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1"/' "$grub"
        update-grub >/dev/null 2>&1
        _wings_ok "GRUB updated"
    fi

    _wings_header "INSTALLING WINGS"
    _wings_status "Creating directories"
    mkdir -p /etc/pterodactyl
    _wings_ok "Directories created"

    _wings_status "Installing Wings"
    if ! install_wings_binary; then
        _wings_err "Gagal install Wings"
        return 1
    fi
    _wings_ok "Wings installed"

    _wings_header "CONFIGURING SERVICE"
    _wings_status "Creating service file"
    cat > /etc/systemd/system/wings.service <<UNIT
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
    _wings_ok "Service file created"

    systemctl daemon-reload >/dev/null 2>&1
    _wings_ok "Systemd reloaded"

    systemctl enable wings >/dev/null 2>&1
    _wings_ok "Service enabled"

    _wings_header "GENERATING SSL"
    _wings_status "Creating certificate"
    mkdir -p /etc/certs/wing
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
        -keyout /etc/certs/wing/privkey.pem -out /etc/certs/wing/fullchain.pem >/dev/null 2>&1
    _wings_ok "SSL certificate generated"

    _wings_header "CREATING HELPER"
    cat > /usr/local/bin/wing <<'EOF'
#!/bin/bash
echo ""
echo "Wings Helper Commands:"
echo "  start    : sudo systemctl start wings"
echo "  stop     : sudo systemctl stop wings"
echo "  status   : sudo systemctl status wings"
echo "  restart  : sudo systemctl restart wings"
echo "  logs     : sudo journalctl -u wings -f"
echo ""
EOF
    chmod +x /usr/local/bin/wing
    _wings_ok "Helper created"

    _wings_header "COMPLETE"
    echo -e "${GREEN}✓ Installation finished${NC}"
    echo ""
    echo -e "${CYAN}Start Wings:${NC} sudo systemctl start wings"
    echo -e "${CYAN}Helper:${NC} wing"
    echo ""
    pause
}
