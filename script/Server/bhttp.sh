#!/bin/bash
# ============================================================
#   GTKVPN - BHTTP (servidor Python incluido: puerto 8445 -> dropbear 2222)
#   Puerto principal a elección, puertos adicionales (p. ej. 8080) y, opcional, BHTTP también por
#   el puerto 80 compartido con pdirect/WebSocket. Nada de esto toca los servicios que ya existen.
#
#   Menú interactivo : bhttp.sh            (también: menu -> [5] Instalador de protocolos -> [15] BHTTP)
#   Línea de comandos: bhttp.sh install|uninstall|status|restart|logs
#                      [BHTTP_PORT=8445 BHTTP_BACKEND_PORT=2222]
#                      bhttp.sh add-port 8080 | del-port 8080   (puertos BHTTP adicionales)
#                      bhttp.sh pdirect on|off                 (BHTTP también por el puerto 80)
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

PDIRECT_FILE="/etc/bhttp/pdirect-port"

# Escribe una unidad systemd: write_unit <archivo> <puerto> <puerto SSH destino>
write_unit() {
    cat > "$1" <<UNITEOF
[Unit]
Description=Servidor BHTTP (puerto $2 -> dropbear $3)
After=network.target
[Service]
Type=simple
ExecStart=$(command -v python3) $DIR/bhttp-server.py --host 0.0.0.0 --port $2 --backend-host 127.0.0.1 --backend-port $3
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
}

# Puertos BHTTP adicionales ya instalados (unidades bhttp-<puerto>.service)
extra_ports() { ls /etc/systemd/system/bhttp-[0-9]*.service 2>/dev/null | sed -E 's/.*bhttp-([0-9]+)\.service/\1/' | sort -n; }

add_extra() {
    local p="$1"
    is_installed || { echo -e "${YELLOW}Instala BHTTP primero${NC}"; return 1; }
    valid_port "$p" || { echo -e "${RED}Puerto no válido${NC}"; return 1; }
    [[ "$p" == "$PORT" ]] && { echo -e "${YELLOW}$p ya es el puerto principal${NC}"; return 1; }
    local f="/etc/systemd/system/bhttp-$p.service"
    if [[ ! -f "$f" ]] && port_busy "$p"; then
        echo -e "${RED}El puerto $p ya lo usa otro servicio (no se toca)${NC}"; return 1
    fi
    write_unit "$f" "$p" "$BPORT"
    fw_open "$p"
    systemctl daemon-reload; systemctl enable "bhttp-$p" >/dev/null 2>&1; systemctl restart "bhttp-$p"
    sleep 2
    systemctl is-active --quiet "bhttp-$p" \
        && echo -e "${GREEN}BHTTP adicional escuchando en $p (backend SSH: 127.0.0.1:$BPORT)${NC}" \
        || { echo -e "${RED}No arrancó bhttp-$p. Revisa: journalctl -u bhttp-$p -n 30${NC}"; return 1; }
}

del_extra() {
    local p="$1" f="/etc/systemd/system/bhttp-$1.service"
    [[ -f "$f" ]] || { echo -e "${YELLOW}No hay BHTTP adicional en $p${NC}"; return 1; }
    systemctl disable --now "bhttp-$p" 2>/dev/null; rm -f "$f"; systemctl daemon-reload
    fw_close "$p"; echo -e "${GREEN}BHTTP adicional en $p eliminado${NC}"
}

# BHTTP también por el puerto 80 (pdirect lo reparte: WebSocket/SSH como siempre, BHTTP al puerto
# principal). pdirect relee el archivo solo, sin reiniciar y sin cortar a nadie.
pdirect_set() {
    case "$1" in
        on)  is_installed || { echo -e "${YELLOW}Instala BHTTP primero${NC}"; return 1; }
             mkdir -p /etc/bhttp; echo "$PORT" > "$PDIRECT_FILE"
             echo -e "${GREEN}Puerto 80 (pdirect) también acepta BHTTP -> $PORT${NC}"
             pgrep -f pdirect.py >/dev/null || echo -e "${YELLOW}pdirect no está corriendo: instala Falcon Proxy / WS para usar el 80${NC}" ;;
        off) rm -f "$PDIRECT_FILE"; echo -e "${GREEN}Puerto 80 sin BHTTP (como antes)${NC}" ;;
        *)   echo "Uso: $0 pdirect on|off"; return 1 ;;
    esac
}
pdirect_state() { [[ -s "$PDIRECT_FILE" ]] && echo "activo -> $(cat "$PDIRECT_FILE")" || echo "apagado"; }

do_install() {
    local old; old="$(unit_val port)"
    command -v python3 >/dev/null || apt-get install -y python3 >/dev/null 2>&1
    [[ -f "$HERE/bhttp-server.py" ]] || { echo -e "${RED}Falta $HERE/bhttp-server.py${NC}"; return 1; }
    mkdir -p "$DIR"; install -m 755 "$HERE/bhttp-server.py" "$DIR/bhttp-server.py"
    write_unit "$UNIT" "$PORT" "$BPORT"
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
    for e in $(extra_ports); do del_extra "$e" >/dev/null; done
    rm -f "$PDIRECT_FILE"; rmdir /etc/bhttp 2>/dev/null
    systemctl disable --now bhttp 2>/dev/null; rm -rf "$UNIT" "$DIR"; systemctl daemon-reload
    fw_close "$p"
    echo -e "${GREEN}BHTTP eliminado${NC}"
}

show_status() {
    systemctl is-active bhttp 2>/dev/null
    ss -ltnp 2>/dev/null | grep -E ":$PORT\b"
    for e in $(extra_ports); do echo "extra $e: $(systemctl is-active bhttp-$e 2>/dev/null)"; done
    echo "puerto 80 (pdirect): $(pdirect_state)"
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
            EX="$(extra_ports | tr '\n' ' ')"
            echo -e " ${WHITE}Puertos extra:${NC} ${CYAN}${EX:-ninguno}${NC}"
            echo -e " ${WHITE}Por el 80:${NC}     ${CYAN}$(pdirect_state)${NC}"
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
        echo -e " ${WHITE}[8]${NC} Añadir puerto BHTTP extra (p. ej. 8080)"
        echo -e " ${WHITE}[9]${NC} Quitar puerto BHTTP extra"
        echo -e " ${WHITE}[10]${NC} Activar/desactivar BHTTP también por el puerto 80"
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
            8)
                echo -ne " ${WHITE}Puerto extra: ${NC}"; read -r P
                add_extra "$P"; press_enter ;;
            9)
                echo -e " ${WHITE}Extras instalados:${NC} $(extra_ports | tr '\n' ' ')"
                echo -ne " ${WHITE}Puerto a quitar: ${NC}"; read -r P
                del_extra "$P"; press_enter ;;
            10)
                if [[ -s "$PDIRECT_FILE" ]]; then pdirect_set off; else pdirect_set on; fi
                press_enter ;;
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
    restart)   systemctl restart bhttp && echo "BHTTP reiniciado"; for e in $(extra_ports); do systemctl restart "bhttp-$e"; done ;;
    add-port)  add_extra "${2:-}" ;;
    del-port)  del_extra "${2:-}" ;;
    pdirect)   pdirect_set "${2:-}" ;;
    logs)      show_logs ;;
    *) echo "Uso: $0 [menu|install|uninstall|status|restart|logs|add-port N|del-port N|pdirect on|off]"; exit 1 ;;
esac
