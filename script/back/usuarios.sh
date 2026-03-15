#!/bin/bash
# ============================================================
#   GTKVPN - Gestión de Usuarios SSH / Xray
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

press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

# ─── CREAR USUARIO SSH ────────────────────────────────────────
create_ssh() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════╗${NC}"
    echo -e "${CYAN}║    CREAR USUARIO SSH          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════╝${NC}"
    echo ""
    
    echo -ne " ${WHITE}Usuario : ${NC}"; read USERNAME
    if [[ -z "$USERNAME" ]]; then echo -e "${RED}[!] Nombre vacío${NC}"; return; fi
    if id "$USERNAME" &>/dev/null; then echo -e "${RED}[!] El usuario ya existe${NC}"; return; fi
    
    echo -ne " ${WHITE}Contraseña : ${NC}"; read -s PASSWORD; echo
    if [[ -z "$PASSWORD" ]]; then echo -e "${RED}[!] Contraseña vacía${NC}"; return; fi
    
    echo -ne " ${WHITE}Días de expiración (ej. 30) : ${NC}"; read DIAS
    [[ -z "$DIAS" ]] && DIAS=30
    
    EXPIRY=$(date -d "+${DIAS} days" +%Y-%m-%d)
    
    # Crear usuario sin home, con shell restringida
    useradd -e "$EXPIRY" -s /bin/bash -M "$USERNAME" 2>/dev/null
    printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
    
    # Guardar info del usuario
    mkdir -p "$USERS_DIR"
    cat > "$USERS_DIR/${USERNAME}.info" << INFO
USERNAME=$USERNAME
PASSWORD=$PASSWORD
TYPE=ssh
CREATED=$(date +%Y-%m-%d)
EXPIRY=$EXPIRY
DIAS=$DIAS
INFO
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         USUARIO CREADO EXITOSAMENTE       ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Usuario  :${NC} ${CYAN}$USERNAME${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Password :${NC} ${CYAN}$PASSWORD${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Expira   :${NC} ${YELLOW}$EXPIRY${NC} (${DIAS} días)"
    echo -e "${GREEN}║${NC} ${WHITE}IP VPS   :${NC} ${CYAN}$(curl -s --max-time 3 ifconfig.me)${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    press_enter
}

# ─── ELIMINAR USUARIO SSH ─────────────────────────────────────
delete_ssh() {
    echo ""
    echo -e "${CYAN}[ ELIMINAR USUARIO SSH ]${NC}"
    echo ""
    echo -ne " ${WHITE}Usuario a eliminar : ${NC}"; read USERNAME
    
    if ! id "$USERNAME" &>/dev/null; then
        echo -e "${RED}[!] Usuario no existe${NC}"; press_enter; return
    fi
    
    # Matar sesiones activas
    pkill -u "$USERNAME" 2>/dev/null
    
    userdel -r "$USERNAME" 2>/dev/null
    rm -f "$USERS_DIR/${USERNAME}.info"
    
    echo -e "${GREEN}[+] Usuario ${USERNAME} eliminado${NC}"
    press_enter
}

# ─── VER USUARIOS ACTIVOS ─────────────────────────────────────
active_users() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                   USUARIOS CONECTADOS                        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e " ${WHITE}USUARIO SSH          CONEXIONES         HORA LOGIN${NC}"
    echo -e "${CYAN} ──────────────────────────────────────────────────────${NC}"

    declare -A SEEN
    local total=0

    # Dropbear: verificar PID activo en sistema y sin Exit en auth.log
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        local has_exit
        has_exit=$(grep "dropbear\[${pid}\].*Exit" /var/log/auth.log 2>/dev/null)
        [[ -n "$has_exit" ]] && continue
        local user
        user=$(grep "dropbear\[${pid}\].*Password auth succeeded" /var/log/auth.log 2>/dev/null | awk -F"'" '{print $2}')
        [[ -z "$user" || "$user" == "root" ]] && continue
        [[ -n "${SEEN[$user]}" ]] && continue
        kill -0 "$pid" 2>/dev/null || continue
        SEEN[$user]=1
        local conns hora
        conns=$(grep "Password auth succeeded for '${user}'" /var/log/auth.log 2>/dev/null | \
                awk '{match($0,/dropbear\[([0-9]+)\]/,a); print a[1]}' | \
                while read p; do kill -0 "$p" 2>/dev/null && echo "$p"; done | wc -l)
        [[ $conns -lt 1 ]] && conns=1
        hora=$(grep "dropbear\[${pid}\].*Password auth succeeded" /var/log/auth.log 2>/dev/null | awk '{print $3}')
        printf " ${GREEN}%-20s${NC} ${CYAN}%-18s${NC} ${YELLOW}%s${NC}\n" "$user" "[${conns}/100]" "$hora"
        (( total++ ))
    done < <(grep "Password auth succeeded" /var/log/auth.log 2>/dev/null | \
             awk '{match($0,/dropbear\[([0-9]+)\]/,a); print a[1]}' | sort -u)

    # OpenSSH normal via ps
    while IFS= read -r user; do
        [[ -z "$user" || "$user" == "root" || "$user" == "sshd" || "$user" == "nobody" ]] && continue
        [[ -n "${SEEN[$user]}" ]] && continue
        SEEN[$user]=1
        local conns hora
        conns=$(ps aux 2>/dev/null | grep "sshd: ${user}" | grep -v grep | grep -v priv | wc -l)
        [[ $conns -lt 1 ]] && conns=1
        hora=$(ps aux 2>/dev/null | grep "sshd: ${user}" | grep -v grep | grep -v priv | head -1 | awk '{print $9}')
        printf " ${GREEN}%-20s${NC} ${CYAN}%-18s${NC} ${YELLOW}%s${NC}\n" "$user" "[${conns}/100]" "$hora"
        (( total++ ))
    done < <(ps aux 2>/dev/null | grep "sshd:" | grep -v grep | grep -v priv | grep -v "sshd -D" | awk '{print $1}' | grep -Ev "^(root|sshd|nobody)$" | sort -u)

    [[ $total -eq 0 ]] && echo -e " ${YELLOW}Sin usuarios SSH conectados${NC}"
    echo ""
    echo -e " ${WHITE}Total SSH activos: ${GREEN}${total}${NC}"
    press_enter
}



