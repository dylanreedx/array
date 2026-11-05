#!/usr/bin/env python3
"""Production managed Codex runner/MCP fixture. No model or network provider."""
from pathlib import Path
source = Path(__file__).with_name('codex-hook-cli.py').read_text()
insertion = r'''
def card4_call(tool, arguments):
    config = {}
    for arg in sys.argv:
        prefix = 'mcp_servers.array_workspace.'
        if arg.startswith(prefix):
            key, value = arg[len(prefix):].split('=', 1)
            if key == 'command' or key.startswith('env.'):
                config[key] = json.loads(value)
    environment = os.environ.copy()
    environment.update({key[4:]: value for key, value in config.items() if key.startswith('env.')})
    calls = [dict(jsonrpc='2.0', id=1, method='initialize', params={}),
             dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name=tool, arguments=arguments))]
    result = subprocess.run([config['command']], input=''.join(json.dumps(c)+'\n' for c in calls),
                            text=True, capture_output=True, env=environment, timeout=20)
    replies = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    reply = next(row for row in replies if row.get('id') == 2)
    record(dict(kind='card4-call', tool=tool, reply=reply))
    payload = reply.get('result', {}).get('structuredContent', {})
    if result.returncode or payload.get('status') == 'error' or reply.get('result', {}).get('isError'):
        raise RuntimeError('card4 MCP refused: '+json.dumps(reply))
    return payload.get('result', {})

def card4_turn(message):
    text = '\n'.join(item.get('text', '') for item in message.get('params', {}).get('input', []))
    record(dict(kind='card4-prompt', session=session_id, text=text))
    if ' finished: ' in text:
        record(dict(kind='card4-wake', text=text))
    elif text == 'CARD4-DELEGATE':
        handles, notes = [], []
        for index in range(3):
            result = card4_call('array_delegate', dict(task='CARD4-HELPER-'+str(index),
                title='Card4 helper '+str(index), idempotencyKey='card4-delegate-'+str(index)))
            handles.append(result['operationId'])
            notes.append(result.get('coordinationNote'))
        # This deterministic fixture follows the tool's returned coordination
        # policy, rather than pretending to infer model behavior from prose.
        if not all(notes):
            card4_call('wait_agents', dict(handles=handles, timeoutSeconds=5))
        record(dict(kind='card4-delegated', handles=handles, notes=notes))
    elif 'CARD4-HELPER-' in text:
        index = re.search(r'CARD4-HELPER-([0-2])', text)[1]
        record(dict(kind='card4-helper-ready', index=index))
        flag = managed_log + '.helper-' + index
        deadline = time.monotonic()+45
        while not os.path.exists(flag) and time.monotonic()<deadline: time.sleep(.01)
        if not os.path.exists(flag): raise RuntimeError('helper release timed out')
        os.unlink(flag)
        card4_call('array_report', dict(summary='CARD4-RESULT-'+index))
    elif 'CARD4-BUSY' in text:
        record(dict(kind='card4-busy'))
        flag = managed_log + '.lead-release'
        deadline = time.monotonic()+20
        while not os.path.exists(flag) and time.monotonic()<deadline: time.sleep(.01)
        if not os.path.exists(flag): raise RuntimeError('lead release timed out')
        os.unlink(flag)
'''
source = source.replace('for line in sys.stdin:', insertion+'\nfor line in sys.stdin:', 1)
source = source.replace("        emit(dict(method='turn/completed'", "        card4_turn(message)\n        emit(dict(method='turn/completed'", 1)
exec(compile(source, str(Path(__file__)), 'exec'))
