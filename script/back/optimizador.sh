#!/bin/bash
# ============================================================
#   GTKVPN - Optimizador del sistema
#
#   Aplica el ajuste de rendimiento que usan las VPS en produccion:
#     · kernel: BBR + fq, buffers de 16 MB, 55 mil puertos, conntrack,
#       keepalive y cola de conexiones para miles de clientes moviles
#     · RPS/XPS: reparte la red entre todos los nucleos
#     · OpenSSH: MaxStartups 500, LoginGraceTime 30, sin compresion
#     · dropbear: ventana de 256 KB y sin corte por inactividad
#     · fail2ban: jaula para dropbear (el sshd no se endurece: los
#       clientes de operadoras moviles comparten IP y se bloquearian)
#     · journald limitado, swap, limites de archivos, Xray y stunnel
#
#   Es IDEMPOTENTE: no reescribe ni reinicia nada que ya este bien, asi
#   que el modo "auto" (setup y arranque) se puede repetir sin riesgo.
#   Ya no sobrescribe /etc/security/limits.conf ni fail2ban/jail.local.
#
#   Uso:  optimizador.sh            menu
#         optimizador.sh auto       aplica en silencio (lo usa setup)
#         optimizador.sh info       estado de las optimizaciones
#         optimizador.sh revertir   quita lo que este script instalo
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

MODE="$1"
CHANGES=0

press_enter() { [[ "$MODE" == "auto" ]] || { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }; }
say()  { [[ "$MODE" == "auto" ]] || echo -e "$*"; }
ok()   { say "${GREEN}  ✓ $*${NC}"; }
same() { say "${WHITE}  = $* (ya estaba)${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }

# put DESTINO [MODO]  — escribe lo que llegue por stdin solo si es distinto.
# Devuelve 0 si cambio algo, 1 si ya estaba igual.
put() {
    local dest="$1" mode="${2:-644}" tmp
    tmp=$(mktemp) || return 1
    cat > "$tmp"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"; chmod "$mode" "$dest" 2>/dev/null; return 1
    fi
    install -m "$mode" "$tmp" "$dest"; rm -f "$tmp"
    CHANGES=$((CHANGES + 1)); return 0
}

optimize_system() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}[!] Ejecuta como root${NC}"; return 1; fi
    say ""
    say "${CYAN}[*] Aplicando optimizaciones de rendimiento...${NC}"

    # ── 1. Kernel ────────────────────────────────────────────
    say "${CYAN}  → Kernel y red...${NC}"
    local RAM_MB CT
    RAM_MB=$(free -m | awk '/Mem:/ {print $2}'); RAM_MB=${RAM_MB:-1024}
    CT=$(( RAM_MB * 256 )); (( CT > 1048576 )) && CT=1048576; (( CT < 65536 )) && CT=65536
    modprobe tcp_bbr 2>/dev/null; modprobe nf_conntrack 2>/dev/null
    put /etc/modules-load.d/gtkvpn.conf <<'GTKEOF'
tcp_bbr
nf_conntrack
GTKEOF
    if put /etc/sysctl.d/99-zz-gtkvpn-speed.conf <<GTKEOF
# GTKVPN — ajuste de red para servidor VPN con muchas conexiones moviles.
# Generado durante la optimizacion. Para revertir: borrar este archivo y
# ejecutar "sysctl --system" (o "optimizador.sh revertir").

# --- Control de congestion: BBR + fq -----------------------------------
# cubic colapsa la ventana con cada perdida de paquete; en redes moviles
# con perdida (el caso de la mayoria de los usuarios) BBR mantiene el
# caudal alto. fq es el encolado que BBR necesita para funcionar bien.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Buffers de socket: 208 KB -> 16 MB --------------------------------
# Con clientes a 100-200 ms de RTT, 208 KB de ventana limita el caudal
# por mas ancho de banda que haya (producto ancho-de-banda x retardo).
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 131072
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- Puertos efimeros: 28 mil -> 55 mil --------------------------------
# Habia 44 mil sesiones activas contra 28 mil puertos disponibles: las
# conexiones nuevas fallaban por agotamiento de puertos.
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_max_orphans = 262144

# --- Keepalive: mata sockets de moviles que desaparecen sin cerrar -----
# Un telefono que cambia de red o se apaga no manda FIN; sin keepalive el
# socket quedaba vivo 2 horas. Esto es parte de la fuga de 44 mil conexiones.
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- Colas de aceptacion (picos de reconexion masiva) ------------------
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_syncookies = 1

