#!/bin/bash
# ============================================================
#   GTKVPN - Módulo Xray (VLESS/VMess/Trojan)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

menu_xray() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                  ⚡ MÓDULO XRAY${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    XRAY_ST=$(systemctl is-active --quiet xray 2>/dev/null && echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")
    XRAY_PORT=$(grep "XRAY_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "N/A")
    
    echo -e " ${WHITE}Estado Xray:${NC} $XRAY_ST"
    echo -e " ${WHITE}Puerto actual:${NC} ${CYAN}$XRAY_PORT${NC}"
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar/Reinstalar Xray"
    echo -e " ${WHITE}[2]${NC} Configurar VLESS + WebSocket"
    echo -e " ${WHITE}[3]${NC} Configurar VMess + WebSocket"
    echo -e " ${WHITE}[4]${NC} Ver config actual"
    echo -e " ${WHITE}[5]${NC} Ver usuarios registrados"
    echo -e " ${WHITE}[6]${NC} Reiniciar Xray"
    echo -e " ${WHITE}[7]${NC} Ver logs Xray"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT
    
    case $OPT in
        1) install_xray ;;
        2) setup_vless ;;
        3) setup_vmess ;;
        4) cat $XRAY_CONFIG 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "Sin config"; press_enter; menu_xray ;;
        5) list_xray_users ;;
        6) systemctl restart xray; echo -e "${GREEN}[+] Xray reiniciado${NC}"; sleep 1; menu_xray ;;
        7) journalctl -u xray -n 30 --no-pager; press_enter; menu_xray ;;
        0) return ;;
        *) menu_xray ;;
    esac
}

install_xray() {
    echo ""
    echo -e "${CYAN}[*] Instalando Xray...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root 2>/dev/null
    
    if [[ -f /usr/local/bin/xray ]]; then
        echo -e "${GREEN}[+] Xray instalado: $(/usr/local/bin/xray version | head -1)${NC}"
        mkdir -p /var/log/xray
        setup_vless
    else
        echo -e "${RED}[!] Error instalando Xray${NC}"
        press_enter
        menu_xray
    fi
}

setup_vless() {
    echo ""
    echo -e "${CYAN}[ CONFIGURAR VLESS + WebSocket ]${NC}"
    echo ""
    echo -ne " ${WHITE}Puerto VLESS (ej. 32595): ${NC}"; read VLESS_PORT
    [[ -z "$VLESS_PORT" ]] && VLESS_PORT=32595
    
    echo -ne " ${WHITE}Path WebSocket (ej. / o /vless): ${NC}"; read WS_PATH
    [[ -z "$WS_PATH" ]] && WS_PATH="/"
    [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"
    
    # UUID inicial para el primer usuario
    UUID=$(uuidgen)
    VPS_IP=$(curl -s --max-time 3 ifconfig.me)
    
    # Crear config Xray con VLESS + VMess
    mkdir -p /usr/local/etc/xray
    cat > $XRAY_CONFIG << XCONF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "",
            "email": "admin@gtkvpn"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH",
          "headers": {}
        }
      },
      "tag": "vless-ws"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
