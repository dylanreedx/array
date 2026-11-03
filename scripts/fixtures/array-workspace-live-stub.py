#!/usr/bin/env python3
"""Stand-in for `array-workspace-mcp` in the opt-in live Managed/Duckherd leg.

Run with no arguments it is the stdio MCP server Array names `array_workspace`:
it lists Array's delegation tools and answers every call with a canned reply.
Run as `hook ...` it is Array's hook command: it logs the payload and replies
with the text the check wrote into replies.json from production
(`ManagedLeadHookState.brief`, `WorkspaceAgentHook.pushBackReason`).
Everything is logged next to this file.
"""
import json, os, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
def log(name, entry):
    with open(os.path.join(HERE, name), 'a') as f: f.write(json.dumps(entry) + '\n')

if len(sys.argv) > 1 and sys.argv[1] == 'hook':
    replies = json.load(open(os.path.join(HERE, 'replies.json')))
    raw = sys.stdin.read()
    try: payload = json.loads(raw)
    except Exception: payload = {}
    event = payload.get('hook_event_name', '')
    message = payload.get('last_assistant_message') or ''
    words = len(message.split())
    out = None
    if (replies.get('mode') == 'managed' and event == 'SessionStart' and payload.get('source') == 'startup'
            and payload.get('agent_id') is None):
        out = {'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': replies['brief']}}
    elif (replies.get('pushBack') and event == 'SubagentStop' and payload.get('stop_hook_active') is not True
            and words > replies['limit']):
        out = {'decision': 'block', 'reason': replies['pushBackTemplate'].replace('987654321', str(words))}
    log('hooks.jsonl', {'t': time.time(), 'event': event, 'agent_id': payload.get('agent_id'),
                        'agent_type': payload.get('agent_type'), 'stop_hook_active': payload.get('stop_hook_active'),
                        'words': words, 'message': message if event == 'SubagentStop' else None, 'reply': out})
    if out is not None: sys.stdout.write(json.dumps(out))
    sys.exit(0)

TOOLS = {
    'array_delegate': 'Run a task in a new visible agent tile on the user\'s Array canvas. Args: task (string), title (string).',
    'wait_agents': 'Wait for delegated child agents and collect their reports.',
    'array_report': 'Report your result to the agent that delegated to you.',
    'array_status': 'Post your plan and status to the Array canvas.',
    'array_workspace_context': 'Who and where you are on the canvas, and what you may do.',
}
def send(o): sys.stdout.write(json.dumps(o) + '\n'); sys.stdout.flush()
for line in sys.stdin:
    try: m = json.loads(line)
    except Exception: continue
    mid, method = m.get('id'), m.get('method')
    if method == 'initialize':
        send({'jsonrpc': '2.0', 'id': mid, 'result': {'protocolVersion': m['params'].get('protocolVersion', '2025-06-18'),
              'capabilities': {'tools': {}}, 'serverInfo': {'name': 'array_workspace', 'version': 'live-stub'}}})
    elif method == 'tools/list':
        send({'jsonrpc': '2.0', 'id': mid, 'result': {'tools': [{'name': k, 'description': v, 'inputSchema': {
              'type': 'object', 'properties': {'task': {'type': 'string'}, 'title': {'type': 'string'}, 'summary': {'type': 'string'}},
              'additionalProperties': True}} for k, v in TOOLS.items()]}})
    elif method == 'tools/call':
        name = m['params'].get('name')
        log('mcp.jsonl', {'t': time.time(), 'tool': name, 'args': m['params'].get('arguments')})
        text = ('The delegated helper finished. Its report: hello.txt has 3 lines.'
                if name in ('array_delegate', 'wait_agents') else 'ok')
        send({'jsonrpc': '2.0', 'id': mid, 'result': {'content': [{'type': 'text', 'text': text}]}})
    elif mid is not None:
        send({'jsonrpc': '2.0', 'id': mid, 'result': {}})
