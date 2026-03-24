#!/bin/bash
# ============================================================
#   GTKVPN - Módulo SlowDNS
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

menu_slowdns() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                🐢 MÓDULO SLOWDNS${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    SDNS_ST=$(systemctl is-active --quiet slowdns 2>/dev/null && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")
    
    echo -e " ${WHITE}Estado SlowDNS:${NC} $SDNS_ST"
    
    if [[ -f $INSTALL_DIR/slowdns.conf ]]; then
        source $INSTALL_DIR/slowdns.conf
        echo -e " ${WHITE}Dominio NS:${NC}   ${CYAN}$SDNS_DOMAIN${NC}"
        echo -e " ${WHITE}Puerto:${NC}       ${CYAN}$SDNS_PORT${NC}"
    fi
    
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar y configurar SlowDNS"
    echo -e " ${WHITE}[2]${NC} Generar claves (pública/privada)"
    echo -e " ${WHITE}[3]${NC} Ver clave pública"
    echo -e " ${WHITE}[4]${NC} Iniciar / Detener"
    echo -e " ${WHITE}[5]${NC} Ver estado"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT
    
    case $OPT in
        1) install_slowdns ;;
        2) gen_keys ;;
        3) show_pubkey ;;
        4) toggle_slowdns ;;
        5) systemctl status slowdns --no-pager; press_enter; menu_slowdns ;;
        0) return ;;
        *) menu_slowdns ;;
    esac
}

install_slowdns() {
    echo ""
    echo -e "${CYAN}[*] Instalando SlowDNS...${NC}"
    
    # Descargar slowdns
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        SDNS_URL="https://github.com/freenetwork/slowdns/releases/latest/download/slowdns-linux-amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        SDNS_URL="https://github.com/freenetwork/slowdns/releases/latest/download/slowdns-linux-arm64"
    else
        echo -e "${RED}[!] Arquitectura no soportada: $ARCH${NC}"
        press_enter; return
    fi
    
    wget -q -O /usr/local/bin/slowdns "$SDNS_URL"
    chmod +x /usr/local/bin/slowdns
    
    if [[ ! -f /usr/local/bin/slowdns ]]; then
        echo -e "${RED}[!] No se pudo descargar slowdns${NC}"
        press_enter; menu_slowdns; return
    fi
    
    echo -e "${GREEN}[+] SlowDNS descargado${NC}"
    
    # Generar claves si no existen
    if [[ ! -f /etc/gtkvpn/slowdns_priv.key ]]; then
        gen_keys_silent
    fi
    
    # Configuración
    echo ""
    echo -e "${YELLOW}[!] Necesitas un subdominio NS apuntando a este VPS${NC}"
    echo -e "${YELLOW}    Ejemplo: ns1.tudominio.com -> $VPS_IP${NC}"
    echo ""
    echo -ne " ${WHITE}Subdominio NS (ej. ns1.tudominio.com): ${NC}"; read SDNS_DOMAIN
    [[ -z "$SDNS_DOMAIN" ]] && { echo -e "${RED}[!] Requerido${NC}"; press_enter; menu_slowdns; return; }
    
    echo -ne " ${WHITE}Puerto SlowDNS (ej. 5300): ${NC}"; read SDNS_PORT
    [[ -z "$SDNS_PORT" ]] && SDNS_PORT=5300
    
    # Guardar config
    cat > $INSTALL_DIR/slowdns.conf << CONF
SDNS_DOMAIN=$SDNS_DOMAIN
SDNS_PORT=$SDNS_PORT
CONF
    
    # Obtener clave pública
    PUBKEY=$(cat /etc/gtkvpn/slowdns_pub.key 2>/dev/null)
    
    # Crear servicio
    cat > /etc/systemd/system/slowdns.service << SVC
[Unit]
Description=SlowDNS Server - GTKVPN
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/slowdns server -pubkey $PUBKEY -privkey $(cat /etc/gtkvpn/slowdns_priv.key) -domain $SDNS_DOMAIN -port $SDNS_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
    
    systemctl daemon-reload
    systemctl enable slowdns 2>/dev/null
    systemctl start slowdns
    
    ufw allow 53/udp 2>/dev/null
    ufw allow "$SDNS_PORT/udp" 2>/dev/null
    
    if systemctl is-active --quiet slowdns; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║         SLOWDNS CONFIGURADO ✓                 ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Dominio:${NC} ${CYAN}$SDNS_DOMAIN${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Puerto:${NC}  ${CYAN}$SDNS_PORT${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Clave:${NC}   ${YELLOW}$PUBKEY${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}[!] Error iniciando SlowDNS${NC}"
        journalctl -u slowdns -n 5 --no-pager
    fi
    
    press_enter; menu_slowdns
}

gen_keys() {
    echo ""
    echo -e "${CYAN}[*] Generando claves SlowDNS...${NC}"
    gen_keys_silent
    echo -e "${GREEN}[+] Claves generadas${NC}"
    show_pubkey
}

gen_keys_silent() {
    mkdir -p /etc/gtkvpn
    /usr/local/bin/slowdns genkey 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qi "pub"; then
            echo "$line" | grep -oP '[A-Za-z0-9+/=]{20,}' > /etc/gtkvpn/slowdns_pub.key
        elif echo "$line" | grep -qi "priv\|secret"; then
            echo "$line" | grep -oP '[A-Za-z0-9+/=]{20,}' > /etc/gtkvpn/slowdns_priv.key
        fi
    done
    
    # Alternativa si genkey no funciona
    if [[ ! -s /etc/gtkvpn/slowdns_priv.key ]]; then
        openssl genrsa -out /tmp/sdns_key.pem 2048 2>/dev/null
        openssl rsa -in /tmp/sdns_key.pem -pubout -out /tmp/sdns_pub.pem 2>/dev/null
        openssl rsa -in /tmp/sdns_key.pem -outform DER 2>/dev/null | base64 -w0 > /etc/gtkvpn/slowdns_priv.key
        openssl rsa -in /tmp/sdns_key.pem -pubout -outform DER 2>/dev/null | base64 -w0 > /etc/gtkvpn/slowdns_pub.key
        rm -f /tmp/sdns_key.pem /tmp/sdns_pub.pem
    fi
}

show_pubkey() {
    echo ""
    if [[ -f /etc/gtkvpn/slowdns_pub.key ]]; then
        PUBKEY=$(cat /etc/gtkvpn/slowdns_pub.key)
        echo -e "${WHITE}Clave pública SlowDNS:${NC}"
        echo -e "${CYAN}$PUBKEY${NC}"
        echo ""
        echo -e "${YELLOW}[!] Usa esta clave en tu app para conectar via SlowDNS${NC}"
    else
        echo -e "${RED}[!] Claves no generadas aún. Usa opción [2]${NC}"
    fi
    press_enter; menu_slowdns
}

toggle_slowdns() {
    if systemctl is-active --quiet slowdns; then
        systemctl stop slowdns
        echo -e "${YELLOW}[-] SlowDNS detenido${NC}"
    else
        systemctl start slowdns
        echo -e "${GREEN}[+] SlowDNS iniciado${NC}"
    fi
    sleep 1; menu_slowdns
}

menu_slowdns
