"""Replay artifact validation and fake-only execution; no live launch capability."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import uuid

MODES = ('solo', 'managed', 'chooser')
HARNESSES = ('claude', 'codex')

def digest(data):
    return hashlib.sha256(data).hexdigest()

def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL).decode().strip()

def has_object(repo, oid):
    return subprocess.run(['git', '-C', str(repo), 'cat-file', '-e', oid],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def fixture(root):
    repo = root / 'source'
    repo.mkdir()
    git(repo, 'init', '-q')
    (repo / 'value').write_text('broken')
    git(repo, 'add', '.')
    git(repo, 'commit', '-qm', 'fixture: introduce defect')
    base = git(repo, 'rev-parse', 'HEAD')
    (repo / 'value').write_text('fixed')
    git(repo, 'commit', '-qam', 'fixture: repair defect')
    return repo, base, git(repo, 'rev-parse', 'HEAD')

class Workspace:
    """Export only base tree; reconstruct the single base commit, no ancestors.

    This removes answer objects/remotes. It is NOT process/network containment.
    """
    def __init__(self, repo, base):
        self.temp = tempfile.TemporaryDirectory(prefix='replay-')
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        self.project.mkdir()
        try:
            archive = subprocess.check_output(['git', '-C', str(repo), 'archive', base])
            with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
                # Do not materialize links or special files from untrusted trees.
                for member in tree.getmembers():
                    p = Path(member.name)
                    if p.is_absolute() or '..' in p.parts or not (member.isfile() or member.isdir()):
                        raise ValueError('unsafe source tree')
                tree.extractall(self.project)
            git(self.project, 'init', '-q')
            git(self.project, 'add', '.')
            tree_oid = git(self.project, 'write-tree')
            commit = subprocess.check_output(['git', '-C', str(repo), 'cat-file', 'commit', base])
            if commit.splitlines()[0] != ('tree ' + tree_oid).encode():
                raise ValueError('export tree mismatch')
            reconstructed = subprocess.check_output(['git', '-C', str(self.project),
                'hash-object', '-t', 'commit', '-w', '--stdin'], input=commit).decode().strip()
            if reconstructed != base:
                raise ValueError('base mismatch')
            git(self.project, 'update-ref', 'HEAD', base)
            self.env = dict(os.environ)
            for key in ('TMUX', 'TMUX_PANE'):
                self.env.pop(key, None)
            for key, folder in [('TMUX_TMPDIR', 'tmux'), ('CONTINUUM_APP_SUPPORT', 'support'),
                                ('REPLAY_BUILD_PATH', 'build')]:
                path = self.root / folder
                path.mkdir()
                self.env[key] = str(path)
            self.env['CONTINUUM_PROJECT_ROOT'] = str(self.project)
        except BaseException:
            self.temp.cleanup()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.temp.cleanup()

def require_live_isolation():
    raise RuntimeError('Live runner unavailable: network/process containment and supervisor adapter required')

class Grader:
    def __init__(self, source):
        self.source = source
        self.sha256 = digest(source)

    def grade(self, project):
        if digest(self.source) != self.sha256:
            return 'modified'
        try:
            compile(self.source, '<hidden grader>', 'exec')
        except SyntaxError:
            return 'compile_failed'
        # Grader resides outside the agent tree and runs only after fake termination.
        with tempfile.TemporaryDirectory(prefix='replay-grade-') as d:
            script = Path(d) / 'grader.py'
            script.write_bytes(self.source)
            try:
                p = subprocess.run([sys.executable, str(script)], cwd=project,
                    capture_output=True, timeout=10)
            except subprocess.TimeoutExpired:
                return 'timeout'
            if p.returncode == 0:
                return 'passed'
            # Runtime/tool failures must never qualify as the intended RED.
            return 'assertion_failed' if b'AssertionError' in p.stderr else 'invalid'

def validate(repo, base, fix, grader):
    with Workspace(repo, base) as before, Workspace(repo, fix) as after:
        return grader.grade(before.project) == 'assertion_failed' and grader.grade(after.project) == 'passed'

def union_seconds(intervals):
    end = total = 0
    for start, stop in sorted(intervals):
        if stop < start or start < 0:
            raise ValueError('invalid interval')
        total += max(0, stop - max(end, start))
        end = max(end, stop)
    return total

def run_fake(repo, base, request, grader, harness, mode, outcome,
             neighbor_ok=True, repair=True):
    if harness not in HARNESSES or mode not in MODES:
        raise ValueError('unknown condition')
    if outcome not in ('completed', 'failed', 'timeout', 'interrupted'):
        raise ValueError('unknown outcome')
    with Workspace(repo, base) as w:
        # Scripted events only. Identity is per agent/message, never context occupancy.
        events = [('lead', 'message-1', 7, 2), ('helper', 'message-2', 5, 3),
                  ('lead', 'message-1', 7, 2)]
        unique = {(agent, message): (inp, out) for agent, message, inp, out in events}
        if outcome == 'completed' and repair:
            (w.project / 'value').write_text('fixed')
        patch = subprocess.check_output(['git', '-C', str(w.project), 'diff', '--binary'])
        # Fake stream has terminal completion at 4, not last usage at 2.
        terminal = 4
        # Agent tree is never graded. Export completed diff into a fresh tree.
        with Workspace(repo, base) as grading:
            subprocess.run(['git', '-C', str(grading.project), 'apply', '--allow-empty'],
                           input=patch, check=True, capture_output=True)
            hidden = grader.grade(grading.project)
            # Actual neighboring command, including deterministic failure fixture.
            neighbor = subprocess.run([sys.executable, '-c',
                'raise SystemExit(0)' if neighbor_ok else 'raise SystemExit(1)'],
                cwd=grading.project).returncode == 0
        return dict(v=1, task=str(uuid.uuid5(uuid.NAMESPACE_URL, base + request)), run=str(uuid.uuid4()), base=base,
            harness=harness, mode=mode, actualChoice='managed' if mode == 'chooser' else mode,
            requestHash=digest(request.encode()), graderHash=grader.sha256,
            diffHash=digest(patch), outcome=outcome, simulated=True,
            tokens={'input': sum(v[0] for v in unique.values()),
                    'output': sum(v[1] for v in unique.values()),
                    'cacheRead': None, 'cacheWrite': None},
            usageComplete=True, wallSeconds=terminal, activeSeconds=union_seconds([(0, 2), (1, 3)]),
            humanSteps=1, hiddenPassed=hidden == 'passed', neighborPassed=neighbor,
            passed=outcome == 'completed' and hidden == 'passed' and neighbor)

def compare(records):
    # Each pair must have exactly one complete observation of the same immutable task.
    groups = {}
    for r in records:
        key = (r['base'], r['requestHash'], r['graderHash'], r['harness'])
        groups.setdefault(key, {}).setdefault(r['mode'], []).append(r)
    differences = []
    for modes in groups.values():
        if any(len(modes.get(m, [])) != 1 for m in ('solo', 'managed')):
            continue
        a, b = modes['solo'][0], modes['managed'][0]
        if any(r['outcome'] != 'completed' or not r['usageComplete'] for r in (a, b)):
            continue
        differences.append(b['tokens']['input'] + b['tokens']['output'] - a['tokens']['input'] - a['tokens']['output'])
    expected = len(groups)
    complete = len(differences)
    return dict(runs=len(records), pairs=complete, coverage=f'{complete}/{expected}',
        passed=sum(r['passed'] for r in records),
        difference=sum(differences) / complete if complete and complete == expected else None,
        simulated=all(r['simulated'] for r in records))

def append_record(path, record):
    """Host-side artifact sink. Never store this file in an agent-visible root."""
    with Path(path).open('a') as stream:
        stream.write(json.dumps(record, sort_keys=True, allow_nan=False) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