# --- Latencia y arranque rapido ---------------------------------------
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 131072

# --- Reparto de interrupciones de red entre los 6 nucleos -------------
net.core.rps_sock_flow_entries = 32768

# --- conntrack: tope segun la RAM (se calcula al aplicar) ---------------
net.netfilter.nf_conntrack_max = $CT
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 15
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# --- Descriptores de archivo -------------------------------------------
fs.file-max = 2097152
fs.nr_open = 2097152

# --- Memoria -----------------------------------------------------------
vm.swappiness = 10
GTKEOF
    then
        sysctl --system >/dev/null 2>&1
        ok "Kernel: BBR + fq, buffers de 16 MB, conntrack $CT"
    else
        same "Kernel"
    fi
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr || warn "BBR no disponible en este kernel"

    # ── 2. Reparto de red entre nucleos (RPS/XPS) ────────────
    say "${CYAN}  → Reparto de red entre nucleos...${NC}"
    local rc=1
    put /usr/local/bin/gtkvpn-rps.sh 755 <<'GTKEOF' && rc=0
#!/bin/bash
# Reparte el procesamiento de paquetes de la interfaz principal entre todos los nucleos.
IFACE=$(ip route show default | awk "{print \$5; exit}")
CPUS=$(nproc)
MASK=$(printf '%x' $(( (1 << CPUS) - 1 )))
for q in /sys/class/net/$IFACE/queues/rx-*; do
  echo $MASK > $q/rps_cpus 2>/dev/null
  echo 32768 > $q/rps_flow_cnt 2>/dev/null
done
for q in /sys/class/net/$IFACE/queues/tx-*; do
  echo $MASK > $q/xps_cpus 2>/dev/null
done
exit 0
GTKEOF
    put /etc/systemd/system/gtkvpn-rps.service <<'GTKEOF' && rc=0
[Unit]
Description=GTKVPN - reparte interrupciones de red (RPS/RFS/XPS) entre nucleos
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gtkvpn-rps.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
GTKEOF
    put /etc/systemd/system/gtkvpn-sysctl-late.service <<'GTKEOF' && rc=0
[Unit]
Description=GTKVPN - reaplica los ajustes de red cuando ya cargaron todos los modulos
After=network-online.target firewalld.service ufw.service netfilter-persistent.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/sysctl --system
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
GTKEOF
    if [[ $rc -eq 0 ]]; then
        systemctl daemon-reload
        systemctl enable gtkvpn-rps gtkvpn-sysctl-late >/dev/null 2>&1
        systemctl restart gtkvpn-rps >/dev/null 2>&1
        ok "RPS/XPS en $(nproc) nucleos"
    else
        systemctl is-enabled --quiet gtkvpn-rps 2>/dev/null || systemctl enable gtkvpn-rps gtkvpn-sysctl-late >/dev/null 2>&1
        same "RPS/XPS"
    fi

    # ── 3. OpenSSH ───────────────────────────────────────────
    say "${CYAN}  → OpenSSH...${NC}"
    if put /etc/ssh/sshd_config.d/99-zz-gtkvpn-speed.conf <<'GTKEOF'
# GTKVPN — ajuste de rendimiento de OpenSSH.
# Revertir: borrar este archivo y `systemctl reload ssh`.

# El servidor recibia ~4 conexiones/segundo de clientes que abren y cierran
# sin autenticar, y con MaxStartups 10:30:100 el puerto 22 quedaba
# respondiendo "Exceeded MaxStartups" a los usuarios legitimos.
MaxStartups 500:30:2000

# Cada intento colgado ocupaba un lugar 2 minutos; 30 s alcanza de sobra
# para un login real y libera los lugares mucho mas rapido.
LoginGraceTime 30

# La compresion gasta CPU comprimiendo trafico que ya viene comprimido
# (video, HTTPS) y BAJA la velocidad del tunel.
Compression no


# Detecta y limpia clientes moviles que desaparecieron sin cerrar.
ClientAliveInterval 30
ClientAliveCountMax 4
TCPKeepAlive yes

# El tunel no necesita X11 ni DNS inverso (este ultimo ya estaba en no).
X11Forwarding no
UseDNS no

