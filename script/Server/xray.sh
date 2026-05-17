#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
INSTALL_DIR="/etc/gtkvpn"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }
check_config() {
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}[!] config.json no existe. Usa Opcion 2 para configurar.${NC}"; return 1
    fi
    if ! python3 -c "import json; json.load(open('$XRAY_CONFIG'))" 2>/dev/null; then
        echo -e "${RED}[!] config.json vacío o corrupto.${NC}"; cat "$XRAY_CONFIG"; echo ""
        echo -ne "${YELLOW}¿Recrear config VLESS desde cero? (s/n): ${NC}"; read -r R
        [[ "$R" == "s" || "$R" == "S" ]] && setup_vless && return 0; return 1
    fi
    return 0
}
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
    echo -e " ${WHITE}[6]${NC} ${GREEN}Agregar usuario VLESS${NC}"
    echo -e " ${WHITE}[7]${NC} ${RED}Eliminar usuario${NC}"
    echo -e " ${WHITE}[8]${NC} ${CYAN}Aplicar configuracion manual${NC}"
    echo -e " ${WHITE}[9]${NC} Reiniciar Xray"
    echo -e " ${WHITE}[10]${NC} Ver logs Xray"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "; read OPT
    case $OPT in
        1) install_xray ;; 2) setup_vless ;; 3) setup_vmess ;;
        4) view_config ;; 5) list_xray_users ;; 6) add_xray_user ;;
        7) delete_xray_user ;; 8) apply_manual_config ;;
        9) systemctl restart xray; echo -e "${GREEN}[+] Xray reiniciado${NC}"; sleep 1; menu_xray ;;
        10) journalctl -u xray -n 30 --no-pager; press_enter; menu_xray ;;
        0) return ;; *) menu_xray ;;
    esac
}
view_config() {
    echo ""; check_config && python3 -m json.tool "$XRAY_CONFIG"
    press_enter; menu_xray
}
apply_manual_config() {
    echo ""
    echo -e "${CYAN}[ APLICAR CONFIGURACION MANUAL ]${NC}"
    echo ""
    echo -e "${YELLOW}Pega tu JSON y presiona ENTER,"
    echo -e "luego escribe FIN en una linea sola y presiona ENTER:${NC}"
    echo ""
    JSON_INPUT=""
    while IFS= read -r line; do
        [[ "$line" == "FIN" ]] && break
        JSON_INPUT+="$line"$'\n'
    done
    if [[ -z "$JSON_INPUT" ]]; then
        echo -e "${RED}[!] No pegaste nada. Cancelado.${NC}"; press_enter; menu_xray; return
    fi
    echo "$JSON_INPUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[!] JSON inválido. Verifica el formato.${NC}"; press_enter; menu_xray; return
    fi
    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak"
    mkdir -p /usr/local/etc/xray
    echo "$JSON_INPUT" > "$XRAY_CONFIG"
    systemctl restart xray
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}[+] Configuracion aplicada y Xray reiniciado exitosamente.${NC}"
        echo ""
        echo -e "${WHITE}Usuarios detectados:${NC}"
        python3 - "$XRAY_CONFIG" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: config = json.load(f)
print(f"{'#':<4} {'PUERTO':<8} {'EMAIL':<28} UUID"); print("─"*80)
idx=1
for ib in config.get('inbounds',[]):
    for c in ib.get('settings',{}).get('clients',[]):
        print(f"{idx:<4} {str(ib.get('port','?')):<8} {c.get('email','N/A'):<28} {c.get('id','N/A')}"); idx+=1
