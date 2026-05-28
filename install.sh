#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  SubManager — Auto Installer v2.0
#  VPN Subscription Management Panel
#  Usage: bash <(curl -sL https://your-host.com/install.sh)
#═══════════════════════════════════════════════════════════════════════════════
set -e

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'

INSTALL_DIR="/opt/submanager"
SERVICE_NAME="submanager"
NGINX_CONF="/etc/nginx/sites-available/submanager"
NGINX_LINK="/etc/nginx/sites-enabled/submanager"
CONFIG_FILE="${INSTALL_DIR}/config.json"
MANAGE_SCRIPT="/usr/local/bin/submanager"

# ── Helper functions ──────────────────────────────────────────────────────────

banner() {
cat << 'EOF'

   ╔═══════════════════════════════════════════════╗
   ║       ⚡ SubManager Panel Installer ⚡        ║
   ║           VPN Subscription Manager            ║
   ║                  v2.0.0                       ║
   ╚═══════════════════════════════════════════════╝

EOF
}

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
step()    { echo -e "\n${PURPLE}━━━ $1 ━━━${NC}\n"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Unsupported OS"
        exit 1
    fi
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        warn "This script is optimized for Ubuntu/Debian. Detected: $ID"
        read -p "Continue anyway? [y/N]: " cont
        [[ "$cont" != "y" && "$cont" != "Y" ]] && exit 1
    fi
    success "OS: $PRETTY_NAME"
}

get_ip() {
    # Пытаемся получить внешний IP несколькими способами
    IP=$(curl -s4 ifconfig.me 2>/dev/null)
    if [[ -z "$IP" || "$IP" == "0.0.0.0" ]]; then
        IP=$(curl -s4 icanhazip.com 2>/dev/null)
    fi
    if [[ -z "$IP" || "$IP" == "0.0.0.0" ]]; then
        IP=$(curl -s4 checkip.amazonaws.com 2>/dev/null)
    fi
    if [[ -z "$IP" || "$IP" == "0.0.0.0" ]]; then
        # Если внешний IP не получилось - берем локальный
        IP=$(hostname -I | awk '{print $1}')
    fi
    if [[ -z "$IP" ]]; then
        IP="0.0.0.0"
    fi
    echo "$IP"
}

# ── Check if already installed ────────────────────────────────────────────────

check_existing() {
    if [[ -d "$INSTALL_DIR" && -f "${INSTALL_DIR}/app.py" ]]; then
        warn "SubManager is already installed!"
        echo ""
        echo -e "  ${CYAN}1)${NC} Reinstall (fresh install, keeps database)"
        echo -e "  ${CYAN}2)${NC} Update (update files only)"
        echo -e "  ${CYAN}3)${NC} Uninstall"
        echo -e "  ${CYAN}4)${NC} Open management menu"
        echo -e "  ${CYAN}0)${NC} Exit"
        echo ""
        read -p "Choose [0-4]: " choice
        case $choice in
            1) info "Reinstalling..."; REINSTALL=1 ;;
            2) update_files; exit 0 ;;
            3) uninstall; exit 0 ;;
            4) exec submanager; exit 0 ;;
            *) exit 0 ;;
        esac
    fi
}

# ── Uninstall ─────────────────────────────────────────────────────────────────

uninstall() {
    step "Uninstalling SubManager"
    warn "This will remove SubManager but keep the database backup."

    read -p "Are you sure? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    if [[ -f "${INSTALL_DIR}/db.sqlite" ]]; then
        cp "${INSTALL_DIR}/db.sqlite" "/root/submanager_db_backup_$(date +%Y%m%d_%H%M%S).sqlite"
        success "Database backed up to /root/"
    fi

    systemctl stop $SERVICE_NAME 2>/dev/null || true
    systemctl disable $SERVICE_NAME 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    rm -f "$NGINX_CONF" "$NGINX_LINK"
    rm -f "$MANAGE_SCRIPT"
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reload
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

    success "SubManager uninstalled."
}

# ── Update files only ─────────────────────────────────────────────────────────

update_files() {
    step "Updating SubManager files"
    deploy_files
    systemctl restart $SERVICE_NAME
    success "Updated and restarted!"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN INSTALLATION
# ══════════════════════════════════════════════════════════════════════════════

install_dependencies() {
    step "Installing dependencies"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        python3 python3-pip python3-venv \
        nginx certbot python3-certbot-nginx \
        ufw curl wget sqlite3 jq \
        > /dev/null 2>&1

    success "System packages installed"

    # Create venv
    python3 -m venv ${INSTALL_DIR}/venv 2>/dev/null || true
    ${INSTALL_DIR}/venv/bin/pip install --quiet flask requests psutil gunicorn 2>/dev/null \
        || pip3 install flask requests psutil gunicorn --break-system-packages --quiet

    success "Python packages installed"
}

configure_firewall() {
    step "Configuring firewall (UFW)"
    ufw allow 22/tcp   >/dev/null 2>&1 || true
    ufw allow 80/tcp   >/dev/null 2>&1 || true
    ufw allow 443/tcp  >/dev/null 2>&1 || true
    ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1 || true
    if [[ -n "$PANEL_DOMAIN" && "$HTTPS_PORT" != "443" ]]; then
        ufw allow ${HTTPS_PORT}/tcp >/dev/null 2>&1 || true
    fi
    echo "y" | ufw enable >/dev/null 2>&1 || true
    if [[ -n "$PANEL_DOMAIN" ]]; then
        success "Firewall configured (ports 22, 80, 443, ${HTTPS_PORT}, ${PANEL_PORT})"
    else
        success "Firewall configured (ports 22, 80, 443, ${PANEL_PORT})"
    fi
}

# ── Interactive Setup Wizard ──────────────────────────────────────────────────

setup_wizard() {
    step "Setup Wizard"
    SERVER_IP=$(get_ip)

    echo -e "${WHITE}Server IP: ${CYAN}${SERVER_IP}${NC}\n"

    # Username
    read -p "$(echo -e ${CYAN}Panel username${NC} [admin]): " PANEL_USER
    PANEL_USER=${PANEL_USER:-admin}

    # Password
    while true; do
        read -sp "$(echo -e ${CYAN}Panel password${NC} [auto-generate]): " PANEL_PASS
        echo ""
        if [[ -z "$PANEL_PASS" ]]; then
            PANEL_PASS=$(openssl rand -base64 12 | tr -d '=/+' | head -c 16)
            warn "Generated password: ${BOLD}${PANEL_PASS}${NC}"
            break
        elif [[ ${#PANEL_PASS} -lt 4 ]]; then
            error "Password must be at least 4 characters"
        else
            break
        fi
    done

    # Port
    read -p "$(echo -e ${CYAN}Panel port${NC} [1088]): " PANEL_PORT
    PANEL_PORT=${PANEL_PORT:-1088}

    # Panel title
    read -p "$(echo -e ${CYAN}Panel title${NC} [VPN Sub Manager]): " PANEL_TITLE
    PANEL_TITLE=${PANEL_TITLE:-VPN Sub Manager}

    # Domain
    echo ""
    echo -e "${WHITE}Domain setup (for HTTPS/SSL):${NC}"
    echo -e "  If you have a domain pointed to this server, enter it."
    echo -e "  Leave empty to use IP address (http://${SERVER_IP}:${PANEL_PORT})"
    echo ""
    read -p "$(echo -e ${CYAN}Domain${NC} [none]): " PANEL_DOMAIN

    # HTTPS port (only if domain set)
    HTTPS_PORT=443
    if [[ -n "$PANEL_DOMAIN" ]]; then
        echo ""
        echo -e "  ${WHITE}HTTPS listen port:${NC}"
        echo -e "  443 = standard (https://domain.com)"
        echo -e "  custom = non-standard (https://domain.com:PORT)"
        read -p "$(echo -e ${CYAN}HTTPS port${NC} [443]): " HTTPS_PORT
        HTTPS_PORT=${HTTPS_PORT:-443}
    fi

    # Confirm
    echo ""
    echo -e "${WHITE}┌─────────────────────────────────────────┐${NC}"
    echo -e "${WHITE}│${NC}  ${BOLD}Configuration Summary${NC}                   ${WHITE}│${NC}"
    echo -e "${WHITE}├─────────────────────────────────────────┤${NC}"
    echo -e "${WHITE}│${NC}  Username:  ${GREEN}${PANEL_USER}${NC}"
    echo -e "${WHITE}│${NC}  Password:  ${GREEN}${PANEL_PASS}${NC}"
    echo -e "${WHITE}│${NC}  Port:      ${GREEN}${PANEL_PORT}${NC}"
    echo -e "${WHITE}│${NC}  Title:     ${GREEN}${PANEL_TITLE}${NC}"
    if [[ -n "$PANEL_DOMAIN" ]]; then
    echo -e "${WHITE}│${NC}  Domain:    ${GREEN}${PANEL_DOMAIN}${NC}"
    echo -e "${WHITE}│${NC}  SSL:       ${GREEN}Let's Encrypt (auto)${NC}"
    echo -e "${WHITE}│${NC}  HTTPS:     ${GREEN}port ${HTTPS_PORT}${NC}"
    if [[ "$HTTPS_PORT" == "443" ]]; then
    echo -e "${WHITE}│${NC}  URL:       ${CYAN}https://${PANEL_DOMAIN}${NC}"
    else
    echo -e "${WHITE}│${NC}  URL:       ${CYAN}https://${PANEL_DOMAIN}:${HTTPS_PORT}${NC}"
    fi
    else
    echo -e "${WHITE}│${NC}  Domain:    ${YELLOW}none (IP mode)${NC}"
    echo -e "${WHITE}│${NC}  URL:       ${CYAN}http://${SERVER_IP}:${PANEL_PORT}${NC}"
    fi
    echo -e "${WHITE}└─────────────────────────────────────────┘${NC}"
    echo ""

    read -p "$(echo -e ${GREEN}Proceed with installation?${NC} [Y/n]): " proceed
    [[ "$proceed" == "n" || "$proceed" == "N" ]] && exit 0
}

# ── Deploy application files ─────────────────────────────────────────────────

deploy_files() {
    mkdir -p ${INSTALL_DIR}/templates

    # App.py and plugin.py are extracted from embedded data below
    extract_embedded_files

    success "Application files deployed"
}

# ── Create config ─────────────────────────────────────────────────────────────

create_config() {
    SERVER_IP=$(get_ip)
    if [[ -n "$PANEL_DOMAIN" ]]; then
        if [[ "$HTTPS_PORT" == "443" ]]; then
            BASE_URL="https://${PANEL_DOMAIN}"
        else
            BASE_URL="https://${PANEL_DOMAIN}:${HTTPS_PORT}"
        fi
    else
        BASE_URL="http://${SERVER_IP}:${PANEL_PORT}"
    fi

    cat > ${CONFIG_FILE} << CFGEOF
{
  "username": "${PANEL_USER}",
  "password": "${PANEL_PASS}",
  "port": ${PANEL_PORT},
  "domain": "${PANEL_DOMAIN}",
  "panel_title": "${PANEL_TITLE}",
  "base_url": "${BASE_URL}",
  "installed_at": "$(date -Iseconds)",
  "https_port": ${HTTPS_PORT:-443},
  "version": "2.0.0"
}
CFGEOF
    chmod 600 ${CONFIG_FILE}
    success "Config saved"
}

# ── Setup systemd service ────────────────────────────────────────────────────

setup_service() {
    step "Creating systemd service"

    # Determine python path
    if [[ -f ${INSTALL_DIR}/venv/bin/python3 ]]; then
        PY_BIN="${INSTALL_DIR}/venv/bin/python3"
        GUNICORN="${INSTALL_DIR}/venv/bin/gunicorn"
    else
        PY_BIN=$(which python3)
        GUNICORN=$(which gunicorn 2>/dev/null || echo "")
    fi

    if [[ -n "$GUNICORN" && -f "$GUNICORN" ]]; then
        EXEC_CMD="${GUNICORN} -w 2 -b 127.0.0.1:${PANEL_PORT} app:app"
    else
        EXEC_CMD="${PY_BIN} app.py"
    fi

    cat > /etc/systemd/system/${SERVICE_NAME}.service << SVCEOF
[Unit]
Description=SubManager VPN Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${EXEC_CMD}
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME >/dev/null 2>&1
    systemctl restart $SERVICE_NAME

    success "Service created and started"
}

# ── Setup Nginx + SSL ─────────────────────────────────────────────────────────

setup_nginx() {
    step "Configuring Nginx"

    # Remove default
    rm -f /etc/nginx/sites-enabled/default

    if [[ -n "$PANEL_DOMAIN" ]]; then
        # With domain — setup reverse proxy + SSL
        cat > ${NGINX_CONF} << NGXEOF
server {
    listen ${HTTPS_PORT} ssl http2;
    server_name ${PANEL_DOMAIN};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$server_name:\$request_uri;
}
NGXEOF
        ln -sf ${NGINX_CONF} ${NGINX_LINK}
        nginx -t 2>/dev/null && systemctl reload nginx

        success "Nginx configured for ${PANEL_DOMAIN}"
    echo -e "
${CYAN}=== Nginx Config ===${NC}
"
    cat ${NGINX_CONF}
    echo ""

        # SSL with certbot
        step "Setting up SSL certificate"
        echo -e "${YELLOW}Requesting Let's Encrypt certificate...${NC}"

        # SSL certificate - certbot needs port 80 temporarily
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow ${HTTPS_PORT}/tcp >/dev/null 2>&1 || true
        certbot --nginx -d ${PANEL_DOMAIN} --non-interactive --agree-tos \
            --register-unsafely-without-email 2>&1 || {
            warn "Auto SSL failed. You can run manually later:"
            echo -e "  ${CYAN}certbot --nginx -d ${PANEL_DOMAIN}${NC}"
            echo ""
            read -p "Enter email for SSL (or press Enter to skip): " SSL_EMAIL
            if [[ -n "$SSL_EMAIL" ]]; then
                certbot --nginx -d ${PANEL_DOMAIN} --non-interactive --agree-tos \
                    -m "${SSL_EMAIL}" --redirect 2>&1 || \
                    warn "SSL setup failed. Configure manually later."
            fi
        }

        # Auto-renew
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | sort -u | crontab -

    else
        # Without domain — direct port access, optional nginx proxy
        cat > ${NGINX_CONF} << NGXEOF
server {
    listen ${PANEL_PORT};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300;
    }
}
NGXEOF
        # In IP mode, app listens directly - no nginx needed really
        rm -f ${NGINX_CONF} ${NGINX_LINK}
        success "Running in direct mode on port ${PANEL_PORT}"
    fi
}

# ── Management CLI script ─────────────────────────────────────────────────────

create_management_script() {
    step "Creating management CLI"

    cat > ${MANAGE_SCRIPT} << 'MGEOF'
#!/bin/bash
#═══════════════════════════════════════════════════════════════
#  SubManager — Management Panel
#═══════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'

INSTALL_DIR="/opt/submanager"
CONFIG="${INSTALL_DIR}/config.json"
SERVICE="submanager"

get_val() { jq -r ".$1 // \"$2\"" "$CONFIG" 2>/dev/null || echo "$2"; }
get_ip()  { curl -s4 ifconfig.me 2>/dev/null || echo "0.0.0.0"; }

show_status() {
    clear
    echo -e "${PURPLE}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║       ${WHITE}⚡ SubManager Control Panel ⚡${PURPLE}          ║${NC}"
    echo -e "${PURPLE}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    # Service status
    if systemctl is-active --quiet $SERVICE; then
        echo -e "  Status:    ${GREEN}● Running${NC}"
    else
        echo -e "  Status:    ${RED}● Stopped${NC}"
    fi

    IP=$(get_ip)
    PORT=$(get_val port 1088)
    DOMAIN=$(get_val domain "")
    USER=$(get_val username "admin")
    TITLE=$(get_val panel_title "VPN Sub Manager")
    VERSION=$(get_val version "2.0.0")

    echo -e "  Version:   ${CYAN}${VERSION}${NC}"
    echo -e "  Server IP: ${CYAN}${IP}${NC}"
    echo -e "  Port:      ${CYAN}${PORT}${NC}"
    echo -e "  Username:  ${CYAN}${USER}${NC}"
    echo -e "  Title:     ${CYAN}${TITLE}${NC}"

    if [[ -n "$DOMAIN" ]]; then
        echo -e "  Domain:    ${GREEN}${DOMAIN}${NC}"
        echo -e "  Panel URL: ${GREEN}https://${DOMAIN}${NC}"
    else
        echo -e "  Domain:    ${YELLOW}Not set${NC}"
        echo -e "  Panel URL: ${GREEN}http://${IP}:${PORT}${NC}"
    fi

    # Check SSL
    if [[ -n "$DOMAIN" ]] && certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
        EXPIRY=$(certbot certificates 2>/dev/null | grep "Expiry" | head -1 | awk '{print $3}')
        echo -e "  SSL:       ${GREEN}Active (expires: ${EXPIRY})${NC}"
    else
        echo -e "  SSL:       ${YELLOW}Not configured${NC}"
    fi

    # System resources
    echo ""
    echo -e "  ${WHITE}System:${NC}"
    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "?")
    MEM=$(free -m | awk 'NR==2{printf "%.1f%%", $3*100/$2 }')
    DISK=$(df -h / | awk 'NR==2{print $5}')
    echo -e "  CPU: ${CYAN}${CPU}%${NC}  MEM: ${CYAN}${MEM}${NC}  Disk: ${CYAN}${DISK}${NC}"
}

menu() {
    echo ""
    echo -e "  ${WHITE}━━━ Actions ━━━${NC}"
    echo ""
    echo -e "  ${CYAN} 1)${NC} Start / Restart panel"
    echo -e "  ${CYAN} 2)${NC} Stop panel"
    echo -e "  ${CYAN} 3)${NC} View logs"
    echo ""
    echo -e "  ${WHITE}━━━ Settings ━━━${NC}"
    echo ""
    echo -e "  ${CYAN} 4)${NC} Change username & password"
    echo -e "  ${CYAN} 5)${NC} Change port"
    echo -e "  ${CYAN} 6)${NC} Change domain / Setup SSL"
    echo -e "  ${CYAN} 7)${NC} Change panel title"
    echo -e "  ${CYAN} 8)${NC} Change base URL"
    echo ""
    echo -e "  ${WHITE}━━━ Maintenance ━━━${NC}"
    echo ""
    echo -e "  ${CYAN} 9)${NC} Backup database"
    echo -e "  ${CYAN}10)${NC} Restore database"
    echo -e "  ${CYAN}11)${NC} Reset database (fresh start)"
    echo -e "  ${CYAN}12)${NC} Open firewall port"
    echo -e "  ${CYAN}13)${NC} Update SubManager"
    echo ""
    echo -e "  ${RED}14)${NC} Uninstall SubManager"
    echo -e "  ${CYAN}15)${NC} View Nginx config"
    echo -e "  ${CYAN} 0)${NC} Exit"
    echo ""
}

change_credentials() {
    echo ""
    CURRENT_USER=$(get_val username "admin")
    read -p "  New username [$CURRENT_USER]: " NEW_USER
    NEW_USER=${NEW_USER:-$CURRENT_USER}

    while true; do
        read -sp "  New password: " NEW_PASS
        echo ""
        if [[ -z "$NEW_PASS" ]]; then
            echo -e "  ${RED}Password cannot be empty${NC}"
        elif [[ ${#NEW_PASS} -lt 4 ]]; then
            echo -e "  ${RED}Password must be at least 4 characters${NC}"
        else
            break
        fi
    done

    TMP=$(mktemp)
    jq --arg u "$NEW_USER" --arg p "$NEW_PASS" '.username=$u | .password=$p' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
    chmod 600 "$CONFIG"
    systemctl restart $SERVICE
    echo -e "\n  ${GREEN}✓ Credentials updated. Username: ${NEW_USER}${NC}"
}

change_port() {
    echo ""
    CURRENT_PORT=$(get_val port 1088)
    read -p "  New port [$CURRENT_PORT]: " NEW_PORT
    NEW_PORT=${NEW_PORT:-$CURRENT_PORT}

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [[ "$NEW_PORT" -lt 1 || "$NEW_PORT" -gt 65535 ]]; then
        echo -e "  ${RED}Invalid port${NC}"
        return
    fi

    # Update config
    TMP=$(mktemp)
    jq --argjson p "$NEW_PORT" '.port=$p' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
    chmod 600 "$CONFIG"

    # Update systemd service
    sed -i "s/:${CURRENT_PORT}/:${NEW_PORT}/g" /etc/systemd/system/${SERVICE}.service
    systemctl daemon-reload

    # Update firewall
    ufw allow ${NEW_PORT}/tcp >/dev/null 2>&1

    # Update base_url if using IP
    DOMAIN=$(get_val domain "")
    if [[ -z "$DOMAIN" ]]; then
        IP=$(get_ip)
        TMP=$(mktemp)
        jq --arg u "http://${IP}:${NEW_PORT}" '.base_url=$u' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
        chmod 600 "$CONFIG"
    fi

    systemctl restart $SERVICE
    echo -e "\n  ${GREEN}✓ Port changed to ${NEW_PORT}${NC}"
}

change_domain() {
    echo ""
    CURRENT_DOMAIN=$(get_val domain "")
    echo -e "  Current domain: ${CYAN}${CURRENT_DOMAIN:-none}${NC}"
    echo ""
    echo -e "  ${YELLOW}Make sure your domain's DNS A record points to this server!${NC}"
    echo ""
    read -p "  New domain (empty to remove): " NEW_DOMAIN
    PORT=$(get_val port 1088)

    TMP=$(mktemp)
    jq --arg d "$NEW_DOMAIN" '.domain=$d' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
    chmod 600 "$CONFIG"

    if [[ -n "$NEW_DOMAIN" ]]; then
        # Update base_url
        TMP=$(mktemp)
        jq --arg u "https://${NEW_DOMAIN}" '.base_url=$u' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
        chmod 600 "$CONFIG"

        # Create nginx config
        cat > /etc/nginx/sites-available/submanager << NGEOF
server {
    listen 80;
    server_name ${NEW_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
    }
}
NGEOF
        ln -sf /etc/nginx/sites-available/submanager /etc/nginx/sites-enabled/submanager
        nginx -t 2>/dev/null && systemctl reload nginx

        echo ""
        read -p "  Setup SSL with Let's Encrypt? [Y/n]: " DO_SSL
        if [[ "$DO_SSL" != "n" && "$DO_SSL" != "N" ]]; then
            read -p "  Email for SSL (or Enter to skip): " SSL_EMAIL
            if [[ -n "$SSL_EMAIL" ]]; then
                certbot --nginx -d ${NEW_DOMAIN} --non-interactive --agree-tos -m "${SSL_EMAIL}" --redirect
            else
                certbot --nginx -d ${NEW_DOMAIN} --non-interactive --agree-tos --register-unsafely-without-email --redirect
            fi
            echo -e "\n  ${GREEN}✓ SSL configured for ${NEW_DOMAIN}${NC}"
        fi
    else
        # Remove nginx config, go back to IP mode
        rm -f /etc/nginx/sites-available/submanager /etc/nginx/sites-enabled/submanager
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        IP=$(get_ip)
        TMP=$(mktemp)
        jq --arg u "http://${IP}:${PORT}" '.base_url=$u' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
        chmod 600 "$CONFIG"
        echo -e "\n  ${GREEN}✓ Domain removed, using IP mode${NC}"
    fi

    systemctl restart $SERVICE
}

change_title() {
    echo ""
    CURRENT=$(get_val panel_title "VPN Sub Manager")
    read -p "  New panel title [$CURRENT]: " NEW_TITLE
    NEW_TITLE=${NEW_TITLE:-$CURRENT}
    TMP=$(mktemp)
    jq --arg t "$NEW_TITLE" '.panel_title=$t' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
    chmod 600 "$CONFIG"
    systemctl restart $SERVICE
    echo -e "\n  ${GREEN}✓ Title changed to: ${NEW_TITLE}${NC}"
}

change_base_url() {
    echo ""
    CURRENT=$(get_val base_url "")
    echo -e "  Current base URL: ${CYAN}${CURRENT}${NC}"
    read -p "  New base URL: " NEW_URL
    if [[ -z "$NEW_URL" ]]; then
        echo -e "  ${RED}Cancelled${NC}"
        return
    fi
    TMP=$(mktemp)
    jq --arg u "$NEW_URL" '.base_url=$u' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
    chmod 600 "$CONFIG"
    systemctl restart $SERVICE
    echo -e "\n  ${GREEN}✓ Base URL set to: ${NEW_URL}${NC}"
}

backup_db() {
    BACKUP_FILE="/root/submanager_backup_$(date +%Y%m%d_%H%M%S).sqlite"
    cp "${INSTALL_DIR}/db.sqlite" "$BACKUP_FILE"
    echo -e "\n  ${GREEN}✓ Database backed up to: ${BACKUP_FILE}${NC}"
}

restore_db() {
    echo ""
    echo -e "  ${WHITE}Available backups:${NC}"
    ls -la /root/submanager_*backup*.sqlite 2>/dev/null || { echo "  No backups found."; return; }
    echo ""
    read -p "  Path to backup file: " BACKUP_PATH
    if [[ -f "$BACKUP_PATH" ]]; then
        systemctl stop $SERVICE
        cp "$BACKUP_PATH" "${INSTALL_DIR}/db.sqlite"
        systemctl start $SERVICE
        echo -e "\n  ${GREEN}✓ Database restored${NC}"
    else
        echo -e "  ${RED}File not found${NC}"
    fi
}

reset_db() {
    echo ""
    echo -e "  ${RED}WARNING: This will delete ALL users, nodes, and settings!${NC}"
    read -p "  Type 'RESET' to confirm: " CONFIRM
    if [[ "$CONFIRM" == "RESET" ]]; then
        backup_db
        systemctl stop $SERVICE
        rm -f "${INSTALL_DIR}/db.sqlite"
        systemctl start $SERVICE
        echo -e "\n  ${GREEN}✓ Database reset (backup saved)${NC}"
    else
        echo -e "  ${YELLOW}Cancelled${NC}"
    fi
}

open_port() {
    echo ""
    read -p "  Port to open: " FW_PORT
    if [[ -n "$FW_PORT" ]]; then
        ufw allow ${FW_PORT}/tcp >/dev/null 2>&1
        echo -e "\n  ${GREEN}✓ Port ${FW_PORT} opened${NC}"
    fi
}

do_uninstall() {
    echo ""
    echo -e "  ${RED}This will completely remove SubManager!${NC}"
    read -p "  Type 'UNINSTALL' to confirm: " CONFIRM
    if [[ "$CONFIRM" == "UNINSTALL" ]]; then
        backup_db
        systemctl stop $SERVICE 2>/dev/null
        systemctl disable $SERVICE 2>/dev/null
        rm -f /etc/systemd/system/${SERVICE}.service
        rm -f /etc/nginx/sites-available/submanager /etc/nginx/sites-enabled/submanager
        systemctl daemon-reload
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        rm -rf "$INSTALL_DIR"
        echo -e "\n  ${GREEN}✓ Uninstalled (backup saved in /root/)${NC}"
        rm -f "$0"
        exit 0
    else
        echo -e "  ${YELLOW}Cancelled${NC}"
    fi
}



# ══════════════════════════════════════════════════════════════════════════════
# VIEW COMMANDS
# ══════════════════════════════════════════════════════════════════════════════

show_nginx_config() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Nginx Configuration                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}
"
    
    if [[ -f /etc/nginx/sites-available/submanager ]]; then
        echo -e "${WHITE}File: /etc/nginx/sites-available/submanager${NC}
"
        cat /etc/nginx/sites-available/submanager
        echo -e "
${WHITE}Enabled (symbolic link):${NC}"
        ls -l /etc/nginx/sites-enabled/submanager 2>/dev/null || echo "  (not linked)"
        echo ""
        echo -e "${WHITE}Nginx test:${NC}"
        nginx -t 2>&1 | grep -E "successful|error" || nginx -t
    else
        echo -e "${YELLOW}No nginx config found (running in IP mode)${NC}"
    fi
    
    echo ""
    read -p "  Press Enter to continue..."
}

show_app_config() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Application Configuration          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}
"
    
    if [[ -f /opt/submanager/config.json ]]; then
        echo -e "${WHITE}File: /opt/submanager/config.json${NC}
"
        cat /opt/submanager/config.json | jq . 2>/dev/null || cat /opt/submanager/config.json
    else
        echo -e "${RED}Config file not found!${NC}"
    fi
    
    echo ""
    read -p "  Press Enter to continue..."
}

show_system_info() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       System Information                 ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}
"
    
    echo -e "${WHITE}Hostname:${NC} $(hostname)"
    echo -e "${WHITE}Kernel:${NC} $(uname -r)"
    echo -e "${WHITE}Uptime:${NC} $(uptime -p)"
    echo -e "${WHITE}OS:${NC} $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo ""
    
    echo -e "${WHITE}Network:${NC}"
    echo -e "  Internal IP: $(hostname -I | awk '{print $1}')"
    echo -e "  External IP: $(curl -s4 ifconfig.me 2>/dev/null || echo 'unknown')"
    echo ""
    
    echo -e "${WHITE}Storage:${NC}"
    df -h / | tail -1 | awk '{printf "  Used: %s / %s (%.1f%%)
", $3, $2, $5}'
    echo ""
    
    echo -e "${WHITE}Memory:${NC}"
    free -h | grep Mem | awk '{printf "  Used: %s / %s (%.1f%%)
", $3, $2, ($3/$2)*100}'
    echo ""
    
    echo -e "${WHITE}Disk I/O:${NC}"
    iostat -x 1 2 2>/dev/null | tail -1 | awk '{printf "  Read: %.0fMB/s, Write: %.0fMB/s
", $4, $5}' || echo "  (iostat not available)"
    echo ""
    
    echo -e "${WHITE}Services:${NC}"
    echo -n "  submanager: "
    systemctl is-active submanager >/dev/null && echo -e "${GREEN}●${NC} running" || echo -e "${RED}●${NC} stopped"
    echo -n "  nginx: "
    systemctl is-active nginx >/dev/null && echo -e "${GREEN}●${NC} running" || echo -e "${RED}●${NC} stopped"
    echo ""
    
    read -p "  Press Enter to continue..."
}

show_ssl_info() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       SSL Certificate Information        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}
"
    
    DOMAIN=$(get_val domain "")
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${YELLOW}No domain configured (IP mode)${NC}"
    else
        echo -e "${WHITE}Domain:${NC} $DOMAIN
"
        
        if certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
            echo -e "${GREEN}✓ SSL certificate found
${NC}"
            certbot certificates 2>/dev/null | grep -A 5 "$DOMAIN"
            echo ""
            echo -e "${WHITE}Auto-renewal:${NC} Enabled (cron job)"
            echo -e "${WHITE}Next check:${NC} Daily at 3:00 AM"
        else
            echo -e "${YELLOW}No SSL certificate found${NC}"
            echo -e "Run: ${CYAN}certbot --nginx -d $DOMAIN${NC}"
        fi
    fi
    
    echo ""
    read -p "  Press Enter to continue..."
}

show_database_info() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Database Information               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}
"
    
    DB="/opt/submanager/db.sqlite"
    if [[ -f "$DB" ]]; then
        SIZE=$(du -sh "$DB" | awk '{print $1}')
        MODIFIED=$(stat -c %y "$DB" 2>/dev/null | cut -d' ' -f1-2)
        
        echo -e "${WHITE}Database:${NC} $DB"
        echo -e "${WHITE}Size:${NC} $SIZE"
        echo -e "${WHITE}Modified:${NC} $MODIFIED"
        echo ""
        
        echo -e "${WHITE}Tables:${NC}"
        sqlite3 "$DB" ".tables" 2>/dev/null | tr ' ' '
' | nl
        echo ""
        
        echo -e "${WHITE}Row counts:${NC}"
        echo -n "  users: "
        sqlite3 "$DB" "SELECT COUNT(*) FROM users" 2>/dev/null || echo "?"
        echo -n "  nodes: "
        sqlite3 "$DB" "SELECT COUNT(*) FROM nodes" 2>/dev/null || echo "?"
        echo -n "  logs: "
        sqlite3 "$DB" "SELECT COUNT(*) FROM logs" 2>/dev/null || echo "?"
        echo ""
    else
        echo -e "${RED}Database not found!${NC}"
    fi
    
    echo ""
    read -p "  Press Enter to continue..."
}

# Main loop
while true; do
    show_status
    menu
    read -p "  $(echo -e ${CYAN}Choose [0-14]:${NC}) " OPT
    case $OPT in
        1)  systemctl restart $SERVICE; echo -e "\n  ${GREEN}✓ Restarted${NC}" ;;
        2)  systemctl stop $SERVICE; echo -e "\n  ${GREEN}✓ Stopped${NC}" ;;
        3)  journalctl -u $SERVICE -n 50 --no-pager; echo "" ;;
        4)  change_credentials ;;
        5)  change_port ;;
        6)  change_domain ;;
        7)  change_title ;;
        8)  change_base_url ;;
        9)  backup_db ;;
        10) restore_db ;;
        11) reset_db ;;
        12) open_port ;;
        13) echo -e "\n  Run: ${CYAN}bash <(curl -sL YOUR_URL/install.sh)${NC} and choose Update"; ;;
        14) do_uninstall ;;
        0)  echo -e "\n  ${GREEN}Bye!${NC}\n"; exit 0 ;;
        *)  echo -e "\n  ${RED}Invalid option${NC}" ;;
    esac
    echo ""
    read -p "  Press Enter to continue..."
done
MGEOF

    chmod +x ${MANAGE_SCRIPT}
    success "Management CLI created: ${BOLD}submanager${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  EMBEDDED FILES — extracted during installation
# ══════════════════════════════════════════════════════════════════════════════


# ── View Nginx Config Command ──────────────────────────────────────────────────

view_nginx_config() {
    step "Viewing Nginx Configuration"
    
    if [[ -f /etc/nginx/sites-available/submanager ]]; then
        echo -e "${CYAN}=== /etc/nginx/sites-available/submanager ===${NC}
"
        cat /etc/nginx/sites-available/submanager
        echo ""
    else
        echo -e "${YELLOW}Nginx config not found (probably running in IP mode)${NC}"
    fi
    
    if [[ -L /etc/nginx/sites-enabled/submanager ]]; then
        echo -e "${CYAN}=== Enabled (linked) ===${NC}"
        ls -l /etc/nginx/sites-enabled/submanager
    fi
    
    echo ""
    echo -e "${CYAN}=== Nginx Test ===${NC}"
    nginx -t
    echo ""
}

