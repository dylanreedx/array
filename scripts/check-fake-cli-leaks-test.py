#!/usr/bin/env python3
"""Behavioral tests of ownership, snapshots and survivors; only kills our PIDs."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

checker = str(Path(__file__).with_name('check-fake-cli-leaks.py').resolve())
with tempfile.TemporaryDirectory(prefix='continuum-fake-leak-check-') as temp:
    root = Path(temp)
    children = []

    def start(scope, name):
        bin_dir = root / scope / ('continuum-test-bin-' + name)
        bin_dir.mkdir(parents=True)
        script = bin_dir / name
        script.write_text('#!/usr/bin/env python3\nimport time\nprint("ready", flush=True)\ntime.sleep(600)\n')
        script.chmod(0o755)
        child = subprocess.Popen([str(script)], stdout=subprocess.PIPE, start_new_session=True)
        children.append(child)
        assert child.stdout.readline() == b'ready\n'
        return child

    def run(*args, expected=0):
        result = subprocess.run([sys.executable, checker, *map(str, args)], text=True, capture_output=True)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        print(result.stdout.strip())

    try:
        old = start('ours', 'claude')
        snapshot = root / 'before.json'
        run('snapshot', snapshot, root / 'ours')
        outside = start('another-bench', 'pi')
        run('check', snapshot)  # A preexisting child and another bench don't count.
        new = start('ours', 'codex')
        run('check', snapshot, expected=1)
        os.killpg(new.pid, signal.SIGKILL)
        new.wait()
        run('check', snapshot)
        assert old.poll() is None and outside.poll() is None
    finally:
        for child in children:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
            child.wait()
print('Fake CLI leak monitor checks passed: preexisting/concurrent excluded; new survivor RED; reaped GREEN.')
