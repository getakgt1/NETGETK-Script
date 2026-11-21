#!/bin/bash
# ============================================================
#   GTKVPN - BadVPN-UDPgw (relay UDP del servidor: 127.0.0.1:7300)
#
#   GTKVPN envía por este relay el UDP de los perfiles V2Ray/XRay y SSH (DNS, QUIC, juegos). Sin él el túnel
#   "conecta" pero no resuelve nombres y no hay internet. Se compila desde el código fuente oficial
#   (ambrop72/badvpn), así que no depende de binarios copiados a mano.
#
#   Menú interactivo : badvpn.sh        (también: menu -> [5] Instalador de protocolos -> [8] BadVPN-UDPgw)
#   Línea de comandos: badvpn.sh install|uninstall|status      [BADVPN_PORT=7300] [BADVPN_MAX_CLIENTS=500]
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
CONF="$INSTALL_DIR/config.conf"
BIN="/usr/local/bin/badvpn-udpgw"
UNIT="/etc/systemd/system/badvpn-udpgw.service"
DROPIN="/etc/systemd/system/badvpn-udpgw.service.d/limits.conf"
VERSION="1.999.130"
SRC_URL="https://github.com/ambrop72/badvpn/archive/refs/tags/${VERSION}.tar.gz"
PORT="${BADVPN_PORT:-7300}"
MAXCL="${BADVPN_MAX_CLIENTS:-500}"
[[ $EUID -ne 0 ]] && { echo -e "${RED}Requiere root${NC}"; exit 1; }

press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read -r; }
is_active() { systemctl is-active --quiet badvpn-udpgw 2>/dev/null; }

# Guarda UDPGW_PORT en config.conf sin duplicar la clave (lo leen el panel y el firewall)
save_port() {
    mkdir -p "$INSTALL_DIR"; touch "$CONF"
    sed -i '/^UDPGW_PORT=/d' "$CONF"
    echo "UDPGW_PORT=$PORT" >> "$CONF"
}

build_binary() {
    local tmp; tmp=$(mktemp -d /tmp/badvpn-build.XXXXXX) || return 1
    echo -e "${CYAN}[*] Instalando dependencias de compilación...${NC}"
    if ! command -v cmake >/dev/null || ! command -v make >/dev/null || ! command -v gcc >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential cmake curl ca-certificates >/dev/null 2>&1
    fi
    for c in cmake make gcc curl tar; do
        command -v "$c" >/dev/null || { echo -e "${RED}[!] Falta '$c' y no se pudo instalar${NC}"; rm -rf "$tmp"; return 1; }
    done
    echo -e "${CYAN}[*] Descargando BadVPN $VERSION...${NC}"
    if ! curl -fsSL --max-time 120 -o "$tmp/src.tar.gz" "$SRC_URL"; then
        echo -e "${RED}[!] No se pudo descargar el código fuente (¿sin acceso a github.com?)${NC}"; rm -rf "$tmp"; return 1
    fi
    tar xzf "$tmp/src.tar.gz" -C "$tmp" || { echo -e "${RED}[!] Archivo dañado${NC}"; rm -rf "$tmp"; return 1; }
    local src; src=$(ls -d "$tmp"/badvpn-* 2>/dev/null | head -1)
    echo -e "${CYAN}[*] Compilando (1-2 min)...${NC}"
    mkdir -p "$tmp/build"
    ( cd "$tmp/build" && cmake "$src" -DCMAKE_BUILD_TYPE=Release -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > "$tmp/cmake.log" 2>&1 && make -j"$(nproc)" >> "$tmp/cmake.log" 2>&1 )
    local out; out=$(find "$tmp/build" -name badvpn-udpgw -type f 2>/dev/null | head -1)
    if [[ -z "$out" ]]; then
        echo -e "${RED}[!] Falló la compilación. Últimas líneas:${NC}"; tail -8 "$tmp/cmake.log"; rm -rf "$tmp"; return 1
    fi
    install -m 755 "$out" "$BIN"
    rm -rf "$tmp"
    return 0
}

do_install() {
    echo ""
    if is_active && [[ -x "$BIN" ]] && grep -q -- "--listen-addr 127.0.0.1:$PORT" "$UNIT" 2>/dev/null; then
        echo -e "${GREEN}[+] BadVPN-UDPgw ya está activo en 127.0.0.1:$PORT${NC}"; return 0
    fi
    [[ -x "$BIN" ]] || build_binary || return 1
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=badvpn udpgw
After=network.target

[Service]
ExecStart=$BIN --listen-addr 127.0.0.1:$PORT --max-clients $MAXCL
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Service]\nLimitNOFILE=65535\n' > "$DROPIN"
    systemctl daemon-reload
    systemctl enable badvpn-udpgw >/dev/null 2>&1
    systemctl restart badvpn-udpgw
    sleep 2
    save_port
    if is_active && ss -tlnH 2>/dev/null | grep -q "127.0.0.1:$PORT "; then
        echo -e "${GREEN}[+] BadVPN-UDPgw activo en 127.0.0.1:$PORT (máx. $MAXCL clientes)${NC}"
    else
        echo -e "${RED}[!] El servicio no quedó escuchando en $PORT${NC}"; journalctl -u badvpn-udpgw -n 8 --no-pager 2>/dev/null
        return 1
    fi
}

do_uninstall() {
    echo ""
    systemctl disable --now badvpn-udpgw >/dev/null 2>&1
    rm -f "$UNIT" "$BIN"; rm -rf "$(dirname "$DROPIN")"
    systemctl daemon-reload
    echo -e "${GREEN}[+] BadVPN-UDPgw desinstalado${NC}"
}

show_status() {
    is_active && echo -e " Estado: ${GREEN}activo ✓${NC}" || echo -e " Estado: ${RED}inactivo${NC}"
    echo " Escucha: $(ss -tlnpH 2>/dev/null | grep badvpn | awk '{print $4}' | tr '\n' ' ')"
    echo " Binario: $([[ -x $BIN ]] && echo "$BIN" || echo "no instalado")"
}

menu_badvpn() {
    while true; do
        clear
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${WHITE}                  🔗 MÓDULO BADVPN-UDPGW${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        show_status
        echo ""
        echo -e " ${WHITE}[1]${NC} Instalar / reinstalar (compila desde el código fuente)"
        echo -e " ${WHITE}[2]${NC} Reiniciar"
        echo -e " ${WHITE}[3]${NC} ${RED}Desinstalar${NC}"
        echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
        echo -ne "\n ${WHITE}► Opcion :${NC} "; read -r OPT
        case $OPT in
            1) rm -f "$BIN"; do_install; press_enter ;;
            2) systemctl restart badvpn-udpgw; echo -e "${GREEN}[+] Reiniciado${NC}"; sleep 1 ;;
            3) do_uninstall; press_enter ;;
            0) return 0 ;;
        esac
    done
}

case "${1:-menu}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    show_status ;;
    *)         menu_badvpn ;;
esac
