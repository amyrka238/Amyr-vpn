#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  SubManager — Config Viewer
#  Usage: bash show-configs.sh [option]
#═══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

show_nginx() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Nginx Configuration                                     ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
    
    CONF="/etc/nginx/sites-available/submanager"
    
    if [[ -f "$CONF" ]]; then
        echo -e "${GREEN}✓ Config found at:${NC} $CONF\n"
        echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        cat "$CONF"
        echo -e "\n${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        
        if [[ -L /etc/nginx/sites-enabled/submanager ]]; then
            echo -e "${GREEN}✓ Enabled (linked to sites-enabled)${NC}\n"
        else
            echo -e "${YELLOW}⚠ Not enabled yet${NC}\n"
        fi
        
        echo -e "${WHITE}Nginx test:${NC}"
        nginx -t 2>&1
    else
        echo -e "${YELLOW}⚠ Nginx config not found (IP mode?)${NC}"
        echo -e "   Location: $CONF"
    fi
}

show_app_config() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Application Configuration (config.json)                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
    
    APPCONF="/opt/submanager/config.json"
    
    if [[ -f "$APPCONF" ]]; then
        echo -e "${GREEN}✓ Config found at:${NC} $APPCONF\n"
        echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        
        if command -v jq &>/dev/null; then
            cat "$APPCONF" | jq .
        else
            cat "$APPCONF"
        fi
        
        echo -e "\n${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        
        echo -e "${WHITE}File info:${NC}"
        ls -lh "$APPCONF"
    else
        echo -e "${RED}✗ Config not found!${NC}"
        echo -e "   Location: $APPCONF"
    fi
}

show_systemd_config() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Systemd Service Configuration                           ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
    
    SVC="/etc/systemd/system/submanager.service"
    
    if [[ -f "$SVC" ]]; then
        echo -e "${GREEN}✓ Service found at:${NC} $SVC\n"
        echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        cat "$SVC"
        echo -e "\n${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        
        echo -e "${WHITE}Service status:${NC}"
        systemctl status submanager --no-pager
    else
        echo -e "${RED}✗ Service file not found!${NC}"
        echo -e "   Location: $SVC"
    fi
}

show_all_configs() {
    show_nginx
    echo -e "\n\n"
    read -p "Press Enter to continue..."
    show_app_config
    echo -e "\n\n"
    read -p "Press Enter to continue..."
    show_systemd_config
}

show_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       SubManager — Config Viewer                               ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "  ${WHITE}1)${NC} Show Nginx config"
    echo -e "  ${WHITE}2)${NC} Show App config (config.json)"
    echo -e "  ${WHITE}3)${NC} Show Systemd service config"
    echo -e "  ${WHITE}4)${NC} Show all configs"
    echo -e "  ${WHITE}0)${NC} Exit\n"
    
    read -p "Choose: " choice
    case $choice in
        1) show_nginx ;;
        2) show_app_config ;;
        3) show_systemd_config ;;
        4) show_all_configs ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    show_menu
}

# If argument provided, run specific command
if [[ $# -gt 0 ]]; then
    case $1 in
        nginx) show_nginx ;;
        app) show_app_config ;;
        service) show_systemd_config ;;
        all) show_all_configs ;;
        *) echo "Usage: $0 [nginx|app|service|all]"; exit 1 ;;
    esac
else
    # Interactive mode
    show_menu
fi

