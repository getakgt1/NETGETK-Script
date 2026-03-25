#!/bin/bash
# ============================================================
#   GTKVPN - Gestión de Usuarios SSH / Xray
#   FIX: Expiración, limpieza Xray, límite de conexiones,
#        renovar Xray, validación de días, log de acciones
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
USERS_DIR="$INSTALL_DIR/users"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
LOG_FILE="/var/log/gtkvpn/usuarios.log"

press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

# --------- LOG ------------------------------------------------------------------------------------------------------------------------------------------------------------------
log_action() {
    mkdir -p "$(dirname $LOG_FILE)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# --------- VALIDAR DÍAS ---------------------------------------------------------------------------------------------------------------------------------------
# BUG FIX: El script original no validaba que DIAS sea un número
# Podía recibir texto vacío o no numérico y romper la fecha
validar_dias() {
    local dias="$1"
    [[ -z "$dias" ]] && dias=30
    if ! [[ "$dias" =~ ^[0-9]+$ ]] || [[ "$dias" -lt 1 ]] || [[ "$dias" -gt 365 ]]; then
        echo -e "${RED}[!] Días inválidos. Usando 30 por defecto.${NC}"
        dias=30
    fi
    echo "$dias"
}

# --------- CREAR USUARIO SSH ------------------------------------------------------------------------------------------------------------------------
create_ssh() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------------------------------------------------${NC}"
    echo -e "${CYAN}---    CREAR USUARIO SSH          ---${NC}"
    echo -e "${CYAN}------------------------------------------------------------------------------------------------${NC}"
    echo ""

    echo -ne " ${WHITE}Usuario : ${NC}"; read USERNAME
    if [[ -z "$USERNAME" ]]; then echo -e "${RED}[!] Nombre vacío${NC}"; return; fi

    # BUG FIX: Validar caracteres del nombre (evitar inyección)
    if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}[!] Solo letras, números, guiones y guión bajo${NC}"; press_enter; return
    fi

    if id "$USERNAME" &>/dev/null; then echo -e "${RED}[!] El usuario ya existe${NC}"; press_enter; return; fi

    echo -ne " ${WHITE}Contraseña : ${NC}"; read -s PASSWORD; echo
    if [[ -z "$PASSWORD" ]]; then echo -e "${RED}[!] Contraseña vacía${NC}"; return; fi

    echo -ne " ${WHITE}Días de expiración (ej. 30) : ${NC}"; read DIAS_INPUT
    DIAS=$(validar_dias "$DIAS_INPUT")

    # BUG FIX: Límite de conexiones simultáneas --- el script original
    # no tenía esta opción, usuarios podían conectarse sin límite
    echo -ne " ${WHITE}Límite de conexiones simultáneas (default: 1) : ${NC}"; read LIMIT
    [[ -z "$LIMIT" ]] && LIMIT=1
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then LIMIT=1; fi

    EXPIRY=$(date -d "+${DIAS} days" +%Y-%m-%d)

    # Crear usuario sin home, con shell restringida
    useradd -e "$EXPIRY" -s /bin/false -M "$USERNAME" 2>/dev/null
    echo "$USERNAME:$PASSWORD" | chpasswd

    # Guardar info del usuario
    mkdir -p "$USERS_DIR"
    cat > "$USERS_DIR/${USERNAME}.info" << INFO
