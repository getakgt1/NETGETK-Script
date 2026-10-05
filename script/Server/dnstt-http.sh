
#!/bin/bash
# ============================================================
#   GTKVPN - Módulo SlowDNS + HTTP Custom (Túnel DNS disfrazado)
# ============================================================
#
# Complementa el módulo SlowDNS (Server/slowdns.sh): usa el MISMO
# servicio dnstt (slowdns.service) — no instala nada nuevo — y solo
# decide hacia dónde reenvía el túnel una vez descifrado:
#
#   · SSH directo (127.0.0.1:$SSH_DB_PORT, dropbear)  → modo clásico,
#     el cliente conecta SSH crudo sin disfraz encima del túnel DNS.
#   · Relay HTTP Custom (127.0.0.1:$SSH_WS_PORT, el mismo ssh-ws que
#     ya sirve el payload/websocket en el puerto 80) → permite que el
#     cliente combine el túnel DNS con los modos de disfraz HTTP
#     (Split/Connect) del formulario HTTP Custom de la app, porque ese
#     relay ya sabe distinguir bytes HTTP de un saludo SSH crudo y
#     reenviarlo tal cual — el modo DIRECT/SSH-crudo se sigue viendo
#     exactamente igual, solo pasa por un salto extra en loopback.
#
# Requiere: SlowDNS ya instalado y configurado (Server/slowdns.sh).

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

INSTALL_DIR="/etc/gtkvpn"
OVERRIDE_DIR="/etc/systemd/system/slowdns.service.d"
OVERRIDE_FILE="$OVERRIDE_DIR/http-custom.conf"

press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

# Puertos reales de este VPS (config.conf), con los mismos valores por
# defecto que usa el resto del script si el archivo no los trae.
SDB_PORT=$(grep -m1 "^SSH_DB_PORT=" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2)
[[ -z "$SDB_PORT" ]] && SDB_PORT=2222
SWS_PORT=$(grep -m1 "^SSH_WS_PORT=" $INSTALL_DIR/config.conf 2>/dev/null | cut -d= -f2)
[[ -z "$SWS_PORT" ]] && SWS_PORT=80

# Upstream vigente: lo lee del override si existe, si no del ExecStart
# base del propio slowdns.service (systemctl cat ya combina los dos).
current_upstream_port() {
    systemctl cat slowdns 2>/dev/null | grep "^ExecStart=" | tail -1 \
        | grep -oE '127\.0\.0\.1:[0-9]+' | tail -1 | cut -d: -f2
}

menu_dnstt_http() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}        🐢🌐 SLOWDNS + HTTP CUSTOM (Túnel DNS disfrazado)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if ! systemctl list-unit-files slowdns.service >/dev/null 2>&1; then
        echo -e "${RED}[!] SlowDNS no está instalado todavía.${NC}"
        echo -e "${YELLOW}    Instalalo primero: Menú Protocolos → SlowDNS → [1]${NC}"
        press_enter; return
    fi

    SDNS_ST=$(systemctl is-active --quiet slowdns 2>/dev/null && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")
    WS_ST=$(relay_activo && \
        echo -e "${GREEN}[ACTIVO]${NC}" || echo -e "${RED}[INACTIVO]${NC}")

    UPPORT=$(current_upstream_port)
    if [[ "$UPPORT" == "$SWS_PORT" ]]; then
        MODE_ST="${GREEN}[ON]${NC}  túnel DNS → relay HTTP Custom (127.0.0.1:$SWS_PORT)"
    elif [[ "$UPPORT" == "$SDB_PORT" ]]; then
        MODE_ST="${RED}[OFF]${NC} túnel DNS → SSH directo (127.0.0.1:$SDB_PORT, modo clásico)"
    else
        MODE_ST="${YELLOW}[?]${NC}  upstream actual: 127.0.0.1:${UPPORT:-desconocido}"
    fi

    echo -e " ${WHITE}Servicio SlowDNS (dnstt):${NC}   $SDNS_ST"
    echo -e " ${WHITE}Relay HTTP Custom (pdirect):${NC} $WS_ST"
    echo -e " ${WHITE}Disfraz HTTP sobre el túnel:${NC} $MODE_ST"
    if [[ -f $INSTALL_DIR/slowdns.conf ]]; then
        source $INSTALL_DIR/slowdns.conf
        echo -e " ${WHITE}Dominio NS:${NC} ${CYAN}$SDNS_DOMAIN${NC}"
    fi
    echo ""
    echo -e " ${WHITE}[1]${NC} Activar disfraz HTTP sobre el túnel DNS"
    echo -e " ${WHITE}[2]${NC} Volver a SSH directo (modo clásico)"
    echo -e " ${WHITE}[3]${NC} Probar el relay ahora (SSH crudo + HTTP/101)"
    echo -e " ${WHITE}[4]${NC} Ver estado / logs de SlowDNS"
    echo ""
    echo -e " ${WHITE}[0]${NC} ${RED}[ REGRESAR ]${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    echo -ne " ${WHITE}► Opcion :${NC} "
    read OPT

    case $OPT in
        1) activar_disfraz_http ;;
        2) volver_ssh_directo ;;
        3) probar_relay ;;
        4) journalctl -u slowdns -n 20 --no-pager; press_enter; menu_dnstt_http ;;
        0) return ;;
        *) menu_dnstt_http ;;
    esac
}

