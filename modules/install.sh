#!/bin/bash

# --- SEMA NEON THEME (scoped to avoid color conflicts) ---
_INST_CYAN='\033[38;5;51m'
_INST_PURPLE='\033[38;5;141m'
_INST_GRAY='\033[38;5;242m'
_INST_WHITE='\033[38;5;255m'
_INST_GREEN='\033[38;5;82m'
_INST_RED='\033[38;5;196m'
_INST_GOLD='\033[38;5;214m'
_INST_HEADER="${_INST_GRAY}────────────────────────────────────────────────────────────${NC}"

_install_banner() {
    clear
    echo -e "${_INST_CYAN}"
    cat << "EOF"
               .                                      .o8                          .               oooo  
             .o8                                     "888                        .o8               `888  
oo.ooooo.  .o888oo  .ooooo.  oooo d8b  .ooooo.   .oooo888   .oooo.    .ooooo.  .o888oo oooo    ooo  888  
 888' `88b   888   d88' `88b `888""8P d88' `88b d88' `888  `P  )88b  d88' `"Y8   888    `88.  .8'   888  
 888   888   888   888ooo888  888     888   888 888   888   .oP"888  888         888     `88..8'    888  
 888   888   888 . 888    .o  888     888   888 888   888  d8(  888  888   .o8   888 .    `888'     888  
 888bod8P'   "888" `Y8bod8P' d888b    `Y8bod8P' `Y8bod88P" `Y888""8o `Y8bod8P'   "888"     .8'     o888o 
 888                                                                                   .o..P'            
o888o                                                                                  `Y8P'             
                                                                                                         
EOF
    echo -e "           ${_INST_WHITE}PREMIUM PTERODACTYL INSTALLER${NC}"
    echo -e "${_INST_HEADER}"
}

_install_ok() {
    echo -e "  ${_INST_GREEN}[OK]${NC} $1"
}

_install_step() {
    echo -e "\n  ${_INST_PURPLE}::${NC} ${_INST_WHITE}$1${NC}"
}

_install_ask() {
    local label=$1
    local default=$2
    local var_name=$3
    echo -ne "  ${_INST_PURPLE}•${NC} ${_INST_WHITE}$label${NC} ${_INST_GRAY}[$default]${NC}\n  ${_INST_GRAY}╰─>${NC} "
    read -r input
    if [ -z "$input" ]; then
        eval "$var_name=\"$default\""
    else
        eval "$var_name=\"$input\""
    fi
}

