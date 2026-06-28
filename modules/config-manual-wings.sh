_cmw_msg_info() { echo -e "  ${BLUE}➜${NC} $1"; }
_cmw_msg_ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
_cmw_msg_err()  { echo -e "  ${RED}✖${NC} $1"; }
_cmw_msg_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
_cmw_msg_input() { echo -ne "  ${PURPLE}➤${NC} $1: "; }

_cmw_spinner() {
    local pid=$1 delay=0.1 spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

_cmw_header() {
    clear
    local host=$(hostname)
    local ip=$(hostname -I | awk '{print $1}')
    local status="${RED}✖ OFFLINE${NC}"
    systemctl is-active --quiet wings && status="${GREEN}● ONLINE${NC}"

    echo -e "${PURPLE} ⚡ ${WHITE}WINGS CONFIGURATOR ${GRAY}:: v4.5${NC}"
    echo -e "${PURPLE} ├──${NC} ${BLUE}SYSTEM INFORMATION${NC}"
    echo -e "${PURPLE} │   ├─${NC} ${GRAY}Hostname :${NC} ${WHITE}$host${NC}"
    echo -e "${PURPLE} │   └─${NC} ${GRAY}IP Addr  :${NC} ${WHITE}$ip${NC}"
    echo -e "${PURPLE} ├──${NC} ${BLUE}SERVICE STATUS${NC}"
    echo -e "${PURPLE} │   └─${NC} ${GRAY}Daemon   :${NC} $status"
    echo -e "${PURPLE} └──────────────────────────────────────────${NC}"
    echo ""
}

function wings_config_manual() {
    require_root || return 1

    _cmw_header

    echo -e "${WHITE}  CONFIGURATION WIZARD${NC}"
    echo -e "${GRAY}  Enter credentials. Type 'back' to go to previous step.${NC}"
    echo -e "${GRAY}  ──────────────────────────────────────────${NC}"

    local step=1 uuid="" token_id="" token="" api_port="8080" remote="" input=""

    while [ $step -le 6 ]; do
        case $step in
            1)
                echo ""
                [ -n "$uuid" ] && echo -e "  ${GRAY}(Current: $uuid)${NC}"
                _cmw_msg_input "Node UUID"
                read input
                if [ "$input" = "back" ]; then _cmw_msg_warn "Exiting..."; return 0
                elif [ -z "$input" ] && [ -n "$uuid" ]; then ((step++))
                elif [ -z "$input" ]; then _cmw_msg_err "UUID required."; continue
                else uuid="$input"; ((step++)); fi ;;
            2)
                echo ""
                [ -n "$token_id" ] && echo -e "  ${GRAY}(Current: $token_id)${NC}"
                _cmw_msg_input "Token ID"
                read input
                if [ "$input" = "back" ]; then ((step--))
                elif [ -z "$input" ] && [ -n "$token_id" ]; then ((step++))
                elif [ -z "$input" ]; then _cmw_msg_err "Token ID required."; continue
                else token_id="$input"; ((step++)); fi ;;
            3)
                echo ""
                [ -n "$token" ] && echo -e "  ${GRAY}(Current: ************)${NC}"
                _cmw_msg_input "Token Key"
                read input
                if [ "$input" = "back" ]; then ((step--))
                elif [ -z "$input" ] && [ -n "$token" ]; then ((step++))
                elif [ -z "$input" ]; then _cmw_msg_err "Token Key required."; continue
                else token="$input"; ((step++)); fi ;;
            4)
                echo ""
                [ "$api_port" != "8080" ] && echo -e "  ${GRAY}(Current: $api_port)${NC}"
                _cmw_msg_input "API Port"
                read input
                if [ "$input" = "back" ]; then ((step--))
                elif [ -z "$input" ]; then _cmw_msg_warn "Using Port: $api_port"; ((step++))
                elif [[ ! "$input" =~ ^[0-9]+$ ]]; then _cmw_msg_err "Must be a number."; continue
                else api_port="$input"; ((step++)); fi ;;
            5)
                echo ""
                [ -n "$remote" ] && echo -e "  ${GRAY}(Current: $remote)${NC}"
                _cmw_msg_input "Panel URL"
                read input
                if [ "$input" = "back" ]; then ((step--))
                elif [ -z "$input" ] && [ -n "$remote" ]; then ((step++))
                elif [ -z "$input" ]; then _cmw_msg_warn "Using default."; remote="https://panel.example.com"; ((step++))
                elif [[ ! "$input" =~ ^https?:// ]]; then _cmw_msg_err "Use http:// or https://"; continue
                else remote="$input"; ((step++)); fi ;;
            6)
                echo ""
                echo -e "${CYAN}  REVIEW SETTINGS:${NC}"
                echo -e "${GRAY}  ──────────────────────────────────────────${NC}"
                echo -e "  ${GRAY}●${NC} UUID      : ${WHITE}$uuid${NC}"
                echo -e "  ${GRAY}●${NC} Token ID  : ${WHITE}$token_id${NC}"
                echo -e "  ${GRAY}●${NC} Token Key : ${WHITE}****************${NC}"
                echo -e "  ${GRAY}●${NC} API Port  : ${WHITE}$api_port${NC}"
                echo -e "  ${GRAY}●${NC} Remote    : ${WHITE}$remote${NC}"
                echo -e "${GRAY}  ──────────────────────────────────────────${NC}"
                echo ""
                read -p "  Apply Configuration? (Y/n/back): " input
                if [ "$input" = "back" ]; then ((step--))
                elif [[ "$input" =~ ^[Nn]$ ]]; then _cmw_msg_err "Cancelled."; return 0
                else break; fi ;;
        esac
    done

    echo ""
    _cmw_msg_info "Generating Configuration File..."
    rm -f /etc/pterodactyl/config.yml
    mkdir -p /etc/pterodactyl

    cat > /etc/pterodactyl/config.yml <<CFG
debug: false
uuid: ${uuid}
token_id: ${token_id}
token: ${token}
api:
  host: 0.0.0.0
  port: ${api_port}
  ssl:
    enabled: true
    cert: /etc/certs/wing/fullchain.pem
    key: /etc/certs/wing/privkey.pem
  upload_limit: 100
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022
allowed_mounts: []
remote: '${remote}'
CFG

    if [ $? -eq 0 ]; then
        _cmw_msg_ok "Config Written: /etc/pterodactyl/config.yml"
    else
        _cmw_msg_err "Failed to write config file!"
        return 1
    fi

    echo ""
    _cmw_msg_info "Restarting Wings Service..."
    systemctl enable wings >/dev/null 2>&1
    (systemctl restart wings) &
    _cmw_spinner $!

    sleep 2
    if systemctl is-active --quiet wings; then
        _cmw_msg_ok "Wings is Active & Running."
        echo ""
        echo -e "${GRAY}  ──────────────────────────────────────────${NC}"
        echo -e "  ${CYAN}DEBUG COMMANDS:${NC}"
        echo -e "  ${WHITE}systemctl status wings${NC}"
        echo -e "  ${WHITE}journalctl -u wings -f${NC}"
        echo ""
    else
        _cmw_msg_err "Service failed to start."
        echo -e "  ${RED}Check logs: journalctl -u wings -n 20${NC}"
    fi
    pause
}
