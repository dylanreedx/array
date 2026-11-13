#!/usr/bin/env python3
"""Production evaluator must never invoke repository-selected signature tools."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

evaluator = Path(sys.argv[1] if len(sys.argv) > 1 else "scripts/gate-prepass.py").resolve()
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
           GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
           GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
for key in ("ARRAY_AGENT_ID", "TMUX", "TMUX_PANE", "GIT_DIR", "GIT_WORK_TREE"):
    env.pop(key, None)
with tempfile.TemporaryDirectory(prefix="array-signature-") as temp:
    root = Path(temp)
    def git(*args, data=None):
        return subprocess.check_output(["/usr/bin/git", "-C", temp, *args],
                                       input=data, env=env).decode().strip()
    git("init", "-q")
    (root / "scripts").mkdir()
    (root / "scripts/check-coverage-manifest.json").write_text(
        '{"version":1,"mappedLegs":0,"checks":[],"exceptions":[],"targetedOnly":[]}')
    (root / "scripts/run-matrix.sh").write_text("#!/bin/bash\n")
    git("add", ".")
    git("commit", "-qm", "test(prepass): base")
    base = git("rev-parse", "HEAD")
    tree = git("rev-parse", "HEAD^{tree}")
    raw = (f"tree {tree}\nparent {base}\nauthor Fixture <fixture@example.invalid> 1 +0000\n"
           "committer Fixture <fixture@example.invalid> 1 +0000\n"
           "gpgsig -----BEGIN PGP SIGNATURE-----\n dummy\n -----END PGP SIGNATURE-----\n"
           "\ntest(prepass): signed candidate\n").encode()
    head = git("hash-object", "-t", "commit", "-w", "--stdin", data=raw)
    marker = root / "executed"
    program = root / "signature-helper"
    program.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\nexit 1\n')
    program.chmod(0o755)
    git("config", "log.showSignature", "true")
    git("config", "gpg.program", str(program))
    # Positive control: malicious local config really executes on this commit.
    git("log", "-1", head)
    assert marker.exists(), "invalid fixture: signature program was not invoked"
    marker.unlink()
    result = subprocess.run(["/usr/bin/python3", "-I", "-B", str(evaluator),
                             base, head, "--repo", temp, "--json"],
                            env=env, capture_output=True, timeout=20)
    assert not marker.exists(), "FAIL: evaluator executed checkout-selected gpg.program"
    assert result.returncode in (0, 1), result.stderr.decode()
    print("PASS signature safety: malicious config executes in control, never in evaluator")
