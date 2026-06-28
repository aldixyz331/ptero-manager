_caw_status() {
    if systemctl is-active --quiet wings; then
        echo -e "${GREEN}ACTIVE${NC}"
    else
        echo -e "${RED}INACTIVE${NC}"
    fi
}

_caw_header() {
    clear
    local s
    s=$(_caw_status)
    local up
    up=$(systemctl show -p ActiveEnterTimestamp wings | cut -d'=' -f2 2>/dev/null || echo "N/A")

    echo -e "${PURPLE}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│${NC}  ${CYAN}🪽  WINGS CONTROL CENTER${NC} ${GRAY}v17.0${NC}          ${GRAY}$(date +"%H:%M")${NC}  ${PURPLE}│${NC}"
    echo -e "${PURPLE}└──────────────────────────────────────────────────────────┘${NC}"
    echo -e "  ${CYAN}NODE DIAGNOSTICS${NC}"
    echo -e "  ${GRAY}├─ Service :${NC} ${WHITE}wings${NC}   ${GRAY}Status :${NC} $s"
    echo -e "  ${GRAY}└─ Active  :${NC} ${GRAY}${up}${NC}"
    echo -e "${GRAY}────────────────────────────────────────────────────────────${NC}"
}

_caw_local_ip() {
    _caw_header
    read -r -p "Create Node Auto [Y/n]: " c
    c=$(echo "$c" | tr -d '[:space:]')
    c=${c:-y}

    if [[ "$c" =~ ^[Yy]$ ]]; then
        local domain
        domain=$(curl -s ifconfig.me)
        read -p "Enter Domain [$domain]: " domain
        domain=${domain:-$domain}

        cd /var/www/pterodactyl 2>/dev/null || { fail "Panel dir not found"; return 1; }
        local last_num
        last_num=$(php artisan p:node:list 2>/dev/null | grep -oP 'Node - \K[0-9]+' | sort -n | tail -1)
        local next=$((last_num + 1))
        next=${next:-1}
        local name="Node - $next"
        printf "$name\nVPS: $(hostname) | IP: $(curl -s ifconfig.me) | RAM: $(free -m | awk '/Mem:/ {print $2}')MB | Location: IN\n1\nhttps\n${domain}\ny\nn\nn\n99999\n0\n99999\n0\n1024\n443\n2022\n/var/lib/pterodactyl/volumes\n" | php artisan p:node:make >/dev/null 2>&1
    fi
}

_caw_public_ip() {
    _caw_header
    read -r -p "Create Node Auto [Y/n]: " c
    c=$(echo "$c" | tr -d '[:space:]')
    c=${c:-y}

    if [[ "$c" =~ ^[Yy]$ ]]; then
        local domain
        domain=$(curl -s ifconfig.me)
        read -p "Enter Domain [$domain]: " domain
        domain=${domain:-$domain}

        if [ -z "$domain" ]; then echo "Aborted."; return; fi

        apt update -y >/dev/null 2>&1
        apt install -y certbot python3-certbot-nginx >/dev/null 2>&1
        rm -rf "/etc/letsencrypt/live/$domain" "/etc/letsencrypt/archive/$domain" "/etc/letsencrypt/renewal/$domain.conf"
        certbot certonly --nginx -d "$domain" --non-interactive --agree-tos --email "ssl$(tr -dc a-z0-9 </dev/urandom | head -c6)@$domain" >/dev/null 2>&1

        cd /var/www/pterodactyl 2>/dev/null || { fail "Panel dir not found"; return 1; }
        local last_num
        last_num=$(php artisan p:node:list 2>/dev/null | grep -oP 'Node - \K[0-9]+' | sort -n | tail -1)
        local next=$((last_num + 1))
        next=${next:-1}
        local name="Node - $next"
        printf "$name\nVPS: $(hostname) | IP: $(curl -s ifconfig.me) | RAM: $(free -m | awk '/Mem:/ {print $2}')MB | Location: IN\n1\nhttps\n$domain\ny\nn\nn\n99999\n0\n99999\n0\n1024\n8080\n2022\n/var/lib/pterodactyl/volumes\n" | php artisan p:node:make >/dev/null 2>&1
    fi
}

