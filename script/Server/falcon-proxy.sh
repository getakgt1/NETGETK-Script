#!/bin/bash
# ============================================================
#   NETGETK — Módulo Falcon Proxy (WebSocket/Socks)
#   Replica la funcionalidad de FirewallFalcon Protocol Manager
#   Instalar en: /etc/gtkvpn/Server/falcon-proxy.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
PROXY_CONFIG="/etc/gtkvpn/falcon-proxy.conf"
PROXY_BIN="/usr/local/bin/pdirect.py"
PROXY_SERVICE="/etc/systemd/system/falcon-proxy.service"

press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

# ── Leer config guardada ──────────────────────────────────────
load_config() {
    PROXY_PORTS=""
    PROXY_MODE="pdirect"
    if [[ -f "$PROXY_CONFIG" ]]; then
        source "$PROXY_CONFIG"
    fi
}

# ── Guardar config ────────────────────────────────────────────
save_config() {
    mkdir -p "$(dirname $PROXY_CONFIG)"
    cat > "$PROXY_CONFIG" << EOF
PROXY_PORTS="$PROXY_PORTS"
PROXY_MODE="$PROXY_MODE"
EOF
}

# ── Estado del servicio con color ─────────────────────────────
svc_status() {
    if systemctl is-active --quiet falcon-proxy 2>/dev/null; then
        echo -e "${GREEN}● ACTIVO${NC}"
    else
        echo -e "${RED}○ INACTIVO${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════
#   MENÚ PRINCIPAL
# ═══════════════════════════════════════════════════════════════
menu_falcon_proxy() {
    load_config
    clear
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}           🦅 FALCON PROXY  (WebSocket / Socks)${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Panel de estado
    local STATUS=$(svc_status)
    local PORTS_DISPLAY="${PROXY_PORTS:-${RED}No configurado${NC}}"
    echo -e " ${WHITE}Estado  :${NC} $STATUS"
    echo -e " ${WHITE}Puertos :${NC} ${CYAN}${PROXY_PORTS:-N/A}${NC}"
    echo -e " ${WHITE}Modo    :${NC} ${CYAN}${PROXY_MODE}${NC}"
    echo ""
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${NC}"
    echo ""

    # Opciones — mismo estilo que FirewallFalcon
    echo -e " ${WHITE}[1]${NC}  🔧 Instalar / Configurar Puertos"
    echo -e " ${WHITE}[2]${NC}  ▶  Iniciar Servicio"
    echo -e " ${WHITE}[3]${NC}  ■  Detener Servicio"
    echo -e " ${WHITE}[4]${NC}  ↺  Reiniciar Servicio"
    echo -e " ${WHITE}[5]${NC}  📊 Ver Estado Detallado"
    echo -e " ${WHITE}[6]${NC}  📋 Ver Logs en Tiempo Real"
    echo -e " ${WHITE}[7]${NC}  ⚙  Cambiar Modo (pdirect / falcontunnel / falconproxy)"
    echo -e " ${WHITE}[8]${NC}  🗑  Desinstalar Falcon Proxy"
    echo ""
    echo -e " ${WHITE}[0]${NC}  ${RED}[ REGRESAR ]${NC}"
    echo ""
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT

    case $OPT in
        1) install_falcon_proxy ;;
        2) start_proxy ;;
        3) stop_proxy ;;
        4) restart_proxy ;;
        5) status_proxy ;;
        6) logs_proxy ;;
        7) change_mode ;;
        8) uninstall_proxy ;;
        0) return ;;
        *) menu_falcon_proxy ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#   [1] INSTALAR / CONFIGURAR PUERTOS
