#!/bin/bash
# ============================================================
#   GTKVPN - HCR Server (servicio aparte, puerto 8880 -> dropbear 2222)
#   Uso: hcr.sh install|uninstall|status   [HCR_PORT=8880 HCR_BACKEND=127.0.0.1:2222]
#   El binario hcr-server es de terceros y NO viaja en este repo:
#   colócalo en /opt/gtk-protocolos/hcr-server o pasa HCR_BIN=/ruta
# ============================================================
PORT="${HCR_PORT:-8880}"; BACKEND="${HCR_BACKEND:-127.0.0.1:2222}"
DEST="/opt/gtk-protocolos/hcr-server"; SRC="${HCR_BIN:-$DEST}"
UNIT="/etc/systemd/system/hcr-server.service"
[[ $EUID -ne 0 ]] && { echo "Requiere root"; exit 1; }
case "${1:-status}" in
install)
    [[ -f "$SRC" ]] || { echo "Falta el binario hcr-server ($SRC)"; exit 1; }
    mkdir -p /opt/gtk-protocolos
    [[ "$SRC" == "$DEST" ]] || install -m 755 "$SRC" "$DEST"
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=HCR Server (puerto $PORT -> $BACKEND)
After=network-online.target
Wants=network-online.target
[Service]
Type=exec
ExecStart=$DEST --listen :$PORT --target $BACKEND --transport plain --max-download-frame 6144 --download-poll-timeout 8s
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
CapabilityBoundingSet=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LimitNOFILE=65535
MemoryMax=512M
[Install]
WantedBy=multi-user.target
UNITEOF
    command -v ufw >/dev/null && ufw status | grep -q active && ufw allow "$PORT/tcp" >/dev/null
    systemctl daemon-reload; systemctl enable --now hcr-server
    sleep 2; systemctl is-active hcr-server && echo "HCR escuchando en $PORT" ;;
uninstall)
    systemctl disable --now hcr-server 2>/dev/null; rm -f "$UNIT"; systemctl daemon-reload
    command -v ufw >/dev/null && ufw delete allow "$PORT/tcp" >/dev/null 2>&1
    echo "HCR eliminado (el binario en /opt/gtk-protocolos se conserva)" ;;
status) systemctl is-active hcr-server; ss -ltnp 2>/dev/null | grep -E "hcr-server" ;;
*) echo "Uso: $0 install|uninstall|status"; exit 1 ;;
esac
