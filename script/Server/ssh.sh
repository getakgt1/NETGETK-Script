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
    # Instalar pdirect.py — proxy HTTP+SSL para SSH
    cat > /usr/local/bin/pdirect.py << 'PDEOF'
#!/usr/bin/python3
import socket, threading, sys, select

REMOTE_ADDR = "127.0.0.1"
BUFFER_SIZE = 65536
HTTP_METHODS = [b"GET ", b"POST ", b"PUT ", b"CONNECT ", b"HTTP", b"OPTI", b"HEAD"]

def get_ssh_port():
    try:
        with open("/etc/gtkvpn/config.conf") as f:
            for line in f:
                if line.startswith("SSH_PORT="):
                    return int(line.strip().split("=")[1])
    except:
        pass
    for port in [2222, 22]:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1)
            s.close()
            return port
        except:
            pass
    return 22

REMOTE_PORT = get_ssh_port()

def is_http(data):
    return any(data.startswith(m) for m in HTTP_METHODS)

def read_payload(sock):
    data = b""
    sock.settimeout(5)
    try:
        while True:
            chunk = sock.recv(BUFFER_SIZE)
            if not chunk:
                break
            data += chunk
            if b"\r\n\r\n" in data or b"\n\n" in data:
                break
            if len(data) >= 4 and not is_http(data):
                break
    except:
        pass
    sock.settimeout(None)
    return data

def handler(client_socket, address):
    remote = None
    try:
        data = read_payload(client_socket)
        if not data:
            client_socket.close()
            return
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.connect((REMOTE_ADDR, REMOTE_PORT))
        remote.settimeout(300)
        client_socket.settimeout(300)
        if is_http(data):
            client_ssh_banner = None
            if b"SSH-2.0-" in data:
                idx = data.find(b"SSH-2.0-")
                client_ssh_banner = data[idx:]
                eol = client_ssh_banner.find(b"\n")
                if eol >= 0:
                    client_ssh_banner = client_ssh_banner[:eol+1]
            remote.settimeout(5)
            server_banner = b""
            try:
                server_banner = remote.recv(BUFFER_SIZE)
            except:
                pass
            remote.settimeout(300)
            client_socket.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            )
            if server_banner:
                client_socket.sendall(server_banner)
            if client_ssh_banner:
                remote.sendall(client_ssh_banner)
        else:
            remote.sendall(data)
        sockets = [client_socket, remote]
        while True:
            r, _, e = select.select(sockets, [], sockets, 300)
            if e or not r:
                break
            for s in r:
                try:
                    d = s.recv(BUFFER_SIZE)
                    if not d:
                        return
                    other = remote if s is client_socket else client_socket
                    other.sendall(d)
                except:
                    return
    except:
        pass
    finally:
        try: client_socket.close()
        except: pass
        try:
            if remote: remote.close()
        except: pass

def main(port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    server.bind(("0.0.0.0", int(port)))
    server.listen(256)
    print(f"[pdirect] :{port} -> SSH {REMOTE_ADDR}:{REMOTE_PORT}", flush=True)
    while True:
        try:
            c, a = server.accept()
            threading.Thread(target=handler, args=(c, a), daemon=True).start()
        except Exception as e:
            print(f"[error] {e}", flush=True)

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else 80)
PDEOF
    chmod +x /usr/local/bin/pdirect.py

    # Crear servicio systemd
    cat > /etc/systemd/system/ssh-ws.service << SVC
[Unit]
Description=SSH WebSocket Proxy - GTKVPN
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pdirect.py $WS_PORT
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
