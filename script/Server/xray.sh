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
    echo -e " ${WHITE}[2]${NC} Configurar VLESS (elegir transporte: ws / splithttp / grpc)"
    echo -e " ${WHITE}[3]${NC} Configurar VMess + WebSocket"
    echo -e " ${WHITE}[4]${NC} Ver config actual"
    echo -e " ${WHITE}[5]${NC} Ver usuarios registrados"
    echo -e " ${WHITE}[6]${NC} ${GREEN}Agregar usuario VLESS${NC}"
    echo -e " ${WHITE}[7]${NC} ${RED}Eliminar usuario${NC}"
    echo -e " ${WHITE}[8]${NC} ${CYAN}Aplicar configuracion manual${NC}"
    echo -e " ${WHITE}[9]${NC} Reiniciar Xray"
    echo -e " ${WHITE}[10]${NC} Ver logs Xray"
    echo -e " ${WHITE}[11]${NC} ${GREEN}Guardar config actual como plantilla${NC}"
    echo -e " ${WHITE}[12]${NC} ${CYAN}Aplicar plantilla guardada${NC}"
    echo -e " ${WHITE}[13]${NC} ${GREEN}Agregar inbound adicional (puerto/host independiente)${NC}"
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
        11) save_current_as_template ;; 12) apply_saved_template ;;
        13) add_xray_inbound ;;
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
    echo ""; echo -e "${CYAN}[ CONFIGURAR VLESS ]${NC}"; echo ""
    if [[ -f "$XRAY_CONFIG" ]]; then
        echo -e "${YELLOW}[!] Ya existe config con usuarios. Sobreescribir y perder todo? (s/n): ${NC}"
        read -r OVW
        [[ "$OVW" != "s" && "$OVW" != "S" ]] && { press_enter; menu_xray; return; }
    fi
    echo -ne " ${WHITE}Puerto VLESS (ej. 8081): ${NC}"; read VLESS_PORT
    [[ -z "$VLESS_PORT" ]] && VLESS_PORT=8081

    echo ""
    echo -e " ${WHITE}Tipo de transporte:${NC}"
    echo -e "   ${CYAN}[1]${NC} ws         — WebSocket clasico"
    echo -e "   ${CYAN}[2]${NC} splithttp  — mejor evasion DPI (recomendado)"
    echo -e "   ${CYAN}[3]${NC} grpc       — menos comun, mas overhead"
    echo -ne " ${WHITE}► Transporte (Enter = splithttp): ${NC}"; read NET_OPT
    case "$NET_OPT" in
        1) NETWORK="ws" ;;
        3) NETWORK="grpc" ;;
        *) NETWORK="splithttp" ;;
    esac

    HOSTS_INPUT=""; SERVICE_NAME=""; WS_PATH="/"
    if [[ "$NETWORK" == "grpc" ]]; then
        echo -ne " ${WHITE}Service Name gRPC (ej. grpc-service): ${NC}"; read SERVICE_NAME
        [[ -z "$SERVICE_NAME" ]] && SERVICE_NAME="grpc-service"
    else
        echo -ne " ${WHITE}Path (ej. /): ${NC}"; read WS_PATH
        [[ -z "$WS_PATH" ]] && WS_PATH="/"
        [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"
        echo -ne " ${WHITE}Host(s) de camuflaje, separados por espacio (opcional — Enter para omitir): ${NC}"
        read HOSTS_INPUT
    fi
    # array con todos los hosts escritos; el primero se usa en el config
    # del inbound, pero como Xray no valida el Host contra el que declara,
    # cualquiera de ellos funciona igual contra el mismo backend.
    read -ra HOSTS_ARR <<< "$HOSTS_INPUT"
    HOST_HEADER="${HOSTS_ARR[0]:-}"

    UUID=$(uuidgen); VPS_IP=$(curl -4 -s --max-time 5 ifconfig.me); [[ "$VPS_IP" == *:* ]] && VPS_IP="[$VPS_IP]"
    mkdir -p /usr/local/etc/xray

    python3 - "$XRAY_CONFIG" "$VLESS_PORT" "$UUID" "$NETWORK" "$WS_PATH" "$HOST_HEADER" "$SERVICE_NAME" << 'PYEOF'
import json, sys
cfg, port, uuid, network, path, host, svc = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]