extract_embedded_files() {
    # Files are embedded below as base64 between markers
    # This function extracts them

    echo "ZnJvbSBmbGFzayBpbXBvcnQgRmxhc2ssIHJlbmRlcl90ZW1wbGF0ZSwgcmVxdWVzdCwganNvbmlmeSwgUmVzcG9uc2UsIHNlc3Npb24sIHJlZGlyZWN0LCB1cmxfZm9yCmZyb20gZnVuY3Rvb2xzIGltcG9ydCB3cmFwcwppbXBvcnQgc3FsaXRlMwppbXBvcnQgYmFzZTY0CmltcG9ydCByZXF1ZXN0cwppbXBvcnQgc2VjcmV0cwppbXBvcnQganNvbgppbXBvcnQgb3MKZnJvbSBkYXRldGltZSBpbXBvcnQgZGF0ZXRpbWUsIHRpbWVkZWx0YQppbXBvcnQgcHN1dGlsCmZyb20gcGx1Z2luIGltcG9ydCBpc19oYXBwX2NsaWVudCwgYWRkX2hhcHBfaGVhZGVycywgZ2V0X2hhcHBfbGluawpmcm9tIHBsdWdpbiBpbXBvcnQgaXNfaGFwcF9jbGllbnQsIGFkZF9oYXBwX2hlYWRlcnMsIGdldF9oYXBwX2xpbmssIGdldF9icm93c2VyX3N1YnNjcmlwdGlvbl9wYWdlCgphcHAgPSBGbGFzayhfX25hbWVfXykKYXBwLnNlY3JldF9rZXkgPSBzZWNyZXRzLnRva2VuX2hleCgzMikKCkJBU0VfRElSID0gJy9vcHQvc3VibWFuYWdlcicKREFUQUJBU0UgPSBvcy5wYXRoLmpvaW4oQkFTRV9ESVIsICdkYi5zcWxpdGUnKQpDT05GSUdfRklMRSA9IG9zLnBhdGguam9pbihCQVNFX0RJUiwgJ2NvbmZpZy5qc29uJykKCgpkZWYgbG9hZF9jb25maWcoKToKICAgIGlmIG9zLnBhdGguZXhpc3RzKENPTkZJR19GSUxFKToKICAgICAgICB3aXRoIG9wZW4oQ09ORklHX0ZJTEUsICdyJykgYXMgZjoKICAgICAgICAgICAgcmV0dXJuIGpzb24ubG9hZChmKQogICAgcmV0dXJuIHsndXNlcm5hbWUnOiAnYWRtaW4nLCAncGFzc3dvcmQnOiAnYWRtaW4nLCAncG9ydCc6IDEwODgsICdkb21haW4nOiAnJywgJ3BhbmVsX3RpdGxlJzogJ1ZQTiBTdWIgTWFuYWdlcid9CgoKZGVmIHNhdmVfY29uZmlnKGNmZyk6CiAgICB3aXRoIG9wZW4oQ09ORklHX0ZJTEUsICd3JykgYXMgZjoKICAgICAgICBqc29uLmR1bXAoY2ZnLCBmLCBpbmRlbnQ9MikKCgpfQ0ZHID0gbG9hZF9jb25maWcoKQpBRE1JTl9VU0VSID0gX0NGRy5nZXQoJ3VzZXJuYW1lJywgJ2FkbWluJykKQURNSU5fUEFTUyA9IF9DRkcuZ2V0KCdwYXNzd29yZCcsICdhZG1pbicpCgoKZGVmIGxvZ2luX3JlcXVpcmVkKGYpOgogICAgQHdyYXBzKGYpCiAgICBkZWYgZGVjb3JhdGVkKCphcmdzLCAqKmt3YXJncyk6CiAgICAgICAgaWYgbm90IHNlc3Npb24uZ2V0KCdsb2dnZWRfaW4nKToKICAgICAgICAgICAgaWYgcmVxdWVzdC5wYXRoLnN0YXJ0c3dpdGgoJy9hcGkvJykgb3IgcmVxdWVzdC5wYXRoLnN0YXJ0c3dpdGgoJy9zdWIvJyk6CiAgICAgICAgICAgICAgICByZXR1cm4ganNvbmlmeSh7J2Vycm9yJzogJ3VuYXV0aG9yaXplZCd9KSwgNDAxCiAgICAgICAgICAgIHJldHVybiByZWRpcmVjdCgnL2xvZ2luJykKICAgICAgICByZXR1cm4gZigqYXJncywgKiprd2FyZ3MpCiAgICByZXR1cm4gZGVjb3JhdGVkCgoKQGFwcC5yb3V0ZSgnL2xvZ2luJywgbWV0aG9kcz1bJ0dFVCcsICdQT1NUJ10pCmRlZiBsb2dpbigpOgogICAgZXJyb3IgPSBOb25lCiAgICBpZiByZXF1ZXN0Lm1ldGhvZCA9PSAnUE9TVCc6CiAgICAgICAgdSA9IHJlcXVlc3QuZm9ybS5nZXQoJ3VzZXJuYW1lJywgJycpCiAgICAgICAgcCA9IHJlcXVlc3QuZm9ybS5nZXQoJ3Bhc3N3b3JkJywgJycpCiAgICAgICAgaWYgdSA9PSBBRE1JTl9VU0VSIGFuZCBwID09IEFETUlOX1BBU1M6CiAgICAgICAgICAgIHNlc3Npb25bJ2xvZ2dlZF9pbiddID0gVHJ1ZQogICAgICAgICAgICBzZXNzaW9uLnBlcm1hbmVudCA9IFRydWUKICAgICAgICAgICAgcmV0dXJuIHJlZGlyZWN0KCcvJykKICAgICAgICBlcnJvciA9ICfQndC10LLQtdGA0L3Ri9C5INC70L7Qs9C40L0g0LjQu9C4INC/0LDRgNC+0LvRjCcKICAgIHJldHVybiByZW5kZXJfdGVtcGxhdGUoJ2xvZ2luLmh0bWwnLCBlcnJvcj1lcnJvcikKCgpAYXBwLnJvdXRlKCcvbG9nb3V0JykKZGVmIGxvZ291dCgpOgogICAgc2Vzc2lvbi5jbGVhcigpCiAgICByZXR1cm4gcmVkaXJlY3QoJy9sb2dpbicpCgojIOKUgOKUgOKUgCBTY2hlbWEg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgpTUUxfVVNFUlMgPSAiIiIKQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgdXNlcnMgKAogICAgaWQgICAgICAgICAgVEVYVCBQUklNQVJZIEtFWSwKICAgIHN1Yl90b2tlbiAgIFRFWFQgVU5JUVVFIE5PVCBOVUxMLAogICAgdXNlcm5hbWUgICAgVEVYVCBOT1QgTlVMTCBERUZBVUxUICcnLAogICAgZGlzcGxheV9uYW1lIFRFWFQgTk9UIE5VTEwgREVGQVVMVCAnVXNlcicsCiAgICBlbmFibGVkICAgICBJTlRFR0VSIE5PVCBOVUxMIERFRkFVTFQgMSwKICAgIGV4cGlyZXNfYXQgIFRFWFQgTk9UIE5VTEwsCiAgICB0cmFmZmljX2xpbWl0IElOVEVHRVIgTk9UIE5VTEwgREVGQVVMVCAwLAogICAgdHJhZmZpY191c2VkICBJTlRFR0VSIE5PVCBOVUxMIERFRkFVTFQgMCwKICAgIGRldmljZV9saW1pdCAgSU5URUdFUiBOT1QgTlVMTCBERUZBVUxUIDAsCiAgICBpbnN0YWxsX2lkcyBURVhUIE5PVCBOVUxMIERFRkFVTFQgJycsCiAgICBub2RlX2lkcyAgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJycsCiAgICB0YWdzICAgICAgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJycsCiAgICBub3RlICAgICAgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJycsCiAgICBjcmVhdGVkX2F0ICBURVhUIE5PVCBOVUxMLAogICAgdXBkYXRlZF9hdCAgVEVYVCBOT1QgTlVMTAopIiIiCgpTUUxfTk9ERVMgPSAiIiIKQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgbm9kZXMgKAogICAgaWQgICAgICAgICAgVEVYVCBQUklNQVJZIEtFWSwKICAgIG5hbWUgICAgICAgIFRFWFQgTk9UIE5VTEwgREVGQVVMVCAnJywKICAgIHVybCAgICAgICAgIFRFWFQgTk9UIE5VTEwgREVGQVVMVCAnJywKICAgIGVuYWJsZWQgICAgIElOVEVHRVIgTk9UIE5VTEwgREVGQVVMVCAxLAogICAgdGFnICAgICAgICAgVEVYVCBOT1QgTlVMTCBERUZBVUxUICcnLAogICAgY3JlYXRlZF9hdCAgVEVYVCBOT1QgTlVMTCwKICAgIGxhc3Rfc3RhdHVzIFRFWFQgTk9UIE5VTEwgREVGQVVMVCAndW5rbm93bicsCiAgICByYXdfY29uZmlnICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJycsCiAgICBub2RlX3R5cGUgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJ3VybCcKKSIiIgoKU1FMX1NFVFRJTkdTID0gIiIiCkNSRUFURSBUQUJMRSBJRiBOT1QgRVhJU1RTIHNldHRpbmdzICgKICAgIGtleSAgIFRFWFQgUFJJTUFSWSBLRVksCiAgICB2YWx1ZSBURVhUIE5PVCBOVUxMIERFRkFVTFQgJycKKSIiIgoKU1FMX0xPR1MgPSAiIiIKQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgbG9ncyAoCiAgICBpZCAgICAgIElOVEVHRVIgUFJJTUFSWSBLRVkgQVVUT0lOQ1JFTUVOVCwKICAgIHVzZXJfaWQgVEVYVCBOT1QgTlVMTCBERUZBVUxUICcnLAogICAgYWN0aW9uICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJycsCiAgICBkZXRhaWwgIFRFWFQgTk9UIE5VTEwgREVGQVVMVCAnJywKICAgIHRzICAgICAgVEVYVCBOT1QgTlVMTAopIiIiCgpERUZBVUxUX1NFVFRJTkdTID0gewogICAgJ2Jhc2VfdXJsJzogICAgICAgICAgICAgJ2h0dHA6Ly84OS4xMDcuMTAuMjA2OjEwODgnLAogICAgJ2V4cGlyZWRfY29uZmlnJzogICAgICAgJ3ZsZXNzOi8vZXhwaXJlZEA4OS4xMDcuMTAuMjA2Ojk5OTk/dHlwZT10Y3Amc2VjdXJpdHk9bm9uZSPimqDvuI8g0J/QvtC00L/QuNGB0LrQsCDQuNGB0YLQtdC60LvQsCcsCiAgICAnZ3JhY2VfZGF5cyc6ICAgICAgICAgICAnMCcsCiAgICAnZGVmYXVsdF9leHBpcmVfZGF5cyc6ICAnMzAnLAogICAgJ2RlZmF1bHRfdHJhZmZpY19nYic6ICAgJzAnLAogICAgJ3BhbmVsX3RpdGxlJzogICAgICAgICAgJ1ZQTiBTdWIgTWFuYWdlcicsCiAgICAndGdfdG9rZW4nOiAgICAgICAgICAgICAnJywKICAgICd0Z19jaGF0X2lkJzogICAgICAgICAgICcnLAp9CgoKIyDilIDilIDilIAgREIgaGVscGVycyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKCmRlZiBnZXRfZGIoKToKICAgIGNvbm4gPSBzcWxpdGUzLmNvbm5lY3QoREFUQUJBU0UpCiAgICBjb25uLnJvd19mYWN0b3J5ID0gc3FsaXRlMy5Sb3cKICAgIGNvbm4uZXhlY3V0ZSgiUFJBR01BIGpvdXJuYWxfbW9kZT1XQUwiKQogICAgcmV0dXJuIGNvbm4KCgpkZWYgaW5pdF9kYigpOgogICAgZGIgPSBnZXRfZGIoKQogICAgZGIuZXhlY3V0ZShTUUxfVVNFUlMpCiAgICBkYi5leGVjdXRlKFNRTF9OT0RFUykKICAgIGRiLmV4ZWN1dGUoU1FMX1NFVFRJTkdTKQogICAgZGIuZXhlY3V0ZShTUUxfTE9HUykKCiAgICAjIE9wdGlvbmFsIGNvbHVtbnMgYWRkZWQgaW4gdGhpcyB2ZXJzaW9uCiAgICBmb3IgY29sLCBkZm4gaW4gWwogICAgICAgICgnZGV2aWNlX2xpbWl0JywgJ0lOVEVHRVIgTk9UIE5VTEwgREVGQVVMVCAwJyksCiAgICAgICAgKCd0YWdzJywgICAgICAgICAiVEVYVCBOT1QgTlVMTCBERUZBVUxUICcnIiksCiAgICAgICAgKCdyYXdfY29uZmlnJywgICAiVEVYVCBOT1QgTlVMTCBERUZBVUxUICcnIiksCiAgICAgICAgKCdub2RlX3R5cGUnLCAgICAiVEVYVCBOT1QgTlVMTCBERUZBVUxUICd1cmwnIiksCiAgICAgICAgKCdpbnN0YWxsX2lkcycsICJURVhUIE5PVCBOVUxMIERFRkFVTFQgJyciKSwKICAgIF06CiAgICAgICAgdHJ5OgogICAgICAgICAgICBkYi5leGVjdXRlKGYnQUxURVIgVEFCTEUgdXNlcnMgQUREIENPTFVNTiB7Y29sfSB7ZGZufScpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwogICAgZm9yIGNvbCwgZGZuIGluIFsKICAgICAgICAoJ3Jhd19jb25maWcnLCAiVEVYVCBOT1QgTlVMTCBERUZBVUxUICcnIiksCiAgICAgICAgKCdub2RlX3R5cGUnLCAgIlRFWFQgTk9UIE5VTEwgREVGQVVMVCAndXJsJyIpLAogICAgXToKICAgICAgICB0cnk6CiAgICAgICAgICAgIGRiLmV4ZWN1dGUoZidBTFRFUiBUQUJMRSBub2RlcyBBREQgQ09MVU1OIHtjb2x9IHtkZm59JykKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCgogICAgIyBNaWdyYXRlIG9sZCAnc3Vic2NyaXB0aW9ucycgdGFibGUKICAgIHRhYmxlcyA9IHtyWzBdIGZvciByIGluIGRiLmV4ZWN1dGUoIlNFTEVDVCBuYW1lIEZST00gc3FsaXRlX21hc3RlciBXSEVSRSB0eXBlPSd0YWJsZSciKX0KICAgIGlmICdzdWJzY3JpcHRpb25zJyBpbiB0YWJsZXM6CiAgICAgICAgX21pZ3JhdGVfb2xkKGRiKQoKICAgIGZvciBrLCB2IGluIERFRkFVTFRfU0VUVElOR1MuaXRlbXMoKToKICAgICAgICBkYi5leGVjdXRlKCJJTlNFUlQgT1IgSUdOT1JFIElOVE8gc2V0dGluZ3MgKGtleSx2YWx1ZSkgVkFMVUVTICg/LD8pIiwgKGssIHYpKQoKICAgIGRiLmNvbW1pdCgpCiAgICBkYi5jbG9zZSgpCgoKZGVmIF9taWdyYXRlX29sZChkYik6CiAgICBleGlzdGluZ190b2tlbnMgPSB7clsnc3ViX3Rva2VuJ10gZm9yIHIgaW4gZGIuZXhlY3V0ZSgiU0VMRUNUIHN1Yl90b2tlbiBGUk9NIHVzZXJzIil9CiAgICB1cmxfdG9fbm9kZSA9IHt9CgogICAgb2xkX3N1YnMgPSBkYi5leGVjdXRlKCJTRUxFQ1QgKiBGUk9NIHN1YnNjcmlwdGlvbnMiKS5mZXRjaGFsbCgpCiAgICBub3cgPSBkYXRldGltZS5ub3coKS5pc29mb3JtYXQoKQoKICAgICMgQ29sbGVjdCBhbGwgdW5pcXVlIFVSTHMg4oaSIGNyZWF0ZSBub2RlcwogICAgZm9yIHMgaW4gb2xkX3N1YnM6CiAgICAgICAgZm9yIHVybCBpbiAoc1snZW5hYmxlZF9saW5rcyddIG9yICcnKS5zcGxpdCgnLCcpOgogICAgICAgICAgICB1cmwgPSB1cmwuc3RyaXAoKQogICAgICAgICAgICBpZiB1cmwgYW5kIHVybCBub3QgaW4gdXJsX3RvX25vZGU6CiAgICAgICAgICAgICAgICBuaWQgPSBzZWNyZXRzLnRva2VuX3VybHNhZmUoOCkKICAgICAgICAgICAgICAgIG5hbWUgPSB1cmwucnN0cmlwKCcvJykuc3BsaXQoJy8nKVstMV1bOjI0XSBvciB1cmxbOjI0XQogICAgICAgICAgICAgICAgZGIuZXhlY3V0ZSgKICAgICAgICAgICAgICAgICAgICAiSU5TRVJUIE9SIElHTk9SRSBJTlRPIG5vZGVzIChpZCxuYW1lLHVybCxlbmFibGVkLGNyZWF0ZWRfYXQpIFZBTFVFUyAoPyw/LD8sMSw/KSIsCiAgICAgICAgICAgICAgICAgICAgKG5pZCwgbmFtZSwgdXJsLCBub3cpLAogICAgICAgICAgICAgICAgKQogICAgICAgICAgICAgICAgdXJsX3RvX25vZGVbdXJsXSA9IG5pZAoKICAgICMgQ3JlYXRlIHVzZXJzIGZyb20gb2xkIHN1YnMKICAgIGZvciBzIGluIG9sZF9zdWJzOgogICAgICAgIGlmIHNbJ2lkJ10gaW4gZXhpc3RpbmdfdG9rZW5zOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIG5vZGVfaWRzID0gJywnLmpvaW4oCiAgICAgICAgICAgIHVybF90b19ub2RlW3Uuc3RyaXAoKV0KICAgICAgICAgICAgZm9yIHUgaW4gKHNbJ2VuYWJsZWRfbGlua3MnXSBvciAnJykuc3BsaXQoJywnKQogICAgICAgICAgICBpZiB1LnN0cmlwKCkgaW4gdXJsX3RvX25vZGUKICAgICAgICApCiAgICAgICAgdWlkID0gc2VjcmV0cy50b2tlbl91cmxzYWZlKDgpCiAgICAgICAgZGIuZXhlY3V0ZSgKICAgICAgICAgICAgIiIiSU5TRVJUIE9SIElHTk9SRSBJTlRPIHVzZXJzCiAgICAgICAgICAgICAgIChpZCxzdWJfdG9rZW4sdXNlcm5hbWUsZGlzcGxheV9uYW1lLGVuYWJsZWQsZXhwaXJlc19hdCwKICAgICAgICAgICAgICAgIHRyYWZmaWNfbGltaXQsdHJhZmZpY191c2VkLG5vZGVfaWRzLG5vdGUsY3JlYXRlZF9hdCx1cGRhdGVkX2F0KQogICAgICAgICAgICAgICBWQUxVRVMgKD8sPyw/LD8sPyw/LD8sPyw/LD8sPyw/KSIiIiwKICAgICAgICAgICAgKHVpZCwgc1snaWQnXSwKICAgICAgICAgICAgIChzWyduYW1lJ10gb3IgJycpLmxvd2VyKCkucmVwbGFjZSgnICcsICdfJyksIHNbJ25hbWUnXSBvciAnVXNlcicsCiAgICAgICAgICAgICBpbnQocy5nZXQoJ2VuYWJsZWQnLCAxKSksIHNbJ2V4cGlyZXNfYXQnXSwKICAgICAgICAgICAgIGludChzLmdldCgndHJhZmZpY19saW1pdCcsIDApKSwgaW50KHMuZ2V0KCd0cmFmZmljX3VzZWQnLCAwKSksCiAgICAgICAgICAgICBub2RlX2lkcywgcy5nZXQoJ25vdGUnLCAnJyksIHMuZ2V0KCdjcmVhdGVkX2F0Jywgbm93KSwgbm93KSwKICAgICAgICApCgoKZGVmIHNldHRpbmcoa2V5KToKICAgIGRiID0gZ2V0X2RiKCkKICAgIHJvdyA9IGRiLmV4ZWN1dGUoIlNFTEVDVCB2YWx1ZSBGUk9NIHNldHRpbmdzIFdIRVJFIGtleT0/IiwgKGtleSwpKS5mZXRjaG9uZSgpCiAgICBkYi5jbG9zZSgpCiAgICByZXR1cm4gcm93Wyd2YWx1ZSddIGlmIHJvdyBlbHNlIERFRkFVTFRfU0VUVElOR1MuZ2V0KGtleSwgJycpCgoKZGVmIGxvZ19pdCh1c2VyX2lkLCBhY3Rpb24sIGRldGFpbD0nJyk6CiAgICBkYiA9IGdldF9kYigpCiAgICBkYi5leGVjdXRlKCJJTlNFUlQgSU5UTyBsb2dzICh1c2VyX2lkLGFjdGlvbixkZXRhaWwsdHMpIFZBTFVFUyAoPyw/LD8sPykiLAogICAgICAgICAgICAgICAodXNlcl9pZCwgYWN0aW9uLCBkZXRhaWwsIGRhdGV0aW1lLm5vdygpLmlzb2Zvcm1hdCgpKSkKICAgIGRiLmNvbW1pdCgpCiAgICBkYi5jbG9zZSgpCgoKIyDilIDilIDilIAgRGF0YSBoZWxwZXJzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAoKZGVmIGVucmljaCh1KToKICAgIGQgPSBkaWN0KHUpCiAgICBub3cgPSBkYXRldGltZS5ub3coKQogICAgZXhwaXJlcyA9IGRhdGV0aW1lLmZyb21pc29mb3JtYXQoZFsnZXhwaXJlc19hdCddKQogICAgZ3JhY2UgPSB0aW1lZGVsdGEoZGF5cz1pbnQoc2V0dGluZygnZ3JhY2VfZGF5cycpIG9yIDApKQogICAgdGwgPSBkWyd0cmFmZmljX2xpbWl0J10KICAgIHR1ID0gZFsndHJhZmZpY191c2VkJ10KCiAgICBvdmVyX3RpbWUgICAgPSBub3cgPiBleHBpcmVzICsgZ3JhY2UKICAgIG92ZXJfdHJhZmZpYyA9IHRsID4gMCBhbmQgdHUgPj0gdGwKCiAgICBpZiBub3QgZFsnZW5hYmxlZCddOgogICAgICAgIGRbJ3N0YXR1cyddID0gJ2Rpc2FibGVkJwogICAgZWxpZiBvdmVyX3RpbWU6CiAgICAgICAgZFsnc3RhdHVzJ10gPSAnZXhwaXJlZCcKICAgIGVsaWYgb3Zlcl90cmFmZmljOgogICAgICAgIGRbJ3N0YXR1cyddID0gJ3RyYWZmaWNfZXhjZWVkZWQnCiAgICBlbHNlOgogICAgICAgIGRbJ3N0YXR1cyddID0gJ2FjdGl2ZScKCiAgICBkWydpc19ibG9ja2VkJ10gICAgICA9IGRbJ3N0YXR1cyddICE9ICdhY3RpdmUnCiAgICBkWyd0aW1lX2xlZnQnXSAgICAgICA9IHN0cihleHBpcmVzIC0gbm93KS5zcGxpdCgnLicpWzBdIGlmIG5vdyA8IGV4cGlyZXMgZWxzZSAn4oCUJwogICAgZFsndHJhZmZpY191c2VkX2diJ10gPSByb3VuZCh0dSAvIDEwMjQqKjMsIDMpCiAgICBkWyd0cmFmZmljX2xpbWl0X2diJ109IHJvdW5kKHRsIC8gMTAyNCoqMywgMikgaWYgdGwgZWxzZSAwCiAgICBkWyd0cmFmZmljX3BlcmNlbnQnXSA9IG1pbigxMDAsIHJvdW5kKHR1IC8gdGwgKiAxMDApKSBpZiB0bCBlbHNlIDAKICAgIGRbJ2V4cGlyZXNfZGlzcGxheSddID0gZFsnZXhwaXJlc19hdCddWzoxNl0ucmVwbGFjZSgnVCcsICcgJykKICAgIGRbJ2NyZWF0ZWRfZGlzcGxheSddID0gKGRbJ2NyZWF0ZWRfYXQnXSBvciAnJylbOjE2XS5yZXBsYWNlKCdUJywgJyAnKQogICAgZFsnZXhwaXJlc19pc28nXSAgICAgPSBkWydleHBpcmVzX2F0J11bOjE2XQogICAgYmFzZSA9IHNldHRpbmcoJ2Jhc2VfdXJsJykKICAgIGRbJ3N1Yl9saW5rJ10gICAgICAgID0gZiJ7YmFzZX0vc3ViL3tkWydzdWJfdG9rZW4nXX0iCgogICAgIyA9PT0g0KPRgdGC0YDQvtC50YHRgtCy0LAgPT09CiAgICBkWydpbnN0YWxsX2lkcyddICAgICAgPSBkLmdldCgnaW5zdGFsbF9pZHMnKSBvciAnJwogICAgZFsnaW5zdGFsbF9pZHNfbGlzdCddID0gW3guc3RyaXAoKSBmb3IgeCBpbiBkWydpbnN0YWxsX2lkcyddLnNwbGl0KCcsJykgaWYgeC5zdHJpcCgpXQogICAgZFsnZGV2aWNlX3VzZWQnXSAgICAgID0gbGVuKGRbJ2luc3RhbGxfaWRzX2xpc3QnXSkKCiAgICBkWyd0YWdzX2xpc3QnXSA9IFt0LnN0cmlwKCkgZm9yIHQgaW4gKGRbJ3RhZ3MnXSBvciAnJykuc3BsaXQoJywnKSBpZiB0LnN0cmlwKCldCiAgICByZXR1cm4gZAogICAgCgpkZWYgc2VydmVyX3N0YXRzKCk6CiAgICBjcHUgID0gcHN1dGlsLmNwdV9wZXJjZW50KGludGVydmFsPTAuMykKICAgIG1lbSAgPSBwc3V0aWwudmlydHVhbF9tZW1vcnkoKQogICAgZGlzayA9IHBzdXRpbC5kaXNrX3VzYWdlKCcvJykKICAgIG5ldCAgPSBwc3V0aWwubmV0X2lvX2NvdW50ZXJzKCkKICAgIHVwICAgPSBkYXRldGltZS5ub3coKSAtIGRhdGV0aW1lLmZyb210aW1lc3RhbXAocHN1dGlsLmJvb3RfdGltZSgpKQogICAgcmV0dXJuIHsKICAgICAgICAnY3B1JzogICAgICAgICAgY3B1LAogICAgICAgICdtZW1fcGVyY2VudCc6ICBtZW0ucGVyY2VudCwKICAgICAgICAnbWVtX3VzZWQnOiAgICAgcm91bmQobWVtLnVzZWQgIC8gMTAyNCoqMywgMiksCiAgICAgICAgJ21lbV90b3RhbCc6ICAgIHJvdW5kKG1lbS50b3RhbCAvIDEwMjQqKjMsIDIpLAogICAgICAgICdkaXNrX3BlcmNlbnQnOiBkaXNrLnBlcmNlbnQsCiAgICAgICAgJ2Rpc2tfdXNlZCc6ICAgIHJvdW5kKGRpc2sudXNlZCAgLyAxMDI0KiozLCAyKSwKICAgICAgICAnZGlza190b3RhbCc6ICAgcm91bmQoZGlzay50b3RhbCAvIDEwMjQqKjMsIDIpLAogICAgICAgICduZXRfc2VudCc6ICAgICByb3VuZChuZXQuYnl0ZXNfc2VudCAvIDEwMjQqKjMsIDMpLAogICAgICAgICduZXRfcmVjdic6ICAgICByb3VuZChuZXQuYnl0ZXNfcmVjdiAvIDEwMjQqKjMsIDMpLAogICAgICAgICd1cHRpbWUnOiAgICAgICBzdHIodXApLnNwbGl0KCcuJylbMF0sCiAgICB9CgoKIyDilIDilIDilIAgTWFpbiBwYWdlIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAoKQGFwcC5yb3V0ZSgnLycpCkBsb2dpbl9yZXF1aXJlZApkZWYgaW5kZXgoKToKICAgIHJldHVybiByZW5kZXJfdGVtcGxhdGUoJ2luZGV4Lmh0bWwnLCB0aXRsZT1zZXR0aW5nKCdwYW5lbF90aXRsZScpKQoKCiMg4pSA4pSA4pSAIFN0YXRzIEFQSSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKCkBhcHAucm91dGUoJy9hcGkvc3RhdHMnKQpAbG9naW5fcmVxdWlyZWQKZGVmIGFwaV9zdGF0cygpOgogICAgZGIgPSBnZXRfZGIoKQogICAgdXNlcnMgPSBbZW5yaWNoKHUpIGZvciB1IGluIGRiLmV4ZWN1dGUoIlNFTEVDVCAqIEZST00gdXNlcnMiKS5mZXRjaGFsbCgpXQogICAgZGIuY2xvc2UoKQoKICAgIGFjdGl2ZSAgPSBzdW0oMSBmb3IgdSBpbiB1c2VycyBpZiB1WydzdGF0dXMnXSA9PSAnYWN0aXZlJykKICAgIGV4cGlyZWQgPSBzdW0oMSBmb3IgdSBpbiB1c2VycyBpZiB1WydzdGF0dXMnXSA9PSAnZXhwaXJlZCcpCiAgICBkaXNhYmxlZCA9IHN1bSgxIGZvciB1IGluIHVzZXJzIGlmIHVbJ3N0YXR1cyddID09ICdkaXNhYmxlZCcpCiAgICB0b3ZlciAgID0gc3VtKDEgZm9yIHUgaW4gdXNlcnMgaWYgdVsnc3RhdHVzJ10gPT0gJ3RyYWZmaWNfZXhjZWVkZWQnKQogICAgdG90YWxfdCA9IHN1bSh1Wyd0cmFmZmljX3VzZWQnXSBmb3IgdSBpbiB1c2VycykKCiAgICBleHBpcmluZyA9IHNvcnRlZCgKICAgICAgICBbdSBmb3IgdSBpbiB1c2VycyBpZiB1WydzdGF0dXMnXSA9PSAnYWN0aXZlJyBhbmQKICAgICAgICAgZGF0ZXRpbWUuZnJvbWlzb2Zvcm1hdCh1WydleHBpcmVzX2F0J10pIC0gZGF0ZXRpbWUubm93KCkgPCB0aW1lZGVsdGEoZGF5cz03KV0sCiAgICAgICAga2V5PWxhbWJkYSB4OiB4WydleHBpcmVzX2F0J10KICAgIClbOjVdCgogICAgcmV0dXJuIGpzb25pZnkoewogICAgICAgICdzZXJ2ZXInOiBzZXJ2ZXJfc3RhdHMoKSwKICAgICAgICAndXNlcnMnOiB7CiAgICAgICAgICAgICd0b3RhbCc6IGxlbih1c2VycyksICdhY3RpdmUnOiBhY3RpdmUsICdleHBpcmVkJzogZXhwaXJlZCwKICAgICAgICAgICAgJ2Rpc2FibGVkJzogZGlzYWJsZWQsICd0cmFmZmljX2V4Y2VlZGVkJzogdG92ZXIsCiAgICAgICAgfSwKICAgICAgICAndHJhZmZpY190b3RhbF9nYic6IHJvdW5kKHRvdGFsX3QgLyAxMDI0KiozLCAyKSwKICAgICAgICAnZXhwaXJpbmdfc29vbic6IGV4cGlyaW5nLAogICAgfSkKCgojIOKUgOKUgOKUgCBVc2VycyBBUEkg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgpAYXBwLnJvdXRlKCcvYXBpL3VzZXJzJywgbWV0aG9kcz1bJ0dFVCddKQpAbG9naW5fcmVxdWlyZWQKZGVmIGFwaV91c2Vyc19saXN0KCk6CiAgICBzZWFyY2ggID0gcmVxdWVzdC5hcmdzLmdldCgncScsICcnKS5sb3dlcigpLnN0cmlwKCkKICAgIHN0YXR1cyAgPSByZXF1ZXN0LmFyZ3MuZ2V0KCdzdGF0dXMnLCAnYWxsJykKICAgIHNvcnQgICAgPSByZXF1ZXN0LmFyZ3MuZ2V0KCdzb3J0JywgJ2NyZWF0ZWRfYXQnKQogICAgb3JkZXIgICA9IHJlcXVlc3QuYXJncy5nZXQoJ29yZGVyJywgJ2Rlc2MnKQogICAgcGFnZSAgICA9IGludChyZXF1ZXN0LmFyZ3MuZ2V0KCdwYWdlJywgMSkpCiAgICBwZXIgICAgID0gaW50KHJlcXVlc3QuYXJncy5nZXQoJ3BlcicsIDI1KSkKCiAgICBkYiA9IGdldF9kYigpCiAgICByb3dzID0gZGIuZXhlY3V0ZSgiU0VMRUNUICogRlJPTSB1c2VycyIpLmZldGNoYWxsKCkKICAgIGRiLmNsb3NlKCkKCiAgICB1c2VycyA9IFtlbnJpY2godSkgZm9yIHUgaW4gcm93c10KCiAgICBpZiBzZWFyY2g6CiAgICAgICAgdXNlcnMgPSBbdSBmb3IgdSBpbiB1c2VycyBpZiBzZWFyY2ggaW4gdVsnZGlzcGxheV9uYW1lJ10ubG93ZXIoKQogICAgICAgICAgICAgICAgIG9yIHNlYXJjaCBpbiB1Wyd1c2VybmFtZSddLmxvd2VyKCkKICAgICAgICAgICAgICAgICBvciBzZWFyY2ggaW4gKHVbJ3RhZ3MnXSBvciAnJykubG93ZXIoKQogICAgICAgICAgICAgICAgIG9yIHNlYXJjaCBpbiAodVsnbm90ZSddIG9yICcnKS5sb3dlcigpXQogICAgaWYgc3RhdHVzICE9ICdhbGwnOgogICAgICAgIHVzZXJzID0gW3UgZm9yIHUgaW4gdXNlcnMgaWYgdVsnc3RhdHVzJ10gPT0gc3RhdHVzXQoKICAgIHJldmVyc2UgPSBvcmRlciA9PSAnZGVzYycKICAgIHNvcnRfbWFwID0gewogICAgICAgICduYW1lJzogICAgICAgICBsYW1iZGEgdTogdVsnZGlzcGxheV9uYW1lJ10ubG93ZXIoKSwKICAgICAgICAnZXhwaXJlc19hdCc6ICAgbGFtYmRhIHU6IHVbJ2V4cGlyZXNfYXQnXSwKICAgICAgICAnY3JlYXRlZF9hdCc6ICAgbGFtYmRhIHU6IHVbJ2NyZWF0ZWRfYXQnXSwKICAgICAgICAndHJhZmZpY191c2VkJzogbGFtYmRhIHU6IHVbJ3RyYWZmaWNfdXNlZCddLAogICAgICAgICdzdGF0dXMnOiAgICAgICBsYW1iZGEgdTogdVsnc3RhdHVzJ10sCiAgICB9CiAgICB1c2Vycy5zb3J0KGtleT1zb3J0X21hcC5nZXQoc29ydCwgc29ydF9tYXBbJ2NyZWF0ZWRfYXQnXSksIHJldmVyc2U9cmV2ZXJzZSkKCiAgICB0b3RhbCAgPSBsZW4odXNlcnMpCiAgICBzdGFydCAgPSAocGFnZSAtIDEpICogcGVyCiAgICBwYWdlZCAgPSB1c2Vyc1tzdGFydDpzdGFydCArIHBlcl0KCiAgICByZXR1cm4ganNvbmlmeSh7J3VzZXJzJzogcGFnZWQsICd0b3RhbCc6IHRvdGFsLCAncGFnZSc6IHBhZ2UsICdwZXInOiBwZXJ9KQoKCkBhcHAucm91dGUoJy9hcGkvdXNlcnMnLCBtZXRob2RzPVsnUE9TVCddKQpAbG9naW5fcmVxdWlyZWQKZGVmIGFwaV91c2VyX2NyZWF0ZSgpOgogICAgZCA9IHJlcXVlc3QuanNvbiBvciB7fQogICAgbm93ID0gZGF0ZXRpbWUubm93KCkuaXNvZm9ybWF0KCkKCiAgICAjINCh0YDQvtC6INC00LXQudGB0YLQstC40Y8KICAgIGV4cGlyZV9kYXlzID0gaW50KGQuZ2V0KCdleHBpcmVfZGF5cycpIG9yIHNldHRpbmcoJ2RlZmF1bHRfZXhwaXJlX2RheXMnKSBvciAzMCkKICAgIGV4cGlyZXNfZHQgPSBkLmdldCgnZXhwaXJlc19hdCcpIG9yIChkYXRldGltZS5ub3coKSArIHRpbWVkZWx0YShkYXlzPWV4cGlyZV9kYXlzKSkuaXNvZm9ybWF0KCkKCiAgICAjINCb0LjQvNC40YIg0YLRgNCw0YTQuNC60LAKICAgIHRsX2diID0gZmxvYXQoZC5nZXQoJ3RyYWZmaWNfbGltaXRfZ2InKSBvciBzZXR0aW5nKCdkZWZhdWx0X3RyYWZmaWNfZ2InKSBvciAwKQogICAgdHJhZmZpY19saW1pdCA9IGludCh0bF9nYiAqIDEwMjQqKjMpCgogICAgdWlkID0gc2VjcmV0cy50b2tlbl91cmxzYWZlKDgpCiAgICBzdWJfdG9rID0gc2VjcmV0cy50b2tlbl91cmxzYWZlKDE2KQogICAgbmFtZSA9IGQuZ2V0KCdkaXNwbGF5X25hbWUnKSBvciAnVXNlcicKICAgIHVzZXJuYW1lID0gZC5nZXQoJ3VzZXJuYW1lJykgb3IgbmFtZS5sb3dlcigpLnJlcGxhY2UoJyAnLCAnXycpCgogICAgZGIgPSBnZXRfZGIoKQogICAgZGIuZXhlY3V0ZSgKICAgICAgICAiIiJJTlNFUlQgSU5UTyB1c2VycyAKICAgICAgICAgICAoaWQsIHN1Yl90b2tlbiwgdXNlcm5hbWUsIGRpc3BsYXlfbmFtZSwgZW5hYmxlZCwgZXhwaXJlc19hdCwKICAgICAgICAgICAgdHJhZmZpY19saW1pdCwgdHJhZmZpY191c2VkLCBkZXZpY2VfbGltaXQsIGluc3RhbGxfaWRzLAogICAgICAgICAgICBub2RlX2lkcywgdGFncywgbm90ZSwgY3JlYXRlZF9hdCwgdXBkYXRlZF9hdCkKICAgICAgICAgICBWQUxVRVMgKD8sPyw/LD8sMSw/LD8sMCwnJyw/LD8sPyw/LD8sPykiIiIsCiAgICAgICAgKAogICAgICAgICAgICB1aWQsCiAgICAgICAgICAgIHN1Yl90b2ssCiAgICAgICAgICAgIHVzZXJuYW1lLAogICAgICAgICAgICBuYW1lLAogICAgICAgICAgICBleHBpcmVzX2R0LAogICAgICAgICAgICB0cmFmZmljX2xpbWl0LAogICAgICAgICAgICBpbnQoZC5nZXQoJ2RldmljZV9saW1pdCcpIG9yIDApLAogICAgICAgICAgICAnLCcuam9pbihkLmdldCgnbm9kZV9pZHMnKSBvciBbXSksCiAgICAgICAgICAgIGQuZ2V0KCd0YWdzJykgb3IgJycsCiAgICAgICAgICAgIGQuZ2V0KCdub3RlJykgb3IgJycsCiAgICAgICAgICAgIG5vdywKICAgICAgICAgICAgbm93CiAgICAgICAgKSwKICAgICkKICAgIGRiLmNvbW1pdCgpCgogICAgdXNlciA9IGVucmljaChkYi5leGVjdXRlKCJTRUxFQ1QgKiBGUk9NIHVzZXJzIFdIRVJFIGlkPT8iLCAodWlkLCkpLmZldGNob25lKCkpCiAgICBkYi5jbG9zZSgpCgogICAgbG9nX2l0KHVpZCwgJ2NyZWF0ZScsIGYiVXNlciAne25hbWV9JyBjcmVhdGVkIikKICAgIHJldHVybiBqc29uaWZ5KHVzZXIpLCAyMDEKCkBhcHAucm91dGUoJy9hcGkvdXNlcnMvPHVpZD4nLCBtZXRob2RzPVsnR0VUJ10pCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX3VzZXJfZ2V0KHVpZCk6CiAgICBkYiA9IGdldF9kYigpCiAgICByb3cgPSBkYi5leGVjdXRlKCJTRUxFQ1QgKiBGUk9NIHVzZXJzIFdIRVJFIGlkPT8iLCAodWlkLCkpLmZldGNob25lKCkKICAgIGRiLmNsb3NlKCkKICAgIGlmIG5vdCByb3c6CiAgICAgICAgcmV0dXJuIGpzb25pZnkoeydlcnJvcic6ICdub3QgZm91bmQnfSksIDQwNAogICAgcmV0dXJuIGpzb25pZnkoZW5yaWNoKHJvdykpCgoKQGFwcC5yb3V0ZSgnL2FwaS91c2Vycy88dWlkPicsIG1ldGhvZHM9WydQVVQnXSkKQGxvZ2luX3JlcXVpcmVkCmRlZiBhcGlfdXNlcl91cGRhdGUodWlkKToKICAgIGQgPSByZXF1ZXN0Lmpzb24gb3Ige30KICAgIG5vdyA9IGRhdGV0aW1lLm5vdygpLmlzb2Zvcm1hdCgpCgogICAgZGIgPSBnZXRfZGIoKQogICAgcm93ID0gZGIuZXhlY3V0ZSgiU0VMRUNUICogRlJPTSB1c2VycyBXSEVSRSBpZD0/IiwgKHVpZCwpKS5mZXRjaG9uZSgpCiAgICBpZiBub3Qgcm93OgogICAgICAgIGRiLmNsb3NlKCkKICAgICAgICByZXR1cm4ganNvbmlmeSh7J2Vycm9yJzogJ25vdCBmb3VuZCd9KSwgNDA0CgogICAgdGxfZ2IgPSBmbG9hdChkLmdldCgndHJhZmZpY19saW1pdF9nYicpIG9yIDApCiAgICB0cmFmZmljX2xpbWl0ID0gaW50KHRsX2diICogMTAyNCoqMykKCiAgICAjINCf0L7QtNC00LXRgNC20LrQsCDQvtCx0L3QvtCy0LvQtdC90LjRjyBpbnN0YWxsX2lkcyAo0LzQvtC20L3QviDQv9C10YDQtdC00LDRgtGMINC/0YPRgdGC0YPRjiDRgdGC0YDQvtC60YMg0LTQu9GPINGB0LHRgNC+0YHQsCkKICAgIGluc3RhbGxfaWRzID0gZC5nZXQoJ2luc3RhbGxfaWRzJykKICAgIGlmIGluc3RhbGxfaWRzIGlzIG5vdCBOb25lOgogICAgICAgIGluc3RhbGxfaWRzID0gaW5zdGFsbF9pZHMuc3RyaXAoKQoKICAgIGRiLmV4ZWN1dGUoCiAgICAgICAgIiIiVVBEQVRFIHVzZXJzIFNFVAogICAgICAgICAgIGRpc3BsYXlfbmFtZT0/LCB1c2VybmFtZT0/LCBlbmFibGVkPT8sIGV4cGlyZXNfYXQ9PywKICAgICAgICAgICB0cmFmZmljX2xpbWl0PT8sIGRldmljZV9saW1pdD0/LCBub2RlX2lkcz0/LCB0YWdzPT8sIG5vdGU9PywgCiAgICAgICAgICAgaW5zdGFsbF9pZHM9PywgdXBkYXRlZF9hdD0/CiAgICAgICAgICAgV0hFUkUgaWQ9PyIiIiwKICAgICAgICAoCiAgICAgICAgICAgIGQuZ2V0KCdkaXNwbGF5X25hbWUnLCByb3dbJ2Rpc3BsYXlfbmFtZSddKSwKICAgICAgICAgICAgZC5nZXQoJ3VzZXJuYW1lJywgcm93Wyd1c2VybmFtZSddKSwKICAgICAgICAgICAgaW50KGQuZ2V0KCdlbmFibGVkJywgcm93WydlbmFibGVkJ10pKSwKICAgICAgICAgICAgZC5nZXQoJ2V4cGlyZXNfYXQnLCByb3dbJ2V4cGlyZXNfYXQnXSksCiAgICAgICAgICAgIHRyYWZmaWNfbGltaXQsCiAgICAgICAgICAgIGludChkLmdldCgnZGV2aWNlX2xpbWl0Jykgb3IgMCksCiAgICAgICAgICAgICcsJy5qb2luKGQuZ2V0KCdub2RlX2lkcycpIG9yIHJvd1snbm9kZV9pZHMnXS5zcGxpdCgnLCcpKSwKICAgICAgICAgICAgZC5nZXQoJ3RhZ3MnLCByb3dbJ3RhZ3MnXSksCiAgICAgICAgICAgIGQuZ2V0KCdub3RlJywgcm93Wydub3RlJ10pLAogICAgICAgICAgICBpbnN0YWxsX2lkcyBpZiBpbnN0YWxsX2lkcyBpcyBub3QgTm9uZSBlbHNlIHJvd1snaW5zdGFsbF9pZHMnXSwKICAgICAgICAgICAgbm93LCB1aWQKICAgICAgICApLAogICAgKQogICAgZGIuY29tbWl0KCkKICAgIHVzZXIgPSBlbnJpY2goZGIuZXhlY3V0ZSgiU0VMRUNUICogRlJPTSB1c2VycyBXSEVSRSBpZD0/IiwgKHVpZCwpKS5mZXRjaG9uZSgpKQogICAgZGIuY2xvc2UoKQogICAgbG9nX2l0KHVpZCwgJ3VwZGF0ZScsIGYiVXNlciAne3VzZXJbJ2Rpc3BsYXlfbmFtZSddfScgdXBkYXRlZCIpCiAgICByZXR1cm4ganNvbmlmeSh1c2VyKQoKCkBhcHAucm91dGUoJy9hcGkvdXNlcnMvPHVpZD4nLCBtZXRob2RzPVsnREVMRVRFJ10pCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX3VzZXJfZGVsZXRlKHVpZCk6CiAgICBkYiA9IGdldF9kYigpCiAgICByb3cgPSBkYi5leGVjdXRlKCJTRUxFQ1QgZGlzcGxheV9uYW1lIEZST00gdXNlcnMgV0hFUkUgaWQ9PyIsICh1aWQsKSkuZmV0Y2hvbmUoKQogICAgZGIuZXhlY3V0ZSgiREVMRVRFIEZST00gdXNlcnMgV0hFUkUgaWQ9PyIsICh1aWQsKSkKICAgIGRiLmNvbW1pdCgpCiAgICBkYi5jbG9zZSgpCiAgICBpZiByb3c6CiAgICAgICAgbG9nX2l0KHVpZCwgJ2RlbGV0ZScsIGYiVXNlciAne3Jvd1snZGlzcGxheV9uYW1lJ119JyBkZWxldGVkIikKICAgIHJldHVybiBqc29uaWZ5KHsnb2snOiBUcnVlfSkKCgpAYXBwLnJvdXRlKCcvYXBpL3VzZXJzLzx1aWQ+L2V4dGVuZCcsIG1ldGhvZHM9WydQT1NUJ10pCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX3VzZXJfZXh0ZW5kKHVpZCk6CiAgICBkID0gcmVxdWVzdC5qc29uIG9yIHt9CiAgICBkYXlzID0gaW50KGQuZ2V0KCdkYXlzJykgb3IgMzApCiAgICBob3VycyA9IGludChkLmdldCgnaG91cnMnKSBvciAwKQoKICAgIGRiID0gZ2V0X2RiKCkKICAgIHJvdyA9IGRiLmV4ZWN1dGUoIlNFTEVDVCAqIEZST00gdXNlcnMgV0hFUkUgaWQ9PyIsICh1aWQsKSkuZmV0Y2hvbmUoKQogICAgaWYgbm90IHJvdzoKICAgICAgICBkYi5jbG9zZSgpCiAgICAgICAgcmV0dXJuIGpzb25pZnkoeydlcnJvcic6ICdub3QgZm91bmQnfSksIDQwNAoKICAgIGJhc2UgPSBtYXgoZGF0ZXRpbWUuZnJvbWlzb2Zvcm1hdChyb3dbJ2V4cGlyZXNfYXQnXSksIGRhdGV0aW1lLm5vdygpKQogICAgbmV3X2V4cCA9IChiYXNlICsgdGltZWRlbHRhKGRheXM9ZGF5cywgaG91cnM9aG91cnMpKS5pc29mb3JtYXQoKQogICAgZGIuZXhlY3V0ZSgiVVBEQVRFIHVzZXJzIFNFVCBleHBpcmVzX2F0PT8sdXBkYXRlZF9hdD0/IFdIRVJFIGlkPT8iLAogICAgICAgICAgICAgICAobmV3X2V4cCwgZGF0ZXRpbWUubm93KCkuaXNvZm9ybWF0KCksIHVpZCkpCiAgICBkYi5jb21taXQoKQogICAgdXNlciA9IGVucmljaChkYi5leGVjdXRlKCJTRUxFQ1QgKiBGUk9NIHVzZXJzIFdIRVJFIGlkPT8iLCAodWlkLCkpLmZldGNob25lKCkpCiAgICBkYi5jbG9zZSgpCiAgICBsb2dfaXQodWlkLCAnZXh0ZW5kJywgZiIre2RheXN9ZCB7aG91cnN9aCDihpIgZXhwaXJlcyB7bmV3X2V4cFs6MTZdfSIpCiAgICByZXR1cm4ganNvbmlmeSh1c2VyKQoKCkBhcHAucm91dGUoJy9hcGkvdXNlcnMvPHVpZD4vdG9nZ2xlJywgbWV0aG9kcz1bJ1BPU1QnXSkKQGxvZ2luX3JlcXVpcmVkCmRlZiBhcGlfdXNlcl90b2dnbGUodWlkKToKICAgIGRiID0gZ2V0X2RiKCkKICAgIHJvdyA9IGRiLmV4ZWN1dGUoIlNFTEVDVCBlbmFibGVkLGRpc3BsYXlfbmFtZSBGUk9NIHVzZXJzIFdIRVJFIGlkPT8iLCAodWlkLCkpLmZldGNob25lKCkKICAgIGlmIG5vdCByb3c6CiAgICAgICAgZGIuY2xvc2UoKQogICAgICAgIHJldHVybiBqc29uaWZ5KHsnZXJyb3InOiAnbm90IGZvdW5kJ30pLCA0MDQKICAgIG5ld192YWwgPSAwIGlmIHJvd1snZW5hYmxlZCddIGVsc2UgMQogICAgZGIuZXhlY3V0ZSgiVVBEQVRFIHVzZXJzIFNFVCBlbmFibGVkPT8sdXBkYXRlZF9hdD0/IFdIRVJFIGlkPT8iLAogICAgICAgICAgICAgICAobmV3X3ZhbCwgZGF0ZXRpbWUubm93KCkuaXNvZm9ybWF0KCksIHVpZCkpCiAgICBkYi5jb21taXQoKQogICAgdXNlciA9IGVucmljaChkYi5leGVjdXRlKCJTRUxFQ1QgKiBGUk9NIHVzZXJzIFdIRVJFIGlkPT8iLCAodWlkLCkpLmZldGNob25lKCkpCiAgICBkYi5jbG9zZSgpCiAgICBsb2dfaXQodWlkLCAndG9nZ2xlJywgZiJ7J2VuYWJsZWQnIGlmIG5ld192YWwgZWxzZSAnZGlzYWJsZWQnfSIpCiAgICByZXR1cm4ganNvbmlmeSh1c2VyKQoKCkBhcHAucm91dGUoJy9hcGkvdXNlcnMvPHVpZD4vcmVzZXRfdHJhZmZpYycsIG1ldGhvZHM9WydQT1NUJ10pCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX3VzZXJfcmVzZXRfdHJhZmZpYyh1aWQpOgogICAgZGIgPSBnZXRfZGIoKQogICAgZGIuZXhlY3V0ZSgiVVBEQVRFIHVzZXJzIFNFVCB0cmFmZmljX3VzZWQ9MCx1cGRhdGVkX2F0PT8gV0hFUkUgaWQ9PyIsCiAgICAgICAgICAgICAgIChkYXRldGltZS5ub3coKS5pc29mb3JtYXQoKSwgdWlkKSkKICAgIGRiLmNvbW1pdCgpCiAgICB1c2VyID0gZW5yaWNoKGRiLmV4ZWN1dGUoIlNFTEVDVCAqIEZST00gdXNlcnMgV0hFUkUgaWQ9PyIsICh1aWQsKSkuZmV0Y2hvbmUoKSkKICAgIGRiLmNsb3NlKCkKICAgIGxvZ19pdCh1aWQsICdyZXNldF90cmFmZmljJywgJ1RyYWZmaWMgY291bnRlciByZXNldCB0byAwJykKICAgIHJldHVybiBqc29uaWZ5KHVzZXIpCgoKQGFwcC5yb3V0ZSgnL2FwaS91c2Vycy88dWlkPi9jbG9uZScsIG1ldGhvZHM9WydQT1NUJ10pCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX3VzZXJfY2xvbmUodWlkKToKICAgIGRiID0gZ2V0X2RiKCkKICAgIHNyYyA9IGRiLmV4ZWN1dGUoIlNFTEVDVCAqIEZST00gdXNlcnMgV0hFUkUgaWQ9PyIsICh1aWQsKSkuZmV0Y2hvbmUoKQogICAgaWYgbm90IHNyYzoKICAgICAgICBkYi5jbG9zZSgpCiAgICAgICAgcmV0dXJuIGpzb25pZnkoeydlcnJvcic6ICdub3QgZm91bmQnfSksIDQwNAoKICAgIG5vdyA9IGRhdGV0aW1lLm5vdygpLmlzb2Zvcm1hdCgpCiAgICBuZXdfaWQgPSBzZWNyZXRzLnRva2VuX3VybHNhZmUoOCkKICAgIG5ld190b2sgPSBzZWNyZXRzLnRva2VuX3VybHNhZmUoMTYpCiAgICBuZXdfbmFtZSA9IHNyY1snZGlzcGxheV9uYW1lJ10gKyAnIChjb3B5KScKCiAgICBkYi5leGVjdXRlKAogICAgICAgICIiIklOU0VSVCBJTlRPIHVzZXJzCiAgICAgICAgICAgKGlkLCBzdWJfdG9rZW4sIHVzZXJuYW1lLCBkaXNwbGF5X25hbWUsIGVuYWJsZWQsIGV4cGlyZXNfYXQsCiAgICAgICAgICAgIHRyYWZmaWNfbGltaXQsIHRyYWZmaWNfdXNlZCwgZGV2aWNlX2xpbWl0LCBpbnN0YWxsX2lkcywKICAgICAgICAgICAgbm9kZV9pZHMsIHRhZ3MsIG5vdGUsIGNyZWF0ZWRfYXQsIHVwZGF0ZWRfYXQpCiAgICAgICAgICAgVkFMVUVTICg/LD8sPyw/LD8sPyw/LDAsJycsPyw/LD8sPyw/LD8pIiIiLAogICAgICAgICgKICAgICAgICAgICAgbmV3X2lkLCBuZXdfdG9rLAogICAgICAgICAgICBzcmNbJ3VzZXJuYW1lJ10gKyAnX2NvcHknLCBuZXdfbmFtZSwKICAgICAgICAgICAgc3JjWydlbmFibGVkJ10sIHNyY1snZXhwaXJlc19hdCddLCBzcmNbJ3RyYWZmaWNfbGltaXQnXSwKICAgICAgICAgICAgc3JjWydkZXZpY2VfbGltaXQnXSwKICAgICAgICAgICAgc3JjWydub2RlX2lkcyddLCBzcmNbJ3RhZ3MnXSwgc3JjWydub3RlJ10sCiAgICAgICAgICAgIG5vdywgbm93CiAgICAgICAgKSwKICAgICkKICAgIGRiLmNvbW1pdCgpCiAgICB1c2VyID0gZW5yaWNoKGRiLmV4ZWN1dGUoIlNFTEVDVCAqIEZST00gdXNlcnMgV0hFUkUgaWQ9PyIsIChuZXdfaWQsKSkuZmV0Y2hvbmUoKSkKICAgIGRiLmNsb3NlKCkKICAgIGxvZ19pdChuZXdfaWQsICdjbG9uZScsIGYiQ2xvbmVkIGZyb20ge3VpZH0iKQogICAgcmV0dXJuIGpzb25pZnkodXNlciksIDIwMQoKIyDilIDilIDilIAgQnVsayBvcGVyYXRpb25zIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAoKQGFwcC5yb3V0ZSgnL2FwaS9idWxrJywgbWV0aG9kcz1bJ1BPU1QnXSkKQGxvZ2luX3JlcXVpcmVkCmRlZiBhcGlfYnVsaygpOgogICAgZCA9IHJlcXVlc3QuanNvbiBvciB7fQogICAgaWRzICAgID0gZC5nZXQoJ2lkcycsIFtdKQogICAgYWN0aW9uID0gZC5nZXQoJ2FjdGlvbicsICcnKQogICAgbm93ID0gZGF0ZXRpbWUubm93KCkuaXNvZm9ybWF0KCkKCiAgICBpZiBub3QgaWRzIG9yIG5vdCBhY3Rpb246CiAgICAgICAgcmV0dXJuIGpzb25pZnkoeydlcnJvcic6ICdpZHMgYW5kIGFjdGlvbiByZXF1aXJlZCd9KSwgNDAwCgogICAgZGIgPSBnZXRfZGIoKQogICAgYWZmZWN0ZWQgPSAwCiAgICBmb3IgdWlkIGluIGlkczoKICAgICAgICByb3cgPSBkYi5leGVjdXRlKCJTRUxFQ1QgKiBGUk9NIHVzZXJzIFdIRVJFIGlkPT8iLCAodWlkLCkpLmZldGNob25lKCkKICAgICAgICBpZiBub3Qgcm93OgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGlmIGFjdGlvbiA9PSAnZW5hYmxlJzoKICAgICAgICAgICAgZGIuZXhlY3V0ZSgiVVBEQVRFIHVzZXJzIFNFVCBlbmFibGVkPTEsdXBkYXRlZF9hdD0/IFdIRVJFIGlkPT8iLCAobm93LCB1aWQpKQogICAgICAgIGVsaWYgYWN0aW9uID09ICdkaXNhYmxlJzoKICAgICAgICAgICAgZGIuZXhlY3V0ZSgiVVBEQVRFIHVzZXJzIFNFVCBlbmFibGVkPTAsdXBkYXRlZF9hdD0/IFdIRVJFIGlkPT8iLCAobm93LCB1aWQpKQogICAgICAgIGVsaWYgYWN0aW9uID09ICdkZWxldGUnOgogICAgICAgICAgICBkYi5leGVjdXRlKCJERUxFVEUgRlJPTSB1c2VycyBXSEVSRSBpZD0/IiwgKHVpZCwpKQogICAgICAgIGVsaWYgYWN0aW9uID09ICdleHRlbmRfMzAnOgogICAgICAgICAgICBiYXNlID0gbWF4KGRhdGV0aW1lLmZyb21pc29mb3JtYXQocm93WydleHBpcmVzX2F0J10pLCBkYXRldGltZS5ub3coKSkKICAgICAgICAgICAgZGIuZXhlY3V0ZSgiVVBEQVRFIHVzZXJzIFNFVCBleHBpcmVzX2F0PT8sdXBkYXRlZF9hdD0/IFdIRVJFIGlkPT8iLAogICAgICAgICAgICAgICAgICAgICAgICgoYmFzZSArIHRpbWVkZWx0YShkYXlzPTMwKSkuaXNvZm9ybWF0KCksIG5vdywgdWlkKSkKICAgICAgICBlbGlmIGFjdGlvbiA9PSAncmVzZXRfdHJhZmZpYyc6CiAgICAgICAgICAgIGRiLmV4ZWN1dGUoIlVQREFURSB1c2VycyBTRVQgdHJhZmZpY191c2VkPTAsdXBkYXRlZF9hdD0/IFdIRVJFIGlkPT8iLCAobm93LCB1aWQpKQogICAgICAgIGFmZmVjdGVkICs9IDEKICAgIGRiLmNvbW1pdCgpCiAgICBkYi5jbG9zZSgpCiAgICBsb2dfaXQoJycsIGYnYnVsa197YWN0aW9ufScsIGYne2FmZmVjdGVkfSB1c2VycycpCiAgICByZXR1cm4ganNvbmlmeSh7J29rJzogVHJ1ZSwgJ2FmZmVjdGVkJzogYWZmZWN0ZWR9KQoKCiMg4pSA4pSA4pSAIE5vZGVzIEFQSSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKCkBhcHAucm91dGUoJy9hcGkvbm9kZXMnLCBtZXRob2RzPVsnR0VUJ10pCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX25vZGVzX2xpc3QoKToKICAgIGRiID0gZ2V0X2RiKCkKICAgIG5vZGVzID0gW2RpY3QobikgZm9yIG4gaW4gZGIuZXhlY3V0ZSgiU0VMRUNUICogRlJPTSBub2RlcyBPUkRFUiBCWSBjcmVhdGVkX2F0IERFU0MiKS5mZXRjaGFsbCgpXQogICAgZGIuY2xvc2UoKQogICAgcmV0dXJuIGpzb25pZnkobm9kZXMpCgoKQGFwcC5yb3V0ZSgnL2FwaS9ub2RlcycsIG1ldGhvZHM9WydQT1NUJ10pCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX25vZGVfY3JlYXRlKCk6CiAgICBkID0gcmVxdWVzdC5qc29uIG9yIHt9CiAgICBuaWQgPSBzZWNyZXRzLnRva2VuX3VybHNhZmUoOCkKICAgIG5vdyA9IGRhdGV0aW1lLm5vdygpLmlzb2Zvcm1hdCgpCiAgICBub2RlX3R5cGUgPSBkLmdldCgnbm9kZV90eXBlJywgJ3VybCcpCiAgICBkYiA9IGdldF9kYigpCiAgICBkYi5leGVjdXRlKAogICAgICAgICJJTlNFUlQgSU5UTyBub2RlcyAoaWQsbmFtZSx1cmwsZW5hYmxlZCx0YWcsY3JlYXRlZF9hdCxsYXN0X3N0YXR1cyxyYXdfY29uZmlnLG5vZGVfdHlwZSkgVkFMVUVTICg/LD8sPywxLD8sPywndW5rbm93bicsPyw/KSIsCiAgICAgICAgKG5pZCwgZC5nZXQoJ25hbWUnLCAnJyksIGQuZ2V0KCd1cmwnLCAnJyksIGQuZ2V0KCd0YWcnLCAnJyksIG5vdywgZC5nZXQoJ3Jhd19jb25maWcnLCAnJyksIG5vZGVfdHlwZSksCiAgICApCiAgICBkYi5jb21taXQoKQogICAgbm9kZSA9IGRpY3QoZGIuZXhlY3V0ZSgiU0VMRUNUICogRlJPTSBub2RlcyBXSEVSRSBpZD0/IiwgKG5pZCwpKS5mZXRjaG9uZSgpKQogICAgZGIuY2xvc2UoKQogICAgbG9nX2l0KCcnLCAnbm9kZV9jcmVhdGUnLCBmIk5vZGUgJ3tub2RlWyduYW1lJ119JyBhZGRlZCIpCiAgICByZXR1cm4ganNvbmlmeShub2RlKSwgMjAxCgoKQGFwcC5yb3V0ZSgnL2FwaS9ub2Rlcy88bmlkPicsIG1ldGhvZHM9WydQVVQnXSkKQGxvZ2luX3JlcXVpcmVkCmRlZiBhcGlfbm9kZV91cGRhdGUobmlkKToKICAgIGQgPSByZXF1ZXN0Lmpzb24gb3Ige30KICAgIGRiID0gZ2V0X2RiKCkKICAgIGRiLmV4ZWN1dGUoCiAgICAgICAgIlVQREFURSBub2RlcyBTRVQgbmFtZT0/LHVybD0/LGVuYWJsZWQ9Pyx0YWc9PyxyYXdfY29uZmlnPT8sbm9kZV90eXBlPT8gV0hFUkUgaWQ9PyIsCiAgICAgICAgKGQuZ2V0KCduYW1lJywgJycpLCBkLmdldCgndXJsJywgJycpLCBpbnQoZC5nZXQoJ2VuYWJsZWQnLCAxKSksCiAgICAgICAgIGQuZ2V0KCd0YWcnLCAnJyksIGQuZ2V0KCdyYXdfY29uZmlnJywgJycpLCBkLmdldCgnbm9kZV90eXBlJywgJ3VybCcpLCBuaWQpLAogICAgKQogICAgZGIuY29tbWl0KCkKICAgIG5vZGUgPSBkaWN0KGRiLmV4ZWN1dGUoIlNFTEVDVCAqIEZST00gbm9kZXMgV0hFUkUgaWQ9PyIsIChuaWQsKSkuZmV0Y2hvbmUoKSkKICAgIGRiLmNsb3NlKCkKICAgIHJldHVybiBqc29uaWZ5KG5vZGUpCgoKQGFwcC5yb3V0ZSgnL2FwaS9ub2Rlcy88bmlkPicsIG1ldGhvZHM9WydERUxFVEUnXSkKQGxvZ2luX3JlcXVpcmVkCmRlZiBhcGlfbm9kZV9kZWxldGUobmlkKToKICAgIGRiID0gZ2V0X2RiKCkKICAgIHJvdyA9IGRiLmV4ZWN1dGUoIlNFTEVDVCBuYW1lIEZST00gbm9kZXMgV0hFUkUgaWQ9PyIsIChuaWQsKSkuZmV0Y2hvbmUoKQogICAgZGIuZXhlY3V0ZSgiREVMRVRFIEZST00gbm9kZXMgV0hFUkUgaWQ9PyIsIChuaWQsKSkKICAgIGRiLmNvbW1pdCgpCiAgICBkYi5jbG9zZSgpCiAgICBpZiByb3c6CiAgICAgICAgbG9nX2l0KCcnLCAnbm9kZV9kZWxldGUnLCBmIk5vZGUgJ3tyb3dbJ25hbWUnXX0nIGRlbGV0ZWQiKQogICAgcmV0dXJuIGpzb25pZnkoeydvayc6IFRydWV9KQoKCkBhcHAucm91dGUoJy9hcGkvbm9kZXMvPG5pZD4vY2hlY2snLCBtZXRob2RzPVsnUE9TVCddKQpAbG9naW5fcmVxdWlyZWQKZGVmIGFwaV9ub2RlX2NoZWNrKG5pZCk6CiAgICBkYiA9IGdldF9kYigpCiAgICBub2RlID0gZGIuZXhlY3V0ZSgiU0VMRUNUICogRlJPTSBub2RlcyBXSEVSRSBpZD0/IiwgKG5pZCwpKS5mZXRjaG9uZSgpCiAgICBpZiBub3Qgbm9kZToKICAgICAgICBkYi5jbG9zZSgpCiAgICAgICAgcmV0dXJuIGpzb25pZnkoeydlcnJvcic6ICdub3QgZm91bmQnfSksIDQwNAogICAgdHJ5OgogICAgICAgIHIgPSByZXF1ZXN0cy5nZXQobm9kZVsndXJsJ10sIGhlYWRlcnM9eyJVc2VyLUFnZW50IjogInYycmF5TkcvMS44LjAifSwgdGltZW91dD04KQogICAgICAgIHN0YXR1cyA9ICdvaycgaWYgci5zdGF0dXNfY29kZSA9PSAyMDAgYW5kIG5vdCByLnRleHQuc3RyaXAoKS5zdGFydHN3aXRoKCc8JykgZWxzZSAnZXJyb3InCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHN0YXR1cyA9ICdlcnJvcicKICAgIGRiLmV4ZWN1dGUoIlVQREFURSBub2RlcyBTRVQgbGFzdF9zdGF0dXM9PyBXSEVSRSBpZD0/IiwgKHN0YXR1cywgbmlkKSkKICAgIGRiLmNvbW1pdCgpCiAgICBkYi5jbG9zZSgpCiAgICByZXR1cm4ganNvbmlmeSh7J3N0YXR1cyc6IHN0YXR1c30pCgoKIyDilIDilIDilIAgU2V0dGluZ3MgQVBJIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAoKQGFwcC5yb3V0ZSgnL2FwaS9zZXR0aW5ncycsIG1ldGhvZHM9WydHRVQnXSkKQGxvZ2luX3JlcXVpcmVkCmRlZiBhcGlfc2V0dGluZ3NfZ2V0KCk6CiAgICBkYiA9IGdldF9kYigpCiAgICByb3dzID0gZGIuZXhlY3V0ZSgiU0VMRUNUIGtleSx2YWx1ZSBGUk9NIHNldHRpbmdzIikuZmV0Y2hhbGwoKQogICAgZGIuY2xvc2UoKQogICAgcmV0dXJuIGpzb25pZnkoe3JbJ2tleSddOiByWyd2YWx1ZSddIGZvciByIGluIHJvd3N9KQoKCkBhcHAucm91dGUoJy9hcGkvc2V0dGluZ3MnLCBtZXRob2RzPVsnUE9TVCddKQpAbG9naW5fcmVxdWlyZWQKZGVmIGFwaV9zZXR0aW5nc19zYXZlKCk6CiAgICBkID0gcmVxdWVzdC5qc29uIG9yIHt9CiAgICBkYiA9IGdldF9kYigpCiAgICBmb3IgaywgdiBpbiBkLml0ZW1zKCk6CiAgICAgICAgZGIuZXhlY3V0ZSgiSU5TRVJUIE9SIFJFUExBQ0UgSU5UTyBzZXR0aW5ncyAoa2V5LHZhbHVlKSBWQUxVRVMgKD8sPykiLCAoaywgc3RyKHYpKSkKICAgIGRiLmNvbW1pdCgpCiAgICBkYi5jbG9zZSgpCiAgICBsb2dfaXQoJycsICdzZXR0aW5nc19zYXZlJywgJycpCiAgICByZXR1cm4ganNvbmlmeSh7J29rJzogVHJ1ZX0pCgoKIyDilIDilIDilIAgTG9ncyBBUEkg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgpAYXBwLnJvdXRlKCcvYXBpL2xvZ3MnLCBtZXRob2RzPVsnR0VUJ10pCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX2xvZ3MoKToKICAgIHBhZ2UgPSBpbnQocmVxdWVzdC5hcmdzLmdldCgncGFnZScsIDEpKQogICAgcGVyICA9IGludChyZXF1ZXN0LmFyZ3MuZ2V0KCdwZXInLCA1MCkpCiAgICBkYiAgID0gZ2V0X2RiKCkKICAgIHRvdGFsID0gZGIuZXhlY3V0ZSgiU0VMRUNUIENPVU5UKCopIEZST00gbG9ncyIpLmZldGNob25lKClbMF0KICAgIHJvd3MgID0gZGIuZXhlY3V0ZSgKICAgICAgICAiU0VMRUNUIGxvZ3MuKix1c2Vycy5kaXNwbGF5X25hbWUgRlJPTSBsb2dzIExFRlQgSk9JTiB1c2VycyBPTiBsb2dzLnVzZXJfaWQ9dXNlcnMuaWQgT1JERVIgQlkgbG9ncy5pZCBERVNDIExJTUlUID8gT0ZGU0VUID8iLAogICAgICAgIChwZXIsIChwYWdlIC0gMSkgKiBwZXIpLAogICAgKS5mZXRjaGFsbCgpCiAgICBkYi5jbG9zZSgpCiAgICByZXR1cm4ganNvbmlmeSh7J2xvZ3MnOiBbZGljdChyKSBmb3IgciBpbiByb3dzXSwgJ3RvdGFsJzogdG90YWx9KQoKCiMg4pSA4pSA4pSAIEV4cG9ydCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKCkBhcHAucm91dGUoJy9hcGkvZXhwb3J0L2NzdicpCkBsb2dpbl9yZXF1aXJlZApkZWYgYXBpX2V4cG9ydF9jc3YoKToKICAgIGRiID0gZ2V0X2RiKCkKICAgIHVzZXJzID0gW2VucmljaCh1KSBmb3IgdSBpbiBkYi5leGVjdXRlKCJTRUxFQ1QgKiBGUk9NIHVzZXJzIE9SREVSIEJZIGNyZWF0ZWRfYXQiKS5mZXRjaGFsbCgpXQogICAgZGIuY2xvc2UoKQoKICAgIGltcG9ydCBpbywgY3N2CiAgICBvdXQgPSBpby5TdHJpbmdJTygpCiAgICB3ID0gY3N2LndyaXRlcihvdXQpCiAgICB3LndyaXRlcm93KFsnbmFtZScsICd1c2VybmFtZScsICdzdGF0dXMnLCAnZXhwaXJlc19hdCcsICd0cmFmZmljX3VzZWRfZ2InLAogICAgICAgICAgICAgICAgJ3RyYWZmaWNfbGltaXRfZ2InLCAnZGV2aWNlX2xpbWl0JywgJ3RhZ3MnLCAnbm90ZScsICdzdWJfbGluaycsICdjcmVhdGVkX2F0J10pCiAgICBmb3IgdSBpbiB1c2VyczoKICAgICAgICB3LndyaXRlcm93KFt1WydkaXNwbGF5X25hbWUnXSwgdVsndXNlcm5hbWUnXSwgdVsnc3RhdHVzJ10sIHVbJ2V4cGlyZXNfYXQnXSwKICAgICAgICAgICAgICAgICAgICB1Wyd0cmFmZmljX3VzZWRfZ2InXSwgdVsndHJhZmZpY19saW1pdF9nYiddLCB1WydkZXZpY2VfbGltaXQnXSwKICAgICAgICAgICAgICAgICAgICB1Wyd0YWdzJ10sIHVbJ25vdGUnXSwgdVsnc3ViX2xpbmsnXSwgdVsnY3JlYXRlZF9hdCddXSkKICAgIG91dHB1dCA9IG91dC5nZXR2YWx1ZSgpCiAgICByZXR1cm4gUmVzcG9uc2Uob3V0cHV0LCBtaW1ldHlwZT0ndGV4dC9jc3YnLAogICAgICAgICAgICAgICAgICAgIGhlYWRlcnM9eydDb250ZW50LURpc3Bvc2l0aW9uJzogJ2F0dGFjaG1lbnQ7ZmlsZW5hbWU9dXNlcnMuY3N2J30pCgoKIyDilIDilIDilIAgU3Vic2NyaXB0aW9uIGVuZHBvaW50IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAoKQGFwcC5yb3V0ZSgnL3N1Yi88dG9rZW4+JykKZGVmIHN1YnNjcmlwdGlvbih0b2tlbik6CiAgICBpbnN0YWxsX2lkID0gcmVxdWVzdC5hcmdzLmdldCgnaW5zdGFsbGlkJywgJycpLnN0cmlwKCkKCiAgICBkYiA9IGdldF9kYigpCiAgICB1c2VyID0gZGIuZXhlY3V0ZSgiU0VMRUNUICogRlJPTSB1c2VycyBXSEVSRSBzdWJfdG9rZW49PyIsICh0b2tlbiwpKS5mZXRjaG9uZSgpCgogICAgaWYgbm90IHVzZXI6CiAgICAgICAgZGIuY2xvc2UoKQogICAgICAgIHJldHVybiBSZXNwb25zZSgiTm90IGZvdW5kIiwgc3RhdHVzPTQwNCkKCiAgICB1ID0gZW5yaWNoKHVzZXIpCgogICAgIyA9PT0g0JHQu9C+0LrQuNGA0L7QstC60LAg0L/QvtC00L/QuNGB0LrQuCA9PT0KICAgIGlmIHVbJ2lzX2Jsb2NrZWQnXToKICAgICAgICBleHBfY2ZnID0gc2V0dGluZygnZXhwaXJlZF9jb25maWcnKQogICAgICAgIGVuY29kZWQgPSBiYXNlNjQuYjY0ZW5jb2RlKGV4cF9jZmcuZW5jb2RlKCkpLmRlY29kZSgpCiAgICAgICAgcmVzcCA9IFJlc3BvbnNlKGVuY29kZWQsIG1pbWV0eXBlPSd0ZXh0L3BsYWluJykKICAgICAgICBhZGRfaGFwcF9oZWFkZXJzKHJlc3AsIHVzZXIsIDAsIDAsIGlzX2hhcHA9aXNfaGFwcF9jbGllbnQoKSkKICAgICAgICBkYi5jbG9zZSgpCiAgICAgICAgcmV0dXJuIHJlc3AKCiAgICAjID09PSDQn9GA0L7QstC10YDQutCwINC70LjQvNC40YLQsCDRg9GB0YLRgNC+0LnRgdGC0LIgKExpbWl0ZWQgTGlua3MpID09PQogICAgaWYgaW5zdGFsbF9pZCBhbmQgdS5nZXQoJ2RldmljZV9saW1pdCcsIDApID4gMDoKICAgICAgICBjdXJyZW50X2lkcyA9IHUuZ2V0KCdpbnN0YWxsX2lkc19saXN0JywgW10pCgogICAgICAgIGlmIGluc3RhbGxfaWQgbm90IGluIGN1cnJlbnRfaWRzOgogICAgICAgICAgICBpZiBsZW4oY3VycmVudF9pZHMpID49IHVbJ2RldmljZV9saW1pdCddOgogICAgICAgICAgICAgICAgZGIuY2xvc2UoKQogICAgICAgICAgICAgICAgcmV0dXJuIFJlc3BvbnNlKCJEZXZpY2UgbGltaXQgcmVhY2hlZCIsIHN0YXR1cz00MDMpCgogICAgICAgICAgICBuZXdfaWRzID0gY3VycmVudF9pZHMgKyBbaW5zdGFsbF9pZF0KICAgICAgICAgICAgZGIuZXhlY3V0ZSgKICAgICAgICAgICAgICAgICJVUERBVEUgdXNlcnMgU0VUIGluc3RhbGxfaWRzID0gPywgdXBkYXRlZF9hdCA9ID8gV0hFUkUgc3ViX3Rva2VuID0gPyIsCiAgICAgICAgICAgICAgICAoJywnLmpvaW4obmV3X2lkcyksIGRhdGV0aW1lLm5vdygpLmlzb2Zvcm1hdCgpLCB0b2tlbikKICAgICAgICAgICAgKQogICAgICAgICAgICBkYi5jb21taXQoKQoKICAgICMgPT09INCf0L7Qu9GD0YfQsNC10Lwg0L3QvtC00YsgPT09CiAgICBub2RlX2lkcyA9IFtuLnN0cmlwKCkgZm9yIG4gaW4gKHVzZXJbJ25vZGVfaWRzJ10gb3IgJycpLnNwbGl0KCcsJykgaWYgbi5zdHJpcCgpXQogICAgaWYgbm90IG5vZGVfaWRzOgogICAgICAgIGRiLmNsb3NlKCkKICAgICAgICByZXR1cm4gUmVzcG9uc2UoIiIsIG1pbWV0eXBlPSd0ZXh0L3BsYWluJykKCiAgICBub2RlcyA9IGRiLmV4ZWN1dGUoCiAgICAgICAgZiJTRUxFQ1QgKiBGUk9NIG5vZGVzIFdIRVJFIGlkIElOICh7JywnLmpvaW4oJz8nICogbGVuKG5vZGVfaWRzKSl9KSBBTkQgZW5hYmxlZD0xIiwKICAgICAgICBub2RlX2lkcywKICAgICkuZmV0Y2hhbGwoKQogICAgZGIuY2xvc2UoKQoKICAgIGFsbF9jb25maWdzID0gW10KICAgIGZldGNoZWRfYnl0ZXMgPSAwCiAgICBoZWFkZXJzID0geyJVc2VyLUFnZW50IjogInYycmF5TkcvMS44LjAifQoKICAgIGZvciBub2RlIGluIG5vZGVzOgogICAgICAgIG5vZGVfdHlwZSA9IG5vZGVbJ25vZGVfdHlwZSddIGlmICdub2RlX3R5cGUnIGluIG5vZGUua2V5cygpIGVsc2UgJ3VybCcKICAgICAgICByYXdfY29uZmlnID0gbm9kZVsncmF3X2NvbmZpZyddIGlmICdyYXdfY29uZmlnJyBpbiBub2RlLmtleXMoKSBlbHNlICcnCgogICAgICAgIGlmIG5vZGVfdHlwZSA9PSAncmF3JyBhbmQgcmF3X2NvbmZpZy5zdHJpcCgpOgogICAgICAgICAgICBhbGxfY29uZmlncy5hcHBlbmQocmF3X2NvbmZpZy5zdHJpcCgpKQogICAgICAgICAgICBjb250aW51ZQoKICAgICAgICBpZiBub3Qgbm9kZVsndXJsJ106CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgdHJ5OgogICAgICAgICAgICByID0gcmVxdWVzdHMuZ2V0KG5vZGVbJ3VybCddLCBoZWFkZXJzPWhlYWRlcnMsIHRpbWVvdXQ9MTApCiAgICAgICAgICAgIHJhdyA9IHIudGV4dC5zdHJpcCgpCiAgICAgICAgICAgIGlmIHJhdy5zdGFydHN3aXRoKCc8Jykgb3IgJzwhRE9DVFlQRScgaW4gcmF3OgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgZGVjb2RlZCA9IGJhc2U2NC5iNjRkZWNvZGUocmF3KS5kZWNvZGUoJ3V0Zi04JywgZXJyb3JzPSdpZ25vcmUnKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgZGVjb2RlZCA9IHJhdwogICAgICAgICAgICBhbGxfY29uZmlncy5hcHBlbmQoZGVjb2RlZC5zdHJpcCgpKQogICAgICAgICAgICBmZXRjaGVkX2J5dGVzICs9IGxlbihyLmNvbnRlbnQpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgY29udGludWUKCiAgICBtZXJnZWQgPSAnXG4nLmpvaW4oYWxsX2NvbmZpZ3MpCiAgICBlbmNvZGVkID0gYmFzZTY0LmI2NGVuY29kZShtZXJnZWQuZW5jb2RlKCd1dGYtOCcpKS5kZWNvZGUoJ3V0Zi04JykKCiAgICAjINCe0LHQvdC+0LLQu9GP0LXQvCDRgtGA0LDRhNC40LoKICAgIGRiMiA9IGdldF9kYigpCiAgICBkYjIuZXhlY3V0ZSgKICAgICAgICAiVVBEQVRFIHVzZXJzIFNFVCB0cmFmZmljX3VzZWQgPSB0cmFmZmljX3VzZWQgKyA/LCB1cGRhdGVkX2F0ID0gPyBXSEVSRSBzdWJfdG9rZW4gPSA/IiwKICAgICAgICAoZmV0Y2hlZF9ieXRlcywgZGF0ZXRpbWUubm93KCkuaXNvZm9ybWF0KCksIHRva2VuKQogICAgKQogICAgZGIyLmNvbW1pdCgpCiAgICBkYjIuY2xvc2UoKQoKICAgIGlzX2hhcHAgPSBpc19oYXBwX2NsaWVudCgpCgogICAgaWYgaXNfaGFwcDoKICAgICAgICByZXNwID0gUmVzcG9uc2UoZW5jb2RlZCwgbWltZXR5cGU9J3RleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgnKQogICAgICAgIGFkZF9oYXBwX2hlYWRlcnMocmVzcCwgdXNlciwgdXNlclsndHJhZmZpY191c2VkJ10sIHVzZXJbJ3RyYWZmaWNfbGltaXQnXSwgaXNfaGFwcD1UcnVlKQogICAgICAgIHJldHVybiByZXNwCgogICAgIyA9PT09PT09PT09PT09PT09PT09PSBIVE1MINGB0YLRgNCw0L3QuNGG0LAg0LTQu9GPINCx0YDQsNGD0LfQtdGA0LAgPT09PT09PT09PT09PT09PT09PT0KICAgIGhhcHBfbGluayA9IGdldF9oYXBwX2xpbmsoc2V0dGluZygnYmFzZV91cmwnKSwgdXNlclsnc3ViX3Rva2VuJ10pCiAgICBpZiBoYXBwX2xpbmsuc3RhcnRzd2l0aCgneycpOgogICAgICAgIGltcG9ydCBqc29uCiAgICAgICAgdHJ5OgogICAgICAgICAgICBoYXBwX2xpbmsgPSBqc29uLmxvYWRzKGhhcHBfbGluaykuZ2V0KCdlbmNyeXB0ZWRfbGluaycsIGhhcHBfbGluaykKICAgICAgICBleGNlcHQ6CiAgICAgICAgICAgIHBhc3MKCiAgICAjID09PSDQodGC0LDRgtGD0YEg0L3QvtC0ID09PQogICAgbm9kZV9zdGF0dXNfaHRtbCA9ICIiCiAgICBmb3Igbm9kZSBpbiBub2RlczoKICAgICAgICBuYW1lID0gbm9kZVsnbmFtZSddCiAgICAgICAgc3RhdHVzID0gbm9kZVsnbGFzdF9zdGF0dXMnXSBpZiAnbGFzdF9zdGF0dXMnIGluIG5vZGUua2V5cygpIGVsc2UgJ3Vua25vd24nCgogICAgICAgIGlmIHN0YXR1cyA9PSAnb2snOgogICAgICAgICAgICB1cHRpbWUgPSAiMTAwJSIKICAgICAgICAgICAgY29sb3IgPSAiIzIyYzU1ZSIKICAgICAgICBlbHNlOgogICAgICAgICAgICB1cHRpbWUgPSAiOTkuNSUiCiAgICAgICAgICAgIGNvbG9yID0gIiNmNTllMGIiCgogICAgICAgIGlmICJhbXlyIiBpbiBuYW1lLmxvd2VyKCk6CiAgICAgICAgICAgIG5vZGVfc3RhdHVzX2h0bWwgKz0gZiIiIgogICAgICAgICAgICAgICAgPGRpdiBzdHlsZT0ibWFyZ2luOiA4cHggMDsgcGFkZGluZzogOHB4IDEycHg7IGJhY2tncm91bmQ6IzFmMjkzNzsgYm9yZGVyLXJhZGl1czo4cHg7IGRpc3BsYXk6ZmxleDsganVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47IGFsaWduLWl0ZW1zOmNlbnRlcjsiPgogICAgICAgICAgICAgICAgICAgIDxzcGFuPjxzdHJvbmc+e25hbWV9PC9zdHJvbmc+PC9zcGFuPgogICAgICAgICAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJjb2xvcjp7Y29sb3J9OyBmb250LXdlaWdodDo2MDA7Ij57dXB0aW1lfTwvc3Bhbj4KICAgICAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICAiIiIKICAgICAgICBlbHNlOgogICAgICAgICAgICBub2RlX3N0YXR1c19odG1sICs9IGYiIiIKICAgICAgICAgICAgICAgIDxkaXYgc3R5bGU9Im1hcmdpbjogNnB4IDA7IGZvbnQtc2l6ZToxM3B4OyBjb2xvcjojYWFhOyI+CiAgICAgICAgICAgICAgICAgICAge25hbWV9OiA8c3BhbiBzdHlsZT0iY29sb3I6e2NvbG9yfTsiPnt1cHRpbWV9PC9zcGFuPgogICAgICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgICIiIgoKICAgIGh0bWwgPSBmIiIiCjwhRE9DVFlQRSBodG1sPgo8aHRtbD4KPGhlYWQ+CiAgICA8bWV0YSBjaGFyc2V0PSJVVEYtOCI+CiAgICA8dGl0bGU+QW15ciBWUE48L3RpdGxlPgogICAgPHN0eWxlPgogICAgICAgIGJvZHkge3sgZm9udC1mYW1pbHk6IHN5c3RlbS11aTsgYmFja2dyb3VuZDogIzBhMGExYTsgY29sb3I6ICNlMGUwZTA7IHBhZGRpbmc6IDMwcHggMTVweDsgfX0KICAgICAgICAuY2FyZCB7eyBtYXgtd2lkdGg6IDQ4MHB4OyBtYXJnaW46IDAgYXV0bzsgYmFja2dyb3VuZDogIzExMTEyMjsgYm9yZGVyLXJhZGl1czogMThweDsgcGFkZGluZzogMzBweDsgfX0KICAgICAgICBoMSB7eyBjb2xvcjogIzNiODJmNjsgdGV4dC1hbGlnbjogY2VudGVyOyB9fQogICAgICAgIC5idG4ge3sgZGlzcGxheTogYmxvY2s7IHdpZHRoOiAxMDAlOyBwYWRkaW5nOiAxNnB4OyBiYWNrZ3JvdW5kOiAjMjJjNTVlOyBjb2xvcjogd2hpdGU7IHRleHQtYWxpZ246IGNlbnRlcjsgdGV4dC1kZWNvcmF0aW9uOiBub25lOyBib3JkZXItcmFkaXVzOiAxMnB4OyBmb250LXdlaWdodDogNzAwOyBtYXJnaW46IDE1cHggMDsgZm9udC1zaXplOiAxNnB4OyB9fQogICAgICAgIC5saW5rLWJveCB7eyBiYWNrZ3JvdW5kOiAjMGQxMTE3OyBwYWRkaW5nOiAxMnB4OyBib3JkZXItcmFkaXVzOiAxMHB4OyBmb250LWZhbWlseTogbW9ub3NwYWNlOyBmb250LXNpemU6IDExcHg7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsgY3Vyc29yOiBwb2ludGVyOyBtYXJnaW46IDhweCAwOyB9fQogICAgICAgIC5sYWJlbCB7eyBjb2xvcjogIzg4ODsgZm9udC1zaXplOiAxM3B4OyBtYXJnaW4tYm90dG9tOiA1cHg7IH19CiAgICAgICAgLnN0YXR1cy1ib3gge3sgYmFja2dyb3VuZDogIzFhMWEyZTsgcGFkZGluZzogMTJweDsgYm9yZGVyLXJhZGl1czogMTBweDsgbWFyZ2luLXRvcDogMTVweDsgfX0KICAgIDwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8aDE+8J+agCBBbXlyIFZQTjwvaDE+CiAgICAgICAgPHAgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyOyI+PHN0cm9uZz57dVsnZGlzcGxheV9uYW1lJ119PC9zdHJvbmc+PC9wPgogICAgICAgIAogICAgICAgIDxhIGhyZWY9IntoYXBwX2xpbmt9IiBjbGFzcz0iYnRuIj7inpUg0JTQvtCx0LDQstC40YLRjCDQv9C+0LTQv9C40YHQutGDINCyIEhhcHA8L2E+CiAgICAgICAgCiAgICAgICAgPGRpdiBjbGFzcz0ibGFiZWwiPtCe0LHRi9GH0L3QsNGPINGB0YHRi9C70LrQsDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmstYm94IiBvbmNsaWNrPSJuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCgne3VbJ3N1Yl9saW5rJ119JykiPgogICAgICAgICAgICB7dVsnc3ViX2xpbmsnXX0KICAgICAgICA8L2Rpdj4KICAgICAgICAKICAgICAgICA8ZGl2IGNsYXNzPSJsYWJlbCI+0JfQsNGI0LjRhNGA0L7QstCw0L3QvdCw0Y8g0YHRgdGL0LvQutCwIChIYXBwKTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmstYm94IiBvbmNsaWNrPSJuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCgne2hhcHBfbGlua30nKSI+CiAgICAgICAgICAgIHtoYXBwX2xpbmt9CiAgICAgICAgPC9kaXY+CgogICAgICAgIDwhLS0g0KHRgtCw0YLRg9GBINC90L7QtCAtLT4KICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0dXMtYm94Ij4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEzcHg7IGNvbG9yOiM4ODg7IG1hcmdpbi1ib3R0b206OHB4OyI+0KHRgtCw0YLRg9GBINGB0LXRgNCy0LXRgNC+0LI8L2Rpdj4KICAgICAgICAgICAge25vZGVfc3RhdHVzX2h0bWwgaWYgbm9kZV9zdGF0dXNfaHRtbCBlbHNlICc8ZGl2IHN0eWxlPSJjb2xvcjojODg4OyI+0J3QvtC00Ysg0L3QtSDQvdCw0LnQtNC10L3RizwvZGl2Pid9CiAgICAgICAgPC9kaXY+CiAgICAgICAgCiAgICAgICAgPCEtLSDQodGC0LDRgtC40YHRgtC40LrQsCAtLT4KICAgICAgICA8ZGl2IHN0eWxlPSJiYWNrZ3JvdW5kOiMxYTFhMmU7IHBhZGRpbmc6MTVweDsgYm9yZGVyLXJhZGl1czoxMHB4OyBtYXJnaW4tdG9wOjE1cHg7IGZvbnQtc2l6ZToxM3B4OyI+CiAgICAgICAgICAgIDxkaXY+0JjRgdC/0L7Qu9GM0LfQvtCy0LDQvdC+OiB7dVsndHJhZmZpY191c2VkX2diJ119IC8ge3VbJ3RyYWZmaWNfbGltaXRfZ2InXX0gR0I8L2Rpdj4KICAgICAgICAgICAgPGRpdj7QntGB0YLQsNC70L7RgdGMOiB7dVsndGltZV9sZWZ0J119PC9kaXY+CiAgICAgICAgICAgIDxkaXY+0JjRgdGC0LXQutCw0LXRgjoge3VbJ2V4cGlyZXNfZGlzcGxheSddfTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CjwvYm9keT4KPC9odG1sPgogICAgIiIiCiAgICByZXR1cm4gaHRtbAoKZGVmIF9hZGRfc3ViX2hlYWRlcnMocmVzcCwgdXNlciwgdXNlZCwgdG90YWwpOgogICAgZXhwaXJlc190cyA9IGludChkYXRldGltZS5mcm9taXNvZm9ybWF0KHVzZXJbJ2V4cGlyZXNfYXQnXSkudGltZXN0YW1wKCkpCiAgICByZXNwLmhlYWRlcnNbJ3N1YnNjcmlwdGlvbi11c2VyaW5mbyddID0gKAogICAgICAgIGYidXBsb2FkPTA7IGRvd25sb2FkPXt1c2VkfTsgdG90YWw9e3RvdGFsfTsgZXhwaXJlPXtleHBpcmVzX3RzfSIKICAgICkKICAgIHRpdGxlID0gYmFzZTY0LmI2NGVuY29kZSgKICAgICAgICAodXNlclsnZGlzcGxheV9uYW1lJ10gKyAnIFZQTicpLmVuY29kZSgpCiAgICApLmRlY29kZSgpCiAgICByZXNwLmhlYWRlcnNbJ3Byb2ZpbGUtdGl0bGUnXSA9IGYiYmFzZTY0Ont0aXRsZX0iCiAgICByZXNwLmhlYWRlcnNbJ3Byb2ZpbGUtdXBkYXRlLWludGVydmFsJ10gPSAnMTInCgoKCgojIOKUgOKUgOKUgCBBZG1pbiBNYW5hZ2VtZW50IEFQSSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKCkBhcHAucm91dGUoJy9hcGkvYWRtaW4vY2hhbmdlX3Bhc3N3b3JkJywgbWV0aG9kcz1bJ1BPU1QnXSkKQGxvZ2luX3JlcXVpcmVkCmRlZiBhcGlfY2hhbmdlX3Bhc3N3b3JkKCk6CiAgICBkID0gcmVxdWVzdC5qc29uIG9yIHt9CiAgICBvbGRfcGFzcyA9IGQuZ2V0KCdvbGRfcGFzc3dvcmQnLCAnJykKICAgIG5ld19wYXNzID0gZC5nZXQoJ25ld19wYXNzd29yZCcsICcnKQogICAgbmV3X3VzZXIgPSBkLmdldCgnbmV3X3VzZXJuYW1lJywgJycpCgogICAgY2ZnID0gbG9hZF9jb25maWcoKQogICAgaWYgb2xkX3Bhc3MgIT0gY2ZnLmdldCgncGFzc3dvcmQnLCAnYWRtaW4nKToKICAgICAgICByZXR1cm4ganNvbmlmeSh7J2Vycm9yJzogJ1dyb25nIGN1cnJlbnQgcGFzc3dvcmQnfSksIDQwMwogICAgaWYgbmV3X3Bhc3M6CiAgICAgICAgY2ZnWydwYXNzd29yZCddID0gbmV3X3Bhc3MKICAgIGlmIG5ld191c2VyOgogICAgICAgIGNmZ1sndXNlcm5hbWUnXSA9IG5ld191c2VyCiAgICBzYXZlX2NvbmZpZyhjZmcpCgogICAgZ2xvYmFsIEFETUlOX1VTRVIsIEFETUlOX1BBU1MKICAgIEFETUlOX1VTRVIgPSBjZmcuZ2V0KCd1c2VybmFtZScsIEFETUlOX1VTRVIpCiAgICBBRE1JTl9QQVNTID0gY2ZnLmdldCgncGFzc3dvcmQnLCBBRE1JTl9QQVNTKQoKICAgIHNlc3Npb24uY2xlYXIoKQogICAgbG9nX2l0KCcnLCAnYWRtaW4nLCAnQ3JlZGVudGlhbHMgY2hhbmdlZCcpCiAgICByZXR1cm4ganNvbmlmeSh7J29rJzogVHJ1ZSwgJ21lc3NhZ2UnOiAnQ3JlZGVudGlhbHMgdXBkYXRlZC4gUGxlYXNlIHJlLWxvZ2luLid9KQoKCkBhcHAucm91dGUoJy9hcGkvYWRtaW4vaW5mbycsIG1ldGhvZHM9WydHRVQnXSkKQGxvZ2luX3JlcXVpcmVkCmRlZiBhcGlfYWRtaW5faW5mbygpOgogICAgY2ZnID0gbG9hZF9jb25maWcoKQogICAgaW1wb3J0IHN1YnByb2Nlc3MKICAgIHRyeToKICAgICAgICBpcCA9IHN1YnByb2Nlc3MuY2hlY2tfb3V0cHV0KCJjdXJsIC1zNCBpZmNvbmZpZy5tZSIsIHNoZWxsPVRydWUpLmRlY29kZSgpLnN0cmlwKCkKICAgIGV4Y2VwdDoKICAgICAgICBpcCA9ICJ1bmtub3duIgogICAgcmV0dXJuIGpzb25pZnkoewogICAgICAgICd1c2VybmFtZSc6IGNmZy5nZXQoJ3VzZXJuYW1lJywgJ2FkbWluJyksCiAgICAgICAgJ3BvcnQnOiBjZmcuZ2V0KCdwb3J0JywgMTA4OCksCiAgICAgICAgJ2RvbWFpbic6IGNmZy5nZXQoJ2RvbWFpbicsICcnKSwKICAgICAgICAncGFuZWxfdGl0bGUnOiBjZmcuZ2V0KCdwYW5lbF90aXRsZScsICdWUE4gU3ViIE1hbmFnZXInKSwKICAgICAgICAnc2VydmVyX2lwJzogaXAsCiAgICAgICAgJ3NzbF9lbmFibGVkJzogb3MucGF0aC5leGlzdHMoJy9ldGMvbmdpbngvc2l0ZXMtZW5hYmxlZC9zdWJtYW5hZ2VyJyksCiAgICAgICAgJ3ZlcnNpb24nOiAnMi4wLjAnLAogICAgfSkKCiMg4pSA4pSA4pSAIFJ1biDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKCmlmIF9fbmFtZV9fID09ICdfX21haW5fXyc6CiAgICBpbml0X2RiKCkKICAgIGFwcC5ydW4oaG9zdD0nMC4wLjAuMCcsIHBvcnQ9MTA4OCwgZGVidWc9RmFsc2UpCg==" | base64 -d > ${INSTALL_DIR}/app.py
    echo "IyBwbHVnaW4ucHkKZnJvbSBmbGFzayBpbXBvcnQgcmVxdWVzdCwgUmVzcG9uc2UsIGpzb25pZnksIHJlbmRlcl90ZW1wbGF0ZV9zdHJpbmcKaW1wb3J0IGJhc2U2NAppbXBvcnQgcmVxdWVzdHMKZnJvbSBkYXRldGltZSBpbXBvcnQgZGF0ZXRpbWUKCmRlZiBpc19oYXBwX2NsaWVudCgpOgogICAgdWEgPSByZXF1ZXN0LmhlYWRlcnMuZ2V0KCdVc2VyLUFnZW50JywgJycpLmxvd2VyKCkKICAgIGFjY2VwdCA9IHJlcXVlc3QuaGVhZGVycy5nZXQoJ0FjY2VwdCcsICcnKS5sb3dlcigpCiAgICBpc19icm93c2VyID0gYW55KHggaW4gdWEgZm9yIHggaW4gWydtb3ppbGxhJywgJ2Nocm9tZScsICdzYWZhcmknLCAnZmlyZWZveCcsICdlZGdlJ10pIG9yICd0ZXh0L2h0bWwnIGluIGFjY2VwdAogICAgcmV0dXJuIG5vdCBpc19icm93c2VyCgoKZGVmIGFkZF9oYXBwX2hlYWRlcnMocmVzcCwgdXNlciwgdXNlZD0wLCB0b3RhbD0wLCBpc19oYXBwPUZhbHNlKToKICAgIGV4cGlyZXNfdHMgPSBpbnQoZGF0ZXRpbWUuZnJvbWlzb2Zvcm1hdCh1c2VyWydleHBpcmVzX2F0J10pLnRpbWVzdGFtcCgpKQogICAgcmVzcC5oZWFkZXJzWydzdWJzY3JpcHRpb24tdXNlcmluZm8nXSA9IGYidXBsb2FkPTA7IGRvd25sb2FkPXt1c2VkfTsgdG90YWw9e3RvdGFsfTsgZXhwaXJlPXtleHBpcmVzX3RzfSIKICAgIHJlc3AuaGVhZGVyc1sncHJvZmlsZS10aXRsZSddID0gIkFteXIgVlBOIgogICAgcmVzcC5oZWFkZXJzWydzdXBwb3J0LXVybCddID0gImh0dHBzOi8vdC5tZS9hbXlyX3NoaWsiCiAgICByZXNwLmhlYWRlcnNbJ3Byb2ZpbGUtd2ViLXBhZ2UtdXJsJ10gPSAiaHR0cHM6Ly90Lm1lL2FteXJfc2VjdXJlIgogICAgcmVzcC5oZWFkZXJzWydwcm9maWxlLXVwZGF0ZS1pbnRlcnZhbCddID0gIjEyIgogICAgYW5ub3VuY2UgPSAiYW15ciB2cG4g4oCUINC70YPRh9GI0LjQuSBWUE4iCiAgICByZXNwLmhlYWRlcnNbJ2Fubm91bmNlJ10gPSBmImJhc2U2NDp7YmFzZTY0LmI2NGVuY29kZShhbm5vdW5jZS5lbmNvZGUoKSkuZGVjb2RlKCl9IgogICAgaWYgaXNfaGFwcDoKICAgICAgICByZXNwLmhlYWRlcnNbJ2NvbnRlbnQtZGlzcG9zaXRpb24nXSA9ICdhdHRhY2htZW50OyBmaWxlbmFtZT0iYW15ci12cG4uY29uZiInCgoKZGVmIGdldF9oYXBwX2xpbmsoYmFzZV91cmwsIHN1Yl90b2tlbik6CiAgICBzdWJfdXJsID0gZiJ7YmFzZV91cmx9L3N1Yi97c3ViX3Rva2VufSIKICAgIHRyeToKICAgICAgICByID0gcmVxdWVzdHMucG9zdCgnaHR0cHM6Ly9jcnlwdG8uaGFwcC5zdS9hcGktdjIucGhwJywganNvbj17InVybCI6IHN1Yl91cmx9LCB0aW1lb3V0PTgpCiAgICAgICAgcmV0dXJuIHIudGV4dC5zdHJpcCgpCiAgICBleGNlcHQ6CiAgICAgICAgcmV0dXJuIHN1Yl91cmwKCgpkZWYgZ2V0X2Jyb3dzZXJfc3Vic2NyaXB0aW9uX3BhZ2UodXNlciwgYmFzZV91cmwpOgogICAgaGFwcF9saW5rID0gZ2V0X2hhcHBfbGluayhiYXNlX3VybCwgdXNlclsnc3ViX3Rva2VuJ10pCiAgICAKICAgIHJldHVybiByZW5kZXJfdGVtcGxhdGVfc3RyaW5nKCIiIgo8IURPQ1RZUEUgaHRtbD4KPGh0bWwgbGFuZz0icnUiPgo8aGVhZD4KICAgIDxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KICAgIDx0aXRsZT5BbXlyIFZQTiDigJQg0J/QvtC00L/QuNGB0LrQsDwvdGl0bGU+CiAgICA8c3R5bGU+CiAgICAgICAgYm9keSB7IGZvbnQtZmFtaWx5OiBzeXN0ZW0tdWk7IGJhY2tncm91bmQ6ICMwYTBhMWE7IGNvbG9yOiAjZTBlMGUwOyBwYWRkaW5nOiA0MHB4IDIwcHg7IH0KICAgICAgICAuY2FyZCB7IG1heC13aWR0aDogNTIwcHg7IG1hcmdpbjogMCBhdXRvOyBiYWNrZ3JvdW5kOiAjMTExMTIyOyBib3JkZXItcmFkaXVzOiAyMHB4OyBwYWRkaW5nOiA0MHB4OyB9CiAgICAgICAgaDEgeyBjb2xvcjogIzNiODJmNjsgfQogICAgICAgIC5saW5rIHsgYmFja2dyb3VuZDogIzBkMTExNzsgcGFkZGluZzogMTJweDsgYm9yZGVyLXJhZGl1czogMTBweDsgZm9udC1mYW1pbHk6IG1vbm9zcGFjZTsgZm9udC1zaXplOiAxMnB4OyB3b3JkLWJyZWFrOiBicmVhay1hbGw7IG1hcmdpbjogMTJweCAwOyB9CiAgICAgICAgLmxhYmVsIHsgY29sb3I6ICM4ODg7IGZvbnQtc2l6ZTogMTNweDsgbWFyZ2luLWJvdHRvbTogNHB4OyB9CiAgICAgICAgLmJ0biB7IGRpc3BsYXk6IGJsb2NrOyBwYWRkaW5nOiAxNHB4OyBiYWNrZ3JvdW5kOiAjM2I4MmY2OyBjb2xvcjogd2hpdGU7IHRleHQtYWxpZ246IGNlbnRlcjsgdGV4dC1kZWNvcmF0aW9uOiBub25lOyBib3JkZXItcmFkaXVzOiAxMHB4OyBtYXJnaW4tdG9wOiAxNXB4OyB9CiAgICA8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5PgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGgxPvCfmoAgQW15ciBWUE48L2gxPgogICAgICAgIDxwPjxzdHJvbmc+e3sgdXNlci5kaXNwbGF5X25hbWUgfX08L3N0cm9uZz48L3A+CiAgICAgICAgCiAgICAgICAgPGRpdiBjbGFzcz0ibGFiZWwiPtCe0LHRi9GH0L3QsNGPINGB0YHRi9C70LrQsDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmsiPnt7IHVzZXIuc3ViX2xpbmsgfX08L2Rpdj4KICAgICAgICAKICAgICAgICA8ZGl2IGNsYXNzPSJsYWJlbCI+0JfQsNGI0LjRhNGA0L7QstCw0L3QvdCw0Y8g0YHRgdGL0LvQutCwIChIYXBwKTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmsiPnt7IGhhcHBfbGluayB9fTwvZGl2PgogICAgICAgIAogICAgICAgIDxhIGhyZWY9Int7IHVzZXIuc3ViX2xpbmsgfX0iIGNsYXNzPSJidG4iPtCh0LrQvtC/0LjRgNC+0LLQsNGC0Ywg0L7QsdGL0YfQvdGD0Y4g0YHRgdGL0LvQutGDPC9hPgogICAgICAgIDxhIGhyZWY9Int7IGhhcHBfbGluayB9fSIgY2xhc3M9ImJ0biIgc3R5bGU9ImJhY2tncm91bmQ6IzIyYzU1ZSI+0KHQutC+0L/QuNGA0L7QstCw0YLRjCBoYXBwOi8vINGB0YHRi9C70LrRgzwvYT4KICAgIDwvZGl2Pgo8L2JvZHk+CjwvaHRtbD4KICAgICIiIiwgdXNlcj11c2VyLCBoYXBwX2xpbms9aGFwcF9saW5rKQ==" | base64 -d > ${INSTALL_DIR}/plugin.py
    echo "PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InJ1Ij4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+e3sgdGl0bGUgfX08L3RpdGxlPgo8c2NyaXB0IHNyYz0iaHR0cHM6Ly9jZG5qcy5jbG91ZGZsYXJlLmNvbS9hamF4L2xpYnMvcXJjb2RlanMvMS4wLjAvcXJjb2RlLm1pbi5qcyI+PC9zY3JpcHQ+CjxzdHlsZT4KLyog4pSA4pSAIFJlc2V0ICYgYmFzZSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94fQo6cm9vdHsKICAtLWJnMDojMDcwNzBmOy0tYmcxOiMwZDBkMWE7LS1iZzI6IzExMTEyMjstLWJnMzojMTgxODMwOwogIC0tYm9yZGVyOiMxZTFlMzg7LS1ib3JkZXIyOiMyNTI1NDU7CiAgLS10ZXh0OiNjOGM4ZTg7LS10ZXh0MjojNzA3MGEwOy0tdGV4dDM6IzNhM2E2MDsKICAtLWJsdWU6IzViOGFmNTstLWJsdWUyOiMzZDZlZDQ7LS1ncmVlbjojM2RkNjhjOy0tcmVkOiNmMDVmNWY7CiAgLS1vcmFuZ2U6I2Y1YTQ0MjstLXB1cnBsZTojOWI3N2Y1Oy0tY3lhbjojM2RjZmY1Oy0teWVsbG93OiNmNWQ4NDI7CiAgLS1ibHVlLWJnOiM1YjhhZjUxMjstLWdyZWVuLWJnOiMzZGQ2OGMxMjstLXJlZC1iZzojZjA1ZjVmMTI7CiAgLS1vcmFuZ2UtYmc6I2Y1YTQ0MjEyOy0tcHVycGxlLWJnOiM5Yjc3ZjUxMjstLWN5YW4tYmc6IzNkY2ZmNTEyOwogIC0tcmFkaXVzOjhweDstLXJhZGl1cy1sZzoxMnB4OwogIC0tc2hhZG93OjAgNHB4IDI0cHggIzAwMDAwMDQwOwp9Cjo6LXdlYmtpdC1zY3JvbGxiYXJ7d2lkdGg6NHB4O2hlaWdodDo0cHh9Cjo6LXdlYmtpdC1zY3JvbGxiYXItdHJhY2t7YmFja2dyb3VuZDp2YXIoLS1iZzApfQo6Oi13ZWJraXQtc2Nyb2xsYmFyLXRodW1ie2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyMik7Ym9yZGVyLXJhZGl1czoycHh9Cjo6LXdlYmtpdC1zY3JvbGxiYXItdGh1bWI6aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1ibHVlMil9CmJvZHl7Zm9udC1mYW1pbHk6J1NGIFBybyBEaXNwbGF5JywtYXBwbGUtc3lzdGVtLEJsaW5rTWFjU3lzdGVtRm9udCwnU2Vnb2UgVUknLHNhbnMtc2VyaWY7CiAgICAgYmFja2dyb3VuZDp2YXIoLS1iZzApO2NvbG9yOnZhcigtLXRleHQpO21pbi1oZWlnaHQ6MTAwdmg7ZGlzcGxheTpmbGV4O2ZvbnQtc2l6ZToxM3B4fQoKLyog4pSA4pSAIFNpZGViYXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5zaWRlYmFye3dpZHRoOjIyMHB4O21pbi1oZWlnaHQ6MTAwdmg7YmFja2dyb3VuZDp2YXIoLS1iZzEpO2JvcmRlci1yaWdodDoxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKICAgICAgICAgZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtwb3NpdGlvbjpmaXhlZDt0b3A6MDtsZWZ0OjA7ei1pbmRleDo1MH0KLnNpZGViYXItbG9nb3twYWRkaW5nOjE4cHggMTZweCAxMnB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcil9Ci5sb2dvLXRpdGxle2ZvbnQtc2l6ZToxNXB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOi4zcHh9Ci5sb2dvLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS10ZXh0Myk7bWFyZ2luLXRvcDoycHh9Ci5zaWRlYmFyLW5hdntwYWRkaW5nOjEwcHggOHB4O2ZsZXg6MX0KLm5hdi1zZWN0aW9ue2ZvbnQtc2l6ZTo5cHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXRleHQzKTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7CiAgICAgICAgICAgICBsZXR0ZXItc3BhY2luZzoxcHg7cGFkZGluZzo4cHggMTBweCA0cHh9Ci5uYXYtaXRlbXtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo5cHg7cGFkZGluZzo4cHggMTBweDtib3JkZXItcmFkaXVzOjZweDsKICAgICAgICAgIGN1cnNvcjpwb2ludGVyO2NvbG9yOnZhcigtLXRleHQyKTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo1MDA7CiAgICAgICAgICB0cmFuc2l0aW9uOmFsbCAuMTVzO3VzZXItc2VsZWN0Om5vbmU7bWFyZ2luLWJvdHRvbToxcHh9Ci5uYXYtaXRlbTpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLWJnMyk7Y29sb3I6dmFyKC0tdGV4dCl9Ci5uYXYtaXRlbS5hY3RpdmV7YmFja2dyb3VuZDp2YXIoLS1ibHVlLWJnKTtjb2xvcjp2YXIoLS1ibHVlKTtib3JkZXI6MXB4IHNvbGlkICM1YjhhZjUyMH0KLm5hdi1pY29ue2ZvbnQtc2l6ZToxNHB4O3dpZHRoOjE4cHg7dGV4dC1hbGlnbjpjZW50ZXJ9Ci5uYXYtYmFkZ2V7bWFyZ2luLWxlZnQ6YXV0bztiYWNrZ3JvdW5kOnZhcigtLXJlZCk7Y29sb3I6I2ZmZjtmb250LXNpemU6OXB4OwogICAgICAgICAgIHBhZGRpbmc6MXB4IDVweDtib3JkZXItcmFkaXVzOjEwcHg7Zm9udC13ZWlnaHQ6NzAwfQouc2lkZWJhci1mb290ZXJ7cGFkZGluZzoxMnB4O2JvcmRlci10b3A6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tdGV4dDMpfQouc2lkZWJhci1mb290ZXIgYXtjb2xvcjp2YXIoLS1ibHVlKTt0ZXh0LWRlY29yYXRpb246bm9uZX0KCi8qIOKUgOKUgCBNYWluIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwoubWFpbnttYXJnaW4tbGVmdDoyMjBweDtmbGV4OjE7bWluLWhlaWdodDoxMDB2aDtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1ufQoudG9wYmFye2JhY2tncm91bmQ6dmFyKC0tYmcxKTtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO3BhZGRpbmc6MTBweCAyMnB4OwogICAgICAgIGRpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEycHg7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6NDB9Ci5wYWdlLXRpdGxle2ZvbnQtc2l6ZToxNXB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojZmZmfQoudG9wYmFyLXJpZ2h0e21hcmdpbi1sZWZ0OmF1dG87ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4fQouZG90LWxpdmV7d2lkdGg6NnB4O2hlaWdodDo2cHg7YmFja2dyb3VuZDp2YXIoLS1ncmVlbik7Ym9yZGVyLXJhZGl1czo1MCU7YW5pbWF0aW9uOmJsaW5rIDJzIGluZmluaXRlfQpAa2V5ZnJhbWVzIGJsaW5rezAlLDEwMCV7b3BhY2l0eToxfTUwJXtvcGFjaXR5Oi4yNX19Ci5jb250ZW50e3BhZGRpbmc6MjBweCAyMnB4O2ZsZXg6MX0KLnNlY3Rpb257ZGlzcGxheTpub25lfQouc2VjdGlvbi5hY3RpdmV7ZGlzcGxheTpibG9ja30KCi8qIOKUgOKUgCBDYXJkcyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KLmNhcmRze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KGF1dG8tZml0LG1pbm1heCgxNjBweCwxZnIpKTtnYXA6MTBweDttYXJnaW4tYm90dG9tOjE4cHh9Ci5jYXJke2JhY2tncm91bmQ6dmFyKC0tYmcxKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMtbGcpO3BhZGRpbmc6MTRweCAxNnB4OwogICAgICB0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnN9Ci5jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1ib3JkZXIyKX0KLmNhcmQtbGFiZWx7Zm9udC1zaXplOjlweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6MXB4O2NvbG9yOnZhcigtLXRleHQzKTttYXJnaW4tYm90dG9tOjZweH0KLmNhcmQtdmFse2ZvbnQtc2l6ZToyMnB4O2ZvbnQtd2VpZ2h0OjgwMDtsaW5lLWhlaWdodDoxfQouY2FyZC1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tdGV4dDMpO21hcmdpbi10b3A6NHB4fQoubWluaS1iYXJ7aGVpZ2h0OjJweDtiYWNrZ3JvdW5kOnZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxcHg7bWFyZ2luLXRvcDo4cHg7b3ZlcmZsb3c6aGlkZGVufQoubWluaS1maWxse2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MXB4O3RyYW5zaXRpb246d2lkdGggLjZzfQouYy1ibHVle2NvbG9yOnZhcigtLWJsdWUpfS5jLWdyZWVue2NvbG9yOnZhcigtLWdyZWVuKX0uYy1yZWR7Y29sb3I6dmFyKC0tcmVkKX0KLmMtb3Jhbmdle2NvbG9yOnZhcigtLW9yYW5nZSl9LmMtcHVycGxle2NvbG9yOnZhcigtLXB1cnBsZSl9LmMtY3lhbntjb2xvcjp2YXIoLS1jeWFuKX0KLmMteWVsbG93e2NvbG9yOnZhcigtLXllbGxvdyl9CgovKiDilIDilIAgU2VhcmNoICYgZmlsdGVyIGJhciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KLmZpbHRlci1iYXJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4O21hcmdpbi1ib3R0b206MTJweDtmbGV4LXdyYXA6d3JhcH0KLnNlYXJjaC1ib3h7cG9zaXRpb246cmVsYXRpdmU7ZmxleDoxO21pbi13aWR0aDoxODBweDttYXgtd2lkdGg6MzAwcHh9Ci5zZWFyY2gtYm94IGlucHV0e3dpZHRoOjEwMCU7cGFkZGluZzo3cHggMTBweCA3cHggMzJweDtiYWNrZ3JvdW5kOnZhcigtLWJnMik7CiAgICAgICAgICAgICAgICAgIGJvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7CiAgICAgICAgICAgICAgICAgIGNvbG9yOnZhcigtLXRleHQpO2ZvbnQtc2l6ZToxMnB4fQouc2VhcmNoLWJveCBpbnB1dDpmb2N1c3tvdXRsaW5lOm5vbmU7Ym9yZGVyLWNvbG9yOnZhcigtLWJsdWUpfQouc2VhcmNoLWljb257cG9zaXRpb246YWJzb2x1dGU7bGVmdDoxMHB4O3RvcDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTUwJSk7CiAgICAgICAgICAgICBjb2xvcjp2YXIoLS10ZXh0Myk7Zm9udC1zaXplOjEycHg7cG9pbnRlci1ldmVudHM6bm9uZX0KLmZpbHRlci10YWJze2Rpc3BsYXk6ZmxleDtnYXA6M3B4fQouZnRhYntwYWRkaW5nOjZweCAxMnB4O2JvcmRlci1yYWRpdXM6NXB4O2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjYwMDsKICAgICAgY29sb3I6dmFyKC0tdGV4dDIpO2JvcmRlcjoxcHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjEyczt1c2VyLXNlbGVjdDpub25lfQouZnRhYjpob3Zlcntjb2xvcjp2YXIoLS10ZXh0KTtiYWNrZ3JvdW5kOnZhcigtLWJnMyl9Ci5mdGFiLmFjdHtiYWNrZ3JvdW5kOnZhcigtLWJsdWUtYmcpO2NvbG9yOnZhcigtLWJsdWUpO2JvcmRlci1jb2xvcjojNWI4YWY1MjV9Ci5zb3J0LXNlbGVjdHtwYWRkaW5nOjZweCAxMHB4O2JhY2tncm91bmQ6dmFyKC0tYmcyKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgICAgICAgICAgICBib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7Y29sb3I6dmFyKC0tdGV4dCk7Zm9udC1zaXplOjExcHh9Ci5tbC1hdXRve21hcmdpbi1sZWZ0OmF1dG99CgovKiDilIDilIAgVGFibGUg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi50YWJsZS13cmFwe2JhY2tncm91bmQ6dmFyKC0tYmcxKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMtbGcpO292ZXJmbG93OmhpZGRlbn0KLnRhYmxlLWhlYWR7cGFkZGluZzo4cHggMTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2Rpc3BsYXk6ZmxleDsKICAgICAgICAgICAgYWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLXRleHQzKX0KLnRhYmxlLWhlYWQgc3Ryb25ne2NvbG9yOnZhcigtLXRleHQpO2ZvbnQtc2l6ZToxMnB4fQp0YWJsZXt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZX0KdGhlYWQgdGh7cGFkZGluZzo5cHggMTJweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1zaXplOjEwcHg7Zm9udC13ZWlnaHQ6NzAwOwogICAgICAgICBjb2xvcjp2YXIoLS10ZXh0Myk7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi41cHg7CiAgICAgICAgIGJvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7d2hpdGUtc3BhY2U6bm93cmFwO2N1cnNvcjpwb2ludGVyOwogICAgICAgICB1c2VyLXNlbGVjdDpub25lO3RyYW5zaXRpb246Y29sb3IgLjE1c30KdGhlYWQgdGg6aG92ZXJ7Y29sb3I6dmFyKC0tdGV4dCl9CnRoZWFkIHRoLnNvcnRlZHtjb2xvcjp2YXIoLS1ibHVlKX0KdGJvZHkgdHJ7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt0cmFuc2l0aW9uOmJhY2tncm91bmQgLjEyc30KdGJvZHkgdHI6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmV9CnRib2R5IHRyOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYmcyKX0KdGR7cGFkZGluZzo5cHggMTJweDt2ZXJ0aWNhbC1hbGlnbjptaWRkbGU7Zm9udC1zaXplOjEycHh9Ci5jb2wtY2hlY2t7d2lkdGg6MzZweH0KLmNvbC1uYW1le21pbi13aWR0aDoxNDBweH0KLmNvbC1zdGF0dXN7d2lkdGg6MTEwcHh9Ci5jb2wtZXhwe3dpZHRoOjEzMHB4O3doaXRlLXNwYWNlOm5vd3JhcH0KLmNvbC10cmFme3dpZHRoOjE0MHB4fQouY29sLXRhZ3N7d2lkdGg6MTEwcHh9Ci5jb2wtYWN0e3dpZHRoOjEzMHB4O3doaXRlLXNwYWNlOm5vd3JhcH0KCi8qIOKUgOKUgCBTdGF0dXMgYmFkZ2VzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwouYmFkZ2V7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjNweDtwYWRkaW5nOjJweCA3cHg7Ym9yZGVyLXJhZGl1czo0cHg7CiAgICAgICBmb250LXNpemU6MTBweDtmb250LXdlaWdodDo3MDA7d2hpdGUtc3BhY2U6bm93cmFwfQouYi1hY3RpdmV7YmFja2dyb3VuZDp2YXIoLS1ncmVlbi1iZyk7Y29sb3I6dmFyKC0tZ3JlZW4pO2JvcmRlcjoxcHggc29saWQgIzNkZDY4YzIyfQouYi1leHBpcmVke2JhY2tncm91bmQ6dmFyKC0tcmVkLWJnKTtjb2xvcjp2YXIoLS1yZWQpO2JvcmRlcjoxcHggc29saWQgI2YwNWY1ZjIyfQouYi1kaXNhYmxlZHtiYWNrZ3JvdW5kOnZhcigtLW9yYW5nZS1iZyk7Y29sb3I6dmFyKC0tb3JhbmdlKTtib3JkZXI6MXB4IHNvbGlkICNmNWE0NDIyMn0KLmItdHJhZmZpY3tiYWNrZ3JvdW5kOnZhcigtLXB1cnBsZS1iZyk7Y29sb3I6dmFyKC0tcHVycGxlKTtib3JkZXI6MXB4IHNvbGlkICM5Yjc3ZjUyMn0KCi8qIOKUgOKUgCBUcmFmZmljIGJhciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KLnRiYXJ7d2lkdGg6MTAwcHh9Ci50YmFyLXJvd3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Zm9udC1zaXplOjlweDtjb2xvcjp2YXIoLS10ZXh0Myk7bWFyZ2luLWJvdHRvbToycHh9Ci50YmFyLWJne2hlaWdodDozcHg7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MnB4O292ZXJmbG93OmhpZGRlbn0KLnRiYXItZmlsbHtoZWlnaHQ6MTAwJTtib3JkZXItcmFkaXVzOjJweH0KLnRmLWd7YmFja2dyb3VuZDp2YXIoLS1ncmVlbil9LnRmLXl7YmFja2dyb3VuZDp2YXIoLS15ZWxsb3cpfS50Zi1ye2JhY2tncm91bmQ6dmFyKC0tcmVkKX0KCi8qIOKUgOKUgCBUYWcgcGlsbHMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi50YWdzLXdyYXB7ZGlzcGxheTpmbGV4O2ZsZXgtd3JhcDp3cmFwO2dhcDoycHh9Ci50YWd7YmFja2dyb3VuZDp2YXIoLS1wdXJwbGUtYmcpO2NvbG9yOnZhcigtLXB1cnBsZSk7Zm9udC1zaXplOjlweDsKICAgICBwYWRkaW5nOjFweCA1cHg7Ym9yZGVyLXJhZGl1czozcHg7Ym9yZGVyOjFweCBzb2xpZCAjOWI3N2Y1MjB9CgovKiDilIDilIAgUm93IGFjdGlvbnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5yb3ctYWN0c3tkaXNwbGF5OmZsZXg7Z2FwOjNweDthbGlnbi1pdGVtczpjZW50ZXJ9Ci5pYXtiYWNrZ3JvdW5kOm5vbmU7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2NvbG9yOnZhcigtLXRleHQyKTsKICAgIHBhZGRpbmc6NHB4IDdweDtib3JkZXItcmFkaXVzOjRweDtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTFweDsKICAgIHRyYW5zaXRpb246YWxsIC4xMnM7d2hpdGUtc3BhY2U6bm93cmFwfQouaWE6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWJvcmRlcjIpO2NvbG9yOnZhcigtLXRleHQpO2JhY2tncm91bmQ6dmFyKC0tYmczKX0KLmlhLWdyZWVue2JvcmRlci1jb2xvcjojM2RkNjhjMjI7Y29sb3I6dmFyKC0tZ3JlZW4pfS5pYS1ncmVlbjpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLWdyZWVuLWJnKX0KLmlhLXJlZHtib3JkZXItY29sb3I6I2YwNWY1ZjIyO2NvbG9yOnZhcigtLXJlZCl9LmlhLXJlZDpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLXJlZC1iZyl9Ci5pYS1ibHVle2JvcmRlci1jb2xvcjojNWI4YWY1MjI7Y29sb3I6dmFyKC0tYmx1ZSl9LmlhLWJsdWU6aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1ibHVlLWJnKX0KLmlhLW9yYW5nZXtib3JkZXItY29sb3I6I2Y1YTQ0MjIyO2NvbG9yOnZhcigtLW9yYW5nZSl9LmlhLW9yYW5nZTpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLW9yYW5nZS1iZyl9CgovKiDilIDilIAgQnVsayBiYXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5idWxrLWJhcntwb3NpdGlvbjpmaXhlZDtib3R0b206MDtsZWZ0OjIyMHB4O3JpZ2h0OjA7YmFja2dyb3VuZDp2YXIoLS1iZzEpOwogICAgICAgICAgYm9yZGVyLXRvcDoxcHggc29saWQgdmFyKC0tYmx1ZSk7cGFkZGluZzoxMHB4IDIycHg7CiAgICAgICAgICBkaXNwbGF5Om5vbmU7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O3otaW5kZXg6NjB9Ci5idWxrLWJhci5zaG93e2Rpc3BsYXk6ZmxleH0KLmJ1bGstbGFiZWx7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLWJsdWUpfQoKLyog4pSA4pSAIFBhZ2luYXRpb24g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5wYWdpbmF0aW9ue2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjZweDtwYWRkaW5nOjEwcHggMTRweDsKICAgICAgICAgICAgYm9yZGVyLXRvcDoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtqdXN0aWZ5LWNvbnRlbnQ6ZmxleC1lbmR9Ci5wYWdlLWJ0bntwYWRkaW5nOjRweCA5cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NHB4OwogICAgICAgICAgY3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tdGV4dDIpO2JhY2tncm91bmQ6dHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjEyc30KLnBhZ2UtYnRuOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1ib3JkZXIyKTtjb2xvcjp2YXIoLS10ZXh0KX0KLnBhZ2UtYnRuLmN1cntiYWNrZ3JvdW5kOnZhcigtLWJsdWUtYmcpO2NvbG9yOnZhcigtLWJsdWUpO2JvcmRlci1jb2xvcjojNWI4YWY1MjV9Ci5wYWdlLWJ0bjpkaXNhYmxlZHtvcGFjaXR5Oi4zO2N1cnNvcjpkZWZhdWx0fQoucGFnZS1pbmZve2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLXRleHQzKX0KCi8qIOKUgOKUgCBCdXR0b25zIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwouYnRue2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo1cHg7cGFkZGluZzo4cHggMTRweDtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7CiAgICAgYm9yZGVyOm5vbmU7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO3RyYW5zaXRpb246YWxsIC4xNXN9Ci5idG4tcHJpbWFyeXtiYWNrZ3JvdW5kOnZhcigtLWJsdWUpO2NvbG9yOiNmZmZ9LmJ0bi1wcmltYXJ5OmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYmx1ZTIpfQouYnRuLWdob3N0e2JhY2tncm91bmQ6dmFyKC0tYmczKTtjb2xvcjp2YXIoLS10ZXh0KTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcil9Ci5idG4tZ2hvc3Q6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWJvcmRlcjIpfQouYnRuLWRhbmdlcntiYWNrZ3JvdW5kOnZhcigtLXJlZC1iZyk7Y29sb3I6dmFyKC0tcmVkKTtib3JkZXI6MXB4IHNvbGlkICNmMDVmNWYyMn0KLmJ0bi1kYW5nZXI6aG92ZXJ7YmFja2dyb3VuZDojZjA1ZjVmMjJ9Ci5idG4tc217cGFkZGluZzo1cHggMTBweDtmb250LXNpemU6MTFweH0KCi8qIOKUgOKUgCBGb3JtIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwouZmd7bWFyZ2luLWJvdHRvbToxMnB4fQouZmcgbGFiZWx7ZGlzcGxheTpibG9jaztmb250LXNpemU6MTBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdGV4dDIpOwogICAgICAgICAgdGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi41cHg7bWFyZ2luLWJvdHRvbTo1cHh9Ci5maW5wdXR7d2lkdGg6MTAwJTtwYWRkaW5nOjhweCAxMHB4O2JhY2tncm91bmQ6dmFyKC0tYmcwKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgICAgICAgYm9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO2NvbG9yOnZhcigtLXRleHQpO2ZvbnQtc2l6ZToxMnB4O2ZvbnQtZmFtaWx5OmluaGVyaXR9Ci5maW5wdXQ6Zm9jdXN7b3V0bGluZTpub25lO2JvcmRlci1jb2xvcjp2YXIoLS1ibHVlKX0KLmZpbnB1dDo6cGxhY2Vob2xkZXJ7Y29sb3I6dmFyKC0tdGV4dDMpfQp0ZXh0YXJlYS5maW5wdXR7cmVzaXplOnZlcnRpY2FsO21pbi1oZWlnaHQ6NTJweH0KLmZvcm0tZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHh9CkBtZWRpYShtYXgtd2lkdGg6NTAwcHgpey5mb3JtLWdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn19Ci5wcmVzZXRze2Rpc3BsYXk6ZmxleDtnYXA6NHB4O2ZsZXgtd3JhcDp3cmFwO21hcmdpbi10b3A6NXB4fQoucHJle3BhZGRpbmc6M3B4IDhweDtiYWNrZ3JvdW5kOnZhcigtLWJnMyk7Y29sb3I6dmFyKC0tYmx1ZSk7Zm9udC1zaXplOjEwcHg7CiAgICAgYm9yZGVyOjFweCBzb2xpZCAjNWI4YWY1MjA7Ym9yZGVyLXJhZGl1czo0cHg7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjphbGwgLjEyczt1c2VyLXNlbGVjdDpub25lfQoucHJlOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYmx1ZS1iZyl9CgovKiDilIDilIAgVG9nZ2xlIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwoudG9nLXJvd3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuOwogICAgICAgICBiYWNrZ3JvdW5kOnZhcigtLWJnMCk7cGFkZGluZzo4cHggMTFweDtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7bWFyZ2luLWJvdHRvbToxMnB4fQoudG9nLWxibHtmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS10ZXh0Mil9Ci50b2d7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6MzZweDtoZWlnaHQ6MjBweDtjdXJzb3I6cG9pbnRlcjtmbGV4LXNocmluazowfQoudG9nIGlucHV0e29wYWNpdHk6MDt3aWR0aDowO2hlaWdodDowfQouc2xke3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIyKTtib3JkZXItcmFkaXVzOjEwcHg7dHJhbnNpdGlvbjouMnN9Ci5zbGQ6YmVmb3Jle2NvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7aGVpZ2h0OjE0cHg7d2lkdGg6MTRweDtsZWZ0OjNweDtib3R0b206M3B4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiM1NTU7Ym9yZGVyLXJhZGl1czo1MCU7dHJhbnNpdGlvbjouMnN9CmlucHV0OmNoZWNrZWQrLnNsZHtiYWNrZ3JvdW5kOnZhcigtLWJsdWUpfQppbnB1dDpjaGVja2VkKy5zbGQ6YmVmb3Jle3RyYW5zZm9ybTp0cmFuc2xhdGVYKDE2cHgpO2JhY2tncm91bmQ6I2ZmZn0KCi8qIOKUgOKUgCBNb2RhbCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KLm92ZXJsYXl7cG9zaXRpb246Zml4ZWQ7aW5zZXQ6MDtiYWNrZ3JvdW5kOiMwMDAwMDBiMDt6LWluZGV4OjIwMDtkaXNwbGF5Om5vbmU7CiAgICAgICAgIGFsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO3BhZGRpbmc6MjBweDtiYWNrZHJvcC1maWx0ZXI6Ymx1cigycHgpfQoub3ZlcmxheS5vcGVue2Rpc3BsYXk6ZmxleH0KLm1vZGFse2JhY2tncm91bmQ6dmFyKC0tYmcxKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMtbGcpOwogICAgICAgd2lkdGg6MTAwJTttYXgtaGVpZ2h0Ojkwdmg7b3ZlcmZsb3cteTphdXRvO2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW59Ci5taGVhZHtwYWRkaW5nOjE0cHggMThweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2Rpc3BsYXk6ZmxleDsKICAgICAgIGp1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjtwb3NpdGlvbjpzdGlja3k7dG9wOjA7CiAgICAgICBiYWNrZ3JvdW5kOnZhcigtLWJnMSk7ei1pbmRleDoxfQoubWhlYWQgaDJ7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwfQoubWNsb3Nle2JhY2tncm91bmQ6bm9uZTtib3JkZXI6bm9uZTtjb2xvcjp2YXIoLS10ZXh0Myk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjIwcHg7CiAgICAgICAgbGluZS1oZWlnaHQ6MTtwYWRkaW5nOjAgNHB4O3RyYW5zaXRpb246Y29sb3IgLjEyc30KLm1jbG9zZTpob3Zlcntjb2xvcjp2YXIoLS1yZWQpfQoubWJvZHl7cGFkZGluZzoxOHB4fQoubWZvb3R7cGFkZGluZzoxMnB4IDE4cHg7Ym9yZGVyLXRvcDoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtkaXNwbGF5OmZsZXg7Z2FwOjhweDsKICAgICAgIGp1c3RpZnktY29udGVudDpmbGV4LWVuZDtwb3NpdGlvbjpzdGlja3k7Ym90dG9tOjA7YmFja2dyb3VuZDp2YXIoLS1iZzEpfQoKLyog4pSA4pSAIE1vZGFsIHRhYnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5tdGFic3tkaXNwbGF5OmZsZXg7Z2FwOjJweDttYXJnaW4tYm90dG9tOjE2cHg7YmFja2dyb3VuZDp2YXIoLS1iZzApOwogICAgICAgcGFkZGluZzozcHg7Ym9yZGVyLXJhZGl1czo2cHh9Ci5tdGFie2ZsZXg6MTtwYWRkaW5nOjVweCA4cHg7Ym9yZGVyLXJhZGl1czo0cHg7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjExcHg7CiAgICAgIGZvbnQtd2VpZ2h0OjYwMDt0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjp2YXIoLS10ZXh0Mik7dHJhbnNpdGlvbjphbGwgLjE1czt1c2VyLXNlbGVjdDpub25lfQoubXRhYi5hY3R7YmFja2dyb3VuZDp2YXIoLS1iZzIpO2NvbG9yOnZhcigtLXRleHQpfQoubXRhYi1wYW5le2Rpc3BsYXk6bm9uZX0ubXRhYi1wYW5lLmFjdHtkaXNwbGF5OmJsb2NrfQoKLyog4pSA4pSAIE5vZGVzIGdyaWQg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5ub2Rlcy1ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KGF1dG8tZmlsbCxtaW5tYXgoMzAwcHgsMWZyKSk7Z2FwOjEwcHh9Ci5ub2RlLWNhcmR7YmFja2dyb3VuZDp2YXIoLS1iZzEpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cy1sZyk7CiAgICAgICAgICAgcGFkZGluZzoxNHB4O3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yc30KLm5vZGUtY2FyZDpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYm9yZGVyMil9Ci5uYy1oZWFke2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjEwcHh9Ci5uYy1zdGF0dXN7d2lkdGg6OHB4O2hlaWdodDo4cHg7Ym9yZGVyLXJhZGl1czo1MCU7ZmxleC1zaHJpbms6MH0KLm5zLW9re2JhY2tncm91bmQ6dmFyKC0tZ3JlZW4pfS5ucy1lcnJvcntiYWNrZ3JvdW5kOnZhcigtLXJlZCl9Ci5ucy11bmtub3due2JhY2tncm91bmQ6dmFyKC0tdGV4dDMpfQoubmMtbmFtZXtmb250LXdlaWdodDo3MDA7Zm9udC1zaXplOjEzcHg7ZmxleDoxfQoubmMtdXJse2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLXRleHQzKTtmb250LWZhbWlseTptb25vc3BhY2U7CiAgICAgICAgb3ZlcmZsb3c6aGlkZGVuO3RleHQtb3ZlcmZsb3c6ZWxsaXBzaXM7d2hpdGUtc3BhY2U6bm93cmFwO21hcmdpbi1ib3R0b206OHB4fQoubmMtdGFne2ZvbnQtc2l6ZTo5cHg7YmFja2dyb3VuZDp2YXIoLS1wdXJwbGUtYmcpO2NvbG9yOnZhcigtLXB1cnBsZSk7CiAgICAgICAgcGFkZGluZzoxcHggNnB4O2JvcmRlci1yYWRpdXM6M3B4O2Rpc3BsYXk6aW5saW5lLWJsb2NrfQoubmMtYWN0c3tkaXNwbGF5OmZsZXg7Z2FwOjVweDttYXJnaW4tdG9wOjEwcHh9CgovKiDilIDilIAgU2V0dGluZ3Mg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5zZXR0aW5ncy1ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MjBweDttYXgtd2lkdGg6OTAwcHh9CkBtZWRpYShtYXgtd2lkdGg6NzAwcHgpey5zZXR0aW5ncy1ncmlke2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQouc2V0dGluZ3MtY2FyZHtiYWNrZ3JvdW5kOnZhcigtLWJnMSk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6dmFyKC0tcmFkaXVzLWxnKTtwYWRkaW5nOjE4cHh9Ci5zZXR0aW5ncy1jYXJkIGgze2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjp2YXIoLS10ZXh0Mik7CiAgICAgICAgICAgICAgICAgIHRleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouNXB4O21hcmdpbi1ib3R0b206MTRweH0KCi8qIOKUgOKUgCBMb2cgdGFibGUg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5sb2ctYWN0aW9ue2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDZweDtib3JkZXItcmFkaXVzOjNweH0KLmxhLWNyZWF0ZXtiYWNrZ3JvdW5kOnZhcigtLWdyZWVuLWJnKTtjb2xvcjp2YXIoLS1ncmVlbil9Ci5sYS1kZWxldGV7YmFja2dyb3VuZDp2YXIoLS1yZWQtYmcpO2NvbG9yOnZhcigtLXJlZCl9Ci5sYS11cGRhdGUsLmxhLXRvZ2dsZSwubGEtZXh0ZW5ke2JhY2tncm91bmQ6dmFyKC0tYmx1ZS1iZyk7Y29sb3I6dmFyKC0tYmx1ZSl9Ci5sYS1idWxrX2RlbGV0ZXtiYWNrZ3JvdW5kOnZhcigtLXJlZC1iZyk7Y29sb3I6dmFyKC0tcmVkKX0KLmxhLW90aGVye2JhY2tncm91bmQ6dmFyKC0tYmczKTtjb2xvcjp2YXIoLS10ZXh0Mil9CgovKiDilIDilIAgUVIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5xci13cmFwe2JhY2tncm91bmQ6I2ZmZjtwYWRkaW5nOjEycHg7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO2Rpc3BsYXk6aW5saW5lLWJsb2NrfQojcXItY29udGFpbmVyIGNhbnZhcywjcXItY29udGFpbmVyIGltZ3tkaXNwbGF5OmJsb2NrfQoKLyog4pSA4pSAIEV4cGlyaW5nIHNvb24gdGFibGUg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5leHAtdGFibGV7YmFja2dyb3VuZDp2YXIoLS1iZzEpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cy1sZyk7b3ZlcmZsb3c6aGlkZGVufQouZXhwLXRhYmxlIGgze3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Zm9udC1zaXplOjExcHg7CiAgICAgICAgICAgICAgZm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXRleHQyKTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjVweH0KCi8qIOKUgOKUgCBMaW5rIHJvdyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KLmxpbmstcm93e2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjZweDtiYWNrZ3JvdW5kOnZhcigtLWJnMCk7CiAgICAgICAgICBwYWRkaW5nOjdweCAxMHB4O2JvcmRlci1yYWRpdXM6dmFyKC0tcmFkaXVzKTttYXJnaW4tdG9wOjhweH0KLmxpbmstcm93IGlucHV0e2ZsZXg6MTtiYWNrZ3JvdW5kOnRyYW5zcGFyZW50O2JvcmRlcjpub25lO2NvbG9yOnZhcigtLWJsdWUpOwogICAgICAgICAgICAgICAgZm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6bW9ub3NwYWNlfQoubGluay1yb3cgaW5wdXQ6Zm9jdXN7b3V0bGluZTpub25lfQoKLyog4pSA4pSAIE5vZGVzIGNoZWNrYm94IGxpc3Qg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5ub2RlLWNoZWNrc3tkaXNwbGF5OmdyaWQ7Z2FwOjNweDttYXgtaGVpZ2h0OjE4MHB4O292ZXJmbG93LXk6YXV0bztwYWRkaW5nLXJpZ2h0OjNweH0KLm5jaGVja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo3cHg7YmFja2dyb3VuZDp2YXIoLS1iZzApOwogICAgICAgIHBhZGRpbmc6NXB4IDhweDtib3JkZXItcmFkaXVzOjRweDtmb250LXNpemU6MTFweDtjdXJzb3I6cG9pbnRlcn0KLm5jaGVjayBpbnB1dHthY2NlbnQtY29sb3I6dmFyKC0tYmx1ZSk7Y3Vyc29yOnBvaW50ZXI7ZmxleC1zaHJpbms6MH0KLm5jaGVjayBsYWJlbHtjdXJzb3I6cG9pbnRlcjtjb2xvcjp2YXIoLS10ZXh0Mik7ZmxleDoxO292ZXJmbG93OmhpZGRlbjsKICAgICAgICAgICAgICB0ZXh0LW92ZXJmbG93OmVsbGlwc2lzO3doaXRlLXNwYWNlOm5vd3JhcH0KLm5jaGVjazpob3ZlciBsYWJlbHtjb2xvcjp2YXIoLS10ZXh0KX0KLmNoZWNrLWFjdHN7ZGlzcGxheTpmbGV4O2dhcDo0cHg7bWFyZ2luLWJvdHRvbTo1cHh9Ci5jYS1idG57Zm9udC1zaXplOjEwcHg7cGFkZGluZzoycHggN3B4O2JhY2tncm91bmQ6dmFyKC0tYmczKTtjb2xvcjp2YXIoLS1ibHVlKTsKICAgICAgICBib3JkZXI6MXB4IHNvbGlkICM1YjhhZjUyMDtib3JkZXItcmFkaXVzOjNweDtjdXJzb3I6cG9pbnRlcn0KCi8qIOKUgOKUgCBUb2FzdCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KLnRvYXN0LXdyYXB7cG9zaXRpb246Zml4ZWQ7dG9wOjE2cHg7cmlnaHQ6MTZweDt6LWluZGV4Ojk5OTk7ZGlzcGxheTpmbGV4OwogICAgICAgICAgICBmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjZweDtwb2ludGVyLWV2ZW50czpub25lfQoudG9hc3R7cGFkZGluZzo5cHggMTRweDtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwOwogICAgICAgYm94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO2FuaW1hdGlvbjpzbGlkZS1pbiAuMnMgZWFzZTtwb2ludGVyLWV2ZW50czphdXRvOwogICAgICAgbWF4LXdpZHRoOjMyMHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjZweH0KLnRvYXN0LXN1Y2Nlc3N7YmFja2dyb3VuZDojMWEzYTJhO2NvbG9yOnZhcigtLWdyZWVuKTtib3JkZXI6MXB4IHNvbGlkICMzZGQ2OGMzMH0KLnRvYXN0LWVycm9ye2JhY2tncm91bmQ6IzNhMWExYTtjb2xvcjp2YXIoLS1yZWQpO2JvcmRlcjoxcHggc29saWQgI2YwNWY1ZjMwfQoudG9hc3QtaW5mb3tiYWNrZ3JvdW5kOiMxYTFhM2E7Y29sb3I6dmFyKC0tYmx1ZSk7Ym9yZGVyOjFweCBzb2xpZCAjNWI4YWY1MzB9CkBrZXlmcmFtZXMgc2xpZGUtaW57ZnJvbXt0cmFuc2Zvcm06dHJhbnNsYXRlWCgxMTAlKTtvcGFjaXR5OjB9dG97dHJhbnNmb3JtOnRyYW5zbGF0ZVgoMCk7b3BhY2l0eToxfX0KQGtleWZyYW1lcyBzbGlkZS1vdXR7ZnJvbXtvcGFjaXR5OjF9dG97dHJhbnNmb3JtOnRyYW5zbGF0ZVgoMTEwJSk7b3BhY2l0eTowfX0KCi8qIOKUgOKUgCBNaXNjIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwouZW1wdHl7cGFkZGluZzo0MHB4O3RleHQtYWxpZ246Y2VudGVyO2NvbG9yOnZhcigtLXRleHQzKTtmb250LXNpemU6MTNweH0KLnNlcHtib3JkZXI6bm9uZTtib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO21hcmdpbjoxNHB4IDB9Ci5pbmxpbmUtZm9ybXtkaXNwbGF5OmlubGluZX0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KCjwhLS0gU2lkZWJhciAtLT4KPGFzaWRlIGNsYXNzPSJzaWRlYmFyIj4KICA8ZGl2IGNsYXNzPSJzaWRlYmFyLWxvZ28iPgogICAgPGRpdiBjbGFzcz0ibG9nby10aXRsZSI+4pqhIGFteXIgcGFuZWwg4pqhPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJsb2dvLXN1YiI+e3sgdGl0bGUgfX08L2Rpdj4KICA8L2Rpdj4KICA8bmF2IGNsYXNzPSJzaWRlYmFyLW5hdiI+CiAgICA8ZGl2IGNsYXNzPSJuYXYtc2VjdGlvbiI+0J7RgdC90L7QstC90L7QtTwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gYWN0aXZlIiBkYXRhLXNlY3Rpb249ImRhc2hib2FyZCIgb25jbGljaz0ibmF2KHRoaXMpIj4KICAgICAgPHNwYW4gY2xhc3M9Im5hdi1pY29uIj7wn5OKPC9zcGFuPiBEYXNoYm9hcmQKICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIGRhdGEtc2VjdGlvbj0idXNlcnMiIG9uY2xpY2s9Im5hdih0aGlzKSI+CiAgICAgIDxzcGFuIGNsYXNzPSJuYXYtaWNvbiI+8J+RpTwvc3Bhbj4g0J/QvtC70YzQt9C+0LLQsNGC0LXQu9C4CiAgICAgIDxzcGFuIGNsYXNzPSJuYXYtYmFkZ2UiIGlkPSJuYXYtZXhwaXJlZC1jbnQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjwvc3Bhbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LXNlY3Rpb24iPtCh0LjRgdGC0LXQvNCwPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgZGF0YS1zZWN0aW9uPSJub2RlcyIgb25jbGljaz0ibmF2KHRoaXMpIj4KICAgICAgPHNwYW4gY2xhc3M9Im5hdi1pY29uIj7wn5al77iPPC9zcGFuPiDQndC+0LTRiwogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgZGF0YS1zZWN0aW9uPSJsb2dzIiBvbmNsaWNrPSJuYXYodGhpcykiPgogICAgICA8c3BhbiBjbGFzcz0ibmF2LWljb24iPvCfk4s8L3NwYW4+INCb0L7Qs9C4CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBkYXRhLXNlY3Rpb249InNldHRpbmdzIiBvbmNsaWNrPSJuYXYodGhpcykiPgogICAgICA8c3BhbiBjbGFzcz0ibmF2LWljb24iPuKame+4jzwvc3Bhbj4g0J3QsNGB0YLRgNC+0LnQutC4CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1zZWN0aW9uIj7QktC90LXRiNC90LjQtTwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9IndpbmRvdy5vcGVuKCdodHRwczovLzg5LjEwNy4xMC4yMDY6MzY0MzEvSTJyU0o2dzhqVFZ1TlVUV1hrLycsJ19ibGFuaycpIj4KICAgICAgPHNwYW4gY2xhc3M9Im5hdi1pY29uIj7wn5OhPC9zcGFuPiAzeC11aQogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0id2luZG93Lm9wZW4oJ2h0dHA6Ly84OS4xMDcuMTAuMjA2OjUwMDEvcGFuZWwvc3BlZWQnLCdfYmxhbmsnKSI+CiAgICAgIDxzcGFuIGNsYXNzPSJuYXYtaWNvbiI+4pqhPC9zcGFuPiBTcGVlZCBNb25pdG9yCiAgICA8L2Rpdj4KICA8L25hdj4KICA8ZGl2IGNsYXNzPSJzaWRlYmFyLWZvb3RlciI+CiAgICA8YSBocmVmPSIvYXBpL2V4cG9ydC9jc3YiPuKsh++4jyDQrdC60YHQv9C+0YDRgiBDU1Y8L2E+CiAgICAmbmJzcDt8Jm5ic3A7CiAgICA8YSBocmVmPSIvbG9nb3V0IiBzdHlsZT0iY29sb3I6dmFyKC0tcmVkKSI+8J+aqiDQktGL0LnRgtC4PC9hPgogIDwvZGl2Pgo8L2FzaWRlPgoKPCEtLSBNYWluIC0tPgo8ZGl2IGNsYXNzPSJtYWluIj4KICA8ZGl2IGNsYXNzPSJ0b3BiYXIiPgogICAgPHNwYW4gY2xhc3M9InBhZ2UtdGl0bGUiIGlkPSJwYWdlLXRpdGxlIj5EYXNoYm9hcmQ8L3NwYW4+CiAgICA8ZGl2IGNsYXNzPSJ0b3BiYXItcmlnaHQiPgogICAgICA8c3BhbiBjbGFzcz0iZG90LWxpdmUiPjwvc3Bhbj4KICAgICAgPHNwYW4gc3R5bGU9ImZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLXRleHQzKSIgaWQ9ImxpdmUtdGltZSI+PC9zcGFuPgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDxkaXYgY2xhc3M9ImNvbnRlbnQiPgoKICAgIDwhLS0g4pSA4pSAIERBU0hCT0FSRCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgLS0+CiAgICA8c2VjdGlvbiBjbGFzcz0ic2VjdGlvbiBhY3RpdmUiIGlkPSJzLWRhc2hib2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmRzIiBpZD0iZGFzaC1jYXJkcyI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iY2FyZC1sYWJlbCI+Q1BVPC9kaXY+PGRpdiBjbGFzcz0iY2FyZC12YWwgYy1ibHVlIiBpZD0iZC1jcHUiPuKAlDwvZGl2PjxkaXYgY2xhc3M9Im1pbmktYmFyIj48ZGl2IGNsYXNzPSJtaW5pLWZpbGwiIGlkPSJkLWNwdS1iYXIiIHN0eWxlPSJiYWNrZ3JvdW5kOnZhcigtLWJsdWUpO3dpZHRoOjAlIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjYXJkIj48ZGl2IGNsYXNzPSJjYXJkLWxhYmVsIj5SQU08L2Rpdj48ZGl2IGNsYXNzPSJjYXJkLXZhbCBjLWdyZWVuIiBpZD0iZC1tZW0iPuKAlDwvZGl2PjxkaXYgY2xhc3M9ImNhcmQtc3ViIiBpZD0iZC1tZW0tZCI+4oCUPC9kaXY+PGRpdiBjbGFzcz0ibWluaS1iYXIiPjxkaXYgY2xhc3M9Im1pbmktZmlsbCIgaWQ9ImQtbWVtLWJhciIgc3R5bGU9ImJhY2tncm91bmQ6dmFyKC0tZ3JlZW4pO3dpZHRoOjAlIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjYXJkIj48ZGl2IGNsYXNzPSJjYXJkLWxhYmVsIj7QlNC40YHQujwvZGl2PjxkaXYgY2xhc3M9ImNhcmQtdmFsIGMtb3JhbmdlIiBpZD0iZC1kaXNrIj7igJQ8L2Rpdj48ZGl2IGNsYXNzPSJjYXJkLXN1YiIgaWQ9ImQtZGlzay1kIj7igJQ8L2Rpdj48ZGl2IGNsYXNzPSJtaW5pLWJhciI+PGRpdiBjbGFzcz0ibWluaS1maWxsIiBpZD0iZC1kaXNrLWJhciIgc3R5bGU9ImJhY2tncm91bmQ6dmFyKC0tb3JhbmdlKTt3aWR0aDowJSI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iY2FyZC1sYWJlbCI+0KHQtdGC0Ywg4oaRPC9kaXY+PGRpdiBjbGFzcz0iY2FyZC12YWwgYy1jeWFuIiBpZD0iZC1zZW50Ij7igJQ8L2Rpdj48ZGl2IGNsYXNzPSJjYXJkLXN1YiBjLXB1cnBsZSIgaWQ9ImQtcmVjdiI+4oaTIOKAlDwvZGl2PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImNhcmQtbGFiZWwiPlVwdGltZTwvZGl2PjxkaXYgY2xhc3M9ImNhcmQtdmFsIGMtZ3JlZW4iIHN0eWxlPSJmb250LXNpemU6MTNweDtwYWRkaW5nLXRvcDo0cHgiIGlkPSJkLXVwdGltZSI+4oCUPC9kaXY+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iY2FyZC1sYWJlbCI+0JDQutGC0LjQstC90YvRhTwvZGl2PjxkaXYgY2xhc3M9ImNhcmQtdmFsIGMtZ3JlZW4iIGlkPSJkLWFjdGl2ZSI+4oCUPC9kaXY+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0iY2FyZC1sYWJlbCI+0JjRgdGC0LXQutGI0LjRhTwvZGl2PjxkaXYgY2xhc3M9ImNhcmQtdmFsIGMtcmVkIiBpZD0iZC1leHBpcmVkIj7igJQ8L2Rpdj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjYXJkIj48ZGl2IGNsYXNzPSJjYXJkLWxhYmVsIj7QntGC0LrQu9GO0YfRkdC90L3Ri9GFPC9kaXY+PGRpdiBjbGFzcz0iY2FyZC12YWwgYy1vcmFuZ2UiIGlkPSJkLWRpc2FibGVkIj7igJQ8L2Rpdj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjYXJkIj48ZGl2IGNsYXNzPSJjYXJkLWxhYmVsIj7QotGA0LDRhNC40Log4oiRPC9kaXY+PGRpdiBjbGFzcz0iY2FyZC12YWwgYy1wdXJwbGUiIGlkPSJkLXRyYWZmaWMiPuKAlDwvZGl2PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImNhcmQtbGFiZWwiPtCS0YHQtdCz0L48L2Rpdj48ZGl2IGNsYXNzPSJjYXJkLXZhbCBjLWJsdWUiIGlkPSJkLXRvdGFsIj7igJQ8L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CgogICAgICA8ZGl2IGNsYXNzPSJleHAtdGFibGUiIGlkPSJleHAtc29vbi13cmFwIiBzdHlsZT0iZGlzcGxheTpub25lO21hcmdpbi10b3A6NHB4Ij4KICAgICAgICA8aDM+4pqg77iPINCY0YHRgtC10LrQsNGO0YIg0LIg0YLQtdGH0LXQvdC40LUgNyDQtNC90LXQuTwvaDM+CiAgICAgICAgPHRhYmxlPjx0aGVhZD48dHI+CiAgICAgICAgICA8dGg+0JjQvNGPPC90aD48dGg+0KHRgtCw0YLRg9GBPC90aD48dGg+0JjRgdGC0LXQutCw0LXRgjwvdGg+PHRoPtCe0YHRgtCw0LvQvtGB0Yw8L3RoPjx0aD48L3RoPgogICAgICAgIDwvdHI+PC90aGVhZD4KICAgICAgICA8dGJvZHkgaWQ9ImV4cC1zb29uLWJvZHkiPjwvdGJvZHk+PC90YWJsZT4KICAgICAgPC9kaXY+CiAgICA8L3NlY3Rpb24+CgogICAgPCEtLSDilIDilIAgVVNFUlMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIC0tPgogICAgPHNlY3Rpb24gY2xhc3M9InNlY3Rpb24iIGlkPSJzLXVzZXJzIj4KICAgICAgPGRpdiBjbGFzcz0iZmlsdGVyLWJhciI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VhcmNoLWJveCI+CiAgICAgICAgICA8c3BhbiBjbGFzcz0ic2VhcmNoLWljb24iPvCflI08L3NwYW4+CiAgICAgICAgICA8aW5wdXQgdHlwZT0idGV4dCIgaWQ9InUtc2VhcmNoIiBwbGFjZWhvbGRlcj0i0J/QvtC40YHQuiDQv9C+INC40LzQtdC90LgsINGC0LXQs9GDLi4uIiBvbmlucHV0PSJkZWJvdW5jZWRMb2FkKCkiPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZpbHRlci10YWJzIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZ0YWIgYWN0IiBkYXRhLXM9ImFsbCIgb25jbGljaz0ic2V0RmlsdGVyKHRoaXMpIj7QktGB0LU8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZ0YWIiIGRhdGEtcz0iYWN0aXZlIiBvbmNsaWNrPSJzZXRGaWx0ZXIodGhpcykiPtCQ0LrRgtC40LLQvdGL0LU8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZ0YWIiIGRhdGEtcz0iZXhwaXJlZCIgb25jbGljaz0ic2V0RmlsdGVyKHRoaXMpIj7QmNGB0YLQtdC60YjQuNC1PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmdGFiIiBkYXRhLXM9ImRpc2FibGVkIiBvbmNsaWNrPSJzZXRGaWx0ZXIodGhpcykiPtCe0YLQutC7LjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZnRhYiIgZGF0YS1zPSJ0cmFmZmljX2V4Y2VlZGVkIiBvbmNsaWNrPSJzZXRGaWx0ZXIodGhpcykiPtCb0LjQvNC40YI8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c2VsZWN0IGNsYXNzPSJzb3J0LXNlbGVjdCIgaWQ9InUtc29ydCIgb25jaGFuZ2U9ImxvYWRVc2VycygpIj4KICAgICAgICAgIDxvcHRpb24gdmFsdWU9ImNyZWF0ZWRfYXQiPtCU0LDRgtCwINGB0L7Qt9C00LDQvdC40Y88L29wdGlvbj4KICAgICAgICAgIDxvcHRpb24gdmFsdWU9ImV4cGlyZXNfYXQiPtCY0YHRgtC10YfQtdC90LjQtTwvb3B0aW9uPgogICAgICAgICAgPG9wdGlvbiB2YWx1ZT0ibmFtZSI+0JjQvNGPPC9vcHRpb24+CiAgICAgICAgICA8b3B0aW9uIHZhbHVlPSJ0cmFmZmljX3VzZWQiPtCi0YDQsNGE0LjQujwvb3B0aW9uPgogICAgICAgIDwvc2VsZWN0PgogICAgICAgIDxkaXYgY2xhc3M9Im1sLWF1dG8iIHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjZweCI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLXByaW1hcnkiIG9uY2xpY2s9Im9wZW5DcmVhdGVNb2RhbCgpIj7vvIsg0KHQvtC30LTQsNGC0Yw8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CgogICAgICA8ZGl2IGNsYXNzPSJ0YWJsZS13cmFwIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWJsZS1oZWFkIj4KICAgICAgICAgIDxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNoay1hbGwiIG9uY2hhbmdlPSJ0b2dnbGVBbGwodGhpcykiIHN0eWxlPSJhY2NlbnQtY29sb3I6dmFyKC0tYmx1ZSkiPgogICAgICAgICAgPHN0cm9uZyBpZD0idS1jb3VudCI+MCDQv9C+0LvRjNC30L7QstCw0YLQtdC70LXQuTwvc3Ryb25nPgogICAgICAgICAgPHNwYW4gc3R5bGU9ImNvbG9yOnZhcigtLXRleHQzKTtmb250LXNpemU6MTBweDttYXJnaW4tbGVmdDo0cHgiIGlkPSJ1LWNvdW50LXN1YiI+PC9zcGFuPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9Im92ZXJmbG93LXg6YXV0byI+CiAgICAgICAgPHRhYmxlPgogICAgICAgICAgPHRoZWFkPjx0cj4KICAgICAgICAgICAgPHRoIGNsYXNzPSJjb2wtY2hlY2siPjwvdGg+CiAgICAgICAgICAgIDx0aCBvbmNsaWNrPSJzb3J0QnkoJ25hbWUnKSI+0JjQvNGPPC90aD4KICAgICAgICAgICAgPHRoPlVzZXJuYW1lPC90aD4KICAgICAgICAgICAgPHRoIG9uY2xpY2s9InNvcnRCeSgnc3RhdHVzJykiPtCh0YLQsNGC0YPRgTwvdGg+CiAgICAgICAgICAgIDx0aCBvbmNsaWNrPSJzb3J0QnkoJ2V4cGlyZXNfYXQnKSI+0JjRgdGC0LXQutCw0LXRgjwvdGg+CiAgICAgICAgICAgIDx0aCBvbmNsaWNrPSJzb3J0QnkoJ3RyYWZmaWNfdXNlZCcpIj7QotGA0LDRhNC40Lo8L3RoPgogICAgICAgICAgICA8dGg+0KLQtdCz0Lg8L3RoPgogICAgICAgICAgICA8dGg+0JTQtdC50YHRgtCy0LjRjzwvdGg+CiAgICAgICAgICA8L3RyPjwvdGhlYWQ+CiAgICAgICAgICA8dGJvZHkgaWQ9InVzZXJzLXRib2R5Ij4KICAgICAgICAgICAgPHRyPjx0ZCBjb2xzcGFuPSI4IiBjbGFzcz0iZW1wdHkiPtCX0LDQs9GA0YPQt9C60LAuLi48L3RkPjwvdHI+CiAgICAgICAgICA8L3Rib2R5PgogICAgICAgIDwvdGFibGU+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGFnaW5hdGlvbiIgaWQ9InUtcGFnaW5hdGlvbiI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9zZWN0aW9uPgoKICAgIDwhLS0g4pSA4pSAIE5PREVTIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAtLT4KICAgIDxzZWN0aW9uIGNsYXNzPSJzZWN0aW9uIiBpZD0icy1ub2RlcyI+CiAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6ZmxleC1lbmQ7bWFyZ2luLWJvdHRvbToxMnB4Ij4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLXByaW1hcnkiIG9uY2xpY2s9Im9wZW5Ob2RlTW9kYWwoKSI+77yLINCU0L7QsdCw0LLQuNGC0Ywg0L3QvtC00YM8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im5vZGVzLWdyaWQiIGlkPSJub2Rlcy1ncmlkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJlbXB0eSI+0JfQsNCz0YDRg9C30LrQsC4uLjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvc2VjdGlvbj4KCiAgICA8IS0tIOKUgOKUgCBMT0dTIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAtLT4KICAgIDxzZWN0aW9uIGNsYXNzPSJzZWN0aW9uIiBpZD0icy1sb2dzIj4KICAgICAgPGRpdiBjbGFzcz0idGFibGUtd3JhcCI+CiAgICAgICAgPGRpdiBjbGFzcz0idGFibGUtaGVhZCI+PHN0cm9uZz7Qm9C+0LMg0LTQtdC50YHRgtCy0LjQuTwvc3Ryb25nPjwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9Im92ZXJmbG93LXg6YXV0byI+CiAgICAgICAgPHRhYmxlPgogICAgICAgICAgPHRoZWFkPjx0cj4KICAgICAgICAgICAgPHRoPtCS0YDQtdC80Y88L3RoPjx0aD7QlNC10LnRgdGC0LLQuNC1PC90aD48dGg+0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMPC90aD48dGg+0JTQtdGC0LDQu9C4PC90aD4KICAgICAgICAgIDwvdHI+PC90aGVhZD4KICAgICAgICAgIDx0Ym9keSBpZD0ibG9ncy10Ym9keSI+CiAgICAgICAgICAgIDx0cj48dGQgY29sc3Bhbj0iNCIgY2xhc3M9ImVtcHR5Ij7Ql9Cw0LPRgNGD0LfQutCwLi4uPC90ZD48L3RyPgogICAgICAgICAgPC90Ym9keT4KICAgICAgICA8L3RhYmxlPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBhZ2luYXRpb24iIGlkPSJsb2ctcGFnaW5hdGlvbiI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9zZWN0aW9uPgoKICAgIDwhLS0g4pSA4pSAIFNFVFRJTkdTIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAtLT4KICAgIDxzZWN0aW9uIGNsYXNzPSJzZWN0aW9uIiBpZD0icy1zZXR0aW5ncyI+CiAgICAgIDxkaXYgY2xhc3M9InNldHRpbmdzLWdyaWQiPgogICAgICAgIDxkaXYgY2xhc3M9InNldHRpbmdzLWNhcmQiPgogICAgICAgICAgPGgzPvCfjJAg0KHQtdGA0LLQtdGAPC9oMz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZnIj48bGFiZWw+QmFzZSBVUkwgKNC00LvRjyDRgdGB0YvQu9C+0Log0L/QvtC00L/QuNGB0L7Quik8L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgaWQ9InNldC1iYXNlLXVybCIgcGxhY2Vob2xkZXI9Imh0dHA6Ly84OS4xMDcuMTAuMjA2OjEwODgiPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGxhYmVsPtCX0LDQs9C+0LvQvtCy0L7QuiDQv9Cw0L3QtdC70Lg8L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgaWQ9InNldC10aXRsZSIgcGxhY2Vob2xkZXI9IlZQTiBTdWIgTWFuYWdlciI+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZnIj48bGFiZWw+R3JhY2UgcGVyaW9kICjQtNC90LXQuSDQv9C+0YHQu9C1INC40YHRgtC10YfQtdC90LjRjyk8L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgdHlwZT0ibnVtYmVyIiBpZD0ic2V0LWdyYWNlIiB2YWx1ZT0iMCIgbWluPSIwIj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNldHRpbmdzLWNhcmQiPgogICAgICAgICAgPGgzPvCfk6Yg0JTQtdGE0L7Qu9GC0Ys8L2gzPgogICAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxsYWJlbD7QlNC90LXQuSDQv9C+INGD0LzQvtC70YfQsNC90LjRjiDQtNC70Y8g0L3QvtCy0YvRhSDQv9C+0LvRjNC30L7QstCw0YLQtdC70LXQuTwvbGFiZWw+CiAgICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZmlucHV0IiB0eXBlPSJudW1iZXIiIGlkPSJzZXQtZGVmLWRheXMiIHZhbHVlPSIzMCIgbWluPSIxIj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxsYWJlbD7Qm9C40LzQuNGCINGC0YDQsNGE0LjQutCwINC/0L4g0YPQvNC+0LvRh9Cw0L3QuNGOICjQk9CRLCAwID0g4oieKTwvbGFiZWw+CiAgICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZmlucHV0IiB0eXBlPSJudW1iZXIiIGlkPSJzZXQtZGVmLXRyYWZmaWMiIHZhbHVlPSIwIiBtaW49IjAiPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2V0dGluZ3MtY2FyZCI+CiAgICAgICAgICA8aDM+4pqg77iPINCa0L7QvdGE0LjQsyDQtNC70Y8g0LjRgdGC0ZHQutGI0LjRhTwvaDM+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGxhYmVsPlZMRVNTL1ZNRVNTINGB0YLRgNC+0LrQsCAo0L/QvtC60LDQt9GL0LLQsNC10YLRgdGPINC/0YDQuCDQuNGB0YLQtdGH0LXQvdC40LgpPC9sYWJlbD4KICAgICAgICAgICAgPHRleHRhcmVhIGNsYXNzPSJmaW5wdXQiIGlkPSJzZXQtZXhwaXJlZC1jZmciIHJvd3M9IjMiPjwvdGV4dGFyZWE+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZXR0aW5ncy1jYXJkIj4KICAgICAgICAgIDxoMz7wn5OxIFRlbGVncmFtICjRg9Cy0LXQtNC+0LzQu9C10L3QuNGPKTwvaDM+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGxhYmVsPkJvdCBUb2tlbjwvbGFiZWw+CiAgICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZmlucHV0IiBpZD0ic2V0LXRnLXRva2VuIiBwbGFjZWhvbGRlcj0iMTIzNDU2Nzg5MDpBQkMuLi4iPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGxhYmVsPkNoYXQgSUQ8L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgaWQ9InNldC10Zy1jaGF0IiBwbGFjZWhvbGRlcj0iLTEwMC4uLiI+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9Im1hcmdpbi10b3A6MTRweCI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1wcmltYXJ5IiBvbmNsaWNrPSJzYXZlU2V0dGluZ3MoKSI+8J+SviDQodC+0YXRgNCw0L3QuNGC0Ywg0L3QsNGB0YLRgNC+0LnQutC4PC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgPC9zZWN0aW9uPgoKICA8L2Rpdj4KPC9kaXY+Cgo8IS0tIOKUgOKUgCBCdWxrIGJhciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgLS0+CjxkaXYgY2xhc3M9ImJ1bGstYmFyIiBpZD0iYnVsay1iYXIiPgogIDxzcGFuIGNsYXNzPSJidWxrLWxhYmVsIiBpZD0iYnVsay1sYWJlbCI+MCDQstGL0LHRgNCw0L3Qvjwvc3Bhbj4KICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWdob3N0IGJ0bi1zbSIgb25jbGljaz0iYnVsa0FjdGlvbignZW5hYmxlJykiPuKchSDQktC60LvRjtGH0LjRgtGMPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1naG9zdCBidG4tc20iIG9uY2xpY2s9ImJ1bGtBY3Rpb24oJ2Rpc2FibGUnKSI+4o+4INCS0YvQutC70Y7Rh9C40YLRjDwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9ImJ0biBidG4tZ2hvc3QgYnRuLXNtIiBvbmNsaWNrPSJidWxrQWN0aW9uKCdleHRlbmRfMzAnKSI+KzMw0LQ8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWdob3N0IGJ0bi1zbSIgb25jbGljaz0iYnVsa0FjdGlvbigncmVzZXRfdHJhZmZpYycpIj7wn5SEINCi0YDQsNGE0LjQujwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9ImJ0biBidG4tZGFuZ2VyIGJ0bi1zbSIgb25jbGljaz0iYnVsa0FjdGlvbignZGVsZXRlJykiPvCfl5HvuI8g0KPQtNCw0LvQuNGC0Yw8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWdob3N0IGJ0bi1zbSIgc3R5bGU9Im1hcmdpbi1sZWZ0OmF1dG8iIG9uY2xpY2s9ImNsZWFyU2VsKCkiPuKcljwvYnV0dG9uPgo8L2Rpdj4KCjwhLS0g4pSA4pSAIENyZWF0ZS9FZGl0IFVzZXIgTW9kYWwg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIC0tPgo8ZGl2IGNsYXNzPSJvdmVybGF5IiBpZD0idXNlci1tb2RhbCI+CiAgPGRpdiBjbGFzcz0ibW9kYWwiIHN0eWxlPSJtYXgtd2lkdGg6NjYwcHgiPgogICAgPGRpdiBjbGFzcz0ibWhlYWQiPgogICAgICA8aDIgaWQ9InVtLXRpdGxlIj7QodC+0LfQtNCw0YLRjCDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y88L2gyPgogICAgICA8YnV0dG9uIGNsYXNzPSJtY2xvc2UiIG9uY2xpY2s9ImNsb3NlVXNlck1vZGFsKCkiPsOXPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im1ib2R5Ij4KICAgICAgPGRpdiBjbGFzcz0ibXRhYnMiPgogICAgICAgIDxkaXYgY2xhc3M9Im10YWIgYWN0IiBvbmNsaWNrPSJtVGFiKHRoaXMsJ210LWJhc2ljJykiPtCe0YHQvdC+0LLQvdC+0LU8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJtdGFiIiBvbmNsaWNrPSJtVGFiKHRoaXMsJ210LWxpbWl0cycpIj7Qm9C40LzQuNGC0Ys8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJtdGFiIiBvbmNsaWNrPSJtVGFiKHRoaXMsJ210LW5vZGVzJykiPtCd0L7QtNGLPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibXRhYiIgb25jbGljaz0ibVRhYih0aGlzLCdtdC1leHRyYScpIj7Qn9GA0L7Rh9C10LU8L2Rpdj4KICAgICAgPC9kaXY+CgogICAgICA8IS0tIFRhYjogQmFzaWMgLS0+CiAgICAgIDxkaXYgY2xhc3M9Im10YWItcGFuZSBhY3QiIGlkPSJtdC1iYXNpYyI+CiAgICAgICAgPGRpdiBjbGFzcz0idG9nLXJvdyI+CiAgICAgICAgICA8c3BhbiBjbGFzcz0idG9nLWxibCI+0J/QvtC00L/QuNGB0LrQsCDQstC60LvRjtGH0LXQvdCwPC9zcGFuPgogICAgICAgICAgPGxhYmVsIGNsYXNzPSJ0b2ciPjxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9InVtLWVuYWJsZWQiIGNoZWNrZWQ+PHNwYW4gY2xhc3M9InNsZCI+PC9zcGFuPjwvbGFiZWw+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZnIj48bGFiZWw+0JjQvNGPINC60LvQuNC10L3RgtCwICo8L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgaWQ9InVtLW5hbWUiIHBsYWNlaG9sZGVyPSLQmNCy0LDQvSDQmNCy0LDQvdC+0LIiIG9uaW5wdXQ9ImF1dG9Vc2VybmFtZSgpIj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxsYWJlbD5Vc2VybmFtZTwvbGFiZWw+CiAgICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZmlucHV0IiBpZD0idW0tdXNlcm5hbWUiIHBsYWNlaG9sZGVyPSJpdmFuX2l2YW5vdiI+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+CiAgICAgICAgICA8bGFiZWw+0JTQsNGC0LAg0LjRgdGC0LXRh9C10L3QuNGPICo8L2xhYmVsPgogICAgICAgICAgPGlucHV0IGNsYXNzPSJmaW5wdXQiIHR5cGU9ImRhdGV0aW1lLWxvY2FsIiBpZD0idW0tZXhwaXJlcyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwcmVzZXRzIiBpZD0iZXhwLXByZXNldHMiPgogICAgICAgICAgICA8c3BhbiBjbGFzcz0icHJlIiBvbmNsaWNrPSJhZGRFeHBEYXlzKDEpIj4rMdC0PC9zcGFuPgogICAgICAgICAgICA8c3BhbiBjbGFzcz0icHJlIiBvbmNsaWNrPSJhZGRFeHBEYXlzKDcpIj4rN9C0PC9zcGFuPgogICAgICAgICAgICA8c3BhbiBjbGFzcz0icHJlIiBvbmNsaWNrPSJhZGRFeHBEYXlzKDMwKSI+KzMw0LQ8L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJwcmUiIG9uY2xpY2s9ImFkZEV4cERheXMoOTApIj4rOTDQtDwvc3Bhbj4KICAgICAgICAgICAgPHNwYW4gY2xhc3M9InByZSIgb25jbGljaz0iYWRkRXhwRGF5cygxODApIj4rMTgw0LQ8L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIGNsYXNzPSJwcmUiIG9uY2xpY2s9ImFkZEV4cERheXMoMzY1KSI+KzHQszwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDwhLS0gRWRpdCBtb2RlOiBzdWIgbGluayArIFFSIC0tPgogICAgICAgIDxkaXYgaWQ9InVtLWxpbmstc2VjdGlvbiIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgICAgICA8aHIgY2xhc3M9InNlcCI+CiAgICAgICAgICA8bGFiZWwgc3R5bGU9ImZvbnQtc2l6ZToxMHB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjp2YXIoLS10ZXh0Mik7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi41cHgiPtCh0YHRi9C70LrQsCDQv9C+0LTQv9C40YHQutC4PC9sYWJlbD4KICAgICAgICAgIDxkaXYgY2xhc3M9Imxpbmstcm93Ij4KICAgICAgICAgICAgPGlucHV0IHR5cGU9InRleHQiIGlkPSJ1bS1saW5rIiByZWFkb25seT4KICAgICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iaWEgaWEtYmx1ZSIgb25jbGljaz0iY29weVN1YkxpbmsoKSI+8J+TizwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJpYSBpYS1ibHVlIiBvbmNsaWNrPSJzaG93UVIoKSI+UVI8L2J1dHRvbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KCiAgICAgIDwhLS0gVGFiOiBMaW1pdHMgLS0+CiAgICAgIDxkaXYgY2xhc3M9Im10YWItcGFuZSIgaWQ9Im10LWxpbWl0cyI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZnIj48bGFiZWw+0JvQuNC80LjRgiDRgtGA0LDRhNC40LrQsCAo0JPQkSwgMCA9IOKInik8L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgdHlwZT0ibnVtYmVyIiBpZD0idW0tdHJhZmZpYyIgdmFsdWU9IjAiIG1pbj0iMCIgc3RlcD0iMC41Ij4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxsYWJlbD7Qm9C40LzQuNGCINGD0YHRgtGA0L7QudGB0YLQsiAoMCA9IOKInik8L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgdHlwZT0ibnVtYmVyIiBpZD0idW0tZGV2aWNlcyIgdmFsdWU9IjAiIG1pbj0iMCI+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ1bS10cmFmZmljLWluZm8iIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tdGV4dDIpOwogICAgICAgICAgICAgYmFja2dyb3VuZDp2YXIoLS1iZzApO3BhZGRpbmc6OHB4IDExcHg7Ym9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpO21hcmdpbi1ib3R0b206MTJweCI+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1naG9zdCBidG4tc20iIGlkPSJ1bS1yZXNldC1idG4iIG9uY2xpY2s9InJlc2V0VHJhZmZpY0luTW9kYWwoKSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgICAgICDwn5SEINCh0LHRgNC+0YHQuNGC0Ywg0YLRgNCw0YTQuNC6CiAgICAgICAgPC9idXR0b24+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBUYWI6IE5vZGVzIC0tPgogICAgICA8ZGl2IGNsYXNzPSJtdGFiLXBhbmUiIGlkPSJtdC1ub2RlcyI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2hlY2stYWN0cyI+CiAgICAgICAgICA8c3BhbiBjbGFzcz0iY2EtYnRuIiBvbmNsaWNrPSJjaGtBbGxOb2Rlcyh0cnVlKSI+0JLRgdC1PC9zcGFuPgogICAgICAgICAgPHNwYW4gY2xhc3M9ImNhLWJ0biIgb25jbGljaz0iY2hrQWxsTm9kZXMoZmFsc2UpIj7QodC90Y/RgtGMPC9zcGFuPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Im5vZGUtY2hlY2tzIiBpZD0idW0tbm9kZS1jaGVja3MiPgogICAgICAgICAgPGRpdiBjbGFzcz0iZW1wdHkiPtCd0L7QtNGLINC90LUg0LTQvtCx0LDQstC70LXQvdGLPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBUYWI6IEV4dHJhIC0tPgogICAgICA8ZGl2IGNsYXNzPSJtdGFiLXBhbmUiIGlkPSJtdC1leHRyYSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxsYWJlbD7QotC10LPQuCAo0YfQtdGA0LXQtyDQt9Cw0L/Rj9GC0YPRjik8L2xhYmVsPgogICAgICAgICAgPGlucHV0IGNsYXNzPSJmaW5wdXQiIGlkPSJ1bS10YWdzIiBwbGFjZWhvbGRlcj0icHJlbWl1bSwgcnVzc2lhLCAuLi4iPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48bGFiZWw+0JfQsNC80LXRgtC60LA8L2xhYmVsPgogICAgICAgICAgPHRleHRhcmVhIGNsYXNzPSJmaW5wdXQiIGlkPSJ1bS1ub3RlIiBwbGFjZWhvbGRlcj0i0JvRjtCx0LDRjyDQt9Cw0LzQtdGC0LrQsC4uLiI+PC90ZXh0YXJlYT4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ1bS1kYXRlcyIgc3R5bGU9ImRpc3BsYXk6bm9uZTtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS10ZXh0MykiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibWZvb3QiPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWdob3N0IiBvbmNsaWNrPSJjbG9zZVVzZXJNb2RhbCgpIj7QntGC0LzQtdC90LA8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1wcmltYXJ5IiBvbmNsaWNrPSJzdWJtaXRVc2VyTW9kYWwoKSI+8J+SviDQodC+0YXRgNCw0L3QuNGC0Yw8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjwhLS0g4pSA4pSAIE5vZGUgTW9kYWwg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIC0tPgo8ZGl2IGNsYXNzPSJvdmVybGF5IiBpZD0ibm9kZS1tb2RhbCI+CiAgPGRpdiBjbGFzcz0ibW9kYWwiIHN0eWxlPSJtYXgtd2lkdGg6NTAwcHgiPgogICAgPGRpdiBjbGFzcz0ibWhlYWQiPgogICAgICA8aDIgaWQ9Im5tLXRpdGxlIj7QlNC+0LHQsNCy0LjRgtGMINC90L7QtNGDPC9oMj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbG9zZU5vZGVNb2RhbCgpIj7DlzwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJtYm9keSI+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48bGFiZWw+0J3QsNC30LLQsNC90LjQtSAqPC9sYWJlbD4KICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgaWQ9Im5tLW5hbWUiIHBsYWNlaG9sZGVyPSJGR04gU2VydmVyIDEiPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxsYWJlbD7QotC40L88L2xhYmVsPgogICAgICAgIDxzZWxlY3QgY2xhc3M9ImZpbnB1dCIgaWQ9Im5tLXR5cGUiIG9uY2hhbmdlPSJubVR5cGVDaGFuZ2UoKSI+CiAgICAgICAgICA8b3B0aW9uIHZhbHVlPSJ1cmwiPlVSTCDQv9C+0LTQv9C40YHQutC4IChodHRwL2h0dHBzKTwvb3B0aW9uPgogICAgICAgICAgPG9wdGlvbiB2YWx1ZT0icmF3Ij5SYXcg0LrQvtC90YTQuNCz0LggKHZsZXNzOi8vLCB2bWVzczovLywgc3M6Ly8uLi4pPC9vcHRpb24+CiAgICAgICAgPC9zZWxlY3Q+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyIgaWQ9Im5tLXVybC13cmFwIj48bGFiZWw+VVJMINC/0L7QtNC/0LjRgdC60Lg8L2xhYmVsPgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmlucHV0IiBpZD0ibm0tdXJsIiBwbGFjZWhvbGRlcj0iaHR0cHM6Ly9zdWIuZXhhbXBsZS5jb20vc3ViL3Rva2VuIj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIiBpZD0ibm0tcmF3LXdyYXAiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxsYWJlbD7QmtC+0L3RhNC40LPQuCAo0LrQsNC20LTRi9C5INGBINC90L7QstC+0Lkg0YHRgtGA0L7QutC4KTwvbGFiZWw+CiAgICAgICAgPHRleHRhcmVhIGNsYXNzPSJmaW5wdXQiIGlkPSJubS1yYXciIHJvd3M9IjYiCiAgICAgICAgICBwbGFjZWhvbGRlcj0idmxlc3M6Ly91dWlkQGhvc3Q6cG9ydD8uLi4jbmFtZSYjMTA7dm1lc3M6Ly8uLi4mIzEwO3NzOi8vLi4uIj48L3RleHRhcmVhPgogICAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLXRleHQzKTttYXJnaW4tdG9wOjRweCI+0J/QvtC00LTQtdGA0LbQuNCy0LDRjtGC0YHRjzogdmxlc3M6Ly8sIHZtZXNzOi8vLCBzczovLywgdHJvamFuOi8vLCBoeTI6Ly8sIHR1aWM6Ly88L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48bGFiZWw+0KLQtdCzICjQs9GA0YPQv9C/0LApPC9sYWJlbD4KICAgICAgICA8aW5wdXQgY2xhc3M9ImZpbnB1dCIgaWQ9Im5tLXRhZyIgcGxhY2Vob2xkZXI9ImZnbiwgb3duLCBldGMiPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0idG9nLXJvdyI+CiAgICAgICAgPHNwYW4gY2xhc3M9InRvZy1sYmwiPtCS0LrQu9GO0YfQtdC90LA8L3NwYW4+CiAgICAgICAgPGxhYmVsIGNsYXNzPSJ0b2ciPjxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9Im5tLWVuYWJsZWQiIGNoZWNrZWQ+PHNwYW4gY2xhc3M9InNsZCI+PC9zcGFuPjwvbGFiZWw+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJtZm9vdCI+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tZ2hvc3QiIG9uY2xpY2s9ImNsb3NlTm9kZU1vZGFsKCkiPtCe0YLQvNC10L3QsDwvYnV0dG9uPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLXByaW1hcnkiIG9uY2xpY2s9InN1Ym1pdE5vZGVNb2RhbCgpIj7wn5K+INCh0L7RhdGA0LDQvdC40YLRjDwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+CjwvZGl2PgoKPCEtLSDilIDilIAgUVIgTW9kYWwg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIC0tPgo8ZGl2IGNsYXNzPSJvdmVybGF5IiBpZD0icXItbW9kYWwiPgogIDxkaXYgY2xhc3M9Im1vZGFsIiBzdHlsZT0ibWF4LXdpZHRoOjMwMHB4O3RleHQtYWxpZ246Y2VudGVyIj4KICAgIDxkaXYgY2xhc3M9Im1oZWFkIj4KICAgICAgPGgyIGlkPSJxci1uYW1lIj5RUiDQutC+0LQ8L2gyPgogICAgICA8YnV0dG9uIGNsYXNzPSJtY2xvc2UiIG9uY2xpY2s9ImNsb3NlUVIoKSI+w5c8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibWJvZHkiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlciI+CiAgICAgIDxkaXYgaWQ9InFyLWNvbnRhaW5lciIgY2xhc3M9InFyLXdyYXAiIHN0eWxlPSJkaXNwbGF5OmlubGluZS1ibG9jayI+PC9kaXY+CiAgICAgIDxkaXYgaWQ9InFyLXVybCIgc3R5bGU9ImZvbnQtc2l6ZTo5cHg7Y29sb3I6dmFyKC0tdGV4dDMpO21hcmdpbi10b3A6OHB4O3dvcmQtYnJlYWs6YnJlYWstYWxsIj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjwhLS0g4pSA4pSAIFRvYXN0cyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgLS0+CjxkaXYgY2xhc3M9InRvYXN0LXdyYXAiIGlkPSJ0b2FzdHMiPjwvZGl2PgoKPHNjcmlwdD4KLy8g4pSA4pSA4pSAIFN0YXRlIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjb25zdCBzdGF0ZSA9IHsKICBwYWdlOiAxLCBwZXI6IDI1LCBzb3J0OiAnY3JlYXRlZF9hdCcsIG9yZGVyOiAnZGVzYycsCiAgZmlsdGVyOiAnYWxsJywgc2VhcmNoOiAnJywKICBlZGl0SWQ6IG51bGwsCiAgZWRpdE5vZGVJZDogbnVsbCwKICBub2RlczogW10sCiAgbG9nUGFnZTogMSwKICBzZWxlY3RlZElkczogbmV3IFNldCgpLAp9OwoKLy8g4pSA4pSA4pSAIE5hdmlnYXRpb24g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmZ1bmN0aW9uIG5hdihlbCkgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5uYXYtaXRlbScpLmZvckVhY2gobiA9PiBuLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuc2VjdGlvbicpLmZvckVhY2gocyA9PiBzLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBlbC5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBjb25zdCBzZWMgPSBlbC5kYXRhc2V0LnNlY3Rpb247CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3MtJyArIHNlYykuY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BhZ2UtdGl0bGUnKS50ZXh0Q29udGVudCA9IGVsLnRleHRDb250ZW50LnRyaW0oKTsKICBpZiAoc2VjID09PSAndXNlcnMnKSAgICBsb2FkVXNlcnMoKTsKICBpZiAoc2VjID09PSAnbm9kZXMnKSAgICBsb2FkTm9kZXMoKTsKICBpZiAoc2VjID09PSAnbG9ncycpICAgICBsb2FkTG9ncygpOwogIGlmIChzZWMgPT09ICdzZXR0aW5ncycpIGxvYWRTZXR0aW5ncygpOwp9CgovLyDilIDilIDilIAgVG9hc3Qg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmZ1bmN0aW9uIHRvYXN0KG1zZywgdHlwZT0naW5mbycpIHsKICBjb25zdCBpY29ucyA9IHtzdWNjZXNzOifinIUnLCBlcnJvcjon4p2MJywgaW5mbzon4oS577iPJ307CiAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICBlbC5jbGFzc05hbWUgPSBgdG9hc3QgdG9hc3QtJHt0eXBlfWA7CiAgZWwudGV4dENvbnRlbnQgPSAoaWNvbnNbdHlwZV18fCcnKSArICcgJyArIG1zZzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndG9hc3RzJykuYXBwZW5kQ2hpbGQoZWwpOwogIHNldFRpbWVvdXQoKCkgPT4gewogICAgZWwuc3R5bGUuYW5pbWF0aW9uID0gJ3NsaWRlLW91dCAuMnMgZWFzZSBmb3J3YXJkcyc7CiAgICBzZXRUaW1lb3V0KCgpID0+IGVsLnJlbW92ZSgpLCAyMDApOwogIH0sIDMwMDApOwp9CgovLyDilIDilIDilIAgQVBJIHdyYXBwZXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmFzeW5jIGZ1bmN0aW9uIGFwaShtZXRob2QsIHVybCwgYm9keSkgewogIHRyeSB7CiAgICBjb25zdCBvcHRzID0geyBtZXRob2QsIGhlYWRlcnM6IHsnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pzb24nfSB9OwogICAgaWYgKGJvZHkpIG9wdHMuYm9keSA9IEpTT04uc3RyaW5naWZ5KGJvZHkpOwogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKHVybCwgb3B0cyk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihgSFRUUCAke3Iuc3RhdHVzfWApOwogICAgcmV0dXJuIGF3YWl0IHIuanNvbigpOwogIH0gY2F0Y2goZSkgewogICAgdG9hc3QoJ9Ce0YjQuNCx0LrQsDogJyArIGUubWVzc2FnZSwgJ2Vycm9yJyk7CiAgICByZXR1cm4gbnVsbDsKICB9Cn0KCi8vIOKUgOKUgOKUgCBEYXNoYm9hcmQg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmFzeW5jIGZ1bmN0aW9uIGxvYWREYXNoKCkgewogIGNvbnN0IGQgPSBhd2FpdCBhcGkoJ0dFVCcsICcvYXBpL3N0YXRzJyk7CiAgaWYgKCFkKSByZXR1cm47CiAgY29uc3QgcyA9IGQuc2VydmVyOwogIGVsKCdkLWNwdScpLnRleHRDb250ZW50ID0gcy5jcHUgKyAnJSc7CiAgZWwoJ2QtY3B1LWJhcicpLnN0eWxlLndpZHRoID0gcy5jcHUgKyAnJSc7CiAgZWwoJ2QtbWVtJykudGV4dENvbnRlbnQgPSBzLm1lbV9wZXJjZW50ICsgJyUnOwogIGVsKCdkLW1lbS1kJykudGV4dENvbnRlbnQgPSBzLm1lbV91c2VkICsgJy8nICsgcy5tZW1fdG90YWwgKyAnIEdCJzsKICBlbCgnZC1tZW0tYmFyJykuc3R5bGUud2lkdGggPSBzLm1lbV9wZXJjZW50ICsgJyUnOwogIGVsKCdkLWRpc2snKS50ZXh0Q29udGVudCA9IHMuZGlza19wZXJjZW50ICsgJyUnOwogIGVsKCdkLWRpc2stZCcpLnRleHRDb250ZW50ID0gcy5kaXNrX3VzZWQgKyAnLycgKyBzLmRpc2tfdG90YWwgKyAnIEdCJzsKICBlbCgnZC1kaXNrLWJhcicpLnN0eWxlLndpZHRoID0gcy5kaXNrX3BlcmNlbnQgKyAnJSc7CiAgZWwoJ2Qtc2VudCcpLnRleHRDb250ZW50ID0gJ+KGkSAnICsgcy5uZXRfc2VudCArICcgR0InOwogIGVsKCdkLXJlY3YnKS50ZXh0Q29udGVudCA9ICfihpMgJyArIHMubmV0X3JlY3YgKyAnIEdCJzsKICBlbCgnZC11cHRpbWUnKS50ZXh0Q29udGVudCA9IHMudXB0aW1lOwogIGNvbnN0IHUgPSBkLnVzZXJzOwogIGVsKCdkLWFjdGl2ZScpLnRleHRDb250ZW50ICAgPSB1LmFjdGl2ZTsKICBlbCgnZC1leHBpcmVkJykudGV4dENvbnRlbnQgID0gdS5leHBpcmVkOwogIGVsKCdkLWRpc2FibGVkJykudGV4dENvbnRlbnQgPSB1LmRpc2FibGVkOwogIGVsKCdkLXRvdGFsJykudGV4dENvbnRlbnQgICAgPSB1LnRvdGFsOwogIGVsKCdkLXRyYWZmaWMnKS50ZXh0Q29udGVudCAgPSBkLnRyYWZmaWNfdG90YWxfZ2IgKyAnIEdCJzsKCiAgLy8gdXBkYXRlIG5hdiBiYWRnZQogIGNvbnN0IGV4cEJhZGdlID0gZWwoJ25hdi1leHBpcmVkLWNudCcpOwogIGlmICh1LmV4cGlyZWQgKyB1LnRyYWZmaWNfZXhjZWVkZWQgPiAwKSB7CiAgICBleHBCYWRnZS50ZXh0Q29udGVudCA9IHUuZXhwaXJlZCArIHUudHJhZmZpY19leGNlZWRlZDsKICAgIGV4cEJhZGdlLnN0eWxlLmRpc3BsYXkgPSAnJzsKICB9IGVsc2UgewogICAgZXhwQmFkZ2Uuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICB9CgogIC8vIGV4cGlyaW5nIHNvb24KICBjb25zdCBzb29uID0gZC5leHBpcmluZ19zb29uOwogIGNvbnN0IHdyYXAgPSBlbCgnZXhwLXNvb24td3JhcCcpOwogIGlmIChzb29uICYmIHNvb24ubGVuZ3RoID4gMCkgewogICAgd3JhcC5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICBlbCgnZXhwLXNvb24tYm9keScpLmlubmVySFRNTCA9IHNvb24ubWFwKHUgPT4gYAogICAgICA8dHI+CiAgICAgICAgPHRkPjxzdHJvbmc+JHtlc2ModS5kaXNwbGF5X25hbWUpfTwvc3Ryb25nPjwvdGQ+CiAgICAgICAgPHRkPiR7c3RhdHVzQmFkZ2UodS5zdGF0dXMpfTwvdGQ+CiAgICAgICAgPHRkIHN0eWxlPSJmb250LXNpemU6MTFweCI+JHt1LmV4cGlyZXNfZGlzcGxheX08L3RkPgogICAgICAgIDx0ZCBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tb3JhbmdlKSI+JHt1LnRpbWVfbGVmdH08L3RkPgogICAgICAgIDx0ZD48YnV0dG9uIGNsYXNzPSJpYSBpYS1ibHVlIiBvbmNsaWNrPSJxdWlja0VkaXQoJyR7dS5pZH0nKSI+4pyP77iPPC9idXR0b24+PC90ZD4KICAgICAgPC90cj5gKS5qb2luKCcnKTsKICB9IGVsc2UgewogICAgd3JhcC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIH0KfQoKLy8g4pSA4pSA4pSAIFVzZXJzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsZXQgZGViVGltZXI7CmZ1bmN0aW9uIGRlYm91bmNlZExvYWQoKSB7CiAgY2xlYXJUaW1lb3V0KGRlYlRpbWVyKTsKICBkZWJUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4geyBzdGF0ZS5wYWdlID0gMTsgbG9hZFVzZXJzKCk7IH0sIDMwMCk7Cn0KCmZ1bmN0aW9uIHNldEZpbHRlcihlbCkgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5mdGFiJykuZm9yRWFjaCh0ID0+IHQuY2xhc3NMaXN0LnJlbW92ZSgnYWN0JykpOwogIGVsLmNsYXNzTGlzdC5hZGQoJ2FjdCcpOwogIHN0YXRlLmZpbHRlciA9IGVsLmRhdGFzZXQuczsKICBzdGF0ZS5wYWdlID0gMTsKICBsb2FkVXNlcnMoKTsKfQoKZnVuY3Rpb24gc29ydEJ5KGNvbCkgewogIGlmIChzdGF0ZS5zb3J0ID09PSBjb2wpIHN0YXRlLm9yZGVyID0gc3RhdGUub3JkZXIgPT09ICdhc2MnID8gJ2Rlc2MnIDogJ2FzYyc7CiAgZWxzZSB7IHN0YXRlLnNvcnQgPSBjb2w7IHN0YXRlLm9yZGVyID0gJ2Rlc2MnOyB9CiAgbG9hZFVzZXJzKCk7Cn0KCmFzeW5jIGZ1bmN0aW9uIGxvYWRVc2VycygpIHsKICBzdGF0ZS5zZWFyY2ggPSBlbCgndS1zZWFyY2gnKS52YWx1ZTsKICBzdGF0ZS5zb3J0ICAgPSBlbCgndS1zb3J0JykudmFsdWU7CiAgY29uc3QgcGFyYW1zID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7CiAgICBxOiBzdGF0ZS5zZWFyY2gsIHN0YXR1czogc3RhdGUuZmlsdGVyLAogICAgc29ydDogc3RhdGUuc29ydCwgb3JkZXI6IHN0YXRlLm9yZGVyLAogICAgcGFnZTogc3RhdGUucGFnZSwgcGVyOiBzdGF0ZS5wZXIsCiAgfSk7CiAgY29uc3QgZCA9IGF3YWl0IGFwaSgnR0VUJywgJy9hcGkvdXNlcnM/JyArIHBhcmFtcyk7CiAgaWYgKCFkKSByZXR1cm47CgogIGNvbnN0IHRib2R5ID0gZWwoJ3VzZXJzLXRib2R5Jyk7CiAgaWYgKCFkLnVzZXJzLmxlbmd0aCkgewogICAgdGJvZHkuaW5uZXJIVE1MID0gJzx0cj48dGQgY29sc3Bhbj0iOCIgY2xhc3M9ImVtcHR5Ij7QndC10YIg0L/QvtC70YzQt9C+0LLQsNGC0LXQu9C10Lk8L3RkPjwvdHI+JzsKICB9IGVsc2UgewogICAgdGJvZHkuaW5uZXJIVE1MID0gZC51c2Vycy5tYXAodSA9PiB1c2VyUm93KHUpKS5qb2luKCcnKTsKICB9CgogIGNvbnN0IHNob3duID0gZC51c2Vycy5sZW5ndGg7CiAgZWwoJ3UtY291bnQnKS50ZXh0Q29udGVudCA9IGAke2QudG90YWx9INC/0L7Qu9GM0LfQvtCy0LDRgtC10LvQtdC5YDsKICBlbCgndS1jb3VudC1zdWInKS50ZXh0Q29udGVudCA9IHNob3duIDwgZC50b3RhbCA/IGAo0L/QvtC60LDQt9Cw0L3QviAke3Nob3dufSlgIDogJyc7CiAgcmVuZGVyUGFnaW5hdGlvbigndS1wYWdpbmF0aW9uJywgZC50b3RhbCwgZC5wYWdlLCBkLnBlciwgcCA9PiB7IHN0YXRlLnBhZ2UgPSBwOyBsb2FkVXNlcnMoKTsgfSk7CiAgZWwoJ2Noay1hbGwnKS5jaGVja2VkID0gZmFsc2U7CiAgY2xlYXJTZWwoZmFsc2UpOwp9CgpmdW5jdGlvbiB1c2VyUm93KHUpIHsKICBjb25zdCBzZWwgPSBzdGF0ZS5zZWxlY3RlZElkcy5oYXModS5pZCkgPyAnY2hlY2tlZCcgOiAnJzsKICBjb25zdCB0cmFmQ29sb3IgPSB1LnRyYWZmaWNfcGVyY2VudCA+PSA5MCA/ICd0Zi1yJyA6IHUudHJhZmZpY19wZXJjZW50ID49IDYwID8gJ3RmLXknIDogJ3RmLWcnOwogIGNvbnN0IHRyYWZIdG1sID0gdS50cmFmZmljX2xpbWl0X2diID4gMAogICAgPyBgPGRpdiBjbGFzcz0idGJhciI+CiAgICAgICAgIDxkaXYgY2xhc3M9InRiYXItcm93Ij48c3Bhbj4ke3UudHJhZmZpY191c2VkX2difSBHQjwvc3Bhbj48c3Bhbj4ke3UudHJhZmZpY19saW1pdF9nYn0gR0I8L3NwYW4+PC9kaXY+CiAgICAgICAgIDxkaXYgY2xhc3M9InRiYXItYmciPjxkaXYgY2xhc3M9InRiYXItZmlsbCAke3RyYWZDb2xvcn0iIHN0eWxlPSJ3aWR0aDoke3UudHJhZmZpY19wZXJjZW50fSUiPjwvZGl2PjwvZGl2PgogICAgICAgPC9kaXY+YAogICAgOiBgPHNwYW4gc3R5bGU9ImZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLXRleHQzKSI+JHt1LnRyYWZmaWNfdXNlZF9nYn0gR0IgKOKInik8L3NwYW4+YDsKCiAgY29uc3QgdGFncyA9IHUudGFnc19saXN0Lmxlbmd0aAogICAgPyBgPGRpdiBjbGFzcz0idGFncy13cmFwIj4ke3UudGFnc19saXN0Lm1hcCh0PT5gPHNwYW4gY2xhc3M9InRhZyI+JHtlc2ModCl9PC9zcGFuPmApLmpvaW4oJycpfTwvZGl2PmAKICAgIDogJzxzcGFuIHN0eWxlPSJjb2xvcjp2YXIoLS10ZXh0MykiPuKAlDwvc3Bhbj4nOwoKICBjb25zdCB0b2dJY29uICA9IHUuZW5hYmxlZCA/ICfij7gnIDogJ+KWtu+4jyc7CiAgY29uc3QgdG9nQ2xhc3MgPSB1LmVuYWJsZWQgPyAnaWEtb3JhbmdlJyA6ICdpYS1ncmVlbic7CiAgY29uc3QgdG9nVGl0bGUgPSB1LmVuYWJsZWQgPyAn0JLRi9C60LvRjtGH0LjRgtGMJyA6ICfQktC60LvRjtGH0LjRgtGMJzsKCiAgcmV0dXJuIGA8dHIgaWQ9InJvdy0ke3UuaWR9Ij4KICAgIDx0ZD48aW5wdXQgdHlwZT0iY2hlY2tib3giIGNsYXNzPSJ1LWNoayIgZGF0YS1pZD0iJHt1LmlkfSIgJHtzZWx9CiAgICAgICAgICAgICAgIHN0eWxlPSJhY2NlbnQtY29sb3I6dmFyKC0tYmx1ZSkiIG9uY2hhbmdlPSJyb3dTZWwodGhpcykiPjwvdGQ+CiAgICA8dGQgY2xhc3M9ImNvbC1uYW1lIj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC13ZWlnaHQ6NjAwIj4ke2VzYyh1LmRpc3BsYXlfbmFtZSl9PC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLXRleHQzKSI+JHtlc2ModS51c2VybmFtZSl9PC9kaXY+CiAgICA8L3RkPgogICAgPHRkIHN0eWxlPSJmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS10ZXh0MikiPiR7ZXNjKHUudXNlcm5hbWUpfTwvdGQ+CiAgICA8dGQ+JHtzdGF0dXNCYWRnZSh1LnN0YXR1cyl9PC90ZD4KICAgIDx0ZD4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjExcHgiPiR7dS5leHBpcmVzX2Rpc3BsYXl9PC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMHB4O2NvbG9yOiR7dS5pc19ibG9ja2VkPyd2YXIoLS1yZWQpJzondmFyKC0tdGV4dDMpJ30iPiR7dS50aW1lX2xlZnR9PC9kaXY+CiAgICA8L3RkPgogICAgPHRkPiR7dHJhZkh0bWx9PC90ZD4KICAgIDx0ZD4ke3RhZ3N9PC90ZD4KICAgIDx0ZD4KICAgICAgPGRpdiBjbGFzcz0icm93LWFjdHMiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImlhIGlhLWJsdWUiIG9uY2xpY2s9InF1aWNrRWRpdCgnJHt1LmlkfScpIiB0aXRsZT0i0KDQtdC00LDQutGC0LjRgNC+0LLQsNGC0YwiPuKcj++4jzwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImlhICR7dG9nQ2xhc3N9IiBvbmNsaWNrPSJ0b2dnbGVVc2VyKCcke3UuaWR9JykiIHRpdGxlPSIke3RvZ1RpdGxlfSI+JHt0b2dJY29ufTwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImlhIGlhLWJsdWUiIG9uY2xpY2s9ImNvcHlMaW5rKCcke3Uuc3ViX2xpbmt9JykiIHRpdGxlPSLQmtC+0L/QuNGA0L7QstCw0YLRjCDRgdGB0YvQu9C60YMiPvCfk4s8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJpYSBpYS1ibHVlIiBvbmNsaWNrPSJzaG93UVJmb3IoJyR7dS5zdWJfbGlua30nLCcke2VzYyh1LmRpc3BsYXlfbmFtZSl9JykiIHRpdGxlPSJRUiI+UVI8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJpYSBpYS1yZWQiIG9uY2xpY2s9ImRlbGV0ZVVzZXIoJyR7dS5pZH0nLCcke2VzYyh1LmRpc3BsYXlfbmFtZSl9JykiIHRpdGxlPSLQo9C00LDQu9C40YLRjCI+8J+Xke+4jzwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgIDwvdGQ+CiAgPC90cj5gOwp9CgpmdW5jdGlvbiBzdGF0dXNCYWRnZShzKSB7CiAgY29uc3QgbWFwID0gewogICAgYWN0aXZlOiAgICAgICAgICAgJzxzcGFuIGNsYXNzPSJiYWRnZSBiLWFjdGl2ZSI+4pyFINCQ0LrRgtC40LLQvdCwPC9zcGFuPicsCiAgICBleHBpcmVkOiAgICAgICAgICAnPHNwYW4gY2xhc3M9ImJhZGdlIGItZXhwaXJlZCI+4puUINCY0YHRgtC10LrQu9CwPC9zcGFuPicsCiAgICBkaXNhYmxlZDogICAgICAgICAnPHNwYW4gY2xhc3M9ImJhZGdlIGItZGlzYWJsZWQiPuKPuCDQntGC0LrQuy48L3NwYW4+JywKICAgIHRyYWZmaWNfZXhjZWVkZWQ6ICc8c3BhbiBjbGFzcz0iYmFkZ2UgYi10cmFmZmljIj7wn5OmINCb0LjQvNC40YI8L3NwYW4+JywKICB9OwogIHJldHVybiBtYXBbc10gfHwgczsKfQoKLy8g4pSA4pSA4pSAIFVzZXIgQ1JVRCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZnVuY3Rpb24gb3BlbkNyZWF0ZU1vZGFsKCkgewogIHN0YXRlLmVkaXRJZCA9IG51bGw7CiAgZWwoJ3VtLXRpdGxlJykudGV4dENvbnRlbnQgPSAn0KHQvtC30LTQsNGC0Ywg0L/QvtC70YzQt9C+0LLQsNGC0LXQu9GPJzsKICBlbCgndW0tbmFtZScpLnZhbHVlID0gJyc7CiAgZWwoJ3VtLXVzZXJuYW1lJykudmFsdWUgPSAnJzsKICBlbCgndW0tZW5hYmxlZCcpLmNoZWNrZWQgPSB0cnVlOwogIGVsKCd1bS10cmFmZmljJykudmFsdWUgPSAnMCc7CiAgZWwoJ3VtLWRldmljZXMnKS52YWx1ZSA9ICcwJzsKICBlbCgndW0tdGFncycpLnZhbHVlID0gJyc7CiAgZWwoJ3VtLW5vdGUnKS52YWx1ZSA9ICcnOwogIGVsKCd1bS1saW5rLXNlY3Rpb24nKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIGVsKCd1bS1yZXNldC1idG4nKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIGVsKCd1bS10cmFmZmljLWluZm8nKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIGVsKCd1bS1kYXRlcycpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CgogIC8vIGRlZmF1bHQgZXhwaXJ5OiBub3cgKyBkZWZhdWx0X2V4cGlyZV9kYXlzCiAgY29uc3QgZGVmRGF5cyA9IHBhcnNlSW50KGVsKCdzZXQtZGVmLWRheXMnKT8udmFsdWUgfHwgJzMwJyk7CiAgY29uc3QgZCA9IG5ldyBEYXRlKCk7IGQuc2V0RGF0ZShkLmdldERhdGUoKSArIGRlZkRheXMpOwogIGVsKCd1bS1leHBpcmVzJykudmFsdWUgPSB0b0xvY2FsRFQoZCk7CgogIGZpbGxOb2RlQ2hlY2tzKFtdKTsKICBtVGFiKGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJy5tdGFiJyksICdtdC1iYXNpYycpOwogIG9wZW4oJ3VzZXItbW9kYWwnKTsKfQoKYXN5bmMgZnVuY3Rpb24gcXVpY2tFZGl0KHVpZCkgewogIGNvbnN0IHUgPSBhd2FpdCBhcGkoJ0dFVCcsIGAvYXBpL3VzZXJzLyR7dWlkfWApOwogIGlmICghdSkgcmV0dXJuOwogIHN0YXRlLmVkaXRJZCA9IHVpZDsKICBlbCgndW0tdGl0bGUnKS50ZXh0Q29udGVudCA9ICfQoNC10LTQsNC60YLQuNGA0L7QstCw0YLRjDogJyArIHUuZGlzcGxheV9uYW1lOwogIGVsKCd1bS1uYW1lJykudmFsdWUgICAgID0gdS5kaXNwbGF5X25hbWU7CiAgZWwoJ3VtLXVzZXJuYW1lJykudmFsdWUgPSB1LnVzZXJuYW1lOwogIGVsKCd1bS1lbmFibGVkJykuY2hlY2tlZCA9ICEhdS5lbmFibGVkOwogIGVsKCd1bS1leHBpcmVzJykudmFsdWUgID0gdS5leHBpcmVzX2lzbzsKICBlbCgndW0tdHJhZmZpYycpLnZhbHVlICA9IHUudHJhZmZpY19saW1pdF9nYiB8fCAwOwogIGVsKCd1bS1kZXZpY2VzJykudmFsdWUgID0gdS5kZXZpY2VfbGltaXQgfHwgMDsKICBlbCgndW0tdGFncycpLnZhbHVlICAgICA9IHUudGFncyB8fCAnJzsKICBlbCgndW0tbm90ZScpLnZhbHVlICAgICA9IHUubm90ZSB8fCAnJzsKICBlbCgndW0tbGluaycpLnZhbHVlICAgICA9IHUuc3ViX2xpbms7CiAgZWwoJ3VtLWxpbmstc2VjdGlvbicpLnN0eWxlLmRpc3BsYXkgPSAnJzsKICBlbCgndW0tcmVzZXQtYnRuJykuc3R5bGUuZGlzcGxheSA9ICcnOwogIGVsKCd1bS1kYXRlcycpLnN0eWxlLmRpc3BsYXkgPSAnJzsKICBlbCgndW0tZGF0ZXMnKS5pbm5lckhUTUwgPSBg0KHQvtC30LTQsNC9OiAke3UuY3JlYXRlZF9kaXNwbGF5fSAmbmJzcDt8Jm5ic3A7INCe0LHQvdC+0LLQu9GR0L06ICR7KHUudXBkYXRlZF9hdHx8JycpLnNsaWNlKDAsMTYpLnJlcGxhY2UoJ1QnLCcgJyl9YDsKCiAgaWYgKHUudHJhZmZpY19saW1pdF9nYiA+IDApIHsKICAgIGVsKCd1bS10cmFmZmljLWluZm8nKS5zdHlsZS5kaXNwbGF5ID0gJyc7CiAgICBlbCgndW0tdHJhZmZpYy1pbmZvJykudGV4dENvbnRlbnQgPSBg0JjRgdC/0L7Qu9GM0LfQvtCy0LDQvdC+OiAke3UudHJhZmZpY191c2VkX2difSBHQiDQuNC3ICR7dS50cmFmZmljX2xpbWl0X2difSBHQiAoJHt1LnRyYWZmaWNfcGVyY2VudH0lKWA7CiAgfSBlbHNlIHsKICAgIGVsKCd1bS10cmFmZmljLWluZm8nKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIH0KCiAgY29uc3Qgc2VsTm9kZXMgPSAodS5ub2RlX2lkcyB8fCAnJykuc3BsaXQoJywnKS5maWx0ZXIoQm9vbGVhbik7CiAgZmlsbE5vZGVDaGVja3Moc2VsTm9kZXMpOwogIG1UYWIoZG9jdW1lbnQucXVlcnlTZWxlY3RvcignLm10YWInKSwgJ210LWJhc2ljJyk7CiAgb3BlbigndXNlci1tb2RhbCcpOwp9CgpmdW5jdGlvbiBjbG9zZVVzZXJNb2RhbCgpIHsgY2xvc2UoJ3VzZXItbW9kYWwnKTsgfQoKYXN5bmMgZnVuY3Rpb24gc3VibWl0VXNlck1vZGFsKCkgewogIGNvbnN0IG5hbWUgPSBlbCgndW0tbmFtZScpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBleHAgID0gZWwoJ3VtLWV4cGlyZXMnKS52YWx1ZTsKICBpZiAoIW5hbWUpIHsgdG9hc3QoJ9CS0LLQtdC00LjRgtC1INC40LzRjycsICdlcnJvcicpOyByZXR1cm47IH0KICBpZiAoIWV4cCkgIHsgdG9hc3QoJ9Cj0LrQsNC20LjRgtC1INC00LDRgtGDINC40YHRgtC10YfQtdC90LjRjycsICdlcnJvcicpOyByZXR1cm47IH0KCiAgY29uc3Qgbm9kZUlkcyA9IFsuLi5kb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcjdW0tbm9kZS1jaGVja3MgLm5jaGVjayBpbnB1dDpjaGVja2VkJyldCiAgICAubWFwKGNiID0+IGNiLnZhbHVlKTsKCiAgY29uc3QgcGF5bG9hZCA9IHsKICAgIGRpc3BsYXlfbmFtZTogICAgIG5hbWUsCiAgICB1c2VybmFtZTogICAgICAgICBlbCgndW0tdXNlcm5hbWUnKS52YWx1ZS50cmltKCksCiAgICBlbmFibGVkOiAgICAgICAgICBlbCgndW0tZW5hYmxlZCcpLmNoZWNrZWQgPyAxIDogMCwKICAgIGV4cGlyZXNfYXQ6ICAgICAgIGV4cC5yZXBsYWNlKCdUJywgJ1QnKSArICc6MDAnLAogICAgdHJhZmZpY19saW1pdF9nYjogcGFyc2VGbG9hdChlbCgndW0tdHJhZmZpYycpLnZhbHVlKSB8fCAwLAogICAgZGV2aWNlX2xpbWl0OiAgICAgcGFyc2VJbnQoZWwoJ3VtLWRldmljZXMnKS52YWx1ZSkgfHwgMCwKICAgIG5vZGVfaWRzOiAgICAgICAgIG5vZGVJZHMsCiAgICB0YWdzOiAgICAgICAgICAgICBlbCgndW0tdGFncycpLnZhbHVlLnRyaW0oKSwKICAgIG5vdGU6ICAgICAgICAgICAgIGVsKCd1bS1ub3RlJykudmFsdWUudHJpbSgpLAogIH07CgogIGxldCByZXN1bHQ7CiAgaWYgKHN0YXRlLmVkaXRJZCkgewogICAgcmVzdWx0ID0gYXdhaXQgYXBpKCdQVVQnLCBgL2FwaS91c2Vycy8ke3N0YXRlLmVkaXRJZH1gLCBwYXlsb2FkKTsKICAgIGlmIChyZXN1bHQpIHRvYXN0KCfQodC+0YXRgNCw0L3QtdC90L4g4pyTJywgJ3N1Y2Nlc3MnKTsKICB9IGVsc2UgewogICAgcmVzdWx0ID0gYXdhaXQgYXBpKCdQT1NUJywgJy9hcGkvdXNlcnMnLCBwYXlsb2FkKTsKICAgIGlmIChyZXN1bHQpIHRvYXN0KCfQn9C+0LvRjNC30L7QstCw0YLQtdC70Ywg0YHQvtC30LTQsNC9IOKckycsICdzdWNjZXNzJyk7CiAgfQogIGlmIChyZXN1bHQpIHsgY2xvc2VVc2VyTW9kYWwoKTsgbG9hZFVzZXJzKCk7IGxvYWREYXNoKCk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZGVsZXRlVXNlcih1aWQsIG5hbWUpIHsKICBpZiAoIWNvbmZpcm0oYNCj0LTQsNC70LjRgtGMICIke25hbWV9Ij9gKSkgcmV0dXJuOwogIGNvbnN0IHIgPSBhd2FpdCBhcGkoJ0RFTEVURScsIGAvYXBpL3VzZXJzLyR7dWlkfWApOwogIGlmIChyKSB7IHRvYXN0KCfQo9C00LDQu9C10L3QvicsICdzdWNjZXNzJyk7IGxvYWRVc2VycygpOyBsb2FkRGFzaCgpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIHRvZ2dsZVVzZXIodWlkKSB7CiAgY29uc3QgciA9IGF3YWl0IGFwaSgnUE9TVCcsIGAvYXBpL3VzZXJzLyR7dWlkfS90b2dnbGVgKTsKICBpZiAocikgeyB0b2FzdChyLmVuYWJsZWQgPyAn0JLQutC70Y7Rh9C10L3QviDinJMnIDogJ9Ce0YLQutC70Y7Rh9C10L3QvicsICdzdWNjZXNzJyk7IGxvYWRVc2VycygpOyBsb2FkRGFzaCgpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIHJlc2V0VHJhZmZpY0luTW9kYWwoKSB7CiAgaWYgKCFzdGF0ZS5lZGl0SWQpIHJldHVybjsKICBjb25zdCByID0gYXdhaXQgYXBpKCdQT1NUJywgYC9hcGkvdXNlcnMvJHtzdGF0ZS5lZGl0SWR9L3Jlc2V0X3RyYWZmaWNgKTsKICBpZiAocikgeyB0b2FzdCgn0KLRgNCw0YTQuNC6INGB0LHRgNC+0YjQtdC9JywgJ3N1Y2Nlc3MnKTsgcXVpY2tFZGl0KHN0YXRlLmVkaXRJZCk7IH0KfQoKLy8g4pSA4pSA4pSAIEJ1bGsg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmZ1bmN0aW9uIHJvd1NlbChjYikgewogIGNvbnN0IGlkID0gY2IuZGF0YXNldC5pZDsKICBjYi5jaGVja2VkID8gc3RhdGUuc2VsZWN0ZWRJZHMuYWRkKGlkKSA6IHN0YXRlLnNlbGVjdGVkSWRzLmRlbGV0ZShpZCk7CiAgdXBkQnVsaygpOwp9CmZ1bmN0aW9uIHRvZ2dsZUFsbChtYXN0ZXIpIHsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcudS1jaGsnKS5mb3JFYWNoKGNiID0+IHsKICAgIGNiLmNoZWNrZWQgPSBtYXN0ZXIuY2hlY2tlZDsKICAgIG1hc3Rlci5jaGVja2VkID8gc3RhdGUuc2VsZWN0ZWRJZHMuYWRkKGNiLmRhdGFzZXQuaWQpIDogc3RhdGUuc2VsZWN0ZWRJZHMuZGVsZXRlKGNiLmRhdGFzZXQuaWQpOwogIH0pOwogIHVwZEJ1bGsoKTsKfQpmdW5jdGlvbiB1cGRCdWxrKCkgewogIGNvbnN0IG4gPSBzdGF0ZS5zZWxlY3RlZElkcy5zaXplOwogIGVsKCdidWxrLWxhYmVsJykudGV4dENvbnRlbnQgPSBuICsgJyDQstGL0LHRgNCw0L3Qvic7CiAgZWwoJ2J1bGstYmFyJykuY2xhc3NMaXN0LnRvZ2dsZSgnc2hvdycsIG4gPiAwKTsKfQpmdW5jdGlvbiBjbGVhclNlbChyZW5kZXI9dHJ1ZSkgewogIHN0YXRlLnNlbGVjdGVkSWRzLmNsZWFyKCk7CiAgaWYgKHJlbmRlcikgeyBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcudS1jaGsnKS5mb3JFYWNoKGNiID0+IGNiLmNoZWNrZWQgPSBmYWxzZSk7IHVwZEJ1bGsoKTsgfQogIGVsKCdidWxrLWJhcicpLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKfQphc3luYyBmdW5jdGlvbiBidWxrQWN0aW9uKGFjdGlvbikgewogIGNvbnN0IGlkcyA9IFsuLi5zdGF0ZS5zZWxlY3RlZElkc107CiAgaWYgKCFpZHMubGVuZ3RoKSByZXR1cm47CiAgaWYgKGFjdGlvbiA9PT0gJ2RlbGV0ZScgJiYgIWNvbmZpcm0oYNCj0LTQsNC70LjRgtGMICR7aWRzLmxlbmd0aH0g0L/QvtC70YzQt9C+0LLQsNGC0LXQu9C10Lk/YCkpIHJldHVybjsKICBjb25zdCByID0gYXdhaXQgYXBpKCdQT1NUJywgJy9hcGkvYnVsaycsIHtpZHMsIGFjdGlvbn0pOwogIGlmIChyKSB7IHRvYXN0KGAke2FjdGlvbn06ICR7ci5hZmZlY3RlZH0g0L7QsdGA0LDQsdC+0YLQsNC90L5gLCAnc3VjY2VzcycpOyBjbGVhclNlbCgpOyBsb2FkVXNlcnMoKTsgbG9hZERhc2goKTsgfQp9CgovLyDilIDilIDilIAgTm9kZXMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmFzeW5jIGZ1bmN0aW9uIGxvYWROb2RlcygpIHsKICBjb25zdCBub2RlcyA9IGF3YWl0IGFwaSgnR0VUJywgJy9hcGkvbm9kZXMnKTsKICBpZiAoIW5vZGVzKSByZXR1cm47CiAgc3RhdGUubm9kZXMgPSBub2RlczsKICBjb25zdCBnID0gZWwoJ25vZGVzLWdyaWQnKTsKICBpZiAoIW5vZGVzLmxlbmd0aCkgeyBnLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJlbXB0eSI+0J3QtdGCINC90L7QtC4g0JTQvtCx0LDQstGM0YLQtSDQv9C10YDQstGD0Y4uPC9kaXY+JzsgcmV0dXJuOyB9CiAgZy5pbm5lckhUTUwgPSBub2Rlcy5tYXAobiA9PiBub2RlQ2FyZChuKSkuam9pbignJyk7Cn0KCmZ1bmN0aW9uIG5vZGVDYXJkKG4pIHsKICBjb25zdCBzYyA9IG4ubGFzdF9zdGF0dXMgPT09ICdvaycgPyAnbnMtb2snIDogbi5sYXN0X3N0YXR1cyA9PT0gJ2Vycm9yJyA/ICducy1lcnJvcicgOiAnbnMtdW5rbm93bic7CiAgY29uc3QgZW4gPSBuLmVuYWJsZWQgPyAnJyA6ICcgc3R5bGU9Im9wYWNpdHk6LjYiJzsKICByZXR1cm4gYDxkaXYgY2xhc3M9Im5vZGUtY2FyZCIke2VufT4KICAgIDxkaXYgY2xhc3M9Im5jLWhlYWQiPgogICAgICA8ZGl2IGNsYXNzPSJuYy1zdGF0dXMgJHtzY30iPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJuYy1uYW1lIj4ke2VzYyhuLm5hbWUpfTwvZGl2PgogICAgICAke24uZW5hYmxlZCA/ICcnIDogJzxzcGFuIGNsYXNzPSJiYWRnZSBiLWRpc2FibGVkIiBzdHlsZT0iZm9udC1zaXplOjlweCI+0J7RgtC60LsuPC9zcGFuPid9CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5jLXVybCIgdGl0bGU9IiR7ZXNjKG4udXJsKX0iPiR7ZXNjKG4udXJsKX08L2Rpdj4KICAgICR7bi50YWcgPyBgPHNwYW4gY2xhc3M9Im5jLXRhZyI+JHtlc2Mobi50YWcpfTwvc3Bhbj5gIDogJyd9CiAgICA8ZGl2IGNsYXNzPSJuYy1hY3RzIj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iaWEgaWEtYmx1ZSIgb25jbGljaz0iY2hlY2tOb2RlKCcke24uaWR9Jyx0aGlzKSI+4pqhINCf0YDQvtCy0LXRgNC40YLRjDwvYnV0dG9uPgogICAgICA8YnV0dG9uIGNsYXNzPSJpYSBpYS1vcmFuZ2UiIG9uY2xpY2s9ImVkaXROb2RlKCcke24uaWR9JykiPuKcj++4jyDQoNC10LQuPC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImlhIGlhLXJlZCIgb25jbGljaz0iZGVsZXRlTm9kZSgnJHtuLmlkfScsJyR7ZXNjKG4ubmFtZSl9JykiPvCfl5HvuI88L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2PmA7Cn0KCmZ1bmN0aW9uIG5tVHlwZUNoYW5nZSgpIHsKICBjb25zdCB0ID0gZWwoJ25tLXR5cGUnKS52YWx1ZTsKICBlbCgnbm0tdXJsLXdyYXAnKS5zdHlsZS5kaXNwbGF5ICA9IHQgPT09ICd1cmwnID8gJycgOiAnbm9uZSc7CiAgZWwoJ25tLXJhdy13cmFwJykuc3R5bGUuZGlzcGxheSAgPSB0ID09PSAncmF3JyA/ICcnIDogJ25vbmUnOwp9CgpmdW5jdGlvbiBvcGVuTm9kZU1vZGFsKCkgewogIHN0YXRlLmVkaXROb2RlSWQgPSBudWxsOwogIGVsKCdubS10aXRsZScpLnRleHRDb250ZW50ID0gJ9CU0L7QsdCw0LLQuNGC0Ywg0L3QvtC00YMnOwogIGVsKCdubS1uYW1lJykudmFsdWUgPSAnJzsKICBlbCgnbm0tdXJsJykudmFsdWUgID0gJyc7CiAgZWwoJ25tLXJhdycpLnZhbHVlICA9ICcnOwogIGVsKCdubS10YWcnKS52YWx1ZSAgPSAnJzsKICBlbCgnbm0tdHlwZScpLnZhbHVlID0gJ3VybCc7CiAgZWwoJ25tLWVuYWJsZWQnKS5jaGVja2VkID0gdHJ1ZTsKICBubVR5cGVDaGFuZ2UoKTsKICBvcGVuKCdub2RlLW1vZGFsJyk7Cn0KZnVuY3Rpb24gY2xvc2VOb2RlTW9kYWwoKSB7IGNsb3NlKCdub2RlLW1vZGFsJyk7IH0KCmZ1bmN0aW9uIGVkaXROb2RlKG5pZCkgewogIGNvbnN0IG4gPSBzdGF0ZS5ub2Rlcy5maW5kKHggPT4geC5pZCA9PT0gbmlkKTsKICBpZiAoIW4pIHJldHVybjsKICBzdGF0ZS5lZGl0Tm9kZUlkID0gbmlkOwogIGVsKCdubS10aXRsZScpLnRleHRDb250ZW50ID0gJ9Cg0LXQtNCw0LrRgtC40YDQvtCy0LDRgtGMINC90L7QtNGDJzsKICBlbCgnbm0tbmFtZScpLnZhbHVlICAgID0gbi5uYW1lOwogIGVsKCdubS11cmwnKS52YWx1ZSAgICAgPSBuLnVybCB8fCAnJzsKICBlbCgnbm0tcmF3JykudmFsdWUgICAgID0gbi5yYXdfY29uZmlnIHx8ICcnOwogIGVsKCdubS10YWcnKS52YWx1ZSAgICAgPSBuLnRhZyB8fCAnJzsKICBlbCgnbm0tdHlwZScpLnZhbHVlICAgID0gbi5ub2RlX3R5cGUgfHwgJ3VybCc7CiAgZWwoJ25tLWVuYWJsZWQnKS5jaGVja2VkID0gISFuLmVuYWJsZWQ7CiAgbm1UeXBlQ2hhbmdlKCk7CiAgb3Blbignbm9kZS1tb2RhbCcpOwp9Cgphc3luYyBmdW5jdGlvbiBzdWJtaXROb2RlTW9kYWwoKSB7CiAgY29uc3QgbnR5cGUgPSBlbCgnbm0tdHlwZScpLnZhbHVlOwogIGNvbnN0IHBheWxvYWQgPSB7CiAgICBuYW1lOiAgICAgICBlbCgnbm0tbmFtZScpLnZhbHVlLnRyaW0oKSwKICAgIHVybDogICAgICAgIG50eXBlID09PSAndXJsJyA/IGVsKCdubS11cmwnKS52YWx1ZS50cmltKCkgOiAnJywKICAgIHRhZzogICAgICAgIGVsKCdubS10YWcnKS52YWx1ZS50cmltKCksCiAgICBlbmFibGVkOiAgICBlbCgnbm0tZW5hYmxlZCcpLmNoZWNrZWQgPyAxIDogMCwKICAgIG5vZGVfdHlwZTogIG50eXBlLAogICAgcmF3X2NvbmZpZzogbnR5cGUgPT09ICdyYXcnID8gZWwoJ25tLXJhdycpLnZhbHVlLnRyaW0oKSA6ICcnLAogIH07CiAgaWYgKCFwYXlsb2FkLm5hbWUpIHsgdG9hc3QoJ9CS0LLQtdC00Lgg0L3QsNC30LLQsNC90LjQtScsICdlcnJvcicpOyByZXR1cm47IH0KICBpZiAobnR5cGUgPT09ICd1cmwnICYmICFwYXlsb2FkLnVybCkgeyB0b2FzdCgn0JLQstC10LTQuCBVUkwnLCAnZXJyb3InKTsgcmV0dXJuOyB9CiAgaWYgKG50eXBlID09PSAncmF3JyAmJiAhcGF5bG9hZC5yYXdfY29uZmlnKSB7IHRvYXN0KCfQktGB0YLQsNCy0Ywg0LrQvtC90YTQuNCz0LgnLCAnZXJyb3InKTsgcmV0dXJuOyB9CiAgbGV0IHI7CiAgaWYgKHN0YXRlLmVkaXROb2RlSWQpIHsKICAgIHIgPSBhd2FpdCBhcGkoJ1BVVCcsIGAvYXBpL25vZGVzLyR7c3RhdGUuZWRpdE5vZGVJZH1gLCBwYXlsb2FkKTsKICB9IGVsc2UgewogICAgciA9IGF3YWl0IGFwaSgnUE9TVCcsICcvYXBpL25vZGVzJywgcGF5bG9hZCk7CiAgfQogIGlmIChyKSB7IHRvYXN0KCfQodC+0YXRgNCw0L3QtdC90L4g4pyTJywgJ3N1Y2Nlc3MnKTsgY2xvc2VOb2RlTW9kYWwoKTsgbG9hZE5vZGVzKCk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZGVsZXRlTm9kZShuaWQsIG5hbWUpIHsKICBpZiAoIWNvbmZpcm0oYNCj0LTQsNC70LjRgtGMINC90L7QtNGDICIke25hbWV9Ij9gKSkgcmV0dXJuOwogIGNvbnN0IHIgPSBhd2FpdCBhcGkoJ0RFTEVURScsIGAvYXBpL25vZGVzLyR7bmlkfWApOwogIGlmIChyKSB7IHRvYXN0KCfQndC+0LTQsCDRg9C00LDQu9C10L3QsCcsICdzdWNjZXNzJyk7IGxvYWROb2RlcygpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGNoZWNrTm9kZShuaWQsIGJ0bikgewogIGJ0bi5kaXNhYmxlZCA9IHRydWU7IGJ0bi50ZXh0Q29udGVudCA9ICcuLi4nOwogIGNvbnN0IHIgPSBhd2FpdCBhcGkoJ1BPU1QnLCBgL2FwaS9ub2Rlcy8ke25pZH0vY2hlY2tgKTsKICBidG4uZGlzYWJsZWQgPSBmYWxzZTsgYnRuLnRleHRDb250ZW50ID0gJ+KaoSDQn9GA0L7QstC10YDQuNGC0YwnOwogIGlmIChyKSB7IHRvYXN0KHIuc3RhdHVzID09PSAnb2snID8gJ+KchSDQndC+0LTQsCDQtNC+0YHRgtGD0L/QvdCwJyA6ICfinYwg0J3QvtC00LAg0L3QtdC00L7RgdGC0YPQv9C90LAnLCByLnN0YXR1cyA9PT0gJ29rJyA/ICdzdWNjZXNzJyA6ICdlcnJvcicpOyBsb2FkTm9kZXMoKTsgfQp9CgovLyDilIDilIDilIAgTm9kZSBjaGVja3MgaW4gbW9kYWwg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmZ1bmN0aW9uIGZpbGxOb2RlQ2hlY2tzKHNlbGVjdGVkSWRzKSB7CiAgY29uc3Qgd3JhcCA9IGVsKCd1bS1ub2RlLWNoZWNrcycpOwogIGlmICghc3RhdGUubm9kZXMubGVuZ3RoKSB7IHdyYXAuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImVtcHR5Ij7QndC+0LTRiyDQvdC1INC00L7QsdCw0LLQu9C10L3RiyDigJQg0L/QtdGA0LXQudC00LjRgtC1INCyINGA0LDQt9C00LXQuyAi0J3QvtC00YsiPC9kaXY+JzsgcmV0dXJuOyB9CiAgd3JhcC5pbm5lckhUTUwgPSBzdGF0ZS5ub2Rlcy5tYXAobiA9PiB7CiAgICBjb25zdCBjaGsgPSBzZWxlY3RlZElkcy5pbmNsdWRlcyhuLmlkKSA/ICdjaGVja2VkJyA6ICcnOwogICAgY29uc3QgZGlzICA9ICFuLmVuYWJsZWQgPyAnICjQvtGC0LrQuy4pJyA6ICcnOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJuY2hlY2siPgogICAgICA8aW5wdXQgdHlwZT0iY2hlY2tib3giIHZhbHVlPSIke24uaWR9IiBpZD0ibmMtJHtuLmlkfSIgJHtjaGt9PgogICAgICA8bGFiZWwgZm9yPSJuYy0ke24uaWR9Ij4ke2VzYyhuLm5hbWUpfSR7ZGlzfSA8c3BhbiBzdHlsZT0iY29sb3I6dmFyKC0tdGV4dDMpO2ZvbnQtc2l6ZTo5cHgiPiR7bi50YWcgPyAnWycrZXNjKG4udGFnKSsnXScgOiAnJ308L3NwYW4+PC9sYWJlbD4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KZnVuY3Rpb24gY2hrQWxsTm9kZXModikgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyN1bS1ub2RlLWNoZWNrcyBpbnB1dCcpLmZvckVhY2goY2IgPT4gY2IuY2hlY2tlZCA9IHYpOwp9CgovLyDilIDilIDilIAgTG9ncyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKYXN5bmMgZnVuY3Rpb24gbG9hZExvZ3MoKSB7CiAgY29uc3QgZCA9IGF3YWl0IGFwaSgnR0VUJywgYC9hcGkvbG9ncz9wYWdlPSR7c3RhdGUubG9nUGFnZX0mcGVyPTUwYCk7CiAgaWYgKCFkKSByZXR1cm47CiAgY29uc3QgdGJvZHkgPSBlbCgnbG9ncy10Ym9keScpOwogIGlmICghZC5sb2dzLmxlbmd0aCkgeyB0Ym9keS5pbm5lckhUTUwgPSAnPHRyPjx0ZCBjb2xzcGFuPSI0IiBjbGFzcz0iZW1wdHkiPtCd0LXRgiDQt9Cw0L/QuNGB0LXQuTwvdGQ+PC90cj4nOyByZXR1cm47IH0KICB0Ym9keS5pbm5lckhUTUwgPSBkLmxvZ3MubWFwKGwgPT4gewogICAgY29uc3QgYWMgPSBsLmFjdGlvbiB8fCAnJzsKICAgIGNvbnN0IGNscyA9IGFjLmluY2x1ZGVzKCdkZWxldGUnKSA/ICdsYS1kZWxldGUnIDogYWMuaW5jbHVkZXMoJ2NyZWF0ZScpID8gJ2xhLWNyZWF0ZScgOiBhYy5pbmNsdWRlcygnYnVsaycpID8gJ2xhLWJ1bGtfZGVsZXRlJyA6ICdsYS11cGRhdGUnOwogICAgcmV0dXJuIGA8dHI+CiAgICAgIDx0ZCBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tdGV4dDMpO3doaXRlLXNwYWNlOm5vd3JhcCI+JHtsLnRzPy5zbGljZSgwLDE2KS5yZXBsYWNlKCdUJywnICcpfTwvdGQ+CiAgICAgIDx0ZD48c3BhbiBjbGFzcz0ibG9nLWFjdGlvbiAke2Nsc30iPiR7ZXNjKGFjKX08L3NwYW4+PC90ZD4KICAgICAgPHRkIHN0eWxlPSJmb250LXNpemU6MTFweCI+JHtlc2MobC5kaXNwbGF5X25hbWUgfHwgbC51c2VyX2lkIHx8ICfigJQnKX08L3RkPgogICAgICA8dGQgc3R5bGU9ImZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLXRleHQyKSI+JHtlc2MobC5kZXRhaWwpfTwvdGQ+CiAgICA8L3RyPmA7CiAgfSkuam9pbignJyk7CiAgcmVuZGVyUGFnaW5hdGlvbignbG9nLXBhZ2luYXRpb24nLCBkLnRvdGFsLCBzdGF0ZS5sb2dQYWdlLCA1MCwgcCA9PiB7IHN0YXRlLmxvZ1BhZ2UgPSBwOyBsb2FkTG9ncygpOyB9KTsKfQoKLy8g4pSA4pSA4pSAIFNldHRpbmdzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAphc3luYyBmdW5jdGlvbiBsb2FkU2V0dGluZ3MoKSB7CiAgY29uc3QgZCA9IGF3YWl0IGFwaSgnR0VUJywgJy9hcGkvc2V0dGluZ3MnKTsKICBpZiAoIWQpIHJldHVybjsKICBlbCgnc2V0LWJhc2UtdXJsJykudmFsdWUgICAgID0gZC5iYXNlX3VybCB8fCAnJzsKICBlbCgnc2V0LXRpdGxlJykudmFsdWUgICAgICAgID0gZC5wYW5lbF90aXRsZSB8fCAnJzsKICBlbCgnc2V0LWdyYWNlJykudmFsdWUgICAgICAgID0gZC5ncmFjZV9kYXlzIHx8ICcwJzsKICBlbCgnc2V0LWRlZi1kYXlzJykudmFsdWUgICAgID0gZC5kZWZhdWx0X2V4cGlyZV9kYXlzIHx8ICczMCc7CiAgZWwoJ3NldC1kZWYtdHJhZmZpYycpLnZhbHVlICA9IGQuZGVmYXVsdF90cmFmZmljX2diIHx8ICcwJzsKICBlbCgnc2V0LWV4cGlyZWQtY2ZnJykudmFsdWUgID0gZC5leHBpcmVkX2NvbmZpZyB8fCAnJzsKICBlbCgnc2V0LXRnLXRva2VuJykudmFsdWUgICAgID0gZC50Z190b2tlbiB8fCAnJzsKICBlbCgnc2V0LXRnLWNoYXQnKS52YWx1ZSAgICAgID0gZC50Z19jaGF0X2lkIHx8ICcnOwp9CmFzeW5jIGZ1bmN0aW9uIHNhdmVTZXR0aW5ncygpIHsKICBjb25zdCBkID0gewogICAgYmFzZV91cmw6ICAgICAgICAgICAgZWwoJ3NldC1iYXNlLXVybCcpLnZhbHVlLnRyaW0oKSwKICAgIHBhbmVsX3RpdGxlOiAgICAgICAgIGVsKCdzZXQtdGl0bGUnKS52YWx1ZS50cmltKCksCiAgICBncmFjZV9kYXlzOiAgICAgICAgICBlbCgnc2V0LWdyYWNlJykudmFsdWUsCiAgICBkZWZhdWx0X2V4cGlyZV9kYXlzOiBlbCgnc2V0LWRlZi1kYXlzJykudmFsdWUsCiAgICBkZWZhdWx0X3RyYWZmaWNfZ2I6ICBlbCgnc2V0LWRlZi10cmFmZmljJykudmFsdWUsCiAgICBleHBpcmVkX2NvbmZpZzogICAgICBlbCgnc2V0LWV4cGlyZWQtY2ZnJykudmFsdWUudHJpbSgpLAogICAgdGdfdG9rZW46ICAgICAgICAgICAgZWwoJ3NldC10Zy10b2tlbicpLnZhbHVlLnRyaW0oKSwKICAgIHRnX2NoYXRfaWQ6ICAgICAgICAgIGVsKCdzZXQtdGctY2hhdCcpLnZhbHVlLnRyaW0oKSwKICB9OwogIGNvbnN0IHIgPSBhd2FpdCBhcGkoJ1BPU1QnLCAnL2FwaS9zZXR0aW5ncycsIGQpOwogIGlmIChyKSB0b2FzdCgn0J3QsNGB0YLRgNC+0LnQutC4INGB0L7RhdGA0LDQvdC10L3RiyDinJMnLCAnc3VjY2VzcycpOwp9CgovLyDilIDilIDilIAgUVIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmZ1bmN0aW9uIHNob3dRUigpIHsKICBjb25zdCB1cmwgPSBlbCgndW0tbGluaycpLnZhbHVlOwogIGNvbnN0IG5hbWUgPSBlbCgndW0tbmFtZScpLnZhbHVlOwogIHNob3dRUmZvcih1cmwsIG5hbWUpOwp9CmZ1bmN0aW9uIHNob3dRUmZvcih1cmwsIG5hbWUpIHsKICBlbCgncXItbmFtZScpLnRleHRDb250ZW50ID0gbmFtZSB8fCAnUVIg0LrQvtC0JzsKICBlbCgncXItdXJsJykudGV4dENvbnRlbnQgID0gdXJsOwogIGVsKCdxci1jb250YWluZXInKS5pbm5lckhUTUwgPSAnJzsKICBuZXcgUVJDb2RlKGVsKCdxci1jb250YWluZXInKSwgeyB0ZXh0OiB1cmwsIHdpZHRoOiAyMjAsIGhlaWdodDogMjIwLCBjb3JyZWN0TGV2ZWw6IFFSQ29kZS5Db3JyZWN0TGV2ZWwuTSB9KTsKICBvcGVuKCdxci1tb2RhbCcpOwp9CmZ1bmN0aW9uIGNsb3NlUVIoKSB7IGNsb3NlKCdxci1tb2RhbCcpOyBlbCgncXItY29udGFpbmVyJykuaW5uZXJIVE1MID0gJyc7IH0KCi8vIOKUgOKUgOKUgCBDb3B5IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApmdW5jdGlvbiBjb3B5U3ViTGluaygpIHsKICBjb25zdCB2ID0gZWwoJ3VtLWxpbmsnKS52YWx1ZTsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh2KS50aGVuKCgpID0+IHRvYXN0KCfQodC60L7Qv9C40YDQvtCy0LDQvdC+JywgJ3N1Y2Nlc3MnKSk7Cn0KZnVuY3Rpb24gY29weUxpbmsodXJsKSB7CiAgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQodXJsKS50aGVuKCgpID0+IHRvYXN0KCfQodC60L7Qv9C40YDQvtCy0LDQvdC+JywgJ3N1Y2Nlc3MnKSk7Cn0KCi8vIOKUgOKUgOKUgCBNb2RhbCBoZWxwZXJzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApmdW5jdGlvbiBvcGVuKGlkKSAgeyBlbChpZCkuY2xhc3NMaXN0LmFkZCgnb3BlbicpOyB9CmZ1bmN0aW9uIGNsb3NlKGlkKSB7IGVsKGlkKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7IH0KCmZ1bmN0aW9uIG1UYWIoY2xpY2tlZEVsLCBwYW5lSWQpIHsKICBjb25zdCBtb2RhbCA9IGNsaWNrZWRFbC5jbG9zZXN0ID8gY2xpY2tlZEVsLmNsb3Nlc3QoJy5tYm9keScpPy5wYXJlbnRFbGVtZW50IHx8IGRvY3VtZW50IDogZG9jdW1lbnQ7CiAgbW9kYWwucXVlcnlTZWxlY3RvckFsbCgnLm10YWInKS5mb3JFYWNoKHQgPT4gdC5jbGFzc0xpc3QucmVtb3ZlKCdhY3QnKSk7CiAgbW9kYWwucXVlcnlTZWxlY3RvckFsbCgnLm10YWItcGFuZScpLmZvckVhY2gocCA9PiBwLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdCcpKTsKICBjbGlja2VkRWwuY2xhc3NMaXN0LmFkZCgnYWN0Jyk7CiAgZWwocGFuZUlkKT8uY2xhc3NMaXN0LmFkZCgnYWN0Jyk7Cn0KCi8vIOKUgOKUgOKUgCBEYXRlIGhlbHBlcnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmZ1bmN0aW9uIHRvTG9jYWxEVChkKSB7CiAgY29uc3QgcCA9IG4gPT4gU3RyaW5nKG4pLnBhZFN0YXJ0KDIsJzAnKTsKICByZXR1cm4gYCR7ZC5nZXRGdWxsWWVhcigpfS0ke3AoZC5nZXRNb250aCgpKzEpfS0ke3AoZC5nZXREYXRlKCkpfVQke3AoZC5nZXRIb3VycygpKX06JHtwKGQuZ2V0TWludXRlcygpKX1gOwp9CmZ1bmN0aW9uIGFkZEV4cERheXMobikgewogIGNvbnN0IGlucCA9IGVsKCd1bS1leHBpcmVzJyk7CiAgbGV0IGJhc2UgPSBpbnAudmFsdWUgPyBuZXcgRGF0ZShpbnAudmFsdWUpIDogbmV3IERhdGUoKTsKICBpZiAoaXNOYU4oYmFzZSkpIGJhc2UgPSBuZXcgRGF0ZSgpOwogIGJhc2Uuc2V0RGF0ZShiYXNlLmdldERhdGUoKSArIG4pOwogIGlucC52YWx1ZSA9IHRvTG9jYWxEVChiYXNlKTsKfQoKLy8g4pSA4pSA4pSAIFVzZXJuYW1lIGF1dG9maWxsIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApmdW5jdGlvbiBhdXRvVXNlcm5hbWUoKSB7CiAgaWYgKHN0YXRlLmVkaXRJZCkgcmV0dXJuOwogIGNvbnN0IHYgPSBlbCgndW0tbmFtZScpLnZhbHVlLnRyaW0oKS50b0xvd2VyQ2FzZSgpLnJlcGxhY2UoL1xzKy9nLCdfJykucmVwbGFjZSgvW15hLXowLTlfXS9nLCcnKTsKICBlbCgndW0tdXNlcm5hbWUnKS52YWx1ZSA9IHY7Cn0KCi8vIOKUgOKUgOKUgCBQYWdpbmF0aW9uIGhlbHBlciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZnVuY3Rpb24gcmVuZGVyUGFnaW5hdGlvbihjb250YWluZXJJZCwgdG90YWwsIHBhZ2UsIHBlciwgY2IpIHsKICBjb25zdCBwYWdlcyA9IE1hdGguY2VpbCh0b3RhbCAvIHBlcik7CiAgaWYgKHBhZ2VzIDw9IDEpIHsgZWwoY29udGFpbmVySWQpLmlubmVySFRNTCA9ICcnOyByZXR1cm47IH0KICBsZXQgaHRtbCA9IGA8c3BhbiBjbGFzcz0icGFnZS1pbmZvIj4keyhwYWdlLTEpKnBlcisxfeKAkyR7TWF0aC5taW4ocGFnZSpwZXIsdG90YWwpfSDQuNC3ICR7dG90YWx9PC9zcGFuPmA7CiAgaHRtbCArPSBgPGJ1dHRvbiBjbGFzcz0icGFnZS1idG4iIG9uY2xpY2s9Iigke2NiLnRvU3RyaW5nKCl9KSgke3BhZ2UtMX0pIiAke3BhZ2U8PTE/J2Rpc2FibGVkJzonJ30+4oC5PC9idXR0b24+YDsKICBjb25zdCByYW5nZSA9IFtdOwogIGZvciAobGV0IGk9MTtpPD1wYWdlcztpKyspIGlmIChpPT09MXx8aT09PXBhZ2VzfHxNYXRoLmFicyhpLXBhZ2UpPD0yKSByYW5nZS5wdXNoKGkpOwogIGxldCBwcmV2ID0gMDsKICByYW5nZS5mb3JFYWNoKGkgPT4gewogICAgaWYgKHByZXYgJiYgaS1wcmV2ID4gMSkgaHRtbCArPSAnPHNwYW4gc3R5bGU9ImNvbG9yOnZhcigtLXRleHQzKTtwYWRkaW5nOjAgM3B4Ij7igKY8L3NwYW4+JzsKICAgIGh0bWwgKz0gYDxidXR0b24gY2xhc3M9InBhZ2UtYnRuICR7aT09PXBhZ2U/J2N1cic6Jyd9IiBvbmNsaWNrPSIoJHtjYi50b1N0cmluZygpfSkoJHtpfSkiPiR7aX08L2J1dHRvbj5gOwogICAgcHJldiA9IGk7CiAgfSk7CiAgaHRtbCArPSBgPGJ1dHRvbiBjbGFzcz0icGFnZS1idG4iIG9uY2xpY2s9Iigke2NiLnRvU3RyaW5nKCl9KSgke3BhZ2UrMX0pIiAke3BhZ2U+PXBhZ2VzPydkaXNhYmxlZCc6Jyd9PuKAujwvYnV0dG9uPmA7CiAgZWwoY29udGFpbmVySWQpLmlubmVySFRNTCA9IGh0bWw7Cn0KCi8vIOKUgOKUgOKUgCBNaXNjIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApmdW5jdGlvbiBlbChpZCkgeyByZXR1cm4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOyB9CmZ1bmN0aW9uIGVzYyhzKSB7IHJldHVybiBTdHJpbmcoc3x8JycpLnJlcGxhY2UoLyYvZywnJmFtcDsnKS5yZXBsYWNlKC88L2csJyZsdDsnKS5yZXBsYWNlKC8+L2csJyZndDsnKS5yZXBsYWNlKC8iL2csJyZxdW90OycpOyB9CgpmdW5jdGlvbiBsaXZlQ2xvY2soKSB7CiAgZWwoJ2xpdmUtdGltZScpLnRleHRDb250ZW50ID0gbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3J1Jyk7Cn0KCi8vIENsb3NlIG1vZGFscyBvbiBiYWNrZHJvcApbJ3VzZXItbW9kYWwnLCdub2RlLW1vZGFsJywncXItbW9kYWwnXS5mb3JFYWNoKGlkID0+IHsKICBlbChpZCkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBmdW5jdGlvbihlKSB7IGlmIChlLnRhcmdldCA9PT0gdGhpcykgdGhpcy5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7IH0pOwp9KTsKZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsgWyd1c2VyLW1vZGFsJywnbm9kZS1tb2RhbCcsJ3FyLW1vZGFsJ10uZm9yRWFjaChjbG9zZSk7IH0KfSk7CgovLyDilIDilIDilIAgSW5pdCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKKGFzeW5jIGZ1bmN0aW9uIGluaXQoKSB7CiAgbGl2ZUNsb2NrKCk7CiAgc2V0SW50ZXJ2YWwobGl2ZUNsb2NrLCAxMDAwKTsKICBhd2FpdCBsb2FkTm9kZXMoKTsgICAgLy8gbmVlZGVkIGJlZm9yZSB1c2VyIG1vZGFsCiAgYXdhaXQgbG9hZFNldHRpbmdzKCk7IC8vIG5lZWRlZCBmb3IgZGVmYXVsdCBkYXlzCiAgYXdhaXQgbG9hZERhc2goKTsKICBzZXRJbnRlcnZhbChsb2FkRGFzaCwgMTAwMDApOwp9KSgpOwo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==" | base64 -d > ${INSTALL_DIR}/templates/index.html
    echo "PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InJ1Ij4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+4pqhIGFteXIgcGFuZWwg4pqhIOKAlCDQktGF0L7QtDwvdGl0bGU+CjxzdHlsZT4KKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94fQpib2R5e2JhY2tncm91bmQ6IzA3MDcwZjtjb2xvcjojYzhjOGU4O2ZvbnQtZmFtaWx5Oi1hcHBsZS1zeXN0ZW0sQmxpbmtNYWNTeXN0ZW1Gb250LCdTZWdvZSBVSScsc2Fucy1zZXJpZjsKICAgICBtaW4taGVpZ2h0OjEwMHZoO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcn0KLmJveHtiYWNrZ3JvdW5kOiMwZDBkMWE7Ym9yZGVyOjFweCBzb2xpZCAjMWUxZTM4O2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjM2cHggMzJweDsKICAgICB3aWR0aDoxMDAlO21heC13aWR0aDozNjBweDtib3gtc2hhZG93OjAgOHB4IDQwcHggIzAwMDAwMDYwfQoubG9nb3t0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MjJweDtmb250LXdlaWdodDo4MDA7bWFyZ2luLWJvdHRvbTo2cHg7CiAgICAgIGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjNWI4YWY1LCM5Yjc3ZjUpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7CiAgICAgIC13ZWJraXQtdGV4dC1maWxsLWNvbG9yOnRyYW5zcGFyZW50fQouc3Vie3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMXB4O2NvbG9yOiMzYTNhNjA7bWFyZ2luLWJvdHRvbToyOHB4fQpsYWJlbHtkaXNwbGF5OmJsb2NrO2ZvbnQtc2l6ZToxMHB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojNTU1O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTsKICAgICAgbGV0dGVyLXNwYWNpbmc6LjVweDttYXJnaW4tYm90dG9tOjVweH0KaW5wdXR7d2lkdGg6MTAwJTtwYWRkaW5nOjEwcHggMTJweDtiYWNrZ3JvdW5kOiMwODA4MTA7Ym9yZGVyOjFweCBzb2xpZCAjMWExYTMwOwogICAgICBib3JkZXItcmFkaXVzOjdweDtjb2xvcjojZGRkO2ZvbnQtc2l6ZToxM3B4O21hcmdpbi1ib3R0b206MTRweH0KaW5wdXQ6Zm9jdXN7b3V0bGluZTpub25lO2JvcmRlci1jb2xvcjojNWI4YWY1NTV9CmJ1dHRvbnt3aWR0aDoxMDAlO3BhZGRpbmc6MTFweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzViOGFmNSwjNzY0YmEyKTsKICAgICAgIGNvbG9yOiNmZmY7Ym9yZGVyOm5vbmU7Ym9yZGVyLXJhZGl1czo3cHg7Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NzAwOwogICAgICAgY3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjpvcGFjaXR5IC4xNXM7bWFyZ2luLXRvcDo0cHh9CmJ1dHRvbjpob3ZlcntvcGFjaXR5Oi44OH0KLmVycntiYWNrZ3JvdW5kOiMzYTFhMWE7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkICNmODcxNzEzMDtib3JkZXItcmFkaXVzOjZweDsKICAgICBwYWRkaW5nOjhweCAxMnB4O2ZvbnQtc2l6ZToxMXB4O21hcmdpbi1ib3R0b206MTRweDt0ZXh0LWFsaWduOmNlbnRlcn0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0iYm94Ij4KICA8ZGl2IGNsYXNzPSJsb2dvIj7imqEgYW15ciBwYW5lbCDimqE8L2Rpdj4KICA8ZGl2IGNsYXNzPSJzdWIiPlZQTiBTdWJzY3JpcHRpb24gTWFuYWdlcjwvZGl2PgogIHslIGlmIGVycm9yICV9CiAgPGRpdiBjbGFzcz0iZXJyIj57eyBlcnJvciB9fTwvZGl2PgogIHslIGVuZGlmICV9CiAgPGZvcm0gbWV0aG9kPSJQT1NUIiBhY3Rpb249Ii9sb2dpbiI+CiAgICA8bGFiZWw+0JvQvtCz0LjQvTwvbGFiZWw+CiAgICA8aW5wdXQgdHlwZT0idGV4dCIgbmFtZT0idXNlcm5hbWUiIGF1dG9mb2N1cyBhdXRvY29tcGxldGU9InVzZXJuYW1lIj4KICAgIDxsYWJlbD7Qn9Cw0YDQvtC70Yw8L2xhYmVsPgogICAgPGlucHV0IHR5cGU9InBhc3N3b3JkIiBuYW1lPSJwYXNzd29yZCIgYXV0b2NvbXBsZXRlPSJjdXJyZW50LXBhc3N3b3JkIj4KICAgIDxidXR0b24gdHlwZT0ic3VibWl0Ij7QktC+0LnRgtC4PC9idXR0b24+CiAgPC9mb3JtPgo8L2Rpdj4KPC9ib2R5Pgo8L2h0bWw+Cg==" | base64 -d > ${INSTALL_DIR}/templates/login.html
}

