#!/bin/bash
# GTKVPN - Optimizador v2.0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
press_enter() { echo -ne "\n${YELLOW}Presiona Enter...${NC}"; read; }

optimize_system() {
    echo -e "${CYAN}[*] Aplicando optimizaciones...${NC}"
    ! command -v ufw &>/dev/null && apt install -y -qq ufw 2>/dev/null
    ! command -v fail2ban-client &>/dev/null && apt install -y -qq fail2ban 2>/dev/null && systemctl enable --now fail2ban 2>/dev/null
    cat > /etc/sysctl.d/99-gtkvpn.conf << 'SYSCTL'
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65536
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.ip_forward = 1
vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSCTL
    sysctl -p /etc/sysctl.d/99-gtkvpn.conf 2>/dev/null
    modprobe tcp_bbr 2>/dev/null
    grep -q "tcp_bbr" /etc/modules-load.d/modules.conf || echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    chattr -i /etc/resolv.conf 2>/dev/null
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null
    SSHD=/etc/ssh/sshd_config
    grep -q "^Compression" $SSHD && sed -i 's/^Compression.*/Compression yes/' $SSHD || echo "Compression yes" >> $SSHD
    grep -q "^UseDNS" $SSHD && sed -i 's/^UseDNS.*/UseDNS no/' $SSHD || echo "UseDNS no" >> $SSHD
    grep -q "^ClientAliveInterval" $SSHD && sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 60/' $SSHD || echo "ClientAliveInterval 60" >> $SSHD
    systemctl restart ssh 2>/dev/null
    RAM=$(free -m | awk '/Mem:/ {print $2}')
    [[ $RAM -lt 2048 && ! -f /swapfile ]] && fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo "/swapfile none swap sw 0 0" >> /etc/fstab
    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    ! ufw status | grep -q "active" && ufw --force enable 2>/dev/null
    echo -e "${GREEN}✓ OPTIMIZACIÓN COMPLETADA${NC}"
    echo -e "  BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo -e "  RAM libre: $(free -h | awk '/Mem:/ {print $4}')"
    [[ "$1" != "auto" ]] && press_enter
}

show_info() {
    echo -e "${CYAN}[ INFO DEL SISTEMA ]${NC}"
    echo -e "  CPU:    $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo -e "  RAM:    $(free -h | awk '/Mem:/ {print $2}') total, $(free -h | awk '/Mem:/ {print $3}') usado"
    echo -e "  BBR:    $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo -e "  DNS:    $(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')"
    echo -e "  Conexiones SSH:  $(ss -tn | grep ':22 ' | grep -c ESTAB)"
    echo -e "  Conexiones Xray: $(ss -tn | grep ':32595 ' | grep -c ESTAB)"
    press_enter
}

case "$1" in
    auto) optimize_system auto ;;
    info) show_info ;;
    *)
        echo -e "${CYAN}[ OPTIMIZADOR v2.0 ]${NC}"
        echo " [1] Aplicar optimizaciones"
        echo " [2] Ver info del sistema"
        echo -ne " ► Opcion: "; read OPT
        case $OPT in 1) optimize_system ;; 2) show_info ;; esac ;;
esac
