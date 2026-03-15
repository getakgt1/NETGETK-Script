#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
INSTALL_DIR="/etc/gtkvpn"
UDP_DIR="/root/udp"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read; }

menu_udp() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                  📡 MÓDULO UDP CUSTOM${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    UDP_PORT=$(cat $UDP_DIR/config.json 2>/dev/null | grep listen | grep -o '[0-9]*' || echo "N/A")
    systemctl is-active --quiet udp-custom 2>/dev/null && STATUS="${GREEN}activo ✓${NC}" || STATUS="${RED}inactivo${NC}"
    echo -e " ${WHITE}Puerto UDP:${NC}  ${CYAN}$UDP_PORT${NC}"
    echo -e " ${WHITE}Estado:${NC}      $STATUS"
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar UDP Custom"
    echo -e " ${WHITE}[2]${NC} Cambiar puerto UDP"
    echo -e " ${WHITE}[3]${NC} Ver conexiones activas"
    echo -e " ${WHITE}[4]${NC} Reiniciar UDP Custom"
    echo -e " ${WHITE}[5]${NC} Ver logs"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "; read OPT
    case $OPT in
        1) install_udp ;;
        2) change_udp_port ;;
        3) show_connections ;;
        4) systemctl restart udp-custom; echo -e "${GREEN}[+] UDP reiniciado${NC}"; sleep 1; menu_udp ;;
        5) journalctl -u udp-custom -n 30 --no-pager; press_enter; menu_udp ;;
        0) return ;;
        *) menu_udp ;;
    esac
}

install_udp() {
    echo ""
    echo -e "${CYAN}[1/5] Instalando UDP Custom...${NC}"
    echo -ne " ${WHITE}Puerto UDP (ej. 36712): ${NC}"; read UDP_PORT
    [[ -z "$UDP_PORT" ]] && UDP_PORT=36712

    apt install curl -y -q

    echo -e "${CYAN}[2/5] Descargando binario...${NC}"
    mkdir -p $UDP_DIR
    # Descargar binario udp-custom
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        curl -sL "https://github.com/http-custom/udp-custom/releases/latest/download/server-amd64" -o $UDP_DIR/udp-custom
    elif [[ "$ARCH" == "aarch64" ]]; then
        curl -sL "https://github.com/http-custom/udp-custom/releases/latest/download/server-arm64" -o $UDP_DIR/udp-custom
    fi
    chmod +x $UDP_DIR/udp-custom

    echo -e "${CYAN}[3/5] Creando configuración...${NC}"
    cat > $UDP_DIR/config.json << CFGEOF
{
  "listen": ":$UDP_PORT",
  "stream_buffer": 33554432,
  "receive_buffer": 83886080,
  "auth": {
    "mode": "passwords"
  }
}
CFGEOF

    echo -e "${CYAN}[4/5] Creando servicio systemd...${NC}"
    cat > /etc/systemd/system/udp-custom.service << SVCEOF
[Unit]
Description=UDP Custom by ePro Dev. Team
[Service]
User=root
Type=simple
ExecStart=$UDP_DIR/udp-custom server
WorkingDirectory=$UDP_DIR/
Restart=always
RestartSec=2s
[Install]
WantedBy=default.target
SVCEOF

    systemctl daemon-reload
    systemctl enable udp-custom
    systemctl start udp-custom
    ufw allow "$UDP_PORT/udp" 2>/dev/null

    # Guardar en config
    mkdir -p $INSTALL_DIR
    grep -q "UDP_PORT" $INSTALL_DIR/config.conf 2>/dev/null \
        && sed -i "s/^UDP_PORT=.*/UDP_PORT=$UDP_PORT/" $INSTALL_DIR/config.conf \
        || echo "UDP_PORT=$UDP_PORT" >> $INSTALL_DIR/config.conf

    echo -e "${CYAN}[5/5] Verificando...${NC}"
    sleep 2
    systemctl is-active --quiet udp-custom \
        && echo -e " ${GREEN}✓ UDP Custom activo en puerto $UDP_PORT${NC}" \
        || echo -e " ${RED}✗ Error iniciando UDP Custom${NC}"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE} 📱 HTTP Custom: IP:$UDP_PORT | UDP Custom ✓${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    press_enter; menu_udp
}

change_udp_port() {
    echo -ne " ${WHITE}Nuevo puerto UDP: ${NC}"; read NEW_PORT
    [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] && echo -e "${RED}[!] Puerto inválido${NC}" && press_enter && menu_udp && return
    sed -i "s/\"listen\": \":[0-9]*/\"listen\": \":$NEW_PORT/" $UDP_DIR/config.json
    ufw allow "$NEW_PORT/udp" 2>/dev/null
    systemctl restart udp-custom
    sed -i "s/^UDP_PORT=.*/UDP_PORT=$NEW_PORT/" $INSTALL_DIR/config.conf 2>/dev/null
    echo -e "${GREEN}[+] Puerto UDP cambiado a $NEW_PORT${NC}"
    press_enter; menu_udp
}

show_connections() {
    echo ""
    echo -e "${CYAN}[ CONEXIONES UDP ACTIVAS ]${NC}"
    ss -unp | grep ":$(cat $UDP_DIR/config.json 2>/dev/null | grep listen | grep -o '[0-9]*')" 2>/dev/null
    echo ""
    journalctl -u udp-custom -n 20 --no-pager
    press_enter; menu_udp
}

menu_udp
