#!/bin/bash
# ============================================================
#   GTKVPN - Módulo Firewall (UFW)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

menu_firewall() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                🛡️  MÓDULO FIREWALL${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    UFW_ST=$(ufw status 2>/dev/null | head -1 | grep -q "active" && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")
    
    echo -e " ${WHITE}UFW:${NC} $UFW_ST"
    echo ""
    echo -e " ${WHITE}[1]${NC} Ver reglas activas"
    echo -e " ${WHITE}[2]${NC} Abrir puerto"
    echo -e " ${WHITE}[3]${NC} Cerrar puerto"
    echo -e " ${WHITE}[4]${NC} Bloquear IP"
    echo -e " ${WHITE}[5]${NC} Desbloquear IP"
    echo -e " ${WHITE}[6]${NC} Activar / Desactivar UFW"
    echo -e " ${WHITE}[7]${NC} Resetear reglas"
    echo -e " ${WHITE}[8]${NC} Aplicar reglas GTKVPN (automático)"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT
    
    case $OPT in
        1)
            echo ""
            ufw status numbered 2>/dev/null
            press_enter; menu_firewall ;;
        2)
            echo -ne " ${WHITE}Puerto (ej. 8080 o 8080/tcp): ${NC}"; read PORT
            ufw allow "$PORT" && echo -e "${GREEN}[+] Puerto $PORT abierto${NC}" || echo -e "${RED}[!] Error${NC}"
            press_enter; menu_firewall ;;
        3)
            echo -ne " ${WHITE}Puerto a cerrar: ${NC}"; read PORT
            ufw delete allow "$PORT" && echo -e "${GREEN}[+] Puerto $PORT cerrado${NC}" || echo -e "${RED}[!] Error${NC}"
            press_enter; menu_firewall ;;
        4)
            echo -ne " ${WHITE}IP a bloquear: ${NC}"; read IP
            ufw deny from "$IP" && echo -e "${GREEN}[+] IP $IP bloqueada${NC}" || echo -e "${RED}[!] Error${NC}"
            press_enter; menu_firewall ;;
        5)
            echo -ne " ${WHITE}IP a desbloquear: ${NC}"; read IP
            ufw delete deny from "$IP" && echo -e "${GREEN}[+] IP $IP desbloqueada${NC}" || echo -e "${RED}[!] Error${NC}"
            press_enter; menu_firewall ;;
        6)
            if ufw status | grep -q "active"; then
                ufw --force disable && echo -e "${YELLOW}[-] UFW desactivado${NC}"
            else
                ufw --force enable && echo -e "${GREEN}[+] UFW activado${NC}"
            fi
            sleep 1; menu_firewall ;;
        7)
            echo -ne "${RED}[!] ¿Resetear TODAS las reglas? (si/no): ${NC}"; read CONF
            if [[ "$CONF" == "si" ]]; then
                ufw --force reset
                echo -e "${YELLOW}[!] Reglas reseteadas${NC}"
            fi
            press_enter; menu_firewall ;;
        8) apply_gtkvpn_rules ;;
        0) return ;;
        *) menu_firewall ;;
    esac
}

apply_gtkvpn_rules() {
    echo ""
    echo -e "${CYAN}[*] Aplicando reglas GTKVPN...${NC}"
    
    # Resetear y aplicar reglas base
    ufw --force reset 2>/dev/null
    ufw default deny incoming 2>/dev/null
    ufw default allow outgoing 2>/dev/null
    
    # Puertos base siempre abiertos
    ufw allow 22/tcp 2>/dev/null      # SSH
    ufw allow 80/tcp 2>/dev/null      # HTTP
    ufw allow 443/tcp 2>/dev/null     # HTTPS/SSL
    ufw allow 53/udp 2>/dev/null      # DNS
    
    # Puertos desde config
    for KEY in SSH_PORT SSH_WS_PORT XRAY_PORT SOCKS_PORT UDP_PORT UDPGW_PORT SDNS_PORT; do
        VAL=$(grep "^$KEY=" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2)
        if [[ -n "$VAL" ]] && [[ "$VAL" != "N/A" ]]; then
            ufw allow "$VAL" 2>/dev/null
            echo -e "  ${GREEN}✓${NC} Puerto $VAL ($KEY) abierto"
        fi
    done
    
    ufw --force enable 2>/dev/null
    
    echo ""
    echo -e "${GREEN}[+] Reglas aplicadas${NC}"
    press_enter
    menu_firewall
}

menu_firewall
