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
base = Path(os.environ.get('ARRAY_NIGHTLY_BASE', Path.home() / 'array-scratch/nightly-gate'))
checkout = base / 'checkout'
results = base / 'results'
label = 'dev.arrayapp.nightly-gate'
plist = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
args = sys.argv[2:]
env = dict(os.environ)
# Every ARRAY_NIGHTLY_* setting belongs to this process; no leg inherits one.
NOTIFY = env.pop('ARRAY_NIGHTLY_NOTIFY', '1') != '0'
env.pop('ARRAY_NIGHTLY_BASE', None)
# The system directories come first, so python3, git and node resolve the same
# however the gate starts. The caller's PATH follows, for what lives only there:
# claude, codex and pi. --install records the installing shell's PATH in the
# LaunchAgent. Keep managed-agent crash protection intact.
SYSTEM_PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
env['PATH'] = ':'.join(p for p in [SYSTEM_PATH, os.environ.get('PATH', '')] if p)
# Gating a named ref is for this process only; no leg may inherit it.
REF = env.pop('ARRAY_NIGHTLY_REF', 'origin/array/integration')
# Before the matrix the gate waits, still holding the shared lock, until the Mac
# is quiet: no other swift-build (an agent's build bypasses the lock) and
# fseventsd under a CPU ceiling for consecutive samples. Timing legs that need
# FSEvents within seconds failed under exactly that load. The wait is bounded;
# after it the gate proceeds and the summary records the contention. These
# knobs are for this process only; no leg inherits them.
KNOB_ERRORS = []

def knob(name, default, low, high):
    # A bad value falls back to the default and is recorded; it never crashes
    # the read-only commands or turns the wait endless (nan, inf, negatives).
    raw = env.pop(name, None)
    try:
        value = float(default if raw is None else raw)
        if not low <= value <= high:  # also false for nan
            raise ValueError(f'outside {low}..{high}')
        return value
    except ValueError as error:
        KNOB_ERRORS.append(f'{name}={raw!r}: {error}; using {default}')
        return float(default)

QUIET = dict(build=env.pop('ARRAY_NIGHTLY_BUILD_PROCESS', 'swift-build'),
             fsevents_cpu=knob('ARRAY_NIGHTLY_FSEVENTS_CPU_MAX', 50, -1, 100000),
             max_seconds=knob('ARRAY_NIGHTLY_QUIET_MAX_SECONDS', 1800, 0, 86400),
             poll=knob('ARRAY_NIGHTLY_QUIET_POLL_SECONDS', 30, 0.05, 3600),
             samples=int(knob('ARRAY_NIGHTLY_QUIET_SAMPLES', 2, 1, 100)),
             # A build counts while it or its compiler children use this much CPU;
             # an idle or stuck swift-build process does not hold the gate.
             build_cpu=knob('ARRAY_NIGHTLY_BUILD_CPU_MIN', 5, 0, 100000))
# The checkout sits on this local branch, never a detached HEAD: legs that read
# the checkout's branch (an agent tile's branch chip) must see what a bench sees.
# The gate owns it; it never moves a branch that lives anywhere else.
BRANCH = 'gate/nightly-checkout'
# A gate always runs the committed known-failure list, every leg and the retry.
for key in ('ARRAY_AGENT_ID', 'TMUX', 'TMUX_PANE', 'ARRAY_MATRIX_LOCK_OWNER', 'ARRAY_RELEASE_LOCK_OWNER',
            'ARRAY_MATRIX_LEGS', 'ARRAY_MATRIX_RETRY', 'ARRAY_MATRIX_KNOWN_FAILURES'):
    env.pop(key, None)
# Paths a release-prep commit may touch without voiding the gate below it:
# nothing the build, the bundle or any matrix leg reads.
INERT = ('.plans/', 'website/', 'docs/VERSIONING.md')
CANDIDATES_KEPT = 3
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
        config['EnvironmentVariables'] = {'PATH': os.environ.get('PATH', SYSTEM_PATH)}
        print('PATH for the job:', config['EnvironmentVariables']['PATH'])
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_bytes(plistlib.dumps(config))
        run(commands[1])
    sys.exit(0)
if (base / 'repository.txt').exists() and script.parent == base:
    repo = Path((base / 'repository.txt').read_text().strip())
