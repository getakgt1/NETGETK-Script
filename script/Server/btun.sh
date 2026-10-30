#!/bin/bash
# ============================================================
#   GTKVPN - BTUN (TCP+UDP 7900, interfaz tun btun0, subred 10.77.0.0/16)
#
#   Menú interactivo : btun.sh         (también: menu -> [5] Instalador de protocolos -> [17] BTUN)
#   Línea de comandos: btun.sh install|uninstall|status|restart|logs|adduser <usuario> <clave>
#                      [BTUN_PORT=7900 BTUN_SUBNET=10.77.0.0/16 BTUN_BIN=/ruta/btun-server]
#
#   El binario btun-server es de terceros y NO viaja en este repo:
#   colócalo en /usr/local/bin/btun-server o pasa BTUN_BIN=/ruta
#   Solo toca su propia subred (NAT) y su propio puerto.
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

DEST="/usr/local/bin/btun-server"; AUTH="/etc/btun/users"
UNIT="/etc/systemd/system/btun.service"
[[ $EUID -ne 0 ]] && { echo -e "${RED}Requiere root${NC}"; exit 1; }

press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read -r; }

# Valores actuales: los de la unidad instalada; si no existe, los del entorno o los de por defecto.
unit_port()   { grep -oE -- '-tcp-listen [0-9.]+:[0-9]+' "$UNIT" 2>/dev/null | head -1 | grep -oE '[0-9]+$'; }
unit_subnet() { grep -oE -- '-subnet [^ ]+' "$UNIT" 2>/dev/null | head -1 | awk '{print $2}'; }
load_cfg() {
    PORT="${BTUN_PORT:-$(unit_port)}";        PORT="${PORT:-7900}"
    SUBNET="${BTUN_SUBNET:-$(unit_subnet)}";  SUBNET="${SUBNET:-10.77.0.0/16}"
    SRC="${BTUN_BIN:-$DEST}"
}
load_cfg

is_installed() { [[ -f "$UNIT" ]]; }
is_active()    { systemctl is-active --quiet btun 2>/dev/null; }
valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
# usuario/clave: solo caracteres seguros (la clave viaja en un archivo "usuario:clave" y el usuario en un sed)
valid_cred()   { [[ "$1" =~ ^[A-Za-z0-9._@+-]{1,32}$ ]]; }
port_busy()    { ss -ltnup 2>/dev/null | grep -E ":$1\b" | grep -vq "btun-server"; }
sessions_now() { ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | wc -l; }

fw_open()  { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && { ufw allow "$1/tcp" >/dev/null 2>&1; ufw allow "$1/udp" >/dev/null 2>&1; }; }
fw_close() { command -v ufw >/dev/null && { ufw delete allow "$1/tcp" >/dev/null 2>&1; ufw delete allow "$1/udp" >/dev/null 2>&1; }; }

do_install() {
    local old; old="$(unit_port)"
    [[ -f "$SRC" ]] || { echo -e "${RED}Falta el binario btun-server ($SRC)${NC}"; return 1; }
    [[ "$SRC" == "$DEST" ]] || install -m 755 "$SRC" "$DEST"
    mkdir -p /etc/btun /var/lib/btun
    if [[ ! -f "$AUTH" ]]; then
        P=$(openssl rand -base64 18 | tr -dc a-zA-Z0-9 | head -c 12)
        echo "gtkbtun:$P" > "$AUTH"; chmod 600 "$AUTH"; echo -e "${WHITE}Usuario gtkbtun / clave $P${NC}  ${YELLOW}(guárdala: no se vuelve a mostrar)${NC}"
    fi
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=BTUN VPN TCP/UDP ($PORT)
After=network.target
[Service]
Type=simple
User=root
ExecStart=$DEST -auth file -auth-file $AUTH -tcp-listen 0.0.0.0:$PORT -udp-listen 0.0.0.0:$PORT -subnet $SUBNET -tun btun0 -stats-file /var/lib/btun/stats.json -handshake-timeout 15s -idle-timeout 2m
Restart=always
RestartSec=3
LimitNOFILE=65535
MemoryMax=768M
[Install]
WantedBy=multi-user.target
UNITEOF
    cat > /etc/systemd/system/btun-nat.service <<UNITEOF
[Unit]
Description=NAT para la subred de BTUN
After=network-online.target btun.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "iptables -t nat -C POSTROUTING -s $SUBNET -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $SUBNET -j MASQUERADE"
ExecStop=/bin/sh -c "iptables -t nat -D POSTROUTING -s $SUBNET -j MASQUERADE 2>/dev/null || true"
[Install]
WantedBy=multi-user.target
UNITEOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    [[ -n "$old" && "$old" != "$PORT" ]] && fw_close "$old"
    fw_open "$PORT"
    systemctl daemon-reload; systemctl enable btun btun-nat >/dev/null 2>&1; systemctl restart btun btun-nat
    sleep 2
    if is_active; then
        echo -e "${GREEN}BTUN escuchando en $PORT (TCP+UDP, subred $SUBNET)${NC}"
    else
        echo -e "${RED}El servicio no arrancó. Revisa: journalctl -u btun -n 30${NC}"; return 1
    fi
}

