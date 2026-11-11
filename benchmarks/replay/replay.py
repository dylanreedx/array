"""Replay benchmark machinery: exports, containment, pristine grading, records
and the comparison. Fake agent processes only; there is no live launch path."""
import collections
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
MANIFEST = json.loads((HERE / 'manifest.json').read_text())
HARNESSES = tuple(MANIFEST['conditions']['harnesses'])
MODES = tuple(MANIFEST['conditions']['modes'])
RECORD_FIELDS = tuple(field['name'] for field in MANIFEST['recordFields'])
HOST_OWNED = tuple(MANIFEST['hostOwnedPaths'])
OUTCOMES = ('completed', 'failed', 'timeout', 'interrupted', 'containmentFailed', 'driverFailed')
TOKEN_TYPES = ('input', 'output', 'cacheRead', 'cacheWrite')
PYTHON = os.path.realpath(sys.executable)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL).decode().strip()


def has_object(repo, oid):
    return subprocess.run(['git', '-C', str(repo), 'cat-file', '-e', oid],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def task_id(base, request_hash, checks_hash):
    """The only task derivation. Swift copies this value; it never derives one."""
    return digest('\n'.join((base, request_hash, checks_hash)).encode())


# MARK: - Tasks

BROKEN = 'def value():\n    return "broken"\n'
FIXED = 'def value():\n    return "fixed"\n'
NEIGHBOUR = 'import calc\nassert callable(calc.value)\n'
HIDDEN = 'import calc\nassert calc.value() == "fixed"\n'


def fixture(root):
    """Synthetic two-commit history: tests the machinery, not model quality."""
    repo = Path(root) / 'source'
    (repo / 'checks').mkdir(parents=True)
    git(repo, 'init', '-q')
    (repo / 'calc.py').write_text(BROKEN)
    (repo / 'checks' / 'neighbour.py').write_text(NEIGHBOUR)
    git(repo, 'add', '.')
    git(repo, '-c', 'user.name=fixture', '-c', 'user.email=fixture@invalid', 'commit', '-qm', 'fixture: introduce defect')
    base = git(repo, 'rev-parse', 'HEAD')
    (repo / 'calc.py').write_text(FIXED)
    (repo / 'checks' / 'hidden_value.py').write_text(HIDDEN)
    git(repo, 'add', '.')
    git(repo, '-c', 'user.name=fixture', '-c', 'user.email=fixture@invalid', 'commit', '-qm', 'fixture: repair defect')
    return repo, base, git(repo, 'rev-parse', 'HEAD')


def checks_hash(task):
    return digest(json.dumps([task['base'], sorted(task['hidden'].items()), sorted(task['neighbours']),
                              sorted(task['protected'])], sort_keys=True).encode())


def make_task(repo, base, fix, request, fixture_id, hidden_paths, neighbours, protected):
    """Hidden checks are the fix commit's added checks, held host-side only."""
    hidden = {p: subprocess.check_output(['git', '-C', str(repo), 'show', fix + ':' + p]).decode() for p in hidden_paths}
    task = dict(fixture=fixture_id, source=str(repo), base=base, fix=fix, request=request,
                hidden=hidden, neighbours=list(neighbours), protected=sorted(set(protected) | set(hidden)))
    task['requestHash'] = digest(request.encode())
    task['checksHash'] = checks_hash(task)
    task['task'] = task_id(base, task['requestHash'], task['checksHash'])
    return task


def synthetic_task(root, request='Repair the value.'):
    repo, base, fix = fixture(root)
    return make_task(repo, base, fix, request, 'synthetic-value', ['checks/hidden_value.py'],
                     ['checks/neighbour.py'], ['checks/'])


def is_protected(task, path):
    return any(path == p or (p.endswith('/') and path.startswith(p)) for p in task['protected'])


# MARK: - Owned storage

_OWNED = {}


def own_root(prefix):
    """A directory this process created; nothing else confers ownership."""
    root = Path(tempfile.mkdtemp(prefix=prefix)).resolve()
    info = os.lstat(root)
    _OWNED[str(root)] = (info.st_dev, info.st_ino)
    return root


def require_owned(root):
    root = Path(root)
    try:
        info = os.lstat(root)
    except FileNotFoundError:
        raise ValueError('refusing unowned replay storage')
    if (stat.S_ISLNK(info.st_mode) or str(root.resolve()) != str(root)
            or _OWNED.get(str(root)) != (info.st_dev, info.st_ino)):
        raise ValueError('refusing unowned replay storage')


def release_root(root):
    if _OWNED.pop(str(root), None) is not None:
        shutil.rmtree(root, ignore_errors=True)


def inside_owned(path):
    path = Path(path).resolve()
    return any(path == Path(r) or Path(r) in path.parents for r in _OWNED)


class Workspace:
    """An export of one commit with no remotes, ancestors or later objects.

    Its root holds the agent's project and the run's own support, build,
    tmux, temporary and home directories, and nothing else."""
    FOLDERS = ('support', 'build', 'tmux', 'tmp', 'home')

    def __init__(self, repo, commit):
        self.root = own_root('replay-')
        self.project = self.root / 'project'
        try:
            self.project.mkdir()
            archive = subprocess.check_output(['git', '-C', str(repo), 'archive', commit])
            with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
                for member in tree.getmembers():
                    p = Path(member.name)
                    if p.is_absolute() or '..' in p.parts or not (member.isfile() or member.isdir()):
                        raise ValueError('unsafe source tree')
                tree.extractall(self.project)
            git(self.project, 'init', '-q')
            git(self.project, 'add', '.')
            tree_oid = git(self.project, 'write-tree')
            body = subprocess.check_output(['git', '-C', str(repo), 'cat-file', 'commit', commit])
            if body.splitlines()[0] != ('tree ' + tree_oid).encode():
                raise ValueError('export tree mismatch')
            rebuilt = subprocess.check_output(['git', '-C', str(self.project), 'hash-object', '-t', 'commit',
                                               '-w', '--stdin'], input=body).decode().strip()
            if rebuilt != commit:
                raise ValueError('base mismatch')
            git(self.project, 'update-ref', 'HEAD', commit)
            for folder in self.FOLDERS:
                (self.root / folder).mkdir()
            # A fresh environment: nothing inherited, so no TMUX or real paths.
            self.env = dict(PATH='/usr/bin:/bin', LANG='en_US.UTF-8', PYTHONDONTWRITEBYTECODE='1',
                            HOME=str(self.root / 'home'), TMPDIR=str(self.root / 'tmp'),
                            TMUX_TMPDIR=str(self.root / 'tmux'), CONTINUUM_APP_SUPPORT=str(self.root / 'support'),
                            REPLAY_BUILD_PATH=str(self.root / 'build'), CONTINUUM_PROJECT_ROOT=str(self.project))
        except BaseException:
            release_root(self.root)
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        release_root(self.root)


# MARK: - Containment

def toolchain():
    return sorted({'/usr/lib', '/usr/share', '/bin', '/usr/bin', '/System/Library', '/System/Cryptexes',
                   '/System/Volumes/Preboot/Cryptexes', '/private/var/db/dyld', '/dev',
                   os.path.realpath(sys.base_prefix), os.path.dirname(PYTHON)})


def sandbox_profile(root):
    """Deny by default. Read: the run root and the toolchain. Write: the run root.
    No network of any kind (unix sockets included), no signals outside the
    sandbox, no mach services."""
    q = json.dumps
    tools = toolchain()
    readable = tools + [str(root)]
    ancestors = sorted({str(a) for p in readable for a in Path(p).parents} - set(readable))
    return ''.join([
        '(version 1)(deny default)',
        '(allow process-fork)(allow sysctl-read)(allow signal (target same-sandbox))',
        '(allow process-exec ', ' '.join('(subpath %s)' % q(p) for p in tools), ')',
        '(allow file-read* (literal "/") (literal "/private/var/select/sh") ',
        ' '.join('(subpath %s)' % q(p) for p in readable), ')',
        '(allow file-read-metadata ', ' '.join('(literal %s)' % q(p) for p in ancestors), ')',
        '(allow file-write* (literal "/dev/null") (subpath %s))' % q(str(root))])


class ContainedRun(Workspace):
    def execute(self, code, deadline=2, interrupt=False):
        require_owned(self.root)
        if self.project.resolve() != self.root / 'project':
            raise ValueError('run storage changed')
        started = time.monotonic()
        process = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', sandbox_profile(self.root), PYTHON, '-I', '-c', code],
                                   cwd=self.project, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        outcome = 'completed'
        try:
            if interrupt:
                os.killpg(process.pid, signal.SIGTERM)
                outcome = 'interrupted'
            stdout, stderr = process.communicate(timeout=deadline)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            outcome = 'timeout'
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        wall = time.monotonic() - started
        if outcome == 'completed' and process.returncode:
            outcome = 'containmentFailed' if b'Operation not permitted' in stderr else 'failed'
        return dict(outcome=outcome, wallSeconds=wall, activeSeconds=wall, exitCode=process.returncode,
                    stdout=stdout.decode(errors='replace'), terminated=process.poll() is not None)


# MARK: - Grading

# Host-owned; passed with -c and never written into any tree an agent touched.
HARNESS = r'''
import json, os, sys
spec = json.loads(sys.stdin.readline())
report = os.fdopen(spec["fd"], "w")
sys.path.insert(0, os.getcwd())
try:
    exec(compile(spec["source"], spec["name"], "exec"), {"__name__": "__replay_check__"})
    result = "passed"
except AssertionError:
    result = "failed"
except BaseException as error:
    result = "error:" + type(error).__name__
report.write(json.dumps({"nonce": spec["nonce"], "check": spec["name"], "result": result}) + "\n")
report.write(json.dumps({"nonce": spec["nonce"], "done": True}) + "\n")
report.flush()
'''


def run_check(run, name, source, deadline=10):
    """One check in its own sandboxed process. The verdict is what the harness
    reported on its own pipe; an exit status alone is never a result."""
    require_owned(run.root)
    read_end, write_end = os.pipe()
    nonce = uuid.uuid4().hex
    process = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', sandbox_profile(run.root), PYTHON, '-I', '-c', HARNESS],
                               cwd=run.project, env=run.env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, pass_fds=(write_end,), start_new_session=True)
    os.close(write_end)
    try:
        process.stdin.write((json.dumps(dict(fd=write_end, nonce=nonce, name=name, source=source)) + '\n').encode())
        process.stdin.close()
    except BrokenPipeError:
        pass
    try:
        process.wait(timeout=deadline)
        timed_out = False
    except subprocess.TimeoutExpired:
        timed_out = True
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    os.set_blocking(read_end, False)
    chunks = []
    while True:
        try:
            chunk = os.read(read_end, 65536)
        except BlockingIOError:
            break
        if not chunk:
            break
        chunks.append(chunk)
    os.close(read_end)
    reports = []
    for line in b''.join(chunks).decode(errors='replace').splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and item.get('nonce') == nonce:
            reports.append(item)
    results = [r.get('result') for r in reports if r.get('check') == name]
    done = sum(1 for r in reports if r.get('done') is True)
    if timed_out or len(results) != 1 or done != 1:
        return 'noResult'
    return results[0]


