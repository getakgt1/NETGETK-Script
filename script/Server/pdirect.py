#!/usr/bin/python3
import socket, threading, sys, select

REMOTE_ADDR = "127.0.0.1"
REMOTE_PORT = 22
BUFFER_SIZE = 65536
HTTP_METHODS = [b"GET ", b"POST ", b"PUT ", b"CONNECT ", b"HTTP", b"OPTI", b"HEAD"]

def is_http(data):
    return any(data.startswith(m) for m in HTTP_METHODS)

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
    except:
        pass
    sock.settimeout(None)
    return data

def handler(client_socket, address):
    remote = None
    try:
        data = read_payload(client_socket)
        if not data:
            client_socket.close()
            return

        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.connect((REMOTE_ADDR, REMOTE_PORT))
        remote.settimeout(300)
        client_socket.settimeout(300)

        if is_http(data):
            # Extraer SSH banner si viene incluido en el payload
            client_ssh_banner = None
            if b"SSH-2.0-" in data:
                idx = data.find(b"SSH-2.0-")
                client_ssh_banner = data[idx:]
                # Limpiar: solo tomar hasta el fin de linea
                eol = client_ssh_banner.find(b"\n")
                if eol >= 0:
                    client_ssh_banner = client_ssh_banner[:eol+1]

            # 1. Leer banner SSH real del servidor
            remote.settimeout(5)
            server_banner = b""
            try:
                server_banner = remote.recv(BUFFER_SIZE)
            except:
                pass
            remote.settimeout(300)

            # 2. Responder 101 + banner del servidor (auto replace lo convierte en 200 OK)
            client_socket.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            )
            if server_banner:
                client_socket.sendall(server_banner)

            # 3. Reenviar SSH banner del cliente al servidor
            if client_ssh_banner:
                remote.sendall(client_ssh_banner)
        else:
            # SSH directo desde stunnel
            remote.sendall(data)

        sockets = [client_socket, remote]
        while True:
            r, _, e = select.select(sockets, [], sockets, 300)
            if e or not r:
                break
            for s in r:
                try:
                    d = s.recv(BUFFER_SIZE)
                    if not d:
                        return
                    other = remote if s is client_socket else client_socket
                    other.sendall(d)
                except:
                    return
    except:
        pass
    finally:
        try: client_socket.close()
        except: pass
        try:
            if remote: remote.close()
        except: pass

def main(port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    server.bind(("0.0.0.0", int(port)))
    server.listen(256)
    print(f"[pdirect] :{port} -> SSH {REMOTE_ADDR}:{REMOTE_PORT}", flush=True)
    while True:
        try:
            c, a = server.accept()
            threading.Thread(target=handler, args=(c, a), daemon=True).start()
        except Exception as e:
            print(f"[error] {e}", flush=True)

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else 80)
