#!/bin/bash
# ============================================================
#   GTKVPN - BHTTP (servidor Python incluido, puerto 8445 -> dropbear 2222)
#   Uso: bhttp.sh install|uninstall|status   [BHTTP_PORT=8445 BHTTP_BACKEND_PORT=2222]
# ============================================================
PORT="${BHTTP_PORT:-8445}"; BPORT="${BHTTP_BACKEND_PORT:-2222}"
DIR="/usr/local/lib/bhttp"; UNIT="/etc/systemd/system/bhttp.service"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -ne 0 ]] && { echo "Requiere root"; exit 1; }
case "${1:-status}" in
install)
    command -v python3 >/dev/null || apt-get install -y python3 >/dev/null 2>&1
    [[ -f "$HERE/bhttp-server.py" ]] || { echo "Falta $HERE/bhttp-server.py"; exit 1; }
    mkdir -p "$DIR"; install -m 755 "$HERE/bhttp-server.py" "$DIR/bhttp-server.py"
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=Servidor BHTTP (puerto $PORT -> dropbear $BPORT)
After=network.target
[Service]
Type=simple
ExecStart=$(command -v python3) $DIR/bhttp-server.py --host 0.0.0.0 --port $PORT --backend-host 127.0.0.1 --backend-port $BPORT
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65535
MemoryMax=512M
[Install]
WantedBy=multi-user.target
UNITEOF
    command -v ufw >/dev/null && ufw status | grep -q active && ufw allow "$PORT/tcp" >/dev/null
    systemctl daemon-reload; systemctl enable --now bhttp
    sleep 2; systemctl is-active bhttp && echo "BHTTP escuchando en $PORT" ;;
uninstall)
    systemctl disable --now bhttp 2>/dev/null; rm -rf "$UNIT" "$DIR"; systemctl daemon-reload
    command -v ufw >/dev/null && ufw delete allow "$PORT/tcp" >/dev/null 2>&1
    echo "BHTTP eliminado" ;;
status) systemctl is-active bhttp; ss -ltnp 2>/dev/null | grep -E ":$PORT\b" ;;
*) echo "Uso: $0 install|uninstall|status"; exit 1 ;;
esac
