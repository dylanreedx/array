#!/usr/bin/env python3
"""No-model Claude stream-json fixture for the Managed Duckherd witness.

Logs its argv and every stdin user message to ARRAY_DUCKHERD_FIXTURE_LOG, and
answers each message the way claude 2.1.317 does: a slash command that a plugin
handles comes back as one synthetic result with no model call, anything else as
an assistant text and a result.
"""
import json, os, sys
log = os.environ['ARRAY_DUCKHERD_FIXTURE_LOG']
def record(entry):
    with open(log, 'a') as f: f.write(json.dumps(entry) + '\n')
record({'argv': sys.argv[1:], 'config_dir': os.environ.get('CLAUDE_CONFIG_DIR')})
for line in sys.stdin:
    request = json.loads(line)
    if request.get('type') != 'user': continue
    content = request['message']['content']
    text = content if isinstance(content, str) else ' '.join(b.get('text', '') for b in content if b.get('type') == 'text')
    record({'stdin': text})
    if text.strip().lower() == '/duckherd off':
        answer = 'duckherd: Duckherd off for this session: plain Claude from your next message.'
    else:
        answer = 'echo: ' + text
    print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'fixture'}), flush=True)
    print(json.dumps({'type': 'stream_event', 'session_id': 'fixture', 'parent_tool_use_id': None,
                      'event': {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': answer}}}), flush=True)
    print(json.dumps({'type': 'assistant', 'message': {'id': 'm-' + str(abs(hash(text))), 'role': 'assistant',
                      'content': [{'type': 'text', 'text': answer}]}, 'session_id': 'fixture'}), flush=True)
    print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': answer, 'session_id': 'fixture',
                      'num_turns': 1, 'duration_ms': 1, 'total_cost_usd': 0, 'usage': {}}), flush=True)