USAGE = ('Usage: nightly-gate.sh [--latest-green | --ship-base [REF] | --awake SHA'
         ' | --install [--dry-run] | --uninstall [--dry-run]]')
if not (args in ([], ['--latest-green']) or (args[:1] == ['--ship-base'] and len(args) <= 2)
        or (args[:1] == ['--awake'] and len(args) == 2)):
    sys.exit(USAGE)
base.mkdir(parents=True, exist_ok=True)

def load(sha):
    path = results / sha / 'summary.json'
    return json.loads(path.read_text()) if path.exists() else None

if args[:1] == ['--ship-base']:
    # Read-only: which green gate, with its release candidate, covers REF?
    git('fetch', 'origin')
    head = git('rev-parse', '--verify', (args[1] if len(args) > 1 else 'origin/array/integration') + '^{commit}')
    for sha in git('rev-list', '--max-count=500', head).splitlines():
        summary = load(sha)
        if not (summary and summary.get('green') and summary.get('candidate')
                and Path(summary['candidate']).is_dir()):
            continue
        # --no-renames: a move from Sources/ into .plans/ must list its source path.
        changed = git('diff', '--no-renames', '--name-only', sha, head).splitlines()
        live = [path for path in changed if not path.startswith(INERT)]
        if live:
            sys.exit(f'Gate {sha[:12]} is the newest green one, but {len(live)} changed path(s) since then '
                     f'can reach the app or a check (first: {live[0]}). Gate {head[:12]} first.')
        whitespace = sp.run(['git', '-C', str(repo), 'diff', '--check', sha, head], env=env,
                            stdin=sp.DEVNULL, capture_output=True, text=True)
        if whitespace.returncode:
            sys.exit('git diff --check fails since the gate:\n' + whitespace.stdout)
        awake = results / sha / 'awake.json'
        print(json.dumps(dict(head=head, gate=sha, candidate=summary['candidate'], inert_changes=changed,
                              awake=json.loads(awake.read_text()) if awake.exists() else None,
                              summary=summary), indent=2))
        sys.exit(0)
    sys.exit(f'No green gate with a release candidate among the ancestors of {head[:12]}.')
# The same regular-file lock as matrix/release; held through fetch and checkout.
lock = open(env.get('ARRAY_MATRIX_LOCK', '/tmp/array-matrix.lock'), 'a+')
if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
    sys.exit('Matrix lock must be a regular file')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print('Skipped: matrix/release lock held', file=sys.stderr)
    # Only the scheduled run treats contention as a quiet skip; a caller waiting
    # on --awake or --latest-green must never read a skip as success.
    sys.exit(0 if args == [] else 1)
git('fetch', 'origin')
# ARRAY_NIGHTLY_REF gates another ref by hand (a branch before it lands); the
# LaunchAgent never sets it.
commit = git('rev-parse', '--verify', REF + '^{commit}')
if args[:1] == ['--awake']:
    commit = git('rev-parse', '--verify', args[1] + '^{commit}')
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
previous = load(commit)
if args == [] and previous and previous.get('green') and previous.get('candidate') \
        and Path(previous['candidate']).is_dir():
    atomic(base / 'latest.json', previous)
    print('Skipped: already green with a release candidate ' + commit)
    sys.exit(0)
if args[:1] == ['--awake'] and not (previous and previous.get('green')):
    sys.exit(f'No green gate for {commit[:12]}; the awake group only completes a green one.')
out.mkdir(parents=True, exist_ok=True)

def checkout_at(log):
    if not checkout.exists():
        git('worktree', 'add', '--detach', str(checkout), commit)
    # Legs leave untracked output (caches, screenshots); only tracked edits are dirt.
    dirty = run(['git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=no'],
                stdout=sp.PIPE, text=True).stdout
    if dirty.strip():
        raise RuntimeError('Nightly checkout is dirty; refusing to change it')
    current = run(['git', '-C', str(checkout), 'branch', '--show-current'], stdout=sp.PIPE, text=True).stdout.strip()
    taken = sp.run(['git', '-C', str(repo), 'show-ref', '--verify', '--quiet', 'refs/heads/' + BRANCH], env=env).returncode == 0
    if taken and current != BRANCH:
        raise RuntimeError(f'Branch {BRANCH} exists outside the nightly checkout; refusing to move it')
    run(['git', '-C', str(checkout), 'checkout', '-B', BRANCH, commit], stdout=log, stderr=sp.STDOUT)
    if not (checkout / 'ThirdParty/GhosttyKit.xcframework').exists():
        run(['bash', str(checkout / 'scripts/prepare-ghosttykit.sh')], stdout=log, stderr=sp.STDOUT)