USERNAME=$USERNAME
PASSWORD=$PASSWORD
TYPE=ssh
CREATED=$(date +%Y-%m-%d)
EXPIRY=$EXPIRY
DIAS=$DIAS
LIMIT=$LIMIT
INFO

    # BUG FIX: Aplicar límite de conexiones vía /etc/security/limits.conf
    # El original no aplicaba el límite en ningún lado del sistema
    if grep -q "^$USERNAME" /etc/security/limits.conf 2>/dev/null; then
        sed -i "/^$USERNAME/d" /etc/security/limits.conf
    fi
    echo "$USERNAME hard maxlogins $LIMIT" >> /etc/security/limits.conf

    log_action "CREAR SSH usuario=$USERNAME expiry=$EXPIRY limit=$LIMIT"

    VPS_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}---         USUARIO CREADO EXITOSAMENTE       ---${NC}"
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Usuario  :${NC} ${CYAN}$USERNAME${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Password :${NC} ${CYAN}$PASSWORD${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Expira   :${NC} ${YELLOW}$EXPIRY${NC} (${DIAS} días)"
    echo -e "${GREEN}---${NC} ${WHITE}Límite   :${NC} ${CYAN}$LIMIT conexión(es)${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}IP VPS   :${NC} ${CYAN}$VPS_IP${NC}"
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------${NC}"
    press_enter
}

# --------- ELIMINAR USUARIO SSH ---------------------------------------------------------------------------------------------------------------
delete_ssh() {
    echo ""
    echo -e "${CYAN}[ ELIMINAR USUARIO SSH ]${NC}"
    echo ""
    echo -ne " ${WHITE}Usuario a eliminar : ${NC}"; read USERNAME

    if ! id "$USERNAME" &>/dev/null; then
        echo -e "${RED}[!] Usuario no existe${NC}"; press_enter; return
    fi

    pkill -u "$USERNAME" 2>/dev/null
    userdel -r "$USERNAME" 2>/dev/null
    rm -f "$USERS_DIR/${USERNAME}.info"

    # BUG FIX: El original no limpiaba limits.conf al borrar
    sed -i "/^$USERNAME/d" /etc/security/limits.conf 2>/dev/null

    log_action "ELIMINAR SSH usuario=$USERNAME"

    echo -e "${GREEN}[+] Usuario ${USERNAME} eliminado${NC}"
    press_enter
}

# --------- VER USUARIOS ACTIVOS ---------------------------------------------------------------------------------------------------------------
active_users() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${CYAN}---            USUARIOS CONECTADOS               ---${NC}"
    echo -e "${CYAN}------------------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo ""

    SSH_ACTIVE=$(who | awk '{print $1}' | sort -u)
    if [[ -z "$SSH_ACTIVE" ]]; then
        echo -e " ${YELLOW}Sin usuarios SSH conectados${NC}"
    else
        echo -e " ${WHITE}USUARIO SSH          DESDE              HORA${NC}"
        echo -e "${CYAN} ---------------------------------------------------------------------------------------------------------------------------------------${NC}"
        while IFS= read -r user; do
            INFO=$(who | grep "^$user" | head -1)
            HORA=$(echo "$INFO" | awk '{print $3, $4}')
            IP=$(echo "$INFO" | grep -oP '\(\K[^\)]+' | head -1)
            printf " ${GREEN}%-20s${NC} ${CYAN}%-18s${NC} ${YELLOW}%s${NC}\n" "$user" "${IP:-local}" "$HORA"
        done <<< "$SSH_ACTIVE"
    fi

    echo ""
    echo -e " ${WHITE}Total SSH activos: ${GREEN}$(who | wc -l)${NC}"
    press_enter
}

