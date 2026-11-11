"""Offline behavioural witnesses. Never launches a provider or Array."""
import json
import tempfile
import unittest
from pathlib import Path
import replay

class Witnesses(unittest.TestCase):
    def test_grader(self):
        with tempfile.TemporaryDirectory(prefix='replay-') as d:
            root = Path(d)
            repo, base, fix = replay.fixture(root)
            grader = replay.Grader(b'from pathlib import Path\nassert Path("value").read_text() == "fixed"\n')
            self.assertTrue(replay.validate(repo, base, fix, grader))
            self.assertFalse(replay.validate(repo, fix, fix, grader))
            self.assertFalse(replay.validate(repo, base, base, grader))
            self.assertFalse(replay.validate(repo, base, fix, replay.Grader(b'bad syntax!')))
            grader.source = b'assert True'
            self.assertFalse(replay.validate(repo, base, fix, grader))

    def test_isolation(self):
        with tempfile.TemporaryDirectory(prefix='replay-') as d:
            root = Path(d)
            repo, base, fix = replay.fixture(root)
            roots = []
            for mode in replay.MODES:
                with replay.Workspace(repo, base) as w:
                    roots.append(str(w.root))
                    self.assertEqual(replay.git(w.project, 'status', '--porcelain'), '')
                    self.assertEqual(replay.git(w.project, 'rev-parse', 'HEAD'), base)
                    self.assertFalse(replay.has_object(w.project, fix))
                    self.assertEqual(replay.git(w.project, 'remote'), '')
                    self.assertNotIn('TMUX', w.env)
                    self.assertNotIn('TMUX_PANE', w.env)
                    self.assertTrue(Path(w.env['TMUX_TMPDIR']).is_relative_to(w.root))
                    self.assertFalse((w.project / 'grader.py').exists())
            self.assertEqual(len(set(roots)), 3)
            self.assertTrue(all(not Path(p).exists() for p in roots))
            with self.assertRaises(RuntimeError):
                replay.require_live_isolation()

    def test_scoring(self):
        with tempfile.TemporaryDirectory(prefix='replay-') as d:
            repo, base, fix = replay.fixture(Path(d))
            grader = replay.Grader(b'from pathlib import Path\nassert Path("value").read_text() == "fixed"\n')
            records = []
            for harness in replay.HARNESSES:
                for mode in replay.MODES:
                    records.append(replay.run_fake(repo, base, 'Repair the value.', grader,
                        harness, mode, 'completed'))
            self.assertEqual(len({r['requestHash'] for r in records}), 1)
            for r in records:
                self.assertTrue(r['passed'])
                self.assertEqual(r['tokens']['input'], 12)
                self.assertEqual(r['activeSeconds'], 3)
                self.assertEqual(r['wallSeconds'], 4)
                self.assertEqual(r['humanSteps'], 1)
                self.assertTrue(r['diffHash'])
            self.assertEqual(replay.compare(records)['coverage'], '2/2')
            self.assertIsNone(replay.compare(records[:-2])['difference'])
            for outcome in ('failed', 'timeout', 'interrupted'):
                r = replay.run_fake(repo, base, 'Repair the value.', grader,
                    'claude', 'solo', outcome)
                replay.append_record(Path(d) / 'results.jsonl', r)
                self.assertEqual(r['outcome'], outcome)
                self.assertFalse(r['passed'])
                self.assertIsNone(replay.compare([r])['difference'])
            saved = [json.loads(line) for line in (Path(d) / 'results.jsonl').read_text().splitlines()]
            self.assertEqual([r['outcome'] for r in saved], ['failed', 'timeout', 'interrupted'])
            r = replay.run_fake(repo, base, 'Repair the value.', grader,
                'claude', 'solo', 'completed', neighbor_ok=False)
            self.assertFalse(r['passed'])
            r = replay.run_fake(repo, base, 'Repair the value.', grader,
                'claude', 'solo', 'completed', repair=False)
            self.assertFalse(r['hiddenPassed'])

if __name__ == '__main__':
    import sys
    names = {'--replay-grader-check': 'test_grader',
             '--replay-isolation-check': 'test_isolation',
             '--replay-scoring-check': 'test_scoring'}
    suite = unittest.TestSuite(Witnesses(names[a]) for a in sys.argv[1:])
    if not suite.countTestCases():
        raise SystemExit('Supply a registered replay check flag')
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
