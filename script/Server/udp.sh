#!/bin/bash
# ============================================================
#   GTKVPN - Módulo UDP Custom + BadVPN-UDPgw
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

menu_udp() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}              📡 MÓDULO UDP CUSTOM + BADVPN${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    UDP_ST=$(systemctl is-active --quiet udp-custom 2>/dev/null && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")
    BADVPN_ST=$(systemctl is-active --quiet badvpn-udpgw 2>/dev/null && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")
    
    UDP_PORT=$(grep "UDP_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "N/A")
    
    echo -e " ${WHITE}UDP Custom:${NC} $UDP_ST  ${WHITE}Puerto:${NC} ${CYAN}$UDP_PORT${NC}"
    echo -e " ${WHITE}BadVPN-UDPgw:${NC} $BADVPN_ST"
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar UDP Custom"
    echo -e " ${WHITE}[2]${NC} Instalar BadVPN-UDPgw"
    echo -e " ${WHITE}[3]${NC} Instalar ambos"
    echo -e " ${WHITE}[4]${NC} Cambiar puerto UDP"
    echo -e " ${WHITE}[5]${NC} Ver conexiones UDP"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT
    
    case $OPT in
        1) install_udp_custom ;;
        2) install_badvpn ;;
        3) install_udp_custom; install_badvpn ;;
        4) change_udp_port ;;
        5) show_udp_conns ;;
        0) return ;;
        *) menu_udp ;;
    esac
}

install_udp_custom() {
    echo ""
    echo -e "${CYAN}[*] Instalando UDP Custom...${NC}"
    
    echo -ne " ${WHITE}Puerto UDP (ej. 36712): ${NC}"; read UDP_PORT
    [[ -z "$UDP_PORT" ]] && UDP_PORT=36712
    
    # Crear servidor UDP Python
    cat > /usr/local/bin/udp-custom.py << 'PYEOF'
#!/usr/bin/env python3
"""UDP Custom Server - GTKVPN"""
import socket
import threading
import sys
import os

HOST = '0.0.0.0'
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 36712
BUFFER = 65535

def handle_udp():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((HOST, PORT))
    print(f"UDP Custom escuchando en :{PORT}")
    
    clients = {}
    
    while True:
        try:
            data, addr = sock.recvfrom(BUFFER)
            if not data:
                continue
            
            # Identificar cliente
            if addr not in clients:
                clients[addr] = True
                print(f"Nueva conexión UDP: {addr}")
            
            # Echo / relay básico
            # En producción aquí iría la lógica de tunelización
            sock.sendto(data, addr)
            
        except Exception as e:
            pass

handle_udp()
PYEOF
    chmod +x /usr/local/bin/udp-custom.py
    
    # Servicio systemd
    cat > /etc/systemd/system/udp-custom.service << SVC
[Unit]
Description=UDP Custom Server - GTKVPN
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/udp-custom.py $UDP_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
    
    systemctl daemon-reload
    systemctl enable udp-custom 2>/dev/null
    systemctl restart udp-custom
    
    ufw allow "$UDP_PORT/udp" 2>/dev/null
    
    # Guardar config
    sed -i '/^UDP_PORT=/d' $INSTALL_DIR/config.conf 2>/dev/null
    echo "UDP_PORT=$UDP_PORT" >> $INSTALL_DIR/config.conf
    
    if systemctl is-active --quiet udp-custom; then
        echo -e "${GREEN}[+] UDP Custom activo en puerto $UDP_PORT${NC}"
    else
        echo -e "${RED}[!] Error iniciando UDP Custom${NC}"
    fi
    press_enter
    [[ "$1" != "silent" ]] && menu_udp
}

install_badvpn() {
    echo ""
    echo -e "${CYAN}[*] Instalando BadVPN-UDPgw...${NC}"
    
    # Intentar instalar desde apt
    apt install -y badvpn 2>/dev/null
    
    # Si no está en apt, compilar desde fuente
    if ! command -v badvpn-udpgw &>/dev/null; then
        echo -e "${CYAN}  → Compilando desde fuente...${NC}"
        apt install -y cmake build-essential 2>/dev/null
        
        cd /tmp
        wget -q "https://github.com/ambrop72/badvpn/archive/master.zip" -O badvpn.zip
        unzip -q badvpn.zip 2>/dev/null
        cd badvpn-master
        mkdir -p build && cd build
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 2>/dev/null
        make 2>/dev/null
        cp udpgw/badvpn-udpgw /usr/local/bin/ 2>/dev/null
        cd / && rm -rf /tmp/badvpn*
    fi
    
    if [[ ! -f /usr/local/bin/badvpn-udpgw ]]; then
        echo -e "${RED}[!] No se pudo instalar badvpn-udpgw${NC}"
        press_enter; menu_udp; return
    fi
    
    echo -ne " ${WHITE}Puerto UDPgw (ej. 7300): ${NC}"; read UDPGW_PORT
    [[ -z "$UDPGW_PORT" ]] && UDPGW_PORT=7300
    
    # Servicio badvpn
    cat > /etc/systemd/system/badvpn-udpgw.service << SVC
[Unit]
Description=BadVPN UDPgw - GTKVPN
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:$UDPGW_PORT --max-clients 500 --max-connections-for-client 10
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
    
    systemctl daemon-reload
    systemctl enable badvpn-udpgw 2>/dev/null
    systemctl restart badvpn-udpgw
    
    sed -i '/^UDPGW_PORT=/d' $INSTALL_DIR/config.conf 2>/dev/null
    echo "UDPGW_PORT=$UDPGW_PORT" >> $INSTALL_DIR/config.conf
    
    if systemctl is-active --quiet badvpn-udpgw; then
        echo -e "${GREEN}[+] BadVPN-UDPgw activo en 127.0.0.1:$UDPGW_PORT${NC}"
    else
        echo -e "${RED}[!] Error iniciando BadVPN${NC}"
    fi
    
    press_enter; menu_udp
}

change_udp_port() {
    echo -ne " ${WHITE}Nuevo puerto UDP: ${NC}"; read PORT
    sed -i "s|ExecStart=.*|ExecStart=/usr/bin/python3 /usr/local/bin/udp-custom.py $PORT|" \
        /etc/systemd/system/udp-custom.service 2>/dev/null
    systemctl daemon-reload
    systemctl restart udp-custom
    sed -i "s/^UDP_PORT=.*/UDP_PORT=$PORT/" $INSTALL_DIR/config.conf
    ufw allow "$PORT/udp" 2>/dev/null
    echo -e "${GREEN}[+] Puerto UDP cambiado a $PORT${NC}"
    press_enter; menu_udp
}

show_udp_conns() {
    UDP_PORT=$(grep "UDP_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "36712")
    echo ""
    echo -e "${CYAN}[ CONEXIONES UDP en :$UDP_PORT ]${NC}"
    ss -unp | grep ":$UDP_PORT" 2>/dev/null || echo "Sin conexiones activas"
    press_enter; menu_udp
}

# Soporte para llamada directa con argumento
case "$1" in
    badvpn) install_badvpn ;;
    *)      menu_udp ;;
esac
