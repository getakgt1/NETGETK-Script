#!/bin/bash
# ============================================================
#   GTKVPN - Módulo SSL/TLS + Nginx
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
    SSL_ST=$([[ -f /etc/letsencrypt/live/*/fullchain.pem ]] 2>/dev/null && \
        echo -e "${GREEN}[CERT OK]${NC}" || echo -e "${YELLOW}[SIN CERT]${NC}")
    
    echo -e " ${WHITE}Nginx:${NC} $NGINX_ST"
    echo -e " ${WHITE}SSL:${NC}   $SSL_ST"
    echo ""
    echo -e " ${WHITE}[1]${NC} Instalar/Configurar Nginx"
    echo -e " ${WHITE}[2]${NC} SSL con Let's Encrypt (requiere dominio)"
    echo -e " ${WHITE}[3]${NC} SSL Autofirmado (sin dominio)"
    echo -e " ${WHITE}[4]${NC} Configurar reverse proxy Xray"
    echo -e " ${WHITE}[5]${NC} Reiniciar Nginx"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT
    
    case $OPT in
        1) install_nginx ;;
        2)
            if [[ "$1" == "cert" ]]; then
                install_letsencrypt
            else
                install_letsencrypt
            fi ;;
        3) install_selfsigned ;;
        4) setup_nginx_proxy ;;
        5) systemctl restart nginx; echo -e "${GREEN}[+] Nginx reiniciado${NC}"; sleep 1; menu_ssl ;;
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
    
    # Config básica
    cat > /etc/nginx/sites-available/gtkvpn << NGINX
server {
    listen $NGINX_PORT default_server;
    server_name _;
    
    location / {
        root /var/www/html;
        index index.html;
    }
    
    # Proxy para Xray WebSocket (configurar después)
    # location /vless {
    #     proxy_pass http://127.0.0.1:XRAY_PORT;
    #     proxy_http_version 1.1;
    #     proxy_set_header Upgrade \$http_upgrade;
    #     proxy_set_header Connection "upgrade";
    #     proxy_set_header Host \$host;
    # }
}
NGINX
    
    ln -sf /etc/nginx/sites-available/gtkvpn /etc/nginx/sites-enabled/gtkvpn 2>/dev/null
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    
    nginx -t 2>/dev/null && systemctl restart nginx
    ufw allow "$NGINX_PORT/tcp" 2>/dev/null
    
    echo "NGINX_PORT=$NGINX_PORT" >> $INSTALL_DIR/config.conf
    
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}[+] Nginx activo en puerto $NGINX_PORT${NC}"
    else
        echo -e "${RED}[!] Error en Nginx${NC}"
        nginx -t
    fi
    press_enter; menu_ssl
}

install_letsencrypt() {
    echo ""
    echo -e "${YELLOW}[!] Requiere dominio apuntando a este VPS${NC}"
    echo -ne " ${WHITE}Dominio (ej. vpn.tudominio.com): ${NC}"; read DOMAIN
    [[ -z "$DOMAIN" ]] && { echo -e "${RED}[!] Requerido${NC}"; press_enter; menu_ssl; return; }
    
    apt install -y certbot python3-certbot-nginx 2>/dev/null
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" 2>/dev/null
    
    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        echo -e "${GREEN}[+] SSL Let's Encrypt instalado para $DOMAIN${NC}"
        echo "SSL_DOMAIN=$DOMAIN" >> $INSTALL_DIR/config.conf
    else
        echo -e "${RED}[!] Error obteniendo certificado. Verifica que el dominio apunte a este servidor.${NC}"
    fi
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
    echo -e " ${WHITE}Puerto Xray:${NC} $XRAY_PORT"
    echo -e " ${WHITE}Path WS:${NC} $XRAY_PATH"
    
    # Agregar location al config de nginx
    NGINX_CONF="/etc/nginx/sites-available/gtkvpn"
    if [[ -f "$NGINX_CONF" ]]; then
        # Insertar antes del cierre del bloque server
        sed -i "s|# location $XRAY_PATH {|location $XRAY_PATH {|" "$NGINX_CONF"
        sed -i "s|#     proxy_pass http://127.0.0.1:XRAY_PORT;|    proxy_pass http://127.0.0.1:$XRAY_PORT;|" "$NGINX_CONF"
        sed -i "s|#     proxy_http_version 1.1;|    proxy_http_version 1.1;|" "$NGINX_CONF"
        sed -i 's|#     proxy_set_header Upgrade|    proxy_set_header Upgrade|g' "$NGINX_CONF"
        sed -i 's|#     proxy_set_header Connection|    proxy_set_header Connection|g' "$NGINX_CONF"
        sed -i 's|#     proxy_set_header Host|    proxy_set_header Host|g' "$NGINX_CONF"
        sed -i 's|# }$|}|' "$NGINX_CONF"
        
        nginx -t 2>/dev/null && systemctl restart nginx
        echo -e "${GREEN}[+] Nginx proxy para Xray configurado${NC}"
    else
        echo -e "${RED}[!] Instala Nginx primero (opción 1)${NC}"
    fi
    press_enter; menu_ssl
}

case "$1" in
    nginx) install_nginx ;;
    cert)  install_letsencrypt ;;
    *)     menu_ssl ;;
esac