# ─── LISTAR USUARIOS ─────────────────────────────────────────
list_users() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              LISTA DE USUARIOS                        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    printf " ${WHITE}%-18s %-12s %-12s %-8s${NC}\n" "USUARIO" "TIPO" "EXPIRA" "ESTADO"
    echo -e "${CYAN} ──────────────────────────────────────────────────────${NC}"
    
    if [[ -d "$USERS_DIR" ]]; then
        for f in "$USERS_DIR"/*.info; do
            [[ -f "$f" ]] || continue
            source "$f"
            
            # Verificar si expiró
            TODAY=$(date +%Y-%m-%d)
            if [[ "$EXPIRY" < "$TODAY" ]]; then
                STATUS="${RED}EXPIRADO${NC}"
            elif id "$USERNAME" &>/dev/null; then
                # Ver si está bloqueado
                if passwd -S "$USERNAME" 2>/dev/null | grep -q "L"; then
                    STATUS="${YELLOW}BLOQUEADO${NC}"
                else
                    STATUS="${GREEN}ACTIVO${NC}"
                fi
            else
                STATUS="${RED}ELIMINADO${NC}"
            fi
            
            printf " ${CYAN}%-18s${NC} ${WHITE}%-12s${NC} ${YELLOW}%-12s${NC} %b\n" \
                "$USERNAME" "${TYPE:-ssh}" "$EXPIRY" "$STATUS"
        done
    else
        echo -e " ${YELLOW}Sin usuarios registrados${NC}"
    fi
    
    press_enter
}

# ─── BLOQUEAR USUARIO ─────────────────────────────────────────
block_user() {
    echo ""
    echo -ne " ${WHITE}Usuario a bloquear : ${NC}"; read USERNAME
    if ! id "$USERNAME" &>/dev/null; then
        echo -e "${RED}[!] Usuario no existe${NC}"; press_enter; return
    fi
    pkill -u "$USERNAME" 2>/dev/null
    passwd -l "$USERNAME" 2>/dev/null
    echo -e "${GREEN}[+] Usuario ${USERNAME} bloqueado${NC}"
    press_enter
}

# ─── DESBLOQUEAR USUARIO ──────────────────────────────────────
unblock_user() {
    echo ""
    echo -ne " ${WHITE}Usuario a desbloquear : ${NC}"; read USERNAME
    if ! id "$USERNAME" &>/dev/null; then
        echo -e "${RED}[!] Usuario no existe${NC}"; press_enter; return
    fi
    passwd -u "$USERNAME" 2>/dev/null
    echo -e "${GREEN}[+] Usuario ${USERNAME} desbloqueado${NC}"
    press_enter
}

# ─── CREAR USUARIO XRAY ───────────────────────────────────────
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
    
    echo -ne " ${WHITE}Días de expiración (ej. 30) : ${NC}"; read DIAS
    [[ -z "$DIAS" ]] && DIAS=30
    
    UUID=$(uuidgen)
    EXPIRY=$(date -d "+${DIAS} days" +%Y-%m-%d)
    XRAY_PORT=$(grep "XRAY_PORT" /etc/gtkvpn/config.conf 2>/dev/null | cut -d= -f2 || echo "32595")
    VPS_IP=$(curl -s --max-time 3 ifconfig.me)
    
    # Agregar UUID al config de Xray
    python3 << PYEOF
import json, sys

config_file = "$XRAY_CONFIG"
with open(config_file, 'r') as f:
    config = json.load(f)

new_user = {
    "id": "$UUID",
    "flow": "",
    "email": "$USERNAME@gtkvpn"
}

# Agregar a inbounds VLESS
for inbound in config.get('inbounds', []):
    if inbound.get('protocol') == 'vless':
        clients = inbound.get('settings', {}).get('clients', [])
        clients.append(new_user)
        inbound['settings']['clients'] = clients
        break

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)

print("OK")
PYEOF
    
    systemctl restart xray 2>/dev/null
    
    # Guardar info
    cat > "$USERS_DIR/${USERNAME}_xray.info" << INFO
USERNAME=$USERNAME
UUID=$UUID
TYPE=xray
CREATED=$(date +%Y-%m-%d)
EXPIRY=$EXPIRY
DIAS=$DIAS
INFO
    
    # Generar link VLESS
    VLESS_LINK="vless://${UUID}@${VPS_IP}:${XRAY_PORT}?type=ws&encryption=none&path=%2F&security=none#${USERNAME}-GTKVPN"
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         USUARIO XRAY CREADO                       ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Usuario  :${NC} ${CYAN}$USERNAME${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}UUID     :${NC} ${YELLOW}$UUID${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Expira   :${NC} ${YELLOW}$EXPIRY${NC} (${DIAS} días)"
    echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${WHITE}Link VLESS:${NC}"
    echo -e " ${CYAN}$VLESS_LINK${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    press_enter
}

# ─── ELIMINAR USUARIO XRAY ────────────────────────────────────
delete_xray() {
    echo ""
    echo -ne " ${WHITE}Usuario Xray a eliminar : ${NC}"; read USERNAME
    
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        echo -e "${RED}[!] Xray no configurado${NC}"; press_enter; return
    fi
    
    # Buscar UUID del usuario
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
    echo -e "${GREEN}[+] Usuario Xray ${USERNAME} eliminado${NC}"
    press_enter
}

# ─── RENOVAR USUARIO ──────────────────────────────────────────
renew_user() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                   RENOVAR USUARIO                            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e " ${WHITE}Usuarios disponibles:${NC}"
    echo -e "${CYAN} ──────────────────────────────────────────────────────${NC}"
    if [[ -d "$USERS_DIR" ]]; then
        for f in "$USERS_DIR"/*.info; do
            [[ -f "$f" ]] || continue
            UNAME=$(grep "^USERNAME=" "$f" | cut -d= -f2)
            UEXPIRY=$(grep "^EXPIRY=" "$f" | cut -d= -f2)
            TODAY=$(date +%Y-%m-%d)
            if [[ "$UEXPIRY" < "$TODAY" ]]; then
                USTATUS="${RED}EXPIRADO${NC}"
            else
                USTATUS="${GREEN}ACTIVO${NC}"
            fi
            printf " ${CYAN}%-18s${NC} ${YELLOW}expira: %-12s${NC} %b\n" "$UNAME" "$UEXPIRY" "$USTATUS"
        done
    else
        echo -e " ${YELLOW}Sin usuarios registrados${NC}"
    fi
    echo ""
    echo -ne " ${WHITE}Usuario a renovar : ${NC}"; read -r RENEW_USER
    echo -ne " ${WHITE}Nuevos días : ${NC}"; read -r RENEW_DIAS
    [[ -z "$RENEW_USER" ]] && { echo -e "${RED}[!] Nombre vacío${NC}"; press_enter; return; }
    [[ -z "$RENEW_DIAS" ]] && RENEW_DIAS=30

    NEW_EXPIRY=$(date -d "+${RENEW_DIAS} days" +%Y-%m-%d)

    # Renovar SSH
    if id "$RENEW_USER" &>/dev/null; then
        chage -E "$NEW_EXPIRY" "$RENEW_USER" 2>/dev/null
        usermod -e "$NEW_EXPIRY" "$RENEW_USER" 2>/dev/null
    fi

    # Actualizar archivo info
    INFO_FILE="$USERS_DIR/${RENEW_USER}.info"
    [[ -f "$INFO_FILE" ]] && sed -i "s/EXPIRY=.*/EXPIRY=$NEW_EXPIRY/" "$INFO_FILE"
    INFO_FILE="$USERS_DIR/${RENEW_USER}_xray.info"
    [[ -f "$INFO_FILE" ]] && sed -i "s/EXPIRY=.*/EXPIRY=$NEW_EXPIRY/" "$INFO_FILE"

    echo -e "${GREEN}[+] Usuario ${RENEW_USER} renovado hasta ${NEW_EXPIRY}${NC}"
    press_enter
}

# ─── LIMPIAR EXPIRADOS ────────────────────────────────────────
clean_expired() {
    echo -e "${CYAN}[*] Limpiando usuarios expirados...${NC}"
    TODAY=$(date +%Y-%m-%d)
    COUNT=0
    
    if [[ -d "$USERS_DIR" ]]; then
        for f in "$USERS_DIR"/*.info; do
            [[ -f "$f" ]] || continue
            source "$f"
            if [[ "$EXPIRY" < "$TODAY" ]]; then
                pkill -u "$USERNAME" 2>/dev/null
                userdel "$USERNAME" 2>/dev/null
                rm -f "$f"
                echo -e " ${RED}[-]${NC} $USERNAME eliminado (expiró $EXPIRY)"
                ((COUNT++))
            fi
        done
    fi
    
    echo -e "${GREEN}[+] $COUNT usuarios expirados eliminados${NC}"
    [[ "$1" != "auto" ]] && press_enter
}

# ─── DISPATCHER ───────────────────────────────────────────────
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
