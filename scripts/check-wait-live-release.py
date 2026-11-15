#!/usr/bin/env python3
"""Drive the production live-release wait against a local server that deploys late; no network."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import threading
import time

SCRIPT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).with_name("wait-live-release.py")
FEED = '''<?xml version='1.0' encoding='UTF-8'?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Array</title>{new}
        <item>
            <title>0.7.50</title>
            <sparkle:version>101</sparkle:version>
            <sparkle:shortVersionString>0.7.50</sparkle:shortVersionString>
            <enclosure url="{base}../v0.7.50/Array-0.7.50.dmg" length="1" type="application/octet-stream" />
        </item>
    </channel>
</rss>
'''
NEW_ITEM = '''
        <item>
            <title>0.7.51</title>
            <sparkle:version>102</sparkle:version>
            <sparkle:shortVersionString>0.7.51</sparkle:shortVersionString>
            <enclosure url="{base}Array-0.7.51.dmg" length="1" type="application/octet-stream" />
        </item>'''


def serve(stale_polls, missing=None):
    """stale_polls feed requests get the old feed; None means it never deploys."""
    log = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, body=b"", location=None):
            self.send_response(status)
            if location:
                self.send_header("Location", location)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command == "GET":
                self.wfile.write(body)

        def handle_one(self):
            path, _, query = self.path.partition("?")
            log.append((self.command, path, query, self.headers.get("Cache-Control")))
            base = f"http://127.0.0.1:{server.server_port}/download/v0.7.51/"
            if path == "/appcast.xml" and self.command == "GET":
                polls = sum(1 for entry in log if entry[1] == path)
                deployed = stale_polls is not None and polls > stale_polls
                body = FEED.format(new=NEW_ITEM.format(base=base) if deployed else "", base=base)
                return self.reply(200, body.encode())
            if self.command != "HEAD":
                return self.reply(405)
            if path.rsplit("/", 1)[-1] == missing:
                return self.reply(404)
            if path == "/download/v0.7.51/Array-0.7.51.dmg":
                return self.reply(302, location="/blob/Array-0.7.51.dmg")
            if path in ("/download/v0.7.51/Array.dmg", "/blob/Array-0.7.51.dmg"):
                return self.reply(200)
            self.reply(404)

        do_GET = do_HEAD = handle_one

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, log


def wait(server, timeout):
    port = server.server_port
    started = time.monotonic()
    result = subprocess.run([sys.executable, str(SCRIPT), "--build", "102", "--version", "0.7.51",
                             "--feed-url", f"http://127.0.0.1:{port}/appcast.xml",
                             "--download-base", f"http://127.0.0.1:{port}/download/v0.7.51/",
                             "--timeout", str(timeout), "--interval", "0.2"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    server.shutdown()
    return result, time.monotonic() - started


def live_after_wait():
    server, log = serve(stale_polls=2)
    result, _ = wait(server, 10)
    feeds = [entry for entry in log if entry[1] == "/appcast.xml"]
    assert result.returncode == 0, f"exit {result.returncode}: {result.stdout}"
    assert len(feeds) >= 3, f"went live after {len(feeds)} feed poll(s); expected it to wait out 2 stale ones"
    assert "feed still serves build 101; Vercel has not deployed build 102 yet" in result.stdout, result.stdout
    assert len({q for _, _, q, _ in feeds}) == len(feeds) and all(q and c == "no-cache" for _, _, q, c in feeds), \
        f"feed polls are not cache-busted: {feeds}"
    downloads = [entry for entry in log if entry[1] != "/appcast.xml"]
    assert all(method == "HEAD" for method, *_ in downloads), f"downloaded a DMG body: {downloads}"
    assert {p for _, p, *_ in downloads} >= {"/download/v0.7.51/Array.dmg", "/blob/Array-0.7.51.dmg"}, downloads


def never_deploys():
    server, _ = serve(stale_polls=None)
    result, elapsed = wait(server, 1)
    assert result.returncode == 1, f"exit {result.returncode}: {result.stdout}"
    assert elapsed < 10, f"took {elapsed:.1f}s against a 1s timeout"
    assert "NOT LIVE" in result.stdout and "feed still serves build 101" in result.stdout, result.stdout


def missing_asset():
    server, _ = serve(stale_polls=0, missing="Array.dmg")
    result, _ = wait(server, 1)
    assert result.returncode == 1, f"exit {result.returncode}: {result.stdout}"
    assert "NOT LIVE" in result.stdout and "Array.dmg returns 404" in result.stdout, result.stdout


failures = []
for case in (live_after_wait, never_deploys, missing_asset):
    try:
        case()
        print("PASS", case.__name__)
    except AssertionError as error:
        failures.append(case.__name__)
        print("FAIL", case.__name__, error)
if failures:
    raise SystemExit(1)
print("PASS production live-release wait against a late local deploy")
