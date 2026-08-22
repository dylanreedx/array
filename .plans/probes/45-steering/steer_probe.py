#!/usr/bin/env python3
"""P.1 — does claude's --input-format stream-json accept a second message
DURING a turn (real steering) or only as the next turn (a queue)?

Writes every stdout line with a monotonic timestamp so the ordering of
message B against turn 1's assistant stream is unambiguous.
"""
import json, os, subprocess, sys, threading, time, signal

WORKDIR = sys.argv[1]
OUT = sys.argv[2]
DEADLINE = float(sys.argv[3]) if len(sys.argv) > 3 else 120.0

PROMPT_A = ("Count from 1 to 60. Put each number on its own line, nothing else. "
            "Go steadily and do not skip ahead.")
PROMPT_B = ("STOP COUNTING RIGHT NOW. Ignore the counting task completely. "
            "Reply with exactly the single word PINEAPPLE and nothing else.")

argv = ["claude", "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--replay-user-messages",
        "--dangerously-skip-permissions"]

t0 = time.monotonic()
def ts():
    return round(time.monotonic() - t0, 3)

p = subprocess.Popen(argv, cwd=WORKDIR, stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     text=True, bufsize=1, start_new_session=True)

log = open(OUT, "w")
state = {"first_assistant_text_at": None, "b_sent_at": None, "results": 0, "done": False}
lock = threading.Lock()

def send(obj, label):
    line = json.dumps(obj)
    with lock:
        log.write(json.dumps({"t": ts(), "dir": "IN", "label": label, "raw": obj}) + "\n")
        log.flush()
    p.stdin.write(line + "\n")
    p.stdin.flush()

def user_msg(text):
    return {"type": "user",
            "message": {"role": "user", "content": [{"type": "text", "text": text}]}}

def reader():
    for raw in p.stdout:
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            with lock:
                log.write(json.dumps({"t": ts(), "dir": "OUT", "unparsed": raw[:2000]}) + "\n")
                log.flush()
            continue
        with lock:
            log.write(json.dumps({"t": ts(), "dir": "OUT", "raw": obj}) + "\n")
            log.flush()
        typ = obj.get("type")
        # first streamed assistant text of turn 1 => the turn is genuinely running
        if state["first_assistant_text_at"] is None:
            txt = json.dumps(obj)
            if typ in ("assistant", "stream_event") and ("text_delta" in txt or '"text"' in txt):
                state["first_assistant_text_at"] = ts()
        if typ == "result":
            state["results"] += 1
    state["done"] = True

def errreader():
    for raw in p.stderr:
        with lock:
            log.write(json.dumps({"t": ts(), "dir": "ERR", "raw": raw.rstrip()[:2000]}) + "\n")
            log.flush()

threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=errreader, daemon=True).start()

send(user_msg(PROMPT_A), "A: count to 60")

# wait until turn 1 is demonstrably streaming, then interrupt mid-turn
while state["first_assistant_text_at"] is None and time.monotonic() - t0 < 45 and not state["done"]:
    time.sleep(0.05)

if state["first_assistant_text_at"] is None:
    with lock:
        log.write(json.dumps({"t": ts(), "dir": "NOTE",
                              "msg": "no assistant text before 45s; sending B anyway"}) + "\n")
        log.flush()
else:
    time.sleep(1.2)  # let a few numbers stream so 'mid-turn' is unambiguous

state["b_sent_at"] = ts()
send(user_msg(PROMPT_B), "B: mid-turn steer")

# keep stdin OPEN so a queued message can still be consumed; close only near the end
while time.monotonic() - t0 < DEADLINE - 8 and not state["done"]:
    time.sleep(0.2)

try:
    p.stdin.close()
except Exception:
    pass

while time.monotonic() - t0 < DEADLINE and not state["done"]:
    time.sleep(0.2)

if p.poll() is None:
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except Exception:
        pass
    time.sleep(1.5)
    if p.poll() is None:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except Exception:
            pass

summary = {"t": ts(), "dir": "SUMMARY",
           "first_assistant_text_at": state["first_assistant_text_at"],
           "b_sent_at": state["b_sent_at"],
           "result_events": state["results"],
           "exit": p.poll()}
with lock:
    log.write(json.dumps(summary) + "\n")
    log.flush()
log.close()
print(json.dumps(summary))
