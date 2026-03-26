#!/bin/bash
# ============================================================
#   GTKVPN - Contador de Usuarios Online
#   FIX: Lee sesiones reales de Dropbear via journalctl
#        Detecta usuarios WebSocket por nombre de usuario
#        Muestra IPs de atacantes bloqueables
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

# ─── Obtener sesiones activas de Dropbear ─────────────────────
get_dropbear_sessions() {
    MAIN_PID=$(pgrep -o dropbear 2>/dev/null)
    ACTIVE_PIDS=$(pgrep dropbear 2>/dev/null | grep -v "^${MAIN_PID}$")

    [[ -z "$ACTIVE_PIDS" ]] && return

    # Cargar todo el journal una sola vez para cruzar datos
    JOURNAL=$(journalctl -u dropbear --no-pager -n 500 2>/dev/null)

    for pid in $ACTIVE_PIDS; do
        # Verificar que este PID no tiene linea de Exit (sesion cerrada)
        EXIT_LINE=$(echo "$JOURNAL" | grep "dropbear\[$pid\]" | grep "^.*Exit ")
        [[ -n "$EXIT_LINE" ]] && continue

        # Buscar linea de autenticacion exitosa para este PID
        # Formato: "Password auth succeeded for 'USER' from IP:PORT"
        AUTH_LINE=$(echo "$JOURNAL" | grep "dropbear\[$pid\]" | \
            grep "auth succeeded for")

        # Buscar linea de Child connection para hora de conexion e IP
        CONN_LINE=$(echo "$JOURNAL" | grep "dropbear\[$pid\]" | \
            grep "Child connection from")

        if [[ -n "$AUTH_LINE" ]]; then
            # Extraer nombre de usuario del formato: for 'NOMBRE' from
            USERNAME=$(echo "$AUTH_LINE" | grep -oP "(?<=for ')[^']+")
            IP_RAW=$(echo "$CONN_LINE" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
            HORA=$(echo "$CONN_LINE" | awk '{print $1, $2, $3}')

            if [[ "$IP_RAW" == "127.0.0.1" ]]; then
                TYPE="WebSocket"
                IP="via WS"
            else
                TYPE="Directo"
                IP="$IP_RAW"
            fi

            echo "$pid|${USERNAME:-desconocido}|$IP|$TYPE|$HORA"
        elif [[ -n "$CONN_LINE" ]]; then
            # Conexion activa pero aun autenticando
            IP_RAW=$(echo "$CONN_LINE" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
            HORA=$(echo "$CONN_LINE" | awk '{print $1, $2, $3}')
            if [[ "$IP_RAW" == "127.0.0.1" ]]; then
                TYPE="WebSocket"
                IP="via WS"
            else
                TYPE="Directo"
                IP="$IP_RAW"
            fi
            echo "$pid|autenticando...|$IP|$TYPE|$HORA"
        fi
    done
}

# ─── Sesiones WebSocket activas con IP real ────────────────────
get_ws_sessions() {
    # ws-proxy.py mantiene conexiones en sus file descriptors
    # Cada fd conectado a 127.0.0.1:2222 es un usuario VPN tuneado
    WS_PID=$(pgrep -f ws-proxy.py 2>/dev/null | head -1)
    [[ -z "$WS_PID" ]] && return
    
    # Contar conexiones activas del proxy hacia dropbear
    WS_TO_DB=$(ss -tnp 2>/dev/null | grep "pid=$WS_PID" | grep "127.0.0.1:2222" | wc -l)
    echo "$WS_TO_DB"
}

# ─── Usuarios autenticados exitosamente hoy ────────────────────
get_auth_users() {
    # Formato real: Password auth succeeded for 'SARA' from 127.0.0.1:PORT
    journalctl -u dropbear --no-pager --since "today" 2>/dev/null | \
        grep "auth succeeded for" | \
        grep -oP "(?<=for ')[^']+" | \
        sort | uniq -c | sort -rn | head -10
}

# ─── IPs atacantes (fuerza bruta) ─────────────────────────────
get_brute_force() {
    journalctl -u dropbear --no-pager --since "1 hour ago" 2>/dev/null | \
        grep "Bad password" | \
        grep -oP '\d+\.\d+\.\d+\.\d+' | \
        sort | uniq -c | sort -rn | \
        awk '$1 >= 3 {printf "  %s intentos - %s\n", $1, $2}' | head -5
}

show_online() {
    clear
    echo -e "${CYAN}===========================================================${NC}"
    echo -e "${WHITE}         MONITOR DE USUARIOS EN TIEMPO REAL${NC}"
    echo -e "${CYAN}===========================================================${NC}"
    echo ""

    # ── SSH DIRECTO (tu sesion de admin) ─────────────────────
    echo -e " ${YELLOW}[ SESION ADMIN SSH ]${NC}"
    SSH_COUNT=$(who | grep -v "^$" | wc -l)
    if [[ $SSH_COUNT -gt 0 ]]; then
        printf " ${WHITE}%-18s %-16s %-20s${NC}\n" "USUARIO" "IP" "HORA"
        echo -e "${CYAN} ---------------------------------------------------------${NC}"
        while IFS= read -r line; do
            USER=$(echo "$line" | awk '{print $1}')
            HORA=$(echo "$line" | awk '{print $3, $4}')
            IP=$(echo "$line" | grep -oP '\(\K[^\)]+' | head -1)
            printf " ${GREEN}%-18s${NC} ${CYAN}%-16s${NC} ${YELLOW}%s${NC}\n" \
                "$USER" "${IP:-local}" "$HORA"
        done < <(who)
    else
        echo -e " ${GRAY}  Sin sesion admin activa${NC}"
    fi

    echo ""

    # ── USUARIOS VPN VIA WEBSOCKET/DROPBEAR ──────────────────
    echo -e " ${YELLOW}[ USUARIOS VPN CONECTADOS (WebSocket+Dropbear) ]${NC}"
    printf " ${WHITE}%-20s %-12s %-10s %-20s${NC}\n" "USUARIO" "IP" "TIPO" "HORA LOGIN"
    echo -e "${CYAN} ---------------------------------------------------------${NC}"

    DB_SESSIONS=$(get_dropbear_sessions)
    DB_COUNT=0

    if [[ -n "$DB_SESSIONS" ]]; then
        while IFS='|' read -r pid username ip type hora; do
            [[ -z "$pid" ]] && continue
            printf " ${GREEN}%-20s${NC} ${CYAN}%-12s${NC} ${YELLOW}%-10s${NC} ${GRAY}%s${NC}\n" \
                "$username" "$ip" "$type" "$hora"
            ((DB_COUNT++))
        done <<< "$DB_SESSIONS"
    fi

    # Contar conexiones WebSocket activas como respaldo
    WS_COUNT=$(get_ws_sessions)
    WS_COUNT=${WS_COUNT:-0}

    if [[ $DB_COUNT -eq 0 && $WS_COUNT -gt 0 ]]; then
        echo -e " ${CYAN}  $WS_COUNT conexion(es) WebSocket activa(s)${NC}"
        echo -e " ${GRAY}  (usuarios autenticados via WebSocket proxy)${NC}"
        DB_COUNT=$WS_COUNT
    elif [[ $DB_COUNT -eq 0 ]]; then
        echo -e " ${GRAY}  Sin usuarios VPN conectados${NC}"
    fi

    echo -e " ${WHITE}Total VPN activos: ${GREEN}$DB_COUNT${NC}"

    echo ""

    # ── USUARIOS AUTENTICADOS HOY ─────────────────────────────
    echo -e " ${YELLOW}[ USUARIOS AUTENTICADOS HOY ]${NC}"
    AUTH_LIST=$(get_auth_users)
    if [[ -n "$AUTH_LIST" ]]; then
        echo "$AUTH_LIST" | while read -r count user; do
            printf "  ${GREEN}%-20s${NC} ${GRAY}%s sesion(es)${NC}\n" "$user" "$count"
        done
    else
        echo -e " ${GRAY}  Sin logins registrados hoy${NC}"
    fi

    echo ""


    # ── XRAY/VLESS ───────────────────────────────────────────
    echo -e " ${YELLOW}[ USUARIOS XRAY/VLESS ]${NC}"
    XRAY_LOG="/var/log/xray/access.log"
    XRAY_COUNT=0
    if [[ -f "$XRAY_LOG" && -s "$XRAY_LOG" ]]; then
        SINCE=$(date -d '30 minutes ago' '+%Y/%m/%d %H:%M')
        printf " ${WHITE}%-20s %-20s${NC}\n" "USUARIO" "ULTIMA CONEXION"
        echo -e "${CYAN} ---------------------------------------------------------${NC}"
        declare -A XRAY_SEEN
        while IFS= read -r line; do
            UNAME=$(echo "$line" | grep -oP "(?<=email: )[^@]+(?=@)")
            HORA=$(echo "$line" | awk '{print $1, $2}' | cut -c1-16)
            [[ -z "$UNAME" ]] && continue
            XRAY_SEEN["$UNAME"]="$HORA"
        done < <(awk -v d="$SINCE" '$0 >= d' "$XRAY_LOG" | grep "email:")
        for UNAME in "${!XRAY_SEEN[@]}"; do
            printf " ${GREEN}%-20s${NC} ${YELLOW}%s${NC}\n" "$UNAME" "${XRAY_SEEN[$UNAME]}"
            ((XRAY_COUNT++))
        done
        [[ $XRAY_COUNT -eq 0 ]] && echo -e " ${GRAY}  Sin usuarios Xray activos (ultimos 30 min)${NC}"
    else
        echo -e " ${GRAY}  Sin log de Xray disponible${NC}"
    fi

    echo ""

    # ── SOCKS5 ───────────────────────────────────────────────
    echo -e " ${YELLOW}[ CONEXIONES SOCKS5 ]${NC}"
    SOCKS_PORT=$(grep "SOCKS_PORT" /etc/gtkvpn/config.conf 2>/dev/null | cut -d= -f2 || echo "8080")
    SOCKS_CONN=$(ss -tnp 2>/dev/null | grep ":${SOCKS_PORT} " | grep -v "LISTEN" | wc -l)
    echo -e "  ${WHITE}Conexiones activas en :${SOCKS_PORT}:${NC} ${GREEN}$SOCKS_CONN${NC}"

    echo ""

    # ── ALERTAS DE FUERZA BRUTA ──────────────────────────────
    BF=$(get_brute_force)
    if [[ -n "$BF" ]]; then
        echo -e " ${RED}[ ! ALERTAS FUERZA BRUTA (ultima hora) ]${NC}"
        echo -e "$BF" | while read -r line; do
            echo -e " ${RED}$line${NC}"
        done
        echo -e " ${GRAY}  Bloquear con: ufw deny from <IP>${NC}"
        echo ""
    fi

    # ── RESUMEN ──────────────────────────────────────────────
    echo -e "${CYAN}===========================================================${NC}"
    TOTAL=$((SSH_COUNT + DB_COUNT + XRAY_COUNT + SOCKS_CONN))
    echo -e " ${WHITE}TOTAL CONEXIONES: ${GREEN}$TOTAL${NC}  ${GRAY}(admin:$SSH_COUNT vpn:$DB_COUNT xray:$XRAY_COUNT socks:$SOCKS_CONN)${NC}"
    echo -e " ${GRAY}Actualizado: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}===========================================================${NC}"
    echo ""
    echo -e " ${WHITE}[1]${NC} Actualizar  ${WHITE}[2]${NC} Auto-refresh (5s)  ${WHITE}[3]${NC} Ver log completo  ${WHITE}[0]${NC} Salir"
    echo -ne " ${WHITE}► ${NC}"
    read -t 15 OPT

    case $OPT in
        1) show_online ;;
        2) while true; do show_online; sleep 5; done ;;
        3)
            echo ""
            echo -e "${CYAN}--- Ultimas 30 entradas de Dropbear ---${NC}"
            journalctl -u dropbear --no-pager -n 30 2>/dev/null
            press_enter
            show_online
            ;;
        0|"") return ;;
        *) show_online ;;
    esac
}

show_online

