#!/usr/bin/env python3
"""Opt-in real model/tools witness. Cleanup is restricted to new receipt-owned UDIDs."""
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import uuid

if os.environ.get('ARRAY_DEVICE_BROWSER_LIVE') != '1':
    raise SystemExit('Set ARRAY_DEVICE_BROWSER_LIVE=1 to authorize real model turns.')
root = Path(__file__).resolve().parents[2]
out = Path(os.environ['ARRAY_DEVICE_BROWSER_LIVE_OUT']).resolve()
project = out / 'fixture-project'
(project / 'Sources').mkdir(parents=True)
shutil.copyfile(root / 'Tools/IOSPreviewProof/InputWitnessApp.swift', project / 'Sources/InputWitnessApp.swift')
(project / 'project.yml').write_text('''name: InputWitness
options:
  deploymentTarget:
    iOS: "17.0"
targets:
  InputWitness:
    type: application
    platform: iOS
    sources: [Sources]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.arrayapp.preview-proof
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        TARGETED_DEVICE_FAMILY: "1,2"
        CODE_SIGNING_ALLOWED: NO
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
schemes:
  InputWitness:
    build:
      targets:
        InputWitness: all
''')
subprocess.run(['xcodegen', 'generate', '--spec', str(project / 'project.yml')], check=True, cwd=project)
counts = {}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/state':
            data = json.dumps(counts).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(data); return
        key = self.path.strip('/').split('?')[0]
        data = f'''<!doctype html><title>Array live counter</title><h1>Live counter</h1>
<button id="increment">Increment once</button><p id="value">COUNTER_0</p>
<script>document.querySelector('button').onclick=async()=>{{
const response=await fetch('/{key}',{{method:'POST'}}); const n=await response.text();
document.querySelector('#value').textContent='COUNTER_'+n;}};</script>'''.encode()
        self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        key = self.path.strip('/')
        counts[key] = counts.get(key, 0) + 1
        self.send_response(200); self.end_headers(); self.wfile.write(str(counts[key]).encode())
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = os.environ.copy()
env['ARRAY_DEVICE_BROWSER_LIVE_URL'] = f'http://127.0.0.1:{server.server_port}'
env['ARRAY_DEVICE_BROWSER_LIVE_PROJECT'] = str(project)
env['ARRAY_DEVICE_BROWSER_LIVE_EVIDENCE'] = str(out / 'evidence.json')
def devices():
    value = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j']))
    return {x['udid']:x for group in value['devices'].values() for x in group}
before = devices()
(out / 'simulators-before.json').write_text(json.dumps(before, indent=2))
status = 1
try:
    status = subprocess.run([str(root / '.build/debug/Array'), '--workspace-api-device-browser-live-check',
        '-continuum.terminal.tmux.enabled', 'NO', '-continuum.terminal.tmux.path', ''], env=env, cwd=root).returncode
finally:
    server.shutdown()
    (out / 'browser-counts.json').write_text(json.dumps(counts, indent=2))
    receipt_file = Path(env['CONTINUUM_APP_SUPPORT']) / 'DeveloperTools/iOSPreview/managed-devices.json'
    receipts = json.loads(receipt_file.read_text()) if receipt_file.exists() else {}
    cleanup = []
    for key, receipt in receipts.items():
        device = receipt['deviceID']
        uuid.UUID(device)
        if key != device or device in before:
            raise RuntimeError('Refusing cleanup of a pre-existing or mismatched simulator')
        for action in ['shutdown', 'delete']:
            result = subprocess.run(['xcrun','simctl',action,device], capture_output=True)
            cleanup.append({'device':device,'action':action,'exit':result.returncode})
    (out / 'cleanup.json').write_text(json.dumps(cleanup, indent=2))
    (out / 'simulators-after.json').write_text(json.dumps(devices(), indent=2))
requested = set(env.get('ARRAY_DEVICE_BROWSER_LIVE_HARNESSES', 'codex,pi').split(','))
if status == 0 and any(counts.get(key) != 1 for key in requested):
    raise RuntimeError(f'Browser server did not receive exactly one click from each harness: {counts}')
raise SystemExit(status)
