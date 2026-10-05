#!/usr/bin/python3
"""pdirect.py — Falcon Proxy: SSH WebSocket compatible con HTTP Custom / NapsternetV.

Version optimizada (GTKVPN). El handshake es el mismo de siempre: deteccion
de payload HTTP, respuesta 101, banner SSH del backend y reenvio de lo que el
cliente mande pegado despues de los headers. Lo que cambia es el rendimiento:

1. os.splice(): los datos pasan de un socket al otro DENTRO del kernel, sin
   copiarse a memoria de Python. Antes cada byte del tunel pasaba por el
   interprete (y por el GIL), lo que limitaba el caudal a un solo nucleo.
2. Varios procesos por puerto con SO_REUSEPORT: el kernel reparte las
   conexiones entre todos (PDIRECT_WORKERS, por defecto un proceso por nucleo
   hasta 4).
3. TCP_NODELAY: sin esperas de Nagle, mucho menos latencia interactiva.
4. Ya NO se cierra el tunel por inactividad. Antes se hacia
   select(..., 300) y se cortaba la conexion si no habia datos por 5 minutos:
   eso mataba el tunel cuando el telefono quedaba con la pantalla apagada.
   Ahora los clientes muertos se detectan con keepalive de TCP.

Uso: pdirect.py [puerto ...]   (por defecto 80)
Debug opcional: touch /etc/gtkvpn/falcon-proxy-debug -> /var/log/falcon-proxy-debug.log
"""
import binascii
import fcntl
import os
import signal
import socket
import sys
import threading
import time
import traceback

REMOTE_ADDR = "127.0.0.1"
BUFFER_SIZE = 65536
PIPE_SIZE = 1048576
F_SETPIPE_SZ = 1031
HTTP_METHODS = [b"GET ", b"POST ", b"PUT ", b"CONNECT ", b"HTTP", b"OPTI", b"HEAD"]
WORKERS = int(os.environ.get("PDIRECT_WORKERS", "0")) or min(os.cpu_count() or 1, 4)

# Keepalive: detecta al cliente que desaparecio sin cerrar (cambio de red,
# telefono apagado) y libera el socket, en vez de dejarlo colgado.
KEEPALIVE_IDLE = 120
KEEPALIVE_INTVL = 30
KEEPALIVE_CNT = 5

HAS_SPLICE = hasattr(os, "splice")

# Mapa de sesiones para el contador de conexiones (back/conexiones.sh): por
# cada sesión reenviada se crea /run/pdirect/<puerto local hacia SSH> con la
# IP:puerto real del cliente y el puerto de entrada. Vive en memoria (/run)
# y se borra al cerrar la sesión.
SESSION_DIR = "/run/pdirect"

DEBUG_LOG = "/var/log/falcon-proxy-debug.log"
DEBUG_FLAG = "/etc/gtkvpn/falcon-proxy-debug"


def dbg(msg):
    if not os.path.exists(DEBUG_FLAG):
        return
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def hexpreview(b, n=120):
    return binascii.hexlify(b[:n]).decode()


def get_ssh_port():
    # Preferir siempre dropbear en 2222 (el backend que instala este mismo
    # script) — un SSH_PORT viejo/incorrecto en config.conf no debe pisar
    # esto, ya que dropbear en 2222 es justo lo que falcon-proxy necesita.
    try:
        s = socket.create_connection(("127.0.0.1", 2222), timeout=1)
        s.close()
        return 2222
    except Exception:
        pass
    try:
        with open("/etc/gtkvpn/config.conf") as f:
            for line in f:
                if line.startswith("SSH_PORT="):
                    return int(line.strip().split("=")[1])
    except Exception:
        pass
    return 22


# PDIRECT_REMOTE_PORT solo se usa para probar el relay contra un servidor de
# prueba; en produccion no se define.
REMOTE_PORT = int(os.environ.get("PDIRECT_REMOTE_PORT", "0")) or get_ssh_port()


REAL_IP_HEADERS = (b"cf-connecting-ip:", b"true-client-ip:", b"x-real-ip:", b"x-forwarded-for:")


def real_client_ip(data):
    """IP real del cliente cuando llega por un CDN (Cloudflare la manda en
    CF-Connecting-IP); si no viene ninguna cabecera, None."""
    for line in data.split(b"\n"):
        low = line.strip().lower()
        for h in REAL_IP_HEADERS:
            if low.startswith(h):
                ip = low[len(h):].split(b",")[0].strip().decode("ascii", "ignore")
                if ip and len(ip) <= 45 and all(c in "0123456789abcdef.:" for c in ip):
                    return ip
    return None


def session_open(remote, address, listen_port, data=b""):
    try:
        path = os.path.join(SESSION_DIR, str(remote.getsockname()[1]))
        ip = real_client_ip(data) or address[0]
        with open(path, "w") as f:
            f.write(f"{ip} {address[1]} {listen_port}\n")
        return path
    except Exception:
        return None


def is_http(data):
    return any(data.startswith(m) for m in HTTP_METHODS)


def tune(sock):
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, KEEPALIVE_IDLE)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, KEEPALIVE_INTVL)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, KEEPALIVE_CNT)
    except OSError:
        pass


def read_payload(sock):
    data = b""
    sock.settimeout(5)
    try:
        while True:
            chunk = sock.recv(BUFFER_SIZE)
            if not chunk:
                break
            data += chunk
            if b"\r\n\r\n" in data or b"\n\n" in data:
                break
            if len(data) >= 4 and not is_http(data):
                break
    except Exception:
        pass
    sock.settimeout(None)
    return data


