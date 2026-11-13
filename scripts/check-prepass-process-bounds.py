#!/usr/bin/env python3
"""Behavior of the actual bundled controller: tree, output, memory and runtime."""
import importlib.util
import os
from pathlib import Path
import resource
import subprocess
import tempfile
import time

worker = Path("Sources/ContinuumRevived/Resources/GatePrepass/worker.py").resolve()
with tempfile.TemporaryDirectory(prefix="array-prepass-bounds-") as temp:
    root = Path(temp)
    marker = root / "escaped"
    descendant = "import time,pathlib;time.sleep(0.8);pathlib.Path(" + repr(str(marker)) + ").write_text('escaped')"
    parent = "import subprocess,time;subprocess.Popen(['/usr/bin/python3','-c'," + repr(descendant) + "]);time.sleep(20)"
    start = time.monotonic()
    result = subprocess.run(["/usr/bin/python3", "-I", "-B", str(worker), "--limits", ".2", "4096",
                             "/usr/bin/python3", "-c", parent], capture_output=True, timeout=4)
    assert result.returncode != 0 and time.monotonic() - start < 2, "runtime unbounded"
    time.sleep(1)
    assert not marker.exists(), "grandchild survived group termination"
    for stream in ("stdout", "stderr"):
        code = "import sys,time;sys." + stream + ".write('x'*100000);sys." + stream + ".flush();time.sleep(20)"
        result = subprocess.run(["/usr/bin/python3", "-I", "-B", str(worker), "--limits", "2", "4096",
                                 "/usr/bin/python3", "-c", code], capture_output=True, timeout=4)
        assert result.returncode != 0 and len(result.stdout) <= 4096, stream + " unbounded"
    code = ("import resource;"
            "assert resource.getrlimit(resource.RLIMIT_CPU)==(8,8);"
            "assert resource.getrlimit(resource.RLIMIT_FSIZE)==(2097152,2097152);"
            "print('limits inherited')")
    result = subprocess.run(["/usr/bin/python3", "-I", "-B", str(worker), "/usr/bin/python3", "-c", code],
                            capture_output=True, timeout=4)
    assert result.returncode == 0 and b"limits inherited" in result.stdout, result.stderr
    code = "import time; x=bytearray(400*1024*1024);time.sleep(1);print('watchdog failed')"
    result = subprocess.run(["/usr/bin/python3", "-I", "-B", str(worker), "/usr/bin/python3", "-c", code],
                            capture_output=True, timeout=4)
    assert result.returncode != 0 and b"watchdog failed" not in result.stdout, "resident memory watchdog ineffective"
# Exact successful tail delivery: no detached reader can race the controller.
    result = subprocess.run(["/usr/bin/python3", "-I", "-B", str(worker),
                             "/usr/bin/python3", "-c", "import sys;sys.stdout.write('a'*65536+'TAIL')"],
                            capture_output=True, timeout=4)
    assert result.returncode == 0 and result.stdout == b"a"*65536+b"TAIL", "output tail lost"
    # Exercise both evaluators' real streaming Git primitive. It must reject a
    # producer before collecting its whole 5MiB output.
    for path in ("scripts/gate-prepass.py", "Sources/ContinuumRevived/Resources/GatePrepass/evaluator.py"):
        spec = importlib.util.spec_from_file_location("prepass_bounds", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            module.bounded_git(["/usr/bin/python3", "-c", "import sys;sys.stdout.write('x'*5000000)"])
        except module.PrepassError:
            pass
        else:
            raise AssertionError("Git output primitive buffered an oversized stream")
print("PASS prepass process bounds: descendant termination, runtime, stdout/stderr caps, inherited CPU/file limits and group resident-memory watchdog")
