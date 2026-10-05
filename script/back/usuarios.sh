#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
# Los .info de Xray traen PATH=/ (ruta del xhttp): al hacer "source" pisaban
# el PATH del sistema y el script dejaba de encontrar date/rm/systemctl.
SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PATH="$SAFE_PATH"
LOG_FILE="/var/log/gtkvpn/usuarios.log"
# ── Sync Hysteria auth con usuarios SSH ──────────────────────
hy_sync() {
    local HY_CFG="/root/hysteria_server.json"
    [[ ! -f "$HY_CFG" ]] && return
    python3 -c "
import json, glob
users_dir = '/etc/gtkvpn/users'
auths = []
for f in glob.glob(users_dir + '/*.info'):
    data = {}
    for line in open(f).read().splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            data[k] = v
    p = data.get('PASSWORD', '')
    if p:
        auths.append(p)
with open('/root/hysteria_server.json') as f: d = json.load(f)
d['auth']['config'] = auths
with open('/root/hysteria_server.json', 'w') as f: json.dump(d, f)
" 2>/dev/null
    systemctl is-active --quiet hysteria 2>/dev/null && systemctl restart hysteria 2>/dev/null
}


press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

# --------- LOG ------------------------------------------------------------------------------------------------------------------------------------------------------------------
log_action() {
    mkdir -p "$(dirname $LOG_FILE)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# --------- VALIDAR DÍAS ---------------------------------------------------------------------------------------------------------------------------------------
# BUG FIX: El script original no validaba que DIAS sea un número
# Podía recibir texto vacío o no numérico y romper la fecha
# Dropbear NO cambia de usuario en los túneles sin terminal: la sesión sigue
# corriendo como root y "pkill -u usuario" no la ve, así que un usuario
# borrado o vencido seguía navegando hasta desconectarse. El PID de cada
# sesión sale del log de dropbear ("[PID] ... auth succeeded for 'usuario'");
# se toma el ÚLTIMO usuario autenticado en cada PID para no cortar a otro si
# el número de proceso se reutilizó.
cerrar_sesiones_dropbear() {
    local u="$1" p
    for p in $( { journalctl -u dropbear -b -o cat --no-pager 2>/dev/null; cat /var/log/auth.log 2>/dev/null | grep dropbear; } \
        | awk -v u="'$u'" '
            match($0, /\[[0-9]+\]/) { pid = substr($0, RSTART + 1, RLENGTH - 2) }
            /auth succeeded for/ { for (i = 1; i <= NF; i++) if ($i == "for") last[pid] = $(i + 1) }
            END { for (p in last) if (last[p] == u) print p }'); do
        [[ -r /proc/$p/comm && "$(cat /proc/$p/comm 2>/dev/null)" == "dropbear" ]] || continue
        [[ "$(awk '/^PPid/{print $2}' /proc/$p/status 2>/dev/null)" != "1" ]] || continue   # nunca el proceso principal
        kill "$p" 2>/dev/null
    done
}

# Cierra las sesiones del usuario y borra la cuenta. pkill solo pide el
# cierre (SIGTERM) y userdel falla si queda algún proceso vivo, así que se
# espera y se fuerza; devuelve error si la cuenta sigue existiendo.
borrar_cuenta() {
    local u="$1" i
    cerrar_sesiones_dropbear "$u"
    pkill -u "$u" 2>/dev/null
    for i in 1 2 3 4 5; do pgrep -u "$u" >/dev/null 2>&1 || break; sleep 1; done
    pkill -KILL -u "$u" 2>/dev/null; sleep 0.5
    userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null
    ! id "$u" &>/dev/null
}

validar_dias() {
    local dias="$1"
    [[ -z "$dias" ]] && dias=30
    # 0 = permanente (no vence nunca)
    [[ "$dias" == "0" ]] && { echo "0"; return; }
    if ! [[ "$dias" =~ ^[0-9]+$ ]] || [[ "$dias" -lt 1 ]] || [[ "$dias" -gt 365 ]]; then
        echo -e "${RED}[!] Días inválidos. Usando 30 por defecto.${NC}" >&2
        dias=30
    fi
    echo "$dias"
}

# --------- CREAR USUARIO SSH ------------------------------------------------------------------------------------------------------------------------
# Fecha de vencimiento a partir de los días; 0 = permanente.
calc_expiry() {
    if [[ "$1" == "0" ]]; then echo "9999-12-31"; else date -d "+$1 days" +%Y-%m-%d; fi
}

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

    echo -ne " ${WHITE}Días de expiración (ej. 30, 0 = permanente) : ${NC}"; read DIAS_INPUT
    DIAS=$(validar_dias "$DIAS_INPUT")

    # Sin límite de conexiones simultáneas. El "hard maxlogins" de
    # /etc/security/limits.conf solo cuenta sesiones con terminal y un túnel
    # SSH no abre terminal, así que nunca limitaba nada; se quitó para no
    # mostrar un límite que no existe. LIMIT=0 significa "sin límite".
    LIMIT=0

    EXPIRY=$(calc_expiry "$DIAS")

    # Crear usuario sin home, con shell restringida
    # FIX CRITICO: Dropbear rechaza usuarios cuya shell no esta en /etc/shells
    grep -qx "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells

    if [[ -z "$EXPIRY" ]]; then
        echo -e "${RED}[!] No se pudo calcular la fecha de expiración${NC}"; press_enter; return
    fi
    if ! useradd -e "$EXPIRY" -s /bin/false -M "$USERNAME"; then
        echo -e "${RED}[!] No se pudo crear el usuario en el sistema${NC}"; press_enter; return
    fi
    if ! echo "$USERNAME:$PASSWORD" | chpasswd; then
        userdel "$USERNAME" 2>/dev/null
        echo -e "${RED}[!] No se pudo asignar la contraseña; usuario no creado${NC}"; press_enter; return
    fi

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
    chmod 600 "$USERS_DIR/${USERNAME}.info"

    # Quitar una línea vieja de maxlogins si quedó de un usuario anterior
    sed -i "/^${USERNAME}[[:space:]]/d" /etc/security/limits.conf 2>/dev/null

    log_action "CREAR SSH usuario=$USERNAME expiry=$EXPIRY"
    hy_sync

    VPS_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}---         USUARIO CREADO EXITOSAMENTE       ---${NC}"
    echo -e "${GREEN}------------------------------------------------------------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Usuario  :${NC} ${CYAN}$USERNAME${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Password :${NC} ${CYAN}$PASSWORD${NC}"
    echo -e "${GREEN}---${NC} ${WHITE}Expira   :${NC} ${YELLOW}$EXPIRY${NC} (${DIAS} días)"
    echo -e "${GREEN}---${NC} ${WHITE}Límite   :${NC} ${CYAN}sin límite${NC}"
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

    if ! borrar_cuenta "$USERNAME"; then
        echo -e "${RED}[!] No se pudo eliminar ${USERNAME} (¿sesión todavía abierta?). Intenta de nuevo.${NC}"
        press_enter; return
    fi
    rm -f "$USERS_DIR/${USERNAME}.info"

    # BUG FIX: El original no limpiaba limits.conf al borrar
    sed -i "/^${USERNAME}[[:space:]]/d" /etc/security/limits.conf 2>/dev/null

    log_action "ELIMINAR SSH usuario=$USERNAME"
    hy_sync

    echo -e "${GREEN}[+] Usuario ${USERNAME} eliminado${NC}"
    press_enter
}

