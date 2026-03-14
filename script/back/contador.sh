#!/bin/bash
# ============================================================
#   GTKVPN - Contador de Usuarios Online
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

show_online() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}              📊 MONITOR DE USUARIOS EN TIEMPO REAL${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # ── SSH ──────────────────────────────────────────────────
    echo -e " ${YELLOW}[ USUARIOS SSH ]${NC}"
    SSH_COUNT=$(who | grep -v "^$" | wc -l)
    if [[ $SSH_COUNT -gt 0 ]]; then
        printf " ${WHITE}%-18s %-16s %-20s %-8s${NC}\n" "USUARIO" "IP" "HORA" "PID"
        echo -e "${CYAN} ──────────────────────────────────────────────────────${NC}"
        while IFS= read -r line; do
            USER=$(echo "$line" | awk '{print $1}')
            TTY=$(echo "$line" | awk '{print $2}')
            HORA=$(echo "$line" | awk '{print $3, $4}')
            IP=$(echo "$line" | grep -oP '\(\K[^\)]+' | head -1)
            PID=$(ps -t "$TTY" -o pid= 2>/dev/null | head -1 | tr -d ' ')
            printf " ${GREEN}%-18s${NC} ${CYAN}%-16s${NC} ${YELLOW}%-20s${NC} ${GRAY}%s${NC}\n" \
                "$USER" "${IP:-local}" "$HORA" "$PID"
        done < <(who)
        echo -e " ${WHITE}Total SSH: ${GREEN}$SSH_COUNT${NC}"
    else
        echo -e " ${YELLOW}  Sin usuarios SSH activos${NC}"
    fi
    
    echo ""
    
    # ── XRAY/VLESS ───────────────────────────────────────────
    echo -e " ${YELLOW}[ USUARIOS XRAY/VLESS ]${NC}"
    XRAY_LOG="/var/log/xray/access.log"
    if [[ -f "$XRAY_LOG" ]]; then
        # Conexiones únicas en los últimos 5 min
        XRAY_IPS=$(awk -v d="$(date -d '5 minutes ago' '+%Y/%m/%d %H:%M')" \
            '$0 >= d {print $3}' "$XRAY_LOG" 2>/dev/null | \
            sort -u | grep -v "^$" | wc -l)
        echo -e "  ${WHITE}Conexiones activas (últimos 5 min):${NC} ${GREEN}$XRAY_IPS${NC}"
        
        # Últimas 5 conexiones
        echo -e "  ${WHITE}Últimas conexiones:${NC}"
        tail -5 "$XRAY_LOG" 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${GRAY}$line${NC}"
        done
    else
        echo -e " ${YELLOW}  Sin log de Xray disponible${NC}"
    fi
    
    echo ""
    
    # ── SOCKS5 ───────────────────────────────────────────────
    echo -e " ${YELLOW}[ CONEXIONES SOCKS5 ]${NC}"
    SOCKS_PORT=$(grep "SOCKS_PORT" /etc/gtkvpn/config.conf 2>/dev/null | cut -d= -f2 || echo "8080")
    SOCKS_CONN=$(ss -tnp 2>/dev/null | grep ":$SOCKS_PORT " | wc -l)
    echo -e "  ${WHITE}Conexiones en puerto $SOCKS_PORT:${NC} ${GREEN}$SOCKS_CONN${NC}"
    
    echo ""
    
    # ── RESUMEN ──────────────────────────────────────────────
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    TOTAL=$((SSH_COUNT + XRAY_IPS))
    echo -e " ${WHITE}TOTAL USUARIOS CONECTADOS: ${GREEN}$TOTAL${NC}"
    echo -e " ${GRAY}Actualizado: $(date '+%H:%M:%S')${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo ""
    echo -e " ${WHITE}[1]${NC} Actualizar  ${WHITE}[2]${NC} Auto-refresh (5s)  ${WHITE}[0]${NC} Salir"
    echo -ne " ${WHITE}► ${NC}"
    read -t 10 OPT
    
    case $OPT in
        1) show_online ;;
        2)
            while true; do
                show_online_auto
                sleep 5
            done ;;
        0|"") return ;;
        *) show_online ;;
    esac
}

show_online_auto() {
    show_online
}

show_online