do_adduser() {
    local u="$1" p="$2"
    valid_cred "$u" && valid_cred "$p" || { echo -e "${RED}Usuario/clave no válidos (letras, números y . _ @ + -, máx. 32)${NC}"; return 1; }
    mkdir -p /etc/btun
    sed -i "/^${u}:/d" "$AUTH" 2>/dev/null; echo "$u:$p" >> "$AUTH"; chmod 600 "$AUTH"
    systemctl restart btun; echo -e "${GREEN}Usuario $u listo${NC}"
}

do_deluser() {
    local u="$1"
    valid_cred "$u" || { echo -e "${RED}Usuario no válido${NC}"; return 1; }
    grep -q "^${u}:" "$AUTH" 2>/dev/null || { echo -e "${YELLOW}No existe $u${NC}"; return 1; }
    [[ "$(wc -l < "$AUTH")" -le 1 ]] && { echo -e "${RED}No se puede borrar el único usuario${NC}"; return 1; }
    sed -i "/^${u}:/d" "$AUTH"; systemctl restart btun; echo -e "${GREEN}Usuario $u eliminado${NC}"
}

do_uninstall() {
    local p; p="$(unit_port)"; p="${p:-$PORT}"
    systemctl disable --now btun btun-nat 2>/dev/null
    rm -f /etc/systemd/system/btun.service /etc/systemd/system/btun-nat.service; systemctl daemon-reload
    fw_close "$p"
    echo -e "${GREEN}BTUN eliminado${NC} (el binario y /etc/btun se conservan)"
}

show_status() { systemctl is-active btun; ss -ltnup 2>/dev/null | grep -E "btun-server"; }
show_logs()   { journalctl -u btun -n 40 --no-pager 2>/dev/null; }

