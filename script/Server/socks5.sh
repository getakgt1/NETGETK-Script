#!/bin/bash
# ============================================================
#   GTKVPN - SOCKS5 Proxy (Python)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

menu_socks() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                🧦 MÓDULO SOCKS5${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    SOCKS_ST=$(systemctl is-active --quiet socks5-gtkvpn 2>/dev/null && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")
    SOCKS_PORT=$(grep "SOCKS_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "N/A")
    
    echo -e " ${WHITE}Estado:${NC} $SOCKS_ST"
    echo -e " ${WHITE}Puerto:${NC} ${CYAN}$SOCKS_PORT${NC}"
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar SOCKS5 (sin autenticación)"
    echo -e " ${WHITE}[2]${NC} Instalar SOCKS5 (con usuario/contraseña)"
    echo -e " ${WHITE}[3]${NC} Cambiar puerto"
    echo -e " ${WHITE}[4]${NC} Iniciar/Detener"
    echo -e " ${WHITE}[5]${NC} Ver conexiones activas"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT
    
    case $OPT in
        1) install_socks_open ;;
        2) install_socks_auth ;;
        3) change_socks_port ;;
        4) toggle_socks ;;
        5) show_socks_conns ;;
        0) return ;;
        *) menu_socks ;;
    esac
}

install_socks_open() {
    echo ""
    echo -ne " ${WHITE}Puerto SOCKS5 (ej. 8080): ${NC}"; read PORT
    [[ -z "$PORT" ]] && PORT=8080
    
    pip3 install PySocks 2>/dev/null
    
    # Crear servidor SOCKS5 Python sin auth
    cat > /usr/local/bin/socks5-server.py << 'PYEOF'
#!/usr/bin/env python3
"""SOCKS5 Server sin autenticación - GTKVPN"""
import socket
import select
import threading
import sys
import struct

HOST = '0.0.0.0'
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

def handle_client(client):
    try:
        # Handshake SOCKS5
        data = client.recv(262)
        if not data or data[0] != 5:
            return
        
        # Responder sin autenticación
        client.sendall(b'\x05\x00')
        
        # Leer solicitud
        data = client.recv(4)
        if not data or len(data) < 4:
            return
        
        cmd = data[1]
        addr_type = data[3]
        
        if addr_type == 1:  # IPv4
            addr = socket.inet_ntoa(client.recv(4))
        elif addr_type == 3:  # Dominio
            domain_len = client.recv(1)[0]
            addr = client.recv(domain_len).decode()
        elif addr_type == 4:  # IPv6
            addr = socket.inet_ntop(socket.AF_INET6, client.recv(16))
        else:
            return
        
        port = struct.unpack('!H', client.recv(2))[0]
        
        if cmd == 1:  # CONNECT
            try:
                remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                remote.connect((addr, port))
                bind_addr = remote.getsockname()
                reply = b'\x05\x00\x00\x01'
                reply += socket.inet_aton(bind_addr[0])
                reply += struct.pack('!H', bind_addr[1])
                client.sendall(reply)
                
                # Relay bidireccional
                def relay():
                    while True:
                        r, _, _ = select.select([client, remote], [], [], 60)
                        if not r:
                            break
                        for s in r:
                            data = s.recv(4096)
                            if not data:
                                return
                            other = remote if s is client else client
                            other.sendall(data)
                relay()
            except:
                pass
    except:
        pass
    finally:
        try: client.close()
        except: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(100)
    print(f"SOCKS5 escuchando en :{PORT}")
    while True:
        client, addr = server.accept()
        t = threading.Thread(target=handle_client, args=(client,))
        t.daemon = True
        t.start()

main()
PYEOF
    chmod +x /usr/local/bin/socks5-server.py
    
    create_socks_service "$PORT"
    
    # Guardar config
    sed -i '/^SOCKS_PORT=/d' $INSTALL_DIR/config.conf 2>/dev/null
    sed -i '/^SOCKS_ENABLED=/d' $INSTALL_DIR/config.conf 2>/dev/null
    echo "SOCKS_PORT=$PORT" >> $INSTALL_DIR/config.conf
    echo "SOCKS_ENABLED=true" >> $INSTALL_DIR/config.conf
    
    ufw allow "$PORT/tcp" 2>/dev/null
    systemctl enable socks5-gtkvpn 2>/dev/null
    systemctl restart socks5-gtkvpn
    
    if systemctl is-active --quiet socks5-gtkvpn; then
        echo -e "${GREEN}[+] SOCKS5 activo en puerto $PORT${NC}"
    else
        echo -e "${RED}[!] Error iniciando SOCKS5${NC}"
    fi
    press_enter
    menu_socks
}