def tree_entries(root):
    """Regular files by relative path. Links and special files are unsafe;
    a directory holding its own .git is a nested checkout and is not content."""
    root = Path(root)
    files, unsafe, nested = {}, [], []
    for dirpath, dirnames, filenames in os.walk(root):
        here = Path(dirpath)
        rel_dir = here.relative_to(root)
        keep = []
        for name in dirnames:
            rel = (rel_dir / name).as_posix()
            if rel_dir == Path('.') and name in HOST_OWNED:
                continue
            if (here / name).is_symlink():
                unsafe.append(rel)
            elif os.path.lexists(here / name / '.git'):
                nested.append(rel)
            else:
                keep.append(name)
        dirnames[:] = keep
        for name in filenames:
            rel = (rel_dir / name).as_posix()
            if rel_dir == Path('.') and name in HOST_OWNED:
                continue
            info = os.lstat(here / name)
            if not stat.S_ISREG(info.st_mode):
                unsafe.append(rel)
                continue
            files[rel] = ((here / name).read_bytes(), bool(info.st_mode & 0o111))
    return files, sorted(unsafe), sorted(nested)


def collect_changes(pristine, agent):
    before, _, _ = tree_entries(pristine)
    after, unsafe, nested = tree_entries(agent)
    changes = {p: v for p, v in after.items() if before.get(p) != v}
    changes.update({p: None for p in before if p not in after})
    return changes, unsafe, nested