_caw_node_menu() {
    while true; do
        clear
        echo "==== 🚀 NODE SETUP PROTOCOLS ===="
        echo "  [1] Public Domain (Auto SSL)"
        echo "  [2] Local IP (Manual)"
        echo "  [3] Finalize Deployment (Start Wings)"
        echo "  [0] Back"
        echo ""
        read -p "Setup-Action: " s_choice

        case $s_choice in
            1)
                _caw_public_ip
                cd /var/www/pterodactyl 2>/dev/null || continue
                local count
                count=$(php artisan p:node:list 2>/dev/null | awk -F'|' 'NR>3 && $2+0 {count++} END {print count+0}')
                local node_id=""
                if [ "$count" -eq 0 ] || [ -z "$count" ]; then
                    local name="Node - 1"
                    printf "$name\nVPS: $(hostname)\n1\nhttp\n$(curl -s ifconfig.me)\ny\nn\nn\n4096\n0\n20000\n0\n100\n8080\n2022\n/var/lib/pterodactyl/volumes\n" | php artisan p:node:make >/dev/null 2>&1
                    node_id=$(php artisan p:node:list | awk -F'|' 'NR>3 && $2+0 {gsub(/ /,"",$2); print $2}' | head -1)
                else
                    php artisan p:node:list | awk -F'|' 'NR>3 && $2+0 {ID=$2; NAME=$4; HOST=$6; gsub(/ /,"",ID); gsub(/^ +| +$/,"",NAME); gsub(/ /,"",HOST); split(HOST,a,":"); PORT=a[length(a)]; printf "%s) %s | %s | Port:%s\n", ID, NAME, HOST, PORT}'
                    read -p "Select Node ID: " node_id
                fi
                [ -z "$node_id" ] && { echo "Invalid Node"; sleep 1; continue; }
                mkdir -p /etc/pterodactyl
                php artisan p:node:configuration "$node_id" > /etc/pterodactyl/config.yml
                pkill wings 2>/dev/null
                wings >/dev/null 2>&1 &
                systemctl restart wings 2>/dev/null
                echo "✅ Done: Node $node_id connected"
                sleep 2 ;;
            2)
                _caw_local_ip
                cd /var/www/pterodactyl 2>/dev/null || continue
                local count
                count=$(php artisan p:node:list 2>/dev/null | awk -F'|' 'NR>3 && $2+0 {count++} END {print count+0}')
                local node_id=""
                if [ "$count" -eq 0 ] || [ -z "$count" ]; then
                    local name="Node - 1"
                    printf "$name\nVPS: $(hostname)\n1\nhttp\n$(curl -s ifconfig.me)\ny\nn\nn\n4096\n0\n20000\n0\n100\n8080\n2022\n/var/lib/pterodactyl/volumes\n" | php artisan p:node:make >/dev/null 2>&1
                    node_id=$(php artisan p:node:list | awk -F'|' 'NR>3 && $2+0 {gsub(/ /,"",$2); print $2}' | head -1)
                else
                    php artisan p:node:list | awk -F'|' 'NR>3 && $2+0 {ID=$2; NAME=$4; HOST=$6; gsub(/ /,"",ID); gsub(/^ +| +$/,"",NAME); gsub(/ /,"",HOST); split(HOST,a,":"); PORT=a[length(a)]; printf "%s) %s | %s | Port:%s\n", ID, NAME, HOST, PORT}'
                    read -p "Select Node ID: " node_id
                fi
                [ -z "$node_id" ] && { echo "Invalid Node"; sleep 1; continue; }
                mkdir -p /etc/pterodactyl
                php artisan p:node:configuration "$node_id" > /etc/pterodactyl/config.yml
                pkill wings 2>/dev/null
                wings >/dev/null 2>&1 &
                sed -i "s|port: 443|port: 8080|g" /etc/pterodactyl/config.yml
                sed -i "s|cert:.*|cert: /etc/certs/wing/fullchain.pem|g" /etc/pterodactyl/config.yml
                sed -i "s|key:.*|key: /etc/certs/wing/privkey.pem|g" /etc/pterodactyl/config.yml
                systemctl restart wings
                echo "✅ Done: Node $node_id connected"
                sleep 2 ;;
            3)
                systemctl restart wings
                echo "✅ Wings Running"
                sleep 2 ;;
            0) break ;;
        esac
    done
}

function wings_control_center() {
    require_root || return 1
    while true; do
        _caw_header
        echo -e "  ${CYAN}SERVICE MANAGEMENT${NC}"
        echo -e "  ${GRAY}├─ [1]${NC} Start       ${GRAY}[4]${NC} Status"
        echo -e "  ${GRAY}├─ [2]${NC} Restart     ${GRAY}[5]${NC} Live Logs"
        echo -e "  ${GRAY}└─ [3]${NC} Stop        ${GRAY}[6]${NC} Debug Mode"
        echo ""
        echo -e "  ${PURPLE}ADVANCED TOOLS${NC}"
        echo -e "  ${GRAY}├─ [A]${NC} ${WHITE}Auto Node Setup${NC}"
        echo -e "  ${GRAY}└─ [0]${NC} ${RED}Exit Manager${NC}"
        echo ""
        echo -ne "  ${CYAN}λ${NC} ${WHITE}Master Command:${NC} "
        read -r choice

        case $choice in
            1) systemctl start wings; echo -e "  ${GREEN}✔ Started${NC}"; sleep 1 ;;
            2) systemctl restart wings; echo -e "  ${CYAN}✔ Restarted${NC}"; sleep 1 ;;
            3) systemctl stop wings; echo -e "  ${RED}✔ Stopped${NC}"; sleep 1 ;;
            4) systemctl status wings --no-pager; read -p "Enter to return..." ;;
            5) journalctl -u wings -f ;;
            6) systemctl stop wings; wings; read -p "Enter to return..." ;;
            [Aa]) _caw_node_menu ;;
            0) echo -e "\n  ${GRAY}Goodbye.${NC}"; return 0 ;;
        esac
    done
}
