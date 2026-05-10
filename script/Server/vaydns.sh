#!/bin/bash
# ============================================================
#   NETGETK - Modulo VayDNS SSH (GTK VPN App)
#   Gestiona Hysteria v1 con datos formateados para GTK VPN
#   By: NETGETK | github.com/getakgt1/NETGETK-Script
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; MAGENTA='\033[0;35m'
GRAY='\033[0;37m'; NC='\033[0m'

HY_BIN="/root/hysteria"
HY_CONFIG="/root/hysteria_server.json"
HY_CERT="/root/hysteria.crt"
HY_KEY="/root/hysteria.key"
HY_SERVICE="/etc/systemd/system/hysteria.service"
INSTALL_DIR="/etc/gtkvpn"

press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read; }

hy_port() { python3 -c "import json; d=json.load(open('$HY_CONFIG')); print(d['listen'].replace(':',''))" 2>/dev/null || echo "N/A"; }
hy_pass() { python3 -c "import json; d=json.load(open('$HY_CONFIG')); cfg=d.get('auth',{}).get('config',[]); print(cfg[0] if cfg else d.get('auth',{}).get('password','N/A'))" 2>/dev/null || echo "N/A"; }
hy_status() { systemctl is-active --quiet hysteria 2>/dev/null && echo -e "${GREEN}activo${NC}" || echo -e "${RED}inactivo${NC}"; }

get_fingerprint() {
    [[ ! -f "$HY_CERT" ]] && echo "N/A" && return
    FP=$(openssl x509 -fingerprint -sha256 -noout -in "$HY_CERT" 2>/dev/null | cut -d= -f2)
    echo "$FP" | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

get_vps_ip() {
    SIP=$(grep "^VPS_IP=" "$INSTALL_DIR/config.conf" 2>/dev/null | cut -d= -f2)
    [[ -z "$SIP" ]] && SIP=$(curl -s --max-time 8 ifconfig.me 2>/dev/null)
    echo "$SIP"
}

menu_vaydns() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}           📱 VAYDNS SSH — GTK VPN APP${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${WHITE}Motor:${NC}    Hysteria v1 (UDP+BBR+TLS)"
    echo -e " ${WHITE}Estado:${NC}   $(hy_status)"
    [[ -f "$HY_CONFIG" ]] && {
        echo -e " ${WHITE}Puerto:${NC}   ${CYAN}$(hy_port) UDP${NC}"
        echo -e " ${WHITE}Password:${NC} ${CYAN}$(hy_pass)${NC}"
    }
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar / Configurar"
    echo -e " ${WHITE}[2]${NC} Ver datos para GTK VPN App"
    echo -e " ${WHITE}[3]${NC} Cambiar contrasena"
    echo -e " ${WHITE}[4]${NC} Cambiar puerto UDP"
    echo -e " ${WHITE}[5]${NC} Reiniciar servicio"
    echo -e " ${WHITE}[6]${NC} Ver logs"
    echo -e " ${WHITE}[7]${NC} Regenerar certificado (nueva Public Key)"
    echo -e " ${WHITE}[8]${NC} Desinstalar"
    echo ""; echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "; read OPT
    case $OPT in
        1) install_vaydns ;; 2) show_app_config ;; 3) change_password ;;
        4) change_port ;; 5) systemctl restart hysteria && echo -e "${GREEN}[+] Reiniciado${NC}" || echo -e "${RED}[!] Error${NC}"; sleep 1; menu_vaydns ;;
        6) journalctl -u hysteria -n 40 --no-pager; press_enter; menu_vaydns ;;
        7) regen_cert ;; 8) uninstall_vaydns ;; 0) return ;; *) menu_vaydns ;;
    esac
}

