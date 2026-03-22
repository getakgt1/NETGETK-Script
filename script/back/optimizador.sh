#!/bin/bash
# ============================================================
#   GTKVPN - Optimizador del Sistema
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

optimize_system() {
    echo ""
    echo -e "${CYAN}[*] Aplicando optimizaciones del sistema...${NC}"
    
    # ── Límites del sistema ──────────────────────────────────
    # ── Instalar UFW si no existe ────────────────────────────────
    if ! command -v ufw &>/dev/null; then
        apt install -y -qq ufw 2>/dev/null
        echo -e "${GREEN}  ✓ UFW instalado${NC}"
    fi
    
    echo -e "${CYAN}  → Configurando límites...${NC}"
    cat > /etc/security/limits.conf << 'LIMITS'
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
root soft nofile 65536
root hard nofile 65536
LIMITS
    
    # ── Parámetros del kernel (sysctl) ───────────────────────
    echo -e "${CYAN}  → Optimizando kernel...${NC}"
    cat > /etc/sysctl.d/99-gtkvpn.conf << 'SYSCTL'
# GTKVPN Optimization
# Red
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65536
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.ip_forward = 1
# Memoria
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
SYSCTL
    
    sysctl -p /etc/sysctl.d/99-gtkvpn.conf 2>/dev/null
    
    # ── BBR ──────────────────────────────────────────────────
    echo -e "${CYAN}  → Activando BBR...${NC}"
    modprobe tcp_bbr 2>/dev/null
    echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null
    
    # Verificar BBR
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        echo -e "${GREEN}  ✓ BBR activado${NC}"
    else
        echo -e "${YELLOW}  ⚠ BBR requiere kernel 4.9+${NC}"
    fi
    
    # ── Swap (si RAM < 2GB) ──────────────────────────────────
    RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    if [[ $RAM_TOTAL -lt 2048 ]] && [[ ! -f /swapfile ]]; then
        echo -e "${CYAN}  → Creando SWAP (RAM < 2GB detectada)...${NC}"
        fallocate -l 1G /swapfile 2>/dev/null
        chmod 600 /swapfile
        mkswap /swapfile 2>/dev/null
        swapon /swapfile 2>/dev/null
        echo "/swapfile none swap sw 0 0" >> /etc/fstab 2>/dev/null
        echo -e "${GREEN}  ✓ SWAP 1GB creado${NC}"
    fi
    
    # ── Limpiar logs antiguos ────────────────────────────────
    echo -e "${CYAN}  → Limpiando logs...${NC}"
    journalctl --vacuum-time=3d 2>/dev/null
    find /var/log -name "*.log" -mtime +7 -delete 2>/dev/null
    
    # ── Fail2ban ─────────────────────────────────────────────
    echo -e "${CYAN}  → Configurando Fail2ban...${NC}"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 3
F2B
        systemctl restart fail2ban 2>/dev/null
        echo -e "${GREEN}  ✓ Fail2ban configurado${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════╗${NC}"
    echo -e "${GREEN}║  OPTIMIZACIÓN COMPLETADA ✓   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════╝${NC}"
    
    [[ "$1" != "auto" ]] && press_enter
}

show_info() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              INFO DEL SISTEMA                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    
    echo -e "\n ${WHITE}[ HARDWARE ]${NC}"
    echo -e "  CPU:    $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo -e "  Cores:  $(nproc)"
    echo -e "  RAM:    $(free -h | awk '/Mem:/ {print $2}') total, $(free -h | awk '/Mem:/ {print $3}') usado"
    echo -e "  Disco:  $(df -h / | awk 'NR==2 {print $2}') total, $(df -h / | awk 'NR==2 {print $3}') usado"
    
    echo -e "\n ${WHITE}[ RED ]${NC}"
    echo -e "  IP Pública: $(curl -s --max-time 3 ifconfig.me)"
    echo -e "  Hostname:   $(hostname)"
    
    echo -e "\n ${WHITE}[ KERNEL ]${NC}"
    echo -e "  Versión:    $(uname -r)"
    echo -e "  BBR:        $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | cut -d= -f2 | xargs)"
    
    echo -e "\n ${WHITE}[ SERVICIOS ]${NC}"
    for svc in ssh nginx xray fail2ban ufw; do
        STATUS=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$STATUS" == "active" ]]; then
            echo -e "  $svc: ${GREEN}●${NC} activo"
        else
            echo -e "  $svc: ${RED}●${NC} inactivo"
        fi
    done
    
    press_enter
}

case "$1" in
    auto)     optimize_system auto ;;
    info)     show_info ;;
    *)
        echo ""
        echo -e "${CYAN}[ OPTIMIZADOR DEL SISTEMA ]${NC}"
        echo ""
        echo -e " ${WHITE}[1]${NC} Aplicar optimizaciones"
        echo -e " ${WHITE}[2]${NC} Ver info del sistema"
        echo ""
        echo -ne " ${WHITE}► Opcion :${NC} "
        read OPT
        case $OPT in
            1) optimize_system ;;
            2) show_info ;;
        esac ;;
esac