def grade(task, agent_tree):
    """Grade a finished working copy on a pristine export. Only the agent's
    changes to unprotected paths are carried over; checks come from host
    memory and the pristine export, never from the agent's tree."""
    if checks_hash(task) != task['checksHash']:
        raise ValueError('checks changed since the task was frozen')
    with Workspace(task['source'], task['base']) as reference, ContainedRun(task['source'], task['base']) as run:
        changes, unsafe, nested = collect_changes(reference.project, agent_tree)
        tampered = list(unsafe)
        for path, value in sorted(changes.items()):
            if not is_protected(task, path):
                continue
            hidden = task['hidden'].get(path)
            if hidden is None or value is None or value[0] != hidden.encode():
                tampered.append(path)
        for path, value in changes.items():
            if is_protected(task, path):
                continue
            target = run.project / path
            if value is None:
                target.unlink()
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(value[0])
            os.chmod(target, 0o755 if value[1] else 0o644)
        for path, source in task['hidden'].items():
            (run.project / path).parent.mkdir(parents=True, exist_ok=True)
            (run.project / path).write_text(source)
        checks = {}
        for path, source in sorted(task['hidden'].items()):
            checks[path] = run_check(run, path, source)
        for path in sorted(task['neighbours']):
            checks[path] = run_check(run, path, (run.project / path).read_text())
        hidden_passed = all(checks[p] == 'passed' for p in task['hidden'])
        neighbour_passed = all(checks[p] == 'passed' for p in task['neighbours'])
        if tampered:
            verdict = 'tampered'
        elif hidden_passed and neighbour_passed:
            verdict = 'passed'
        elif any(v == 'noResult' for v in checks.values()):
            verdict = 'noResult'
        else:
            verdict = 'failed'
        listing = sorted((p, None if v is None else digest(v[0])) for p, v in changes.items())
        return dict(checks=checks, gradeResult=verdict, hiddenPassed=hidden_passed, neighbourPassed=neighbour_passed,
                    tampered=sorted(set(tampered)), changedPaths=sorted(changes), nestedCheckouts=nested,
                    diffHash=digest(json.dumps(listing).encode()))


