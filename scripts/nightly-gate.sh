#!/usr/bin/env bash
set -euo pipefail
# Python supplies macOS flock, atomic JSON writes, and plist escaping.
exec python3 - "$0" "$@" <<'PY'
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess as sp
import sys
import time

script = Path(sys.argv[1]).resolve()
repo = script.parent.parent
base = Path.home() / 'array-scratch/nightly-gate'
checkout = base / 'checkout'
results = base / 'results'
label = 'dev.arrayapp.nightly-gate'
plist = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
args = sys.argv[2:]
env = dict(os.environ)
# LaunchAgents have a minimal PATH. Keep managed-agent crash protection intact.
env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
for key in ('ARRAY_AGENT_ID', 'TMUX', 'TMUX_PANE', 'ARRAY_MATRIX_LOCK_OWNER'):
    env.pop(key, None)
env.update(TERM='xterm-256color', CONTINUUM_SKIP_UI_BASELINES='1')

def run(cmd, **kw):
    return sp.run(cmd, env=env, stdin=sp.DEVNULL, check=True, **kw)

def git(*args):
    return run(['git', '-C', str(repo), *args], stdout=sp.PIPE, text=True).stdout.strip()

def atomic(path, data):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(data, indent=2) + '\n')
    tmp.replace(path)

if args and args[0] in ('--install', '--uninstall'):
    dry = args[1:] == ['--dry-run']
    if args[1:] and not dry:
        sys.exit('Expected --dry-run')
    domain = 'gui/' + str(os.getuid())
    commands = [['launchctl', 'bootout', domain + '/' + label]]
    if args[0] == '--install':
        commands.append(['launchctl', 'bootstrap', domain, str(plist)])
    print('Plist:', plist)
    for cmd in commands:
        print(' '.join(cmd))
    if dry:
        sys.exit(0)
    sp.run(commands[0], check=False)
    if args[0] == '--uninstall':
        plist.unlink(missing_ok=True)
    else:
        base.mkdir(parents=True, exist_ok=True)
        # Install a stable copy outside Documents so launchd needs no folder grant.
        installed = base / 'nightly-gate.sh'
        shutil.copy2(script, installed)
        shutil.copy2(script.parent / (label + '.plist'), base / (label + '.plist'))
        # The common object store remains the source repo; no clone is made.
        (base / 'repository.txt').write_text(git('rev-parse', '--path-format=absolute', '--git-common-dir'))
        config = plistlib.loads((base / (label + '.plist')).read_bytes())
        config['ProgramArguments'] = ['/bin/bash', str(installed)]
        config['StandardOutPath'] = str(base / 'launchd.log')
        config['StandardErrorPath'] = str(base / 'launchd.log')
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_bytes(plistlib.dumps(config))
        run(commands[1])
    sys.exit(0)
if (base / 'repository.txt').exists() and script.parent == base:
    repo = Path((base / 'repository.txt').read_text().strip())
if args not in ([], ['--latest-green']):
    sys.exit('Usage: nightly-gate.sh [--latest-green | --install [--dry-run] | --uninstall [--dry-run]]')
base.mkdir(parents=True, exist_ok=True)
# The same regular-file lock as matrix/release; held through fetch and checkout.
lock = open(env.get('ARRAY_MATRIX_LOCK', '/tmp/array-matrix.lock'), 'a+')
if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
    sys.exit('Matrix lock must be a regular file')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print('Skipped: matrix/release lock held', file=sys.stderr)
    sys.exit(1 if args == ['--latest-green'] else 0)
git('fetch', 'origin')
commit = git('rev-parse', 'origin/array/integration')
if args == ['--latest-green']:
    # Git history order, not result timestamp: newest checked integration ancestor.
    for sha in git('rev-list', 'origin/array/integration').splitlines():
        candidate = results / sha / 'summary.json'
        if candidate.exists() and json.loads(candidate.read_text()).get('green'):
            print(sha)
            sys.exit(0)
    sys.exit('No green nightly result on origin/array/integration')
results.mkdir(parents=True, exist_ok=True)
for path in results.iterdir():
    if path.is_dir() and time.time() - path.stat().st_mtime > 14 * 86400:
        shutil.rmtree(path)
out = results / commit
summary_file = out / 'summary.json'
if summary_file.exists() and json.loads(summary_file.read_text()).get('green'):
    atomic(base / 'latest.json', json.loads(summary_file.read_text()))
    print('Skipped: already green ' + commit)
    sys.exit(0)
out.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
failed = []
rows = []
code = 1
with (out / 'run.log').open('w') as log:
    try:
        if not checkout.exists():
            git('worktree', 'add', '--detach', str(checkout), commit)
        dirty = run(['git', '-C', str(checkout), 'status', '--porcelain'], stdout=sp.PIPE, text=True).stdout
        if dirty.strip():
            raise RuntimeError('Nightly checkout is dirty; refusing to change it')
        run(['git', '-C', str(checkout), 'checkout', '--detach', commit], stdout=log, stderr=sp.STDOUT)
        matrix = checkout / 'scripts/run-matrix.sh'
        source = matrix.read_text()
        if '--skip-awake)' not in source or 'ARRAY_MATRIX_LOCK_OWNER' not in source:
            raise RuntimeError('Integration must first land array/matrix-cleanup (skip-awake, shared lock, JSON results)')
        if not (checkout / 'ThirdParty/GhosttyKit.xcframework').exists():
            run(['bash', str(checkout / 'scripts/prepare-ghosttykit.sh')], stdout=log, stderr=sp.STDOUT)
        matrix_results = out / ('matrix-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
        child_env = dict(env, ARRAY_MATRIX_RESULTS=str(matrix_results))
        # caffeinate forks the shell. Shell $$ must match the lock-owner bypass;
        # the parent's flock remains held until the complete child exits.
        command = 'export ARRAY_MATRIX_LOCK_OWNER=$$; exec bash scripts/run-matrix.sh --skip-awake'
        code = sp.run(['/usr/bin/caffeinate', '-i', '/bin/bash', '-c', command], cwd=checkout,
                      env=child_env, stdin=sp.DEVNULL, stdout=log, stderr=sp.STDOUT).returncode
        data = matrix_results / 'results.json'
        if data.exists():
            rows = json.loads(data.read_text())
        failed = [r['leg'] for r in rows if r['status'] == 'fail']
        if code or not rows:
            failed.append('matrix exit ' + str(code) if code else 'missing matrix results')
    except Exception as error:
        failed.append(str(error))
        print(str(error), file=log)
summary = dict(commit=commit, date=dt.datetime.now(dt.timezone.utc).isoformat(),
               green=code == 0 and bool(rows) and not failed,
               passed=sum(r['status'] in ('pass', 'known-red-passed') for r in rows),
               failed=len(failed), failed_legs=failed, seconds=round(time.monotonic()-started, 2),
               mode='skip-awake', managed_agent=env.get('CONTINUUM_ARRAY_MANAGED_AGENT') == '1',
               results=str(out))
atomic(summary_file, summary)
atomic(base / 'latest.json', summary)
(out / 'summary.md').write_text('# Nightly gate\n\n' + json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
message = ('Green' if summary['green'] else str(len(failed)) + ' red') + ' — ' + commit[:12]
# One completion signal; notification delivery failure does not alter gate results.
notice = sp.run(['/usr/bin/osascript', '-e', 'on run argv\n display notification (item 1 of argv) with title "Array nightly gate"\nend run', message], capture_output=True, text=True)
(out / 'notification.log').write_text(notice.stdout + notice.stderr)
sys.exit(0 if summary['green'] else 1)
PY