# Mas canales por conexion: un tunel VPN abre varios forwards a la vez.
MaxSessions 50
GTKEOF
    then
        if sshd -t 2>/dev/null; then
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
            ok "OpenSSH: MaxStartups 500, LoginGraceTime 30, sin compresion"
        else
            rm -f /etc/ssh/sshd_config.d/99-zz-gtkvpn-speed.conf; CHANGES=$((CHANGES - 1))
            warn "sshd rechazo la configuracion; se quito el ajuste de OpenSSH"
        fi
    else
        same "OpenSSH"
    fi

    # ── 4. Dropbear ──────────────────────────────────────────
    if [[ -f /etc/default/dropbear ]]; then
        say "${CYAN}  → Dropbear...${NC}"
        if grep -qx 'DROPBEAR_RECEIVE_WINDOW=262144' /etc/default/dropbear && \
           grep -qx 'DROPBEAR_EXTRA_ARGS="-K 30 -I 0"' /etc/default/dropbear; then
            same "Dropbear"
        else
            sed -i '/^DROPBEAR_RECEIVE_WINDOW=/d; /^DROPBEAR_EXTRA_ARGS=/d' /etc/default/dropbear
            printf 'DROPBEAR_RECEIVE_WINDOW=262144\nDROPBEAR_EXTRA_ARGS="-K 30 -I 0"\n' >> /etc/default/dropbear
            CHANGES=$((CHANGES + 1))
            # try-restart: no arranca dropbear si estaba parado (lo hace el modulo SSH)
            systemctl try-restart dropbear 2>/dev/null
            ok "Dropbear: ventana de 256 KB, keepalive 30 s, sin corte por inactividad"
        fi
    fi

    # ── 5. stunnel (si el modulo SSL ya lo instalo) ──────────
    if [[ -f /etc/stunnel/stunnel.conf ]] && ! grep -q '^sessionCacheSize' /etc/stunnel/stunnel.conf; then
        say "${CYAN}  → stunnel...${NC}"
        cp -a /etc/stunnel/stunnel.conf /etc/stunnel/stunnel.conf.pre-gtkvpn 2>/dev/null
        awk 'BEGIN{d=0} /^\[/ && !d {print "; GTKVPN: cache de sesiones TLS (reconexion rapida en moviles) y menos log"; print "debug = 4"; print "sessionCacheSize = 20000"; print "sessionCacheTimeout = 3600"; print "socket = l:TCP_NODELAY=1"; print "socket = r:TCP_NODELAY=1"; print "socket = l:SO_KEEPALIVE=1"; print "socket = r:SO_KEEPALIVE=1"; print ""; d=1} {print}' /etc/stunnel/stunnel.conf.pre-gtkvpn > /etc/stunnel/stunnel.conf
        CHANGES=$((CHANGES + 1)); systemctl try-restart stunnel4 2>/dev/null
        ok "stunnel: cache de sesiones TLS y keepalive"
    fi

    # ── 6. fail2ban (solo dropbear) ──────────────────────────
    if command -v fail2ban-client >/dev/null 2>&1; then
        say "${CYAN}  → fail2ban (dropbear)...${NC}"
        local fc=1
        put /etc/fail2ban/filter.d/dropbear.conf <<'GTKEOF' && fc=0
# Fail2Ban filter for dropbear
#
# NOTE: The regex below is ONLY intended to work with a patched
# version of Dropbear as described here:
# http://www.unchartedbackwaters.co.uk/pyblosxom/static/patches
#            ^%(__prefix_line)sexit before auth from <HOST>.*\s*$
#
# The standard Dropbear output doesn't provide enough information to
# ban all types of attack.  The Dropbear patch adds IP address
# information to the 'exit before auth' message which is always
# produced for any form of non-successful login. It is that message
# which this file matches.
#
# More information: http://bugs.debian.org/546913

[INCLUDES]

# Read common prefixes. If any customizations available -- read them from
# common.local
before = common.conf

[Definition]

_daemon = dropbear

prefregex = ^%(__prefix_line)s<F-CONTENT>(?:[Ll]ogin|[Bb]ad|[Ee]xit).+</F-CONTENT>$

failregex = ^[Ll]ogin attempt for nonexistent user ('.*' )?from <HOST>:\d+$
            ^[Bb]ad (PAM )?password attempt for .+ from <HOST>(:\d+)?$
            ^[Ee]xit before auth \(user '.+', \d+ fails\): Max auth tries reached - user '.+' from <HOST>:\d+\s*$

ignoreregex = 

