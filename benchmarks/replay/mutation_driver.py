"""Behavioural RED/GREEN for the production driver (debug builds, fake agents
only). A RED counts only if the check fails with the named reason; a build
failure is never RED."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Sources/ContinuumRevived/App/ReplayDriverChecks.swift'
MUTATIONS = [
    ('solo run that delegates',
     b'            if forbid { facts.intercept(); return }\n',
     b'            if false { facts.intercept(); return }\n',
     'FAIL: solo run delegated: the production record has 1 helper(s)'),
    ('codex resume without a baseline read as complete',
     b'        let complete = line.fullyCounted && problems.isEmpty\n',
     b'        let complete = task.state == .closed\n',
     'FAIL: a Codex resume without a baseline was recorded complete'),
    ("ledger rows' incomplete flags dropped",
     b'        problems += Set(task.usage.flatMap(\\.incomplete)).subtracting(["reportedByParent"]).sorted()\n',
     b'',
     "FAIL: a Codex resume's record does not carry the ledger's noBaseline flag"),
    ('missing counted as zero',
     b'                tokens[name] = NSNull(); problems.append("\\(name) unknown")\n',
     b'                tokens[name] = figure.known; problems.append("\\(name) unknown")\n',
     'FAIL: a Codex resume without a baseline produced a total'),
    ('codex cache write not reported counted as incomplete',
     b'                tokens[name] = NSNull(); notReported.append(name)\n',
     b'                tokens[name] = NSNull(); problems.append("\\(name) unknown")\n',
     'FAIL: codex solo usage was not complete'),
    ("helpers' usage left out of the task",
     b'        let all = line.tokens[.all] ?? [:]\n',
     b'        let all = line.tokens[.lead] ?? [:]\n',
     'FAIL: claude managed tokens are not'),
    ("failed run's record vanishes",
     b'            try ReplayRecordSchema.write(record, to: sink)\n',
     b'            if record["outcome"] as? String == "completed" { try ReplayRecordSchema.write(record, to: sink) }\n',
     "FAIL: a failed run's record vanished"),
]


def build_env():
    """The /usr/bin/python3 shim exports the Command Line Tools SDKROOT, which
    does not match the Xcode compiler; resolve the SDK without it."""
    env = {k: v for k, v in os.environ.items() if k != 'SDKROOT'}
    env['SDKROOT'] = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                             env=env, text=True).strip()
    return env


def build(log):
    for product in ('array-workspace-mcp', 'Array'):
        result = subprocess.run(['swift', 'build', '--configuration', 'debug', '--product', product, '-j', '4'],
                                cwd=ROOT, env=build_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (ROOT / 'benchmarks/replay' / log).write_text(result.stdout)
        if result.returncode:
            raise RuntimeError('build failed; compilation failure is not RED (see %s)' % log)


def check():
    with tempfile.TemporaryDirectory(prefix='replay-entry-') as d:
        env = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE')}
        env.update(CONTINUUM_APP_SUPPORT=d, TMUX_TMPDIR=d)
        return subprocess.run([str(ROOT / '.build/debug/Array'), '--replay-driver-check'], cwd=ROOT, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)


def main():
    original = SOURCE.read_bytes()
    lines = []
    try:
        for name, needle, mutant, reason in MUTATIONS:
            assert original.count(needle) == 1, name
            SOURCE.write_bytes(original.replace(needle, mutant))
            build('driver-build-red.txt')
            result = check()
            failure = [l for l in result.stdout.splitlines() if l.startswith('FAIL: ')]
            lines.append('%s: RED exit=%d %s' % (name, result.returncode, failure[0][:160] if failure else 'no failure'))
            if result.returncode == 0 or not any(l.startswith(reason) for l in failure):
                raise RuntimeError('mutation %r was not RED for its reason:\n%s' % (name, result.stdout[-3000:]))
        SOURCE.write_bytes(original)
        build('driver-build-green.txt')
        result = check()
        lines.append('restored: GREEN exit=%d %s' % (result.returncode, result.stdout.strip().splitlines()[-1]))
        if result.returncode:
            raise RuntimeError('restored driver is not GREEN:\n' + result.stdout[-3000:])
    finally:
        if SOURCE.read_bytes() != original:
            SOURCE.write_bytes(original)
        (ROOT / 'benchmarks/replay/driver-mutation-results.txt').write_text('\n'.join(lines) + '\n')
    print('%d driver mutations RED for their named reason; restored driver GREEN' % len(MUTATIONS))


if __name__ == '__main__':
    main()