install_vaydns() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}        Instalando VayDNS SSH (Hysteria v1)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    if [[ -f "$HY_BIN" ]]; then
        echo -e "${YELLOW}[!] Ya instalado. ¿Reinstalar? (s/N): ${NC}"; read C
        [[ "$C" != "s" && "$C" != "S" ]] && menu_vaydns && return
        systemctl stop hysteria 2>/dev/null
    fi
    echo -ne " ${WHITE}Puerto UDP [443]: ${NC}"; read HY_PORT; [[ -z "$HY_PORT" ]] && HY_PORT=443
    echo -ne " ${WHITE}Contrasena [gtkvpn2024]: ${NC}"; read HY_PASS; [[ -z "$HY_PASS" ]] && HY_PASS="gtkvpn2024"
    echo -ne " ${WHITE}UP Mbps [100]: ${NC}"; read UP; [[ -z "$UP" ]] && UP=100
    echo -ne " ${WHITE}DOWN Mbps [100]: ${NC}"; read DOWN; [[ -z "$DOWN" ]] && DOWN=100
    echo ""
    echo -e "${CYAN}[1/4] Descargando Hysteria v1...${NC}"
    ARCH=$(uname -m); [[ "$ARCH" == "aarch64" ]] && AT="arm64" || AT="amd64"
    curl -L --progress-bar -o "$HY_BIN" \
        "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-${AT}" 2>/dev/null
    chmod +x "$HY_BIN"
    [[ ! -x "$HY_BIN" ]] && echo -e "${RED}[!] Error descargando.${NC}" && press_enter && menu_vaydns && return
    echo -e "${CYAN}[2/4] Generando certificado TLS...${NC}"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$HY_KEY" -out "$HY_CERT" -subj "/CN=gtkvpn" -days 3650 2>/dev/null
    chmod 600 "$HY_KEY"
    echo -e "${CYAN}[3/4] Creando configuracion...${NC}"
    cat > "$HY_CONFIG" << JSONEOF
{
  "listen": ":${HY_PORT}",
  "cert": "${HY_CERT}",
  "key": "${HY_KEY}",
  "auth": {
    "mode": "passwords",
    "config": ["${HY_PASS}"]
  },
  "up_mbps": ${UP},
  "down_mbps": ${DOWN},
  "recv_window_conn": 33554432,
  "recv_window": 83886080,
  "disable_mtu_discovery": false
}
JSONEOF
    echo -e "${CYAN}[4/4] Creando servicio...${NC}"
    cat > "$HY_SERVICE" << SVCEOF
[Unit]
Description=Hysteria VayDNS SSH Server
After=network.target
[Service]
User=root
ExecStart=${HY_BIN} server -c ${HY_CONFIG} --no-check
Restart=always
RestartSec=3s
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload; systemctl enable hysteria; systemctl restart hysteria
    ufw allow "${HY_PORT}/udp" 2>/dev/null; ufw allow "${HY_PORT}/tcp" 2>/dev/null
    apt-get install -y iptables-persistent netfilter-persistent 2>/dev/null
    iptables -I INPUT -p udp --dport "$HY_PORT" -j ACCEPT
    iptables -t raw -I PREROUTING -p udp --dport "$HY_PORT" -j NOTRACK
    iptables -t raw -I PREROUTING -p udp --sport "$HY_PORT" -j NOTRACK
    netfilter-persistent save 2>/dev/null
    grep -q "^HY_PORT=" "$INSTALL_DIR/config.conf" 2>/dev/null \
        && sed -i "s/^HY_PORT=.*/HY_PORT=$HY_PORT/" "$INSTALL_DIR/config.conf" \
        || echo "HY_PORT=$HY_PORT" >> "$INSTALL_DIR/config.conf"
    grep -q "^HY_PASS=" "$INSTALL_DIR/config.conf" 2>/dev/null \
        && sed -i "s/^HY_PASS=.*/HY_PASS=$HY_PASS/" "$INSTALL_DIR/config.conf" \
        || echo "HY_PASS=$HY_PASS" >> "$INSTALL_DIR/config.conf"
    sleep 2; echo ""
    systemctl is-active --quiet hysteria \
        && echo -e "${GREEN}✓ VayDNS SSH activo en puerto UDP $HY_PORT${NC}" \
        || echo -e "${RED}✗ Error — revisa: journalctl -u hysteria -n 20${NC}"
    echo ""; show_app_config
}

