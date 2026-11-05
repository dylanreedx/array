#!/usr/bin/env python3
"""Offline behavioral check of the real MCP binary; never starts a provider."""
import http.server, json, os, pathlib, queue, subprocess, tempfile, threading, time, sys

state = {'reason': None, 'polled': threading.Event(), 'anypoll': threading.Event(),
         'stall_started': threading.Event(), 'release': threading.Event(), 'lookups': 0}
class Host(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert body['op'] == 'operation.get'
        state['anypoll'].set()
        pending = body['payload'].get('pendingInputOnly')
        if (pending and state.get('stall_input')) or (not pending and state.get('stall_lookup')):
            state['stall_started'].set()
            if state.get('trickle'):
                self.send_response(200); self.end_headers()
                while not state['release'].wait(0.1):
                    try: self.wfile.write(b' '); self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError): break
            else:
                state['release'].wait(70)
            return
        if pending:
            result = {'pendingInput': state['reason']}
            state['polled'].set()
        else:
            state['lookups'] += 1
            done = body['payload'].get('operationId') == 'settled-helper'
            result = {'childRunning': not done, 'childAgentId': 'fixture-child'}
            if done: result['childResult'] = {'status':'completed','finalText':'fixture answer'}
            if state.get('interrupt_after_snapshot') and not done:
                state['reason'] = 'user_steer'
                state['stall_lookup'] = True
        data = json.dumps({'status': 'ok', 'result': result}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(data)

host = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Host)
threading.Thread(target=host.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='array-wait-check-') as root:
    token = pathlib.Path(root)/'token'; token.write_text('fixture')
    env = dict(os.environ, ARRAY_WORKSPACE_MCP_ENDPOINT=f'http://127.0.0.1:{host.server_port}',
               ARRAY_WORKSPACE_AGENT_ID='fixture-lead', ARRAY_WORKSPACE_MCP_TOKEN_FILE=str(token))
    proc = subprocess.Popen([os.environ.get('ARRAY_WAIT_CHECK_EXECUTABLE', '.build/debug/array-workspace-mcp')], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    replies = queue.Queue()
    def read():
        for line in proc.stdout: replies.put(json.loads(line))
    threading.Thread(target=read, daemon=True).start()
    def send(method, params, id=None):
        request = dict(jsonrpc='2.0', method=method, params=params)
        if id is not None: request['id'] = id
        proc.stdin.write(json.dumps(request)+'\n'); proc.stdin.flush()
    def result(id, timeout=2):
        reply = replies.get(timeout=timeout)
        assert reply['id'] == id, reply
        return json.loads(reply['result']['content'][0]['text'])['result']
    try:
        # Both MCP consumers use this exact server, including their distinct id types.
        for harness, id in ([] if any(arg in sys.argv for arg in ['--cancel-only', '--stalled-only', '--deadline-only']) else [('claude', 'tool-fixture'), ('codex', 42)]):
            for reason in ['user_steer', 'inbox']:
                state['reason'] = None; state['polled'].clear()
                send('tools/call', {'name':'wait_agents','arguments':{'handles':['helper'], 'timeoutSeconds':600}}, id)
                assert state['polled'].wait(2), 'wait never polled pending input'
                started = time.monotonic(); state['reason'] = reason
                r = result(id)
                assert time.monotonic()-started < 2
                assert r['interrupted'] == reason and r['timedOut'] is False and r['agents'][0]['status'] == 'running', r
                print(f'PASS {harness}: 600s requested wait interrupted by {reason} within 2s')
        if not any(arg in sys.argv for arg in ['--cancel-only', '--stalled-only', '--deadline-only']):
            state['reason'] = None; state['interrupt_after_snapshot'] = True; state['lookups'] = 0
            send('tools/call', {'name':'wait_agents','arguments':{'handles':['settled-helper', 'helper'],'timeoutSeconds':600}}, 'settled')
            r = result('settled')
            assert r['agents'][0]['status'] == 'completed' and r['interrupted'] == 'user_steer', r
            assert r['agents'][1]['childAgentId'] == 'fixture-child' and state['lookups'] == 2, r
            state['interrupt_after_snapshot'] = False; state['stall_lookup'] = False
            print('PASS interrupted wait retains an already settled helper answer')
        state['reason'] = None; state['anypoll'].clear()
        send('tools/call', {'name':'wait_agents','arguments':{'handles':['helper'],'timeoutSeconds':600}}, 'cancel-me')
        assert state['anypoll'].wait(2)
        # Wrong id must leave the wait alive; ping is answered independently.
        send('notifications/cancelled', {'requestId':'other'})
        send('ping', {}, 'ping')
        assert replies.get(timeout=2)['id'] == 'ping'
        send('notifications/cancelled', {'requestId':'cancel-me'})
        r = result('cancel-me')
        assert r['interrupted'] == 'cancelled' and not r['timedOut'], r
        print('PASS cancellation targets matching request and returns within 2s')
        if '--cancel-only' not in sys.argv:
            # A lookup already in flight must not hide subsequent input. Cover
            # batches too: checking input only after all 16 lookups is too late.
            for reason in ([] if '--deadline-only' in sys.argv else ['user_steer', 'inbox', 'cancelled']):
                state['reason'] = None; state['stall_lookup'] = True
                state['stall_started'].clear()
                id = 'stalled-' + reason
                send('tools/call', {'name':'wait_agents','arguments':{
                    'handles':[f'helper-{n}' for n in range(16)],'timeoutSeconds':600}}, id)
                assert state['stall_started'].wait(2), 'lookup did not start'
                started = time.monotonic()
                if reason == 'cancelled': send('notifications/cancelled', {'requestId':id})
                else: state['reason'] = reason
                r = result(id)
                assert time.monotonic()-started < 2 and r['interrupted'] == reason, r
                assert len(r['agents']) == 16 and not r['timedOut'], r
                print(f'PASS stalled lookup: {reason} returns within 2s for 16 handles', flush=True)
            # Cancellation must also abort the pending-input HTTP request itself.
            state['reason'] = None; state['stall_lookup'] = False; state['stall_input'] = True
            state['stall_started'].clear()
            send('tools/call', {'name':'wait_agents','arguments':{'handles':['helper'],'timeoutSeconds':600}}, 'cancel-input')
            assert state['stall_started'].wait(2)
            send('notifications/cancelled', {'requestId':'cancel-input'})
            assert result('cancel-input')['interrupted'] == 'cancelled'
            print('PASS stalled pending-input request: cancellation returns within 2s', flush=True)
            # Real elapsed-time bounds, including trickled responses that keep
            # resetting an HTTP idle timeout. The final request tests the 60s cap.
            for stage, seconds, trickle in [('input',5,False), ('lookup',5,True), ('lookup',600,False)]:
                state['stall_input'] = stage == 'input'; state['stall_lookup'] = stage == 'lookup'
                state['trickle'] = trickle
                started = time.monotonic(); id = f'deadline-{stage}-{seconds}'
                send('tools/call', {'name':'wait_agents','arguments':{'handles':['helper'],'timeoutSeconds':seconds}}, id)
                r = result(id, min(seconds, 60)+2)
                elapsed = time.monotonic()-started
                assert min(seconds,60)-0.5 <= elapsed < min(seconds,60)+2, elapsed
                assert r['timedOut'] and 'interrupted' not in r, r
                print(f'PASS stalled {stage}: requested {seconds}s returns timedOut in {elapsed:.2f}s (trickle={trickle})', flush=True)
            state['stall_input'] = False; state['stall_lookup'] = False; state['trickle'] = False
        send('tools/list', {}, 'catalog')
        catalog = replies.get(timeout=2)['result']['tools']
        wait = next(t for t in catalog if t['name']=='wait_agents')
        assert wait['inputSchema']['properties']['timeoutSeconds']['maximum'] == 60
        print('PASS wait timeout cap advertised as 60s')
    finally:
        proc.terminate(); proc.wait(timeout=5); state['release'].set(); host.shutdown()
