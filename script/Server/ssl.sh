#!/bin/bash
# ============================================================
#   GTKVPN - Módulo SSL/TLS + Nginx + Stunnel
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

menu_ssl() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                🔒 MÓDULO SSL/TLS + NGINX${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    NGINX_ST=$(systemctl is-active --quiet nginx 2>/dev/null && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")
    SSL_ST=$(systemctl is-active --quiet stunnel4 2>/dev/null && \
        echo -e "${GREEN}[ACTIVO]${NC}" || \
        ([[ -f /etc/letsencrypt/live/*/fullchain.pem ]] 2>/dev/null && \
        echo -e "${GREEN}[CERT OK]${NC}" || echo -e "${YELLOW}[SIN CERT]${NC}"))
    STUNNEL_ST=$(systemctl is-active --quiet stunnel4 2>/dev/null && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")

    echo -e " ${WHITE}Nginx:${NC}   $NGINX_ST"
    echo -e " ${WHITE}SSL:${NC}     $SSL_ST"
    echo -e " ${WHITE}Stunnel:${NC} $STUNNEL_ST"
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar/Configurar Nginx"
    echo -e " ${WHITE}[2]${NC} SSL con Let's Encrypt (requiere dominio)"
    echo -e " ${WHITE}[3]${NC} SSL Autofirmado (sin dominio)"
    echo -e " ${WHITE}[4]${NC} Configurar reverse proxy Xray"
    echo -e " ${WHITE}[5]${NC} Reiniciar Nginx"
    echo -e " ${WHITE}[6]${NC} ${CYAN}Instalar Stunnel (SSH sobre SSL/443)${NC}"
    echo -e " ${WHITE}[7]${NC} Estado Stunnel"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT

    case $OPT in
        1) install_nginx ;;
        2) install_letsencrypt ;;
        3) install_selfsigned ;;
        4) setup_nginx_proxy ;;
        5) systemctl restart nginx; echo -e "${GREEN}[+] Nginx reiniciado${NC}"; sleep 1; menu_ssl ;;
        6) install_stunnel ;;
        7) status_stunnel ;;
        0) return ;;
        *) menu_ssl ;;
    esac
}

install_nginx() {
    echo ""
    echo -e "${CYAN}[*] Instalando Nginx...${NC}"
    apt install -y nginx 2>/dev/null

    echo -ne " ${WHITE}Puerto HTTP Nginx (ej. 80): ${NC}"; read NGINX_PORT
    [[ -z "$NGINX_PORT" ]] && NGINX_PORT=80

    cat > /etc/nginx/sites-available/gtkvpn << NGINX
server {
    listen $NGINX_PORT default_server;
    server_name _;

    location / {
        root /var/www/html;
        index index.html;
    }
}
NGINX

    ln -sf /etc/nginx/sites-available/gtkvpn /etc/nginx/sites-enabled/gtkvpn 2>/dev/null
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    nginx -t 2>/dev/null && systemctl restart nginx
    echo -e "${GREEN}[+] Nginx instalado en puerto $NGINX_PORT${NC}"
    press_enter; menu_ssl
}

install_letsencrypt() {
    echo ""
    echo -ne " ${WHITE}Dominio (ej. vpn.tudominio.com): ${NC}"; read DOMAIN
    [[ -z "$DOMAIN" ]] && { echo -e "${RED}[!] Dominio requerido${NC}"; press_enter; menu_ssl; return; }
    apt install -y certbot python3-certbot-nginx 2>/dev/null
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" 2>/dev/null
    echo -e "${GREEN}[+] Let's Encrypt configurado para $DOMAIN${NC}"
    press_enter; menu_ssl
}

install_selfsigned() {
    echo ""
    echo -e "${CYAN}[*] Generando certificado autofirmado...${NC}"
    mkdir -p /etc/gtkvpn/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/gtkvpn/ssl/server.key \
        -out /etc/gtkvpn/ssl/server.crt \
        -subj "/C=US/ST=State/L=City/O=GTKVPN/CN=$(curl -s ifconfig.me)" 2>/dev/null
    if [[ -f /etc/gtkvpn/ssl/server.crt ]]; then
        echo -e "${GREEN}[+] Certificado autofirmado generado${NC}"
        echo -e " ${WHITE}Key:${NC} /etc/gtkvpn/ssl/server.key"
        echo -e " ${WHITE}Crt:${NC} /etc/gtkvpn/ssl/server.crt"
    else
        echo -e "${RED}[!] Error generando certificado${NC}"
    fi
    press_enter; menu_ssl
}

setup_nginx_proxy() {
    echo ""
    XRAY_PORT=$(grep "XRAY_PORT" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "32595")
    XRAY_PATH=$(grep "XRAY_WS_PATH" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2 || echo "/")
    echo -e "${CYAN}[*] Configurando Nginx como proxy para Xray...${NC}"
    NGINX_CONF="/etc/nginx/sites-available/gtkvpn"
    if [[ -f "$NGINX_CONF" ]]; then
        nginx -t 2>/dev/null && systemctl restart nginx
        echo -e "${GREEN}[+] Nginx proxy para Xray configurado${NC}"
    else
        echo -e "${RED}[!] Instala Nginx primero (opción 1)${NC}"
    fi
    press_enter; menu_ssl
}

install_stunnel() {
    echo ""
    echo -e "${CYAN}[*] Instalando Stunnel (SSH sobre SSL/443)...${NC}"

    # Verificar que pdirect.py esté corriendo (requiere SSH instalado primero)
    if ! systemctl is-active --quiet ssh-ws; then
        echo -e "${RED}[!] El proxy SSH (ssh-ws) no está activo.${NC}"
        echo -e "${YELLOW}[!] Instala primero el módulo SSH desde el menú principal.${NC}"
        press_enter; menu_ssl; return
    fi

    apt install -y stunnel4 2>/dev/null
    if ! command -v stunnel4 &>/dev/null; then
        echo -e "${RED}[!] Error instalando stunnel4${NC}"
        press_enter; menu_ssl; return
    fi

    echo -ne " ${WHITE}Puerto SSL para stunnel (default 443): ${NC}"; read SSL_PORT
    [[ -z "$SSL_PORT" ]] && SSL_PORT=443

    WS_PORT=$(grep "^SSH_WS_PORT=" /etc/gtkvpn/config.conf 2>/dev/null | cut -d= -f2 || echo "80")
    VPS_IP=$(grep "^VPS_IP=" /etc/gtkvpn/config.conf 2>/dev/null | cut -d= -f2 || curl -s ifconfig.me)
    echo -e " ${WHITE}Flujo:${NC} ${CYAN}SSL:$SSL_PORT → pdirect:$WS_PORT → SSH:22${NC}"

    echo -e "${CYAN}[*] Generando certificado autofirmado...${NC}"
    openssl req -new -x509 -days 3650 -nodes \
        -out /etc/stunnel/stunnel.pem \
        -keyout /etc/stunnel/stunnel.pem \
        -subj "/CN=$VPS_IP" 2>/dev/null
    chmod 600 /etc/stunnel/stunnel.pem

    cat > /etc/stunnel/stunnel.conf << STUNNELCONF
pid = /var/run/stunnel4/stunnel4.pid
output = /var/log/stunnel4/stunnel.log

[ssh-ssl]
accept  = $SSL_PORT
connect = 127.0.0.1:$WS_PORT
cert    = /etc/stunnel/stunnel.pem
STUNNELCONF

    echo "ENABLED=1" > /etc/default/stunnel4
    ufw allow "$SSL_PORT/tcp" 2>/dev/null
    systemctl daemon-reload
    systemctl enable stunnel4 2>/dev/null
    systemctl restart stunnel4

    sed -i "/^STUNNEL_PORT=/d" $INSTALL_DIR/config.conf
    sed -i "/^SSL_PORT=/d" $INSTALL_DIR/config.conf
    echo "STUNNEL_PORT=$SSL_PORT" >> /etc/gtkvpn/config.conf

    sleep 1
    if systemctl is-active --quiet stunnel4; then
        echo ""
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}[+] Stunnel instalado y activo${NC}"
        echo -e " ${WHITE}Puerto SSL:${NC} ${CYAN}$SSL_PORT${NC}"
        echo -e " ${WHITE}→ SSH:${NC}      ${CYAN}127.0.0.1:$SSH_PORT_DEST${NC}"
        echo -e " ${WHITE}Cert:${NC}       /etc/stunnel/stunnel.pem"
        echo ""
        echo -e " ${WHITE}Configuración GTK VPN / HTTP Custom:${NC}"
        echo -e "  Host:   ${CYAN}$VPS_IP${NC}"
        echo -e "  Puerto: ${CYAN}$SSL_PORT${NC}"
        echo -e "  SSL:    ${CYAN}✅ Activado${NC}"
        echo -e "  SNI:    ${CYAN}cdn-global.configcat.com${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${RED}[!] Error iniciando stunnel:${NC}"
        journalctl -u stunnel4 --no-pager -n 10
    fi
    press_enter; menu_ssl
}

status_stunnel() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}         Estado de Stunnel${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if systemctl is-active --quiet stunnel4; then
        echo -e " Estado: ${GREEN}[ACTIVO]${NC}"
    else
        echo -e " Estado: ${RED}[INACTIVO]${NC}"
    fi
    STUNNEL_PORT=$(grep "^STUNNEL_PORT=" /etc/gtkvpn/config.conf 2>/dev/null | cut -d= -f2 || echo "443")
    echo -e " Puerto SSL: ${CYAN}$STUNNEL_PORT${NC}"
    if [[ -f /etc/stunnel/stunnel.conf ]]; then
        echo ""
        echo -e "${WHITE}Configuración actual:${NC}"
        cat /etc/stunnel/stunnel.conf
    fi
    echo ""
    echo -e "${WHITE}Conexiones activas en :$STUNNEL_PORT:${NC}"
    ss -tnp | grep ":$STUNNEL_PORT" | wc -l
    press_enter; menu_ssl
}
