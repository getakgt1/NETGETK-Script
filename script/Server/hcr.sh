#!/bin/bash
# ============================================================
#   GTKVPN - HCR Server (servicio aparte, puerto 8880 -> dropbear 2222)
#
#   Menú interactivo : hcr.sh          (también: menu -> [5] Instalador de protocolos -> [16] HCR)
#   Línea de comandos: hcr.sh install|uninstall|status|restart|logs
#                      [HCR_PORT=8880 HCR_BACKEND=127.0.0.1:2222 HCR_BIN=/ruta/hcr-server]
#
#   El binario hcr-server es de terceros y NO viaja en este repo:
#   colócalo en /opt/gtk-protocolos/hcr-server o pasa HCR_BIN=/ruta
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

DEST="/opt/gtk-protocolos/hcr-server"
UNIT="/etc/systemd/system/hcr-server.service"
[[ $EUID -ne 0 ]] && { echo -e "${RED}Requiere root${NC}"; exit 1; }

press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read -r; }

# Valores actuales: los de la unidad instalada; si no existe, los del entorno o los de por defecto.
unit_listen()  { grep -oE -- '--listen :[0-9]+' "$UNIT" 2>/dev/null | head -1 | grep -oE '[0-9]+$'; }
unit_target()  { grep -oE -- '--target [^ ]+' "$UNIT" 2>/dev/null | head -1 | awk '{print $2}'; }
load_cfg() {
    PORT="${HCR_PORT:-$(unit_listen)}";       PORT="${PORT:-8880}"
    BACKEND="${HCR_BACKEND:-$(unit_target)}"; BACKEND="${BACKEND:-127.0.0.1:2222}"
    SRC="${HCR_BIN:-$DEST}"
}
load_cfg

