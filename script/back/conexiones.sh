#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# ============================================================
#   GTKVPN - Conexiones reales por usuario
#
#   Cuenta lo que está conectado AHORA (no eventos de log recientes):
#   · SSH: cada sesión viva de dropbear / OpenSSH, con su usuario y por
#     dónde entró (WS/HTTP en el puerto del proxy, SSL, SlowDNS o directo).
#     Dropbear no cambia de usuario en túneles sin terminal, así que el
#     usuario de cada sesión sale del log de dropbear por PID.
#     La IP real de las sesiones que pasan por el proxy pdirect sale de
#     /run/pdirect (lo escribe Server/pdirect.py).
#   · Xray: IPs conectadas por usuario (contador "online" de Xray; requiere
#     la API de estadísticas en 127.0.0.1:10085, ver Server/xray.sh).
#   · UDP Custom / Hysteria: sus clientes no se pueden atribuir a un usuario
#     (clave común), se informa solo el total.
#
#   Uso: conexiones.sh          → tabla
#        conexiones.sh --json   → JSON (lo usa el panel web)
# ============================================================

exec python3 - "$@" <<'PYEOF'
import glob, json, os, pwd, re, subprocess, sys

USERS_DIR = "/etc/gtkvpn/users"
CONFIG = "/etc/gtkvpn/config.conf"
SESSION_DIR = "/run/pdirect"
XRAY_API = "127.0.0.1:10085"
LOOP = ("127.0.0.1", "::1", "::ffff:127.0.0.1")


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return ""


def conf_ports():
    ports = {22, 2222}
    try:
        for line in open(CONFIG):
            k, _, v = line.strip().partition("=")
            if k in ("SSH_PORT", "SSH_DB_PORT") and v.isdigit():
                ports.add(int(v))
    except OSError:
        pass
    return ports


def split_ep(ep):
    ep = ep.replace("[", "").replace("]", "")
    host, _, port = ep.rpartition(":")
    if host.startswith("::ffff:"):
        host = host[7:]
    return host, int(port) if port.isdigit() else 0


def proc_name(pid):
    try:
        return open(f"/proc/{pid}/comm").read().strip()
    except OSError:
        return ""