# ═══════════════════════════════════════════════════════════════
install_falcon_proxy() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}     🦅 Instalando Falcon Proxy (WebSocket/Socks)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    load_config

    # Verificar si ya está instalado
    if systemctl is-active --quiet falcon-proxy 2>/dev/null; then
        echo -e " ${GREEN}🦅 Falcon Proxy ya está instalado.${NC}"
        echo -e "    Está configurado para correr en puerto(s): ${CYAN}$PROXY_PORTS${NC}"
        echo -e "    Modo actual: ${CYAN}$PROXY_MODE${NC}"
        echo ""
        echo -ne " ${YELLOW}👉 ¿Deseas reinstalar/actualizar? (s/n): ${NC}"
        read RESP
        [[ "$RESP" != "s" && "$RESP" != "S" ]] && menu_falcon_proxy && return
    fi

    echo -e " ${WHITE}Elige el modo del proxy:${NC}"
    echo -e "   ${CYAN}[1]${NC} pdirect    — Proxy Python (WebSocket SSH, incluido en NETGETK)"
    echo -e "   ${CYAN}[2]${NC} falcontunnel — Proxy Rust de FirewallFalcon (descarga binario)"
    echo -e "   ${CYAN}[3]${NC} falconproxy  — Falcon Proxy v1.2-RustFast (local)"
    echo ""
    echo -ne " ${WHITE}► Modo (Enter = pdirect): ${NC}"
    read MODE_OPT
    
    case $MODE_OPT in
        2) PROXY_MODE="falcontunnel" ;;
        3) PROXY_MODE="falconproxy" ;;
        *) PROXY_MODE="pdirect" ;;
    esac

    echo ""
    echo -e " ${WHITE}Puerto(s) para Falcon Proxy${NC}"
    echo -e " ${CYAN}Puedes poner uno o varios separados por espacio${NC}"
    echo -e " ${CYAN}Ejemplos: 80    ó    80 8080 3128${NC}"
    echo ""
    echo -ne " ${WHITE}► Puerto(s) (Enter = 80): ${NC}"
    read INPUT_PORTS
    [[ -z "$INPUT_PORTS" ]] && INPUT_PORTS="80"

    PROXY_PORTS="$INPUT_PORTS"

    echo ""

    # ── Instalar dependencias ────────────────────────────────
    echo -e "${CYAN}[1/4] Verificando dependencias...${NC}"
    apt-get install -y python3 dropbear libcap2-bin -qq 2>/dev/null
    echo -e "  ${GREEN}✓ Python3, Dropbear, libcap2-bin${NC}"

    # ── Instalar el binario/proxy según modo ─────────────────
    case "$PROXY_MODE" in
        falcontunnel) _install_falcontunnel_binary ;;
        falconproxy)  _install_falconproxy ;;
        *)            _install_pdirect ;;
    esac

    # ── Crear servicio systemd ────────────────────────────────
    echo -e "${CYAN}[3/4] Configurando servicio systemd...${NC}"
    _create_systemd_service

    # ── Abrir puertos en UFW ──────────────────────────────────
    echo -e "${CYAN}[4/4] Abriendo puertos en firewall...${NC}"
    for PORT in $PROXY_PORTS; do
        ufw allow "$PORT/tcp" comment "Falcon Proxy" 2>/dev/null
        echo -e "  ${GREEN}✓ Puerto $PORT abierto${NC}"
    done

    # ── Guardar config ────────────────────────────────────────
    save_config

    # ── Iniciar servicio ──────────────────────────────────────
    systemctl daemon-reload
    systemctl enable falcon-proxy 2>/dev/null
    systemctl restart falcon-proxy
    sleep 2

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if systemctl is-active --quiet falcon-proxy; then
        echo -e " ${GREEN}🦅 Falcon Proxy activo en puerto(s): $PROXY_PORTS${NC}"
        echo -e " ${GREEN}   Modo: $PROXY_MODE${NC}"
    else
        echo -e " ${RED}[!] Error al iniciar. Ver logs: journalctl -u falcon-proxy -n 30${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    press_enter
    menu_falcon_proxy
}