def validate(task):
    """A task is usable only if every hidden check fails by assertion on the
    parent and passes on the landed fix, with neighbours passing on both."""
    try:
        with Workspace(task['source'], task['base']) as parent, Workspace(task['source'], task['fix']) as fix:
            before, after = grade(task, parent.project), grade(task, fix.project)
    except ValueError:
        return False
    return (all(before['checks'][p] == 'failed' for p in task['hidden']) and before['neighbourPassed']
            and after['gradeResult'] == 'passed')


# MARK: - Records

def new_record(task, harness, mode, simulated=True):
    if harness not in HARNESSES or mode not in MODES:
        raise ValueError('unknown condition')
    return dict(v=MANIFEST['v'], run=str(uuid.uuid4()), task=task['task'], ledgerTask=None,
                fixture=task['fixture'], base=task['base'], requestHash=task['requestHash'],
                checksHash=task['checksHash'], harness=harness, mode=mode, actualChoice=None,
                simulated=simulated, outcome='driverFailed', failure=None,
                fannedOut=None if mode == 'solo' else False, helperCount=0, helpers=[], delegationAttempts=0,
                tokens={t: None for t in TOKEN_TYPES}, usageComplete=False,
                usageProblems=['no usage observed'], wallSeconds=None, activeSeconds=None, humanSteps=None,
                diffHash=None, changedPaths=[], tampered=[], checks={}, gradeResult='notGraded',
                hiddenPassed=None, neighbourPassed=None, passed=False)


def check_record(record):
    if tuple(sorted(record)) != tuple(sorted(RECORD_FIELDS)):
        raise ValueError('record fields differ from manifest: %s' % sorted(set(record) ^ set(RECORD_FIELDS)))
    if record['v'] != MANIFEST['v'] or record['outcome'] not in OUTCOMES or record['mode'] not in MODES:
        raise ValueError('record values outside the schema')
    if set(record['tokens']) != set(TOKEN_TYPES):
        raise ValueError('record token types differ from the schema')
    if record['usageComplete'] and (any(record['tokens'][t] is None for t in TOKEN_TYPES) or record['usageProblems']):
        raise ValueError('usage marked complete with unknown token types')
    if record['passed'] and (record['outcome'] != 'completed' or record['gradeResult'] != 'passed'):
        raise ValueError('passed without a completed, passing grade')
    return record


def write_record(destination, record):
    """The one Python writer. The sink must sit outside every run root, so
    cleaning a run can never take its record with it."""
    if inside_owned(destination):
        raise ValueError('record sink is inside a run directory')
    line = json.dumps(check_record(record), sort_keys=True, allow_nan=False)
    with Path(destination).open('a') as stream:
        stream.write(line + '\n')
        stream.flush()
        os.fsync(stream.fileno())


def read_records(path):
    return [check_record(json.loads(line)) for line in Path(path).read_text().splitlines() if line.strip()]