show_app_config() {
    [[ ! -f "$HY_CONFIG" ]] && echo -e "${RED}[!] No instalado${NC}" && press_enter && menu_vaydns && return
    SIP=$(get_vps_ip); PORT=$(hy_port); PASS=$(hy_pass); FP=$(get_fingerprint)
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}         📱 CONFIGURACION PARA GTK VPN APP${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e " ${YELLOW}Protocolo   →${NC} ${WHITE}VayDNS${NC}  (en lista de protocolos de la app)"
    echo -e " ${YELLOW}Servidor    →${NC} ${CYAN}$SIP${NC}"
    echo -e " ${YELLOW}Usuario SSH →${NC} ${CYAN}vaydns${NC}"
    echo -e " ${YELLOW}Contrasena  →${NC} ${CYAN}$PASS${NC}"
    echo -e " ${YELLOW}Puerto SSH  →${NC} ${CYAN}22${NC}  (ignorado)"
    echo -e " ${YELLOW}Puerto UDP  →${NC} ${CYAN}$PORT${NC}"
    echo -e " ${YELLOW}Public Key  →${NC} ${CYAN}$FP${NC}"
    echo -e " ${YELLOW}DNS propios →${NC} ${GRAY}dejar vacio${NC}"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -e " ${YELLOW}Estado      →${NC} $(hy_status)"
    echo -e " ${YELLOW}Motor       →${NC} Hysteria v1 (UDP+BBR+TLS autofirmado)"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    press_enter; menu_vaydns
}

change_password() {
    [[ ! -f "$HY_CONFIG" ]] && echo -e "${RED}[!] No instalado${NC}" && press_enter && menu_vaydns && return
    echo -e " Actual: ${CYAN}$(hy_pass)${NC}"
    echo -ne " ${WHITE}Nueva contrasena: ${NC}"; read NP
    [[ -z "$NP" ]] && echo -e "${RED}[!] Vacia${NC}" && press_enter && menu_vaydns && return
    python3 -c "
import json
with open('$HY_CONFIG') as f: d=json.load(f)
if 'config' in d.get('auth',{}): d['auth']['config']=['$NP']
elif 'password' in d.get('auth',{}): d['auth']['password']='$NP'
with open('$HY_CONFIG','w') as f: json.dump(d,f,indent=2)
"
    systemctl restart hysteria
    sed -i "s/^HY_PASS=.*/HY_PASS=$NP/" "$INSTALL_DIR/config.conf" 2>/dev/null
    echo -e "${GREEN}[+] Contrasena: $NP${NC}"; press_enter; menu_vaydns
}

change_port() {
    [[ ! -f "$HY_CONFIG" ]] && echo -e "${RED}[!] No instalado${NC}" && press_enter && menu_vaydns && return
    echo -ne " ${WHITE}Nuevo puerto UDP: ${NC}"; read NP
    [[ ! "$NP" =~ ^[0-9]+$ ]] && echo -e "${RED}[!] Invalido${NC}" && press_enter && menu_vaydns && return
    python3 -c "
import json
with open('$HY_CONFIG') as f: d=json.load(f)
d['listen']=':$NP'
with open('$HY_CONFIG','w') as f: json.dump(d,f,indent=2)
"
    ufw allow "$NP/udp" 2>/dev/null; systemctl restart hysteria
    sed -i "s/^HY_PORT=.*/HY_PORT=$NP/" "$INSTALL_DIR/config.conf" 2>/dev/null
    echo -e "${GREEN}[+] Puerto: $NP${NC}"; press_enter; menu_vaydns
}

regen_cert() {
    echo -e "${YELLOW}[!] Esto genera una nueva Public Key — actualizar en la app.${NC}"
    echo -ne " Continuar? (s/N): "; read C
    [[ "$C" != "s" && "$C" != "S" ]] && menu_vaydns && return
    systemctl stop hysteria 2>/dev/null
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$HY_KEY" -out "$HY_CERT" -subj "/CN=gtkvpn" -days 3650 2>/dev/null
    chmod 600 "$HY_KEY"; systemctl start hysteria
    echo -e "${GREEN}[+] Certificado regenerado${NC}"; echo ""; show_app_config
}

uninstall_vaydns() {
    echo -ne "${RED}[!] Desinstalar VayDNS SSH? (s/N): ${NC}"; read C
    [[ "$C" != "s" && "$C" != "S" ]] && menu_vaydns && return
    systemctl stop hysteria 2>/dev/null; systemctl disable hysteria 2>/dev/null
    rm -f "$HY_SERVICE" "$HY_BIN" "$HY_CONFIG" "$HY_CERT" "$HY_KEY"
    systemctl daemon-reload
    sed -i '/^HY_PORT=/d; /^HY_PASS=/d' "$INSTALL_DIR/config.conf" 2>/dev/null
    echo -e "${GREEN}[+] Desinstalado${NC}"; press_enter; return
}

menu_vaydns