# ── Instalar pdirect.py (modo Python) ─────────────────────────
_install_pdirect() {
    echo -e "${CYAN}[2/4] Instalando pdirect.py (modo Python)...${NC}"

    cat > /usr/local/bin/pdirect.py << 'PDEOF'
#!/usr/bin/python3
# pdirect.py — Falcon Proxy: SSH WebSocket compatible con HTTP Custom / NapsternetV
import socket, threading, sys, select, time, traceback, binascii, os

REMOTE_ADDR = "127.0.0.1"
BUFFER_SIZE = 65536
HTTP_METHODS = [b"GET ", b"POST ", b"PUT ", b"CONNECT ", b"HTTP", b"OPTI", b"HEAD"]

DEBUG_LOG = "/var/log/falcon-proxy-debug.log"
DEBUG_FLAG = "/etc/gtkvpn/falcon-proxy-debug"

def dbg(msg):
    if not os.path.exists(DEBUG_FLAG):
        return
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except:
        pass

def hexpreview(b, n=120):
    return binascii.hexlify(b[:n]).decode()

def get_ssh_port():
    # Preferir siempre dropbear en 2222 (el backend que instala este mismo
    # script) — un SSH_PORT viejo/incorrecto en config.conf no debe pisar
    # esto, ya que dropbear en 2222 es justo lo que falcon-proxy necesita.
    try:
        s = socket.create_connection(("127.0.0.1", 2222), timeout=1)
        s.close()
        return 2222
    except:
        pass
    try:
        with open("/etc/gtkvpn/config.conf") as f:
            for line in f:
                if line.startswith("SSH_PORT="):
                    return int(line.strip().split("=")[1])
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
            if not chunk: break
            data += chunk
            if b"\r\n\r\n" in data or b"\n\n" in data: break
            if len(data) >= 4 and not is_http(data): break
    except: pass
    sock.settimeout(None)
    return data

def handler(client_socket, address):
    remote = None
    try:
        data = read_payload(client_socket)
        dbg(f"--- new conn {address} | initial data ({len(data)}b): {hexpreview(data, 400)}")
        if not data:
            dbg(f"{address} | sin datos iniciales, cerrando")
            client_socket.close(); return
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.connect((REMOTE_ADDR, REMOTE_PORT))
        remote.settimeout(300)
        client_socket.settimeout(300)
        if is_http(data):
            remote.settimeout(5)
            try:
                banner = remote.recv(BUFFER_SIZE)
            except Exception as ex:
                dbg(f"{address} | error leyendo banner remoto: {ex}")
                banner = b""
            remote.settimeout(300)
            dbg(f"{address} | banner remoto ({len(banner)}b): {hexpreview(banner)}")
            client_socket.sendall(
                b"HTTP/1.1 101 Web Socket Protocol Handshake\r\n"
                b"Upgrade: WebSocket\r\n"
                b"Connection: Upgrade\r\n\r\n"
            )
            if banner:
                client_socket.sendall(banner)
            # Cualquier byte que haya llegado pegado despues del \r\n\r\n
            # (el arranque real del handshake SSH del cliente) NO debe
            # descartarse: hay que reenviarlo al backend. Ademas, algunos
            # payloads no traen \r\n\r\n en absoluto pero SI llevan pegada
            # la linea de identificacion SSH ("SSH-2.0-...") del cliente
            # en el mismo bloque inicial -> hay que detectarla tambien.
            leftover = b""
            sep_idx = data.find(b"\r\n\r\n")
            sep_len = 4
            if sep_idx == -1:
                sep_idx = data.find(b"\n\n")
                sep_len = 2
            if sep_idx != -1:
                leftover = data[sep_idx + sep_len:]
                dbg(f"{address} | leftover tras headers ({len(leftover)}b): {hexpreview(leftover)}")
            else:
                ssh_idx = data.find(b"SSH-")
                if ssh_idx != -1:
                    leftover = data[ssh_idx:]
                    dbg(f"{address} | identificacion SSH embebida en data, "
                        f"extrayendo desde offset {ssh_idx} ({len(leftover)}b): {hexpreview(leftover)}")
                else:
                    dbg(f"{address} | no se encontro separador ni identificacion SSH en data")
            if leftover:
                remote.sendall(leftover)
        else:
            dbg(f"{address} | data no-HTTP, reenviando directo a remoto")
            remote.sendall(data)
        sockets = [client_socket, remote]
        while True:
            r, _, e = select.select(sockets, [], sockets, 300)
            if e:
                dbg(f"{address} | select devolvio error-sockets, cerrando")
                break
            if not r:
                dbg(f"{address} | select timeout (300s) sin actividad")
                break
            for s in r:
                who = "client" if s is client_socket else "remote"
                try:
                    d = s.recv(BUFFER_SIZE)
                    if not d:
                        dbg(f"{address} | {who} cerro la conexion (recv vacio)")
                        return
                    dbg(f"{address} | {who}->{'remote' if who=='client' else 'client'} ({len(d)}b): {hexpreview(d)}")
                    (remote if s is client_socket else client_socket).sendall(d)
                except Exception as ex:
                    dbg(f"{address} | excepcion en relay ({who}): {ex}")
                    return
    except Exception as ex:
        dbg(f"{address} | EXCEPCION en handler: {ex}\n{traceback.format_exc()}")
    finally:
        try: client_socket.close()
        except: pass
        try:
            if remote: remote.close()
        except: pass

def main(ports):
    threads = []
    for port in ports:
        def listen(p=port):
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("0.0.0.0", int(p)))
            server.listen(256)
            print(f"[falcon-proxy] Puerto {p} → SSH {REMOTE_ADDR}:{REMOTE_PORT}", flush=True)
            while True:
                try:
                    c, a = server.accept()
                    threading.Thread(target=handler, args=(c, a), daemon=True).start()
                except Exception as ex:
                    print(f"[error] {ex}", flush=True)
        t = threading.Thread(target=listen, daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()

if __name__ == "__main__":
    ports = sys.argv[1:] if len(sys.argv) > 1 else [80]
    main(ports)
PDEOF

    chmod +x /usr/local/bin/pdirect.py

    # Configurar Dropbear como backend SSH en 2222
    apt-get install -y dropbear -qq 2>/dev/null
    sed -i 's/#DROPBEAR_PORT=22/DROPBEAR_PORT=2222/' /etc/default/dropbear 2>/dev/null
    sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=2222/' /etc/default/dropbear 2>/dev/null
    sed -i 's/^NO_START=1/NO_START=0/' /etc/default/dropbear 2>/dev/null
    [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]] && \
        dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null
    systemctl enable dropbear 2>/dev/null
    systemctl restart dropbear 2>/dev/null

    _install_dropbear_legacy

    echo -e "  ${GREEN}✓ pdirect.py instalado${NC}"
    echo -e "  ${GREEN}✓ Dropbear SSH activo en puerto 2222${NC}"
}