# Arma (o reemplaza) el override de systemd que cambia SOLO el upstream
# del ExecStart, sin tocar dominio/clave/puerto UDP del slowdns.conf.
write_override() {
    local target_port="$1"
    # head -1: systemctl cat imprime PRIMERO el archivo base
    # (/etc/systemd/system/slowdns.service) y RECIÉN DESPUÉS cualquier
    # drop-in de slowdns.service.d/ — así que la primera línea ExecStart=
    # es siempre la del archivo original, nunca la de un override previo.
    # Anclarse ahí (en vez de a la última) evita ir arrastrando cambios de
    # una alternada a la siguiente: cada toggle parte del mismo punto
    # limpio, sin importar cuántas veces se haya activado/desactivado antes.
    local base_cmd
    base_cmd=$(systemctl cat slowdns 2>/dev/null | grep "^ExecStart=" | head -1)
    if [[ -z "$base_cmd" ]]; then
        echo -e "${RED}[!] No se pudo leer el ExecStart de slowdns.service${NC}"
        return 1
    fi
    # Reemplaza el "127.0.0.1:PUERTO" del final por el puerto pedido,
    # conservando dominio/clave/flags tal cual estén hoy.
    local new_cmd
    new_cmd=$(echo "$base_cmd" | sed -E "s#127\.0\.0\.1:[0-9]+#127.0.0.1:$target_port#")
    mkdir -p "$OVERRIDE_DIR"
    cat > "$OVERRIDE_FILE" <<OVR
[Service]
ExecStart=
$new_cmd
OVR
    systemctl daemon-reload
    systemctl restart slowdns
    sleep 2
}

# El relay del puerto WS puede llamarse ssh-ws (instalaciones viejas) o
# falcon-proxy (el que crea Server/falcon-proxy.sh); los dos son pdirect.
relay_activo() {
    systemctl is-active --quiet ssh-ws 2>/dev/null || systemctl is-active --quiet falcon-proxy 2>/dev/null
}

activar_disfraz_http() {
    echo ""
    if ! relay_activo; then
        echo -e "${YELLOW}[!] El relay HTTP Custom (ssh-ws / falcon-proxy) no está activo.${NC}"
        echo -e "${YELLOW}    Sin él, el disfraz no tiene a dónde reenviar el túnel.${NC}"
        echo -ne " ${WHITE}¿Continuar igual? (s/n): ${NC}"; read CONF
        [[ "$CONF" != "s" && "$CONF" != "S" ]] && { menu_dnstt_http; return; }
    fi
    echo -e "${CYAN}[*] Repuntando el túnel DNS hacia el relay HTTP Custom (127.0.0.1:$SWS_PORT)...${NC}"
    if write_override "$SWS_PORT"; then
        if systemctl is-active --quiet slowdns; then
            echo -e "${GREEN}[+] Listo. El túnel DNS ahora acepta DIRECT, INSTANT_SPLIT y HTTP_CONNECT.${NC}"
            echo -e "${YELLOW}    Las sesiones SSH crudo (DIRECT) siguen funcionando igual: el relay${NC}"
            echo -e "${YELLOW}    detecta que no es HTTP y las reenvía tal cual a dropbear.${NC}"
        else
            echo -e "${RED}[!] slowdns no quedó activo — revirtiendo${NC}"
            rm -f "$OVERRIDE_FILE"; systemctl daemon-reload; systemctl restart slowdns
        fi
    fi
    press_enter; menu_dnstt_http
}

volver_ssh_directo() {
    echo ""
    echo -e "${CYAN}[*] Volviendo el túnel DNS a SSH directo (127.0.0.1:$SDB_PORT)...${NC}"
    write_override "$SDB_PORT"
    if systemctl is-active --quiet slowdns; then
        echo -e "${GREEN}[+] Listo. Modo clásico restaurado.${NC}"
    else
        echo -e "${RED}[!] slowdns no quedó activo — revisa journalctl -u slowdns${NC}"
    fi
    press_enter; menu_dnstt_http
}

probar_relay() {
    echo ""
    echo -e "${CYAN}[*] Probando el relay HTTP Custom en 127.0.0.1:$SWS_PORT...${NC}"
    RESP1=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$SWS_PORT; printf 'SSH-2.0-Prueba\r\n' >&3; head -c 40 <&3" 2>/dev/null)
    if [[ "$RESP1" == SSH-2.0-* ]]; then
        echo -e "  ${GREEN}[ok]${NC} SSH crudo (modo DIRECT) → $RESP1"
    else
        echo -e "  ${RED}[FALLO]${NC} SSH crudo — respuesta: ${RESP1:-<vacío>}"
    fi
    RESP2=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$SWS_PORT; printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' >&3; head -c 40 <&3" 2>/dev/null)
    if [[ "$RESP2" == *"101 Switching"* ]]; then
        echo -e "  ${GREEN}[ok]${NC} HTTP/101 (modo INSTANT_SPLIT/HTTP_CONNECT) → detectado"
    else
        echo -e "  ${RED}[FALLO]${NC} HTTP/101 — respuesta: ${RESP2:-<vacío>}"
    fi
    press_enter; menu_dnstt_http
}

menu_dnstt_http
