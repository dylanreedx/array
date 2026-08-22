import json, subprocess, sys, threading, time, os, signal
W=sys.argv[1]
t0=time.monotonic(); ts=lambda: round(time.monotonic()-t0,3)
p=subprocess.Popen(["pi","-p","--mode","rpc","--no-session"],cwd=W,
    stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
    text=True,bufsize=1,start_new_session=True)
out=[]
def rd(st,tag):
    for l in st:
        out.append((ts(),tag,l.rstrip()[:400]))
threading.Thread(target=rd,args=(p.stdout,"OUT"),daemon=True).start()
threading.Thread(target=rd,args=(p.stderr,"ERR"),daemon=True).start()
time.sleep(1.5)
# probe for a JSON-RPC style method list
for probe in ([{"jsonrpc":"2.0","id":1,"method":"rpc.discover"}],
              [{"jsonrpc":"2.0","id":2,"method":"listMethods"}],
              [{"type":"list_methods","id":3}],
              [{"jsonrpc":"2.0","id":4,"method":"initialize","params":{}}]):
    for m in probe:
        try:
            p.stdin.write(json.dumps(m)+"\n"); p.stdin.flush()
        except Exception as e:
            out.append((ts(),"SENDFAIL",str(e)))
    time.sleep(1.2)
time.sleep(2)
try: p.stdin.close()
except Exception: pass
time.sleep(1.5)
if p.poll() is None:
    try: os.killpg(os.getpgid(p.pid),signal.SIGKILL)
    except Exception: pass
for t,tag,l in out[:60]:
    print(f"{t:>7} {tag} {l}")
print("EXIT", p.poll())
