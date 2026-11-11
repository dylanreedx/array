"""Reproducible behavioral RED/GREEN; mutations touch disposable code copies only."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
MUTATIONS = [
    ('--replay-grader-check', "return grader.grade(before.project) == 'assertion_failed' and grader.grade(after.project) == 'passed'", 'return True'),
    ('--replay-isolation-check', "git(self.project, 'init', '-q')", "git(self.project, 'init', '-q')\n            git(self.project, 'fetch', str(repo), 'HEAD')"),
    ('--replay-containment-check', '(deny file-write*)', ''),
    ('--replay-scoring-check', 'if complete and complete == expected else None', 'if complete else None'),
]

def main():
    lines = []
    for flag, original, mutant in MUTATIONS:
        with tempfile.TemporaryDirectory(prefix='replay-mutation-') as d:
            root = Path(d)
            source = (HERE / 'replay.py').read_text()
            assert source.count(original) == 1, flag
            (root / 'check.py').write_bytes((HERE / 'check.py').read_bytes())
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
            for phase, code in [('RED', source.replace(original, mutant)), ('GREEN', source)]:
                (root / 'replay.py').write_text(code)
                result = subprocess.run([sys.executable, str(root / 'check.py'), flag],
                    capture_output=True, text=True, env=env)
                lines.append(f'{flag} {phase} exit={result.returncode}\n{result.stdout}{result.stderr}')
                if (phase == 'RED' and result.returncode == 0) or (phase == 'GREEN' and result.returncode != 0):
                    print('\n'.join(lines))
                    raise SystemExit(1)
    (HERE / 'mutation-results.txt').write_text('\n'.join(lines))
    print('Four behavioral mutations RED; restored witnesses GREEN. See mutation-results.txt')

if __name__ == '__main__':
    main()
