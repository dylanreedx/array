#!/usr/bin/env python3
"""Compile the production command runner alone; verify owned descendant cleanup."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = (args.out or Path(tempfile.mkdtemp(prefix='array-ios-command-check-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
source = (root / 'Sources/ContinuumRevived/IOSPreview/IOSPreviewTools.swift').read_text()
runner = source[source.index('private final class IOSPreviewCommandTask'):source.index('struct IOSPreviewDevice')]
harness = r'''
struct ToolEnvironment {
    static let shared = ToolEnvironment()
    func environment() -> [String: String] { ProcessInfo.processInfo.environment }
}
@main struct CommandProcessTreeProbe {
    @MainActor static func main() async {
        do { try await check(outputToFile: false); try await check(outputToFile: true); try await checkBoundedLog() }
        catch { print("FAIL: \(error)"); Darwin.exit(1) }
    }
    @MainActor static func checkBoundedLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-bounded-build-log-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("build.log")
        try await IOSPreviewCommands.runBoundedLog(["/usr/bin/awk", "BEGIN { for(i=0;i<1048576;i++) printf \"x\"; printf \"END\" }"], outputURL: log, timeoutSeconds: 5)
        let data = try Data(contentsOf: log)
        guard data.count == 512 * 1024, data.suffix(3) == Data("END".utf8) else { throw NSError(domain: "bounded-log-tail", code: 1) }
        do {
            try await IOSPreviewCommands.runBoundedLog(["/bin/sleep", "30"], outputURL: log, timeoutSeconds: 0.02)
            throw NSError(domain: "bounded-log-timeout-not-enforced", code: 1)
        } catch is IOSPreviewError {}
        print("PASS: production bounded build log keeps newest 512KiB, finite timeout stops owned command")
    }
    @MainActor static func check(outputToFile: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-command-tree-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("owned-pids")
        var completed = false, cancelled = false
        let task = Task {
            do { _ = try await IOSPreviewCommands.run(["/bin/sh", "-c", "trap '' TERM; /bin/sleep 30 & child=$!; printf '%s %s\\n' \"$$\" \"$child\" > \"$1\"; wait \"$child\"", "array-command-tree", pidFile.path], outputURL: outputToFile ? root.appendingPathComponent("captured-command.log") : nil) }
            catch is CancellationError { cancelled = true }
            catch { print("Unexpected runner error: \(error)") }
            completed = true
        }
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
        guard pids.count == 2 else { throw NSError(domain: "probe-no-owned-pids", code: 1) }
        defer { for pid in pids where Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) } }
        let began = Date()
        task.cancel()
        let deadline = Date().addingTimeInterval(4)
        while !completed, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let completionSeconds = Date().timeIntervalSince(began)
        let deathDeadline = Date().addingTimeInterval(1)
        while pids.contains(where: { Darwin.kill($0, 0) == 0 }), Date() < deathDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let alive = pids.filter { Darwin.kill($0, 0) == 0 }
        print("Command process tree: stdoutToFile=\(outputToFile), cancellationCompleted=\(completed), cancellationError=\(cancelled), elapsedSeconds=\(completionSeconds), survivingOwnedPIDs=\(alive)")
        // Clean only the fixture's known descendants even when reproducing RED.
        for pid in alive { Darwin.kill(pid, SIGKILL) }
        await task.value
        guard completed, cancelled, completionSeconds < 4, alive.isEmpty else {
            throw NSError(domain: "probe-process-tree-cancellation", code: 1)
        }
        let output = try await IOSPreviewCommands.run(["/usr/bin/printf", "%s", "captured output"])
        guard String(data: output, encoding: .utf8) == "captured output" else { throw NSError(domain: "probe-captured-output", code: 1) }
        let log = root.appendingPathComponent("command.log")
        let data = try await IOSPreviewCommands.run(["/bin/sh", "-c", "printf stdout; printf stderr >&2; printf tail"], outputURL: log)
        guard data.isEmpty, try String(contentsOf: log, encoding: .utf8) == "stdoutstderrtail" else { throw NSError(domain: "probe-output-file", code: 1) }
        let timeoutBegan = Date()
        do {
            _ = try await IOSPreviewCommands.run(["/bin/sleep", "30"], timeoutSeconds: 0.05)
            throw NSError(domain: "probe-timeout-ignored", code: 1)
        } catch is IOSPreviewError { }
        guard Date().timeIntervalSince(timeoutBegan) < 4 else { throw NSError(domain: "probe-timeout-hung", code: 1) }
        let noisyLog = root.appendingPathComponent("noisy.log")
        let marker = "<final-stderr-marker>"
        do {
            _ = try await IOSPreviewCommands.run(["/bin/sh", "-c", "/bin/dd if=/dev/zero bs=1048576 count=10 1>&2 2>/dev/null; printf '<final-stderr-marker>' >&2; exit 7"], outputURL: noisyLog)
            throw NSError(domain: "probe-noisy-error-ignored", code: 1)
        } catch let error as IOSPreviewError {
            let message = error.localizedDescription
            guard message.count <= 1400, message.hasSuffix(marker) else { throw NSError(domain: "probe-error-tail-unbounded", code: 1) }
        }
        do {
            _ = try await IOSPreviewCommands.run(["/bin/sh", "-c", "/bin/dd if=/dev/zero bs=1048576 count=10 1>&2 2>/dev/null; printf '<final-stderr-marker>' >&2; exit 7"])
            throw NSError(domain: "probe-noisy-captured-error-ignored", code: 1)
        } catch let error as IOSPreviewError {
            guard error.localizedDescription.count <= 1400, error.localizedDescription.hasSuffix(marker) else {
                throw NSError(domain: "probe-captured-error-tail-unbounded", code: 1)
            }
        }
        let byteCount = try FileManager.default.attributesOfItem(atPath: noisyLog.path)[.size] as? NSNumber
        guard byteCount?.intValue == 10 * 1024 * 1024 + marker.utf8.count else { throw NSError(domain: "probe-noisy-log-incomplete", code: 1) }
        print("PASS: owned shell and child killed; pipe reaches EOF; captured stdout, retained stdout/stderr, timeout and 10MB stderr with bounded error tail preserved")
    }
}
'''
path = out / 'command-process-tree.swift'
path.write_text('import Foundation\nimport Darwin\n' + runner + harness)
compiled = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-parse-as-library', '-swift-version', '5', str(path), '-o', str(out / 'command-process-tree')], text=True, capture_output=True)
(out / 'compile.log').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    print(compiled.stderr)
    raise SystemExit(compiled.returncode)
result = subprocess.run([str(out / 'command-process-tree')], text=True, capture_output=True, timeout=20)
(out / 'result.log').write_text(result.stdout + result.stderr)
print(result.stdout + result.stderr, end='')
raise SystemExit(result.returncode)