stream = {"network": network}
if network == "ws":
    ws = {"path": path}
    if host:
        ws["headers"] = {"Host": host}
    stream["wsSettings"] = ws
elif network == "splithttp":
    sh = {"path": path}
    if host:
        sh["host"] = host
    stream["splithttpSettings"] = sh
elif network == "grpc":
    stream["grpcSettings"] = {"serviceName": svc}

config = {
    "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
    "inbounds": [{
        "port": port, "listen": "0.0.0.0", "protocol": "vless",
        "settings": {"clients": [{"id": uuid, "flow": "", "email": "admin@gtkvpn"}], "decryption": "none"},
        "streamSettings": stream,
        "sniffing": {"enabled": False},
        "tag": "vless-" + network
    }],
    "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}],
    "routing": {"rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}]}
}
with open(cfg, "w") as f:
    json.dump(config, f, indent=2)
print("OK")
PYEOF

    ufw allow "$VLESS_PORT/tcp" 2>/dev/null
    sed -i '/^XRAY_PORT=/d' $INSTALL_DIR/config.conf 2>/dev/null
    echo "XRAY_PORT=$VLESS_PORT" >> $INSTALL_DIR/config.conf
    sed -i '/^XRAY_HOSTS=/d' $INSTALL_DIR/config.conf 2>/dev/null
    echo "XRAY_HOSTS=${HOSTS_INPUT}" >> $INSTALL_DIR/config.conf
    sed -i "/^XRAY_HOSTS_${VLESS_PORT}=/d" $INSTALL_DIR/config.conf 2>/dev/null
    echo "XRAY_HOSTS_${VLESS_PORT}=${HOSTS_INPUT}" >> $INSTALL_DIR/config.conf
    systemctl enable xray 2>/dev/null; systemctl restart xray
    if systemctl is-active --quiet xray; then
        echo ""; echo -e "${GREEN}[+] VLESS configurado (transporte: $NETWORK)${NC}"
        echo -e "${WHITE}UUID:${NC} ${YELLOW}$UUID${NC}"
        echo -e "${WHITE}Link(s):${NC}"
        if [[ "$NETWORK" != "grpc" && ${#HOSTS_ARR[@]} -gt 0 ]]; then
            for H in "${HOSTS_ARR[@]}"; do
                LINK=$(python3 -c "
import urllib.parse
path = urllib.parse.quote('$WS_PATH')
h = '$H'
print(f'vless://$UUID@$VPS_IP:$VLESS_PORT?encryption=none&security=none&type=$NETWORK&path={path}&host=' + urllib.parse.quote(h) + f'#{h}-GTKVPN')
")
                echo -e "  ${CYAN}$LINK${NC}"
            done
        else
            LINK=$(python3 -c "
import urllib.parse
network = '$NETWORK'; path = urllib.parse.quote('$WS_PATH'); svc = urllib.parse.quote('$SERVICE_NAME')
base = f'vless://$UUID@$VPS_IP:$VLESS_PORT?encryption=none&security=none&type={network}'
if network in ('ws', 'splithttp'):
    base += f'&path={path}'
elif network == 'grpc':
    base += f'&serviceName={svc}'
print(base + '#admin-GTKVPN')
")
            echo -e "  ${CYAN}$LINK${NC}"
        fi
        mkdir -p $INSTALL_DIR/users
        printf "USERNAME=admin\nUUID=%s\nTYPE=xray-vless-%s\nCREATED=%s\nEXPIRY=9999-12-31\n" "$UUID" "$NETWORK" "$(date +%Y-%m-%d)" > "$INSTALL_DIR/users/admin_xray.info"
    else
        echo -e "${RED}[!] Error iniciando Xray:${NC}"; journalctl -u xray -n 10 --no-pager
    fi
    press_enter; menu_xray
}

# ── Guardar la config actual (ya funcionando) como plantilla reutilizable ─
# El puerto y el UUID se reemplazan por marcadores, para poder aplicarla
# en cualquier otro VPS pidiendo solo un puerto nuevo.
save_current_as_template() {
    echo ""; echo -e "${CYAN}[ GUARDAR CONFIG ACTUAL COMO PLANTILLA ]${NC}"; echo ""
    if ! check_config; then press_enter; menu_xray; return; fi
    echo -ne " ${WHITE}Nombre para la plantilla (ej. splithttp-tekmob): ${NC}"; read TPL_NAME
    [[ -z "$TPL_NAME" ]] && TPL_NAME="template-$(date +%s)"
    TPL_NAME=$(echo "$TPL_NAME" | tr -cd 'a-zA-Z0-9_-')
    mkdir -p "$INSTALL_DIR/xray-templates"
    python3 -c "
import json
with open('$XRAY_CONFIG') as f:
    c = json.load(f)
for ib in c.get('inbounds', []):
    ib['port'] = '__PORT__'
    for cl in ib.get('settings', {}).get('clients', []):
        cl['id'] = '__UUID__'
with open('$INSTALL_DIR/xray-templates/${TPL_NAME}.json', 'w') as f:
    json.dump(c, f, indent=2)
"
    echo -e "${GREEN}[+] Plantilla '${TPL_NAME}' guardada en $INSTALL_DIR/xray-templates/${NC}"
    echo -e "${CYAN}    Podras aplicarla en este u otro VPS desde la Opcion 12.${NC}"
    press_enter; menu_xray
}

# ── Aplicar una plantilla previamente guardada, con puerto/UUID nuevos ─
apply_saved_template() {
    echo ""; echo -e "${CYAN}[ APLICAR PLANTILLA GUARDADA ]${NC}"; echo ""
    mkdir -p "$INSTALL_DIR/xray-templates"
    TEMPLATES=("$INSTALL_DIR"/xray-templates/*.json)
    if [[ ! -e "${TEMPLATES[0]}" ]]; then
        echo -e "${YELLOW}No hay plantillas guardadas todavia.${NC}"
        echo -e "${YELLOW}Usa la Opcion 11 (o pega una config que funcione con la Opcion 8 y luego guardala).${NC}"
        press_enter; menu_xray; return
    fi
    echo -e "${WHITE}Plantillas disponibles:${NC}"
    local i=1
    for t in "${TEMPLATES[@]}"; do
        echo "  [$i] $(basename "$t" .json)"
        ((i++))
    done
    echo -ne " ${WHITE}► Elige numero: ${NC}"; read TPL_IDX
    SELECTED="${TEMPLATES[$((TPL_IDX-1))]}"
    if [[ ! -f "$SELECTED" ]]; then
        echo -e "${RED}[!] Opcion invalida.${NC}"; press_enter; menu_xray; return
    fi
    echo -ne " ${WHITE}Puerto a usar (Enter = 8081): ${NC}"; read APPLY_PORT
    [[ -z "$APPLY_PORT" ]] && APPLY_PORT=8081
    UUID=$(uuidgen); VPS_IP=$(curl -4 -s --max-time 5 ifconfig.me); [[ "$VPS_IP" == *:* ]] && VPS_IP="[$VPS_IP]"
    mkdir -p /usr/local/etc/xray
    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak"
    python3 -c "
import json
with open('$SELECTED') as f:
    c = json.load(f)
for ib in c.get('inbounds', []):
    ib['port'] = $APPLY_PORT
    for cl in ib.get('settings', {}).get('clients', []):
        cl['id'] = '$UUID'
with open('$XRAY_CONFIG', 'w') as f:
    json.dump(c, f, indent=2)
"
    ufw allow "$APPLY_PORT/tcp" 2>/dev/null
    sed -i '/^XRAY_PORT=/d' $INSTALL_DIR/config.conf 2>/dev/null
    echo "XRAY_PORT=$APPLY_PORT" >> $INSTALL_DIR/config.conf
    systemctl enable xray 2>/dev/null; systemctl restart xray
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}[+] Plantilla aplicada correctamente.${NC}"
        echo -e "${WHITE}Puerto:${NC} ${CYAN}$APPLY_PORT${NC}  ${WHITE}UUID:${NC} ${YELLOW}$UUID${NC}"
        mkdir -p $INSTALL_DIR/users
        printf "USERNAME=admin\nUUID=%s\nTYPE=xray-vless-template\nCREATED=%s\nEXPIRY=9999-12-31\n" "$UUID" "$(date +%Y-%m-%d)" > "$INSTALL_DIR/users/admin_xray.info"
    else
        echo -e "${RED}[!] Error iniciando Xray con la plantilla. Restaurando config anterior...${NC}"
        [[ -f "${XRAY_CONFIG}.bak" ]] && cp "${XRAY_CONFIG}.bak" "$XRAY_CONFIG" && systemctl restart xray
        journalctl -u xray -n 10 --no-pager
    fi
    press_enter; menu_xray
}
# ── Agregar un inbound VLESS adicional e independiente (nuevo puerto,   ─
# ── transporte y host propios) SIN tocar los inbounds que ya existen. ──
add_xray_inbound() {
    echo ""; echo -e "${CYAN}[ AGREGAR INBOUND ADICIONAL (independiente) ]${NC}"; echo ""
    if ! check_config; then press_enter; menu_xray; return; fi

    echo -ne " ${WHITE}Puerto nuevo (debe ser distinto a los existentes): ${NC}"; read NEW_PORT
    if [[ -z "$NEW_PORT" ]]; then
        echo -e "${RED}[!] Cancelado.${NC}"; press_enter; menu_xray; return
    fi
    PORT_TAKEN=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); print('yes' if any(str(i.get('port'))=='$NEW_PORT' for i in c.get('inbounds',[])) else 'no')" 2>/dev/null)
    if [[ "$PORT_TAKEN" == "yes" ]]; then
        echo -e "${RED}[!] Ese puerto ya esta en uso por otro inbound de este mismo Xray.${NC}"
        press_enter; menu_xray; return
    fi

    echo ""
    echo -e " ${WHITE}Tipo de transporte:${NC}"
    echo -e "   ${CYAN}[1]${NC} ws"
    echo -e "   ${CYAN}[2]${NC} splithttp"
    echo -e "   ${CYAN}[3]${NC} grpc"
    echo -ne " ${WHITE}► Transporte (Enter = splithttp): ${NC}"; read NET_OPT
    case "$NET_OPT" in
        1) NETWORK="ws" ;;
        3) NETWORK="grpc" ;;
        *) NETWORK="splithttp" ;;
    esac

    HOSTS_INPUT=""; SERVICE_NAME=""; WS_PATH="/"
    if [[ "$NETWORK" == "grpc" ]]; then
        echo -ne " ${WHITE}Service Name gRPC (ej. grpc-service): ${NC}"; read SERVICE_NAME
        [[ -z "$SERVICE_NAME" ]] && SERVICE_NAME="grpc-service"
    else
        echo -ne " ${WHITE}Path (ej. /): ${NC}"; read WS_PATH
        [[ -z "$WS_PATH" ]] && WS_PATH="/"
        [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"
        echo -ne " ${WHITE}Host(s) de camuflaje, separados por espacio (opcional): ${NC}"; read HOSTS_INPUT
    fi
    read -ra HOSTS_ARR <<< "$HOSTS_INPUT"
    HOST_HEADER="${HOSTS_ARR[0]:-}"

    echo -ne " ${WHITE}Nombre de usuario para este inbound (ej. admin2): ${NC}"; read USERNAME
    [[ -z "$USERNAME" ]] && USERNAME="admin"

    NEW_UUID=$(uuidgen); VPS_IP=$(curl -4 -s --max-time 5 ifconfig.me); [[ "$VPS_IP" == *:* ]] && VPS_IP="[$VPS_IP]"

    RESULT=$(python3 - "$XRAY_CONFIG" "$NEW_PORT" "$NEW_UUID" "$NETWORK" "$WS_PATH" "$HOST_HEADER" "$SERVICE_NAME" "${USERNAME}@gtkvpn" << 'PYEOF'
import json, sys
cfg, port, uuid, network, path, host, svc, email = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
with open(cfg) as f:
    config = json.load(f)

stream = {"network": network}
if network == "ws":
    ws = {"path": path}
    if host:
        ws["headers"] = {"Host": host}
    stream["wsSettings"] = ws
elif network == "splithttp":
    sh = {"path": path}
    if host:
        sh["host"] = host
    stream["splithttpSettings"] = sh
elif network == "grpc":
    stream["grpcSettings"] = {"serviceName": svc}

tag = f"vless-{network}-{port}"
config.setdefault("inbounds", []).append({
    "port": port, "listen": "0.0.0.0", "protocol": "vless",
    "settings": {"clients": [{"id": uuid, "flow": "", "email": email}], "decryption": "none"},
    "streamSettings": stream,
    "sniffing": {"enabled": False},
    "tag": tag
})
with open(cfg, "w") as f:
    json.dump(config, f, indent=2)
print("OK")
PYEOF
)
    if [[ "$RESULT" != "OK" ]]; then
        echo -e "${RED}[!] Error al agregar el inbound.${NC}"; press_enter; menu_xray; return
    fi

    ufw allow "$NEW_PORT/tcp" 2>/dev/null
    sed -i "/^XRAY_HOSTS_${NEW_PORT}=/d" $INSTALL_DIR/config.conf 2>/dev/null
    echo "XRAY_HOSTS_${NEW_PORT}=${HOSTS_INPUT}" >> $INSTALL_DIR/config.conf

    systemctl restart xray
    if systemctl is-active --quiet xray; then
        echo ""; echo -e "${GREEN}[+] Inbound adicional creado en puerto $NEW_PORT (transporte: $NETWORK)${NC}"
        echo -e "${WHITE}Los inbounds anteriores siguen activos sin cambios.${NC}"
        echo -e "${WHITE}UUID:${NC} ${YELLOW}$NEW_UUID${NC}"
        echo -e "${WHITE}Link(s):${NC}"
        if [[ "$NETWORK" != "grpc" && ${#HOSTS_ARR[@]} -gt 0 ]]; then
            for H in "${HOSTS_ARR[@]}"; do
                LINK=$(python3 -c "
import urllib.parse
path = urllib.parse.quote('$WS_PATH')
h = '$H'
print(f'vless://$NEW_UUID@$VPS_IP:$NEW_PORT?encryption=none&security=none&type=$NETWORK&path={path}&host=' + urllib.parse.quote(h) + f'#${USERNAME}-{h}-GTKVPN')
")
                echo -e "  ${CYAN}$LINK${NC}"
            done
        else
            LINK=$(python3 -c "
import urllib.parse
network = '$NETWORK'; path = urllib.parse.quote('$WS_PATH'); svc = urllib.parse.quote('$SERVICE_NAME')
base = f'vless://$NEW_UUID@$VPS_IP:$NEW_PORT?encryption=none&security=none&type={network}'
if network in ('ws', 'splithttp'):
    base += f'&path={path}'
elif network == 'grpc':
    base += f'&serviceName={svc}'
print(base + '#${USERNAME}-GTKVPN')
")
            echo -e "  ${CYAN}$LINK${NC}"
        fi
        mkdir -p $INSTALL_DIR/users
        printf "USERNAME=%s\nUUID=%s\nTYPE=xray-vless-%s\nCREATED=%s\nEXPIRY=9999-12-31\n" "$USERNAME" "$NEW_UUID" "$NETWORK" "$(date +%Y-%m-%d)" > "$INSTALL_DIR/users/${USERNAME}_xray.info"
    else
        echo -e "${RED}[!] Error iniciando Xray con el nuevo inbound. Revisa: journalctl -u xray -n 20${NC}"
        echo -e "${YELLOW}    (el inbound quedo agregado en config.json; revisa que el puerto no choque con otro servicio)${NC}"
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
    UUID=$(uuidgen); VPS_IP=$(curl -4 -s --max-time 5 ifconfig.me); [[ "$VPS_IP" == *:* ]] && VPS_IP="[$VPS_IP]"
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
    VLESS_PORTS=($(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); [print(i['port']) for i in c.get('inbounds',[]) if i.get('protocol')=='vless']" 2>/dev/null))
    if [[ ${#VLESS_PORTS[@]} -eq 0 ]]; then
        echo -e "${RED}[!] No hay inbound VLESS. Usa Opcion 2 primero.${NC}"; press_enter; menu_xray; return
    fi
    TARGET_PORT="${VLESS_PORTS[0]}"
    if [[ ${#VLESS_PORTS[@]} -gt 1 ]]; then
        echo -e "${WHITE}Hay varios inbounds VLESS activos:${NC}"
        local i=1
        for p in "${VLESS_PORTS[@]}"; do
            NET=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); [print(i.get('streamSettings',{}).get('network','ws')) for i in c.get('inbounds',[]) if i.get('protocol')=='vless' and i.get('port')==$p]" 2>/dev/null | head -1)
            echo "  [$i] puerto $p ($NET)"
            ((i++))
        done
        echo -ne " ${WHITE}► ¿A cual agregar el usuario? (Enter = puerto ${VLESS_PORTS[0]}): ${NC}"; read PORT_IDX
        if [[ -n "$PORT_IDX" && "$PORT_IDX" =~ ^[0-9]+$ && "$PORT_IDX" -ge 1 && "$PORT_IDX" -le ${#VLESS_PORTS[@]} ]]; then
            TARGET_PORT="${VLESS_PORTS[$((PORT_IDX-1))]}"
        fi
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
    NEW_UUID=$(uuidgen); VPS_IP=$(curl -4 -s --max-time 5 ifconfig.me); [[ "$VPS_IP" == *:* ]] && VPS_IP="[$VPS_IP]"
    RESULT=$(python3 - "$XRAY_CONFIG" "$NEW_UUID" "${USERNAME}@gtkvpn" "$TARGET_PORT" << 'PYEOF'
import json, sys
cfg, uid, email, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(cfg) as f: config = json.load(f)
for ib in config.get('inbounds',[]):
    if ib.get('protocol') == 'vless' and ib.get('port') == port:
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
    VLESS_PORT="$TARGET_PORT"
    NETWORK=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); [print(i.get('streamSettings',{}).get('network','ws')) for i in c.get('inbounds',[]) if i.get('protocol')=='vless' and i.get('port')==$TARGET_PORT]" 2>/dev/null | head -1)
    case "$NETWORK" in
        splithttp) WS_PATH=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); [print(i.get('streamSettings',{}).get('splithttpSettings',{}).get('path','/')) for i in c.get('inbounds',[]) if i.get('protocol')=='vless' and i.get('port')==$TARGET_PORT]" 2>/dev/null | head -1) ;;
        grpc)      SERVICE_NAME=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); [print(i.get('streamSettings',{}).get('grpcSettings',{}).get('serviceName','')) for i in c.get('inbounds',[]) if i.get('protocol')=='vless' and i.get('port')==$TARGET_PORT]" 2>/dev/null | head -1) ;;
        *)         WS_PATH=$(python3 -c "import json; c=json.load(open('$XRAY_CONFIG')); [print(i.get('streamSettings',{}).get('wsSettings',{}).get('path','/')) for i in c.get('inbounds',[]) if i.get('protocol')=='vless' and i.get('port')==$TARGET_PORT]" 2>/dev/null | head -1) ;;
    esac

    # Reutiliza los hosts guardados para ESE puerto especifico (Opcion 2/13);
    # si no hay entrada por-puerto, cae al XRAY_HOSTS generico (config original)
    SAVED_HOSTS=$(grep "^XRAY_HOSTS_${TARGET_PORT}=" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2-)
    [[ -z "$SAVED_HOSTS" ]] && SAVED_HOSTS=$(grep "^XRAY_HOSTS=" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2-)
    read -ra HOSTS_ARR <<< "$SAVED_HOSTS"

    LINKS=()
    if [[ "$NETWORK" != "grpc" && ${#HOSTS_ARR[@]} -gt 0 ]]; then
        for H in "${HOSTS_ARR[@]}"; do
            LINKS+=("$(python3 -c "
import urllib.parse
path = urllib.parse.quote('$WS_PATH')
h = '$H'
print(f'vless://$NEW_UUID@$VPS_IP:$VLESS_PORT?encryption=none&security=none&type=$NETWORK&path={path}&host=' + urllib.parse.quote(h) + f'#${USERNAME}-{h}-GTKVPN')
")")
        done
    else
        LINKS+=("$(python3 -c "
import urllib.parse
network = '$NETWORK'; path = urllib.parse.quote('$WS_PATH'); svc = urllib.parse.quote('$SERVICE_NAME')
base = f'vless://$NEW_UUID@$VPS_IP:$VLESS_PORT?encryption=none&security=none&type={network}'
if network in ('ws', 'splithttp'):
    base += f'&path={path}'
elif network == 'grpc':
    base += f'&serviceName={svc}'
print(base + '#${USERNAME}-GTKVPN')
")")
    fi
    echo ""; echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         USUARIO AGREGADO EXITOSAMENTE ✓                  ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Usuario:${NC} ${CYAN}${USERNAME}${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}UUID:${NC}    ${YELLOW}${NEW_UUID}${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Puerto:${NC}  ${CYAN}${VLESS_PORT}${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Link(s) VLESS:${NC}"
    for LINK in "${LINKS[@]}"; do
        echo -e " ${CYAN}$LINK${NC}"
    done
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
