"""Behavioural RED/GREEN for each Python guard. Mutations touch disposable
copies only; a RED counts only if the witness fails with the named reason."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
MUTATIONS = [
    ('grader an exit(0) fools', '--replay-grader-check',
     "    if timed_out or len(results) != 1 or done != 1:\n        return 'noResult'\n",
     "    if timed_out or len(results) != 1 or done != 1:\n        return 'passed' if process.returncode == 0 else 'noResult'\n",
     "an agent's exit(0) passed the grader"),
    ('tampered check file', '--replay-grader-check',
     "                tampered.append(path)\n", "                pass\n",
     'a tampered check file was not recorded as tampering'),
    ('run reads the host repository', '--replay-containment-check',
     "'(version 1)(deny default)',", "'(version 1)(allow default)(deny network*)(deny file-write*)',",
     'a run read the host repository'),
    ('run writes outside its directories', '--replay-containment-check',
     "'(allow file-write* (literal \"/dev/null\") (subpath %s))' % q(str(root))])",
     "'(allow file-write*)'])",
     'a run wrote outside its directories'),
    ('managed run that did not delegate counted as fan-out', '--replay-scoring-check',
     "    if managed['fannedOut'] is not True:\n        return 'managed did not fan out'\n", "",
     'a comparison was printed from an excluded pair: managed did not fan out'),
    ('comparison from a failed pair', '--replay-scoring-check',
     "    if solo['outcome'] != 'completed' or managed['outcome'] != 'completed':\n        return 'a run did not complete'\n", "",
     'a comparison was printed from an excluded pair: a run did not complete'),
    ('comparison from an unmatched pair', '--replay-scoring-check',
     "if len(solo) != 1 or len(managed) != 1:", "if not solo or not managed:",
     'a comparison was printed from an unmatched pair'),
    ('comparison from an incomplete pair', '--replay-scoring-check',
     "    if not solo['usageComplete'] or not managed['usageComplete']:\n        return 'usage incomplete'\n", "",
     'a comparison was printed from an excluded pair: usage incomplete'),
    ('not reported counted as missing', '--replay-scoring-check',
     "if record['tokens'][t] is None and t not in not_reported]", "if record['tokens'][t] is None]",
     'a type its harness never reports was read as missing'),
    ("failed run's record vanishes", '--replay-scoring-check',
     "    finally:\n        write_record(destination, record)\n        run.__exit__()\n    return record\n",
     "    finally:\n        run.__exit__()\n    write_record(destination, record)\n    return record\n",
     "a failed run's record vanished"),
]


def main():
    lines = []
    for name, flag, original, mutant, reason in MUTATIONS:
        with tempfile.TemporaryDirectory(prefix='replay-mutation-') as d:
            root = Path(d)
            source = (HERE / 'replay.py').read_text()
            assert source.count(original) == 1, name
            for extra in ('check.py', 'manifest.json'):
                (root / extra).write_bytes((HERE / extra).read_bytes())
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
            for phase, code in [('RED', source.replace(original, mutant)), ('GREEN', source)]:
                (root / 'replay.py').write_text(code)
                result = subprocess.run([sys.executable, str(root / 'check.py'), flag],
                                        capture_output=True, text=True, env=env)
                output = result.stdout + result.stderr
                # unittest says FAIL for an assertion and ERROR for anything
                # else (an import, syntax or tool error), which never counts.
                behavioural = (result.returncode != 0 and '\nFAIL: ' in output
                               and '\nERROR: ' not in output and reason in output)
                lines.append('%s: %s %s exit=%d %s' % (name, flag, phase, result.returncode,
                                                       reason if behavioural else 'all witnesses passed'
                                                       if result.returncode == 0 else 'unexpected failure'))
                if (phase == 'RED' and not behavioural) or (phase == 'GREEN' and result.returncode != 0):
                    print('\n'.join(lines))
                    print(output)
                    raise SystemExit(1)
    (HERE / 'mutation-results.txt').write_text('\n'.join(lines) + '\n')
    print('%d behavioural mutations RED for their named reason; restored witnesses GREEN.' % len(MUTATIONS))


if __name__ == '__main__':
    main()
