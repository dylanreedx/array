#!/usr/bin/env python3
"""Behavioral ownership tests plus a positive control using the real Swift bench."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
checker = Path(__file__).with_name('check-fake-cli-leaks.py').resolve()
spec = importlib.util.spec_from_file_location('fixture_leaks', checker)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


def run(*args, expected=0):
    result = subprocess.run([sys.executable, str(checker), *map(str, args)], text=True, capture_output=True)
    assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
    print(result.stdout.strip(), flush=True)
    return result.stdout


def unit():
    with tempfile.TemporaryDirectory(prefix='continuum-fake-leak-check-') as temp:
        root = Path(temp)
        children = []
        ours, foreign = str(uuid.uuid4()), str(uuid.uuid4())

        def start(scope, name, owner, fixture=True, arguments=()):
            bin_dir = root / scope / (('continuum-test-bin-' + str(uuid.uuid4())) if fixture else 'real-cli-bin')
            bin_dir.mkdir(parents=True)
            script = bin_dir / name
            script.write_text('#!/usr/bin/env python3\nimport time\nprint("ready", flush=True)\ntime.sleep(600)\n')
            script.chmod(0o755)
            env = dict(os.environ)
            env.pop('ARRAY_CHECK_RUN_ID', None)
            if owner: env['ARRAY_CHECK_RUN_ID'] = owner
            child = subprocess.Popen([str(script), *arguments], env=env, stdout=subprocess.PIPE, start_new_session=True)
            children.append(child)
            assert child.stdout.readline() == b'ready\n'
            return child, script

        try:
            old, _ = start('preexisting', 'claude', ours)
            snapshot = root / 'before.json'
            run('snapshot', snapshot, ours)
            outside, _ = start('another-bench', 'pi', foreign)
            unmarked, fake_path = start('unmarked', 'claude', None)
            real, _ = start('real-cli', 'claude', ours, fixture=False, arguments=(str(fake_path),))
            run('check', snapshot)
            new, new_script = start('new', 'codex', ours)
            shutil.rmtree(new_script.parent)  # Teardown may already have deleted the bench.
            run('check', snapshot, expected=1)
            os.killpg(new.pid, signal.SIGKILL)
            new.wait()
            run('check', snapshot)
            assert all(child.poll() is None for child in (old, outside, unmarked, real))
        finally:
            for child in children:
                if child.poll() is None: os.killpg(child.pid, signal.SIGKILL)
                child.wait()
    print('Fake CLI ownership passed: preexisting, foreign, unmarked and real CLIs excluded; own survivor RED; reaped GREEN.', flush=True)


def reap_control(record):
    # This PID was handed off by the app we just started. Revalidate its run
    # marker, exact executable and group before signaling anything.
    bin_dir = Path(record['bin'])
    assert bin_dir.parent.resolve() == Path(record['foundationTemp']).resolve()
    assert bin_dir.name.startswith('continuum-fake-cli-positive-control-bin-')
    uuid.UUID(bin_dir.name.removeprefix('continuum-fake-cli-positive-control-bin-'))
    found = monitor.fixtures(record['runID']).get(str(record['pid']))
    if found:
        assert Path(found['executable']).resolve() == Path(record['executable']).resolve()
        assert found['pgid'] == record['pgid'] == record['pid'] > 1
        os.killpg(record['pgid'], signal.SIGKILL)
    if bin_dir.exists(): shutil.rmtree(bin_dir)


def real_bench(app):
    app = str(Path(app).resolve())
    for old in (True, False):
        with tempfile.TemporaryDirectory(prefix='array-real-bench-control-', dir='/tmp') as temp:
            root = Path(temp)
            for name in ('project', 'support'): (root / name).mkdir()
            run_id = str(uuid.uuid4())
            snapshot, control = root / 'before.json', root / 'control.json'
            run('snapshot', snapshot, run_id)
            env = dict(os.environ, ARRAY_CHECK_RUN_ID=run_id, ARRAY_FAKE_CLI_CONTROL_PATH=str(control),
                       CONTINUUM_FAKE_CLI_LEAK_OLD_FIXTURE='1' if old else '0',
                       CONTINUUM_APP_SUPPORT=str(root / 'support'), CONTINUUM_PROJECT_ROOT=str(root / 'project'))
            env.pop('ARRAY_AGENT_ID', None)
            record = None
            child = subprocess.Popen([app, '--fake-cli-leak-probe-check', '-continuum.terminal.tmux.enabled', 'NO',
                                      '-continuum.terminal.tmux.path', ''], env=env, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            try:
                output, _ = child.communicate(timeout=30)
                print(output, end='', flush=True)
                assert child.returncode == 0, (child.returncode, output)
                record = json.loads(control.read_text())
                assert record['runID'] == run_id and record['oldFixture'] == old
                if old: assert str(record['pid']) in monitor.fixtures(run_id)
                verdict = run('check', snapshot, expected=1 if old else 0)
                assert f"{1 if old else 0} new survivor(s)" in verdict
                print(f'Real Swift bench: old hold={old}, monitor {"RED (1)" if old else "GREEN (0)"}', flush=True)
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                if record is None and control.exists(): record = json.loads(control.read_text())
                if record is not None: reap_control(record)
            run('check', snapshot)
    print('Real bench positive control passed: actual Foundation bin, old hold RED, fixed hold GREEN, owned PID reaped.', flush=True)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--real-bench': real_bench(sys.argv[2])
    else:
        assert len(sys.argv) == 1, 'usage: check-fake-cli-leaks-test.py [--real-bench Array]'
        unit()