is_installed() { [[ -f "$UNIT" ]]; }
is_active()    { systemctl is-active --quiet hcr-server 2>/dev/null; }
valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_target() { [[ "$1" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]; }
port_busy()    { ss -ltnp 2>/dev/null | grep -E ":$1\b" | grep -vq "hcr-server"; }
sessions_now() { ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | wc -l; }

fw_open()  { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$1/tcp" >/dev/null 2>&1; }
fw_close() { command -v ufw >/dev/null && ufw delete allow "$1/tcp" >/dev/null 2>&1; }

do_install() {
    local old; old="$(unit_listen)"
    [[ -f "$SRC" ]] || { echo -e "${RED}Falta el binario hcr-server ($SRC)${NC}"; return 1; }
    mkdir -p /opt/gtk-protocolos
    [[ "$SRC" == "$DEST" ]] || install -m 755 "$SRC" "$DEST"
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=HCR Server (puerto $PORT -> $BACKEND)
After=network-online.target
Wants=network-online.target
[Service]
Type=exec
ExecStart=$DEST --listen :$PORT --target $BACKEND --transport plain --max-download-frame 6144 --download-poll-timeout 8s
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
CapabilityBoundingSet=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LimitNOFILE=65535
MemoryMax=512M
[Install]
WantedBy=multi-user.target
UNITEOF
    [[ -n "$old" && "$old" != "$PORT" ]] && fw_close "$old"
    fw_open "$PORT"
    systemctl daemon-reload; systemctl enable hcr-server >/dev/null 2>&1; systemctl restart hcr-server
    sleep 2
    if is_active; then
        echo -e "${GREEN}HCR escuchando en $PORT (destino: $BACKEND)${NC}"
    else
        echo -e "${RED}El servicio no arrancó. Revisa: journalctl -u hcr-server -n 30${NC}"; return 1
    fi
}

do_uninstall() {
    local p; p="$(unit_listen)"; p="${p:-$PORT}"
    systemctl disable --now hcr-server 2>/dev/null; rm -f "$UNIT"; systemctl daemon-reload
    fw_close "$p"
    echo -e "${GREEN}HCR eliminado${NC} (el binario en /opt/gtk-protocolos se conserva)"
}

show_status() { systemctl is-active hcr-server; ss -ltnp 2>/dev/null | grep -E "hcr-server"; }
show_logs()   { journalctl -u hcr-server -n 40 --no-pager 2>/dev/null; }

# ── Menú interactivo ──────────────────────────────────────────
menu_hcr() {
    while true; do
        load_cfg
        clear
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${WHITE}                  🔌 MÓDULO HCR${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        if is_installed; then
            is_active && ST="${GREEN}activo ✓${NC}" || ST="${RED}inactivo${NC}"
            echo -e " ${WHITE}Estado:${NC}        $ST"
            echo -e " ${WHITE}Puerto HCR:${NC}    ${CYAN}$PORT${NC}"
            echo -e " ${WHITE}Destino SSH:${NC}   ${CYAN}$BACKEND${NC}"
            echo -e " ${WHITE}Conexiones:${NC}    ${CYAN}$(sessions_now)${NC} abiertas"
        else
            echo -e " ${WHITE}Estado:${NC}        ${YELLOW}no instalado${NC}"
        fi
        [[ -f "$DEST" ]] && echo -e " ${WHITE}Binario:${NC}       ${GREEN}$DEST${NC}" \
                         || echo -e " ${WHITE}Binario:${NC}       ${RED}falta${NC} ${YELLOW}(déjalo en $DEST)${NC}"
        echo ""
        echo -e " ${WHITE}[1]${NC} Instalar / reinstalar HCR"
        echo -e " ${WHITE}[2]${NC} Cambiar puerto HCR"
        echo -e " ${WHITE}[3]${NC} Cambiar destino SSH (host:puerto)"
        echo -e " ${WHITE}[4]${NC} Ver estado y conexiones"
        echo -e " ${WHITE}[5]${NC} Reiniciar HCR"
        echo -e " ${WHITE}[6]${NC} Ver logs"
        echo -e " ${WHITE}[7]${NC} ${RED}Desinstalar HCR${NC}"
        echo ""
        echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -ne " ${WHITE}► Opcion :${NC} "; read -r OPT
        case $OPT in
            1)
                if [[ ! -f "$SRC" ]]; then
                    echo -e "${YELLOW}El binario hcr-server es de terceros y no viaja en el script.${NC}"
                    echo -ne " ${WHITE}Ruta del binario (Enter para cancelar): ${NC}"; read -r BIN
                    [[ -z "$BIN" ]] && continue
                    [[ -f "$BIN" ]] || { echo -e "${RED}No existe $BIN${NC}"; press_enter; continue; }
                    SRC="$BIN"; export HCR_BIN="$BIN"
                fi
                echo -ne " ${WHITE}Puerto HCR [${PORT}]: ${NC}"; read -r P
                [[ -z "$P" ]] && P="$PORT"
                valid_port "$P" || { echo -e "${RED}Puerto no válido${NC}"; press_enter; continue; }
                port_busy "$P" && { echo -e "${RED}El puerto $P ya lo usa otro servicio${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Destino SSH [${BACKEND}]: ${NC}"; read -r B
                [[ -z "$B" ]] && B="$BACKEND"
                valid_target "$B" || { echo -e "${RED}Destino no válido (usa host:puerto)${NC}"; press_enter; continue; }
                PORT="$P"; BACKEND="$B"; export HCR_PORT="$P" HCR_BACKEND="$B"
                do_install; press_enter ;;
            2)
                is_installed || { echo -e "${YELLOW}Instala HCR primero${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Nuevo puerto HCR: ${NC}"; read -r P
                valid_port "$P" || { echo -e "${RED}Puerto no válido${NC}"; press_enter; continue; }
                port_busy "$P" && [[ "$P" != "$PORT" ]] && { echo -e "${RED}El puerto $P ya lo usa otro servicio${NC}"; press_enter; continue; }
                echo -e "${YELLOW}Se reiniciará el servicio: los clientes conectados se cortarán un momento.${NC}"
                export HCR_PORT="$P" HCR_BACKEND="$BACKEND"; PORT="$P"
                do_install; echo -e " ${WHITE}Recuerda cambiar el puerto en los servidores del panel/app.${NC}"; press_enter ;;
            3)
                is_installed || { echo -e "${YELLOW}Instala HCR primero${NC}"; press_enter; continue; }
                echo -ne " ${WHITE}Nuevo destino SSH (host:puerto): ${NC}"; read -r B
                valid_target "$B" || { echo -e "${RED}Destino no válido (usa host:puerto)${NC}"; press_enter; continue; }
                echo -e "${YELLOW}Se reiniciará el servicio: los clientes conectados se cortarán un momento.${NC}"
                export HCR_PORT="$PORT" HCR_BACKEND="$B"; BACKEND="$B"
                do_install; press_enter ;;
            4)
                echo ""
                if is_installed; then
                    show_status
                    echo ""
                    echo -e " ${WHITE}Conexiones por IP de origen:${NC}"
                    ss -tn state established "( sport = :$PORT )" 2>/dev/null | tail -n +2 | awk '{print $4}' \
                        | sed -E 's/:[0-9]+$//' | sort | uniq -c | sort -rn | head -10
                else
                    echo -e "${YELLOW}HCR no está instalado${NC}"
                fi
                press_enter ;;
            5)
                is_installed || { echo -e "${YELLOW}HCR no está instalado${NC}"; press_enter; continue; }
                systemctl restart hcr-server; sleep 1
                is_active && echo -e "${GREEN}[+] HCR reiniciado${NC}" || echo -e "${RED}[!] No arrancó${NC}"
                press_enter ;;
            6) echo ""; show_logs; press_enter ;;
            7)
                is_installed || { echo -e "${YELLOW}HCR no está instalado${NC}"; press_enter; continue; }
                echo -ne "${RED}[!] ¿Desinstalar HCR? (si/no): ${NC}"; read -r C
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
    menu)      menu_hcr ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    show_status ;;
    restart)   systemctl restart hcr-server && echo "HCR reiniciado" ;;
    logs)      show_logs ;;
    *) echo "Uso: $0 [menu|install|uninstall|status|restart|logs]"; exit 1 ;;
esac