def owned(command, owner, log, extra_env=None):
    # caffeinate forks the shell. Shell $$ must match the lock-owner bypass;
    # the parent's flock remains held until the complete child exits.
    script = f'export {owner}=$$; exec {command}'
    return sp.run(['/usr/bin/caffeinate', '-i', '/bin/bash', '-c', script], cwd=checkout,
                  env=dict(env, **(extra_env or {})), stdin=sp.DEVNULL, stdout=log, stderr=sp.STDOUT).returncode

LAST_CONTENTION = {}  # the latest wait, kept for a summary written after an error

def machine_load():
    listing = sp.run(['/bin/ps', '-axo', 'pid=,ppid=,%cpu=,comm='], capture_output=True, text=True)
    procs = {}
    for line in listing.stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) == 4:
            procs[int(fields[0])] = (int(fields[1]), float(fields[2]), os.path.basename(fields[3].strip()))
    if listing.returncode or not procs:
        # Unknown load is not quiet: wait (bounded) and say why.
        return dict(swift_builds=None, idle_swift_builds=None, fseventsd_cpu=None,
                    probe_error=f'ps exit {listing.returncode}, {len(procs)} processes')
    children = {}
    for pid, (ppid, _, _) in procs.items():
        children.setdefault(ppid, []).append(pid)
    def tree_cpu(pid):
        stack, total, seen = [pid], 0.0, set()
        while stack:
            current = stack.pop()
            if current in seen or current not in procs:
                continue
            seen.add(current)
            total += procs[current][1]
            stack.extend(children.get(current, []))
        return total
    builds = [tree_cpu(pid) for pid, (_, _, name) in procs.items() if name == QUIET['build']]
    active = sum(cpu >= QUIET['build_cpu'] for cpu in builds)
    fsevents = [cpu for _, cpu, name in procs.values() if name == 'fseventsd']
    return dict(swift_builds=active, idle_swift_builds=len(builds) - active,
                fseventsd_cpu=max(fsevents) if fsevents else None)

def wait_until_quiet(log):
    # Wall clock, so a Mac that slept through the wait does not stretch the bound.
    started, quiet_in_row, worst, polls, first = time.time(), 0, dict(swift_builds=0, fseventsd_cpu=0.0), 0, None
    while True:
        load = machine_load()
        polls += 1
        first = first or load
        worst = dict(swift_builds=max(worst['swift_builds'], load['swift_builds'] or 0),
                     fseventsd_cpu=max(worst['fseventsd_cpu'], load['fseventsd_cpu'] or 0.0))
        calm = load['swift_builds'] == 0 and (load['fseventsd_cpu'] or 0.0) <= QUIET['fsevents_cpu']
        quiet_in_row = quiet_in_row + 1 if calm else 0
        waited = time.time() - started
        if quiet_in_row >= QUIET['samples'] or waited >= QUIET['max_seconds']:
            result = dict(quiet=quiet_in_row >= QUIET['samples'], waited_seconds=round(waited, 2), polls=polls,
                          first=first, last=load, worst=worst, limits=dict(QUIET), knob_errors=KNOB_ERRORS)
            LAST_CONTENTION.clear()
            LAST_CONTENTION.update(result)
            print('Machine ' + ('quiet' if result['quiet'] else 'still busy; proceeding') + ': ' + json.dumps(result),
                  file=log, flush=True)
            return result
        time.sleep(QUIET['poll'])

def matrix(mode, log):
    contention = wait_until_quiet(log)
    began = time.monotonic()
    matrix_results = out / ('matrix-' + mode + '-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    code = owned('bash scripts/run-matrix.sh --' + mode, 'ARRAY_MATRIX_LOCK_OWNER', log,
                 dict(ARRAY_MATRIX_RESULTS=str(matrix_results)))
    data = matrix_results / 'results.json'
    rows = json.loads(data.read_text()) if data.exists() else []
    failed = [r['leg'] for r in rows if r['status'] == 'fail']
    if code or not rows:
        failed.append('matrix exit ' + str(code) if code else 'missing matrix results')
    return dict(green=code == 0 and bool(rows) and not failed,
                passed=sum(r['status'] in ('pass', 'known-red-passed', 'retry-passed') for r in rows),
                failed=len(failed), failed_legs=failed,
                retry_passed=[r['leg'] for r in rows if r['status'] == 'retry-passed'],
                known=[r['leg'] for r in rows if r['status'] in ('known-red', 'known-flaky')],
                matrix_results=str(matrix_results), contention=contention,
                matrix_seconds=round(time.monotonic() - began, 2))

