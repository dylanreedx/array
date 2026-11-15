#!/usr/bin/env python3
"""Pattern dependency must be source data, never an unverified bytecode cache."""
import importlib.util
import importlib._bootstrap_external
from pathlib import Path
import shutil
import sys
import tempfile

source = Path(sys.argv[1] if len(sys.argv) > 1 else "scripts/gate-prepass.py").resolve()


def poisoned_cache_is_ignored(root, prefix):
    # Apple's python3 sets sys.pycache_prefix, which moves the cache out of a
    # __pycache__ beside the source into a mirror of its path under the prefix.
    # Both layouts run on every interpreter: the prefix here does not exist yet.
    sys.pycache_prefix = None if prefix is None else str(prefix)
    work = root / ("prefixed" if prefix else "beside")
    work.mkdir()
    evaluator = work / "evaluator.py"
    patterns = work / "check-notification-map.py"
    shutil.copy(source, evaluator)
    shutil.copy(source.with_name("check-notification-map.py"), patterns)
    marker = work / "executed"
    payload = compile("from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\nPATTERNS={}\n",
                      str(patterns), "exec")
    info = patterns.stat()
    cache = Path(importlib.util.cache_from_source(str(patterns)))
    cache.parent.mkdir(parents=True)
    cache.write_bytes(importlib._bootstrap_external._code_to_timestamp_pyc(
        payload, int(info.st_mtime), info.st_size))
    # Prove that the interpreter accepts the poisoned timestamp/size-matched cache.
    spec = importlib.util.spec_from_file_location("control", patterns)
    control = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(control)
    assert marker.exists(), f"invalid poisoned-cache positive control ({work.name})"
    marker.unlink()
    spec = importlib.util.spec_from_file_location("subject", evaluator)
    subject = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(subject)
    values = subject.notification_patterns()
    assert not marker.exists(), f"FAIL: evaluator executed unverified pattern bytecode ({work.name})"
    assert values and all(isinstance(value, str) for value in values)


interpreter_prefix = sys.pycache_prefix
with tempfile.TemporaryDirectory(prefix="array-prepass-patterns-") as temp:
    root = Path(temp).resolve()
    try:
        poisoned_cache_is_ignored(root, None)
        poisoned_cache_is_ignored(root, root / "pycache-prefix")
    finally:
        sys.pycache_prefix = interpreter_prefix
print("PASS prepass source patterns: poisoned cache executes in control, source-only evaluator ignores it"
      " (cache beside the source and under a pycache prefix)")