print(f"\nTotal: {idx-1} usuario(s)")
PYEOF
    else
        echo -e "${RED}[!] Error iniciando Xray. Restaurando backup...${NC}"
        [[ -f "${XRAY_CONFIG}.bak" ]] && cp "${XRAY_CONFIG}.bak" "$XRAY_CONFIG" && systemctl restart xray
        journalctl -u xray -n 10 --no-pager
    fi
    press_enter; menu_xray
}
install_xray() {
    echo ""; echo -e "${CYAN}[*] Instalando Xray...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root 2>/dev/null
    if [[ -f /usr/local/bin/xray ]]; then
        echo -e "${GREEN}[+] Xray instalado: $(/usr/local/bin/xray version | head -1)${NC}"
        mkdir -p /var/log/xray; setup_vless
    else
        echo -e "${RED}[!] Error instalando Xray${NC}"; press_enter; menu_xray
    fi
}
setup_vless() {
    echo ""; echo -e "${CYAN}[ CONFIGURAR VLESS + WebSocket ]${NC}"; echo ""
    if [[ -f "$XRAY_CONFIG" ]]; then
        echo -e "${YELLOW}[!] Ya existe config con usuarios. Sobreescribir y perder todo? (s/n): ${NC}"
        read -r OVW
        [[ "$OVW" != "s" && "$OVW" != "S" ]] && { press_enter; menu_xray; return; }
    fi
    echo -ne " ${WHITE}Puerto VLESS (ej. 8081): ${NC}"; read VLESS_PORT
    [[ -z "$VLESS_PORT" ]] && VLESS_PORT=8081
    echo -ne " ${WHITE}Path WebSocket (ej. /): ${NC}"; read WS_PATH
    [[ -z "$WS_PATH" ]] && WS_PATH="/"
    [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"
    UUID=$(uuidgen); VPS_IP=$(curl -s --max-time 5 ifconfig.me)
    mkdir -p /usr/local/etc/xray
    cat > "$XRAY_CONFIG" <<XCONF
{
  "log": {"loglevel":"warning","access":"/var/log/xray/access.log","error":"/var/log/xray/error.log"},
  "inbounds": [
    {
      "port": $VLESS_PORT, "listen": "0.0.0.0", "protocol": "vless",
      "settings": {"clients": [{"id": "$UUID","flow": "","email": "admin@gtkvpn"}],"decryption": "none"},
      "streamSettings": {"network": "ws","wsSettings": {"path": "$WS_PATH","headers": {}}},"tag": "vless-ws"
    }
  ],
  "outbounds": [{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}],
  "routing": {"rules": [{"type":"field","ip":["geoip:private"],"outboundTag":"block"}]}
}
XCONF
    ufw allow "$VLESS_PORT/tcp" 2>/dev/null
    sed -i '/^XRAY_PORT=/d' $INSTALL_DIR/config.conf 2>/dev/null
    echo "XRAY_PORT=$VLESS_PORT" >> $INSTALL_DIR/config.conf
    systemctl enable xray 2>/dev/null; systemctl restart xray
    if systemctl is-active --quiet xray; then
        WS_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$WS_PATH'))")
        LINK="vless://${UUID}@${VPS_IP}:${VLESS_PORT}?type=ws&encryption=none&path=${WS_ENC}&security=none#admin-GTKVPN"
        echo ""; echo -e "${GREEN}[+] VLESS configurado${NC}"
        echo -e "${WHITE}UUID:${NC} ${YELLOW}$UUID${NC}"
        echo -e "${WHITE}Link:${NC} ${CYAN}$LINK${NC}"
        mkdir -p $INSTALL_DIR/users
        printf "USERNAME=admin\nUUID=%s\nTYPE=xray-vless\nCREATED=%s\nEXPIRY=9999-12-31\n" "$UUID" "$(date +%Y-%m-%d)" > "$INSTALL_DIR/users/admin_xray.info"
    else
        echo -e "${RED}[!] Error iniciando Xray:${NC}"; journalctl -u xray -n 10 --no-pager
    fi
    press_enter; menu_xray
}
setup_vmess() {
    echo ""; echo -e "${CYAN}[ AGREGAR VMESS ]${NC}"; echo ""
    if ! check_config; then press_enter; menu_xray; return; fi
    echo -ne " ${WHITE}Puerto VMess (ej. 11111): ${NC}"; read VMESS_PORT
    [[ -z "$VMESS_PORT" ]] && VMESS_PORT=11111
    echo -ne " ${WHITE}Path WebSocket (ej. /vmess): ${NC}"; read WS_PATH
    [[ -z "$WS_PATH" ]] && WS_PATH="/vmess"
    [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"
    UUID=$(uuidgen); VPS_IP=$(curl -s --max-time 5 ifconfig.me)
    python3 - "$XRAY_CONFIG" "$VMESS_PORT" "$UUID" "$WS_PATH" << 'PYEOF'
import json, sys
cfg, port, uuid, wspath = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(cfg) as f: config = json.load(f)
config['inbounds'] = [i for i in config.get('inbounds',[]) if i.get('tag') != 'vmess-ws']
config['inbounds'].append({"port":port,"listen":"0.0.0.0","protocol":"vmess","settings":{"clients":[{"id":uuid,"alterId":0,"security":"auto","email":"admin-vmess@gtkvpn"}]},"streamSettings":{"network":"ws","wsSettings":{"path":wspath,"headers":{}}},"tag":"vmess-ws"})
with open(cfg,'w') as f: json.dump(config, f, indent=2)
print("OK")
PYEOF
    ufw allow "$VMESS_PORT/tcp" 2>/dev/null; systemctl restart xray
    echo -e "${GREEN}[+] VMess en puerto $VMESS_PORT | UUID: ${CYAN}$UUID${NC}"
    press_enter; menu_xray
}
list_xray_users() {
    echo ""; echo -e "${CYAN}[ USUARIOS XRAY ]${NC}"; echo ""
    if ! check_config; then press_enter; menu_xray; return; fi
    python3 - "$XRAY_CONFIG" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: config = json.load(f)
ibs = config.get('inbounds',[])
if not ibs: print("No hay inbounds configurados.")
else:
    print(f"{'#':<4} {'PROTO':<10} {'PUERTO':<8} {'EMAIL':<28} UUID"); print("─"*90)
    idx=1
    for ib in ibs:
        for c in ib.get('settings',{}).get('clients',[]):
            print(f"{idx:<4} {ib.get('protocol','?'):<10} {str(ib.get('port','?')):<8} {c.get('email','N/A'):<28} {c.get('id','N/A')}"); idx+=1
    print(f"\nTotal: {idx-1} cliente(s)")
PYEOF
    press_enter; menu_xray
}
add_xray_user() {
    echo ""; echo -e "${CYAN}[ AGREGAR USUARIO VLESS ]${NC}"; echo ""
    if ! check_config; then press_enter; menu_xray; return; fi
    VLESS_EXISTS=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); print('yes' if any(i.get('protocol')=='vless' for i in c.get('inbounds',[])) else 'no')" 2>/dev/null)
    if [[ "$VLESS_EXISTS" != "yes" ]]; then
        echo -e "${RED}[!] No hay inbound VLESS. Usa Opcion 2 primero.${NC}"; press_enter; menu_xray; return
    fi
    echo -ne " ${WHITE}Nombre del usuario (ej. user1): ${NC}"; read USERNAME
    [[ -z "$USERNAME" ]] && { echo -e "${RED}[!] Cancelado.${NC}"; press_enter; menu_xray; return; }
    EXISTS=$(python3 -c "
import json
c=json.load(open('$XRAY_CONFIG'))
emails=[cl.get('email','') for i in c.get('inbounds',[]) for cl in i.get('settings',{}).get('clients',[])]
print('yes' if '${USERNAME}@gtkvpn' in emails else 'no')
" 2>/dev/null)
    if [[ "$EXISTS" == "yes" ]]; then
        echo -e "${RED}[!] Usuario '${USERNAME}' ya existe.${NC}"; press_enter; menu_xray; return
    fi
    NEW_UUID=$(uuidgen); VPS_IP=$(curl -s --max-time 5 ifconfig.me)
    RESULT=$(python3 - "$XRAY_CONFIG" "$NEW_UUID" "${USERNAME}@gtkvpn" << 'PYEOF'
import json, sys
cfg, uid, email = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cfg) as f: config = json.load(f)
for ib in config.get('inbounds',[]):
    if ib.get('protocol') == 'vless':
        ib.setdefault('settings',{}).setdefault('clients',[]).append({"id":uid,"flow":"","email":email})
        with open(cfg,'w') as f: json.dump(config, f, indent=2)
        print("OK"); break
else: print("ERROR"); exit(1)
PYEOF
)
    if [[ "$RESULT" != "OK" ]]; then
        echo -e "${RED}[!] Error al agregar usuario.${NC}"; press_enter; menu_xray; return
    fi
    systemctl restart xray
    VLESS_PORT=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); [print(i['port']) for i in c.get('inbounds',[]) if i.get('protocol')=='vless']" 2>/dev/null | head -1)
    WS_PATH=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); [print(i.get('streamSettings',{}).get('wsSettings',{}).get('path','/')) for i in c.get('inbounds',[]) if i.get('protocol')=='vless']" 2>/dev/null | head -1)
    WS_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$WS_PATH'))")
    LINK="vless://${NEW_UUID}@${VPS_IP}:${VLESS_PORT}?type=ws&encryption=none&path=${WS_ENC}&security=none#${USERNAME}-GTKVPN"
    echo ""; echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         USUARIO AGREGADO EXITOSAMENTE ✓                  ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Usuario:${NC} ${CYAN}${USERNAME}${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}UUID:${NC}    ${YELLOW}${NEW_UUID}${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Puerto:${NC}  ${CYAN}${VLESS_PORT}${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Link VLESS:${NC}"; echo -e " ${CYAN}$LINK${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    mkdir -p $INSTALL_DIR/users
    printf "USERNAME=%s\nUUID=%s\nTYPE=xray-vless\nCREATED=%s\nEXPIRY=9999-12-31\n" "$USERNAME" "$NEW_UUID" "$(date +%Y-%m-%d)" > "$INSTALL_DIR/users/${USERNAME}_xray.info"
    press_enter; menu_xray
}
delete_xray_user() {
    echo ""; echo -e "${CYAN}[ ELIMINAR USUARIO XRAY ]${NC}"; echo ""
    if ! check_config; then press_enter; menu_xray; return; fi
    python3 - "$XRAY_CONFIG" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f: config = json.load(f)
print(f"{'#':<4} {'PROTO':<10} {'EMAIL':<30} UUID"); print("─"*80)
idx=1
for ib in config.get('inbounds',[]):
    for c in ib.get('settings',{}).get('clients',[]):
        print(f"{idx:<4} {ib.get('protocol','?'):<10} {c.get('email','N/A'):<30} {c.get('id','N/A')}"); idx+=1
PYEOF
    echo ""
    echo -ne " ${WHITE}Email a eliminar (ej. user1@gtkvpn): ${NC}"; read DEL_EMAIL
    [[ -z "$DEL_EMAIL" ]] && { echo -e "${RED}Cancelado.${NC}"; press_enter; menu_xray; return; }
    echo -ne " ${YELLOW}¿Confirmas eliminar '${DEL_EMAIL}'? (s/n): ${NC}"; read CONFIRM
    [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]] && { echo -e "${YELLOW}Cancelado.${NC}"; press_enter; menu_xray; return; }
    RESULT=$(python3 - "$XRAY_CONFIG" "$DEL_EMAIL" << 'PYEOF'
import json, sys
cfg, email = sys.argv[1], sys.argv[2]
with open(cfg) as f: config = json.load(f)
removed = False
for ib in config.get('inbounds',[]):
    clients = ib.get('settings',{}).get('clients',[])
    new = [c for c in clients if c.get('email') != email]
    if len(new) < len(clients): ib['settings']['clients'] = new; removed = True
if removed:
    with open(cfg,'w') as f: json.dump(config, f, indent=2); print("OK")
else: print("NOTFOUND"); exit(1)
PYEOF
)
    if [[ "$RESULT" == "OK" ]]; then
        systemctl restart xray
        echo -e "${GREEN}[+] '${DEL_EMAIL}' eliminado. Xray reiniciado.${NC}"
        rm -f "$INSTALL_DIR/users/$(echo $DEL_EMAIL | cut -d@ -f1)_xray.info" 2>/dev/null
    else
        echo -e "${RED}[!] Usuario '${DEL_EMAIL}' no encontrado.${NC}"
    fi
    press_enter; menu_xray
}
menu_xray
