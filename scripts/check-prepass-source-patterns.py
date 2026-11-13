#!/usr/bin/env python3
"""Pattern dependency must be source data, never an unverified bytecode cache."""
import importlib.util
import importlib._bootstrap_external
from pathlib import Path
import shutil
import sys
import tempfile

source = Path(sys.argv[1] if len(sys.argv) > 1 else "scripts/gate-prepass.py").resolve()
with tempfile.TemporaryDirectory(prefix="array-prepass-patterns-") as temp:
    root = Path(temp)
    evaluator = root / "evaluator.py"
    patterns = root / "check-notification-map.py"
    shutil.copy(source, evaluator)
    shutil.copy(source.with_name("check-notification-map.py"), patterns)
    marker = root / "executed"
    payload = compile("from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\nPATTERNS={}\n",
                      str(patterns), "exec")
    info = patterns.stat()
    cache = Path(importlib.util.cache_from_source(str(patterns)))
    cache.parent.mkdir()
    cache.write_bytes(importlib._bootstrap_external._code_to_timestamp_pyc(
        payload, int(info.st_mtime), info.st_size))
    # Prove that the interpreter accepts the poisoned timestamp/size-matched cache.
    spec = importlib.util.spec_from_file_location("control", patterns)
    control = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(control)
    assert marker.exists(), "invalid poisoned-cache positive control"
    marker.unlink()
    spec = importlib.util.spec_from_file_location("subject", evaluator)
    subject = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(subject)
    values = subject.notification_patterns()
    assert not marker.exists(), "FAIL: evaluator executed unverified pattern bytecode"
    assert values and all(isinstance(value, str) for value in values)
print("PASS prepass source patterns: poisoned cache executes in control, source-only evaluator ignores it")
