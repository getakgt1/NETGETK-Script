#!/bin/bash
# ============================================================
#   GTKVPN - Módulo SlowDNS (dnstt)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
DNSTT_URL_AMD64="https://www.bamsoftware.com/software/dnstt/dnstt-20220208.zip"
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

install_binary() {
    echo -e "${CYAN}[*] Instalando binario dnstt (SlowDNS)...${NC}"

    # Verificar si ya está instalado y funciona
    if [[ -f /usr/local/bin/slowdns ]] && /usr/local/bin/slowdns --help 2>&1 | grep -q "gen-key"; then
        echo -e "${GREEN}[+] Binario ya instalado${NC}"
        return 0
    fi

    # Verificar Go
    if ! command -v go &>/dev/null; then
        echo -e "${CYAN}[*] Instalando Go...${NC}"
        apt-get install -y golang-go 2>/dev/null || apt-get install -y golang 2>/dev/null
    fi

    if ! command -v go &>/dev/null; then
        echo -e "${RED}[!] No se pudo instalar Go. Instálalo manualmente.${NC}"
        press_enter; return 1
    fi

    # Compilar dnstt
    cd /tmp
    rm -rf dnstt-20220208*
    wget -q -O dnstt.zip "$DNSTT_URL_AMD64"
    if [[ ! -f dnstt.zip ]]; then
        echo -e "${RED}[!] No se pudo descargar dnstt${NC}"
        press_enter; return 1
    fi

    unzip -q dnstt.zip
    cd dnstt-20220208/dnstt-server
    go build -o /usr/local/bin/slowdns . 2>/dev/null
    chmod +x /usr/local/bin/slowdns
    cd /tmp && rm -rf dnstt-20220208*

    if /usr/local/bin/slowdns --help 2>&1 | grep -q "gen-key"; then
        echo -e "${GREEN}[+] Binario compilado correctamente${NC}"
        return 0
    else
        echo -e "${RED}[!] Error compilando binario${NC}"
        press_enter; return 1
    fi
}

install_slowdns() {
    echo ""
    echo -e "${CYAN}[*] Instalando SlowDNS...${NC}"

    install_binary || return

    # Generar claves si no existen
    if [[ ! -s $INSTALL_DIR/slowdns.key ]]; then
        gen_keys_silent
    fi

    # Configuración
    echo ""
    echo -e "${YELLOW}[!] Necesitas un subdominio NS apuntando a este VPS${NC}"
    VPS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
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

    # Guardar también en config.conf principal
    grep -q "SDNS_DOMAIN" $INSTALL_DIR/config.conf 2>/dev/null && \
        sed -i "s/SDNS_DOMAIN=.*/SDNS_DOMAIN=$SDNS_DOMAIN/" $INSTALL_DIR/config.conf || \
        echo "SDNS_DOMAIN=$SDNS_DOMAIN" >> $INSTALL_DIR/config.conf
    grep -q "SDNS_PORT" $INSTALL_DIR/config.conf 2>/dev/null && \
        sed -i "s/SDNS_PORT=.*/SDNS_PORT=$SDNS_PORT/" $INSTALL_DIR/config.conf || \
        echo "SDNS_PORT=$SDNS_PORT" >> $INSTALL_DIR/config.conf

    # Crear servicio usando formato dnstt
    cat > /etc/systemd/system/slowdns.service << SVC
[Unit]
Description=SlowDNS Server - GTKVPN
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/slowdns -udp :${SDNS_PORT} -privkey-file ${INSTALL_DIR}/slowdns.key ${SDNS_DOMAIN} 127.0.0.1:22
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

    sleep 2
    if systemctl is-active --quiet slowdns; then
        PUBKEY=$(cat $INSTALL_DIR/slowdns.pub 2>/dev/null)
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║         SLOWDNS CONFIGURADO ✓                 ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Dominio:${NC} ${CYAN}$SDNS_DOMAIN${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Puerto:${NC}  ${CYAN}$SDNS_PORT${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Pubkey:${NC}  ${YELLOW}$PUBKEY${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}[!] Error iniciando SlowDNS${NC}"
        journalctl -u slowdns -n 10 --no-pager
    fi

    press_enter; menu_slowdns
}

gen_keys_silent() {
    mkdir -p $INSTALL_DIR
    # dnstt genera claves en formato hex
    /usr/local/bin/slowdns -gen-key \
        -privkey-file $INSTALL_DIR/slowdns.key \
        -pubkey-file $INSTALL_DIR/slowdns.pub 2>/dev/null

    # Compatibilidad: también guardar en formato antiguo
    [[ -f $INSTALL_DIR/slowdns.pub ]] && \
        cp $INSTALL_DIR/slowdns.pub $INSTALL_DIR/slowdns_pub.key
    [[ -f $INSTALL_DIR/slowdns.key ]] && \
        cp $INSTALL_DIR/slowdns.key $INSTALL_DIR/slowdns_priv.key
}

gen_keys() {
    echo ""
    # Instalar binario si no existe
    if [[ ! -f /usr/local/bin/slowdns ]]; then
        install_binary || return
    fi
    echo -e "${CYAN}[*] Generando claves SlowDNS...${NC}"
    gen_keys_silent
    if [[ -s $INSTALL_DIR/slowdns.pub ]]; then
        echo -e "${GREEN}[+] Claves generadas${NC}"
        show_pubkey
    else
        echo -e "${RED}[!] Error generando claves${NC}"
        press_enter; menu_slowdns
    fi
}

show_pubkey() {
    echo ""
    PUBFILE=$INSTALL_DIR/slowdns.pub
    [[ ! -f $PUBFILE ]] && PUBFILE=$INSTALL_DIR/slowdns_pub.key
    if [[ -f $PUBFILE ]]; then
        PUBKEY=$(cat $PUBFILE)
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
