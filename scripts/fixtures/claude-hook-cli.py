#!/usr/bin/env python3
"""No-model Claude control-protocol fixture for Array's capability probe."""
import json, os, subprocess, sys
if '--version' in sys.argv:
    print('fixture-claude-1');sys.exit(0)
if '--help' in sys.argv:
    print('--settings <file-or-json>');sys.exit(0)
settings=json.loads(sys.argv[sys.argv.index('--settings')+1]) if '--settings' in sys.argv else {'hooks':{}}
hooks=[]
for event, groups in settings['hooks'].items():
    for group in groups:
        for hook in group['hooks']:
            hooks.append(dict(event=event,source='flagSettings',type=hook['type'],commandText=hook['command'],
                              timeout=hook['timeout'],matcher=group.get('matcher','')))
            if event=='SessionStart':subprocess.run(hook['command'],shell=True,check=True)
for line in sys.stdin:
    request=json.loads(line)
    if request.get('type')=='user':
        with open(os.environ['ARRAY_HOOK_FIXTURE_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\n')
        print(json.dumps(dict(type='system',subtype='init',session_id='fixture')),flush=True)
        print(json.dumps(dict(type='result',subtype='success',is_error=False,result='done',session_id='fixture',num_turns=1,duration_ms=1,total_cost_usd=0,usage={})),flush=True)
        continue
    if request.get('request',{}).get('subtype')=='get_hooks_listing':
        catalog=[dict(name=h['event']) for h in hooks]
        if os.environ.get('ARRAY_HOOK_FIXTURE_MISSING')=='1':catalog=[e for e in catalog if e['name']!='SubagentStop']
        print(json.dumps(dict(type='control_response',response=dict(subtype='success',request_id=request['request_id'],response=dict(eventCatalog=catalog,hooks=hooks)))),flush=True)
