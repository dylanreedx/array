#!/usr/bin/env python3
"""Offline Codex hook-surface/runner double. Never starts a provider or model."""
import hashlib, json, os, re, subprocess, sys, time, uuid

events = [('SessionStart', 'session_start'), ('UserPromptSubmit', 'user_prompt_submit'),
          ('PreToolUse', 'pre_tool_use'), ('PostToolUse', 'post_tool_use'), ('Stop', 'stop'),
          ('SubagentStart', 'subagent_start'), ('SubagentStop', 'subagent_stop')]
managed_log = os.environ.get('ARRAY_MANAGED_CODEX_LOG')
session_id = 'fixture-session'
source = 'startup'

def record(value):
    if managed_log:
        with open(managed_log, 'a') as f: f.write(json.dumps(dict(pid=os.getpid(), **value))+'\n')

missing = os.environ.get('ARRAY_HOOK_FIXTURE_MISSING') == '1'
if '--version' in sys.argv:
    print('codex-cli fixture-' + ('old' if missing else 'hooks'))
    sys.exit(0)

definitions = {}
trust = ''
for arg in sys.argv:
    if arg.startswith('hooks.state='):
        trust = arg
    for event, snake in events:
        if arg.startswith('hooks.' + event + '='):
            command = json.loads(re.search(r'command=("(?:[^"\\]|\\.)*")', arg)[1])
            definitions[event] = (command, arg)

def emit(value):
    print(json.dumps(value), flush=True)

def hook(event, tool=None):
    if event not in definitions:
        return
    command, _ = definitions[event]
    payload = dict(session_id=session_id, turn_id='fixture-turn', transcript_path='/tmp/fixture-rollout',
                   cwd=os.getcwd(), hook_event_name=event, model='fixture', permission_mode='never')
    if event == 'SessionStart': payload['source'] = source
    if event in ['Stop', 'SubagentStop']:
        payload.update(stop_hook_active=False, last_assistant_message='done')
    if event in ['SubagentStart', 'SubagentStop']:
        payload.update(agent_id='native-child', agent_type='default', agent_transcript_path='/tmp/fixture-child')
    if event in ['PreToolUse', 'PostToolUse']:
        payload.update(tool_name=tool or 'exec_command', tool_input={'command':'*** Begin Patch\n*** Add File: forbidden\n+no\n*** End Patch' } if tool == 'apply_patch' else {'cmd':'true'}, tool_use_id='tool-1')
    if event == 'PostToolUse': payload['tool_response'] = 'ok'
    if event == 'UserPromptSubmit': payload['prompt'] = 'fixture'
    result = subprocess.run(command, shell=True, input=json.dumps(payload), text=True, capture_output=True, timeout=6)
    if managed_log:
        record(dict(kind='hook', session=session_id, payload=payload, output=json.loads(result.stdout) if result.stdout else {}))
        if result.returncode: raise RuntimeError('hook failed')
        return
    if result.returncode or result.stdout:
        raise RuntimeError('observation hook must be silent: ' + result.stdout)

for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if 'id' not in message: continue
    result = {}
    if method == 'hooks/list':
        if missing:
            emit(dict(id=message['id'], error=dict(code=-32601, message='no hooks surface')))
            continue
        hooks = []
        for event, snake in events:
            if event not in definitions: continue
            command, definition = definitions[event]
            key = '/<session-flags>/config.toml:' + snake + ':0:0'
            fingerprint = 'sha256:' + hashlib.sha256(definition.encode()).hexdigest()
            trusted = json.dumps(key) + '={trusted_hash=' + json.dumps(fingerprint) + '}' in trust
            hooks.append(dict(key=key, eventName=event[0].lower()+event[1:], handlerType='command',
                              command=command, enabled=True, timeoutSec=5, source='sessionFlags',
                              matcher='*' if event in ['PreToolUse','PostToolUse'] else None,
                              currentHash=fingerprint, trustStatus='trusted' if trusted and os.environ.get('ARRAY_HOOK_FIXTURE_UNTRUSTED') != '1' else 'untrusted',
                              **{'async':False}))
        result = dict(data=[dict(cwd=os.getcwd(), hooks=hooks, errors=[], warnings=[])])
    elif method in ['thread/start', 'thread/resume']:
        if os.environ.get('ARRAY_HOOK_FIXTURE_LOG'):
            with open(os.environ['ARRAY_HOOK_FIXTURE_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\n')
        if managed_log:
            session_id = message.get('params', {}).get('threadId') or str(uuid.uuid4())
            source = 'resume' if method == 'thread/resume' else 'startup'
            record(dict(kind='launch', argv=sys.argv[1:], request=message, session=session_id))
        result = dict(thread=dict(id=session_id))
    elif method == 'turn/start':
        result = dict(turn=dict(id='fixture-turn'))
    emit(dict(id=message['id'], result=result))
    if managed_log and method == 'thread/start':
        emit(dict(method='thread/started', params=dict(thread=dict(id=session_id))))
    if method == 'turn/start':
        emit(dict(method='turn/started', params=dict(threadId=session_id, turn=dict(id='fixture-turn'))))
        if managed_log:
            hook('SessionStart')
            hook('UserPromptSubmit')
            hook('PreToolUse', 'apply_patch')
            if 'HOLD' in json.dumps(message):
                record(dict(kind='held', session=session_id))
                release = managed_log + '.release'
                deadline = time.monotonic() + 30
                while not os.path.exists(release) and time.monotonic() < deadline: time.sleep(.01)
                if not os.path.exists(release): raise RuntimeError('held turn timed out')
                os.unlink(release)
        else:
            for event, _ in events: hook(event)
        emit(dict(method='turn/completed', params=dict(threadId=session_id, turn=dict(id='fixture-turn',status='completed'))))