# DEV Notes:
#
# The first two regexs here match the unmodified dropbear messages. It isn't
# possible to match the source of the 'exit before auth' messages from dropbear
# as they don't include the "from <HOST>" bit.
#
# The second last failregex line we need to match with the modified dropbear.
#
# For the second regex the following apply:
#
# http://www.netmite.com/android/mydroid/external/dropbear/svr-authpam.c
# http://svn.dd-wrt.com/changeset/16642#file64
#
# http://svn.dd-wrt.com/changeset/16642/src/router/dropbear/svr-authpasswd.c
#
# Author: Francis Russell
#         Zak B. Elep
GTKEOF
        put /etc/fail2ban/jail.d/dropbear.conf <<'GTKEOF' && fc=0
[dropbear]
enabled  = true
port     = 2222
filter   = dropbear
backend  = systemd
journalmatch = _SYSTEMD_UNIT=dropbear.service
maxretry = 6
findtime = 600
bantime  = 3600
GTKEOF
        if [[ $fc -eq 0 ]]; then
            systemctl restart fail2ban 2>/dev/null
            ok "fail2ban: jaula de dropbear (6 intentos / 10 min, bloqueo 1 h)"
        else
            same "fail2ban"
        fi
    fi

    # ── 7. Registros del sistema ─────────────────────────────
    say "${CYAN}  → Registros del sistema...${NC}"
    if put /etc/systemd/journald.conf.d/99-gtkvpn.conf <<'GTKEOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
GTKEOF
    then
        systemctl restart systemd-journald 2>/dev/null
        ok "journald limitado a 200 MB"
    else
        same "journald"
    fi

    # ── 8. Limites de archivos ───────────────────────────────
    # (sin tocar /etc/security/limits.conf: antes se sobrescribia entero)
    if put /etc/security/limits.d/99-gtkvpn.conf <<'GTKEOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
GTKEOF
    then ok "Limites de archivos abiertos: 1.048.576"; else same "Limites de archivos"; fi
    if systemctl cat xray >/dev/null 2>&1; then
        local nf; nf=$(systemctl show xray -p LimitNOFILE --value 2>/dev/null)
        if [[ "$nf" =~ ^[0-9]+$ ]] && (( nf < 524288 )); then
            if put /etc/systemd/system/xray.service.d/20-gtk-limits.conf <<'GTKEOF'
[Service]
LimitNOFILE=1000000
LimitNPROC=10000
GTKEOF
            then systemctl daemon-reload; ok "Xray: limite de archivos 1.000.000 (se aplica al proximo reinicio de Xray)"; fi
        fi
    fi

    # ── 9. Swap ──────────────────────────────────────────────
    if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]] && ! grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab 2>/dev/null; then
        local gb=4; (( RAM_MB < 2048 )) && gb=2
        local free_mb; free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
        if (( free_mb > gb * 1024 * 4 )); then
            say "${CYAN}  → Creando swap de ${gb} GB...${NC}"
            fallocate -l ${gb}G /swapfile-gtk 2>/dev/null || dd if=/dev/zero of=/swapfile-gtk bs=1M count=$((gb * 1024)) status=none
            chmod 600 /swapfile-gtk; mkswap /swapfile-gtk >/dev/null 2>&1; swapon /swapfile-gtk 2>/dev/null
            grep -q swapfile-gtk /etc/fstab || echo "/swapfile-gtk none swap sw 0 0" >> /etc/fstab
            CHANGES=$((CHANGES + 1)); ok "Swap de ${gb} GB"
        else
            warn "Poco espacio en disco: no se crea swap"
        fi
    else
        same "Swap"
    fi

    say ""
    if (( CHANGES > 0 )); then
        say "${GREEN}  OPTIMIZACION COMPLETADA ✓ ($CHANGES cambios)${NC}"
    else
        say "${GREEN}  Todo estaba ya optimizado: no hubo cambios.${NC}"
    fi
    press_enter
}