def run_contained(task, harness, mode, code, destination, deadline=2, interrupt=False):
    """One fake process run, graded after termination. Usage stays unknown:
    a subprocess has no typed usage, so this adapter never claims any."""
    record = new_record(task, harness, mode)
    run = ContainedRun(task['source'], task['base'])
    try:
        result = run.execute(code, deadline=deadline, interrupt=interrupt)
        record.update(outcome=result['outcome'], wallSeconds=result['wallSeconds'],
                      activeSeconds=result['activeSeconds'],
                      failure=None if result['outcome'] == 'completed' else 'exit %s' % result['exitCode'])
        record['usageProblems'] = ['subprocess adapter has no typed usage']
        graded = grade(task, run.project)
        for key in ('checks', 'gradeResult', 'hiddenPassed', 'neighbourPassed', 'tampered', 'changedPaths', 'diffHash'):
            record[key] = graded[key]
        record['passed'] = record['outcome'] == 'completed' and graded['gradeResult'] == 'passed'
    except Exception as error:
        record.update(outcome='driverFailed', failure=type(error).__name__, passed=False)
        raise
    finally:
        write_record(destination, record)
        run.__exit__()
    return record


# MARK: - Comparison

def pair_exclusion(solo, managed):
    if solo['outcome'] != 'completed' or managed['outcome'] != 'completed':
        return 'a run did not complete'
    if not solo['usageComplete'] or not managed['usageComplete']:
        return 'usage incomplete'
    if solo['delegationAttempts'] or solo['helperCount']:
        return 'solo delegated'
    if managed['fannedOut'] is not True:
        return 'managed did not fan out'
    return None


def compare(records):
    """Differences only for matched solo/managed pairs that both completed with
    complete usage, each figure printed beside both sides' pass/fail."""
    for r in records:
        check_record(r)
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in records:
        groups[(r['task'], r['harness'])][r['mode']].append(r)
    tasks = sorted({r['task'] for r in records})
    expected = [(t, h) for t in tasks for h in HARNESSES]
    excluded = collections.Counter()
    pairs, lines = [], []

    def verdict(r):
        return 'PASS' if r['passed'] else 'FAIL'
    for key in expected:
        modes = groups.get(key, {})
        solo, managed = modes.get('solo', []), modes.get('managed', [])
        if len(solo) != 1 or len(managed) != 1:
            excluded['unmatched (solo %d, managed %d)' % (len(solo), len(managed))] += 1
            continue
        a, b = solo[0], managed[0]
        reason = pair_exclusion(a, b)
        if reason:
            excluded[reason] += 1
            continue
        side = '(solo %s, managed %s)' % (verdict(a), verdict(b))
        pair = dict(task=key[0], harness=key[1], soloPassed=a['passed'], managedPassed=b['passed'],
                    input=b['tokens']['input'] - a['tokens']['input'],
                    output=b['tokens']['output'] - a['tokens']['output'],
                    wallSeconds=b['wallSeconds'] - a['wallSeconds'])
        pairs.append(pair)
        lines.append('%s %s input %+d %s output %+d %s wall %+.2fs %s' % (
            key[1], key[0][:12], pair['input'], side, pair['output'], side, pair['wallSeconds'], side))
    by_mode = collections.Counter((r['mode'], r['passed']) for r in records)
    fan_out = sum(1 for r in records if r['mode'] == 'managed' and r['fannedOut'] is True)
    lines.append('runs %d; pairs compared %d of %d expected; coverage %d/%d' % (
        len(records), len(pairs), len(expected), len(pairs), len(expected)))
    for reason, count in sorted(excluded.items()):
        lines.append('excluded %d: %s' % (count, reason))
    for mode in MODES:
        lines.append('%s: %d passed, %d failed' % (mode, by_mode[(mode, True)], by_mode[(mode, False)]))
    lines.append('managed runs that fanned out: %d' % fan_out)
    if any(r['simulated'] for r in records):
        lines.append('simulated records: not evidence of any model behaviour')
    return dict(runs=len(records), pairs=pairs, expected=len(expected), coverage='%d/%d' % (len(pairs), len(expected)),
                excluded=dict(excluded), fanOutSamples=fan_out, lines=lines)


def main(argv):
    if argv[:1] == ['make-fixture'] and len(argv) == 2:
        task = synthetic_task(Path(argv[1]))
        (Path(argv[1]) / 'task.json').write_text(json.dumps(task, sort_keys=True))
        print(Path(argv[1]) / 'task.json')
    elif argv[:1] == ['grade'] and len(argv) == 3:
        print(json.dumps(grade(json.loads(Path(argv[1]).read_text()), Path(argv[2])), sort_keys=True))
    elif argv[:1] == ['compare'] and len(argv) == 2:
        print('\n'.join(compare(read_records(argv[1]))['lines']))
    else:
        raise SystemExit('usage: replay.py make-fixture DIR | grade TASK TREE | compare RECORDS')


if __name__ == '__main__':
    main(sys.argv[1:])