function install_pterodactyl() {
    require_root || return 1

    _install_banner

    _install_ask "Panel Domain" "panel.example.com" DOMAIN
    _install_ask "Admin Email" "admin@example.com" EMAIL
    _install_ask "Admin Username" "admin" USERNAME
    _install_ask "Admin Password" "admin123" PASSWORD
    _install_ask "Database Password" "$(openssl rand -base64 24 | tr -d '=+/')" DB_PASS

    echo -e "\n  ${_INST_GOLD}┌─[ REVIEW CONFIGURATION ]${NC}"
    echo -e "  ${_INST_GOLD}│${NC} ${_INST_GRAY}Domain:${NC}   $DOMAIN"
    echo -e "  ${_INST_GOLD}│${NC} ${_INST_GRAY}Email:${NC}    $EMAIL"
    echo -e "  ${_INST_GOLD}│${NC} ${_INST_GRAY}User:${NC}     $USERNAME"
    echo -e "  ${_INST_GOLD}│${NC} ${_INST_GRAY}DB Pass:${NC}  $DB_PASS"
    echo -e "  ${_INST_GOLD}└───────────────────────────${NC}"

    while true; do
        echo -ne "\n  ${_INST_CYAN}Start Installation?${NC} ${_INST_WHITE}(y/n)${NC}${_INST_GRAY}:${NC} "
        read -n 1 -r CONFIRM
        echo ""
        case $CONFIRM in
            [Yy]*)
                echo -e "  ${_INST_GREEN}Proceeding to deployment...${NC}"
                break ;;
            [Nn]*)
                echo -e "  ${_INST_RED}Installation aborted by user.${NC}"
                return 0 ;;
            *) echo -e "  ${_INST_GRAY}Invalid input. Enter y or n.${NC}" ;;
        esac
    done

    echo -e "${_INST_HEADER}"

    # --- Dependencies ---
    apt update && apt install -y curl apt-transport-https ca-certificates gnupg unzip git tar sudo lsb-release

    # Detect OS
    OS=$(lsb_release -is | tr '[:upper:]' '[:lower:]')

    if [ "$OS" = "ubuntu" ]; then
        echo "Detected Ubuntu. Adding PPA for PHP..."
        apt install -y software-properties-common
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    elif [ "$OS" = "debian" ]; then
        echo "Detected Debian. Adding SURY PHP repo..."
        curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/sury-php.list
    fi

    # Add Redis GPG key and repo
    rm -f /usr/share/keyrings/redis-archive-keyring.gpg
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list

    apt update

    # --- Install PHP + extensions ---
    apt install -y php"${PHP_VERSION}" php"${PHP_VERSION}"-{cli,fpm,common,mysql,mbstring,bcmath,xml,zip,curl,gd,tokenizer,ctype,simplexml,dom} mariadb-server nginx redis-server

    # --- Install Composer ---
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    # --- Download Pterodactyl Panel ---
    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl || return 1
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/

    # --- MariaDB Setup ---
    DB_NAME=panel
    DB_USER=pterodactyl
    mariadb -e "CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
    mariadb -e "CREATE DATABASE ${DB_NAME};" 2>/dev/null || true
    mariadb -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;"
    mariadb -e "FLUSH PRIVILEGES;"

    # --- .env Setup ---
    if [ ! -f ".env.example" ]; then
        curl -Lo .env.example https://raw.githubusercontent.com/pterodactyl/panel/develop/.env.example
    fi
    cp .env.example .env
    sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|g" .env
    sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env
    sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env
    grep -q "^APP_ENVIRONMENT_ONLY=" .env || echo "APP_ENVIRONMENT_ONLY=false" >> .env

    # --- Install PHP dependencies ---
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

    # --- Generate Application Key ---
    php artisan key:generate --force

    # --- Run Migrations ---
    php artisan migrate --seed --force

    # --- Permissions ---
    chown -R www-data:www-data /var/www/pterodactyl/*
    apt install -y cron
    systemctl enable --now cron
    (crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

    # --- Nginx Setup ---
    mkdir -p /etc/certs/panel
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=NA/ST=NA/L=NA/O=NA/CN=${DOMAIN}" \
        -keyout /etc/certs/panel/privkey.pem -out /etc/certs/panel/fullchain.pem

    tee /etc/nginx/sites-available/pterodactyl.conf > /dev/null << EOF
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

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx
    fi

    # --- Queue Worker ---
    tee /etc/systemd/system/pteroq.service > /dev/null << 'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now redis-server
    systemctl enable --now pteroq.service
    _install_ok "Queue running"

    clear
    _install_step "Create admin user"

    cd /var/www/pterodactyl || return 1

    # Update .env settings
    sed -i '/^APP_ENVIRONMENT_ONLY=/d' .env
    echo "APP_ENVIRONMENT_ONLY=false" >> .env
    sed -i '/RECAPTCHA_ENABLED=/d' .env
    echo 'RECAPTCHA_ENABLED=false' >> .env
    sed -i '/APP_NAME=/d' .env
    echo 'APP_NAME="Pterodactyl Panel"' >> .env
    TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=${TIMEZONE}|g" .env

    # --- Cache optimization ---
    php artisan view:clear
    php artisan config:clear
    php artisan cache:clear
    php artisan config:cache
    chown -R www-data:www-data /var/www/pterodactyl/*
    php artisan queue:restart

    # --- Admin User ---
    php artisan p:user:make -n --email="$EMAIL" --username="${USERNAME}" --password="$PASSWORD" --admin=1 --name-first=My --name-last=Admin

    # --- END REPORT ---
    clear
    echo -e "${_INST_HEADER}"
    echo -e "\n  ${_INST_CYAN}DEPLOYMENT COMPLETE${NC}"
    echo -e "  ${_INST_GRAY}Panel URL :${NC} ${_INST_WHITE}https://$DOMAIN${NC}"
    echo -e "  ${_INST_GRAY}Username  :${NC} ${_INST_WHITE}$USERNAME${NC}"
    echo -e "  ${_INST_GRAY}Password  :${NC} ${_INST_WHITE}$PASSWORD${NC}"
    echo -e "  ${_INST_GRAY}Email     :${NC} ${_INST_WHITE}$EMAIL${NC}"
    echo -e "\n  ${_INST_PURPLE}Enjoy your new Pterodactyl Panel!${NC}"
    echo -e "${_INST_HEADER}"
}
