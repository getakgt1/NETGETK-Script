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

    # Detener nginx si está corriendo (liberar el puerto)
    systemctl stop nginx 2>/dev/null
    systemctl disable nginx 2>/dev/null

    # Configurar Dropbear en puerto 2222
    sed -i 's/#DROPBEAR_PORT=22/DROPBEAR_PORT=2222/' /etc/default/dropbear
    sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=2222/' /etc/default/dropbear
    # Generar llaves faltantes de Dropbear
    [[ ! -f /etc/dropbear/dropbear_dss_host_key ]] && dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key 2>/dev/null
    [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]] && dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null
    systemctl restart dropbear 2>/dev/null

    # Crear proxy HTTP->SSH simple (compatible con HTTP Custom/payload)
    cat > /usr/local/bin/ssh-ws.py << PYEOF
#!/usr/bin/env python3
import socket, threading, select

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = $WS_PORT
SSH_HOST    = "127.0.0.1"
SSH_PORT    = 2222
BUFFER      = 4096
RESPONSE    = b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"

def tunnel(src, dst):
    while True:
        try:
            r, _, _ = select.select([src, dst], [], [], 60)
            if not r: break
            for s in r:
                data = s.recv(BUFFER)
                if not data: return
                (dst if s is src else src).sendall(data)
        except: break
    src.close(); dst.close()

def handle(client):
    try:
        client.recv(BUFFER)
        client.sendall(RESPONSE)
        ssh = socket.create_connection((SSH_HOST, SSH_PORT), timeout=10)
        ssh.setblocking(True)
        threading.Thread(target=tunnel, args=(client, ssh), daemon=True).start()
    except Exception as e:
        print(f"Error: {e}")
        client.close()

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((LISTEN_HOST, LISTEN_PORT))
server.listen(200)
print(f"Proxy HTTP->SSH corriendo en :{LISTEN_PORT}")
while True:
    try:
        client, _ = server.accept()
        client.settimeout(30)
        threading.Thread(target=handle, args=(client,), daemon=True).start()
    except: pass
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

    # Guardar en config (sin duplicados)
    sed -i "/^SSH_WS_PORT=/d" $INSTALL_DIR/config.conf && echo "SSH_WS_PORT=$WS_PORT" >> $INSTALL_DIR/config.conf

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