# --------- LISTAR USUARIOS ---------------------------------------------------------------------------------------------------------------------------
list_users() {
    echo ""
    echo -e "${CYAN}------------------------------------------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${CYAN}---              LISTA DE USUARIOS                        ---${NC}"
    echo -e "${CYAN}------------------------------------------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo ""
    printf " ${WHITE}%-18s %-8s %-12s %-6s %-10s${NC}\n" "USUARIO" "TIPO" "EXPIRA" "LIMIT" "ESTADO"
    echo -e "${CYAN} ------------------------------------------------------------------------------------------------------------------------------------------------------------------${NC}"

    if [[ -d "$USERS_DIR" ]]; then
        for f in "$USERS_DIR"/*.info; do
            [[ -f "$f" ]] || continue
            unset USERNAME TYPE EXPIRY LIMIT
            source "$f"

            TODAY=$(date +%Y-%m-%d)

            # BUG FIX: Comparación de fechas con operador correcto
            # El original usaba < que en bash string-compara (puede fallar
            # entre fechas del mismo mes con diferente día de un dígito).
            # Usando date para comparación numérica confiable.
            EXPIRY_TS=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
            TODAY_TS=$(date -d "$TODAY" +%s)

            if [[ "$EXPIRY_TS" -lt "$TODAY_TS" ]]; then
                STATUS="${RED}EXPIRADO${NC}"
            elif id "$USERNAME" &>/dev/null 2>/dev/null; then
                if passwd -S "$USERNAME" 2>/dev/null | grep -q " L "; then
                    STATUS="${YELLOW}BLOQUEADO${NC}"
                else
                    STATUS="${GREEN}ACTIVO${NC}"
                fi
            else
                STATUS="${RED}ELIMINADO${NC}"
            fi

            printf " ${CYAN}%-18s${NC} ${WHITE}%-8s${NC} ${YELLOW}%-12s${NC} ${WHITE}%-6s${NC} %b\n" \
                "$USERNAME" "${TYPE:-ssh}" "$EXPIRY" "${LIMIT:-1}" "$STATUS"
        done
    else
        echo -e " ${YELLOW}Sin usuarios registrados${NC}"
    fi

    press_enter
}

# --------- BLOQUEAR USUARIO ---------------------------------------------------------------------------------------------------------------------------
block_user() {
    echo ""
    echo -ne " ${WHITE}Usuario a bloquear : ${NC}"; read USERNAME
    if ! id "$USERNAME" &>/dev/null; then
        echo -e "${RED}[!] Usuario no existe${NC}"; press_enter; return
    fi
    pkill -u "$USERNAME" 2>/dev/null
    passwd -l "$USERNAME" 2>/dev/null
    log_action "BLOQUEAR SSH usuario=$USERNAME"
    echo -e "${GREEN}[+] Usuario ${USERNAME} bloqueado${NC}"
    press_enter
}

# --------- DESBLOQUEAR USUARIO ------------------------------------------------------------------------------------------------------------------
unblock_user() {
    echo ""
    echo -ne " ${WHITE}Usuario a desbloquear : ${NC}"; read USERNAME
    if ! id "$USERNAME" &>/dev/null; then
        echo -e "${RED}[!] Usuario no existe${NC}"; press_enter; return
    fi
    passwd -u "$USERNAME" 2>/dev/null
    log_action "DESBLOQUEAR SSH usuario=$USERNAME"
    echo -e "${GREEN}[+] Usuario ${USERNAME} desbloqueado${NC}"
    press_enter
}

# --------- CREAR USUARIO XRAY ---------------------------------------------------------------------------------------------------------------------
create_xray() {
    echo ""
    echo -e "${CYAN}[ CREAR USUARIO XRAY/VLESS ]${NC}"
    echo ""

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}[!] Xray no está configurado. Instálalo primero.${NC}"
        press_enter; return
    fi

    echo -ne " ${WHITE}Nombre del usuario : ${NC}"; read USERNAME
    if [[ -z "$USERNAME" ]]; then echo -e "${RED}[!] Nombre vacío${NC}"; return; fi

    if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}[!] Solo letras, números, guiones y guión bajo${NC}"; press_enter; return
    fi

    # BUG FIX: El original no verificaba si el usuario Xray ya existía
    if [[ -f "$USERS_DIR/${USERNAME}_xray.info" ]]; then
        echo -e "${RED}[!] Ya existe un usuario Xray con ese nombre${NC}"; press_enter; return
    fi

    echo -ne " ${WHITE}Días de expiración (ej. 30) : ${NC}"; read DIAS_INPUT
    DIAS=$(validar_dias "$DIAS_INPUT")

    UUID=$(uuidgen)
    EXPIRY=$(date -d "+${DIAS} days" +%Y-%m-%d)
    XRAY_PORT=$(grep "XRAY_PORT" /etc/gtkvpn/config.conf 2>/dev/null | cut -d= -f2 || echo "32595")
    VPS_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    python3 << PYEOF
import json, sys

config_file = "$XRAY_CONFIG"
try:
    with open(config_file, 'r') as f:
        config = json.load(f)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

new_user = {
    "id": "$UUID",
    "flow": "",
    "email": "$USERNAME@gtkvpn"
}

added = False
for inbound in config.get('inbounds', []):
    if inbound.get('protocol') == 'vless':
        clients = inbound.get('settings', {}).get('clients', [])
        # BUG FIX: El original no verificaba emails duplicados en Xray
        if any(c.get('email') == '$USERNAME@gtkvpn' for c in clients):
            print("DUPLICATE")
            sys.exit(0)
        clients.append(new_user)
        inbound['settings']['clients'] = clients
        added = True
        break

if not added:
    print("NO_VLESS", file=sys.stderr)
    sys.exit(1)

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)

print("OK")
PYEOF

    RESULT=$?
    if [[ $RESULT -ne 0 ]]; then
        echo -e "${RED}[!] Error al agregar usuario a Xray. Verificar config.${NC}"
        press_enter; return
    fi

    systemctl restart xray 2>/dev/null

    mkdir -p "$USERS_DIR"
    cat > "$USERS_DIR/${USERNAME}_xray.info" << INFO
USERNAME=$USERNAME
UUID=$UUID
TYPE=xray
CREATED=$(date +%Y-%m-%d)
EXPIRY=$EXPIRY
DIAS=$DIAS
INFO

    log_action "CREAR XRAY usuario=$USERNAME uuid=$UUID expiry=$EXPIRY"

    VLESS_LINK="vless://${UUID}@${VPS_IP}:${XRAY_PORT}?type=ws&encryption=none&path=%2F&security=none#${USERNAME}-GTKVPN"

    echo ""
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}---         USUARIO XRAY CREADO                       ---${NC}"
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Usuario  :${NC} ${CYAN}$USERNAME${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}UUID     :${NC} ${YELLOW}$UUID${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Expira   :${NC} ${YELLOW}$EXPIRY${NC} (${DIAS} días)"
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Link VLESS:${NC}"
    echo -e " ${CYAN}$VLESS_LINK${NC}"
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------------------------------${NC}"
    press_enter
}

# --------- ELIMINAR USUARIO XRAY ------------------------------------------------------------------------------------------------------------
delete_xray() {
    echo ""
    echo -ne " ${WHITE}Usuario Xray a eliminar : ${NC}"; read USERNAME

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}[!] Xray no configurado${NC}"; press_enter; return
    fi

    INFO_FILE="$USERS_DIR/${USERNAME}_xray.info"
    if [[ ! -f "$INFO_FILE" ]]; then
        echo -e "${RED}[!] Usuario no encontrado${NC}"; press_enter; return
    fi

    source "$INFO_FILE"

    python3 << PYEOF
import json

config_file = "$XRAY_CONFIG"
with open(config_file, 'r') as f:
    config = json.load(f)

for inbound in config.get('inbounds', []):
    if inbound.get('protocol') == 'vless':
        clients = inbound.get('settings', {}).get('clients', [])
        clients = [c for c in clients if c.get('id') != '$UUID']
        inbound['settings']['clients'] = clients
        break

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)
PYEOF

    rm -f "$INFO_FILE"
    systemctl restart xray 2>/dev/null
    log_action "ELIMINAR XRAY usuario=$USERNAME uuid=$UUID"
    echo -e "${GREEN}[+] Usuario Xray ${USERNAME} eliminado${NC}"
    press_enter
}

# --------- RENOVAR USUARIO ------------------------------------------------------------------------------------------------------------------------------
renew_user() {
    echo ""
    echo -ne " ${WHITE}Usuario a renovar : ${NC}"; read USERNAME
    echo -ne " ${WHITE}Nuevos días : ${NC}"; read DIAS_INPUT
    DIAS=$(validar_dias "$DIAS_INPUT")

    NEW_EXPIRY=$(date -d "+${DIAS} days" +%Y-%m-%d)

    RENOVADO=false

    # Renovar SSH
    if id "$USERNAME" &>/dev/null 2>/dev/null; then
        # BUG FIX: El original usaba chage Y usermod, uno pisa al otro.
        # usermod -e es la forma correcta y suficiente
        usermod -e "$NEW_EXPIRY" "$USERNAME" 2>/dev/null
        # Si estaba bloqueado, desbloquearlo
        passwd -u "$USERNAME" 2>/dev/null
        RENOVADO=true
    fi

    INFO_FILE="$USERS_DIR/${USERNAME}.info"
    if [[ -f "$INFO_FILE" ]]; then
        sed -i "s/EXPIRY=.*/EXPIRY=$NEW_EXPIRY/" "$INFO_FILE"
        sed -i "s/DIAS=.*/DIAS=$DIAS/" "$INFO_FILE"
        RENOVADO=true
    fi

    # BUG FIX: El original no renovaba usuarios Xray en el config de Xray,
    # solo en el .info --- el UUID seguía en Xray sin fecha real de expiración
    # (Xray no tiene expiración nativa, se maneja borrando el UUID)
    XRAY_INFO="$USERS_DIR/${USERNAME}_xray.info"
    if [[ -f "$XRAY_INFO" ]]; then
        sed -i "s/EXPIRY=.*/EXPIRY=$NEW_EXPIRY/" "$XRAY_INFO"
        sed -i "s/DIAS=.*/DIAS=$DIAS/" "$XRAY_INFO"
        RENOVADO=true
    fi

    if [[ "$RENOVADO" == true ]]; then
        log_action "RENOVAR usuario=$USERNAME new_expiry=$NEW_EXPIRY dias=$DIAS"
        echo -e "${GREEN}[+] Usuario ${USERNAME} renovado hasta ${NEW_EXPIRY}${NC}"
    else
        echo -e "${RED}[!] No se encontró el usuario ${USERNAME}${NC}"
    fi

    press_enter
}

