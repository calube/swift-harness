# Minimal HTTP CONNECT proxy on localhost that refuses api.typesafe.ai and tunnels everything else.
import socket, threading, sys, select
PORT = int(sys.argv[1]); LOG = open(sys.argv[2], 'a', buffering=1)
def pipe(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 300)
            if not r: break
            for s in r:
                d = s.recv(65536)
                if not d: return
                (b if s is a else a).sendall(d)
    except Exception: pass
    finally: a.close(); b.close()
def handle(c):
    try:
        req = b''
        while b'\r\n\r\n' not in req:
            d = c.recv(4096)
            if not d: c.close(); return
            req += d
        line = req.split(b'\r\n')[0].decode()
        method, target, _ = line.split(' ', 2)
        host = target.split(':')[0]
        if method != 'CONNECT' or host == 'api.typesafe.ai':
            LOG.write(f'REFUSED {line}\n'); c.sendall(b'HTTP/1.1 403 Forbidden\r\n\r\n'); c.close(); return
        LOG.write(f'TUNNEL {line}\n')
        h, p = target.rsplit(':', 1)
        u = socket.create_connection((h, int(p)), timeout=30)
        c.sendall(b'HTTP/1.1 200 Connection Established\r\n\r\n')
        pipe(c, u)
    except Exception as e:
        LOG.write(f'ERROR {e}\n'); c.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', PORT)); s.listen(64)
while True:
    c, _ = s.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
