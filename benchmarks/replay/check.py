"""Offline behavioural witnesses. Never launches a provider or Array."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
import replay

TIMEOUT = 'import time; time.sleep(60)'


def write(code_path, text):
    return 'from pathlib import Path; Path(%r).write_text(%r)' % (code_path, text)


class Witnesses(unittest.TestCase):
    def setUp(self):
        self.host = Path(tempfile.mkdtemp(prefix='replay-check-')).resolve()
        self.task = replay.synthetic_task(self.host)

    def tearDown(self):
        shutil.rmtree(self.host, ignore_errors=True)

    def agent_tree(self, files, base=None):
        """A finished agent working copy: an export with the agent's edits."""
        w = replay.Workspace(self.task['source'], base or self.task['base'])
        self.addCleanup(w.__exit__)
        for path, text in files.items():
            target = w.project / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        return w.project

    def refrozen(self, **changes):
        t = json.loads(json.dumps(dict(self.task, **changes)))
        t['checksHash'] = replay.checks_hash(t)
        return t

    def test_grader(self):
        self.assertTrue(replay.validate(self.task))
        self.assertFalse(replay.validate(self.refrozen(fix=self.task['base'])), 'failing fix accepted')
        self.assertFalse(replay.validate(self.refrozen(base=self.task['fix'])), 'green parent accepted')
        bad = self.refrozen(hidden={'checks/hidden_value.py': 'bad syntax!'})
        self.assertFalse(replay.validate(bad), 'compile failure accepted as RED')
        modified = json.loads(json.dumps(self.task))
        modified['hidden']['checks/hidden_value.py'] = 'assert True\n'
        self.assertFalse(replay.validate(modified), 'modified grader accepted')
        # Agent code that ends the grading process at import time.
        for text, expected in [('import os\nos._exit(0)\n', 'noResult'),
                               ('import sys\nsys.exit(0)\n', 'error:SystemExit')]:
            graded = replay.grade(self.task, self.agent_tree({'calc.py': text}))
            self.assertEqual(graded['checks']['checks/hidden_value.py'], expected,
                             "an agent's exit(0) passed the grader: %s" % graded)
            self.assertNotEqual(graded['gradeResult'], 'passed', "an agent's exit(0) passed the grader")
        # A pass needs the harness's own report for every check.
        graded = replay.grade(self.task, self.agent_tree({'calc.py': replay.FIXED}))
        self.assertEqual(graded['gradeResult'], 'passed', graded)
        self.assertEqual(set(graded['checks']), {'checks/hidden_value.py', 'checks/neighbour.py'})
        # Tampering: the checks are protected, and the pristine copies are used.
        tampered = replay.grade(self.task, self.agent_tree({
            'calc.py': replay.BROKEN.replace('broken', 'half'), 'checks/neighbour.py': 'pass\n',
            'checks/hidden_value.py': 'pass\n'}))
        self.assertEqual(tampered['gradeResult'], 'tampered', 'a tampered check file was not recorded as tampering')
        self.assertEqual(tampered['tampered'], ['checks/hidden_value.py', 'checks/neighbour.py'],
                         'a tampered check file was not recorded as tampering')
        self.assertEqual(tampered['checks']['checks/hidden_value.py'], 'failed', 'an agent-edited check was run')
        # Deleting a check is tampering too; an identical copy of the hidden check is not.
        tree = self.agent_tree({'calc.py': replay.FIXED, 'checks/hidden_value.py': replay.HIDDEN})
        (tree / 'checks' / 'neighbour.py').unlink()
        deleted = replay.grade(self.task, tree)
        self.assertEqual(deleted['tampered'], ['checks/neighbour.py'], 'a deleted check was not recorded as tampering')

    def test_isolation(self):
        roots = []
        for _ in replay.MODES:
            with replay.Workspace(self.task['source'], self.task['base']) as w:
                roots.append(w.root)
                self.assertEqual(replay.git(w.project, 'status', '--porcelain'), '')
                self.assertEqual(replay.git(w.project, 'rev-parse', 'HEAD'), self.task['base'])
                self.assertFalse(replay.has_object(w.project, self.task['fix']), 'future commit reachable')
                self.assertEqual(replay.git(w.project, 'remote'), '')
                self.assertNotIn('TMUX', w.env)
                self.assertNotIn('TMUX_PANE', w.env)
                self.assertTrue(Path(w.env['TMUX_TMPDIR']).is_relative_to(w.root))
                self.assertFalse((w.project / 'checks' / 'hidden_value.py').exists(), 'hidden grader exposed')
        self.assertEqual(len(set(roots)), len(replay.MODES))
        self.assertTrue(all(not p.exists() for p in roots))
        # New files are part of the change set, and are carried into grading.
        tree = self.agent_tree({'calc.py': 'from helper import v\ndef value():\n    return v\n', 'helper.py': 'v = "fixed"\n'})
        graded = replay.grade(self.task, tree)
        self.assertEqual(graded['changedPaths'], ['calc.py', 'helper.py'], 'a new file was dropped')
        self.assertEqual(graded['gradeResult'], 'passed', graded)
        # Ownership is this process's own creation, checked by identity.
        stranger = self.host / 'stranger'
        stranger.mkdir()
        with self.assertRaises(ValueError):
            replay.require_owned(stranger)
        with replay.ContainedRun(self.task['source'], self.task['base']) as run:
            original = run.root
            shutil.rmtree(original)
            original.mkdir()
            with self.assertRaises(ValueError, msg='replaced storage accepted'):
                run.execute('pass')

    def test_containment(self):
        outside = self.host / 'outside'
        outside.write_text('unchanged')
        repository = Path(self.task['source']) / '.git'
        support = Path(os.path.expanduser('~/Library/Application Support'))
        sleeper = subprocess.Popen(['/bin/sleep', '30'])
        self.addCleanup(sleeper.kill)
        with replay.ContainedRun(self.task['source'], self.task['base']) as run:
            good = run.execute(write('allowed', 'ok'))
            self.assertEqual(good['outcome'], 'completed', good)
            for code, why in [
                (write(str(outside), 'escaped'), 'a run wrote outside its directories'),
                ('from pathlib import Path; print(Path(%r).read_text())' % str(repository / 'HEAD'), 'a run read the host repository'),
                ('import os; print(os.listdir(%r))' % str(repository / 'objects'), 'a run read the host repository'),
                ('import os; print(os.listdir(%r))' % str(support), 'a run read Application Support'),
                ('import os; os.kill(%d, 0)' % sleeper.pid, 'a run signalled a process outside its sandbox'),
            ]:
                result = run.execute(code)
                self.assertEqual(result['outcome'], 'containmentFailed', why + ': ' + result['stdout'][:200])
            self.assertEqual(outside.read_text(), 'unchanged', 'a run wrote outside its directories')
            for code, options, expected in [('raise RuntimeError("failed")', {}, 'failed'),
                                            (TIMEOUT, {'deadline': 0.1}, 'timeout'),
                                            (TIMEOUT, {'interrupt': True}, 'interrupted')]:
                result = run.execute(code, **options)
                self.assertEqual(result['outcome'], expected)
                self.assertTrue(result['terminated'])
        self.assertEqual(self.socket_experiment(), {'denyDefault': 'denied', 'withUnixSocketRule': 'connected'},
                         'unix-socket experiment changed its answer')

    def socket_experiment(self):
        """Harmless: a socket this test owns, in its own temporary directory."""
        holder = replay.own_root('replay-socket-')
        self.addCleanup(replay.release_root, holder)
        path = str(holder / 's')
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        server.listen(4)
        self.addCleanup(server.close)

        def serve():
            while True:
                try:
                    server.accept()[0].close()
                except OSError:
                    return
        threading.Thread(target=serve, daemon=True).start()
        answers = {}
        code = 'import socket, sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])'
        with replay.ContainedRun(self.task['source'], self.task['base']) as run:
            rule = '(allow network-outbound (remote unix-socket (path-literal %s)))' % json.dumps(path)
            for name, profile in [('denyDefault', replay.sandbox_profile(run.root)),
                                  ('withUnixSocketRule', replay.sandbox_profile(run.root) + rule)]:
                p = subprocess.run(['/usr/bin/sandbox-exec', '-p', profile, replay.PYTHON, '-I', '-c', code, path],
                                   cwd=run.project, env=run.env, capture_output=True)
                answers[name] = 'connected' if p.returncode == 0 else 'denied'
        return answers

    def test_records(self):
        sink = self.host / 'records.jsonl'
        record = replay.run_contained(self.task, 'codex', 'solo', TIMEOUT, sink, deadline=0.1)
        self.assertEqual(record['outcome'], 'timeout')
        self.assertFalse(record['passed'])
        self.assertFalse(record['usageComplete'])
        good = replay.run_contained(self.task, 'claude', 'solo', write('calc.py', replay.FIXED), sink)
        self.assertTrue(good['passed'], good)
        self.assertEqual(good['changedPaths'], ['calc.py'])
        # A run whose grading raises still leaves its record, after cleanup.
        broken = json.loads(json.dumps(self.task))
        broken['hidden']['checks/hidden_value.py'] = 'assert True\n'
        before = set(replay._OWNED)
        with self.assertRaises(ValueError):
            replay.run_contained(broken, 'claude', 'managed', 'pass', sink)
        self.assertEqual(set(replay._OWNED), before, 'run directory not cleaned')
        saved = replay.read_records(sink)
        self.assertEqual([r['outcome'] for r in saved], ['timeout', 'completed', 'driverFailed'],
                         "a failed run's record vanished")
        with replay.ContainedRun(self.task['source'], self.task['base']) as run:
            with self.assertRaises(ValueError):
                replay.write_record(run.root / 'record.jsonl', record)
        with self.assertRaises(ValueError):
            replay.check_record(dict(record, usageComplete=True, usageProblems=[],
                                     tokens=dict(uncachedInput=1, cacheRead=None, cacheWrite=0, output=1)))
        # Not reported is not missing: complete with a null figure, but never a zero one.
        codex = dict(tokens=dict(uncachedInput=1, cacheRead=2, cacheWrite=None, output=3), tokensNotReported=['cacheWrite'])
        try:
            replay.check_record(dict(record, usageComplete=True, usageProblems=[], **codex))
        except ValueError as error:
            self.fail('a type its harness never reports was read as missing: %s' % error)
        with self.assertRaises(ValueError):
            replay.check_record(dict(record, usageComplete=True, usageProblems=[], tokensNotReported=['cacheWrite'],
                                     tokens=dict(uncachedInput=1, cacheRead=2, cacheWrite=0, output=3)))

    def test_scoring(self):
        def rec(harness, mode, passed=True, outcome='completed', fanned=True, tokens=(100, 10), wall=10.0, attempts=0):
            r = replay.new_record(self.task, harness, mode)
            r.update(outcome=outcome, passed=passed and outcome == 'completed',
                     gradeResult='passed' if passed and outcome == 'completed' else 'failed',
                     tokens=dict(uncachedInput=tokens[0], cacheRead=0, cacheWrite=0, output=tokens[1]),
                     usageComplete=True, usageProblems=[], wallSeconds=wall, activeSeconds=wall,
                     delegationAttempts=attempts)
            if mode == 'managed':
                r.update(fannedOut=fanned, helperCount=2 if fanned else 0)
            return r
        records = [rec('claude', 'solo'), rec('claude', 'managed', passed=False, tokens=(150, 20), wall=7.5),
                   rec('codex', 'solo'), rec('codex', 'managed', tokens=(90, 12), wall=12.0)]
        result = replay.compare(records)
        self.assertEqual(result['coverage'], '2/2')
        line = [l for l in result['lines'] if l.startswith('claude ')][0]
        self.assertEqual(line.count('(solo PASS, managed FAIL)'), 5, 'a figure was printed without both verdicts')
        self.assertIn('uncachedInput +50', line)
        self.assertIn('managed: 1 passed, 1 failed', result['lines'])
        for broken, reason in [
            (rec('codex', 'managed', fanned=False), 'managed did not fan out'),
            (rec('codex', 'managed', outcome='failed'), 'a run did not complete'),
            (dict(rec('codex', 'managed'), usageComplete=False, usageProblems=['cacheRead unknown'],
                  tokens=dict(uncachedInput=90, cacheRead=None, cacheWrite=None, output=12)), 'usage incomplete')]:
            out = replay.compare(records[:3] + [broken])
            self.assertEqual(out['coverage'], '1/2', 'a comparison was printed from an excluded pair: ' + reason)
            self.assertEqual(out['excluded'], {reason: 1}, 'exclusion not counted: ' + reason)
            self.assertFalse(any(l.startswith('codex ') for l in out['lines']), 'difference printed for: ' + reason)
        # A Managed run that did not fan out is shown beside solo, never compared as fan-out.
        out = replay.compare(records[:3] + [rec('codex', 'managed', fanned=False)])
        beside = [l for l in out['lines'] if l.startswith('managed, did not fan out, beside solo: codex ')]
        self.assertEqual(len(beside), 1, 'a managed run that did not fan out was dropped instead of shown beside solo')
        self.assertIn('(solo PASS, managed PASS)', beside[0])
        self.assertTrue(any(l.startswith('row ') and 'managed, did not fan out' in l for l in out['lines']),
                        'the run table does not name a managed run that did not fan out')
        # Every run is a row, with its agents; a strict arm pairs with solo under its own name.
        strict = dict(rec('claude', 'managed-strict', tokens=(120, 15)), fannedOut=True, helperCount=1,
                      usageRows=[dict(agent='a' * 36, role='lead', tokens=dict(uncachedInput=70, cacheRead=0, cacheWrite=0, output=5)),
                                 dict(agent='b' * 36, role='helper', tokens=dict(uncachedInput=50, cacheRead=0, cacheWrite=0, output=10))])
        out = replay.compare(records + [strict])
        self.assertEqual(out['coverage'], '3/3', 'the strict arm was not paired with solo')
        self.assertTrue(any('(solo PASS, managed-strict PASS)' in l and 'uncachedInput +20' in l for l in out['lines']))
        self.assertEqual(sum(1 for l in out['lines'] if l.startswith('row ')), 5, 'a run is missing from the table')
        self.assertTrue(any(l.strip().startswith('helper bbbbbbbb 50/0/0/10') for l in out['lines']),
                        'per-agent tokens are missing from the table')
        out = replay.compare(records[:2] + [rec('codex', 'solo', attempts=1), records[3]])
        self.assertEqual(out['excluded'], {'solo delegated': 1}, 'a delegating solo run was compared')
        self.assertEqual(replay.compare([rec('codex', 'managed', fanned=False)])['fanOutSamples'], 0,
                         'a managed run that did not delegate was counted as fan-out')
        # A type the harness never reports is named, and the pair still compares.
        def unreported(r):
            return dict(r, tokens=dict(r['tokens'], cacheWrite=None), tokensNotReported=['cacheWrite'])
        try:
            out = replay.compare(records[:2] + [unreported(records[2]), unreported(records[3])])
        except ValueError as error:
            self.fail('a type its harness never reports was read as missing: %s' % error)
        self.assertEqual(out['coverage'], '2/2', 'a pair with a type its harness never reports was refused')
        codex_line = [l for l in out['lines'] if l.startswith('codex ')][0]
        self.assertIn('cacheWrite not reported', codex_line)
        self.assertIn('uncachedInput -10', codex_line)
        unmatched = replay.compare(records[:3])
        self.assertEqual(unmatched['coverage'], '1/2', 'a comparison was printed from an unmatched pair')
        duplicate = replay.compare(records + [rec('codex', 'managed')])
        self.assertEqual(duplicate['coverage'], '1/2', 'a comparison was printed from an unmatched pair')
        self.assertFalse(any(l.startswith('codex ') for l in duplicate['lines']), 'a comparison was printed from an unmatched pair')
        # Same base, request and checks per condition; the comparison reads its own writer's records.
        sink = self.host / 'records.jsonl'
        for harness in replay.HARNESSES:
            for mode in replay.MODES:
                replay.run_contained(self.task, harness, mode, write('calc.py', replay.FIXED), sink)
        saved = replay.read_records(sink)
        self.assertEqual(len({(r['task'], r['base'], r['requestHash'], r['checksHash']) for r in saved}), 1)
        self.assertTrue(all(r['passed'] for r in saved))
        self.assertEqual(replay.compare(saved)['excluded'], {'usage incomplete': 4})


if __name__ == '__main__':
    import sys
    names = {'--replay-containment-check': ['test_containment'],
             '--replay-grader-check': ['test_grader'],
             '--replay-isolation-check': ['test_isolation'],
             '--replay-scoring-check': ['test_scoring', 'test_records']}
    suite = unittest.TestSuite(Witnesses(n) for a in sys.argv[1:] for n in names.get(a, []))
    if not suite.countTestCases():
        raise SystemExit('Supply a registered replay check flag')
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
