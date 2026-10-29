#!/usr/bin/env python3
"""Loopback-only fake serve-sim: MJPEG + tagged binary HID WebSocket.

This changes labeled fixture pixels in response to input. It is not a simulator.
No external Python/Node dependencies, and no exec routes or device operations.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

DEVICE = "11111111-1111-4111-8111-111111111111"
parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
args = parser.parse_args()
condition = threading.Condition()
state = dict(events=[], streams=0, sockets=0, changed=False, dark=False, generation=0)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        route = urlsplit(self.path)
        if route.path == "/events":
            with condition:
                self.reply(dict(state))
        elif route.path == "/dark":
            with condition:
                state["dark"] = True
                state["generation"] += 1
                condition.notify_all()
            self.reply({"dark": True})
        elif route.path == f"/helper/{DEVICE}/stream.mjpeg":
            self.stream()
        elif route.path == "/helper/ws" and parse_qs(route.query).get("device") == [DEVICE]:
            self.websocket()
        else:
            self.send_error(404)

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Connection", "close")
        self.end_headers()
        with condition:
            state["streams"] += 1
        try:
            while True:
                with condition:
                    theme = "dark" if state["dark"] else "light"
                    status = "changed" if state["changed"] else "initial"
                body = (args.directory / f"{theme}-{status}.jpg").read_bytes()
                self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " +
                                 str(len(body)).encode() + b"\r\n\r\n" + body + b"\r\n")
                self.wfile.flush()
                with condition:
                    condition.wait(timeout=0.1)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with condition:
                state["streams"] -= 1

    def websocket(self):
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept.decode())
        self.end_headers()
        self.wfile.write(b"\x82\x01\x83")  # serve-sim binary input-admitted tag
        self.wfile.flush()
        with condition:
            state["sockets"] += 1
        try:
            while True:
                head = self.rfile.read(2)
                if len(head) != 2 or head[0] & 15 == 8:
                    return
                length = head[1] & 127
                if length == 126:
                    length = struct.unpack("!H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.rfile.read(8))[0]
                if length > 4096:
                    return
                mask = self.rfile.read(4) if head[1] & 128 else b"\0" * 4
                payload = self.rfile.read(length)
                payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
                if head[0] & 15 != 2 or not payload:
                    continue
                event = json.loads(payload[1:])
                event["tag"] = payload[0]
                with condition:
                    state["events"].append(event)
                    state["changed"] = True
                    condition.notify_all()
        except (ConnectionError, ValueError):
            pass
        finally:
            with condition:
                state["sockets"] -= 1
            self.close_connection = True


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(args.directory / "origin.txt").write_text(f"http://127.0.0.1:{server.server_port}")
server.serve_forever()