def leftover_after_headers(data, address):
    # Cualquier byte que haya llegado pegado despues del \r\n\r\n
    # (el arranque real del handshake SSH del cliente) NO debe
    # descartarse: hay que reenviarlo al backend. Ademas, algunos
    # payloads no traen \r\n\r\n en absoluto pero SI llevan pegada
    # la linea de identificacion SSH ("SSH-2.0-...") del cliente
    # en el mismo bloque inicial -> hay que detectarla tambien.
    sep_idx, sep_len = data.find(b"\r\n\r\n"), 4
    if sep_idx == -1:
        sep_idx, sep_len = data.find(b"\n\n"), 2
    if sep_idx != -1:
        leftover = data[sep_idx + sep_len:]
        dbg(f"{address} | leftover tras headers ({len(leftover)}b): {hexpreview(leftover)}")
        return leftover
    ssh_idx = data.find(b"SSH-")
    if ssh_idx != -1:
        dbg(f"{address} | identificacion SSH embebida en data, offset {ssh_idx}")
        return data[ssh_idx:]
    dbg(f"{address} | no se encontro separador ni identificacion SSH en data")
    return b""


def pump_splice(src, dst):
    """Mueve datos src->dst sin pasar por espacio de usuario."""
    r, w = os.pipe()
    try:
        try:
            fcntl.fcntl(w, F_SETPIPE_SZ, PIPE_SIZE)
        except OSError:
            pass
        sfd, dfd = src.fileno(), dst.fileno()
        while True:
            n = os.splice(sfd, w, PIPE_SIZE)
            if n == 0:
                return
            while n > 0:
                m = os.splice(r, dfd, n)
                if m == 0:
                    return
                n -= m
    except OSError:
        return
    finally:
        os.close(r)
        os.close(w)
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def pump_copy(src, dst):
    """Respaldo si splice no esta disponible: copia clasica."""
    try:
        while True:
            d = src.recv(BUFFER_SIZE)
            if not d:
                return
            dst.sendall(d)
    except OSError:
        return
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


pump = pump_splice if HAS_SPLICE else pump_copy


def handler(client_socket, address, listen_port):
    remote = None
    session = None
    try:
        tune(client_socket)
        data = read_payload(client_socket)
        dbg(f"--- new conn {address} | initial data ({len(data)}b): {hexpreview(data, 400)}")
        if not data:
            return
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.connect((REMOTE_ADDR, REMOTE_PORT))
        tune(remote)
        session = session_open(remote, address, listen_port, data)

        if is_http(data):
            remote.settimeout(5)
            banner = b""
            try:
                banner = remote.recv(BUFFER_SIZE)
            except Exception as ex:
                dbg(f"{address} | error leyendo banner remoto: {ex}")
            remote.settimeout(None)
            client_socket.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            )
            if banner:
                client_socket.sendall(banner)
            leftover = leftover_after_headers(data, address)
            if leftover:
                remote.sendall(leftover)
        else:
            dbg(f"{address} | data no-HTTP, reenviando directo a remoto")
            remote.sendall(data)

        # Un hilo por sentido. Los dos se bloquean dentro del kernel
        # (splice libera el GIL), asi que el trafico ya no depende de que
        # el interprete de Python llegue a atenderlo.
        t = threading.Thread(target=pump, args=(client_socket, remote), daemon=True)
        t.start()
        pump(remote, client_socket)
        t.join(30)
    except Exception as ex:
        dbg(f"{address} | EXCEPCION en handler: {ex}\n{traceback.format_exc()}")
    finally:
        if session:
            try:
                os.unlink(session)
            except OSError:
                pass
        for s in (client_socket, remote):
            try:
                if s:
                    s.close()
            except Exception:
                pass


def listen(port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    server.bind(("0.0.0.0", int(port)))
    server.listen(4096)
    return server


def accept_loop(server):
    listen_port = server.getsockname()[1]
    while True:
        try:
            c, a = server.accept()
            threading.Thread(target=handler, args=(c, a, listen_port), daemon=True).start()
        except Exception as ex:
            print(f"[error] {ex}", flush=True)


def serve(ports):
    # Cada proceso escucha en todos los puertos; SO_REUSEPORT reparte.
    servers = [listen(p) for p in ports]
    print(f"[falcon-proxy] pid={os.getpid()} puertos {' '.join(map(str, ports))} -> "
          f"SSH {REMOTE_ADDR}:{REMOTE_PORT} splice={HAS_SPLICE}", flush=True)
    for s in servers[1:]:
        threading.Thread(target=accept_loop, args=(s,), daemon=True).start()
    accept_loop(servers[0])


def main(ports, workers=WORKERS):
    threading.stack_size(512 * 1024)
    try:
        os.makedirs(SESSION_DIR, exist_ok=True)
        # Al reiniciar, las sesiones anteriores ya no existen.
        for n in os.listdir(SESSION_DIR):
            os.unlink(os.path.join(SESSION_DIR, n))
    except OSError:
        pass
    children = []
    for _ in range(max(0, workers - 1)):
        pid = os.fork()
        if pid == 0:
            try:
                serve(ports)
            finally:
                os._exit(0)
        children.append(pid)

    def bye(*_):
        for p in children:
            try:
                os.kill(p, signal.SIGTERM)
            except OSError:
                pass
        os._exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    serve(ports)


if __name__ == "__main__":
    main(sys.argv[1:] if len(sys.argv) > 1 else [80])
