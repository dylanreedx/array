#!/usr/bin/env python3
"""P.2 — does claude honour a control_request/interrupt mid-turn, and does the
control_response carry still_queued?

Sequence: long prompt A -> wait for real assistant streaming -> queue prompt B
(so still_queued has something to report) -> send control_request interrupt ->
capture the control_response and whether turn 1 ends early.
"""
import json, os, subprocess, sys, threading, time, signal, uuid

WORKDIR, OUT = sys.argv[1], sys.argv[2]
DEADLINE = float(sys.argv[3]) if len(sys.argv) > 3 else 150.0

PROMPT_A = ("Write a detailed 3000-word essay on the history of the bicycle. "
            "Write the full essay in prose; do not summarise.")
PROMPT_B = "Separately, what is 2+2? Answer with just the number."

argv = ["claude", "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose", "--include-partial-messages", "--replay-user-messages",
        "--dangerously-skip-permissions"]

t0 = time.monotonic()
ts = lambda: round(time.monotonic() - t0, 3)

p = subprocess.Popen(argv, cwd=WORKDIR, stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, bufsize=1, start_new_session=True)
log = open(OUT, "w"); lock = threading.Lock()
st = {"deltas": 0, "done": False, "results": 0, "ctrl_responses": []}

def emit(rec):
    with lock:
        log.write(json.dumps(rec) + "\n"); log.flush()

def send(obj, label):
    emit({"t": ts(), "dir": "IN", "label": label, "raw": obj})
    p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()

def user_msg(text):
    return {"type": "user",
            "message": {"role": "user", "content": [{"type": "text", "text": text}]}}

def reader():
    for raw in p.stdout:
        raw = raw.strip()
        if not raw: continue
        try: obj = json.loads(raw)
        except Exception:
            emit({"t": ts(), "dir": "OUT", "unparsed": raw[:1000]}); continue
        typ = obj.get("type")
        if typ == "stream_event":
            ev = (obj.get("event") or {}).get("type")
            if ev == "content_block_delta":
                st["deltas"] += 1
                if st["deltas"] % 25 != 1:
                    continue   # sample, do not flood the log
        if typ == "control_response":
            st["ctrl_responses"].append(obj)
        if typ == "result":
            st["results"] += 1
        emit({"t": ts(), "dir": "OUT", "deltas": st["deltas"], "raw": obj})
    st["done"] = True

def errreader():
    for raw in p.stderr:
        emit({"t": ts(), "dir": "ERR", "raw": raw.rstrip()[:1000]})

threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=errreader, daemon=True).start()

send(user_msg(PROMPT_A), "A: long essay")

# wait for REAL assistant deltas, not the replayed user echo
while st["deltas"] < 40 and time.monotonic() - t0 < 60 and not st["done"]:
    time.sleep(0.05)
emit({"t": ts(), "dir": "NOTE", "msg": f"assistant deltas seen: {st['deltas']}"})

send(user_msg(PROMPT_B), "B: queued follow-up")
time.sleep(1.5)

rid = f"interrupt-{uuid.uuid4()}"
send({"type": "control_request", "request_id": rid,
      "request": {"subtype": "interrupt"}}, "C: control_request interrupt")

deadline_soft = time.monotonic() + 45
while time.monotonic() < deadline_soft and not st["done"]:
    time.sleep(0.2)
try: p.stdin.close()
except Exception: pass
while time.monotonic() - t0 < DEADLINE and not st["done"]:
    time.sleep(0.2)
if p.poll() is None:
    try: os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except Exception: pass
    time.sleep(1.5)
    if p.poll() is None:
        try: os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except Exception: pass

summary = {"t": ts(), "dir": "SUMMARY", "total_deltas": st["deltas"],
           "result_events": st["results"],
           "control_responses": st["ctrl_responses"], "exit": p.poll()}
emit(summary); log.close()
print(json.dumps(summary, indent=2))
