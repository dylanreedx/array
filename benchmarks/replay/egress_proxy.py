"""Host-side HTTPS CONNECT proxy for live replay runs.

The sandbox filters network by address and port only, so a live run may reach
nothing but loopback; this proxy is the one way out. It tunnels CONNECT to an
allowed host on port 443 and refuses everything else. It never terminates
TLS, so it sees host names, never content or credentials. Every request is
logged as one JSON line: host, port, allowed.

usage: egress_proxy.py PORT_FILE LOG_FILE HOST [HOST ...]
Writes the chosen loopback port to PORT_FILE once listening."""
import json
import select
import socket
import socketserver
import sys
import threading
import time

LOCK = threading.Lock()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline(4096).decode('latin-1').strip()
        while True:
            header = self.rfile.readline(4096)
            if header in (b'\r\n', b'\n', b''):
                break
        parts = line.split()
        host, port = '', 0
        if len(parts) >= 2 and parts[0] == 'CONNECT' and ':' in parts[1]:
            host, _, text = parts[1].rpartition(':')
            port = int(text) if text.isdigit() else 0
        allowed = host.lower() in self.server.allowed and port == 443
        with LOCK, open(self.server.log, 'a') as log:
            log.write(json.dumps(dict(time=time.time(), method=parts[0] if parts else '', host=host,
                                      port=port, allowed=allowed)) + '\n')
        if not allowed:
            self.wfile.write(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
            return
        try:
            upstream = socket.create_connection((host, port), timeout=30)
        except OSError:
            self.wfile.write(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')
            return
        self.wfile.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
        self.wfile.flush()
        client = self.connection
        upstream.settimeout(None)
        client.settimeout(None)
        try:
            while True:
                ready, _, _ = select.select([client, upstream], [], [], 600)
                if not ready:
                    break
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is client else client).sendall(data)
        except OSError:
            pass
        finally:
            upstream.close()


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv):
    port_file, log, hosts = argv[0], argv[1], argv[2:]
    server = Server(('127.0.0.1', 0), Handler)
    server.allowed = {h.lower() for h in hosts}
    server.log = log
    with open(port_file, 'w') as out:
        out.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == '__main__':
    main(sys.argv[1:])
