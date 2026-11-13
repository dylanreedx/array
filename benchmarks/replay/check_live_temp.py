"""Offline behavior of the live replay's host-owned mktemp shim."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SHIM = Path(__file__).resolve().parent / 'live-bin' / 'mktemp'


class LiveTempChecks(unittest.TestCase):
    def test_missing_prefix_terminates(self):
        with tempfile.TemporaryDirectory() as root:
            result = subprocess.run([str(SHIM), '-t'], env=dict(os.environ, TMPDIR=root),
                                    capture_output=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)

    def test_temp_files_stay_in_run(self):
        with tempfile.TemporaryDirectory(prefix='replay temp ') as root:
            for args in ([], ['-d'], ['-t', 'fixture'], ['-tfixture']):
                result = subprocess.run([str(SHIM)] + args, env=dict(os.environ, TMPDIR=root),
                                        capture_output=True, text=True, timeout=2, check=True)
                path = Path(result.stdout.strip())
                self.assertEqual(path.parent, Path(root))
                self.assertTrue(path.exists())


if __name__ == '__main__':
    unittest.main()
