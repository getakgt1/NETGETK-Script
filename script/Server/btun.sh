#!/bin/bash
# ============================================================
#   GTKVPN - BTUN (TCP+UDP 7900, interfaz tun btun0, subred 10.77.0.0/16)
#   Uso: btun.sh install|uninstall|status|adduser <usuario> <clave>
#   El binario btun-server es de terceros y NO viaja en este repo:
#   colócalo en /usr/local/bin/btun-server o pasa BTUN_BIN=/ruta
#   Solo toca su propia subred (NAT) y su propio puerto.
# ============================================================
PORT="${BTUN_PORT:-7900}"; SUBNET="${BTUN_SUBNET:-10.77.0.0/16}"
DEST="/usr/local/bin/btun-server"; SRC="${BTUN_BIN:-$DEST}"; AUTH="/etc/btun/users"
[[ $EUID -ne 0 ]] && { echo "Requiere root"; exit 1; }
case "${1:-status}" in
install)
    [[ -f "$SRC" ]] || { echo "Falta el binario btun-server ($SRC)"; exit 1; }
    [[ "$SRC" == "$DEST" ]] || install -m 755 "$SRC" "$DEST"
    mkdir -p /etc/btun /var/lib/btun
    if [[ ! -f "$AUTH" ]]; then
        P=$(openssl rand -base64 18 | tr -dc a-zA-Z0-9 | head -c 12)
        echo "gtkbtun:$P" > "$AUTH"; chmod 600 "$AUTH"; echo "Usuario gtkbtun / clave $P"
    fi
    cat > /etc/systemd/system/btun.service <<UNITEOF
[Unit]
Description=BTUN VPN TCP/UDP ($PORT)
After=network.target
[Service]
Type=simple
User=root
ExecStart=$DEST -auth file -auth-file $AUTH -tcp-listen 0.0.0.0:$PORT -udp-listen 0.0.0.0:$PORT -subnet $SUBNET -tun btun0 -stats-file /var/lib/btun/stats.json -handshake-timeout 15s -idle-timeout 2m
Restart=always
RestartSec=3
LimitNOFILE=65535
MemoryMax=768M
[Install]
WantedBy=multi-user.target
UNITEOF
    cat > /etc/systemd/system/btun-nat.service <<UNITEOF
[Unit]
Description=NAT para la subred de BTUN
After=network-online.target btun.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "iptables -t nat -C POSTROUTING -s $SUBNET -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $SUBNET -j MASQUERADE"
ExecStop=/bin/sh -c "iptables -t nat -D POSTROUTING -s $SUBNET -j MASQUERADE 2>/dev/null || true"
[Install]
WantedBy=multi-user.target
UNITEOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    command -v ufw >/dev/null && ufw status | grep -q active && { ufw allow "$PORT/tcp" >/dev/null; ufw allow "$PORT/udp" >/dev/null; }
    systemctl daemon-reload; systemctl enable --now btun btun-nat
    sleep 2; systemctl is-active btun && echo "BTUN escuchando en $PORT" ;;
adduser)
    [[ -n "$2" && -n "$3" ]] || { echo "Uso: $0 adduser <usuario> <clave>"; exit 1; }
    sed -i "/^$2:/d" "$AUTH"; echo "$2:$3" >> "$AUTH"; chmod 600 "$AUTH"; systemctl restart btun; echo "Usuario $2 listo" ;;
uninstall)
    systemctl disable --now btun btun-nat 2>/dev/null
    rm -f /etc/systemd/system/btun.service /etc/systemd/system/btun-nat.service; systemctl daemon-reload
    command -v ufw >/dev/null && { ufw delete allow "$PORT/tcp" >/dev/null 2>&1; ufw delete allow "$PORT/udp" >/dev/null 2>&1; }
    echo "BTUN eliminado (binario y /etc/btun se conservan)" ;;
status) systemctl is-active btun; ss -ltnup 2>/dev/null | grep -E "btun-server" ;;
*) echo "Uso: $0 install|uninstall|status|adduser"; exit 1 ;;
esac
