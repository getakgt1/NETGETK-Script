#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[1;35m'; WHITE='\033[1;37m'; NC='\033[0m'

press_enter() { echo -ne "\n${YELLOW}¡Enter, para volver!${NC}"; read; }

get_session_time() {
    local user="$1"
    # Tomar el proceso más antiguo del usuario (primera conexión)
    local pid
    pid=$(ps aux 2>/dev/null | grep "sshd: ${user}" | grep -v grep | grep -v priv \
        | awk '{print $1, $2}' | head -1 | awk '{print $2}')
    [[ -z "$pid" ]] && { echo "00:00:00"; return; }
    local etime
    etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
    [[ -z "$etime" ]] && { echo "00:00:00"; return; }
    local days=0 hours=0 mins=0 secs=0
    if   [[ "$etime" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        days=${BASH_REMATCH[1]}; hours=${BASH_REMATCH[2]}; mins=${BASH_REMATCH[3]}; secs=${BASH_REMATCH[4]}
    elif [[ "$etime" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        hours=${BASH_REMATCH[1]}; mins=${BASH_REMATCH[2]}; secs=${BASH_REMATCH[3]}
    elif [[ "$etime" =~ ^([0-9]+):([0-9]+)$ ]]; then
        mins=${BASH_REMATCH[1]}; secs=${BASH_REMATCH[2]}
    fi
    printf "%02d:%02d:%02d" "$(( days*24 + hours ))" "$(( 10#$mins ))" "$(( 10#$secs ))"
}

get_user_limit() {
    local f="/etc/gtkvpn/users/${1}.info"
    local limit; [[ -f "$f" ]] && limit=$(grep "^LIMIT=" "$f" 2>/dev/null | cut -d= -f2)
    [[ -n "$limit" ]] && echo "$limit" || echo "100"
}

show_online() {
    clear; echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf " ${MAGENTA}%-22s${NC}${WHITE}%-16s${NC}${GREEN}%s${NC}\n" "USUARIO" "CONEXIONES" "TIEMPO HH:MM:SS"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    declare -A SEEN
    local total_users=0

    while IFS= read -r user; do
        # Filtrar usuarios del sistema
        [[ -z "$user" || "$user" == "root" || "$user" == "sshd" || "$user" == "nobody" ]] && continue
        [[ -n "${SEEN[$user]}" ]] && continue
        SEEN[$user]=1

        local conns limit tiempo
        conns=$(ps aux 2>/dev/null | grep "sshd: ${user}" | grep -v grep | grep -v priv | wc -l)
        # Detectar conexiones Dropbear via auth.log
        local ll le
        ll=$(grep "succeeded for '${user}'" /var/log/auth.log 2>/dev/null | tail -1 | awk '{print $1,$2,$3,$4}')
        le=$(grep "Exit (${user})" /var/log/auth.log 2>/dev/null | tail -1 | awk '{print $1,$2,$3,$4}')
        [[ -n "$ll" && "$ll" > "$le" ]] && (( conns++ ))
        [[ $conns -lt 1 ]] && conns=1
        limit=$(get_user_limit "$user")
        tiempo=$(get_session_time "$user")

        local pct=$(( conns * 100 / limit ))
        local conn_color
        if   [[ $pct -ge 90 ]]; then conn_color="$RED"
        elif [[ $pct -ge 50 ]]; then conn_color="$YELLOW"
        else                          conn_color="$GREEN"; fi

        (( total_users++ ))
        printf " ${CYAN}[%d]${NC}${YELLOW}-%-17s${NC}  ${conn_color}[%d/%s]${NC}      ${WHITE}%s${NC}\n" \
            "$total_users" "$user" "$conns" "$limit" "$tiempo"

    done < <({ ps aux 2>/dev/null | grep "sshd:" | grep -v grep | grep -v priv | grep -v "sshd -D" | awk '{print $1}'; grep "Password auth succeeded" /var/log/auth.log 2>/dev/null | awk -F"'" '{print $2}'; } | sort -u)

    [[ $total_users -eq 0 ]] && echo -e "  ${YELLOW}Sin usuarios conectados${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local total_sesiones
    total_sesiones=$(ps aux 2>/dev/null | grep "sshd:" | grep -v grep | grep -v priv \
        | grep -v "sshd -D" | awk '{print $1}' | grep -Ev "^(root|sshd|nobody)$" | wc -l)
    echo -e "\n ${YELLOW}🦋${NC} # TIENES  ${WHITE}[${NC} ${GREEN}${total_sesiones}${NC} ${WHITE}]${NC} USUARIOS CONECTADOS ${YELLOW}🦋${NC} #"
    echo ""; press_enter
}

show_online
