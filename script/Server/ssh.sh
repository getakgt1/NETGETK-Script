#!/bin/bash
# ============================================================
#   GTKVPN - Módulo SSH + WebSocket
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

menu_ssh() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                    🔐 MÓDULO SSH${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    SSH_WS_PORT=$(grep "SSH_WS_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "N/A")
    
    echo -e " ${WHITE}Puerto SSH actual:${NC} ${CYAN}$SSH_PORT${NC}"
    echo -e " ${WHITE}WebSocket SSH:${NC} ${CYAN}$SSH_WS_PORT${NC}"
    echo ""
    echo -e " ${WHITE}[1]${NC} Cambiar puerto SSH"
    echo -e " ${WHITE}[2]${NC} Instalar/configurar SSH WebSocket"
    echo -e " ${WHITE}[3]${NC} Ver estado SSH"
    echo -e " ${WHITE}[4]${NC} Reiniciar SSH"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT
    
    case $OPT in
        1) change_ssh_port ;;
        2) install_ssh_ws ;;
        3) status_ssh ;;
        4) systemctl restart ssh; echo -e "${GREEN}[+] SSH reiniciado${NC}"; sleep 1; menu_ssh ;;
        0) return ;;
        *) menu_ssh ;;
    esac
}

change_ssh_port() {
    echo ""
    echo -ne " ${WHITE}Nuevo puerto SSH (ej. 22 o 2222): ${NC}"; read NEW_PORT
    
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [[ $NEW_PORT -lt 1 ]] || [[ $NEW_PORT -gt 65535 ]]; then
        echo -e "${RED}[!] Puerto inválido${NC}"; press_enter; menu_ssh; return
    fi
    
    # Cambiar en sshd_config
    sed -i "s/^#*Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
    
    # Abrir en UFW
    ufw allow "$NEW_PORT/tcp" 2>/dev/null
    
    systemctl restart ssh
    
    # Guardar en config
    sed -i "s/^SSH_PORT=.*/SSH_PORT=$NEW_PORT/" $INSTALL_DIR/config.conf 2>/dev/null
    
    echo -e "${GREEN}[+] Puerto SSH cambiado a $NEW_PORT${NC}"
    echo -e "${YELLOW}[!] Reconéctate usando el nuevo puerto${NC}"
    press_enter
    menu_ssh
}

install_ssh_ws() {
    echo ""
    echo -e "${CYAN}[*] Instalando SSH WebSocket...${NC}"
    echo -ne " ${WHITE}Puerto para WebSocket SSH (ej. 80): ${NC}"; read WS_PORT
    [[ -z "$WS_PORT" ]] && WS_PORT=80
    
    # Instalar python3-websockets si no está
    python3 -c "import websockets" 2>/dev/null || apt install python3-websockets -y -q
    
    SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}' || echo "22")
    
    # Crear script de WebSocket SSH
    cat > /usr/local/bin/ssh-ws.py << PYEOF
#!/usr/bin/env python3
"""SSH WebSocket Proxy - GTKVPN"""
import asyncio
import websockets
import socket
import sys

SSH_HOST = "127.0.0.1"
SSH_PORT = ${SSH_PORT}
WS_PORT  = ${WS_PORT}

async def forward(ws, reader, writer):
    async def ws_to_ssh():
        try:
            async for data in ws:
                writer.write(data if isinstance(data, bytes) else data.encode())
                await writer.drain()
        except: pass
        finally: writer.close()

    async def ssh_to_ws():
        try:
            while True:
                data = await reader.read(4096)
                if not data: break
                await ws.send(data)
        except: pass

    await asyncio.gather(ws_to_ssh(), ssh_to_ws())

async def handler(ws, path):
    # Responder handshake HTTP personalizado
    reader, writer = await asyncio.open_connection(SSH_HOST, SSH_PORT)
    await forward(ws, reader, writer)

async def main():
    async with websockets.serve(handler, "0.0.0.0", WS_PORT,
                                 subprotocols=["binary"],
                                 ping_interval=None):
        print(f"SSH WebSocket corriendo en :{WS_PORT} → SSH :{SSH_PORT}")
        await asyncio.Future()

asyncio.run(main())
PYEOF
    chmod +x /usr/local/bin/ssh-ws.py
    
    # Crear servicio systemd
    cat > /etc/systemd/system/ssh-ws.service << SVC
[Unit]
Description=SSH WebSocket Proxy - GTKVPN
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-ws.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
    
    systemctl daemon-reload
    systemctl enable ssh-ws 2>/dev/null
    systemctl restart ssh-ws
    
    # Abrir puerto en UFW
    ufw allow "$WS_PORT/tcp" 2>/dev/null
    
    # Guardar en config
    echo "SSH_WS_PORT=$WS_PORT" >> $INSTALL_DIR/config.conf
    
    if systemctl is-active --quiet ssh-ws; then
        echo -e "${GREEN}[+] SSH WebSocket activo en puerto $WS_PORT${NC}"
    else
        echo -e "${RED}[!] Error iniciando SSH WebSocket${NC}"
    fi
    
    press_enter
    menu_ssh
}

status_ssh() {
    echo ""
    echo -e "${CYAN}[ ESTADO SSH ]${NC}"
    systemctl status ssh --no-pager 2>/dev/null
    echo ""
    echo -e "${CYAN}[ CONEXIONES ACTIVAS ]${NC}"
    ss -tnp | grep ":22\|:$(grep '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')" 2>/dev/null
    press_enter
    menu_ssh
}

menu_ssh
