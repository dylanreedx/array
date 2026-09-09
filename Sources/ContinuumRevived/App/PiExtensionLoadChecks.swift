import ContinuumRevivedCore
import Foundation

/// `--pi-extension-load-check` — the gate that asks the REAL `pi` to load every
/// extension Array ships, and fails when pi rejects one.
///
/// Why this exists: `continuum-workspace-tools.ts` reached
/// `array/cx01-canvas-api` with a syntax error a three-way merge had spliced in,
/// and every check in the repo stayed green — because nothing in the repo ever
/// asked pi to PARSE these files. A resource we hand to another program's
/// parser is only witnessed by that parser.
///
/// The witness, per file: `pi --mode rpc -ne -e <bundled path>` with stdin closed
/// exits 0 for a loadable extension and non-zero for one pi cannot parse. It
/// needs no model, no auth and no network — pi loads the extension during
/// startup, then reaches EOF on stdin and exits. `-ne` disables auto-discovery,
/// so the ONLY extension in the run is the one named with `-e`.
///
/// Teeth: a positive control copies a bundled extension into a temp dir with a
/// deliberate syntax error injected and asserts pi rejects THAT. Without it a
/// future pi that silently swallowed load failures would leave the gate green
/// while shipping a broken extension.
///
/// Isolation: `PI_CODING_AGENT_DIR` points at a temp dir for every run, so the
/// user's `~/.pi` is never written (pi mints `auth.json`, `models-store.json`
/// and `sessions/` in that dir on startup). `CONTINUUM_ARRAY_MANAGED_AGENT=1`
/// matches how a managed runner loads these files — the extensions check the
/// marker themselves.
///
/// Skip: when `pi` is not on PATH the leg prints a loud SKIP naming every file
/// it did not parse and exits 0. A missing developer tool must not be reported
/// as a passing gate, and must not turn the matrix red either.
enum PiExtensionLoadChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    /// A per-file budget. pi's startup parse is well under a second; 30s is a
    /// loaded-machine allowance, not an expectation.
    static let perFileTimeout: TimeInterval = 30

    private struct Outcome {
        let status: Int32
        let timedOut: Bool
        let stderr: String
    }

    /// Runs `pi --mode rpc -ne -e <path>` to completion or to the timeout, and
    /// never leaves the process behind: a timeout escalates SIGTERM to SIGKILL
    /// and then waits.
    private static func loadExtension(
        command: PiAgentRunner.ResolvedCommand,
        extensionPath: String,
        scratch: URL
    ) throws -> Outcome {
        let fileManager = FileManager.default
        let agentDir = scratch.appendingPathComponent("pi-agent-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = scratch.appendingPathComponent("stdout-\(UUID().uuidString).log")
        let stderrURL = scratch.appendingPathComponent("stderr-\(UUID().uuidString).log")
        try fileManager.createDirectory(at: agentDir, withIntermediateDirectories: true)
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.prefixArgs + ["--mode", "rpc", "-ne", "-e", extensionPath]
        process.currentDirectoryURL = scratch
        // Closed stdin is what makes this terminate on its own: pi finishes
        // startup (having loaded the extension), reads EOF and exits.
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        // Files, not pipes: a pipe nobody drains deadlocks a chatty child.
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        var environment = ProcessInfo.processInfo.environment
        environment["CONTINUUM_ARRAY_MANAGED_AGENT"] = "1"
        environment["PI_CODING_AGENT_DIR"] = agentDir.path
        environment.removeValue(forKey: "PI_EXTENSIONS")
        process.environment = environment

        try process.run()
        let deadline = Date().addingTimeInterval(perFileTimeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < graceDeadline { usleep(50_000) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return Outcome(status: process.terminationStatus, timedOut: timedOut, stderr: stderrText)
    }

    private static func tail(_ text: String, lines: Int = 6) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return all.suffix(lines).joined(separator: " | ")
    }

    /// Returns true when pi really parsed every bundled extension, false when
    /// the leg skipped (no pi on PATH). It throws only on a real failure, so a
    /// skip still exits 0 — but the caller never prints "passed" for one.
    @discardableResult
    static func run() throws -> Bool {
        let fileManager = FileManager.default
        let names = PiExtensionInstaller.bundledExtensionFileNames

        // The SAME accessor the runner uses (`PiAgentRunner.installedExtensionPaths`
        // calls `bundledWorkspaceToolsExtensionPath`, which is
        // `bundledExtensionURL(fileName:)`). A gate that read the source tree
        // instead would miss a resource that never reached the bundle.
        var bundled: [(name: String, path: String)] = []
        for name in names {
            guard let url = PiExtensionInstaller.bundledExtensionURL(fileName: name) else {
                throw Failure(message: "\(name) is not in the Core resource bundle — the production accessor cannot find what the runner would load with -e")
            }
            bundled.append((name, url.path))
        }
        // The workspace-tools accessor the runner actually calls must agree with
        // the enumeration, so this leg can never drift off the shipped path.
        guard let runnerPath = PiExtensionInstaller.bundledWorkspaceToolsExtensionPath() else {
            throw Failure(message: "bundledWorkspaceToolsExtensionPath() is nil — the runner would ship pi no workspace tools at all")
        }
        guard bundled.contains(where: { $0.path == runnerPath }) else {
            throw Failure(message: "the runner's extension path \(runnerPath) is not among the enumerated bundle files \(bundled.map(\.path))")
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let command = PiAgentRunner.resolvedCommand(
            pathDirs: ToolDetector.splitPath(path),
            extraDirs: [],
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) })
        // `resolvedCommand` falls back to `/usr/bin/env pi` when it finds no
        // absolute pi; for a GATE that fallback is "not installed".
        guard command.prefixArgs.isEmpty else {
            print("SKIP: --pi-extension-load-check found no `pi` on PATH, so NOTHING was parsed.")
            print("SKIP: unverified bundled pi extensions: \(names.joined(separator: ", "))")
            print("SKIP: install pi (npm i -g @earendil-works/pi-coding-agent) and re-run this leg to witness them.")
            return false
        }

        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-pi-extension-load-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        print("pi: \(command.executable)")
        for entry in bundled {
            let outcome = try loadExtension(command: command, extensionPath: entry.path, scratch: scratch)
            if outcome.timedOut {
                throw Failure(message: "pi did not finish loading \(entry.name) within \(Int(perFileTimeout))s — killed. stderr: \(tail(outcome.stderr))")
            }
            if outcome.status != 0 {
                throw Failure(message: "pi REJECTED the bundled extension \(entry.name) (exit \(outcome.status)). stderr: \(tail(outcome.stderr))")
            }
            print("loaded: \(entry.name)")
        }

        // Teeth. A syntax error injected into a real bundled extension must be
        // rejected; if pi accepts it, every GREEN above is meaningless.
        guard let control = bundled.last else {
            throw Failure(message: "no bundled extensions to control against")
        }
        let brokenURL = scratch.appendingPathComponent("broken-\(control.name)")
        let original = try String(contentsOfFile: control.path, encoding: .utf8)
        try ("function ( { — a deliberate syntax error, see PiExtensionLoadChecks\n" + original)
            .write(to: brokenURL, atomically: true, encoding: .utf8)
        let controlOutcome = try loadExtension(command: command, extensionPath: brokenURL.path, scratch: scratch)
        if controlOutcome.timedOut {
            throw Failure(message: "the positive control timed out instead of being rejected — the gate proved nothing")
        }
        guard controlOutcome.status != 0 else {
            throw Failure(message: "POSITIVE CONTROL FAILED: pi accepted \(control.name) with a syntax error injected (exit 0). This pi does not report load failures, so the GREEN results above witness nothing.")
        }
        print("positive control: pi rejected a deliberately broken \(control.name) (exit \(controlOutcome.status))")
        return true
    }
}
