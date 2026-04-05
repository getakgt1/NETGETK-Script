#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; MAGENTA='\033[0;35m'; NC='\033[0m'
INSTALL_DIR="/etc/gtkvpn"; HY_BIN="/root/hysteria"; HY_CONFIG="/root/hysteria_server.json"
HY_CERT="/root/hysteria.crt"; HY_KEY="/root/hysteria.key"; HY_SERVICE="/etc/systemd/system/hysteria.service"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read; }
hy_port()   { python3 -c "import json; d=json.load(open('$HY_CONFIG')); print(d['listen'].replace(':',''))" 2>/dev/null || echo "N/A"; }
hy_pass()   { python3 -c "import json; d=json.load(open('$HY_CONFIG')); print(','.join(d['auth']['config']))" 2>/dev/null || echo "N/A"; }
hy_status() { systemctl is-active --quiet hysteria 2>/dev/null && echo -e "${GREEN}activo ✓${NC}" || echo -e "${RED}inactivo${NC}"; }
udp_port()  { grep -o '"listen":":[0-9]*"' /root/udp/config.json 2>/dev/null | grep -o '[0-9]*'; }
menu_hysteria() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                🚀 MÓDULO HYSTERIA v1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${WHITE}Estado:${NC}     $(hy_status)"
    echo -e " ${WHITE}Puerto:${NC}     ${CYAN}$(hy_port)${NC}"
    echo -e " ${WHITE}Password:${NC}   ${CYAN}$(hy_pass)${NC}"
    echo -e " ${WHITE}UDP Custom:${NC} ${CYAN}$(udp_port)${NC}"
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar Hysteria"
    echo -e " ${WHITE}[2]${NC} Cambiar puerto"
    echo -e " ${WHITE}[3]${NC} Cambiar contraseña"
    echo -e " ${WHITE}[4]${NC} Mostrar datos de conexión"
    echo -e " ${WHITE}[5]${NC} Reiniciar"
    echo -e " ${WHITE}[6]${NC} Ver logs"
    echo -e " ${WHITE}[7]${NC} Desinstalar"
    echo ""; echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "; read OPT
    case $OPT in
        1) install_hysteria ;; 2) change_port ;; 3) change_password ;;
        4) show_info ;; 5) systemctl restart hysteria; echo -e "${GREEN}[+] Reiniciado${NC}"; sleep 1; menu_hysteria ;;
        6) journalctl -u hysteria -n 40 --no-pager; press_enter; menu_hysteria ;;
        7) uninstall_hysteria ;; 0) return ;; *) menu_hysteria ;;
    esac
}
install_hysteria() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}        🔧 Instalando Hysteria v1.3.5${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo ""
    if [[ -f "$HY_BIN" ]]; then
        echo -e "${YELLOW}[!] Ya instalado. ¿Reinstalar? (s/N): ${NC}"; read C
        [[ "$C" != "s" && "$C" != "S" ]] && menu_hysteria && return
        systemctl stop hysteria 2>/dev/null
    fi
    UDP_USED=$(udp_port)
    echo -ne " ${WHITE}Puerto UDP [36711]: ${NC}"; read HY_PORT; [[ -z "$HY_PORT" ]] && HY_PORT=36711
    if [[ -n "$UDP_USED" && "$HY_PORT" == "$UDP_USED" ]]; then
        echo -e "${RED}[!] Puerto $HY_PORT ya lo usa UDP Custom.${NC}"; press_enter; menu_hysteria; return
    fi
    echo -ne " ${WHITE}Contraseña [FREE]: ${NC}"; read HY_PASS; [[ -z "$HY_PASS" ]] && HY_PASS="FREE"
    echo -ne " ${WHITE}UP Mbps [100]: ${NC}"; read UP; [[ -z "$UP" ]] && UP=100
    echo -ne " ${WHITE}DOWN Mbps [100]: ${NC}"; read DOWN; [[ -z "$DOWN" ]] && DOWN=100
    echo -e "${CYAN}[1/4] Descargando binario...${NC}"
    ARCH=$(uname -m); [[ "$ARCH" == "aarch64" ]] && AT="arm64" || AT="amd64"
    curl -L --progress-bar -o "$HY_BIN" "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-${AT}" 2>/dev/null
    chmod +x "$HY_BIN"
    [[ ! -x "$HY_BIN" ]] && echo -e "${RED}[!] Error descargando.${NC}" && press_enter && menu_hysteria && return
    echo -e "${CYAN}[2/4] Generando certificado...${NC}"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout "$HY_KEY" -out "$HY_CERT" -subj "/CN=hysteria" -days 3650 2>/dev/null
    chmod 600 "$HY_KEY"
    echo -e "${CYAN}[3/4] Creando config...${NC}"
    echo "{\"listen\":\":${HY_PORT}\",\"cert\":\"${HY_CERT}\",\"key\":\"${HY_KEY}\",\"up_mbps\":${UP},\"down_mbps\":${DOWN},\"auth\":{\"mode\":\"passwords\",\"config\":[\"${HY_PASS}\"]},\"recv_window_conn\":33554432,\"recv_window\":83886080}" > "$HY_CONFIG"
    echo -e "${CYAN}[4/4] Creando servicio...${NC}"
    cat > "$HY_SERVICE" << 'SVCEOF'
[Unit]
Description=Hysteria VPN Server
After=network.target
[Service]
User=root
ExecStart=/root/hysteria server -c /root/hysteria_server.json --no-check
Restart=always
RestartSec=3s
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload; systemctl enable hysteria; systemctl restart hysteria
    ufw allow "$HY_PORT/udp" 2>/dev/null; ufw allow "$HY_PORT/tcp" 2>/dev/null
    grep -q "^HY_PORT=" "$INSTALL_DIR/config.conf" 2>/dev/null && sed -i "s/^HY_PORT=.*/HY_PORT=$HY_PORT/" "$INSTALL_DIR/config.conf" || echo "HY_PORT=$HY_PORT" >> "$INSTALL_DIR/config.conf"
    grep -q "^HY_PASS=" "$INSTALL_DIR/config.conf" 2>/dev/null && sed -i "s/^HY_PASS=.*/HY_PASS=$HY_PASS/" "$INSTALL_DIR/config.conf" || echo "HY_PASS=$HY_PASS" >> "$INSTALL_DIR/config.conf"
    sleep 2; echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    systemctl is-active --quiet hysteria && echo -e " ${GREEN}✓ Hysteria activo en puerto UDP $HY_PORT${NC}" || echo -e " ${RED}✗ Error — revisa: journalctl -u hysteria -n 20${NC}"
    echo ""; show_info
}
change_port() {
    [[ ! -f "$HY_CONFIG" ]] && echo -e "${RED}[!] No instalado${NC}" && press_enter && menu_hysteria && return
    echo -ne " ${WHITE}Nuevo puerto: ${NC}"; read NP
    [[ ! "$NP" =~ ^[0-9]+$ ]] && echo -e "${RED}[!] Inválido${NC}" && press_enter && menu_hysteria && return
    UDP_USED=$(udp_port)
    [[ -n "$UDP_USED" && "$NP" == "$UDP_USED" ]] && echo -e "${RED}[!] Lo usa UDP Custom.${NC}" && press_enter && menu_hysteria && return
    python3 -c "import json; f=open('$HY_CONFIG'); d=json.load(f); f.close(); d['listen']=':$NP'; open('$HY_CONFIG','w').write(json.dumps(d))"
    ufw allow "$NP/udp" 2>/dev/null; systemctl restart hysteria
    sed -i "s/^HY_PORT=.*/HY_PORT=$NP/" "$INSTALL_DIR/config.conf" 2>/dev/null
    echo -e "${GREEN}[+] Puerto cambiado a $NP${NC}"; press_enter; menu_hysteria
}
change_password() {
    [[ ! -f "$HY_CONFIG" ]] && echo -e "${RED}[!] No instalado${NC}" && press_enter && menu_hysteria && return
    echo -e " Actual: ${CYAN}$(hy_pass)${NC}"; echo -ne " ${WHITE}Nueva contraseña: ${NC}"; read NP2
    [[ -z "$NP2" ]] && echo -e "${RED}[!] Vacía${NC}" && press_enter && menu_hysteria && return
    python3 -c "import json; f=open('$HY_CONFIG'); d=json.load(f); f.close(); d['auth']['config']=['$NP2']; open('$HY_CONFIG','w').write(json.dumps(d))"
    systemctl restart hysteria; sed -i "s/^HY_PASS=.*/HY_PASS=$NP2/" "$INSTALL_DIR/config.conf" 2>/dev/null
    echo -e "${GREEN}[+] Contraseña cambiada${NC}"; press_enter; menu_hysteria
}
show_info() {
    [[ ! -f "$HY_CONFIG" ]] && echo -e "${RED}[!] No instalado${NC}" && press_enter && menu_hysteria && return
    SIP=$(grep "^VPS_IP=" "$INSTALL_DIR/config.conf" 2>/dev/null | cut -d= -f2)
    [[ -z "$SIP" ]] && SIP=$(curl -s --max-time 8 ifconfig.me 2>/dev/null)
    echo ""; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}              📱 DATOS DE CONEXIÓN${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo ""
    echo -e "${MAGENTA} ── HYSTERIA v1 ─────────────────────────────────────────────${NC}"
    echo -e " ${YELLOW}IP       →${NC} ${CYAN}$SIP${NC}"
    echo -e " ${YELLOW}Puerto   →${NC} ${CYAN}$(hy_port) (UDP)${NC}"
    echo -e " ${YELLOW}Password →${NC} ${CYAN}$(hy_pass)${NC}"
    echo -e " ${YELLOW}TLS      →${NC} ${CYAN}self-signed / skip verify${NC}"
    UDP_P=$(udp_port)
    [[ -n "$UDP_P" ]] && echo "" && echo -e "${MAGENTA} ── UDP CUSTOM ──────────────────────────────────────────────${NC}" && echo -e " ${YELLOW}Servidor →${NC} ${CYAN}$SIP:$UDP_P${NC}"
    echo ""; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    press_enter; menu_hysteria
}
uninstall_hysteria() {
    echo -ne "${RED}[!] ¿Desinstalar? (s/N): ${NC}"; read C
    [[ "$C" != "s" && "$C" != "S" ]] && menu_hysteria && return
    systemctl stop hysteria 2>/dev/null; systemctl disable hysteria 2>/dev/null
    rm -f "$HY_SERVICE" "$HY_BIN" "$HY_CONFIG" "$HY_CERT" "$HY_KEY"; systemctl daemon-reload
    sed -i '/^HY_PORT=/d; /^HY_PASS=/d' "$INSTALL_DIR/config.conf" 2>/dev/null
    echo -e "${GREEN}[+] Desinstalado${NC}"; press_enter; menu_hysteria
}
menu_hysteria