def notify(message):
    # One completion signal; notification delivery failure does not alter gate results.
    if not NOTIFY:
        return
    notice = sp.run(['/usr/bin/osascript', '-e', 'on run argv\n display notification (item 1 of argv) with title "Array nightly gate"\nend run', message], capture_output=True, text=True)
    (out / 'notification.log').write_text(notice.stdout + notice.stderr)

started = time.monotonic()
if args[:1] == ['--awake']:
    # The display/focus group the unattended gate skips, at the same commit and
    # in the same warm checkout. It needs an unlocked, awake console.
    with (out / 'awake.log').open('w') as log:
        try:
            checkout_at(log)
            awake = matrix('awake-only', log)
        except Exception as error:
            awake = dict(green=False, failed=1, failed_legs=[str(error)], contention=dict(LAST_CONTENTION) or None)
    awake.update(commit=commit, date=dt.datetime.now(dt.timezone.utc).isoformat(),
                 seconds=round(time.monotonic() - started, 2))
    atomic(out / 'awake.json', awake)
    print(json.dumps(awake, indent=2))
    sys.exit(0 if awake['green'] else 1)

summary = previous if previous and previous.get('green') else None
with (out / 'run.log').open('a') as log:
    try:
        checkout_at(log)
        if summary is None:
            source = (checkout / 'scripts/run-matrix.sh').read_text()
            if '--skip-awake)' not in source or 'ARRAY_MATRIX_LOCK_OWNER' not in source:
                raise RuntimeError('Integration must first land array/matrix-cleanup (skip-awake, shared lock, JSON results)')
            summary = matrix('skip-awake', log)
    except Exception as error:
        summary = dict(green=False, passed=0, failed=1, failed_legs=[str(error)], contention=dict(LAST_CONTENTION) or None)
        print(str(error), file=log)
    summary.update(commit=commit, date=dt.datetime.now(dt.timezone.utc).isoformat(), mode='skip-awake',
                   managed_agent=env.get('CONTINUUM_ARRAY_MANAGED_AGENT') == '1', results=str(out),
                   candidate=None, matrix_seconds=summary.get('matrix_seconds', round(time.monotonic() - started, 2)))
    if summary['green']:
        # The optimized prod bundle for this exact commit, built while nobody
        # waits on it, so a ship signs it instead of compiling for 20+ minutes.
        built = time.monotonic()
        target = out / 'candidate/Array.app'
        shutil.rmtree(target.parent, ignore_errors=True)
        code = owned('bash scripts/make-app-bundle.sh --configuration release --channel prod --output '
                     + str(target), 'ARRAY_RELEASE_LOCK_OWNER', log)
        summary['candidate_seconds'] = round(time.monotonic() - built, 2)
        if code == 0 and target.is_dir():
            summary['candidate'] = str(target)
        else:
            summary['candidate_error'] = f'make-app-bundle exit {code}; see run.log'
summary['seconds'] = round(time.monotonic() - started, 2)
atomic(summary_file, summary)
atomic(base / 'latest.json', summary)
(out / 'summary.md').write_text('# Nightly gate\n\n' + json.dumps(summary, indent=2) + '\n')
# Candidates are about 200 MB each; keep the newest few.
with_candidates = sorted((p for p in results.iterdir() if (p / 'candidate').is_dir()),
                         key=lambda p: p.stat().st_mtime, reverse=True)
for stale in with_candidates[CANDIDATES_KEPT:]:
    shutil.rmtree(stale / 'candidate', ignore_errors=True)
print(json.dumps(summary, indent=2))
ready = summary['green'] and summary['candidate']
notify(('Green, candidate built' if ready else 'Green, candidate FAILED' if summary['green']
        else str(summary['failed']) + ' red') + ' — ' + commit[:12])
sys.exit(0 if ready else 1)
PY