revert_system() {
    [[ $EUID -eq 0 ]] || { echo -e "${RED}[!] Ejecuta como root${NC}"; return 1; }
    say "${CYAN}[*] Quitando las optimizaciones instaladas por este script...${NC}"
    systemctl disable --now gtkvpn-rps gtkvpn-sysctl-late >/dev/null 2>&1
    rm -f /etc/systemd/system/gtkvpn-rps.service /etc/systemd/system/gtkvpn-sysctl-late.service /usr/local/bin/gtkvpn-rps.sh \
          /etc/sysctl.d/99-zz-gtkvpn-speed.conf /etc/modules-load.d/gtkvpn.conf /etc/security/limits.d/99-gtkvpn.conf \
          /etc/systemd/journald.conf.d/99-gtkvpn.conf /etc/systemd/system/xray.service.d/20-gtk-limits.conf \
          /etc/ssh/sshd_config.d/99-zz-gtkvpn-speed.conf /etc/fail2ban/jail.d/dropbear.conf /etc/fail2ban/filter.d/dropbear.conf
    if [[ -f /etc/stunnel/stunnel.conf.pre-gtkvpn ]]; then
        mv -f /etc/stunnel/stunnel.conf.pre-gtkvpn /etc/stunnel/stunnel.conf; systemctl try-restart stunnel4 2>/dev/null
    fi
    sed -i '/^DROPBEAR_RECEIVE_WINDOW=/d; /^DROPBEAR_EXTRA_ARGS=/d' /etc/default/dropbear 2>/dev/null
    systemctl daemon-reload; sysctl --system >/dev/null 2>&1
    systemctl reload ssh 2>/dev/null; systemctl try-restart dropbear fail2ban systemd-journald 2>/dev/null
    say "${GREEN}  ✓ Optimizaciones quitadas (el swap se conserva).${NC}"
    press_enter
}

show_info() {
    say ""
    say "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    say "${CYAN}║              INFO DEL SISTEMA                 ║${NC}"
    say "${CYAN}╚══════════════════════════════════════════════╝${NC}"

    say "\n ${WHITE}[ HARDWARE ]${NC}"
    say "  CPU:    $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    say "  Cores:  $(nproc)"
    say "  RAM:    $(free -h | awk '/Mem:/ {print $2}') total, $(free -h | awk '/Mem:/ {print $3}') usado"
    say "  Disco:  $(df -h / | awk 'NR==2 {print $2}') total, $(df -h / | awk 'NR==2 {print $3}') usado"

    say "\n ${WHITE}[ RED ]${NC}"
    say "  IP Publica: $(curl -s --max-time 3 ifconfig.me)"
    say "  Hostname:   $(hostname)"

    say "\n ${WHITE}[ OPTIMIZACION ]${NC}"
    local cc q rm ct ssh_ms rps
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null); q=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    rm=$(sysctl -n net.core.rmem_max 2>/dev/null); ct=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
    ssh_ms=$(sshd -T 2>/dev/null | awk '/^maxstartups/{print $2}')
    rps=$(cat "/sys/class/net/$(ip route show default | awk '{print $5; exit}')/queues/rx-0/rps_cpus" 2>/dev/null)
    chk() { [[ "$1" == "$2" ]] && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}✗${NC}"; }
    say "  Congestion:  $cc / $q  $(chk "$cc" bbr)"
    say "  Buffers max: $rm  $(chk "$rm" 16777216)"
    say "  Conntrack:   ${ct:-n/d}"
    say "  sshd MaxStartups: $ssh_ms  $(chk "$ssh_ms" 500:30:2000)"
    say "  RPS (mascara de nucleos): ${rps:-n/d}"
    say "  Swap:        $(swapon --show --noheadings 2>/dev/null | awk '{print $1, $3}' | paste -sd' ')"
    say "  fail2ban:    $(fail2ban-client status 2>/dev/null | tail -1 | sed 's/.*Jail list:[[:space:]]*//')"

    say "\n ${WHITE}[ SERVICIOS ]${NC}"
    for svc in ssh dropbear stunnel4 xray fail2ban ufw; do
        if [[ "$(systemctl is-active "$svc" 2>/dev/null)" == "active" ]]; then
            say "  $svc: ${GREEN}●${NC} activo"
        else
            say "  $svc: ${RED}●${NC} inactivo"
        fi
    done
    press_enter
}

case "$MODE" in
    auto)     optimize_system ;;
    info)     show_info ;;
    revertir) revert_system ;;
    *)
        echo ""
        echo -e "${CYAN}[ OPTIMIZADOR DEL SISTEMA ]${NC}"
        echo ""
        echo -e " ${WHITE}[1]${NC} Aplicar optimizaciones"
        echo -e " ${WHITE}[2]${NC} Ver info y estado de las optimizaciones"
        echo -e " ${WHITE}[3]${NC} Quitar las optimizaciones"
        echo ""
        echo -ne " ${WHITE}► Opcion :${NC} "
        read OPT
        case $OPT in
            1) optimize_system ;;
            2) show_info ;;
            3) revert_system ;;
        esac ;;
esac
