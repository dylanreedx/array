#!/usr/bin/env python3
"""Trusted process-group owner. Only the host supplies executable/argv."""
import os
import resource
import selectors
import signal
import subprocess
import sys
import time

# The group is owned before spawning anything. Swift's fallback kills this
# whole group if this controller ever stops responding.
if os.getpgrp() != os.getpid():
    os.setsid()
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
# Darwin rejects DATA/AS resource limits for the system Python. Enforce a
# group resident-memory watchdog instead; CPU/file limits remain kernel-owned.
resident_limit_kib = 256 * 1024
resource.setrlimit(resource.RLIMIT_CPU, (8, 8))
resource.setrlimit(resource.RLIMIT_FSIZE, (2 * 1024 * 1024,) * 2)
os.environ["ARRAY_PREPASS_OWNED_GROUP"] = str(os.getpgrp())
limit = 1048576
timeout = 8
# Test-only parameters are supplied solely by the fixture driver, never reports.
if sys.argv[1:2] == ["--limits"]:
    timeout, limit = float(sys.argv[2]), int(sys.argv[3])
    del sys.argv[1:4]
child = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
streams = selectors.DefaultSelector()
for stream in (child.stdout, child.stderr):
    os.set_blocking(stream.fileno(), False)
    streams.register(stream, selectors.EVENT_READ)
output = bytearray()
total = 0
deadline = time.monotonic() + timeout
next_memory_check = 0
def abort():
    os.killpg(os.getpgrp(), signal.SIGKILL)
try:
    while streams.get_map():
        if time.monotonic() >= deadline:
            abort()
        now = time.monotonic()
        if now >= next_memory_check:
            census = subprocess.run(["/bin/ps", "-o", "rss=", "-g", str(os.getpgrp())],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=.5)
            if census.returncode != 0 or len(census.stdout) > 4096:
                abort()
            if sum(int(row) for row in census.stdout.split()) > resident_limit_kib:
                abort()
            next_memory_check = now + .05
        for key, _ in streams.select(0.02):
            data = os.read(key.fd, 16384)
            if not data:
                streams.unregister(key.fileobj)
                continue
            total += len(data)
            if total > limit:
                abort()
            if key.fileobj is child.stdout:
                output.extend(data)
    remaining = max(0.001, deadline - time.monotonic())
    status = child.wait(timeout=remaining)
except BaseException:
    abort()
sys.stdout.buffer.write(output)
sys.stdout.buffer.flush()
raise SystemExit(status if status >= 0 else 2)