install_socks_auth() {
    echo ""
    echo -ne " ${WHITE}Puerto SOCKS5 (ej. 8080): ${NC}"; read PORT
    [[ -z "$PORT" ]] && PORT=8080
    echo -ne " ${WHITE}Usuario: ${NC}"; read SOCKS_USER
    echo -ne " ${WHITE}Contraseña: ${NC}"; read -s SOCKS_PASS; echo
    
    # Guardar credenciales
    echo "$SOCKS_USER:$SOCKS_PASS" > /etc/gtkvpn/socks5_creds
    chmod 600 /etc/gtkvpn/socks5_creds
    
    # Script con autenticación
    cat > /usr/local/bin/socks5-server.py << PYEOF
#!/usr/bin/env python3
"""SOCKS5 Server con autenticación - GTKVPN"""
import socket, select, threading, sys, struct

HOST = '0.0.0.0'
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else $PORT
CREDS = {}

# Leer credenciales
try:
    with open('/etc/gtkvpn/socks5_creds') as f:
        for line in f:
            u, p = line.strip().split(':', 1)
            CREDS[u] = p
except: pass

def handle_client(client):
    try:
        data = client.recv(262)
        if not data or data[0] != 5: return
        
        # Métodos soportados
        client.sendall(b'\x05\x02')  # 0x02 = user/pass auth
        
        # Leer credenciales
        auth = client.recv(513)
        if not auth or auth[0] != 1: return
        ulen = auth[1]
        user = auth[2:2+ulen].decode()
        plen = auth[2+ulen]
        passwd = auth[3+ulen:3+ulen+plen].decode()
        
        if CREDS.get(user) != passwd:
            client.sendall(b'\x01\x01')  # Auth failed
            return
        client.sendall(b'\x01\x00')  # Auth OK
        
        data = client.recv(4)
        if not data: return
        addr_type = data[3]
        
        if addr_type == 1:
            addr = socket.inet_ntoa(client.recv(4))
        elif addr_type == 3:
            domain_len = client.recv(1)[0]
            addr = client.recv(domain_len).decode()
        else: return
        
        port = struct.unpack('!H', client.recv(2))[0]
        
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.connect((addr, port))
        bind = remote.getsockname()
        reply = b'\x05\x00\x00\x01' + socket.inet_aton(bind[0]) + struct.pack('!H', bind[1])
        client.sendall(reply)
        
        while True:
            r, _, _ = select.select([client, remote], [], [], 60)
            if not r: break
            for s in r:
                d = s.recv(4096)
                if not d: return
                (remote if s is client else client).sendall(d)
    except: pass
    finally:
        try: client.close()
        except: pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((HOST, PORT))
server.listen(100)
print(f"SOCKS5 (auth) escuchando en :{PORT}")
while True:
    c, a = server.accept()
    t = threading.Thread(target=handle_client, args=(c,), daemon=True)
    t.start()
PYEOF
    chmod +x /usr/local/bin/socks5-server.py
    create_socks_service "$PORT"
    
    sed -i '/^SOCKS_PORT=/d' $INSTALL_DIR/config.conf 2>/dev/null
    echo "SOCKS_PORT=$PORT" >> $INSTALL_DIR/config.conf
    echo "SOCKS_ENABLED=true" >> $INSTALL_DIR/config.conf
    
    ufw allow "$PORT/tcp" 2>/dev/null
    systemctl enable socks5-gtkvpn 2>/dev/null
    systemctl restart socks5-gtkvpn
    
    echo -e "${GREEN}[+] SOCKS5 con auth activo en puerto $PORT${NC}"
    press_enter; menu_socks
}

create_socks_service() {
    local PORT=$1
    cat > /etc/systemd/system/socks5-gtkvpn.service << SVC
[Unit]
Description=SOCKS5 Proxy - GTKVPN
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/socks5-server.py $PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
}

change_socks_port() {
    echo -ne " ${WHITE}Nuevo puerto: ${NC}"; read PORT
    sed -i "s|ExecStart=.*|ExecStart=/usr/bin/python3 /usr/local/bin/socks5-server.py $PORT|" \
        /etc/systemd/system/socks5-gtkvpn.service 2>/dev/null
    systemctl daemon-reload
    systemctl restart socks5-gtkvpn
    sed -i "s/^SOCKS_PORT=.*/SOCKS_PORT=$PORT/" $INSTALL_DIR/config.conf
    ufw allow "$PORT/tcp" 2>/dev/null
    echo -e "${GREEN}[+] Puerto cambiado a $PORT${NC}"
    press_enter; menu_socks
}

toggle_socks() {
    if systemctl is-active --quiet socks5-gtkvpn; then
        systemctl stop socks5-gtkvpn
        echo -e "${YELLOW}[-] SOCKS5 detenido${NC}"
    else
        systemctl start socks5-gtkvpn
        echo -e "${GREEN}[+] SOCKS5 iniciado${NC}"
    fi
    sleep 1; menu_socks
}

show_socks_conns() {
    SOCKS_PORT=$(grep "SOCKS_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "8080")
    echo ""
    echo -e "${CYAN}[ CONEXIONES SOCKS5 en :$SOCKS_PORT ]${NC}"
    ss -tnp | grep ":$SOCKS_PORT" | head -20
    echo ""
    echo -e "${WHITE}Total: ${GREEN}$(ss -tnp | grep ":$SOCKS_PORT" | wc -l)${NC}"
    press_enter; menu_socks
}

menu_socks