# ── Compilar dropbear legacy 2017.75 (compatibilidad con clientes SSH ──
# ── viejos tipo HTTP Custom/HTTP Injector, que fallan con las           ─
# ── extensiones anti-Terrapin de dropbear moderno) ──────────────────────
_install_dropbear_legacy() {
    if /usr/sbin/dropbear -h 2>&1 | head -1 | grep -q "2017.75"; then
        echo -e "  ${GREEN}✓ dropbear legacy 2017.75 ya estaba instalado${NC}"
        return
    fi
    echo -e "  ${CYAN}→ Compilando dropbear 2017.75 (compat. clientes SSH legacy)...${NC}"
    apt-get install -y build-essential libz-dev wget -qq 2>/dev/null

    local BUILD_DIR="/usr/src/dropbear-2017.75"
    if [[ ! -f "$BUILD_DIR/dropbear" ]]; then
        mkdir -p /usr/src && cd /usr/src
        if [[ ! -d "$BUILD_DIR" ]]; then
            wget -q https://matt.ucc.asn.au/dropbear/releases/dropbear-2017.75.tar.bz2 \
                -O dropbear-2017.75.tar.bz2 2>/dev/null
            if [[ ! -s dropbear-2017.75.tar.bz2 ]]; then
                echo -e "  ${YELLOW}⚠ No se pudo descargar dropbear 2017.75. Se mantiene la version del sistema.${NC}"
                return
            fi
            tar xjf dropbear-2017.75.tar.bz2
        fi
        cd "$BUILD_DIR"
        ./configure >/dev/null 2>&1
        make PROGRAMS="dropbear dbclient dropbearkey dropbearconvert" -j"$(nproc)" >/dev/null 2>&1
    fi

    if [[ -f "$BUILD_DIR/dropbear" ]]; then
        systemctl stop dropbear 2>/dev/null
        cp "$BUILD_DIR/dropbear" /usr/sbin/dropbear
        systemctl start dropbear 2>/dev/null
        echo -e "  ${GREEN}✓ dropbear reemplazado por build legacy 2017.75${NC}"
    else
        echo -e "  ${YELLOW}⚠ No se pudo compilar dropbear legacy. Se mantiene la version del sistema${NC}"
        echo -e "  ${YELLOW}  (clientes SSH viejos podrian fallar con 'Cannot read full block, EOF').${NC}"
    fi
}

# ── Instalar Falcon Proxy v1.2-RustFast (binario local del repo) ─
_install_falconproxy() {
    echo -e "${CYAN}[2/4] Instalando falconproxy (v1.2-RustFast)...${NC}"

    # El binario viaja junto a este script dentro del repo (script/Server/falconproxy)
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local LOCAL_SRC="$SCRIPT_DIR/falconproxy"

    if [[ -f /usr/local/bin/falconproxy ]]; then
        echo -e "  ${GREEN}✓ falconproxy ya estaba instalado en /usr/local/bin${NC}"
    elif [[ -f "$LOCAL_SRC" ]]; then
        cp "$LOCAL_SRC" /usr/local/bin/falconproxy
        chmod +x /usr/local/bin/falconproxy
        setcap 'cap_net_bind_service=+ep' /usr/local/bin/falconproxy 2>/dev/null
        echo -e "  ${GREEN}✓ falconproxy copiado a /usr/local/bin${NC}"
    else
        echo -e "  ${YELLOW}⚠ No se encontró el binario falconproxy junto al script ($LOCAL_SRC).${NC}"
        echo -e "  ${YELLOW}  Usando pdirect.py como fallback.${NC}"
        PROXY_MODE="pdirect"
        _install_pdirect
        return
    fi
}

