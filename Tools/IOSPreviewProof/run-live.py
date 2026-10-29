#!/usr/bin/env python3
"""Live proof using one newly created simulator; always clean up that exact UDID.

The pinned addon resolves only the default device set, so this creates its own
device there. It never adopts or shuts down another simulator.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--backend-package", type=Path, required=True)
parser.add_argument("--ws-package", type=Path, required=True)
parser.add_argument("--device-type", required=True)
parser.add_argument("--runtime", required=True)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--companion-app", type=Path)
parser.add_argument("--array-bin", type=Path)
parser.add_argument("--array-check", default="--ios-preview-live-tile-check", choices=["--ios-preview-live-tile-check"])
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
package = args.backend_package.resolve()
if json.loads((package / "package.json").read_text())["version"] != "0.19.0-canary-20261023-1357114":
    raise RuntimeError("expected the researched T3-pinned backend version")
ws_package = str(args.ws_package.resolve())
device = None
backend = None
backend_log = None
commands = []


def run(name, command, input=None, timeout=240, environment=None):
    commands.append(command)
    result = subprocess.run(command, cwd=root, input=input, capture_output=True, timeout=timeout, env=environment)
    (out / (name + ".log")).write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode}); see {out / (name + '.log')}")
    return result.stdout.decode().strip()


def stop_backend():
    global backend, backend_log
    if backend and backend.poll() is None:
        backend.terminate()
        try:
            backend.wait(timeout=10)
        except subprocess.TimeoutExpired:
            backend.kill()
            backend.wait()
    if backend_log:
        backend_log.close()
    backend = backend_log = None


def start_backend(name):
    global backend, backend_log
    origin_file = out / "live-origin.txt"
    origin_file.unlink(missing_ok=True)
    addon = package / "vendor/serve-sim/dist/native/serve-sim-native.node"
    backend_log = (out / (name + ".log")).open("wb")
    backend = subprocess.Popen(["node", str(root / "Tools/IOSPreviewProof/live-backend.cjs"), str(addon), device,
                                str(out), ws_package], cwd=root, stdout=backend_log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 30
    while not origin_file.exists():
        if backend.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError(f"backend failed to become ready; see {name}.log")
        time.sleep(0.1)
    return origin_file.read_text().strip()


report = {"liveSimulator": "FAIL"}
try:
    run("xcode", ["xcodebuild", "-version"])
    cache = out / "swift-cache"
    cache.mkdir(exist_ok=True)
    binary = out / "PreviewProof"
    run("native-build", ["swiftc", "-module-cache-path", str(cache), str(root / "Tools/IOSPreviewProof/PreviewProof.swift"), "-o", str(binary)])
    app = out / "InputWitness.app"
    app.mkdir(exist_ok=True)
    info = dict(CFBundleIdentifier="dev.arrayapp.preview-proof", CFBundleName="Array Input Proof",
                CFBundleDisplayName="Array Input Proof", CFBundleExecutable="InputWitness", CFBundlePackageType="APPL",
                CFBundleVersion="1", CFBundleShortVersionString="1.0", MinimumOSVersion="17.0", UILaunchScreen={},
                UIDeviceFamily=[1, 2], UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight", "UIInterfaceOrientationPortraitUpsideDown"])
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    sdk = run("sdk", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    run("witness-build", ["xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-sdk", sdk,
        "-target", "arm64-apple-ios17.0-simulator", "-module-cache-path", str(cache),
        str(root / "Tools/IOSPreviewProof/InputWitnessApp.swift"), "-o", str(app / "InputWitness")])
    run("witness-sign", ["codesign", "--force", "--sign", "-", str(app)])
    device = run("create", ["xcrun", "simctl", "create", "Array Preview Proof " + uuid.uuid4().hex[:8], args.device_type, args.runtime])
    uuid.UUID(device)
    (out / "device.udid").write_text(device)
    run("boot", ["xcrun", "simctl", "boot", device])
    run("bootstatus", ["xcrun", "simctl", "bootstatus", device, "-b"])
    run("install", ["xcrun", "simctl", "install", device, str(app)])
    run("launch", ["xcrun", "simctl", "launch", device, "dev.arrayapp.preview-proof"] +
        (["--performance-animation"] if os.environ.get("IOS_PREVIEW_LIVE_PERFORMANCE") == "1" else []))
    container = run("container", ["xcrun", "simctl", "get_app_container", device, "dev.arrayapp.preview-proof", "data"])
    state_path = str(Path(container) / "Documents/proof-state.json")
    run("pasteboard", ["xcrun", "simctl", "pbcopy", device], input="Array café 🧪".encode())
    origin = start_backend("backend")
    run("native-live-check", [str(binary), "--live-check", origin, device, str(out), state_path])
    run("orientation", ["node", str(root / "Tools/IOSPreviewProof/live-controls.cjs"), origin, device, state_path, str(out), ws_package])
    stop_backend()
    if args.array_bin:
        environment = os.environ.copy()
        environment.update(CONTINUUM_APP_SUPPORT=str(out / "array-support"),
                           CONTINUUM_QA_OUTPUT_DIR=str(out / "canvas"),
                           CONTINUUM_IOS_PREVIEW_DEVICE_ID=device,
                           CONTINUUM_IOS_PREVIEW_STATE_PATH=state_path,
                           CONTINUUM_IOS_PREVIEW_WITNESS_APP=str(app))
        run("production-canvas", [str(args.array_bin.resolve()), args.array_check,
            "-continuum.terminal.tmux.enabled", "NO", "-continuum.terminal.tmux.path", ""], environment=environment,
            timeout=1100 if (environment.get("IOS_PREVIEW_LIVE_BUILD_PROJECT") or environment.get("IOS_PREVIEW_LIVE_AGENT_BUILD_PROJECT")) else (600 if environment.get("IOS_PREVIEW_LIVE_PERFORMANCE") else 240))
        print("PASS: production Array canvas tile rendered and accepted real simulator input")
    before = json.loads(Path(state_path).read_text())
    origin = start_backend("backend-restarted")
    run("reconnected", [str(binary), "--capture-live", origin, device, str(out)])
    (out / "companion-native.png").rename(out / "helper-reconnected.png")
    after = json.loads(Path(state_path).read_text())
    assert before["text"] == after["text"] and before["taps"] == after["taps"], "helper restart changed app state"
    if args.companion_app:
        run("companion-install", ["xcrun", "simctl", "install", device, str(args.companion_app.resolve())])
        run("companion-launch", ["xcrun", "simctl", "launch", device, "dev.dylanreedx.continuum"])
        time.sleep(3)
        run("companion-capture", [str(binary), "--capture-live", origin, device, str(out)])
    report = dict(liveSimulator="PASS", device=device, helperRestart="PASS",
                  productionCanvas="PASS" if args.array_bin else "NOT_RUN",
                  companion="CAPTURED" if args.companion_app else "NOT_RUN",
                  input=json.loads((out / "live-report.json").read_text()),
                  orientation=json.loads((out / "orientation-report.json").read_text()))
    print("PASS: live touch, HID typing, Unicode paste, rotation and helper restart")
finally:
    stop_backend()
    if device:
        for action in ["shutdown", "delete"]:
            command = ["xcrun", "simctl", action, device]
            commands.append(command)
            result = subprocess.run(command, capture_output=True, timeout=60)
            (out / (action + ".log")).write_bytes(result.stdout + result.stderr)
            if action == "delete":
                report["ownedDeviceDeleted"] = result.returncode == 0
    (out / "commands.json").write_text(json.dumps(commands, indent=2))
    (out / "live-summary.json").write_text(json.dumps(report, indent=2))
    print(f"Artifacts: {out}")
    if device and not report.get("ownedDeviceDeleted"):
        raise RuntimeError("could not delete the owned simulator; exact UDID retained in the report")
