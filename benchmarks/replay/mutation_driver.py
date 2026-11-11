"""Behavioral mutation proof for production delegation (debug, fake-only)."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Sources/ContinuumRevived/App/ReplayDriverChecks.swift'

def main():
    original = SOURCE.read_bytes()
    needle = b'        if managed {\n'
    assert original.count(needle) == 1
    lines = []
    try:
        for phase, data in [('RED', original.replace(needle, b'        if false {\n')), ('GREEN', original)]:
            SOURCE.write_bytes(data)
            build = subprocess.run(['swift', 'build', '--configuration', 'debug', '--product', 'Array', '-j', '2'],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            (ROOT / 'benchmarks/replay' / ('driver-build-' + phase.lower() + '.txt')).write_text(build.stdout)
            if build.returncode:
                raise RuntimeError('build failed; compilation failure is not RED')
            with tempfile.TemporaryDirectory(prefix='replay-entry-') as d:
                env = dict(os.environ, CONTINUUM_APP_SUPPORT=d)
                check = subprocess.run([str(ROOT / '.build/debug/Array'), '--replay-driver-check'],
                    cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
            lines.append(f'--replay-driver-check {phase} exit={check.returncode}\n{check.stdout}')
            if (phase == 'RED' and check.returncode == 0) or (phase == 'GREEN' and check.returncode != 0):
                raise RuntimeError('unexpected witness result')
    finally:
        if SOURCE.read_bytes() != original:
            SOURCE.write_bytes(original)
        (ROOT / 'benchmarks/replay/driver-mutation-results.txt').write_text('\n'.join(lines))
    print('Production delegation mutation RED; restored driver GREEN')

if __name__ == '__main__':
    main()
