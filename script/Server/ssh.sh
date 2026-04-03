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
import socket, threading, hashlib, base64, re, select

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = $WS_PORT
SSH_HOST    = "127.0.0.1"
SSH_PORT    = 2222
BUFFER      = 32768
MAX_TUNNELS = 50

tunnel_sem = threading.Semaphore(MAX_TUNNELS)

def relay(src, dst):
    src.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    dst.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    src.settimeout(300)
    dst.settimeout(300)
    try:
        while True:
            r, _, _ = select.select([src, dst], [], [], 300)
            if not r:
                break
            for s in r:
                try:
                    data = s.recv(BUFFER)
                    if not data:
                        return
                    other = dst if s is src else src
                    other.sendall(data)
                except:
                    return
    except:
        pass
    finally:
        try: src.close()
        except: pass
        try: dst.close()
        except: pass

def open_tunnel(client, addr):
    if not tunnel_sem.acquire(blocking=False):
        client.close()
        return
    try:
        ssh = socket.create_connection((SSH_HOST, SSH_PORT), timeout=10)
        t = threading.Thread(target=relay, args=(client, ssh), daemon=True)
        t.start()
        t.join()
    except Exception as e:
        print(f"[{addr}] tunnel: {e}", flush=True)
    finally:
        tunnel_sem.release()
        try: client.close()
        except: pass

def handle(client, addr):
    try:
        client.settimeout(5)
        data = b""
        try:
            data = client.recv(BUFFER)
        except:
            client.close()
            return
        client.settimeout(None)
        if not data:
            client.close()
            return
        first_line = data.split(b"\r\n")[0].decode(errors="ignore")
        if first_line.startswith("PUT "):
            client.sendall(b"HTTP/1.1 530 \r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            try:
                client.settimeout(3)
                client.recv(BUFFER)
            except: pass
            client.settimeout(None)
            client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            open_tunnel(client, addr)
            return
        get_idx = data.rfind(b"GET ")
        if get_idx >= 0 and b"websocket" in data[get_idx:].lower() and b"Upgrade" in data[get_idx:]:
            km = re.search(rb"Sec-WebSocket-Key:\s*([^\r\n]+)", data[get_idx:])
            if km:
                key = km.group(1).strip()
                accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest()).decode()
                resp = "HTTP/1.1 101 Web Socket Protocol\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"
            else:
                resp = "HTTP/1.1 101 Web Socket Protocol\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            client.sendall(resp.encode())
            open_tunnel(client, addr)
            return
        if first_line.startswith("HTTP/2.0 200") or first_line.startswith("HTTP/1.1 200"):
            client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n")
            open_tunnel(client, addr)
            return
        if first_line.startswith("CONNECT "):
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            open_tunnel(client, addr)
            return
        client.close()
    except Exception as e:
        print(f"[{addr}] {e}", flush=True)
        try: client.close()
        except: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    srv.bind((LISTEN_HOST, LISTEN_PORT))
    srv.listen(256)
    print(f"[ssh-ws] Proxy :{LISTEN_PORT} -> SSH {SSH_HOST}:{SSH_PORT} (max={MAX_TUNNELS})", flush=True)
    while True:
        try:
            c, a = srv.accept()
            threading.Thread(target=handle, args=(c, a), daemon=True).start()
        except Exception as e:
            print(f"[accept] {e}", flush=True)

if __name__ == "__main__":
    main()
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