# ── Instalar binario FalconTunnel de FirewallFalcon (modo Rust) ─
_install_falcontunnel_binary() {
    echo -e "${CYAN}[2/4] Descargando binario FalconTunnel...${NC}"

    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
        BINARY_NAME="FalconTunnel"
    else
        BINARY_NAME="FalconTunnelArm"
    fi

    # Primero verificar si ya existe falconproxy local (v1.2-RustFast)
    if [[ -f /usr/local/bin/falconproxy ]]; then
        echo -e "  ${GREEN}✓ Usando falconproxy local (v1.2-RustFast)${NC}"
        PROXY_MODE="falconproxy"
        return
    fi
    RELEASE_URL="https://github.com/firewallfalcons/FalconTunnel/releases/download/v1.0.0/$BINARY_NAME"

    if curl -L --max-time 30 -o /tmp/falcontunnel_core "$RELEASE_URL" 2>/dev/null && \
       [[ -s /tmp/falcontunnel_core ]]; then
        mv /tmp/falcontunnel_core /usr/local/bin/falcontunnel_core
        chmod +x /usr/local/bin/falcontunnel_core
        # Permitir puertos bajos sin root
        setcap 'cap_net_bind_service=+ep' /usr/local/bin/falcontunnel_core 2>/dev/null
        echo -e "  ${GREEN}✓ FalconTunnel binario instalado ($ARCH)${NC}"
        PROXY_MODE="falcontunnel"
    else
        echo -e "  ${YELLOW}⚠ No se pudo descargar FalconTunnel. Usando pdirect.py como fallback.${NC}"
        PROXY_MODE="pdirect"
        _install_pdirect
        return
    fi
}

# ── Crear servicio systemd según el modo ──────────────────────
_create_systemd_service() {
    # Construir el ExecStart según modo
    if [[ "$PROXY_MODE" == "falconproxy" ]]; then
        EXEC_BIN="/usr/local/bin/falconproxy"
        EXEC_CMD="$EXEC_BIN -p $PROXY_PORTS"
        RUN_USER="root"
    elif [[ "$PROXY_MODE" == "falcontunnel" ]]; then
        EXEC_BIN="/usr/local/bin/falcontunnel_core"
        EXEC_CMD="$EXEC_BIN $PROXY_PORTS"
        RUN_USER="nobody"
    else
        EXEC_BIN="/usr/bin/python3"
        EXEC_CMD="$EXEC_BIN /usr/local/bin/pdirect.py $PROXY_PORTS"
        RUN_USER="root"
    fi

    cat > "$PROXY_SERVICE" << SVC
[Unit]
Description=Falcon Proxy — WebSocket/Socks (NETGETK)
After=network.target

[Service]
Type=simple
User=$RUN_USER
ExecStart=$EXEC_CMD
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

    echo -e "  ${GREEN}✓ Servicio systemd creado${NC}"
}

# ═══════════════════════════════════════════════════════════════
#   [2] INICIAR
# ═══════════════════════════════════════════════════════════════
start_proxy() {
    echo ""
    systemctl start falcon-proxy 2>/dev/null
    sleep 1
    if systemctl is-active --quiet falcon-proxy; then
        echo -e " ${GREEN}[+] Falcon Proxy iniciado${NC}"
    else
        echo -e " ${RED}[!] Error al iniciar. Verifica con: journalctl -u falcon-proxy -n 20${NC}"
    fi
    press_enter; menu_falcon_proxy
}

# ═══════════════════════════════════════════════════════════════
#   [3] DETENER
# ═══════════════════════════════════════════════════════════════
stop_proxy() {
    echo ""
    systemctl stop falcon-proxy 2>/dev/null
    echo -e " ${YELLOW}[-] Falcon Proxy detenido${NC}"
    press_enter; menu_falcon_proxy
}