def ppid_of(pid):
    try:
        for line in open(f"/proc/{pid}/status"):
            if line.startswith("PPid:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


# ── Sockets TCP establecidos: dueño de cada extremo y sockets por PID ────
owner = {}      # (ip, puerto local) -> nombre del proceso
socks = {}      # pid -> [(local, peer)]
for line in sh("ss -tnpH state established").splitlines():
    parts = line.split()
    if len(parts) < 5:
        continue
    local, peer = split_ep(parts[2]), split_ep(parts[3])
    for name, pid in re.findall(r'\("([^"]+)",pid=(\d+)', line):
        owner[local] = name
        socks.setdefault(int(pid), []).append((local, peer))

ssh_ports = conf_ports()


def origin_of(pid):
    """Por dónde entró la sesión SSH de este PID: (tipo, ip cliente)."""
    for local, peer in socks.get(pid, []):
        if local[1] not in ssh_ports:
            continue
        if peer[0] not in LOOP:
            return ("SSH directo" if local[1] == 22 else "Dropbear directo"), peer[0]
        relay = owner.get(peer, "")
        if relay.startswith("python"):                  # proxy pdirect
            try:
                cip, cport, lport = open(f"{SESSION_DIR}/{peer[1]}").read().split()
            except (OSError, ValueError):
                return "WS/SSL/DNS", ""
            if cip in LOOP:
                via = owner.get((cip, int(cport)), "")
                if via.startswith("stunnel"):
                    return "SSL", ""
                if "dns" in via.lower():
                    return "SlowDNS", ""
                return via or "local", ""
            return f"WS/HTTP:{lport}", cip
        if relay.startswith("stunnel"):
            return "SSL", ""
        if "dns" in relay.lower():
            return "SlowDNS", ""
        return relay or "local", ""
    return "?", ""


users = {}


def is_user(name):
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


def add(user, kind, ip):
    u = users.setdefault(user, {"total": 0, "ssh": 0, "xray": 0, "tipos": {}, "ips": set()})
    u["total"] += 1
    u["ssh" if kind != "Xray" else "xray"] += 1
    u["tipos"][kind] = u["tipos"].get(kind, 0) + 1
    if ip:
        u["ips"].add(ip)


# ── Dropbear: usuario por PID desde su log (último usuario autenticado) ──
last_user = {}
# Ninguna sesión viva es anterior al arranque del servicio: leer solo desde
# ahí (en un VPS con días de uptime el log completo es enorme).
since = sh("systemctl show dropbear -p ActiveEnterTimestamp --value").strip()
since_arg = f'--since "{since}"' if since and since != "n/a" else "-b"
log = sh(f"journalctl -u dropbear {since_arg} -o cat --no-pager 2>/dev/null; grep dropbear /var/log/auth.log 2>/dev/null")
for line in log.splitlines():
    m = re.search(r"\[(\d+)\].*auth succeeded for '([^']+)'", line)
    if m:
        last_user[int(m.group(1))] = m.group(2)
for pid in map(int, sh("pgrep -x dropbear").split()):
    if proc_name(ppid_of(pid)) != "dropbear":           # proceso principal
        continue
    user = last_user.get(pid)
    if user and user != "root":                         # root = administración
        kind, ip = origin_of(pid)
        add(user, kind, ip)

# ── OpenSSH: "sshd: usuario [priv]" (root) tiene el socket del cliente ───
for line in sh("ps -eo pid=,args=").splitlines():
    m = re.match(r"\s*(\d+)\s+sshd(?:-session)?: (\S+?) \[priv\]$", line)
    # "unknown" = conexión todavía sin autenticar; root = administración
    if m and m.group(2) not in ("root", "unknown") and is_user(m.group(2)):
        kind, ip = origin_of(int(m.group(1)))
        add(m.group(2), kind, ip)

# ── Xray: IPs en línea por usuario ───────────────────────────────────────
xray_ok = False
online = None
try:
    online = {re.sub(r"^user>>>|>>>online$", "", x)
              for x in json.loads(sh(f"xray api statsgetallonlineusers --server={XRAY_API} 2>/dev/null")).get("users", [])}
except ValueError:
    pass                                                # Xray viejo: consultar uno por uno
for f in sorted(glob.glob(f"{USERS_DIR}/*_xray.info")):
    name = os.path.basename(f)[:-len("_xray.info")]
    if online is not None:
        xray_ok = True
        if f"{name}@gtkvpn" not in online:
            continue
    out = sh(f"xray api statsonlineiplist --server={XRAY_API} -email '{name}@gtkvpn' 2>/dev/null")
    try:
        ips = list(json.loads(out).get("ips", {}).keys())
        xray_ok = True
    except ValueError:
        continue
    for ip in ips:
        add(name, "Xray", ip)

# ── UDP: totales (no atribuibles a un usuario) ───────────────────────────
udp = {}
for svc in ("udp-custom", "hysteria-udp", "hysteria"):
    if sh(f"systemctl is-active {svc} 2>/dev/null").strip() == "active":
        udp[svc] = "activo"

if "--json" in sys.argv:
    print(json.dumps({
        "users": {k: {**v, "ips": sorted(v["ips"])} for k, v in users.items()},
        "xray_stats": xray_ok, "udp": udp}, ensure_ascii=False))
    sys.exit(0)

C, G, Y, W, R, N = "\033[0;36m", "\033[0;32m", "\033[1;33m", "\033[1;37m", "\033[0;31m", "\033[0m"
print(f"\n{C}{'─' * 70}{N}\n{C}   CONEXIONES ACTIVAS POR USUARIO (en este momento){N}\n{C}{'─' * 70}{N}\n")
print(f" {W}{'USUARIO':<16} {'TOTAL':>5}  {'IPs':>4}  DETALLE{N}")
print(f" {C}{'─' * 68}{N}")
for name, u in sorted(users.items(), key=lambda x: -x[1]["total"]):
    det = ", ".join(f"{k} {v}" for k, v in sorted(u["tipos"].items(), key=lambda x: -x[1]))
    print(f" {G}{name:<16}{N} {W}{u['total']:>5}{N}  {Y}{len(u['ips']):>4}{N}  {det}")
if not users:
    print(f"  Sin usuarios conectados")
tot_ssh = sum(u["ssh"] for u in users.values())
tot_xray = sum(u["xray"] for u in users.values())
print(f"\n {W}SSH:{N} {G}{tot_ssh}{N} conexiones   {W}Xray:{N} {G}{tot_xray}{N} IPs   {W}Usuarios:{N} {G}{len(users)}{N}")
if not xray_ok and glob.glob(f"{USERS_DIR}/*_xray.info"):
    print(f" {Y}Xray: contador no disponible (falta la API de estadísticas en {XRAY_API}){N}")
if udp:
    print(f" {Y}UDP ({', '.join(udp)}): sus clientes no se pueden atribuir a un usuario (clave común){N}")
print(f"\n {W}IPs{N} = direcciones distintas (varios teléfonos tras la misma red móvil pueden compartir IP)")
PYEOF
