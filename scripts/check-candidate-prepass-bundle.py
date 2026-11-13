#!/usr/bin/env python3
"""Run the production app witness in a real dev bundle, without rebuilding."""
import os
from pathlib import Path
import subprocess
import tempfile

env = dict(os.environ, TERM="xterm-256color", CONTINUUM_SKIP_UI_BASELINES="1")
for name in ("ARRAY_AGENT_ID", "TMUX", "TMUX_PANE"):
    env.pop(name, None)
with tempfile.TemporaryDirectory(prefix="array-prepass-bundle-") as temp:
    root = Path(temp)
    bundle = root / "Array.app"
    subprocess.run(["scripts/make-app-bundle.sh", "--configuration", "debug", "--channel", "dev",
                    "--skip-build", "--output", str(bundle)], env=env,
                   stdin=subprocess.DEVNULL, check=True)
    env["CONTINUUM_APP_SUPPORT"] = str(root / "host-support")
    subprocess.run([str(bundle / "Contents/MacOS/Array"), "--candidate-prepass-check"],
                   env=env, stdin=subprocess.DEVNULL, check=True, timeout=90)
print("PASS candidate-prepass actual dev bundle")