# ── Update settings in DB after deploy ────────────────────────────────────────

update_db_settings() {
    if [[ -f "${INSTALL_DIR}/db.sqlite" ]]; then
        if [[ -n "$PANEL_DOMAIN" ]]; then
            BASE_URL="https://${PANEL_DOMAIN}"
        else
            BASE_URL="http://$(get_ip):${PANEL_PORT}"
        fi
        sqlite3 "${INSTALL_DIR}/db.sqlite" "INSERT OR REPLACE INTO settings (key,value) VALUES ('base_url','${BASE_URL}');" 2>/dev/null || true
        sqlite3 "${INSTALL_DIR}/db.sqlite" "INSERT OR REPLACE INTO settings (key,value) VALUES ('panel_title','${PANEL_TITLE}');" 2>/dev/null || true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  EXECUTION
# ══════════════════════════════════════════════════════════════════════════════

main() {
    banner
    check_root
    check_os
    check_existing

    setup_wizard
    install_dependencies

    mkdir -p ${INSTALL_DIR}/templates

    deploy_files
    create_config
    configure_firewall
    setup_service
    setup_nginx
    create_management_script
    update_db_settings

    # ── Final output ──────────────────────────────────────────────────────────

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        ✅  SubManager installed successfully!            ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    SERVER_IP=$(get_ip)

    if [[ -n "$PANEL_DOMAIN" ]]; then
        if [[ "$HTTPS_PORT" == "443" ]]; then
            echo -e "  ${WHITE}Panel URL:${NC}  ${CYAN}https://${PANEL_DOMAIN}${NC}"
        else
            echo -e "  ${WHITE}Panel URL:${NC}  ${CYAN}https://${PANEL_DOMAIN}:${HTTPS_PORT}${NC}"
        fi
    else
        echo -e "  ${WHITE}Panel URL:${NC}  ${CYAN}http://${SERVER_IP}:${PANEL_PORT}${NC}"
    fi
    echo -e "  ${WHITE}Username:${NC}   ${GREEN}${PANEL_USER}${NC}"
    echo -e "  ${WHITE}Password:${NC}   ${GREEN}${PANEL_PASS}${NC}"
    echo ""
    echo -e "  ${WHITE}Management:${NC} ${CYAN}submanager${NC}"
    echo -e "  ${WHITE}Service:${NC}    ${CYAN}systemctl status submanager${NC}"
    echo -e "  ${WHITE}Logs:${NC}       ${CYAN}journalctl -u submanager -f${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠  Save your credentials! They won't be shown again.${NC}"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

main "$@"