# ── Menú interactivo ──────────────────────────────────────────
menu_btun() {
    while true; do
        load_cfg
        clear
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${WHITE}                  🛰️  MÓDULO BTUN${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        if is_installed; then
            is_active && ST="${GREEN}activo ✓${NC}" || ST="${RED}inactivo${NC}"
            echo -e " ${WHITE}Estado:${NC}        $ST"
            echo -e " ${WHITE}Puerto:${NC}        ${CYAN}$PORT${NC} (TCP+UDP)"
            echo -e " ${WHITE}Subred:${NC}        ${CYAN}$SUBNET${NC}"
            echo -e " ${WHITE}Usuarios:${NC}      ${CYAN}$(grep -c . "$AUTH" 2>/dev/null || echo 0)${NC}"
            echo -e " ${WHITE}Conexiones TCP:${NC} ${CYAN}$(sessions_now)${NC} abiertas"
        else
            echo -e " ${WHITE}Estado:${NC}        ${YELLOW}no instalado${NC}"
        fi
        [[ -f "$DEST" ]] && echo -e " ${WHITE}Binario:${NC}       ${GREEN}$DEST${NC}" \
                         || echo -e " ${WHITE}Binario:${NC}       ${RED}falta${NC} ${YELLOW}(déjalo en $DEST)${NC}"
        echo ""
        echo -e " ${WHITE}[1]${NC} Instalar / reinstalar BTUN"
        echo -e " ${WHITE}[2]${NC} Cambiar puerto"
        echo -e " ${WHITE}[3]${NC} Crear / cambiar clave de un usuario"
        echo -e " ${WHITE}[4]${NC} Eliminar usuario"
        echo -e " ${WHITE}[5]${NC} Ver usuarios y estado"
        echo -e " ${WHITE}[6]${NC} Reiniciar BTUN"
        echo -e " ${WHITE}[7]${NC} Ver logs"
        echo -e " ${WHITE}[8]${NC} ${RED}Desinstalar BTUN${NC}"
        echo ""
        echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -ne " ${WHITE}► Opcion :${NC} "; read -r OPT
        case $OPT in
            1)
                if [[ ! -f "$SRC" ]]; then
                    echo -e "${YELLOW}El binario btun-server es de terceros y no viaja en el script.${NC}"
                    echo -ne " ${WHITE}Ruta del binario (Enter para cancelar): ${NC}"; read -r BIN
                    [[ -z "$BIN" ]] && continue
                    [[ -f "$BIN" ]] || { echo -e "${RED}No existe $BIN${NC}"; press_enter; continue; }
                    SRC="$BIN"; export BTUN_BIN="$BIN"
                fi
                echo -ne " ${WHITE}Puerto TCP+UDP [${PORT}]: ${NC}"; read -r P
                [[ -z "$P" ]] && P="$PORT"
                valid_port "$P" || { echo -e "${RED}Puerto no válido${NC}"; press_enter; continue; }
                port_busy "$P" && { echo -e "${RED}El puerto $P ya lo usa otro servicio${NC}"; press_enter; continue; }
                PORT="$P"; export BTUN_PORT="$P" BTUN_SUBNET="$SUBNET"
                do_install; press_enter ;;
            2)
                is_installed || { echo -e "${YELLOW}Instala BTUN primero${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Nuevo puerto TCP+UDP: ${NC}"; read -r P
                valid_port "$P" || { echo -e "${RED}Puerto no válido${NC}"; press_enter; continue; }
                port_busy "$P" && [[ "$P" != "$PORT" ]] && { echo -e "${RED}El puerto $P ya lo usa otro servicio${NC}"; press_enter; continue; }
                echo -e "${YELLOW}Se reiniciará el servicio: los clientes conectados se cortarán un momento.${NC}"
                export BTUN_PORT="$P" BTUN_SUBNET="$SUBNET"; PORT="$P"
                do_install; echo -e " ${WHITE}Recuerda cambiar el puerto en los clientes.${NC}"; press_enter ;;
            3)
                is_installed || { echo -e "${YELLOW}Instala BTUN primero${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Usuario: ${NC}"; read -r U
                echo -ne " ${WHITE}Clave:   ${NC}"; read -r PW
                do_adduser "$U" "$PW"; press_enter ;;
            4)
                is_installed || { echo -e "${YELLOW}Instala BTUN primero${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Usuario a eliminar: ${NC}"; read -r U
                do_deluser "$U"; press_enter ;;
            5)
                echo ""
                if is_installed; then
                    show_status
                    echo ""
                    echo -e " ${WHITE}Usuarios (solo nombres):${NC} $(cut -d: -f1 "$AUTH" 2>/dev/null | tr '\n' ' ')"
                    echo -e " ${WHITE}Interfaz btun0:${NC} $(ip -br addr show btun0 2>/dev/null | awk '{print $2, $3}' || echo 'sin interfaz')"
                    echo -e " ${WHITE}NAT:${NC} $(systemctl is-active btun-nat 2>/dev/null)"
                    echo ""
                    echo -e " ${WHITE}Conexiones TCP por IP de origen:${NC}"
                    ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | awk '{print $4}' \
                        | sed -E 's/:[0-9]+$//' | sort | uniq -c | sort -rn | head -10
                else
                    echo -e "${YELLOW}BTUN no está instalado${NC}"
                fi
                press_enter ;;
            6)
                is_installed || { echo -e "${YELLOW}BTUN no está instalado${NC}"; press_enter; continue; }
                systemctl restart btun; sleep 1
                is_active && echo -e "${GREEN}[+] BTUN reiniciado${NC}" || echo -e "${RED}[!] No arrancó${NC}"
                press_enter ;;
            7) echo ""; show_logs; press_enter ;;
            8)
                is_installed || { echo -e "${YELLOW}BTUN no está instalado${NC}"; press_enter; continue; }
                echo -ne "${RED}[!] ¿Desinstalar BTUN? (si/no): ${NC}"; read -r C
                [[ "$C" == "si" ]] && do_uninstall; press_enter ;;
            0) return 0 ;;
            *) ;;
        esac
    done
}

# ── Entrada ───────────────────────────────────────────────────
ACTION="${1:-}"
if [[ -z "$ACTION" ]]; then
    # sin argumentos: menú si hay terminal; en scripts/cron, el estado de siempre
    if [[ -t 0 && -t 1 ]]; then ACTION="menu"; else ACTION="status"; fi
fi
case "$ACTION" in
    menu)      menu_btun ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    show_status ;;
    restart)   systemctl restart btun && echo "BTUN reiniciado" ;;
    logs)      show_logs ;;
    adduser)   do_adduser "$2" "$3" ;;
    *) echo "Uso: $0 [menu|install|uninstall|status|restart|logs|adduser <usuario> <clave>]"; exit 1 ;;
esac
