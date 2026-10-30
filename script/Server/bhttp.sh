#!/bin/bash
# ============================================================
#   GTKVPN - BHTTP (servidor Python incluido: puerto 8445 -> dropbear 2222)
#
#   Menú interactivo : bhttp.sh            (también: menu -> [5] Instalador de protocolos -> [15] BHTTP)
#   Línea de comandos: bhttp.sh install|uninstall|status|restart|logs
#                      [BHTTP_PORT=8445 BHTTP_BACKEND_PORT=2222]
#
#   BHTTP es un transporte binario que lleva el SSH (dropbear/sshd) del servidor dentro de
#   peticiones tipo HTTP. El cliente (app) se conecta al PUERTO BHTTP e inicia sesión con el
#   usuario/clave SSH normales del servidor.
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

DIR="/usr/local/lib/bhttp"; UNIT="/etc/systemd/system/bhttp.service"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -ne 0 ]] && { echo -e "${RED}Requiere root${NC}"; exit 1; }

press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read -r; }

# Puertos actuales: los de la unidad instalada; si no existe, los del entorno o los de por defecto.
unit_val() { grep -oE -- "--$1 [0-9]+" "$UNIT" 2>/dev/null | head -1 | awk '{print $2}'; }
load_ports() {
    PORT="${BHTTP_PORT:-$(unit_val port)}";                 PORT="${PORT:-8445}"
    BPORT="${BHTTP_BACKEND_PORT:-$(unit_val backend-port)}"; BPORT="${BPORT:-2222}"
}
load_ports

is_installed() { [[ -f "$UNIT" ]]; }
is_active()    { systemctl is-active --quiet bhttp 2>/dev/null; }
valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
# ¿el puerto lo usa OTRO proceso que no sea nuestro servidor BHTTP?
port_busy()    { ss -ltnp 2>/dev/null | grep -E ":$1\b" | grep -vq "bhttp-server"; }
sessions_now() { ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | wc -l; }

