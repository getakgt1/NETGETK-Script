#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
INSTALL_DIR="/etc/gtkvpn"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read; }

menu_ssh() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                    🔐 MÓDULO SSH${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    SSH_WS_PORT=$(grep "SSH_WS_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "N/A")
    DB_PORT=$(grep "SSH_DB_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "N/A")
    systemctl is-active --quiet ws-proxy 2>/dev/null && WS_STATUS="${GREEN}activo ✓${NC}" || WS_STATUS="${RED}inactivo${NC}"
    echo -e " ${WHITE}Puerto SSH:${NC}         ${CYAN}$SSH_PORT${NC}"
    echo -e " ${WHITE}Dropbear interno:${NC}   ${CYAN}$DB_PORT${NC}"
    echo -e " ${WHITE}WebSocket Proxy:${NC}    ${CYAN}$SSH_WS_PORT${NC} [${WS_STATUS}]"
    echo ""
    echo -e " ${WHITE}[1]${NC} Cambiar puerto SSH"
    echo -e " ${WHITE}[2]${NC} Instalar Dropbear + WebSocket Proxy"
    echo -e " ${WHITE}[3]${NC} Ver estado SSH"
    echo -e " ${WHITE}[4]${NC} Reiniciar SSH"
    echo -e " ${WHITE}[5]${NC} Reiniciar WebSocket Proxy"
    echo -e " ${WHITE}[6]${NC} Ver logs WebSocket Proxy"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "; read OPT
    case $OPT in
        1) change_ssh_port ;;
        2) install_ssh_ws ;;
        3) status_ssh ;;
        4) systemctl restart ssh; echo -e "${GREEN}[+] SSH reiniciado${NC}"; sleep 1; menu_ssh ;;
        5) systemctl restart ws-proxy; echo -e "${GREEN}[+] WS Proxy reiniciado${NC}"; sleep 1; menu_ssh ;;
        6) journalctl -u ws-proxy -n 30 --no-pager; press_enter; menu_ssh ;;
        0) return ;;
        *) menu_ssh ;;
    esac
}

change_ssh_port() {
    echo -ne " ${WHITE}Nuevo puerto SSH: ${NC}"; read NEW_PORT
    [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [[ $NEW_PORT -lt 1 ]] || [[ $NEW_PORT -gt 65535 ]] && \
        echo -e "${RED}[!] Puerto inválido${NC}" && press_enter && menu_ssh && return
    sed -i "s/^#*Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
    ufw allow "$NEW_PORT/tcp" 2>/dev/null
    systemctl restart ssh
    sed -i "s/^SSH_PORT=.*/SSH_PORT=$NEW_PORT/" $INSTALL_DIR/config.conf 2>/dev/null
    echo -e "${GREEN}[+] Puerto SSH cambiado a $NEW_PORT${NC}"
    press_enter; menu_ssh
}

install_ssh_ws() {
    echo ""
    echo -ne " ${WHITE}Puerto público WebSocket para clientes (ej. 80): ${NC}"; read WS_PORT
    [[ -z "$WS_PORT" ]] && WS_PORT=80
    echo -ne " ${WHITE}Puerto interno Dropbear (ej. 2222): ${NC}"; read DB_PORT
    [[ -z "$DB_PORT" ]] && DB_PORT=2222

    echo -e "${CYAN}[1/4] Instalando paquetes...${NC}"
    apt install dropbear python3 -y -q

    cat > /etc/default/dropbear << DBEOF
NO_START=0
DROPBEAR_PORT=$DB_PORT
DROPBEAR_EXTRA_ARGS="-w"
DBEOF
    systemctl enable dropbear
    systemctl restart dropbear
    ufw allow "$DB_PORT/tcp" 2>/dev/null

    echo -e "${CYAN}[2/4] Creando WebSocket Proxy...${NC}"
    cat > /usr/local/bin/ws-proxy.py << PYEOF
import socket, threading
LISTEN_PORT = $WS_PORT
SSH_HOST    = '127.0.0.1'
SSH_PORT    = $DB_PORT
BUFFER      = 65536

def pipe(src, dst):
    try:
        while True:
            data = src.recv(BUFFER)
            if not data: break
            dst.sendall(data)
    except: pass
    finally:
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except: pass
            try: s.close()
            except: pass

def handle(client):
    try:
        data = client.recv(BUFFER)
        if not data: client.close(); return
        if data[:3] in (b'GET', b'POS', b'HEA', b'CON'):
            client.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.connect((SSH_HOST, SSH_PORT))
        t1 = threading.Thread(target=pipe, args=(client, srv), daemon=True)
        t2 = threading.Thread(target=pipe, args=(srv, client), daemon=True)
        t1.start(); t2.start()
        t1.join(); t2.join()
    except: pass
    finally:
        try: client.close()
        except: pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', LISTEN_PORT))
server.listen(512)
print(f"[WS-Proxy] :{LISTEN_PORT} -> SSH :{SSH_PORT}", flush=True)
while True:
    try:
        c, _ = server.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()
    except: pass
PYEOF
    chmod +x /usr/local/bin/ws-proxy.py

    echo -e "${CYAN}[3/4] Creando servicio systemd...${NC}"
    cat > /etc/systemd/system/ws-proxy.service << SVCEOF
[Unit]
Description=WebSocket SSH Proxy (GTKVPN)
After=network.target dropbear.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable ws-proxy
    systemctl start ws-proxy
    ufw allow "$WS_PORT/tcp" 2>/dev/null

    mkdir -p $INSTALL_DIR
    grep -q "SSH_WS_PORT" $INSTALL_DIR/config.conf 2>/dev/null \
        && sed -i "s/^SSH_WS_PORT=.*/SSH_WS_PORT=$WS_PORT/" $INSTALL_DIR/config.conf \
        || echo "SSH_WS_PORT=$WS_PORT" >> $INSTALL_DIR/config.conf
    grep -q "SSH_DB_PORT" $INSTALL_DIR/config.conf 2>/dev/null \
        && sed -i "s/^SSH_DB_PORT=.*/SSH_DB_PORT=$DB_PORT/" $INSTALL_DIR/config.conf \
        || echo "SSH_DB_PORT=$DB_PORT" >> $INSTALL_DIR/config.conf

    echo -e "${CYAN}[4/4] Verificando...${NC}"
    systemctl is-active --quiet dropbear && echo -e " ${GREEN}✓ Dropbear activo en puerto $DB_PORT${NC}" || echo -e " ${RED}✗ Error Dropbear${NC}"
    systemctl is-active --quiet ws-proxy  && echo -e " ${GREEN}✓ WS Proxy activo en puerto $WS_PORT${NC}"  || echo -e " ${RED}✗ Error WS Proxy${NC}"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE} 📱 HTTP Custom: IP:$WS_PORT | Payload: GET / HTTP/1.1[crlf]Host: DOMINIO[crlf]x-auth-key: app[crlf]Connection: Upgrade[crlf]Upgrade: Websocket[crlf][crlf]${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    press_enter; menu_ssh
}

status_ssh() {
    echo ""
    echo -e "${CYAN}[ SSH ]${NC}";      systemctl status ssh --no-pager 2>/dev/null
    echo -e "${CYAN}[ DROPBEAR ]${NC}"; systemctl status dropbear --no-pager 2>/dev/null
    echo -e "${CYAN}[ WS-PROXY ]${NC}"; systemctl status ws-proxy --no-pager 2>/dev/null
    press_enter; menu_ssh
}

menu_ssh