# --------- VER USUARIOS ACTIVOS ---------------------------------------------------------------------------------------------------------------
# Calcular tiempo transcurrido desde una hora de log
calc_tiempo() {
    local log_time="$1"  # formato: "Mar 26 02:21:00" o "2026-03-26 02:21"
    local now_ts=$(date +%s)
    local conn_ts=0

    # Intentar parsear formato "Mar 26 02:21:00"
    conn_ts=$(date -d "$log_time $(date +%Y)" +%s 2>/dev/null) || \
    conn_ts=$(date -d "$log_time" +%s 2>/dev/null) || \
    conn_ts=0

    [[ $conn_ts -eq 0 ]] && echo "?" && return

    local diff=$(( now_ts - conn_ts ))
    [[ $diff -lt 0 ]] && diff=0

    local h=$(( diff / 3600 ))
    local m=$(( (diff % 3600) / 60 ))
    local s=$(( diff % 60 ))

    if [[ $h -gt 0 ]]; then
        printf "%dh %02dm" $h $m
    elif [[ $m -gt 0 ]]; then
        printf "%dm %02ds" $m $s
    else
        printf "%ds" $s
    fi
}

active_users() {
    # Conexiones reales en este momento, por usuario y por protocolo.
    # El conteo anterior (log de dropbear de las últimas 500 líneas, una sola
    # entrada por usuario, log de Xray apagado) no reflejaba lo conectado.
    bash "$INSTALL_DIR/back/conexiones.sh"
    local ADMIN
    ADMIN=$(who | wc -l)
    [[ $ADMIN -gt 0 ]] && echo -e " ${WHITE}Sesiones de administración (root):${NC} ${GREEN}$ADMIN${NC}"
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
            unset USERNAME TYPE EXPIRY LIMIT UUID
            source "$f"; PATH="$SAFE_PATH"

            TODAY=$(date +%Y-%m-%d)

            # BUG FIX: Comparación de fechas con operador correcto
            # El original usaba < que en bash string-compara (puede fallar
            # entre fechas del mismo mes con diferente día de un dígito).
            # Usando date para comparación numérica confiable.
            EXPIRY_TS=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
            TODAY_TS=$(date -d "$TODAY" +%s)

            if [[ "$EXPIRY_TS" -lt "$TODAY_TS" ]]; then
                STATUS="${RED}EXPIRADO${NC}"
            elif [[ "${TYPE:-ssh}" == "xray" ]]; then
                # Xray no crea cuenta del sistema: está activo si su UUID
                # sigue en la config de Xray.
                if [[ -n "$UUID" ]] && grep -q "$UUID" "$XRAY_CONFIG" 2>/dev/null; then
                    STATUS="${GREEN}ACTIVO${NC}"
                else
                    STATUS="${RED}ELIMINADO${NC}"
                fi
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
                "$USERNAME" "${TYPE:-ssh}" "$EXPIRY" "$([[ -z "$LIMIT" || "$LIMIT" == 0 ]] && echo "sin" || echo "$LIMIT")" "$STATUS"
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
    hy_sync
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
    hy_sync
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

    echo -ne " ${WHITE}Días de expiración (ej. 30, 0 = permanente) : ${NC}"; read DIAS_INPUT
    DIAS=$(validar_dias "$DIAS_INPUT")

    UUID=$(uuidgen)
    EXPIRY=$(calc_expiry "$DIAS")
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
    chmod 600 "$USERS_DIR/${USERNAME}_xray.info"

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

    source "$INFO_FILE"; PATH="$SAFE_PATH"

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
    echo -ne " ${WHITE}Nuevos días (0 = permanente) : ${NC}"; read DIAS_INPUT
    DIAS=$(validar_dias "$DIAS_INPUT")

    NEW_EXPIRY=$(calc_expiry "$DIAS")

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
    XRAY_CHANGED=0

    if [[ -d "$USERS_DIR" ]]; then
        for f in "$USERS_DIR"/*.info; do
            [[ -f "$f" ]] || continue
            unset USERNAME TYPE EXPIRY UUID
            source "$f"; PATH="$SAFE_PATH"

            # BUG FIX: Comparación de fecha con timestamp igual que list_users
            # Fecha vacía o inválida → no se toca (antes contaba como vencido).
            [[ -z "$EXPIRY" ]] && continue
            EXPIRY_TS=$(date -d "$EXPIRY" +%s 2>/dev/null) || continue

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
                        # Un solo reinicio al final (ver abajo): reiniciar aquí,
                        # por cada usuario vencido, cortaba a TODOS los
                        # conectados por Xray varias veces seguidas.
                        XRAY_CHANGED=1
                    fi
                else
                    # SSH: matar sesiones y eliminar usuario del sistema
                    # Si la cuenta no se pudo borrar, se conserva el .info
                    # para reintentar en la próxima limpieza.
                    borrar_cuenta "$USERNAME" || continue
                    sed -i "/^${USERNAME}[[:space:]]/d" /etc/security/limits.conf 2>/dev/null
                fi

                rm -f "$f"
                log_action "AUTO-CLEAN tipo=${TYPE:-ssh} usuario=$USERNAME expiry=$EXPIRY"
                [[ "$1" != "auto" ]] && echo -e " ${RED}[-]${NC} $USERNAME (${TYPE:-ssh}) eliminado --- expiró $EXPIRY"
                ((COUNT++))
            fi
        done
    fi

    [[ "$XRAY_CHANGED" == "1" ]] && systemctl restart xray 2>/dev/null
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