fw_open()  { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$1/tcp" >/dev/null 2>&1; }
fw_close() { command -v ufw >/dev/null && ufw delete allow "$1/tcp" >/dev/null 2>&1; }

do_install() {
    local old; old="$(unit_val port)"
    command -v python3 >/dev/null || apt-get install -y python3 >/dev/null 2>&1
    [[ -f "$HERE/bhttp-server.py" ]] || { echo -e "${RED}Falta $HERE/bhttp-server.py${NC}"; return 1; }
    mkdir -p "$DIR"; install -m 755 "$HERE/bhttp-server.py" "$DIR/bhttp-server.py"
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=Servidor BHTTP (puerto $PORT -> dropbear $BPORT)
After=network.target
[Service]
Type=simple
ExecStart=$(command -v python3) $DIR/bhttp-server.py --host 0.0.0.0 --port $PORT --backend-host 127.0.0.1 --backend-port $BPORT
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65535
MemoryMax=512M
[Install]
WantedBy=multi-user.target
UNITEOF
    [[ -n "$old" && "$old" != "$PORT" ]] && fw_close "$old"
    fw_open "$PORT"
    systemctl daemon-reload; systemctl enable bhttp >/dev/null 2>&1; systemctl restart bhttp
    sleep 2
    if is_active; then
        echo -e "${GREEN}BHTTP escuchando en $PORT (backend SSH: 127.0.0.1:$BPORT)${NC}"
    else
        echo -e "${RED}El servicio no arrancó. Revisa: journalctl -u bhttp -n 30${NC}"; return 1
    fi
}

do_uninstall() {
    local p; p="$(unit_val port)"; p="${p:-$PORT}"
    systemctl disable --now bhttp 2>/dev/null; rm -rf "$UNIT" "$DIR"; systemctl daemon-reload
    fw_close "$p"
    echo -e "${GREEN}BHTTP eliminado${NC}"
}

show_status() {
    systemctl is-active bhttp 2>/dev/null
    ss -ltnp 2>/dev/null | grep -E ":$PORT\b"
}

show_logs() { journalctl -u bhttp -n 40 --no-pager 2>/dev/null | grep -v "socket.send() raised"; }

# ── Menú interactivo ──────────────────────────────────────────
menu_bhttp() {
    while true; do
        load_ports
        clear
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${WHITE}                  🚀 MÓDULO BHTTP${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        if is_installed; then
            is_active && ST="${GREEN}activo ✓${NC}" || ST="${RED}inactivo${NC}"
            echo -e " ${WHITE}Estado:${NC}        $ST"
            echo -e " ${WHITE}Puerto BHTTP:${NC}  ${CYAN}$PORT${NC}"
            echo -e " ${WHITE}Backend SSH:${NC}   ${CYAN}127.0.0.1:$BPORT${NC}"
            echo -e " ${WHITE}Conexiones:${NC}    ${CYAN}$(sessions_now)${NC} abiertas"
        else
            echo -e " ${WHITE}Estado:${NC}        ${YELLOW}no instalado${NC}"
        fi
        echo ""
        echo -e " ${WHITE}[1]${NC} Instalar / reinstalar BHTTP"
        echo -e " ${WHITE}[2]${NC} Cambiar puerto BHTTP"
        echo -e " ${WHITE}[3]${NC} Cambiar puerto del SSH de destino (dropbear 2222 / OpenSSH 22)"
        echo -e " ${WHITE}[4]${NC} Ver estado y conexiones"
        echo -e " ${WHITE}[5]${NC} Reiniciar BHTTP"
        echo -e " ${WHITE}[6]${NC} Ver logs"
        echo -e " ${WHITE}[7]${NC} ${RED}Desinstalar BHTTP${NC}"
        echo ""
        echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -ne " ${WHITE}► Opcion :${NC} "; read -r OPT
        case $OPT in
            1)
                echo -ne " ${WHITE}Puerto BHTTP [${PORT}]: ${NC}"; read -r P
                [[ -z "$P" ]] && P="$PORT"
                valid_port "$P" || { echo -e "${RED}Puerto no válido${NC}"; press_enter; continue; }
                port_busy "$P" && { echo -e "${RED}El puerto $P ya lo usa otro servicio${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Puerto del SSH de destino [${BPORT}]: ${NC}"; read -r B
                [[ -z "$B" ]] && B="$BPORT"
                valid_port "$B" || { echo -e "${RED}Puerto no válido${NC}"; press_enter; continue; }
                PORT="$P"; BPORT="$B"; export BHTTP_PORT="$P" BHTTP_BACKEND_PORT="$B"
                do_install; press_enter ;;
            2)
                is_installed || { echo -e "${YELLOW}Instala BHTTP primero${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Nuevo puerto BHTTP: ${NC}"; read -r P
                valid_port "$P" || { echo -e "${RED}Puerto no válido${NC}"; press_enter; continue; }
                port_busy "$P" && [[ "$P" != "$PORT" ]] && { echo -e "${RED}El puerto $P ya lo usa otro servicio${NC}"; press_enter; continue; }
                echo -e "${YELLOW}Se reiniciará el servicio: los clientes conectados se cortarán un momento.${NC}"
                export BHTTP_PORT="$P" BHTTP_BACKEND_PORT="$BPORT"; PORT="$P"
                do_install; echo -e " ${WHITE}Recuerda cambiar el puerto en los servidores del panel/app.${NC}"; press_enter ;;
            3)
                is_installed || { echo -e "${YELLOW}Instala BHTTP primero${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Nuevo puerto del SSH de destino: ${NC}"; read -r B
                valid_port "$B" || { echo -e "${RED}Puerto no válido${NC}"; press_enter; continue; }
                echo -e "${YELLOW}Se reiniciará el servicio: los clientes conectados se cortarán un momento.${NC}"
                export BHTTP_PORT="$PORT" BHTTP_BACKEND_PORT="$B"; BPORT="$B"
                do_install; press_enter ;;
            4)
                echo ""
                if is_installed; then
                    show_status
                    echo ""
                    echo -e " ${WHITE}Conexiones por IP de origen:${NC}"
                    ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | awk '{print $4}' \
                        | sed -E 's/:[0-9]+$//' | sort | uniq -c | sort -rn | head -10
                    echo ""
                    echo -e " ${WHITE}Cliente:${NC} IP de este servidor, puerto ${CYAN}$PORT${NC}, usuario y clave SSH normales."
                else
                    echo -e "${YELLOW}BHTTP no está instalado${NC}"
                fi
                press_enter ;;
            5)
                is_installed || { echo -e "${YELLOW}BHTTP no está instalado${NC}"; press_enter; continue; }
                systemctl restart bhttp; sleep 1
                is_active && echo -e "${GREEN}[+] BHTTP reiniciado${NC}" || echo -e "${RED}[!] No arrancó${NC}"
                press_enter ;;
            6) echo ""; show_logs; press_enter ;;
            7)
                is_installed || { echo -e "${YELLOW}BHTTP no está instalado${NC}"; press_enter; continue; }
                echo -ne "${RED}[!] ¿Desinstalar BHTTP? (si/no): ${NC}"; read -r C
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
    menu)      menu_bhttp ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    show_status ;;
    restart)   systemctl restart bhttp && echo "BHTTP reiniciado" ;;
    logs)      show_logs ;;
    *) echo "Uso: $0 [menu|install|uninstall|status|restart|logs]"; exit 1 ;;
esac
