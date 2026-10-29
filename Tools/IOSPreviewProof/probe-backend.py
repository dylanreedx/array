#!/usr/bin/env python3
"""Inspect the exact T3-pinned Expo binary without installing global packages.

Runs only Xcode version, isolated simctl discovery and native-addon loading.
Never boots, installs, launches, or modifies a simulator or an Array instance.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request

VERSION = "0.19.0-canary-20261023-1357114"
parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)


def run(name, command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        log = result.stdout + result.stderr
        code = result.returncode
    except subprocess.TimeoutExpired as error:
        log = str(error)
        code = 124
    (out / f"{name}.log").write_text(log)
    return dict(exitCode=code, log=f"{name}.log")


report = {"package": "expo-device-hub", "version": VERSION}
with urllib.request.urlopen(f"https://registry.npmjs.org/expo-device-hub/{VERSION}") as response:
    metadata = json.load(response)
with urllib.request.urlopen(metadata["dist"]["tarball"]) as response:
    archive = response.read()
integrity = "sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()
if integrity != metadata["dist"]["integrity"]:
    raise RuntimeError("tarball integrity mismatch")
report["integrity"] = integrity
(out / "package-metadata.json").write_text(json.dumps(metadata, indent=2))
(out / "package.tgz").write_bytes(archive)
with tarfile.open(out / "package.tgz") as package:
    package.extractall(out / "upstream", filter="data")
addon = out / "upstream/package/vendor/serve-sim/dist/native/serve-sim-native.node"
node = """
const n = require(process.argv[1]);
console.log(JSON.stringify({exports:Object.keys(n),
  capture:Object.getOwnPropertyNames(n.SimCapture.prototype),
  input:Object.getOwnPropertyNames(n.SimHID.prototype)},null,2));
"""
report["nativeAddonLoad"] = run("native-addon", ["node", "-e", node, str(addon)])
report["xcode"] = run("xcode", ["xcodebuild", "-version"])
device_set = out / "device-set"
device_set.mkdir(exist_ok=True)
report["isolatedSimulatorDiscovery"] = run("simctl", ["xcrun", "simctl", "--set", str(device_set),
                                                         "list", "devices", "--json"])
report["liveFramesAndInput"] = "NOT_VERIFIED"
(out / "backend-report.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
if report["nativeAddonLoad"]["exitCode"] != 0 or report["isolatedSimulatorDiscovery"]["exitCode"] != 0:
    raise SystemExit(1)
