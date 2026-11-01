"""Measure the REAL local continuum-relay presence lane: publish rate in,
delivery rate and age out, at a simulated one-way network delay."""
import base64, http.client, json, os, socket, subprocess, sys, threading, time, uuid, statistics, tempfile

RELAY = sys.argv[1]
DELAY = float(sys.argv[2]) / 1000.0 if len(sys.argv) > 2 else 0.0   # one-way seconds
MODE = sys.argv[3] if len(sys.argv) > 3 else "pipelined"            # pipelined | gated
DURATION = 6.0

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
root = tempfile.mkdtemp(prefix="mp-polish-relay.")
port, admin = free_port(), free_port()
env = {k: v for k, v in os.environ.items() if not k.startswith(("RELAY_", "APNS_"))}
env.update(RELAY_HOST="127.0.0.1", PORT=str(port), RELAY_ADMIN_PORT=str(admin),
    RELAY_DATABASE_PATH=root + "/relay.sqlite", RELAY_MASTER_KEY=base64.b64encode(os.urandom(32)).decode(),
    RELAY_COLLABORATION_DATABASE_PATH=root + "/collab.sqlite", RELAY_COLLABORATION_MASTER_KEY=base64.b64encode(os.urandom(32)).decode())
server = subprocess.Popen([RELAY], env=env, stdout=open(root + "/relay.log", "w"), stderr=subprocess.STDOUT)
for _ in range(150):
    try: socket.create_connection(("127.0.0.1", port), timeout=0.1).close(); break
    except OSError: time.sleep(0.1)

class Client:
    def __init__(self, token=None): self.token = token; self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=40)
    def req(self, method, path, body=None):
        time.sleep(DELAY)
        headers = {"content-type": "application/json"}
        if self.token: headers["authorization"] = "Bearer " + self.token
        self.conn.request(method, "/collaboration/v1/" + path, body=None if body is None else json.dumps(body), headers=headers)
        r = self.conn.getresponse(); data = r.read()
        time.sleep(DELAY)
        if r.status >= 300: raise RuntimeError(f"{method} {path} -> {r.status} {data[:200]}")
        return json.loads(data) if data else None

def enroll(label):
    out = subprocess.run([RELAY, "--collaboration-enroll", label], env=env, capture_output=True, text=True, check=True).stdout
    e = json.loads(out); cred = Client().req("POST", "enrollments/redeem", {"code": e["code"], "deviceLabel": label})
    return cred
try:
    ca, cb = enroll("A"), enroll("B")
    A, B = Client(ca["token"]), Client(cb["token"])
    state = A.req("POST", "areas"); area = state["scope"]["area"]
    area_id = area if isinstance(area, str) else area.get("rawValue")
    inv = A.req("POST", f"areas/{area_id}/invitations", {"person": cb["identity"]["person"], "role": "editor", "lifetime": 3600})
    B.req("POST", "invitations/accept", {"code": inv["code"]})
    bstate = B.req("GET", f"areas/{area_id}")
    revision = bstate["document"]["revision"]
    session = A.req("POST", f"areas/{area_id}/presence-sessions")["id"]
    t0 = time.time(); stop = threading.Event()
    sent = []; inflight_max = [0]; mouse = []
    def publisher():
        # 60 Hz mouse. gated = today's app policy: one request in flight, >=50 ms apart,
        # moves during a flight are DROPPED. pipelined = every 60 Hz sample posted.
        seq = 0; last = 0.0; lock = threading.Lock(); flying = [0]; conns = [Client(ca["token"]) for _ in range(6)]
        def post(c, s, x):
            with lock: flying[0] += 1; inflight_max[0] = max(inflight_max[0], flying[0])
            try: c.req("POST", f"areas/{area_id}/presence", {"session": session, "sequence": s, "cursor": {"x": x, "y": 1}})
            finally:
                with lock: flying[0] -= 1
        while not stop.is_set():
            now = time.time() - t0
            if now > DURATION: break
            x = now * 1000.0; mouse.append((now, x))
            if MODE == "gated":
                if flying[0] == 0 and now - last >= 0.05:
                    seq += 1; last = now; sent.append((now, x)); threading.Thread(target=post, args=(conns[0], seq, x)).start()
            else:
                seq += 1; sent.append((now, x))
                threading.Thread(target=post, args=(conns[seq % 6], seq, x)).start()
            time.sleep(1/60)
    got = []
    def receiver():
        version = None
        while not stop.is_set():
            page = B.req("POST", f"areas/{area_id}/updates", {"subscriptionID": str(uuid.uuid4()), "after": revision, "presenceVersion": version, "waitMilliseconds": 2000})
            version = page["presenceVersion"]; now = time.time() - t0
            for p in page.get("presence", []):
                c = p.get("cursor")
                if c and p["identity"]["device"] == ca["identity"]["device"]: got.append((now, c["x"]))
    rt = threading.Thread(target=receiver, daemon=True); rt.start()
    pt = threading.Thread(target=publisher); pt.start(); pt.join()
    if MODE == "gated":
        time.sleep(1.0 - ((time.time() - t0) % 1.0))  # the 1 s presence timer fires on its own grid
        A.req("POST", f"areas/{area_id}/presence", {"session": session, "sequence": 10**9, "cursor": {"x": mouse[-1][1], "y": 1}})
    time.sleep(1.5); stop.set()
    final_x = mouse[-1][1]; reached = next((t for t, x in got if x == final_x), None)
    steady = [(t, x) for t, x in got if 1.0 < t < DURATION]
    ages = [t * 1000 - x for t, x in steady]
    gaps = [b[0] - a[0] for a, b in zip(steady, steady[1:]) if b[1] != a[1]]
    distinct = len({x for _, x in steady})
    print(f"one-way={DELAY*1000:.0f}ms mode={MODE}: posted {len([s for s in sent if s[0] > 1])/(DURATION-1):.1f}/s (max in flight {inflight_max[0]}), "
          f"delivered {distinct/(DURATION-1):.1f} distinct/s, age at delivery median {statistics.median(ages):.0f} ms p90 {sorted(ages)[int(len(ages)*.9)]:.0f} ms, "
          f"gap between deliveries median {statistics.median(gaps)*1000:.0f} ms max {max(gaps)*1000:.0f} ms, "
          f"final position delivered {('%.0f ms after the last move' % ((reached - mouse[-1][0]) * 1000)) if reached else 'NEVER'}")
finally:
    server.terminate(); server.wait(timeout=10)