XCONF
    
    # Abrir puerto en UFW
    ufw allow "$VLESS_PORT/tcp" 2>/dev/null
    
    # Guardar en config
    sed -i '/^XRAY_PORT=/d' $INSTALL_DIR/config.conf 2>/dev/null
    sed -i '/^XRAY_WS_PATH=/d' $INSTALL_DIR/config.conf 2>/dev/null
    sed -i "/^XRAY_PORT=/d" $INSTALL_DIR/config.conf && echo "XRAY_PORT=$VLESS_PORT" >> $INSTALL_DIR/config.conf
    sed -i "/^XRAY_WS_PATH=/d" $INSTALL_DIR/config.conf && echo "XRAY_WS_PATH=$WS_PATH" >> $INSTALL_DIR/config.conf
    
    systemctl enable xray 2>/dev/null
    systemctl restart xray
    
    if systemctl is-active --quiet xray; then
        # Generar link VLESS para el admin
        VLESS_LINK="vless://${UUID}@${VPS_IP}:${VLESS_PORT}?type=ws&encryption=none&path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$WS_PATH'))")&security=none#admin-GTKVPN"
        
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║           XRAY VLESS CONFIGURADO ✓                   ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}IP:${NC}      ${CYAN}$VPS_IP${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Puerto:${NC}  ${CYAN}$VLESS_PORT${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Path:${NC}    ${CYAN}$WS_PATH${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}UUID:${NC}    ${YELLOW}$UUID${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} ${WHITE}Link VLESS Admin:${NC}"
        echo -e " ${CYAN}$VLESS_LINK${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
        
        # Guardar user admin
        mkdir -p $INSTALL_DIR/users
        cat > $INSTALL_DIR/users/admin_xray.info << INFO
USERNAME=admin
UUID=$UUID
TYPE=xray
CREATED=$(date +%Y-%m-%d)
EXPIRY=9999-12-31
INFO
    else
        echo -e "${RED}[!] Error iniciando Xray. Ver logs:${NC}"
        journalctl -u xray -n 10 --no-pager
    fi
    
    press_enter
    menu_xray
}

setup_vmess() {
    echo ""
    echo -e "${CYAN}[ AGREGAR VMESS al config actual ]${NC}"
    echo ""
    
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}[!] Configura VLESS primero${NC}"; press_enter; menu_xray; return
    fi
    
    echo -ne " ${WHITE}Puerto VMess (ej. 11111): ${NC}"; read VMESS_PORT
    [[ -z "$VMESS_PORT" ]] && VMESS_PORT=11111
    
    echo -ne " ${WHITE}Path WebSocket (ej. /vmess): ${NC}"; read WS_PATH
    [[ -z "$WS_PATH" ]] && WS_PATH="/vmess"
    [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"
    
    UUID=$(uuidgen)
    VPS_IP=$(curl -s --max-time 3 ifconfig.me)
    
    # Agregar inbound VMess al config existente usando python3
    python3 << PYEOF
import json

with open('$XRAY_CONFIG', 'r') as f:
    config = json.load(f)

vmess_inbound = {
    "port": $VMESS_PORT,
    "listen": "0.0.0.0",
    "protocol": "vmess",
    "settings": {
        "clients": [
            {
                "id": "$UUID",
                "alterId": 0,
                "security": "auto",
                "email": "admin-vmess@gtkvpn"
            }
        ]
    },
    "streamSettings": {
        "network": "ws",
        "wsSettings": {
            "path": "$WS_PATH",
            "headers": {}
        }
    },
    "tag": "vmess-ws"
}

config['inbounds'].append(vmess_inbound)

with open('$XRAY_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)

print("OK")
PYEOF
    
    ufw allow "$VMESS_PORT/tcp" 2>/dev/null
    systemctl restart xray
    
    echo -e "${GREEN}[+] VMess configurado en puerto $VMESS_PORT${NC}"
    echo -e "${WHITE}UUID: ${CYAN}$UUID${NC}"
    press_enter
    menu_xray
}

list_xray_users() {
    echo ""
    echo -e "${CYAN}[ USUARIOS XRAY ]${NC}"
    echo ""
    
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}[!] Xray no configurado${NC}"; press_enter; menu_xray; return
    fi
    
    python3 << 'PYEOF'
import json

with open('/usr/local/etc/xray/config.json', 'r') as f:
    config = json.load(f)

print(f"{'PROTOCOLO':<12} {'EMAIL':<25} {'UUID'}")
print("-" * 80)
for inbound in config.get('inbounds', []):
    proto = inbound.get('protocol', '?')
    settings = inbound.get('settings', {})
    clients = settings.get('clients', [])
    for c in clients:
        email = c.get('email', 'N/A')
        uid = c.get('id', 'N/A')
        print(f"{proto:<12} {email:<25} {uid}")
PYEOF
    
    press_enter
    menu_xray
}

menu_xray