# ═══════════════════════════════════════════════════════════════
#   [4] REINICIAR
# ═══════════════════════════════════════════════════════════════
restart_proxy() {
    echo ""
    systemctl restart falcon-proxy 2>/dev/null
    sleep 1
    if systemctl is-active --quiet falcon-proxy; then
        echo -e " ${GREEN}[+] Falcon Proxy reiniciado correctamente${NC}"
    else
        echo -e " ${RED}[!] Error al reiniciar${NC}"
    fi
    press_enter; menu_falcon_proxy
}

# ═══════════════════════════════════════════════════════════════
#   [5] ESTADO DETALLADO
# ═══════════════════════════════════════════════════════════════
status_proxy() {
    echo ""
    echo -e "${CYAN}[ ESTADO FALCON PROXY ]${NC}"
    systemctl status falcon-proxy --no-pager 2>/dev/null
    echo ""
    echo -e "${CYAN}[ PUERTOS ACTIVOS ]${NC}"
    load_config
    for PORT in $PROXY_PORTS; do
        ss -tlnp | grep ":$PORT " && echo -e "  ${GREEN}✓ Puerto $PORT escuchando${NC}" || \
            echo -e "  ${RED}✗ Puerto $PORT NO activo${NC}"
    done
    press_enter; menu_falcon_proxy
}

# ═══════════════════════════════════════════════════════════════
#   [6] LOGS
# ═══════════════════════════════════════════════════════════════
logs_proxy() {
    echo ""
    echo -e "${YELLOW}[Ctrl+C para salir de los logs]${NC}"
    sleep 1
    journalctl -u falcon-proxy -f --no-pager
    menu_falcon_proxy
}

# ═══════════════════════════════════════════════════════════════
#   [7] CAMBIAR MODO
# ═══════════════════════════════════════════════════════════════
change_mode() {
    load_config
    echo ""
    echo -e " ${WHITE}Modo actual:${NC} ${CYAN}$PROXY_MODE${NC}"
    echo ""
    echo -e " ${WHITE}[1]${NC} pdirect (Python — incluido en NETGETK)"
    echo -e " ${WHITE}[2]${NC} falcontunnel (Rust — binario de FirewallFalcon)"
    echo -e " ${WHITE}[3]${NC} falconproxy  (v1.2-RustFast — binario local)"
    echo ""
    echo -ne " ${WHITE}► Nuevo modo: ${NC}"
    read MODE_OPT

    case $MODE_OPT in
        1) PROXY_MODE="pdirect" ;;
        2) PROXY_MODE="falcontunnel" ;;
        3) PROXY_MODE="falconproxy" ;;
        *) echo -e "${RED}[!] Opción inválida${NC}"; press_enter; menu_falcon_proxy; return ;;
    esac

    echo ""
    echo -e " ${CYAN}[*] Reinstalando con modo: $PROXY_MODE...${NC}"

    case "$PROXY_MODE" in
        falcontunnel) _install_falcontunnel_binary ;;
        falconproxy)  _install_falconproxy ;;
        *)            _install_pdirect ;;
    esac

    _create_systemd_service
    save_config
    systemctl daemon-reload
    systemctl restart falcon-proxy
    sleep 1

    if systemctl is-active --quiet falcon-proxy; then
        echo -e " ${GREEN}[+] Modo cambiado a $PROXY_MODE correctamente${NC}"
    else
        echo -e " ${RED}[!] Error al reiniciar con nuevo modo${NC}"
    fi

    press_enter; menu_falcon_proxy
}

# ═══════════════════════════════════════════════════════════════
#   [8] DESINSTALAR
# ═══════════════════════════════════════════════════════════════
uninstall_proxy() {
    echo ""
    echo -ne " ${RED}[!] ¿Seguro que deseas desinstalar Falcon Proxy? (si/no): ${NC}"
    read CONF
    if [[ "$CONF" == "si" ]]; then
        systemctl stop falcon-proxy 2>/dev/null
        systemctl disable falcon-proxy 2>/dev/null
        rm -f "$PROXY_SERVICE"
        rm -f /usr/local/bin/pdirect.py
        rm -f /usr/local/bin/falcontunnel_core
        rm -f "$PROXY_CONFIG"
        systemctl daemon-reload
        echo -e " ${GREEN}[+] Falcon Proxy desinstalado completamente${NC}"
    else
        echo -e " ${YELLOW}[-] Cancelado${NC}"
    fi
    press_enter; menu_falcon_proxy
}

# ── Entry point ───────────────────────────────────────────────
menu_falcon_proxy