# --------- LIMPIAR EXPIRADOS ------------------------------------------------------------------------------------------------------------------------
clean_expired() {
    [[ "$1" != "auto" ]] && echo -e "${CYAN}[*] Limpiando usuarios expirados...${NC}"
    TODAY_TS=$(date +%s)
    COUNT=0

    if [[ -d "$USERS_DIR" ]]; then
        for f in "$USERS_DIR"/*.info; do
            [[ -f "$f" ]] || continue
            unset USERNAME TYPE EXPIRY UUID
            source "$f"

            # BUG FIX: Comparación de fecha con timestamp igual que list_users
            EXPIRY_TS=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)

            if [[ "$EXPIRY_TS" -lt "$TODAY_TS" ]]; then
                if [[ "${TYPE:-ssh}" == "xray" ]]; then
                    # BUG FIX: El original NO eliminaba usuarios Xray expirados
                    # del config.json --- el UUID seguía activo en Xray indefinidamente
                    if [[ -n "$UUID" && -f "$XRAY_CONFIG" ]]; then
                        python3 -c "
import json
with open('$XRAY_CONFIG','r') as f: c=json.load(f)
for ib in c.get('inbounds',[]):
    if ib.get('protocol')=='vless':
        cl=ib.get('settings',{}).get('clients',[])
        ib['settings']['clients']=[x for x in cl if x.get('id')!='$UUID']
with open('$XRAY_CONFIG','w') as f: json.dump(c,f,indent=2)
" 2>/dev/null
                        systemctl restart xray 2>/dev/null
                    fi
                else
                    # SSH: matar sesiones y eliminar usuario del sistema
                    pkill -u "$USERNAME" 2>/dev/null
                    userdel "$USERNAME" 2>/dev/null
                    sed -i "/^$USERNAME/d" /etc/security/limits.conf 2>/dev/null
                fi

                rm -f "$f"
                log_action "AUTO-CLEAN tipo=${TYPE:-ssh} usuario=$USERNAME expiry=$EXPIRY"
                [[ "$1" != "auto" ]] && echo -e " ${RED}[-]${NC} $USERNAME (${TYPE:-ssh}) eliminado --- expiró $EXPIRY"
                ((COUNT++))
            fi
        done
    fi

    [[ "$1" != "auto" ]] && echo -e "${GREEN}[+] $COUNT usuarios expirados eliminados${NC}"
    [[ "$1" != "auto" ]] && press_enter
}

# --------- DISPATCHER ---------------------------------------------------------------------------------------------------------------------------------------------
case "$1" in
    create_ssh)   create_ssh ;;
    delete_ssh)   delete_ssh ;;
    active)       active_users ;;
    list)         list_users ;;
    block)        block_user ;;
    unblock)      unblock_user ;;
    create_xray)  create_xray ;;
    delete_xray)  delete_xray ;;
    renew)        renew_user ;;
    clean)        clean_expired "$2" ;;
    *)            echo "Uso: usuarios.sh [accion]" ;;
esac
