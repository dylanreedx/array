import AppKit
import Darwin
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2A.3-agent-supervisor.md
//
// THE AGENT IS THE ENTITY; A TILE IS ONE VIEW OF IT (locked decision, _RUNBOOK.md).
//
// What this file moves: `AppDelegate.managedAgentRunners` was `[UUID: PiAgentRunner]`
// keyed by TILE, and the runner was constructed inside the tile's own
// `onSubmitPrompt` closure. The view was therefore the de-facto owner — the
// dictionary entry existed only because a tile asked for it, and every consumer of
// the event stream was that one tile's `ingest`. `AgentSupervisor` is the
// app-lifetime owner instead: it holds the runner, persists the `AgentRecord`
// (P2A.1) through `AgentStore` (P2A.2), and MULTICASTS the event stream.
//
// The multicast is the load-bearing half, not a convenience. A single-consumer
// stream makes the consumer the owner by construction: there is nowhere for the
// events to go once it is gone, so tearing the view down has to tear the agent
// down too. With a fan-out, a tile is one subscriber among several (inventory,
// phone mirror, a second tile after P2A.5's re-attach) and closing it is just one
// `onTermination`. `events(for:)` follows `ActivityStore.subscribe()`'s
// snapshot-then-tail contract for the same reason it does: a subscriber that
// attaches late must see the history before the tail, or a re-attached tile would
// render a transcript that starts mid-turn.
//
// NOT here, deliberately:
// · `PiAgentRunner` is untouched — Phase 5 replaces it with the RPC client, and a
//   rewrite here would collide with that.
// · Nothing is restored at INIT. `restore()` (P2A.7) is an explicit call the app
//   makes at boot, before it walks the canvas, so a test can construct a supervisor
//   over a populated store and still observe the pre-restore state.
// · Attach / detach as an operation is P2A.5. This file only gets the ownership out
//   of the view so that ticket has something to move.

/// The runner seam. `PiAgentRunner`'s two entry points, named as a protocol so the
/// matrix can drive the supervisor with a scripted runner instead of Pi (no
/// network, no provider auth, no wall-clock). The production path still constructs
/// a real `PiAgentRunner` — `AgentSupervisor.piRunner(for:)` is the only place in
/// the app that constructs one, and `runAgentSupervisorChecks` asserts that by
/// reading the source.
protocol AgentRunning: AnyObject, Sendable {
    /// Blocking: runs one prompt to completion, streaming events to `onEvent` as
    /// they arrive. Called off the main thread by `send`.
    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws
    func stop()
    /// P2D.2 — the local-only `spawn_agent` side channel. Separate from `onEvent`
    /// because a `SpawnRequest` carries the call's ARGUMENTS, which may never enter
    /// `AgentRuntimeEvent` (I5); set by `send` before the prompt runs.
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void)
    /// Queue 91 P2 — local-only cwd/tool evidence, likewise separate from the
    /// Codable runtime and companion activity streams.
    func observeRuntimeObservations(
        _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void)
    /// A provider session which remains useful after `run` returns can be
    /// retained by the supervisor and rebound to the next prompt.
    var keepsSessionAliveBetweenTurns: Bool { get }
    /// Rechecked at the reuse boundary so a child that exited while idle is
    /// discarded instead of failing the user's next prompt.
    var canAcceptAnotherTurn: Bool { get }
}

extension AgentRunning {
    /// Text-only compatibility wrapper for older supervisor checks/callers.
    func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try run(prompt: AgentPrompt(prompt), onEvent: onEvent)
    }

    var keepsSessionAliveBetweenTurns: Bool { false }
    var canAcceptAnotherTurn: Bool { false }
}

/// B2.2 — a REFINEMENT, deliberately not a wider `AgentRunning`.
///
/// A session runner holds one provider process for the agent's whole life, which
/// is what makes mid-turn steering and a clean interrupt possible at all. The
/// three one-shot runners do not conform and compile untouched, keeping
/// `.sendStop(...)` as their conservative floor; the supervisor composes real
/// capabilities only when a session runner is actually bound.
///
/// **Capabilities come from the BOUND RUNNER, never from `record.harness`.** A
/// harness-name table lies for the entire migration window, when pi-one-shot and
/// pi-rpc are both live in one build — and the thing that will execute the intent
/// is the only honest source for what it can do.
protocol AgentSessionRunning: AgentRunning {
    var sessionCapabilities: PiRpcSessionCapabilities { get }
    /// Turn-boundary steering. pi documents delivery as AFTER the current
    /// assistant turn finishes its tool calls and before the next LLM call
    /// (`agent-session.js:986`) — it is not mid-tool interruption, and no comment
    /// or UI string may promise that it is.
    func steer(_ text: String) throws
    /// Clean, awaited, no signal — and therefore no lost session file.
    func interrupt() throws
    @discardableResult
    func command(_ type: String, payload: [String: Any]) throws -> [String: Any]
}

extension PiAgentRunner: AgentRunning {}
extension PiRpcAgentRunner: AgentRunning {}
extension PiRpcAgentRunner: AgentSessionRunning {}
extension PiRpcAgentRunner {
    var keepsSessionAliveBetweenTurns: Bool { true }
    var canAcceptAnotherTurn: Bool { isSessionRunning }
}
extension ClaudeAgentRunner: AgentRunning {}
extension CodexAgentRunner: AgentRunning {}

private final class RefusingAgentRunner: AgentRunning,  Sendable {
    struct Refusal: Error, CustomStringConvertible { let description: String }
    private let reason: String
    init(reason: String) { self.reason = reason }
    func run(prompt: AgentPrompt, onEvent:   (AgentRuntimeEvent) -> Void) throws { throw Refusal(description: reason) }
    func stop() {}
    func observeSpawnRequests(_ handler:   (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(_ handler:   (AgentRuntimeObservation) -> Void) {}
}

// MARK: - P4.5 generated-name one-shot

/// The capability needed by the explicit generated-name action. It is resolved
/// without launching the provider: the login shell supplies the executable PATH,
/// and Pi's provider config supplies the authentication fact. A missing capability
/// is therefore a hidden affordance, not a dead menu item.
struct AgentNameGenerationCapability: Equatable, Sendable {
    static let cheapModel = "openai-codex/gpt-5.4-mini"

    let executable: String
    let configDirectory: URL
    let loginShellPath: String
    let model: String

    init(
        executable: String,
        configDirectory: URL,
        loginShellPath: String,
        model: String = AgentNameGenerationCapability.cheapModel
    ) {
        self.executable = executable
        self.configDirectory = configDirectory
        self.loginShellPath = loginShellPath
        self.model = model
    }

    /// The login-shell PATH resolver is kept pure at the path-selection seam so
    /// deterministic checks can use a fake executable without invoking Pi.
    static func resolvedExecutable(
        loginShellPath: String,
        fileExists: (String) -> Bool
    ) -> String? {
        for component in loginShellPath.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = String(component)
            let candidate = directory.hasSuffix("/")
                ? directory + "pi"
                : directory + "/pi"
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    /// Resolve the live capability. This reads auth/config state only; notably it
    /// never runs `pi --list-models` or another provider probe, so an absent
    /// capability cannot spawn a process as a side effect of hiding the action.
    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> AgentNameGenerationCapability? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let configuredDirectory = environment["PI_CODING_AGENT_DIR"]
            ?? URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".pi/agent", isDirectory: true).path
        let configDirectory = URL(fileURLWithPath: configuredDirectory, isDirectory: true)
        guard hasAuthentication(
            in: configDirectory,
            now: now
        ) else { return nil }
        guard let loginShellPath = loginShellPath(environment: environment),
              let executable = resolvedExecutable(
                loginShellPath: loginShellPath,
                fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
              ) else {
            return nil
        }
        return AgentNameGenerationCapability(
            executable: executable,
            configDirectory: configDirectory,
            loginShellPath: loginShellPath
        )
    }

    /// Pure auth/config gate used by the live resolver and the deterministic
    /// checks. A refresh credential is sufficient for Pi to refresh an expired
    /// access token; an expired access-only credential is not.
    static func hasAuthentication(
        in configDirectory: URL,
        now: Date,
        data: Data? = nil
    ) -> Bool {
        let authData = data ?? (try? Data(contentsOf: configDirectory.appendingPathComponent("auth.json")))
        guard let authData,
              let object = try? JSONSerialization.jsonObject(with: authData),
              let providers = object as? [String: Any],
              let provider = providers["openai-codex"] as? [String: Any] else {
            return false
        }
        let access = (provider["access"] as? String)?.isEmpty == false
        let refresh = (provider["refresh"] as? String)?.isEmpty == false
        guard access || refresh else { return false }
        if refresh { return true }
        guard let expires = provider["expires"] as? NSNumber else { return true }
        return expires.doubleValue > now.timeIntervalSince1970 * 1000
    }

    /// Ask the user's login shell for PATH. The actual process work is owned by
    /// `AgentNameOneShot` and always runs off-main with a timeout and bounded pipe
    /// readers. Keeping this call synchronous is safe only for the resolver task;
    /// no menu/query path calls `live()` directly.
    private static func loginShellPath(environment: [String: String]) -> String? {
        AgentNameOneShot.loginShellPath(environment: environment)
    }
}


/// The menu's capability query is deliberately a snapshot. It never resolves a
/// shell, reads auth, or launches a process. Resolution is started by a view and
/// completed on the main actor only after the bounded utility task finishes.
private final class AgentNameGenerationCapabilityCache: @unchecked Sendable {
    enum State: Sendable {
        case unknown
        case unavailable
        case available(AgentNameGenerationCapability)

        var capability: AgentNameGenerationCapability? {
            if case let .available(capability) = self { return capability }
            return nil
        }

        var isAvailable: Bool { capability != nil }
    }

    static let shared = AgentNameGenerationCapabilityCache()

    private let lock = NSLock()
    private var state: State = .unknown
    private var inFlight: Task<AgentNameGenerationCapability?, Never>?

    func snapshot() -> State { lock.withLock { state } }

    /// Starts at most one detached resolution. Returning an already-completed
    /// task for a cached result keeps callers uniformly asynchronous without
    /// making the main actor wait for even a lock or a shell startup.
    func startResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> Task<AgentNameGenerationCapability?, Never> {
        lock.withLock {
            switch state {
            case .available, .unavailable:
                let cached = state.capability
                return Task.detached { cached }
            case .unknown:
                break
            }
            if let inFlight { return inFlight }
            let task = Task.detached(priority: .utility) { [weak self] in
                let capability = AgentNameGenerationCapability.live(environment: environment, now: now)
                self?.finish(capability)
                return capability
            }
            inFlight = task
            return task
        }
    }

    /// Test-only reset. Production code never needs to forget a resolved
    /// capability; the next app launch creates a fresh cache.
    func resetForQA() {
        lock.withLock {
            state = .unknown
            inFlight?.cancel()
            inFlight = nil
        }
    }

    private func finish(_ capability: AgentNameGenerationCapability?) {
        lock.withLock {
            state = capability.map(State.available) ?? .unavailable
            inFlight = nil
        }
    }
}

private enum AgentNameOneShotError: Error, CustomStringConvertible, Sendable {
    case launchFailed
    case processGroupUnavailable
    case failed(Int32)
    case timedOut
    case inputFailed

    var description: String {
        switch self {
        case .launchFailed: return "launch failed"
        case .processGroupUnavailable: return "process group unavailable"
        case .failed(let code): return "provider exited with code \(code)"
        case .timedOut: return "timed out"
        case .inputFailed: return "prompt input failed"
        }
    }
}

/// A provider-independent, print-mode Pi invocation. The source prompt is
/// written to stdin only; it is never an argv element, a session, or an event.
// Internal (not private): ToolEnvironment reuses the bounded login-shell
// PATH probe for the app-wide PATH upgrade (go-live Phase 4).
enum AgentNameOneShot {
    static let timeout: TimeInterval = 8
    static let processGroupGrace: TimeInterval = 0.15
    static let maximumPromptLength = 8_000
    static let systemPrompt = "Return exactly one JSON object with exactly one string field named name. The name value is short and human-readable, 1 to 8 words. Output one line only. No explanation, extra fields, markdown, punctuation, identifiers, model ids, roles, or UUIDs."

    static func arguments(model: String) -> [String] {
        [
            "--no-session",
            "--print",
            "--mode", "text",
            "--model", model,
            "--thinking", "low",
            "--no-tools",
            "--no-extensions",
            "--no-skills",
            "--no-context-files",
            "--no-approve",
            "--system-prompt", systemPrompt,
        ]
    }

    /// Accept only the exact one-field JSON shape requested by `systemPrompt`.
    /// Provider chatter is not a recoverable prefix: a warning, label, fence,
    /// extra field, plain prose line, or multi-line explanation fails closed
    /// before the existing AgentName policy can turn it into a title.
    /// Identifiers are rejected with the same metadata-aware rule as P4.3.
    static func candidate(
        from stdout: String,
        model: String?,
        role: String?,
        id: UUID?
    ) -> String? {
        let nonEmptyLines = stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard nonEmptyLines.count == 1 else { return nil }
        let line = nonEmptyLines[0]
        guard !line.hasPrefix("```") && !line.contains("```") && line != "---",
              !line.hasPrefix("- ") && !line.hasPrefix("* "),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1,
              let rawName = object["name"] as? String else {
            return nil
        }
        let name = stripWrappingQuotes(from: rawName)
        guard !name.isEmpty,
              !name.contains(where: { ":;!?{}[]()<>#*`".contains($0) }) else {
            return nil
        }
        let lower = name.lowercased()
        let words = lower.split(whereSeparator: { $0.isWhitespace })
        let providerNoise = [
            "warning", "fallback", "error", "progress", "assistant", "role", "user",
            "system", "model", "title", "name", "generated", "output", "result",
            "thinking", "note", "here", "sure", "okay", "suggest", "proposed"
        ]
        guard words.count <= 8,
              !words.contains(where: { providerNoise.contains(String($0)) }),
              !AgentName.isIdentifier(name, model: model, role: role, id: id),
              AgentName.normalizedLabel(name) != nil else {
            return nil
        }
        return AgentName.normalizedLabel(name)
    }

    private static func stripWrappingQuotes(from raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("`", "`")]
        var changed = true
        while changed, line.count >= 2 {
            changed = false
            for (opening, closing) in pairs where line.hasPrefix(opening) && line.hasSuffix(closing) {
                line = String(line.dropFirst(opening.count).dropLast(closing.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return line
    }

    private struct BoundedProcessResult: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Resolve the login-shell PATH with the same bounded process machinery as
    /// the provider. A noisy rc file is drained into a capped buffer while the
    /// leader runs, and a descendant that keeps either pipe open is killed before
    /// this method returns.
    static func loginShellPath(environment: [String: String]) -> String? {
        let shell = environment["SHELL"].flatMap { path in
            FileManager.default.isExecutableFile(atPath: path) ? path : nil
        } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let command = "printf '\\n__CONTINUUM_LOGIN_PATH__%s\\n' \"$PATH\""
        do {
            let result = try runProcess(
                executable: shell,
                arguments: [URL(fileURLWithPath: shell).lastPathComponent, "-ilc", command],
                input: Data(),
                environment: environment,
                timeout: 1.0)
            guard processExitCode(result.status) == 0,
                  let marker = result.stdout.range(of: "__CONTINUUM_LOGIN_PATH__") else {
                return nil
            }
            let path = result.stdout[marker.upperBound...]
                .split(whereSeparator: \.isNewline)
                .first.map(String.init) ?? ""
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    static func run(
        capability: AgentNameGenerationCapability,
        prompt: String,
        cwd: URL,
        timeout: TimeInterval = AgentNameOneShot.timeout,
        environmentOverrides: [String: String] = [:],
        configDirectoryOverride: URL? = nil,
        inputWriteDelay: TimeInterval = 0
    ) throws -> String {
        let configDirectory = try temporaryConfigDirectory(
            for: capability,
            at: configDirectoryOverride)
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = capability.loginShellPath
        environment["PI_CODING_AGENT_DIR"] = configDirectory.path
        environment.merge(environmentOverrides) { _, override in override }
        // HOME is deliberately inherited untouched in production. The optional
        // override exists only for the controlled fake-Pi fixture, which proves
        // that --no-session creates no session/transcript artifact in a known home.

        // Foundation's Process does not expose a pre-exec hook, and attempting
        // setpgid(pid, pid) after Process.run() races the child's exec on macOS
        // (EACCES). posix_spawn's SETPGROUP attribute creates the group before
        // /bin/sh starts, so every descendant inherits it and timeout cleanup can
        // kill the group without risking the app's own group.
        let script = "cd -- \(shellQuote(cwd.path)) || exit 126; exec \"$@\""
        let rawArguments = ["sh", "-c", script, "continuum-name-one-shot", capability.executable]
            + arguments(model: capability.model)
        let result = try runProcess(
            executable: "/bin/sh",
            arguments: rawArguments,
            input: Data(prompt.utf8),
            environment: environment,
            timeout: timeout,
            inputWriteDelay: inputWriteDelay)
        guard processExitCode(result.status) == 0 else {
            throw AgentNameOneShotError.failed(processExitCode(result.status))
        }
        return result.stdout
    }

    /// All blocking process and pipe work lives here. In particular, this never
    /// calls `waitUntilExit` or `readDataToEndOfFile`: both would wait forever
    /// when a normally-exited leader leaves a descendant holding a pipe.
    private static func runProcess(
        executable: String,
        arguments: [String],
        input: Data,
        environment: [String: String],
        timeout: TimeInterval,
        inputWriteDelay: TimeInterval = 0,
        stdoutLimit: Int = 64 * 1024,
        stderrLimit: Int = 16 * 1024
    ) throws -> BoundedProcessResult {
        // M1.8: the spawn and the SIGTERM -> grace -> SIGKILL escalation now come
        // from `ProcessGroupChild` in Core. This path owned both and was correct,
        // but the runners live in Core and cannot import the app -- so the
        // machinery moved down and this became a client of it. One escalation
        // routine, two graces, rather than two routines that drift.
        //
        // What stays here is genuinely one-shot-specific and NOT duplicated logic:
        // the hard timeout, the bounded readers, and the deliberate refusal to
        // block. A normally-exited leader can leave a descendant holding stdout,
        // so `wait()` would wait forever; every reap below is the WNOHANG form.
        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.spawn(
                executable: executable,
                // `runProcess`'s contract is that `arguments` INCLUDES argv[0] --
                // both callers pass one deliberately (a bare `sh`, and a login
                // shell's own basename), and argv[0] is not cosmetic for a shell.
                arguments: Array(arguments.dropFirst()),
                environment: environment,
                currentDirectory: nil,
                standardInput: .pipe,
                argv0: arguments.first)
        } catch {
            throw AgentNameOneShotError.launchFailed
        }
        guard let inputWrite = child.standardInput else {
            child.terminateGroup(graceSeconds: processGroupGrace)
            throw AgentNameOneShotError.launchFailed
        }

        let stdoutBox = LockedData(limit: stdoutLimit)
        let stderrBox = LockedData(limit: stderrLimit)
        let stdoutReader = BoundedPipeReader(handle: child.standardOutput, box: stdoutBox)
        let stderrReader = BoundedPipeReader(handle: child.standardError, box: stderrBox)

        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        do {
            if inputWriteDelay > 0 {
                Thread.sleep(forTimeInterval: min(inputWriteDelay, max(0.01, timeout)))
            }
            try writeInput(input, to: inputWrite.fileDescriptor, until: deadline)
            try inputWrite.close()
        } catch {
            try? inputWrite.close()
            child.terminateGroup(graceSeconds: processGroupGrace)
            stdoutReader.finish(timeout: processGroupGrace)
            stderrReader.finish(timeout: processGroupGrace)
            throw AgentNameOneShotError.inputFailed
        }

        var status = child.pollExitRaw()
        while status == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            status = child.pollExitRaw()
        }
        guard let status else {
            child.terminateGroup(graceSeconds: processGroupGrace)
            stdoutReader.finish(timeout: processGroupGrace)
            stderrReader.finish(timeout: processGroupGrace)
            throw AgentNameOneShotError.timedOut
        }

        // Intentional even after a successful leader exit. The leader can have
        // forked a child that still owns stdout/stderr; killing the whole group
        // before joining the bounded readers releases the slot.
        child.terminateGroup(graceSeconds: processGroupGrace)
        stdoutReader.finish(timeout: processGroupGrace)
        stderrReader.finish(timeout: processGroupGrace)
        return BoundedProcessResult(
            stdout: String(decoding: stdoutBox.data, as: UTF8.self),
            stderr: String(decoding: stderrBox.data, as: UTF8.self),
            status: child.reapedRawStatus ?? status)
    }

    private static func writeInput(
        _ data: Data,
        to descriptor: Int32,
        until deadline: Date
    ) throws {
        guard !data.isEmpty else { return }
        setNonBlocking(descriptor)
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard Date() < deadline else { throw AgentNameOneShotError.inputFailed }
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                throw AgentNameOneShotError.inputFailed
            }
        }
    }

    private static func spawnInOwnProcessGroup(
        executable: String,
        arguments: [String],
        environment: [String: String],
        input: Pipe,
        stdout: Pipe,
        stderr: Pipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw AgentNameOneShotError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let inputRead = input.fileHandleForReading.fileDescriptor
        let inputWrite = input.fileHandleForWriting.fileDescriptor
        let stdoutRead = stdout.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdout.fileHandleForWriting.fileDescriptor
        let stderrRead = stderr.fileHandleForReading.fileDescriptor
        let stderrWrite = stderr.fileHandleForWriting.fileDescriptor
        let addDup: (Int32, Int32) throws -> Void = { source, destination in
            guard posix_spawn_file_actions_adddup2(&fileActions, source, destination) == 0 else {
                throw AgentNameOneShotError.launchFailed
            }
        }
        let addClose: (Int32) throws -> Void = { descriptor in
            guard posix_spawn_file_actions_addclose(&fileActions, descriptor) == 0 else {
                throw AgentNameOneShotError.launchFailed
            }
        }
        try addDup(inputRead, STDIN_FILENO)
        try addDup(stdoutWrite, STDOUT_FILENO)
        try addDup(stderrWrite, STDERR_FILENO)
        for (descriptor, duplicate) in [
            (inputRead, Int32(STDIN_FILENO)),
            (inputWrite, Int32(STDIN_FILENO)),
            (stdoutRead, Int32(STDOUT_FILENO)),
            (stdoutWrite, Int32(STDOUT_FILENO)),
            (stderrRead, Int32(STDERR_FILENO)),
            (stderrWrite, Int32(STDERR_FILENO)),
        ] where descriptor != duplicate {
            try addClose(descriptor)
        }

        var spawnAttributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&spawnAttributes) == 0 else {
            throw AgentNameOneShotError.processGroupUnavailable
        }
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        guard posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&spawnAttributes, 0) == 0 else {
            throw AgentNameOneShotError.processGroupUnavailable
        }

        var argv = try arguments.map { value -> UnsafeMutablePointer<CChar>? in
            guard let pointer = strdup(value) else { throw AgentNameOneShotError.launchFailed }
            return pointer
        }
        argv.append(nil)
        defer { argv.dropLast().forEach { free($0) } }
        var envp = try environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .map { value -> UnsafeMutablePointer<CChar>? in
                guard let pointer = strdup(value) else { throw AgentNameOneShotError.launchFailed }
                return pointer
            }
        envp.append(nil)
        defer { envp.dropLast().forEach { free($0) } }

        var pid: pid_t = 0
        let result = executable.withCString { path in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envpBuffer in
                    posix_spawn(
                        &pid,
                        path,
                        &fileActions,
                        &spawnAttributes,
                        UnsafePointer(argvBuffer.baseAddress!),
                        UnsafePointer(envpBuffer.baseAddress!))
                }
            }
        }
        guard result == 0 else { throw AgentNameOneShotError.launchFailed }
        // The parent must close its copies of the child's pipe ends, or EOF on
        // stdout/stderr would wait for the parent's own descriptors forever.
        try? input.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        return pid
    }

    /// Stop the entire process group after every leader outcome. The first grace
    /// period lets a cooperative shell close its descendants; SIGKILL is the
    /// bounded backstop for a child that ignores SIGTERM. `waitpid` is always the
    /// WNOHANG form, so input failure cannot turn cleanup into a second hang.
    private static func cleanupProcessGroup(
        _ pid: pid_t,
        knownStatus: Int32?
    ) -> Int32? {
        var status = knownStatus
        if processGroupExists(pid) {
            killProcessGroup(pid, signal: SIGTERM)
        }
        let termDeadline = Date().addingTimeInterval(processGroupGrace)
        while Date() < termDeadline {
            if status == nil { status = waitForProcess(pid, noHang: true) }
            if !processGroupExists(pid) {
                if status == nil { status = waitForProcess(pid, noHang: true) }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if processGroupExists(pid) {
            killProcessGroup(pid, signal: SIGKILL)
        }
        let reapDeadline = Date().addingTimeInterval(processGroupGrace)
        while status == nil && Date() < reapDeadline {
            status = waitForProcess(pid, noHang: true)
            if status == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        // Do not wait again after the bound. The pipe readers are closed by their
        // own bounded finish path, so a broken provider cannot retain this slot.
        return status
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        // A provider is allowed to close stdin immediately. Do not let that
        // ordinary input-failure witness deliver SIGPIPE to the app process.
        #if os(macOS)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    private final class BoundedPipeReader: @unchecked Sendable {
        private let handle: FileHandle
        private let descriptor: Int32
        private let box: LockedData
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stopped = false
        private var closed = false

        init(handle: FileHandle, box: LockedData) {
            self.handle = handle
            self.descriptor = handle.fileDescriptor
            self.box = box
            setNonBlocking(descriptor)
            DispatchQueue.global(qos: .utility).async { [self] in readLoop() }
        }

        func finish(timeout: TimeInterval) {
            let result = done.wait(timeout: .now() + max(0, timeout))
            if result == .timedOut {
                stopAndClose()
                _ = done.wait(timeout: .now() + 0.05)
            } else {
                stopAndClose()
            }
        }

        func stopAndClose() {
            let shouldClose = lock.withLock {
                stopped = true
                guard !closed else { return false }
                closed = true
                return true
            }
            if shouldClose { try? handle.close() }
        }

        private func readLoop() {
            defer { done.signal() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !isStopped {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
                }
                if count > 0 {
                    box.append(Data(buffer.prefix(count)))
                    continue
                }
                if count == 0 { return }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    return
                }
                var descriptorSet = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN),
                    revents: 0)
                let pollResult = Darwin.poll(&descriptorSet, 1, 50)
                if pollResult < 0 && errno != EINTR { return }
            }
        }

        private var isStopped: Bool { lock.withLock { stopped } }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\\''") + "'"
    }

    private static func waitForProcess(_ pid: pid_t, noHang: Bool = false) -> Int32? {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, noHang ? WNOHANG : 0)
        if result == pid { return status }
        if result == -1 && errno != EINTR && errno != ECHILD { return status }
        return nil
    }

    private static func processExitCode(_ status: Int32) -> Int32 {
        // Darwin exposes the wait status as an opaque C macro family that is
        // unavailable to Swift. These are the POSIX wait(2) bit fields: a zero
        // low byte means normal exit; otherwise the low seven bits are a signal.
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return status
    }

    private static func temporaryConfigDirectory(
        for capability: AgentNameGenerationCapability,
        at override: URL? = nil
    ) throws -> URL {
        let directory = override ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-name-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let settings = #"{"retry":{"maxRetries":0,"baseDelayMs":0}}"#
        try settings.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let auth = capability.configDirectory.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: auth.path) {
            // Copy rather than symlink: Pi may refresh OAuth state during a run,
            // but a best-effort name action must never mutate the user's durable
            // credential file as a side effect.
            let destination = directory.appendingPathComponent("auth.json")
            try Data(contentsOf: auth).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path)
        }
        for name in ["models.json", "models-store.json"] {
            let source = capability.configDirectory.appendingPathComponent(name)
            let destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path),
               let data = try? Data(contentsOf: source) {
                try? data.write(to: destination, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path)
            }
        }
        return directory
    }

    private static func killProcessGroup(_ pid: Int32, signal: Int32) {
        guard pid > 1 else { return }
        if Darwin.kill(-pid, signal) != 0, errno != ESRCH {
            // Best effort: the caller is already on the failure/timeout path.
        }
    }

    private static func processGroupExists(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return Darwin.kill(-pid, 0) == 0 || errno == EPERM
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var storage = Data()

        init(limit: Int) { self.limit = max(0, limit) }

        func append(_ data: Data) {
            lock.withLock {
                guard storage.count < limit else { return }
                storage.append(data.prefix(limit - storage.count))
            }
        }
        var data: Data { lock.withLock { storage } }
    }
}

/// One-way latch: did this run deliver a `.turnCompleted`? Set and read on the
/// main queue in production — the lock exists so the compiler can prove the
/// capture by the runner's `@Sendable` event closure is safe.
private final class TerminalDeliveryLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@MainActor
final class AgentSupervisor {
    private struct RunnerGenerationToken: Equatable, Sendable {
        let rawValue = UUID()
    }

    /// How much of an agent's event history a late subscriber replays. Capped
    /// because `contentDelta` arrives per token, so an uncapped history is an
    /// uncapped buffer for the lifetime of the app. A re-attached tile therefore
    /// shows the recent transcript, not the whole one; the durable transcript is
    /// not this buffer's job.
    static let replayCap = 500

    private let store: AgentStore
    private let makeRunner: (AgentRunnerLaunch) -> AgentRunning
    private let warn: (String) -> Void
    /// The production writer is `AgentStore.upsert`. The optional seam exists only
    /// for deterministic checks that need to model an AtomicWriter throw before or
    /// after rename; every real write still goes through AgentStore unchanged.
    private let upsertRecord: (AgentRecord) throws -> Void
    /// P2C.1's `git worktree` wrapper, used only by the isolated `spawn`. Not
    /// injectable: the checks exercise the failure path with a real failure (a `cwd`
    /// that is not a repository), so a fake would test less than the real thing.
    private let worktrees = WorktreeManager()
    /// P2C.4: the branch each agent's working directory is on. Cached because the
    /// tile header that renders it re-lays out on every streamed token, and a
    /// `git rev-parse` per render is a process launch per token.
    private let checkedOutBranches = CheckedOutBranchCache()
    /// A provider seam is retained for deterministic checks. Production uses the
    /// process-free cache snapshot; it never invokes a shell from this actor.
    private let nameGenerationCapabilityProvider: (@Sendable () -> AgentNameGenerationCapability?)?
    private let nameGenerationTimeout: TimeInterval
    private let attachmentStore: AgentComposerAttachmentStore
    private var runtimeObservationObservers: [AgentID: [UUID: (AgentRuntimeObservation) -> Void]] = [:]
    /// Live views of an agent's identity. Names are record state rather than
    /// runtime events, so the transcript stream cannot carry first-prompt,
    /// manual, or generated renames to an already-attached tile.
    private var displayNameObservers: [AgentID: [UUID: (String) -> Void]] = [:]
    /// App-lifetime recovery owner. This is deliberately independent of tile
    /// subscriptions so launch failures and provider rejection restore drafts
    /// even when no tile remains bound.
    private let submissionRecoveryStore: AgentComposerDraftStore?
    /// C4: persistence must not require a tile. `nil` in every check that does
    /// not pass one (the overwhelming majority), so building/ingesting the
    /// per-agent projection below is skipped entirely rather than adding
    /// per-event cost to hundreds of unrelated fixtures.
    private let transcriptStore: AgentTranscriptStore?
    /// Applies only to child turns whose runner Array creates. `nil` means
    /// unlimited. Provider-owned observed children never consult this value.
    private let maximumActiveManagedChildren: () -> Int?

    /// The records this supervisor owns, in memory. `AgentStore` is the durable
    /// copy; this is the live one.
    private(set) var records: [AgentID: AgentRecord] = [:]
    /// The runner for the prompt currently in flight, if any.
    private var runners: [AgentID: AgentRunning] = [:]
    /// The latest runner generation to own each agent. Unlike `runners`, this is
    /// deliberately retained after the live slot clears: it is the tombstone that
    /// prevents an older runner from becoming authoritative again merely because
    /// the replacement has also finished.
    private var runnerGenerationTokens: [AgentID: RunnerGenerationToken] = [:]
    /// Provider sessions which are alive but have no turn in flight. Keeping
    /// these separate preserves `runners` as the truthful busy/Stop capability
    /// while avoiding a fresh Pi/Node/resource-loader startup on every message.
    private var idleSessionRunners: [AgentID: AgentRunning] = [:]
    private var subscribers: [AgentID: [UUID: AsyncStream<AgentRuntimeEvent>.Continuation]] = [:]
    private var history: [AgentID: [AgentRuntimeEvent]] = [:]
    /// C4: the semantic document, built here so it exists whether or not any
    /// tile is attached — a tile-less child (the common case at fan-out) used
    /// to persist nothing, because the only `saveSnapshot` call site lived
    /// inside the tile's own event hook. Uninjected (no `transcriptStore`)
    /// means this stays empty; a check that never passes a store pays nothing.
    private var transcriptProjections: [AgentID: ManagedAgentTranscriptModel] = [:]
    private var transcriptPersistenceTasks: [AgentID: Task<Void, Never>] = [:]
    /// Queue 91 P2 host-local projection. Never persisted or published: it carries
    /// concrete checkout/current/tool-target URLs that are outside I5's wire model.
    private var locationProjectors: [AgentID: AgentLocationProjector] = [:]
    /// Prompt-derived naming context stays in memory only. It is deliberately not
    /// an AgentRecord field and never reaches AgentInventory or the companion.
    private var firstPromptByAgent: [AgentID: String] = [:]
    /// Read-watermark persistence is deliberately less frequent than the visual
    /// focus path. An unread-clearing visit is the exception: delaying that write
    /// would let a relaunch resurrect the mark the person just cleared.
    private var lastVisitedPersistAt: [AgentID: Date] = [:]
    private static let lastVisitedPersistThrottle: TimeInterval = 10
    private var activeNameGenerations = 0
    private var nameGenerationTasks: [AgentID: Task<Void, Never>] = [:]
    private var nameGenerationRequestIDs: [AgentID: UUID] = [:]
    /// Recovery operations are serialized per agent. Completion and teardown
    /// events can arrive back-to-back; ordering them prevents a late restore from
    /// racing a successful confirmation and makes replay/rebind idempotent.
    private var submissionRecoveryTasks: [AgentID: Task<Void, Never>] = [:]

    // MARK: - B4 follow-up queue
    //
    /// Mirrors `AgentComposerDraftStore`'s durable per-agent queue for
    /// synchronous UI reads (pending chips). The store is the source of truth;
    /// this cache is refreshed after every mutation this supervisor performs
    /// and hydrated lazily on first read for an agent restored across launch.
    private var queuedMessagesCache: [AgentID: [AgentComposerQueuedMessage]] = [:]
    /// Queue mutations against the durable store are serialized per agent, the
    /// same reason `submissionRecoveryTasks` is: back-to-back UI actions and a
    /// `turnCompleted` drain must not race each other's read-modify-write.
    private var queueOpTasks: [AgentID: Task<Void, Never>] = [:]
    /// Set on `.interrupted`. A user who interrupted wants to look first, so
    /// the held queue is not auto-drained into a turn they did not ask for.
    /// Cleared by the next explicit `.send`/`.sendPrompt` or `resumeQueue`.
    private var pausedQueues: Set<AgentID> = []
    /// The outcome of the turn that just freed a runner slot, read by
    /// `clearRunner` — the one moment the slot is actually free to accept the
    /// next send. Set in `deliver`'s `.turnCompleted` handling, same as the
    /// submission-recovery branch beside it.
    private var pendingQueueOutcome: [AgentID: TurnOutcome] = [:]

    /// Provider facts used by the v2 tile. Deliberately separate from `runners`:
    /// a provider process may remain alive while its turn is ready, and that must
    /// never paint Working. `runners` is consulted only when deciding whether the
    /// current send/stop transport can accept an action.
    /// A prompt reaches the runner only after the attachment store has validated
    /// every reference for this exact agent. The unchecked AgentPrompt remains a
    /// public model for transcripts/providers, but it is never the internal send
    /// capability for an image-bearing transport.
    private struct PreparedAgentPrompt {
        let prompt: AgentPrompt
        let expectedAgentID: AgentID
    }

    private struct TurnFacts {
        var execution: AgentTurnExecutionState = .ready
        var failureMessage: String?
        var didFail = false
        var pendingRequests: [String: AgentPendingRequest] = [:]
        var requestOrder: [String] = []
        /// P3.3: when the turn now in flight started. THE anchor for every elapsed
        /// reading, and the fact the supervisor was not keeping — without it the
        /// sidebar measured from the event ring, whose oldest working event for a
        /// restored agent is a synthetic draft stamped at the SPAWN instant (the
        /// 158-hour reading). Non-nil exactly while `execution == .working`.
        var turnStartedAt: Date?
        /// When the prompt was accepted here, before any provider event.
        ///
        /// The spawn window (`submittedAt` set, `turnStartedAt` still nil) is the
        /// dead-air interval nothing in this app used to record: `turnStartedAt` is
        /// stamped from the provider's `.turnStarted`, so the process spawn, session
        /// resume and CLI cold start fell in a gap. Cleared by the same transitions
        /// that clear `turnStartedAt`.
        var submittedAt: Date?
    }
    private var turnFacts: [AgentID: TurnFacts] = [:]
    /// Latest provider-reported context-window telemetry per agent. The replay
    /// buffer cannot be trusted to still contain the (rare) telemetry event
    /// after a streaming turn floods it, so a tile that attaches later seeds
    /// from this instead (`contextWindowSnapshot(for:)`).
    private var contextWindowSnapshots: [AgentID: AgentContextWindowSnapshot] = [:]
    /// Restore-time Codex rollout lookup. Injected in checks so repair is
    /// deterministic and never depends on a developer's real ~/.codex tree.
    private let codexRestoredContextSnapshot: @Sendable (AgentRecord) -> AgentContextWindowSnapshot?

    init(
        store: AgentStore,
        makeRunner: @escaping (AgentRunnerLaunch) -> AgentRunning = AgentSupervisor.productionRunner,
        warn: @escaping (String) -> Void = { fputs($0 + "\n", stderr) },
        upsertRecord: ((AgentRecord) throws -> Void)? = nil,
        nameGenerationCapabilityProvider: (@Sendable () -> AgentNameGenerationCapability?)? = nil,
        nameGenerationTimeout: TimeInterval = AgentNameOneShot.timeout,
        attachmentStore: AgentComposerAttachmentStore? = nil,
        submissionRecoveryStore: AgentComposerDraftStore? = nil,
        codexRestoredContextSnapshot: (@Sendable (AgentRecord) -> AgentContextWindowSnapshot?)? = nil,
        transcriptStore: AgentTranscriptStore? = nil,
        maximumActiveManagedChildren: @escaping () -> Int? = {
            AgentSpawnLimitConfig.maximumActiveChildren()
        }
    ) {
        self.store = store
        self.makeRunner = makeRunner
        self.warn = warn
        self.upsertRecord = upsertRecord ?? { record in try store.upsert(record) }
        self.nameGenerationCapabilityProvider = nameGenerationCapabilityProvider
        self.nameGenerationTimeout = nameGenerationTimeout
        self.attachmentStore = attachmentStore ?? AgentComposerAttachmentStore(
            applicationSupportDirectory: store.layout.applicationSupportDirectory
        )
        self.submissionRecoveryStore = submissionRecoveryStore
        self.transcriptStore = transcriptStore
        self.maximumActiveManagedChildren = maximumActiveManagedChildren
        self.codexRestoredContextSnapshot = codexRestoredContextSnapshot ?? { record in
            guard let threadId = record.codexThreadId else { return nil }
            return CodexRolloutTelemetry.latestSnapshot(threadId: threadId, freshness: .stale)
        }
    }

    /// The explicit action's cached capability gate. This is a snapshot only:
    /// missing/unknown capability is hidden, and no login shell can run while a
    /// menu is being built.
    static var nameGenerationCapabilityAvailable: Bool {
        AgentNameGenerationCapabilityCache.shared.snapshot().isAvailable
    }

    /// Start capability resolution without making the caller wait on a shell.
    /// The returned task does its auth read and bounded login-shell probe on a
    /// utility executor; callers can await it from a UI task and repaint safely.
    static func resolveNameGenerationCapability() async -> AgentNameGenerationCapability? {
        let task = AgentNameGenerationCapabilityCache.shared.startResolution()
        return await task.value
    }

    /// The cached capability consumed by the already-gated row action. It is a
    /// process-free read; a stale/unavailable cache simply refuses the action.
    static func cachedNameGenerationCapability() -> AgentNameGenerationCapability? {
        AgentNameGenerationCapabilityCache.shared.snapshot().capability
    }

    static let maximumConcurrentNameGenerations = 2

    // MARK: - Identity

    /// The thread every event for this agent carries. Provider adapters synthesize
    /// their own thread ids (Pi uses its live session id, and a fresh one per
    /// process), so the supervisor restamps each event with the AGENT's thread
    /// before fan-out: all consumers then see one consistent stream regardless of
    /// how many runner processes produced it. A consumer that filters on its own
    /// thread — the managed-agent tile does — rebinds again on the way in, exactly
    /// as the pre-supervisor wiring did.
    nonisolated static func threadId(for id: AgentID) -> String {
        "agent-\(id.rawValue.uuidString)"
    }

    /// Stable Pi session id, so prompts CONTINUE the same conversation. Keyed on
    /// the agent, not the tile (it was `continuum-<tileId>`): the conversation
    /// belongs to the agent, and a tile is one view of it.
    nonisolated static func sessionId(for id: AgentID) -> String {
        "array-agent-\(id.rawValue.uuidString)"
    }

    /// Claude's analogue of `sessionId(for:)`: claude validates UUID format,
    /// so the agent id itself IS the conversation id. Derived, never stored —
    /// restore keeps working for claude-backed agents for the same reason it
    /// does for pi-backed ones.
    nonisolated static func claudeSessionId(for id: AgentID) -> String {
        id.rawValue.uuidString.lowercased()
    }

    /// THE production runner factory: routes each prompt to the runtime the
    /// machine actually has, under the user's chosen backend. Anthropic models
    /// prefer the user's own claude CLI and openai-codex models prefer codex when
    /// installed — subscription-correct and pi-free (see the runner headers for
    /// the compliance posture) — and everything else stays on pi. Routing policy
    /// is pure and pinned in the matrix (`AgentBackendConfig.route`); only the
    /// backend preference and the availability reads are live. The DEFAULT
    /// backend (`.pi`) preserves the shipped native-preferring behaviour exactly.
    nonisolated static func productionRunner(for launch: AgentRunnerLaunch) -> AgentRunning {
        let record = launch.record
        switch record.harness {
        case .claudeCode: return claudeRunner(for: record)
        case .codex: return codexRunner(for: record)
        case .pi: return piRunner(for: launch)
        case nil: return RefusingAgentRunner(reason: "This agent has unresolved harness ownership. Choose Claude Code, Codex, or Pi in the agent composer. Help → Environment Setup…")
        }
    }

    /// The only `PiAgentRunner(` construction in the app.
    ///
    /// RPC is the production default: it is Pi's native managed-session seam and
    /// avoids paying process, resource, extension, and session-resume startup on
    /// every prompt. The one-shot JSON runner remains as an explicit diagnostic
    /// escape hatch (`CONTINUUM_PI_TRANSPORT=oneshot`) and parity baseline.
    nonisolated static func piRunner(for launch: AgentRunnerLaunch) -> AgentRunning {
        let config = runnerConfig(for: launch.record, spawnDepth: launch.spawnDepth)
        guard piSessionTransportEnabled() else {
            return PiAgentRunner(config: config)
        }
        return PiRpcAgentRunner(config: config)
    }

    /// Default-on with an explicit developer fallback. `json` is accepted as an
    /// alias because that is Pi's one-shot output mode name.
    nonisolated static func piSessionTransportEnabled() -> Bool {
        let override = ProcessInfo.processInfo.environment["CONTINUUM_PI_TRANSPORT"]?.lowercased()
        return override != "oneshot" && override != "json"
    }

    /// The session runner bound to this agent RIGHT NOW, or nil.
    ///
    /// The one honest source for what the composer may offer. Reading it from the
    /// bound runner rather than from `record.harness` is the whole point of B2.2.
    func sessionRunner(for id: AgentID) -> AgentSessionRunning? {
        runners[id] as? AgentSessionRunning
    }

    /// The only `ClaudeAgentRunner(` construction in the app, mirroring
    /// `piRunner(for:)` so the same ownership scan can hold for both.
    nonisolated static func claudeRunner(for record: AgentRecord) -> AgentRunning {
        ClaudeAgentRunner(config: claudeRunnerConfig(for: record))
    }

    /// What a claude-backed runner is built with. The catalogue's provider
    /// prefix is stripped (claude takes bare model names), pi thinking levels
    /// pass through as `--effort` only on exact match, and the role's
    /// pi-specific `--tools` args are deliberately not forwarded — claude
    /// runs its own toolset.
    ///
    /// B7.1: `claudeSessionId(for:)` is the SEED — what a fresh agent (no
    /// adopted id yet) uses. `record.providerSessionId`, when set, is what
    /// claude itself has reported since (captured from `system/init`), which
    /// is authoritative once `--fork-session` (B7.2) has minted an id Array
    /// could not have predicted.
    nonisolated static func claudeRunnerConfig(for record: AgentRecord) -> ClaudeAgentRunner.Config {
        // B7.2 — a pending `/clear` rotation overrides the normal sessionId
        // choice entirely: this ONE launch resumes-and-forks the OLD session
        // (`record.pendingSessionForkFrom`) instead of continuing on
        // `providerSessionId`/the derived seed. `AgentSupervisor
        // .ingestRuntimeObservation` clears the pending marker the moment the
        // forked id comes back and is adopted into `providerSessionId`.
        if let forkFrom = record.pendingSessionForkFrom {
            return ClaudeAgentRunner.Config(
                model: ClaudeCLIBackend.modelArgument(forCatalogId: record.model),
                effort: ClaudeCLIBackend.effortArgument(forThinking: record.thinking),
                cwd: URL(fileURLWithPath: record.lastObservedWhere, isDirectory: true),
                sessionId: forkFrom,
                forkSession: true
            )
        }
        return ClaudeAgentRunner.Config(
            model: ClaudeCLIBackend.modelArgument(forCatalogId: record.model),
            effort: ClaudeCLIBackend.effortArgument(forThinking: record.thinking),
            cwd: URL(fileURLWithPath: record.lastObservedWhere, isDirectory: true),
            sessionId: record.providerSessionId ?? claudeSessionId(for: record.id),
            // An agent that has never had a turn cannot have a conversation to
            // resume, so resume-first would spawn a CLI process purely to be told
            // so. `latestTurnAt` is stamped on `.turnStarted` and persisted, which
            // makes it the durable answer across relaunches.
            conversationMayExist: record.latestTurnAt != nil
        )
    }

    /// The only `CodexAgentRunner(` construction in the app, mirroring
    /// `claudeRunner(for:)` so the same ownership scan holds for all three.
    nonisolated static func codexRunner(for record: AgentRecord) -> AgentRunning {
        CodexAgentRunner(config: codexRunnerConfig(for: record))
    }

    /// What a codex-backed runner is built with. The catalogue prefix is
    /// stripped (codex takes bare slugs), pi thinking levels map to
    /// `model_reasoning_effort` only on exact match, and — the one difference
    /// from claude — continuity is STORED: `record.codexThreadId` (nil ⇒ fresh)
    /// is read back so a later turn resumes the same codex thread.
    nonisolated static func codexRunnerConfig(for record: AgentRecord) -> CodexAgentRunner.Config {
        CodexAgentRunner.Config(
            model: CodexCLIBackend.modelArgument(forCatalogId: record.model),
            effort: CodexCLIBackend.effortArgument(forThinking: record.thinking),
            cwd: URL(fileURLWithPath: record.lastObservedWhere, isDirectory: true),
            threadId: record.codexThreadId
        )
    }

    /// What the production runner is built with. Split out of `piRunner(for:)` so the
    /// matrix can read it — the runner itself exposes nothing.
    ///
    /// P2D.3: the role's `tools` reaches Pi from HERE, derived from the record's role
    /// id and its working directory, rather than from a new persisted field: role
    /// files are tracked in the repository, so an isolated agent's worktree carries
    /// the same `.pi/agents` its project does, and editing a role file takes effect on
    /// the next run instead of being frozen at spawn time.
    /// `spawnDepth` is REQUIRED and has no default. `toolsArguments`' own comment
    /// has said since C8 that "the caller passes `allowingSpawn: depth <
    /// maxSpawnDepth`" — and no production caller ever did, so Array's pi spawn
    /// tool was denied to every ROLED agent for the whole time it shipped. A
    /// defaulted parameter is exactly how that happened once; it does not get a
    /// second chance.
    nonisolated static func runnerConfig(
        for record: AgentRecord, spawnDepth: Int
    ) -> PiAgentRunner.Config {
        let cwd = URL(fileURLWithPath: record.lastObservedWhere, isDirectory: true)
        // `model`/`thinking` come from the RECORD: the role already decided them at
        // spawn time (`handleSpawnRequest`), and a role file edited since must not
        // silently move a running agent's provider settings. Only the tool list is
        // read live, and via `toolsArguments` rather than `resolve` (cross-review):
        // resolving would also validate the role's model/reasoning, so a typo in a
        // field this call ignores would silently drop the agent's `--tools`.
        return PiAgentRunner.Config(
            model: record.model,
            thinking: record.thinking,
            cwd: cwd,
            // B7.1: `sessionId(for:)` is the SEED a fresh agent uses;
            // `record.providerSessionId` — nothing populates it for pi today,
            // since Array's own `--session-id` is authoritative there, but the
            // field is provider-neutral (mirrors `codexThreadId`) — would win
            // if a future pi path ever needed to adopt an id it did not mint.
            sessionId: record.providerSessionId ?? sessionId(for: record.id),
            // Only scan for roles when this agent HAS one. `toolsArguments(roleId:)`
            // returns [] for nil, so building a registry first was a directory
            // enumeration plus a frontmatter parse of every role file — on the main
            // actor, on every turn — to compute an empty array for the common case.
            // Array's own project has 12 role files; a roleless agent read all of
            // them before each prompt.
            // T5 — the spawn verbs are appended only below Array's own cap, so the
            // model is never OFFERED a verb it cannot use. That is better than
            // refusing after the fact: it never proposes what it cannot have.
            extraArgs: record.role.map {
                RoleRegistry(projectRoot: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true))
                    .toolsArguments(roleId: $0, allowingSpawn: spawnDepth < Self.maxSpawnDepth)
            } ?? []
        )
    }

    // MARK: - Host-local Home / Where / What (Queue 91 P2)

    /// Current private location projection from the durable four-part location
    /// model. This host-local value never enters companion sync.
    func locationSnapshot(for id: AgentID, at now: Date = Date()) -> AgentLocationSnapshot? {
        guard let record = records[id] else { return nil }
        ensureLocationProjector(for: record)
        return locationProjectors[id]?.snapshot(at: now)
    }

    private func ensureLocationProjector(for record: AgentRecord) {
        guard locationProjectors[record.id] == nil else { return }
        let checkout = URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)
        let home = AgentHome(
            projectId: record.projectId,
            projectRoot: record.projectRoot.map { URL(fileURLWithPath: $0, isDirectory: true) },
            checkoutRoot: checkout,
            homeRelativePath: record.homeRelativePath)
        locationProjectors[record.id] = AgentLocationProjector(
            home: home,
            whereDirectory: URL(fileURLWithPath: record.lastObservedWhere, isDirectory: true))
    }

    @discardableResult
    func addRuntimeObservationObserver(
        for id: AgentID,
        _ observer: @escaping (AgentRuntimeObservation) -> Void
    ) -> UUID {
        let token = UUID()
        runtimeObservationObservers[id, default: [:]][token] = observer
        return token
    }

    func removeRuntimeObservationObserver(_ token: UUID, for id: AgentID) {
        runtimeObservationObservers[id]?[token] = nil
        if runtimeObservationObservers[id]?.isEmpty == true {
            runtimeObservationObservers[id] = nil
        }
    }

    @discardableResult
    func addDisplayNameObserver(
        for id: AgentID,
        _ observer: @escaping (String) -> Void
    ) -> UUID {
        let token = UUID()
        displayNameObservers[id, default: [:]][token] = observer
        return token
    }

    func removeDisplayNameObserver(_ token: UUID, for id: AgentID) {
        displayNameObservers[id]?[token] = nil
        if displayNameObservers[id]?.isEmpty == true {
            displayNameObservers[id] = nil
        }
    }

    private func notifyDisplayNameChanged(for record: AgentRecord) {
        guard let observers = displayNameObservers[record.id] else { return }
        for observer in observers.values {
            observer(record.displayName)
        }
    }

    private func ingestRuntimeObservation(
        _ observation: AgentRuntimeObservation,
        for id: AgentID
    ) {
        guard let record = records[id] else { return }
        // A captured codex thread id is host-local persistence state, not a Home
        // / Where / What fact: persist it and stop. The guard on inequality
        // makes this a no-op when `thread.started` re-fires the same id on
        // resume (so a turn does not needlessly rewrite the store).
        if case let .threadId(value) = observation {
            guard record.codexThreadId != value else { return }
            var updated = record
            updated.codexThreadId = value
            records[id] = updated
            persist(updated)
            return
        }
        // B7.1 — claude's own reported session id. Same shape and same
        // inequality guard as `.threadId` above (a no-op when `system/init`
        // re-echoes the id a normal, non-forked resume already has).
        if case let .providerSessionId(value) = observation {
            // B7.2: a pending fork clears the moment its new id is adopted —
            // checked before the inequality shortcut below, since the whole
            // point of a fork was to stop using the id `record.providerSessionId`
            // held before it, and that stale marker must not survive a no-op.
            guard record.providerSessionId != value || record.pendingSessionForkFrom != nil else { return }
            var updated = record
            updated.providerSessionId = value
            updated.pendingSessionForkFrom = nil
            records[id] = updated
            persist(updated)
            return
        }
        // The concrete model behind the alias. Persisted for the same reason as
        // the session id: it is the context meter's denominator key, and without
        // it on the record the ring is empty until the agent takes another turn.
        if case let .resolvedModel(value) = observation {
            guard record.resolvedModelId != value else { return }
            var updated = record
            updated.resolvedModelId = value
            records[id] = updated
            persist(updated)
            return
        }
        ensureLocationProjector(for: record)
        locationProjectors[id]?.ingest(observation)
        // The projector and the transcript list consume the same sanitized,
        // non-Codable side channel. Observers are host-local and scoped by the
        // immutable agent ID; no raw runtime payload or path enters the event log.
        runtimeObservationObservers[id]?.values.forEach { $0(observation) }
    }

    /// The concrete `provider/model` the harness resolved this agent's alias to,
    /// as the harness reported it. The context meter's denominator key: the
    /// Claude harness offers aliases (`anthropic/opus`) that are not catalogue
    /// keys, so without this a claude agent has no window and an empty ring.
    func resolvedModelId(for id: AgentID) -> String? { records[id]?.resolvedModelId }

    /// True once there is user/session work that makes Home retargeting unsafe.
    /// Used by the native Home action surface: zero-turn agents may be reassigned;
    /// anything with a prompt, history, or live runner must fork through New Agent Here.
    func hasUserWorkOrSessionHistory(_ id: AgentID) -> Bool {
        guard let record = records[id] else { return false }
        return restoredIDs.contains(id)
            || record.realActivityAt != nil
            || firstPromptByAgent[id] != nil
            || !(history[id]?.isEmpty ?? true)
            || isRunning(id)
    }

    /// Explicitly changes authoritative Home for a provisional zero-turn agent.
    /// This mutates only the host-local execution location and project identity and
    /// the in-memory location projector; no path-bearing value becomes Codable.
    @discardableResult
    func reassignProvisionalHome(agentID id: AgentID, cwd: URL, projectId: UUID?) -> Bool {
        guard var record = records[id] else { return false }
        guard !hasUserWorkOrSessionHistory(id) else { return false }
        record.cwd = cwd.path
        record.projectRoot = cwd.path
        record.checkoutRoot = cwd.path
        record.homeRelativePath = nil
        record.lastObservedWhere = cwd.path
        record.worktreeId = nil
        record.projectId = projectId
        record.lastActivityAt = max(record.lastActivityAt, Date())
        do {
            // Durability is the commit point. Do not update the live record or
            // projector first: a swallowed write failure would make the UI/next
            // runner use one Home while relaunch restored another.
            try upsertRecord(record)
        } catch {
            warn("AgentSupervisor.reassignProvisionalHome: could not persist Home for \(id.rawValue.uuidString): \(error)")
            return false
        }
        records[id] = record
        locationProjectors[id] = nil
        ensureLocationProjector(for: record)
        return true
    }

    // MARK: - Restore (P2A.7)

    /// What one `restore()` adopted, so the caller reports numbers instead of
    /// guessing at them.
    struct RestoreReport {
        /// Adopted into `records`, in `AgentStore.loadAll()` order.
        var restored: [AgentID] = []
        /// Records whose `cwd` no longer exists on disk. Marked, not adopted, and
        /// never deleted — the directory may be a detached worktree that comes back,
        /// and throwing away a user's agent because a path moved is not this call's
        /// decision to make.
        var stale: [AgentID] = []
        /// Already live in this session, so the in-memory copy was left alone.
        var skipped: [AgentID] = []
    }

    /// The agents this supervisor adopted from a previous launch. Read by
    /// `wireManagedAgentTile`, which shows a "previous session" notice for them: the
    /// desktop transcript lives only in the view, so a restored agent's tile is empty
    /// even though its conversation is not.
    private(set) var restoredIDs: Set<AgentID> = []
    /// Records `restore()` refused to adopt because their project root is gone. Kept
    /// so the Phase 3 inbox can surface them rather than have them silently missing.
    private(set) var staleIDs: Set<AgentID> = []

    /// Prior transcripts rehydrated from a provider session file, for DISPLAY
    /// ONLY. Deliberately a SEPARATE buffer from `history[id]`: history is
    /// replayed through `events(for:)`, and a managed-agent tile mirrors every
    /// event it ingests off that stream onto the syncable activity timeline
    /// (`ContinuumApp.recordManagedActivity`, 88.4c). Rehydration restores
    /// message BODIES the sync translators intentionally drop, so replaying them
    /// through that path would re-cross the companion boundary (I5). Instead the
    /// tile reads this buffer directly. See `seedRehydratedTranscript`.
    private var rehydratedTranscripts: [AgentID: RehydratedTranscript] = [:]

    /// Adopts every record `AgentStore` holds into `records`.
    ///
    /// NO PROVIDER PROCESS IS STARTED, which is the whole shape of this method: a
    /// relaunched agent is idle until the user sends a prompt, and auto-resuming N
    /// processes at launch is both surprising and expensive. Nothing is lost by
    /// waiting — Pi's `--session-id` is derived from the agent id (`sessionId(for:)`),
    /// so the next prompt continues the same conversation.
    ///
    /// A record whose `cwd` no longer exists is MARKED AND SKIPPED (the packet's
    /// watch-out): adopting it would put an agent in the inbox whose every `send`
    /// spawns a process into a missing directory.
    @discardableResult
    func restore(fileManager: FileManager = .default) -> RestoreReport {
        var report = RestoreReport()
        let stored: [AgentRecord]
        do {
            stored = try store.loadAll()
        } catch {
            warn("AgentSupervisor.restore: could not read the agent store: \(error)")
            return report
        }
        func persistBeforeAdoption(_ record: AgentRecord) {
            do {
                try withAgentStoreLock { try upsertRecord(record) }
            } catch {
                warn("AgentSupervisor.restore: could not persist migrated agent \(record.id.rawValue.uuidString): \(error)")
            }
        }

        for storedRecord in stored {
            // An agent this session already owns wins over the stored copy: `records`
            // is the live one and the store trails it by at most one persist. This is
            // also what makes `restore()` safe to call twice.
            if records[storedRecord.id] != nil {
                report.skipped.append(storedRecord.id)
                continue
            }
            var record = storedRecord
            if record.harness == nil {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let claudeURL = ClaudeSessionTranscriptReader.sessionFileURL(
                    homeURL: home, cwd: record.cwd, sessionId: Self.claudeSessionId(for: record.id))
                let piURL = PiSessionTranscriptReader.locateSessionFile(
                    homeURL: home, cwd: record.cwd, sessionId: Self.sessionId(for: record.id))
                let evidence = LegacyAgentHarnessMigration.Evidence(
                    hasCodexThread: !(record.codexThreadId ?? "").isEmpty,
                    hasClaudeConversation: fileManager.fileExists(atPath: claudeURL.path),
                    hasPiSession: piURL != nil)
                record.harness = LegacyAgentHarnessMigration.resolve(
                    evidence: evidence,
                    storedPreference: AgentHarnessConfig.explicitlyStored())
                // The stored preference decides what a NEW agent gets; it is not
                // evidence about THIS record. When it hands a record a harness that
                // cannot run the record's own model — a settings default of Claude
                // Code meeting an `openai-codex/*` agent — the pairing is a dead
                // agent: every send refused, forever, for a record that ran fine
                // yesterday. Pi is the multi-provider harness and is what these
                // records ran under before ownership existed, so it takes them back.
                if let resolved = record.harness,
                   !AgentHarnessConfig.isProviderCompatible(model: record.model, harness: resolved),
                   AgentHarnessConfig.isProviderCompatible(model: record.model, harness: .pi) {
                    record.harness = .pi
                }
                if record.harness != nil { persistBeforeAdoption(record) }
            }
            // Legacy records used model ids, role ids, UUIDs, or blank names. Read
            // them defensively and rewrite the corrected record before the inbox can
            // observe it, including when the project root is temporarily stale.
            if record.migrateDisplayNameIfNeeded() { persistBeforeAdoption(record) }
            // Repair the two legacy Codex states before any tile can seed from
            // them: replace with an exact stale rollout reading when available;
            // otherwise strip the bogus used/max pair while preserving the
            // cumulative accounting fields. restore() never owns a live runner,
            // so this bounded tail read cannot race an active turn.
            if record.codexThreadId != nil {
                if var exact = codexRestoredContextSnapshot(record) {
                    exact.freshness = .stale
                    if record.lastContextWindow != exact {
                        record.lastContextWindow = exact
                        persistBeforeAdoption(record)
                    }
                } else if var legacy = record.lastContextWindow,
                          legacy.source == .codexTurnUsage,
                          legacy.usedTokens != nil || legacy.maxTokens != nil {
                    legacy.usedTokens = nil
                    legacy.maxTokens = nil
                    record.lastContextWindow = legacy
                    persistBeforeAdoption(record)
                }
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: record.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                staleIDs.insert(record.id)
                report.stale.append(record.id)
                warn("AgentSupervisor.restore: skipping agent \(record.id.rawValue.uuidString) — its project root \(record.cwd) no longer exists")
                continue
            }
            records[record.id] = record
            // A root that came back stops being stale. Without this an agent marked
            // on an earlier sweep would read as both stale and live to the Phase 3
            // inbox (from the cross-review).
            staleIDs.remove(record.id)
            restoredIDs.insert(record.id)
            report.restored.append(record.id)
        }
        // T6.6: every observed pi child restored above may have a delegated run
        // that died with the previous session. Settle each one's fate from its
        // `run.json` — one read, never `events.jsonl`, and never a watcher — so a
        // child tile does not sit apparently mid-turn forever. Runs at the END,
        // because it needs every restored record in `records` to resolve a child's
        // parent.
        reconcileObservedRunsAfterRestore()
        return report
    }

    /// True for an agent that came back from a previous launch rather than being
    /// spawned in this one. A durable fact about the agent: it stays true once the
    /// agent runs again.
    func wasRestored(_ id: AgentID) -> Bool { restoredIDs.contains(id) }

    /// Whether a view attaching to this agent should show the "previous session"
    /// placeholder: it came back from a previous launch AND has produced nothing
    /// since, so the replay it is about to receive is empty.
    ///
    /// Narrower than `wasRestored` on purpose (from the cross-review). A restored
    /// agent that has since been prompted has a real transcript to replay, and a tile
    /// re-wired to it — P2A.5's re-attach, Phase 3's "open in tile" — would otherwise
    /// print the placeholder underneath it.
    func needsPreviousSessionNotice(_ id: AgentID) -> Bool {
        restoredIDs.contains(id) && (history[id]?.isEmpty ?? true) && rehydratedTranscripts[id] == nil
    }

    // MARK: - Transcript rehydration (.plans/03-transcript-rehydration.md)

    /// Seeds a restored agent's prior transcript for DISPLAY ONLY. Stored in a
    /// buffer the tile reads directly (`rehydratedTranscript(for:)`); it is
    /// deliberately NOT appended to `history[id]` and NOT run through
    /// `deliver`, so it is never replayed via `events(for:)` and therefore never
    /// re-published to the syncable activity timeline. This is the I5
    /// display-only guard: rehydration restores message bodies locally without
    /// re-crossing the companion sync boundary. Seeding it flips
    /// `needsPreviousSessionNotice` false, so the plain placeholder is not also
    /// shown, and lets any tile that later attaches rehydrate the same content.
    func seedRehydratedTranscript(_ transcript: RehydratedTranscript, for id: AgentID) {
        rehydratedTranscripts[id] = transcript
    }

    /// The prior transcript seeded for `id`, if any. A tile pulls this on attach
    /// and ingests it straight into its local projection (never through the
    /// event stream), so the bodies render locally and never re-sync.
    func rehydratedTranscript(for id: AgentID) -> RehydratedTranscript? {
        rehydratedTranscripts[id]
    }

    /// The inputs a rehydrate needs, resolved from the live record on the main
    /// thread so the caller can then read the (potentially large) session file
    /// OFF it. `nil` for an agent this supervisor does not know.
    func rehydrationInputs(for id: AgentID) -> ManagedTranscriptRehydrator.Inputs? {
        guard let record = records[id] else { return nil }
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let codexHomeURL = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeURL.appendingPathComponent(".codex", isDirectory: true)
        return ManagedTranscriptRehydrator.Inputs(
            agentUUID: id.rawValue,
            cwd: record.cwd,
            model: record.model,
            harness: record.harness,
            claudeCLIAvailable: false,
            homeURL: homeURL,
            codexThreadId: record.codexThreadId,
            codexHomeURL: codexHomeURL)
    }

    // MARK: - Lifecycle

    /// Creates an agent, persists it, and (when `prompt` is non-empty) runs that
    /// first prompt. `tileId` is a VIEW BINDING, not identity — `nil` is a headless
    /// agent (P2A.6).
    ///
    /// The agent works in `cwd` — today's behaviour, and the unchanged default. The
    /// isolated form below is a separate, THROWING entry point rather than a defaulted
    /// `isolated:` parameter on this one: only isolation can fail, and folding it in
    /// here would make every existing caller handle an error its call can never raise.
    func spawn(
        role: String?,
        prompt: String?,
        cwd: URL,
        harness: AgentHarness = AgentHarnessConfig.resolved(),
        model: String,
        thinking: String,
        projectId: UUID? = nil,
        projectRoot: URL? = nil,
        homeRelativePath: String? = nil,
        parentAgentID: AgentID? = nil,
        sourceItemId: String? = nil,
        tileId: UUID? = nil,
        displayName: String? = nil
    ) -> AgentID {
        let logicalProjectRoot = projectRoot ?? cwd
        let checkoutRoot = projectRoot ?? cwd
        return makeAgent(
            id: AgentID(rawValue: UUID()),
            role: role,
            prompt: prompt,
            cwd: cwd,
            projectRoot: logicalProjectRoot,
            checkoutRoot: checkoutRoot,
            homeRelativePath: homeRelativePath,
            worktreeId: nil,
            worktreeBranch: nil,
            harness: harness,
            model: model,
            thinking: thinking,
            projectId: projectId,
            parentAgentID: parentAgentID,
            sourceItemId: sourceItemId,
            tileId: tileId,
            displayName: displayName
        )
    }

    /// P2C.2 — spawn that can opt into its own checkout.
    ///
    /// `isolated: true` runs `git worktree add` against `cwd` (the project root) and
    /// gives the agent `<repo>/.worktrees/<slug>` on `agent/<slug>`: the record's `cwd`
    /// IS the worktree, so `piRunner(for:)` — which reads `record.cwd` — starts Pi
    /// there, and `worktreeBranch` records which branch the work lands on. `false` is
    /// exactly the call above.
    ///
    /// A worktree that cannot be created FAILS THE SPAWN. No agent, no record, no
    /// fallback to the main checkout: falling back would silently put a supposedly
    /// isolated agent in the shared tree, which is the clobbering 2C exists to
    /// prevent, and the caller would never learn it.
    func spawn(
        role: String?,
        prompt: String?,
        cwd: URL,
        harness: AgentHarness = AgentHarnessConfig.resolved(),
        model: String,
        thinking: String,
        projectId: UUID? = nil,
        projectRoot: URL? = nil,
        homeRelativePath: String? = nil,
        parentAgentID: AgentID? = nil,
        sourceItemId: String? = nil,
        tileId: UUID? = nil,
        isolated: Bool,
        displayName: String? = nil
    ) throws -> AgentID {
        // The id is minted HERE, before anything is created, because the slug is
        // derived from it — `WorktreeManager.slug` id-suffixes so two agents given the
        // same role and prompt do not land on one directory and one branch.
        let id = AgentID(rawValue: UUID())
        let logicalProjectRoot = projectRoot ?? cwd
        var checkoutRoot = projectRoot ?? cwd
        var workingDirectory = cwd
        var branch: String?
        var worktreeId: String?
        if isolated {
            let worktree = try worktrees.add(
                repo: logicalProjectRoot,
                slug: WorktreeManager.slug(role: role, prompt: prompt, id: id)
            )
            checkoutRoot = worktree.path
            workingDirectory = homeRelativePath.map {
                worktree.path.appendingPathComponent($0, isDirectory: true)
            } ?? worktree.path
            branch = worktree.branch
            worktreeId = worktree.path.lastPathComponent
        } else if let homeRelativePath {
            checkoutRoot = logicalProjectRoot
            workingDirectory = logicalProjectRoot.appendingPathComponent(homeRelativePath, isDirectory: true)
        }
        return makeAgent(
            id: id,
            role: role,
            prompt: prompt,
            cwd: workingDirectory,
            projectRoot: logicalProjectRoot,
            checkoutRoot: checkoutRoot,
            homeRelativePath: homeRelativePath,
            worktreeId: worktreeId,
            worktreeBranch: branch,
            harness: harness,
            model: model,
            thinking: thinking,
            projectId: projectId,
            parentAgentID: parentAgentID,
            sourceItemId: sourceItemId,
            tileId: tileId,
            displayName: displayName
        )
    }

    private func makeAgent(
        id: AgentID,
        role: String?,
        prompt: String?,
        cwd: URL,
        projectRoot: URL,
        checkoutRoot: URL,
        homeRelativePath: String?,
        worktreeId: String?,
        worktreeBranch: String?,
        harness: AgentHarness,
        model: String,
        thinking: String,
        projectId: UUID?,
        parentAgentID: AgentID? = nil,
        sourceItemId: String? = nil,
        tileId: UUID?,
        displayName: String? = nil
    ) -> AgentID {
        let now = Date()
        if let parentAgentID {
            // The child and its parent's counter are committed as one
            // store-locked transaction. A stale restored supervisor therefore
            // cannot reserve the same slot, and a child write failure leaves the
            // durable counter untouched instead of burning an ordinal.
            guard let child = persistChildSpawn(
                id: id,
                role: role,
                cwd: cwd,
                projectRoot: projectRoot,
                checkoutRoot: checkoutRoot,
                homeRelativePath: homeRelativePath,
                worktreeId: worktreeId,
                worktreeBranch: worktreeBranch,
                harness: harness,
                model: model,
                thinking: thinking,
                projectId: projectId,
                parentAgentID: parentAgentID,
                sourceItemId: sourceItemId,
                tileId: tileId,
                displayName: displayName,
                createdAt: now
            ) else {
                warn("AgentSupervisor.makeAgent: child \(id.rawValue.uuidString) was not persisted; no ordinal was committed")
                return id
            }
            records[id] = child
        } else {
            var record = AgentRecord(
                id: id,
                // A spawn path starts with the shared permission sentinel. The
                // prompt remains named inside `send(_:to:)`; source and parent
                // fallbacks are applied below only when no prompt will be sent.
                displayName: AgentRecord.defaultAgentName,
                displayNameSource: .sentinel,
                role: role,
                harness: harness,
                model: model,
                thinking: thinking,
                cwd: cwd.path,
                projectRoot: projectRoot.path,
                checkoutRoot: checkoutRoot.path,
                homeRelativePath: homeRelativePath,
                lastObservedWhere: cwd.path,
                worktreeId: worktreeId,
                worktreeBranch: worktreeBranch,
                projectId: projectId,
                parentAgentID: nil,
                sourceItemId: sourceItemId,
                createdAt: now,
                lastActivityAt: now,
                tileId: tileId
            )
            // An explicit name is the only rung allowed to land before `send`; a
            // valid first prompt must still pass through that single funnel.
            if let proposal = AgentRecord.resolveDerivedDisplayName(
                explicitName: displayName,
                model: model,
                role: role,
                id: id.rawValue
            ) {
                record.displayName = proposal.name
                record.displayNameSource = proposal.source
            }
            records[id] = record
            persist(record)
        }
        if let prompt, !prompt.isEmpty {
            send(prompt, to: id)
        } else {
            applyDerivedNameIfNeeded(to: id, firstPrompt: nil)
        }
        return id
    }

    /// Commit one child allocation against the durable `AgentStore`, not a
    /// supervisor's restored in-memory parent. The lock is a shared filesystem
    /// lock in the store, so independently restored supervisors and separate
    /// processes use the same exclusion. AgentStore still performs every record
    /// write through its AtomicWriter; the lock makes the read/child/parent
    /// sequence a store-level transaction.
    private func persistChildSpawn(
        id: AgentID,
        role: String?,
        cwd: URL,
        projectRoot: URL,
        checkoutRoot: URL,
        homeRelativePath: String?,
        worktreeId: String?,
        worktreeBranch: String?,
        harness: AgentHarness,
        model: String,
        thinking: String,
        projectId: UUID?,
        parentAgentID: AgentID,
        sourceItemId: String?,
        tileId: UUID?,
        displayName: String?,
        createdAt: Date
    ) -> AgentRecord? {
        do {
            return try withAgentStoreLock {
                // The durable parent is authoritative. Falling back to the
                // restored copy would reopen the exact collision this lock closes.
                guard let parent = try store.load(id: parentAgentID) else {
                    warn("AgentSupervisor: cannot reserve a child ordinal; parent \(parentAgentID.rawValue.uuidString) is absent from AgentStore")
                    return nil
                }
                let durableChildren = try store.loadAll()
                    .filter { $0.parentAgentID == parentAgentID }
                    .compactMap(\.parentRelativeOrdinal)
                    .filter { $0 > 0 }
                let highestChildOrdinal = durableChildren.max() ?? 0
                let minimumNextOrdinal = highestChildOrdinal == Int.max
                    ? Int.max
                    : highestChildOrdinal + 1
                let ordinal = max(1, max(parent.nextChildOrdinal, minimumNextOrdinal))
                // Do not wrap the counter. A wrapped ordinal could collide with
                // an old child and is a failed spawn, not a reason to reuse it.
                guard ordinal < Int.max else {
                    warn("AgentSupervisor: child ordinal space exhausted for parent \(parentAgentID.rawValue.uuidString)")
                    return nil
                }

                var child = AgentRecord(
                    id: id,
                    displayName: AgentRecord.defaultAgentName,
                    displayNameSource: .sentinel,
                    role: role,
                    harness: harness,
                    model: model,
                    thinking: thinking,
                    cwd: cwd.path,
                    projectRoot: projectRoot.path,
                    checkoutRoot: checkoutRoot.path,
                    homeRelativePath: homeRelativePath,
                    lastObservedWhere: cwd.path,
                    worktreeId: worktreeId,
                    worktreeBranch: worktreeBranch,
                    projectId: projectId,
                    parentAgentID: parentAgentID,
                    sourceItemId: sourceItemId,
                    parentRelativeOrdinal: ordinal,
                    createdAt: createdAt,
                    lastActivityAt: createdAt,
                    tileId: tileId
                )
                // Only the explicit rung may land before the first prompt. The
                // common send/headless funnel applies the remaining rungs below.
                if let proposal = AgentRecord.resolveDerivedDisplayName(
                    explicitName: displayName,
                    model: model,
                    role: role,
                    id: id.rawValue
                ) {
                    child.displayName = proposal.name
                    child.displayNameSource = proposal.source
                }

                var updatedParent = parent
                updatedParent.nextChildOrdinal = ordinal + 1

                // Write the child first. Re-read after a throw to distinguish an
                // AtomicWriter failure before rename from one after rename (for
                // example, backup pruning). A durable child is a committed claim
                // and must become visible instead of a phantom failure.
                let committedChild: AgentRecord
                do {
                    try upsertRecord(child)
                    committedChild = child
                } catch {
                    let durableChild: AgentRecord?
                    do {
                        durableChild = try store.load(id: id)
                    } catch {
                        warn("AgentSupervisor: could not re-read child \(id.rawValue.uuidString) after its write threw; refusing to hide possible corruption: \(error)")
                        return nil
                    }
                    guard let durableChild else {
                        warn("AgentSupervisor: child \(id.rawValue.uuidString) was absent after its write threw before commit at ordinal \(ordinal): \(error)")
                        return nil
                    }
                    guard durableChild.parentAgentID == parentAgentID,
                          durableChild.parentRelativeOrdinal == ordinal else {
                        warn("AgentSupervisor: child \(id.rawValue.uuidString) changed unexpectedly after its write threw; refusing unrelated durable state")
                        return nil
                    }
                    warn("AgentSupervisor: child \(id.rawValue.uuidString) was durable after its write threw; treating the post-commit claim as success: \(error)")
                    committedChild = durableChild
                }

                // The parent is the second half of the claim. Its own write uses
                // the same read-after-throw rule and a bounded repair attempt, so
                // success is reported only when the durable high-water is visible.
                let durableParent = try persistParentHighWater(
                    updatedParent,
                    requiredNextOrdinal: ordinal + 1,
                    childID: id
                )
                records[parentAgentID] = durableParent
                return committedChild
            }
        } catch {
            warn("AgentSupervisor: could not reserve a durable child ordinal for parent \(parentAgentID.rawValue.uuidString): \(error)")
            return nil
        }
    }

    /// Persist the parent half of a child claim and re-read after every throwing
    /// upsert. `AtomicWriter` is intentionally unchanged: this supervisor owns the
    /// recovery decision because only it knows which child claim requires which
    /// parent high-water.
    private func persistParentHighWater(
        _ desiredParent: AgentRecord,
        requiredNextOrdinal: Int,
        childID: AgentID
    ) throws -> AgentRecord {
        do {
            try upsertRecord(desiredParent)
            return desiredParent
        } catch {
            let reread: AgentRecord?
            do {
                reread = try store.load(id: desiredParent.id)
            } catch {
                warn("AgentSupervisor: could not re-read parent \(desiredParent.id.rawValue.uuidString) after child \(childID.rawValue.uuidString)'s parent write threw; refusing unrelated corruption: \(error)")
                throw error
            }
            if let reread, reread.nextChildOrdinal >= requiredNextOrdinal {
                warn("AgentSupervisor: parent \(desiredParent.id.rawValue.uuidString) was durable after its write threw; treating child \(childID.rawValue.uuidString) as a coherent success: \(error)")
                return reread
            }

            guard var repair = reread else {
                warn("AgentSupervisor: parent \(desiredParent.id.rawValue.uuidString) disappeared after child \(childID.rawValue.uuidString)'s write; refusing an orphaned child")
                throw error
            }
            repair.nextChildOrdinal = max(repair.nextChildOrdinal, requiredNextOrdinal)
            do {
                try upsertRecord(repair)
                return repair
            } catch {
                let repaired: AgentRecord?
                do {
                    repaired = try store.load(id: desiredParent.id)
                } catch {
                    warn("AgentSupervisor: could not re-read parent \(desiredParent.id.rawValue.uuidString) after its high-water repair threw: \(error)")
                    throw error
                }
                guard let repaired, repaired.nextChildOrdinal >= requiredNextOrdinal else {
                    warn("AgentSupervisor: parent \(desiredParent.id.rawValue.uuidString) high-water remained below \(requiredNextOrdinal) after child \(childID.rawValue.uuidString) became durable; refusing an incoherent success")
                    throw error
                }
                warn("AgentSupervisor: parent \(desiredParent.id.rawValue.uuidString) high-water repair was durable after its write threw; child \(childID.rawValue.uuidString) is coherent: \(error)")
                return repaired
            }
        }
    }

    /// A shared advisory lock, rooted beside the AgentStore records. This is
    /// deliberately not an `NSLock`: another restored supervisor or process must
    /// be excluded by the same durable store-level primitive. Every parent write,
    /// not only allocation, uses this lock before it reads and writes the record.
    private func withAgentStoreLock<T>(_ body: () throws -> T) throws -> T {
        let directory = store.layout.agentsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            warn("AgentSupervisor: could not create the AgentStore lock directory: \(error)")
            throw error
        }
        let lockURL = directory.appendingPathComponent(".child-ordinal-reservation.lock", isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            warn("AgentSupervisor: could not open the AgentStore child-ordinal lock: \(error)")
            throw error
        }
        var locked: CInt = -1
        repeat {
            locked = flock(descriptor, LOCK_EX)
        } while locked != 0 && errno == EINTR
        guard locked == 0 else {
            let code = errno
            Darwin.close(descriptor)
            let error = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            warn("AgentSupervisor: could not lock the AgentStore child-ordinal lock: \(error)")
            throw error
        }
        defer {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        return try body()
    }

    /// A child may inherit a parent's human name, but never a legacy model/role/
    /// UUID title that happened to be provenance-marked manual. The defensive
    /// projection deliberately differs from `humanDisplayName`, whose job is to
    /// preserve an explicit human rename for the existing row.
    private func parentDisplayName(for child: AgentRecord) -> String? {
        guard let parentId = child.parentAgentID, let parent = records[parentId] else { return nil }
        return AgentName.displayTitle(
            parent.displayName,
            model: parent.model,
            role: parent.role,
            id: parent.id.rawValue
        )
    }

    /// The shared production naming funnel after the explicit-name rung. It is
    /// called by both prompted and headless spawns, including role-based and
    /// source-item fan-out children.
    private func applyDerivedNameIfNeeded(to id: AgentID, firstPrompt: String?) {
        guard var record = records[id],
              record.namingRequest == nil,
              record.displayName == AgentRecord.defaultAgentName,
              record.displayNameSource == .sentinel,
              let proposal = AgentRecord.resolveDerivedDisplayName(
                firstPrompt: firstPrompt,
                sourceItemId: record.sourceItemId,
                parentName: parentDisplayName(for: record),
                parentRelativeOrdinal: record.parentRelativeOrdinal,
                model: record.model,
                role: record.role,
                id: record.id.rawValue
              ) else {
            return
        }
        record.displayName = proposal.name
        record.displayNameSource = proposal.source
        records[id] = record
        persist(record)
    }

    /// Runs `prompt` on the agent's own runner, off the main thread (`run` blocks).
    /// Events hop back via `DispatchQueue.main.async` — FIFO, which is what keeps
    /// the fan-out ordered; a `Task { @MainActor }` per event would not be.
    /// Public compatibility seam for text-only callers. Image-bearing prompts
    /// must use `accept(.sendPrompt:)`, which creates a prepared capability after
    /// all-or-nothing ownership/path validation. Rejecting here closes the direct
    /// `send(AgentPrompt,to:)` bypass instead of trusting caller-supplied URLs.
    @discardableResult
    func send(_ prompt: AgentPrompt, to id: AgentID) -> Bool {
        guard prompt.imageAttachments.isEmpty else {
            warn("AgentSupervisor.send: unmanaged image attachment transport refused")
            return false
        }
        return sendPrepared(
            PreparedAgentPrompt(prompt: prompt, expectedAgentID: id),
            to: id
        )
    }

    @discardableResult
    private func sendPrepared(_ prepared: PreparedAgentPrompt, to id: AgentID) -> Bool {
        guard prepared.expectedAgentID == id else {
            warn("AgentSupervisor.send: prepared prompt agent mismatch")
            return false
        }
        let prompt = prepared.prompt
        guard var record = records[id] else {
            warn("AgentSupervisor.send: no agent \(id.rawValue.uuidString)")
            return false
        }
        // ONE RUNNER PER AGENT, refused rather than replaced (from the
        // cross-review). Assigning over `runners[id]` would leave the first process
        // running and unreachable by `stop`, with two Pi processes on the same
        // `--session-id` writing the same conversation. Refusing is safe for the UI
        // — the tile latches `promptInFlight` and disables its compose row for the
        // duration, so a user cannot reach this — and it is the honest answer for a
        // programmatic caller (P2D's orchestrator): queueing or steering a live turn
        // is `P5.7-steer-follow-up`'s, and inventing it here would be a second
        // answer to supersede.
        if let inFlight = runners[id] {
            warn("AgentSupervisor.send: agent \(id.rawValue.uuidString) already has a prompt in flight (\(type(of: inFlight)))")
            return false
        }
        if let refusal = sendRefusal(for: id) {
            warn("AgentSupervisor.send: \(refusal)")
            return false
        }
        let firstPromptText = Self.visibleNamingText(
            from: prompt,
            model: record.model,
            role: record.role,
            id: record.id.rawValue
        )
        // Keep only the first local prompt's visible text for the explicit naming
        // action. Local image paths/@path argv capabilities are never copied into
        // this memory-only naming context.
        if firstPromptByAgent[id] == nil, let firstPromptText {
            firstPromptByAgent[id] = firstPromptText
        }
        // This is the ONE automatic naming funnel. The shared resolver applies
        // prompt, source-item, then parent-relative ordinal precedence; a later
        // prompt cannot clobber an earlier rung, and a manual rename disarms the
        // gate even if somebody deliberately types the sentinel. No model call,
        // role id, UUID, or worktree slug participates in display naming.
        if record.namingRequest == nil,
           record.displayName == AgentRecord.defaultAgentName,
           record.displayNameSource == .sentinel,
           let proposal = AgentRecord.resolveDerivedDisplayName(
               firstPrompt: firstPromptText,
               sourceItemId: record.sourceItemId,
               parentName: parentDisplayName(for: record),
               parentRelativeOrdinal: record.parentRelativeOrdinal,
               model: record.model,
               role: record.role,
               id: record.id.rawValue
           ) {
            record.displayName = proposal.name
            record.displayNameSource = proposal.source
        }
        let now = Date()
        record.lastActivityAt = max(record.lastActivityAt, now)
        // P6.2: this is real activity, unlike the metadata/event stamp above.
        // Keep the two facts separate so a rename, read, or meter update cannot
        // keep a dead agent out of the settled tail.
        record.latestPromptAt = max(record.latestPromptAt ?? .distantPast, now)
        // P4.4: a user message is the plainest real activity there is, so a settle
        // does not survive it. Before the runner starts, because this write is the
        // same one `persist` below carries — the clear must not wait for the first
        // event to come back.
        clearSettleOnActivity(&record)
        records[id] = record
        persist(record)

        // C4: the user's own words, echoed into the same durable transcript the
        // provider's events land in. Without this a tile-less agent's saved
        // transcript would be missing the prompt that started every turn — the
        // tile used to supply this echo itself (`appendUserPrompt`), which is
        // exactly the tile-shaped dependency this ticket removes.
        recordTranscriptUserPrompt(prompt, for: id)

        // Stamp the spawn-window anchor BEFORE the runner is built, so the
        // interval covers makeRunner (which for pi walks `.pi/agents`) and the
        // dispatch, not just the provider's silence.
        turnFacts[id, default: TurnFacts()].submittedAt = now

        // M1.7: a new prompt is a new turn, so the previous turn's stop no longer
        // speaks for it. Cleared here rather than in `stop` because the throw it
        // guards arrives strictly after `stop` returns.
        stopRequestedAgents.remove(id)
        // `depth(of:)` walks the parent chain, which the caps bound at 3 links,
        // once per turn — not on any per-delta path.
        let runner: AgentRunning
        if let idle = idleSessionRunners.removeValue(forKey: id) {
            if idle.canAcceptAnotherTurn {
                runner = idle
            } else {
                idle.stop()
                runner = makeRunner(AgentRunnerLaunch(record: record, spawnDepth: depth(of: id)))
            }
        } else {
            runner = makeRunner(AgentRunnerLaunch(record: record, spawnDepth: depth(of: id)))
        }
        let runnerGeneration = RunnerGenerationToken()
        runnerGenerationTokens[id] = runnerGeneration
        runners[id] = runner
        notifyTurnCapabilitiesChanged(id)
        // P2D.2: an agent asking for another agent arrives here, out of band from
        // the event stream. Hopped to the main actor like the events are, and for
        // the same reason — the handler mutates supervisor state.
        runner.observeSpawnRequests { [weak self] request in
            DispatchQueue.main.async {
                guard let self,
                      self.runnerGenerationTokens[id] == runnerGeneration,
                      self.runners[id] === runner else { return }
                self.handleSpawnRequest(request, from: id)
            }
        }
        // The runner emits private observations before the matching normalized
        // item event on one serial queue. Main-queue FIFO preserves that order, so
        // the generic event cannot overwrite the path-bearing local What value.
        runner.observeRuntimeObservations { [weak self] observation in
            DispatchQueue.main.async {
                guard let self,
                      self.runnerGenerationTokens[id] == runnerGeneration,
                      self.runners[id] === runner else { return }
                self.ingestRuntimeObservation(observation, for: id)
            }
        }
        // C7: a claude subagent's own work, routed to the CHILD rather than the
        // parent. The child's id is re-derived from the same (parent, tool_use_id)
        // pair the announcement used, so a frame that arrives before, after, or
        // without its announcement still lands on the right agent.
        //
        // T6.5: asked for as a CAPABILITY, not as a class. The downcast was
        // `runner as? ClaudeAgentRunner`, which made this whole path unreachable
        // for every other harness — including pi, whose delegation Dylan was
        // actually using.
        if let observing = runner as? SubagentEventObserving {
            observing.observeSubagentEvents { [weak self] toolUseID, event in
                DispatchQueue.main.async {
                    guard let self,
                          self.runnerGenerationTokens[id] == runnerGeneration,
                          self.runners[id] === runner else { return }
                    self.deliverSubagentEvent(event, parent: id, toolUseID: toolUseID)
                }
            }
        }
        // Codex app-server keys every frame by a provider thread id and can nest
        // descendants. Keep that provider identity local, map the primary to the
        // root Array agent, and adopt each announced child beneath the mapped
        // provider parent.
        if let observing = runner as? ProviderSubagentActivityObserving {
            providerThreadAgentRoutes[id] = [:]
            pendingProviderThreadEvents[id] = [:]
            observing.observeProviderSubagentActivity { [weak self] activity in
                DispatchQueue.main.async {
                    guard let self,
                          self.runnerGenerationTokens[id] == runnerGeneration,
                          self.runners[id] === runner else { return }
                    self.handleProviderSubagentActivity(activity, rootAgentID: id)
                }
            }
        }
        // T6: pi's delegated child does not stream on the parent at all — it
        // writes its own run directory — so its runner reports a LOCATION and the
        // supervisor tails it. Different mechanism, same destination: the child's
        // own thread, through `deliverSubagentEvent`.
        if let reporting = runner as? ObservedRunReporting {
            reporting.observeObservedRuns { [weak self] handle in
                DispatchQueue.main.async {
                    guard let self,
                          self.runnerGenerationTokens[id] == runnerGeneration,
                          self.runners[id] === runner else { return }
                    self.bindObservedRun(handle, parent: id)
                }
            }
        }
        let threadId = Self.threadId(for: id)
        // The translators mint `.turnCompleted` only from a provider result line.
        // A CLI that dies without one (crash mid-line, init never parsed, silent
        // exit 0) must not leave the turn open forever — the supervisor watches
        // for the terminal event itself and closes the turn when the runner
        // returns or throws without having delivered one.
        let sawTurnCompleted = TerminalDeliveryLatch()
        let harnessName = record.harness?.rawValue ?? "agent"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try runner.run(prompt: prompt) { event in
                    let bound = event.withThreadId(threadId)
                    DispatchQueue.main.async {
                        if case .turnCompleted = bound { sawTurnCompleted.set() }
                        self?.deliver(
                            bound, from: runner, generation: runnerGeneration, to: id)
                    }
                }
                // Dispatched from the same runner thread AFTER `run` returned, so
                // main-queue FIFO serializes this behind every queued delivery.
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard !sawTurnCompleted.isSet else { return }
                    // A stop already closes the turn through its own synchronous
                    // `.sessionStateChanged(.stopped)`; a "no result" mint over it
                    // would misreport a deliberate stop as a runner defect.
                    guard !self.stopRequestedAgents.contains(id) else { return }
                    let message = "The \(harnessName) process exited without reporting a result."
                    self.appendAgentDiagnostics(
                        "harness=\(harnessName) exit=no-result \(message)", agentID: id)
                    self.deliver(
                        .turnCompleted(
                            threadId: threadId,
                            turnId: "no-result:\(threadId)",
                            outcome: .interrupted,
                            errorMessage: message),
                        from: runner,
                        generation: runnerGeneration,
                        to: id)
                }
            } catch {
                let message = SecretRedactor.redactLocalDiagnostics(String(describing: error))
                let runnerSaidStopped = error is AgentRunStopped
                DispatchQueue.main.async {
                    guard let self else { return }
                    // M1.7: a stop is not a failure.
                    //
                    // `AgentRunning.stop()` is non-throwing and reports nothing; what
                    // actually happens is that it SIGTERMs the child and `run()` then
                    // throws on the way out. That threw `.runtimeError` -> didFail ->
                    // `.failed`, which was persisted and pushed to the user's phone
                    // as "agent failed". Every consumer of `TurnOutcome.interrupted`
                    // was already correct; there was no producer.
                    //
                    // TWO independent sources agree here on purpose. The runner's own
                    // `AgentRunStopped` is the precise one. The supervisor's own
                    // record of having called `stop(_:)` closes the race the plan
                    // named: `stop` delivers `.sessionStateChanged(.stopped)`
                    // synchronously while the throw arrives later on this hop, so a
                    // runner that decided to throw a plain error microseconds before
                    // the flag was set would still overwrite the stopped state. It
                    // also covers any runner that has not adopted `AgentRunStopped`.
                    if runnerSaidStopped || self.stopRequestedAgents.contains(id) {
                        self.noticePiConversationLoss(id)
                        self.deliver(
                            .turnCompleted(
                                threadId: threadId,
                                turnId: "stopped:\(threadId)",
                                outcome: .interrupted,
                                errorMessage: nil),
                            from: runner,
                            generation: runnerGeneration,
                            to: id)
                        return
                    }
                    fputs("AgentSupervisor: runner failed for agent \(id.rawValue.uuidString): \(message)\n", stderr)
                    // The fputs above is /dev/null for a GUI launched via `open`;
                    // this line is the trail that survives the process.
                    self.appendAgentDiagnostics(
                        "harness=\(harnessName) exit=threw \(message)", agentID: id)
                    self.deliver(
                        .runtimeError(threadId: threadId, message: message),
                        from: runner,
                        generation: runnerGeneration,
                        to: id)
                    // `.runtimeError` shows the error row; a `.turnCompleted` is
                    // still owed so every consumer of turn liveness sees the turn
                    // END — unless the runner already closed it before throwing.
                    if !sawTurnCompleted.isSet {
                        self.deliver(
                            .turnCompleted(
                                threadId: threadId,
                                turnId: "failed:\(threadId)",
                                outcome: .failed,
                                errorMessage: message),
                            from: runner,
                            generation: runnerGeneration,
                            to: id)
                    }
                }
            }
            DispatchQueue.main.async {
                self?.clearRunner(runner, generation: runnerGeneration, for: id)
            }
        }
        return true
    }

    /// Agents whose provider has produced enough output that pi would have written
    /// its session file. See `deliver`.
    private var piPersistenceWatermarkReached: Set<AgentID> = []

    /// B1 — say it out loud at the moment of loss.
    ///
    /// Measured 2026-08-22 and re-measured 2026-08-24: signalling a pi process
    /// before its session has produced one assistant message leaves the session
    /// directory created and EMPTY, and a rerun with the same `--session-id`
    /// reports no session found and starts fresh. M1.7 made that quieter, not
    /// better: the error row that used to hint at it became a clean "Interrupted"
    /// over a destroyed conversation.
    ///
    /// Deliberately narrow. It is not every stop — a long-lived session crosses the
    /// watermark once, early, and then loses at most the in-flight message — and it
    /// is not every harness: claude's SIGINT ends the turn and keeps the session,
    /// and codex is unaffected. A warning that fired on every Stop would be
    /// ignored, and being ignored is the same as being absent.
    ///
    /// It also survives the rpc migration rather than dying with it: rpc registers
    /// SIGTERM/SIGHUP handlers that one-shot mode does not, but persistence is
    /// gated by the watermark in BOTH modes, so the first turn stays exposed.
    private func noticePiConversationLoss(_ id: AgentID) {
        guard records[id]?.harness == .pi else { return }
        guard !piPersistenceWatermarkReached.contains(id) else { return }
        let threadId = Self.threadId(for: id)
        deliver(.itemStarted(
            threadId: threadId,
            itemId: "pi-session-discarded:\(threadId)",
            kind: .error,
            title: "Stopped before Pi saved anything — this conversation was discarded, and the next message starts fresh."
        ), to: id)
        deliver(.itemCompleted(
            threadId: threadId,
            itemId: "pi-session-discarded:\(threadId)",
            kind: .error,
            status: .failed
        ), to: id)
    }

    /// Why a prompt for `id` would be refused right now, or nil if it would be
    /// accepted. The ONE copy of the rule — `send` asks this rather than deciding
    /// again, so the tile cannot show a reason the supervisor does not act on.
    ///
    /// It exists because refusing was invisible: `send` returned false, the caller
    /// returned, and the prompt simply did not go. Strict harness ownership makes
    /// that reachable in ordinary use — a legacy record whose harness could not be
    /// inferred, a CLI that is not logged in, and the seconds after launch while
    /// the catalogue probe is still out, during which readiness is `.checking` for
    /// every harness. Silence there reads as a broken app.
    func sendRefusal(for id: AgentID) -> String? {
        guard let record = records[id] else { return nil }
        return Self.sendRefusal(record: record)
    }

    /// The rule itself, over a record and a catalogue — pure enough to pin every
    /// refusing state in the matrix without a store, a home directory, or the
    /// shared catalogue's global state.
    static func sendRefusal(record: AgentRecord, catalog: AgentModelCatalog = .shared) -> String? {
        guard let harness = record.harness else {
            return "This agent's harness ownership is unresolved. Choose Claude Code, Codex, or Pi and a model it owns."
        }
        let snapshot = catalog.snapshot(for: harness)
        guard snapshot.readiness.canRun else {
            switch snapshot.readiness {
            case .checking:
                return "\(harness.rawValue) is still starting up — try again in a moment."
            case .missing:
                return "\(harness.rawValue) is not installed. Open Help ▸ Environment Setup…"
            case .loggedOut:
                return "\(harness.rawValue) is logged out. Sign in with its own login command, then try again."
            case .unavailable(let reason):
                return "\(harness.rawValue) is unavailable (\(reason)). Open Help ▸ Environment Setup…"
            case .ready:
                return nil
            }
        }
        guard snapshot.models.contains(record.model) else {
            return "\(harness.rawValue) cannot run \(record.model). Pick a model this harness owns."
        }
        return nil
    }

    /// Text-only compatibility wrapper for existing callers and checks.
    @discardableResult
    func send(_ prompt: String, to id: AgentID) -> Bool {
        send(AgentPrompt(prompt), to: id)
    }

    private nonisolated static func visibleNamingText(
        from prompt: AgentPrompt,
        model: String?,
        role: String?,
        id: UUID?
    ) -> String? {
        let bounded = String(prompt.text.prefix(AgentNameOneShot.maximumPromptLength))
        // B7.0: a COMMAND INVOCATION IS NOT A NAME, and this is the only place
        // that can tell — the redaction below strips the leading `/compact` as
        // path-shaped text, so by the time the shared resolver sees the prompt
        // the command is already gone and only its ARGUMENTS are left. That is
        // what named a tile "focus on the auth work" after `/compact focus on
        // the auth work`, with `displayNameSource` left at `.prompt` so the
        // funnel never re-armed and no later prompt could rename it.
        //
        // A bare `/clear` was accidentally safe for the same reason — the
        // redactor ate the whole thing — which is exactly why the rule needs to
        // be stated rather than inherited from a side effect.
        guard !AgentName.isCommandInvocation(bounded) else { return nil }
        // Reject identifiers before stripping local-path-shaped text. Model ids
        // contain a slash, so sanitizing first could turn `provider/model` into
        // the plausible-looking title `provider` and bypass the shared guard.
        guard let original = AgentName.normalizedLabel(bounded),
              !AgentName.isIdentifier(original, model: model, role: role, id: id) else {
            return nil
        }
        let visible = SecretRedactor.removeLocalPathReferences(bounded)
        return AgentName.normalizedLabel(visible)
    }

    /// Terminates the in-flight runner and records the stop on the agent's stream.
    /// `.sessionStateChanged(.stopped)` is what the tile's status derivation reads,
    /// and it is persist-worthy, so the stored record's `lastActivityAt` moves too.
    func stop(_ id: AgentID) {
        guard records[id] != nil else {
            warn("AgentSupervisor.stop: no agent \(id.rawValue.uuidString)")
            return
        }
        // M1.7: recorded BEFORE the runner is told, so the unwinding `run()` can
        // never lose the race back to `deliver`.
        stopRequestedAgents.insert(id)
        runners[id]?.stop()
        runners[id] = nil
        // Normally Stop is offered only for an active turn. Keeping teardown
        // complete here also makes programmatic stop/archive paths safe if an
        // idle persistent session exists.
        idleSessionRunners.removeValue(forKey: id)?.stop()
        // T6: the parent's process group is what runs its delegated children, so
        // stopping the parent kills them. Keeping a watcher polling their run
        // directories afterwards would poll files nothing will ever write again.
        stopObservedRuns(for: id)
        interruptWorkingClaudeMirroredChildren(of: id)
        notifyTurnCapabilitiesChanged(id)
        deliver(.sessionStateChanged(.stopped), to: id)
    }

    /// Stops every agent with a prompt in flight. The app calls this when it quits
    /// (`applicationWillTerminate`), which is P2A.6's watch-out: a headless agent has
    /// no tile to close and no surface to stop it from until the Phase 3 inbox, so
    /// without this its Pi process outlives the session that started it. Iterates a
    /// snapshot because `stop` mutates `runners`.
    func stopAll() {
        for id in Array(runners.keys) { stop(id) }
        for runner in idleSessionRunners.values { runner.stop() }
        idleSessionRunners.removeAll()
        // `stop(id)` reaches `stopObservedRuns(for: id)` only for a parent still
        // in `runners`. A parent whose runner had already exited but whose
        // observed children were still being tailed (B: quiet-forever until the
        // liveness sweep or a relaunch) would otherwise survive `stopAll` with a
        // live watcher and timer outliving the session that started it.
        for parent in Array(observedRunWatchers.keys) { stopObservedRuns(for: parent) }
    }

    // MARK: - Orchestration (P2D.2)

    /// How deep a chain of spawns may go. The root agent a human started is depth 0,
    /// the worker it asks for is depth 1, and that worker's own worker is depth 2 —
    /// which is the last one: an agent already at the cap cannot spawn.
    ///
    /// A cap exists because the request is MODEL-AUTHORED (the packet's watch-out): a
    /// prompt that tells a worker to delegate produces workers that delegate, and
    /// every one of them is a Pi process. Nothing else in the app bounds that.
    nonisolated static let maxSpawnDepth = 2
    /// The shipped breadth cap retained only as a regression-fixture width. It
    /// is not an admission policy anymore; production defaults to unlimited.
    static let formerChildrenPerParentCap = 4
    /// Why a `spawn_agent` call did not produce an agent. Carries counts and caps
    /// only — never the request's `prompt` or a path — because the refusal is
    /// SURFACED IN THE PARENT'S TRANSCRIPT, which is an `AgentRuntimeEvent`, i.e. the
    /// far side of the boundary `SpawnRequest` stays off (I5).
    enum SpawnRefusal: Equatable {
        case unknownParent
        case depthCapped(depth: Int, cap: Int)
        case childCapped(children: Int, cap: Int)
        case worktreeFailed
        /// P2D.3 — the request named a role this project does not define, or defines
        /// with a model/thinking value Pi would have to guess at.
        case roleUnresolved
        /// The project declares NO roles at all for this harness, so every named
        /// role would refuse. Split from `roleUnresolved` because the two have
        /// different fixes and only this one is actionable: "the requested role is
        /// not defined in this project" reads as a typo when the truth is that the
        /// project has no `.pi/agents` directory. Observed live on 2026-08-25.
        case projectDeclaresNoRoles(directory: String)
        /// C12 — the parent runs codex. `codex exec --json` (measured, `.plans/46`)
        /// emits no wire representation for subagent activity at all: even with
        /// `features.multi_agent_v2=true` set and delegation genuinely happening,
        /// Array receives nothing about the child on the transport it runs. The
        /// honest refusal is about OBSERVABILITY, not capability — codex itself can
        /// spawn; Array cannot see it happen, so it will not pretend to run it.
        case codexSubagentsUnobservable
        /// C12 — the parent is a claude `Agent` subagent Array only mirrors
        /// (`AgentCapabilities.observedReadOnly`): read-only transcript, not
        /// locally managed, no runner. There is nothing for a spawn to go through.
        case observedParentCannotSpawn
        /// What the parent's transcript says. `worktreeFailed` deliberately does not
        /// name the git error: `WorktreeManager`'s failures quote paths. `roleUnresolved`
        /// deliberately does not name the role id either — not because an id is unsafe
        /// (it is not; P2D.3's watch-out says ids may be published) but because the
        /// P2D.2 witness holds the requested role out of every event on the parent's
        /// stream, and a reason that echoes it would be the one hole in that.
        var reason: String {
            switch self {
            case .unknownParent:
                return "the requesting agent is not known to this session"
            case let .projectDeclaresNoRoles(directory):
                // The DIRECTORY name, never the requested role id — the P2D.2
                // witness holds the role out of every event on the parent's stream
                // and a reason that echoed it would be the one hole in that. A
                // relative directory name is project structure, not host state.
                return "this project defines no agent roles — add one to \(directory) to delegate"
            case let .depthCapped(depth, cap):
                return "spawn depth \(depth) exceeds the cap of \(cap)"
            case let .childCapped(children, cap):
                return "this agent already has \(children) child agents (cap \(cap))"
            case .worktreeFailed:
                return "its isolated checkout could not be created"
            case .roleUnresolved:
                return "the requested role is not defined in this project"
            case .codexSubagentsUnobservable:
                return "Array cannot observe codex subagents on the transport it runs"
            case .observedParentCannotSpawn:
                return "this agent is mirrored, not run, and has no runner to spawn through"
            }
        }
    }

    // MARK: - Observed pi runs (T6)

    /// One bound `delegate_agent` run: which child it feeds, how far it has been
    /// read, and the translator carrying that child's stream position.
    private struct ObservedRunBinding {
        /// Stored directly rather than re-derived via `records[childID]?.parentAgentID`
        /// on every use: the child record may not exist yet (see `bindObservedRun`),
        /// and a lookup that returns nil in that window used to read as "not mine"
        /// and get the parent's only watcher torn down out from under a still-open
        /// binding — see `refreshObservedRunWatchers`.
        let parent: AgentID
        let childID: AgentID
        let toolUseID: String
        var consumedEventCount = 0
        /// The last `run.json` this binding has seen. Set from every snapshot
        /// `ingestObservedRunUpdate` processes, and read by `sweepObservedRunLiveness`
        /// to reach a terminal state WITHOUT depending on the directory changing
        /// again — see that function.
        var lastKnownPid: Int?
        var lastKnownStatus: RunArtifact.Status?
        /// Set when the translated artifact stream itself supplied a terminal
        /// boundary. Every non-stream terminal path consults this before minting
        /// its fallback, so a child receives exactly one completion.
        var terminalDelivered = false
        /// Per child, because a `PiEventTranslator` carries stream state (thread id,
        /// turn counter). One shared translator would interleave two children's
        /// turns into one.
        ///
        /// `replayingCompletedMessages` is the whole reason this path can show the
        /// child's prose: the extension rewrites `events.jsonl` when the run ends
        /// and the rewrite strips every `message_update`, so a completed run holds
        /// its text only in `message_end`.
        var translator: PiEventTranslator
    }

    /// Bind a delegated run to the child it belongs to, and start watching for it.
    ///
    /// Called on the main actor from the runner's report. The child may not exist
    /// yet — `tool_execution_end` can be translated before the main-actor hop that
    /// adopted the child from `tool_execution_start` has run — so the binding is
    /// keyed by the tool call id and `deliverSubagentEvent` buffers anything that
    /// arrives early, exactly as the claude path does. Provider-owned children
    /// are always adopted, so a later run update always has a destination.
    private func bindObservedRun(_ handle: ObservedRunHandle, parent: AgentID) {
        guard let parentRecord = records[parent] else { return }
        let childID = AgentID(rawValue: AgentRecord.observedChildID(
            parentAgentID: parent.rawValue, toolUseID: handle.toolUseID))
        // Re-observation converges: the same (parent, toolUseID) pair rebinds the
        // same cursor rather than starting a second one. Keyed on the tool call id
        // and never on the runId, which embeds a timestamp and a random suffix.
        if observedRunBindings[handle.runId] != nil { return }
        observedRunBindings[handle.runId] = ObservedRunBinding(
            parent: parent,
            childID: childID,
            toolUseID: handle.toolUseID,
            translator: PiEventTranslator(
                workingDirectory: URL(fileURLWithPath: parentRecord.lastObservedWhere, isDirectory: true),
                replayingCompletedMessages: true))
        // The runId is persisted on the CHILD, in the existing provider-neutral
        // field, so a relaunch can reconcile the run's fate without a schema
        // change. It is deliberately NOT used to resume tailing — see
        // `reconcileObservedRunsAfterRestore`.
        if var child = records[childID], child.providerSessionId != handle.runId {
            child.providerSessionId = handle.runId
            records[childID] = child
            try? upsertRecord(child)
        }
        startObservedRunWatcher(for: parent, parentRecord: parentRecord)
        ensureObservedRunLivenessSweepRunning()
    }

    /// One watcher per PARENT, not per child: the run store is a single directory
    /// and four children of one parent are four subdirectories of it.
    private func startObservedRunWatcher(for parent: AgentID, parentRecord: AgentRecord) {
        let root = URL(fileURLWithPath: parentRecord.lastObservedWhere, isDirectory: true)
            .appendingPathComponent(".pi/agent-runs", isDirectory: true)
        // Scoped to THIS parent's own bindings. An unfiltered set (every open
        // binding across every parent) would hand a parent's watcher run ids that
        // live under a different parent's `.pi/agent-runs` root entirely, and it
        // also breaks re-arming: closing then rebinding a run under this parent
        // must not depend on some OTHER parent's bindings for the watcher to see
        // it as "mine".
        let watched = Set(observedRunBindings.filter { $0.value.parent == parent }.keys)
        if let existing = observedRunWatchers[parent] {
            existing.setWatchedRunIds(watched)
            return
        }
        let watcher = RunArtifactsWatcher(rootURL: root)
        observedRunWatchers[parent] = watcher
        // MANDATORY, not a tuning knob: `.pi/agent-runs` accumulates a directory
        // per run forever (143 in Array's own checkout), and an unfiltered watcher
        // stats four paths in every one of them every 0.25s.
        watcher.setWatchedRunIds(watched)
        watcher.start { [weak self] update in
            DispatchQueue.main.async {
                self?.ingestObservedRunUpdate(update, parent: parent)
            }
        }
    }

    private func ingestObservedRunUpdate(_ update: RunArtifactsWatcherUpdate, parent: AgentID) {
        for (runId, snapshot) in update.snapshots {
            guard var binding = observedRunBindings[runId] else { continue }
            let events = snapshot.events.events
            // The file was REWRITTEN, not appended: the extension compacts it at
            // completion via temp-file + rename, which also changes the inode
            // (`RunEventsArtifact.rewrote`, computed from that inode by the
            // watcher). `events` here is the FRESH file's content from byte 0 —
            // not a continuation of what this binding already delivered — so
            // slicing at `consumedEventCount` would misread whatever the old
            // cursor's position happens to land on inside the new file. A count
            // comparison alone cannot tell this apart from an ordinary append
            // that grew past the cursor (a compaction that removes fewer lines
            // than were already consumed is NOT shorter than the cursor), which
            // is exactly the bug this replaces. Close instead: losing a few
            // post-compaction lines beats duplicating a transcript.
            if snapshot.events.rewrote {
                // The compacted file is a new history and must not be replayed,
                // but terminal run.json is still authoritative. Close the child
                // before dropping the only binding that knows its destination.
                finishObservedRun(
                    runId: runId, binding: binding, status: snapshot.run.status)
                continue
            }
            if events.count > binding.consumedEventCount {
                // A partial trailing line needs no special handling: it fails to
                // parse, is counted as bad, and is simply absent from this array —
                // so it arrives at this same index on the next read.
                for artifact in events[binding.consumedEventCount..<events.count] {
                    for event in binding.translator.translate(line: artifact.rawJSON) {
                        if case .turnCompleted = event { binding.terminalDelivered = true }
                        deliverSubagentEvent(
                            event, parent: parent, toolUseID: binding.toolUseID)
                    }
                }
                binding.consumedEventCount = events.count
            }
            binding.lastKnownPid = snapshot.run.pid
            binding.lastKnownStatus = snapshot.run.status
            if snapshot.run.isFinished() {
                finishObservedRun(
                    runId: runId, binding: binding, status: snapshot.run.status)
            } else {
                observedRunBindings[runId] = binding
            }
        }
        refreshObservedRunWatchers()
        stopObservedRunLivenessSweepIfIdle()
    }

    /// Deliver the terminal boundary owed by one observed Pi run, then remove
    /// its binding. All live closure paths converge here so status mapping and
    /// exactly-once behavior cannot drift.
    private func finishObservedRun(
        runId: String,
        binding: ObservedRunBinding,
        status: RunArtifact.Status,
        errorMessage: String? = nil
    ) {
        if !binding.terminalDelivered {
            let outcome = Self.observedRunOutcome(for: status)
            deliverSubagentEvent(.turnCompleted(
                threadId: Self.threadId(for: binding.childID),
                turnId: "\(Self.threadId(for: binding.childID))#observed-\(runId)",
                outcome: outcome,
                errorMessage: errorMessage ?? Self.observedRunErrorMessage(
                    status: status, outcome: outcome)
            ), parent: binding.parent, toolUseID: binding.toolUseID)
        }
        observedRunBindings.removeValue(forKey: runId)
        refreshObservedRunWatchers()
        stopObservedRunLivenessSweepIfIdle()
    }

    private nonisolated static func observedRunOutcome(
        for status: RunArtifact.Status
    ) -> TurnOutcome {
        switch status {
        case .done: return .completed
        case .failed: return .failed
        case .queued, .running, .killed, .stale, .unknown: return .interrupted
        }
    }

    private nonisolated static func observedRunErrorMessage(
        status: RunArtifact.Status, outcome: TurnOutcome
    ) -> String? {
        guard outcome != .completed else { return nil }
        return "This delegated run ended with status \(status.rawValue)."
    }

    /// Narrow every watcher to the runs still open, and stop the ones with none —
    /// so a parent that finished delegating stops polling entirely.
    private func refreshObservedRunWatchers() {
        let open = Set(observedRunBindings.keys)
        for (parent, watcher) in observedRunWatchers {
            let mine = open.filter { runId in observedRunBindings[runId]?.parent == parent }
            if mine.isEmpty {
                watcher.stop()
                observedRunWatchers.removeValue(forKey: parent)
            } else {
                watcher.setWatchedRunIds(Set(mine))
            }
        }
    }

    /// A watcher only notices a run ending when its DIRECTORY changes. If the
    /// child process is killed outright, or the extension dies before writing a
    /// terminal `run.json`, the directory goes quiet forever — no update ever
    /// reaches `ingestObservedRunUpdate` again, so its `isFinished()` check (the
    /// one place a binding closes on its own) never runs, and a 0.25s timer polls
    /// a dead run for the rest of the app's life while the child tile sits stuck
    /// mid-turn.
    ///
    /// This reaches a terminal state a different way: the pid, not the
    /// directory, using the same liveness probe `RunArtifact.isFinished` and
    /// `reconcileObservedRunsAfterRestore` use. Deliberately conservative — a
    /// binding is only ever checked here once it has ALREADY reported a pid and a
    /// non-terminal status, so a run that is merely slow to produce its first
    /// output (no snapshot processed yet) is never closed early.
    private func sweepObservedRunLiveness() {
        guard !observedRunBindings.isEmpty else {
            observedRunLivenessTimer?.cancel()
            observedRunLivenessTimer = nil
            return
        }
        var didClose = false
        for (runId, binding) in observedRunBindings {
            guard let pid = binding.lastKnownPid, pid > 0 else { continue }
            switch binding.lastKnownStatus {
            case .some(.running), .some(.queued): break
            default: continue
            }
            guard !RunArtifact.processIsAlive(pid) else { continue }
            didClose = true
            finishObservedRun(
                runId: runId,
                binding: binding,
                status: .stale,
                errorMessage: "This delegated run ended unexpectedly (its process is no longer running).")
        }
        if didClose {
            refreshObservedRunWatchers()
            stopObservedRunLivenessSweepIfIdle()
        }
    }

    private func ensureObservedRunLivenessSweepRunning() {
        guard observedRunLivenessTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        // `@Sendable` here is load-bearing, same as `SessionObserver.scheduleDetectionTimer`:
        // without it, Swift infers this closure literal (written inside an
        // `@MainActor` method) as MainActor-isolated by default, and the runtime
        // traps (`_dispatch_assert_queue_fail`) the instant GCD invokes it on
        // the timer's own queue instead of the main queue. `Task { @MainActor in }`
        // is the real, explicit hop back onto the actor.
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.sweepObservedRunLiveness()
            }
        }
        observedRunLivenessTimer = timer
        timer.resume()
    }

    /// Stop watching this parent's runs, and forget their cursors. Safe to call
    /// on an id that is a CHILD (see `stopObservedRun(forChild:)`) or has no
    /// observed runs at all — both are no-ops.
    func stopObservedRuns(for parent: AgentID) {
        observedRunWatchers.removeValue(forKey: parent)?.stop()
        for (runId, binding) in observedRunBindings where binding.parent == parent {
            observedRunBindings.removeValue(forKey: runId)
        }
        stopObservedRunLivenessSweepIfIdle()
    }

    /// The other direction: `id` is the CHILD being torn down (e.g. archived on
    /// its own, independent of its parent), not the parent. Closes just that
    /// child's own binding, leaving its siblings' tailing untouched.
    private func stopObservedRun(forChild childID: AgentID) {
        guard let runId = observedRunBindings.first(where: { $0.value.childID == childID })?.key
        else { return }
        observedRunBindings.removeValue(forKey: runId)
        refreshObservedRunWatchers()
        stopObservedRunLivenessSweepIfIdle()
    }

    private func stopObservedRunLivenessSweepIfIdle() {
        guard observedRunBindings.isEmpty else { return }
        observedRunLivenessTimer?.cancel()
        observedRunLivenessTimer = nil
    }

    /// After a restore, settle what happened to every observed run — and never
    /// resume tailing one.
    ///
    /// The cursor is deliberately not persisted. The child's events were already
    /// written to its transcript as they were delivered, so replaying the file
    /// would duplicate a transcript. And Array's own parent `pi` process is what
    /// writes these runs, so an app relaunch GUARANTEES the run is defunct: a
    /// `status: "running"` that survives a restart is stale, and believing it is
    /// the resurrection bug — Array would wait forever for a child that died with
    /// the previous session. One `run.json` read per child, never `events.jsonl`,
    /// and no watcher.
    func reconcileObservedRunsAfterRestore() {
        for (childID, record) in records
        where record.capabilities == .observedReadOnly && record.harness == .pi {
            guard let runId = record.providerSessionId,
                  let parentID = record.parentAgentID,
                  let parentRecord = records[parentID]
            else { continue }
            let runJSON = URL(fileURLWithPath: parentRecord.lastObservedWhere, isDirectory: true)
                .appendingPathComponent(".pi/agent-runs", isDirectory: true)
                .appendingPathComponent(runId, isDirectory: true)
                .appendingPathComponent("run.json", isDirectory: false)
            let run = RunArtifactsReader.readRunJSON(at: runJSON)
            // Restore has no surviving ownership generation for this provider-
            // owned child and deliberately does not resume its event cursor or
            // install a watcher. Therefore even `queued`/`running` is terminal
            // here: its PID may belong to an orphan or have been reused, and mere
            // process existence cannot prove that this restored record owns it.
            // Live bindings still use `isFinished()` and the liveness sweep; this
            // fail-closed rule is specific to crossing an app-session boundary.
            noteObservedRunEndedBeforeRestore(childID: childID, status: run.status)
        }
    }

    /// Say out loud that a delegated run did not survive the restart, rather than
    /// leaving a child tile apparently mid-turn forever.
    private func noteObservedRunEndedBeforeRestore(
        childID: AgentID, status: RunArtifact.Status
    ) {
        guard observedRunsReconciled.insert(childID).inserted else { return }
        let outcome = Self.observedRunOutcome(for: status)
        deliver(.turnCompleted(
            threadId: Self.threadId(for: childID),
            turnId: "\(Self.threadId(for: childID))#observed",
            outcome: outcome,
            errorMessage: outcome == .completed
                ? nil
                : "This delegated run ended with the previous session (\(status.rawValue))."
        ), to: childID)
    }

    /// Routes one frame of a claude subagent's work to the child it belongs to.
    ///
    /// The child is found by re-deriving its id, never by looking up a table the
    /// announcement had to populate first. Claude does not promise that the
    /// `Agent` tool_use block is flushed before the child's first frame, and a
    /// race there would silently drop the opening of every child transcript. If
    /// the record does not exist yet the announcement simply has not landed, so
    /// the frame is held and replayed once it does.
    private func deliverSubagentEvent(_ event: AgentRuntimeEvent, parent: AgentID, toolUseID: String) {
        let childID = AgentID(rawValue: AgentRecord.observedChildID(
            parentAgentID: parent.rawValue, toolUseID: toolUseID))
        guard records[childID] != nil else {
            pendingSubagentEvents[childID, default: []].append(event)
            return
        }
        flushPendingSubagentEvents(for: childID)
        deliver(event.withThreadId(Self.threadId(for: childID)), to: childID)
    }

    /// Frames that arrived before their child's record existed.
    /// Bound `delegate_agent` runs, keyed by runId. See `bindObservedRun`.
    private var observedRunBindings: [String: ObservedRunBinding] = [:]
    /// One watcher per parent over its `.pi/agent-runs` directory.
    private var observedRunWatchers: [AgentID: RunArtifactsWatcher] = [:]
    /// Children already told their run died with the last session, so a second
    /// restore pass cannot say it twice.
    private var observedRunsReconciled: Set<AgentID> = []
    /// One shared timer sweeping every open `ObservedRunBinding` for a dead pid —
    /// see `sweepObservedRunLiveness`. Lazily started by the first binding, torn
    /// down by `stopObservedRunLivenessSweepIfIdle` once none remain.
    private var observedRunLivenessTimer: DispatchSourceTimer?
    private var pendingSubagentEvents: [AgentID: [AgentRuntimeEvent]] = [:]
    private var providerThreadAgentRoutes: [AgentID: [String: AgentID]] = [:]
    private var pendingProviderThreadEvents: [AgentID: [String: [AgentRuntimeEvent]]] = [:]

    private func handleProviderSubagentActivity(
        _ activity: ProviderSubagentActivity,
        rootAgentID: AgentID
    ) {
        switch activity {
        case let .primaryThread(providerThreadID):
            providerThreadAgentRoutes[rootAgentID, default: [:]][providerThreadID] = rootAgentID

        case let .childAnnounced(parentProviderThreadID, childProviderThreadID, sourceItemID, displayLabel):
            guard let parentAgentID = providerThreadAgentRoutes[rootAgentID]?[parentProviderThreadID]
            else { return }
            let request = SpawnRequest(
                role: nil,
                prompt: "Codex delegated work",
                isolated: false,
                sourceItemID: sourceItemID,
                observedOnly: true,
                displayLabel: displayLabel
            )
            guard let childAgentID = handleSpawnRequest(request, from: parentAgentID) else { return }
            providerThreadAgentRoutes[rootAgentID, default: [:]][childProviderThreadID] = childAgentID
            let pending = pendingProviderThreadEvents[rootAgentID]?
                .removeValue(forKey: childProviderThreadID) ?? []
            for event in pending {
                deliver(event.withThreadId(Self.threadId(for: childAgentID)), to: childAgentID)
            }

        case let .threadEvent(providerThreadID, event):
            guard let target = providerThreadAgentRoutes[rootAgentID]?[providerThreadID] else {
                pendingProviderThreadEvents[rootAgentID, default: [:]][providerThreadID, default: []]
                    .append(event)
                return
            }
            // Primary events already travel through AgentRunning.onEvent. This
            // channel is for provider-owned descendants only.
            guard target != rootAgentID else { return }
            deliver(event.withThreadId(Self.threadId(for: target)), to: target)
        }
    }

    private func flushPendingSubagentEvents(for childID: AgentID) {
        guard let held = pendingSubagentEvents.removeValue(forKey: childID), !held.isEmpty
        else { return }
        let threadId = Self.threadId(for: childID)
        for event in held { deliver(event.withThreadId(threadId), to: childID) }
    }

    /// Mints the read-only record for a subagent the HARNESS runs.
    ///
    /// The whole design turns on `AgentCapabilities.observedReadOnly` — declared
    /// since P2 and, until now, used nowhere in production. A claude `Agent`
    /// subagent has no process of Array's, so it must never offer a composer or a
    /// working Stop; and it needs no new `AgentRuntimeEvent`, because
    /// `.childAgentSpawned` and the durable `agentReference` block already carry
    /// nesting for children Array owns. Minting a real record is what lets a
    /// harness-run child reuse all of it — `parentAgentID` alone then makes
    /// `InboxSort` nest it, `ChildRollup` count it, and the lineage overlay draw
    /// it, with no widening of the sync boundary anywhere.
    ///
    /// **Idempotent by construction.** The same child is announced again on every
    /// restore and re-observation, and the id is derived from
    /// `(parentAgentID, tool_use_id)`, so a second sighting converges on the same
    /// record instead of minting a duplicate.
    private func adoptObservedChild(
        _ request: SpawnRequest,
        from parentId: AgentID,
        parent: AgentRecord
    ) -> AgentID? {
        guard let toolUseID = request.sourceItemID, !toolUseID.isEmpty else {
            // Without the announcing call's id there is no stable identity, and a
            // child Array cannot re-identify later is not worth minting.
            let toolName = parent.harness == .claudeCode ? "Agent" : "delegate_agent"
            return refuseSpawn(.roleUnresolved, for: parentId, toolName: toolName)
        }
        let childID = AgentID(rawValue: AgentRecord.observedChildID(
            parentAgentID: parentId.rawValue, toolUseID: toolUseID))
        let boundRunID = observedRunBindings.first(where: {
            $0.value.parent == parentId
                && $0.value.childID == childID
                && $0.value.toolUseID == toolUseID
        })?.key
        if var existing = records[childID] {
            if let boundRunID, existing.providerSessionId != boundRunID {
                existing.providerSessionId = boundRunID
                records[childID] = existing
                persist(existing)
            }
            return childID
        }

        // This child already exists inside the provider. Applying Array's spawn
        // caps here cannot prevent work; it only makes the running child
        // invisible and leaves its transcript with nowhere to land. Provider-
        // owned children are therefore always adopted and restored.

        let projectRoot = Self.repositoryRoot(of: parent)
        // `prompt: nil` deliberately: the child is already running its task inside
        // claude, and sending it one here would start a SECOND conversation that
        // Array would then be unable to stop.
        _ = makeAgent(
            id: childID,
            role: request.role,
            prompt: nil,
            cwd: projectRoot,
            projectRoot: projectRoot,
            checkoutRoot: projectRoot,
            homeRelativePath: parent.homeRelativePath,
            worktreeId: nil,
            worktreeBranch: nil,
            harness: parent.harness ?? AgentHarnessConfig.resolved(),
            model: parent.model,
            thinking: parent.thinking,
            projectId: parent.projectId,
            parentAgentID: parentId,
            // NOT the tool_use id. That is an identity, not a name, and letting
            // it reach the naming funnel is what titled every child tile
            // `toolu_01NFqGS…`. The label the model wrote for its own call is
            // the honest title; its role is the fallback; and if it gave
            // neither, the parent-relative ordinal already handles it.
            sourceItemId: nil,
            tileId: nil,
            displayName: request.displayLabel ?? request.role
        )
        guard var child = records[childID] else { return nil }
        child.capabilities = .observedReadOnly
        // `tool_execution_end` may bind before the announcing start reaches the
        // main actor. Persist the binding's run identity in either order so a
        // restored supervisor can reconcile terminal run.json.
        child.providerSessionId = boundRunID ?? child.providerSessionId
        records[childID] = child
        persist(child)
        // Anything that arrived before the record existed replays now, in order.
        flushPendingSubagentEvents(for: childID)
        deliver(.childAgentSpawned(
            threadId: Self.threadId(for: parentId),
            childAgentID: childID.rawValue,
            parentAgentID: parentId.rawValue,
            displayName: child.humanDisplayName,
            sourceItemID: toolUseID,
            provider: (parent.harness ?? AgentHarnessConfig.resolved()).rawValue,
            spawnedAt: Date()
        ), to: parentId)
        return childID
    }

    /// Turns an observed `spawn_agent` call into a real child agent.
    ///
    /// THE TOOL CALL IS THE API (P2D.1): the extension is inert, so this is the only
    /// place a child is created. The child inherits the parent's project always, and
    /// the parent's model and thinking level unless the ROLE it was asked for declares
    /// its own (P2D.3) — a `code-scout` runs what `.pi/agents/code-scout.md` says it
    /// runs. A role id this project does not define is REFUSED, not defaulted: the
    /// orchestrator asked for a specific worker, and quietly starting a generic one
    /// would answer a question nobody asked.
    ///
    /// `parentAgentID` is set on the child's record, which is what makes P2D.4's
    /// nesting and P2D.5's roll-up possible from the store alone.
    ///
    /// Returns nil on a refusal, having said so in the parent's transcript.
    @discardableResult
    func handleSpawnRequest(_ request: SpawnRequest, from parentId: AgentID) -> AgentID? {
        guard let parent = records[parentId] else {
            return refuseSpawn(.unknownParent, for: parentId)
        }
        // C7: an OBSERVED child is not a spawn at all. claude has already started
        // it inside itself by the time the `Agent` call reaches us, so there is
        // nothing to launch — only a record to mint so the child's own frames have
        // somewhere to land and the parent gets a chip.
        if request.observedOnly {
            return adoptObservedChild(request, from: parentId, parent: parent)
        }
        // C12 — a mirrored subagent has no runner behind it at all: refuse before
        // even asking what harness it claims, since that field describes who
        // PRODUCED it, not something Array can spawn through.
        guard parent.capabilities != .observedReadOnly else {
            return refuseSpawn(
                .observedParentCannotSpawn, for: parentId,
                handle: request.sourceItemID, requestedRole: request.role)
        }
        guard let parentHarness = parent.harness else {
            warn("AgentSupervisor.handleSpawnRequest: child of \(parentId.rawValue.uuidString) not spawned: parent harness ownership is unresolved")
            return refuseSpawn(
                .roleUnresolved, for: parentId,
                handle: request.sourceItemID, requestedRole: request.role)
        }
        // C12 — codex delegation may genuinely be happening; Array's transport
        // (`codex exec --json`) has no wire representation for it, so refuse
        // honestly about observability rather than silently producing nothing or
        // claiming codex itself cannot spawn.
        guard parentHarness != .codex else {
            return refuseSpawn(
                .codexSubagentsUnobservable, for: parentId,
                handle: request.sourceItemID, requestedRole: request.role)
        }
        let depth = depth(of: parentId) + 1
        guard depth <= Self.maxSpawnDepth else {
            return refuseSpawn(
                .depthCapped(depth: depth, cap: Self.maxSpawnDepth), for: parentId,
                handle: request.sourceItemID, requestedRole: request.role)
        }
        let activeChildren = activeManagedChildren(of: parentId).count
        if let cap = maximumActiveManagedChildren(), activeChildren >= cap {
            return refuseSpawn(
                .childCapped(children: activeChildren, cap: cap), for: parentId,
                handle: request.sourceItemID, requestedRole: request.role)
        }
        // The role resolves against the PROJECT's registry, not the parent's possibly
        // isolated checkout — and after the caps, so a request that was going to be
        // refused anyway is refused for the reason that actually stopped it.
        let projectRoot = Self.repositoryRoot(of: parent)
        let resolvedRole: RoleRegistry.Resolution
        let registry = RoleRegistry(projectRoot: projectRoot)
        // A named role in a project with no roles is not a typo, and saying "the
        // requested role is not defined" invites reading it as one. Checked before
        // `resolve`, because resolve cannot tell the two apart.
        if request.role != nil, registry.definesNoRoles {
            return refuseSpawn(
                .projectDeclaresNoRoles(directory: RoleRegistry.directoryName(for: parentHarness)),
                for: parentId,
                handle: request.sourceItemID, requestedRole: request.role)
        }
        do {
            resolvedRole = try registry.resolve(
                roleId: request.role,
                inheriting: AgentModelConfig.Resolution(model: parent.model, thinking: parent.thinking)
            )
        } catch {
            warn("AgentSupervisor.handleSpawnRequest: child of \(parentId.rawValue.uuidString) not spawned: \(error)")
            return refuseSpawn(
                .roleUnresolved, for: parentId,
                handle: request.sourceItemID, requestedRole: request.role)
        }
        do {
            let childID = try spawn(
                role: request.role,
                prompt: request.prompt,
                cwd: projectRoot,
                harness: parentHarness,
                model: resolvedRole.model,
                thinking: resolvedRole.thinking,
                projectId: parent.projectId,
                parentAgentID: parentId,
                isolated: request.isolated
            )
            // The child record remembers the tool call that asked for it, so its
            // terminal `.turnCompleted` in `deliver` can rewrite the result file
            // even across a relaunch. Distinct from `sourceItemId` (fan-out and
            // naming semantics) on purpose.
            if let handle = SpawnResultFile.validatedHandle(request.sourceItemID),
               var child = records[childID] {
                child.spawnResultHandle = handle
                records[childID] = child
                persist(child)
                SpawnResultFile.write(
                    SpawnResultFile(
                        toolCallId: handle,
                        status: .spawned,
                        agentId: childID.rawValue,
                        role: request.role
                    ),
                    parentCwd: parent.cwd,
                    warn: warn
                )
            }
            let childName = records[childID]?.humanDisplayName ?? "Subagent"
            deliver(.childAgentSpawned(
                threadId: Self.threadId(for: parentId),
                childAgentID: childID.rawValue,
                parentAgentID: parentId.rawValue,
                displayName: childName,
                sourceItemID: request.sourceItemID,
                provider: parentHarness.rawValue,
                spawnedAt: Date()
            ), to: parentId)
            return childID
        } catch {
            // The isolated spawn refuses to fall back to the shared checkout (P2C.2),
            // so a failed worktree is a failed spawn — reported, not downgraded.
            warn("AgentSupervisor.handleSpawnRequest: child of \(parentId.rawValue.uuidString) not spawned: \(error)")
            return refuseSpawn(
                .worktreeFailed, for: parentId,
                handle: request.sourceItemID, requestedRole: request.role)
        }
    }

    /// Says the refusal on the parent's own stream, so an orchestrator's transcript
    /// shows the ask being declined rather than silently producing nothing.
    ///
    /// Shaped as a failed tool item because that is what it is — the parent called a
    /// tool and the tool's effect did not happen — and because the bridge already
    /// renders `.itemCompleted(.failed)` on the timeline while collapsing the title to
    /// a safe token on the way to the phone.
    private func refuseSpawn(
        _ refusal: SpawnRefusal,
        for parentId: AgentID,
        handle: String? = nil,
        requestedRole: String? = nil,
        toolName: String = SpawnRequest.toolName
    ) -> AgentID? {
        warn("AgentSupervisor: refusing \(toolName) from \(parentId.rawValue.uuidString) — \(refusal.reason)")
        guard let parent = records[parentId] else { return nil }
        let itemId = "spawn-refused-\(UUID().uuidString)"
        let thread = Self.threadId(for: parentId)
        deliver(.itemStarted(
            threadId: thread,
            itemId: itemId,
            kind: .error,
            title: "\(toolName) refused: \(refusal.reason)"
        ), to: parentId)
        deliver(.itemCompleted(
            threadId: thread,
            itemId: itemId,
            kind: .error,
            status: .failed
        ), to: parentId)
        // The MODEL's copy of the refusal. The transcript items above are
        // UI-only — the extension's `spawn_agent` has already answered
        // "spawned" by the time this runs, so without this file the model's
        // only view of a refused spawn is a success. `wait_agents` reads it as
        // a terminal status. Local file under the parent's own cwd, so echoing
        // the reason (already role-free, path-free) breaks no I5 boundary.
        if let handle = SpawnResultFile.validatedHandle(handle) {
            SpawnResultFile.write(
                SpawnResultFile(
                    toolCallId: handle,
                    status: .refused,
                    role: requestedRole,
                    reason: refusal.reason,
                    endedAt: Date()
                ),
                parentCwd: parent.cwd,
                warn: warn
            )
        }
        return nil
    }

    /// The agents this one spawned.
    func children(of id: AgentID) -> [AgentID] {
        records.values.filter { $0.parentAgentID == id }.map(\.id)
    }

    /// Children currently consuming an Array-managed turn slot. Durable child
    /// records and idle/completed sessions do not block future delegation.
    private func activeManagedChildren(of id: AgentID) -> [AgentID] {
        children(of: id).filter { childID in
            records[childID]?.capabilities != .observedReadOnly && runners[childID] != nil
        }
    }

    /// How many parents this agent has above it. Bounded by the record count so a
    /// store that somehow describes a cycle terminates instead of hanging the app.
    func depth(of id: AgentID) -> Int {
        var depth = 0
        var current = records[id]?.parentAgentID
        var seen: Set<AgentID> = [id]
        while let parent = current, !seen.contains(parent), depth <= records.count {
            seen.insert(parent)
            depth += 1
            current = records[parent]?.parentAgentID
        }
        return depth
    }

    /// The repository a child should be isolated FROM: the parent's own working
    /// directory, unless the parent is itself in an agent worktree, in which case it
    /// is the repository that worktree was created from.
    ///
    /// Without the second half a child of an isolated parent would get
    /// `<repo>/.worktrees/<parent>/.worktrees/<child>` — a worktree nested inside a
    /// worktree, which git allows and nothing else in this codebase expects (P2C.3's
    /// cleanup identifies an agent checkout by its `.worktrees/` container, and keeps
    /// its own guard because it DELETES; this one only chooses where to add).
    static func repositoryRoot(of record: AgentRecord) -> URL {
        if let projectRoot = record.projectRoot {
            return URL(fileURLWithPath: projectRoot, isDirectory: true)
        }
        let cwd = URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)
        guard record.worktreeBranch != nil,
              cwd.deletingLastPathComponent().lastPathComponent == WorktreeManager.containerDirectoryName
        else {
            return cwd
        }
        return cwd.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Immutable completion scope for one managed tile. The checkout root is the
    /// record's exact cwd—even when the Array project or parent repository is a
    /// broader directory—so Falcon-like nested repositories cannot leak outward.
    func completionContext(for agentID: AgentID) -> AgentCompletionContext? {
        guard let record = records[agentID], let harness = record.harness else { return nil }
        let checkoutRoot = URL(fileURLWithPath: record.checkoutRoot, isDirectory: true).standardizedFileURL
        return AgentCompletionContext(
            agentID: agentID,
            backend: harness,
            checkoutRoot: checkoutRoot,
            gitRoot: checkoutRoot,
            arrayProjectRoot: Self.repositoryRoot(of: record).standardizedFileURL,
            trustState: .trusted
        )
    }

    // MARK: - Fan-out (P2D.6)

    /// One selected work item: the identifier the source surface knows it by (a
    /// Linear row's `ENG-214`, a conductor task id) and the prompt its agent runs.
    struct FanOutItem: Equatable {
        let id: String
        let prompt: String
        /// Optional explicit title supplied by the source surface. When absent,
        /// the shared spawn ladder falls through prompt → source item → parent.
        let displayName: String?

        init(id: String, prompt: String, displayName: String? = nil) {
            self.id = id
            self.prompt = prompt
            self.displayName = displayName
        }
    }

    /// Why one selected item did not get an agent. Kept apart from `deferred`
    /// because they are different answers: deferred means "not yet, the batch is
    /// full", refused means "not at all".
    enum FanOutRefusal: Equatable {
        /// An agent from an earlier fan-out is already working this item. Spawning a
        /// second would give one row two isolated checkouts and two answers.
        case alreadyRunning(AgentID)
        /// `git worktree add` failed. Per P2C.2 the spawn fails rather than falling
        /// back to the shared checkout — N agents in one tree is what 2C exists to
        /// prevent, and a fan-out is the case that makes it certain.
        case worktreeFailed

        var reason: String {
            switch self {
            case .alreadyRunning:
                return "an agent is already working on it"
            case .worktreeFailed:
                return "its isolated checkout could not be created"
            }
        }
    }

    /// What one `fanOut` actually did. Every item is in exactly one of the three
    /// lists, which is the packet's no-silent-truncation rule made checkable:
    /// `launched.count + deferred.count + refused.count == items.count`.
    struct FanOutReport: Equatable {
        var launched: [(itemId: String, agentId: AgentID)] = []
        /// Past the cap. Still selected, still yours to run — nothing was started
        /// for them and nothing pretended otherwise.
        var deferred: [String] = []
        var refused: [(itemId: String, refusal: FanOutRefusal)] = []
        /// The cap this batch was held to. Reported so the surface can say what
        /// stopped it rather than inventing a number.
        var cap: Int = 0

        /// One line for the surface that asked. Names counts and the cap only — no
        /// prompt text, no path.
        var summary: String {
            var parts = ["started \(launched.count)"]
            if !deferred.isEmpty { parts.append("deferred \(deferred.count) past the cap of \(cap)") }
            if !refused.isEmpty { parts.append("refused \(refused.count)") }
            return parts.joined(separator: " · ")
        }

        static func == (lhs: FanOutReport, rhs: FanOutReport) -> Bool {
            lhs.cap == rhs.cap
                && lhs.deferred == rhs.deferred
                && lhs.launched.count == rhs.launched.count
                && zip(lhs.launched, rhs.launched).allSatisfy { $0 == $1 }
                && lhs.refused.count == rhs.refused.count
                && zip(lhs.refused, rhs.refused).allSatisfy { $0 == $1 }
        }
    }

    /// How many agents ONE fan-out may start. Selecting thirty rows must not start
    /// thirty Pi processes and thirty worktrees; the rest come back as `deferred`.
    /// Human-triggered queue batching stays bounded independently from provider
    /// delegation. It is not a per-parent lifetime cap.
    static let maxFanOutBatch = 4

    /// Called when an agent that was fanned out for an item finishes a turn
    /// successfully: `(itemId, agentId)`. The source surface checks the item off —
    /// the supervisor does not know what "done" means for a Linear row or a
    /// conductor task, and guessing would put queue semantics in here.
    var onFanOutItemCompleted: ((String, AgentID) -> Void)?

    /// Observers of turn-capability changes that no runtime event carries: the
    /// runner slot being taken or freed. The Pi process prints its terminal events
    /// before it exits, so the slot frees strictly after the last event a view will
    /// ever ingest — without this seam a view's cached `turnSnapshot` stays
    /// `canSend == false` forever (P5.5 live finding). Observers re-read
    /// `turnSnapshot(for:)`; nothing is fabricated onto the event stream. Token
    /// per observer because every attached agent tile subscribes.
    /// Agents whose in-flight turn was deliberately stopped, cleared when the next
    /// prompt starts a new turn. M1.7 (`.plans/46`) — see the catch in `send`.
    private var stopRequestedAgents: Set<AgentID> = []

    private var turnCapabilityObservers: [UUID: (AgentID) -> Void] = [:]

    @discardableResult
    func addTurnCapabilitiesObserver(_ observe: @escaping (AgentID) -> Void) -> UUID {
        let token = UUID()
        turnCapabilityObservers[token] = observe
        return token
    }

    func removeTurnCapabilitiesObserver(_ token: UUID) {
        turnCapabilityObservers[token] = nil
    }

    private func notifyTurnCapabilitiesChanged(_ id: AgentID) {
        for observe in turnCapabilityObservers.values { observe(id) }
    }

    /// Items whose agent has reported a completed turn, so a surface that rebuilds
    /// its rows (or one that attaches after the fact) can still draw them checked.
    private(set) var completedFanOutItems: Set<String> = []

    /// N items in, one agent per item out, each with the item's own prompt and —
    /// when `isolated` — its own worktree.
    ///
    /// Siblings by default: `parentAgentID` is nil, because a human selecting rows
    /// is not an agent. Passing one makes them children of the orchestrator that
    /// asked, and the batch is then ALSO held to whatever room that parent has left
    /// under the configured active-child limit — otherwise a fan-out would be the
    /// way around a limit that `handleSpawnRequest` enforces one spawn at a time.
    @discardableResult
    func fanOut(
        items: [FanOutItem],
        role: String?,
        cwd: URL,
        harness: AgentHarness = AgentHarnessConfig.resolved(),
        model: String,
        thinking: String,
        projectId: UUID? = nil,
        parentAgentID: AgentID? = nil,
        isolated: Bool = true
    ) -> FanOutReport {
        var report = FanOutReport()
        var cap = Self.maxFanOutBatch
        if let parentAgentID, let maximumActiveManagedChildren = maximumActiveManagedChildren() {
            cap = min(cap, max(0, maximumActiveManagedChildren - activeManagedChildren(of: parentAgentID).count))
        }
        report.cap = cap

        for item in items {
            // The refusal is decided BEFORE the cap, so an item that was never going
            // to run does not consume a slot a runnable one could have used.
            if let existing = agent(forSourceItem: item.id) {
                report.refused.append((item.id, .alreadyRunning(existing)))
                continue
            }
            guard report.launched.count < cap else {
                report.deferred.append(item.id)
                continue
            }
            do {
                // C2: `harness` was accepted by this function and never forwarded,
                // so every fan-out child silently took `AgentHarnessConfig.resolved()`
                // — the SETTINGS default — regardless of what the caller asked for
                // or what the parent was running. Settings seed new agents; they do
                // not get to re-decide an existing one's runner.
                let id = try spawn(
                    role: role,
                    prompt: item.prompt,
                    cwd: cwd,
                    harness: harness,
                    model: model,
                    thinking: thinking,
                    projectId: projectId,
                    parentAgentID: parentAgentID,
                    sourceItemId: item.id,
                    isolated: isolated,
                    displayName: item.displayName
                )
                report.launched.append((item.id, id))
                // C2: and `fanOut` never emitted this, so a fan-out child got
                // durable parentage in the record and NO chip in the parent's
                // transcript — the one surface where an orchestrator can see what
                // it started. `handleSpawnRequest` has always emitted it; the two
                // spawn paths simply disagreed.
                if let parentAgentID {
                    deliver(.childAgentSpawned(
                        threadId: Self.threadId(for: parentAgentID),
                        childAgentID: id.rawValue,
                        parentAgentID: parentAgentID.rawValue,
                        displayName: records[id]?.humanDisplayName ?? "Subagent",
                        sourceItemID: item.id,
                        provider: harness.rawValue,
                        spawnedAt: Date()
                    ), to: parentAgentID)
                }
            } catch {
                warn("AgentSupervisor.fanOut: no agent for item \(item.id): \(error)")
                report.refused.append((item.id, .worktreeFailed))
            }
        }
        return report
    }

    /// The live agent working an item, if any. Derived from the RECORDS rather than
    /// a runtime map, so it still answers after a relaunch has restored them.
    /// Archived agents are excluded: the item is free again once its agent is gone.
    func agent(forSourceItem itemId: String) -> AgentID? {
        records.values.first { $0.sourceItemId == itemId && $0.archivedAt == nil }?.id
    }

    /// The item this agent was fanned out for.
    func sourceItem(of id: AgentID) -> String? { records[id]?.sourceItemId }

    // MARK: - Archive / cleanup (P2C.3)

    /// What one `archive` did, so the caller reports facts instead of assuming the
    /// happy path ran. Every field is a decision that could have gone the other way.
    struct ArchiveReport {
        /// True when a prompt was in flight and had to be terminated.
        var wasRunning = false
        /// The worktree that is now gone from disk.
        var worktreeRemoved: URL?
        /// The worktree still on disk, and why it was left there.
        var worktreeRetained: (path: URL, reason: String)?
        /// The branch that was deleted because it held nothing the repo does not have.
        var branchDeleted: String?
        /// The branch kept because deleting it would have discarded the agent's
        /// commits, and why.
        var branchRetained: (branch: String, reason: String)?
        /// False only when the store refused; the in-memory record is always dropped.
        var recordDeleted = false

        var summary: String {
            var parts: [String] = []
            if wasRunning { parts.append("stopped a live runner") }
            if let worktreeRemoved { parts.append("removed \(worktreeRemoved.lastPathComponent)") }
            if let worktreeRetained { parts.append("kept worktree \(worktreeRetained.path.lastPathComponent) (\(worktreeRetained.reason))") }
            if let branchDeleted { parts.append("deleted \(branchDeleted)") }
            if let branchRetained { parts.append("KEPT \(branchRetained.branch) (\(branchRetained.reason))") }
            if parts.isEmpty { parts.append("nothing to clean up") }
            return parts.joined(separator: ", ")
        }
    }

    /// The agent leaves: its runner stops, its worktree goes away, and its record is
    /// deleted from memory and from the store.
    ///
    /// This is NOT what closing a tile does — that is `detachView` + `close`
    /// (P2A.5, .plans/05-close-to-history.md): closing a tile never ends the work,
    /// it parks the agent in History with everything it owns intact. Only a
    /// deliberate Delete reaches here, and it is the one verb that destroys.
    ///
    /// The branch is deleted ONLY when `WorktreeManager.isMerged` says the repository
    /// already has everything on it. Otherwise the branch is kept and NAMED in the
    /// report: discarding an agent's commits silently is worse than leaving a branch
    /// behind for a human to look at. A dirty worktree is likewise retained rather than
    /// force-removed — the uncommitted edits are work too, and no diff has been
    /// captured yet (that is P2C.5).
    ///
    /// P4.1 owns the `archived` lifecycle state; this is only the cleanup the
    /// archive/delete action performs.
    @discardableResult
    func archive(_ id: AgentID) -> ArchiveReport {
        var report = ArchiveReport()
        guard let record = records[id] else {
            warn("AgentSupervisor.archive: no agent \(id.rawValue.uuidString)")
            return report
        }
        // Stopped BEFORE the record is deleted, and that order is load-bearing: `stop`
        // delivers `.sessionStateChanged(.stopped)`, which is persist-worthy, so a stop
        // after the delete would write the record straight back.
        if runners[id] != nil || idleSessionRunners[id] != nil {
            report.wasRunning = true
            stop(id)
        }
        // `stop(id)` above only reaches `stopObservedRuns(for: id)` when `id` had
        // a live runner. An archived PARENT whose runner had already exited (its
        // observed children may still be tailing — B's liveness sweep had not
        // closed them yet) would otherwise leave their watcher and bindings
        // running against a directory nothing is coming back to read. And `id`
        // may itself be the CHILD being archived, independent of its parent —
        // that closes just this one binding. Both are no-ops when they don't apply.
        stopObservedRuns(for: id)
        stopObservedRun(forChild: id)
        // THE DURABLE DELETE COMES FIRST (from the cross-review). Removing a worktree
        // for a record that is still on disk is the worst combination available: the
        // next launch restores an agent whose checkout is gone. If the store refuses,
        // nothing is cleaned up and the agent stays exactly where it was.
        do {
            try store.delete(id: id)
            report.recordDeleted = true
        } catch {
            warn("AgentSupervisor.archive: could not delete agent \(id.rawValue.uuidString), so nothing was cleaned up: \(error)")
            return report
        }
        cleanUpWorktree(of: record, into: &report)
        // A spawned child's result file goes with the child. Archiving the
        // PARENT deliberately leaves its `spawn-results/` directory alone —
        // `.array/` is project-local scratch and the parent's cwd may already
        // be gone with its worktree.
        if let handle = record.spawnResultHandle,
           let parentID = record.parentAgentID,
           let parent = records[parentID] {
            try? FileManager.default.removeItem(
                at: SpawnResultFile.url(parentCwd: parent.cwd, handle: handle))
        }

        records.removeValue(forKey: id)
        runnerGenerationTokens.removeValue(forKey: id)
        history.removeValue(forKey: id)
        rehydratedTranscripts.removeValue(forKey: id)
        locationProjectors.removeValue(forKey: id)
        turnFacts.removeValue(forKey: id)
        contextWindowSnapshots.removeValue(forKey: id)
        for continuation in (subscribers[id] ?? [:]).values { continuation.finish() }
        subscribers.removeValue(forKey: id)
        restoredIDs.remove(id)
        // C4: cancel a pending save before quarantining, so a debounced write
        // in flight cannot land AFTER the move and recreate the directory the
        // move just cleared out. The transcript is the user's own record of
        // their work (the same rule the C3 migration follows) — quarantined,
        // never `rm`'d, so a deleted agent's history is still on disk if
        // someone goes looking for it.
        transcriptPersistenceTasks[id]?.cancel()
        transcriptPersistenceTasks.removeValue(forKey: id)
        transcriptProjections.removeValue(forKey: id)
        if let transcriptStore {
            Task.detached { _ = await transcriptStore.quarantineTranscript(agentID: id) }
        }
        // P6.4: the in-memory watermark throttle goes with the agent. The durable
        // watermark is deleted with the record, and a recycled id must not inherit
        // this supervisor's write cadence.
        lastVisitedPersistAt.removeValue(forKey: id)
        if focusedAgentID == id { focusedAgentID = nil }
        return report
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.15-wire-destructive-row-actions.md
    //
    // KEPT OUT OF `archive` ON PURPOSE. Archiving is the agent's cleanup and says
    // nothing about a tile; suppressing a respawn is a statement about the TILE, made
    // by the surface that deleted the agent. Folding it into `archive` would also make
    // every internal caller (P2C.3's cleanup, a fan-out teardown) leave tombstones
    // behind for tiles nobody deleted.

    /// Record that this tile's agent was deleted by a person, so restoring the canvas
    /// does not mint a replacement (`AppDelegate.wireManagedAgentTile`).
    func suppressAgentRespawn(forTile tileId: UUID) {
        var tiles = store.loadDeletedAgentTiles()
        guard tiles.insert(tileId).inserted else { return }
        do {
            try store.setDeletedAgentTiles(tiles)
        } catch {
            warn("AgentSupervisor.suppressAgentRespawn: could not record the deletion of tile \(tileId.uuidString): \(error)")
        }
    }

    func isAgentRespawnSuppressed(forTile tileId: UUID) -> Bool {
        store.loadDeletedAgentTiles().contains(tileId)
    }

    /// The other direction, for the one gesture that undoes it: submitting a prompt in
    /// a tile whose agent was deleted is asking for an agent there again.
    func allowAgentRespawn(forTile tileId: UUID) {
        var tiles = store.loadDeletedAgentTiles()
        guard tiles.remove(tileId) != nil else { return }
        do {
            try store.setDeletedAgentTiles(tiles)
        } catch {
            warn("AgentSupervisor.allowAgentRespawn: could not clear the deletion of tile \(tileId.uuidString): \(error)")
        }
    }

    /// Removes an isolated agent's checkout, keeping anything unmerged.
    ///
    /// The repository is DERIVED from the record: an isolated `cwd` is
    /// `<repo>/.worktrees/<slug>`, so the repo is two components up. That derivation is
    /// checked rather than assumed — a record whose `cwd` is not inside the container
    /// gets nothing removed, because the alternative is running `git worktree remove`
    /// on somebody's project root.
    private func cleanUpWorktree(of record: AgentRecord, into report: inout ArchiveReport) {
        guard let branch = record.worktreeBranch else { return }
        let worktree = URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)
        let container = worktree.deletingLastPathComponent()
        guard container.lastPathComponent == WorktreeManager.containerDirectoryName else {
            report.worktreeRetained = (worktree, "cwd is not inside \(WorktreeManager.containerDirectoryName)/")
            report.branchRetained = (branch, "the worktree could not be identified")
            warn("AgentSupervisor.archive: \(record.id.rawValue.uuidString) claims branch \(branch) but its checkout \(record.checkoutRoot) is not an agent worktree; leaving both alone")
            return
        }
        let repo = container.deletingLastPathComponent()

        do {
            // Git's own view: a worktree it no longer knows about must not be handed to
            // `worktree remove`, which fails on it, and the branch decision below is
            // still worth making.
            let known = try worktrees.list(repo: repo).contains {
                WorktreeManager.resolved($0.path) == WorktreeManager.resolved(worktree)
            }
            if known {
                try worktrees.remove(repo: repo, path: worktree, force: false)
                report.worktreeRemoved = worktree
            } else {
                report.worktreeRetained = (worktree, "git does not know this worktree")
            }
        } catch {
            // `git worktree remove` refuses a dirty tree. Retained, not forced.
            report.worktreeRetained = (worktree, String(describing: error))
            report.branchRetained = (branch, "its worktree is still on disk")
            warn("AgentSupervisor.archive: could not remove worktree \(worktree.path): \(error)")
            return
        }

        do {
            guard try worktrees.isMerged(repo: repo, branch: branch) else {
                report.branchRetained = (branch, "it has commits the repository does not")
                return
            }
            try worktrees.deleteBranch(repo: repo, branch: branch)
            report.branchDeleted = branch
        } catch {
            report.branchRetained = (branch, String(describing: error))
            warn("AgentSupervisor.archive: could not delete branch \(branch): \(error)")
        }
    }

    /// Worktrees under `<repo>/.worktrees/` with no agent record behind them.
    ///
    /// The known set is the union of the live records and everything still in the
    /// store, which is the load-bearing part: `restore()` MARKS a record whose `cwd` is
    /// missing and does not adopt it (P2A.7), so an in-memory-only set would call that
    /// agent's worktree an orphan and `repair` would prune the one thing that could
    /// still bring it back.
    func orphanWorktrees(repo: URL) throws -> [WorktreeManager.Orphan] {
        try worktrees.orphans(repo: repo, knownAgents: knownAgentDirectories())
    }

    /// Reports the orphans, removes the ones that hold no work, and prunes.
    func repairWorktrees(repo: URL) throws -> WorktreeManager.RepairReport {
        try worktrees.repair(repo: repo, knownAgents: knownAgentDirectories())
    }

    enum CleanupRefusal: Error, CustomStringConvertible {
        case unreadableAgentStore(String)

        var description: String {
            switch self {
            case let .unreadableAgentStore(detail):
                return "refusing to classify worktrees as orphans: \(detail)"
            }
        }
    }

    /// Every directory an agent record claims, live or stored.
    ///
    /// THROWS RATHER THAN NARROWING (from the cross-review). Repair DELETES checkouts,
    /// so an incomplete known set is not a degraded answer, it is a destructive one:
    /// every agent missing from it becomes an orphan. Both ways the set can come up
    /// short are refusals here, not warnings.
    ///
    /// The second one is the subtle one. `AgentStore.loadAll` deliberately SKIPS a
    /// record it cannot decode — correct for the inbox, which must not go down over one
    /// bad file, and silently wrong for this caller. The `.json` file count is the
    /// witness that nothing was skipped.
    private func knownAgentDirectories() throws -> Set<String> {
        let stored = try store.loadAll()
        let directory = store.layout.agentsDirectory
        var files: [URL] = []
        if FileManager.default.fileExists(atPath: directory.path) {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        }
        guard files.count == stored.count else {
            throw CleanupRefusal.unreadableAgentStore(
                "\(files.count) record file(s) in \(directory.lastPathComponent)/ but only \(stored.count) could be read, so an agent could be mistaken for an orphan"
            )
        }
        return Set(records.values.map(\.cwd)).union(stored.map(\.cwd))
    }

    // MARK: - View binding (P2A.5)

    /// Binds an agent to a tile. `AgentRecord.tileId` is WHERE THE AGENT IS BEING
    /// SHOWN, not who owns it, so this is the only thing attaching a view changes:
    /// no runner is started, stopped or replaced.
    ///
    /// One tile shows one agent, so an agent claiming a tile another agent still
    /// claims unbinds that other one. Without it `agent(forTile:)` — a
    /// `first(where:)` over the records — would answer nondeterministically after
    /// Phase 3's "open in tile" retargets a tile, and the losing agent would keep a
    /// stale binding that says it is visible when it is not.
    func attach(agentID id: AgentID, to tileId: UUID) {
        guard var record = records[id] else {
            warn("AgentSupervisor.attach: no agent \(id.rawValue.uuidString)")
            return
        }
        for (otherId, other) in records where otherId != id && other.tileId == tileId {
            var displaced = other
            displaced.tileId = nil
            records[otherId] = displaced
            persist(displaced)
        }
        guard record.tileId != tileId else { return }
        record.tileId = tileId
        records[id] = record
        persist(record)
    }

    /// Unbinds the view and NOTHING ELSE: the runner keeps running, the record stays
    /// in the store, and the agent's stream keeps delivering to its other
    /// subscribers. This is what closing a tile does (`AppDelegate.deleteTile`) —
    /// closing a tile is closing a window, not ending the work (locked decision).
    /// Ending the work is `stop(_:)`, which only a deliberate action calls.
    func detachView(agentID id: AgentID) {
        guard var record = records[id] else {
            warn("AgentSupervisor.detachView: no agent \(id.rawValue.uuidString)")
            return
        }
        guard record.tileId != nil else { return }
        record.tileId = nil
        records[id] = record
        persist(record)
    }

    // MARK: - Rename (P3.13)

    /// The longest name an agent may carry. A label, not a sentence: it is drawn in
    /// one truncating line and it crosses to the phone inside
    /// `AgentInventory.safeSummary`, where anything over 512 characters is a
    /// `transcriptBody` taint (`SyncPayloadTaintScanner`).
    static let maximumDisplayNameLength = AgentName.maximumLength

    /// User text, made into a label. Whitespace and newlines collapse to single
    /// spaces, the result is capped, and an ABSOLUTE PATH keeps only its last
    /// component — this name is published in a synced summary, and a leading `/` or
    /// `~` is how a filesystem path starts.
    ///
    /// The test is "starts a path", NOT the four prefixes `SyncPayloadTaintScanner`
    /// names (`/Users/`, `/home/`, `~/`, `/var/folders/`): copying that list here would
    /// be two copies of one rule that can drift, and it would also let `/tmp/…` or
    /// `/Volumes/…` through — a path the scanner happens not to catch is still not a
    /// name. A slash INSIDE the text is left alone, because `fix/parser` is a label
    /// people really use. (Both halves raised in cross-review.)
    ///
    /// nil for a name with nothing left in it, which the caller must read as "keep the
    /// previous one".
    static func sanitizedDisplayName(_ raw: String) -> String? {
        AgentName.fromExplicitName(raw)
    }

    /// Give an agent a human name. The name is the RECORD's (`AgentRecord.displayName`),
    /// so it outlives the tile it happens to be shown in and comes back with the agent
    /// after a relaunch — everything that draws a name joins through the record
    /// (`AgentContextIndex`, `AgentInboxRowBuilder`, `AgentInventory`).
    ///
    /// Returns whether anything changed: false for an agent this supervisor does not
    /// have or for a name that sanitises to nothing. A valid manual rename always
    /// disarms the in-flight automatic proposal, including an explicit choice of the
    /// unchanged sentinel; a late completion must then fail its request marker check.
    @discardableResult
    func rename(agentID id: AgentID, to name: String) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.rename: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard let label = AgentSupervisor.sanitizedDisplayName(name) else { return false }
        // A human rename disarms both the durable CAS marker and the best-effort
        // process. The process may still be finishing, but its request id and
        // expected title can no longer land it.
        nameGenerationTasks[id]?.cancel()
        let changed = record.displayName != label
            || record.displayNameSource != .manual
            || record.namingRequest != nil
        guard changed else { return false }
        record.displayName = label
        record.displayNameSource = .manual
        // A human title owns the record again. Clear the marker before persisting
        // so no already-started provider completion can find a live request.
        record.namingRequest = nil
        records[id] = record
        persist(record)
        return true
    }

    /// Start an automatic name proposal without doing any provider work. The
    /// caller keeps the returned token and must hand it back to
    /// `applyGeneratedName` after its best-effort work finishes.
    @discardableResult
    func beginNameGeneration(agentID id: AgentID) -> NamingRequest? {
        guard var record = records[id] else {
            warn("AgentSupervisor.beginNameGeneration: no agent \(id.rawValue.uuidString)")
            return nil
        }
        let request = record.beginNamingRequest()
        records[id] = record
        persist(record)
        return request
    }

    /// Land a generated title through the record's compare-and-swap. The
    /// request id and expected title are both checked on the completion path;
    /// checking only the id before starting work would let a rename race win.
    @discardableResult
    func applyGeneratedName(_ name: String, for request: NamingRequest, agentID id: AgentID) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.applyGeneratedName: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.namingRequest?.id == request.id,
              record.displayName == request.expectedName else { return false }
        guard let label = AgentSupervisor.sanitizedDisplayName(name) else {
            // The request was current but its result was unusable. Consume the
            // marker without changing the existing title; failure is best-effort.
            record.namingRequest = nil
            records[id] = record
            persist(record)
            return false
        }
        guard record.applyGeneratedName(label, for: request) else {
            // `AgentRecord` also validates identifier-shaped output. Persist only
            // when it consumed this current request, never for a stale completion.
            if record.namingRequest == nil {
                records[id] = record
                persist(record)
            }
            return false
        }
        records[id] = record
        persist(record)
        return true
    }

    /// The request boundary used by the later one-shot generator. An explicit
    /// name and regenerate intent are mutually exclusive: rejecting the combined
    /// request is safer than silently choosing one side and surprising the caller.
    /// Explicit names use the normal manual rename path; regenerate returns the
    /// persisted CAS token. Neither intent creates a provider process here.
    @discardableResult
    func requestName(
        agentID id: AgentID,
        explicitName: String? = nil,
        regenerate: Bool = false
    ) -> NamingRequest? {
        guard !(explicitName != nil && regenerate) else {
            warn("AgentSupervisor.requestName: explicit name and regenerate intent are mutually exclusive; refusing")
            return nil
        }
        if let explicitName {
            _ = rename(agentID: id, to: explicitName)
            return nil
        }
        guard regenerate else { return nil }
        return beginNameGeneration(agentID: id)
    }

    // MARK: - P4.5 generated-name one-shot

    /// The result of a burst routed through the supervisor. `accepted` is the
    /// only set that armed a durable CAS request; `refused` includes terminal
    /// rows, manual names, missing records/capability, and cap members.
    struct GeneratedNameBatch: Equatable, Sendable {
        let accepted: [AgentID]
        let refused: [AgentID]

        var acceptedCount: Int { accepted.count }
        var didAcceptAny: Bool { !accepted.isEmpty }
    }

    /// The owner-level orchestration for the inbox action. Keeping the filtering,
    /// cap admission, and per-agent completion wiring here means the app delegate
    /// only supplies the compile-forced row-action callback; it cannot grow a
    /// second naming owner or accidentally bypass the CAS.
    @discardableResult
    func requestGeneratedNames(
        agentIDs: [AgentID],
        onCompletion: (@Sendable (AgentID, Bool) -> Void)? = nil
    ) -> GeneratedNameBatch {
        var seen = Set<AgentID>()
        var accepted: [AgentID] = []
        var refused: [AgentID] = []
        for id in agentIDs where seen.insert(id).inserted {
            let started = requestGeneratedName(agentID: id) { landed in
                onCompletion?(id, landed)
            }
            if started {
                accepted.append(id)
            } else {
                refused.append(id)
            }
        }
        return GeneratedNameBatch(accepted: accepted, refused: refused)
    }

    /// Start the explicit, best-effort generated-name action. This method only
    /// claims the CAS token and schedules work; the blocking Process lives on a
    /// detached utility task and never occupies the agent's turn runner.
    @discardableResult
    func requestGeneratedName(
        agentID id: AgentID,
        onCompletion: (@Sendable (Bool) -> Void)? = nil
    ) -> Bool {
        guard let record = records[id] else {
            warn("AgentSupervisor.requestGeneratedName: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.displayNameSource != .manual else {
            warn("AgentSupervisor.requestGeneratedName: manual name owns agent \(id.rawValue.uuidString); refusing generated overwrite")
            return false
        }
        // This admission check is on the main actor, before capability lookup or
        // CAS mutation. A refused burst member therefore remains unchanged and
        // cannot make a synchronous login-shell probe part of the burst.
        guard activeNameGenerations < Self.maximumConcurrentNameGenerations else {
            warn("AgentSupervisor.requestGeneratedName: concurrency cap \(Self.maximumConcurrentNameGenerations) reached; refusing burst member")
            return false
        }
        let capability: AgentNameGenerationCapability?
        if let nameGenerationCapabilityProvider {
            capability = nameGenerationCapabilityProvider()
        } else {
            capability = Self.cachedNameGenerationCapability()
        }
        guard let capability else {
            warn("AgentSupervisor.requestGeneratedName: Pi capability/auth unavailable; no process spawned")
            return false
        }
        // A second explicit click supersedes the old request. Cancellation is a
        // hint to the detached task; the completion still proves the old CAS id,
        // so cancellation failure cannot clobber a newer request.
        nameGenerationTasks[id]?.cancel()
        guard let request = beginNameGeneration(agentID: id) else { return false }
        let source = firstPromptByAgent[id]
            ?? "No source prompt is available. Propose a concise name from the current agent title: \(record.humanDisplayName)"
        let prompt = Self.generatedNamePrompt(source)
        let cwd = URL(fileURLWithPath: record.lastObservedWhere, isDirectory: true)
        let timeout = nameGenerationTimeout
        activeNameGenerations += 1
        nameGenerationRequestIDs[id] = request.id
        let task = Task.detached(priority: .utility) { [weak self, capability, request, prompt, cwd, timeout, onCompletion, record] in
            var candidate: String?
            var failure: String?
            do {
                let stdout = try AgentNameOneShot.run(
                    capability: capability,
                    prompt: prompt,
                    cwd: cwd,
                    timeout: timeout)
                candidate = AgentNameOneShot.candidate(
                    from: stdout,
                    model: record.model,
                    role: record.role,
                    id: record.id.rawValue)
                if candidate == nil { failure = "invalid provider output" }
            } catch let error as AgentNameOneShotError {
                failure = error.description
            } catch {
                failure = "provider failed"
            }
            await MainActor.run {
                self?.finishGeneratedName(
                    candidate: candidate,
                    failure: failure,
                    request: request,
                    agentID: id,
                    onCompletion: onCompletion)
            }
        }
        nameGenerationTasks[id] = task
        return true
    }

    /// QA-only observability for the concurrency witness. It is not a second
    /// capability or provider state owner.
    var qaActiveNameGenerationCount: Int { activeNameGenerations }

    private static func generatedNamePrompt(_ source: String) -> String {
        let bounded = String(source.prefix(AgentNameOneShot.maximumPromptLength))
        return "Name the agent from this user request. Return one short name only, with no explanation or metadata.\n\nUser request:\n\(bounded)"
    }

    private func finishGeneratedName(
        candidate: String?,
        failure: String?,
        request: NamingRequest,
        agentID id: AgentID,
        onCompletion: (@Sendable (Bool) -> Void)?
    ) {
        activeNameGenerations = max(0, activeNameGenerations - 1)
        if nameGenerationRequestIDs[id] == request.id {
            nameGenerationRequestIDs[id] = nil
            nameGenerationTasks[id] = nil
        }
        let landed: Bool
        if let candidate {
            landed = applyGeneratedName(candidate, for: request, agentID: id)
        } else {
            // A current failed request consumes only its marker. The record's
            // existing/P4.2 name remains untouched; a stale/manual request is a
            // no-op through the same CAS guard.
            landed = applyGeneratedName("", for: request, agentID: id)
        }
        if let failure {
            warn("AgentSupervisor.requestGeneratedName: agent \(id.rawValue.uuidString) \(failure); keeping its existing name")
        } else if !landed {
            warn("AgentSupervisor.requestGeneratedName: agent \(id.rawValue.uuidString) lost the naming CAS; keeping its existing name")
        }
        onCompletion?(landed)
    }

    // MARK: - Model and thinking level (P6.1)

    /// What this agent's NEXT turn will run with. Returns the record's own values,
    /// never the global default: `AgentModelConfig` is only what a record was seeded
    /// from at spawn, and changing that Settings default must not move an agent that
    /// already exists. nil for an agent this supervisor does not know.
    func providerSettings(for id: AgentID) -> AgentModelConfig.Resolution? {
        records[id].map { AgentModelConfig.Resolution(model: $0.model, thinking: $0.thinking) }
    }

    /// Choose the model and/or thinking level for ONE agent, and persist it.
    ///
    /// This is the whole mechanism: `piRunner(for:)` builds a runner per turn from
    /// the record (`runnerConfig(for:)` reads `record.model` / `record.thinking`), so
    /// writing them here is what makes the next `send` spawn Pi with those flags.
    /// Nothing mid-turn changes — `send` refuses a prompt on a busy agent rather than
    /// replacing the in-flight runner, and switching a live turn's model needs Pi's
    /// `set_model` RPC (P5.4/P5.5).
    ///
    /// A value outside `AgentModelConfig`'s catalogue is REFUSED rather than
    /// substituted: `--model` takes a *pattern*, so a shortened or misspelt id fuzzy
    /// matches and the agent silently runs whichever model Pi picked — the exact bug
    /// P0.10 exists to prevent. Persisting immediately is correct here even though
    /// P2A.3 keeps writes to lifecycle events: this is a discrete user action, not a
    /// per-token write on the main thread.
    ///
    /// Returns whether anything changed — as `rename` does, so a caller cannot
    /// mistake a no-op for a write.
    @discardableResult
    func launchSelection(for id: AgentID) -> AgentLaunchSelection? {
        guard let record = records[id], let harness = record.harness else { return nil }
        return AgentLaunchSelection(harness: harness, model: record.model, thinking: record.thinking)
    }

    func setProviderSettings(agentID id: AgentID, harness: AgentHarness? = nil, model: String? = nil, thinking: String? = nil) -> Bool {
        guard var record = records[id] else { return false }
        let effectiveHarness = harness ?? record.harness
        guard let effectiveHarness else { return false }
        let effectiveModel = model ?? record.model
        // Validate ownership only when this action changes the model/harness.
        // A restored record may legitimately retain a model removed from the
        // current catalogue; changing only its effort must preserve that model,
        // not become impossible until the user also chooses a replacement.
        if model != nil || harness != nil {
            let snapshot = AgentModelCatalog.shared.snapshot(for: effectiveHarness)
            guard snapshot.models.contains(effectiveModel), AgentHarnessConfig.isProviderCompatible(model: effectiveModel, harness: effectiveHarness) else {
                warn("AgentSupervisor.setProviderSettings: choose a model owned by \(effectiveHarness.rawValue) before switching harness")
                return false
            }
        }
        if let thinking, !AgentModelConfig.thinkingOptions.contains(thinking) { return false }
        var changed = false
        if record.harness != effectiveHarness { record.harness = effectiveHarness; changed = true }
        if record.model != effectiveModel { record.model = effectiveModel; changed = true }
        if let thinking, record.thinking != thinking { record.thinking = thinking; changed = true }
        guard changed else { return false }
        records[id] = record
        persist(record)
        // A persistent Pi process was launched with the previous harness/model/
        // thinking arguments. Provider controls are disabled during a turn, so
        // the only stale instance possible here is idle; retire it now and let
        // the next send create a session with the newly persisted settings.
        idleSessionRunners.removeValue(forKey: id)?.stop()
        return true
    }

    /// The agent bound to a tile. Reads `records`, which `restore()` (P2A.7)
    /// repopulates from the store at boot — so this dedupes a re-wire within a launch
    /// AND across launches, and a restored tile finds its own agent instead of
    /// spawning a second one over the top of it.
    func agent(forTile tileId: UUID) -> AgentID? {
        records.values.first(where: { $0.tileId == tileId })?.id
    }

    /// True while a prompt is in flight. Exposed for the checks and for P2A.5,
    /// which must know whether detaching a view leaves work running.
    func isRunning(_ id: AgentID) -> Bool {
        runners[id] != nil
    }

    /// Operational state for one tile. State comes only from explicit lifecycle
    /// and request events. Transport occupancy affects capability acceptance, not
    /// the label: a process that has emitted Ready still presents Ready.
    /// The latest context-window telemetry the supervisor has seen for this
    /// agent, or nil when none was ever reported. Attach-time seeding reads
    /// this seam (like `turnSnapshot`/`providerSettings`/`branchContext`)
    /// because the capped replay buffer routinely evicts the rare
    /// `.contextWindowUpdated` event behind a streaming turn's deltas. The
    /// caller owns demoting freshness for a seeded (non-live) read.
    func contextWindowSnapshot(for id: AgentID) -> AgentContextWindowSnapshot? {
        guard let record = records[id] else { return nil }
        // In-memory first (freshest), then the record's persisted telemetry so
        // a resumed session seeds real prior occupancy instead of "unknown".
        return contextWindowSnapshots[id] ?? record.lastContextWindow
    }

    func turnSnapshot(for id: AgentID) -> AgentTileTurnSnapshot? {
        guard let record = records[id] else { return nil }
        let facts = turnFacts[id] ?? TurnFacts()
        let state: AgentTileOperationalState
        if let requestID = facts.requestOrder.first(where: { facts.pendingRequests[$0] != nil }),
           let request = facts.pendingRequests[requestID] {
            state = .needsAction(request)
        } else if facts.didFail {
            state = .failed(message: facts.failureMessage)
        } else if restoredIDs.contains(id) && (history[id]?.isEmpty ?? true) {
            state = .restored
        } else if facts.execution == .working {
            state = .working
        } else if runners[id] != nil, facts.submittedAt != nil {
            // A runner is bound, a prompt was accepted, and the provider has not
            // reported a turn yet. This used to fall through to `.ready`, which is
            // why the tile said "idle" with a disabled composer while `canStop` was
            // already true.
            //
            // `submittedAt != nil` is load-bearing, not belt-and-braces: a runner
            // can still be bound while a finished turn drains (`clearRunner` runs
            // after `.turnCompleted`), and that window must read `.ready`, not
            // "Starting" — the settle transitions clear both anchors together.
            state = .starting
        } else {
            state = .ready
        }

        let occupied = runners[id] != nil
        // C5 — `AgentCapabilities` becomes load-bearing here, its first production
        // use. A mirrored child has no runner of Array's, so no send and no stop
        // are honest at ANY moment, not merely at this one.
        let mirrored = !record.capabilities.locallyManaged
        // B2.2 — steer is a fact about the BOUND RUNNER, composed only when a
        // session runner is actually bound: it is real mid-turn delivery into
        // that runner's own process, so a harness mid-migration never advertises
        // a verb the process behind it cannot perform.
        let session = mirrored ? nil : (runners[id] as? AgentSessionRunning)
        let steerable = session?.sessionCapabilities.supportedCommands.contains("steer") ?? false
        // B4 — queue is Array's own capability, not the harness's. Queueing never
        // asks the bound runner to do anything while it is busy; Array holds the
        // text and sends it as an ORDINARY prompt once `turnCompleted` frees the
        // runner. That is honest for every harness with an occupied runner,
        // one-shot or session-backed alike — there is no RPC to gate on.
        let queueable = occupied && !mirrored
        return AgentTileTurnSnapshot(
            state: state,
            capabilities: AgentTurnCapabilities(
                canSend: !mirrored && !occupied && state.acceptsNewTurn,
                // In flight = stoppable, full stop (P5.5 consolidation): `stop()`
                // genuinely kills a spawning (pre-turnStarted) or draining
                // (post-settle) process, so gating on `execution == .working`
                // under-advertised the transport — and painted the two windows
                // "Unavailable" on the composer.
                canStop: !mirrored && occupied && record.capabilities.canStop,
                canSteer: steerable && occupied,
                canQueue: queueable && occupied
            ),
            // P3.3: carried, never derived here. A consumer that wanted an elapsed
            // reading had to reach for the event ring instead, which is why the
            // sidebar and the tile header measured different durations for one turn.
            turnStartedAt: facts.turnStartedAt,
            submittedAt: facts.submittedAt,
            isMirrored: mirrored
        )
    }

    /// One action owner for the v2 composer. Validation and mutation happen on the
    /// same main-actor turn, so an accepted send/stop cannot be refused by a second
    /// capability check hidden in the view.
    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
        guard records[agentID] != nil else { return .refused(.unknownAgent) }
        guard let snapshot = turnSnapshot(for: agentID) else { return .refused(.unknownAgent) }
        switch intent {
        case .send(let draft):
            let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return .refused(.emptyDraft) }
            guard snapshot.capabilities.canSend else { return .refused(.turnNotReady) }
            guard sendPrepared(
                PreparedAgentPrompt(prompt: AgentPrompt(prompt), expectedAgentID: agentID),
                to: agentID
            ) else { return .refused(.invalidAttachment) }
            // B4: an explicit Send releases a queue this agent's last turn left
            // paused after an interrupt — the user looked, and is choosing to act.
            pausedQueues.remove(agentID)
            return .accepted
        case .sendPrompt(let draft):
            var prompt = draft
            prompt.text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return .refused(.emptyDraft) }
            guard snapshot.capabilities.canSend else { return .refused(.turnNotReady) }
            do {
                let prepared = try await attachmentStore.preparePromptAttachments(
                    for: agentID,
                    draftAttachments: prompt.imageAttachments.map { AgentComposerDraftImageAttachment(metadata: $0.metadata) }
                )
                guard sendPrepared(
                    PreparedAgentPrompt(
                        prompt: AgentPrompt(
                            text: prompt.text,
                            imageAttachments: prepared,
                            fileReferences: prompt.fileReferences
                        ),
                        expectedAgentID: agentID
                    ),
                    to: agentID
                ) else {
                    return .refused(.invalidAttachment)
                }
            } catch {
                warn("AgentSupervisor.accept: attachment preparation refused for agent \(agentID.rawValue.uuidString): invalid managed attachment")
                return .refused(.invalidAttachment)
            }
            pausedQueues.remove(agentID)
            return .accepted
        case .stop:
            guard snapshot.capabilities.canStop, runners[agentID] != nil else {
                return .refused(.noTurnInProgress)
            }
            stop(agentID)
            return .accepted
        case .providerCommand(let invocation):
            guard invocation.surface != .cli else { return .refused(.unsupported) }
            // B5 — routed through the classifier instead of unconditionally
            // serializing and sending. `AgentCommandExecutionPlanner` decides per
            // invocation whether Array performs it, the harness does, it expands
            // into an ordinary prompt, or it cannot run here at all — never
            // derived from `record.harness`, always from the BOUND runner (the
            // same rule `turnSnapshot` already follows for steer/queue).
            guard let descriptor = AgentCommandCatalog.allBaselines()
                .first(where: { $0.id == invocation.descriptorID }) else {
                return .refused(.unsupported)
            }
            switch AgentCommandExecutionPlanner.resolve(
                descriptor, capabilities: sessionCommandCapabilities(for: agentID)
            ) {
            case .arrayOwned:
                // Array performs it and authors the reply itself as a `.system`
                // notice — it never reaches the CLI as text, so no runtime event
                // is invented and no turn is spent.
                guard snapshot.capabilities.canSend else { return .refused(.turnNotReady) }
                if descriptor.name == "clear" {
                    // B7.2 — `/clear` is not just a notice: it is one transaction
                    // over session rotation, the stale context meter, naming, and
                    // subagent chips, or it is worse than doing nothing.
                    performClearCommand(descriptor, for: agentID)
                } else {
                    appendArrayOwnedCommandNotice(descriptor, for: agentID)
                }
                return .accepted
            case .harnessDelegated, .skillTemplate:
                let native = invocation.nativeSlashText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !native.isEmpty else { return .refused(.emptyDraft) }
                guard snapshot.capabilities.canSend else { return .refused(.turnNotReady) }
                guard sendPrepared(
                    PreparedAgentPrompt(prompt: AgentPrompt(native), expectedAgentID: agentID),
                    to: agentID
                ) else { return .refused(.invalidAttachment) }
                return .accepted
            case .unavailable:
                // Disabled with a reason, never degraded into prose: codex and pi
                // hand a leading slash straight to the model, spending a real paid
                // turn answering conversationally about a command that means
                // nothing to them in this mode.
                return .refused(.unsupported)
            }
        case .queue(let draft):
            // B4 — this REVERSES the prohibition that used to sit here. That rule
            // was aimed at faking steering by silently replaying a send later; about
            // THAT it stays correct. Queueing is a different act: the user explicitly
            // asked to hold this message until the current turn ends, and Array must
            // be the one holding it, because neither claude nor pi exposes a
            // cancel-the-queue verb (claude reports `still_queued` with no cancel;
            // pi's rpc surface has `abort`/`abort_bash`/`abort_retry` and no
            // `cancel_follow_up`). Write-ahead into the harness's own queue would
            // make "cancel what I queued" unimplementable, so the harness never
            // holds more than one pending message and retaining text in a local
            // queue is exactly the mechanism that keeps a cancel honest.
            var prompt = draft
            prompt.text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return .refused(.emptyDraft) }
            guard snapshot.capabilities.canQueue, let store = submissionRecoveryStore else {
                return .refused(.unsupported)
            }
            let draftImageAttachments = prompt.imageAttachments.map { AgentComposerDraftImageAttachment(metadata: $0.metadata) }
            do {
                // Validate now, the same way an ordinary send does, so a queued
                // message cannot die silently for an attachment reason the user
                // had no chance to see at the moment they asked to queue it.
                _ = try await attachmentStore.preparePromptAttachments(for: agentID, draftAttachments: draftImageAttachments)
            } catch {
                warn("AgentSupervisor.accept: attachment preparation refused for queued message, agent \(agentID.rawValue.uuidString)")
                return .refused(.invalidAttachment)
            }
            let fileReferences = prompt.fileReferences.map {
                AgentComposerDraftFileReference(displayName: $0.displayName, contentType: $0.contentType, path: $0.fileURL.path)
            }
            _ = await store.enqueueMessage(
                text: prompt.text,
                imageAttachments: draftImageAttachments,
                fileReferences: fileReferences,
                for: agentID
            )
            queuedMessagesCache[agentID] = await store.queuedMessages(for: agentID)
            notifyTurnCapabilitiesChanged(agentID)
            return .accepted
        case .steer, .command:
            // Today's compiled runner exercises neither of these. Never simulate
            // one by replaying send.
            return .refused(.unsupported)
        }
    }

    // MARK: - Branch context (P2C.4)

    /// What a view needs to say which checkout this agent is about to touch: the
    /// branch its record names, and the branch actually checked out in the directory
    /// it works in.
    ///
    /// `record.cwd` IS that directory — an isolated agent's own worktree, or the
    /// project root for a shared one — so no repository root has to be re-derived
    /// here (the derivation `cleanUpWorktree` needs, and its container guard, exist
    /// because THAT call deletes things).
    ///
    /// Returns an `AgentRowContext` carrying only the branch fields rather than a
    /// pair of strings: it is the type Phase 3's rows already join, so a renderer
    /// takes one shape from either source and `isBranchMismatch` keeps one
    /// definition. nil for an agent this supervisor does not know.
    func branchContext(for id: AgentID) -> AgentRowContext? {
        guard let record = records[id] else { return nil }
        return AgentRowContext(
            agentKind: .managed,
            worktreeBranch: record.worktreeBranch,
            checkedOutBranch: checkedOutBranches.branch(
                repo: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)
            )
        )
    }

    /// `branchContext(for:)` without the shell-out: serves whatever the cache
    /// holds, possibly stale, possibly absent. The activation-path sidebar
    /// rebuild reads through THIS — the TTL variant put two synchronous git
    /// spawns per agent repo on the main thread at every app switch (~0.4 s
    /// frozen, sampled live 2026-08-19). `warmCheckedOutBranchTargets` +
    /// `storeCheckedOutBranch` are how an off-main pass keeps it fresh.
    func branchContextCachedOnly(for id: AgentID) -> AgentRowContext? {
        guard let record = records[id] else { return nil }
        return AgentRowContext(
            agentKind: .managed,
            worktreeBranch: record.worktreeBranch,
            checkedOutBranch: checkedOutBranches.cachedOnly(
                repo: URL(fileURLWithPath: record.checkoutRoot, isDirectory: true)) ?? nil
        )
    }

    /// Every distinct working directory a warm pass should read, each once.
    func warmCheckedOutBranchTargets() -> [URL] {
        var seen = Set<String>()
        return records.values.compactMap { record in
            seen.insert(record.checkoutRoot).inserted
                ? URL(fileURLWithPath: record.checkoutRoot, isDirectory: true) : nil
        }
    }

    /// Fold one off-main read back into the cache. True when the value CHANGED,
    /// so the caller re-renders only when a chip would actually differ.
    @discardableResult
    func storeCheckedOutBranch(_ branch: String?, repo: URL) -> Bool {
        let before = checkedOutBranches.cachedOnly(repo: repo)
        checkedOutBranches.store(branch: branch, repo: repo)
        return before != .some(branch)
    }

    /// Forget the cached branches, for a caller that knows a checkout moved. The
    /// TTL gets there on its own; this is how a refresh gets there at once.
    func invalidateCheckedOutBranches() {
        checkedOutBranches.invalidate()
    }

    /// How many `git rev-parse` calls the branch cache has made — the witness that
    /// re-rendering a header does not shell out.
    var qaBranchGitReads: Int { checkedOutBranches.gitReads }

    // MARK: - Read state (P3.3)

    /// Read-state is derived from the durable completion/failure signals and this
    /// desktop-local watermark. The watermark is host-bound state on the record;
    /// `AgentInventory` never publishes it. Keeping the derivation beside the
    /// record means a relaunch preserves what this Mac has actually seen without
    /// making a phone's read state part of the companion contract.

    /// The agent the human is looking at, or nil when that is nothing this
    /// supervisor owns. Read-state is cleared against THIS, not against a hover:
    /// clearing on hover would empty the inbox by sweeping the mouse across it.
    private(set) var focusedAgentID: AgentID?

    // MARK: - WS4 · arrival-time active-view facts

    /// Live facts about whether a human is looking at this agent RIGHT NOW.
    ///
    /// Installed by the app (`AppDelegate.installAgentAwarenessHooks`) and read at
    /// the instant a terminal event arrives. Absent — a headless supervisor, a
    /// fixture that never wired the app — answers `.away`, so a completion stays
    /// unread. `focusedAgentID` deliberately plays NO part: it is a remembered
    /// value that survives app resignation, window ordering and modal restoration,
    /// and using it here is precisely the false-read defect.
    var activeViewFactsProvider: ((AgentID) -> AgentActiveViewFacts)?

    /// Fires for every terminal arrival that the facts said was actively viewed,
    /// carrying the decision so the live/visual half is applied by one owner.
    var onWatchedTerminalArrival: ((AgentID, UUID?, AgentTerminalArrivalKind, AgentAwarenessDecision) -> Void)?

    /// Every terminal arrival this supervisor has seen. The POSITIVE CONTROL for
    /// every "…and it stayed unread" assertion: without it, a witness that broke
    /// the delivery path entirely would read as a pass.
    private(set) var qaTerminalArrivalCount = 0
    /// Terminal arrivals the facts accepted as watched.
    private(set) var qaWatchedTerminalArrivalCount = 0
    /// The facts and decision from the most recent terminal arrival, for the
    /// semantic record a check writes out.
    private(set) var qaLastArrivalFacts: AgentActiveViewFacts?
    private(set) var qaLastArrivalDecision: AgentAwarenessDecision?

    func activeViewFacts(for id: AgentID) -> AgentActiveViewFacts {
        activeViewFactsProvider?(id) ?? .away
    }

    /// A deliberate focus or open: the tile was activated, or the inbox row was
    /// revealed (P3.9). Record the maximum watermark for that agent. The in-memory
    /// value moves immediately, while disk writes are throttled except when this
    /// visit clears a completion that would otherwise be unread.
    ///
    /// Pass nil when focus leaves for something that is not an agent; from then on a
    /// later completion is unread again. `now` is injectable for deterministic
    /// supervisor checks and defaults to the real visit instant in production.
    ///
    /// WS4: `deliberate` is the difference between a human going to look at an
    /// agent and the app putting focus back where it was (app activation, modal
    /// dismissal, recovery). A non-deliberate focus still arms `focusedAgentID`
    /// — the sidebar, lineage overlay and z-order all depend on knowing where
    /// focus sits — but it must NOT move the read watermark, or coming back to
    /// Array would silently clear every completion that landed while you were
    /// away.
    func focus(agentID id: AgentID?, now: Date = Date(), deliberate: Bool = true) {
        focusedAgentID = id
        guard deliberate, let id else { return }
        markVisited(agentID: id, now: now)
    }

    /// Record a deliberate view without changing keyboard-focus identity. Hover
    /// dwell and Focus Mode clicks use this: the human has read the completion,
    /// but merely looking must not retarget lineage, shortcuts, or spawn context.
    func markVisited(agentID id: AgentID, now: Date = Date()) {
        guard var record = records[id] else { return }
        let wasUnread = record.isUnread
        let previous = record.lastVisitedAt
        let visited = previous.map { max($0, now) } ?? now
        guard visited != previous else { return }
        record.lastVisitedAt = visited
        if let terminal = record.latestTerminalEvent {
            record.acknowledgedTerminalSequence = max(
                record.acknowledgedTerminalSequence, terminal.sequence)
        }
        records[id] = record
        let elapsed = lastVisitedPersistAt[id].map { now.timeIntervalSince($0) } ?? .infinity
        let shouldPersist = wasUnread || previous == nil || elapsed >= Self.lastVisitedPersistThrottle
        guard shouldPersist else { return }
        lastVisitedPersistAt[id] = now
        persist(record)
    }

    /// The same thing keyed by TILE, which is how focus actually arrives on the
    /// desktop (`FocusBroker` speaks tile ids). A tile showing no agent focuses
    /// nothing rather than leaving the previous agent armed.
    func focusTile(_ tileId: UUID?, deliberate: Bool = true) {
        focus(agentID: tileId.flatMap { agent(forTile: $0) }, deliberate: deliberate)
    }

    /// This agent's attention axis, resolved (`InboxAttention.resolve`). Durable
    /// completion/failure stamps provide the two watermark comparisons; a live
    /// pending request is passed only so a still-held snooze can raise its hand.
    /// The explicit argument remains for non-record/fixture callers.
    func attention(for id: AgentID, raisedHand: Bool = false, now: Date = Date()) -> InboxAttention {
        guard let record = records[id] else {
            return InboxAttention.resolve(unread: false, raisedHand: raisedHand)
        }
        let pending = turnFacts[id]?.pendingRequests.values.first != nil
        let durable = record.attention(now: now, pending: pending)
        return InboxAttention.resolve(
            unread: durable == .unread,
            raisedHand: raisedHand || durable == .woke)
    }

    // MARK: - Auto-unsettle (P4.4)

    /// Which reason last cleared each agent's settle. Kept so a clear can be
    /// ATTRIBUTED — `.activity` is the app's own, `.user` is a person's — rather than
    /// inferred from a `.neutral` that both paths produce. In memory only: the
    /// attribution is debugging state, not a fact about the agent, and `AgentRecord`
    /// is what the store and the companion publisher serialize.
    private(set) var settledOverrideClearReasons: [AgentID: SettledOverrideClearReason] = [:]

    /// Every clear is also SAID OUT LOUD, through this file's one logging seam. The
    /// dictionary above answers "who cleared it" only while the process lives, and the
    /// question the packet actually poses ("so the ledger/debugging can tell them
    /// apart") is usually asked after the fact about an override that is already gone.
    /// A line per clear is the durable half of the attribution; `warn` is injectable,
    /// so it is also the testable half. Rare by construction — only a settled agent has
    /// anything to clear — and it names the agent id and the reason, both of which this
    /// file's other log lines already carry.
    private func logSettleCleared(_ id: AgentID, reason: SettledOverrideClearReason) {
        warn("AgentSupervisor: cleared the settle on agent \(id.rawValue.uuidString) — reason \(reason.rawValue)")
    }

    /// Whether an event proves a genuine prompt/turn, the only activity allowed
    /// to clear a keep-active pin. Session/process state and request bookkeeping
    /// can add lifecycle blockers or wake signals, but they are not proof that a
    /// new prompt or turn began.
    ///
    /// `nonisolated static` and a total switch over `AgentRuntimeEvent`, like
    /// `isPersistWorthy` beside it: a new event case is a compile error here rather
    /// than a silent default.
    nonisolated static func isRealActivity(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case .turnStarted:
            return true
        case .sessionStateChanged, .turnCompleted, .itemStarted, .itemCompleted,
             .contentDelta, .requestOpened, .requestResolved, .userInputRequested,
             .userInputResolved, .tokenUsageUpdated, .contextWindowUpdated,
             .childAgentSpawned, .runtimeError, .semanticSignal:
            return false
        }
    }

    /// The older settled override still clears when a session/request becomes
    /// visible, preserving P4.4's restored-settle behavior. A keep-active pin does
    /// not use this broader classification: `isRealActivity` above is the narrower
    /// prompt/turn gate passed to `clearSettleOnActivity`.
    nonisolated static func clearsSettledOverride(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case let .sessionStateChanged(state):
            switch state {
            case .starting, .running:
                return true
            case .ready, .waiting, .stopped, .error:
                return false
            }
        case .turnStarted, .requestOpened, .userInputRequested:
            return true
        case .turnCompleted, .itemStarted, .itemCompleted, .contentDelta,
             .requestResolved, .userInputResolved, .tokenUsageUpdated, .contextWindowUpdated, .runtimeError:
            return false
        case .childAgentSpawned, .semanticSignal:
            return false
        }
    }

    /// THE APP's clear, and the only writer of `reason: .activity`. Returns whether the
    /// override actually moved, which is what tells `deliver` it has to persist an
    /// event that is not otherwise persist-worthy — a clear that lives only in memory
    /// comes back settled on the next launch.
    ///
    /// Takes the record `inout` rather than an id so it composes with the callers that
    /// are already holding a mutated copy (`send`, `deliver`); they own writing it back.
    @discardableResult
    private func clearSettleOnActivity(
        _ record: inout AgentRecord,
        clearKeepActivePin: Bool = true
    ) -> Bool {
        // P6.2: a session/request event may clear a restored settle, but the
        // keep-active pin is a stronger explicit instruction and survives every
        // event except a genuine prompt/turn. `send` and `.turnStarted` pass the
        // default true; `deliver` passes the narrower classifier above.
        guard record.settledOverride != .neutral,
              record.settledOverride != .active || clearKeepActivePin else { return false }
        record.settledOverride = .neutral
        settledOverrideClearReasons[record.id] = .activity
        logSettleCleared(record.id, reason: .activity)
        return true
    }

    /// The live lifecycle facts used by action writers. An unadopted prompt is a
    /// real stored prompt stamp newer than the latest turn stamp — never merely an
    /// idle persistent runner. Reusing `now` here would renew the grace window on
    /// every menu open and make an ordinary ready session permanently unsnoozable.
    private func currentLifecycleFacts(for id: AgentID, now: Date) -> AgentLifecycleFacts {
        let turn = turnFacts[id] ?? TurnFacts()
        let hasPendingRequest = !turn.pendingRequests.isEmpty
        let record = records[id]
        let unadoptedPromptAt: Date? = {
            guard runners[id] != nil,
                  let promptAt = record?.latestPromptAt,
                  promptAt > (record?.latestTurnAt ?? .distantPast) else { return nil }
            return promptAt
        }()
        return AgentLifecycleFacts(
            attentionIsYours: hasPendingRequest,
            hasLiveRunner: runners[id] != nil,
            unadoptedPromptAt: unadoptedPromptAt,
            graceWindow: 30)
    }

    /// Settle one agent at a point in time. The stored `settledAt` is written with
    /// the override so history never falls back to a metadata timestamp.
    @discardableResult
    func settle(agentID id: AgentID, now: Date = Date()) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.settle: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.settledOverride != .settled else { return false }
        let facts = currentLifecycleFacts(for: id, now: now)
        guard record.canSettle(facts: facts, autoSettleAfter: AgentAutoSettleConfig.resolvedFromDefaults().window, now: now) else {
            warn("AgentSupervisor.settle: refusing blocked or already parked agent \(id.rawValue.uuidString)")
            return false
        }
        record.settledOverride = .settled
        record.settledAt = now
        records[id] = record
        persist(record)
        return true
    }

    /// Explicit un-settle means keep this row active until real activity arrives;
    /// it is not the neutral clear used by an activity or a deliberately neutral
    /// human reset.
    @discardableResult
    func pinActive(agentID id: AgentID) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.pinActive: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.settledOverride != .active else { return false }
        record.settledOverride = .active
        settledOverrideClearReasons[id] = nil
        records[id] = record
        persist(record)
        return true
    }

    /// Store both snooze dates as one record mutation. A live turn is allowed to
    /// hide; only a pending human request or an unadopted prompt refuses it.
    @discardableResult
    func snooze(agentID id: AgentID, until: Date, now: Date = Date()) -> Bool {
        guard until > now else {
            warn("AgentSupervisor.snooze: refusing non-future wake for \(id.rawValue.uuidString)")
            return false
        }
        guard var record = records[id] else {
            warn("AgentSupervisor.snooze: no agent \(id.rawValue.uuidString)")
            return false
        }
        let facts = currentLifecycleFacts(for: id, now: now)
        guard record.canSnooze(facts: facts, now: now) else {
            warn("AgentSupervisor.snooze: refusing a human-blocked or unadopted agent \(id.rawValue.uuidString)")
            return false
        }
        record.snoozedUntil = until
        record.snoozedAt = now
        records[id] = record
        persist(record)
        return true
    }

    /// Explicit Wake clears the stored visibility overlay. A derived raised hand
    /// never calls this method, so early wake leaves both stored dates intact.
    @discardableResult
    func wake(agentID id: AgentID) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.wake: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.snoozedUntil != nil || record.snoozedAt != nil else { return false }
        record.snoozedUntil = nil
        record.snoozedAt = nil
        records[id] = record
        persist(record)
        return true
    }

    // Ticket: .plans/05-close-to-history.md

    /// Park an agent in History. The row leaves the live list; the record, the
    /// transcript, the provider session and the worktree all stay, so reopening the
    /// row brings the agent back with its context (`revealAgentFromInbox`).
    ///
    /// THIS IS NOT `archive`, which is the destructive verb below and deletes
    /// everything. The two used to be the same thing because closing a tile left
    /// the agent in the list forever; the plan splits them.
    ///
    /// REFUSES A BLOCKED AGENT, through the predicate the settle action already
    /// uses (`AgentLifecycleFacts.blocksSettlement`) rather than a second opinion
    /// about what "busy" means: a turn in flight, a pending human request, an
    /// unadopted prompt, or a descendant holding its parent open all keep the agent
    /// where you can see it. Closing the tile of a WORKING agent is the case this
    /// protects — P2A.5's decision is that the work continues, and the row is then
    /// the only thing left saying so.
    @discardableResult
    func close(agentID id: AgentID, now: Date = Date()) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.close: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.archivedAt == nil else { return false }
        guard !currentLifecycleFacts(for: id, now: now).blocksSettlement(now: now) else {
            return false
        }
        record.archivedAt = now
        records[id] = record
        persist(record)
        return true
    }

    /// The way out of History. Reopening a closed agent is asking for it back, so
    /// the stamp is cleared — otherwise the row it was revealed from would still be
    /// in History while its tile sits on the canvas.
    @discardableResult
    func reopen(agentID id: AgentID) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.reopen: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.archivedAt != nil else { return false }
        record.archivedAt = nil
        records[id] = record
        persist(record)
        return true
    }

    /// Deliberately rewind the read watermark. This is the one non-monotonic path;
    /// ordinary focus always stores a maximum.
    @discardableResult
    func markUnread(agentID id: AgentID, now: Date = Date()) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.markUnread: no agent \(id.rawValue.uuidString)")
            return false
        }
        let terminalCanRewind = record.latestTerminalEvent.map {
            record.acknowledgedTerminalSequence >= $0.sequence
        } ?? false
        guard record.lastVisitedAt != .distantPast || terminalCanRewind else { return false }
        record.lastVisitedAt = .distantPast
        if let terminal = record.latestTerminalEvent {
            record.acknowledgedTerminalSequence = terminal.sequence &- 1
        }
        lastVisitedPersistAt[id] = now
        records[id] = record
        persist(record)
        return true
    }

    /// THE HUMAN's clear — "not done with this after all" — a separate entry point on
    /// purpose (the packet: only the app may clear for `activity`, a user action is its
    /// own path). Same resulting `.neutral`, different recorded reason.
    ///
    /// Returns false for an agent this supervisor does not have and for one that was
    /// not settled, so a caller cannot mistake a no-op for a write.
    ///
    /// NOTHING CALLS THIS YET: the surface that lets a person settle or un-settle a row
    /// is a later Phase-4 ticket, and this ticket owns the writer, not its button.
    /// Pushes one event through the real `deliver` path. FOR THE CHECKS, like the
    /// `qa`-prefixed members elsewhere in this file.
    ///
    /// It exists because every event this app produces today arrives INSIDE a `send`,
    /// and `send` clears a settle itself (a user message is activity) — so there is no
    /// other way to observe what an ARRIVING event does to a still-settled agent, which
    /// is precisely what this ticket adds. The production caller it defends is Phase 5's
    /// persistent session: an rpc session comes alive, or an approval opens, without
    /// this app having just sent a prompt.
    func qaDeliver(_ event: AgentRuntimeEvent, to id: AgentID, now: Date = Date()) {
        deliver(event, to: id, now: now)
    }

    @discardableResult
    func clearSettle(agentID id: AgentID) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.clearSettle: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.settledOverride != .neutral else { return false }
        record.settledOverride = .neutral
        settledOverrideClearReasons[id] = .user
        logSettleCleared(id, reason: .user)
        records[id] = record
        persist(record)
        return true
    }

    // MARK: - Multicast

    struct TranscriptAttachment {
        /// Complete semantic state, including any open streaming markup buffer.
        var snapshot: ManagedAgentTranscriptModel?
        /// Events strictly after the snapshot/recent-events boundary.
        var tail: AsyncStream<AgentRuntimeEvent>
    }

    /// Atomically snapshot the complete transcript and register its live tail.
    /// `AgentSupervisor` is main-actor isolated, so no delivery can interleave the
    /// snapshot read and continuation registration.
    func transcriptAttachment(for id: AgentID, reboundTo threadId: String) -> TranscriptAttachment {
        let snapshot = transcriptProjections[id]?.rebound(to: threadId)
        let recent = history[id] ?? []
        let tail = AsyncStream<AgentRuntimeEvent> { continuation in
            // Compatibility supervisors without a transcript store still use the
            // historical snapshot-then-tail contract. Production has `snapshot`
            // and therefore yields no bounded replay into its transcript.
            if snapshot == nil {
                for event in recent { continuation.yield(event) }
            }
            let token = UUID()
            subscribers[id, default: [:]][token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeSubscriber(token, for: id) }
            }
        }
        return TranscriptAttachment(snapshot: snapshot, tail: tail)
    }

    /// Snapshot-then-tail, per `ActivityStore.subscribe()`: the buffered history is
    /// yielded before the subscriber is registered, so it cannot miss an event that
    /// arrives during attach and cannot see the tail before the history.
    func events(for id: AgentID) -> AsyncStream<AgentRuntimeEvent> {
        let replay = history[id] ?? []
        return AsyncStream { continuation in
            for event in replay {
                continuation.yield(event)
            }
            let token = UUID()
            subscribers[id, default: [:]][token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeSubscriber(token, for: id) }
            }
        }
    }

    func subscriberCount(for id: AgentID) -> Int {
        subscribers[id]?.count ?? 0
    }

    /// How many `delegate_agent` runs are currently bound and being tailed.
    /// Read-only, no production caller — the same reason
    /// `subscriberCount(for:)` exists.
    var observedRunBindingCount: Int { observedRunBindings.count }

    // MARK: - QA observer counts (M1.4, `.plans/46`)

    /// Of the four things `ManagedAgentTileNSView.detach()` releases, only the
    /// event subscription was observable — `subscriberCount(for:)`. These three
    /// expose the rest, because the leak they witness is not equal in kind.
    ///
    /// `turnCapabilityObservers` is a **flat, un-keyed** dictionary: every entry is
    /// invoked for *every* agent's capability change, and the tile filters after
    /// the fact by comparing `changed == attachedAgentID`. So one leaked entry from
    /// one dead tile keeps running on every agent in the app, forever. The other
    /// two are per-agent and prune their inner map on removal, which makes their
    /// assertion crisp: after a sweep the outer key must be gone.
    var qaTurnCapabilityObserverCount: Int { turnCapabilityObservers.count }

    func qaRuntimeObservationObserverCount(for id: AgentID) -> Int {
        runtimeObservationObservers[id]?.count ?? 0
    }

    func qaDisplayNameObserverCount(for id: AgentID) -> Int {
        displayNameObservers[id]?.count ?? 0
    }

    private func removeSubscriber(_ token: UUID, for id: AgentID) {
        subscribers[id]?.removeValue(forKey: token)
        if subscribers[id]?.isEmpty == true { subscribers.removeValue(forKey: id) }
    }

    // MARK: - Transcript persistence (C4)

    /// Feeds one provider event into the durable semantic document, then
    /// schedules a save. A no-op with no `transcriptStore` injected, which is
    /// every check that does not pass one.
    private func ingestTranscriptEvent(_ event: AgentRuntimeEvent, for id: AgentID) {
        guard transcriptStore != nil else { return }
        var projection = transcriptProjections[id]
            ?? ManagedAgentTranscriptModel(threadId: Self.threadId(for: id))
        projection.ingest(event)
        transcriptProjections[id] = projection
        scheduleTranscriptPersist(for: id, final: Self.isTranscriptPersistBoundary(event))
    }

    /// Echoes the user's own prompt into the durable document. `send` used to
    /// rely entirely on the tile calling `appendUserPrompt` for this; a
    /// tile-less agent (fan-out's common case) never had a tile to ask.
    private func recordTranscriptUserPrompt(_ prompt: AgentPrompt, for id: AgentID) {
        guard transcriptStore != nil else { return }
        guard let promptID = AgentNodeID(rawValue: "supervisor-prompt-\(UUID().uuidString)") else { return }
        var projection = transcriptProjections[id]
            ?? ManagedAgentTranscriptModel(threadId: Self.threadId(for: id))
        projection.appendUserPrompt(id: promptID, prompt: prompt)
        transcriptProjections[id] = projection
        // A user's own words must not wait behind the streaming debounce below.
        scheduleTranscriptPersist(for: id, final: true)
    }

    // MARK: - B5 command classifier

    /// Capability facts for `AgentCommandExecutionPlanner`.
    ///
    /// **This comment used to describe something the body does not do**, and the
    /// difference is a live defect rather than a documentation nicety. It claimed
    /// the facts came "from the BOUND runner's harness rather than a stored
    /// preference — the same rule `turnSnapshot` already follows", and that
    /// "every compiled runner today is one-shot". Both were false by 2026-08-25:
    /// the body switches on `records[id]?.harness`, which IS the stored record and
    /// not the bound runner, and `PiRpcAgentRunner`/`PiRpcTransport` ship a
    /// session runner with `steer`, `interrupt` and a generic `command`.
    ///
    /// The consequence is `.plans/49` §3.4: a pi agent whose rpc runner is bound
    /// and can genuinely take `/compact` is told it cannot, because this returns
    /// `.oneShotProse` for `.pi` unconditionally. Fixing that means consulting the
    /// bound runner the way `AgentSessionRunning.sessionCapabilities` already does
    /// for steer — deliberately NOT done here, because it changes what the
    /// composer offers and belongs with the rest of the advertise-then-refuse
    /// work, not smuggled in behind a comment correction.
    ///
    /// Measured 2026-08-24: `claude -p` interprets `/help`, `/status`,
    /// `/compact` itself (synthetic zero-token replies); `codex exec --json`
    /// and `pi -p --mode json` both hand the literal text to the model, which
    /// spends a real paid turn answering conversationally.
    private func sessionCommandCapabilities(for id: AgentID) -> AgentSessionCommandCapabilities {
        switch records[id]?.harness {
        case .claudeCode: return .claudeOneShot
        case .codex, .pi, nil: return .oneShotProse
        }
    }

    /// B7.2 — `/clear`, in one transaction. `/clear` alone used to be
    /// accidentally-fine only because nothing else was wired: it appended a
    /// notice and left the stale context meter, the disarmed naming funnel,
    /// the orphaned subagent chips, and the un-reset replay/telemetry state
    /// all in place. Every effect below commits together in this one method
    /// (all in-memory writes, then one persist, then the notice); there is no
    /// intermediate state where only some of them have happened.
    private func performClearCommand(_ descriptor: AgentCommandDescriptor, for id: AgentID) {
        guard var record = records[id] else { return }

        // 1. Rotate the session. claude only — pi's session id is Array's own
        //    (no forking needed) and codex has no established rotate
        //    mechanism. `/clear` spends no turn, same as every other
        //    Array-owned command, so this MARKS the next launch to
        //    `--resume <current> --fork-session` rather than eagerly
        //    spawning a claude process here; `ingestRuntimeObservation`
        //    adopts the forked id and clears the marker once that launch's
        //    `system/init` reports it.
        if record.harness == .claudeCode {
            record.pendingSessionForkFrom = record.providerSessionId ?? Self.claudeSessionId(for: id)
        }

        // 2. The stale-but-numeric context meter must not re-seed from a
        //    conversation the harness is about to forget.
        record.lastContextWindow = nil

        // 3. Re-arm naming: both fields the funnel actually checks
        //    (`displayNameSource == .sentinel && namingRequest == nil`) —
        //    B7.0 is exactly the story of a half-disarm going unnoticed.
        record.displayNameSource = .sentinel
        record.namingRequest = nil

        records[id] = record
        persist(record)

        // 4. Drop subagent chips: sever the parent link for every child
        //    spawned under this thread, so the supervisor's own bookkeeping
        //    agrees with the fact that a forked/cleared conversation cannot
        //    see them anymore — the disagreement C10 was making visible.
        for childID in children(of: id) {
            guard var child = records[childID] else { continue }
            child.parentAgentID = nil
            records[childID] = child
            persist(child)
        }

        // 5. Clear the 500-entry replay buffer (`history[id]`) and the live
        //    cumulative context-window cache (`contextWindowSnapshots[id]`
        //    — the in-memory counterpart to the persisted
        //    `record.lastContextWindow` cleared in step 2).
        history[id] = []
        contextWindowSnapshots[id] = nil

        // 6. The boundary, as a Tier A notice — the transcript keeps its
        //    history and says where the model's memory ends.
        appendArrayOwnedCommandNotice(descriptor, for: id)
    }

    /// Tier A of the classifier: Array performs the command itself and authors
    /// the reply as a `.system` notice, never as text sent to the CLI. No new
    /// runtime event, no I5 pressure — `AgentTranscriptProjection.appendNotice`
    /// is already idempotent and already carries `provenance: .localNotice`.
    private func appendArrayOwnedCommandNotice(_ descriptor: AgentCommandDescriptor, for id: AgentID) {
        guard transcriptStore != nil else { return }
        let (title, body) = Self.arrayOwnedCommandNoticeText(descriptor, record: records[id])
        var projection = transcriptProjections[id]
            ?? ManagedAgentTranscriptModel(threadId: Self.threadId(for: id))
        projection.appendNotice(id: "array-command-\(descriptor.id)", title: title, text: body)
        transcriptProjections[id] = projection
        scheduleTranscriptPersist(for: id, final: true)
    }

    private static func arrayOwnedCommandNoticeText(
        _ descriptor: AgentCommandDescriptor, record: AgentRecord?
    ) -> (title: String, body: String) {
        switch descriptor.name {
        case "clear":
            return (
                "Conversation cleared",
                "Array marked a fresh boundary here. Earlier turns remain in this transcript but are no longer part of the active context."
            )
        case "status":
            let harness = record?.harness?.rawValue ?? "unassigned"
            let model = record?.model ?? "default"
            return ("Agent status", "Harness: \(harness) · Model: \(model)")
        case "help":
            let names = AgentCommandCatalog.arrayCommands().map { "/\($0.name)" }.joined(separator: ", ")
            return ("Array commands", names)
        default:
            return (descriptor.name.capitalized, descriptor.detail ?? "Handled by Array.")
        }
    }

    /// A turn's outcome or an error/stop is a real boundary worth writing
    /// immediately; everything else (principally `contentDelta`, which arrives
    /// per token) is debounced the same 200ms the tile used to debounce it by.
    private static func isTranscriptPersistBoundary(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case .turnCompleted, .runtimeError, .sessionStateChanged(.stopped), .sessionStateChanged(.error):
            return true
        default:
            return false
        }
    }

    private func scheduleTranscriptPersist(for id: AgentID, final: Bool) {
        guard let store = transcriptStore else { return }
        // Assistant/reasoning content deltas parse into blocks off a scheduled
        // deadline (the tile drove that off a real `RunLoop` timer); nothing
        // here runs that clock, so a boundary write must flush the pending
        // streaming markup itself or the just-streamed reply is silently
        // absent from what gets saved.
        if final, var projection = transcriptProjections[id] {
            _ = projection.flushPendingStreamingMarkup()
            transcriptProjections[id] = projection
        }
        guard let document = transcriptProjections[id]?.document else { return }
        let sessionID = AgentTranscriptStore.canonicalSessionID(for: id)
        transcriptPersistenceTasks[id]?.cancel()
        transcriptPersistenceTasks[id] = Task { [weak self] in
            if !final { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled, let self else { return }
            try? await store.saveSnapshot(agentID: id, sessionID: sessionID, document: document)
            self.transcriptPersistenceTasks.removeValue(forKey: id)
        }
    }

    // MARK: - B4 follow-up queue

    /// Synchronous snapshot for the tile/composer to render pending chips.
    /// Hydrates the cache from durable storage on first read for an agent this
    /// process has not queued anything for yet (e.g. restored across launch).
    func queuedMessages(for id: AgentID) -> [AgentComposerQueuedMessage] {
        if queuedMessagesCache[id] == nil { hydrateQueueCache(for: id) }
        return queuedMessagesCache[id] ?? []
    }

    /// Whether this agent's queue is held after an interrupted turn — the UI
    /// paints chips distinctly rather than implying they are about to run.
    func isQueuePaused(for id: AgentID) -> Bool {
        pausedQueues.contains(id)
    }

    private func hydrateQueueCache(for id: AgentID) {
        guard let store = submissionRecoveryStore else { return }
        queuedMessagesCache[id] = []
        Task { @MainActor [weak self] in
            let messages = await store.queuedMessages(for: id)
            guard let self else { return }
            self.queuedMessagesCache[id] = messages
            if !messages.isEmpty { self.notifyTurnCapabilitiesChanged(id) }
        }
    }

    /// Deletes one visible chip. Direct manipulation of Array's own queue,
    /// never the turn in flight — the two-verb Stop stays two verbs: the
    /// primary control still means only "interrupt the current turn".
    func cancelQueuedMessage(_ messageID: UUID, for id: AgentID) {
        guard let store = submissionRecoveryStore else { return }
        queuedMessagesCache[id]?.removeAll { $0.id == messageID }
        notifyTurnCapabilitiesChanged(id)
        runQueueOp(for: id) { await store.removeQueuedMessage(id: messageID, for: id) }
    }

    /// "Clear queued" — every chip at once, still without touching the turn in
    /// flight.
    func clearQueuedMessages(for id: AgentID) {
        guard let store = submissionRecoveryStore else { return }
        queuedMessagesCache[id] = []
        notifyTurnCapabilitiesChanged(id)
        runQueueOp(for: id) { await store.clearQueue(for: id) }
    }

    /// Explicit resume after an interrupt, distinct from the next Send: this
    /// keeps the composer untouched and drains immediately if the runner is
    /// already free.
    func resumeQueue(for id: AgentID) {
        guard pausedQueues.contains(id) else { return }
        pausedQueues.remove(id)
        notifyTurnCapabilitiesChanged(id)
        if runners[id] == nil { drainQueue(for: id) }
    }

    private func runQueueOp(for id: AgentID, _ operation: @escaping @Sendable () async -> Void) {
        guard let store = submissionRecoveryStore else { return }
        let previous = queueOpTasks[id]
        queueOpTasks[id] = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            await operation()
            guard let self else { return }
            self.queuedMessagesCache[id] = await store.queuedMessages(for: id)
            self.notifyTurnCapabilitiesChanged(id)
        }
    }

    /// Called from `clearRunner`, the one moment a runner slot actually frees.
    /// `.interrupted` holds the queue instead of draining it (see
    /// `pausedQueues`); every other outcome (`.completed`, `.failed`,
    /// `.cancelled`) writes the next queued item as an ordinary send.
    private func handleQueueOnTurnCompleted(outcome: TurnOutcome, for id: AgentID) {
        guard submissionRecoveryStore != nil else { return }
        if outcome == .interrupted {
            pausedQueues.insert(id)
            notifyTurnCapabilitiesChanged(id)
            return
        }
        guard !pausedQueues.contains(id) else { return }
        drainQueue(for: id)
    }

    private func drainQueue(for id: AgentID) {
        guard let store = submissionRecoveryStore else { return }
        let previous = queueOpTasks[id]
        queueOpTasks[id] = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            guard let message = await store.dequeueNextQueuedMessage(for: id) else { return }
            self.queuedMessagesCache[id] = await store.queuedMessages(for: id)
            self.notifyTurnCapabilitiesChanged(id)
            let prompt: AgentPrompt
            do {
                let prepared = try await self.attachmentStore.preparePromptAttachments(
                    for: id,
                    draftAttachments: message.imageAttachments
                )
                let fileReferences = message.fileReferences.map {
                    AgentPromptFileReference(
                        displayName: $0.displayName,
                        contentType: $0.contentType,
                        fileURL: URL(fileURLWithPath: $0.path)
                    )
                }
                prompt = AgentPrompt(text: message.text, imageAttachments: prepared, fileReferences: fileReferences)
            } catch {
                self.warn("AgentSupervisor: dropping queued message for agent \(id.rawValue.uuidString): attachment no longer valid")
                return
            }
            guard self.sendPrepared(PreparedAgentPrompt(prompt: prompt, expectedAgentID: id), to: id) else {
                // The runner became busy again in the same beat (a fresh
                // interactive send won the race) — put the message back rather
                // than lose it.
                await store.requeueMessageAtFront(message, for: id)
                self.queuedMessagesCache[id] = await store.queuedMessages(for: id)
                self.notifyTurnCapabilitiesChanged(id)
                return
            }
        }
    }

    private enum SubmissionRecoveryAction {
        case confirmSuccess(Date)
        case restore
    }

    /// Serialize recovery against the event order. The journal is deliberately
    /// not consumed at `.turnStarted`: only a completed turn is authoritative.
    /// Replayed completion/error events are harmless because the draft store's
    /// remove/restore operations are idempotent once the journal is gone.
    private func enqueueSubmissionRecovery(_ action: SubmissionRecoveryAction, for id: AgentID) {
        guard submissionRecoveryStore != nil else { return }
        let previous = submissionRecoveryTasks[id]
        let task = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, let store = self.submissionRecoveryStore else { return }
            do {
                switch action {
                case let .confirmSuccess(sentAt):
                    do {
                        _ = try await store.confirmSubmissionAfterAuthoritativeHandoff(for: id, sentAt: sentAt)
                    } catch {
                        // A successful provider turn cannot silently discard a
                        // draft when local acceptance persistence failed.
                        _ = try? await store.recoverSubmissionAfterAuthoritativeFailure(for: id)
                    }
                case .restore:
                    _ = try await store.recoverSubmissionAfterAuthoritativeFailure(for: id)
                }
            } catch {
                self.warn("AgentSupervisor: composer recovery remained pending for agent \(id.rawValue.uuidString)")
            }
        }
        submissionRecoveryTasks[id] = task
    }

    /// Provider callbacks are accepted only from the concrete runner generation
    /// that currently owns the agent. A terminal callback may finish a runner
    /// Stop already removed, provided no replacement generation has taken over;
    /// every nonterminal event requires exact identity.
    private func deliver(
        _ event: AgentRuntimeEvent,
        from runner: AgentRunning,
        generation: RunnerGenerationToken,
        to id: AgentID,
        now: Date = Date()
    ) {
        // Keep the latest generation after its live slot clears. A nil `runners`
        // entry is not evidence that any retired terminal event is valid: an old
        // A may unwind after replacement B has completed and cleared too.
        guard runnerGenerationTokens[id] == generation else { return }
        if runners[id] !== runner {
            guard runners[id] == nil, event.isRunnerTerminal else { return }
        }
        deliver(event, to: id, now: now)
    }

    private func deliver(_ event: AgentRuntimeEvent, to id: AgentID, now: Date = Date()) {
        // B1 — pi's persistence watermark, tracked because a stop before it costs
        // the user the whole conversation and Array is the only thing that can say
        // so. `SessionManager._persist()` (`session-manager.js:717-751`, shared by
        // json and rpc alike) holds every completed entry in memory until the
        // session has produced ONE assistant message; after that each message is
        // written synchronously before its event even reaches stdout.
        //
        // So the exposure is the FIRST turn of a brand-new session, not every stop
        // — which is why this is a watermark and not a blanket warning. Approximated
        // conservatively from the normalized stream: any assistant content or any
        // completed turn means pi has almost certainly crossed it.
        switch event {
        case let .itemStarted(_, _, kind, _) where kind == .assistantMessage:
            piPersistenceWatermarkReached.insert(id)
        case .contentDelta:
            piPersistenceWatermarkReached.insert(id)
        case let .turnCompleted(_, _, outcome, _) where outcome == .completed:
            piPersistenceWatermarkReached.insert(id)
        default:
            break
        }
        switch event {
        case let .turnCompleted(_, _, outcome, _):
            if outcome == .completed {
                enqueueSubmissionRecovery(.confirmSuccess(now), for: id)
            } else {
                enqueueSubmissionRecovery(.restore, for: id)
            }
            // B4: recorded here, read by `clearRunner` — the one moment the
            // runner slot is actually free to accept the next send. This event
            // still fires while `runners[id]` holds the OLD runner (the process
            // hop that clears it is dispatched separately, after this one).
            pendingQueueOutcome[id] = outcome
        case .runtimeError, .sessionStateChanged(.stopped), .sessionStateChanged(.error):
            enqueueSubmissionRecovery(.restore, for: id)
        default:
            break
        }
        updateTurnFacts(with: event, for: id, now: now)
        if case let .contextWindowUpdated(_, snapshot) = event {
            contextWindowSnapshots[id] = snapshot
        }
        if let record = records[id] {
            ensureLocationProjector(for: record)
            locationProjectors[id]?.ingest(event, at: now)
        }

        var buffer = history[id] ?? []
        buffer.append(event)
        if buffer.count > Self.replayCap {
            buffer.removeFirst(buffer.count - Self.replayCap)
        }
        history[id] = buffer

        // C4: fed here rather than by the tile, so a child that never gets a
        // tile (the common case at fan-out) is not silently unsaved. `deliver`
        // is where every event already carries this agent's own thread id
        // (restamped before this point), the same precondition the tile's
        // model relied on.
        ingestTranscriptEvent(event, for: id)

        // WS4: stamped inside the record block, fired once the record is stored
        // and persisted, so the live/visual half can never run against a record
        // the durable half has not finished writing.
        var pendingWatchedArrival: (AgentID, UUID?, AgentTerminalArrivalKind, AgentAwarenessDecision)?
        if var record = records[id] {
            record.lastActivityAt = max(record.lastActivityAt, now)
            // Context telemetry rides the record so a resumed session can seed
            // its meter after relaunch (rendered stale). Turn-scale cadence, and
            // only an actual change forces the write, so this adds at most one
            // AtomicWriter write per turn — never one per token.
            var contextTelemetryChanged = false
            if case let .contextWindowUpdated(_, snapshot) = event,
               record.lastContextWindow != snapshot {
                record.lastContextWindow = snapshot
                contextTelemetryChanged = true
            }
            // WS4 · A terminal event that lands while a human is ACTIVELY LOOKING
            // at this agent is a visit at the moment it lands: it counts as read
            // without demanding an exit and re-entry. Keep the watermark monotonic
            // and persist this write even though ordinary focus writes are
            // throttled; otherwise the just-read completion would reappear after a
            // relaunch.
            //
            // "Actively looking" is decided by facts sampled HERE, at arrival, from
            // live AppKit state — never by the remembered `focusedAgentID`, which
            // outlives app resignation, window ordering and modal restoration and
            // therefore marked background completions read. See
            // `AgentActiveViewFacts`.
            let watchedCompletion: Bool
            let arrivalKind: AgentTerminalArrivalKind?
            switch event {
            case .turnCompleted(_, _, let outcome, _):
                switch outcome {
                case .completed: arrivalKind = .completed
                case .failed: arrivalKind = .failed
                case .interrupted, .cancelled: arrivalKind = nil
                }
            case .runtimeError: arrivalKind = .failed
            default: arrivalKind = nil
            }
            if let arrivalKind {
                qaTerminalArrivalCount &+= 1
                let facts = activeViewFacts(for: id)
                let decision = AgentAwarenessTransition.decide(arrival: arrivalKind, facts: facts)
                qaLastArrivalFacts = facts
                qaLastArrivalDecision = decision
                if decision.advancesReadWatermark {
                    qaWatchedTerminalArrivalCount &+= 1
                    watchedCompletion = record.isUnread
                    let visited = record.lastVisitedAt.map { max($0, now) } ?? now
                    record.lastVisitedAt = visited
                    if let terminal = record.latestTerminalEvent {
                        record.acknowledgedTerminalSequence = max(
                            record.acknowledgedTerminalSequence, terminal.sequence)
                    }
                    if watchedCompletion { lastVisitedPersistAt[id] = now }
                } else {
                    watchedCompletion = false
                }
                pendingWatchedArrival = (id, record.tileId, arrivalKind, decision)
            } else {
                // Deliberately does NOT clear `qaLastArrival*`: the events that
                // trail a completion (`.sessionStateChanged(.ready)`) would erase
                // the record of the arrival a witness is about to read.
                watchedCompletion = false
            }
            // P4.4: real work un-settles the agent. Narrower than the stamp above —
            // every event is activity for the purposes of "when did this last do
            // anything", but only the `isRealActivity` set means "it is working
            // again", and `.sessionStateChanged(.ready)` in particular must not
            // (it is how a turn ENDS).
            let unsettled = Self.clearsSettledOverride(event)
                && clearSettleOnActivity(
                    &record,
                    clearKeepActivePin: Self.isRealActivity(event))
            records[id] = record
            // Only lifecycle-shaped events reach the disk. `contentDelta` arrives
            // per token and every write is an AtomicWriter write (temp file +
            // fsync + read-back), so persisting all of them would put a synchronous
            // fsync per token on the main thread. A watched completion is a
            // read-watermark exception, just like an unread-clearing focus.
            //
            // A clear forces the write regardless: `.requestOpened` and
            // `.userInputRequested` are not persist-worthy, so without this the
            // agent would read `.neutral` in memory and come back `.settled` on the
            // next launch.
            if Self.isPersistWorthy(event) || unsettled || watchedCompletion
                || contextTelemetryChanged { persist(record) }
        }
        if let pendingWatchedArrival, pendingWatchedArrival.3 != AgentAwarenessDecision.none {
            onWatchedTerminalArrival?(
                pendingWatchedArrival.0, pendingWatchedArrival.1,
                pendingWatchedArrival.2, pendingWatchedArrival.3)
        }

        for continuation in (subscribers[id] ?? [:]).values {
            continuation.yield(event)
        }

        // A spawned child's turn ending is the moment its result becomes
        // collectable: rewrite the parent's `spawn-results/<handle>.json` from
        // `spawned` to a terminal status, carrying the child's final assistant
        // text. After `ingestTranscriptEvent` above on purpose — the projection
        // must already hold this turn's last assistant entry.
        if case let .turnCompleted(_, _, outcome, errorMessage) = event {
            writeTerminalSpawnResult(for: id, outcome: outcome, errorMessage: errorMessage)
        }

        // P2D.6: the agent finished the work its item was fanned out for, so the
        // item is done. Only `.completed` — a turn that failed or was aborted has
        // not done the work, and checking the row off would lose it. Last, after
        // the record and every subscriber are consistent, because the handler is
        // the source surface re-rendering.
        if case let .turnCompleted(_, _, outcome, _) = event,
           outcome == .completed,
           let itemId = records[id]?.sourceItemId {
            completedFanOutItems.insert(itemId)
            onFanOutItemCompleted?(itemId, id)
        }
    }

    /// The child half of the `spawn_agent` result-file channel. No-op for any
    /// agent without a spawn handle (user-created agents, observed children) and
    /// for a child whose parent is gone — nothing is waiting on the file then.
    /// A later turn of the same child overwrites with its own final text: the
    /// last answer is the freshest one, and `wait_agents` only reads during the
    /// parent's own turn.
    private func writeTerminalSpawnResult(for id: AgentID, outcome: TurnOutcome, errorMessage: String?) {
        guard let child = records[id],
              let handle = child.spawnResultHandle,
              let parentID = child.parentAgentID,
              let parent = records[parentID] else { return }
        let status: SpawnResultFile.Status
        switch outcome {
        case .completed: status = .completed
        case .failed: status = .failed
        case .interrupted, .cancelled: status = .interrupted
        }
        var finalText: String?
        var finalTextTruncated: Bool?
        if status == .completed, let text = transcriptProjections[id]?.finalAssistantText {
            let capped = SpawnResultFile.cappedFinalText(text)
            finalText = capped.text
            finalTextTruncated = capped.truncated ? true : nil
        }
        SpawnResultFile.write(
            SpawnResultFile(
                toolCallId: handle,
                status: status,
                agentId: id.rawValue,
                role: child.role,
                reason: errorMessage,
                finalText: finalText,
                finalTextTruncated: finalTextTruncated,
                endedAt: Date()
            ),
            parentCwd: parent.cwd,
            warn: warn
        )
    }

    private func updateTurnFacts(with event: AgentRuntimeEvent, for id: AgentID, now: Date = Date()) {
        var facts = turnFacts[id] ?? TurnFacts()
        switch event {
        case .turnStarted:
            facts.execution = .working
            facts.didFail = false
            facts.failureMessage = nil
            // P3.3: THE elapsed anchor, stamped by the one owner of turn state at
            // the one event that means "work started now". Every other candidate is
            // a proxy: `record.lastSeenAt` is the spawn instant, and the event ring's
            // trailing working run starts at whatever synthetic draft a restore left
            // behind — which is the 158-hour reading the sidebar was showing.
            // Provider adapters may repeat a start boundary while one user turn
            // is still active (for example around nested/subagent protocol
            // cycles). A repeated boundary is activity, but it is not a new
            // elapsed-time origin. Preserve the oldest authoritative stamp until
            // a terminal event clears it; this keeps every provider and every
            // surface on one honest clock.
            facts.turnStartedAt = facts.turnStartedAt.map { min($0, now) } ?? now
            if var record = records[id] {
                // P6.2: a turn start is real activity; the surrounding event
                // delivery may still update metadata for non-activity events.
                record.latestTurnAt = max(record.latestTurnAt ?? .distantPast, now)
                records[id] = record
            }
        case let .turnCompleted(_, turnID, outcome, errorMessage):
            facts.execution = .ready
            facts.didFail = outcome == .failed
            facts.failureMessage = outcome == .failed ? errorMessage : nil
            facts.turnStartedAt = nil
            facts.submittedAt = nil
            if var record = records[id] {
                // P6.3/P6.4: completion is both a possible raised hand and the
                // durable source for the unread axis. It is stamped at the actual
                // switch arm, not inferred from lastActivityAt.
                record.runCompletedAt = max(record.runCompletedAt ?? .distantPast, now)
                if outcome == .failed {
                    record.failedAt = max(record.failedAt ?? .distantPast, now)
                }
                if record.latestTerminalEvent?.turnID != turnID {
                    let terminalOutcome: AgentTerminalOutcome
                    switch outcome {
                    case .completed: terminalOutcome = .succeeded
                    case .failed: terminalOutcome = .failed
                    case .interrupted: terminalOutcome = .interrupted
                    case .cancelled: terminalOutcome = .cancelled
                    }
                    record.latestTerminalEvent = AgentTerminalEvent(
                        sequence: (record.latestTerminalEvent?.sequence ?? 0) &+ 1,
                        turnID: turnID, outcome: terminalOutcome, endedAt: now)
                }
                records[id] = record
            }
        case let .sessionStateChanged(state):
            // `.running` is session/process state, not proof of an active turn.
            // Only turnStarted/turnCompleted move the execution fact.
            if state == .error {
                facts.execution = .ready
                facts.didFail = true
                facts.turnStartedAt = nil
                facts.submittedAt = nil
            facts.submittedAt = nil
                if var record = records[id] {
                    record.failedAt = max(record.failedAt ?? .distantPast, now)
                    records[id] = record
                }
            } else if state == .stopped || state == .ready {
                facts.execution = .ready
                facts.turnStartedAt = nil
                facts.submittedAt = nil
            facts.submittedAt = nil
            }
        case let .requestOpened(_, requestID, kind):
            let request = AgentPendingRequest(
                requestID: requestID,
                prompt: kind.compiledRequestPrompt,
                responseMode: .fixedChoice(ApprovalDecision.compiledChoices),
                // P3.3: stated by the event that produced it. An approval is an
                // approval because the adapter opened one and is holding it, not
                // because its choice list happened to be non-empty.
                kind: .approval
            )
            facts.pendingRequests[requestID] = request
            if !facts.requestOrder.contains(requestID) { facts.requestOrder.append(requestID) }
        case let .userInputRequested(_, requestID, questions):
            // User-input events carry prompt text but no compiled response-mode
            // capability. Empty choices therefore remain fixed-choice([]), never a
            // fabricated freeform editor — and, since P3.3, never evidence of the
            // request's KIND either: `.fixedChoice([])` is what an approval with no
            // decisions would compile to as well.
            let prompt = questions.map(\.prompt).filter { !$0.isEmpty }.joined(separator: " ")
            let request = AgentPendingRequest(
                requestID: requestID,
                prompt: prompt.isEmpty ? "Provider requested input" : prompt,
                responseMode: .fixedChoice([]),
                kind: .input
            )
            facts.pendingRequests[requestID] = request
            if !facts.requestOrder.contains(requestID) { facts.requestOrder.append(requestID) }
        case let .requestResolved(_, requestID, _), let .userInputResolved(_, requestID):
            facts.pendingRequests.removeValue(forKey: requestID)
            facts.requestOrder.removeAll { $0 == requestID }
        case let .runtimeError(threadID, message):
            facts.execution = .ready
            facts.didFail = true
            facts.failureMessage = message
            facts.turnStartedAt = nil
            facts.submittedAt = nil
            if var record = records[id] {
                record.failedAt = max(record.failedAt ?? .distantPast, now)
                record.runCompletedAt = max(record.runCompletedAt ?? .distantPast, now)
                let eventID = threadID.map { "runtime:\($0)" }
                if record.latestTerminalEvent?.turnID != eventID
                    || record.latestTerminalEvent?.outcome != .runtimeError {
                    record.latestTerminalEvent = AgentTerminalEvent(
                        sequence: (record.latestTerminalEvent?.sequence ?? 0) &+ 1,
                        turnID: eventID, outcome: .runtimeError, endedAt: now)
                }
                records[id] = record
            }
        case .itemStarted, .itemCompleted, .contentDelta, .tokenUsageUpdated,
             .contextWindowUpdated, .childAgentSpawned, .semanticSignal:
            break
        }
        // The invariant this file owns, asserted in `--agent-supervisor-check`: a
        // stamped start exists exactly while a turn is in flight, so a stale anchor
        // can never outlive the turn it measured.
        assert((facts.turnStartedAt != nil) == (facts.execution == .working),
               "turnStartedAt must be non-nil exactly while execution is working")
        turnFacts[id] = facts
    }

    nonisolated static func isPersistWorthy(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case .sessionStateChanged, .turnStarted, .turnCompleted, .childAgentSpawned, .runtimeError:
            return true
        case .itemStarted, .itemCompleted, .contentDelta, .requestOpened,
             .requestResolved, .userInputRequested, .userInputResolved, .tokenUsageUpdated,
             .contextWindowUpdated, .semanticSignal:
            return false
        }
    }

    private func clearRunner(
        _ runner: AgentRunning,
        generation: RunnerGenerationToken,
        for id: AgentID
    ) {
        // Identity-checked: a `send` that started while the previous prompt was
        // finishing must not have its runner cleared by the old one's completion.
        if runnerGenerationTokens[id] == generation, runners[id] === runner {
            // Claude owns mirrored children inside this process. If it exits or
            // crashes before their matching tool_result, no later transport can
            // close them. Codex is deliberately excluded: its provider children
            // can drain after the parent turn completes.
            interruptWorkingClaudeMirroredChildren(of: id)
            runners[id] = nil
            if runner.keepsSessionAliveBetweenTurns && runner.canAcceptAnotherTurn {
                idleSessionRunners[id] = runner
            }
            notifyTurnCapabilitiesChanged(id)
            // B4: this is the actual moment the runner slot frees, not the
            // `.turnCompleted` event itself — that event still fires while
            // `runners[id]` holds this very runner, so draining there would
            // refuse against an occupied slot every time.
            if let outcome = pendingQueueOutcome.removeValue(forKey: id) {
                handleQueueOnTurnCompleted(outcome: outcome, for: id)
            }
        }
    }

    private func interruptWorkingClaudeMirroredChildren(of parentID: AgentID) {
        guard records[parentID]?.harness == .claudeCode else { return }
        for childID in children(of: parentID) {
            guard records[childID]?.capabilities == .observedReadOnly,
                  records[childID]?.harness == .claudeCode,
                  turnFacts[childID]?.execution == .working else { continue }
            deliver(.turnCompleted(
                threadId: Self.threadId(for: childID),
                turnId: "\(Self.threadId(for: childID))#claude-parent-ended",
                outcome: .interrupted,
                errorMessage: "The Claude parent ended before this mirrored child reported a result."
            ), to: childID)
        }
    }

    /// Failure-time diagnostics that survive the process. The supervisor's other
    /// trail is `fputs(stderr)`/`warn`, which for a GUI app launched via `open`
    /// goes to /dev/null — so WHY a runner died was unrecoverable after the fact.
    /// One line per failure, redacted upstream by `SecretRedactor` (never prompt
    /// text or command bodies), appended under the app-support root the store
    /// already owns — which is what keeps checks off the real file. Rotated at
    /// 1 MB to a single `.old`; never on a hot path.
    private func appendAgentDiagnostics(_ message: String, agentID: AgentID) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) "
            + "agent=\(agentID.rawValue.uuidString) \(message)\n"
        let url = store.layout.applicationSupportDirectory
            .appendingPathComponent("agent-diagnostics.log", isDirectory: false)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 1_048_576 {
            let old = url.appendingPathExtension("old")
            try? fileManager.removeItem(at: old)
            try? fileManager.moveItem(at: url, to: old)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func persist(_ record: AgentRecord) {
        do {
            let persisted = try withAgentStoreLock {
                var candidate = record
                // Ordinary mutations (rename, tile binding, lifecycle, and
                // activity) may come from a supervisor restored before another
                // supervisor allocated a child. Read the durable parent while the
                // same store-level lock is held and never lower its high-water.
                let durable = try store.load(id: record.id)
                if let durable {
                    candidate.nextChildOrdinal = max(
                        candidate.nextChildOrdinal,
                        durable.nextChildOrdinal
                    )
                }
                try upsertRecord(candidate)
                return (record: candidate, previousDisplayName: durable?.displayName)
            }
            // Keep the live copy coherent too: a stale parent write that was
            // merged upward must not leave this supervisor holding the old value.
            records[record.id] = persisted.record
            if persisted.previousDisplayName != persisted.record.displayName {
                notifyDisplayNameChanged(for: persisted.record)
            }
        } catch {
            warn("AgentSupervisor: could not persist agent \(record.id.rawValue.uuidString): \(error)")
        }
    }
}

extension AgentSupervisor: AgentTileActionSink {}

private extension AgentRuntimeEvent {
    var isRunnerTerminal: Bool {
        switch self {
        case .turnCompleted, .runtimeError,
             .sessionStateChanged(.stopped), .sessionStateChanged(.error):
            return true
        case .sessionStateChanged, .turnStarted, .itemStarted, .itemCompleted,
             .contentDelta, .requestOpened, .requestResolved, .userInputRequested,
             .userInputResolved, .tokenUsageUpdated, .contextWindowUpdated,
             .childAgentSpawned, .semanticSignal:
            return false
        }
    }
}

private extension AgentTileOperationalState {
    var acceptsNewTurn: Bool {
        switch self {
        case .ready, .failed, .restored: return true
        case .starting, .working, .queued, .needsAction: return false
        }
    }
}

// MARK: - Self-check

@MainActor
private final class ScriptedTileActionSink: AgentTileActionSink {
    var acceptance: IntentAcceptance
    private(set) var intents: [(AgentComposerIntent, AgentID)] = []

    init(_ acceptance: IntentAcceptance) { self.acceptance = acceptance }

    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
        intents.append((intent, agentID))
        return acceptance
    }
}

/// Deterministic write faults for the child-claim recovery witness. The production
/// initializer leaves this seam nil, so the real path remains AgentStore/AtomicWriter.
private enum AgentSupervisorCheckWriteFault: Error {
    case beforeRename
    case afterRename
}

private final class AgentSupervisorCheckWriteState {
    var didInjectPostCommitFault = false
}

/// A runner that emits a fixed script instead of spawning Pi. `holdUntilStopped`
/// blocks `run` after the script until `stop()` arrives, which is how the stop path
/// is exercised without a real process.
final class ScriptedAgentRunner: AgentRunning, @unchecked Sendable {
    private let script: [AgentRuntimeEvent]
    private let runtimeObservations: [AgentRuntimeObservation]
    private let holdUntilStopped: Bool
    private let releaseOnStop: Bool
    private let runError: Error?
    /// Thrown AFTER `released.wait()` returns — i.e. as a consequence of `stop()`.
    /// M1.9 (`.plans/46`).
    ///
    /// `runError` above is thrown before `run` ever blocks, so it can model "failed
    /// to start" and nothing else. Production's shape is the opposite: `stop()` is
    /// non-throwing (`AgentRunning` declares it so, and the supervisor calls it
    /// unqualified), it SIGTERMs the child, and `run()` throws on the way out
    /// because the CLI exited non-zero. This is that. Every one of the seven
    /// existing `supervisor.stop(_:)` checks drives a runner whose `run` falls
    /// through to a normal return after the semaphore, which is exactly why they
    /// were all green while a Stop was being recorded as a failure.
    private let stopError: Error?
    private let persistentBetweenTurns: Bool
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopCountStorage = 0
    private var runCountStorage = 0
    private var completedRunStorage = 0
    private var promptsStorage: [String] = []
    private var agentPromptsStorage: [AgentPrompt] = []
    private var liveHandler: (@Sendable (AgentRuntimeEvent) -> Void)?
    private var spawnHandler: (@Sendable (SpawnRequest) -> Void)?
    private var runtimeObservationHandler: (@Sendable (AgentRuntimeObservation) -> Void)?

    init(
        script: [AgentRuntimeEvent],
        runtimeObservations: [AgentRuntimeObservation] = [],
        holdUntilStopped: Bool = false,
        releaseOnStop: Bool = true,
        runError: Error? = nil,
        stopError: Error? = nil,
        persistentBetweenTurns: Bool = false
    ) {
        self.script = script
        self.runtimeObservations = runtimeObservations
        self.holdUntilStopped = holdUntilStopped
        self.releaseOnStop = releaseOnStop
        self.runError = runError
        self.stopError = stopError
        self.persistentBetweenTurns = persistentBetweenTurns
    }

    var keepsSessionAliveBetweenTurns: Bool { persistentBetweenTurns }
    var canAcceptAnotherTurn: Bool {
        persistentBetweenTurns && lock.withLock { stopCountStorage == 0 }
    }

    var stopCount: Int { lock.withLock { stopCountStorage } }
    var runCount: Int { lock.withLock { runCountStorage } }
    /// Incremented only once `run` has actually RETURNED. The distinction is the
    /// point (from the cross-review): `stop` clears `runners[id]` synchronously, so
    /// `isRunning == false` proves a dictionary entry went away and nothing about
    /// the blocked call. This counter is the only witness that the runner exited.
    var completedRuns: Int { lock.withLock { completedRunStorage } }
    var prompts: [String] { lock.withLock { promptsStorage } }
    var agentPrompts: [AgentPrompt] { lock.withLock { agentPromptsStorage } }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        lock.withLock {
            runCountStorage += 1
            promptsStorage.append(prompt.text)
            agentPromptsStorage.append(prompt)
            liveHandler = onEvent
        }
        if let runError { throw runError }
        if let observer = lock.withLock({ runtimeObservationHandler }) {
            for observation in runtimeObservations { observer(observation) }
        }
        for event in script { onEvent(event) }
        if holdUntilStopped { released.wait() }
        if let stopError {
            lock.withLock {
                completedRunStorage += 1
                liveHandler = nil
            }
            throw stopError
        }
        lock.withLock {
            completedRunStorage += 1
            liveHandler = nil
        }
    }

    /// Emits one more event from the turn that is CURRENTLY BLOCKED in `run`, i.e.
    /// from a runner the supervisor still holds. `false` when no run is in flight, so
    /// a check cannot mistake "the agent produced nothing" for "the agent was gone".
    /// P2A.5 needs it: proving a detached agent still delivers to the supervisor takes
    /// an event produced AFTER the detach, and `send` is (correctly) refused while a
    /// prompt is in flight.
    func emit(_ event: AgentRuntimeEvent) -> Bool {
        guard let handler = lock.withLock({ liveHandler }) else { return false }
        handler(event)
        return true
    }

    func stop() {
        lock.withLock { stopCountStorage += 1 }
        if releaseOnStop { released.signal() }
    }

    /// Lets a check retire a runner, install its replacement, and only then allow
    /// the old blocking `run` call to return. Production runners can unwind after
    /// Stop on the same schedule, so this makes supersession deterministic.
    func releaseRunAfterStop() { released.signal() }

    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        lock.withLock { spawnHandler = handler }
    }

    func observeRuntimeObservations(
        _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void
    ) {
        lock.withLock { runtimeObservationHandler = handler }
    }

    /// Fires the side channel the supervisor registered, as a provider stream would.
    /// `false` when nothing is observing, so a check cannot mistake "the supervisor
    /// never wired the channel" for "the request was refused".
    func emit(spawn request: SpawnRequest) -> Bool {
        guard let handler = lock.withLock({ spawnHandler }) else { return false }
        handler(request)
        return true
    }
}

@MainActor
private func runComposerKeyContractChecks() throws -> Int {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError { CheckError(description: "composer key contract: \(message)") }
    func event(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { throw fail("could not create synthetic key event") }
        return event
    }

    guard ComposerKeyPolicy.action(
        for: try event(keyCode: 36, characters: "\r"),
        hasMarkedText: false,
        hasTrimmedContent: false,
        suggestionsVisible: false,
        hasAttachments: true
    ) == .send else {
        throw fail("image-only Return did not select the send route")
    }
    guard ComposerKeyPolicy.action(
        for: try event(keyCode: 36, characters: "\r"),
        hasMarkedText: false,
        hasTrimmedContent: false,
        suggestionsVisible: false
    ) == .nativeTextSystem else {
        throw fail("truly empty Return was not rejected")
    }

    // Exercise the production composer and its required observer contract, not a
    // private protocol conformer or process-global notification that can mask a
    // dropped intent. P5.4 will bind this already-compiled seam to the live tile.
    let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
    let textView = composer.textView
    var sendCount = 0
    var submittedPrompt: String?
    var dismissCount = 0
    composer.onSubmitPrompt = { prompt in
        sendCount += 1
        submittedPrompt = prompt
    }
    composer.onDismissSuggestions = { dismissCount += 1 }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = composer
    window.makeKey()
    guard window.makeFirstResponder(textView) else {
        throw fail("could not install production composer text view as real first responder")
    }
    func dispatch(_ event: NSEvent) { window.sendEvent(event) }
    func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try event(keyCode: code, characters: characters, modifiers: modifiers, windowNumber: window.windowNumber)
    }

    textView.string = "send this"
    textView.setSelectedRange(NSRange(location: 9, length: 0))
    dispatch(try key(36, "\r"))
    guard sendCount == 1, submittedPrompt == "send this", textView.string == "send this" else {
        throw fail("plain Return with content did not emit exactly one send without editing")
    }

    dispatch(try key(36, "\r", .shift))
    guard sendCount == 1, textView.string == "send this\n" else {
        throw fail("Shift+Return did not stay on the native newline path")
    }

    let beforeModifiedReturn = textView.string
    dispatch(try key(36, "\r", .command))
    guard sendCount == 1, textView.string == beforeModifiedReturn else {
        throw fail("Command+Return was repurposed or did not preserve native text behavior")
    }
    dispatch(try key(36, "\r", .option))
    guard sendCount == 1, textView.string == beforeModifiedReturn + "\n" else {
        throw fail("Option+Return was repurposed or did not preserve native newline behavior; got '\(textView.string)'")
    }

    textView.string = "   "
    textView.setSelectedRange(NSRange(location: 3, length: 0))
    dispatch(try key(36, "\r"))
    guard sendCount == 1, textView.string == "   \n" else {
        throw fail("whitespace-only Return sent instead of remaining native editing")
    }

    textView.string = "compose "
    textView.setSelectedRange(NSRange(location: 8, length: 0))
    textView.setMarkedText("候", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 8, length: 0))
    guard textView.hasMarkedText() else { throw fail("marked-text setup did not enter IME composition") }
    dispatch(try key(36, "\r"))
    // A synthetic key event has no live input manager/candidate window, so AppKit
    // replaces this artificial marked range with its native Return edit. Assert that
    // observable edit rather than pretending `unmarkText()` proves an IME commit:
    // the policy assertion below owns the crucial contract that marked Return is
    // forwarded, while a real IME remains responsible for choosing its candidate.
    guard ComposerKeyPolicy.action(
            for: try key(36, "\r"),
            hasMarkedText: true,
            hasTrimmedContent: true,
            suggestionsVisible: false
          ) == .nativeTextSystem,
          sendCount == 1,
          !textView.hasMarkedText(),
          textView.string == "compose \n",
          textView.selectedRange() == NSRange(location: 9, length: 0) else {
        throw fail("Return during marked IME text did not traverse AppKit's native input path without sending; got '\(textView.string)' / \(textView.selectedRange())")
    }

    textView.suggestionsAreVisible = true
    dispatch(try key(53, "\u{1b}"))
    guard dismissCount == 1, sendCount == 1, !textView.suggestionsAreVisible else {
        throw fail("Escape did not dismiss suggestions first, or unexpectedly emitted send/stop-like work")
    }
    dispatch(try key(53, "\u{1b}"))
    guard dismissCount == 1 else {
        throw fail("Escape without suggestions was consumed by the composer")
    }

    textView.string = "/rev old tail"
    let originalSelection = NSRange(location: 5, length: 3)
    textView.setSelectedRange(originalSelection)
    textView.undoManager?.removeAllActions()
    textView.insertCompletion("reviewer", replacementRange: NSRange(location: 0, length: 8))
    guard textView.string == "reviewer tail", textView.selectedRange() == NSRange(location: 8, length: 0),
          textView.undoManager?.canUndo == true else {
        throw fail("completion insertion did not replace the query as one undoable native edit")
    }
    textView.undoManager?.undo()
    guard textView.string == "/rev old tail", textView.selectedRange() == originalSelection else {
        throw fail("one undo did not restore completion text and selection; got '\(textView.string)' / \(textView.selectedRange())")
    }

    // P4.5: drive history through the same production composer and real TextKit
    // layout. The live tile binds this already-compiled seam in P5.4.
    let promptHistory = AgentPromptHistory(capacityPerAgent: 4)
    let historyAgentA = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009451")!)
    let historyAgentB = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009452")!)
    composer.bindPromptHistory(promptHistory, agentID: historyAgentA)
    composer.onSubmitPrompt = nil
    var shouldAcceptHistorySend = false
    var historySendAttempts = 0
    composer.onSubmitIntent = { _ in
        historySendAttempts += 1
        return shouldAcceptHistorySend
    }
    var historyAssertions = 0
    func installHistoryText(_ value: String, selection: NSRange) {
        textView.string = value
        textView.setSelectedRange(selection)
        textView.layoutManager?.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: (value as NSString).length),
            actualCharacterRange: nil
        )
        composer.layoutSubtreeIfNeeded()
    }
    let upArrow = try key(126, "\u{f700}")
    let downArrow = try key(125, "\u{f701}")

    installHistoryText("rejected prompt", selection: NSRange(location: 15, length: 0))
    dispatch(try key(36, "\r"))
    guard historySendAttempts == 1,
          promptHistory.count(for: historyAgentA) == 0,
          textView.string == "rejected prompt" else {
        throw fail("a rejected send entered history or cleared its draft")
    }
    historyAssertions += 1

    installHistoryText("   ", selection: NSRange(location: 3, length: 0))
    dispatch(try key(36, "\r"))
    guard historySendAttempts == 1, promptHistory.count(for: historyAgentA) == 0 else {
        throw fail("a whitespace-only native Return entered accepted prompt history")
    }
    historyAssertions += 1

    shouldAcceptHistorySend = true
    for prompt in ["accepted one", "accepted two", "accepted two"] {
        installHistoryText(prompt, selection: NSRange(location: (prompt as NSString).length, length: 0))
        dispatch(try key(36, "\r"))
        guard textView.string.isEmpty else {
            throw fail("an accepted history send did not clear the submitted draft")
        }
    }
    guard historySendAttempts == 4,
          promptHistory.count(for: historyAgentA) == 2,
          promptHistory.acceptedSubmissionCount(for: historyAgentA) == 3 else {
        throw fail("accepted sends were not recorded exactly once with adjacent deduplication")
    }
    historyAssertions += 2

    composer.bindPromptHistory(promptHistory, agentID: historyAgentB)
    installHistoryText("agent B draft", selection: NSRange(location: 0, length: 0))
    dispatch(upArrow)
    guard textView.string == "agent B draft",
          !promptHistory.isNavigating(for: historyAgentB) else {
        throw fail("history crossed AgentID when agent B pressed Up")
    }
    historyAssertions += 1
    composer.bindPromptHistory(promptHistory, agentID: historyAgentA)

    promptHistory.cancelNavigation(for: historyAgentA)
    let multilineDraft = "first visual line\nsecond visual line"
    installHistoryText(
        multilineDraft,
        selection: NSRange(location: (multilineDraft as NSString).length, length: 0)
    )
    let multilineEnd = textView.selectedRange().location
    dispatch(upArrow)
    guard textView.string == multilineDraft,
          textView.selectedRange().location < multilineEnd,
          !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up inside multiline text did not remain native")
    }
    historyAssertions += 1

    installHistoryText(multilineDraft, selection: NSRange(location: 2, length: 0))
    dispatch(upArrow)
    guard textView.string == "accepted two", promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up on the first visual line did not enter the newest history item")
    }
    historyAssertions += 1
    dispatch(upArrow)
    guard textView.string == "accepted one" else {
        throw fail("repeated Up did not walk toward older accepted prompts")
    }
    historyAssertions += 1
    dispatch(downArrow)
    guard textView.string == "accepted two", promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Down in history did not walk toward newer accepted prompts")
    }
    historyAssertions += 1
    dispatch(downArrow)
    guard textView.string == multilineDraft, !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Down beyond newest history did not restore the exact multiline draft")
    }
    historyAssertions += 1

    promptHistory.recordAccepted("history first\nhistory second", for: historyAgentA)
    installHistoryText("boundary draft", selection: NSRange(location: 0, length: 0))
    dispatch(upArrow)
    guard textView.string == "history first\nhistory second",
          promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("the multiline history fixture did not enter history mode")
    }
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    dispatch(downArrow)
    guard textView.string == "history first\nhistory second",
          promptHistory.isNavigating(for: historyAgentA),
          textView.selectedRange().location > 2 else {
        throw fail("Down before the last visual line did not remain native")
    }
    historyAssertions += 1
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    dispatch(downArrow)
    guard textView.string == "boundary draft", !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Down on the last visual line did not restore the preserved draft")
    }
    historyAssertions += 1

    promptHistory.cancelNavigation(for: historyAgentA)
    let wrappedDraft = String(repeating: "wrapped text ", count: 80)
    installHistoryText(
        wrappedDraft,
        selection: NSRange(location: (wrappedDraft as NSString).length, length: 0)
    )
    let lineHeight = textView.layoutManager?.defaultLineHeight(for: textView.font ?? .token(.body)) ?? 17
    guard textView.measuredDocumentHeight() > lineHeight * 2 else {
        throw fail("soft-wrap fixture did not produce multiple TextKit visual lines")
    }
    historyAssertions += 1
    let wrappedEnd = textView.selectedRange().location
    dispatch(upArrow)
    guard textView.string == wrappedDraft,
          textView.selectedRange().location < wrappedEnd,
          !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up inside a soft-wrapped line did not remain native")
    }
    historyAssertions += 1
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    dispatch(upArrow)
    guard textView.string == "history first\nhistory second",
          promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up on the first soft-wrapped visual line did not enter history")
    }
    historyAssertions += 1
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    dispatch(downArrow)
    guard textView.string == wrappedDraft, !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("soft-wrapped history navigation did not restore its exact draft")
    }
    historyAssertions += 1

    for modifiers: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
        promptHistory.cancelNavigation(for: historyAgentA)
        installHistoryText("modified arrow", selection: NSRange(location: 0, length: 0))
        dispatch(try key(126, "\u{f700}", modifiers))
        guard textView.string == "modified arrow",
              !promptHistory.isNavigating(for: historyAgentA) else {
            throw fail("a modified Up arrow was repurposed for prompt history")
        }
        historyAssertions += 1
    }

    promptHistory.cancelNavigation(for: historyAgentA)
    installHistoryText("selected arrow", selection: NSRange(location: 0, length: 3))
    dispatch(upArrow)
    guard textView.string == "selected arrow", !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up with a noncollapsed selection entered prompt history")
    }
    historyAssertions += 1

    promptHistory.cancelNavigation(for: historyAgentA)
    installHistoryText("trailing line\n", selection: NSRange(location: 14, length: 0))
    dispatch(upArrow)
    guard textView.string == "trailing line\n", !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up from a trailing empty visual line incorrectly entered history")
    }
    historyAssertions += 1

    installHistoryText("draft before edit", selection: NSRange(location: 0, length: 0))
    dispatch(upArrow)
    guard promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("edit-cancellation fixture did not enter history")
    }
    textView.insertText("!", replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
    let editedHistoryText = textView.string
    guard !promptHistory.isNavigating(for: historyAgentA), editedHistoryText.hasSuffix("!") else {
        throw fail("editing a recalled prompt did not cancel history navigation")
    }
    historyAssertions += 1
    dispatch(downArrow)
    guard textView.string == editedHistoryText else {
        throw fail("Down after editing a recalled prompt restored a stale preserved draft")
    }
    historyAssertions += 1

    promptHistory.cancelNavigation(for: historyAgentA)
    installHistoryText("ime arrows", selection: NSRange(location: 0, length: 0))
    textView.setMarkedText(
        "候",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 0, length: 0)
    )
    dispatch(upArrow)
    guard !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up during marked IME text entered prompt history")
    }
    textView.unmarkText()
    historyAssertions += 1

    return 13 + historyAssertions
}

private final class CompletionProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var returned = 0
    private var queries: [String] = []
    private var contexts: [AgentCompletionContext?] = []
    private var navigationPaths: [String?] = []

    func record(_ query: AgentCompletionQuery) {
        lock.withLock {
            queries.append(query.text)
            contexts.append(query.context)
            navigationPaths.append(query.navigationPath)
        }
    }
    func markStarted() { lock.withLock { started += 1 } }
    func markReturned() { lock.withLock { returned += 1 } }
    var startedCount: Int { lock.withLock { started } }
    var returnedCount: Int { lock.withLock { returned } }
    var observedQueries: [String] { lock.withLock { queries } }
    var observedContexts: [AgentCompletionContext?] { lock.withLock { contexts } }
    var observedNavigationPaths: [String?] { lock.withLock { navigationPaths } }
}

/// The stale branch deliberately ignores task cancellation and completes after a
/// newer query. This reaches the presentation generation guard directly rather
/// than being filtered by `AgentCompletionProviderRegistry` first.
private struct CompletionProbeSource: AgentCompletionSuggestionSource {
    let state: CompletionProbeState

    func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        state.record(query)
        if query.text == "s" {
            state.markStarted()
            let values = await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.18) {
                    continuation.resume(returning: [
                        AgentCompletion(id: "stale", title: "stale", insertionText: "/stale")
                    ])
                }
            }
            state.markReturned()
            return values
        }
        if query.text == "/compact" {
            return [AgentCompletion(
                id: "compact",
                title: "compact",
                insertionText: "/RAW-COMPACT-MUST-NOT-BE-INSERTED",
                payload: .runtimeCommand(ResolvedRuntimeCommand(
                    name: "compact",
                    providerHandle: "probe.compact"
                ))
            )]
        }
        if query.text == "read" {
            return [AgentCompletion(
                id: "readme-file",
                title: "README.md",
                insertionText: "@RAW-FILE-MUST-NOT-BE-INSERTED",
                payload: .file(AgentPromptFileReference(
                    displayName: "README.md",
                    contentType: "text/markdown",
                    fileURL: URL(fileURLWithPath: "/tmp/array-completion-probe/README.md")
                ))
            )]
        }
        if query.trigger == "@", query.text == "dir" {
            return [AgentCompletion(
                id: "sources-directory",
                title: "Sources/",
                insertionText: "@Sources",
                payload: .directory(DirectoryNavigationTarget(
                    directoryURL: URL(fileURLWithPath: "/tmp/array-context-a/Sources", isDirectory: true)
                ))
            )]
        }
        if query.trigger == "@", query.text.isEmpty, query.navigationPath == nil {
            return [AgentCompletion(
                id: "sources-directory",
                title: "Sources/",
                detail: "Sources/",
                insertionText: "@Sources",
                payload: .directory(DirectoryNavigationTarget(
                    directoryURL: URL(fileURLWithPath: "/tmp/array-context-a/Sources", isDirectory: true)
                ))
            )]
        }
        if query.trigger == "@", query.text.isEmpty, query.navigationPath == "Sources" {
            return [AgentCompletion(
                id: "nested-file",
                title: "Nested.swift",
                detail: "Sources/Nested.swift",
                insertionText: "@Sources/Nested.swift",
                payload: .file(AgentPromptFileReference(
                    displayName: "Nested.swift",
                    contentType: "public.swift-source",
                    fileURL: URL(fileURLWithPath: "/tmp/array-context-a/Sources/Nested.swift")
                ))
            )]
        }
        guard query.text.hasPrefix("he") else { return [] }
        return [
            AgentCompletion(id: "help", title: "help", insertionText: "/help"),
            AgentCompletion(id: "hello", title: "hello", insertionText: "/hello"),
        ]
    }
}

@MainActor
private func runCompletionComposerChecks() async throws -> Int {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError {
        CheckError(description: "composer completion contract: \(message)")
    }
    func event(keyCode: UInt16, characters: String, windowNumber: Int) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { throw fail("could not make a synthetic key event") }
        return event
    }

    let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
    let textView = composer.textView
    let state = CompletionProbeState()
    composer.qaBindCompletionSource(CompletionProbeSource(state: state))
    let window = NSWindow(
        contentRect: NSRect(x: 500, y: 500, width: 480, height: 96),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = composer
    window.makeKey()
    guard window.makeFirstResponder(textView), composer.isEditorFocused else {
        throw fail("could not keep the native text view first responder")
    }
    defer {
        composer.removeFromSuperview()
        window.orderOut(nil)
        window.close()
    }

    func replaceText(_ value: String, caret: Int? = nil) {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText(value, replacementRange: fullRange)
        let location = caret ?? (value as NSString).length
        textView.setSelectedRange(NSRange(location: location, length: 0))
        // AppKit normally calls these delegate methods from its field editor event
        // path; the headless check invokes the same production callbacks after its
        // programmatic fixture replacement.
        textView.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        textView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
    }
    func dispatch(_ event: NSEvent) { window.sendEvent(event) }

    // Start a source that ignores cancellation, then replace it with a newer query.
    replaceText("/s")
    guard AgentCompletionQueryDetector.activeQuery(
        in: textView.string, selection: textView.selectedRange()
    )?.text == "s" else {
        throw fail("the production editor did not hold the /s query: \(textView.string) / \(textView.selectedRange())")
    }
    guard await waitUntil(timeout: 1, pollInterval: 0.01, { state.startedCount >= 1 }) else {
        throw fail("the uncooperative stale source never started from \(textView.string) / \(textView.selectedRange()); focused=\(composer.isEditorFocused), window=\(textView.window != nil), requestTasks=\(composer.qaCompletionRequestStartCount), queries=\(state.observedQueries)")
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let firstStaleRequestCount = state.startedCount
    replaceText("/he")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        composer.qaCompletionIsPresented && composer.qaCompletionTitles == ["help", "hello"]
    }) else {
        throw fail("real text/selection callbacks did not present the newer query")
    }
    guard window.firstResponder === textView else {
        throw fail("the passive completion panel stole first responder from TextKit")
    }
    guard let panelFrame = composer.qaCompletionPanelFrame else {
        throw fail("the real completion panel has no frame")
    }
    let caretFrame = textView.firstRect(
        forCharacterRange: textView.selectedRange(), actualRange: nil
    )
    guard abs(panelFrame.minX - caretFrame.minX) <= 1 else {
        throw fail("panel x \(panelFrame.minX) is not anchored to caret x \(caretFrame.minX)")
    }
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        state.returnedCount >= firstStaleRequestCount
    }) else {
        throw fail("the uncooperative stale source never returned")
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    guard composer.qaCompletionTitles == ["help", "hello"] else {
        throw fail("a stale generation repainted the newer suggestions as \(composer.qaCompletionTitles)")
    }

    // Continued typing stays on the native editor while the passive panel is open.
    dispatch(try event(keyCode: 37, characters: "l", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "/hel" && composer.qaCompletionTitles == ["help", "hello"]
    }), window.firstResponder === textView else {
        throw fail("continued native typing or first-responder retention failed")
    }

    // Unmodified navigation is forwarded while TextKit stays first responder.
    dispatch(try event(keyCode: 125, characters: "", windowNumber: window.windowNumber))
    guard composer.qaCompletionFocusedTitle == "hello" else {
        throw fail("Down did not move completion focus")
    }
    dispatch(try event(keyCode: 115, characters: "", windowNumber: window.windowNumber))
    guard composer.qaCompletionFocusedTitle == "help" else {
        throw fail("Home did not move completion focus to the first row")
    }
    dispatch(try event(keyCode: 119, characters: "", windowNumber: window.windowNumber))
    guard composer.qaCompletionFocusedTitle == "hello" else {
        throw fail("End did not move completion focus to the last row")
    }
    dispatch(try event(keyCode: 126, characters: "", windowNumber: window.windowNumber))
    guard composer.qaCompletionFocusedTitle == "help" else {
        throw fail("Up did not move completion focus")
    }

    // Return follows the real list focus/selection path and insertion is one undo.
    dispatch(try event(keyCode: 36, characters: "\r", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "/help" && !composer.qaCompletionIsPresented
    }) else {
        throw fail("Return did not insert the focused completion and dismiss once")
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    guard !composer.qaCompletionIsPresented else {
        throw fail("the accepted completion immediately reopened its own query")
    }
    guard textView.undoManager?.canUndo == true else {
        throw fail("completion insertion did not register a native undo unit")
    }
    textView.undoManager?.undo()
    guard textView.string == "/hel" else {
        throw fail("one Undo did not restore the complete pre-insertion query")
    }

    // Escape and moving the caret before the trigger cancel the visible request.
    guard await waitUntil(timeout: 1, pollInterval: 0.01, { composer.qaCompletionIsPresented }) else {
        throw fail("Undo did not drive the real query path again")
    }
    dispatch(try event(keyCode: 53, characters: "\u{1b}", windowNumber: window.windowNumber))
    guard !composer.qaCompletionIsPresented, textView.string == "/hel" else {
        throw fail("Escape mutated text or left the completion surface visible")
    }
    replaceText("/he", caret: 0)
    guard !composer.qaCompletionIsPresented else {
        throw fail("moving the caret before the trigger left suggestions actionable")
    }

    // Detaching cancels an in-flight uncooperative request and removes its panel.
    let startedBeforeDetach = state.startedCount
    replaceText("/s")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        state.startedCount > startedBeforeDetach
    }) else {
        throw fail("the detach cancellation request never started")
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let detachRequestCount = state.startedCount
    composer.removeFromSuperview()
    guard !composer.qaCompletionIsPresented else {
        throw fail("detaching the composer left its completion panel visible")
    }
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        state.returnedCount >= detachRequestCount
    }) else {
        throw fail("the detached uncooperative source never returned for the guard assertion")
    }
    guard !composer.qaCompletionIsPresented else {
        throw fail("a stale detached request resurrected the completion panel")
    }

    return 25
}

/// Focused witness for typed completion acceptance. Kept separate from the
/// historical supervisor corpus so an unrelated AppKit undo failure cannot mask
/// semantic dispatch, structured file references, or context rebinding.
@MainActor
func runAgentCompletionSemanticChecks() async throws {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError {
        CheckError(description: "semantic completion contract: \(message)")
    }
    func event(keyCode: UInt16, characters: String, windowNumber: Int) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { throw fail("could not make a synthetic key event") }
        return event
    }

    let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
    let textView = composer.textView
    let state = CompletionProbeState()
    let contextA = AgentCompletionContext(
        agentID: AgentID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!),
        backend: .claudeCode,
        checkoutRoot: URL(fileURLWithPath: "/tmp/array-context-a", isDirectory: true),
        gitRoot: URL(fileURLWithPath: "/tmp/array-context-a", isDirectory: true),
        arrayProjectRoot: URL(fileURLWithPath: "/tmp/array-project", isDirectory: true),
        trustState: .trusted
    )
    let contextB = AgentCompletionContext(
        agentID: AgentID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!),
        backend: .codex,
        checkoutRoot: URL(fileURLWithPath: "/tmp/array-context-b", isDirectory: true),
        gitRoot: URL(fileURLWithPath: "/tmp/array-context-b", isDirectory: true),
        arrayProjectRoot: URL(fileURLWithPath: "/tmp/array-project", isDirectory: true),
        trustState: .untrusted
    )
    composer.qaBindCompletionContext(contextA)
    composer.qaBindCompletionSource(CompletionProbeSource(state: state))
    let window = NSWindow(
        contentRect: NSRect(x: 500, y: 500, width: 480, height: 96),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = composer
    window.makeKey()
    guard window.makeFirstResponder(textView) else {
        throw fail("could not focus the native text view")
    }
    defer {
        composer.removeFromSuperview()
        window.orderOut(nil)
        window.close()
    }

    func replaceText(_ value: String) {
        textView.insertText(
            value,
            replacementRange: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        textView.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        textView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
    }

    var acceptedPayload: AgentCompletionPayload?
    composer.onCompletionAction = { payload in
        acceptedPayload = payload
        return false
    }
    replaceText("//compact")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        composer.qaCompletionTitles == ["compact"]
    }) else { throw fail("runtime command did not present") }
    window.sendEvent(try event(keyCode: 36, characters: "\r", windowNumber: window.windowNumber))
    guard textView.string == "//compact",
          acceptedPayload == .runtimeCommand(ResolvedRuntimeCommand(
              name: "compact", providerHandle: "probe.compact"
          )) else {
        throw fail("runtime command degraded into literal text or lost its typed payload")
    }

    replaceText("@read")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        composer.qaCompletionTitles == ["README.md"]
    }) else { throw fail("file result did not present") }
    window.sendEvent(try event(keyCode: 36, characters: "\r", windowNumber: window.windowNumber))
    guard textView.string.isEmpty,
          composer.qaFileReferenceCount == 1,
          composer.qaFileReferenceRailNames == ["README.md"] else {
        throw fail("file result did not become one structured draft reference")
    }

    replaceText("@dir")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        composer.qaCompletionTitles == ["Sources/"]
    }) else { throw fail("directory result did not present") }
    window.sendEvent(try event(keyCode: 124, characters: "", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "@"
            && state.observedNavigationPaths.last == "Sources"
            && composer.qaCompletionTitles == ["../", "Nested.swift"]
            && composer.qaCompletionDetails == ["Go to array-context-a", "Sources/"]
            && composer.qaCompletionBreadcrumb == "array-context-a  ›  Sources"
    }) else {
        throw fail("directory acceptance mutated the draft with a path or failed to show scoped breadcrumbs: text=\(textView.string), paths=\(state.observedNavigationPaths), titles=\(composer.qaCompletionTitles), details=\(composer.qaCompletionDetails), breadcrumb=\(String(describing: composer.qaCompletionBreadcrumb))")
    }
    guard composer.qaCompletionFooter == "Type to fuzzy find   ↑↓ Choose   Tab/→ Open folder   ↵ Add" else {
        throw fail("file completion lost its fixed keyboard footer")
    }

    // Literal relative-path syntax is browsing input, not fuzzy-search text.
    // It previews the resolved parent without persisting any navigation state or
    // mutating the native draft until a result is accepted.
    replaceText("@../")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "@../"
            && state.observedQueries.last == ""
            && state.observedNavigationPaths.last! == nil
            && composer.qaCompletionIsPresented
            && composer.qaCompletionTitles == ["../", "Sources/"]
            && composer.qaCompletionBreadcrumb == "array-context-a"
    }) else {
        throw fail("typed @../ did not preview the parent scope: text=\(textView.string), queries=\(state.observedQueries), paths=\(state.observedNavigationPaths), titles=\(composer.qaCompletionTitles)")
    }
    replaceText("@../../Nest")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "@../../Nest"
            && state.observedQueries.last == "Nest"
            && state.observedNavigationPaths.last == "/tmp"
    }) else {
        throw fail("typed @../../query did not escape the checkout and preserve the fuzzy remainder")
    }
    replaceText("@../Sibling/Needle")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "@../Sibling/Needle"
            && state.observedQueries.last == "Needle"
            && state.observedNavigationPaths.last == "Sibling"
    }) else {
        throw fail("typed relative directory components did not resolve like a path from the current scope: text=\(textView.string), queries=\(state.observedQueries), paths=\(state.observedNavigationPaths)")
    }

    replaceText("@")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        composer.qaCompletionTitles == ["../", "Nested.swift"]
            && composer.qaCompletionBreadcrumb == "array-context-a  ›  Sources"
    }) else { throw fail("nested scope did not restore after typed traversal coverage") }

    // The synthetic parent row uses the same typed directory payload path as a
    // real folder. At the checkout root it remains available for external ascent.
    window.sendEvent(try event(keyCode: 36, characters: "\r", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "@"
            && state.observedNavigationPaths.last! == nil
            && composer.qaCompletionIsPresented
            && composer.qaCompletionTitles == ["../", "Sources/"]
            && composer.qaCompletionBreadcrumb == "array-context-a"
    }) else {
        throw fail("selecting ../ did not keep the checkout-root list open without mutating the draft: text=\(textView.string), paths=\(state.observedNavigationPaths), titles=\(composer.qaCompletionTitles), presented=\(composer.qaCompletionIsPresented)")
    }

    window.sendEvent(try event(keyCode: 36, characters: "\r", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "@"
            && state.observedNavigationPaths.last == "/tmp"
            && composer.qaCompletionIsPresented
            && composer.qaCompletionTitles == ["../"]
            && composer.qaCompletionBreadcrumb == "array-context-a  ›  .."
    }) else {
        throw fail("checkout-root ../ did not ascend into the external parent directory")
    }

    replaceText("@dir")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        composer.qaCompletionTitles == ["Sources/"]
    }) else { throw fail("directory result did not reopen for keyboard-ascent coverage") }
    window.sendEvent(try event(keyCode: 124, characters: "", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        composer.qaCompletionTitles == ["../", "Nested.swift"]
    }) else { throw fail("nested scope did not reopen for keyboard-ascent coverage") }
    let observationsBeforeAscend = state.observedNavigationPaths.count
    window.sendEvent(try event(keyCode: 51, characters: "\u{8}", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "@"
            && state.observedNavigationPaths.count > observationsBeforeAscend
            && state.observedNavigationPaths.last! == nil
            && composer.qaCompletionIsPresented
            && composer.qaCompletionTitles == ["../", "Sources/"]
    }) else {
        throw fail("empty-query Backspace did not ascend to a visible root list without mutating draft text")
    }

    replaceText("/he")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        state.observedContexts.last == contextA
            && composer.qaCompletionTitles == ["help", "hello"]
    }) else { throw fail("query did not carry its initial agent context") }
    composer.qaBindCompletionContext(contextB)
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        state.observedContexts.last == contextB
            && composer.qaCompletionTitles == ["help", "hello"]
    }) else { throw fail("rebind did not atomically replace backend/cwd context") }

    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-completion-managed-root-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("falcon-platform/falcon", isDirectory: true)
    try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: managedRoot.deletingLastPathComponent().deletingLastPathComponent()) }
    let managedStore = AgentStore(
        applicationSupportDirectory: managedRoot.deletingLastPathComponent().appendingPathComponent("agent-store", isDirectory: true)
    )
    let managedSupervisor = AgentSupervisor(
        store: managedStore,
        makeRunner: { _ in ScriptedAgentRunner(script: []) }
    )
    let managedAgentID = managedSupervisor.spawn(
        role: "completion-root",
        prompt: nil,
        cwd: managedRoot,
        model: AgentModelConfig.resolvedFromDefaults().model,
        thinking: AgentModelConfig.resolvedFromDefaults().thinking
    )
    let managedTile = ManagedAgentTileNSView(tile: Tile(
        id: UUID(),
        kind: .managedAgent,
        title: "completion-root",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    managedTile.attach(agentID: managedAgentID, supervisor: managedSupervisor)
    defer { managedTile.detach() }
    guard managedTile.qaCompletionContext?.checkoutRoot == managedRoot.standardizedFileURL else {
        throw fail("managed tile did not bind the record's exact nested checkout root")
    }
}

/// Gated on `--image-supervisor-check`. This is intentionally separate from the
/// historical naming corpus: image transport ownership and recovery must remain
/// executable evidence even when that older model-id expectation fails.
@MainActor
func runImageSupervisorProductionSeamChecks() async throws {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-image-supervisor-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = AgentModelConfig.resolvedFromDefaults()
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents", isDirectory: true))
    let attachmentStore = AgentComposerAttachmentStore(
        applicationSupportDirectory: root.appendingPathComponent("attachments", isDirectory: true))
    let draftStore = AgentComposerDraftStore(
        applicationSupportDirectory: root.appendingPathComponent("drafts", isDirectory: true),
        debounceInterval: 60,
        attachmentStore: attachmentStore)
    let runner = ScriptedAgentRunner(
        script: [
            .turnStarted(threadId: "image-check", turnId: "image-check#1")
        ],
        holdUntilStopped: true)
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { _ in runner },
        attachmentStore: attachmentStore,
        submissionRecoveryStore: draftStore)
    let agent = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let validation = try AgentComposerImageValidation(
        validatedContentType: "image/png", pixelWidth: 80, pixelHeight: 60, byteCount: 3)
    let managed = try await attachmentStore.importValidatedPastedImage(
        Data([1, 2, 3]), displayName: "managed.png", validation: validation, forDraftOf: agent)

    // RED witness for the unchecked transport seam: a caller-provided /tmp URL
    // has no managed ownership and must never reach the runner.
    let unmanaged = AgentPrompt(imageAttachments: [
        AgentPromptImageAttachment(metadata: managed.manifest.metadata,
                                   fileURL: URL(fileURLWithPath: "/tmp/unmanaged.png"))
    ])
    guard !supervisor.send(unmanaged, to: agent), runner.agentPrompts.isEmpty else {
        throw fail("unmanaged direct AgentPrompt send reached the runner")
    }

    let draft = ContinuumRevivedCore.AgentComposerDraft(
        text: "  inspect visible details @/tmp/not-a-capability.png  ",
        selection: 0..<0,
        updatedAt: Date(timeIntervalSinceReferenceDate: 807_803_000),
        imageAttachments: [managed.draftAttachment])
    await draftStore.save(draft, for: agent)
    await draftStore.flushAll()
    guard try await draftStore.beginSubmission(for: agent) else {
        throw fail("image supervisor recovery fixture did not journal the draft")
    }
    guard await supervisor.accept(
        .sendPrompt(AgentPrompt(text: draft.text, imageAttachments: [managed.promptAttachment])),
        for: agent) == .accepted else {
        throw fail("managed image prompt was refused at the supervisor production seam")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.agentPrompts.count == 1
            && supervisor.turnSnapshot(for: agent)?.state == .working
    }) else {
        throw fail("managed image prompt did not reach the runner")
    }
    guard runner.agentPrompts[0].imageAttachments.map(\.fileURL.path) == [managed.fileURL.path] else {
        throw fail("managed image prompt did not preserve its Application Support capability")
    }
    guard await draftStore.hasSubmissionRecovery(for: agent) else {
        throw fail("turnStarted consumed composer recovery before authoritative completion")
    }
    supervisor.stop(agent)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        !supervisor.isRunning(agent)
    }) else {
        throw fail("runtime/provider stop after turnStarted did not finish")
    }
    for _ in 0..<100 {
        if !(await draftStore.hasSubmissionRecovery(for: agent)) { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let restoredDraft = await draftStore.load(for: agent)
    guard restoredDraft == draft else {
        throw fail("runtime/provider stop after turnStarted did not restore the exact draft")
    }

    // A successful turn is the only acceptance point that may consume recovery.
    let successRunner = ScriptedAgentRunner(script: [
        .turnStarted(threadId: "image-success", turnId: "image-success#1"),
        .turnCompleted(threadId: "image-success", turnId: "image-success#1", outcome: .completed, errorMessage: nil)
    ])
    let successSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("success-agents", isDirectory: true)),
        makeRunner: { _ in successRunner },
        attachmentStore: attachmentStore,
        submissionRecoveryStore: draftStore)
    let successAgent = successSupervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let successImage = try await attachmentStore.importValidatedPastedImage(
        Data([4, 5, 6]), displayName: "success.png", validation: validation, forDraftOf: successAgent)
    let successDraft = ContinuumRevivedCore.AgentComposerDraft(
        text: "successful image acceptance",
        selection: 0..<0,
        updatedAt: Date(timeIntervalSinceReferenceDate: 807_803_001),
        imageAttachments: [successImage.draftAttachment])
    await draftStore.save(successDraft, for: successAgent)
    await draftStore.flushAll()
    guard try await draftStore.beginSubmission(for: successAgent),
          await successSupervisor.accept(
              .sendPrompt(AgentPrompt(imageAttachments: [successImage.promptAttachment])),
              for: successAgent) == .accepted else {
        throw fail("successful image recovery fixture was not accepted")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        successRunner.agentPrompts.count == 1 && !successSupervisor.isRunning(successAgent)
    }) else {
        throw fail("successful image turn did not complete")
    }
    for _ in 0..<100 {
        if !(await draftStore.hasSubmissionRecovery(for: successAgent)) { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    guard !(await draftStore.hasSubmissionRecovery(for: successAgent)),
          await draftStore.load(for: successAgent) == nil else {
        throw fail("successful turn did not authoritatively consume recovery")
    }
}

/// Gated on `--agent-supervisor-check`.
///
/// Deterministic and offline: a `ScriptedAgentRunner` replaces Pi, so what is under
/// test is the supervisor's ownership and fan-out, not a provider. Waits go through
/// P0.8's `waitUntil`, which suspends on a main-queue timer rather than spinning a
/// nested RunLoop — the events arrive by `DispatchQueue.main.async`, which a nested
/// RunLoop starves.
@MainActor
func runAgentSupervisorChecks() async throws {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-supervisor-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let config = AgentModelConfig.resolvedFromDefaults()
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    // Liveness ownership is foundational and fast; run it before the broader
    // supervisor corpus so an unrelated later fixture cannot mask this witness.
    let retiredRunnerReport = try await checkRetiredRunnerCannotRestartTurn(fail: fail)
    print("AgentSupervisor runner generation: \(retiredRunnerReport)")
    let composerKeyAssertions = try runComposerKeyContractChecks()
    let completionAssertions = try await runCompletionComposerChecks()
    // Run the one-shot's production sync-boundary witness first so a regression
    // in its actual companion envelope fails at the named P4.5 assertion rather
    // than being masked by the broader historical naming corpus below.
    let generatedNameReport = try await checkGeneratedNameOneShot(config: config, fail: fail)
    let namingReport = try await checkAgentNameContract(config: config, cwd: cwd, fail: fail)

    func managedImageAttachment(
        _ store: AgentComposerAttachmentStore,
        displayName: String,
        for agentID: AgentID
    ) async throws -> AgentPromptImageAttachment {
        let validation = try AgentComposerImageValidation(
            validatedContentType: "image/png", pixelWidth: 80, pixelHeight: 60, byteCount: 123)
        return try await store.importValidatedPastedImage(
            Data(repeating: 7, count: 123), displayName: displayName,
            validation: validation, forDraftOf: agentID
        ).promptAttachment
    }

    func replayedEvents(
        from supervisor: AgentSupervisor,
        for agentID: AgentID,
        count: Int
    ) async -> [AgentRuntimeEvent] {
        var result: [AgentRuntimeEvent] = []
        for await event in supervisor.events(for: agentID) {
            result.append(event)
            if result.count >= count { break }
        }
        return result
    }

    func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { !$0.isEmpty && text.contains($0) }
    }

    // Image Wave 2A · Lane D — AgentPrompt reaches the real supervisor/runner
    // transport seam. This intentionally does not touch the composer UI: a
    // serialized coordinator that already owns attachments must call
    // AgentSupervisor.accept(.sendPrompt(prompt), for:); unchecked direct send
    // rejects image-bearing prompts.
    let imageTransportStore = AgentStore(
        applicationSupportDirectory: root.appendingPathComponent("image-transport", isDirectory: true))
    let imageRunner = ScriptedAgentRunner(
        script: [
            .turnStarted(threadId: "provider-image", turnId: "image-turn"),
            .contentDelta(threadId: "provider-image", turnId: "image-turn", streamKind: .assistant, delta: "received"),
        ],
        holdUntilStopped: true)
    let imageAttachmentStore = AgentComposerAttachmentStore(
        applicationSupportDirectory: imageTransportStore.layout.applicationSupportDirectory)
    let imageSupervisor = AgentSupervisor(
        store: imageTransportStore, makeRunner: { _ in imageRunner }, attachmentStore: imageAttachmentStore)
    let imageAgent = imageSupervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        projectId: nil)
    let firstImage = try await managedImageAttachment(
        imageAttachmentStore, displayName: "first visible image.png", for: imageAgent)
    let secondImage = try await managedImageAttachment(
        imageAttachmentStore, displayName: "second visible image.png", for: imageAgent)
    let imageOnlyPrompt = AgentPrompt(imageAttachments: [firstImage, secondImage])
    guard await imageSupervisor.accept(.sendPrompt(imageOnlyPrompt), for: imageAgent) == .accepted else {
        throw fail("image transport: image-only AgentPrompt was refused at the supervisor accept seam")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { imageRunner.agentPrompts.count == 1 }) else {
        throw fail("image transport: prompt-capable accept did not reach the runner")
    }
    guard imageRunner.agentPrompts[0].text.isEmpty,
          imageRunner.agentPrompts[0].imageAttachments.map(\.fileURL.path) == [firstImage.fileURL.path, secondImage.fileURL.path] else {
        throw fail("image transport: multiple attachment URLs did not reach the runner intact: \(imageRunner.agentPrompts)")
    }
    guard imageSupervisor.records[imageAgent]?.displayName == AgentRecord.defaultAgentName else {
        throw fail("image transport: image-only first prompt derived a name from a local path or attachment metadata")
    }
    let refusalImage = try await managedImageAttachment(
        imageAttachmentStore, displayName: "refused.png", for: imageAgent)
    let refusalPrompt = AgentPrompt(
        text: "do not clear this draft",
        imageAttachments: [refusalImage])
    guard await imageSupervisor.accept(.sendPrompt(refusalPrompt), for: imageAgent) == .refused(.turnNotReady),
          imageRunner.agentPrompts.count == 1 else {
        throw fail("image transport: in-flight send was accepted or destructively replaced the runner prompt")
    }
    imageSupervisor.stop(imageAgent)
    _ = await waitUntil(timeout: 5, pollInterval: 0.02, { imageRunner.completedRuns == 1 })

    let replayedImageEvents = await replayedEvents(from: imageSupervisor, for: imageAgent, count: 3)
    let replayedImageJSON = String(decoding: try JSONEncoder().encode(replayedImageEvents), as: UTF8.self)
    let secretImagePaths = [firstImage.fileURL.path, secondImage.fileURL.path, "@\(firstImage.fileURL.path)", "@\(secondImage.fileURL.path)"]
    guard !containsAny(replayedImageJSON, secretImagePaths) else {
        throw fail("image transport: local image paths leaked into supervisor runtime events: \(replayedImageJSON)")
    }

    let leakyManagedPath = root
        .appendingPathComponent("agent-composer-attachments/objects/private-image.bin", isDirectory: false)
        .path
    let stderrLeakRunner = ScriptedAgentRunner(
        script: [],
        runError: PiAgentRunner.RunError.piFailed(
            exitCode: 42,
            stderr: "provider echoed argv @\(leakyManagedPath) and \(leakyManagedPath) before start"))
    let stderrLeakStore = AgentStore(
        applicationSupportDirectory: root.appendingPathComponent("stderr-leak", isDirectory: true))
    let stderrLeakAttachmentStore = AgentComposerAttachmentStore(
        applicationSupportDirectory: stderrLeakStore.layout.applicationSupportDirectory)
    let stderrLeakSupervisor = AgentSupervisor(
        store: stderrLeakStore, makeRunner: { _ in stderrLeakRunner },
        attachmentStore: stderrLeakAttachmentStore)
    let stderrLeakAgent = stderrLeakSupervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        projectId: nil)
    let stderrLeakImage = try await managedImageAttachment(
        stderrLeakAttachmentStore, displayName: "leak.png", for: stderrLeakAgent)
    guard await stderrLeakSupervisor.accept(.sendPrompt(AgentPrompt(imageAttachments: [stderrLeakImage])), for: stderrLeakAgent) == .accepted else {
        throw fail("image transport: stderr leak fixture send was refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { !stderrLeakSupervisor.isRunning(stderrLeakAgent) }) else {
        throw fail("image transport: stderr leak fixture did not finish")
    }
    let stderrLeakEvents = await replayedEvents(from: stderrLeakSupervisor, for: stderrLeakAgent, count: 1)
    let stderrLeakJSON = String(decoding: try JSONEncoder().encode(stderrLeakEvents), as: UTF8.self)
    guard !stderrLeakJSON.contains(leakyManagedPath),
          !stderrLeakJSON.contains("@\(leakyManagedPath)"),
          stderrLeakJSON.contains("[LOCAL-PATH]") else {
        throw fail("image transport: runner stderr path leaked into runtime events/transcript source: \(stderrLeakJSON)")
    }

    var imageProjection = AgentTranscriptProjection(threadId: "image-transport-thread")
    try imageProjection.appendUserPrompt(
        id: AgentNodeID(rawValue: "local:image-only-prompt")!,
        prompt: imageOnlyPrompt)
    let imageTranscriptBody = imageProjection.compatibilityRows.map(\.body).joined(separator: "\n")
    let imageTranscriptJSON = String(decoding: try JSONEncoder().encode(imageProjection.document), as: UTF8.self)
    guard !containsAny(imageTranscriptBody, secretImagePaths),
          !containsAny(imageTranscriptJSON, secretImagePaths),
          imageTranscriptJSON.contains(firstImage.metadata.id.rawValue),
          imageTranscriptJSON.contains("image-gallery") else {
        throw fail("image transport: transcript projection did not preserve path-free image metadata only; body=\(imageTranscriptBody), json=\(imageTranscriptJSON)")
    }

    let mixedRunner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
    let mixedStore = AgentStore(
        applicationSupportDirectory: root.appendingPathComponent("image-transport-mixed", isDirectory: true))
    let mixedAttachmentStore = AgentComposerAttachmentStore(
        applicationSupportDirectory: mixedStore.layout.applicationSupportDirectory)
    let mixedSupervisor = AgentSupervisor(
        store: mixedStore, makeRunner: { _ in mixedRunner }, attachmentStore: mixedAttachmentStore)
    let mixedAgent = mixedSupervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        projectId: nil)
    let mixedImage = try await managedImageAttachment(
        mixedAttachmentStore, displayName: "mixed visible image.png", for: mixedAgent)
    let mixedPrompt = AgentPrompt(
        text: "  Compare visible screen details Inspect(/Users/dylan/Private/name-leak.png) '@/tmp/quoted-name-leak.png' @/tmp/name-leak.png  ",
        imageAttachments: [mixedImage])
    guard await mixedSupervisor.accept(.sendPrompt(mixedPrompt), for: mixedAgent) == .accepted else {
        throw fail("image transport: text plus image AgentPrompt was refused at the supervisor accept seam")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { mixedRunner.agentPrompts.count == 1 }) else {
        throw fail("image transport: mixed AgentPrompt did not reach the runner")
    }
    guard mixedRunner.agentPrompts[0].text == "Compare visible screen details Inspect(/Users/dylan/Private/name-leak.png) '@/tmp/quoted-name-leak.png' @/tmp/name-leak.png",
          mixedRunner.agentPrompts[0].imageAttachments.map(\.fileURL.path) == [mixedImage.fileURL.path] else {
        throw fail("image transport: mixed prompt text/attachments were not preserved at the runner: \(mixedRunner.agentPrompts)")
    }
    let mixedName = mixedSupervisor.records[mixedAgent]?.displayName ?? ""
    guard mixedName.count <= AgentName.maximumLength,
          !mixedName.contains("/"),
          !mixedName.contains("@"),
          !mixedName.contains("name-leak"),
          !mixedName.contains("Users"),
          mixedName.contains("Compare visible screen details") else {
        throw fail("image transport: first-prompt naming leaked embedded/quoted path/@path text or exceeded the visible-text cap: \(mixedName)")
    }

    // Queue 91 P3.6/P3.7 — Home may be changed only while the agent is still a
    // zero-turn/provisional record. After any session history exists, callers must
    // use the app's explicit New Agent Here route instead of silently retargeting.
    let homeSelectionStore = AgentStore(
        applicationSupportDirectory: root.appendingPathComponent("home-selection", isDirectory: true))
    let homeSelectionSupervisor = AgentSupervisor(
        store: homeSelectionStore,
        makeRunner: { _ in ScriptedAgentRunner(script: [.sessionStateChanged(.ready)]) })
    let originalProjectId = UUID()
    let selectedHome = root.appendingPathComponent("selected-home", isDirectory: true)
    try FileManager.default.createDirectory(at: selectedHome, withIntermediateDirectories: true)
    let homeSelectionAgent = homeSelectionSupervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        projectId: originalProjectId)
    let selectedProjectId = UUID()
    guard homeSelectionSupervisor.reassignProvisionalHome(
        agentID: homeSelectionAgent,
        cwd: selectedHome,
        projectId: selectedProjectId) else {
        throw fail("zero-turn Home selection should update the authoritative AgentRecord before submission")
    }
    guard homeSelectionSupervisor.records[homeSelectionAgent]?.cwd == selectedHome.path,
          homeSelectionSupervisor.records[homeSelectionAgent]?.projectId == selectedProjectId,
          homeSelectionSupervisor.locationSnapshot(for: homeSelectionAgent)?.home.checkoutRoot.path == selectedHome.path else {
        throw fail("provisional Home selection did not update record and host-local projector together")
    }
    homeSelectionSupervisor.send("first real prompt", to: homeSelectionAgent)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        homeSelectionSupervisor.hasUserWorkOrSessionHistory(homeSelectionAgent)
    }) else {
        throw fail("first prompt did not mark the agent as no longer provisional")
    }
    let forbiddenHome = root.appendingPathComponent("forbidden-retarget", isDirectory: true)
    try FileManager.default.createDirectory(at: forbiddenHome, withIntermediateDirectories: true)
    guard !homeSelectionSupervisor.reassignProvisionalHome(
        agentID: homeSelectionAgent,
        cwd: forbiddenHome,
        projectId: nil),
          homeSelectionSupervisor.records[homeSelectionAgent]?.cwd == selectedHome.path else {
        throw fail("agent with session history was silently retargeted instead of requiring New Agent Here")
    }

    // A relaunch has no in-memory prompt/event ring, so the durable activity
    // facts and conservative restored marker must still close the retarget gate.
    let restoredHomeSupervisor = AgentSupervisor(
        store: homeSelectionStore,
        makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let restoreReport = restoredHomeSupervisor.restore()
    guard restoreReport.restored.contains(homeSelectionAgent),
          restoredHomeSupervisor.hasUserWorkOrSessionHistory(homeSelectionAgent),
          !restoredHomeSupervisor.reassignProvisionalHome(
              agentID: homeSelectionAgent,
              cwd: forbiddenHome,
              projectId: nil),
          restoredHomeSupervisor.records[homeSelectionAgent]?.cwd == selectedHome.path else {
        throw fail("restored session history reopened provisional Home retargeting")
    }

    // A Home change is committed only after the injected production writer
    // succeeds. A failed write must leave the in-memory record/projector and the
    // durable record on the same old Home.
    let failedWriteStore = AgentStore(
        applicationSupportDirectory: root.appendingPathComponent("home-selection-write-failure", isDirectory: true))
    var rejectHomeWrite = false
    let failedWriteSupervisor = AgentSupervisor(
        store: failedWriteStore,
        makeRunner: { _ in ScriptedAgentRunner(script: []) },
        upsertRecord: { record in
            if rejectHomeWrite { throw CheckError(description: "injected Home write failure") }
            try failedWriteStore.upsert(record)
        })
    let failedWriteAgent = failedWriteSupervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        projectId: originalProjectId)
    rejectHomeWrite = true
    guard !failedWriteSupervisor.reassignProvisionalHome(
        agentID: failedWriteAgent,
        cwd: selectedHome,
        projectId: selectedProjectId),
          failedWriteSupervisor.records[failedWriteAgent]?.cwd == cwd.path,
          failedWriteSupervisor.locationSnapshot(for: failedWriteAgent)?.home.checkoutRoot.path == cwd.path,
          try failedWriteStore.load(id: failedWriteAgent)?.cwd == cwd.path else {
        throw fail("failed Home persistence left live and durable authority split")
    }

    // Queue 91 P2 — the runner's private observation reaches supervisor-owned
    // Home/Where/What before the matching generic item event, while subscribers
    // still receive exactly the original event and no path-bearing payload.
    let locationStore = AgentStore(
        applicationSupportDirectory: root.appendingPathComponent("location-projection", isDirectory: true))
    let locationProjectId = UUID()
    let externalTarget = root
        .appendingPathComponent("external-reference", isDirectory: true)
        .appendingPathComponent("Router.swift")
    let locationObservedAt = Date()
    let locationRunner = ScriptedAgentRunner(
        script: [
            .itemStarted(
                threadId: "provider-location",
                itemId: "read-location",
                kind: .commandExecution,
                title: "read"),
            .itemCompleted(
                threadId: "provider-location",
                itemId: "read-location",
                kind: .commandExecution,
                status: .completed),
        ],
        runtimeObservations: [
            .workingDirectory(cwd, observedAt: locationObservedAt),
            .toolActivity(
                itemId: "read-location",
                activity: AgentObservedActivity(
                    operation: .reading,
                    targetPath: externalTarget,
                    startedAt: locationObservedAt,
                    updatedAt: locationObservedAt,
                    evidenceSource: .toolEvent)),
        ],
        // Every assertion below reads MID-TURN state (the stale timer, the live
        // projector). A script that returned would now be closed by the
        // supervisor's no-result mint — correctly, but that is section 23's
        // subject, not this one's — so the run stays open until the explicit
        // stop at the end of the section.
        holdUntilStopped: true)
    let locationSupervisor = AgentSupervisor(store: locationStore, makeRunner: { _ in locationRunner })
    let locationAgentId = locationSupervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        projectId: locationProjectId)
    let locationTile = ManagedAgentTileNSView(tile: Tile(
        id: UUID(),
        kind: .managedAgent,
        title: "Location agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 360),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    locationTile.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
    locationTile.attach(
        agentID: locationAgentId,
        supervisor: locationSupervisor,
        projectName: "Continuum")
    let locationInbox = EventInbox()
    let locationStream = locationSupervisor.events(for: locationAgentId)
    let locationTask = Task { @MainActor in
        for await event in locationStream { locationInbox.append(event) }
    }
    locationSupervisor.send("inspect external reference", to: locationAgentId)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        locationInbox.events.count == 2
            && locationTile.ingestedEvents.count == 2
            && locationSupervisor.locationSnapshot(for: locationAgentId)?.what?.operation == .thinking
            && locationSupervisor.locationSnapshot(for: locationAgentId)?.lastUsefulWhat?.operation == .reading
            && locationTile.qaLocationText == "Home Continuum"
            && locationTile.qaWhatText == "What Thinking"
            && locationTile.qaLocationStaleTimerActive
    }) else {
        locationTask.cancel()
        throw fail("host-local location observation did not reach the supervisor before its matching event")
    }
    locationTask.cancel()
    guard let locationSnapshot = locationSupervisor.locationSnapshot(for: locationAgentId),
          locationSnapshot.home.projectId == locationProjectId,
          locationSnapshot.home.checkoutRoot == cwd.standardizedFileURL,
          locationSnapshot.workingLocation.directory == cwd.standardizedFileURL,
          locationSnapshot.lastUsefulWhat?.targetPath == externalTarget.standardizedFileURL,
          locationSnapshot.lastUsefulWhatRelationToHome == .outside else {
        throw fail("supervisor Home/Where/What projection lost identity, cwd, target, or outside relation")
    }
    let locationWire = String(
        decoding: try JSONEncoder().encode(locationInbox.events),
        as: UTF8.self)
    guard !locationWire.contains(externalTarget.path), locationInbox.events.count == 2 else {
        throw fail("private location observation widened or duplicated supervisor event fan-out")
    }
    guard locationTile.qaLocationDetail.contains(externalTarget.path),
          locationTile.qaLocationAccessibilityValue
            == "Home and Where: Continuum, project root.",
          locationTile.qaWhatAccessibilityValue == "What: thinking." else {
        throw fail("managed tile did not consume independent host-local location/activity disclosure and AX facts: location='\(locationTile.qaLocationText)' what='\(locationTile.qaWhatText)' locationAX='\(locationTile.qaLocationAccessibilityValue)' whatAX='\(locationTile.qaWhatAccessibilityValue)' detail='\(locationTile.qaLocationDetail)'")
    }
    guard let locationExpiry = locationSnapshot.whatExpiresAt else {
        throw fail("supervisor location snapshot omitted the exact UI stale refresh boundary")
    }
    locationTile.qaRefreshLocation(at: locationExpiry)
    guard locationTile.qaWhatText == "Last Read external-reference/Router.swift",
          locationTile.qaWhatAccessibilityValue
            == "Last observed activity: read external-reference/Router.swift, outside Home.",
          !locationTile.qaLocationStaleTimerActive else {
        throw fail("managed tile did not replace expired current What with retained recent activity at the projector boundary")
    }
    locationTile.qaRefreshLocation(at: Date())
    guard locationTile.qaWhatText == "What Thinking",
          locationTile.qaLocationStaleTimerActive else {
        throw fail("managed tile could not restore current What from the live projector before detach")
    }
    locationTile.detach()
    guard locationTile.qaWhatText == "Last Read external-reference/Router.swift",
          locationTile.qaWhatAccessibilityValue
            == "Last observed activity: read external-reference/Router.swift, outside Home.",
          !locationTile.qaLocationStaleTimerActive else {
        throw fail("detached tile froze current What after removing its observer/timer instead of demoting it to recent")
    }
    locationSupervisor.stop(locationAgentId)

    // Exercise the real native location band at narrow width. Externality has its
    // own fixed marker lane, so tail truncation can never turn an outside fact into
    // an apparently in-Home one.
    let externalActivity = AgentObservedActivity(
        operation: .reading,
        targetPath: externalTarget,
        startedAt: locationObservedAt,
        updatedAt: locationObservedAt,
        evidenceSource: .toolEvent)
    let externalSnapshot = AgentLocationSnapshot(
        home: locationSnapshot.home,
        whereDirectory: externalTarget.deletingLastPathComponent(),
        what: externalActivity,
        lastUsefulWhat: externalActivity)
    let narrowLocation = AgentLocationStatusView(frame: NSRect(
        x: 0, y: 0, width: 320, height: AgentLocationStatusView.preferredHeight))
    narrowLocation.apply(AgentLocationStatusPresenter.present(
        externalSnapshot,
        projectName: "Continuum"))
    narrowLocation.layoutSubtreeIfNeeded()
    guard narrowLocation.qaWhereOutboundMarkerVisible,
          narrowLocation.qaWhatOutboundMarkerVisible,
          narrowLocation.qaLocationText.contains("Where external-reference"),
          narrowLocation.qaWhatText.contains("What Reading"),
          narrowLocation.qaMarkerLanesDoNotOverlapText,
          narrowLocation.qaContentFitsBounds,
          narrowLocation.qaCompactTextFitsWithoutTruncation,
          narrowLocation.qaLocationAccessibilityValue.contains("outside Home"),
          narrowLocation.qaWhatAccessibilityValue.contains("outside Home"),
          narrowLocation.qaAccessibilityLabels == [
            narrowLocation.qaLocationAccessibilityValue,
            narrowLocation.qaWhatAccessibilityValue,
          ] else {
        throw fail("narrow native location band hid/overlapped external Where/What or lost independent AX values")
    }
    let locationProjectionReport = "host-local Home/Where/What projected before unchanged event fan-out and rendered in a narrow external-safe native band"

    // The script is deliberately a real turn shape with DISTINCT events, so
    // "in order" is checkable and a dropped or reordered event is named.
    let scriptThread = "provider-thread"
    let script: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .turnStarted(threadId: scriptThread, turnId: "t1"),
        .contentDelta(threadId: scriptThread, turnId: "t1", streamKind: .assistant, delta: "one"),
        .contentDelta(threadId: scriptThread, turnId: "t1", streamKind: .assistant, delta: "two"),
        .itemStarted(threadId: scriptThread, itemId: "i1", kind: .commandExecution, title: "ls"),
        .itemCompleted(threadId: scriptThread, itemId: "i1", kind: .commandExecution, status: .completed),
        .turnCompleted(threadId: scriptThread, turnId: "t1", outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready)
    ]

    // MARK: 1 · two consumers, one agent, every event in order

    let runner = ScriptedAgentRunner(script: script)
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })
    let agentId = supervisor.spawn(
        role: "reviewer",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: UUID()
    )
    let expected = script.map { $0.withThreadId(AgentSupervisor.threadId(for: agentId)) }

    // Both subscribers attach BEFORE the prompt, which is the tile's real ordering.
    let inboxA = EventInbox()
    let inboxB = EventInbox()
    let streamA = supervisor.events(for: agentId)
    let streamB = supervisor.events(for: agentId)
    let taskA = Task { @MainActor in for await event in streamA { inboxA.append(event) } }
    let taskB = Task { @MainActor in for await event in streamB { inboxB.append(event) } }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 2 }) else {
        throw fail("both subscribers should be registered; got \(supervisor.subscriberCount(for: agentId))")
    }

    supervisor.send("first prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        inboxA.events.count == script.count && inboxB.events.count == script.count
    }) else {
        throw fail("subscribers did not both receive all \(script.count) events — A got \(inboxA.events.count), B got \(inboxB.events.count)")
    }
    if let divergence = firstDivergence(inboxA.events, expected) {
        throw fail("subscriber A received the wrong sequence \(divergence)")
    }
    if let divergence = firstDivergence(inboxB.events, expected) {
        throw fail("subscriber B received the wrong sequence \(divergence)")
    }
    // Restamping is not cosmetic: every consumer must see the AGENT's thread, not
    // the provider's. A vacuity guard, since the script uses a different one.
    guard AgentSupervisor.threadId(for: agentId) != scriptThread else {
        throw fail("the script's thread id matches the agent's, so restamping is untested")
    }
    guard case let .turnStarted(threadId, _) = inboxA.events[1], threadId == AgentSupervisor.threadId(for: agentId) else {
        throw fail("delivered events are not restamped with the agent's thread id")
    }
    guard runner.runCount == 1, runner.prompts == ["first prompt"] else {
        throw fail("the supervisor should have run the prompt exactly once; runCount \(runner.runCount), prompts \(runner.prompts)")
    }

    // MARK: 2 · the record persists, without a tile being involved

    guard let persisted = try store.load(id: agentId) else {
        throw fail("no record persisted for the spawned agent at \(store.layout.agentFile(id: agentId).path)")
    }
    guard persisted.role == "reviewer", persisted.model == config.model, persisted.thinking == config.thinking else {
        throw fail("persisted record lost its spawn parameters: role \(String(describing: persisted.role)), model \(persisted.model), thinking \(persisted.thinking)")
    }
    guard persisted.cwd == cwd.path else {
        throw fail("persisted record's cwd is \(persisted.cwd), expected \(cwd.path)")
    }
    guard supervisor.records[agentId]?.lastActivityAt ?? .distantPast > persisted.createdAt else {
        throw fail("lastActivityAt did not advance past createdAt while events were delivered")
    }
    // SPAWN itself must persist, not just the first `send`. Found by the negative
    // test: dropping `persist` from `spawn` left the assertion above green, because
    // `send` writes too — so a headless agent that is never prompted (P2A.6) would
    // exist only in memory and vanish on relaunch.
    let unpromptedId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    guard let unprompted = try store.load(id: unpromptedId) else {
        throw fail("an agent spawned with no prompt was not persisted — spawn must write, not just send")
    }
    guard unprompted.tileId == nil, unprompted.role == nil else {
        throw fail("the headless spawn persisted a tile binding or role it was not given: tileId \(String(describing: unprompted.tileId)), role \(String(describing: unprompted.role))")
    }
    guard supervisor.isRunning(unpromptedId) == false else {
        throw fail("a spawn with no prompt should not start a runner")
    }

    // MARK: 3 · a LATE subscriber replays the history (snapshot-then-tail)

    let inboxC = EventInbox()
    let streamC = supervisor.events(for: agentId)
    let taskC = Task { @MainActor in for await event in streamC { inboxC.append(event) } }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { inboxC.events.count == script.count }) else {
        throw fail("a subscriber attaching after the turn should replay the history; got \(inboxC.events.count) of \(script.count)")
    }
    if let divergence = firstDivergence(inboxC.events, expected) {
        throw fail("the replayed history is not the delivered sequence \(divergence)")
    }

    // MARK: 4 · stop terminates the runner, and the record reflects it

    let blocking = ScriptedAgentRunner(script: [.turnStarted(threadId: scriptThread, turnId: "t2")], holdUntilStopped: true)
    let stopSupervisor = AgentSupervisor(store: store, makeRunner: { _ in blocking })
    let stopAgentId = stopSupervisor.spawn(
        role: nil,
        prompt: "long running",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    let inboxD = EventInbox()
    let streamD = stopSupervisor.events(for: stopAgentId)
    let taskD = Task { @MainActor in for await event in streamD { inboxD.append(event) } }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { inboxD.events.count == 1 }) else {
        throw fail("the spawn prompt should have run: got \(inboxD.events.count) events")
    }
    guard stopSupervisor.isRunning(stopAgentId) else {
        throw fail("a blocked runner should still be held as in-flight before stop")
    }
    let beforeStop = try store.load(id: stopAgentId)?.lastActivityAt ?? .distantPast

    stopSupervisor.stop(stopAgentId)
    guard blocking.stopCount == 1 else {
        throw fail("stop did not reach the runner; stopCount \(blocking.stopCount)")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { inboxD.events.contains(.sessionStateChanged(.stopped)) }) else {
        throw fail("subscribers did not see .sessionStateChanged(.stopped) after stop")
    }
    // The blocked `run` must actually RETURN, or the agent is stopped in name only.
    // Asserted on the runner's own post-return counter, not on `isRunning`: `stop`
    // clears `runners[id]` synchronously, so `isRunning == false` is true the
    // instant stop is called and proves nothing about the blocked call.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { blocking.completedRuns == 1 }) else {
        throw fail("the blocked run() never returned after stop — completedRuns \(blocking.completedRuns)")
    }
    guard stopSupervisor.isRunning(stopAgentId) == false else {
        throw fail("the supervisor still holds a runner for a stopped agent")
    }

    // A second prompt while one is in flight must NOT replace the runner: the first
    // process would keep running, unreachable by `stop`, on the same session id.
    let concurrent = ScriptedAgentRunner(script: [], holdUntilStopped: true)
    let concurrentSupervisor = AgentSupervisor(store: store, makeRunner: { _ in concurrent })
    let busyId = concurrentSupervisor.spawn(
        role: nil,
        prompt: "occupy the runner",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { concurrent.runCount == 1 }) else {
        throw fail("the first prompt did not start; runCount \(concurrent.runCount)")
    }
    concurrentSupervisor.send("second prompt while busy", to: busyId)
    // WAIT for the violation rather than reading `runCount` straight after `send`:
    // `run` is invoked on a background queue, so an immediate read is green even
    // when a second runner was started. Found by the negative test — deleting the
    // refusal passed until this became a windowed assertion.
    guard await waitUntil(timeout: 1.0, pollInterval: 0.02, { concurrent.runCount > 1 }) == false else {
        throw fail("a second send started a second runner for a busy agent: runCount \(concurrent.runCount), prompts \(concurrent.prompts)")
    }
    guard concurrent.prompts == ["occupy the runner"] else {
        throw fail("a second send reached the runner for a busy agent: prompts \(concurrent.prompts)")
    }
    guard concurrentSupervisor.isRunning(busyId) else {
        throw fail("the refused send dropped the in-flight runner")
    }
    concurrentSupervisor.stop(busyId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { concurrent.completedRuns == 1 }) else {
        throw fail("the occupying runner did not exit after stop")
    }
    guard let afterStop = try store.load(id: stopAgentId)?.lastActivityAt else {
        throw fail("no persisted record for the stopped agent")
    }
    guard afterStop > beforeStop else {
        // Reference intervals, not formatted dates: the difference is sub-second, so
        // a `Date` description would print the two as the same string.
        throw fail("the stored record did not reflect the stop: lastActivityAt \(afterStop.timeIntervalSinceReferenceDate) is not after \(beforeStop.timeIntervalSinceReferenceDate)")
    }

    // MARK: 5 · the production path constructs Pi's persistent RPC runner…

    guard let record = supervisor.records[agentId] else {
        throw fail("the supervisor lost the record it spawned")
    }
    guard AgentSupervisor.piRunner(for: AgentRunnerLaunch(record: record, spawnDepth: 0)) is PiRpcAgentRunner else {
        throw fail("the default runner factory does not produce a PiRpcAgentRunner")
    }
    guard AgentSupervisor.claudeRunner(for: record) is ClaudeAgentRunner else {
        throw fail("the claude runner factory does not produce a ClaudeAgentRunner")
    }
    guard AgentSupervisor.codexRunner(for: record) is CodexAgentRunner else {
        throw fail("the codex runner factory does not produce a CodexAgentRunner")
    }
    // Routing policy itself (backend + provider prefix + availability → runner)
    // is pure and pinned machine-independently in runClaudeAgentBackendChecks /
    // runCodexAgentBackendChecks; asserting `productionRunner` live here would
    // make the matrix depend on whether THIS machine has claude/codex installed.

    // MARK: …6 · and no VIEW constructs one

    let (constructionSites, scannedFiles) = try runnerConstructionSites(typeName: "PiAgentRunner")
    guard scannedFiles > 0 else {
        throw fail("the source scan found no Swift files — it is looking in the wrong place")
    }
    guard constructionSites == ["App/AgentSupervisor.swift"] else {
        throw fail("PiAgentRunner is constructed outside AgentSupervisor.swift: \(constructionSites.sorted()) (the supervisor owns the runner; a view that makes its own is a second owner and will double-spawn)")
    }
    let (claudeConstructionSites, _) = try runnerConstructionSites(typeName: "ClaudeAgentRunner")
    guard claudeConstructionSites == ["App/AgentSupervisor.swift"] else {
        throw fail("ClaudeAgentRunner is constructed outside AgentSupervisor.swift: \(claudeConstructionSites.sorted()) (same single-owner rule as PiAgentRunner)")
    }
    let (codexConstructionSites, _) = try runnerConstructionSites(typeName: "CodexAgentRunner")
    guard codexConstructionSites == ["App/AgentSupervisor.swift"] else {
        throw fail("CodexAgentRunner is constructed outside AgentSupervisor.swift: \(codexConstructionSites.sorted()) (same single-owner rule as PiAgentRunner)")
    }

    // MARK: 7 · a TILE is a subscriber (P2A.4), and detaching it leaves the agent running

    let tileReport = try await checkTileIsASubscriber(store: store, config: config, cwd: cwd, fail: fail)
    let liveV2Report = try await checkLiveV2TileMigration(store: store, config: config, cwd: cwd, fail: fail)
    let capabilityReport = try await checkTurnCapabilityRepaint(store: store, config: config, cwd: cwd, fail: fail)
    let persistentRunnerReport = try await checkPersistentRunnerReuse(
        config: config, cwd: cwd, fail: fail)

    // MARK: 8 · closing a tile is closing a window, not ending the work (P2A.5)

    let detachReport = try await checkDetachOutlivesItsTile(store: store, config: config, cwd: cwd, fail: fail)
    let snapshotTailReport = try await checkTranscriptSnapshotAndTailBeyondReplayCap(
        config: config, cwd: cwd, fail: fail)

    // MARK: 9 · an agent exists and runs with no tile at all (P2A.6)

    let headlessReport = try await checkHeadlessAgents(store: store, config: config, cwd: cwd, fail: fail)

    // MARK: 10 · an isolated spawn works in its own checkout (P2C.2)

    let isolationReport = try await checkIsolatedSpawn(config: config, fail: fail)

    // MARK: 11 · archiving an agent cleans up after it, without losing work (P2C.3)

    let cleanupReport = try await checkArchiveCleanup(config: config, fail: fail)

    // MARK: 11b · a tile-less agent still persists, and archive quarantines its transcript (C4)

    let transcriptPersistenceReport = try await checkTranscriptPersistenceWithoutTile(config: config, cwd: cwd, fail: fail)

    // MARK: 12 · a tile SAYS which checkout its agent is about to touch (P2C.4)

    let branchReport = try await checkBranchChip(config: config, fail: fail)

    // MARK: 13 · an observed spawn_agent call becomes a child agent (P2D.2)

    let spawnCallReport = try await checkSpawnFromToolCall(fail: fail)

    // MARK: 13b · a spawn's result is COLLECTABLE: refused/spawned/terminal reach the model's file channel

    let spawnResultReport = try await checkSpawnResultFileChannel(fail: fail)

    // MARK: 14 · a turn you did not watch is unread, and looking clears it (P3.3)

    let readStateReport = try await checkReadState(config: config, cwd: cwd, fail: fail)

    // MARK: 15 · real work un-settles a settled agent; a refresh does not (P4.4)

    let unsettleReport = try await checkAutoUnsettle(config: config, cwd: cwd, fail: fail)

    // MARK: 16 · lifecycle writers preserve P6.2–P6.4 facts

    let lifecycleReport = try await checkPhase6LifecycleWriters(config: config, cwd: cwd, fail: fail)
    let inboxLifecycleReport = try checkPhase6InboxView(fail: fail)

    // MARK: 17 · the model and the effort level belong to the AGENT, not to Settings (P6.1)

    let providerReport = try await checkPerAgentProviderSettings(cwd: cwd, fail: fail)

    // MARK: 18 · a row's status is the TURN's state, not the process's (P4.14)

    let rowStatusReport = try await AppDelegate.checkRowStatusIsTurnState(config: config, cwd: cwd, fail: fail)

    // MARK: 19 · every semantic kind has one frozen renderer, with a safe fallback (91/P3.1)

    let rendererReport = try checkAgentBlockRendererRegistry(fail: fail)

    // MARK: 20 · tile state and actions follow turn facts/capabilities (91/P5.2)

    let turnStateReport = try await checkCapabilityDrivenTurnStates(config: config, cwd: cwd, fail: fail)

    // MARK: 21 · a status tick never rewrites the document (C10)

    let agentReferenceStatusReport = try await checkAgentReferenceLiveStatus(config: config, cwd: cwd, fail: fail)

    // MARK: 22 · B7.2 — `/clear` is one transaction, not a notice alone

    let clearCommandReport = try await checkClearCommandTransaction(config: config, cwd: cwd, fail: fail)

    // MARK: 23 · a runner that dies without a result still ends the turn

    // D1 (2026-08-26): the translators mint `.turnCompleted` only from a provider
    // result line. A CLI that exits 0 without one (crash mid-line, init never
    // parsed, silent death) made `run()` return normally, the do-block fell
    // through to `clearRunner`, and NOTHING ever told the tile the turn ended —
    // it showed "Working" forever. The supervisor now closes the turn itself.
    let noResultStore = AgentStore(
        applicationSupportDirectory: root.appendingPathComponent("no-result", isDirectory: true))
    let noResultRunner = ScriptedAgentRunner(script: [
        .turnStarted(threadId: scriptThread, turnId: "t-lost"),
        .contentDelta(threadId: scriptThread, turnId: "t-lost", streamKind: .assistant, delta: "half an answer"),
    ])
    let noResultSupervisor = AgentSupervisor(store: noResultStore, makeRunner: { _ in noResultRunner })
    let noResultId = noResultSupervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let noResultInbox = EventInbox()
    let noResultStream = noResultSupervisor.events(for: noResultId)
    let noResultTask = Task { @MainActor in for await event in noResultStream { noResultInbox.append(event) } }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { noResultSupervisor.subscriberCount(for: noResultId) == 1 }) else {
        throw fail("no-result exit: the subscriber never registered")
    }
    noResultSupervisor.send("a prompt whose result will be lost", to: noResultId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        noResultInbox.events.contains { if case .turnCompleted = $0 { return true } else { return false } }
    }) else {
        throw fail(
            "no-result exit: the runner returned without a result event and no .turnCompleted was "
            + "ever delivered — the tile shows Working forever")
    }
    let noResultCompletions = noResultInbox.events.compactMap { event -> (turnId: String, outcome: TurnOutcome, message: String?)? in
        if case let .turnCompleted(_, turnId, outcome, message) = event { return (turnId, outcome, message) }
        return nil
    }
    guard noResultCompletions.count == 1 else {
        throw fail("no-result exit: expected exactly one minted .turnCompleted, got \(noResultCompletions.count)")
    }
    guard noResultCompletions[0].outcome == .interrupted else {
        throw fail("no-result exit: the minted completion's outcome is \(noResultCompletions[0].outcome), expected .interrupted")
    }
    guard noResultCompletions[0].message?.contains("exited without reporting a result") == true else {
        throw fail("no-result exit: the minted completion carries no explanation: \(String(describing: noResultCompletions[0].message))")
    }
    // The mint must be TERMINAL: behind every event the runner queued, never before.
    guard case .turnCompleted = noResultInbox.events.last! else {
        throw fail("no-result exit: the minted completion was not the last event delivered — \(noResultInbox.events.map(eventLabel))")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { noResultSupervisor.isRunning(noResultId) == false }) else {
        throw fail("no-result exit: the runner slot was never cleared")
    }

    // D1-catch: a runner that THROWS mid-turn (not a stop) must both show the
    // error row (.runtimeError, unchanged) AND close the turn (.turnCompleted),
    // each exactly once — the error alone left the tile's liveness dangling.
    struct RunnerExploded: Error, CustomStringConvertible {
        var description: String { "checks-runner-exploded mid-turn" }
    }
    let thrownRunner = ScriptedAgentRunner(
        script: [.turnStarted(threadId: scriptThread, turnId: "t-thrown")],
        stopError: RunnerExploded())
    let thrownSupervisor = AgentSupervisor(store: noResultStore, makeRunner: { _ in thrownRunner })
    let thrownId = thrownSupervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let thrownInbox = EventInbox()
    let thrownStream = thrownSupervisor.events(for: thrownId)
    let thrownTask = Task { @MainActor in for await event in thrownStream { thrownInbox.append(event) } }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { thrownSupervisor.subscriberCount(for: thrownId) == 1 }) else {
        throw fail("thrown mid-turn: the subscriber never registered")
    }
    thrownSupervisor.send("a prompt whose runner throws", to: thrownId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        thrownInbox.events.contains { if case .turnCompleted = $0 { return true } else { return false } }
    }) else {
        throw fail("thrown mid-turn: no closing .turnCompleted was delivered after the runtime error")
    }
    let thrownErrors = thrownInbox.events.filter { if case .runtimeError = $0 { return true } else { return false } }
    let thrownCompletions = thrownInbox.events.compactMap { event -> TurnOutcome? in
        if case let .turnCompleted(_, _, outcome, _) = event { return outcome }
        return nil
    }
    guard thrownErrors.count == 1 else {
        throw fail("thrown mid-turn: expected exactly one .runtimeError, got \(thrownErrors.count)")
    }
    guard thrownCompletions == [.failed] else {
        throw fail("thrown mid-turn: expected exactly one closing .turnCompleted(.failed), got \(thrownCompletions)")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { thrownSupervisor.isRunning(thrownId) == false }) else {
        throw fail("thrown mid-turn: the runner slot was never cleared")
    }

    // D4: WHY a runner died must survive the process. For a GUI app launched via
    // `open`, stderr is /dev/null, so the fputs trail was unrecoverable. Both
    // failure paths above append one redacted line to a durable file under the
    // (isolated) app-support root.
    let diagnosticsLog = noResultStore.layout.applicationSupportDirectory
        .appendingPathComponent("agent-diagnostics.log", isDirectory: false)
    guard let diagnosticsText = try? String(contentsOf: diagnosticsLog, encoding: .utf8) else {
        throw fail("diagnostics: no agent-diagnostics.log was written at \(diagnosticsLog.path)")
    }
    guard diagnosticsText.contains("checks-runner-exploded") else {
        throw fail("diagnostics: the thrown runner's redacted message never reached the log: \(diagnosticsText)")
    }
    guard diagnosticsText.contains("exited without reporting a result") else {
        throw fail("diagnostics: the no-result exit left no trail in the log: \(diagnosticsText)")
    }
    noResultTask.cancel()
    thrownTask.cancel()
    let deadRunnerReport = "a runner that returned with no result minted one terminal "
        + ".turnCompleted(.interrupted), a mid-turn throw delivered .runtimeError plus one closing "
        + ".turnCompleted(.failed), and both left a redacted line in agent-diagnostics.log"

    let piDelegateReport = try await checkPiDelegatedRunTailing(fail: fail)
    let piRewriteFirstReport = try await checkObservedRunRewriteBeforeInitialAppend(fail: fail)
    let codexSubagentReport = try await checkCodexProviderSubagentRouting(fail: fail)
    let refusalReport = try await checkRefusedSpawnIsActionableAndLeavesNothing(fail: fail)
    let observedCapReport = try await checkObservedChildrenPastFormerCapStayVisible(fail: fail)
    let observedRaceReport = try await checkObservedRunBindingSurvivesAdoptionRace(fail: fail)
    let observedLivenessReport = try await checkObservedRunLivenessSweepClosesQuietDeadRun(fail: fail)
    for task in [taskA, taskB, taskC, taskD] { task.cancel() }
    print("AgentSupervisor: \(script.count) events fanned out to 2 live + 1 late subscriber, \(locationProjectionReport), spawn persisted headless, stop made a blocked run() return, a send on a busy agent refused, \(composerKeyAssertions) composer key/IME/undo/history assertions, \(completionAssertions) production completion assertions, \(namingReport), \(generatedNameReport), \(scannedFiles) source files scanned for stray runner construction; \(tileReport); \(liveV2Report); \(capabilityReport); \(persistentRunnerReport); \(detachReport); \(snapshotTailReport); \(headlessReport); \(isolationReport); \(cleanupReport); \(transcriptPersistenceReport); \(branchReport); \(spawnCallReport); \(spawnResultReport); \(readStateReport); \(unsettleReport); \(lifecycleReport); \(inboxLifecycleReport); \(providerReport); \(rowStatusReport); \(rendererReport); \(turnStateReport); \(agentReferenceStatusReport); \(clearCommandReport); \(deadRunnerReport); \(piDelegateReport); \(piRewriteFirstReport); \(codexSubagentReport); \(refusalReport); \(observedCapReport); \(observedRaceReport); \(observedLivenessReport); \(retiredRunnerReport)")
}

/// A callback queued by a runner that Stop has already retired must not reopen
/// execution or affect its replacement generation. The callback is deliberately
/// enqueued before `stop(_:)` while this check is still on the main actor; it
/// cannot be delivered until after the replacement is installed. The old run call
/// is then released separately, proving its process-return fallback is scoped too.
@MainActor
private func checkRetiredRunnerCannotRestartTurn(
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-retired-runner-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let retiredRunner = ScriptedAgentRunner(
        script: [.turnStarted(threadId: "provider", turnId: "initial")],
        holdUntilStopped: true,
        releaseOnStop: false)
    let replacementRunner = ScriptedAgentRunner(
        script: [
            .turnStarted(threadId: "provider", turnId: "replacement"),
            .turnCompleted(
                threadId: "provider", turnId: "replacement",
                outcome: .completed, errorMessage: nil)
        ])
    let queue = ScriptedRunnerQueue([retiredRunner, replacementRunner])
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root),
        makeRunner: { queue.next($0.record) }, warn: { _ in })
    let config = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let id = supervisor.spawn(
        role: nil, prompt: nil,
        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        harness: .pi, model: config.model, thinking: config.thinking)
    guard supervisor.send("start", to: id) else {
        throw fail("retired runner: initial send was refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.turnSnapshot(for: id)?.state == .working
    }) else { throw fail("retired runner: initial turn never became Working") }

    guard retiredRunner.emit(.turnStarted(threadId: "provider", turnId: "late-after-stop")) else {
        throw fail("retired runner: could not queue the late provider event")
    }
    supervisor.stop(id)
    guard supervisor.turnSnapshot(for: id)?.state != .working,
          supervisor.turnSnapshot(for: id)?.turnStartedAt == nil else {
        throw fail("retired runner: Stop itself did not clear Working")
    }
    let stoppedStamp = supervisor.records[id]?.runCompletedAt
    guard supervisor.send("replacement", to: id) else {
        throw fail("retired runner: replacement send was refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        replacementRunner.completedRuns == 1
            && !supervisor.isRunning(id)
            && supervisor.turnSnapshot(for: id)?.state != .working
    }), let replacementStamp = supervisor.records[id]?.runCompletedAt,
       replacementStamp != stoppedStamp else {
        throw fail("retired runner: replacement generation did not complete and clear its slot")
    }
    guard supervisor.turnSnapshot(for: id)?.turnStartedAt == nil else {
        throw fail("retired runner: completed replacement retained an elapsed anchor")
    }

    retiredRunner.releaseRunAfterStop()
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        retiredRunner.completedRuns == 1
    }) else { throw fail("retired runner: old run call did not return after release") }
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard !supervisor.isRunning(id),
          supervisor.turnSnapshot(for: id)?.state != .working,
          supervisor.turnSnapshot(for: id)?.turnStartedAt == nil,
          supervisor.records[id]?.runCompletedAt == replacementStamp else {
        throw fail("retired runner: old fallback overwrote a completed replacement after its slot cleared")
    }

    // Positive control: scoping the fallback must not suppress it for the runner
    // that still owns the slot when a provider exits silently.
    let fallbackRunner = ScriptedAgentRunner(script: [
        .turnStarted(threadId: "provider-fallback", turnId: "fallback")
    ])
    let fallbackSupervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("fallback", isDirectory: true)),
        makeRunner: { _ in fallbackRunner }, warn: { _ in })
    let fallbackID = fallbackSupervisor.spawn(
        role: nil, prompt: nil,
        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        harness: .pi, model: config.model, thinking: config.thinking)
    let fallbackInbox = EventInbox()
    let fallbackStream = fallbackSupervisor.events(for: fallbackID)
    let fallbackTask = Task { @MainActor in
        for await event in fallbackStream { fallbackInbox.append(event) }
    }
    defer { fallbackTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        fallbackSupervisor.subscriberCount(for: fallbackID) == 1
    }), fallbackSupervisor.send("silent exit", to: fallbackID) else {
        throw fail("retired runner: fallback positive control did not start")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        !fallbackSupervisor.isRunning(fallbackID)
            && fallbackSupervisor.turnSnapshot(for: fallbackID)?.state != .working
    }) else { throw fail("retired runner: current runner's silent exit stayed Working") }
    let fallbackCompletions = fallbackInbox.events.compactMap { event -> TurnOutcome? in
        guard case let .turnCompleted(_, _, outcome, _) = event else { return nil }
        return outcome
    }
    guard fallbackCompletions == [.interrupted] else {
        throw fail("retired runner: current runner fallback outcomes were \(fallbackCompletions)")
    }
    return "a queued old turnStarted and retired process-return fallback were rejected after a replacement completed and cleared its slot, while the current runner's silent exit still terminalized once"
}

/// A disposable tile must attach from the supervisor's complete semantic model,
/// never by replaying the bounded raw-event ring. The turn intentionally remains
/// open across attachment so this also covers streaming-Markdown parser state.
@MainActor
private func checkTranscriptSnapshotAndTailBeyondReplayCap(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-transcript-snapshot-tail-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
    let transcriptStore = AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true))
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { _ in ScriptedAgentRunner(script: []) },
        warn: { _ in },
        transcriptStore: transcriptStore)
    let agentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let thread = AgentSupervisor.threadId(for: agentId)
    let turn = "beyond-replay-cap"
    supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: agentId)
    supervisor.qaDeliver(.contentDelta(
        threadId: thread, turnId: turn, streamKind: .assistant,
        delta: "BEGIN-ONLY-ONCE|"), to: agentId)
    for _ in 0..<550 {
        supervisor.qaDeliver(.contentDelta(
            threadId: thread, turnId: turn, streamKind: .assistant, delta: "x"), to: agentId)
    }
    supervisor.qaDeliver(.contentDelta(
        threadId: thread, turnId: turn, streamKind: .assistant,
        delta: "|BEFORE-ATTACH"), to: agentId)

    let tileId = UUID()
    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileId,
        kind: .managedAgent,
        title: "snapshot-tail",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    tile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: agentId) == 1
            && tile.qaTranscriptText.contains("BEGIN-ONLY-ONCE|")
            && tile.qaTranscriptText.contains("|BEFORE-ATTACH")
    }) else {
        throw fail("snapshot-tail: attaching after more than replayCap deltas truncated the open response: \(tile.qaTranscriptText)")
    }

    supervisor.qaDeliver(.contentDelta(
        threadId: thread, turnId: turn, streamKind: .assistant,
        delta: "|AFTER-ATTACH"), to: agentId)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaTranscriptText.contains("|AFTER-ATTACH")
    }) else {
        throw fail("snapshot-tail: the tail did not continue the installed open response")
    }
    let copies = tile.qaTranscriptText.components(separatedBy: "BEGIN-ONLY-ONCE|").count - 1
    guard copies == 1 else {
        throw fail("snapshot-tail: snapshot/tail boundary duplicated the response prefix \(copies) times")
    }
    tile.detach()
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: agentId) == 0
    }) else {
        throw fail("snapshot-tail: closing the replacement tile leaked its observer")
    }
    return "full semantic snapshot + tail preserved an open 552-delta response beyond replayCap with zero loss/duplication and zero leaked observers"
}

/// B7.2 — `/clear`'s one-transaction contract, driven through the real
/// production dispatch (`AgentSupervisor.accept(.providerCommand(…))`) rather
/// than calling `performClearCommand` directly, so a regression that only
/// wires the classifier back to the OLD notice-only path still fails here.
///
/// Every one of the five stored/live effects is seeded through a REAL prior
/// state (a delivered `.contextWindowUpdated`, a disarmed naming source, a
/// real child record, a populated replay buffer) rather than asserting
/// against a hand-built "already cleared" fixture, so a `/clear` that does
/// nothing to a field that started out already-clear would not pass by
/// accident.
@MainActor
func checkClearCommandTransaction(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-clear-command-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)

    let createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let parentID = AgentID(rawValue: UUID())
    let childID = AgentID(rawValue: UUID())

    // Seeded pre-cleared so every assertion below proves a real transition,
    // not an already-clear fixture read back unchanged.
    let parent = AgentRecord(
        id: parentID,
        displayName: "old prompt-derived name",
        displayNameSource: .prompt,
        namingRequest: NamingRequest(expectedName: "old prompt-derived name"),
        harness: .claudeCode,
        model: config.model,
        thinking: config.thinking,
        cwd: cwd.path,
        createdAt: createdAt,
        lastActivityAt: createdAt,
        lastContextWindow: AgentContextWindowSnapshot(
            usedTokens: 9_000, maxTokens: 10_000, observedAt: createdAt,
            source: .claudeAssistantUsage, freshness: .live),
        providerSessionId: "claude-old-session-id"
    )
    let child = AgentRecord(
        id: childID,
        displayName: "child",
        model: config.model,
        thinking: config.thinking,
        cwd: cwd.path,
        parentAgentID: parentID,
        createdAt: createdAt,
        lastActivityAt: createdAt
    )
    try store.upsert(parent)
    try store.upsert(child)

    let transcriptStore = AgentTranscriptStore(
        root: root.appendingPathComponent("agent-transcripts", isDirectory: true))
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in
        ScriptedAgentRunner(script: [], holdUntilStopped: false)
    }, transcriptStore: transcriptStore)
    supervisor.restore()

    guard supervisor.children(of: parentID) == [childID] else {
        throw fail("clear-command fixture: the seeded child did not restore as a child of the parent")
    }
    // The in-memory cumulative telemetry cache and the replay buffer both need
    // real prior content — a live `.contextWindowUpdated` populates
    // `contextWindowSnapshots[id]` (distinct from the persisted
    // `record.lastContextWindow` seeded above) and `history[id]`, exactly like
    // a real turn would.
    let liveSnapshot = AgentContextWindowSnapshot(
        usedTokens: 9_500, maxTokens: 10_000, observedAt: createdAt,
        source: .claudeAssistantUsage, freshness: .live)
    supervisor.qaDeliver(.contextWindowUpdated(threadId: "does-not-matter", snapshot: liveSnapshot), to: parentID)
    guard supervisor.contextWindowSnapshot(for: parentID) == liveSnapshot else {
        throw fail("clear-command fixture: the live contextWindowUpdated did not seed the cumulative telemetry cache")
    }
    var preClearReplay: [AgentRuntimeEvent] = []
    for await event in supervisor.events(for: parentID) { preClearReplay.append(event); break }
    guard preClearReplay == [.contextWindowUpdated(threadId: "does-not-matter", snapshot: liveSnapshot)] else {
        throw fail("clear-command fixture: the replay buffer did not carry the delivered event")
    }

    let invocation = AgentCommandInvocation(descriptorID: "array:clear", name: "clear", surface: .array)
    let outcome = await supervisor.accept(.providerCommand(invocation), for: parentID)
    guard case .accepted = outcome else {
        throw fail("clear command: expected .accepted, got \(outcome)")
    }

    // 1 · session rotation MARKED (claude only) — an eager launch is not what
    //     `/clear` does; it defers to the next real turn (see
    //     `performClearCommand`'s doc comment).
    guard supervisor.records[parentID]?.pendingSessionForkFrom == "claude-old-session-id" else {
        throw fail("clear command: did not mark the old session for --fork-session rotation, got \(String(describing: supervisor.records[parentID]?.pendingSessionForkFrom))")
    }
    guard AgentSupervisor.claudeRunnerConfig(for: supervisor.records[parentID]!).forkSession,
          AgentSupervisor.claudeRunnerConfig(for: supervisor.records[parentID]!).sessionId == "claude-old-session-id" else {
        throw fail("clear command: the next claude runner config did not route through the fork")
    }

    // 2 · lastContextWindow cleared (persisted).
    guard supervisor.records[parentID]?.lastContextWindow == nil,
          try store.load(id: parentID)?.lastContextWindow == nil else {
        throw fail("clear command: lastContextWindow survived, would re-seed a stale meter after relaunch")
    }

    // 3 · naming re-armed — both fields the funnel actually gates on.
    guard supervisor.records[parentID]?.displayNameSource == .sentinel,
          supervisor.records[parentID]?.namingRequest == nil else {
        throw fail("clear command: naming was not re-armed (source=\(String(describing: supervisor.records[parentID]?.displayNameSource)), request=\(String(describing: supervisor.records[parentID]?.namingRequest)))")
    }

    // 4 · subagent chip dropped — the supervisor's own parent/child bookkeeping
    //     now agrees that the cleared thread cannot see this child anymore.
    guard supervisor.children(of: parentID).isEmpty,
          supervisor.records[childID]?.parentAgentID == nil,
          try store.load(id: childID)?.parentAgentID == nil else {
        throw fail("clear command: the child's parent link was not severed")
    }

    // 5 · the 500-entry replay buffer AND the live cumulative telemetry cache
    //     both reset — the persisted lastContextWindow (assertion 2) is a
    //     DIFFERENT storage location from this in-memory cache.
    guard supervisor.contextWindowSnapshot(for: parentID) == nil else {
        throw fail("clear command: the live cumulative context-window cache survived")
    }
    // `events(for:)` replays its buffer then stays open on the live stream, so
    // proving "empty" needs a bounded read: deliver one new sentinel and
    // confirm IT comes first. If the pre-clear event had survived, FIFO replay
    // order would hand it back before the sentinel.
    let sentinelSnapshot = AgentContextWindowSnapshot(
        usedTokens: 1, maxTokens: 2, observedAt: createdAt,
        source: .claudeAssistantUsage, freshness: .live)
    supervisor.qaDeliver(.contextWindowUpdated(threadId: "sentinel", snapshot: sentinelSnapshot), to: parentID)
    var firstReplayedAfterClear: AgentRuntimeEvent?
    for await event in supervisor.events(for: parentID) { firstReplayedAfterClear = event; break }
    guard firstReplayedAfterClear == .contextWindowUpdated(threadId: "sentinel", snapshot: sentinelSnapshot) else {
        throw fail("clear command: the replay buffer was not cleared — got \(String(describing: firstReplayedAfterClear)) before the post-clear sentinel")
    }

    // 6 · the boundary, as a Tier A notice: the transcript keeps its history.
    // Debounced persistence (`scheduleTranscriptPersist`), so poll rather than
    // assert on the first read.
    let sessionID = AgentTranscriptStore.canonicalSessionID(for: parentID)
    var noticeDocument: AgentDocument?
    let deadline = Date().addingTimeInterval(3)
    while noticeDocument == nil {
        noticeDocument = try await transcriptStore.load(agentID: parentID, sessionID: sessionID)
        if noticeDocument != nil { break }
        if Date() >= deadline { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    guard let document = noticeDocument,
          document.entries.contains(where: { entry in
              guard case .localNotice = entry.provenance else { return false }
              return true
          }) else {
        throw fail("clear command: no Tier A notice was appended to the persisted transcript")
    }

    return "B7.2 clear-command transaction: session fork marked and routed, lastContextWindow cleared, naming re-armed, subagent chip dropped, replay buffer and cumulative telemetry reset, boundary notice appended — all through the real .providerCommand dispatch"
}

@MainActor
private func checkGeneratedNameOneShot<Failure: Error>(
    config: AgentModelConfig.Resolution,
    fail: (String) -> Failure
) async throws -> String {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-generated-name-oneshot-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let appSource = try String(
        contentsOf: URL(fileURLWithPath: "Sources/ContinuumRevived/App/ContinuumApp.swift"),
        encoding: .utf8)
    guard !appSource.contains("generateNamesFromInbox"),
          appSource.contains("requestGeneratedNames") else {
        throw fail("generated-name orchestration still lives in ContinuumApp.swift instead of the supervisor owner")
    }

    // This is a real executable child, not a fake Process object. It records the
    // argument vector and stdin separately, can hold a request open, and forks a
    // child for the timeout witness. It never reaches the network.
    let executable = root.appendingPathComponent("fake-pi", isDirectory: false)
    let fakePi = """
    #!/bin/sh
    set -eu
    printf '%s\\n' "$@" > .p45-args
    has_no_session=false
    for arg in "$@"; do
      if [ "$arg" = "--no-session" ]; then has_no_session=true; fi
    done
    if [ "$has_no_session" = false ]; then
      mkdir -p "$HOME/.pi/agent/sessions" "$HOME/.pi/agent/transcripts"
      : > "$HOME/.pi/agent/sessions/fake-session.jsonl"
      : > "$HOME/.pi/agent/transcripts/fake-transcript.jsonl"
    fi
    if [ -e .p45-input-failure ]; then
      exec 0<&-
      : > .p45-input-closed
      (sleep 0.7; : > .p45-input-child-survived) &
      printf '%s' "$!" > .p45-input-child-pid
      sleep 30
      exit 0
    fi
    cat > .p45-stdin
    if [ -e .p45-normal-descendant ]; then
      (sleep 0.7; : > .p45-normal-child-survived) &
      printf '%s' "$!" > .p45-normal-child-pid
      printf '%s\n' '{"name":"Normal Child"}'
      exit 0
    fi
    if [ -e .p45-timeout ]; then
      (sleep 0.7; : > .p45-child-survived) &
      printf '%s' "$!" > .p45-child-pid
      sleep 30
      exit 0
    fi
    while [ -e .p45-hold ]; do sleep 0.01; done
    if [ -e .p45-provider-output ]; then
      cat .p45-provider-output
      exit 0
    fi
    if [ -e .p45-invalid ]; then
      printf '%s\\n' '{"name":"openai-codex/gpt-5.4-mini"}'
      exit 0
    fi
    printf '%s\\n' '{"name":"\\"  Ship   It  \\""}'
    """
    try fakePi.write(to: executable, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let configDirectory = root.appendingPathComponent("pi-config", isDirectory: true)
    let controlledHome = root.appendingPathComponent("controlled-home", isDirectory: true)
    let ephemeralConfig = root.appendingPathComponent("one-shot-config", isDirectory: true)
    try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: controlledHome, withIntermediateDirectories: true)
    let authData = Data(#"{"openai-codex":{"access":"fixture-access","expires":4102444800000}}"#.utf8)
    try authData.write(to: configDirectory.appendingPathComponent("auth.json"))
    let capability = AgentNameGenerationCapability(
        executable: executable.path,
        configDirectory: configDirectory,
        loginShellPath: "/bin:/usr/bin",
        model: AgentNameGenerationCapability.cheapModel)

    // Capability and login-shell resolution are pure enough to exercise without
    // invoking a provider. The negative auth witness is intentionally expired.
    let now = Date(timeIntervalSince1970: 1_000)
    let validAuth = Data(#"{"openai-codex":{"access":"fixture-access"}}"#.utf8)
    let refreshAuth = Data(#"{"openai-codex":{"refresh":"fixture-refresh","expires":0}}"#.utf8)
    let expiredAuth = Data(#"{"openai-codex":{"access":"fixture-access","expires":999000}}"#.utf8)
    guard AgentNameGenerationCapability.hasAuthentication(
            in: configDirectory, now: now, data: validAuth),
          AgentNameGenerationCapability.hasAuthentication(
            in: configDirectory, now: now, data: refreshAuth),
          !AgentNameGenerationCapability.hasAuthentication(
            in: configDirectory, now: now, data: expiredAuth) else {
        throw fail("auth gate accepted expired access or rejected a usable fixture credential")
    }
    guard AgentNameGenerationCapability.resolvedExecutable(
            loginShellPath: "/missing:/bin", fileExists: { $0 == "/bin/pi" }) == "/bin/pi",
          AgentNameGenerationCapability.resolvedExecutable(
            loginShellPath: "/missing:/also-missing", fileExists: { _ in false }) == nil else {
        throw fail("login-shell executable resolution did not select the first executable or refuse an absent one")
    }

    // The UI query is a snapshot, not a resolver. This records the initial
    // unknown state as hidden and proves that a hanging/noisy login shell cannot
    // make a main-actor menu query wait. The actual resolver is then exercised
    // on a detached task with both stdout and stderr over the pipe cap.
    AgentNameGenerationCapabilityCache.shared.resetForQA()
    let queryStarted = Date()
    let initialCapabilityQuery = AgentSupervisor.nameGenerationCapabilityAvailable
    guard !initialCapabilityQuery,
          Date().timeIntervalSince(queryStarted) < 0.05 else {
        throw fail("the initial capability query was not immediately hidden: available=\(initialCapabilityQuery)")
    }
    let menuProbe = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 280, height: 240))
    let menuProbeID = UUID()
    menuProbe.wiredRowActions = [.generateName]
    menuProbe.onRowAction = { _, _ in }
    menuProbe.reload(rows: [AgentInboxRow(
        id: menuProbeID,
        title: "Menu probe",
        state: .ready,
        createdAt: now)])
    menuProbe.layoutForQA()
    let menuQueryStarted = Date()
    guard menuProbe.openRowMenuForQA(clickedRowId: menuProbeID),
          !menuProbe.rowMenuTitlesForQA.contains(InboxRowAction.generateName.title(forCount: 1)),
          Date().timeIntervalSince(menuQueryStarted) < 0.05 else {
        throw fail("the initial row-menu capability query was not immediately hidden")
    }
    let loginShell = root.appendingPathComponent("noisy-hanging-login-shell", isDirectory: false)
    let noisyShell = """
    #!/bin/sh
    i=0
    while [ "$i" -lt 4096 ]; do
      printf 'login-shell-noise-%s-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' "$i"
      printf 'login-shell-stderr-%s-yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\\n' "$i" >&2
      i=$((i + 1))
    done
    sleep 30
    """
    try noisyShell.write(to: loginShell, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loginShell.path)
    let loginProbeStarted = Date()
    let loginCapability = await Task.detached(priority: .utility) {
        AgentNameGenerationCapability.live(
            environment: [
                "HOME": controlledHome.path,
                "PI_CODING_AGENT_DIR": configDirectory.path,
                "PATH": "/bin:/usr/bin",
                "SHELL": loginShell.path,
            ],
            now: now)
    }.value
    guard loginCapability == nil,
          Date().timeIntervalSince(loginProbeStarted) < 2 else {
        throw fail("a noisy/hanging login shell was not bounded: result=\(String(describing: loginCapability))")
    }
    // The cache remains a hidden/unavailable answer until its own resolver has
    // completed; this query is still process-free after the failed probe.
    let postProbeQueryStarted = Date()
    _ = AgentSupervisor.nameGenerationCapabilityAvailable
    guard Date().timeIntervalSince(postProbeQueryStarted) < 0.05 else {
        throw fail("the cached capability query performed synchronous shell work after resolution")
    }

    func fixtureManifest(in roots: [URL]) -> Set<String> {
        var paths = Set<String>()
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: []) else { continue }
            while let item = enumerator.nextObject() as? URL {
                let relative = item.path.hasPrefix(root.path + "/")
                    ? String(item.path.dropFirst(root.path.count + 1))
                    : item.lastPathComponent
                paths.insert(root.lastPathComponent + "/" + relative)
            }
        }
        return paths
    }
    func containsSessionOrTranscriptArtifact(_ paths: Set<String>) -> Bool {
        paths.contains { path in
            let lower = path.lowercased()
            return lower.contains("session") || lower.contains("transcript")
        }
    }

    // The actual one-shot proves stdin, --no-session, no user prompt in argv,
    // no session/transcript artifact in a controlled HOME/config fixture, and
    // the shared sanitizer on a quoted candidate line.
    let fixtureRoots = [controlledHome, configDirectory]
    let fixtureBefore = fixtureManifest(in: fixtureRoots)
    let privatePrompt = "PRIVATE prompt that must never become argv metadata"
    let output = try await Task.detached(priority: .utility) {
        try AgentNameOneShot.run(
            capability: capability,
            prompt: privatePrompt,
            cwd: root,
            timeout: 2,
            environmentOverrides: ["HOME": controlledHome.path],
            configDirectoryOverride: ephemeralConfig)
    }.value
    guard AgentNameOneShot.candidate(
            from: output,
            model: config.model,
            role: "reviewer",
            id: UUID()) == "Ship It" else {
        throw fail("the fake Pi output did not sanitize to the expected one-line name")
    }
    let args = try String(contentsOf: root.appendingPathComponent(".p45-args"), encoding: .utf8)
    let receivedPrompt = try String(contentsOf: root.appendingPathComponent(".p45-stdin"), encoding: .utf8)
    let fixtureAfter = fixtureManifest(in: fixtureRoots)
    guard args.contains("--no-session"), args.contains("--print"),
          !args.contains(privatePrompt), !args.contains("Ship It"),
          receivedPrompt == privatePrompt,
          fixtureBefore == fixtureAfter,
          !containsSessionOrTranscriptArtifact(fixtureAfter),
          !fileManager.fileExists(atPath: ephemeralConfig.path) else {
        throw fail("--no-session did not keep the prompt on stdin only or left a session/transcript artifact: args=\(args.debugDescription), stdin=\(receivedPrompt.debugDescription), fixture=\(fixtureAfter.sorted())")
    }
    guard AgentNameOneShot.candidate(
            from: "```\\nName: \"  \(config.model)  \"\\n```",
            model: config.model,
            role: "reviewer",
            id: UUID()) == nil else {
        throw fail("identifier-shaped one-shot output was accepted as a display name")
    }

    // These are real fake-Pi stdout cases, not only direct parser calls. Every
    // wrapper/noise shape is refused as a whole; none is trimmed into a title.
    let providerNoiseCases: [(String, String)] = [
        ("warning", "{\"name\":\"Warning: using fallback model\"}\n"),
        ("fallback", "{\"name\":\"fallback model selected\"}\n"),
        ("error", "{\"name\":\"Error: provider unavailable\"}\n"),
        ("progress", "{\"name\":\"Progress 40%\"}\n"),
        ("role", "{\"name\":\"assistant: Ship It\"}\n"),
        ("title-field", "{\"title\":\"Ship It\"}\n"),
        ("extra-field", "{\"name\":\"Ship It\",\"status\":\"done\"}\n"),
        ("fence", "```\n{\"name\":\"Ship It\"}\n```\n"),
        ("prose", "Here is the name you requested: Ship It\n"),
        ("multi-line", "{\"name\":\"Ship It\"}\nI hope this helps.\n")
    ]
    for (kind, noise) in providerNoiseCases {
        let outputFile = root.appendingPathComponent(".p45-provider-output")
        try noise.write(to: outputFile, atomically: true, encoding: .utf8)
        let noiseOutput = try await Task.detached(priority: .utility) {
            try AgentNameOneShot.run(
                capability: capability,
                prompt: privatePrompt,
                cwd: root,
                timeout: 2,
                environmentOverrides: ["HOME": controlledHome.path],
                configDirectoryOverride: ephemeralConfig)
        }.value
        try? fileManager.removeItem(at: outputFile)
        guard AgentNameOneShot.candidate(
                from: noiseOutput,
                model: config.model,
                role: "reviewer",
                id: UUID()) == nil else {
            throw fail("provider noise case \(kind) was converted into a candidate: \(noiseOutput.debugDescription)")
        }
    }

    // A real supervisor request lands the result through the production mutation
    // path and keeps the prompt-derived title/name out of the companion projection.
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
    let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { _ in runner },
        nameGenerationCapabilityProvider: { capability },
        nameGenerationTimeout: 2)
    let generatedID = supervisor.spawn(
        role: "reviewer",
        prompt: privatePrompt,
        cwd: root,
        model: config.model,
        thinking: config.thinking)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        !supervisor.isRunning(generatedID)
    }) else {
        throw fail("the fixture prompt did not finish before the generated-name action")
    }
    guard supervisor.requestGeneratedName(agentID: generatedID) else {
        throw fail("an authenticated fake Pi capability did not start the explicit action")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.qaActiveNameGenerationCount == 0
    }), let generated = supervisor.records[generatedID],
          generated.displayName == "Ship It",
          generated.displayNameSource == .prompt,
          generated.namingRequest == nil,
          try store.load(id: generatedID)?.displayName == "Ship It" else {
        throw fail("the production request did not land the sanitized name through its CAS path")
    }
    let snapshot = AgentInventory.snapshot(
        terminalDescriptors: [],
        liveStatuses: [:],
        agents: [generated],
        activityByAgent: [:],
        replicaId: UUID(),
        now: Date())
    guard snapshot.byAgent[generatedID.rawValue] != nil else {
        throw fail("the companion snapshot did not contain the generated agent")
    }
    // This is the exact activity envelope sent by DesktopCompanionSyncService,
    // not a host-bound AgentRecord and not merely a field inspection. The source
    // prompt and generated name must both be absent from the bytes, while the
    // boundary sentinel remains as the safe summary.
    let companionPayload = String(
        decoding: try JSONCodec.makeEncoder().encode(
            SyncMessage.activity(.snapshot(snapshot))),
        as: UTF8.self)
    guard companionPayload.contains(AgentRecord.defaultAgentName),
          !companionPayload.contains(privatePrompt),
          !companionPayload.contains("Ship It") else {
        throw fail("the actual companion payload carried the source prompt or generated name: \(companionPayload)")
    }

    // A missing capability refuses before any Process launch. This is the required
    // negative witness for the hidden/absent-auth path.
    let absentRoot = root.appendingPathComponent("absent", isDirectory: true)
    let absentStore = AgentStore(applicationSupportDirectory: absentRoot)
    let absentSupervisor = AgentSupervisor(
        store: absentStore,
        makeRunner: { _ in ScriptedAgentRunner(script: []) },
        nameGenerationCapabilityProvider: { nil })
    let absentID = absentSupervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: root,
        model: config.model,
        thinking: config.thinking)
    guard !absentSupervisor.requestGeneratedName(agentID: absentID),
          absentSupervisor.qaActiveNameGenerationCount == 0,
          absentSupervisor.records[absentID]?.namingRequest == nil else {
        throw fail("an absent capability started naming work or armed a durable request")
    }

    // A human rename while the real fake process is held must win the request CAS
    // after the child returns. This is production mutation evidence, not a direct
    // AgentRecord-only test.
    let hold = root.appendingPathComponent(".p45-hold")
    try Data().write(to: hold)
    let raceID = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: root,
        model: config.model,
        thinking: config.thinking)
    guard supervisor.requestGeneratedName(agentID: raceID),
          await waitUntil(timeout: 5, pollInterval: 0.02, {
              fileManager.fileExists(atPath: root.appendingPathComponent(".p45-stdin").path)
          }),
          supervisor.rename(agentID: raceID, to: "Human wins") else {
        throw fail("the held production one-shot did not reach the rename race")
    }
    try fileManager.removeItem(at: hold)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.qaActiveNameGenerationCount == 0
    }), supervisor.records[raceID]?.displayName == "Human wins",
          supervisor.records[raceID]?.displayNameSource == .manual else {
        throw fail("a human rename lost to a late generated-name completion")
    }

    // Three held requests prove the main-actor admission cap is race-safe: the
    // first two use distinct fixture working directories so their fake providers
    // cannot contend over one marker or stdin file, while the refused member is
    // never armed. Releasing both accepted holds must release both slots.
    let burstRoots = (0..<3).map { root.appendingPathComponent("burst-\($0)", isDirectory: true) }
    for burstRoot in burstRoots {
        try fileManager.createDirectory(at: burstRoot, withIntermediateDirectories: true)
    }
    for burstRoot in burstRoots.prefix(2) {
        try Data().write(to: burstRoot.appendingPathComponent(".p45-hold"))
    }
    let burstIDs = burstRoots.map { burstRoot in
        supervisor.spawn(role: nil, prompt: nil, cwd: burstRoot, model: config.model, thinking: config.thinking)
    }
    let burst = supervisor.requestGeneratedNames(agentIDs: burstIDs)
    guard burst.accepted == Array(burstIDs.prefix(2)),
          burst.refused == [burstIDs[2]],
          supervisor.qaActiveNameGenerationCount == AgentSupervisor.maximumConcurrentNameGenerations,
          supervisor.records[burstIDs[2]]?.displayName == AgentRecord.defaultAgentName,
          supervisor.records[burstIDs[2]]?.namingRequest == nil else {
        throw fail("the generated-name burst exceeded the concurrency cap or armed the refused member")
    }
    for burstRoot in burstRoots.prefix(2) {
        try fileManager.removeItem(at: burstRoot.appendingPathComponent(".p45-hold"))
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.qaActiveNameGenerationCount == 0
    }),
          supervisor.records[burstIDs[0]]?.displayName == "Ship It",
          supervisor.records[burstIDs[1]]?.displayName == "Ship It",
          supervisor.records[burstIDs[2]]?.displayName == AgentRecord.defaultAgentName,
          supervisor.records[burstIDs[2]]?.namingRequest == nil else {
        throw fail("the capped burst did not release both accepted names while keeping the refused member unchanged")
    }

    // Timeout: the fake forks a child that would leave a marker after the leader
    // exits. A process-group kill must prevent that marker from ever appearing.
    let timeoutMarker = root.appendingPathComponent(".p45-timeout")
    try Data().write(to: timeoutMarker)
    _ = try? fileManager.removeItem(at: root.appendingPathComponent(".p45-child-survived"))
    let timeoutResult = await Task.detached(priority: .utility) {
        do {
            _ = try AgentNameOneShot.run(
                capability: capability,
                prompt: "timeout prompt",
                cwd: root,
                timeout: 0.12)
            return false
        } catch AgentNameOneShotError.timedOut {
            return true
        } catch {
            return false
        }
    }.value
    try? fileManager.removeItem(at: timeoutMarker)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    guard timeoutResult,
          !fileManager.fileExists(atPath: root.appendingPathComponent(".p45-child-survived").path) else {
        throw fail("the one-shot timeout did not kill the forked process group")
    }

    func descendantIsAlive(pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    // Normal leader exit is a separate failure mode from timeout: the fake
    // writes a valid result and exits immediately, while its child keeps both
    // output descriptors open. The return must stay bounded and the child must
    // not get a chance to leave its survival marker.
    let normalDescendantMarker = root.appendingPathComponent(".p45-normal-descendant")
    try Data().write(to: normalDescendantMarker)
    _ = try? fileManager.removeItem(at: root.appendingPathComponent(".p45-normal-child-survived"))
    _ = try? fileManager.removeItem(at: root.appendingPathComponent(".p45-normal-child-pid"))
    let normalStarted = Date()
    let normalResult = await Task.detached(priority: .utility) {
        try? AgentNameOneShot.run(
            capability: capability,
            prompt: "normal descendant prompt",
            cwd: root,
            timeout: 1)
    }.value
    let normalElapsed = Date().timeIntervalSince(normalStarted)
    try? fileManager.removeItem(at: normalDescendantMarker)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    guard normalResult.map({ AgentNameOneShot.candidate(
            from: $0,
            model: config.model,
            role: "reviewer",
            id: UUID()) == "Normal Child" }) == true,
          normalElapsed < 2,
          !fileManager.fileExists(atPath: root.appendingPathComponent(".p45-normal-child-survived").path),
          !descendantIsAlive(pidFile: root.appendingPathComponent(".p45-normal-child-pid")) else {
        throw fail("normal leader exit did not bound pipe drain and process-group cleanup: elapsed=\(normalElapsed), output=\(String(describing: normalResult))")
    }

    // Input failure is the other cleanup path. The fake closes stdin before
    // the write and leaves a descendant holding stdout/stderr; no unbounded
    // post-SIGTERM wait or pipe read may retain the request slot.
    let inputFailureMarker = root.appendingPathComponent(".p45-input-failure")
    try Data().write(to: inputFailureMarker)
    _ = try? fileManager.removeItem(at: root.appendingPathComponent(".p45-input-child-survived"))
    _ = try? fileManager.removeItem(at: root.appendingPathComponent(".p45-input-child-pid"))
    let inputFailureStarted = Date()
    let inputFailureResult = await Task.detached(priority: .utility) {
        do {
            _ = try AgentNameOneShot.run(
                capability: capability,
                prompt: privatePrompt,
                cwd: root,
                timeout: 1,
                inputWriteDelay: 0.2)
            return "success"
        } catch AgentNameOneShotError.inputFailed {
            return "input-failed"
        } catch {
            return "other-failure"
        }
    }.value
    let inputFailureElapsed = Date().timeIntervalSince(inputFailureStarted)
    try? fileManager.removeItem(at: inputFailureMarker)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    guard inputFailureResult == "input-failed",
          inputFailureElapsed < 2,
          !fileManager.fileExists(atPath: root.appendingPathComponent(".p45-input-child-survived").path),
          !descendantIsAlive(pidFile: root.appendingPathComponent(".p45-input-child-pid")) else {
        throw fail("input failure did not bound cleanup: result=\(inputFailureResult), elapsed=\(inputFailureElapsed)")
    }

    // The same two paths must release the supervisor's concurrency slot. The
    // input-failure agent starts with a real prompt-derived name so failure is
    // also proven not to clobber the prior title.
    let normalSupervisorRoot = root.appendingPathComponent("normal-supervisor", isDirectory: true)
    let inputSupervisorRoot = root.appendingPathComponent("input-supervisor", isDirectory: true)
    try fileManager.createDirectory(at: normalSupervisorRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: inputSupervisorRoot, withIntermediateDirectories: true)
    try Data().write(to: normalSupervisorRoot.appendingPathComponent(".p45-normal-descendant"))
    try Data().write(to: inputSupervisorRoot.appendingPathComponent(".p45-input-failure"))
    let normalSupervisorID = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: normalSupervisorRoot,
        model: config.model,
        thinking: config.thinking)
    let inputSupervisorID = supervisor.spawn(
        role: nil,
        prompt: "Prior stable name",
        cwd: inputSupervisorRoot,
        model: config.model,
        thinking: config.thinking)
    guard let priorName = supervisor.records[inputSupervisorID]?.displayName else {
        throw fail("input-failure setup did not create a prior display name")
    }
    guard supervisor.requestGeneratedNames(agentIDs: [normalSupervisorID, inputSupervisorID]).accepted.count == 2 else {
        throw fail("normal/input-failure supervisor requests did not both claim a slot")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.qaActiveNameGenerationCount == 0
    }), supervisor.records[normalSupervisorID]?.displayName == "Normal Child",
          supervisor.records[inputSupervisorID]?.displayName == priorName,
          supervisor.records[inputSupervisorID]?.namingRequest == nil else {
        throw fail("normal/input-failure supervisor paths did not release their slots or preserve the prior name")
    }

    return "P4.5 async cached capability gate with bounded noisy/hanging login-shell witness; fake-pi stdin/--no-session with controlled HOME/config artifact absence, strict one-field JSON/noise rejection, auth/executable gates, exact companion-envelope prompt/generated scrub, production CAS, supervisor-owned burst cap/release, normal-exit/input-failure/timeout process-group cleanup, bounded pipe drains, and prior-name preservation"
}

/// Focused witness for record-backed names reaching an already-attached tile.
/// Kept separate from the broad supervisor corpus so a failure in an unrelated
/// composer contract cannot prevent this live identity boundary from running.
@MainActor
func runAgentDisplayNameChecks() async throws {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-display-name-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let config = AgentModelConfig.resolvedFromDefaults()
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })

    func makeView(for id: AgentID) throws -> ManagedAgentTileNSView {
        let tile = Tile(
            id: UUID(), kind: .managedAgent, title: "GPT-5.6",
            frame: TileFrame(x: 0, y: 0, width: 480, height: 320),
            zPosition: .fromLegacyRank(0), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent")
        )
        let view = ManagedAgentTileNSView(tile: tile)
        view.attach(agentID: id, supervisor: supervisor)
        guard view.qaAgentHeaderName == AgentRecord.defaultAgentName else {
            throw fail("a fresh attached tile did not show the record's sentinel")
        }
        return view
    }

    let promptedID = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd,
        model: config.model, thinking: config.thinking
    )
    let promptedView = try makeView(for: promptedID)
    defer { promptedView.detach() }
    supervisor.send("Fix\n\tparser", to: promptedID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
              runner.runCount == 1 && !supervisor.isRunning(promptedID)
          }),
          promptedView.qaAgentHeaderName == "Fix parser" else {
        throw fail("a first-prompt name did not reach the attached tile header: \(promptedView.qaAgentHeaderName)")
    }
    guard supervisor.rename(agentID: promptedID, to: "Human chosen"),
          promptedView.qaAgentHeaderName == "Human chosen" else {
        throw fail("a manual name did not reach the attached tile header: \(promptedView.qaAgentHeaderName)")
    }

    let generatedID = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd,
        model: config.model, thinking: config.thinking
    )
    let generatedView = try makeView(for: generatedID)
    defer { generatedView.detach() }
    guard let request = supervisor.beginNameGeneration(agentID: generatedID),
          supervisor.applyGeneratedName("Generated title", for: request, agentID: generatedID),
          generatedView.qaAgentHeaderName == "Generated title" else {
        throw fail("a generated name did not reach the attached tile header: \(generatedView.qaAgentHeaderName)")
    }

    print("agent display names: first-prompt, manual, and generated names refresh attached tile headers")
}

@MainActor
private func checkAgentNameContract<Failure: Error>(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-name-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })

    // P4.1: every spawn starts with the one shared permission sentinel, never a
    // role/model/UUID. P4.2: the first valid prompt is the only seed site.
    let id = supervisor.spawn(
        role: "operator",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    guard let initial = supervisor.records[id],
          initial.displayName == AgentRecord.defaultAgentName,
          initial.displayNameSource == .sentinel,
          initial.displayName != config.model,
          initial.displayName != "operator",
          initial.displayName != id.rawValue.uuidString else {
        throw fail("a new agent did not start with the shared sentinel instead of an identifier")
    }
    supervisor.send("Fix\n\tparser", to: id)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.runCount == 1 && !supervisor.isRunning(id) }) else {
        throw fail("the first prompt did not finish in the deterministic naming runner")
    }
    guard let first = supervisor.records[id],
          first.displayName == "Fix parser",
          first.displayNameSource == .prompt else {
        throw fail("the first prompt did not seed the display name inside send(_:to:): \(String(describing: supervisor.records[id]?.displayName))")
    }

    // A second prompt must not overwrite the first, and a manual rename must
    // remain authoritative afterwards.
    supervisor.send("A later prompt must not win", to: id)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.runCount == 2 && !supervisor.isRunning(id) }) else {
        throw fail("the second deterministic prompt did not finish")
    }
    guard supervisor.records[id]?.displayName == "Fix parser" else {
        throw fail("a later prompt clobbered the first prompt name")
    }
    guard supervisor.rename(agentID: id, to: "Human chosen") else {
        throw fail("the manual name did not persist")
    }
    supervisor.send("A third prompt must not reseed", to: id)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.runCount == 3 && !supervisor.isRunning(id) }) else {
        throw fail("the third deterministic prompt did not finish")
    }
    guard supervisor.records[id]?.displayName == "Human chosen",
          supervisor.records[id]?.displayNameSource == .manual else {
        throw fail("a manually renamed agent was reseeded by a later prompt")
    }

    // The forwarded spawn prompt still travels through send, not makeAgent.
    let forwarded = supervisor.spawn(
        role: nil,
        prompt: "Spawned\nworker",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.runCount == 4 && !supervisor.isRunning(forwarded) }) else {
        throw fail("the forwarded first prompt did not finish")
    }
    guard supervisor.records[forwarded]?.displayName == "Spawned worker" else {
        throw fail("the forwarded first prompt did not use the send funnel")
    }
    let identifierPrompt = supervisor.spawn(
        role: "operator",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    supervisor.send(config.model, to: identifierPrompt)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.runCount == 5 && !supervisor.isRunning(identifierPrompt) }),
          supervisor.records[identifierPrompt]?.displayName == AgentRecord.defaultAgentName else {
        throw fail("a prompt equal to a model id produced an identifier-shaped display name")
    }

    // An explicit manual rename to the same sentinel text is still a write: it
    // changes provenance and must disarm the only automatic naming gate.
    let manuallyKeptSentinel = supervisor.spawn(
        role: "operator",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    guard supervisor.rename(agentID: manuallyKeptSentinel, to: AgentRecord.defaultAgentName),
          supervisor.records[manuallyKeptSentinel]?.displayNameSource == .manual,
          try store.load(id: manuallyKeptSentinel)?.displayNameSource == .manual else {
        throw fail("an explicit rename to the unchanged sentinel did not disarm automatic naming")
    }
    supervisor.send("A manual sentinel choice must survive", to: manuallyKeptSentinel)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.runCount == 6 && !supervisor.isRunning(manuallyKeptSentinel) }),
          supervisor.records[manuallyKeptSentinel]?.displayName == AgentRecord.defaultAgentName,
          supervisor.records[manuallyKeptSentinel]?.displayNameSource == .manual else {
        throw fail("a manual sentinel rename was overwritten by the next prompt")
    }

    // B7.0: a slash command must never name the tile. The funnel must stay
    // armed at `.sentinel` through a `/`-prefixed first prompt, so a later
    // ordinary prompt is still free to name it.
    let commandFirst = supervisor.spawn(
        role: "operator", prompt: nil, cwd: cwd,
        model: config.model, thinking: config.thinking
    )
    let beforeCommandRunCount = runner.runCount
    supervisor.send("/compact focus on the auth work", to: commandFirst)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.runCount == beforeCommandRunCount + 1 && !supervisor.isRunning(commandFirst)
    }) else {
        throw fail("the slash-command first prompt did not finish in the deterministic naming runner")
    }
    guard supervisor.records[commandFirst]?.displayName == AgentRecord.defaultAgentName,
          supervisor.records[commandFirst]?.displayNameSource == .sentinel else {
        throw fail("a slash command named the tile: \(String(describing: supervisor.records[commandFirst]?.displayName)), source \(String(describing: supervisor.records[commandFirst]?.displayNameSource))")
    }
    supervisor.send("Actually rename me", to: commandFirst)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.runCount == beforeCommandRunCount + 2 && !supervisor.isRunning(commandFirst)
    }) else {
        throw fail("the ordinary prompt after a slash command did not finish")
    }
    guard supervisor.records[commandFirst]?.displayName == "Actually rename me",
          supervisor.records[commandFirst]?.displayNameSource == .prompt else {
        throw fail("displayNameSource did not stay armed after a slash command, so a later real prompt could not name the tile: \(String(describing: supervisor.records[commandFirst]?.displayName)), source \(String(describing: supervisor.records[commandFirst]?.displayNameSource))")
    }

    // P4.3: the generation marker is durable, and both halves of the CAS are
    // checked on completion. A manual rename during the pending request must
    // survive a late generated result.
    let raceRequest = supervisor.beginNameGeneration(agentID: id)
    guard let raceRequest,
          try store.load(id: id)?.namingRequest == raceRequest,
          supervisor.rename(agentID: id, to: "Human chosen after generation"),
          supervisor.records[id]?.namingRequest == nil,
          !supervisor.applyGeneratedName("late generated title", for: raceRequest, agentID: id),
          supervisor.records[id]?.displayName == "Human chosen after generation" else {
        throw fail("a manual rename during pending generation did not win the completion CAS")
    }

    // A current request can land, but an older request cannot land after it is
    // superseded. The expected-name half is also exercised directly on a record
    // whose title changed without going through the supervisor.
    let generatedID = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    guard let generatedRequest = supervisor.beginNameGeneration(agentID: generatedID),
          generatedRequest.expectedName == AgentRecord.defaultAgentName,
          supervisor.applyGeneratedName("Generated title", for: generatedRequest, agentID: generatedID),
          supervisor.records[generatedID]?.displayName == "Generated title",
          supervisor.records[generatedID]?.displayNameSource == .prompt,
          supervisor.records[generatedID]?.namingRequest == nil else {
        throw fail("a current generated name did not pass the marker CAS and persist")
    }
    let supersededID = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    guard let firstRequest = supervisor.beginNameGeneration(agentID: supersededID),
          let secondRequest = supervisor.beginNameGeneration(agentID: supersededID),
          firstRequest.id != secondRequest.id,
          !supervisor.applyGeneratedName("old result", for: firstRequest, agentID: supersededID),
          supervisor.applyGeneratedName("new result", for: secondRequest, agentID: supersededID) else {
        throw fail("a superseded generated-name request landed after a newer request")
    }
    var directCAS = supervisor.records[generatedID]!
    let directRequest = directCAS.beginNamingRequest()
    directCAS.displayName = "Concurrent human title"
    guard !directCAS.applyGeneratedName("must not clobber", for: directRequest),
          directCAS.displayName == "Concurrent human title",
          directCAS.namingRequest?.id == directRequest.id else {
        throw fail("the generated-name CAS did not reject a changed expected title")
    }
    let persistedCAS = try JSONCodec.makeDecoder().decode(
        AgentRecord.self, from: JSONCodec.makeEncoder().encode(directCAS))
    guard persistedCAS.namingRequest == directRequest,
          persistedCAS.displayName == "Concurrent human title" else {
        throw fail("the in-flight naming marker did not round-trip through AgentRecord persistence")
    }

    // The request boundary is exclusive. Do not silently choose explicit text or
    // regeneration when a caller supplies both.
    let conflictingID = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    guard let beforeConflict = supervisor.records[conflictingID],
          supervisor.requestName(
              agentID: conflictingID, explicitName: "explicit", regenerate: true) == nil,
          supervisor.records[conflictingID] == beforeConflict,
          supervisor.records[conflictingID]?.namingRequest == nil else {
        throw fail("a request carrying both explicit name and regenerate intent was not rejected")
    }

    // P4.4: exercise the actual spawn funnels, not just the resolver. An explicit
    // title beats even an identifier-shaped first prompt, while an ordinary prompt
    // beats its source item.
    let explicitRuns = runner.runCount
    let explicitChild = supervisor.spawn(
        role: "operator",
        prompt: config.model,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        displayName: "Explicit child"
    )
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.runCount > explicitRuns && !supervisor.isRunning(explicitChild)
    }),
          let explicitRecord = supervisor.records[explicitChild],
          explicitRecord.displayName == "Explicit child",
          explicitRecord.displayNameSource == .manual,
          explicitRecord.tileId == nil else {
        throw fail("an explicit headless spawn did not win over its first prompt: \(String(describing: supervisor.records[explicitChild]?.displayName))")
    }

    let promptRuns = runner.runCount
    let promptChild = supervisor.spawn(
        role: "operator",
        prompt: "Prompt child",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        sourceItemId: "QUEUE-PROMPT"
    )
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.runCount > promptRuns && !supervisor.isRunning(promptChild)
    }),
          let promptNamedRecord = supervisor.records[promptChild],
          promptNamedRecord.displayName == "Prompt child",
          promptNamedRecord.displayNameSource == .prompt else {
        throw fail("a first prompt did not beat its source item in the real spawn funnel")
    }

    // A fan-out is the source-item funnel used by the ticket queue. Give it an
    // identifier-shaped prompt so the source rung is forced, and keep it headless
    // while retaining its real role-based provider path.
    let fanOutNaming = supervisor.fanOut(
        items: [AgentSupervisor.FanOutItem(id: "QUEUE-SOURCE-42", prompt: config.model)],
        role: "code-scout",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        isolated: false
    )
    guard fanOutNaming.launched.count == 1,
          let sourceChild = fanOutNaming.launched.first?.agentId,
          await waitUntil(timeout: 5, pollInterval: 0.02, { !supervisor.isRunning(sourceChild) }),
          let sourceRecord = supervisor.records[sourceChild],
          sourceRecord.displayName == "QUEUE-SOURCE-42",
          sourceRecord.displayNameSource == .sourceItem,
          sourceRecord.role == "code-scout",
          sourceRecord.tileId == nil else {
        throw fail("the real headless role-based fan-out did not use its source item after an identifier prompt")
    }

    // A role-based child with no usable prompt falls to a durable parent-relative
    // slot. The parent deliberately remains the sentinel, so the result must still
    // be readable and must not simply copy the parent's title.
    let sentinelParent = supervisor.spawn(
        role: "operator",
        prompt: nil,
        cwd: cwd,
        // Project roles live under `.pi/agents` and may override the model to a
        // provider Pi owns. Keep this witness on that real harness instead of
        // inheriting the machine's ambient default (often Claude Code), which
        // would correctly refuse the role's OpenAI model before naming runs.
        harness: .pi,
        model: config.model,
        thinking: config.thinking
    )
    guard supervisor.records[sentinelParent]?.displayName == AgentRecord.defaultAgentName else {
        throw fail("the ordinal witness parent did not remain on the shared sentinel")
    }
    let roleNamingModel = try RoleRegistry(projectRoot: cwd).resolve(
        roleId: "code-scout",
        inheriting: AgentModelConfig.Resolution(model: config.model, thinking: config.thinking)
    ).model
    guard let roleChild = supervisor.handleSpawnRequest(
        SpawnRequest(role: "code-scout", prompt: roleNamingModel, isolated: false),
        from: sentinelParent
    ),
          await waitUntil(timeout: 5, pollInterval: 0.02, { !supervisor.isRunning(roleChild) }),
          let roleRecord = supervisor.records[roleChild],
          roleRecord.displayName == "New agent agent 1",
          roleRecord.displayNameSource == .parent,
          roleRecord.parentRelativeOrdinal == 1,
          roleRecord.role == "code-scout",
          roleRecord.displayName != supervisor.records[sentinelParent]?.displayName else {
        throw fail("a headless role-based child did not receive the parent-relative ordinal fallback")
    }
    let siblingTwo = supervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: sentinelParent)
    let siblingThree = supervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: sentinelParent)
    let siblingFour = supervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: sentinelParent)
    guard supervisor.records[siblingTwo]?.displayName == "New agent agent 2",
          supervisor.records[siblingThree]?.displayName == "New agent agent 3",
          supervisor.records[siblingFour]?.displayName == "New agent agent 4",
          try store.load(id: sentinelParent)?.nextChildOrdinal == 5 else {
        throw fail("parent-relative child ordinals were not unique and durable: \(String(describing: supervisor.records[siblingTwo]?.displayName)), \(String(describing: supervisor.records[siblingThree]?.displayName)), \(String(describing: supervisor.records[siblingFour]?.displayName))")
    }

    // Delete the second sibling, then restore the parent from disk before creating
    // another child. The learned ordinal must advance to 5, not reuse 2 or count
    // the currently visible siblings.
    guard supervisor.archive(siblingTwo).recordDeleted else {
        throw fail("the sibling deletion witness could not archive the second child")
    }
    let restoredNamingSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    _ = restoredNamingSupervisor.restore()
    let siblingFive = restoredNamingSupervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: sentinelParent)
    guard restoredNamingSupervisor.records[siblingFive]?.displayName == "New agent agent 5",
          restoredNamingSupervisor.records[siblingFive]?.parentRelativeOrdinal == 5,
          restoredNamingSupervisor.records[siblingFive]?.displayNameSource == .parent,
          try store.load(id: sentinelParent)?.nextChildOrdinal == 6 else {
        throw fail("a restored parent reused a deleted sibling ordinal: \(String(describing: restoredNamingSupervisor.records[siblingFive]?.displayName))")
    }

    // Two supervisors restore the same parent BEFORE either allocates. Their
    // stale in-memory counters are the deterministic interleaving that caught
    // the first candidate; allocation must consult the shared durable store and
    // commit the child/counter pair under its store-level lock.
    let interleavedParent = supervisor.spawn(
        role: "operator", prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let firstRestored = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let secondRestored = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    _ = firstRestored.restore()
    _ = secondRestored.restore()
    guard firstRestored.records[interleavedParent] != nil,
          secondRestored.records[interleavedParent] != nil,
          try store.load(id: interleavedParent)?.nextChildOrdinal == 1 else {
        throw fail("the two-supervisor ordinal witness did not begin from one shared durable counter")
    }
    let firstInterleavedChild = firstRestored.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: interleavedParent)
    let secondInterleavedChild = secondRestored.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: interleavedParent)
    let firstOrdinal = firstRestored.records[firstInterleavedChild]?.parentRelativeOrdinal
    let secondOrdinal = secondRestored.records[secondInterleavedChild]?.parentRelativeOrdinal
    let durableInterleavedChildren = try store.loadAll().filter {
        $0.parentAgentID == interleavedParent
    }
    guard firstInterleavedChild != secondInterleavedChild,
          firstOrdinal != nil,
          secondOrdinal != nil,
          Set([firstOrdinal!, secondOrdinal!]) == Set([1, 2]),
          Set(durableInterleavedChildren.compactMap(\.parentRelativeOrdinal)) == Set([1, 2]),
          try store.load(id: interleavedParent)?.nextChildOrdinal == 3 else {
        throw fail("independently restored supervisors duplicated a child ordinal or counter: \(String(describing: firstOrdinal)), \(String(describing: secondOrdinal)), next=\(String(describing: try store.load(id: interleavedParent)?.nextChildOrdinal))")
    }

    // A stale supervisor's ordinary parent mutation must not lower the durable
    // high-water. Delete the only child after that write, then allocate again:
    // without the merge in persist(_:) the new child would visibly reuse label 1.
    let staleWriteParent = supervisor.spawn(
        role: "operator", prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let staleSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let currentSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    _ = staleSupervisor.restore()
    _ = currentSupervisor.restore()
    let staleFirstChild = currentSupervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: staleWriteParent)
    guard currentSupervisor.records[staleFirstChild]?.parentRelativeOrdinal == 1,
          try store.load(id: staleWriteParent)?.nextChildOrdinal == 2,
          staleSupervisor.records[staleWriteParent]?.nextChildOrdinal == 1 else {
        throw fail("the stale-parent witness did not establish distinct in-memory and durable counters")
    }
    guard staleSupervisor.rename(agentID: staleWriteParent, to: "Stale parent write") else {
        throw fail("the stale supervisor could not perform an ordinary parent mutation")
    }
    guard try store.load(id: staleWriteParent)?.nextChildOrdinal == 2 else {
        throw fail("an ordinary stale parent write lowered the durable child high-water")
    }
    guard currentSupervisor.archive(staleFirstChild).recordDeleted else {
        throw fail("the stale-parent witness could not delete the first child")
    }
    let staleRetryChild = staleSupervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: staleWriteParent)
    guard staleSupervisor.records[staleRetryChild]?.parentRelativeOrdinal == 2,
          staleSupervisor.records[staleRetryChild]?.displayName == "Stale parent write agent 2",
          try store.load(id: staleWriteParent)?.nextChildOrdinal == 3 else {
        throw fail("stale parent persistence allowed a deleted child label to be reused: \(String(describing: staleSupervisor.records[staleRetryChild]?.displayName))")
    }

    // A worktree failure happens before the child transaction. It must leave the
    // parent's counter and child set unchanged, rather than reserving a slot for
    // an agent that never existed.
    let failedSpawnParent = supervisor.spawn(
        role: "operator", prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let failedCounter = try store.load(id: failedSpawnParent)?.nextChildOrdinal
    let failedRoot = root.appendingPathComponent("failed-child-not-a-repository", isDirectory: true)
    try FileManager.default.createDirectory(at: failedRoot, withIntermediateDirectories: true)
    var failedSpawnThrew = false
    do {
        _ = try supervisor.spawn(
            role: "code-scout", prompt: nil, cwd: failedRoot, model: config.model,
            thinking: config.thinking, parentAgentID: failedSpawnParent, isolated: true)
    } catch {
        failedSpawnThrew = true
    }
    guard failedSpawnThrew,
          try store.load(id: failedSpawnParent)?.nextChildOrdinal == failedCounter,
          try store.loadAll().allSatisfy({ $0.parentAgentID != failedSpawnParent }) else {
        throw fail("a failed isolated child spawn burned or reused its parent's ordinal")
    }

    // Force the child AtomicWriter write to fail after the shared lock file has
    // been created. The parent counter must remain unchanged and no in-memory
    // child may pretend that a failed durable spawn succeeded.
    let failedWriteRoot = root.appendingPathComponent("failed-child-write", isDirectory: true)
    let failedWriteStore = AgentStore(applicationSupportDirectory: failedWriteRoot)
    let failedWriteSupervisor = AgentSupervisor(
        store: failedWriteStore, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let failedWriteParent = failedWriteSupervisor.spawn(
        role: "operator", prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    guard let failedWriteCounter = try failedWriteStore.load(id: failedWriteParent)?.nextChildOrdinal else {
        throw fail("the failed-child-write witness lost its parent before the write failure")
    }
    let failedWriteDirectory = failedWriteStore.layout.agentsDirectory
    let failedWriteLock = failedWriteDirectory.appendingPathComponent(
        ".child-ordinal-reservation.lock", isDirectory: false)
    guard FileManager.default.createFile(atPath: failedWriteLock.path, contents: Data()) else {
        throw fail("the failed-child-write witness could not create the shared lock file")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: failedWriteDirectory.path)
    let failedWriteChild = failedWriteSupervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: failedWriteParent)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failedWriteDirectory.path)
    guard failedWriteSupervisor.records[failedWriteChild] == nil,
          try failedWriteStore.load(id: failedWriteParent)?.nextChildOrdinal == failedWriteCounter,
          try failedWriteStore.loadAll().allSatisfy({ $0.parentAgentID != failedWriteParent }) else {
        throw fail("a failed child AtomicWriter write burned the parent ordinal or left a phantom child")
    }

    // Deterministic seam for both sides of AtomicWriter's commit boundary. The
    // pre-commit fault never writes the child, so it remains a real failure; the
    // post-commit fault writes it and then throws, so re-reading must promote it
    // into a visible child and persist the parent high-water before returning.
    let preCommitRoot = root.appendingPathComponent("pre-commit-child-write", isDirectory: true)
    let preCommitStore = AgentStore(applicationSupportDirectory: preCommitRoot)
    let preCommitSupervisor = AgentSupervisor(
        store: preCommitStore,
        makeRunner: { _ in ScriptedAgentRunner(script: []) },
        upsertRecord: { record in
            guard record.parentAgentID != nil else {
                try preCommitStore.upsert(record)
                return
            }
            throw AgentSupervisorCheckWriteFault.beforeRename
        })
    let preCommitParent = preCommitSupervisor.spawn(
        role: "operator", prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let preCommitChild = preCommitSupervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: preCommitParent)
    guard preCommitSupervisor.records[preCommitChild] == nil,
          try preCommitStore.load(id: preCommitChild) == nil,
          try preCommitStore.load(id: preCommitParent)?.nextChildOrdinal == 1 else {
        throw fail("a pre-commit child write was reported or persisted as a success")
    }

    let postCommitRoot = root.appendingPathComponent("post-commit-child-write", isDirectory: true)
    let postCommitStore = AgentStore(applicationSupportDirectory: postCommitRoot)
    let postCommitState = AgentSupervisorCheckWriteState()
    let postCommitSupervisor = AgentSupervisor(
        store: postCommitStore,
        makeRunner: { _ in ScriptedAgentRunner(script: []) },
        upsertRecord: { record in
            if record.parentAgentID != nil && !postCommitState.didInjectPostCommitFault {
                try postCommitStore.upsert(record)
                postCommitState.didInjectPostCommitFault = true
                throw AgentSupervisorCheckWriteFault.afterRename
            }
            try postCommitStore.upsert(record)
        })
    let postCommitParent = postCommitSupervisor.spawn(
        role: "operator", prompt: nil, cwd: cwd, model: config.model, thinking: config.thinking)
    let postCommitChild = postCommitSupervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: postCommitParent)
    guard postCommitState.didInjectPostCommitFault,
          let durablePostCommitChild = try postCommitStore.load(id: postCommitChild),
          postCommitSupervisor.records[postCommitChild] == durablePostCommitChild,
          durablePostCommitChild.parentRelativeOrdinal == 1,
          postCommitSupervisor.records[postCommitParent]?.nextChildOrdinal == 2,
          try postCommitStore.load(id: postCommitParent)?.nextChildOrdinal == 2 else {
        throw fail("a post-commit child write was not re-read into a coherent visible success")
    }
    let postCommitRetry = postCommitSupervisor.spawn(
        role: "code-scout", prompt: nil, cwd: cwd, model: config.model,
        thinking: config.thinking, parentAgentID: postCommitParent)
    guard postCommitSupervisor.records[postCommitRetry]?.parentRelativeOrdinal == 2,
          try postCommitStore.load(id: postCommitParent)?.nextChildOrdinal == 3 else {
        throw fail("a durable post-commit child was hidden or its ordinal was burned on retry")
    }

    // Automatic provenance is retained locally but scrubbed before the real
    // companion-shaped inventory is encoded. This covers prompt, source, and the
    // parent fallback; the sentinel substring itself is expected in safe output.
    let namingInventory = AgentInventory.snapshot(
        terminalDescriptors: [], liveStatuses: [:],
        agents: [promptNamedRecord, sourceRecord, roleRecord],
        activityByAgent: [:], replicaId: UUID(), now: Date()
    )
    let namingPayload = String(decoding: try JSONCodec.makeEncoder().encode(namingInventory), as: UTF8.self)
    guard !namingPayload.contains("Prompt child"),
          !namingPayload.contains("QUEUE-SOURCE-42"),
          !namingPayload.contains("New agent agent 1") else {
        throw fail("prompt/source/parent-derived child text crossed the companion boundary")
    }

    // A future provenance value carrying ordinary text must fail closed during
    // record decoding, and the witness must use the actual encoded companion
    // payload rather than a source scan or a hand-written string filter.
    let unknownNameToken = "ordinary-unknown-provenance-\(UUID().uuidString)"
    let unknownSeed = AgentRecord(
        id: AgentID(rawValue: UUID()), displayName: unknownNameToken, displayNameSource: .manual,
        model: config.model, thinking: config.thinking, cwd: cwd.path,
        createdAt: Date(), lastActivityAt: Date())
    guard var unknownObject = try JSONSerialization.jsonObject(
        with: JSONCodec.makeEncoder().encode(unknownSeed)) as? [String: Any] else {
        throw fail("the unknown-provenance fixture did not encode as an AgentRecord object")
    }
    unknownObject["displayNameSource"] = "future-ordinary-provenance"
    let unknownRecordData = try JSONSerialization.data(withJSONObject: unknownObject, options: [.sortedKeys])
    let unknownRecord = try JSONCodec.makeDecoder().decode(AgentRecord.self, from: unknownRecordData)
    guard unknownRecord.displayName == AgentRecord.defaultAgentName,
          unknownRecord.displayNameSource == .sentinel,
          unknownRecord.syncDisplayName == AgentRecord.defaultAgentName else {
        throw fail("unknown display-name provenance was not redacted at decode: \(unknownRecord.displayName), \(unknownRecord.displayNameSource.rawValue)")
    }
    let unknownInventory = AgentInventory.snapshot(
        terminalDescriptors: [], liveStatuses: [:], agents: [unknownRecord],
        activityByAgent: [:], replicaId: UUID(), now: Date())
    let unknownPayload = String(decoding: try JSONCodec.makeEncoder().encode(unknownInventory), as: UTF8.self)
    guard !unknownPayload.contains(unknownNameToken),
          unknownPayload.contains(AgentRecord.defaultAgentName) else {
        throw fail("unknown-provenance text crossed the encoded companion payload")
    }

    // Deterministic edge corpus: empty/whitespace stay displayable through the
    // sentinel; all other cases preserve human text, including marks and RTL.
    let combiningOnly = "\u{301}\u{302}"
    let edgeCases: [(String, String?)] = [
        ("", nil),
        (" \n\t ", nil),
        ("Fix\nparser", "Fix parser"),
        ("Cafe\u{301}", "Cafe\u{301}"),
        (combiningOnly, nil),
        ("\u{202E}שלום עולם\u{202C}", "שלום עולם"),
        ("\u{0001}left\u{0000}right\u{007F}", "leftright"),
    ]
    for (prompt, expected) in edgeCases {
        guard AgentName.fromPrompt(prompt) == expected else {
            throw fail("prompt naming edge case \(prompt.debugDescription) produced \(String(describing: AgentName.fromPrompt(prompt))), expected \(String(describing: expected))")
        }
    }
    let longPrompt = String(repeating: "long words ", count: 20)
    guard let longName = AgentName.fromPrompt(longPrompt),
          longName.count == AgentName.maximumLength,
          longName.hasSuffix(AgentName.ellipsis),
          AgentSupervisor.maximumDisplayNameLength == AgentName.maximumLength else {
        throw fail("prompt naming did not apply one \(AgentName.maximumLength)-character cap with one ellipsis rule")
    }
    guard AgentRecord.defaultAgentName == AgentName.defaultName,
          AgentInboxRow.untitled == AgentName.defaultName else {
        throw fail("the sentinel has divergent record and row definitions")
    }
    let sourceReport = try checkAgentNameSentinelSourceContract(fail: fail)

    // P4.1 migration: old disk records with model, role, and UUID titles are
    // rewritten before they enter the live inventory. A title that is merely a
    // human-cased role name remains a legitimate human name at the row boundary.
    let migrationRoot = root.appendingPathComponent("migration", isDirectory: true)
    let migrationStore = AgentStore(applicationSupportDirectory: migrationRoot)
    let modelID = AgentID(rawValue: UUID())
    let roleID = AgentID(rawValue: UUID())
    let uuidID = AgentID(rawValue: UUID())
    let manualModelID = AgentID(rawValue: UUID())
    let manualRoleID = AgentID(rawValue: UUID())
    let manualSuffixID = AgentID(rawValue: UUID())
    let manualUUIDID = AgentID(rawValue: UUID())
    let manualUUIDName = UUID(uuidString: "D4A10000-0000-4000-8000-000000000004")!.uuidString
    let modelSuffix = config.model.split(separator: "/").last.map(String.init) ?? config.model
    let migrationDate = Date(timeIntervalSinceReferenceDate: 806_700_000)
    let oldRecords = [
        AgentRecord(id: modelID, displayName: config.model, model: config.model, thinking: config.thinking,
                    cwd: cwd.path, createdAt: migrationDate, lastActivityAt: migrationDate),
        AgentRecord(id: roleID, displayName: "operator", role: "operator", model: config.model,
                    thinking: config.thinking, cwd: cwd.path, createdAt: migrationDate.addingTimeInterval(1),
                    lastActivityAt: migrationDate.addingTimeInterval(1)),
        AgentRecord(id: uuidID, displayName: uuidID.rawValue.uuidString, model: config.model,
                    thinking: config.thinking, cwd: cwd.path, createdAt: migrationDate.addingTimeInterval(2),
                    lastActivityAt: migrationDate.addingTimeInterval(2)),
    ]
    // Simulate the actual pre-provenance wire shape: the old records have no
    // displayNameSource key, so decode must classify identifier seeds as automatic
    // rather than inventing `.manual` provenance for them.
    try FileManager.default.createDirectory(
        at: migrationStore.layout.agentsDirectory,
        withIntermediateDirectories: true
    )
    for record in oldRecords {
        guard var object = try JSONSerialization.jsonObject(
            with: JSONCodec.makeEncoder().encode(record)) as? [String: Any] else {
            throw fail("the legacy migration fixture did not encode as an object")
        }
        object.removeValue(forKey: "displayNameSource")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try legacyData.write(to: migrationStore.layout.agentFile(id: record.id))
    }
    let manualRecords = [
        AgentRecord(id: manualModelID, displayName: config.model, displayNameSource: .manual,
                    model: config.model, thinking: config.thinking, cwd: cwd.path,
                    createdAt: migrationDate.addingTimeInterval(3), lastActivityAt: migrationDate.addingTimeInterval(3)),
        AgentRecord(id: manualRoleID, displayName: "operator", displayNameSource: .manual,
                    role: "operator", model: config.model, thinking: config.thinking, cwd: cwd.path,
                    createdAt: migrationDate.addingTimeInterval(4), lastActivityAt: migrationDate.addingTimeInterval(4)),
        AgentRecord(id: manualSuffixID, displayName: modelSuffix, displayNameSource: .manual,
                    model: config.model, thinking: config.thinking, cwd: cwd.path,
                    createdAt: migrationDate.addingTimeInterval(5), lastActivityAt: migrationDate.addingTimeInterval(5)),
        AgentRecord(id: manualUUIDID, displayName: manualUUIDName, displayNameSource: .manual,
                    model: config.model, thinking: config.thinking, cwd: cwd.path,
                    createdAt: migrationDate.addingTimeInterval(6), lastActivityAt: migrationDate.addingTimeInterval(6)),
    ]
    for record in manualRecords { try migrationStore.upsert(record) }
    let migratedSupervisor = AgentSupervisor(store: migrationStore, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    _ = migratedSupervisor.restore()
    for record in oldRecords {
        guard migratedSupervisor.records[record.id]?.displayName == AgentRecord.defaultAgentName,
              migratedSupervisor.records[record.id]?.displayNameSource == .sentinel,
              try migrationStore.load(id: record.id)?.displayName == AgentRecord.defaultAgentName else {
            throw fail("the persisted \(record.displayName) identifier name was not migrated to the sentinel")
        }
    }
    for record in manualRecords {
        guard migratedSupervisor.records[record.id]?.displayName == record.displayName,
              migratedSupervisor.records[record.id]?.displayNameSource == .manual,
              migratedSupervisor.records[record.id]?.humanDisplayName == record.displayName,
              try migrationStore.load(id: record.id)?.displayName == record.displayName else {
            throw fail("a provenance-confirmed manual identifier name was erased during migration: \(record.displayName)")
        }
    }
    let humanRoleRow = AgentInboxRow(
        id: UUID(), title: "Operator", state: .ready, model: config.model, role: "operator", createdAt: migrationDate)
    let modelRow = AgentInboxRow(
        id: UUID(), title: config.model, state: .ready, model: config.model, createdAt: migrationDate)
    let roleRow = AgentInboxRow(
        id: UUID(), title: "operator", state: .ready, model: config.model, role: "operator", createdAt: migrationDate)
    let uuidRow = AgentInboxRow(
        id: UUID(), title: uuidID.rawValue.uuidString, state: .ready, model: config.model, createdAt: migrationDate)
    guard humanRoleRow.displayTitle == "Operator",
          modelRow.displayTitle == AgentRecord.defaultAgentName,
          roleRow.displayTitle == AgentRecord.defaultAgentName,
          uuidRow.displayTitle == AgentRecord.defaultAgentName,
          roleRow.model == config.model && roleRow.role == "operator" else {
        throw fail("identifier-shaped row titles were not defensively projected while metadata stayed available")
    }

    // I5: a prompt-derived local title is replaced before the real inventory
    // snapshot is encoded. This drives the companion-shaped payload, not a source
    // scan or a hand-written string filter.
    let promptToken = "prompt-derived---\(UUID().uuidString)"
    let promptRecord = AgentRecord(
        id: AgentID(rawValue: UUID()), displayName: promptToken, displayNameSource: .prompt,
        model: config.model, thinking: config.thinking, cwd: cwd.path,
        createdAt: migrationDate, lastActivityAt: migrationDate)
    let inventory = AgentInventory.snapshot(
        terminalDescriptors: [], liveStatuses: [:], agents: [promptRecord],
        activityByAgent: [:], replicaId: UUID(), now: migrationDate)
    let encoded = try JSONCodec.makeEncoder().encode(inventory)
    let payload = String(decoding: encoded, as: UTF8.self)
    guard !payload.contains(promptToken), payload.contains(AgentRecord.defaultAgentName) else {
        throw fail("prompt-derived display text crossed the companion payload")
    }

    return "agent naming: sentinel-only spawn, P4.4 explicit→prompt→source→parent ordinal funnels across headless/role-based children with deletion/restore stability, prompt/source/parent I5 scrubbing, first-send seed, repeat/manual no-clobber incl. manual sentinel disarm, P4.3 durable request CAS (manual race, current/superseded completion, expected-name mismatch, round-trip, explicit+regenerate rejection), identifier prompt held at sentinel, edge corpus \(edgeCases.count), \(AgentName.maximumLength)-character cap, model/role/UUID migration with manual provenance, row defensive read, \(sourceReport), and prompt I5 boundary"
}

private struct AgentNameSentinelSourceMatch {
    let path: String
    let line: Int
}

private func checkAgentNameSentinelSourceContract<Failure: Error>(
    fail: (String) -> Failure
) throws -> String {

    // This is a lexical scan, not a grep: comments may explain the sentinel and
    // string contents may contain comment markers. Only executable Swift string
    // literals whose decoded value is the shared sentinel count.
    func matches(in source: String, target: String, path: String) -> [AgentNameSentinelSourceMatch] {
        let scalars = Array(source.unicodeScalars)
        var matches: [AgentNameSentinelSourceMatch] = []
        var index = 0
        var line = 1

        func isNewline(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 10 }
        func isQuote(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 34 }
        func isSlash(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 47 }
        func isStar(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 42 }
        func isHash(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 35 }

        while index < scalars.count {
            let scalar = scalars[index]
            if isNewline(scalar) { line += 1; index += 1; continue }

            // Line and nested block comments are skipped before looking for a
            // quote, so a prose example cannot satisfy the source contract.
            if isSlash(scalar), index + 1 < scalars.count, isSlash(scalars[index + 1]) {
                index += 2
                while index < scalars.count, !isNewline(scalars[index]) { index += 1 }
                continue
            }
            if isSlash(scalar), index + 1 < scalars.count, isStar(scalars[index + 1]) {
                index += 2
                var depth = 1
                while index < scalars.count, depth > 0 {
                    if isNewline(scalars[index]) { line += 1; index += 1; continue }
                    if isSlash(scalars[index]), index + 1 < scalars.count, isStar(scalars[index + 1]) {
                        depth += 1
                        index += 2
                    } else if isStar(scalars[index]), index + 1 < scalars.count, isSlash(scalars[index + 1]) {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                continue
            }

            // Count a regular or raw string. A raw string's hashes are part of
            // its delimiter; its body still contributes one lexical literal.
            var hashCount = 0
            var delimiterIndex = index
            while delimiterIndex < scalars.count, isHash(scalars[delimiterIndex]) {
                hashCount += 1
                delimiterIndex += 1
            }
            guard delimiterIndex < scalars.count, isQuote(scalars[delimiterIndex]) else {
                index += 1
                continue
            }

            let openingQuote = delimiterIndex
            let isMultiline = openingQuote + 2 < scalars.count
                && isQuote(scalars[openingQuote + 1])
                && isQuote(scalars[openingQuote + 2])
            let startLine = line
            index = openingQuote + (isMultiline ? 3 : 1)
            var value = ""
            var escaped = false
            var closed = false
            while index < scalars.count {
                if isNewline(scalars[index]) { line += 1 }

                if isQuote(scalars[index]) {
                    let quoteCount = isMultiline ? 3 : 1
                    if index + quoteCount - 1 < scalars.count,
                       (0..<quoteCount).allSatisfy({ isQuote(scalars[index + $0]) }) {
                        var closingHashIndex = index + quoteCount
                        var closingHashes = 0
                        while closingHashIndex < scalars.count,
                              closingHashes < hashCount,
                              isHash(scalars[closingHashIndex]) {
                            closingHashes += 1
                            closingHashIndex += 1
                        }
                        if closingHashes == hashCount {
                            index = closingHashIndex
                            closed = true
                            break
                        }
                    }
                }

                if hashCount == 0, !isMultiline, scalars[index].value == 92 {
                    // Interpolation and escaped text cannot be the exact plain
                    // sentinel literal. Skip the escaped scalar while retaining
                    // lexical correctness for the following quote.
                    escaped = true
                    index += min(2, scalars.count - index)
                    continue
                }
                value.unicodeScalars.append(scalars[index])
                index += 1
            }
            if closed, !escaped, value == target {
                matches.append(AgentNameSentinelSourceMatch(path: path, line: startLine))
            }
        }
        return matches
    }

    let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources", isDirectory: true)
    let files = (FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )?.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }) ?? []
    guard !files.isEmpty else {
        throw fail("AgentName sentinel source contract: no Swift sources were scanned")
    }

    let rootPrefix = sourceRoot.path + "/"
    var found: [AgentNameSentinelSourceMatch] = []
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        let relativePath = file.path.hasPrefix(rootPrefix)
            ? String(file.path.dropFirst(rootPrefix.count))
            : file.path
        found += matches(in: source, target: AgentRecord.defaultAgentName, path: relativePath)
    }

    guard found.count == 1 else {
        let locations = found.map { "\($0.path):\($0.line)" }.joined(separator: ", ")
        throw fail("AgentName sentinel source contract: expected exactly one executable sentinel literal, found \(found.count): \(locations)")
    }
    guard found[0].path == "ContinuumRevivedAgentUI/AgentInboxRow.swift" else {
        throw fail("AgentName sentinel source contract: canonical literal moved to \(found[0].path):\(found[0].line)")
    }
    return "sentinel source contract: 1 executable literal at \(found[0].path):\(found[0].line), comments excluded"
}

@MainActor
private func checkCapabilityDrivenTurnStates<Failure: Error>(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-turn-state-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let runner = ScriptedAgentRunner(
        script: [
            .turnStarted(threadId: "provider", turnId: "turn-1"),
            .sessionStateChanged(.ready),
        ],
        holdUntilStopped: true
    )
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })
    let id = supervisor.spawn(
        role: nil, prompt: "work", cwd: cwd, model: config.model, thinking: config.thinking
    )
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.runCount == 1 && supervisor.turnSnapshot(for: id)?.state == .ready
    }) else {
        throw fail("turn-state: scripted ready event did not arrive")
    }
    guard supervisor.isRunning(id), supervisor.turnSnapshot(for: id)?.state == .ready else {
        throw fail("turn-state: process alive but explicitly idle did not present Ready")
    }
    guard supervisor.turnSnapshot(for: id)?.capabilities.canSend == false else {
        throw fail("turn-state: occupied send transport advertised acceptance")
    }
    guard supervisor.turnSnapshot(for: id)?.capabilities.canStop == true else {
        throw fail("turn-state: an in-flight alive-but-idle runner lost its Stop — the spawn/drain windows must stay interruptible (P5.5 consolidation)")
    }
    supervisor.qaDeliver(.turnStarted(
        threadId: AgentSupervisor.threadId(for: id), turnId: "turn-2"
    ), to: id)
    guard let working = supervisor.turnSnapshot(for: id),
          working.state == .working, working.capabilities.canStop else {
        throw fail("turn-state: explicit turnStarted did not present stoppable Working")
    }
    guard let originalStart = working.turnStartedAt else {
        throw fail("turn-state: working turn has no elapsed-time origin")
    }
    supervisor.qaDeliver(.turnStarted(
        threadId: AgentSupervisor.threadId(for: id), turnId: "nested-provider-cycle"
    ), to: id, now: originalStart.addingTimeInterval(600))
    guard supervisor.turnSnapshot(for: id)?.turnStartedAt == originalStart else {
        throw fail("turn-state: repeated provider turnStarted reset the 10-minute elapsed clock")
    }
    supervisor.qaDeliver(.turnCompleted(
        threadId: AgentSupervisor.threadId(for: id),
        turnId: "turn-2",
        outcome: .completed,
        errorMessage: nil
    ), to: id)

    // Context-window seam: attach-time seeding reads the supervisor's latest
    // snapshot because the capped replay buffer evicts the rare telemetry event
    // behind a streaming turn. RED before the seam: after the delta flood below,
    // a re-attached tile's replay contained no `.contextWindowUpdated`, so the
    // meter presented "unknown" until the next live report.
    guard supervisor.contextWindowSnapshot(for: id) == nil else {
        throw fail("context-seam: telemetry reported before any was delivered")
    }
    let contextSnapshot = AgentContextWindowSnapshot(
        usedTokens: 42_000,
        maxTokens: 200_000,
        observedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
        source: .piMessageUsage,
        freshness: .live)
    supervisor.qaDeliver(.contextWindowUpdated(
        threadId: AgentSupervisor.threadId(for: id), snapshot: contextSnapshot), to: id)
    guard supervisor.contextWindowSnapshot(for: id) == contextSnapshot else {
        throw fail("context-seam: delivered snapshot is not returned by the seam")
    }
    for index in 0..<(AgentSupervisor.replayCap + 8) {
        supervisor.qaDeliver(.contentDelta(
            threadId: AgentSupervisor.threadId(for: id),
            turnId: "turn-flood",
            streamKind: .assistant,
            delta: "chunk-\(index)"), to: id)
    }
    var floodedReplay: [AgentRuntimeEvent] = []
    for await event in supervisor.events(for: id) {
        floodedReplay.append(event)
        if floodedReplay.count >= AgentSupervisor.replayCap { break }
    }
    let replayStillCarriesTelemetry = floodedReplay.contains { event in
        if case .contextWindowUpdated = event { return true }
        return false
    }
    guard !replayStillCarriesTelemetry else {
        throw fail("context-seam: flood was expected to evict telemetry from the replay buffer (witness precondition)")
    }
    guard supervisor.contextWindowSnapshot(for: id) == contextSnapshot else {
        throw fail("context-seam: snapshot must survive replay-buffer eviction")
    }
    guard supervisor.contextWindowSnapshot(for: AgentID(rawValue: UUID())) == nil else {
        throw fail("context-seam: unknown agent must report nil telemetry")
    }
    // Relaunch path: telemetry rides the persisted record, so a supervisor
    // restored over the same store must still seed the last-known snapshot.
    let resumedSupervisor = AgentSupervisor(
        store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    // …and RESTORED, which is what a relaunch does. Without this the resumed
    // supervisor holds no records at all, `contextWindowSnapshot` short-circuits
    // on the missing record, and the leg has been asserting nil == a snapshot
    // since `24b1b00` gave the seam its record lookup — unnoticed, because this
    // leg halts earlier at the KNOWN-RED naming section.
    resumedSupervisor.restore()
    guard resumedSupervisor.contextWindowSnapshot(for: id) == contextSnapshot else {
        throw fail("context-seam: a restored supervisor must seed persisted telemetry from the record")
    }

    supervisor.qaDeliver(.requestOpened(
        threadId: AgentSupervisor.threadId(for: id),
        requestId: "request-1",
        kind: .commandExecutionApproval
    ), to: id)
    guard let requestSnapshot = supervisor.turnSnapshot(for: id),
          case let .needsAction(request) = requestSnapshot.state,
          request.requestID == "request-1",
          request.prompt.contains("command"),
          request.responseMode == .fixedChoice([
              ApprovalDecision.accept.rawValue,
              ApprovalDecision.acceptForSession.rawValue,
              ApprovalDecision.decline.rawValue,
              ApprovalDecision.cancel.rawValue,
          ]) else {
        throw fail("turn-state: Needs action did not retain matching provider request context and choices")
    }
    let needsPresentation = AgentTileStatePresenter.present(
        name: "Checker",
        snapshot: requestSnapshot,
        branchContext: nil,
        startedAt: Date(timeIntervalSince1970: 1),
        now: Date(timeIntervalSince1970: 3)
    )
    guard needsPresentation.revealRequestID == "request-1",
          needsPresentation.availableActionDescription == "Reveal provider request",
          needsPresentation.stateAccessibilityLabel.contains("accept") else {
        throw fail("turn-state: Needs action presentation cannot reveal its real request and choices")
    }

    supervisor.qaDeliver(.requestResolved(
        threadId: AgentSupervisor.threadId(for: id), requestId: "request-1", decision: "accept"
    ), to: id)
    guard supervisor.turnSnapshot(for: id)?.state == .ready else {
        throw fail("turn-state: resolved request did not restore explicit Ready")
    }
    supervisor.qaDeliver(.runtimeError(
        threadId: AgentSupervisor.threadId(for: id), message: "provider failed"
    ), to: id)
    guard supervisor.turnSnapshot(for: id)?.state == .failed(message: "provider failed") else {
        throw fail("turn-state: runtime error did not present Failed")
    }

    // Required negative semantics: a user-input event with no response-mode
    // capability must remain fixed-choice([]). Treating empty choices as freeform
    // would make this named assertion red.
    supervisor.qaDeliver(.userInputRequested(
        threadId: AgentSupervisor.threadId(for: id),
        requestId: "question-1",
        questions: [.init(key: "answer", prompt: "Explain")]
    ), to: id)
    guard let inputSnapshot = supervisor.turnSnapshot(for: id),
          case let .needsAction(inputRequest) = inputSnapshot.state,
          inputRequest.responseMode == .fixedChoice([]) else {
        throw fail("turn-state negative witness: empty choices fabricated a freeform response capability")
    }

    guard await supervisor.accept(.queue(AgentPrompt("not supported")), for: id) == .refused(.unsupported) else {
        throw fail("turn-state: conservative runtime accepted a fabricated queue intent")
    }
    let draftBeforeRefusal = "keep this draft"
    guard await supervisor.accept(.send(draftBeforeRefusal), for: id) == .refused(.turnNotReady) else {
        throw fail("turn-state: send while Needs action was not refused")
    }

    // Exercise the real composer acceptance boundary: refusal keeps the exact
    // edited draft; acceptance clears it only after the sink reports success.
    let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
    composer.apply(.init(
        text: draftBeforeRefusal,
        selection: NSRange(location: (draftBeforeRefusal as NSString).length, length: 0),
        revision: 7
    ))
    let refusingSink = ScriptedTileActionSink(.refused(.turnNotReady))
    composer.bindActionSink(
        refusingSink,
        agentID: id,
        snapshot: .init(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil
        )
    )
    composer.composerRequestedSend(composer.textView)
    guard await waitUntil(timeout: 1, pollInterval: 0.01, { refusingSink.intents.count == 1 }),
          composer.textView.string == draftBeforeRefusal else {
        throw fail("turn-state: refused composer send cleared or changed its draft")
    }
    // The dealloc-mid-submit latch (P5.5 correction, defect 3): the composer
    // holds its sink weakly, so a submit whose sink dies before the action task
    // runs resolves a nil acceptance — that exit must still release the
    // single-flight latch, or no sink bound afterwards can ever dispatch.
    var dyingSink: ScriptedTileActionSink? = ScriptedTileActionSink(.accepted)
    composer.bindActionSink(
        dyingSink!,
        agentID: id,
        snapshot: .init(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil
        )
    )
    composer.composerRequestedSend(composer.textView)
    dyingSink = nil
    let acceptingSink = ScriptedTileActionSink(.accepted)
    composer.bindActionSink(
        acceptingSink,
        agentID: id,
        snapshot: .init(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil
        )
    )
    composer.composerRequestedSend(composer.textView)
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        acceptingSink.intents.count == 1 && composer.textView.string.isEmpty
    }) else {
        throw fail("turn-state: a submit whose sink deallocated latched the composer — the sink bound after it never dispatched (dispatches \(acceptingSink.intents.count))")
    }

    supervisor.qaDeliver(.turnStarted(
        threadId: AgentSupervisor.threadId(for: id), turnId: "turn-stop"
    ), to: id)
    guard await supervisor.accept(.stop, for: id) == .accepted else {
        throw fail("turn-state: stoppable turn was refused by the shared action sink")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.completedRuns == 1 }) else {
        throw fail("turn-state: accepted stop did not release runner")
    }
    guard await supervisor.accept(.stop, for: id) == .refused(.noTurnInProgress) else {
        throw fail("turn-state: stop without a turn was reported accepted")
    }

    // Restored is a durable supervisor fact, not inferred from a blank view.
    let restoredRecord = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: "Restored",
        role: nil,
        model: config.model,
        thinking: config.thinking,
        cwd: cwd.path,
        worktreeBranch: nil,
        projectId: nil,
        parentAgentID: nil,
        sourceItemId: nil,
        createdAt: Date(),
        lastActivityAt: Date(),
        tileId: nil
    )
    try store.upsert(restoredRecord)
    let restoredSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    _ = restoredSupervisor.restore()
    guard let restored = restoredSupervisor.turnSnapshot(for: restoredRecord.id),
          restored.state == .restored,
          restored.capabilities.canSend else {
        throw fail("turn-state: restored idle agent did not present Restored with Send available")
    }

    // Presentation exhausts the states that have no current transport producer too:
    // missing queue capability means unavailable, not omission from the vocabulary.
    let queued = AgentTileStatePresenter.present(
        name: "Checker",
        snapshot: .init(state: .queued, capabilities: .sendStop(canSend: false, canStop: false), turnStartedAt: nil),
        branchContext: nil,
        startedAt: Date(timeIntervalSince1970: 1),
        now: Date(timeIntervalSince1970: 2)
    )
    let restoredPresentation = AgentTileStatePresenter.present(
        name: "Checker", snapshot: restored, branchContext: nil, startedAt: nil
    )
    // P3.5 moved these two existing expectations with the shared vocabulary:
    // queued is the live Working word and restored is the live Idle word. Keep
    // the action/accessibility checks beside the migrated labels so the test
    // still proves the real presenter did not drop the reason for either fold.
    guard queued.stateLabel == "Working",
          queued.status == .working,
          queued.stateAccessibilityLabel.contains("No immediate"),
          restoredPresentation.stateLabel == "Idle",
          restoredPresentation.status == .idle,
          restoredPresentation.availableActionDescription == "Send a prompt to continue" else {
        throw fail("turn-state: queued/restored presentation omitted truthful action accessibility")
    }

    return "capability turn states: process-alive Ready, explicit Working, request reveal with fixed choices, Failed, Restored/Queued presentation, accepted Stop, refused queue/send/stop, and empty-choice negative witness held"
}

@MainActor
private func checkAgentBlockRendererRegistry<Failure: Error>(
    fail: (String) -> Failure
) throws -> String {
    let registry = AgentBlockRendererRegistry.production
    guard registry.isFrozen else {
        throw fail("production block renderer registry is not frozen after bootstrap")
    }
    // 21, not 16: `ddbf83d` (Render semantic transcript images) added `.image`
    // and `.imageGallery` to the fixture and did not move the number with them,
    // `882316d0` later added `.fileReferences`, the semantic subagent work added
    // `.agentReference`, and `.plans/45` T8 added `.table` — GFM tables used to
    // be flattened into `.fencedCode` at parse time. Both halves are pinned — the
    // exact roster size, and that no kind is listed twice, which a bare count
    // cannot tell apart from a missing one.
    guard AgentBlockRendererRegistry.builtInKinds.count == 21,
          Set(AgentBlockRendererRegistry.builtInKinds).count
            == AgentBlockRendererRegistry.builtInKinds.count else {
        throw fail("block renderer built-in fixture is incomplete or duplicated: \(AgentBlockRendererRegistry.builtInKinds.map(\.rawValue))")
    }

    var identities = Set<ObjectIdentifier>()
    for kind in AgentBlockRendererRegistry.builtInKinds {
        guard registry.registrationCount(for: kind) == 1 else {
            throw fail("block kind '\(kind.rawValue)' did not resolve exactly once")
        }
        identities.insert(ObjectIdentifier(try registry.renderer(for: kind)))
    }
    // Fifteen bootstrap renderers plus the one fallback. This catches an
    // accidental many-kinds-to-one registration shortcut as well as omissions.
    guard identities.count == AgentBlockRendererRegistry.builtInKinds.count else {
        throw fail("built-in block kinds resolved to \(identities.count) renderer instances, expected 16")
    }

    let futureKind = AgentBlockKind(rawValue: "provider.future-card.v3")!
    let unknown = try registry.renderer(for: .unknown)
    guard ObjectIdentifier(try registry.renderer(for: futureKind)) == ObjectIdentifier(unknown) else {
        throw fail("an unregistered provider kind did not resolve to the mandatory unknown fallback")
    }

    // Malformed bootstraps must hit their named errors. The ownership witness is
    // important: dictionary registration may not override the renderer's own
    // declaration, nor reuse that renderer for another semantic family.
    let duplicate = AgentBlockRendererRegistry()
    try duplicate.register(
        AgentDeferredBlockRenderer(kind: .paragraph, safeLabel: "first"),
        for: .paragraph
    )
    do {
        try duplicate.register(
            AgentDeferredBlockRenderer(kind: .paragraph, safeLabel: "second"),
            for: .paragraph
        )
        throw fail("duplicate-registration witness did not fail")
    } catch let error as AgentBlockRendererRegistryError {
        guard error == .duplicateKind(.paragraph) else {
            throw fail("duplicate-registration witness failed with unnamed error: \(error)")
        }
    }

    let mismatched = AgentBlockRendererRegistry()
    let paragraphRenderer = AgentDeferredBlockRenderer(kind: .paragraph, safeLabel: "paragraph")
    do {
        try mismatched.register(paragraphRenderer, for: .heading)
        throw fail("renderer-ownership witness did not fail")
    } catch let error as AgentBlockRendererRegistryError {
        guard error == .mismatchedKind(expected: .heading, declared: .paragraph) else {
            throw fail("renderer-ownership witness failed with unnamed error: \(error)")
        }
    }

    let missingFallback = AgentBlockRendererRegistry()
    do {
        try missingFallback.freeze()
        throw fail("missing-fallback witness did not fail")
    } catch let error as AgentBlockRendererRegistryError {
        guard error == .missingFallback else {
            throw fail("missing-fallback witness failed with unnamed error: \(error)")
        }
    }

    do {
        try registry.register(
            AgentDeferredBlockRenderer(kind: futureKind, safeLabel: "late"),
            for: futureKind
        )
        throw fail("frozen-registry witness did not fail")
    } catch let error as AgentBlockRendererRegistryError {
        guard error == .registryFrozen else {
            throw fail("frozen-registry witness failed with wrong error: \(error)")
        }
    }

    let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/ContinuumRevived/Canvas")
    let switchScanPaths = [
        sourceRoot.appendingPathComponent("AgentTranscript"),
        sourceRoot.appendingPathComponent("ManagedAgentTileNSView.swift")
    ]
    var scanned = 0
    for path in switchScanPaths {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else { continue }
        let files: [URL]
        if isDirectory.boolValue {
            files = (FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }) ?? []
        } else {
            files = [path]
        }
        for file in files {
            scanned += 1
            let source = try String(contentsOf: file, encoding: .utf8)
            let blockKindSwitch = source.range(
                of: #"switch\s+block\s*\.\s*kind"#,
                options: .regularExpression
            ) != nil
            guard !blockKindSwitch else {
                throw fail("\(file.lastPathComponent) switches on AgentBlockKind instead of resolving through the registry")
            }
        }
    }
    guard scanned >= 3 else {
        throw fail("renderer kind-switch source check scanned only \(scanned) files")
    }

    return "renderer registry: 16 unique built-ins, ownership/duplicate/missing/frozen witnesses named, unknown fallback shared, \(scanned) tile/transcript sources free of block-kind switches"
}

/// Gated on `--agent-restore-check` (P2A.7).
///
/// The records are written straight to an `AgentStore` in a temp root — nothing in
/// this process ever held them — so `restore()` is observed adopting state it did not
/// create, which is exactly what a relaunch is. The provider is a
/// `ScriptedAgentRunner` behind `ScriptedRunnerQueue`, so "no agent auto-started"
/// is asserted as ZERO RUNNERS EVER CONSTRUCTED rather than as a nil dictionary
/// entry.
///
/// What stays a source scan, and why: the two production sites are the boot walk in
/// `startWorkspace` and `wireManagedAgentTile`, both `AppDelegate` methods over a
/// live canvas, window and workspace runtime — the same reason
/// `managedAgentCloseBranchSource` and `paletteAgentSpawnBranch` are scans. The
/// ORDERING is the load-bearing half there (restore must precede the tile walk, or
/// the walk spawns a fresh agent over a surviving record), so it is asserted as a
/// line ordering, not read off the diff.
@MainActor
func runAgentRestoreChecks() async throws {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-restore-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let config = AgentModelConfig.resolvedFromDefaults()
    let liveCwd = FileManager.default.currentDirectoryPath
    // Never created, so the stale-record branch is about a genuinely missing
    // directory and not about permissions.
    let missingCwd = root.appendingPathComponent("gone-project-root", isDirectory: true).path

    // MARK: 1 · the previous launch's records, written by nothing in this process

    let createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let tileId = UUID()
    let projectId = UUID()
    let tiled = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: "Human reviewer",
        role: "reviewer",
        model: config.model,
        thinking: config.thinking,
        cwd: liveCwd,
        projectId: projectId,
        createdAt: createdAt,
        lastActivityAt: createdAt.addingTimeInterval(30),
        tileId: tileId
    )
    let headless = AgentRecord(
        id: AgentID(rawValue: UUID()),
        // P4.1: this fixture represents the pre-provenance automatic model seed;
        // explicit `.sentinel` provenance lets the migration check stay honest
        // without misclassifying a confirmed manual model-shaped name.
        displayName: config.model,
        displayNameSource: .sentinel,
        model: config.model,
        thinking: config.thinking,
        cwd: liveCwd,
        createdAt: createdAt.addingTimeInterval(1),
        lastActivityAt: createdAt.addingTimeInterval(2)
    )
    let orphaned = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: "orphan",
        model: config.model,
        thinking: config.thinking,
        cwd: missingCwd,
        createdAt: createdAt.addingTimeInterval(3),
        lastActivityAt: createdAt.addingTimeInterval(4),
        tileId: UUID()
    )
    let legacyContext = AgentContextWindowSnapshot(
        usedTokens: 4_160_000,
        maxTokens: 272_000,
        inputTokens: 4_160_000,
        outputTokens: 8_000,
        totalProcessedTokens: 4_168_000,
        observedAt: createdAt,
        source: .codexTurnUsage,
        freshness: .live)
    let codexExact = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: "Codex exact repair",
        model: "openai-codex/gpt-5.6-sol",
        thinking: "high",
        cwd: liveCwd,
        createdAt: createdAt,
        lastActivityAt: createdAt,
        lastContextWindow: legacyContext,
        codexThreadId: "exact-thread")
    let codexSanitized = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: "Codex sanitize repair",
        model: "openai-codex/gpt-5.6-sol",
        thinking: "high",
        cwd: liveCwd,
        createdAt: createdAt,
        lastActivityAt: createdAt,
        lastContextWindow: legacyContext,
        codexThreadId: "missing-thread")
    for record in [tiled, headless, orphaned, codexExact, codexSanitized] { try store.upsert(record) }

    let repairedExactSnapshot = AgentContextWindowSnapshot(
        usedTokens: 217_800,
        maxTokens: 258_400,
        inputTokens: 215_000,
        outputTokens: 2_800,
        totalProcessedTokens: 217_800,
        observedAt: createdAt.addingTimeInterval(10),
        source: .codexRolloutTokenCount,
        freshness: .live)

    let turn: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .contentDelta(threadId: "provider-thread", turnId: "t1", streamKind: .assistant, delta: "resumed"),
        .turnCompleted(threadId: "provider-thread", turnId: "t1", outcome: .completed, errorMessage: nil)
    ]
    let queue = ScriptedRunnerQueue([ScriptedAgentRunner(script: turn)])
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { queue.next($0.record) },
        codexRestoredContextSnapshot: { record in
            record.id == codexExact.id ? repairedExactSnapshot : nil
        })
    // Vacuity guard: if a supervisor adopted the store at init, everything below
    // would pass while saying nothing about `restore()`.
    guard supervisor.records.isEmpty else {
        throw fail("a fresh supervisor already holds \(supervisor.records.count) record(s), so restore() is not what adopts them")
    }

    // MARK: 2 · restore adopts the live records and MARKS the stale one

    let report = supervisor.restore()
    guard report.restored.count == 4,
          Set(report.restored) == Set([tiled.id, headless.id, codexExact.id, codexSanitized.id]) else {
        throw fail("restore adopted \(report.restored.map { $0.rawValue.uuidString }), expected the tiled, headless, and two Codex repair agents")
    }
    guard report.stale == [orphaned.id] else {
        throw fail("restore did not skip the agent whose project root is gone: stale \(report.stale.map { $0.rawValue.uuidString })")
    }
    guard report.skipped.isEmpty else {
        throw fail("restore skipped \(report.skipped.count) record(s) as already-live on a supervisor that held none")
    }
    guard supervisor.records[orphaned.id] == nil, supervisor.staleIDs.contains(orphaned.id) else {
        throw fail("the stale agent was adopted rather than marked and skipped")
    }
    // Marked, not destroyed: the directory may be a worktree that comes back.
    guard try store.load(id: orphaned.id) != nil else {
        throw fail("restore deleted the stale agent's record; skipping is not removing")
    }

    // Identity, model and role come back intact — the point of restoring at all.
    guard let restoredTiled = supervisor.records[tiled.id] else {
        throw fail("the tiled agent is not in supervisor.records after restore")
    }
    guard restoredTiled.displayName == "Human reviewer",
          restoredTiled.role == "reviewer",
          restoredTiled.model == config.model,
          restoredTiled.thinking == config.thinking,
          restoredTiled.cwd == liveCwd,
          restoredTiled.projectId == projectId,
          restoredTiled.createdAt == createdAt,
          restoredTiled.tileId == tileId else {
        throw fail("the restored record lost its identity: \(restoredTiled)")
    }
    guard supervisor.records[headless.id]?.tileId == nil else {
        throw fail("the headless agent came back with a tile binding: \(String(describing: supervisor.records[headless.id]?.tileId))")
    }
    guard supervisor.records[headless.id]?.displayName == AgentRecord.defaultAgentName,
          supervisor.records[headless.id]?.displayNameSource == .sentinel,
          try store.load(id: headless.id)?.displayName == AgentRecord.defaultAgentName else {
        throw fail("restore did not migrate the persisted model id to the shared sentinel")
    }
    var expectedExact = repairedExactSnapshot
    expectedExact.freshness = .stale
    guard supervisor.records[codexExact.id]?.lastContextWindow == expectedExact,
          try store.load(id: codexExact.id)?.lastContextWindow == expectedExact else {
        throw fail("restore did not replace legacy Codex occupancy with the exact stale rollout snapshot")
    }
    guard let sanitized = supervisor.records[codexSanitized.id]?.lastContextWindow,
          sanitized.source == .codexTurnUsage,
          sanitized.usedTokens == nil,
          sanitized.maxTokens == nil,
          sanitized.inputTokens == legacyContext.inputTokens,
          try store.load(id: codexSanitized.id)?.lastContextWindow == sanitized else {
        throw fail("restore did not sanitize legacy Codex used/max while preserving accounting")
    }
    // The conversation is continuable because the Pi session id is derived from the
    // agent id, which is what survived. Asserted, since "history is not lost"
    // depends on it entirely.
    guard AgentSupervisor.sessionId(for: tiled.id) == "array-agent-\(tiled.id.rawValue.uuidString)" else {
        throw fail("the restored agent's Pi session id is not derived from its id: \(AgentSupervisor.sessionId(for: tiled.id))")
    }
    // B7.1 — the pure seed functions above must still hold for a FRESH agent
    // (this is the cheap way that ticket goes wrong: a resolver that shadows
    // the seed for every agent, not just one that has adopted a real id).
    // `tiled.providerSessionId` is nil, so both the claude and pi runner
    // configs must still derive from the agent id exactly as before.
    guard let tiledRecord = supervisor.records[tiled.id], tiledRecord.providerSessionId == nil else {
        throw fail("fixture setup drifted: the restored fresh agent already carries a providerSessionId")
    }
    guard AgentSupervisor.claudeRunnerConfig(for: tiledRecord).sessionId
            == AgentSupervisor.claudeSessionId(for: tiled.id),
          AgentSupervisor.runnerConfig(for: tiledRecord, spawnDepth: 0).sessionId
            == AgentSupervisor.sessionId(for: tiled.id) else {
        throw fail("a fresh agent's runner configs must still use the derived seed, not a nil providerSessionId")
    }
    // And once claude has reported its own id (captured via the
    // `.providerSessionId` runtime observation, `--fork-session`'s case),
    // the claude runner config must adopt it instead of re-deriving.
    var adopted = tiledRecord
    adopted.providerSessionId = "claude-forked-session-id"
    guard AgentSupervisor.claudeRunnerConfig(for: adopted).sessionId == "claude-forked-session-id" else {
        throw fail("the claude runner config did not adopt a stored providerSessionId over the derived seed")
    }
    // THE REASON THE BOOT WALK NEEDS THIS: the tile finds its own agent instead of
    // spawning a second one over the top of a surviving record.
    guard supervisor.agent(forTile: tileId) == tiled.id else {
        throw fail("a restored tile does not resolve to its agent, so wiring it would spawn a duplicate")
    }

    // MARK: 3 · nothing auto-started

    guard queue.handedOut.isEmpty else {
        throw fail("restore constructed \(queue.handedOut.count) runner(s) — a relaunched agent must be idle until prompted")
    }
    for (label, id) in [
        ("tiled", tiled.id),
        ("headless", headless.id),
        ("Codex exact", codexExact.id),
        ("Codex sanitized", codexSanitized.id),
    ] {
        guard supervisor.isRunning(id) == false else {
            throw fail("the restored \(label) agent has a live runner")
        }
    }

    // MARK: 4 · the tiled one gets a view, and it says where it stands

    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    tile.attach(agentID: tiled.id, supervisor: supervisor)
    guard tile.attachedAgentID == tiled.id else {
        throw fail("the restored agent's tile is not attached to it: \(String(describing: tile.attachedAgentID))")
    }
    guard supervisor.wasRestored(tiled.id) else {
        throw fail("the restored agent does not report as restored, so the tile cannot know to place the notice")
    }
    // The replay is empty by construction — the supervisor's history buffer is
    // in-memory and this process never ran a turn for this agent — which is exactly
    // why the notice exists. Asserted so "the placeholder stands in for a transcript
    // that is genuinely absent" is a measurement rather than a claim.
    guard tile.ingestedEvents.isEmpty, tile.transcriptCardCount == 0 else {
        throw fail("a restored agent replayed \(tile.ingestedEvents.count) event(s) into \(tile.transcriptCardCount) card(s); the notice would be covering for nothing")
    }
    guard supervisor.needsPreviousSessionNotice(tiled.id) else {
        throw fail("a restored agent with no history does not ask for the previous-session notice")
    }
    // The status a fresh tile starts at, and the one it must NOT keep for a restored
    // agent: `configuring` reads as "still starting up" for something that is simply
    // idle. The pre-assertion is the vacuity guard for the post-assertion below.
    guard tile.currentAgentStatus == .configuring else {
        throw fail("a just-built tile is \(tile.currentAgentStatus), so the status assertion below proves nothing")
    }
    tile.showPreviousSessionNotice()
    guard tile.currentAgentStatus == .idle else {
        throw fail("a restored agent's tile shows \(tile.currentAgentStatus) — a relaunched agent is idle until it is prompted")
    }
    guard tile.qaTranscriptText.contains(ManagedAgentTileNSView.previousSessionNoticeText) else {
        throw fail("the previous-session notice did not reach the transcript: \(tile.qaTranscriptText)")
    }
    guard tile.qaRenderedCardCount == tile.transcriptCardCount, tile.transcriptCardCount == 1 else {
        throw fail("the notice rendered \(tile.qaRenderedCardCount) view(s) for \(tile.transcriptCardCount) card(s)")
    }
    // Re-wiring the same tile happens (three call sites), so the notice must not stack.
    tile.showPreviousSessionNotice()
    guard tile.transcriptCardCount == 1 else {
        throw fail("a second notice stacked up: \(tile.transcriptCardCount) cards")
    }
    // Vacuity guard on `wasRestored`: an agent spawned in THIS session must not get
    // the notice, or every tile would carry it.
    let freshId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: URL(fileURLWithPath: liveCwd, isDirectory: true),
        model: config.model,
        thinking: config.thinking
    )
    guard supervisor.wasRestored(freshId) == false else {
        throw fail("an agent spawned in this session reports as restored")
    }

    // MARK: 4b · a restored agent with a provider session file rehydrates its
    // prior transcript — DISPLAY-ONLY, never re-published to the sync timeline.
    //
    // Isolated supervisor/store so the restore accounting in sections 5–8 stays
    // undisturbed. The claude and pi session files are written into a temp $HOME
    // the readers are pointed at; the agents' cwd is the live dir so restore()
    // adopts them (its only filesystem precondition).
    do {
        let rehydrateHome = root.appendingPathComponent("rehydrate-home", isDirectory: true)
        let rehydrateStore = AgentStore(
            applicationSupportDirectory: root.appendingPathComponent("rehydrate-store", isDirectory: true))
        let rehydrateSupervisor = AgentSupervisor(
            store: rehydrateStore, makeRunner: { _ in ScriptedAgentRunner(script: []) })

        let claudeAgent = AgentID(rawValue: UUID())
        let piAgent = AgentID(rawValue: UUID())
        let codexAgent = AgentID(rawValue: UUID())
        let codexThreadId = "019c0dex-restore-check"
        for id in [claudeAgent, piAgent] {
            try rehydrateStore.upsert(AgentRecord(
                id: id, displayName: "restored", harness: id == claudeAgent ? .claudeCode : .pi, model: config.model, thinking: config.thinking,
                cwd: liveCwd, createdAt: createdAt, lastActivityAt: createdAt, tileId: UUID()))
        }
        try rehydrateStore.upsert(AgentRecord(
            id: codexAgent, displayName: "restored codex", harness: .codex, model: "openai-codex/gpt-5.6-sol",
            thinking: config.thinking, cwd: liveCwd, createdAt: createdAt,
            lastActivityAt: createdAt, tileId: UUID(), codexThreadId: codexThreadId))
        _ = rehydrateSupervisor.restore()

        // The derived session ids the readers locate by MUST equal the
        // supervisor's own derivation, or a real relaunch would look in the
        // wrong file. Asserted so the two definitions cannot drift.
        guard ManagedTranscriptRehydrator.claudeSessionId(forAgentUUID: claudeAgent.rawValue)
                == AgentSupervisor.claudeSessionId(for: claudeAgent),
              ManagedTranscriptRehydrator.piSessionId(forAgentUUID: piAgent.rawValue)
                == AgentSupervisor.sessionId(for: piAgent) else {
            throw fail("the rehydrator's session-id derivation drifted from AgentSupervisor's")
        }

        // A tile wired to record whatever it would mirror onto the syncable
        // activity timeline — exactly ContinuumApp.recordManagedActivity's fold.
        // Rehydration must leave it EMPTY: that is the display-only I5 guard.
        func attachRecordingTile(_ agentID: AgentID) -> (tile: ManagedAgentTileNSView, drafts: () -> [AgentActivityEventDraft]) {
            final class DraftBox { var drafts: [AgentActivityEventDraft] = [] }
            let box = DraftBox()
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "agent",
                frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            tile.onIngestedEvent = { event in
                if let draft = ManagedAgentActivityBridge.draft(
                    for: event, agentId: agentID.rawValue, tileId: nil, status: .idle, now: createdAt) {
                    box.drafts.append(draft)
                }
            }
            tile.attach(agentID: agentID, supervisor: rehydrateSupervisor)
            return (tile, { box.drafts })
        }

        func assertDisplayOnly(_ transcript: RehydratedTranscript, drafts: [AgentActivityEventDraft], _ label: String) throws {
            // Vacuity guard: these very events WOULD have produced activity
            // drafts had they flowed through the mirror, so "zero drafts" is a
            // measurement of the bypass, not of an empty bridge.
            let wouldDraft = transcript.events.filter {
                ManagedAgentActivityBridge.draft(
                    for: $0, agentId: UUID(), tileId: nil, status: .idle, now: createdAt) != nil
            }.count
            guard wouldDraft > 0 else {
                throw fail("\(label): rehydrated transcript has no activity-bridge-visible events, so the I5 assertion is vacuous")
            }
            guard drafts.isEmpty else {
                throw fail("\(label): rehydration published \(drafts.count) draft(s) to the syncable activity timeline — the display-only I5 guard is violated")
            }
        }

        // -- claude path --
        let claudeURL = ClaudeSessionTranscriptReader.sessionFileURL(
            homeURL: rehydrateHome, cwd: liveCwd,
            sessionId: AgentSupervisor.claudeSessionId(for: claudeAgent))
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try [
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"CLAUDE_PLANTED_PROMPT"}}"#,
            #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"CLAUDE_PLANTED_REPLY"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","is_error":false,"content":"out"}]}}"#,
        ].joined(separator: "\n").write(to: claudeURL, atomically: true, encoding: .utf8)

        let claudeInputs = ManagedTranscriptRehydrator.Inputs(
            agentUUID: claudeAgent.rawValue, cwd: liveCwd, model: "anthropic/opus", harness: .claudeCode,
            claudeCLIAvailable: true, homeURL: rehydrateHome)
        guard let claudeTranscript = ManagedTranscriptRehydrator.rehydrate(claudeInputs) else {
            throw fail("a restored claude agent with a session file did not rehydrate")
        }
        guard rehydrateSupervisor.needsPreviousSessionNotice(claudeAgent) else {
            throw fail("a restored agent should want the previous-session notice before rehydration seeds it")
        }
        rehydrateSupervisor.seedRehydratedTranscript(claudeTranscript, for: claudeAgent)
        guard rehydrateSupervisor.needsPreviousSessionNotice(claudeAgent) == false else {
            throw fail("seeding a rehydrated transcript did not retire the previous-session notice")
        }
        let (claudeTile, claudeDrafts) = attachRecordingTile(claudeAgent)
        guard claudeTile.qaTranscriptText.contains("CLAUDE_PLANTED_PROMPT"),
              claudeTile.qaTranscriptText.contains("CLAUDE_PLANTED_REPLY") else {
            throw fail("rehydrated claude transcript did not reach the tile cards: \(claudeTile.qaTranscriptText)")
        }
        guard claudeTile.qaTranscriptText.contains("Previous session") else {
            throw fail("rehydrated claude transcript is not led by the previous-session boundary card")
        }
        guard claudeTile.transcriptCardCount > 1 else {
            throw fail("rehydration produced \(claudeTile.transcriptCardCount) card(s); the restored history is missing")
        }
        guard claudeTile.currentAgentStatus == .idle else {
            throw fail("a rehydrated agent's tile shows \(claudeTile.currentAgentStatus) — a relaunched agent is idle until prompted")
        }
        try assertDisplayOnly(claudeTranscript, drafts: claudeDrafts(), "claude")
        claudeTile.detach()

        // -- pi path -- (no claude file for this agent, non-anthropic model)
        let piDir = rehydrateHome
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
            .appendingPathComponent(PiSessionTranscriptReader.slug(forCwd: liveCwd), isDirectory: true)
        try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
        let piURL = piDir.appendingPathComponent("2026-08-07T01-20-08-718Z_\(AgentSupervisor.sessionId(for: piAgent)).jsonl")
        try [
            #"{"type":"session","version":3,"id":"s","cwd":"x"}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"PI_PLANTED_PROMPT"}]}}"#,
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"PI_PLANTED_REASON"},{"type":"text","text":"PI_PLANTED_REPLY"},{"type":"toolCall","id":"call_9","name":"read","arguments":{}}]}}"#,
            #"{"type":"message","message":{"role":"toolResult","toolCallId":"call_9","toolName":"read","isError":false,"content":[{"type":"text","text":"body"}]}}"#,
        ].joined(separator: "\n").write(to: piURL, atomically: true, encoding: .utf8)

        let piInputs = ManagedTranscriptRehydrator.Inputs(
            agentUUID: piAgent.rawValue, cwd: liveCwd, model: "openai-codex/gpt-5.6", harness: .pi,
            claudeCLIAvailable: false, homeURL: rehydrateHome)
        guard let piTranscript = ManagedTranscriptRehydrator.rehydrate(piInputs) else {
            throw fail("a restored pi agent with a session file did not rehydrate")
        }
        rehydrateSupervisor.seedRehydratedTranscript(piTranscript, for: piAgent)
        guard rehydrateSupervisor.needsPreviousSessionNotice(piAgent) == false else {
            throw fail("seeding a rehydrated pi transcript did not retire the previous-session notice")
        }
        let (piTile, piDrafts) = attachRecordingTile(piAgent)
        guard piTile.qaTranscriptText.contains("PI_PLANTED_PROMPT"),
              piTile.qaTranscriptText.contains("PI_PLANTED_REPLY") else {
            throw fail("rehydrated pi transcript did not reach the tile cards: \(piTile.qaTranscriptText)")
        }
        try assertDisplayOnly(piTranscript, drafts: piDrafts(), "pi")
        piTile.detach()

        // -- codex path -- exact persisted thread id, not newest/same-cwd.
        let codexDir = rehydrateHome
            .appendingPathComponent(".codex/sessions/2026/08/10", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        func writeCodexRollout(_ filename: String, threadId: String, prompt: String) throws {
            let url = codexDir.appendingPathComponent(filename)
            try [
                #"{"type":"session_meta","payload":{"id":"\#(threadId)","cwd":"\#(liveCwd)","timestamp":"2026-08-10T12:00:00.000Z"}}"#,
                #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)"}}"#,
                #"{"type":"event_msg","payload":{"type":"agent_message","message":"CODEX_PLANTED_REPLY"}}"#,
            ].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        try writeCodexRollout("rollout-z-wrong.jsonl", threadId: "wrong-thread", prompt: "WRONG_CODEX_PROMPT")
        try writeCodexRollout("rollout-a-exact.jsonl", threadId: codexThreadId, prompt: "CODEX_PLANTED_PROMPT")

        let codexInputs = ManagedTranscriptRehydrator.Inputs(
            agentUUID: codexAgent.rawValue, cwd: liveCwd, model: "openai-codex/gpt-5.6-sol", harness: .codex,
            claudeCLIAvailable: false, homeURL: rehydrateHome,
            codexThreadId: codexThreadId,
            codexHomeURL: rehydrateHome.appendingPathComponent(".codex", isDirectory: true))
        guard let codexTranscript = ManagedTranscriptRehydrator.rehydrate(codexInputs) else {
            throw fail("a restored Codex agent with an exact-id rollout did not rehydrate")
        }
        rehydrateSupervisor.seedRehydratedTranscript(codexTranscript, for: codexAgent)
        guard rehydrateSupervisor.needsPreviousSessionNotice(codexAgent) == false else {
            throw fail("seeding a rehydrated Codex transcript did not retire the previous-session notice")
        }
        let (codexTile, codexDrafts) = attachRecordingTile(codexAgent)
        guard codexTile.qaTranscriptText.contains("CODEX_PLANTED_PROMPT"),
              codexTile.qaTranscriptText.contains("CODEX_PLANTED_REPLY"),
              !codexTile.qaTranscriptText.contains("WRONG_CODEX_PROMPT") else {
            throw fail("rehydrated Codex transcript did not use the exact stored thread: \(codexTile.qaTranscriptText)")
        }
        guard codexTile.qaTranscriptText.contains("Previous session"),
              codexTile.currentAgentStatus == .idle else {
            throw fail("rehydrated Codex tile must lead with the boundary and remain idle")
        }
        try assertDisplayOnly(codexTranscript, drafts: codexDrafts(), "codex")
        codexTile.detach()

        // Display restoration and continuation are separate contracts: the
        // restored record must still construct the next runner with this exact
        // id, which CodexCLIBackend maps to `exec resume <id>`.
        guard let restoredCodexRecord = rehydrateSupervisor.records[codexAgent] else {
            throw fail("restored Codex record disappeared")
        }
        let resumedConfig = AgentSupervisor.codexRunnerConfig(for: restoredCodexRecord)
        guard resumedConfig.threadId == codexThreadId else {
            throw fail("restored Codex runner config lost the persisted thread id")
        }
        let resumeArgv = CodexCLIBackend.processArguments(
            model: resumedConfig.model,
            effort: resumedConfig.effort,
            sessionMode: .resume,
            threadId: resumedConfig.threadId,
            cwdPath: resumedConfig.cwd.path,
            extraArgs: [],
            prompt: AgentPrompt("continue"))
        guard Array(resumeArgv.prefix(3)) == ["exec", "resume", codexThreadId] else {
            throw fail("first post-restore Codex prompt is not routed through exec resume: \(resumeArgv)")
        }
    }

    // MARK: 5 · a prompt starts it, and the conversation continues from there

    let inbox = EventInbox()
    let stream = supervisor.events(for: headless.id)
    let task = Task { @MainActor in for await event in stream { inbox.append(event) } }
    defer { task.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: headless.id) == 1 }) else {
        throw fail("the subscriber did not register on the restored agent")
    }
    supervisor.send("continue please", to: headless.id)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { inbox.events.count == turn.count }) else {
        throw fail("a prompt to a restored agent did not run: \(inbox.events.count) of \(turn.count) events")
    }
    guard queue.handedOut.count == 1, queue.handedOut[0].prompts == ["continue please"] else {
        throw fail("the restored agent's prompt did not reach a runner: \(queue.handedOut.map(\.prompts))")
    }
    guard try store.load(id: headless.id)?.lastActivityAt ?? .distantPast > headless.lastActivityAt else {
        throw fail("running a restored agent did not move its stored lastActivityAt")
    }
    // Having run, it no longer wants the placeholder — but it is still a restored
    // agent. The two answers are deliberately different (see
    // `needsPreviousSessionNotice`).
    guard supervisor.wasRestored(headless.id), supervisor.needsPreviousSessionNotice(headless.id) == false else {
        throw fail("a restored agent that has produced a transcript still asks for the previous-session placeholder")
    }
    // Continuity is only real if the resumed prompt carries the SAME Pi session id,
    // and that id survives because it is derived from the agent id. Asserted on the
    // production argument builder, not on a string this check formats.
    let resumeArgs = PiAgentRunner.processArguments(
        model: config.model,
        thinking: config.thinking,
        sessionId: AgentSupervisor.sessionId(for: headless.id),
        extraArgs: [],
        prompt: "continue please"
    )
    guard resumeArgs.contains("--session-id"),
          resumeArgs.contains(AgentSupervisor.sessionId(for: headless.id)),
          !resumeArgs.contains("--no-session") else {
        throw fail("a restored agent's prompt would not resume its Pi session: \(resumeArgs)")
    }
    // HONEST LIMIT: this shows the flag and the id the production path composes. That
    // Pi then RESUMES that conversation is the provider's behaviour and needs the
    // supervised `--managed-agent-live-check`, not this leg.

    // MARK: 6 · restoring twice does not clobber the live copy

    // A doctored copy back to disk stands in for "the store is behind memory". The
    // live record must win, or a second restore would undo work this session did.
    var doctored = headless
    doctored.displayName = "stale name from disk"
    try store.upsert(doctored)
    let second = supervisor.restore()
    guard Set(second.skipped) == Set([
        tiled.id, headless.id, codexExact.id, codexSanitized.id, freshId,
    ]) else {
        throw fail("a second restore did not treat the live records as already-owned: skipped \(second.skipped.count)")
    }
    guard second.restored.isEmpty else {
        throw fail("a second restore re-adopted \(second.restored.count) record(s)")
    }
    // This used to pin `displayName == config.model`, which was the old spawn
    // bug. The assertion stays load-bearing: after the restored agent is prompted,
    // a second restore must not clobber its first-prompt name with the doctored disk copy.
    guard supervisor.records[headless.id]?.displayName == "continue please" else {
        throw fail("a second restore clobbered the live first-prompt name with the stored copy: \(String(describing: supervisor.records[headless.id]?.displayName))")
    }
    guard supervisor.records.count == 5 else {
        throw fail("restoring twice duplicated records: \(supervisor.records.count)")
    }

    // MARK: 7 · no double-restore out of the OTHER store (the packet's watch-out)

    // `ManagedAgentSessionRecord` still exists for terminal/tmux agents. A record
    // there must not conjure a supervised agent, or a tmux agent would come back
    // twice — once as a pane and once as a Pi agent.
    let projectRoot = root.appendingPathComponent("project", isDirectory: true)
    let managedSessionStore = ManagedAgentSessionStore(projectRoot: projectRoot)
    let tmuxTileId = UUID()
    try managedSessionStore.upsert(ManagedAgentSessionRecord(
        tileId: tmuxTileId,
        agentKind: .managed,
        lastSeenAt: Date()
    ))
    guard try managedSessionStore.load(tileId: tmuxTileId) != nil else {
        throw fail("the managed-session record did not persist, so the double-restore assertion proves nothing")
    }
    let beforeThirdRestore = supervisor.records.count
    _ = supervisor.restore()
    guard supervisor.records.count == beforeThirdRestore else {
        throw fail("a restore adopted records from outside AgentStore: \(supervisor.records.count) vs \(beforeThirdRestore)")
    }
    guard supervisor.agent(forTile: tmuxTileId) == nil else {
        throw fail("a ManagedAgentSessionRecord produced a supervised agent — an agent must not be restored from both stores")
    }
    tile.detach()

    // MARK: 8 · a project root that comes back stops being stale

    // The stale mark is not a tombstone: a detached worktree can be re-created, and
    // the agent must then come back like any other. Found by the cross-review, which
    // caught `staleIDs` never being cleared.
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: missingCwd, isDirectory: true),
        withIntermediateDirectories: true
    )
    let recovered = supervisor.restore()
    guard recovered.restored == [orphaned.id] else {
        throw fail("an agent whose project root came back was not adopted: restored \(recovered.restored.count), stale \(recovered.stale.count)")
    }
    guard supervisor.records[orphaned.id] != nil, supervisor.staleIDs.contains(orphaned.id) == false else {
        throw fail("the recovered agent is still marked stale, so the inbox would show it as both live and gone")
    }

    // MARK: 9 · the production wiring: restore runs BEFORE the tile walk…

    let bootLines = try continuumAppLineIndices([
        "let agentRestore = agentSupervisor.restore()",
        "for tile in canvasState.tiles {",
        "installInitialManagedAgentTile(tile, in: canvasView)"
    ])
    guard bootLines[0] < bootLines[1], bootLines[1] < bootLines[2] else {
        throw fail("restore() does not run before the boot tile walk (lines \(bootLines)) — the walk would spawn a fresh agent over each surviving record")
    }

    // …and a restored agent's tile is told to say so.
    // The signature carries P3.9's `agentID:` — revealing a headless agent wires an
    // agent that already exists into a fresh tile. Still an EXACT match, so a rename
    // still turns this scan red rather than blind.
    let wiring = try paletteAgentSpawnBranch("func wireManagedAgentTile(_ tileId: UUID, agentID: AgentID? = nil, initialLaunchSelection: AgentLaunchSelection? = nil) {")
    guard wiring.contains("needsPreviousSessionNotice("), wiring.contains("rehydratePreviousSessionOrNotice(") else {
        throw fail("wireManagedAgentTile does not route a restored agent through rehydration/notice, so a restored agent renders as a blank tile:\n\(wiring)")
    }
    // …and that route reads the session file, seeds the display-only transcript,
    // renders it, and falls back to the plain notice when there is no file.
    let rehydrationBranch = try paletteAgentSpawnBranch(
        "private func rehydratePreviousSessionOrNotice(agentId: AgentID, into view: ManagedAgentTileNSView) {")
    guard rehydrationBranch.contains("ManagedTranscriptRehydrator.rehydrate("),
          rehydrationBranch.contains("seedRehydratedTranscript("),
          rehydrationBranch.contains("renderRehydratedPreviousSession("),
          rehydrationBranch.contains("showPreviousSessionNotice()") else {
        throw fail("rehydratePreviousSessionOrNotice must read the session file, seed + render the transcript, and fall back to the notice:\n\(rehydrationBranch)")
    }

    print("AgentRestore: 2 of 3 stored agents adopted with no runner (1 marked stale for a missing project root, adopted once that root came back), the tiled one re-resolved from its tileId and took a view showing idle plus a previous-session notice, a prompt then started it with --session-id and retired its placeholder, and restoring four times neither duplicated, clobbered, nor pulled from ManagedAgentSessionStore")
}

/// The line index of each of `needles` in `ContinuumApp.swift`, in the order given.
/// Used to assert an ORDERING between two production statements — a scan, for the
/// same reason `paletteAgentSpawnBranch` is one, and an ordering is the one property
/// a body-contains scan cannot see.
private func continuumAppLineIndices(_ needles: [String]) throws -> [Int] {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    return try needles.map { needle in
        guard let index = lines.firstIndex(of: needle) else {
            throw ScanError(description: "no line `\(needle)` in \(path) — it moved or was renamed, and this scan is now blind")
        }
        return index
    }
}

/// A runner factory that hands out one scripted runner per `send`, in order. The
/// supervisor makes a new runner per prompt, so a single shared script cannot say
/// "this turn emits three events and the next two".
@MainActor
private final class ScriptedRunnerQueue {
    private(set) var handedOut: [ScriptedAgentRunner] = []
    private var pending: [ScriptedAgentRunner]

    init(_ runners: [ScriptedAgentRunner]) { pending = runners }

    func next(_ record: AgentRecord) -> AgentRunning {
        let runner = pending.isEmpty ? ScriptedAgentRunner(script: []) : pending.removeFirst()
        handedOut.append(runner)
        return runner
    }
}

private final class CapabilityRepaintRunnerBox: @unchecked Sendable {
    var made: [ScriptedAgentRunner] = []
}

/// Pi startup-latency regression: a session-capable runner returns after a
/// settled turn but remains owned by the agent. The next prompt must rebind that
/// exact process, while the UI still sees an unoccupied/sendable turn boundary.
@MainActor
private func checkPersistentRunnerReuse<Failure: Error>(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-persistent-runner-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let thread = "persistent-provider"
    let persistent = ScriptedAgentRunner(
        script: [
            .turnStarted(threadId: thread, turnId: "provider-turn"),
            .turnCompleted(
                threadId: thread, turnId: "provider-turn",
                outcome: .completed, errorMessage: nil),
            .sessionStateChanged(.ready),
        ],
        persistentBetweenTurns: true)
    var factoryCount = 0
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root),
        makeRunner: { _ in
            factoryCount += 1
            return persistent
        })
    let id = supervisor.spawn(
        role: "persistent-runner", prompt: nil, cwd: cwd,
        model: config.model, thinking: config.thinking)

    guard supervisor.send("first", to: id) else {
        throw fail("persistent runner: first prompt was refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        persistent.completedRuns == 1
            && supervisor.turnSnapshot(for: id)?.capabilities.canSend == true
    }) else {
        throw fail("persistent runner: first settled turn never became sendable")
    }
    guard supervisor.send("second", to: id) else {
        throw fail("persistent runner: second prompt was refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        persistent.completedRuns == 2
            && supervisor.turnSnapshot(for: id)?.capabilities.canSend == true
    }) else {
        throw fail("persistent runner: second settled turn never completed")
    }
    guard factoryCount == 1, persistent.prompts == ["first", "second"] else {
        throw fail(
            "persistent runner: two prompts used \(factoryCount) process(es), prompts \(persistent.prompts)")
    }
    supervisor.stopAll()
    guard persistent.stopCount == 1 else {
        throw fail("persistent runner: app teardown did not stop the idle session")
    }
    return "two prompts reused one persistent provider process and app teardown stopped its idle session"
}

/// P5.5 correction gate (`plan-P5.5-review-corrections.md` defect 1). The Pi
/// process prints its terminal turn events before it exits, so the runner slot
/// frees strictly AFTER the last runtime event a tile ever ingests — the tile's
/// repaint of that transition rides the supervisor's capability seam, never a
/// fabricated event. `qaDeliver` cannot represent this race (no runner exists on
/// that path, which is exactly how the latch shipped); this leg drives it with a
/// real held-open scripted runner. The required negative witness is disconnecting
/// `notifyTurnCapabilitiesChanged` from `clearRunner`: the slot-free repaint
/// assertion below goes red.
@MainActor
private func checkTurnCapabilityRepaint<Failure: Error>(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    // One FRESH runner per send, as production's makeRunner does: reusing one
    // instance across rounds defeats clearRunner's identity check — a previous
    // round's late completion would clear the next round's slot.
    let box = CapabilityRepaintRunnerBox()
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in
        let runner = ScriptedAgentRunner(script: [], holdUntilStopped: true)
        box.made.append(runner)
        return runner
    })
    let tileID = UUID()
    let agentID = supervisor.spawn(
        role: "capability-repaint",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileID
    )
    let thread = AgentSupervisor.threadId(for: agentID)
    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileID,
        kind: .managedAgent,
        title: "capability-repaint",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
    tile.attach(agentID: agentID, supervisor: supervisor)
    defer { tile.detach() }

    // Round 1 — the SPAWN window (P5.5 consolidation). The seam fires inside
    // `send` itself, so the button offers Stop before any runtime event exists —
    // and that Stop is callable: it kills the spawning runner.
    supervisor.send("first prompt", to: agentID)
    guard tile.qaV2ActionTitle == "Stop",
          supervisor.turnSnapshot(for: agentID)?.capabilities.canStop == true else {
        throw fail("capability-repaint: send did not synchronously present a stoppable flight (action '\(tile.qaV2ActionTitle ?? "nil")')")
    }
    guard let spawnRunner = box.made.first else {
        throw fail("capability-repaint: send made no runner")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { spawnRunner.runCount == 1 }) else {
        throw fail("capability-repaint: the scripted runner never ran")
    }
    guard await supervisor.accept(.stop, for: agentID) == .accepted else {
        throw fail("capability-repaint: stop during the spawn window was refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        spawnRunner.stopCount == 1 && spawnRunner.completedRuns == 1 && tile.qaV2ActionTitle == "Send"
    }) else {
        throw fail("capability-repaint: stopping the spawning runner did not release the flight (stops \(spawnRunner.stopCount), completed \(spawnRunner.completedRuns), action '\(tile.qaV2ActionTitle ?? "nil")')")
    }
    // Let round 1's `.stopped` delivery land before counting round 2's events.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.ingestedEvents.count == 1 }) else {
        throw fail("capability-repaint: the stop's session event never reached the tile (\(tile.ingestedEvents.count) ingested)")
    }

    // Round 2 — a full natural turn, ending in the DRAIN window: terminal events
    // arrive while the process is still alive and blocked in run().
    supervisor.send("second prompt", to: agentID)
    guard box.made.count == 2, let runner = box.made.last else {
        throw fail("capability-repaint: the second send did not make a fresh runner (\(box.made.count) made)")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.runCount == 1 }) else {
        throw fail("capability-repaint: the second run never started")
    }
    guard runner.emit(.turnStarted(threadId: thread, turnId: "t1")),
          runner.emit(.turnCompleted(threadId: thread, turnId: "t1", outcome: .completed, errorMessage: nil)),
          runner.emit(.sessionStateChanged(.ready)) else {
        throw fail("capability-repaint: no run was in flight to emit the turn from")
    }
    // At the LAST event the tile will ever ingest, the slot is still held:
    // sending is truthfully impossible, and the drain window keeps the interrupt
    // affordance — never "Unavailable" — with the pickers dark alongside it. The
    // event count is part of the condition: spawn and drain deliberately look
    // identical at the button, so only the ingested turn distinguishes them.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.ingestedEvents.count == 4 && tile.qaV2CanSend == false
            && tile.qaV2ActionTitle == "Stop" && !tile.qaProviderControlsEnabled
    }) else {
        throw fail("capability-repaint: the drain window lost its Stop (canSend \(tile.qaV2CanSend), action '\(tile.qaV2ActionTitle ?? "nil")', pickers \(tile.qaProviderControlsEnabled ? "live" : "dark"), events \(tile.ingestedEvents.count))")
    }

    // The process exits; run() returns; the slot frees. No further runtime event.
    // The button offers Send again (its enablement then follows the draft, which
    // is the composer key contract's business, not this leg's).
    let eventsBeforeExit = tile.ingestedEvents.count
    runner.stop()
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.completedRuns == 1 && tile.qaV2CanSend && tile.qaV2ActionTitle == "Send" && tile.qaProviderControlsEnabled
    }) else {
        throw fail("capability-repaint: composer stayed un-sendable after the runner slot freed — the capability seam did not repaint (canSend \(tile.qaV2CanSend), action '\(tile.qaV2ActionTitle ?? "nil")')")
    }
    // And nothing was fabricated to do it.
    guard tile.ingestedEvents.count == eventsBeforeExit else {
        throw fail("capability-repaint: the repaint rode a fabricated runtime event (\(tile.ingestedEvents.count) ingested, was \(eventsBeforeExit))")
    }
    // The advertised capability is transport-true: a third turn is accepted.
    let acceptance = await supervisor.accept(.send("third prompt"), for: agentID)
    guard case .accepted = acceptance else {
        throw fail("capability-repaint: the supervisor refused the third turn (\(acceptance))")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { box.made.count == 3 && box.made.last?.runCount == 1 }) else {
        throw fail("capability-repaint: the accepted third turn never reached a fresh runner (\(box.made.count) made)")
    }
    box.made.last?.stop()
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { box.made.last?.completedRuns == 1 }) else {
        throw fail("capability-repaint: the third run did not release")
    }
    return "spawn window stoppable, drain window kept Stop, slot-free repainted without an event, third turn ran"
}

/// P5.4 live migration gate. The required negative witness is the empty-choice
/// user-input request: it must render context but never acquire a fabricated text
/// editor or action. Changing that request to freeform makes this assertion red.
@MainActor
private func checkLiveV2TileMigration<Failure: Error>(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    // The runner is a transport stub — the turn shapes under test are
    // hand-delivered via `qaDeliver`. It still closes its own turn like a real
    // provider does, because a runner that returns WITHOUT a `.turnCompleted` is
    // now (correctly) closed by the supervisor's no-result mint, and that
    // interrupted completion is section 23's subject, not this leg's.
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: [
        .turnCompleted(threadId: "v2-stub", turnId: "composer-turn", outcome: .completed, errorMessage: nil)
    ]) })
    let tileID = UUID()
    let agentID = supervisor.spawn(
        role: "migration-check",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileID
    )
    let thread = AgentSupervisor.threadId(for: agentID)

    // Replay exists before the v2 view and tail follows after attach. Two deltas
    // update one stable semantic row rather than creating a second visible model.
    supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "v2-turn"), to: agentID)
    supervisor.qaDeliver(.contentDelta(
        threadId: thread, turnId: "v2-turn", streamKind: .assistant, delta: "replay"
    ), to: agentID)

    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileID,
        kind: .managedAgent,
        title: "migration-check",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
    let draftStore = AgentComposerDraftStore(
        applicationSupportDirectory: store.layout.applicationSupportDirectory,
        debounceInterval: 60
    )
    let promptHistory = AgentPromptHistory()
    tile.bindV2ComposerState(draftStore: draftStore, promptHistory: promptHistory)
    tile.attach(agentID: agentID, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.ingestedEvents.count == 2 && tile.qaRenderedCardCount == 1
    }) else {
        throw fail("live-v2: replay did not produce exactly one semantic row (events \(tile.ingestedEvents.count), rows \(tile.qaRenderedCardCount), error \(tile.qaV2RenderError ?? "none"))")
    }
    supervisor.qaDeliver(.contentDelta(
        threadId: thread, turnId: "v2-turn", streamKind: .assistant, delta: "→tail"
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.ingestedEvents.count == 3 && tile.qaRenderedCardCount == 1
    }) else {
        throw fail("live-v2: tail duplicated the stable semantic row (events \(tile.ingestedEvents.count), rows \(tile.qaRenderedCardCount))")
    }
    // This is the production event path: supervisor delivery -> tile ingest ->
    // compact phase projection. It deliberately does not call the geometry-only
    // qaApplyCompactStatusFacts seam.
    // WHERE THE LIVE WORD IS NOW. Commit 204b2ac moved live status onto the prism
    // gyro at the transcript tail and left the footer only the states that want
    // your attention, so a `.responding` turn deliberately says nothing in the
    // footer. This assertion still read the footer, and it went red the moment
    // that shipped — invisible, because this leg halts earlier at the KNOWN-RED
    // naming section. Both halves are asserted now: the word appears where it
    // moved to, and the surface it moved off stays quiet. Prefix and not equality:
    // the gyro's line carries the 1s elapsed tick after the word ("Responding · 0s"),
    // and pinning a running clock in a string comparison is how a leg becomes a
    // flake. The tick has its own witness (`qaCompactStatusTickScheduled`).
    guard tile.qaCompactStatusPhase == .responding,
          tile.qaTailStatusText.hasPrefix("Responding"),
          tile.qaCompactStatusActivityText.isEmpty else {
        throw fail("live-v2: an ingested assistant delta did not drive the installed compact row (phase \(String(describing: tile.qaCompactStatusPhase)), gyro status '\(tile.qaTailStatusText)', footer activity '\(tile.qaCompactStatusActivityText)')")
    }
    guard tile.qaCompactStatusRowIsInstalled,
          tile.qaCompactStatusAccessibilityLabel.contains("Home") else {
        throw fail("live-v2: attach/replay left the compact status row uninstalled or without its location semantics")
    }
    guard tile.qaLocationActionButtonAccessibilityLabel == "Location actions",
          tile.qaLocationActionButtonEnabled else {
        throw fail("live-v2: the compact row lost its single accessible location action owner")
    }
    guard tile.qaUsesV2Tile, tile.qaUsesFullTurnComposer,
          !tile.qaHasLegacyComposeField, !tile.qaHasPermanentApprovalDock,
          tile.qaV2RenderError == nil else {
        throw fail("live-v2: migrated shell did not install semantic list/full-turn composer exclusively")
    }

    // The request block is projected by the content reducer, and a choice press
    // is a transport dispatch, never a resolution. The seam here refuses (as an
    // unbound production seam effectively does), so the request must remain
    // pending until the REAL runtime resolution event arrives.
    var dispatches: [(String, String)] = []
    tile.onProviderResponse = { requestID, value in
        dispatches.append((requestID, value))
        return false
    }
    supervisor.qaDeliver(.requestOpened(
        threadId: thread, requestId: "approval-live", kind: .commandExecutionApproval
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaV2RequestIDs == ["approval-live"]
            && tile.qaV2RequestChoices("approval-live") == ApprovalDecision.compiledChoices
    }) else {
        throw fail("live-v2: needs-attention did not reveal the matching fixed-choice request")
    }
    tile.layoutSubtreeIfNeeded()
    guard tile.qaClickV2RequestChoice(
        requestID: "approval-live", value: ApprovalDecision.decline.rawValue
    ) else {
        throw fail("live-v2: provider choice was not a clickable action in the semantic request block")
    }
    guard dispatches.count == 1, dispatches[0] == ("approval-live", ApprovalDecision.decline.rawValue),
          tile.qaV2RequestStatus("approval-live") == .inProgress else {
        throw fail("live-v2: a choice press without an accepting transport must dispatch exactly once and resolve nothing")
    }
    supervisor.qaDeliver(.requestResolved(
        threadId: thread, requestId: "approval-live", decision: ApprovalDecision.decline.rawValue
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaV2RequestStatus("approval-live") == .cancelled
    }) else {
        throw fail("live-v2: the runtime resolution event did not turn the request block passive")
    }
    _ = tile.qaClickV2RequestChoice(
        requestID: "approval-live", value: ApprovalDecision.decline.rawValue
    )
    guard dispatches.count == 1 else {
        throw fail("live-v2: a stale resolved request action fired twice")
    }

    // Required negative witness: empty choices are an explicit fixed-choice([]),
    // not evidence of freeform. The request remains readable without controls.
    supervisor.qaDeliver(.userInputRequested(
        threadId: thread,
        requestId: "input-without-contract",
        questions: [UserInputQuestion(key: "q", prompt: "Provide deployment context")]
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaV2RequestIDs.contains("input-without-contract")
    }) else {
        throw fail("live-v2: explicit input request context was not revealed")
    }
    guard tile.qaV2RequestChoices("input-without-contract") == [],
          !tile.qaV2HasCompactRequestEditor,
          !tile.qaClickV2RequestChoice(requestID: "input-without-contract", value: "fabricated") else {
        throw fail("live-v2 negative witness: fixedChoice([]) fabricated a response editor or action")
    }
    supervisor.qaDeliver(.userInputResolved(
        threadId: thread, requestId: "input-without-contract"
    ), to: agentID)
    supervisor.qaDeliver(.turnCompleted(
        threadId: thread, turnId: "v2-turn", outcome: .completed, errorMessage: nil
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.turnSnapshot(for: agentID)?.capabilities.canSend == true
            && tile.qaV2CanSend && tile.qaComposeEnabled
    }) else {
        throw fail("live-v2: tile did not return to a send-capable turn after requests resolved")
    }
    tile.qaSubmitPrompt("sent through the full-turn composer")
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        promptHistory.acceptedSubmissionCount(for: agentID) == 1
            && tile.qaTranscriptText.contains("sent through the full-turn composer")
    }) else {
        throw fail("live-v2: AgentID-bound composer did not accept, record history, and echo its prompt (history \(promptHistory.acceptedSubmissionCount(for: agentID)), transcript \(tile.qaTranscriptText))")
    }
    guard await draftStore.load(for: agentID) == nil else {
        throw fail("live-v2: accepted composer send did not clear the AgentID-bound draft")
    }

    // P5.4: forced reattach. Detaching the v2 view and re-attaching the same
    // agent replays the full history — request blocks included — exactly once
    // into a fresh reducer, with no duplicate nodes and no render error. The
    // branch refresh that ran on this v2 tile at turn completion must have
    // yielded a truthful no-chip for a non-repository cwd, not a shell failure.
    // Replay is event-sourced: the locally appended prompt row is not a runtime
    // event and transcript durability of local entries is an explicit program
    // non-goal, so exactly that one row is absent after a forced reattach.
    let rowsBeforeReattach = tile.qaRenderedCardCount
    let requestsBeforeReattach = tile.qaV2RequestIDs
    tile.detach()
    tile.attach(agentID: agentID, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaRenderedCardCount == rowsBeforeReattach - 1
            && tile.qaV2RequestIDs == requestsBeforeReattach
            && tile.qaV2RenderError == nil
    }) else {
        throw fail("live-v2: reattach did not replay the event-sourced document exactly once (rows \(tile.qaRenderedCardCount) vs \(rowsBeforeReattach - 1) expected, requests \(tile.qaV2RequestIDs), error \(tile.qaV2RenderError ?? "none"))")
    }
    guard tile.qaV2RequestStatus("approval-live") == .cancelled else {
        throw fail("live-v2: reattach lost the resolved request's passive state")
    }
    // The check runs in a shared repo checkout, so the turn-completion branch
    // refresh must have produced a real chip through the v2 header contract —
    // never the shell-failure sentinel and never an empty label.
    guard let v2Chip = tile.qaBranchChipText, v2Chip.hasPrefix("⎇") else {
        throw fail("live-v2: v2 branch refresh did not yield a truthful chip for the shared checkout: \(tile.qaBranchChipText ?? "nil")")
    }

    // P5.5 acceptance removed the reversible construction seam with the legacy
    // path: v2 is the only tile. The rollback assertions this leg carried died
    // with it; the structural absences are asserted below on the live tile.
    guard !tile.qaHasLegacyComposeField, !tile.qaHasPermanentApprovalDock else {
        throw fail("live-v2: the legacy compose field or approval dock is reachable after the P5.5 removal")
    }

    let subscribersBeforeDetach = supervisor.subscriberCount(for: agentID)
    tile.detach()
    // A detached tile has no phase and says nothing. It used to say "Unknown"
    // out loud; 204b2ac's rule is that the row is silent whenever it has no
    // authoritative fact, and a permanent "Unknown" chip on a tile nobody is
    // driving is exactly the wallpaper that rule exists to remove. The
    // conservative CLEAR is still the assertion — phase back to nil, and the
    // gyro's live word gone with it.
    guard tile.qaCompactStatusPhase == nil,
          tile.qaCompactStatusActivityText.isEmpty,
          tile.qaTailStatusText.isEmpty else {
        throw fail("live-v2: detach did not conservatively clear the compact lifecycle projection (phase \(String(describing: tile.qaCompactStatusPhase)), footer '\(tile.qaCompactStatusActivityText)', gyro '\(tile.qaTailStatusText)')")
    }
    tile.attach(agentID: agentID, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.attachedAgentID == agentID
            && supervisor.subscriberCount(for: agentID) == subscribersBeforeDetach
    }) else {
        throw fail("live-v2: rebind task did not restore the subscription")
    }
    // The replay is the assertion; the WORD is not, because an idle agent is
    // deliberately silent now (92c07da: "go silent when idle"). A permanent
    // "Ready" chip was the thing that made the status line unreadable — it was
    // on screen whether or not anything had happened. So: the phase must come
    // back, and the row must say nothing about it.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaCompactStatusPhase == .ready
            && tile.qaCompactStatusRow.qaActivityIsSilent
    }) else {
        throw fail("live-v2: rebind did not replay lifecycle events into the compact row (phase \(String(describing: tile.qaCompactStatusPhase)), activity \'\(tile.qaCompactStatusActivityText)\', silent \(tile.qaCompactStatusRow.qaActivityIsSilent))")
    }
    tile.detach()
    guard subscribersBeforeDetach == 1,
          await waitUntil(timeout: 5, pollInterval: 0.02, {
              supervisor.subscriberCount(for: agentID) == 0
          }),
          supervisor.records[agentID] != nil else {
        throw fail("live-v2: detach failed to cancel UI subscription or changed supervisor ownership")
    }
    return "v2 tile replayed then tailed one stable semantic row and drove compact status through real ingest, sent and history-recorded one AgentID-bound full-turn draft with no legacy field/dock, revealed one reducer-projected fixed-choice request whose choice press dispatched once and resolved NOTHING until the real runtime resolution turned it passive, kept fixedChoice([]) read-only, detached and rebound the compact lifecycle projection with an exactly-once replay including resolved request history and a truthful no-chip branch refresh, with the legacy path structurally unreachable"
}

/// The tile as a pure view over an agent's stream: attach replays the history,
/// live events keep arriving, and `detach()` cancels the subscription and nothing
/// else. Drives the real `ManagedAgentTileNSView` — a stand-in would prove nothing
/// about the view that ships.
///
/// Seven negative tests observed red at exit 1 with the final code, six of them
/// production edits to `ManagedAgentTileNSView.attach/detach`:
/// · `let bound = event` (no rebinding to the tile's thread) →
///   `FAIL: the replayed history did not reach the transcript:` (the model filters
///   on its own thread, so an unbound event renders nothing)
/// · the `attachedAgentID == agentID` early return deleted — re-attach WHILE STILL
///   ATTACHED, which is the live re-wire the app's three call sites can do →
///   `FAIL: re-attaching the same agent replayed its history again: 6 events`
/// · `detach()` no longer cancelling →
///   `FAIL: detach did not remove the tile's subscription; 2 subscribers remain`
/// · `if replayingIntoAProjection { resetProjection() }` deleted →
///   `FAIL: attaching to a second agent did not reset the projection: the tile
///   holds 8 events, expected 2`
/// · that same guard narrowed to `projectedAgentID != agentID`, which is what the
///   first draft shipped and the cross-review caught — DETACH then re-attach the
///   SAME agent →
///   `FAIL: re-attaching after a detach did not replay the history exactly once:
///   the tile holds 13 events, the agent's history is 7`
/// · `resetProjection` leaving the stack's arranged subviews in place →
///   `FAIL: the card stack holds 4 views for 2 cards — a reset left stale arranged
///   subviews`
/// · and, at this call site, a `supervisor.stop(agentId)` next to `tile.detach()`
///   standing in for a detach that killed its agent →
///   `FAIL: detaching the tile stopped the agent — a tile is one view of an agent,
///   not its owner`
@MainActor
private func checkTileIsASubscriber(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let provider = "provider-thread"
    // Turn 1: three events, one of them assistant text, so "shows all 3" is
    // checkable as rendered content and not only as a count.
    let turnOne: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "alpha"),
        .turnCompleted(threadId: provider, turnId: "t1", outcome: .completed, errorMessage: nil)
    ]
    // Turn 2: two more.
    let turnTwo: [AgentRuntimeEvent] = [
        .contentDelta(threadId: provider, turnId: "t2", streamKind: .assistant, delta: "beta"),
        .turnCompleted(threadId: provider, turnId: "t2", outcome: .completed, errorMessage: nil)
    ]
    // Turn 3 blocks, so the agent is provably still working when the tile detaches.
    let blocking = ScriptedAgentRunner(script: [.turnStarted(threadId: provider, turnId: "t3")], holdUntilStopped: true)
    let queue = ScriptedRunnerQueue([
        ScriptedAgentRunner(script: turnOne),
        ScriptedAgentRunner(script: turnTwo),
        blocking
    ])
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0.record) })
    let tileId = UUID()
    let agentId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileId
    )
    // An independent subscriber, so "the supervisor still receives events" after
    // detach is observed on the stream rather than inferred from the runner.
    let probe = EventInbox()
    let probeStream = supervisor.events(for: agentId)
    let probeTask = Task { @MainActor in for await event in probeStream { probe.append(event) } }
    defer { probeTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 1 }) else {
        throw fail("the probe subscriber did not register")
    }

    // The turn runs with NO tile attached — the history the tile will replay has to
    // exist before it does, or "replay" is indistinguishable from "tail".
    supervisor.send("first prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { probe.events.count == turnOne.count }) else {
        throw fail("turn 1 did not complete before the tile attached; probe has \(probe.events.count) of \(turnOne.count)")
    }

    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    guard tile.ingestedEvents.isEmpty else {
        throw fail("a fresh tile already holds \(tile.ingestedEvents.count) events")
    }

    tile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.ingestedEvents.count == turnOne.count }) else {
        throw fail("attaching a tile did not replay the agent's history: the tile holds \(tile.ingestedEvents.count) of \(turnOne.count) events")
    }
    guard tile.attachedAgentID == agentId else {
        throw fail("the tile did not record which agent it is attached to")
    }
    // Replay is not a counter: the transcript has to RENDER the history.
    guard tile.qaTranscriptText.contains("alpha") else {
        throw fail("the replayed history did not reach the transcript: \(tile.qaTranscriptText)")
    }
    // Rebinding at the boundary (the model filters on the tile's own thread), so a
    // supervisor-stamped event must arrive carrying the TILE's thread id.
    guard AgentSupervisor.threadId(for: agentId) != tile.wiringThreadId else {
        throw fail("the agent's thread id equals the tile's, so the rebinding is untested")
    }
    guard case let .turnCompleted(boundThread, _, _, _) = tile.ingestedEvents[2], boundThread == tile.wiringThreadId else {
        throw fail("ingested events were not rebound to the tile's thread id: \(tile.ingestedEvents[2])")
    }
    // Idempotent: re-attaching the same agent must not replay a second time.
    tile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 1.0, pollInterval: 0.02, { tile.ingestedEvents.count != turnOne.count }) == false else {
        throw fail("re-attaching the same agent replayed its history again: \(tile.ingestedEvents.count) events")
    }
    guard supervisor.subscriberCount(for: agentId) == 2 else {
        throw fail("expected the probe plus one tile subscription; got \(supervisor.subscriberCount(for: agentId))")
    }

    // Live tail: two more events reach the attached tile.
    supervisor.send("second prompt", to: agentId)
    let afterTurnTwo = turnOne.count + turnTwo.count
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { tile.ingestedEvents.count == afterTurnTwo }) else {
        throw fail("live events did not continue to arrive: the tile holds \(tile.ingestedEvents.count) of \(afterTurnTwo)")
    }
    guard tile.qaTranscriptText.contains("alpha"), tile.qaTranscriptText.contains("beta") else {
        throw fail("the transcript lost the replay or missed the tail: \(tile.qaTranscriptText)")
    }

    // Detach while a prompt is IN FLIGHT, which is the case the locked decision is
    // about: closing a view of a working agent must not kill it.
    supervisor.send("third prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { tile.ingestedEvents.count == afterTurnTwo + 1 }) else {
        throw fail("the third turn's first event did not reach the tile")
    }
    guard supervisor.isRunning(agentId) else {
        throw fail("the blocking runner should be in flight before the tile detaches")
    }

    tile.detach()
    guard tile.attachedAgentID == nil else {
        throw fail("detach left the tile bound to \(String(describing: tile.attachedAgentID))")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 1 }) else {
        throw fail("detach did not remove the tile's subscription; \(supervisor.subscriberCount(for: agentId)) subscribers remain")
    }
    guard supervisor.isRunning(agentId) else {
        throw fail("detaching the tile stopped the agent — a tile is one view of an agent, not its owner")
    }
    guard blocking.completedRuns == 0, blocking.stopCount == 0 else {
        throw fail("detaching the tile reached the runner: completedRuns \(blocking.completedRuns), stopCount \(blocking.stopCount)")
    }

    // The agent's stream is still live, and the detached tile is off it.
    let tileEventsAtDetach = tile.ingestedEvents.count
    let probeAtDetach = probe.events.count
    supervisor.stop(agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { probe.events.count > probeAtDetach }) else {
        throw fail("the supervisor stopped delivering events to its remaining subscriber after the tile detached")
    }
    guard probe.events.last == .sessionStateChanged(.stopped) else {
        throw fail("the remaining subscriber did not see the stop: \(String(describing: probe.events.last))")
    }
    guard tile.ingestedEvents.count == tileEventsAtDetach else {
        throw fail("a detached tile kept ingesting: \(tile.ingestedEvents.count) events, was \(tileEventsAtDetach)")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { blocking.completedRuns == 1 }) else {
        throw fail("the agent's blocked run() never returned after stop")
    }

    // Re-attaching the SAME agent after a detach (from the cross-review, which found
    // this double-ingesting): the replay is the whole conversation and the tile still
    // holds the part of it that it ingested before detaching, so `attach` has to
    // reset the projection rather than append a second copy of it.
    let historyCount = probe.events.count
    tile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.ingestedEvents.count == historyCount }) else {
        throw fail("re-attaching after a detach did not replay the history exactly once: the tile holds \(tile.ingestedEvents.count) events, the agent's history is \(historyCount)")
    }
    let alphaCards = tile.qaTranscriptText.components(separatedBy: "alpha").count - 1
    guard alphaCards == 1 else {
        throw fail("re-attaching after a detach duplicated the transcript (\(alphaCards) copies of the first reply): \(tile.qaTranscriptText)")
    }
    // The reset has to reach the view hierarchy, not just the model behind it.
    guard tile.qaRenderedCardCount == tile.transcriptCardCount else {
        throw fail("the card stack holds \(tile.qaRenderedCardCount) views for \(tile.transcriptCardCount) cards — a reset left stale arranged subviews")
    }
    tile.detach()

    // Attaching the SAME view to a DIFFERENT agent shows that agent's conversation,
    // not both of them concatenated.
    let otherTurn: [AgentRuntimeEvent] = [
        .contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "gamma"),
        .turnCompleted(threadId: provider, turnId: "t1", outcome: .completed, errorMessage: nil)
    ]
    let otherQueue = ScriptedRunnerQueue([ScriptedAgentRunner(script: otherTurn)])
    let otherSupervisor = AgentSupervisor(store: store, makeRunner: { otherQueue.next($0.record) })
    let otherAgentId = otherSupervisor.spawn(
        role: nil,
        prompt: "other prompt",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileId
    )
    let otherProbe = EventInbox()
    let otherStream = otherSupervisor.events(for: otherAgentId)
    let otherTask = Task { @MainActor in for await event in otherStream { otherProbe.append(event) } }
    defer { otherTask.cancel() }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { otherProbe.events.count == otherTurn.count }) else {
        throw fail("the second agent's turn did not complete; got \(otherProbe.events.count) of \(otherTurn.count)")
    }
    tile.attach(agentID: otherAgentId, supervisor: otherSupervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.ingestedEvents.count == otherTurn.count }) else {
        throw fail("attaching to a second agent did not reset the projection: the tile holds \(tile.ingestedEvents.count) events, expected \(otherTurn.count)")
    }
    guard tile.qaTranscriptText.contains("gamma"), !tile.qaTranscriptText.contains("alpha"), !tile.qaTranscriptText.contains("beta") else {
        throw fail("the tile mixed two agents' transcripts: \(tile.qaTranscriptText)")
    }
    tile.detach()

    return "a tile replayed \(turnOne.count) history events on attach, tailed \(turnTwo.count) more, detached without stopping an in-flight turn, and re-attached to a second agent without mixing transcripts"
}

/// P2A.5: the tile-close path in full. A tile is attached to a running agent, a
/// prompt is left IN FLIGHT, and then exactly what `AppDelegate.deleteTile`'s
/// `.managedAgent` branch does happens — `supervisor.detachView` plus
/// `tile.detach()` — after which the agent must still be running, still listed with
/// no tile binding, and still delivering. Stopping is then shown to be the separate
/// deliberate action that DOES end it.
///
/// The production branch itself is source-scanned rather than executed
/// (`managedAgentCloseBranchSource`); the precedent is `piRunnerConstructionSites`
/// above. `deleteTile` is an `AppDelegate` method over a live `canvasView`,
/// `workspaceRuntime`, focus broker and canvas save — and it reads
/// `DeleteConfirmPolicy`, which under `.always` runs an `NSAlert` modal — so
/// executing it headlessly needs an app-level harness that does not exist and that
/// this packet's `## Files` does not name. What the scan buys is that "never as a
/// side effect of closing a tile" is asserted rather than claimed about a diff; what
/// it does not cover is the rest of that branch's ordering (the
/// `managedSessionStore.delete`, `removeTile`, focus recovery and canvas flush that
/// already shipped), which stays the cross-review's and the owner's to read.
///
/// Negative tests observed red at exit 1 with the final code (production edits
/// except where noted):
/// · `detachView` not clearing `record.tileId` →
///   `FAIL: closing the tile left the persisted record claiming tile …`
/// · `detachView` clearing only the in-memory record (no `persist`) →
///   the same failure, since the assertion reads the store, not `records`
/// · `agentSupervisor.stop(agentId)` added next to `detachView` in `deleteTile` →
///   `FAIL: deleteTile's .managedAgent branch stops the agent: …`
/// · the `detachView` call deleted from `deleteTile` →
///   `FAIL: deleteTile's .managedAgent branch never detaches the agent's view …`
/// · `attach` not unbinding the tile's previous agent →
///   `FAIL: two agents claim tile …`
/// · (check-local vacuity witness, from the cross-review) the reaper's stale record
///   written at `Date()` instead of `.distantPast` →
///   `FAIL: the reaper sweep did not fire, so it proves nothing about a detached
///   agent: []`
/// · `attach` not persisting →
///   `FAIL: attach did not persist the tile binding: nil, expected …` (the assertion
///   reads the STORE after every bind, so an in-memory-only binding is red at the
///   first one)
@MainActor
private func checkDetachOutlivesItsTile(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let provider = "provider-thread"
    let firstTurn: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "alpha"),
        .turnCompleted(threadId: provider, turnId: "t1", outcome: .completed, errorMessage: nil)
    ]
    // The second turn blocks, so the agent is provably mid-work when its tile closes.
    let blocking = ScriptedAgentRunner(script: [.turnStarted(threadId: provider, turnId: "t2")], holdUntilStopped: true)
    let queue = ScriptedRunnerQueue([ScriptedAgentRunner(script: firstTurn), blocking])
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0.record) })

    // Spawned with NO tile, then bound by `attach` — the operation P2A.5 adds, and
    // the one Phase 3's "open in tile" will reach.
    let agentId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    let tileId = UUID()
    supervisor.attach(agentID: agentId, to: tileId)
    let boundTileId = try store.load(id: agentId)?.tileId
    guard boundTileId == tileId else {
        throw fail("attach did not persist the tile binding: \(String(describing: boundTileId)), expected \(tileId)")
    }
    guard supervisor.agent(forTile: tileId) == agentId else {
        throw fail("the attached agent is not the one found for its tile")
    }

    let probe = EventInbox()
    let probeStream = supervisor.events(for: agentId)
    let probeTask = Task { @MainActor in for await event in probeStream { probe.append(event) } }
    defer { probeTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 1 }) else {
        throw fail("the probe subscriber did not register")
    }

    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    tile.attach(agentID: agentId, supervisor: supervisor)

    supervisor.send("first prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { tile.ingestedEvents.count == firstTurn.count }) else {
        throw fail("the first turn did not reach the attached tile: \(tile.ingestedEvents.count) of \(firstTurn.count)")
    }
    // The first runner has to be RELEASED before the next send, or the second prompt
    // is (correctly) refused as concurrent: `run` returning and the supervisor
    // clearing `runners[id]` are one main-queue hop apart.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { supervisor.isRunning(agentId) == false }) else {
        throw fail("the first turn's runner was never released")
    }
    supervisor.send("second prompt", to: agentId)
    // Waiting for the blocking turn's `.turnStarted` to have REACHED THE PROBE, not
    // merely for `run()` to have been entered: the runner emits on a background queue
    // and the supervisor hops each event to main, so `isRunning && runCount == 1` is
    // true while that first event is still in flight. Capturing `probeAtClose` under
    // that condition left a moving baseline, and the `+ 1` comparison below then
    // watched the count step 3 → 4 → 5 and never equal 4. Observed as
    // "an event produced after the tile closed did not reach the supervisor's
    // remaining subscriber: probe holds 5, was 3" in roughly one run in five.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        supervisor.isRunning(agentId) && blocking.runCount == 1
            && probe.events.last == .turnStarted(threadId: AgentSupervisor.threadId(for: agentId), turnId: "t2")
    }) else {
        throw fail("the blocking turn did not start; runCount \(blocking.runCount), probe last \(String(describing: probe.events.last))")
    }

    // THE CLOSE PATH, exactly as `deleteTile`'s `.managedAgent` branch runs it —
    // the park first, then the detach, in that order.
    let parked = supervisor.close(agentID: agentId)
    supervisor.detachView(agentID: agentId)
    tile.detach()

    // THE PARK MUST REFUSE HERE (.plans/05-close-to-history.md). This agent is
    // mid-turn, and burying working work in History is the one thing closing a
    // tile may never do: the row is all that is left saying the work exists.
    guard !parked else {
        throw fail("closing the tile of a WORKING agent parked it in History; the turn is still in flight and its row is the only surface left reporting it")
    }

    guard let afterClose = try store.load(id: agentId) else {
        throw fail("closing the tile removed the agent's record from the store — the agent is the entity, the tile is one view of it")
    }
    guard afterClose.archivedAt == nil else {
        throw fail("closing the tile of a working agent stamped archivedAt \(String(describing: afterClose.archivedAt)) — it would draw in History while its turn runs")
    }
    guard afterClose.tileId == nil else {
        throw fail("closing the tile left the persisted record claiming tile \(String(describing: afterClose.tileId))")
    }
    guard supervisor.agent(forTile: tileId) == nil else {
        throw fail("the closed tile still resolves to an agent")
    }
    guard supervisor.records[agentId] != nil else {
        throw fail("closing the tile dropped the agent from the supervisor's live records")
    }
    guard supervisor.isRunning(agentId) else {
        throw fail("closing the tile stopped the agent's in-flight turn")
    }
    guard blocking.stopCount == 0, blocking.completedRuns == 0 else {
        throw fail("closing the tile reached the runner: stopCount \(blocking.stopCount), completedRuns \(blocking.completedRuns)")
    }

    // Events still flow to the supervisor, from the turn that is still running.
    let probeAtClose = probe.events.count
    let tileAtClose = tile.ingestedEvents.count
    guard blocking.emit(.contentDelta(threadId: provider, turnId: "t2", streamKind: .assistant, delta: "beta")) else {
        throw fail("the detached agent's runner is no longer in flight, so post-close delivery is untestable")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { probe.events.count == probeAtClose + 1 }) else {
        throw fail("an event produced after the tile closed did not reach the supervisor's remaining subscriber: probe holds \(probe.events.count), was \(probeAtClose)")
    }
    guard case let .contentDelta(threadId, _, _, delta) = probe.events[probeAtClose],
          delta == "beta",
          threadId == AgentSupervisor.threadId(for: agentId) else {
        throw fail("the post-close event arrived wrong: \(probe.events[probeAtClose])")
    }
    guard tile.ingestedEvents.count == tileAtClose else {
        throw fail("the closed tile kept ingesting: \(tile.ingestedEvents.count) events, was \(tileAtClose)")
    }

    // THE IDLE REAPER (the packet's watch-out). What this asserts, exactly: a real
    // `SessionPruner.sweep()` over a maximally stale binding covering the closed
    // tile issues a tmux `detachSession` and NO kill, and leaves the detached
    // agent running with its record intact. That is the whole of the reaper's
    // mutating surface, and a supervisor agent is a Pi process the supervisor holds
    // rather than a tmux pane, so there is nothing for it to reap.
    //
    // The binding is built with the PRODUCTION expression
    // (`ZoneRuntimeController.startReaper`'s `managedSessionStore.load(tileId:)?
    // .lastSeenAt`, ~:350) over a real `ManagedAgentSessionRecord` written stale, so
    // the `lastSeenAt` path the watch-out names is the one under test. What stays
    // unexercised is `startReaper`'s own wiring, which needs a live
    // `ZoneRuntimeController`; it contributes only `sessionName`/`tileIds`/
    // `lastSeenAt` to this same sweep.
    let reaperProjectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-supervisor-reaper-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: reaperProjectRoot) }
    let managedSessionStore = ManagedAgentSessionStore(projectRoot: reaperProjectRoot)
    try managedSessionStore.upsert(ManagedAgentSessionRecord(
        tileId: tileId,
        agentKind: .managed,
        lastSeenAt: .distantPast
    ))
    guard let staleLastSeenAt = try managedSessionStore.load(tileId: tileId)?.lastSeenAt else {
        throw fail("the stale managed-session record did not persist, so the reaper binding is not the production one")
    }
    let tmux = InMemoryTmuxControl()
    let binding = SessionPruner.SessionBinding(
        sessionName: "continuum-agent-supervisor-check",
        tileIds: [tileId],
        lastSeenAt: staleLastSeenAt
    )
    let pruner = SessionPruner(
        tmuxControl: tmux,
        clock: SystemClock(),
        bindingSource: { [binding] in [binding] },
        activitySnapshotSource: { nil }
    )
    await pruner.sweep()
    guard tmux.log.contains(.detachSession(name: binding.sessionName)) else {
        throw fail("the reaper sweep did not fire, so it proves nothing about a detached agent: \(tmux.log)")
    }
    let reaperKills = tmux.log.filter {
        if case .killSession = $0 { return true }
        if case .killWindow = $0 { return true }
        return false
    }
    guard reaperKills.isEmpty else {
        throw fail("the reaper killed something for an idle binding: \(reaperKills)")
    }
    guard supervisor.isRunning(agentId), try store.load(id: agentId) != nil else {
        throw fail("an idle reaper sweep reaped a detached, still-running agent")
    }

    // Re-attach to a DIFFERENT tile: the agent is rebindable after its first view
    // closed, and the replay carries the work it did while unattached.
    let secondTileId = UUID()
    supervisor.attach(agentID: agentId, to: secondTileId)
    let reboundTileId = try store.load(id: agentId)?.tileId
    guard reboundTileId == secondTileId else {
        throw fail("re-attaching did not persist the new tile binding: \(String(describing: reboundTileId))")
    }
    let secondTile = ManagedAgentTileNSView(tile: Tile(
        id: secondTileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    secondTile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    let historyCount = probe.events.count
    secondTile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { secondTile.ingestedEvents.count == historyCount }) else {
        throw fail("a new tile did not replay the surviving agent's history: \(secondTile.ingestedEvents.count) of \(historyCount)")
    }
    guard secondTile.qaTranscriptText.contains("alpha"), secondTile.qaTranscriptText.contains("beta") else {
        throw fail("the re-attached transcript lost the work done before or after the close: \(secondTile.qaTranscriptText)")
    }

    // One tile shows one agent: binding a second agent to that tile unbinds the first.
    let otherAgentId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    supervisor.attach(agentID: otherAgentId, to: secondTileId)
    let claimants = supervisor.records.values.filter { $0.tileId == secondTileId }.map(\.id)
    guard claimants == [otherAgentId] else {
        throw fail("two agents claim tile \(secondTileId): \(claimants.map { $0.rawValue.uuidString })")
    }
    guard try store.load(id: agentId)?.tileId == nil else {
        throw fail("the displaced agent's persisted record still claims the tile it lost")
    }
    guard supervisor.isRunning(agentId) else {
        throw fail("being displaced from a tile stopped the agent")
    }

    // …and stopping IS the thing that ends it — a separate deliberate action, which
    // leaves the record in place (stopped, not deleted).
    supervisor.stop(agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { blocking.completedRuns == 1 }) else {
        throw fail("stop did not make the surviving agent's blocked run() return: completedRuns \(blocking.completedRuns)")
    }
    guard blocking.stopCount == 1, supervisor.isRunning(agentId) == false else {
        throw fail("stop did not reach the runner: stopCount \(blocking.stopCount), isRunning \(supervisor.isRunning(agentId))")
    }
    guard try store.load(id: agentId) != nil else {
        throw fail("stopping an agent deleted its record; stopped is a state, not a removal")
    }
    secondTile.detach()

    // The production branch: it detaches, and it does not stop.
    let branch = try managedAgentCloseBranchSource()
    guard branch.contains("detachView(") else {
        throw fail("deleteTile's .managedAgent branch never detaches the agent's view — a closed tile would leave the agent claiming a tile that no longer exists:\n\(branch)")
    }
    guard branch.contains(".detach()") else {
        throw fail("deleteTile's .managedAgent branch does not detach the tile's own subscription:\n\(branch)")
    }
    // …and it parks. Without this line the branch reverts to what filled the
    // sidebar with unobservable rows: a record with no tile, no runner and no way
    // out of the live list (.plans/05-close-to-history.md).
    guard branch.contains("close(agentID:") else {
        throw fail("deleteTile's .managedAgent branch never parks the agent: a closed tile would leave its record in the live list forever, with no tile to observe it and no section to hold it:\n\(branch)")
    }
    let stopPattern = try NSRegularExpression(pattern: "\\.stop\\s*\\(")
    guard stopPattern.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)) == nil else {
        throw fail("deleteTile's .managedAgent branch stops the agent: closing a tile must not end the work (locked decision); stopping is a deliberate action:\n\(branch)")
    }

    return "a tile closed on an in-flight turn without stopping it (record kept, tileId cleared, events still delivered, an idle sweep could not reach it), the agent re-attached to a new tile and was displaced from it by a second agent, and only stop() ended the turn"
}

/// P2A.6: an agent exists and RUNS with no tile at all.
///
/// The count is DERIVED from `ZoneHydrationBudgetConfig.defaultMaxLiveZones`, not
/// picked: the packet's reason for headless agents is that the hydration budget caps
/// live zones, so this runs two more agents than that budget allows and each one is
/// provably mid-turn at the same time.
///
/// What "no tile exists in `CanvasState`" is asserted as: a real `CanvasState` is
/// carried alongside the supervisor and the invariant NO RECORD CLAIMS A TILE THE
/// CANVAS DOES NOT HAVE is checked both while every agent is headless and after one
/// of them is bound to a tile that IS on the canvas. A headless spawn that quietly
/// invented a `tileId` is red on it. The production palette branch is source-scanned
/// separately (`paletteAgentSpawnBranch`), because the only way a tile reaches
/// `CanvasState` in this app is `TileSpawner`, which needs a live `CanvasNSView` —
/// the same reason `managedAgentCloseBranchSource` below is a scan.
///
/// Negative tests observed red at exit 1 with the final code, production edits except
/// where noted:
/// · `spawnHeadlessAgentFromPalette` calling `spawnSupervisedAgent(tileId: UUID())` →
///   `FAIL: the headless spawn branch does not pass `tileId: nil` …`
/// · `spawnHeadlessAgentFromPalette` calling `spawnManagedAgentFromPalette()` as well →
///   `FAIL: the headless spawn branch reaches the tile spawner …`. This one PASSED
///   against the first draft of `tileMakers` and is why `spawnManagedAgent` is in the
///   pattern: delegating to the managed path creates a tile without naming the spawner.
/// · the `case .newHeadlessAgent:` dispatch deleted from `performPaletteAction` →
///   a compile error (the switch is exhaustive), so the reachability assertion below
///   is about the REGISTRY and the palette rows, which are what ⌘K reads
/// · the `agent.newHeadless` `CanvasCommand` removed →
///   `FAIL: ⌘K cannot reach a headless spawn: no agent.newHeadless in CommandRegistry`
/// · `spawnHeadlessAgentFromPalette` spawning with no prompt (the first draft, which
///   the cross-review caught: a record nothing can reach and nothing running) →
///   `FAIL: the headless spawn branch does not collect and pass a first prompt …`
/// · `spawnSupervisedAgent` passing `prompt: nil` through to the supervisor →
///   `FAIL: the app's spawn helper drops the prompt …`
/// · `applicationWillTerminate` not calling `stopAll` →
///   `FAIL: quitting does not stop the agents …`
/// · `stopAll` iterating no runners (`for id in [] `, check-local mutation) →
///   `FAIL: stopAll did not make the headless agents' blocked run()s return: 0 of 6`
/// · a headless record's `tileId` set by hand to a tile the canvas does not hold
///   (check-local vacuity witness for the invariant) →
///   `FAIL: a record claims tile … which is not on the canvas`
@MainActor
private func checkHeadlessAgents(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let provider = "provider-thread"
    let headlessCount = ZoneHydrationBudgetConfig.defaultMaxLiveZones + 2

    // ⌘K reachability, executed rather than scanned: the palette builds its static
    // rows from `CommandRegistry`, so these two assertions are the whole path from
    // the command id to a row a user can pick.
    guard CommandRegistry.all().contains(where: { $0.id == "agent.newHeadless" && $0.action == .newHeadlessAgent }) else {
        throw fail("⌘K cannot reach a headless spawn: no agent.newHeadless in CommandRegistry: \(CommandRegistry.all().map(\.id))")
    }
    guard LaunchPaletteModel.makeRows(profiles: []).contains(.action(.newHeadlessAgent)) else {
        throw fail("the headless spawn command is not a palette row")
    }

    // Each agent gets its own blocking runner, so "six agents are running at once" is
    // observed on six live turns rather than inferred from six records.
    let scripted = (0 ..< headlessCount).map { _ in
        ScriptedAgentRunner(script: [.turnStarted(threadId: provider, turnId: "t1")], holdUntilStopped: true)
    }
    let queue = ScriptedRunnerQueue(scripted)
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0.record) })

    // A canvas with NO tiles on it, carried through the whole section.
    var canvasState = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [],
        groups: [],
        lastActiveTileId: nil
    )
    func expectNoRecordClaimsAMissingTile(_ stage: String) throws {
        for record in supervisor.records.values {
            guard let claimed = record.tileId else { continue }
            guard canvasState.tiles.contains(where: { $0.id == claimed }) else {
                throw fail("\(stage): a record claims tile \(claimed) which is not on the canvas (\(canvasState.tiles.count) tile(s)) — an agent must not invent a view binding")
            }
        }
    }

    var headless: [AgentID] = []
    var inboxes: [AgentID: EventInbox] = [:]
    var tasks: [Task<Void, Never>] = []
    defer { for task in tasks { task.cancel() } }
    for index in 0 ..< headlessCount {
        // Spawned WITH its first prompt, which is what the ⌘K branch does (a headless
        // agent has no compose row, so the run has to start at spawn) — not
        // spawn-then-send, which would leave "the production path never runs anything"
        // green. Found by the cross-review.
        let id = supervisor.spawn(
            role: nil,
            prompt: "work \(index)",
            cwd: cwd,
            model: config.model,
            thinking: config.thinking
        )
        headless.append(id)
        let inbox = EventInbox()
        inboxes[id] = inbox
        // Attaches after the prompt, so the event is seen through the replay — the
        // headless agent's history exists whether or not anything is listening.
        let stream = supervisor.events(for: id)
        tasks.append(Task { @MainActor in for await event in stream { inbox.append(event) } })
        guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: id) == 1 }) else {
            throw fail("headless agent \(index) has no subscriber")
        }
    }

    // Running, tile-less, and persisted that way.
    for (index, id) in headless.enumerated() {
        guard await waitUntil(timeout: 10, pollInterval: 0.02, { supervisor.isRunning(id) }) else {
            throw fail("headless agent \(index) is not running — a tile-less agent must still run")
        }
        guard supervisor.records[id]?.tileId == nil else {
            throw fail("headless agent \(index) has a tile binding: \(String(describing: supervisor.records[id]?.tileId))")
        }
        guard let persisted = try store.load(id: id) else {
            throw fail("headless agent \(index) was not persisted — it must survive without a tile")
        }
        guard persisted.tileId == nil else {
            throw fail("headless agent \(index) persisted a tile binding: \(String(describing: persisted.tileId))")
        }
        // Events flow with nothing rendering them.
        guard await waitUntil(timeout: 10, pollInterval: 0.02, { inboxes[id]?.events.count == 1 }) else {
            throw fail("headless agent \(index) delivered no events: \(inboxes[id]?.events.count ?? -1)")
        }
        guard inboxes[id]?.events.first == .turnStarted(threadId: AgentSupervisor.threadId(for: id), turnId: "t1") else {
            throw fail("headless agent \(index)'s event arrived wrong: \(String(describing: inboxes[id]?.events.first))")
        }
    }
    guard canvasState.tiles.isEmpty else {
        throw fail("the canvas gained a tile from \(headlessCount) headless spawns: \(canvasState.tiles.count)")
    }
    try expectNoRecordClaimsAMissingTile("all headless")
    guard queue.handedOut.count == headlessCount, scripted.allSatisfy({ $0.runCount == 1 }) else {
        throw fail("not every headless agent got its own runner: \(queue.handedOut.count) handed out, runCounts \(scripted.map(\.runCount))")
    }

    // ATTACH A TILE to one of them (the P2A.4 path): the tile replays the history the
    // agent accumulated while it had no view.
    let subject = headless[0]
    // The queue hands runners out in `send` order, which is the spawn order above, so
    // the first one belongs to `headless[0]` — asserted by the runCount check above.
    let subjectRunner = queue.handedOut[0]
    guard subjectRunner.emit(.contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "headless work")) else {
        throw fail("the subject agent's runner is not in flight, so its history cannot grow before the tile attaches")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { inboxes[subject]?.events.count == 2 }) else {
        throw fail("the headless agent's second event never arrived: \(inboxes[subject]?.events.count ?? -1)")
    }
    let tileId = UUID()
    let tile = Tile(
        id: tileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    )
    canvasState.tiles.append(tile)
    let view = ManagedAgentTileNSView(tile: tile)
    view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    supervisor.attach(agentID: subject, to: tileId)
    view.attach(agentID: subject, supervisor: supervisor)
    let historyCount = inboxes[subject]?.events.count ?? 0
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { view.ingestedEvents.count == historyCount }) else {
        throw fail("attaching a tile to a headless agent did not replay its history: the tile holds \(view.ingestedEvents.count) of \(historyCount)")
    }
    guard view.qaTranscriptText.contains("headless work") else {
        throw fail("the work the agent did while headless did not reach the transcript: \(view.qaTranscriptText)")
    }
    guard try store.load(id: subject)?.tileId == tileId else {
        throw fail("attaching a tile to a headless agent did not persist the binding")
    }
    try expectNoRecordClaimsAMissingTile("one attached")
    guard canvasState.tiles.count == 1, supervisor.records.count >= headlessCount else {
        throw fail("\(supervisor.records.count) agent(s) against \(canvasState.tiles.count) tile(s) — the point of a headless agent is that those two numbers are independent")
    }
    view.detach()

    // STOPPABILITY (the packet's watch-out): a headless agent has no tile to close,
    // so `stopAll` — which the app runs on quit — is the only thing that can reach
    // its process. Asserted on the runners' own post-return counter, so it proves the
    // blocked `run()`s exited rather than that a dictionary was emptied.
    supervisor.stopAll()
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { scripted.allSatisfy { $0.completedRuns == 1 } }) else {
        throw fail("stopAll did not make the headless agents' blocked run()s return: \(scripted.filter { $0.completedRuns == 1 }.count) of \(headlessCount)")
    }
    guard scripted.allSatisfy({ $0.stopCount == 1 }) else {
        throw fail("stopAll did not reach every runner: \(scripted.map(\.stopCount))")
    }
    guard headless.allSatisfy({ supervisor.isRunning($0) == false }) else {
        throw fail("the supervisor still holds a runner after stopAll")
    }
    for (index, id) in headless.enumerated() {
        guard try store.load(id: id) != nil else {
            throw fail("stopAll deleted headless agent \(index)'s record; stopped is a state, not a removal")
        }
    }

    // The production wiring: the palette branch spawns WITHOUT a tile, the managed
    // branch (the vacuity guard for the same patterns) spawns WITH one, and quitting
    // stops the agents.
    let headlessBranch = try paletteAgentSpawnBranch("private func spawnHeadlessAgentFromPalette() {")
    // The ⌘K model step gave this a parameter and a result; the scan string went
    // stale and this leg has been reading as BLIND (a throw) behind the KNOWN-RED
    // naming section ever since. Pinned to the real signature again.
    let managedBranch = try paletteAgentSpawnBranch("private func spawnManagedAgentFromPalette(model: String? = nil) -> Bool {")
    // `spawnManagedAgent` is in the pattern because of the negative test: a headless
    // branch that simply CALLS the managed one creates a tile without naming the
    // spawner, and the first draft of this pattern passed that mutation.
    let tileMakers = try NSRegularExpression(pattern: "tileSpawner|spawner\\.|spawnManagedAgent|wireManagedAgentTile|install\\(tileView")
    func makesATile(_ body: String) -> Bool {
        tileMakers.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
    }
    guard makesATile(managedBranch) else {
        throw fail("the managed spawn branch matches none of the tile-creating patterns, so the check below proves nothing:\n\(managedBranch)")
    }
    guard !makesATile(headlessBranch) else {
        throw fail("the headless spawn branch reaches the tile spawner — a headless agent is one with no tile:\n\(headlessBranch)")
    }
    guard headlessBranch.contains("tileId: nil") else {
        throw fail("the headless spawn branch does not pass `tileId: nil`:\n\(headlessBranch)")
    }
    // …and it must actually RUN. `spawn` only starts a runner for a non-empty prompt,
    // so a branch that spawns with `prompt: nil` would leave a record no surface can
    // reach and nothing running — the done-criterion is "a RUNNING agent with no
    // tile". The cross-review caught exactly that in the first draft.
    guard headlessBranch.contains("promptForAgentTask("), headlessBranch.contains("prompt: prompt") else {
        throw fail("the headless spawn branch does not collect and pass a first prompt, so it spawns an agent that never runs:\n\(headlessBranch)")
    }
    let spawnHelper = try paletteAgentSpawnBranch("private func spawnSupervisedAgent(tileId: UUID?, prompt: String? = nil, launchSelection: AgentLaunchSelection? = nil) -> AgentID? {")
    guard spawnHelper.contains("prompt: prompt") else {
        throw fail("the app's spawn helper drops the prompt, so the headless agent would not run:\n\(spawnHelper)")
    }
    let terminate = try paletteAgentSpawnBranch("func applicationWillTerminate(_ notification: Notification) {")
    guard terminate.contains("stopAll()") else {
        throw fail("quitting does not stop the agents, so a headless agent's process outlives the session:\n\(terminate)")
    }

    return "\(headlessCount) agents ran concurrently with no tile (two past the \(ZoneHydrationBudgetConfig.defaultMaxLiveZones)-zone hydration budget), each persisted with tileId nil and delivering events, one then took a tile and replayed the work it did headless, and stopAll made every blocked run() return"
}

/// A runner factory that records the `cwd` of every record it is handed. The record
/// is what `AgentSupervisor.piRunner(for:)` reads to build `PiAgentRunner.Config`, so
/// this is the working directory the real provider process would start in.
@MainActor
private final class SpawningCwdRecorder {
    private(set) var cwds: [String] = []
    private let runner: ScriptedAgentRunner

    init(_ runner: ScriptedAgentRunner) { self.runner = runner }

    func make(_ record: AgentRecord) -> AgentRunning {
        cwds.append(record.cwd)
        return runner
    }
}

/// A runner that replays P2D.1's REAL captured Pi stream through a REAL
/// `PiEventTranslator`, forwarding both halves: the normalized events to `onEvent`,
/// and the `spawn_agent` arguments to the side channel. So what MARK 13 drives is the
/// production reading path (fixture line → translator → runner seam → supervisor), not
/// a hand-made `SpawnRequest`.
final class FixtureStreamRunner: AgentRunning, @unchecked Sendable {
    private let lines: [String]
    private let lock = NSLock()
    private var spawnHandler: (@Sendable (SpawnRequest) -> Void)?
    private var runtimeObservationHandler: (@Sendable (AgentRuntimeObservation) -> Void)?
    private var observedRunHandler: (@Sendable (ObservedRunHandle) -> Void)?
    private var promptsStorage: [String] = []
    private var agentPromptsStorage: [AgentPrompt] = []

    init(lines: [String]) { self.lines = lines }

    var prompts: [String] { lock.withLock { promptsStorage } }
    var agentPrompts: [AgentPrompt] { lock.withLock { agentPromptsStorage } }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        lock.withLock {
            promptsStorage.append(prompt.text)
            agentPromptsStorage.append(prompt)
        }
        var translator = PiEventTranslator()
        if let handler = lock.withLock({ spawnHandler }) {
            translator.onSpawnRequest = handler
        }
        if let handler = lock.withLock({ runtimeObservationHandler }) {
            translator.onRuntimeObservation = handler
        }
        if let handler = lock.withLock({ observedRunHandler }) {
            translator.onObservedRun = handler
        }
        for line in lines {
            for event in translator.translate(line: line) { onEvent(event) }
        }
    }

    func stop() {}

    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        lock.withLock { spawnHandler = handler }
    }

    func observeRuntimeObservations(
        _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void
    ) {
        lock.withLock { runtimeObservationHandler = handler }
    }
}

/// The fixture runner reports observed runs too, so the supervisor's
/// `runner as? ObservedRunReporting` wiring is exercised by the real production
/// path rather than bypassed by a check that calls `bindObservedRun` itself.
extension FixtureStreamRunner: ObservedRunReporting {
    func observeObservedRuns(_ handler: @escaping @Sendable (ObservedRunHandle) -> Void) {
        lock.withLock { observedRunHandler = handler }
    }
}

/// Offline Codex app-server double for the supervisor seam. Announcements are
/// emitted first so the check can subscribe to the adopted descendants; their
/// transcript frames wait behind `releaseDescendantEvents()`.
private final class ProviderSubagentFixtureRunner:
    AgentRunning, ProviderSubagentActivityObserving, @unchecked Sendable
{
    private let lock = NSLock()
    private let descendantGate = DispatchSemaphore(value: 0)
    private var activityHandler: (@Sendable (ProviderSubagentActivity) -> Void)?

    func observeProviderSubagentActivity(
        _ handler: @escaping @Sendable (ProviderSubagentActivity) -> Void
    ) {
        lock.withLock { activityHandler = handler }
    }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        guard let activity = lock.withLock({ activityHandler }) else { return }
        let parent = "codex-provider-parent"
        let child = "codex-provider-child"
        let grandchild = "codex-provider-grandchild"
        activity(.primaryThread(providerThreadID: parent))
        activity(.childAnnounced(
            parentProviderThreadID: parent, childProviderThreadID: child,
            sourceItemID: "codex-child-call", displayLabel: "Scout"))
        activity(.childAnnounced(
            parentProviderThreadID: child, childProviderThreadID: grandchild,
            sourceItemID: "codex-grandchild-call", displayLabel: "Verifier"))
        // Positive control: Codex can close the parent before its provider-owned
        // descendants drain. The runner itself remains bound while those late
        // child frames arrive; a generic parent-completion closure would truncate
        // both child transcripts.
        onEvent(.turnCompleted(
            threadId: parent, turnId: "codex-parent-turn",
            outcome: .completed, errorMessage: nil))
        guard descendantGate.wait(timeout: .now() + 10) == .success else { return }
        activity(.threadEvent(providerThreadID: child, event: .turnStarted(
            threadId: child, turnId: "codex-child-turn")))
        activity(.threadEvent(providerThreadID: child, event: .contentDelta(
            threadId: child, turnId: "codex-child-turn",
            streamKind: .assistant, delta: "child routed")))
        activity(.threadEvent(providerThreadID: grandchild, event: .turnStarted(
            threadId: grandchild, turnId: "codex-grandchild-turn")))
        activity(.threadEvent(providerThreadID: grandchild, event: .contentDelta(
            threadId: grandchild, turnId: "codex-grandchild-turn",
            streamKind: .assistant, delta: "grandchild routed")))
        activity(.threadEvent(providerThreadID: grandchild, event: .turnCompleted(
            threadId: grandchild, turnId: "codex-grandchild-turn",
            outcome: .completed, errorMessage: nil)))
        activity(.threadEvent(providerThreadID: child, event: .turnCompleted(
            threadId: child, turnId: "codex-child-turn",
            outcome: .completed, errorMessage: nil)))
    }

    func stop() { descendantGate.signal() }
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(
        _ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void
    ) {}
    func releaseDescendantEvents() { descendantGate.signal() }
}

@MainActor
private func checkCodexProviderSubagentRouting(
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-codex-subagent-routing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = ProviderSubagentFixtureRunner()
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root),
        makeRunner: { _ in runner })
    let config = AgentModelConfig.resolvedFromDefaults(harness: .codex)
    let parentID = supervisor.spawn(
        role: nil, prompt: nil,
        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        harness: .codex, model: config.model, thinking: config.thinking)
    let parentInbox = EventInbox()
    let parentTask = Task { @MainActor in
        for await event in supervisor.events(for: parentID) { parentInbox.append(event) }
    }
    defer { parentTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: parentID) == 1
    }) else { throw fail("Codex routing: the parent subscriber never registered") }

    supervisor.send("delegate twice", to: parentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        guard let child = supervisor.children(of: parentID).first else { return false }
        return supervisor.children(of: child).count == 1
    }) else {
        throw fail("Codex routing: structured announcements did not create a nested child and grandchild")
    }
    guard let childID = supervisor.children(of: parentID).first,
          let grandchildID = supervisor.children(of: childID).first,
          let childRecord = supervisor.records[childID],
          let grandchildRecord = supervisor.records[grandchildID]
    else { throw fail("Codex routing: adopted descendant records disappeared") }
    guard childRecord.capabilities == .observedReadOnly,
          grandchildRecord.capabilities == .observedReadOnly,
          childRecord.harness == .codex,
          grandchildRecord.harness == .codex else {
        throw fail("Codex routing: provider-owned descendants must remain read-only Codex records")
    }

    let childInbox = EventInbox()
    let grandchildInbox = EventInbox()
    let childTask = Task { @MainActor in
        for await event in supervisor.events(for: childID) { childInbox.append(event) }
    }
    let grandchildTask = Task { @MainActor in
        for await event in supervisor.events(for: grandchildID) { grandchildInbox.append(event) }
    }
    defer { childTask.cancel(); grandchildTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: childID) == 1
            && supervisor.subscriberCount(for: grandchildID) == 1
    }) else { throw fail("Codex routing: descendant subscribers never registered") }

    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        parentInbox.events.contains { if case .turnCompleted = $0 { return true }; return false }
    }) else {
        throw fail("Codex routing: the parent did not complete before descendant release, so the late-child positive control is vacuous")
    }
    runner.releaseDescendantEvents()
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        childInbox.events.contains {
            if case .contentDelta(_, _, _, "child routed") = $0 { return true }
            return false
        } && grandchildInbox.events.contains {
            if case .contentDelta(_, _, _, "grandchild routed") = $0 { return true }
            return false
        }
    }) else {
        throw fail("Codex routing: provider thread events did not reach their own descendant transcripts")
    }
    guard !parentInbox.events.contains(where: {
        if case .contentDelta(_, _, _, let delta) = $0 {
            return delta == "child routed" || delta == "grandchild routed"
        }
        return false
    }) else { throw fail("Codex routing: descendant content leaked into the parent transcript") }

    return "structured Codex provider activity adopted one read-only child plus a nested grandchild and routed each provider thread only to its own transcript"
}

/// A runner factory that hands a distinct runner to each agent and remembers which
/// record it was built for, so a child's own prompt and working directory can be read
/// back. The parent's runner is supplied; everybody else gets a fresh scripted one.
@MainActor
private final class SpawnedRunnerFactory {
    private(set) var records: [AgentRecord] = []
    private(set) var runners: [AgentID: ScriptedAgentRunner] = [:]
    private let parent: (id: AgentID, runner: AgentRunning)?

    init(parent: (id: AgentID, runner: AgentRunning)? = nil) { self.parent = parent }

    func make(_ record: AgentRecord) -> AgentRunning {
        records.append(record)
        if let parent, parent.id == record.id { return parent.runner }
        if let existing = runners[record.id] { return existing }
        let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
        runners[record.id] = runner
        return runner
    }
}

/// T7 — a refused spawn says something actionable, and leaves nothing behind.
///
/// Observed live 2026-08-25 on a scratch project with no `.pi/agents` directory:
/// the model was offered `spawn_agent` (a roleless pi agent sends no `--tools`, so
/// pi permits every tool), called it with a role it invented, and got
/// "spawn_agent refused: the requested role is not defined in this project" —
/// which reads as a typo when the truth is the project has no roles at all.
///
/// The second assertion is the one Dylan's question was really about: a refusal
/// must mint NO record, NO chip and therefore NO openable tile. A refusal that
/// left a half-built child would be worse than the dead end it replaced.
@MainActor
private func checkRefusedSpawnIsActionableAndLeavesNothing(
    fail: (String) -> Error
) async throws -> String {
    let config = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-refusal-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Deliberately NO .pi/agents directory — the live condition.
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let store = AgentStore(applicationSupportDirectory: root)
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in
        ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
    }, warn: { _ in })
    let parentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: config.model, thinking: config.thinking)

    let inbox = EventInbox()
    let stream = supervisor.events(for: parentId)
    let task = Task { @MainActor in for await e in stream { inbox.append(e) } }
    defer { task.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: parentId) == 1
    }) else {
        throw fail("T7: the parent's subscriber never registered")
    }

    // The real production dispatch, with a role the project cannot define.
    let refused = supervisor.handleSpawnRequest(
        SpawnRequest(role: "researcher", prompt: "look it up", isolated: false),
        from: parentId)
    guard refused == nil else {
        throw fail("T7: a role in a project with no roles was not refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        inbox.events.contains { "\($0)".contains("refused") }
    }) else {
        throw fail("T7: the refusal was never said in the parent's transcript")
    }
    let said = inbox.events.map { "\($0)" }.joined(separator: "\n")
    guard said.contains(RoleRegistry.directoryName(for: .pi)) else {
        throw fail("T7: the refusal did not name the directory a role would go in, so it is not actionable: \(said)")
    }
    // And it still must not echo the requested role — the P2D.2 witness holds that
    // out of every event on the parent's stream and this reason would be the hole.
    guard !said.contains("researcher") else {
        throw fail("T7: the refusal echoed the requested role id onto the parent's stream")
    }
    // THE second half: nothing was created. No record, so no chip and no tile.
    guard supervisor.children(of: parentId).isEmpty else {
        throw fail("T7: a REFUSED spawn left \(supervisor.children(of: parentId).count) child record(s) behind — an openable tile for an agent that never existed")
    }
    guard !said.contains("childAgentSpawned") else {
        throw fail("T7: a refused spawn announced a child, which mints a chip for an agent that does not exist")
    }

    // A role that IS defined still spawns, so the new guard is not a blanket refusal.
    let rolesDir = cwd.appendingPathComponent(RoleRegistry.directoryName(for: .pi), isDirectory: true)
    try FileManager.default.createDirectory(at: rolesDir, withIntermediateDirectories: true)
    try "---\nname: researcher\ndescription: Looks things up.\ntools: read, grep\n---\nLook things up.\n"
        .write(to: rolesDir.appendingPathComponent("researcher.md"), atomically: true, encoding: .utf8)
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: "researcher", prompt: "look it up", isolated: false),
        from: parentId) != nil
    else {
        throw fail("T7: a role the project DOES define was refused — the guard is too broad")
    }

    return "a spawn naming a role in a project with no roles refuses with the directory to add one to, without echoing the role, and leaves no record, no chip and no tile; a defined role still spawns"
}

/// T6 — a pi `delegate_agent` child gets a tile, a transcript, and an honest end.
///
/// Driven entirely through production: a real `AgentSupervisor`, the real
/// `PiEventTranslator` inside a runner, the real `runner as? ObservedRunReporting`
/// wiring, the real `RunArtifactsWatcher`, and the real `restore()`. Nothing here
/// calls `bindObservedRun` or `ingestObservedRunUpdate` directly — a check that
/// did would pass on a supervisor that never subscribed, which is precisely the
/// defect being fixed (the subscription used to be `runner as? ClaudeAgentRunner`,
/// so it was unreachable for pi).
///
/// Six properties:
///   1. The parent's `delegate_agent` call mints exactly ONE child, read-only,
///      keyed on the tool call id — and the child's `task` reaches no event.
///   2. The child's own work, read from its run directory, lands on the CHILD.
///   3. Appending more lines delivers only the new ones — no re-delivery.
///   4. The completion REWRITE (temp-file + rename, which also changes the inode)
///      closes the run instead of being read as new content.
///   5. A relaunch over the same store adds no children and replays no events,
///      and says out loud that the run died with the previous session.
///   6. A run still marked `running` with a dead pid is treated as finished, not
///      waited on forever.
@MainActor
private func checkPiDelegatedRunTailing(
    fail: (String) -> Error
) async throws -> String {
    // A pi-owned model: the harness gate in `send` refuses anything else, and the
    // suite's shared `config` is claude's.
    let config = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-pi-delegate-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

    func fixture(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures/\(name)", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw fail("T6: missing fixture \(name) at \(url.path)")
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
    let parentLines = try fixture("pi-delegate-agent-turn.jsonl")
    let childLines = try fixture("pi-delegate-run-events.jsonl")
    let runId = "code-scout-20260825T141759Z-a23808"
    let taskText = "Survey the recipe column helpers and report what they share."

    let runDir = cwd.appendingPathComponent(".pi/agent-runs/\(runId)", isDirectory: true)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    let eventsURL = runDir.appendingPathComponent("events.jsonl", isDirectory: false)
    let runJSONURL = runDir.appendingPathComponent("run.json", isDirectory: false)
    // Only the first half is on disk when the parent's call is observed — the child
    // is still working.
    let firstHalf = Array(childLines.prefix(9))
    try (firstHalf.joined(separator: "\n") + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)
    // Real appends while the run is live, matching what the extension actually
    // does: it keeps one file descriptor open and writes to it, so the file's
    // inode does NOT change until the completion rewrite (MARK 4). Using
    // `write(atomically:true)` here instead — a temp-file + rename every
    // "append" — would change the inode on every call, which is not what a
    // live run does and would make every one of these writes look like the
    // completion rewrite to the A fix under test.
    func appendToEvents(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    // A live pid so the run is not read as already finished. Our own pid is alive
    // by construction, which beats inventing one that might be recycled.
    let livePid = ProcessInfo.processInfo.processIdentifier
    func writeRunJSON(status: String, pid: Int32) throws {
        try #"{"id":"\#(runId)","role":"code-scout","status":"\#(status)","pid":\#(pid)}"#
            .write(to: runJSONURL, atomically: true, encoding: .utf8)
    }
    try writeRunJSON(status: "running", pid: livePid)

    let store = AgentStore(applicationSupportDirectory: root)
    let delegateWarnings = NSMutableArray()
    let parentRunner = FixtureStreamRunner(lines: parentLines)
    var supervisor: AgentSupervisor! = AgentSupervisor(
        store: store,
        makeRunner: { launch -> AgentRunning in
            launch.record.parentAgentID == nil
                ? parentRunner
                : ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
        },
        warn: { delegateWarnings.add($0) })
    // Spawned WITHOUT a prompt so the id exists before the runner is needed, and
    // so the subscriber is attached before the fixture stream replays — the
    // fixture runner emits its whole stream synchronously inside `run`.
    let parentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: config.model, thinking: config.thinking)

    // MARK: 1 · one observed child, and the task body stays out of the events

    let parentInbox = EventInbox()
    let parentStream = supervisor.events(for: parentId)
    let parentTask = Task { @MainActor in for await e in parentStream { parentInbox.append(e) } }
    defer { parentTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: parentId) == 1
    }) else {
        throw fail("T6: the parent's subscriber never registered")
    }
    supervisor.send("delegate the survey", to: parentId)

    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        supervisor.records.values.contains { $0.parentAgentID == parentId }
    }) else {
        throw fail("T6: the delegate_agent call produced no child at all; records \(supervisor.records.count); warnings \(delegateWarnings); parent events \(parentInbox.events.map { "\($0)" }.prefix(20))")
    }
    let children = supervisor.records.values.filter { $0.parentAgentID == parentId }
    guard children.count == 1, let child = children.first else {
        throw fail("T6: expected one delegated child, got \(children.count)")
    }
    guard child.capabilities == AgentCapabilities.observedReadOnly else {
        throw fail("T6: a delegated child must be observedReadOnly — Array does not run it; got \(child.capabilities)")
    }
    let expectedChildID = AgentID(rawValue: AgentRecord.observedChildID(
        parentAgentID: parentId.rawValue, toolUseID: "call_fixture_delegate_1"))
    guard child.id == expectedChildID else {
        throw fail("T6: the child is not keyed on its tool call id, so re-observation would mint a duplicate")
    }
    for event in parentInbox.events {
        guard !"\(event)".contains(taskText) else {
            throw fail("T6: the child's task body crossed the parent's event boundary: \(event)")
        }
    }

    // MARK: 2 · the child's own work arrives on the child

    let childInbox = EventInbox()
    let childStream = supervisor.events(for: child.id)
    let childTask = Task { @MainActor in for await e in childStream { childInbox.append(e) } }
    defer { childTask.cancel() }

    func childText() -> String { childInbox.events.map { "\($0)" }.joined(separator: "\n") }
    guard await waitUntil(timeout: 15, pollInterval: 0.05, {
        childText().contains("grep") || childText().contains("read")
    }) else {
        throw fail("T6: the delegated child received none of its own work — the run was never tailed")
    }
    let afterFirstHalf = childInbox.events.count

    // MARK: 3 · appending delivers only what is new

    let secondHalf = Array(childLines.dropFirst(firstHalf.count))
    try appendToEvents(secondHalf.joined(separator: "\n") + "\n")
    guard await waitUntil(timeout: 15, pollInterval: 0.05, {
        childText().contains("shared descriptor")
    }) else {
        throw fail("T6: the child's completed prose never arrived — a finished run keeps its text only in message_end")
    }
    let readCount = childInbox.events.filter { "\($0)".contains("grep") }.count
    guard readCount <= 1 else {
        throw fail("T6: the child's grep call was delivered \(readCount) times — the cursor re-read consumed lines")
    }
    guard childInbox.events.count > afterFirstHalf else {
        throw fail("T6: appending to the run delivered nothing")
    }

    // MARK: 4 · the completion rewrite closes the run rather than replaying it
    //
    // This is deliberately the case a size/line-count comparison gets WRONG,
    // not the easy one: `secondHalf` above already brought `consumedEventCount`
    // up to the full 16 lines of `childLines`. A rewritten file that is
    // SHORTER than 16 is caught by a naive shrink check too — that was the
    // pre-existing (and passing) coverage. A rewritten file with MORE than 16
    // lines is the one a shrink check misses entirely: `newCount(20) is not <
    // consumedCount(16)`, so the old logic fell straight into the "grew, so
    // it's new content" branch and delivered `events[16..<20]` of the REWRITTEN
    // file — content that has nothing to do with what actually came after line
    // 16 of the ORIGINAL file, because there is no "after line 16" continuity
    // across a rename. Every line below is a distinct, checkable marker for
    // exactly that reason: if any of it reaches the child, the cursor treated
    // the new file as a continuation of the old one instead of noticing the
    // file itself changed.
    let poisonedRewrite = (0..<20).map {
        #"{"ts":"2026-08-25T14:19:00.000Z","type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"POISON-\#($0)"}]}}"#
    }.joined(separator: "\n") + "\n"
    try poisonedRewrite.write(to: eventsURL, atomically: true, encoding: .utf8)
    try writeRunJSON(status: "done", pid: livePid)
    let settled = childInbox.events.count
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    guard childInbox.events.count == settled else {
        throw fail("T6: the compaction rewrite was read as new content and replayed \(childInbox.events.count - settled) events")
    }
    guard !childText().contains("POISON-") else {
        throw fail("T6: a rewritten file LONGER than the consumed cursor (20 lines vs. 16 already read) was sliced as if it continued the old file — the child received content from the wrong file: \(childText())")
    }

    // MARK: 5 · a relaunch adds nothing and says the run is over

    supervisor = nil
    let relaunched = AgentSupervisor(store: store, makeRunner: { _ in
        ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
    }, warn: { _ in })
    let relaunchInbox = EventInbox()
    _ = relaunched.restore()
    guard relaunched.records.values.filter({ $0.parentAgentID == parentId }).count == 1 else {
        throw fail("T6: the relaunch minted a duplicate child — identity is not stable across a restart")
    }
    let relaunchedChildStream = relaunched.events(for: child.id)
    let relaunchTask = Task { @MainActor in
        for await e in relaunchedChildStream { relaunchInbox.append(e) }
    }
    defer { relaunchTask.cancel() }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    // The cursor is deliberately not persisted, so a relaunch must NOT re-read the
    // file: the child's events were already written to its transcript when they
    // were delivered, and replaying would duplicate a transcript.
    guard !relaunchInbox.events.contains(where: { "\($0)".contains("shared descriptor") }) else {
        throw fail("T6: the relaunch replayed the child's run and duplicated its transcript")
    }

    // MARK: 6 · a stale `running` is finished, not waited on

    // Array's own parent pi process writes these files, so a `running` status that
    // survives a restart is stale by construction. A dead pid must read as over.
    let stale = RunArtifact(
        id: runId, role: "code-scout", status: .running, task: nil, cwd: nil,
        createdAt: nil, updatedAt: nil, pid: 999_999_999, rawJSON: nil)
    guard stale.isFinished(isProcessAlive: { _ in false }) else {
        throw fail("T6: a `running` run with a dead pid was treated as live — Array would wait for a child that died with the last session")
    }
    let live = RunArtifact(
        id: runId, role: "code-scout", status: .running, task: nil, cwd: nil,
        createdAt: nil, updatedAt: nil, pid: 4242, rawJSON: nil)
    guard !live.isFinished(isProcessAlive: { _ in true }) else {
        throw fail("T6: a genuinely running run was treated as finished, which would stop tailing a live child")
    }

    return "one pi delegate_agent call became one read-only child keyed on its tool call id, its run was tailed into the child's own transcript without re-delivery, a completion rewrite closed it instead of replaying it, a relaunch added no child and no duplicate events, and a stale running status with a dead pid reads as over"
}

/// A completion compaction can be the watcher's first view of a Pi run. No
/// append-only snapshot has then carried `agent_settled`, so the terminal
/// `run.json` must close the mirrored child before the binding is discarded.
@MainActor
private func checkObservedRunRewriteBeforeInitialAppend(
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-pi-rewrite-first-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures/pi-delegate-agent-turn.jsonl")
    guard let fixture = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
        throw fail("T6 rewrite-first: missing parent fixture")
    }
    let runId = "code-scout-20260825T141759Z-a23808"
    let runDir = cwd.appendingPathComponent(".pi/agent-runs/\(runId)", isDirectory: true)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    let eventsURL = runDir.appendingPathComponent("events.jsonl")
    let runURL = runDir.appendingPathComponent("run.json")
    try "".write(to: eventsURL, atomically: true, encoding: .utf8)
    try #"{"id":"code-scout-20260825T141759Z-a23808","status":"running","pid":1}"#
        .write(to: runURL, atomically: true, encoding: .utf8)

    let runner = FixtureStreamRunner(lines: fixture.split(separator: "\n").map(String.init))
    let config = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root),
        makeRunner: { launch -> AgentRunning in
            if launch.record.parentAgentID == nil { return runner }
            return ScriptedAgentRunner(script: [])
        }, warn: { _ in })
    let parent = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: config.model, thinking: config.thinking)
    guard supervisor.send("delegate", to: parent) else {
        throw fail("T6 rewrite-first: parent send was refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.01, {
        supervisor.children(of: parent).count == 1 && supervisor.observedRunBindingCount == 1
    }), let child = supervisor.children(of: parent).first else {
        throw fail("T6 rewrite-first: child and binding were not established before compaction")
    }
    let inbox = EventInbox()
    let task = Task { @MainActor in
        for await event in supervisor.events(for: child) { inbox.append(event) }
    }
    defer { task.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.01, {
        supervisor.subscriberCount(for: child) == 1
    }) else { throw fail("T6 rewrite-first: child subscriber did not attach") }

    // Atomic write changes inode before the watcher has consumed any append-only
    // lifecycle. `run.json` is already terminal in that same snapshot.
    try (#"{"ts":"done","type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"compacted final"}]}}"# + "\n")
        .write(to: eventsURL, atomically: true, encoding: .utf8)
    try #"{"id":"code-scout-20260825T141759Z-a23808","status":"done","pid":1}"#
        .write(to: runURL, atomically: true, encoding: .utf8)

    guard await waitUntil(timeout: 10, pollInterval: 0.05, {
        supervisor.observedRunBindingCount == 0
    }) else { throw fail("T6 rewrite-first: terminal rewrite did not release the binding") }
    let terminal = inbox.events.compactMap { event -> TurnOutcome? in
        if case let .turnCompleted(_, _, outcome, _) = event { return outcome }
        return nil
    }
    guard terminal == [.completed],
          supervisor.turnSnapshot(for: child)?.state != .working else {
        throw fail("T6 rewrite-first: terminal rewrite owed exactly one completed child boundary, got \(terminal)")
    }
    return "a terminal Pi inode rewrite seen before any append snapshot delivered one completion before releasing its binding"
}

/// T6-C — provider-owned children remain visible past Array's former breadth cap.
///
/// Claude `Agent` and Pi `delegate_agent` children already exist when Array sees
/// them. Refusing the fifth record never prevented work; it only hid the running
/// child and stranded its transcript. Drive the production adoption entry point
/// through the exact old boundary and assert every child is retained.
@MainActor
private func checkObservedChildrenPastFormerCapStayVisible(
    fail: (String) -> Error
) async throws -> String {
    let config = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let settingsSuite = "continuum-agent-spawn-limit-check-\(UUID().uuidString)"
    guard let limitDefaults = UserDefaults(suiteName: settingsSuite) else {
        throw fail("T6-C: could not create isolated defaults for the agent-limit setting")
    }
    defer { UserDefaults.standard.removePersistentDomain(forName: settingsSuite) }
    guard AgentSpawnLimitConfig.maximumActiveChildren(defaults: limitDefaults) == nil else {
        throw fail("T6-C: the shipped active-child default is not Unlimited")
    }
    limitDefaults.set(7, forKey: AgentSpawnLimitConfig.maximumActiveChildrenKey)
    guard AgentSpawnLimitConfig.maximumActiveChildren(defaults: limitDefaults) == 7 else {
        throw fail("T6-C: the configured active-child limit did not resolve")
    }
    limitDefaults.set(0, forKey: AgentSpawnLimitConfig.maximumActiveChildrenKey)
    guard AgentSpawnLimitConfig.maximumActiveChildren(defaults: limitDefaults) == nil else {
        throw fail("T6-C: zero did not resolve back to Unlimited")
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-observed-cap-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let store = AgentStore(applicationSupportDirectory: root)

    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { _ in ScriptedAgentRunner(script: [.sessionStateChanged(.ready)]) },
        warn: { _ in })
    let parentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: config.model, thinking: config.thinking)

    for i in 0...AgentSupervisor.formerChildrenPerParentCap {
        guard supervisor.handleSpawnRequest(
            SpawnRequest(role: nil, prompt: "observed child \(i)", isolated: false,
                         sourceItemID: "cap-fill-\(i)", observedOnly: true),
            from: parentId) != nil
        else {
            throw fail("T6-C: provider-owned child \(i + 1) was hidden at Array's former cap")
        }
    }
    let expected = AgentSupervisor.formerChildrenPerParentCap + 1
    guard supervisor.children(of: parentId).count == expected,
          supervisor.children(of: parentId).allSatisfy({
              supervisor.records[$0]?.capabilities == .observedReadOnly
          }) else {
        throw fail("T6-C: expected all \(expected) provider-owned children past the old boundary, got \(supervisor.children(of: parentId).count)")
    }

    // An explicit managed-process limit counts only turns that are actually
    // running. A completed/stopped durable child must release its slot.
    let managedStore = AgentStore(applicationSupportDirectory: root.appendingPathComponent("managed", isDirectory: true))
    let managed = AgentSupervisor(
        store: managedStore,
        makeRunner: { _ in ScriptedAgentRunner(
            script: [.turnStarted(threadId: "managed-cap", turnId: UUID().uuidString)],
            holdUntilStopped: true)
        },
        warn: { _ in },
        maximumActiveManagedChildren: { 1 })
    let managedParent = managed.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: config.model, thinking: config.thinking)
    guard let firstManaged = managed.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "first active child", isolated: false),
        from: managedParent) else {
        throw fail("T6-C: configured managed cap refused its first active child")
    }
    guard managed.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "second concurrent child", isolated: false),
        from: managedParent) == nil else {
        throw fail("T6-C: configured active-child limit did not constrain concurrent Array-managed work")
    }
    managed.stop(firstManaged)
    guard managed.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "replacement after stop", isolated: false),
        from: managedParent) != nil else {
        throw fail("T6-C: a stopped durable child kept consuming the active-child slot")
    }

    return "\(expected) provider-owned children crossed Array's former four-child boundary, while an explicit managed limit counted only active turns and released a stopped child's slot"
}

@MainActor
func runAgentSpawnLimitChecks() async throws {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    let report = try await checkObservedChildrenPastFormerCapStayVisible {
        CheckError(description: $0)
    }
    print("AgentSpawnLimit: \(report)")
}

/// T6-D — a parent's watcher is scoped to that parent's own bindings, and a
/// binding survives the window before its child is adopted.
///
/// `tool_execution_end` (which reports the run and drives `bindObservedRun`)
/// can arrive before the main-actor hop that adopts the child from
/// `tool_execution_start` has run — the exact scenario `bindObservedRun`'s own
/// comment names. Before this fix, `refreshObservedRunWatchers`' "mine" filter
/// asked `records[binding.childID]?.parentAgentID == parent`, which read nil
/// (child not adopted yet) as "not mine" and tore the parent's only watcher
/// down out from under a binding that was very much still open — so once the
/// child WAS finally adopted, nothing was left running to tail its run.
///
/// Reproduced by binding the run through ONLY a `tool_execution_end` line —
/// leaving the child permanently un-adopted for now — then letting the
/// watcher run at least one full debounce+refresh cycle (so
/// `refreshObservedRunWatchers` actually evaluates "mine" while the child
/// genuinely does not exist), and only THEN adopting the child, via the same
/// `handleSpawnRequest` entry point `tool_execution_start` would have driven.
/// A version gated on the two lines' ORDER in one synchronous fixture stream
/// is not enough: both translator lines process microseconds apart, long
/// before the watcher's 0.5s debounce ever fires a refresh, so the race
/// window that actually matters is against the watcher's cadence, not against
/// `tool_execution_start`.
@MainActor
private func checkObservedRunBindingSurvivesAdoptionRace(
    fail: (String) -> Error
) async throws -> String {
    let config = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-observed-race-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let runId = "race-run-000"
    let toolUseID = "call_race_1"
    let runDir = cwd.appendingPathComponent(".pi/agent-runs/\(runId)", isDirectory: true)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    let eventsURL = runDir.appendingPathComponent("events.jsonl", isDirectory: false)
    let runJSONURL = runDir.appendingPathComponent("run.json", isDirectory: false)
    // The trailing "\n" matters: a real pi run only ever has a trailing newline
    // missing on a line still being WRITTEN, and the byte-cursor tail reader
    // deliberately withholds an unterminated trailing line rather than risk
    // reading a half-written one (see `RunArtifactsReader.tailEventsJSONL`). A
    // line with no newline at all reads as "still being written" — correct for
    // production, but it means this fixture must not omit it.
    try ([
        #"{"ts":"0","type":"agent_start","agentId":"race-child"}"#,
        #"{"ts":"1","type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"first line on disk before either half of the tool call is processed"}]}}"#
    ].joined(separator: "\n") + "\n")
        .write(to: eventsURL, atomically: true, encoding: .utf8)
    let livePid = ProcessInfo.processInfo.processIdentifier
    try #"{"id":"\#(runId)","role":"code-scout","status":"running","pid":\#(livePid)}"#
        .write(to: runJSONURL, atomically: true, encoding: .utf8)

    // ONLY `tool_execution_end` — reports the run and calls `bindObservedRun`.
    // Nothing in this stream ever adopts the child; that is done by hand,
    // later, once the watcher has had a full cycle to run with no child to find.
    let raceRunner = FixtureStreamRunner(lines: [
        #"{"type":"tool_execution_end","toolCallId":"\#(toolUseID)","toolName":"delegate_agent","result":{"details":{"runId":"\#(runId)"}}}"#
    ])
    let store = AgentStore(applicationSupportDirectory: root)
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { launch -> AgentRunning in
            launch.record.parentAgentID == nil
                ? raceRunner
                : ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
        },
        warn: { _ in })
    let parentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: config.model, thinking: config.thinking)

    let parentInbox = EventInbox()
    let parentStream = supervisor.events(for: parentId)
    let parentTask = Task { @MainActor in for await e in parentStream { parentInbox.append(e) } }
    defer { parentTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: parentId) == 1
    }) else {
        throw fail("T6-D: the parent's subscriber never registered")
    }
    supervisor.send("delegate with a not-yet-adopted child", to: parentId)

    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.observedRunBindingCount == 1
    }) else {
        throw fail("T6-D: the run was never bound at all")
    }
    guard !supervisor.records.values.contains(where: { $0.parentAgentID == parentId }) else {
        throw fail("T6-D: the child was adopted before this test could create the race window — nothing in the fixture stream should have adopted it yet")
    }

    // Let the watcher run at least one full debounce (default 0.5s) + refresh
    // cycle with the child genuinely absent — this is the window
    // `refreshObservedRunWatchers` used to mis-evaluate as "not mine".
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    guard supervisor.observedRunBindingCount == 1 else {
        throw fail("T6-D: the binding did not survive the window before adoption — \(supervisor.observedRunBindingCount) binding(s) remain instead of 1, so the parent's watcher was torn down while the child did not exist yet")
    }

    // NOW adopt the child — the real entry point `tool_execution_start` drives.
    guard let child = supervisor.handleSpawnRequest(
        SpawnRequest(role: "code-scout", prompt: "race test", isolated: false,
                     sourceItemID: toolUseID, observedOnly: true),
        from: parentId).map({ id in supervisor.records[id] }) ?? nil
    else {
        throw fail("T6-D: adopting the child (after the race window) was refused")
    }
    guard supervisor.observedRunBindingCount == 1 else {
        throw fail("T6-D: the binding did not survive adoption itself — \(supervisor.observedRunBindingCount) binding(s) remain instead of 1")
    }
    guard child.providerSessionId == runId,
          (try? store.load(id: child.id))?.providerSessionId == runId else {
        throw fail("T6-D: bind-before-adopt did not persist runId as the child's providerSessionId, so restore cannot reconcile it")
    }

    // The proof that matters: the watcher must still be ALIVE to tail an
    // append that happens after the child is adopted, not merely that the
    // binding dictionary entry survived.
    let childInbox = EventInbox()
    let childStream = supervisor.events(for: child.id)
    let childTask = Task { @MainActor in for await e in childStream { childInbox.append(e) } }
    defer { childTask.cancel() }
    func appendToEvents(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.1, {
        childInbox.events.map { "\($0)" }.joined().contains("first line on disk")
    }) else {
        throw fail("T6-D: the content already on disk before the race even began never reached the child, so the watcher this test depends on is not tailing at all")
    }
    guard supervisor.turnSnapshot(for: child.id)?.state == .working,
          supervisor.turnSnapshot(for: child.id)?.turnStartedAt != nil else {
        throw fail("T6-D: the observed child's authoritative agent_start did not establish a live turn before restore reconciliation")
    }
    try appendToEvents(#"{"ts":"2","type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"appended after the child was finally adopted"}]}}"# + "\n")
    guard await waitUntil(timeout: 10, pollInterval: 0.05, {
        childInbox.events.map { "\($0)" }.joined().contains("appended after the child was finally adopted")
    }) else {
        throw fail("T6-D: an append made AFTER the child was adopted never reached it — the watcher was torn down during the race and nothing was left running to notice the append")
    }

    // End the first supervisor's ownership before making run.json terminal. This
    // leaves the child's persisted working turn exactly as an app termination
    // would, while ensuring the old watcher cannot win the reconciliation race.
    supervisor.stop(parentId)
    guard supervisor.observedRunBindingCount == 0 else {
        throw fail("T6-D: stopping the original parent did not release its observed-run binding before the restore witness")
    }
    // Keep run.json nonterminal and point it at a definitely-live, same-user PID.
    // A restore owns neither that process nor its generation: trusting this PID
    // (which may also have been reused) would skip reconciliation forever because
    // restore deliberately installs no watcher for prior-session runs.
    try #"{"id":"\#(runId)","role":"code-scout","status":"running","pid":\#(ProcessInfo.processInfo.processIdentifier)}"#
        .write(to: runJSONURL, atomically: true, encoding: .utf8)

    let restored = AgentSupervisor(
        store: store,
        makeRunner: { _ in ScriptedAgentRunner(script: [.sessionStateChanged(.ready)]) },
        warn: { _ in })
    _ = restored.restore()
    guard restored.records[child.id]?.providerSessionId == runId,
          (try? store.load(id: child.id))?.providerSessionId == runId else {
        throw fail("T6-D: the restored child lost the bind-before-adopt run identity")
    }
    guard restored.turnSnapshot(for: child.id)?.state != .working,
          restored.turnSnapshot(for: child.id)?.turnStartedAt == nil,
          restored.records[child.id]?.latestTerminalEvent?.outcome == .interrupted else {
        throw fail("T6-D: restoring a prior-session running child trusted an unowned live/reused PID instead of interrupting the stale turn")
    }
    let terminalSequence = restored.records[child.id]?.latestTerminalEvent?.sequence
    restored.reconcileObservedRunsAfterRestore()
    guard restored.records[child.id]?.latestTerminalEvent?.sequence == terminalSequence else {
        throw fail("T6-D: repeated restore reconciliation delivered the same observed-run terminal boundary more than once")
    }

    return "a run bound before its child was adopted keeps its watcher and persisted run identity across that window, an append after adoption reaches it, and a new supervisor interrupts prior-session running state exactly once without trusting an unowned live/reused PID"
}

/// T6-B — a run whose directory goes quiet forever still reaches a terminal
/// state, via the pid rather than the directory.
///
/// `RunArtifactsWatcher` only notices a run ending when its directory's
/// signature CHANGES. If the child process is `kill -9`'d, or the extension
/// dies before writing a terminal `run.json`, the directory stops changing —
/// no further watcher update ever arrives, so `ingestObservedRunUpdate`'s
/// `isFinished()` check (the only place a binding used to close on its own)
/// never runs again, and a 0.25s timer would poll a dead run for the rest of
/// the app's life while the child tile sat stuck mid-turn forever.
///
/// The run directory here is written ONCE and never touched again after that.
/// `run.json` names a REAL, briefly-live process's pid — alive at the moment of
/// that one write, dead moments later with nothing ever rewriting the file. A
/// pid that is already dead at the FIRST read does not exercise this: the
/// pre-existing `isFinished()` check inside `ingestObservedRunUpdate` already
/// catches that on the one read that happens to occur. Reaching a terminal
/// state here has to come from `sweepObservedRunLiveness`'s periodic pid
/// probe, since nothing else will ever prompt it.
@MainActor
private func checkObservedRunLivenessSweepClosesQuietDeadRun(
    fail: (String) -> Error
) async throws -> String {
    let config = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-observed-liveness-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let runId = "quiet-run-000"
    let toolUseID = "call_quiet_1"
    let runDir = cwd.appendingPathComponent(".pi/agent-runs/\(runId)", isDirectory: true)
    try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    let eventsURL = runDir.appendingPathComponent("events.jsonl", isDirectory: false)
    let runJSONURL = runDir.appendingPathComponent("run.json", isDirectory: false)
    try (#"{"ts":"1","type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"the only thing this run ever writes"}]}}"# + "\n")
        .write(to: eventsURL, atomically: true, encoding: .utf8)
    // A REAL process, alive when `run.json` is written and dead moments later
    // with NOTHING ever rewriting the directory again — exactly a `kill -9`'d
    // child (or an extension that died before writing `status: "done"`), and
    // exactly the case a dead-pid-at-first-read would NOT exercise: that case
    // is already caught by the pre-existing `isFinished()` check inside
    // `ingestObservedRunUpdate` on the very first (and only) read, so it says
    // nothing about whether anything checks again once the directory goes
    // quiet.
    let shortLivedProcess = Process()
    shortLivedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
    shortLivedProcess.arguments = ["1"]
    try shortLivedProcess.run()
    let shortLivedPid = shortLivedProcess.processIdentifier
    // Reaped once it exits, off the main actor — an un-reaped child is a
    // zombie, and `kill(pid, 0)` on a zombie still succeeds (the pid is still
    // allocated until something calls wait on it), which would make this
    // "dead" pid read as alive forever and the test vacuous.
    Task.detached { shortLivedProcess.waitUntilExit() }
    try #"{"id":"\#(runId)","role":"code-scout","status":"running","pid":\#(shortLivedPid)}"#
        .write(to: runJSONURL, atomically: true, encoding: .utf8)

    let quietRunner = FixtureStreamRunner(lines: [
        #"{"type":"tool_execution_start","toolCallId":"\#(toolUseID)","toolName":"delegate_agent","args":{"agent":"code-scout","task":"quiet test","worktree":false}}"#,
        #"{"type":"tool_execution_end","toolCallId":"\#(toolUseID)","toolName":"delegate_agent","result":{"details":{"runId":"\#(runId)"}}}"#
    ])
    let store = AgentStore(applicationSupportDirectory: root)
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { launch -> AgentRunning in
            launch.record.parentAgentID == nil
                ? quietRunner
                : ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
        },
        warn: { _ in })
    let parentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: config.model, thinking: config.thinking)

    let parentInbox = EventInbox()
    let parentStream = supervisor.events(for: parentId)
    let parentTask = Task { @MainActor in for await e in parentStream { parentInbox.append(e) } }
    defer { parentTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: parentId) == 1
    }) else {
        throw fail("T6-B: the parent's subscriber never registered")
    }
    supervisor.send("delegate to a run that will go quiet", to: parentId)

    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        supervisor.records.values.contains { $0.parentAgentID == parentId }
    }) else {
        throw fail("T6-B: the delegate call produced no child at all")
    }
    let children = supervisor.records.values.filter { $0.parentAgentID == parentId }
    guard children.count == 1, let child = children.first else {
        throw fail("T6-B: expected one delegated child, got \(children.count)")
    }

    let childInbox = EventInbox()
    let childStream = supervisor.events(for: child.id)
    let childTask = Task { @MainActor in for await e in childStream { childInbox.append(e) } }
    defer { childTask.cancel() }
    func childText() -> String { childInbox.events.map { "\($0)" }.joined(separator: "\n") }
    guard await waitUntil(timeout: 10, pollInterval: 0.05, {
        childText().contains("the only thing this run ever writes")
    }) else {
        throw fail("T6-B: the run's one write never reached the child — the watcher this test depends on is not tailing at all")
    }
    guard supervisor.observedRunBindingCount == 1 else {
        throw fail("T6-B: expected exactly one open binding after the first (and only) tail, got \(supervisor.observedRunBindingCount)")
    }

    // The directory is untouched from here on. Nothing but the pid probe can
    // ever move this binding to a terminal state.
    guard await waitUntil(timeout: 15, pollInterval: 0.1, {
        childText().contains("no longer running")
    }) else {
        throw fail("T6-B: a run with a dead pid and an untouched directory never reached a terminal state — the child tile would be stuck mid-turn until the app relaunches. child events: \(childInbox.events.map { "\($0)" })")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.1, {
        supervisor.observedRunBindingCount == 0
    }) else {
        throw fail("T6-B: the child was told its run ended, but the binding (and the watcher polling for it) was never actually released — \(supervisor.observedRunBindingCount) remain")
    }
    guard !parentInbox.events.contains(where: { "\($0)".contains("no longer running") }) else {
        throw fail("T6-B: the liveness sweep's synthetic completion leaked onto the PARENT's stream instead of the child's")
    }

    return "a run whose directory goes quiet forever (dead pid, `status` stuck at \"running\") still closes — via a periodic pid probe independent of the directory — telling the child its run ended and releasing the binding, rather than polling a dead run for the rest of the app's life"
}

/// P2D.2 — an observed `spawn_agent` call becomes a real child agent.
///
/// Six properties, all against a temp `git init` repository (the fixture's call is
/// `isolated: true`, so a real worktree is created; P2C.1's inherited trap — the real
/// repository is never a `worktree add` target):
///   1. Replaying the REAL captured stream through the parent's runner produces
///      exactly ONE child, with the role and the prompt the model sent, `parentAgentID`
///      pointing at the emitting agent, the parent's project inherited, and — P2D.3 —
///      the model, thinking level and `--tools` its ROLE FILE declares.
///   2. The child actually RUNS that prompt — read off the child's own runner, so
///      "a child agent was created" is not satisfied by an inert record.
///   3. I5 — the child's prompt and role appear in NO event on the parent's stream and
///      in no activity event published from it, while `tool.spawn_agent` still does.
///   4. The isolated child's checkout is a SIBLING of the parent's, not nested inside
///      it: `<repo>/.worktrees/<child>`, with git agreeing.
///   5. The depth cap holds: a grandchild is allowed, a great-grandchild is refused,
///      and the refusal is SAID in the requesting agent's transcript.
///   6. Array's former four-child boundary is crossed, and children whose role
///      declares no provider settings still inherit the parent's (P2D.3).
///   7. A role this project does not define is REFUSED (P2D.3), said on the requesting
///      agent's transcript, without echoing the role id or a path.
///
/// Negative tests observed red at exit 1 with the final code are quoted at each
/// assertion.
@MainActor
private func checkSpawnFromToolCall(
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-spawn-tool-call-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    // P2D.3 — the roles this project defines. The captured call asks for `code-scout`,
    // so it gets a model and a reasoning level DIFFERENT from the parent's: a child
    // that matched the parent by coincidence would prove nothing about resolution. The
    // others declare no provider settings, which is where inheritance is asserted.
    // Committed, because the isolated child works in a worktree and only tracked files
    // reach one — which is the property `runnerConfig(for:)` relies on.
    // `spawn_agent` roles are Pi-owned (`.pi/agents` plus Pi's tool side
    // channel), so this end-to-end fixture must not inherit the app's ambient
    // Claude/Codex selection. Resolve both parent and role models from Pi's
    // deterministic QA catalogue.
    let piConfig = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    guard let scoutModel = AgentModelConfig.modelOptions(for: .pi).last else {
        throw fail("AgentModelConfig lists no models, so the role fixture cannot name one")
    }
    let scoutThinking = "xhigh"
    let scoutTools = "read, grep, find"
    guard scoutModel != piConfig.model, scoutThinking != piConfig.thinking else {
        throw fail("the role fixture must differ from the inherited settings, or the resolution assertions are vacuous")
    }
    try writeSpawnCheckRole(in: repo, id: "code-scout", model: scoutModel, reasoning: scoutThinking, tools: scoutTools)
    for id in ["grandchild"] + (1...AgentSupervisor.formerChildrenPerParentCap).map({ "worker-\($0)" }) {
        try writeSpawnCheckRole(in: repo, id: id)
    }
    try runIsolatedSpawnGit(["add", ".pi"], in: repo)
    try runIsolatedSpawnGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", "roles",
    ], in: repo)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))

    // The same committed capture P2D.1 produced and `SpawnRequestChecks` parses —
    // one artifact, read from disk, not a copy of its contents.
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // App
        .deletingLastPathComponent()          // ContinuumRevived
        .deletingLastPathComponent()          // Sources
        .appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures/spawn-agent-tool-call.jsonl", isDirectory: false)
    guard let fixtureText = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
        throw fail("the captured spawn_agent stream is missing at \(fixtureURL.path)")
    }
    let capturedPrompt = "Find every call site of AgentSupervisor.spawn and report the file:line list."
    let capturedRole = "code-scout"
    guard fixtureText.contains(capturedPrompt), fixtureText.contains(capturedRole) else {
        throw fail("the capture no longer carries the arguments this check asserts on — re-check after a re-capture")
    }
    let lines = fixtureText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

    // MARK: 1–2 · the call becomes a child that runs the task

    let parentRunner = FixtureStreamRunner(lines: lines)
    let projectId = UUID()
    var factory: SpawnedRunnerFactory!
    let supervisor = AgentSupervisor(store: store, makeRunner: { factory.make($0.record) })
    factory = SpawnedRunnerFactory()
    // The parent is spawned WITHOUT a prompt so its id exists before its runner is
    // needed; the factory then hands it the fixture runner.
    let parentId = supervisor.spawn(
        role: "orchestrator",
        prompt: nil,
        cwd: repo,
        harness: .pi,
        model: piConfig.model,
        thinking: piConfig.thinking,
        projectId: projectId
    )
    factory = SpawnedRunnerFactory(parent: (parentId, parentRunner))

    let parentInbox = EventInbox()
    let parentStream = supervisor.events(for: parentId)
    let parentTask = Task { @MainActor in for await event in parentStream { parentInbox.append(event) } }
    defer { parentTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: parentId) == 1 }) else {
        throw fail("the parent's subscriber never registered")
    }

    supervisor.send("delegate the search", to: parentId)
    // Red when `send` does not call `observeSpawnRequests` (the wiring deleted):
    // `the captured spawn_agent call produced 0 child agent(s), expected 1`.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { supervisor.children(of: parentId).count == 1 }) else {
        throw fail("the captured spawn_agent call produced \(supervisor.children(of: parentId).count) child agent(s), expected 1")
    }
    guard supervisor.records.count == 2 else {
        throw fail("the stream produced \(supervisor.records.count) agents in total, expected the parent and one child")
    }
    guard let childId = supervisor.children(of: parentId).first,
          let child = supervisor.records[childId] else {
        throw fail("the child agent has no record")
    }
    // Red when `handleSpawnRequest` omits `parentAgentID:` — the child exists but
    // nothing links it, so `children(of:)` above returns 0 and this never runs; the
    // durable half is asserted separately below.
    guard child.role == capturedRole else {
        throw fail("the child's role is \(String(describing: child.role)), expected the requested \(capturedRole)")
    }
    // P2D.3 — the ROLE decides the provider settings when it declares them, the parent
    // decides the project. Red when `handleSpawnRequest` passes `parent.model` /
    // `parent.thinking` again: `the child did not take its role's provider settings:
    // model openai-codex/gpt-5.6-sol, thinking medium — expected
    // openai-codex/gpt-5.3-codex-spark / xhigh from .pi/agents/code-scout.md`.
    guard child.model == scoutModel, child.thinking == scoutThinking else {
        throw fail("the child did not take its role's provider settings: model \(child.model), thinking \(child.thinking) — expected \(scoutModel) / \(scoutThinking) from \(RoleRegistry.directoryName)/\(capturedRole).md")
    }
    guard child.projectId == projectId else {
        throw fail("the child did not inherit the parent's project: \(String(describing: child.projectId))")
    }
    // …and the role's tool list is what the provider process would actually be
    // launched with. Red when `runnerConfig(for:)` drops `extraArgs`: `the child's
    // runner would not pass its role's tools: []`.
    //
    // T5 (2026-08-25): the child sits BELOW the spawn cap, so its list must also
    // carry pi's delegation verbs — `.pi/agents/*.md` roles declare none of them,
    // and `--tools` is a hard allowlist that covers extension tools, so a roled
    // agent that is not given them cannot delegate at all. This is the assertion
    // that the depth actually reaches the runner: `runnerConfig` alone would go
    // green on a supervisor that never threaded it, because the check would be
    // choosing the depth itself. Here the depth comes from the supervisor's own
    // record tree.
    let childDepth = supervisor.depth(of: child.id)
    guard childDepth < AgentSupervisor.maxSpawnDepth else {
        throw fail("the child's depth is \(childDepth), which is not below the cap — this act no longer tests what it says")
    }
    let childRunnerArgs = AgentSupervisor.runnerConfig(for: child, spawnDepth: childDepth).extraArgs
    let expectedChildTools = "\(scoutTools), " + RoleRegistry.spawnToolNames(for: .pi).joined(separator: ", ")
    guard childRunnerArgs == ["--tools", expectedChildTools] else {
        throw fail("the child's runner would not pass its role's tools plus the spawn verbs it is under the cap for: \(childRunnerArgs)")
    }
    guard let storedChild = try store.load(id: childId), storedChild.parentAgentID == parentId else {
        throw fail("the parent link did not reach the store: \(String(describing: try store.load(id: childId)?.parentAgentID))")
    }
    // …and it is DOING the work, not merely recorded. Red when `handleSpawnRequest`
    // spawns with `prompt: nil`: `the child never ran the requested task`.
    guard let childRunner = factory.runners[childId] else {
        throw fail("no runner was ever constructed for the child — it was recorded but never started")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { childRunner.prompts == [capturedPrompt] }) else {
        throw fail("the child never ran the requested task; prompts \(childRunner.prompts)")
    }

    // MARK: 3 · I5 — the arguments stay out of everything that is published

    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        parentInbox.events.contains { event in
            if case let .itemStarted(_, _, _, title) = event { return title == SpawnRequest.toolName }
            return false
        }
    }) else {
        throw fail("the parent's stream never carried the tool call itself: \(parentInbox.events.count) events")
    }
    let encodedEvents = String(decoding: try JSONEncoder().encode(parentInbox.events), as: UTF8.self)
    for (label, secret) in [("prompt", capturedPrompt), ("role", capturedRole)] {
        guard !encodedEvents.contains(secret) else {
            throw fail("I5: the child's \(label) reached an AgentRuntimeEvent on the parent's stream")
        }
    }
    let published = parentInbox.events.enumerated().compactMap { offset, event in
        ManagedAgentActivityBridge.draft(
            for: event, agentId: parentId.rawValue, tileId: nil, status: .working, now: Date()
        ).map { AgentActivityEvent(stamping: $0, sequence: UInt64(offset), replicaId: UUID()) }
    }
    guard !published.isEmpty else {
        throw fail("no activity event was published from the parent's stream, so the I5 witness is vacuous")
    }
    let encodedPublished = String(decoding: try JSONEncoder().encode(published), as: UTF8.self)
    guard !encodedPublished.contains(capturedPrompt), !encodedPublished.contains(capturedRole) else {
        throw fail("I5: a published activity event carries the spawn arguments: \(encodedPublished)")
    }
    guard encodedPublished.contains("tool.\(SpawnRequest.toolName)") else {
        throw fail("the tool NAME should still cross — no tool.\(SpawnRequest.toolName) in \(encodedPublished)")
    }

    // MARK: 4 · the isolated child is a SIBLING checkout, not a nested one

    guard let branch = child.worktreeBranch else {
        throw fail("the request asked for isolation and the child has no branch")
    }
    let container = repo.appendingPathComponent(WorktreeManager.containerDirectoryName, isDirectory: true)
    guard URL(fileURLWithPath: child.cwd).deletingLastPathComponent().path == container.path else {
        throw fail("the isolated child works in \(child.cwd), not directly in \(container.path)/")
    }
    // Red when `repositoryRoot(of:)` returns the parent's `cwd` unconditionally and
    // the parent is itself isolated (asserted below with a grandchild).
    let listed = try WorktreeManager().list(repo: repo)
    guard listed.contains(where: {
        WorktreeManager.resolved($0.path) == WorktreeManager.resolved(URL(fileURLWithPath: child.cwd)) && $0.branch == branch
    }) else {
        throw fail("git does not know the child's worktree: \(listed.map { "\($0.path.path)@\($0.branch ?? "detached")" })")
    }

    // MARK: 5 · the depth cap, and what a refusal says

    // A grandchild is inside the cap. Requested from the CHILD, which is isolated —
    // so this is also where a nested `.worktrees/.worktrees/` would show up.
    guard let grandchildId = supervisor.handleSpawnRequest(
        SpawnRequest(role: "grandchild", prompt: "look at one file", isolated: true),
        from: childId
    ) else {
        throw fail("a grandchild is at depth \(AgentSupervisor.maxSpawnDepth) and must be allowed")
    }
    guard let grandchild = supervisor.records[grandchildId] else {
        throw fail("the grandchild has no record")
    }
    // A DIRECT child of the container, not merely somewhere under it. `hasPrefix` is
    // the trap the negative test caught: a nested
    // `<repo>/.worktrees/<child>/.worktrees/<grandchild>` satisfies the prefix and is
    // exactly the shape `repositoryRoot(of:)` exists to prevent.
    guard URL(fileURLWithPath: grandchild.cwd).deletingLastPathComponent().path == container.path else {
        throw fail("the grandchild's checkout \(grandchild.cwd) is nested inside its parent's rather than a sibling in \(container.path)/")
    }
    guard supervisor.depth(of: grandchildId) == AgentSupervisor.maxSpawnDepth else {
        throw fail("the grandchild's depth is \(supervisor.depth(of: grandchildId)), expected \(AgentSupervisor.maxSpawnDepth)")
    }
    // T5 — AT the cap the spawn verbs are WITHHELD, so the model is never offered
    // a tool Array would have to refuse. The other half of the child assertion
    // above, and the half that catches an off-by-one in the comparison.
    let grandchildArgs = AgentSupervisor.runnerConfig(
        for: grandchild, spawnDepth: supervisor.depth(of: grandchildId)).extraArgs
    for spawnTool in RoleRegistry.spawnToolNames(for: .pi) {
        guard !grandchildArgs.joined(separator: " ").contains(spawnTool) else {
            throw fail("the grandchild is AT the depth cap but was still offered \(spawnTool): \(grandchildArgs)")
        }
    }

    let grandchildInbox = EventInbox()
    let grandchildStream = supervisor.events(for: grandchildId)
    let grandchildTask = Task { @MainActor in for await event in grandchildStream { grandchildInbox.append(event) } }
    defer { grandchildTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: grandchildId) == 1 }) else {
        throw fail("the grandchild's subscriber never registered")
    }
    let beforeDepthRefusal = supervisor.records.count
    // Red when the depth guard is deleted: `a great-great-grandchild was spawned past
    // the depth cap`.
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: "too-deep", prompt: "keep delegating", isolated: false),
        from: grandchildId
    ) == nil else {
        throw fail("an agent past the depth cap of \(AgentSupervisor.maxSpawnDepth) was spawned anyway")
    }
    guard supervisor.records.count == beforeDepthRefusal else {
        throw fail("a refused spawn still created a record: \(supervisor.records.count) agents, expected \(beforeDepthRefusal)")
    }
    // The refusal is SAID, not swallowed. Red when `refuseSpawn` only warns:
    // `the refusal never reached the requesting agent's transcript`.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        grandchildInbox.events.contains { event in
            if case let .itemStarted(_, _, kind, title) = event {
                return kind == .error && (title ?? "").contains("\(SpawnRequest.toolName) refused")
            }
            return false
        }
    }) else {
        throw fail("the refusal never reached the requesting agent's transcript: \(grandchildInbox.events)")
    }
    guard grandchildInbox.events.contains(where: { event in
        if case let .itemCompleted(_, _, kind, status) = event { return kind == .error && status == .failed }
        return false
    }) else {
        throw fail("the refusal was started but never completed as failed: \(grandchildInbox.events)")
    }
    // The reason may not carry the refused prompt or a path — the transcript is the
    // near side of the boundary, but the bridge publishes from it.
    let refusalTitles = grandchildInbox.events.compactMap { event -> String? in
        if case let .itemStarted(_, _, _, title) = event, (title ?? "").contains("refused") { return title }
        return nil
    }
    guard refusalTitles.allSatisfy({ !$0.contains("keep delegating") && !$0.contains(root.path) }) else {
        throw fail("I5: a refusal reason carries the request's prompt or a host path: \(refusalTitles)")
    }

    // MARK: 6 · durable history does not impose the former child cap

    // The parent already has one child (the captured call). Add four more,
    // non-isolated so this stays an admission assertion rather than N worktrees.
    for index in 1...AgentSupervisor.formerChildrenPerParentCap {
        guard supervisor.handleSpawnRequest(
            SpawnRequest(role: "worker-\(index)", prompt: "task \(index)", isolated: false),
            from: parentId
        ) != nil else {
            throw fail("child \(index + 1) was refused at Array's former four-child boundary")
        }
    }
    let childrenPastFormerCap = AgentSupervisor.formerChildrenPerParentCap + 1
    guard supervisor.children(of: parentId).count == childrenPastFormerCap else {
        throw fail("the parent has \(supervisor.children(of: parentId).count) children, expected \(childrenPastFormerCap) past the former cap")
    }
    // P2D.3 — those roles declare no model or reasoning, so the PARENT's settings are
    // still what they run with (and no `--tools`, because the role names none). Red
    // when `resolve` defaults a silent model instead of inheriting: `worker-1 did not
    // inherit the parent's provider settings`.
    let workers = supervisor.children(of: parentId)
        .compactMap { supervisor.records[$0] }
        .filter { ($0.role ?? "").hasPrefix("worker-") }
    guard workers.count == AgentSupervisor.formerChildrenPerParentCap else {
        throw fail("expected \(AgentSupervisor.formerChildrenPerParentCap) role-only children, got \(workers.count)")
    }
    for worker in workers {
        guard worker.model == piConfig.model, worker.thinking == piConfig.thinking else {
            throw fail("\(worker.role ?? "?") did not inherit the parent's provider settings: model \(worker.model), thinking \(worker.thinking)")
        }
        guard AgentSupervisor.runnerConfig(for: worker, spawnDepth: 0).extraArgs.isEmpty else {
            throw fail("\(worker.role ?? "?") declares no tools but its runner would pass \(AgentSupervisor.runnerConfig(for: worker, spawnDepth: 0).extraArgs)")
        }
    }
    // An agent this supervisor does not know gets nothing, and does not crash.
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "from nowhere", isolated: false),
        from: AgentID(rawValue: UUID())
    ) == nil else {
        throw fail("a spawn request from an unknown agent produced a child")
    }

    // MARK: 7 · a role this project does not define is refused (P2D.3)

    // Asked of the CHILD: it is at depth 1 with one child of its own, so neither cap
    // can be what stops this — only the unknown role can.
    let childInbox = EventInbox()
    let childStream = supervisor.events(for: childId)
    let childTask = Task { @MainActor in for await event in childStream { childInbox.append(event) } }
    defer { childTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: childId) == 1 }) else {
        throw fail("the child's subscriber never registered")
    }
    let undefinedRole = "not-a-role-in-this-project"
    let beforeRoleRefusal = supervisor.records.count
    // Red when `handleSpawnRequest` skips the registry and inherits the parent's model
    // for an unknown role: `a spawn naming an undefined role produced a child`.
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: undefinedRole, prompt: "work for a role that does not exist", isolated: false),
        from: childId
    ) == nil else {
        throw fail("a spawn naming an undefined role produced a child")
    }
    guard supervisor.records.count == beforeRoleRefusal else {
        throw fail("the refused role still created a record: \(supervisor.records.count), expected \(beforeRoleRefusal)")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        childInbox.events.contains { event in
            if case let .itemStarted(_, _, kind, title) = event {
                return kind == .error && (title ?? "").contains(AgentSupervisor.SpawnRefusal.roleUnresolved.reason)
            }
            return false
        }
    }) else {
        throw fail("the unknown role was refused silently — nothing on the requesting agent's transcript: \(childInbox.events)")
    }
    // The reason names no role id and no path: the P2D.2 witness above holds the
    // REQUESTED role out of every event on a parent's stream, and this is the one
    // place that could put one back.
    let roleRefusalTitles = childInbox.events.compactMap { event -> String? in
        if case let .itemStarted(_, _, _, title) = event, (title ?? "").contains("refused") { return title }
        return nil
    }
    guard roleRefusalTitles.allSatisfy({ !$0.contains(undefinedRole) && !$0.contains(root.path) }) else {
        throw fail("I5: a role refusal echoes the requested role id or a host path: \(roleRefusalTitles)")
    }

    // MARK: 8 · C12 — a codex parent is refused honestly about OBSERVABILITY

    // `codex exec --json` (measured, `.plans/46`) has no wire representation for
    // subagent activity at all, so Array cannot say a codex parent spawned
    // anything even where codex itself may be delegating. The refusal must not
    // claim codex cannot spawn — that would be false — only that this transport
    // cannot see it.
    let codexConfig = AgentModelConfig.resolvedFromDefaults(harness: .codex)
    let codexParentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: repo,
        harness: .codex, model: codexConfig.model, thinking: codexConfig.thinking,
        projectId: projectId)
    let codexInbox = EventInbox()
    let codexStream = supervisor.events(for: codexParentId)
    let codexTask = Task { @MainActor in for await event in codexStream { codexInbox.append(event) } }
    defer { codexTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: codexParentId) == 1 }) else {
        throw fail("the codex parent's subscriber never registered")
    }
    let beforeCodexRefusal = supervisor.records.count
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "delegate this to a subagent", isolated: false),
        from: codexParentId
    ) == nil else {
        throw fail("a codex parent was allowed to spawn — Array has no transport evidence of what would happen to the child")
    }
    guard supervisor.records.count == beforeCodexRefusal else {
        throw fail("the refused codex spawn still created a record: \(supervisor.records.count), expected \(beforeCodexRefusal)")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        codexInbox.events.contains { event in
            if case let .itemStarted(_, _, kind, title) = event {
                return kind == .error && (title ?? "").contains(AgentSupervisor.SpawnRefusal.codexSubagentsUnobservable.reason)
            }
            return false
        }
    }) else {
        throw fail("a codex parent's spawn was refused silently — nothing on its transcript: \(codexInbox.events)")
    }
    let codexRefusalTitles = codexInbox.events.compactMap { event -> String? in
        if case let .itemStarted(_, _, _, title) = event, (title ?? "").contains("refused") { return title }
        return nil
    }
    guard codexRefusalTitles.allSatisfy({ !$0.contains("delegate this to a subagent") && !$0.contains(root.path) }) else {
        throw fail("I5: a codex refusal echoes the requested prompt or a host path: \(codexRefusalTitles)")
    }
    guard !codexRefusalTitles.contains(where: { $0.localizedCaseInsensitiveContains("cannot spawn") }) else {
        throw fail("the codex refusal claims codex cannot spawn, which is false — it says Array cannot observe it: \(codexRefusalTitles)")
    }
    supervisor.stop(codexParentId)

    // MARK: 9 · C12 — a mirrored (observedReadOnly) parent has no runner to spawn through

    // This is a claude `Agent` subagent Array only mirrors — read-only transcript,
    // not locally managed. Persist it through the real store/restore path (the
    // same one a relaunch uses) rather than reaching into `records` directly, so
    // this witness exercises production adoption too.
    let observedId = AgentID(rawValue: UUID())
    let now = Date()
    let observedRecord = AgentRecord(
        id: observedId,
        displayName: "Mirrored subagent",
        role: nil,
        harness: .claudeCode,
        model: piConfig.model,
        thinking: piConfig.thinking,
        cwd: repo.path,
        projectId: projectId,
        capabilities: .observedReadOnly,
        createdAt: now,
        lastActivityAt: now
    )
    try store.upsert(observedRecord)
    supervisor.restore()
    guard supervisor.records[observedId]?.capabilities == .observedReadOnly else {
        throw fail("the mirrored record did not restore with observedReadOnly capabilities")
    }
    let observedInbox = EventInbox()
    let observedStream = supervisor.events(for: observedId)
    let observedTask = Task { @MainActor in for await event in observedStream { observedInbox.append(event) } }
    defer { observedTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: observedId) == 1 }) else {
        throw fail("the mirrored agent's subscriber never registered")
    }
    let beforeObservedRefusal = supervisor.records.count
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "spawn a helper", isolated: false),
        from: observedId
    ) == nil else {
        throw fail("a mirrored (observedReadOnly) agent was allowed to spawn a child through a runner it does not own")
    }
    guard supervisor.records.count == beforeObservedRefusal else {
        throw fail("the refused mirrored-parent spawn still created a record: \(supervisor.records.count), expected \(beforeObservedRefusal)")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        observedInbox.events.contains { event in
            if case let .itemStarted(_, _, kind, title) = event {
                return kind == .error && (title ?? "").contains(AgentSupervisor.SpawnRefusal.observedParentCannotSpawn.reason)
            }
            return false
        }
    }) else {
        throw fail("a mirrored parent's spawn was refused silently — nothing on its transcript: \(observedInbox.events)")
    }
    let observedRefusalTitles = observedInbox.events.compactMap { event -> String? in
        if case let .itemStarted(_, _, _, title) = event, (title ?? "").contains("refused") { return title }
        return nil
    }
    guard observedRefusalTitles.allSatisfy({ !$0.contains("spawn a helper") && !$0.contains(root.path) }) else {
        throw fail("I5: a mirrored-parent refusal echoes the requested prompt or a host path: \(observedRefusalTitles)")
    }

    // MARK: 10 · C7 — an OBSERVED claude subagent is adopted, not spawned
    //
    // An `Agent` (formerly `Task`) call is claude reporting a child it has already
    // started inside itself. Array mints a read-only record so the child's own
    // frames have somewhere to land and the parent gets a chip — and must never
    // start a process for it.
    let observedParent = supervisor.spawn(
        role: nil, prompt: nil, cwd: repo, harness: .claudeCode,
        model: piConfig.model, thinking: piConfig.thinking, projectId: projectId)
    let observedParentInbox = EventInbox()
    let observedParentStream = supervisor.events(for: observedParent)
    let observedParentTask = Task { @MainActor in
        for await event in observedParentStream { observedParentInbox.append(event) }
    }
    defer { observedParentTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.subscriberCount(for: observedParent) == 1
    }) else {
        throw fail("the observed parent's subscriber never registered")
    }

    let toolUseID = "toolu_0164hvbb7oKHD8HqnBRJVh8E"
    let announcement = SpawnRequest(
        role: "general-purpose",
        prompt: "read notes.txt and report its contents",
        isolated: false,
        sourceItemID: toolUseID,
        observedOnly: true)
    guard let adopted = supervisor.handleSpawnRequest(announcement, from: observedParent) else {
        throw fail("a claude Agent announcement produced no child record, so its frames would have nowhere to land")
    }
    guard let adoptedRecord = supervisor.records[adopted] else {
        throw fail("the adopted child is not in the supervisor's records")
    }
    guard adoptedRecord.capabilities == .observedReadOnly else {
        throw fail("the adopted child has capabilities \(adoptedRecord.capabilities) — a child Array only mirrors must not advertise a composer or a working Stop")
    }
    guard adoptedRecord.parentAgentID == observedParent else {
        throw fail("the adopted child is not parented, so the inbox cannot nest it and the lineage overlay cannot draw it")
    }
    // No process. `handleSpawnRequest` returning a child that is RUNNING would
    // mean Array had started a second conversation claude already owns.
    guard !supervisor.isRunning(adopted) else {
        throw fail("Array started a runner for a child claude is already running")
    }

    // Deterministic identity: the same announcement is replayed on every restore
    // and re-observation, and a random id would mint a duplicate agent each time.
    let beforeReadopt = supervisor.records.count
    guard supervisor.handleSpawnRequest(announcement, from: observedParent) == adopted else {
        throw fail("re-observing the same Agent call minted a different child — a restore would duplicate every subagent")
    }
    guard supervisor.records.count == beforeReadopt else {
        throw fail("re-observing the same Agent call added a record: \(supervisor.records.count), expected \(beforeReadopt)")
    }
    guard adopted.rawValue == AgentRecord.observedChildID(
        parentAgentID: observedParent.rawValue, toolUseID: toolUseID) else {
        throw fail("the adopted child's id is not derived from (parent, tool_use_id), so it cannot be re-derived on restore")
    }

    // The parent gets exactly one chip, and it names the announcing call.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        observedParentInbox.events.contains { event in
            if case let .childAgentSpawned(_, childAgentID, _, _, sourceItemID, _, _) = event {
                return childAgentID == adopted.rawValue && sourceItemID == toolUseID
            }
            return false
        }
    }) else {
        throw fail("the observed child produced no chip on the parent's transcript: \(observedParentInbox.events)")
    }
    let chipCount = observedParentInbox.events.filter {
        if case .childAgentSpawned = $0 { return true }
        return false
    }.count
    guard chipCount == 1 else {
        throw fail("the parent saw \(chipCount) chips for one child — re-observation must converge, not accumulate")
    }
    // I5: the model-authored prompt must not reach the parent's published stream.
    let observedTitles = observedParentInbox.events.compactMap { event -> String? in
        if case let .itemStarted(_, _, _, title) = event { return title }
        if case let .childAgentSpawned(_, _, _, displayName, _, _, _) = event { return displayName }
        return nil
    }
    guard observedTitles.allSatisfy({ !$0.contains("read notes.txt") && !$0.contains(root.path) }) else {
        throw fail("I5: an observed-child event echoes the model-authored prompt or a host path: \(observedTitles)")
    }

    // If Claude's parent stops/crashes before its top-level tool_result, the
    // mirrored child has no independent transport left to close it. This fallback
    // is Claude-only; the Codex positive control above must still drain late.
    supervisor.qaDeliver(.turnStarted(
        threadId: AgentSupervisor.threadId(for: adopted),
        turnId: "claude-unclosed-child"), to: adopted)
    guard supervisor.turnSnapshot(for: adopted)?.state == .working else {
        throw fail("the mirrored Claude child did not enter Working before parent-stop fallback")
    }
    supervisor.stop(observedParent)
    guard supervisor.turnSnapshot(for: adopted)?.state != .working,
          supervisor.turnSnapshot(for: adopted)?.turnStartedAt == nil else {
        throw fail("stopping a Claude parent left its still-open mirrored child Working")
    }

    for id in supervisor.children(of: parentId) + [grandchildId] { supervisor.stop(id) }
    return "the captured spawn_agent call produced 1 child (role \(capturedRole) at \(scoutModel)/\(scoutThinking) and --tools from its role file, isolated on \(branch), parent linked in the store) that ran the requested prompt, prompt/role absent from \(parentInbox.events.count) parent events and \(published.count) published activity events while tool.\(SpawnRequest.toolName) crossed, a grandchild got a sibling worktree, depth capped at \(AgentSupervisor.maxSpawnDepth), \(childrenPastFormerCap) managed children crossed the former breadth cap, \(workers.count) role-only children inherited the parent's settings, an undefined role was refused without echoing its id, a codex parent was refused honestly about transport observability rather than a false claim it cannot spawn, and a mirrored observedReadOnly parent restored from the store was refused for having no runner to spawn through — neither refusal echoing its request; and a claude Agent announcement was ADOPTED as one observedReadOnly, parented, process-less child at a (parent, tool_use_id)-derived id that re-observation converges on, with exactly one chip on the parent and no prompt in it"
}

/// The `spawn_agent` result-file channel — what makes delegation COLLECTABLE.
///
/// Witnessed live 2026-08-22: `spawn_agent` is fire-and-forget, so a parent's
/// model spawned two children, had no way to read their results, slept in a
/// loop, gave up and redid the work itself; and a REFUSED spawn still read
/// "spawned" to the model, because `refuseSpawn` synthesizes transcript items
/// the model never receives. The channel is
/// `<parent cwd>/.array/spawn-results/<toolCallId>.json`, written by the
/// production functions this check drives (`handleSpawnRequest`,
/// `refuseSpawn`, `deliver`'s `.turnCompleted`), and read by the extension's
/// `wait_agents` tool.
///
/// Three lifecycles, all in an isolated temp cwd:
///   1. a REFUSED spawn writes `refused` with the refusal's own reason
///      (red at HEAD: no file existed at all),
///   2. a successful spawn writes `spawned` synchronously, and the child's
///      `.turnCompleted(.completed)` rewrites it to `completed` carrying the
///      child's final assistant text (red at HEAD),
///   3. an interrupted child's file ends `interrupted`; archiving that child
///      removes its file.
@MainActor
private func checkSpawnResultFileChannel(
    fail: (String) -> Error
) async throws -> String {
    let piConfig = AgentModelConfig.resolvedFromDefaults(harness: .pi)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-spawn-result-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Deliberately NO .pi/agents directory, so a NAMED role is the refusal.
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))

    let childAnswer = "The final answer from the spawned child: 42."
    let completedScript: [AgentRuntimeEvent] = [
        .turnStarted(threadId: "child-thread", turnId: "turn-1"),
        .itemStarted(threadId: "child-thread", itemId: "msg-1", kind: .assistantMessage, title: nil),
        .contentDelta(threadId: "child-thread", turnId: "turn-1", streamKind: .assistant, delta: childAnswer),
        .itemCompleted(threadId: "child-thread", itemId: "msg-1", kind: .assistantMessage, status: .completed),
        .turnCompleted(threadId: "child-thread", turnId: "turn-1", outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready),
    ]
    let interruptedScript: [AgentRuntimeEvent] = [
        .turnStarted(threadId: "child-thread", turnId: "turn-1"),
        .turnCompleted(threadId: "child-thread", turnId: "turn-1", outcome: .interrupted, errorMessage: nil),
        .sessionStateChanged(.ready),
    ]
    // The parent never runs a turn here; each CHILD gets the next script in
    // order, so the two spawns below exercise two different terminal outcomes.
    var childScripts = [completedScript, interruptedScript]
    // A transcript store is required: `finalText` is read from the transcript
    // projection, which `ingestTranscriptEvent` only feeds when one is injected
    // — exactly production's shape.
    let transcriptStore = AgentTranscriptStore(
        root: root.appendingPathComponent("transcripts", isDirectory: true))
    let supervisor = AgentSupervisor(store: store, makeRunner: { launch in
        if launch.record.parentAgentID == nil {
            return ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
        }
        return ScriptedAgentRunner(script: childScripts.isEmpty ? [.sessionStateChanged(.ready)] : childScripts.removeFirst())
    }, warn: { _ in }, transcriptStore: transcriptStore)
    let parentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: piConfig.model, thinking: piConfig.thinking)

    func resultFile(_ handle: String) -> SpawnResultFile? {
        guard let data = try? Data(contentsOf: SpawnResultFile.url(parentCwd: cwd.path, handle: handle)) else {
            return nil
        }
        return try? JSONCodec.makeDecoder().decode(SpawnResultFile.self, from: data)
    }

    // MARK: 1 · a refusal reaches the MODEL's channel, with the reason

    let refusedHandle = "call_refused_no_roles"
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: "researcher", prompt: "look it up", isolated: false, sourceItemID: refusedHandle),
        from: parentId
    ) == nil else {
        throw fail("a named role in a project with no roles was not refused")
    }
    guard let refused = resultFile(refusedHandle) else {
        throw fail("a refused spawn wrote no result file — the refusal is still UI-only and the model still believes it spawned")
    }
    guard refused.status == .refused, refused.toolCallId == refusedHandle else {
        throw fail("the refused result file says \(refused.status.rawValue) for \(refused.toolCallId), expected refused/\(refusedHandle)")
    }
    guard refused.reason == AgentSupervisor.SpawnRefusal
        .projectDeclaresNoRoles(directory: RoleRegistry.directoryName(for: .pi)).reason else {
        throw fail("the refused result file's reason is \(String(describing: refused.reason)), not the refusal's own")
    }

    // MARK: 2 · spawned synchronously, then rewritten to completed with the child's final text

    let okHandle = "call_ok_completed"
    guard let childId = supervisor.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "find the answer", isolated: false, sourceItemID: okHandle),
        from: parentId
    ) else {
        throw fail("a roleless spawn inside every cap was refused")
    }
    // Synchronous read on the same actor turn: the child's runner has not run
    // yet, so this MUST already say `spawned` — the write is part of the spawn.
    guard let spawned = resultFile(okHandle), spawned.status == .spawned else {
        throw fail("a successful spawn did not synchronously write a spawned result file, got \(String(describing: resultFile(okHandle)?.status))")
    }
    guard spawned.agentId == childId.rawValue else {
        throw fail("the spawned result file names agent \(String(describing: spawned.agentId)), not the child \(childId.rawValue)")
    }
    guard supervisor.records[childId]?.spawnResultHandle == okHandle else {
        throw fail("the child record does not remember its spawn handle: \(String(describing: supervisor.records[childId]?.spawnResultHandle))")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { resultFile(okHandle)?.status == .completed }) else {
        throw fail("the child's turnCompleted never rewrote the result file to completed; last status \(String(describing: resultFile(okHandle)?.status))")
    }
    guard let completed = resultFile(okHandle), completed.finalText == childAnswer else {
        throw fail("the completed result file does not carry the child's final assistant text: \(String(describing: resultFile(okHandle)?.finalText))")
    }
    guard completed.agentId == childId.rawValue, completed.endedAt != nil else {
        throw fail("the completed result file lost the child's identity or endedAt")
    }

    // MARK: 3 · an interrupted child says so, and archiving it removes the file

    let interruptedHandle = "call_interrupted"
    guard let interruptedChildId = supervisor.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "work that will be stopped", isolated: false, sourceItemID: interruptedHandle),
        from: parentId
    ) else {
        throw fail("the second spawn inside every cap was refused")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { resultFile(interruptedHandle)?.status == .interrupted }) else {
        throw fail("an interrupted child's result file never reached interrupted; last status \(String(describing: resultFile(interruptedHandle)?.status))")
    }
    _ = supervisor.archive(interruptedChildId)
    guard resultFile(interruptedHandle) == nil else {
        throw fail("archiving a spawned child left its result file behind")
    }

    // A handle that cannot be a filename writes nothing, anywhere.
    let beforeTraversal = (try? FileManager.default.contentsOfDirectory(
        atPath: SpawnResultFile.directory(parentCwd: cwd.path).path)) ?? []
    _ = supervisor.handleSpawnRequest(
        SpawnRequest(role: "researcher", prompt: "x", isolated: false, sourceItemID: "../escape"),
        from: parentId)
    let afterTraversal = (try? FileManager.default.contentsOfDirectory(
        atPath: SpawnResultFile.directory(parentCwd: cwd.path).path)) ?? []
    guard beforeTraversal.sorted() == afterTraversal.sorted(),
          !FileManager.default.fileExists(atPath: cwd.deletingLastPathComponent()
              .appendingPathComponent("escape.json").path) else {
        throw fail("a path-shaped toolCallId reached the filesystem")
    }

    supervisor.stop(childId)
    supervisor.stop(parentId)
    return "spawn results: a refusal wrote refused with its reason to the model's file channel, a launch wrote spawned synchronously and the child's turnCompleted rewrote it to completed with the final assistant text, an interrupted child ended interrupted and its archive removed the file, and a path-shaped handle wrote nothing"
}

/// P2C.2 — an isolated spawn works in its OWN checkout.
///
/// Runs against a temp `git init` repository created here and deleted after. The real
/// repository is never a `git worktree add` target — P2C.1's explicit trap, inherited.
///
/// Four properties:
///   1. An isolated spawn's record has `cwd` inside `<repo>/.worktrees/` and
///      `worktreeBranch` set, and GIT agrees both exist (`git worktree list`).
///   2. The runner is handed that directory, and the branch actually checked out
///      there is the agent's own — asserted with `git rev-parse --abbrev-ref HEAD`
///      inside the cwd the runner was constructed with, so "the agent works on its own
///      branch" is a git fact rather than a string comparison against the same
///      constant the code built. The PRODUCTION factory is asserted too
///      (`PiAgentRunner.Config.cwd`), since an injected runner cannot witness it.
///   3. A non-isolated spawn against the same repo is UNCHANGED: `cwd` is the project
///      root, `worktreeBranch` is nil, and no new worktree appears.
///   4. NO FALLBACK, the packet's load-bearing rule. Two real `add` failures — a `cwd`
///      that is not a repository, and a `.worktrees` path occupied by a file — must
///      throw out of `spawn` and leave NO agent behind, in memory or on disk. A silent
///      fallback would put a supposedly isolated agent in the shared tree.
///
/// Negative tests observed red at exit 1 with the final code:
/// · `spawn(isolated:)` ignoring `isolated` (always `cwd`, no worktree) →
///   `FAIL: an isolated spawn's cwd … is not inside …/.worktrees/`
/// · setting `worktreeBranch: nil` on the isolated path →
///   `FAIL: an isolated agent's record does not name its branch`
/// · catching the `add` failure and falling back to `cwd` →
///   `FAIL: a failed worktree (not a repository) did not fail the spawn — the agent
///    landed in the main checkout …`
/// · `piRunner(for:)` building its `Config` with a fixed cwd instead of `record.cwd` →
///   `FAIL: the production runner would start Pi in /Users/dylan, not the agent's
///    worktree …`
@MainActor
private func checkIsolatedSpawn(
    config: AgentModelConfig.Resolution,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-isolated-spawn-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))

    // MARK: 1–2 · the isolated agent's own checkout

    let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
    let recorder = SpawningCwdRecorder(runner)
    let supervisor = AgentSupervisor(store: store, makeRunner: { recorder.make($0.record) })
    let isolatedId = try supervisor.spawn(
        role: "implementer",
        prompt: "fix auth",
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        isolated: true
    )
    guard let isolated = supervisor.records[isolatedId] else {
        throw fail("the supervisor lost the isolated agent it spawned")
    }
    let container = repo.appendingPathComponent(WorktreeManager.containerDirectoryName, isDirectory: true)
    guard isolated.cwd.hasPrefix(container.path + "/") else {
        throw fail("an isolated spawn's cwd \(isolated.cwd) is not inside \(container.path)/")
    }
    guard let branch = isolated.worktreeBranch else {
        throw fail("an isolated agent's record does not name its branch")
    }
    guard branch.hasPrefix(WorktreeManager.branchPrefix) else {
        throw fail("an isolated agent's branch \(branch) is not under \(WorktreeManager.branchPrefix)")
    }
    let slug = URL(fileURLWithPath: isolated.cwd).lastPathComponent
    guard branch == WorktreeManager.branchName(slug: slug) else {
        throw fail("the branch \(branch) does not match the worktree directory \(slug)")
    }
    // The role and the prompt are both in the slug, so a spawn that dropped either
    // from the derivation would produce a directory no one can identify.
    guard slug.hasPrefix("implementer-fix-auth-") else {
        throw fail("the worktree directory \(slug) is not derived from the agent's role and prompt")
    }

    // Git's own view, not the manager's return value: `list` re-reads the repository.
    let manager = WorktreeManager()
    let listed = try manager.list(repo: repo)
    guard listed.contains(where: {
        isolatedSpawnResolved($0.path) == isolatedSpawnResolved(URL(fileURLWithPath: isolated.cwd)) && $0.branch == branch
    }) else {
        throw fail("git does not know about the agent's worktree: \(listed.map { "\($0.path.path)@\($0.branch ?? "detached")" })")
    }

    // …and the runner was pointed at it. The recorder captures what
    // `AgentSupervisor.piRunner(for:)` reads (`record.cwd`), and the branch is read
    // back out of that directory with git.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { recorder.cwds.count == 1 }) else {
        throw fail("the isolated spawn's prompt never reached a runner: \(recorder.cwds)")
    }
    guard recorder.cwds == [isolated.cwd] else {
        throw fail("the runner was constructed for \(recorder.cwds) rather than the worktree \(isolated.cwd)")
    }
    let checkedOut = try runIsolatedSpawnGit(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: isolated.cwd))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard checkedOut == branch else {
        throw fail("the directory the runner works in is on branch \(checkedOut), not the agent's \(branch)")
    }
    // The PRODUCTION factory, not the recorder: an injected runner cannot witness
    // what `PiRpcAgentRunner.Config.cwd` would be, so a regression in `piRunner(for:)`
    // would pass everything above (from the cross-review).
    guard let production = AgentSupervisor.piRunner(for: AgentRunnerLaunch(record: isolated, spawnDepth: 0)) as? PiRpcAgentRunner else {
        throw fail("the default runner factory does not produce a PiRpcAgentRunner for an isolated agent")
    }
    guard production.config.cwd.path == isolated.cwd else {
        throw fail("the production runner would start Pi in \(production.config.cwd.path), not the agent's worktree \(isolated.cwd)")
    }

    // MARK: 3 · a non-isolated spawn is exactly what it was

    let plainId = supervisor.spawn(
        role: "reviewer",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking
    )
    guard let plain = supervisor.records[plainId] else {
        throw fail("the supervisor lost the non-isolated agent it spawned")
    }
    guard plain.cwd == repo.path, plain.worktreeBranch == nil else {
        throw fail("a non-isolated spawn changed: cwd \(plain.cwd) branch \(plain.worktreeBranch ?? "nil") — it must stay the project root with no branch")
    }
    guard try manager.list(repo: repo).count == listed.count else {
        throw fail("a non-isolated spawn created a worktree")
    }

    // MARK: 4 · a worktree that cannot be created FAILS THE SPAWN

    /// Returns the error `spawn` raised, so the caller can be specific about it where
    /// the manager owns the failure. ANY error is accepted here rather than only a
    /// `WorktreeError`: the container-creation failure below surfaces as Foundation's
    /// own `NSFileWriteFileExistsError`, and re-typing it would mean editing P2C.1's
    /// manager for a ticket that is about the spawn path.
    func expectNoFallback(_ label: String, cwd: URL) throws -> Error {
        let before = supervisor.records.count
        var leaked: AgentID?
        var thrown: Error?
        do {
            leaked = try supervisor.spawn(
                role: "implementer",
                prompt: "fix auth",
                cwd: cwd,
                model: config.model,
                thinking: config.thinking,
                isolated: true
            )
        } catch {
            thrown = error
        }
        if let leaked {
            throw fail("a failed worktree (\(label)) did not fail the spawn — the agent landed in the main checkout \(supervisor.records[leaked]?.cwd ?? "?")")
        }
        guard let thrown else {
            throw fail("a failed worktree (\(label)) neither threw nor returned an agent")
        }
        guard supervisor.records.count == before else {
            throw fail("a failed isolated spawn (\(label)) left \(supervisor.records.count - before) agent(s) behind in memory")
        }
        guard try store.loadAll().count == before else {
            throw fail("a failed isolated spawn (\(label)) persisted a record")
        }
        return thrown
    }

    let notARepo = root.appendingPathComponent("not-a-repo", isDirectory: true)
    try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
    let notARepoError = try expectNoFallback("not a repository", cwd: notARepo)
    guard (notARepoError as? WorktreeManager.WorktreeError) == .invalidRepository(notARepo.path) else {
        throw fail("an isolated spawn into a non-repository reported \(notARepoError) rather than .invalidRepository")
    }

    // A real repository whose `.worktrees` path is occupied by a FILE: the failure is
    // in creating the container, i.e. past the repository check, which is where a
    // fallback would be most tempting.
    let blocked = root.appendingPathComponent("blocked", isDirectory: true)
    try makeIsolatedSpawnRepo(at: blocked)
    try "not a directory\n".write(
        to: blocked.appendingPathComponent(WorktreeManager.containerDirectoryName),
        atomically: true,
        encoding: .utf8
    )
    _ = try expectNoFallback(".worktrees occupied by a file", cwd: blocked)

    supervisor.stopAll()
    return "an isolated spawn ran in .worktrees/\(slug) on \(branch) (git agrees, and that is the branch checked out in the runner's cwd), a non-isolated spawn stayed in the project root with no branch, and two real worktree failures each threw out of spawn leaving no agent"
}

/// P2C.3 — archiving an agent cleans up after it, and never at the cost of work.
///
/// Everything runs against a TEMP `git init` repository (P2C.1's inherited trap: the
/// real repository is never a `worktree add` target) and a temp `AgentStore`. The
/// orphan half uses SUCCESSIVE supervisors over that one store, because "the record
/// is gone" has to be observed by something that never held the record — a supervisor
/// that spawned the agent could answer from memory.
///
/// Eight properties:
///   1. Archiving an isolated agent with nothing on its branch removes the worktree
///      AND the branch, and deletes the record from memory and from the store.
///   2. An UNMERGED commit keeps the branch: the worktree still goes, the branch is
///      retained and named in the report. This is the packet's headline prohibition.
///   3. Archiving stops a live runner.
///   4. A non-isolated agent's archive touches no worktree and no branch.
///   5. A record claiming a branch whose `cwd` is NOT under `.worktrees/` gets
///      nothing removed — the fixture is a real worktree a human created elsewhere in
///      the repository, which the derivation would otherwise hand to
///      `git worktree remove`.
///   6. Orphans: a worktree whose record was deleted behind the supervisor's back is
///      reported and repaired; a STALE record's worktree (the P2A.7 case: `cwd`
///      missing, so `restore` marks and skips it) is NOT an orphan, because the
///      record is still in the store.
///   7. A store that cannot be read completely makes orphan detection and repair
///      REFUSE, rather than treat the agents it could not read as orphans.
///   8. A store that cannot delete the record cleans up NOTHING.
///
/// Seven negative tests observed red at exit 1 with the final code, each quoted at its
/// assertion below. One mutation that is deliberately NOT red is recorded at MARK 2:
/// deleting the branch without the `isMerged` guard is caught by `git branch -d`
/// instead, and the destructive form of it (`-D`) is red in `runWorktreeMergedBranchCheck`.
/// C4 — persistence must not require a tile, and archiving quarantines rather
/// than deletes the transcript directory.
///
/// The sole production `saveSnapshot` call site used to live inside the TILE's
/// own event hook (`ContinuumApp.wireManagedAgentTile`'s `onSemanticTranscriptUpdated`),
/// so a child spawned without a tile — fan-out's common case at up to 16
/// concurrent children — persisted nothing at all. This agent is spawned with a
/// prompt and NEVER attached to a view.
@MainActor
private func checkTranscriptPersistenceWithoutTile(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-transcript-persist-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
    let transcriptRoot = root.appendingPathComponent("agent-transcripts", isDirectory: true)
    let transcriptStore = AgentTranscriptStore(root: transcriptRoot)

    let scripted = ScriptedAgentRunner(script: [
        .turnStarted(threadId: "provider-thread", turnId: "turn-1"),
        .contentDelta(threadId: "provider-thread", turnId: "turn-1", streamKind: .assistant, delta: "assistant-reply-text"),
        .turnCompleted(threadId: "provider-thread", turnId: "turn-1", outcome: .completed, errorMessage: nil)
    ])
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in scripted }, transcriptStore: transcriptStore)

    let promptText = "the-users-own-prompt-text-\(UUID().uuidString)"
    let id = supervisor.spawn(
        role: nil,
        prompt: promptText,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    guard supervisor.records[id]?.tileId == nil else {
        throw fail("transcript-persistence check: the spawned agent unexpectedly has a tile binding")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { !supervisor.isRunning(id) }) else {
        throw fail("transcript-persistence check: the scripted run never completed")
    }

    let sessionID = AgentTranscriptStore.canonicalSessionID(for: id)
    func containsParagraphText(_ document: AgentDocument, matching predicate: (String) -> Bool) -> Bool {
        document.entries.contains { entry in
            entry.blocks.contains { block in
                if case let .paragraph(inlines) = block.payload {
                    return inlines.contains { if case let .text(text) = $0 { return predicate(text) }; return false }
                }
                return false
            }
        }
    }
    func containsPrompt(_ document: AgentDocument) -> Bool {
        containsParagraphText(document) { $0 == promptText }
    }
    // Proves `ingestTranscriptEvent` (the provider-event half, distinct from
    // the prompt echo) actually ran without a tile — a witness that only
    // checked the prompt would stay green even if provider events were still
    // gated behind a tile, because the prompt echo is a separate code path.
    func containsAssistantReply(_ document: AgentDocument) -> Bool {
        containsParagraphText(document) { $0.contains("assistant-reply-text") }
    }

    // Debounced, not immediate — poll rather than assert on the first read.
    var loaded: AgentDocument?
    let deadline = Date().addingTimeInterval(3)
    while loaded == nil || !containsPrompt(loaded!) || !containsAssistantReply(loaded!) {
        loaded = try await transcriptStore.load(agentID: id, sessionID: sessionID)
        if let loaded, containsPrompt(loaded), containsAssistantReply(loaded) { break }
        if Date() >= deadline { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    guard let document = loaded else {
        throw fail("a tile-less agent persisted NOTHING under its canonical session id — the only saveSnapshot call site lived inside the tile")
    }
    guard containsPrompt(document) else {
        throw fail("the tile-less agent's persisted transcript does not contain its own prompt \(promptText.debugDescription)")
    }
    guard containsAssistantReply(document) else {
        throw fail("the tile-less agent's persisted transcript does not contain the assistant's streamed reply — provider events are not reaching the supervisor's own persistence path without a tile")
    }
    guard !document.entries.isEmpty else {
        throw fail("the tile-less agent's persisted transcript has no entries at all")
    }

    // MARK: archiving quarantines the directory, never `rm`s it

    let agentDirectory = transcriptRoot.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
    guard FileManager.default.fileExists(atPath: agentDirectory.path) else {
        throw fail("the transcript directory does not exist before archive: \(agentDirectory.path)")
    }
    supervisor.archive(id)
    // The archive-time quarantine move races the debounce timer only in theory
    // (the timer is cancelled synchronously inside `archive`); still poll, since
    // the move itself happens on a detached task.
    let quarantineDirectory = transcriptRoot.appendingPathComponent(
        "quarantine-\(id.rawValue.uuidString)", isDirectory: true)
    var quarantined = false
    let quarantineDeadline = Date().addingTimeInterval(3)
    while !quarantined {
        quarantined = FileManager.default.fileExists(atPath: quarantineDirectory.path)
        if quarantined { break }
        if Date() >= quarantineDeadline { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    guard quarantined else {
        throw fail("archiving an agent did not quarantine its transcript directory to \(quarantineDirectory.path) — a transcript is the user's own record of their work and must not be silently rm'd")
    }
    guard !FileManager.default.fileExists(atPath: agentDirectory.path) else {
        throw fail("archiving an agent left its transcript directory at the ORIGINAL path as well as the quarantined one: \(agentDirectory.path)")
    }
    // `moveItem` renames the whole subtree, so the session directory (and the
    // snapshot inside it) rode along; a directory that exists but is EMPTY
    // would mean something silently emptied it first.
    let quarantinedContents = (try? FileManager.default.contentsOfDirectory(atPath: quarantineDirectory.path)) ?? []
    guard !quarantinedContents.isEmpty else {
        throw fail("the quarantined transcript directory is empty — content was lost, not just moved")
    }

    return "tile-less agent persisted its own prompt without a tile, and archive quarantined (not deleted) its transcript directory"
}

@MainActor
private func checkArchiveCleanup(
    config: AgentModelConfig.Resolution,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-archive-cleanup-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
    let manager = WorktreeManager()

    // Only the agent given a prompt takes a runner, and it holds `run` open until
    // `stop` arrives — which is how "archive stopped a live runner" is observed as the
    // runner exiting rather than as a dictionary entry disappearing.
    let holding = ScriptedAgentRunner(script: [.sessionStateChanged(.running)], holdUntilStopped: true)
    let queue = ScriptedRunnerQueue([holding])
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0.record) })

    func spawnIsolated(_ prompt: String?, role: String) throws -> (id: AgentID, record: AgentRecord) {
        let id = try supervisor.spawn(
            role: role,
            prompt: prompt,
            cwd: repo,
            model: config.model,
            thinking: config.thinking,
            isolated: true
        )
        guard let record = supervisor.records[id] else {
            throw fail("the supervisor lost the isolated agent it spawned for \(role)")
        }
        return (id, record)
    }

    // MARK: 1 · nothing on the branch: the worktree AND the branch go

    let clean = try spawnIsolated(nil, role: "clean")
    guard let cleanBranch = clean.record.worktreeBranch else {
        throw fail("an isolated agent's record does not name its branch")
    }
    let cleanPath = URL(fileURLWithPath: clean.record.cwd, isDirectory: true)
    let listedBefore = try manager.list(repo: repo).count

    // Negative test observed red with the final code: with `archive` calling only
    // `store.delete` (no `cleanUpWorktree`) this reported
    //   FAIL: archiving a clean isolated agent left its worktree on disk: …/.worktrees/clean-…
    let cleanReport = supervisor.archive(clean.id)
    guard !FileManager.default.fileExists(atPath: cleanPath.path) else {
        throw fail("archiving a clean isolated agent left its worktree on disk: \(cleanPath.path)")
    }
    guard cleanReport.worktreeRemoved.map({ WorktreeManager.resolved($0) }) == WorktreeManager.resolved(cleanPath) else {
        throw fail("the report does not name the removed worktree: \(String(describing: cleanReport.worktreeRemoved?.path))")
    }
    guard try !manager.branchExists(repo: repo, branch: cleanBranch) else {
        throw fail("archiving a clean isolated agent left branch \(cleanBranch) behind; it held nothing the repository does not have")
    }
    guard cleanReport.branchDeleted == cleanBranch else {
        throw fail("the report does not name the deleted branch: \(String(describing: cleanReport.branchDeleted))")
    }
    guard try manager.list(repo: repo).count == listedBefore - 1 else {
        throw fail("git still lists the archived agent's worktree")
    }
    guard supervisor.records[clean.id] == nil else {
        throw fail("the archived agent is still in memory")
    }
    guard try store.load(id: clean.id) == nil, cleanReport.recordDeleted else {
        throw fail("the archived agent's record is still in the store")
    }

    // MARK: 2 · an unmerged commit keeps the branch

    let unmerged = try spawnIsolated(nil, role: "unmerged")
    guard let unmergedBranch = unmerged.record.worktreeBranch else {
        throw fail("the unmerged agent's record does not name its branch")
    }
    let unmergedPath = URL(fileURLWithPath: unmerged.record.cwd, isDirectory: true)
    try "the agent's work\n".write(to: unmergedPath.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
    try runIsolatedSpawnGit(["add", "agent.txt"], in: unmergedPath)
    try runIsolatedSpawnGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", "agent work",
    ], in: unmergedPath)

    // TWO INDEPENDENT GUARDS, and the honest note about which one this check catches:
    // deleting the branch unconditionally here (no `isMerged` guard) is NOT red, because
    // `WorktreeManager.deleteBranch` is `git branch -d` and git refuses it too — the
    // branch survives and lands in `branchRetained` carrying git's message instead of
    // this code's reason. The destructive mutation is `-d` -> `-D` in the manager, and
    // it is observed red in `runWorktreeMergedBranchCheck`. What the assertions below
    // do witness is that an unmerged branch survives an archive at all, which is the
    // packet's done-criterion.
    let unmergedReport = supervisor.archive(unmerged.id)
    guard !FileManager.default.fileExists(atPath: unmergedPath.path) else {
        throw fail("the committed worktree was clean, so archive should have removed it: \(unmergedPath.path)")
    }
    guard try manager.branchExists(repo: repo, branch: unmergedBranch) else {
        throw fail("archiving an agent with an unmerged commit DELETED branch \(unmergedBranch) — its work is gone")
    }
    guard unmergedReport.branchRetained?.branch == unmergedBranch, unmergedReport.branchDeleted == nil else {
        throw fail("the report does not say the branch was kept: deleted=\(String(describing: unmergedReport.branchDeleted)) retained=\(String(describing: unmergedReport.branchRetained?.branch))")
    }
    guard let retainedReason = unmergedReport.branchRetained?.reason, !retainedReason.isEmpty else {
        throw fail("a retained branch was reported without a reason")
    }
    // The commit is still reachable, which is the property the branch existing stands
    // in for.
    let reachable = try runIsolatedSpawnGit(["log", "--format=%s", "-1", unmergedBranch], in: repo)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard reachable == "agent work" else {
        throw fail("the retained branch no longer points at the agent's commit: \(reachable)")
    }

    // MARK: 3 · archive stops a live runner

    let live = try spawnIsolated("work on it", role: "live")
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { holding.runCount == 1 }) else {
        throw fail("the live agent's prompt never reached a runner")
    }
    guard supervisor.isRunning(live.id) else {
        throw fail("the live agent should have a prompt in flight")
    }
    // Negative test observed red with the final code: with the `stop` call removed
    // from `archive` this reported
    //   FAIL: archiving a live agent did not stop its runner: run() never returned
    let liveReport = supervisor.archive(live.id)
    guard liveReport.wasRunning else {
        throw fail("the report does not say a live runner was stopped")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { holding.completedRuns == 1 }) else {
        throw fail("archiving a live agent did not stop its runner: run() never returned")
    }
    guard !supervisor.isRunning(live.id), supervisor.records[live.id] == nil else {
        throw fail("the archived live agent is still around")
    }

    // MARK: 4 · a non-isolated agent's archive touches no git state

    let plainId = supervisor.spawn(
        role: "plain",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking
    )
    let listedBeforePlain = try manager.list(repo: repo)
    let plainReport = supervisor.archive(plainId)
    guard plainReport.worktreeRemoved == nil, plainReport.worktreeRetained == nil,
          plainReport.branchDeleted == nil, plainReport.branchRetained == nil else {
        throw fail("archiving a non-isolated agent made a worktree decision: \(plainReport.summary)")
    }
    guard try manager.list(repo: repo).map({ $0.path.path }) == listedBeforePlain.map({ $0.path.path }) else {
        throw fail("archiving a non-isolated agent changed the repository's worktrees")
    }
    guard FileManager.default.fileExists(atPath: repo.appendingPathComponent("README.md").path) else {
        throw fail("archiving a non-isolated agent damaged the project root")
    }
    guard supervisor.records[plainId] == nil, try store.load(id: plainId) == nil else {
        throw fail("the archived non-isolated agent's record survived")
    }

    // MARK: 5 · a branch-claiming record outside .worktrees/ is left alone

    // The fixture is the case that would actually be destroyed: a REAL worktree a
    // human created two levels down inside the repository, so the `<repo>/.worktrees/
    // <slug>` derivation would resolve to a genuine repository that genuinely knows
    // this path — and `git worktree remove` would take it. (A first attempt pointed the
    // record at the project root; that is not discriminating, because the derived
    // "repo" is then the temp directory, which is not a repository at all, so the
    // removal fails for a reason that has nothing to do with the guard.)
    let manual = repo.appendingPathComponent("manual", isDirectory: true)
        .appendingPathComponent("tree", isDirectory: true)
    try runIsolatedSpawnGit(["worktree", "add", "-q", "-b", "manual", manual.path], in: repo)

    // Written straight to the store, so nothing in this process ever spawned it: this
    // is a hand-edited or migrated record.
    let mislabelledId = AgentID(rawValue: UUID())
    let now = Date()
    try store.upsert(AgentRecord(
        id: mislabelledId,
        displayName: "mislabelled",
        role: "mislabelled",
        model: config.model,
        thinking: config.thinking,
        cwd: manual.path,
        worktreeBranch: "manual",
        projectId: nil,
        createdAt: now,
        lastActivityAt: now,
        tileId: nil
    ))
    let adopting = AgentSupervisor(store: store, makeRunner: { ScriptedRunnerQueue([]).next($0.record) })
    _ = adopting.restore()
    guard adopting.records[mislabelledId] != nil else {
        throw fail("the mislabelled record was not adopted, so the guard is untested")
    }
    let listedBeforeMislabelled = try manager.list(repo: repo).map { $0.path.path }
    // Negative test observed red with the final code: with the container check in
    // `cleanUpWorktree` bypassed this reported
    //   FAIL: archiving a record that claims a worktree outside .worktrees/ removed
    //   it: Optional("…/repo/manual/tree")
    let mislabelledReport = adopting.archive(mislabelledId)
    guard mislabelledReport.worktreeRemoved == nil else {
        throw fail("archiving a record that claims a worktree outside \(WorktreeManager.containerDirectoryName)/ removed it: \(String(describing: mislabelledReport.worktreeRemoved?.path))")
    }
    guard mislabelledReport.worktreeRetained != nil, mislabelledReport.branchRetained != nil else {
        throw fail("the mislabelled record was cleaned up silently: \(mislabelledReport.summary)")
    }
    guard try manager.list(repo: repo).map({ $0.path.path }) == listedBeforeMislabelled else {
        throw fail("archiving a mislabelled record changed the repository's worktrees")
    }
    guard FileManager.default.fileExists(atPath: manual.appendingPathComponent("README.md").path) else {
        throw fail("archiving a mislabelled record destroyed the human's worktree at \(manual.path)")
    }
    guard try manager.branchExists(repo: repo, branch: "manual") else {
        throw fail("archiving a mislabelled record deleted the human's branch `manual`")
    }

    // MARK: 6 · orphans, and what is NOT one

    let orphanSupervisor = AgentSupervisor(store: store, makeRunner: { ScriptedRunnerQueue([]).next($0.record) })
    func spawnOn(
        _ supervisor: AgentSupervisor,
        role: String,
        parentAgentID: AgentID? = nil
    ) throws -> AgentRecord {
        let id = try supervisor.spawn(
            role: role,
            prompt: nil,
            cwd: repo,
            model: config.model,
            thinking: config.thinking,
            parentAgentID: parentAgentID,
            isolated: true
        )
        guard let record = supervisor.records[id] else { throw fail("lost the \(role) agent") }
        return record
    }
    let keptAgent = try spawnOn(orphanSupervisor, role: "kept")
    // This child is the resource-bookkeeping counterpart of a UI child that may
    // be omitted by presentation: its durable record still owns a worktree and
    // must remain in the known set after relaunch.
    let cappedChildAgent = try spawnOn(
        orphanSupervisor, role: "capped-child", parentAgentID: keptAgent.id)
    let orphanAgent = try spawnOn(orphanSupervisor, role: "orphaned")
    // Behind the supervisor's back: the record file goes, nothing else does.
    try store.delete(id: orphanAgent.id)

    // A supervisor that never held either record — it only knows what the store says.
    let afterRelaunch = AgentSupervisor(store: store, makeRunner: { ScriptedRunnerQueue([]).next($0.record) })
    _ = afterRelaunch.restore()
    let orphans = try afterRelaunch.orphanWorktrees(repo: repo)
    // Negative test observed red with the final code: with `knownAgentDirectories`
    // returning `[]` this reported
    //   FAIL: orphan detection reported 2 worktrees, expected only the one whose
    //   record was deleted
    guard orphans.count == 1 else {
        throw fail("orphan detection reported \(orphans.count) worktrees, expected only the one whose record was deleted: \(orphans.map { $0.path.lastPathComponent })")
    }
    guard !orphans.contains(where: {
        WorktreeManager.resolved($0.path) == WorktreeManager.resolved(URL(fileURLWithPath: cappedChildAgent.cwd))
    }) else {
        throw fail("a capped child worktree was classified as an orphan even though its stored child record remained in the known set")
    }
    guard FileManager.default.fileExists(atPath: cappedChildAgent.cwd) else {
        throw fail("the capped child's known worktree disappeared before repair")
    }
    guard WorktreeManager.resolved(orphans[0].path) == WorktreeManager.resolved(URL(fileURLWithPath: orphanAgent.cwd)) else {
        throw fail("orphan detection named \(orphans[0].path.path), expected \(orphanAgent.cwd)")
    }
    let repaired = try afterRelaunch.repairWorktrees(repo: repo)
    guard repaired.removed.count == 1, repaired.retained.isEmpty else {
        throw fail("repair removed \(repaired.removed.count) and retained \(repaired.retained.count) worktrees, expected 1 and 0")
    }
    guard !FileManager.default.fileExists(atPath: orphanAgent.cwd) else {
        throw fail("repair left the orphan's worktree on disk")
    }
    guard FileManager.default.fileExists(atPath: keptAgent.cwd) else {
        throw fail("repair deleted the LIVE agent's worktree")
    }
    if let orphanBranch = orphanAgent.worktreeBranch {
        guard try manager.branchExists(repo: repo, branch: orphanBranch) else {
            throw fail("repair deleted branch \(orphanBranch) — it is all that was left of that agent")
        }
    }

    // …and a STALE record's worktree is not an orphan. `restore` marks a record whose
    // `cwd` is missing and does not adopt it (P2A.7), so a known-set built from live
    // records alone would prune the one thing that could bring that agent back.
    let staleAgent = try spawnOn(afterRelaunch, role: "stale")
    try FileManager.default.removeItem(at: URL(fileURLWithPath: staleAgent.cwd))
    let afterSecondRelaunch = AgentSupervisor(store: store, makeRunner: { ScriptedRunnerQueue([]).next($0.record) })
    let restored = afterSecondRelaunch.restore()
    guard restored.stale.contains(staleAgent.id) else {
        throw fail("the stale agent was not marked stale, so this case is untested")
    }
    // Negative test observed red with the final code: with `knownAgentDirectories`
    // reading only `records.values` (no `store.loadAll()`) this reported
    //   FAIL: a STALE agent's worktree was reported as an orphan — its record is
    //   still in the store
    let staleOrphans = try afterSecondRelaunch.orphanWorktrees(repo: repo)
    guard !staleOrphans.contains(where: {
        WorktreeManager.resolved($0.path) == WorktreeManager.resolved(URL(fileURLWithPath: staleAgent.cwd))
    }) else {
        throw fail("a STALE agent's worktree was reported as an orphan — its record is still in the store")
    }
    guard try store.load(id: staleAgent.id) != nil else {
        throw fail("the stale agent's record disappeared from the store")
    }
    if let staleBranch = staleAgent.worktreeBranch {
        guard try manager.branchExists(repo: repo, branch: staleBranch) else {
            throw fail("the stale agent's branch \(staleBranch) was deleted")
        }
    }

    // MARK: 7 · a store it cannot fully read makes orphan detection REFUSE

    // `AgentStore.loadAll` skips a record it cannot decode, which for the inbox is
    // correct and for a DESTRUCTIVE sweep is a silently narrowed known set: that
    // agent's worktree would be an orphan and repair would delete it.
    //
    // Negative test observed red with the final code: with `knownAgentDirectories`
    // warning instead of throwing on the count mismatch this reported
    //   FAIL: a record file that cannot be decoded did not stop orphan detection;
    //   it reported 0 orphan(s)
    // — zero, and that is the point: a narrowed known set answers confidently, and the
    // only thing standing between that answer and a deleted checkout is which
    // worktrees happen to be on disk at the time.
    let corrupt = store.layout.agentsDirectory.appendingPathComponent("not-a-record.json")
    try "{ this is not an AgentRecord".write(to: corrupt, atomically: true, encoding: .utf8)
    do {
        let reported = try afterSecondRelaunch.orphanWorktrees(repo: repo)
        throw fail("a record file that cannot be decoded did not stop orphan detection; it reported \(reported.count) orphan(s)")
    } catch let refusal as AgentSupervisor.CleanupRefusal {
        guard case .unreadableAgentStore = refusal else { throw fail("unexpected refusal \(refusal)") }
    }
    do {
        _ = try afterSecondRelaunch.repairWorktrees(repo: repo)
        throw fail("repair ran against a store it could not fully read")
    } catch is AgentSupervisor.CleanupRefusal {
        // Expected: the destructive call refuses on the same grounds.
    }
    try FileManager.default.removeItem(at: corrupt)
    _ = try afterSecondRelaunch.orphanWorktrees(repo: repo)

    // MARK: 8 · a store that refuses the delete cleans up NOTHING

    // The durable record and the worktree must not disagree: if the record survives,
    // the checkout it names has to survive too, or the next launch restores an agent
    // whose directory is gone.
    //
    // Negative test observed red with the final code: with `archive` cleaning up before
    // `store.delete` (and not returning on failure) this reported
    //   FAIL: archive removed the worktree of an agent whose record it could not
    //   delete: …/.worktrees/undeletable-…
    let undeletable = try spawnOn(afterSecondRelaunch, role: "undeletable")
    // A real store failure, not an injected fake: the records directory is made
    // read-only, so `removeItem` cannot unlink the file while `loadAll` can still read
    // it. (A first attempt replaced the record file with a directory; `removeItem`
    // deletes those recursively, so the delete succeeded and the case was vacuous.)
    let recordsDirectory = store.layout.agentsDirectory
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recordsDirectory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordsDirectory.path) }
    let undeletableReport = afterSecondRelaunch.archive(undeletable.id)
    guard !undeletableReport.recordDeleted else {
        throw fail("the store reported deleting a record it cannot delete, so this case is untested")
    }
    guard undeletableReport.worktreeRemoved == nil else {
        throw fail("archive removed the worktree of an agent whose record it could not delete: \(String(describing: undeletableReport.worktreeRemoved?.path))")
    }
    guard FileManager.default.fileExists(atPath: undeletable.cwd) else {
        throw fail("the worktree of an agent whose record could not be deleted is gone")
    }
    guard afterSecondRelaunch.records[undeletable.id] != nil else {
        throw fail("a failed archive dropped the agent from memory anyway")
    }

    supervisor.stopAll()
    return "archive removed a clean agent's worktree and branch, KEPT the branch of one with an unmerged commit, stopped a live runner, left a non-isolated agent's repo untouched, refused to touch a project root a record wrongly claimed, repaired 1 orphan while leaving a live child-resource record and a stale agent alone"
}

/// A temp repository with one commit — `git worktree add` needs a HEAD. The `-c`
/// identity keeps the check independent of the host's global git config, as
/// `WorktreeManagerChecks` does for the same reason.
/// Writes one `.pi/agents/<id>.md` role file into a fixture repository (P2D.3).
///
/// `name` is always declared, because `RoleRegistry` requires it — a file without one
/// is deliberately not a role, and that exclusion is asserted directly in
/// `runRoleRegistryChecks`.
private func writeSpawnCheckRole(
    in repo: URL,
    id: String,
    model: String? = nil,
    reasoning: String? = nil,
    tools: String? = nil
) throws {
    let directory = repo.appendingPathComponent(RoleRegistry.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var frontmatter = ["name: \(id)"]
    if let model { frontmatter.append("model: \(model)") }
    if let reasoning { frontmatter.append("reasoning: \(reasoning)") }
    if let tools { frontmatter.append("tools: \(tools)") }
    let body = "---\n\(frontmatter.joined(separator: "\n"))\n---\n\nYou are the \(id).\n"
    try body.write(to: directory.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
}

private func makeIsolatedSpawnRepo(at root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runIsolatedSpawnGit(["init", "-q", "-b", "main"], in: root)
    try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runIsolatedSpawnGit(["add", "README.md"], in: root)
    try runIsolatedSpawnGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", "seed",
    ], in: root)
}

@discardableResult
private func runIsolatedSpawnGit(_ arguments: [String], in directory: URL) throws -> String {
    struct GitError: Error, CustomStringConvertible { let description: String }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitError(description: "git \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(String(data: errData, encoding: .utf8) ?? "")")
    }
    return String(data: outData, encoding: .utf8) ?? ""
}

/// P2C.4 — the tile SAYS which checkout its agent is about to touch.
///
/// The whole path, against a real temp repository: a real isolated spawn, a real
/// `ManagedAgentTileNSView`, the production `attach(agentID:supervisor:)`, and the
/// chip text read back off the view. Nothing here sets the chip directly — that is
/// what makes it a check of the wiring rather than of `BranchChipNSView.display`.
///
/// Five properties:
///   1. An isolated agent's tile shows its branch, with no warning: its checkout IS
///      on the branch it was given, which is the ordinary case.
///   2. A shared-checkout agent's tile shows the branch the PROJECT is on, marked
///      shared — the "which of five agents is about to touch my tree" question.
///   3. A tile nobody has told anything shows NO chip, rather than implying a
///      shared checkout.
///   4. THE WARNING IS REACHABLE, THROUGH THE PRODUCTION REFRESH: a real `git
///      checkout` inside the agent's own worktree, then an ordinary `.turnCompleted`
///      into the tile — no hand-written re-apply — and the chip flags it and names
///      both branches. Not a synthesized context; git moved the checkout.
///   5. The branch is read from CACHE: re-deriving the context ten times costs no
///      further `git rev-parse`, because the chip re-renders per streamed token.
@MainActor
private func checkBranchChip(
    config: AgentModelConfig.Resolution,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-branch-chip-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })

    func makeTile(_ title: String) -> ManagedAgentTileNSView {
        let view = ManagedAgentTileNSView(tile: Tile(
            id: UUID(),
            kind: .managedAgent,
            title: title,
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        ))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        return view
    }

    // MARK: 3 · a tile that has been told nothing shows nothing
    let untold = makeTile("untold")
    guard untold.qaBranchChipText == nil else {
        throw fail("a tile with no branch context shows \(untold.qaBranchChipText ?? "nil") — it must show no chip at all")
    }

    // MARK: 1 · the isolated agent
    let isolatedId = try supervisor.spawn(
        role: "implementer",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        isolated: true
    )
    guard let isolated = supervisor.records[isolatedId], let branch = isolated.worktreeBranch else {
        throw fail("the isolated spawn produced no record with a branch")
    }
    let isolatedTile = makeTile("isolated")
    isolatedTile.attach(agentID: isolatedId, supervisor: supervisor)
    guard let isolatedChip = isolatedTile.qaBranchChipText else {
        throw fail("an isolated agent's tile shows NO branch — the packet's own done-criterion")
    }
    guard isolatedChip.contains(branch) else {
        throw fail("the chip reads \(isolatedChip), which does not name the agent's branch \(branch)")
    }
    guard !isolatedTile.qaBranchChipIsWarning else {
        throw fail("an isolated agent sitting ON its own branch was flagged as a mismatch: \(isolatedChip)")
    }

    // MARK: 2 · the shared-checkout agent
    let sharedId = supervisor.spawn(
        role: "reviewer",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking
    )
    let sharedTile = makeTile("shared")
    sharedTile.attach(agentID: sharedId, supervisor: supervisor)
    guard let sharedChip = sharedTile.qaBranchChipText else {
        throw fail("a shared-checkout agent's tile shows no branch — you cannot tell it apart from an isolated one")
    }
    guard sharedChip.contains("main") else {
        throw fail("a shared agent's chip reads \(sharedChip), not the project's own branch (main)")
    }
    guard sharedChip.contains(BranchChipNSView.sharedSuffix) else {
        throw fail("a shared agent's chip \(sharedChip) does not say it is the project's own checkout")
    }
    guard !sharedTile.qaBranchChipIsWarning else {
        throw fail("an agent working in YOUR checkout was flagged as being on the wrong branch: \(sharedChip)")
    }

    // MARK: 5 · the reads are cached
    let readsBefore = supervisor.qaBranchGitReads
    for _ in 0..<10 { _ = supervisor.branchContext(for: isolatedId) }
    guard supervisor.qaBranchGitReads == readsBefore else {
        throw fail(
            "ten re-renders cost \(supervisor.qaBranchGitReads - readsBefore) extra git call(s) — "
                + "the chip re-renders per streamed token, so the read has to come from cache"
        )
    }

    // MARK: 5b · the activation path never shells out at all
    //
    // The sidebar rebuild runs on app activate/resign, on the main thread; the
    // TTL variant froze every app switch for ~0.4 s in git spawns (sampled live
    // 2026-08-19). Its replacement reads through `branchContextCachedOnly`,
    // whose contract is ZERO reads even cold, serving what the warmer stored.
    supervisor.invalidateCheckedOutBranches()
    let coldReads = supervisor.qaBranchGitReads
    let cold = supervisor.branchContextCachedOnly(for: isolatedId)
    guard supervisor.qaBranchGitReads == coldReads else {
        throw fail("a cachedOnly branch read shelled out on a COLD cache — the activation path would freeze again")
    }
    guard cold?.checkedOutBranch == nil else {
        throw fail("a cold cachedOnly read invented a branch: \(String(describing: cold?.checkedOutBranch))")
    }
    let isolatedRepo = URL(fileURLWithPath: isolated.cwd, isDirectory: true)
    supervisor.storeCheckedOutBranch("warmed-branch", repo: isolatedRepo)
    guard supervisor.branchContextCachedOnly(for: isolatedId)?.checkedOutBranch == "warmed-branch" else {
        throw fail("a value the warmer stored was not served by the cachedOnly path")
    }
    guard supervisor.qaBranchGitReads == coldReads else {
        throw fail("serving a warmed value cost a git read")
    }
    supervisor.invalidateCheckedOutBranches()

    // MARK: 4 · the agent leaves the branch it was given, for real
    //
    // The refresh goes through the PRODUCTION path — an event the tile ingests —
    // not a hand-written `applyBranchContext`. A turn is the only thing that can move
    // an agent's checkout, so `.turnCompleted` is where the tile re-reads it; a check
    // that invalidated and re-applied by hand would pass over a tile that never
    // refreshes at all (the cross-review's finding).
    try runIsolatedSpawnGit(["checkout", "-q", "-b", "wandered-off"], in: URL(fileURLWithPath: isolated.cwd))
    isolatedTile.ingest(.turnCompleted(
        threadId: AgentSupervisor.threadId(for: isolatedId),
        turnId: "branch-chip-turn",
        outcome: .completed,
        errorMessage: nil
    ))
    guard isolatedTile.qaBranchChipIsWarning else {
        throw fail(
            "the agent's checkout moved to wandered-off and the tile still reads "
                + "\(isolatedTile.qaBranchChipText ?? "nil") with no warning"
        )
    }
    guard let wanderedChip = isolatedTile.qaBranchChipText, wanderedChip.contains("wandered-off") else {
        throw fail("the warning chip \(isolatedTile.qaBranchChipText ?? "nil") does not name the branch the work is actually landing on")
    }
    guard let tooltip = isolatedTile.qaBranchChipTooltip, tooltip.contains(branch), tooltip.contains("wandered-off") else {
        throw fail("the warning names only one of the two branches: \(isolatedTile.qaBranchChipTooltip ?? "nil")")
    }

    return "a tile names its checkout (isolated \(isolatedChip), shared \(sharedChip), moved \(wanderedChip)), an unbound tile shows none, and 10 re-renders cost 0 git calls"
}

/// P3.3 — attention is a separate axis from state, and read-state is LOCAL.
///
/// Driven through real turns from a `ScriptedRunnerQueue` (one runner per `send`,
/// because the supervisor makes a new one per prompt), so "a turn completed" is an
/// event travelling the production `deliver` path rather than a flag set by hand.
///
/// Six properties:
///   1. A turn that completes while you are looking elsewhere leaves the agent
///      `.unread` — the packet's done-criterion.
///   2. A deliberate focus clears it to `.none`.
///   3. A turn completing WHILE FOCUSED never sets it. Without this the mark means
///      "this agent has ever finished a turn", which is every agent.
///   4. Focus leaving re-arms it: the next turn is unread again.
///   5. `focusTile` clears through the tile binding, which is how focus arrives on
///      the desktop (`FocusBroker` speaks tile ids).
///   6. The watermark IS durable but remains local and unsynced: the record carries
///      a visit timestamp rather than a derived unread flag, and a second supervisor
///      restoring the same store derives the same comparison.
///
/// The precedence between `unread` and `woke` is the vocabulary's, checked in
/// `ContinuumRevivedAgentUIChecks/AgentInboxRowChecks.swift`; what is checked here
/// is that the supervisor routes its one fact through `InboxAttention.resolve`
/// rather than answering with a second opinion.
///
/// Three negative tests observed red at exit 1 with the final code, each a
/// production edit to the section above:
/// · `focus(agentID:)` no longer advances the durable watermark →
///   `FAIL: read-state: focusing the agent left it unread`
/// · `deliver`'s focused-completion watermark update dropped, so a watched turn
///   reappears after relaunch →
///   `FAIL: read-state: the completion/watermark comparison was lost across relaunch`
/// · the completion timestamp was derived from `lastActivityAt` instead of the
///   turn-completion arm → the mark moved when unrelated metadata arrived.
///
/// The forbidden-key scan is still vacuity-guarded on `id`, and explicitly
/// requires `lastVisitedAtReferenceInterval`; a derived `unread`/`focus` boolean
/// remains forbidden even though the local watermark is durable.
@MainActor
private func checkReadState(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-read-state-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)

    let provider = "provider-thread"
    func turn(_ id: String) -> [AgentRuntimeEvent] {
        [
            .turnStarted(threadId: provider, turnId: id),
            .contentDelta(threadId: provider, turnId: id, streamKind: .assistant, delta: "…"),
            .turnCompleted(threadId: provider, turnId: id, outcome: .completed, errorMessage: nil),
            .sessionStateChanged(.ready)
        ]
    }
    let queue = ScriptedRunnerQueue((1 ... 4).map { ScriptedAgentRunner(script: turn("t\($0)")) })
    var persistedWriteCount = 0
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { queue.next($0.record) },
        // Count the actual production store writes, not an in-memory helper. The
        // closure still delegates to AgentStore.upsert, so every count is a real
        // AtomicWriter persistence that the readback below can observe.
        upsertRecord: { record in
            persistedWriteCount += 1
            try store.upsert(record)
        })

    let tileId = UUID()
    let agentId = supervisor.spawn(
        role: "reviewer",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileId
    )
    let inbox = EventInbox()
    let stream = supervisor.events(for: agentId)
    let task = Task { @MainActor in for await event in stream { inbox.append(event) } }
    defer { task.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 1 }) else {
        throw fail("read-state: the subscriber never registered")
    }

    // WS4: this check is HEADLESS — no window, no canvas, no responder — so it
    // supplies the active-view facts the app supplies in production. `watchedAgent`
    // is this fixture's statement of "the human is looking at this one"; that the
    // APP derives those facts from real AppKit state (and refuses after a real
    // resign) is what `--completion-awareness-check` proves.
    var watchedAgent: AgentID?
    let viewedFacts = AgentActiveViewFacts(
        appActive: true, windowNotUpstaged: true, windowVisible: true,
        windowOcclusionVisible: true, tileMounted: true, responderInTile: true,
        focusScopeIsTile: true, modalPresented: false)
    supervisor.activeViewFactsProvider = { id in id == watchedAgent ? viewedFacts : .away }

    var turnsRun = 0
    func runOneTurn(_ prompt: String) async throws {
        let before = inbox.events.count
        supervisor.send(prompt, to: agentId)
        guard await waitUntil(timeout: 10, pollInterval: 0.02, { inbox.events.count == before + 4 }) else {
            throw fail("read-state: the turn `\(prompt)` did not complete — \(inbox.events.count - before) of 4 events arrived")
        }
        turnsRun += 1
    }

    // 1 · nothing is unread before anything has happened. Establish the local
    // watermark once before leaving the agent; an older record with no watermark
    // is intentionally treated as already-read, while a new completion after a
    // real visit is unread.
    guard supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: a freshly spawned agent is already \(supervisor.attention(for: agentId).rawValue)")
    }
    watchedAgent = agentId
    supervisor.focus(agentID: agentId)
    watchedAgent = nil
    supervisor.focus(agentID: nil)
    try await runOneTurn("first prompt")
    guard supervisor.attention(for: agentId) == .unread else {
        throw fail("read-state: a turn completed while you were looking elsewhere and the agent reads \(supervisor.attention(for: agentId).rawValue), not unread")
    }
    // The axis is routed through the vocabulary, not answered twice: the same
    // unread agent is `woke` once P4.6's fact holds.
    guard supervisor.attention(for: agentId, raisedHand: true) == .woke else {
        throw fail("read-state: a raised hand on an unread agent reads \(supervisor.attention(for: agentId, raisedHand: true).rawValue), not woke")
    }

    // 2 · a deliberate focus advances the watermark and clears it, without
    // touching the metadata timestamp used by the frozen inbox order.
    let activityBeforeVisit = supervisor.records[agentId]?.lastActivityAt
    supervisor.focus(agentID: agentId)
    guard supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: focusing the agent left it \(supervisor.attention(for: agentId).rawValue)")
    }
    guard supervisor.records[agentId]?.lastActivityAt == activityBeforeVisit else {
        throw fail("read-state: focusing an agent changed lastActivityAt and can reorder the inbox")
    }
    guard let visitedAt = supervisor.records[agentId]?.lastVisitedAt else {
        throw fail("read-state: focus did not leave a durable visit watermark")
    }
    supervisor.focus(agentID: agentId, now: visitedAt.addingTimeInterval(-1))
    guard supervisor.records[agentId]?.lastVisitedAt == visitedAt else {
        throw fail("read-state: an out-of-order visit rewound the monotonic watermark")
    }
    guard supervisor.markUnread(agentID: agentId) && supervisor.attention(for: agentId) == .unread else {
        throw fail("read-state: explicit mark-unread did not rewind the watermark")
    }
    supervisor.focus(agentID: agentId)
    guard supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: a focus after mark-unread did not clear the derived mark")
    }

    // 3 · a turn completing while you are here is not unread.
    watchedAgent = agentId
    try await runOneTurn("second prompt")
    guard supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: a turn you watched finish was marked \(supervisor.attention(for: agentId).rawValue) — the mark would then mean `has ever finished a turn`")
    }

    // 4 · focus leaves, and the next turn is unread again.
    watchedAgent = nil
    supervisor.focus(agentID: nil)
    try await runOneTurn("third prompt")
    guard supervisor.attention(for: agentId) == .unread else {
        throw fail("read-state: focus left and the next turn still reads \(supervisor.attention(for: agentId).rawValue)")
    }

    // 5 · focus by TILE, which is the shape the desktop's focus actually has.
    guard supervisor.agent(forTile: tileId) == agentId else {
        throw fail("read-state: the agent is not bound to its tile, so the tile-keyed focus is untested")
    }
    watchedAgent = agentId
    supervisor.focusTile(tileId)
    guard supervisor.focusedAgentID == agentId, supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: focusing the agent's TILE left it \(supervisor.attention(for: agentId).rawValue)")
    }
    // A tile that shows no agent focuses nothing, rather than leaving the previous
    // agent armed — otherwise clicking a terminal would keep an agent's turns read.
    watchedAgent = nil
    supervisor.focusTile(UUID())
    guard supervisor.focusedAgentID == nil else {
        throw fail("read-state: focusing an unrelated tile left \(String(describing: supervisor.focusedAgentID)) armed")
    }
    try await runOneTurn("fourth prompt")
    guard supervisor.attention(for: agentId) == .unread else {
        throw fail("read-state: a turn after focus moved to another tile reads \(supervisor.attention(for: agentId).rawValue)")
    }

    // 5b · P6.4 production-seam ordering and persistence proof. Add two settled
    // records whose end order falls back to lastActivityAt, then VISIT the older
    // settled target. If focus restamps activity it jumps ahead of its peer — the
    // exact settled-block regression an active-only ordering check cannot expose.
    struct SortDateSnapshot: Equatable {
        let id: UUID
        let createdAt: Date
        let settledAt: Date?
        let lastActivityAt: Date
    }
    let sortProbeID = AgentID(rawValue: UUID(uuidString: "2B640000-0000-4000-8000-0000000000F1")!)
    let sortPeerID = AgentID(rawValue: UUID(uuidString: "2B640000-0000-4000-8000-0000000000F2")!)
    let sortNow = (supervisor.records[agentId]?.lastActivityAt ?? Date()).addingTimeInterval(1)
    let sortProbeEndAt = sortNow.addingTimeInterval(-120)
    let sortPeerEndAt = sortNow.addingTimeInterval(-60)
    try store.upsert(AgentRecord(
        id: sortProbeID,
        displayName: "Older settled visit target",
        role: "reviewer",
        model: config.model,
        thinking: config.thinking,
        cwd: cwd.path,
        createdAt: sortNow.addingTimeInterval(-240),
        lastActivityAt: sortProbeEndAt,
        settledOverride: .settled
    ))
    try store.upsert(AgentRecord(
        id: sortPeerID,
        displayName: "Newer settled peer",
        role: "reviewer",
        model: config.model,
        thinking: config.thinking,
        cwd: cwd.path,
        createdAt: sortNow.addingTimeInterval(-180),
        lastActivityAt: sortPeerEndAt,
        settledOverride: .settled
    ))
    let sortRestore = supervisor.restore()
    guard sortRestore.restored.contains(sortProbeID),
          sortRestore.restored.contains(sortPeerID) else {
        throw fail("read-state: both settled sort probes must reach the production supervisor seam")
    }
    func inboxSortSnapshot() -> (ids: [UUID], dates: [SortDateSnapshot]) {
        let rows = supervisor.records.values
            .filter { $0.archivedAt == nil }
            .map { record in
                AgentInboxRow(
                    id: record.id.rawValue,
                    title: record.humanDisplayName,
                    state: .ready,
                    attention: supervisor.attention(for: record.id, now: sortNow),
                    lifecycle: record.lifecycle(now: sortNow),
                    createdAt: record.createdAt)
            }
        let dates = supervisor.records.values
            .filter { $0.archivedAt == nil }
            .sorted(by: AgentStore.isOrderedBefore)
            .map { record in
                SortDateSnapshot(
                    id: record.id.rawValue,
                    createdAt: record.createdAt,
                    settledAt: record.settledAt,
                    lastActivityAt: record.lastActivityAt)
            }
        return (InboxSort.sortForInbox(rows: rows).map(\.id), dates)
    }
    let sortBeforeVisit = inboxSortSnapshot()
    guard sortBeforeVisit.ids.count == supervisor.records.values.filter({ $0.archivedAt == nil }).count,
          let peerIndex = sortBeforeVisit.ids.firstIndex(of: sortPeerID.rawValue),
          let targetIndex = sortBeforeVisit.ids.firstIndex(of: sortProbeID.rawValue),
          peerIndex < targetIndex else {
        throw fail("read-state: the pre-visit settled tail did not order the newer peer before the fallback-dated target — ids \(sortBeforeVisit.ids)")
    }
    let sortTargetActivityBefore = supervisor.records[sortProbeID]?.lastActivityAt
    supervisor.focus(agentID: sortProbeID, now: sortNow)
    let sortAfterSettledVisit = inboxSortSnapshot()
    guard sortAfterSettledVisit.ids == sortBeforeVisit.ids,
          sortAfterSettledVisit.dates == sortBeforeVisit.dates,
          supervisor.records[sortProbeID]?.lastActivityAt == sortTargetActivityBefore else {
        throw fail("read-state: visiting the settled fallback-dated target reordered history or changed its activity stamp — before \(sortBeforeVisit.ids), after \(sortAfterSettledVisit.ids)")
    }
    let writesBeforeVisit = persistedWriteCount
    let activityBeforePersistenceVisit = supervisor.records[agentId]?.lastActivityAt
    guard let completionAt = supervisor.records[agentId]?.runCompletedAt else {
        throw fail("read-state: the production completion seam did not stamp runCompletedAt")
    }
    let unreadClearingVisitAt = completionAt.addingTimeInterval(1)
    supervisor.focus(agentID: agentId, now: unreadClearingVisitAt)
    guard supervisor.attention(for: agentId, now: unreadClearingVisitAt) == .none else {
        throw fail("read-state: an unread-clearing visit left the production row \(supervisor.attention(for: agentId, now: unreadClearingVisitAt).rawValue)")
    }
    let writesAfterUnreadClear = persistedWriteCount
    guard writesAfterUnreadClear > writesBeforeVisit,
          try store.load(id: agentId)?.lastVisitedAt == unreadClearingVisitAt else {
        throw fail("read-state: unread-clearing visit was throttled or stayed in memory — writes \(writesBeforeVisit) -> \(writesAfterUnreadClear), disk watermark \(String(describing: try store.load(id: agentId)?.lastVisitedAt))")
    }
    // Ordinary visits inside the ten-second window still advance memory, but do
    // not write. Read the file back to prove this is actual persistence throttling.
    let throttledVisitAt = unreadClearingVisitAt.addingTimeInterval(1)
    supervisor.focus(agentID: agentId, now: throttledVisitAt)
    guard supervisor.records[agentId]?.lastVisitedAt == throttledVisitAt,
          persistedWriteCount == writesAfterUnreadClear,
          try store.load(id: agentId)?.lastVisitedAt == unreadClearingVisitAt else {
        throw fail("read-state: a visit inside the throttle wrote unexpectedly or failed to advance memory — writes \(writesAfterUnreadClear) -> \(persistedWriteCount), disk watermark \(String(describing: try store.load(id: agentId)?.lastVisitedAt))")
    }
    let sortAfterVisit = inboxSortSnapshot()
    guard sortAfterVisit.ids == sortBeforeVisit.ids,
          sortAfterVisit.dates == sortBeforeVisit.dates,
          supervisor.records[agentId]?.lastActivityAt == activityBeforePersistenceVisit else {
        throw fail("read-state: visiting changed the complete InboxSort order or an activity/sort timestamp — before \(sortBeforeVisit.ids), after \(sortAfterVisit.ids)")
    }
    guard supervisor.markUnread(agentID: agentId, now: throttledVisitAt.addingTimeInterval(1)),
          supervisor.attention(for: agentId) == .unread,
          try store.load(id: agentId)?.lastVisitedAt == .distantPast else {
        throw fail("read-state: explicit mark-unread did not durably rewind the watermark")
    }

    // 6 · LOCAL ONLY. Read-state is per-human and per-device, so it may not be in
    //     the record — the type `AgentStore` writes and the companion publishes.
    guard let record = supervisor.records[agentId] else {
        throw fail("read-state: the agent lost its record")
    }
    let encoded = try JSONEncoder().encode(record)
    guard let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw fail("read-state: the record did not encode as an object")
    }
    // Vacuity guard: the scan below only means something if it can see the record's
    // real keys.
    guard fields["id"] != nil else {
        throw fail("read-state: the encoded record has no `id` key, so this scan is blind: \(fields.keys.sorted())")
    }
    let forbidden = ["unread", "attention", "focused", "seen", "viewed"]
    for key in fields.keys {
        let lowered = key.lowercased()
        if let hit = forbidden.first(where: { lowered.contains($0) }) {
            throw fail("read-state: AgentRecord carries `\(key)` (matches `\(hit)`) — the durable watermark must remain a local timestamp, not a derived unread/focus flag")
        }
    }
    guard fields["lastVisitedAtReferenceInterval"] != nil else {
        throw fail("read-state: the local watermark was not encoded, so a relaunch could not preserve this device's read boundary")
    }
    // And the store round-trip says the same thing from the other side: a second
    // supervisor over the SAME directory restores the agent and derives the same
    // unread mark from completion time versus the persisted local watermark.
    let relaunched = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root), makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let report = relaunched.restore()
    guard report.restored.contains(agentId) else {
        throw fail("read-state: the relaunched supervisor did not restore the agent (restored \(report.restored.count), stale \(report.stale.count)), so the round-trip is untested")
    }
    guard relaunched.attention(for: agentId) == .unread else {
        throw fail("read-state: the completion/watermark comparison was lost across relaunch — fresh supervisor reads \(relaunched.attention(for: agentId).rawValue)")
    }

    // Archiving takes the read-state with it.
    supervisor.focus(agentID: agentId)
    supervisor.archive(agentId)
    guard supervisor.focusedAgentID == nil, supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: archiving left focus \(String(describing: supervisor.focusedAgentID)) / attention \(supervisor.attention(for: agentId).rawValue) behind for a gone agent")
    }

    return "read-state over \(turnsRun) real turns: completions after a durable visit read unread, focus (by agent and by tile) advances the watermark, a watched turn stays read, and the completion/watermark comparison survives the record (\(fields.count) keys) and a relaunch"
}

// P6.2/P6.3/P6.4 production-writer check. These assertions deliberately use
// injected instants for the writer APIs and a held scripted runner for the one
// fact that must remain live. Negative witnesses observed red during the slice:
// · treating a working runner as a snooze blocker refused a valid visibility action;
// · allowing a pending request through wrote a snooze over work waiting on a human;
// · accepting `until <= now` created an already-expired shelf entry;
// · clearing derived wake by mutating the stored dates lost the original snooze.
@MainActor
private func checkPhase6LifecycleWriters<Failure: Error>(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-phase6-writer-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let heldRunner = ScriptedAgentRunner(
        script: [.turnStarted(threadId: "phase6", turnId: "working")],
        holdUntilStopped: true)
    var runners = [heldRunner]
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root),
        makeRunner: { _ in
            runners.removeFirst()
        })
    let now = Date(timeIntervalSinceReferenceDate: 806_300_000)
    let workingID = supervisor.spawn(
        role: "reviewer", prompt: nil, cwd: cwd,
        model: config.model, thinking: config.thinking)
    supervisor.send("hold this turn", to: workingID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.isRunning(workingID)
            && supervisor.turnSnapshot(for: workingID)?.state == .working
    }) else {
        throw fail("phase6 writers: the held runner never became a working turn")
    }

    let wakeAt = now.addingTimeInterval(3_600)
    guard supervisor.snooze(agentID: workingID, until: wakeAt, now: now) else {
        throw fail("phase6 writers: a working runner was incorrectly refused snooze")
    }
    guard supervisor.isRunning(workingID),
          supervisor.records[workingID]?.snoozedUntil == wakeAt,
          supervisor.records[workingID]?.snoozedAt == now else {
        throw fail("phase6 writers: snooze did not preserve the live runner and both durable dates")
    }
    guard !supervisor.snooze(agentID: workingID, until: now, now: now) else {
        throw fail("phase6 writers: a non-future wake was accepted")
    }

    let pendingID = supervisor.spawn(
        role: "reviewer", prompt: nil, cwd: cwd,
        model: config.model, thinking: config.thinking)
    supervisor.qaDeliver(
        .requestOpened(threadId: "phase6", requestId: "human", kind: .toolUserInput),
        to: pendingID, now: now)
    guard !supervisor.snooze(agentID: pendingID, until: wakeAt, now: now) else {
        throw fail("phase6 writers: a request waiting on a human was snoozed")
    }

    guard supervisor.wake(agentID: workingID),
          supervisor.records[workingID]?.snoozedUntil == nil,
          supervisor.records[workingID]?.snoozedAt == nil else {
        throw fail("phase6 writers: explicit wake did not clear both stored snooze dates")
    }
    // A persistent runner can be idle between turns. Its adopted prompt is older
    // than the stamped turn, so it is not an unadopted-prompt blocker and must not
    // renew a 30-second grace window each time the menu asks.
    let idleAt = Date().addingTimeInterval(1)
    supervisor.qaDeliver(
        .turnCompleted(threadId: "phase6", turnId: "working", outcome: .completed, errorMessage: nil),
        to: workingID,
        now: idleAt)
    let idleWakeAt = idleAt.addingTimeInterval(3_600)
    guard supervisor.isRunning(workingID),
          supervisor.turnSnapshot(for: workingID)?.state == .ready,
          supervisor.snooze(agentID: workingID, until: idleWakeAt, now: idleAt),
          supervisor.records[workingID]?.snoozedUntil == idleWakeAt else {
        throw fail("phase6 writers: an idle persistent runner renewed an unadopted-prompt grace window and refused snooze")
    }

    let pinnedID = supervisor.spawn(
        role: "reviewer", prompt: nil, cwd: cwd,
        model: config.model, thinking: config.thinking)
    guard supervisor.settle(agentID: pinnedID, now: now),
          supervisor.pinActive(agentID: pinnedID),
          supervisor.records[pinnedID]?.settledOverride == .active else {
        throw fail("phase6 writers: settle/pinActive did not write the explicit lifecycle facts")
    }
    supervisor.qaDeliver(.sessionStateChanged(.running), to: pinnedID, now: now.addingTimeInterval(1))
    supervisor.qaDeliver(.requestOpened(
        threadId: "phase6", requestId: "pin-request", kind: .commandExecutionApproval),
        to: pinnedID, now: now.addingTimeInterval(2))
    supervisor.qaDeliver(.userInputRequested(
        threadId: "phase6", requestId: "pin-input", questions: []),
        to: pinnedID, now: now.addingTimeInterval(3))
    guard supervisor.records[pinnedID]?.settledOverride == .active else {
        throw fail("phase6 writers: session/request bookkeeping cleared the keep-active pin before a prompt/turn")
    }
    // The actual turn event is the production clear seam; unlike session state or
    // request bookkeeping it proves that a new prompt was adopted by the runner.
    supervisor.qaDeliver(.turnStarted(threadId: "phase6", turnId: "actual-turn"), to: pinnedID, now: now.addingTimeInterval(4))
    guard supervisor.records[pinnedID]?.settledOverride == .neutral,
          supervisor.settledOverrideClearReasons[pinnedID] == .activity else {
        throw fail("phase6 writers: an actual turn did not reset the active pin with an activity reason")
    }

    supervisor.stop(workingID)
    return "working and idle-persistent runners remained snoozable, non-future/pending-human snoozes were refused, explicit wake cleared dates, and settle→pin→real-activity reset the pin"
}

// P6.3's executable AppKit seam. This lives beside the supervisor check so the
// matrix invokes the actual AgentInboxView timer and ChoiceListView paths, not a
// parallel date helper. The scheduler is injected only at the boundary; the view
// still owns earliest-wake selection, clamping, cancellation and callback routing.
@MainActor
private func checkPhase6InboxView<Failure: Error>(fail: (String) -> Failure) throws -> String {
    let base = Date(timeIntervalSinceReferenceDate: 806_600_000)
    var now = base
    let activeID = UUID(uuidString: "2B630000-0000-4000-8000-000000000001")!
    let soonID = UUID(uuidString: "2B630000-0000-4000-8000-000000000002")!
    let farID = UUID(uuidString: "2B630000-0000-4000-8000-000000000003")!
    let settledID = UUID(uuidString: "2B630000-0000-4000-8000-000000000004")!
    func row(_ id: UUID, _ title: String, _ lifecycle: InboxLifecycle, _ createdAt: TimeInterval) -> AgentInboxRow {
        AgentInboxRow(
            id: id,
            title: title,
            state: .ready,
            lifecycle: lifecycle,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt))
    }
    let soon = base.addingTimeInterval(0.001)
    let far = base.addingTimeInterval(2 * 86_400)
    let rows = [
        row(activeID, "Active", .active, base.timeIntervalSinceReferenceDate - 10),
        row(soonID, "Soon", .snoozed(until: soon), base.timeIntervalSinceReferenceDate - 20),
        row(farID, "Far", .snoozed(until: far), base.timeIntervalSinceReferenceDate - 30),
        row(settledID, "Settled", .settled(at: base.addingTimeInterval(-40)), base.timeIntervalSinceReferenceDate - 40),
    ]
    let view = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: 620))
    view.clock = { now }
    var scheduledDelays: [TimeInterval] = []
    var scheduledFires: [() -> Void] = []
    var cancellationCount = 0
    view.wakeRerenderScheduler = { delay, fire in
        scheduledDelays.append(delay)
        scheduledFires.append(fire)
        return { cancellationCount += 1 }
    }
    view.reload(rows: rows)
    guard scheduledDelays.count == 1,
          scheduledFires.count == 1,
          abs(scheduledDelays[0] - 0.05) < 0.000_1,
          view.hasWakeRerenderTimerForQA,
          view.scheduledWakeDelayForQA == scheduledDelays[0] else {
        throw fail("phase6 inbox: expected one clamped timer for the earliest wake, got delays \(scheduledDelays), timer=\(view.hasWakeRerenderTimerForQA)")
    }
    // Move the injected clock to the first wake and fire the callback captured
    // from the live scheduler. The view's own reload must drop the expired wake
    // and reschedule the remaining far wake at the maximum clamp.
    now = soon
    scheduledFires[0]()
    guard view.wakeRerenderCountForQA == 1,
          scheduledDelays.count == 2,
          cancellationCount == 1,
          abs(scheduledDelays[1] - 86_400) < 0.000_1,
          view.hasWakeRerenderTimerForQA else {
        throw fail("phase6 inbox: expiry did not rerender and reschedule one far wake with the maximum clamp — renders \(view.wakeRerenderCountForQA), delays \(scheduledDelays), cancellations \(cancellationCount)")
    }

    // Presets are captured by the same menu-open seam. Changing the injected
    // clock before activation must not change the absolute date already carried
    // by the menu item.
    let presetView = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: 620))
    let menuOpenedAt = base.addingTimeInterval(9_000)
    var menuClock = menuOpenedAt
    presetView.clock = { menuClock }
    let presetID = UUID(uuidString: "2B630000-0000-4000-8000-000000000005")!
    presetView.reload(rows: [row(presetID, "Preset target", .active, menuOpenedAt.timeIntervalSinceReferenceDate)])
    var capturedSnooze: (ids: [UUID], wakeAt: Date)?
    presetView.onSnoozeSelection = { ids, wakeAt in capturedSnooze = (ids, wakeAt) }
    guard presetView.openSnoozeMenuForQA(ids: [presetID]),
          presetView.snoozeOptionTitlesForQA.contains(SnoozePreset.inOneHour.title) else {
        throw fail("phase6 inbox: the production snooze menu did not open through its choice list")
    }
    let expectedWake = SnoozePreset.inOneHour.wakeDate(
        from: menuOpenedAt, calendar: Calendar.autoupdatingCurrent)
    menuClock = menuOpenedAt.addingTimeInterval(7_200)
    guard presetView.pickSnoozePresetForQA(.inOneHour),
          capturedSnooze?.ids == [presetID],
          capturedSnooze?.wakeAt == expectedWake else {
        throw fail("phase6 inbox: preset activation recomputed from activation time — opened \(menuOpenedAt), activated \(menuClock), captured \(String(describing: capturedSnooze?.wakeAt)), expected \(expectedWake)")
    }
    return "AgentInboxView timer/preset seams: one earliest wake, expiry rerendered and rescheduled with 0.05s/86400s clamps, and in-one-hour captured from menu-open time"
}

// Ticket: docs/38-tickets/90-agent-ux/P4.4-auto-unsettle.md
//
/// A settle that goes stale silently is the failure here: an agent the human said
/// "done" to starts working again, and the row stays buried.
///
/// Every settled agent in this check is made settled BY THE STORE and adopted with
/// `restore()` — nothing in this process ever wrote the override in memory — so the
/// clear is observed against state the supervisor did not create, which is what a
/// relaunched settled agent really is.
///
/// What it asserts:
///   1. The activity CLASSIFIER, as a table over every `AgentRuntimeEvent` case.
///      `.sessionStateChanged(.ready)` on the not-activity side is the packet's named
///      watch-out — an agent settling into ready is the normal END of work.
///   2. A real activity event through `deliver` clears the settle AND reaches the
///      disk, including for `.requestOpened`/`.userInputRequested`, which are not
///      `isPersistWorthy`: a clear that lived only in memory would come back settled.
///   3. The REGRESSION WITNESS the packet names: an observer-shaped refresh does not
///      clear. Four shapes of it — the `.ready` that ends a turn, a `.turnCompleted`,
///      a `.tokenUsageUpdated` meter, and `stop()`'s `.stopped` — plus the two
///      no-op reads (`focus`/`focusTile` is viewing, and reading is free per P4.9;
///      `branchContext` is the header refresh).
///   4. A user message (`send`) clears it.
///   5. The keep-active `.active` PIN lasts until the next real activity, then
///      returns to `.neutral` so the normal inactivity rule can apply again.
///   6. The two clears are ATTRIBUTED: `.activity` for the app's, `.user` for
///      `clearSettle(agentID:)`, and `restore()` records neither.
@MainActor
private func checkAutoUnsettle(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-auto-unsettle-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)

    // MARK: 1 · the classifier, as a table

    let provider = "provider-thread"
    let activity: [AgentRuntimeEvent] = [
        .turnStarted(threadId: provider, turnId: "t1")
    ]
    let notActivity: [AgentRuntimeEvent] = [
        .sessionStateChanged(.starting),
        .sessionStateChanged(.running),
        .sessionStateChanged(.ready),
        .sessionStateChanged(.waiting),
        .sessionStateChanged(.stopped),
        .sessionStateChanged(.error),
        .turnCompleted(threadId: provider, turnId: "t1", outcome: .completed, errorMessage: nil),
        .itemStarted(threadId: provider, itemId: "i1", kind: .commandExecution, title: "ls"),
        .itemCompleted(threadId: provider, itemId: "i1", kind: .commandExecution, status: .completed),
        .contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "…"),
        .requestOpened(threadId: provider, requestId: "r1", kind: .commandExecutionApproval),
        .requestResolved(threadId: provider, requestId: "r1", decision: "approved"),
        .userInputRequested(threadId: provider, requestId: "q1", questions: []),
        .userInputResolved(threadId: provider, requestId: "q1"),
        .tokenUsageUpdated(threadId: provider, snapshot: TokenUsageSnapshot(inputTokens: 1, outputTokens: 1, totalCostUsd: nil)),
        .contextWindowUpdated(threadId: provider, snapshot: AgentContextWindowSnapshot(observedAt: Date(timeIntervalSinceReferenceDate: 0), source: .piMessageUsage, freshness: .live)),
        .runtimeError(threadId: provider, message: "boom")
    ]
    for event in activity where !AgentSupervisor.isRealActivity(event) {
        throw fail("auto-unsettle: \(event) is genuine prompt/turn activity and the classifier says it is not")
    }
    for event in notActivity where AgentSupervisor.isRealActivity(event) {
        throw fail("auto-unsettle: \(event) is not a genuine prompt/turn and the pin classifier says it is — observer/bookkeeping traffic must not clear a keep-active pin")
    }
    // Both sides of the table cover every `AgentRuntimeEvent` case, which
    // the exhaustive classifiers keep honest at compile time; the count guard
    // catches a case dropped from THIS table.
    let caseCount = activity.count + notActivity.count
    guard caseCount == 18 else {
        throw fail("auto-unsettle: the classifier table covers \(caseCount) event shapes, expected 18 — a case was added or dropped without a decision")
    }

    // MARK: 2 · a settled agent, made settled by the store

    let settledOn = Date(timeIntervalSinceReferenceDate: 700_000_000)
    // The log is the durable half of the attribution (`logSettleCleared`), so it is
    // captured rather than left on stderr — a reason nobody can read is not a reason.
    final class WarningLog { var lines: [String] = [] }
    let warnings = WarningLog()
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { _ in ScriptedAgentRunner(script: []) },
        warn: { warnings.lines.append($0) }
    )
    func adoptAgent(_ name: String, override: SettledOverride) throws -> AgentID {
        let id = AgentID(rawValue: UUID())
        try store.upsert(AgentRecord(
            id: id,
            displayName: name,
            model: config.model,
            thinking: config.thinking,
            cwd: cwd.path,
            createdAt: settledOn,
            lastActivityAt: settledOn,
            settledOverride: override,
            settledAt: override == .settled ? settledOn : nil
        ))
        supervisor.restore()
        guard supervisor.records[id]?.settledOverride == override else {
            throw fail("auto-unsettle: restore() did not adopt \(name) as \(override.rawValue) — got \(String(describing: supervisor.records[id]?.settledOverride.rawValue)); a refresh of the store must not touch the override")
        }
        guard supervisor.settledOverrideClearReasons[id] == nil else {
            throw fail("auto-unsettle: restoring \(name) recorded a clear reason \(String(describing: supervisor.settledOverrideClearReasons[id]?.rawValue)) — restore clears nothing")
        }
        return id
    }

    // 2a · an approval opening un-settles it, and the clear reaches the DISK even
    //      though `.requestOpened` is not persist-worthy on its own.
    let approvalAgent = try adoptAgent("approval", override: .settled)
    supervisor.qaDeliver(.requestOpened(threadId: provider, requestId: "r1", kind: .commandExecutionApproval), to: approvalAgent)
    guard supervisor.records[approvalAgent]?.settledOverride == .neutral else {
        throw fail("auto-unsettle: an approval request left the agent \(String(describing: supervisor.records[approvalAgent]?.settledOverride.rawValue)) — a settled agent waiting on a human is the row this ticket exists to un-bury")
    }
    guard supervisor.settledOverrideClearReasons[approvalAgent] == .activity else {
        throw fail("auto-unsettle: the app's own clear was attributed \(String(describing: supervisor.settledOverrideClearReasons[approvalAgent]?.rawValue)), not activity")
    }
    // The attribution is READABLE, not just held in a dictionary that dies with the
    // process: one log line naming the agent and the reason.
    func clearLines(_ id: AgentID) -> [String] {
        warnings.lines.filter { $0.contains(id.rawValue.uuidString) && $0.contains("cleared the settle") }
    }
    guard clearLines(approvalAgent) == ["AgentSupervisor: cleared the settle on agent \(approvalAgent.rawValue.uuidString) — reason activity"] else {
        throw fail("auto-unsettle: the app's clear was not logged as an activity clear — got \(clearLines(approvalAgent))")
    }
    guard try store.load(id: approvalAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: the clear did not reach the store (\(String(describing: try store.load(id: approvalAgent)?.settledOverride.rawValue))) — `.requestOpened` is not persist-worthy, so the agent would come back settled on the next launch")
    }

    // 2b · an INPUT request too — the other not-persist-worthy activity event, and the
    //      one a summary could otherwise claim on the classifier table's word alone.
    let questionAgent = try adoptAgent("question", override: .settled)
    supervisor.qaDeliver(
        .userInputRequested(threadId: provider, requestId: "q1", questions: []),
        to: questionAgent
    )
    guard supervisor.records[questionAgent]?.settledOverride == .neutral,
          try store.load(id: questionAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: an input request left the agent \(String(describing: supervisor.records[questionAgent]?.settledOverride.rawValue)) in memory / \(String(describing: try store.load(id: questionAgent)?.settledOverride.rawValue)) on disk")
    }

    // 2c · a session coming alive still clears a restored SETTLE, but it must not
    //      clear a keep-active PIN.
    let aliveAgent = try adoptAgent("alive", override: .settled)
    supervisor.qaDeliver(.sessionStateChanged(.running), to: aliveAgent)
    guard supervisor.records[aliveAgent]?.settledOverride == .neutral,
          try store.load(id: aliveAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: a session coming alive left the restored settle \(String(describing: supervisor.records[aliveAgent]?.settledOverride.rawValue)) in memory / \(String(describing: try store.load(id: aliveAgent)?.settledOverride.rawValue)) on disk")
    }
    let pinnedSessionAgent = try adoptAgent("pinned session", override: .active)
    supervisor.qaDeliver(.sessionStateChanged(.running), to: pinnedSessionAgent)
    supervisor.qaDeliver(.requestOpened(threadId: provider, requestId: "pin-r1", kind: .commandExecutionApproval), to: pinnedSessionAgent)
    supervisor.qaDeliver(.userInputRequested(threadId: provider, requestId: "pin-q1", questions: []), to: pinnedSessionAgent)
    guard supervisor.records[pinnedSessionAgent]?.settledOverride == .active,
          try store.load(id: pinnedSessionAgent)?.settledOverride == .active else {
        throw fail("auto-unsettle: session/request bookkeeping cleared a keep-active pin — got \(String(describing: supervisor.records[pinnedSessionAgent]?.settledOverride.rawValue)) / \(String(describing: try store.load(id: pinnedSessionAgent)?.settledOverride.rawValue))")
    }

    // MARK: 3 · the regression witness — observer/bookkeeping refreshes do not
    // un-settle. Session/request events are intentionally excluded here because
    // section 2 proves their older P4.4 settle-clearing behavior separately.

    let refreshAgent = try adoptAgent("refresh", override: .settled)
    for event in notActivity where !AgentSupervisor.clearsSettledOverride(event) {
        supervisor.qaDeliver(event, to: refreshAgent)
        guard supervisor.records[refreshAgent]?.settledOverride == .settled else {
            throw fail("auto-unsettle: \(event) un-settled the agent — an agent settling into ready, or reporting on itself, is the normal end of work and would undo every settle")
        }
    }
    guard try store.load(id: refreshAgent)?.settledOverride == .settled else {
        throw fail("auto-unsettle: the stored override moved to \(String(describing: try store.load(id: refreshAgent)?.settledOverride.rawValue)) with no activity")
    }
    guard supervisor.settledOverrideClearReasons[refreshAgent] == nil, clearLines(refreshAgent).isEmpty else {
        throw fail("auto-unsettle: a refresh recorded a clear reason \(String(describing: supervisor.settledOverrideClearReasons[refreshAgent]?.rawValue)) / logged \(clearLines(refreshAgent))")
    }
    // A deliberate stop is the same shape through the REAL entry point rather than
    // `qaDeliver`: `stop` delivers `.sessionStateChanged(.stopped)` itself.
    supervisor.stop(refreshAgent)
    guard supervisor.records[refreshAgent]?.settledOverride == .settled else {
        throw fail("auto-unsettle: stopping the agent un-settled it — a stop ends work, it does not start it")
    }
    // Viewing is free (P4.9), and so is the header's branch refresh.
    supervisor.focus(agentID: refreshAgent)
    supervisor.focusTile(UUID())
    _ = supervisor.branchContext(for: refreshAgent)
    guard supervisor.records[refreshAgent]?.settledOverride == .settled,
          supervisor.settledOverrideClearReasons[refreshAgent] == nil else {
        throw fail("auto-unsettle: looking at the row un-settled it (\(String(describing: supervisor.records[refreshAgent]?.settledOverride.rawValue))) — reading is free")
    }

    // MARK: 4 · a user message un-settles it, through `send`

    let promptAgent = try adoptAgent("prompt", override: .settled)
    supervisor.send("carry on", to: promptAgent)
    guard supervisor.records[promptAgent]?.settledOverride == .neutral,
          try store.load(id: promptAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: sending a prompt to a settled agent left it \(String(describing: supervisor.records[promptAgent]?.settledOverride.rawValue)) in memory / \(String(describing: try store.load(id: promptAgent)?.settledOverride.rawValue)) on disk")
    }
    guard supervisor.settledOverrideClearReasons[promptAgent] == .activity else {
        throw fail("auto-unsettle: a user message was attributed \(String(describing: supervisor.settledOverrideClearReasons[promptAgent]?.rawValue)), not activity")
    }
    // `settledAt` is deliberately LEFT ALONE: an override that was cleared still
    // happened, and P3.4 orders history by when work ended.
    guard supervisor.records[promptAgent]?.settledAt == settledOn else {
        throw fail("auto-unsettle: clearing the override also erased settledAt (\(String(describing: supervisor.records[promptAgent]?.settledAt)))")
    }

    // MARK: 5 · a keep-active pin lasts until genuine prompt/turn activity

    let pinnedAgent = try adoptAgent("pinned", override: .active)
    supervisor.qaDeliver(.sessionStateChanged(.running), to: pinnedAgent)
    guard supervisor.records[pinnedAgent]?.settledOverride == .active else {
        throw fail("auto-unsettle: session-running cleared the keep-active pin before a prompt/turn — got \(String(describing: supervisor.records[pinnedAgent]?.settledOverride.rawValue))")
    }
    supervisor.send("carry on", to: pinnedAgent)
    guard supervisor.records[pinnedAgent]?.settledOverride == .neutral else {
        throw fail("auto-unsettle: send did not reset the keep-active pin — got \(String(describing: supervisor.records[pinnedAgent]?.settledOverride.rawValue))")
    }
    guard supervisor.settledOverrideClearReasons[pinnedAgent] == .activity else {
        throw fail("auto-unsettle: resetting a pin did not record an activity clear reason — got \(String(describing: supervisor.settledOverrideClearReasons[pinnedAgent]?.rawValue))")
    }

    // MARK: 6 · the human's own path is separate, and says so

    let userAgent = try adoptAgent("user", override: .settled)
    guard supervisor.clearSettle(agentID: userAgent) else {
        throw fail("auto-unsettle: clearSettle refused a settled agent")
    }
    guard supervisor.records[userAgent]?.settledOverride == .neutral,
          try store.load(id: userAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: the user's clear did not stick (\(String(describing: supervisor.records[userAgent]?.settledOverride.rawValue)) / \(String(describing: try store.load(id: userAgent)?.settledOverride.rawValue)))")
    }
    guard supervisor.settledOverrideClearReasons[userAgent] == .user else {
        throw fail("auto-unsettle: the human's clear was attributed \(String(describing: supervisor.settledOverrideClearReasons[userAgent]?.rawValue)), not user — the two paths must be tellable apart")
    }
    guard clearLines(userAgent) == ["AgentSupervisor: cleared the settle on agent \(userAgent.rawValue.uuidString) — reason user"] else {
        throw fail("auto-unsettle: the human's clear was not logged as a user clear — got \(clearLines(userAgent))")
    }
    guard supervisor.clearSettle(agentID: userAgent) == false else {
        throw fail("auto-unsettle: clearSettle reported a write for an agent that was already neutral")
    }
    guard supervisor.clearSettle(agentID: AgentID(rawValue: UUID())) == false else {
        throw fail("auto-unsettle: clearSettle reported a write for an agent this supervisor does not have")
    }

    return "auto-unsettle over \(caseCount) event shapes: approval/input/session traffic clears a restored settle but not a keep-active pin, send clears the pin, \(notActivity.count) observer/bookkeeping shapes + stop + focus + a branch refresh do not clear it, and the two clears are attributed activity vs user in \(warnings.lines.filter { $0.contains("cleared the settle") }.count) log lines"
}

// Ticket: docs/38-tickets/90-agent-ux/P6.1-per-agent-model-effort.md
//
/// Model and thinking level, per agent, in the tile — the failure this closes is
/// that both were configurable ONLY as a global default in Settings, for every
/// future agent at once and nowhere near the agent you were looking at.
///
/// NO PI, NO NETWORK, NO WALL CLOCK: the runner behind the two-method
/// `AgentRunning` protocol is a `ScriptedAgentRunner`, and the flags a real turn
/// would carry are asserted through `AgentSupervisor.runnerConfig(for:)` and
/// `PiAgentRunner.processArguments`, both pure over the record.
///
/// THE FIXTURE'S VALUES DIFFER FROM THE GLOBAL DEFAULT, deliberately and with a
/// vacuity guard: the defaults and a freshly-spawned record are equal by
/// construction, so an agent that picked the default would prove nothing — every
/// assertion here would stay green against a `runnerConfig` that read
/// `AgentModelConfig` instead of the record.
///
/// What it asserts:
///   1. The mutator writes the record and the write REACHES DISK — asserted on a
///      re-read from the store, so a change that lived only in memory (and would
///      come back as the old model next launch) is red.
///   2. The next turn's flags: `runnerConfig(for:)` over the RELOADED record, and
///      the argument vector `PiAgentRunner` builds from it.
///   3. Two agents holding different models at the same time.
///   4. Moving the global Settings default does NOT move an existing agent.
///   5. A value outside `AgentModelConfig`'s catalogue is refused, not substituted.
///   6. The tile: its pickers carry exactly the catalogue, seed from the RECORD,
///      write a pick back through to the store, go unavailable with the rest of
///      compose while a turn is in flight, and keep the "next turn" notice
///      unpickable across an `NSMenu.update()`.
///
/// SEVEN NEGATIVE TESTS observed RED at exit 1 against this final code, the failure
/// text quoted verbatim:
///   1. `persist(record)` dropped from `setProviderSettings` — "the store holds
///      openai-codex/gpt-5.6-sol / medium, not the picked openai-codex/gpt-5.4-mini
///      / xhigh". The re-read from disk is what catches it; the in-memory assertion
///      above stays green.
///   2. `runnerConfig(for:)` fed `AgentModelConfig.resolvedFromDefaults()` instead of
///      the record — "the runner would be built with openai-codex/gpt-5.6-sol /
///      medium". THE ONE THAT NEEDS THE UNLIKE-THE-DEFAULT FIXTURE: with a
///      default-valued agent this bug is green.
///   3. The two popups left out of `applyComposeAvailability()` — "the pickers
///      stayed live during a turn".
///   4. `autoenablesItems` left at AppKit's default — "`Applies to the next turn`
///      came back pickable after NSMenu.update()".
///   5. The model options re-typed as a five-entry literal — "the model picker
///      offers […5 ids], not AgentModelConfig.modelOptions […7 ids]".
///   6. `attach` re-seeding the tile from the global default instead of the record —
///      "attaching left the tile showing Resolution(model: openai-codex/gpt-5.6-sol,
///      thinking: medium) instead of the agent's own".
///   7. The compose row left at its old single-body-line height — red in
///      `--ui-geometry-check`, not here: "managedAgent@320pt.NSAppearanceNameAqua:
///      … holds a broken required constraint — measured 24.0, needs == 41.0".
/// Two more for the cross-review's findings, same standard:
///   8. Both fields submitted on every pick instead of only the one that moved —
///      "an off-catalogue model made the thinking level unchangeable".
///   9. The revert-on-refusal dropped — "a refused pick left the record at
///      openai-codex/gpt-5.5 and the picker showing openai-codex/gpt-4o-legacy".
@MainActor
private func checkPerAgentProviderSettings(
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-provider-settings-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)

    // This section exercises Pi-only contracts (`--model`, `--thinking`, role
    // tools, and Pi's full catalogue). Scope the ambient defaults used by the
    // production tile to Pi, then restore them exactly; otherwise a developer's
    // selected Claude/Codex harness changes what this deterministic check means.
    let standardDefaults = UserDefaults.standard
    let savedHarness = standardDefaults.object(forKey: AgentHarnessConfig.key)
    let savedModel = standardDefaults.object(forKey: AgentModelConfig.modelKey)
    let savedThinking = standardDefaults.object(forKey: AgentModelConfig.thinkingKey)
    AgentHarnessConfig.store(.pi, defaults: standardDefaults)
    standardDefaults.set(AgentModelConfig.fallbackModelOptions[0], forKey: AgentModelConfig.modelKey)
    standardDefaults.set(AgentModelConfig.defaultThinking, forKey: AgentModelConfig.thinkingKey)
    defer {
        func restore(_ value: Any?, key: String) {
            if let value { standardDefaults.set(value, forKey: key) }
            else { standardDefaults.removeObject(forKey: key) }
        }
        restore(savedHarness, key: AgentHarnessConfig.key)
        restore(savedModel, key: AgentModelConfig.modelKey)
        restore(savedThinking, key: AgentModelConfig.thinkingKey)
    }

    // The picks, chosen to be UNLIKE the defaults in both fields. Guarded, because
    // the whole check turns on that difference.
    let pickedModel = "openai-codex/gpt-5.4-mini"
    let pickedThinking = "xhigh"
    let globalDefault = AgentModelConfig.resolvedFromDefaults()
    guard pickedModel != globalDefault.model, pickedThinking != globalDefault.thinking,
          AgentModelConfig.modelOptions.contains(pickedModel),
          AgentModelConfig.thinkingOptions.contains(pickedThinking) else {
        throw fail("provider-settings: the fixture's pick (\(pickedModel) / \(pickedThinking)) is the global default or is not in the catalogue — every assertion below would be green against a runner that ignored the record")
    }

    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let tileId = UUID()
    let agentId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: globalDefault.model,
        thinking: globalDefault.thinking,
        tileId: tileId
    )

    // MARK: 1 · the mutator writes the record, and the write reaches disk

    guard supervisor.providerSettings(for: agentId) == globalDefault else {
        throw fail("provider-settings: a fresh agent reads \(String(describing: supervisor.providerSettings(for: agentId))), not the values it was spawned with")
    }
    guard supervisor.setProviderSettings(agentID: agentId, model: pickedModel, thinking: pickedThinking) else {
        throw fail("provider-settings: setProviderSettings refused a catalogue model/thinking pair on a live agent")
    }
    guard supervisor.setProviderSettings(agentID: agentId, model: pickedModel, thinking: pickedThinking) == false else {
        throw fail("provider-settings: re-picking the values the agent already had reported a write")
    }
    guard supervisor.setProviderSettings(agentID: AgentID(rawValue: UUID()), model: pickedModel) == false else {
        throw fail("provider-settings: setProviderSettings reported a write for an agent this supervisor does not have")
    }
    guard let stored = try store.load(id: agentId) else {
        throw fail("provider-settings: no record on disk for the agent at \(store.layout.agentFile(id: agentId).path)")
    }
    guard stored.model == pickedModel, stored.thinking == pickedThinking else {
        throw fail("provider-settings: the store holds \(stored.model) / \(stored.thinking), not the picked \(pickedModel) / \(pickedThinking) — a pick that lives only in memory comes back as the old model on the next launch")
    }

    // MARK: 2 · the NEXT turn's flags, from the reloaded record

    let config = AgentSupervisor.runnerConfig(for: stored, spawnDepth: 0)
    guard config.model == pickedModel, config.thinking == pickedThinking else {
        throw fail("provider-settings: the runner would be built with \(config.model) / \(config.thinking) — the record is not what decides the next turn")
    }
    let args = PiAgentRunner.processArguments(
        model: config.model,
        thinking: config.thinking,
        sessionId: config.sessionId,
        extraArgs: config.extraArgs,
        prompt: "next turn"
    )
    guard let modelFlag = args.firstIndex(of: "--model"), args.indices.contains(modelFlag + 1),
          args[modelFlag + 1] == pickedModel,
          let thinkingFlag = args.firstIndex(of: "--thinking"), args.indices.contains(thinkingFlag + 1),
          args[thinkingFlag + 1] == pickedThinking else {
        throw fail("provider-settings: Pi would be spawned as \(args) — the pick does not reach the flags")
    }

    // MARK: 3 · two agents, two models, at the same time

    let otherId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: globalDefault.model,
        thinking: globalDefault.thinking
    )
    guard supervisor.providerSettings(for: otherId) == globalDefault,
          supervisor.providerSettings(for: agentId)?.model == pickedModel else {
        throw fail("provider-settings: picking a model for one agent moved another's — \(String(describing: supervisor.providerSettings(for: otherId))) vs \(String(describing: supervisor.providerSettings(for: agentId)))")
    }

    // MARK: 4 · the global default moves; the agent that already exists does not

    let suite = "continuum-provider-settings-check-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw fail("provider-settings: could not open an isolated defaults suite")
    }
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let movedDefault = "openai-codex/gpt-5.3-codex-spark"
    guard movedDefault != pickedModel, movedDefault != globalDefault.model else {
        throw fail("provider-settings: the moved default \(movedDefault) is not distinct from the pick or the original default")
    }
    defaults.set(movedDefault, forKey: AgentModelConfig.modelKey)
    defaults.set("minimal", forKey: AgentModelConfig.thinkingKey)
    AgentHarnessConfig.store(.pi, defaults: defaults)
    guard AgentModelConfig.resolvedFromDefaults(defaults: defaults).model == movedDefault else {
        throw fail("provider-settings: the isolated defaults suite did not take the moved default, so this section proves nothing")
    }
    guard supervisor.providerSettings(for: agentId)?.model == pickedModel,
          try store.load(id: agentId)?.model == pickedModel,
          AgentSupervisor.runnerConfig(for: stored, spawnDepth: 0).model == pickedModel else {
        throw fail("provider-settings: moving the global Settings default moved an agent that already existed — the record is the truth, and \"per-agent\" means the default is only a seed")
    }

    // MARK: 5 · a value outside the catalogue is refused, never substituted

    for bad in ["gpt-5.6", "openai-codex/gpt-9", ""] {
        guard supervisor.setProviderSettings(agentID: agentId, model: bad) == false else {
            throw fail("provider-settings: \(bad.isEmpty ? "an empty model" : bad) was accepted — `--model` takes a pattern, so a partial id fuzzy-matches and the agent silently runs whichever model Pi picked (the P0.10 bug)")
        }
    }
    guard supervisor.setProviderSettings(agentID: agentId, thinking: "ludicrous") == false else {
        throw fail("provider-settings: a thinking level Pi does not accept was written to the record")
    }
    guard supervisor.providerSettings(for: agentId)?.model == pickedModel,
          supervisor.providerSettings(for: agentId)?.thinking == pickedThinking else {
        throw fail("provider-settings: a refused value still moved the record to \(String(describing: supervisor.providerSettings(for: agentId)))")
    }
    // `"off"` is a LEGAL thinking level, not a null — the packet's watch-out.
    guard supervisor.setProviderSettings(agentID: agentId, thinking: "off"),
          try store.load(id: agentId)?.thinking == "off" else {
        throw fail("provider-settings: `off` was refused as a thinking level — Pi accepts it, and filtering it out would take a real option off the picker")
    }
    supervisor.setProviderSettings(agentID: agentId, thinking: pickedThinking)

    // MARK: 6 · the tile

    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 360),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    // Before it knows an agent, the tile shows the global default — the seed.
    guard tile.qaProviderSettings == AgentModelConfig.resolvedFromDefaults() else {
        throw fail("provider-settings: a tile with no agent shows \(tile.qaProviderSettings), not the global default")
    }
    // The options ARE the catalogue, listed rather than counted: a second hardcoded
    // list here would drift from Pi's, which is what P0.10 closed.
    guard tile.qaUsesCustomProviderControls else {
        throw fail("provider-settings: the production tile still exposes native popup chrome instead of the custom next-turn footer")
    }
    guard tile.qaModelOptionTitles == AgentModelConfig.modelOptions else {
        throw fail("provider-settings: the model picker offers \(tile.qaModelOptionTitles), not AgentModelConfig.modelOptions \(AgentModelConfig.modelOptions)")
    }
    guard tile.qaThinkingOptionTitles == AgentModelConfig.thinkingOptions else {
        throw fail("provider-settings: the thinking picker offers \(tile.qaThinkingOptionTitles), not AgentModelConfig.thinkingOptions \(AgentModelConfig.thinkingOptions)")
    }
    guard !tile.qaProviderFooterView.qaHasVisibleContextLabel,
          !tile.qaModelOptionTitles.contains(ManagedAgentTileNSView.providerNoticeText),
          !tile.qaProviderFooterView.qaEffortTitles.contains(ManagedAgentTileNSView.providerNoticeText),
          tile.qaProviderFooterView.modelButton.accessibilityLabel() == "Model, next turn",
          tile.qaProviderFooterView.effortButton.accessibilityLabel() == "Reasoning effort, next turn" else {
        throw fail("provider-settings: the production footer kept a visible inert `\(ManagedAgentTileNSView.providerNoticeText)` label, exposed it as a choice, or lost its next-turn accessibility labels")
    }

    tile.attach(agentID: agentId, supervisor: supervisor)
    guard tile.qaProviderSettings == AgentModelConfig.Resolution(model: pickedModel, thinking: pickedThinking) else {
        throw fail("provider-settings: attaching left the tile showing \(tile.qaProviderSettings) instead of the agent's own \(pickedModel) / \(pickedThinking)")
    }

    // A pick made the way a user makes it reaches the record AND the disk.
    let secondModel = "openai-codex/gpt-5.5"
    guard secondModel != pickedModel else { throw fail("provider-settings: the second pick is the first one") }
    // `qaPick` goes through the popup's own target/action, so a control that was
    // never wired reports false here rather than passing on a handler call the user
    // could not make (from the cross-review).
    guard tile.qaPickModel(secondModel), tile.qaPickThinking("low") else {
        throw fail("provider-settings: a picker's action did not fire — its target/action is unwired, so a real user's pick would do nothing")
    }
    guard supervisor.providerSettings(for: agentId) == AgentModelConfig.Resolution(model: secondModel, thinking: "low"),
          try store.load(id: agentId)?.model == secondModel,
          try store.load(id: agentId)?.thinking == "low" else {
        throw fail("provider-settings: picking in the tile left the record at \(String(describing: supervisor.providerSettings(for: agentId))) / the store at \(String(describing: try store.load(id: agentId).map { "\($0.model) / \($0.thinking)" }))")
    }
    guard AgentSupervisor.runnerConfig(for: try store.load(id: agentId)!, spawnDepth: 0).model == secondModel else {
        throw fail("provider-settings: the tile's pick does not reach the next turn's runner config")
    }

    // While a turn is in flight both controls go dark with the rest of compose.
    // Through the supervisor, not direct tile ingest: an attached v2 tile's status
    // derives from the supervisor snapshot (P5.5 status single-ownership), so a
    // fixture event that bypasses `deliver` no longer represents a turn — exactly
    // as a real turn never bypasses it.
    supervisor.qaDeliver(.sessionStateChanged(.running), to: agentId)
    supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: agentId), turnId: "t1"), to: agentId)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.qaComposeEnabled == false }) else {
        throw fail("provider-settings: compose stayed enabled during a turn, so the in-flight assertion below is vacuous")
    }
    guard tile.qaProviderControlsEnabled == false else {
        throw fail("provider-settings: the pickers stayed live during a turn — a change picked mid-turn cannot apply until Phase 5's set_model RPC, and a control that silently does nothing is worse than one that is visibly unavailable")
    }
    tile.qaPickModel(globalDefault.model)
    guard supervisor.providerSettings(for: agentId)?.model == secondModel else {
        throw fail("provider-settings: a disabled picker still wrote \(String(describing: supervisor.providerSettings(for: agentId)?.model)) to the record mid-turn")
    }
    supervisor.qaDeliver(.turnCompleted(threadId: AgentSupervisor.threadId(for: agentId), turnId: "t1", outcome: .completed, errorMessage: nil), to: agentId)
    supervisor.qaDeliver(.sessionStateChanged(.ready), to: agentId)
    // Both, together: the pickers are on `applyComposeAvailability()` and not on a
    // second notion of "busy", so they must come back exactly when compose does.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.qaProviderControlsEnabled && tile.qaComposeEnabled }) else {
        throw fail("provider-settings: after the turn ended compose is \(tile.qaComposeEnabled ? "live" : "dark") and the pickers are \(tile.qaProviderControlsEnabled ? "live" : "dark") — they must move together")
    }
    tile.detach()

    // MARK: 7 · a value this catalogue no longer has (the cross-review's finding)

    // A record written by an older build can hold a value this catalogue no longer
    // has. The picker SHOWS it rather than renaming it silently, and — the
    // cross-review's finding — the OTHER field stays changeable, because only the
    // field that moved is submitted. Written through the store and re-adopted, so
    // nothing in this process put the foreign value in memory.
    var foreign = try store.load(id: agentId)!
    foreign.model = "openai-codex/gpt-4o-legacy"
    try store.upsert(foreign)
    let foreignSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    foreignSupervisor.restore()

    // MARK: 8 · custom composer footer

    // P4.8 exercises the same footer now installed in the production tile: it reads
    // the shared catalogues, labels its scope truthfully, persists through the same
    // supervisor, and submits only the field that moved.
    // Label variants are a MEASURED fit since the P5.5 corrections, not a
    // width threshold: 240 pt cannot hold this catalogue's full titles (compact
    // expected), and at 640 pt the full titles must come back verbatim.
    let footer = AgentComposerFooterView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
    footer.apply(foreignSupervisor.providerSettings(for: agentId)!)
    footer.onSettingsWrite = { model, thinking in
        foreignSupervisor.setProviderSettings(agentID: agentId, model: model, thinking: thinking)
    }
    footer.layoutSubtreeIfNeeded()
    guard footer.qaModelTitles == (AgentModelConfig.modelOptions + [foreign.model]).map(AgentComposerFooterView.abbreviatedModel),
          footer.qaEffortTitles == AgentModelConfig.thinkingOptions.map(AgentComposerFooterView.abbreviatedEffort),
          footer.modelButton.accessibilityLabel() == "Model, next turn",
          footer.effortButton.accessibilityLabel() == "Reasoning effort, next turn" else {
        throw fail("provider-settings: the custom footer diverged from AgentModelConfig, hid the off-catalog model, or lost its next-turn accessibility labels")
    }
    footer.setFrameSize(NSSize(width: 640, height: 48))
    footer.layoutSubtreeIfNeeded()
    guard footer.qaModelTitles == AgentModelConfig.modelOptions + [foreign.model],
          footer.qaEffortTitles == AgentModelConfig.thinkingOptions.map(\.capitalized) else {
        throw fail("provider-settings: 640 pt did not restore the full model ids and effort names — the measured fit stayed compact with room to spare")
    }
    guard footer.qaPickThinking("high"),
          foreignSupervisor.providerSettings(for: agentId)?.model == foreign.model,
          foreignSupervisor.providerSettings(for: agentId)?.thinking == "high",
          try store.load(id: agentId)?.model == foreign.model,
          try store.load(id: agentId)?.thinking == "high" else {
        throw fail("provider-settings: the custom footer's effort-only change overwrote or rejected the off-catalog model instead of persisting only effort")
    }
    // Detaching is view-only. A new footer populated from a supervisor reloaded from
    // disk must show the same non-default pair.
    let reloadedSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    reloadedSupervisor.restore()
    let reattachedFooter = AgentComposerFooterView(frame: footer.frame)
    reattachedFooter.apply(reloadedSupervisor.providerSettings(for: agentId)!)
    guard reattachedFooter.qaSettings == AgentModelConfig.Resolution(model: foreign.model, thinking: "high") else {
        throw fail("provider-settings: custom footer values did not survive detach/re-attach and disk reload — got \(reattachedFooter.qaSettings)")
    }

    // The reciprocal old-record case: a model-only change must not resubmit an
    // effort value this build no longer catalogues.
    let legacyEffort = "legacy-auto"
    let legacyEffortID = foreignSupervisor.spawn(
        role: nil, prompt: nil, cwd: cwd,
        model: pickedModel, thinking: legacyEffort
    )
    let reciprocalFooter = AgentComposerFooterView(frame: footer.frame)
    reciprocalFooter.apply(foreignSupervisor.providerSettings(for: legacyEffortID)!)
    reciprocalFooter.onSettingsWrite = { model, thinking in
        foreignSupervisor.setProviderSettings(agentID: legacyEffortID, model: model, thinking: thinking)
    }
    guard reciprocalFooter.qaEffortTitles.last == AgentComposerFooterView.abbreviatedEffort(legacyEffort),
          reciprocalFooter.qaPickModel(secondModel),
          foreignSupervisor.providerSettings(for: legacyEffortID) == .init(model: secondModel, thinking: legacyEffort),
          try store.load(id: legacyEffortID)?.thinking == legacyEffort else {
        throw fail("provider-settings: the custom footer's model-only change overwrote or rejected an off-catalog effort")
    }
    _ = foreignSupervisor.setProviderSettings(agentID: agentId, thinking: pickedThinking)

    let foreignTile = ManagedAgentTileNSView(tile: Tile(
        id: UUID(),
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 360),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    foreignTile.attach(agentID: agentId, supervisor: foreignSupervisor)
    guard foreignTile.qaProviderSettings.model == foreign.model,
          foreignTile.qaModelOptionTitles == AgentModelConfig.modelOptions + [foreign.model] else {
        throw fail("provider-settings: a record holding \(foreign.model) renders as \(foreignTile.qaProviderSettings.model) with options \(foreignTile.qaModelOptionTitles) — the picker must not rename what the next turn will really run")
    }
    guard foreignTile.qaPickThinking("high"),
          foreignSupervisor.providerSettings(for: agentId)?.thinking == "high",
          foreignSupervisor.providerSettings(for: agentId)?.model == foreign.model else {
        throw fail("provider-settings: an off-catalogue model made the thinking level unchangeable — \(String(describing: foreignSupervisor.providerSettings(for: agentId)))")
    }
    // A pick the supervisor REFUSES puts the record's own value back, rather than
    // leaving a choice on screen that never happened.
    foreignTile.qaPickModel(secondModel)
    foreignTile.qaPickModel(foreign.model)
    guard foreignSupervisor.providerSettings(for: agentId)?.model == secondModel,
          foreignTile.qaProviderSettings.model == secondModel else {
        throw fail("provider-settings: a refused pick left the record at \(String(describing: foreignSupervisor.providerSettings(for: agentId)?.model)) and the picker showing \(foreignTile.qaProviderSettings.model) — a control must not display a choice that was not written")
    }
    foreignTile.detach()

    // MARK: 9 · a harness pick is atomic, including a model shared by two harnesses

    // This is the exact production regression: Pi and Claude Code can both list the
    // same Anthropic model ID. Choosing Claude Code used to update only the footer's
    // temporary harness while the unchanged model title made the two-step state look
    // committed. Send then read the still-Pi record. One harness click must update
    // the footer, live record, disk, and therefore the next runner together.
    let sharedModel = "anthropic/claude-opus-5"
    let savedHarnessCatalogues = AgentHarness.allCases.map {
        AgentModelCatalog.shared.snapshot(for: $0)
    }
    defer {
        for snapshot in savedHarnessCatalogues {
            AgentModelCatalog.shared.resetForQA(snapshot: snapshot)
        }
    }
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .pi, readiness: .ready, models: [sharedModel],
        displayNames: [sharedModel: "Claude Opus (latest)"]))
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .claudeCode, readiness: .ready, models: [sharedModel],
        displayNames: [sharedModel: "Claude Opus (latest)"]))

    let harnessTileID = UUID()
    let harnessAgentID = supervisor.spawn(
        role: nil, prompt: nil, cwd: cwd, harness: .pi,
        model: sharedModel, thinking: "medium", tileId: harnessTileID)
    let harnessTile = ManagedAgentTileNSView(tile: Tile(
        id: harnessTileID,
        kind: .managedAgent,
        title: "shared model harness switch",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 360),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    harnessTile.attach(agentID: harnessAgentID, supervisor: supervisor)
    guard harnessTile.qaProviderFooterView.qaLaunchSelection.harness == .pi,
          harnessTile.qaPickHarness(.claudeCode),
          harnessTile.qaProviderFooterView.qaLaunchSelection == AgentLaunchSelection(
            harness: .claudeCode, model: sharedModel, thinking: "medium"),
          supervisor.launchSelection(for: harnessAgentID) == AgentLaunchSelection(
            harness: .claudeCode, model: sharedModel, thinking: "medium"),
          try store.load(id: harnessAgentID)?.harness == .claudeCode else {
        throw fail("provider-settings: choosing Claude Code while Pi shared the same visible Opus model did not atomically update the footer, record, and disk")
    }
    harnessTile.detach()

    return "per-agent provider settings: a pick lands on the record and the disk and reaches --model/--thinking (\(pickedModel) / \(pickedThinking), both unlike the global default), two agents hold different models, a moved global default moves neither, \(3 + 1) off-catalogue values are refused while `off` is accepted, a Pi→Claude Code switch sharing the same visible Opus model commits atomically, and the tile's \(tile.qaModelOptionTitles.count)+\(tile.qaThinkingOptionTitles.count) options are AgentModelConfig's own with no visible inert next-turn notice"
}

/// macOS temp directories live under a `/var` symlink to `/private/var`, and git
/// reports the RESOLVED path in `worktree list --porcelain`.
private func isolatedSpawnResolved(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

/// The body of one `AppDelegate` method, comments stripped. Bounded by the closing
/// brace at the method's own four-space indentation. Same precedent, and same reason,
/// as `managedAgentCloseBranchSource` below: these methods need a live canvas and a
/// running app to execute.
private func paletteAgentSpawnBranch(_ signature: String) throws -> String {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == signature }) else {
        throw ScanError(description: "no `\(signature)` in \(path) — it was renamed or removed, and this scan is now blind")
    }
    var body: [String] = []
    for line in lines[(start + 1)...] {
        if line == "    }" { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        body.append(line)
    }
    guard !body.isEmpty else {
        throw ScanError(description: "`\(signature)` scanned as an empty body")
    }
    return body.joined(separator: "\n")
}

/// The lines of `AppDelegate.deleteTile`'s `case .managedAgent:` branch, comments
/// stripped. Source-read for the same reason `piRunnerConstructionSites` is: the
/// branch needs a canvas, a workspace runtime and a modal-capable app to execute, so
/// "closing a tile never stops the agent" is otherwise only assertable by reading the
/// diff. Bounded by indentation (the branch's own `case` is at eight spaces) rather
/// than by a closing brace, since the branch contains nested blocks.
private func managedAgentCloseBranchSource() throws -> String {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let functionStart = lines.firstIndex(where: { $0.contains("func deleteTile(id: UUID) {") }) else {
        throw ScanError(description: "no `func deleteTile(id: UUID)` in \(path)")
    }
    guard let branchStart = lines[functionStart...].firstIndex(where: { $0 == "        case .managedAgent:" }) else {
        throw ScanError(description: "no `case .managedAgent:` in deleteTile — the close path moved, and this scan is now blind")
    }
    var body: [String] = []
    for line in lines[(branchStart + 1)...] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !line.hasPrefix("         ") && !trimmed.isEmpty { break }
        if trimmed.hasPrefix("//") { continue }
        body.append(line)
    }
    guard !body.isEmpty else {
        throw ScanError(description: "deleteTile's .managedAgent branch scanned as empty")
    }
    return body.joined(separator: "\n")
}

/// Main-actor collector for a subscriber task. A class so the collecting closure
/// does not have to be `inout`-capturing.
@MainActor
final class EventInbox {
    private(set) var events: [AgentRuntimeEvent] = []
    func append(_ event: AgentRuntimeEvent) { events.append(event) }
}

/// `nil` when the two sequences match, otherwise the first index that differs and
/// both labels there — the useful half of a sequence mismatch, since a full dump of
/// two eight-event arrays makes the reader do the diff.
@MainActor
private func firstDivergence(_ actual: [AgentRuntimeEvent], _ expected: [AgentRuntimeEvent]) -> String? {
    guard actual != expected else { return nil }
    for index in 0..<max(actual.count, expected.count) {
        let got = index < actual.count ? eventLabel(actual[index]) : "<nothing>"
        let want = index < expected.count ? eventLabel(expected[index]) : "<nothing>"
        if got != want {
            return "— at index \(index) got \(got), expected \(want) (\(actual.count) of \(expected.count) events)"
        }
    }
    return "— \(actual.count) events vs \(expected.count) expected"
}

/// A short label per event, so a sequence mismatch prints readably. The thread id
/// is part of the label because restamping is one of the things under test — a
/// label without it turns "the wrong thread" into an unexplained mismatch.
private func eventLabel(_ event: AgentRuntimeEvent) -> String {
    switch event {
    case let .sessionStateChanged(state): return "session:\(state.rawValue)"
    case let .turnStarted(threadId, turnId): return "turnStarted:\(turnId)@\(threadId)"
    case let .turnCompleted(threadId, turnId, outcome, _): return "turnCompleted:\(turnId):\(outcome.rawValue)@\(threadId)"
    case let .itemStarted(threadId, itemId, _, _): return "itemStarted:\(itemId)@\(threadId)"
    case let .itemCompleted(threadId, itemId, _, status): return "itemCompleted:\(itemId):\(status.rawValue)@\(threadId)"
    case let .contentDelta(threadId, _, _, delta): return "delta:\(delta)@\(threadId)"
    case let .requestOpened(threadId, requestId, _): return "requestOpened:\(requestId)@\(threadId)"
    case let .requestResolved(threadId, requestId, _): return "requestResolved:\(requestId)@\(threadId)"
    case let .userInputRequested(threadId, requestId, _): return "userInputRequested:\(requestId)@\(threadId)"
    case let .userInputResolved(threadId, requestId): return "userInputResolved:\(requestId)@\(threadId)"
    case let .tokenUsageUpdated(threadId, snapshot): return "tokenUsage:\(snapshot.inputTokens)/\(snapshot.outputTokens)@\(threadId)"
    case let .contextWindowUpdated(threadId, snapshot): return "contextWindow:\(String(describing: snapshot.occupancyPercentage))@\(threadId)"
    case let .childAgentSpawned(threadId, childAgentID, _, _, sourceItemID, _, _):
        return "childAgentSpawned:\(childAgentID.uuidString)@\(sourceItemID):\(threadId)"
    case let .semanticSignal(threadId, itemId, kind): return "semantic:\(kind.rawValue):\(itemId)@\(threadId)"
    case let .runtimeError(threadId, message): return "runtimeError:\(message)@\(threadId ?? "-")"
    }
}

/// Every file under `Sources/ContinuumRevived` that constructs the named
/// runner type, as paths relative to that root. Source-scanned for the same
/// reason `UIProbeAppearance.declaredConformers()` is: Swift cannot enumerate
/// this at runtime, the matrix runs from the repo root, and a missing
/// directory is a loud failure rather than a silent pass. The done-criterion
/// "no runner is constructed by a view" is otherwise only assertable by
/// reading the diff.
private func runnerConstructionSites(typeName: String) throws -> (sites: Set<String>, scannedFiles: Int) {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let scanRoot = "Sources/ContinuumRevived"
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let root = cwd.appendingPathComponent(scanRoot, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ScanError(description: "no \(scanRoot) directory at \(root.path) (working directory \(cwd.path)) — run this check from the repo root")
    }
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        throw ScanError(description: "could not enumerate \(root.path)")
    }
    // `<Type>(config:` and `<Type>.init(` — construction, not the type being
    // named in a signature, a comment or an `is` test.
    let pattern = try NSRegularExpression(pattern: "\(typeName)\\s*(\\.init)?\\s*\\(")
    var sites: Set<String> = []
    var scanned = 0
    for case let url as URL in walker where url.pathExtension == "swift" {
        let source = try String(contentsOf: url, encoding: .utf8)
        scanned += 1
        let stripped = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard pattern.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil else { continue }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        sites.insert(relative)
    }
    return (sites, scanned)
}

// MARK: - Fan-out self-check (P2D.6)

/// Gated on `--agent-fanout-check`.
///
/// Deterministic and offline: a real temp `git init` repository (worktrees are the
/// half that cannot be faked without testing nothing) and `ScriptedAgentRunner`s in
/// place of Pi. The runner factory picks its script from the RECORD's
/// `sourceItemId`, which is also the first witness that the mapping exists at spawn
/// time rather than being attached afterwards.
///
/// Six properties:
///   1. Three selected rows → three agents, each with its own worktree, its own
///      branch, and its own item's prompt. Git is asked, not the manager's return
///      value.
///   2. Completing agent 2 checks off item 2 IN THE TILE and leaves 1 and 3 alone.
///   3. Past the cap: 6 items → `maxFanOutBatch` launched, the rest DEFERRED and
///      named in the report the tile renders. Nothing is silently dropped —
///      launched + deferred + refused == items, asserted on every report here.
///   4. An item that already has an agent is REFUSED, not fanned out twice.
///   5. The mapping survives a relaunch: a second supervisor over the same store
///      resolves item → agent from the restored records alone.
///   6. A parent with durable, idle child history still gets a full fan-out batch;
///      only an explicitly configured active-child limit can reduce it.
///
/// Negative tests observed red at exit 1 with the final code are quoted at the
/// assertions they land at.
@MainActor
func runAgentFanOutChecks() async throws {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }
    func requireAccounted(_ report: AgentSupervisor.FanOutReport, _ items: [AgentSupervisor.FanOutItem], _ label: String) throws {
        let accounted = report.launched.count + report.deferred.count + report.refused.count
        guard accounted == items.count else {
            throw fail("\(label): \(items.count) items in, \(accounted) accounted for (\(report.summary)) — a fan-out may never drop an item silently")
        }
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-fanout-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    let storeDirectory = root.appendingPathComponent("support", isDirectory: true)
    let store = AgentStore(applicationSupportDirectory: storeDirectory)
    let config = AgentModelConfig.resolvedFromDefaults()

    // MARK: 1 · three selected rows, three isolated agents

    let rows = [
        LinearTicketQueueRow(identifier: "CON-1", title: "Fix auth", state: "Todo", stateType: "unstarted", priority: .high, labels: []),
        LinearTicketQueueRow(identifier: "CON-2", title: "Trim the sidebar", state: "Todo", stateType: "unstarted", priority: .medium, labels: []),
        LinearTicketQueueRow(identifier: "CON-3", title: "Cache the branch read", state: "Todo", stateType: "unstarted", priority: .low, labels: [])
    ]
    let tile = Tile(
        id: UUID(uuidString: "A2D60000-0000-4000-8000-000000000001")!,
        kind: .ticketQueue,
        title: "CON Ticket Queue",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 480),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(linearTeamKey: "CON", linearTeamId: nil, linearQuery: nil)
    )

    // Only the item that is meant to finish gets a completing script; the other two
    // stay mid-turn, which is what makes "leaves 1 and 3 untouched" a real claim.
    let completing: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .turnStarted(threadId: "provider", turnId: "t1"),
        .turnCompleted(threadId: "provider", turnId: "t1", outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready)
    ]
    let runners = FanOutRunnerLog()
    let supervisor = AgentSupervisor(store: store, makeRunner: { launch in
        runners.make(sourceItemId: launch.record.sourceItemId, script: launch.record.sourceItemId == "CON-2" ? completing : [.sessionStateChanged(.running)])
    })

    var fannedOut: [[LinearTicketQueueRow]] = []
    var lastReport: AgentSupervisor.FanOutReport?
    // Assigned once the tile exists; the handler below runs only on a click.
    var renderReport: ((AgentSupervisor.FanOutReport) -> Void)?
    let queueTile = TicketQueueTileNSView(tile: tile, rows: rows, emptyStateMessage: nil, fanOutHandler: { selected in
        fannedOut.append(selected)
        let report = supervisor.fanOut(
            items: selected.map {
                AgentSupervisor.FanOutItem(id: $0.identifier, prompt: "Work \($0.identifier): \($0.title)")
            },
            role: "implementer",
            cwd: repo,
            model: config.model,
            thinking: config.thinking,
            isolated: true
        )
        lastReport = report
        renderReport?(report)
    })
    // The tile is the source surface: it checks its own rows off.
    supervisor.onFanOutItemCompleted = { [weak queueTile] itemId, _ in
        queueTile?.markItemDone(itemId)
    }
    renderReport = { [weak queueTile] report in queueTile?.report(report.summary) }

    // Selection goes through the rendered checkboxes, not the model behind them —
    // a fan-out that could not be reached from the view is not the gesture.
    for identifier in ["CON-1", "CON-2", "CON-3"] {
        guard let box = queueTile.descendant(withIdentifier: "fanout.select.\(identifier)") as? NSButton else {
            throw fail("row \(identifier) rendered no selection control — a fan-out tile must be selectable")
        }
        box.state = .on
    }
    guard queueTile.selectedRowIdentifiers == ["CON-1", "CON-2", "CON-3"] else {
        throw fail("the tile reports \(queueTile.selectedRowIdentifiers) selected, not all three rows")
    }
    guard let runButton = queueTile.descendant(withIdentifier: "fanout.run") as? NSButton else {
        throw fail("the tile rendered no fan-out control")
    }
    runButton.performClick(nil)

    guard fannedOut.map({ $0.map(\.identifier) }) == [["CON-1", "CON-2", "CON-3"]] else {
        throw fail("the fan-out handler received \(fannedOut.map { $0.map(\.identifier) }), not one batch of all three selected rows")
    }
    guard let firstReport = lastReport else {
        throw fail("the fan-out produced no report")
    }
    let firstItems = rows.map { AgentSupervisor.FanOutItem(id: $0.identifier, prompt: "Work \($0.identifier): \($0.title)") }
    try requireAccounted(firstReport, firstItems, "the first fan-out")
    guard firstReport.launched.map(\.itemId) == ["CON-1", "CON-2", "CON-3"], firstReport.deferred.isEmpty, firstReport.refused.isEmpty else {
        throw fail("three items under the cap should all start: \(firstReport.summary)")
    }

    // Each agent: its own item, its own prompt, its own worktree and branch.
    // NEGATIVE TEST (observed red): `makeAgent` dropping `sourceItemId` →
    // "FAIL: agent … was fanned out for CON-1 and its record says nil".
    var worktrees: [String] = []
    var branches: [String] = []
    let manager = WorktreeManager()
    let listed = try manager.list(repo: repo)
    for (itemId, agentId) in firstReport.launched {
        guard let record = supervisor.records[agentId] else {
            throw fail("the supervisor lost the agent it fanned out for \(itemId)")
        }
        guard record.sourceItemId == itemId else {
            throw fail("agent \(agentId.rawValue.uuidString) was fanned out for \(itemId) and its record says \(record.sourceItemId ?? "nil")")
        }
        guard let branch = record.worktreeBranch else {
            throw fail("the agent for \(itemId) has no branch — a fan-out over one checkout is the clobbering P2C prevents")
        }
        guard record.cwd.hasPrefix(repo.appendingPathComponent(WorktreeManager.containerDirectoryName).path + "/") else {
            throw fail("the agent for \(itemId) works in \(record.cwd), which is not its own worktree")
        }
        guard listed.contains(where: {
            isolatedSpawnResolved($0.path) == isolatedSpawnResolved(URL(fileURLWithPath: record.cwd)) && $0.branch == branch
        }) else {
            throw fail("git does not know the worktree for \(itemId): \(listed.map { $0.path.lastPathComponent })")
        }
        worktrees.append(record.cwd)
        branches.append(branch)
    }
    // NEGATIVE TEST (observed red): reusing one slug for the batch →
    // "FAIL: … three agents share 1 worktree …".
    guard Set(worktrees).count == 3, Set(branches).count == 3 else {
        throw fail("three agents share \(Set(worktrees).count) worktree(s) and \(Set(branches).count) branch(es) — each item needs its own")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { runners.promptCount == 3 }) else {
        throw fail("only \(runners.promptCount) of 3 fanned-out agents were given a prompt")
    }
    guard runners.prompts(for: "CON-1") == ["Work CON-1: Fix auth"],
          runners.prompts(for: "CON-2") == ["Work CON-2: Trim the sidebar"],
          runners.prompts(for: "CON-3") == ["Work CON-3: Cache the branch read"] else {
        throw fail("the agents did not each get their own item's prompt: \(runners.promptsByItem)")
    }

    // MARK: 2 · completing agent 2 checks off item 2, and only item 2

    // NEGATIVE TEST (observed red): `deliver` firing the completion for every
    // outcome, or the tile marking every row → "FAIL: completing the agent for
    // CON-2 checked off ["CON-1", "CON-2", "CON-3"]".
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { queueTile.doneRowIdentifiers == ["CON-2"] }) else {
        throw fail("completing the agent for CON-2 checked off \(queueTile.doneRowIdentifiers)")
    }
    guard supervisor.completedFanOutItems == ["CON-2"] else {
        throw fail("the supervisor records \(supervisor.completedFanOutItems.sorted()) as completed, not just CON-2")
    }
    guard let doneMarker = queueTile.descendant(withIdentifier: "fanout.done.CON-2"), doneMarker.isHidden == false else {
        throw fail("CON-2's row does not SHOW that it is done")
    }
    for untouched in ["CON-1", "CON-3"] {
        guard let marker = queueTile.descendant(withIdentifier: "fanout.done.\(untouched)"), marker.isHidden else {
            throw fail("\(untouched)'s agent has not finished and its row is marked done")
        }
    }
    // A checked-off row drops out of the selection, so the next fan-out cannot
    // re-launch work that is already done.
    guard queueTile.selectedRowIdentifiers == ["CON-1", "CON-3"] else {
        throw fail("a completed row is still selected: \(queueTile.selectedRowIdentifiers)")
    }

    // MARK: 3 · past the cap: launched to the cap, the rest deferred and REPORTED
    //
    // Not isolated, on purpose: the cap is orthogonal to isolation and section 1
    // already proves the worktree half. Six worktrees to re-prove it would only
    // make this leg slower.
    let capItems = (1 ... 6).map { AgentSupervisor.FanOutItem(id: "CAP-\($0)", prompt: "cap item \($0)") }
    let capReport = supervisor.fanOut(
        items: capItems,
        role: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        isolated: false
    )
    try requireAccounted(capReport, capItems, "the capped fan-out")
    // NEGATIVE TEST (observed red): `fanOut` launching every item →
    // "FAIL: 6 items past a cap of 4 started 6 agents and deferred []".
    guard capReport.launched.count == AgentSupervisor.maxFanOutBatch,
          capReport.deferred == ["CAP-5", "CAP-6"],
          capReport.cap == AgentSupervisor.maxFanOutBatch else {
        throw fail("6 items past a cap of \(AgentSupervisor.maxFanOutBatch) started \(capReport.launched.count) agents and deferred \(capReport.deferred)")
    }
    guard supervisor.records.values.filter({ $0.sourceItemId?.hasPrefix("CAP-") == true }).count == AgentSupervisor.maxFanOutBatch else {
        throw fail("the store holds more capped agents than the cap allowed")
    }
    // NEGATIVE TEST (observed red): `summary` omitting the deferred clause →
    // "FAIL: the deferred count is not surfaced …".
    queueTile.report(capReport.summary)
    guard let surfaced = queueTile.fanOutStatusMessage,
          surfaced.contains("deferred 2"),
          surfaced.contains("cap of \(AgentSupervisor.maxFanOutBatch)") else {
        throw fail("the deferred count is not surfaced on the tile: \(queueTile.fanOutStatusMessage ?? "nothing")")
    }
    guard let statusView = queueTile.descendant(withIdentifier: "fanout.status") as? NSTextField,
          statusView.isHidden == false,
          statusView.stringValue == capReport.summary else {
        throw fail("the fan-out report is not RENDERED — a cap the user cannot see is a silent truncation")
    }

    // MARK: 4 · an item that already has an agent is refused, not doubled

    let repeatItems = [AgentSupervisor.FanOutItem(id: "CON-1", prompt: "Work CON-1 again")]
    let repeatReport = supervisor.fanOut(
        items: repeatItems,
        role: "implementer",
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        isolated: true
    )
    try requireAccounted(repeatReport, repeatItems, "the repeat fan-out")
    guard repeatReport.launched.isEmpty,
          repeatReport.refused.count == 1,
          repeatReport.refused[0].itemId == "CON-1",
          case .alreadyRunning = repeatReport.refused[0].refusal else {
        throw fail("fanning out an item that already has an agent produced \(repeatReport.summary)")
    }
    guard supervisor.records.values.filter({ $0.sourceItemId == "CON-1" }).count == 1 else {
        throw fail("CON-1 has \(supervisor.records.values.filter { $0.sourceItemId == "CON-1" }.count) agents — one item is one agent")
    }

    // MARK: 5 · the mapping survives a relaunch

    // A second supervisor over the same store, holding nothing this one built.
    // NEGATIVE TEST (observed red): `sourceItemId` left out of `AgentRecord`'s
    // `encode` → "FAIL: after a relaunch CON-3 has no agent …".
    let afterRelaunch = AgentSupervisor(store: AgentStore(applicationSupportDirectory: storeDirectory),
                                        makeRunner: { _ in ScriptedAgentRunner(script: []) })
    afterRelaunch.restore()
    for (itemId, agentId) in firstReport.launched {
        guard afterRelaunch.agent(forSourceItem: itemId) == agentId else {
            throw fail("after a relaunch \(itemId) has no agent — the mapping did not survive, so nothing can be checked off")
        }
        guard afterRelaunch.sourceItem(of: agentId) == itemId else {
            throw fail("after a relaunch agent \(agentId.rawValue.uuidString) no longer names its item")
        }
    }

    // MARK: 6 · idle durable children do not reduce a parented fan-out

    let parentId = supervisor.spawn(
        role: "orchestrator",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking
    )
    for index in 1 ... 3 {
        _ = supervisor.spawn(
            role: "worker-\(index)",
            prompt: nil,
            cwd: repo,
            model: config.model,
            thinking: config.thinking,
            parentAgentID: parentId
        )
    }
    let childItems = (1 ... 3).map { AgentSupervisor.FanOutItem(id: "CHILD-\($0)", prompt: "child item \($0)") }
    let childReport = supervisor.fanOut(
        items: childItems,
        role: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        parentAgentID: parentId,
        isolated: false
    )
    try requireAccounted(childReport, childItems, "the parented fan-out")
    guard childReport.cap == AgentSupervisor.maxFanOutBatch,
          childReport.launched.count == 3,
          childReport.deferred.isEmpty else {
        throw fail("a parent with 3 idle durable children did not receive a full fan-out: launched \(childReport.launched.count), cap \(childReport.cap), deferred \(childReport.deferred)")
    }
    guard supervisor.children(of: parentId).count == 6 else {
        throw fail("the parent ended with \(supervisor.children(of: parentId).count) children, expected all 3 existing plus 3 fanned out")
    }

    // MARK: 7 · the gesture is REACHABLE in the app, not only from this check
    //
    // Same shape as P2A.6's headless assertions, and for the same reason: the
    // sections above drive the view directly, so they would all stay green over an
    // app that never wires a `fanOutHandler` or never dispatches the command. The
    // `case .fanOutQueueSelection:` in `performPaletteAction` cannot be scanned for
    // — deleting it is a compile error, the switch is exhaustive — so what is
    // asserted is the registry, the palette rows, and the install branch.
    guard CommandRegistry.all().contains(where: { $0.id == "agent.fanOut" && $0.action == .fanOutQueueSelection }) else {
        throw fail("⌘K cannot reach a fan-out: no agent.fanOut in CommandRegistry")
    }
    guard LaunchPaletteModel.makeRows(profiles: []).contains(.action(.fanOutQueueSelection)) else {
        throw fail("the fan-out command is registered but not offered as a palette row")
    }
    let installBranch = try ticketQueueInstallSource()
    guard installBranch.contains("fanOutHandler:") else {
        throw fail("the app installs its ticket-queue tile with no fanOutHandler, so no row is selectable in the running app:\n\(installBranch)")
    }
    guard installBranch.contains("completedFanOutItems") else {
        throw fail("a tile installed after a completion would not show it — the install branch never replays completedFanOutItems:\n\(installBranch)")
    }

    // MARK: 8 · C2 — a fan-out child takes the asked-for harness, and shows up
    //
    // Two bugs that shipped together and hid each other. `harness:` was a
    // parameter of `fanOut` that was never forwarded to `spawn`, so every child
    // silently ran `AgentHarnessConfig.resolved()`; and `fanOut` never emitted
    // `.childAgentSpawned`, so children got durable parentage in the record and
    // no chip in the parent's transcript. `handleSpawnRequest` had always emitted
    // it — the two spawn paths simply disagreed.
    //
    // The harness asked for here is deliberately NOT the settings default, so a
    // regression that drops the parameter again reads as a real difference rather
    // than an accidental match.
    let chipParent = supervisor.spawn(
        role: "chip-orchestrator", prompt: nil, cwd: repo,
        model: config.model, thinking: config.thinking)
    let askedHarness: AgentHarness = AgentHarnessConfig.resolved() == .pi ? .claudeCode : .pi
    // A model the ASKED harness owns. A cross-harness model would have the
    // supervisor refuse the send for an unrelated reason and mask what this
    // section is actually about.
    guard let askedModel = AgentModelConfig.modelOptions(for: askedHarness).first else {
        throw fail("no catalogue model for \(askedHarness.rawValue)")
    }
    var parentEvents: [AgentRuntimeEvent] = []
    let parentStream = supervisor.events(for: chipParent)
    let collector = Task { @MainActor in
        for await event in parentStream { parentEvents.append(event) }
    }
    let chipItems = (1 ... 2).map {
        AgentSupervisor.FanOutItem(id: "CHIP-\($0)", prompt: "chip item \($0)")
    }
    let chipReport = supervisor.fanOut(
        items: chipItems, role: nil, cwd: repo, harness: askedHarness,
        model: askedModel, thinking: config.thinking,
        parentAgentID: chipParent, isolated: false)
    try requireAccounted(chipReport, chipItems, "the chip fan-out")
    guard chipReport.launched.count == 2 else {
        throw fail("the chip fan-out launched \(chipReport.launched.count) of 2 (\(chipReport.summary))")
    }
    // Let the multicast drain before reading what the parent saw.
    for _ in 0 ..< 50 where parentEvents.count < chipReport.launched.count {
        try? await Task.sleep(for: .milliseconds(20))
    }
    collector.cancel()

    for (itemId, childID) in chipReport.launched {
        guard let childHarness = supervisor.records[childID]?.harness else {
            throw fail("the fan-out child for \(itemId) persisted no harness at all")
        }
        guard childHarness == askedHarness else {
            throw fail("the fan-out child for \(itemId) runs \(childHarness.rawValue), but the batch asked for \(askedHarness.rawValue) — `harness:` was accepted and never forwarded to spawn")
        }
    }

    let spawnChips = parentEvents.compactMap { event -> (UUID, String)? in
        guard case let .childAgentSpawned(_, childAgentID, _, _, sourceItemID, provider, _) = event
        else { return nil }
        return (childAgentID, "\(sourceItemID ?? "-")|\(provider)")
    }
    guard spawnChips.count == chipReport.launched.count else {
        throw fail("the parent's stream carried \(spawnChips.count) childAgentSpawned events for \(chipReport.launched.count) launched children — a fan-out child with no chip is invisible to the orchestrator that started it")
    }
    for (itemId, childID) in chipReport.launched {
        guard spawnChips.contains(where: { $0.0 == childID.rawValue && $0.1 == "\(itemId)|\(askedHarness.rawValue)" }) else {
            throw fail("no childAgentSpawned named child \(childID.rawValue.uuidString) for item \(itemId) at harness \(askedHarness.rawValue); saw \(spawnChips.map(\.1))")
        }
    }

    supervisor.stopAll()
    print("AgentSupervisor fan-out: 3 rows → 3 agents on 3 worktrees with 3 prompts, completing one checked off exactly that row, \(capReport.summary) at the cap, a repeat refused, the mapping survived a relaunch, a parented batch fell to cap \(childReport.cap), and \(chipReport.launched.count) fan-out children took the asked-for \(askedHarness.rawValue) harness with one chip each on the parent's stream")
}

/// The scripted runners a fan-out produced, keyed by the item their agent was
/// spawned for — so "each agent got ITS item's prompt" is checkable.
private final class FanOutRunnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var runners: [String: ScriptedAgentRunner] = [:]

    func make(sourceItemId: String?, script: [AgentRuntimeEvent]) -> AgentRunning {
        let runner = ScriptedAgentRunner(script: script)
        if let sourceItemId {
            lock.withLock { runners[sourceItemId] = runner }
        }
        return runner
    }

    func prompts(for itemId: String) -> [String] {
        lock.withLock { runners[itemId] }?.prompts ?? []
    }

    var promptsByItem: [String: [String]] {
        lock.withLock { runners.mapValues(\.prompts) }
    }

    var promptCount: Int {
        lock.withLock { runners.values.reduce(0) { $0 + $1.prompts.count } }
    }
}

/// The body of `installInitialTicketQueueTile`, for the reachability assertions
/// above. A scan for the same reason `managedAgentCloseBranchSource` is one: the
/// install needs a live `CanvasNSView`, which a headless check does not have.
private func ticketQueueInstallSource() throws -> String {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.contains("func installInitialTicketQueueTile(") }) else {
        throw ScanError(description: "no `func installInitialTicketQueueTile(` in \(path) — the install moved, and this scan is now blind")
    }
    var body: [String] = []
    for line in lines[(start + 1)...] {
        if line.hasPrefix("    }") { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        body.append(line)
    }
    guard !body.isEmpty else {
        throw ScanError(description: "installInitialTicketQueueTile scanned as empty")
    }
    return body.joined(separator: "\n")
}

// MARK: - P3.3 · the row's state and the tile's presentation say the same thing
//
// Ticket: docs/38-tickets/94-sidebar-native-ux/P3.3-single-status-owner.md
//
// `AgentTileStatePresenter` lives above the row builder (it is App-layer, and it
// paints a header), so it cannot be the shared owner — the SNAPSHOT is. This check
// is the agreement: for every one of the six operational states, the row's
// `InboxState` and the tile's presentation must carry the same meaning, with exactly
// one divergence, named and reasoned.
//
// THE DIVERGENCE: the presenter renders `.failed` as `AgentStatus.idle` (the header
// has its own "Failed" label and does not need a status to carry it), which folds to
// `InboxState.ready`. The row maps `.failed` to `.failed`, because the inbox's one
// label slot is the only place a human sees that an agent broke —
// `AgentInboxRow.swift:52-55` records `.failed` as reachable-but-unwired, "Phase 4
// wires a fact"; this is that fact (§5.11).
@MainActor
func checkInboxStateAgreesWithTilePresenter<Failure: Error>(fail: (String) -> Failure) throws -> String {
    let approval = AgentPendingRequest(
        requestID: "req-approval",
        prompt: "Approve running a command?",
        responseMode: .fixedChoice(ApprovalDecision.compiledChoices),
        kind: .approval
    )
    let input = AgentPendingRequest(
        requestID: "req-input",
        prompt: "Which branch should this land on?",
        responseMode: .fixedChoice([]),
        kind: .input
    )
    // Hand-listed because `AgentTileOperationalState` carries associated values and
    // cannot be `CaseIterable` (design C8). `kindName` is the table the count below
    // is asserted against, so an eighth case cannot be added without appearing here.
    let states: [AgentTileOperationalState] = [
        .ready, .starting, .working, .queued, .needsAction(approval), .needsAction(input),
        .failed(message: "provider failed"), .restored
    ]
    guard Set(states.map(\.kindName)).count == 7 else {
        throw fail("presenter-agreement: the case table covers \(Set(states.map(\.kindName)).count) of AgentTileOperationalState's 7 kinds — \(Set(states.map(\.kindName)).sorted())")
    }

    // P3.5 migrates this existing row/tile agreement gate from state-only proof
    // to the words the real compatibility presenter gives its header. The phone
    // source and sidebar join are exercised by the matrix-wired Core check; this
    // App-layer assertion keeps their shared vocabulary honest at the actual tile
    // seam rather than accepting an unused helper as a proxy.
    for status in AgentStatus.allCases {
        let presentation = AgentTileStatePresenter.present(
            name: "Agreement", status: status, branchContext: nil, startedAt: nil)
        let expected = AgentStatusVocabulary.label(for: status)
        guard presentation.stateLabel == expected else {
            throw fail("presenter-agreement: raw \(status.rawValue) reads \(presentation.stateLabel) in the tile header, expected \(expected)")
        }
    }

    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var rows: [String] = []
    for state in states {
        // `.starting` has no provider turn by invariant, so it carries the
        // submission anchor instead — and both surfaces must still read 30s.
        let isStarting = state.kindName == "starting"
        let snapshot = AgentTileTurnSnapshot(
            state: state,
            capabilities: .sendStop(canSend: true, canStop: true),
            turnStartedAt: isStarting ? nil : now.addingTimeInterval(-30),
            submittedAt: isStarting ? now.addingTimeInterval(-30) : nil
        )
        let mine = InboxState.state(forSnapshot: snapshot)
        let presented = AgentTileStatePresenter.present(
            name: "Agreement",
            snapshot: snapshot,
            branchContext: nil,
            startedAt: isStarting ? nil : now.addingTimeInterval(-30),
            now: now
        )
        // The tile's fold, given everything the tile knows — including WHICH request
        // is open, which is a fact the presenter holds but does not put in its status.
        var pending: PendingRequest?
        if case let .needsAction(request) = state { pending = request.kind }
        let theirs = AgentInboxRow.state(for: presented.status, pending: pending)
        let expectedHeaderLabel: String
        switch snapshot.state {
        case .ready, .restored:
            expectedHeaderLabel = AgentStatusVocabulary.label(for: .idle)
        case .working, .queued:
            expectedHeaderLabel = AgentStatusVocabulary.label(for: .working)
        case .needsAction:
            expectedHeaderLabel = AgentStatusVocabulary.label(for: .needsAttention)
        case .failed:
            expectedHeaderLabel = AgentStatusVocabulary.failed
        case .starting:
            expectedHeaderLabel = AgentStatusVocabulary.starting
        }
        guard presented.stateLabel == expectedHeaderLabel else {
            throw fail("presenter-agreement: \(snapshot.state.kindName) reads \(presented.stateLabel) in the real tile header, expected \(expectedHeaderLabel)")
        }
        if snapshot.state.kindName == "ready" || snapshot.state.kindName == "restored" {
            guard mine.label == nil else {
                throw fail("presenter-agreement: the named \(snapshot.state.kindName) fold must keep the established unlabeled ready row while the tile says \(expectedHeaderLabel)")
            }
        } else if snapshot.state.kindName == "starting" {
            // THE SECOND NAMED DIVERGENCE, deliberate. The tile is the surface the
            // user is staring at during the spawn window, so it earns the precise
            // word ("Starting"); the sidebar keeps `InboxState`'s five-state
            // vocabulary, where the only honest reading is motion. The row is not
            // lying — it says working and carries a live clock anchored on the
            // submission — it is simply less specific than the tile, which is the
            // established relationship between these two surfaces.
            guard mine.label == AgentStatusVocabulary.label(for: .working) else {
                throw fail("presenter-agreement: starting reads \(mine.label ?? "nil") in the sidebar, expected the working label")
            }
        } else {
            guard mine.label == expectedHeaderLabel else {
                throw fail("presenter-agreement: \(snapshot.state.kindName) reads \(mine.label ?? "nil") in the sidebar and \(expectedHeaderLabel) in the tile header")
            }
        }

        let isTheDivergence = snapshot.state.kindName == "failed"
        if isTheDivergence {
            guard mine == .failed, theirs == .ready else {
                throw fail("presenter-agreement: the ONE named divergence is gone — a failed turn reads row \(mine.rawValue) / tile-fold \(theirs.rawValue). If the presenter started carrying failure in its status this exception must be deleted, not kept as a lie")
            }
        } else {
            guard mine == theirs else {
                throw fail("presenter-agreement: \(snapshot.state.kindName) reads \(mine.rawValue) on the row and \(theirs.rawValue) through the tile's presentation — two surfaces telling a human different things about one agent")
            }
        }
        // The spawn window must be measurable on BOTH surfaces, or the dead-air
        // interval is still unreported where it matters. This is the assertion that
        // fails if `submittedAt` ever stops reaching a presenter.
        if snapshot.state.kindName == "starting" {
            guard presented.elapsedSeconds == 30 else {
                throw fail("presenter-agreement: the starting window measures \(String(describing: presented.elapsedSeconds))s in the tile header, expected 30 from the submission anchor")
            }
        }
        rows.append("\(snapshot.state.kindName)=\(mine.rawValue)\(isTheDivergence ? "(tile \(theirs.rawValue), documented)" : "")")
    }

    // The elapsed anchor is the snapshot's, on both surfaces.
    let working = AgentTileTurnSnapshot(
        state: .working,
        capabilities: .sendStop(canSend: false, canStop: true),
        turnStartedAt: now.addingTimeInterval(-30)
    )
    let workingPresentation = AgentTileStatePresenter.present(
        name: "Agreement", snapshot: working, branchContext: nil,
        // A replay/rebuilt view may offer a newer local fallback. The tile must
        // ignore it while the supervisor has the real turn origin.
        startedAt: now.addingTimeInterval(-3), now: now
    )
    guard workingPresentation.elapsedSeconds == 30 else {
        throw fail("presenter-agreement: the tile header measures \(String(describing: workingPresentation.elapsedSeconds))s from a replay-restamped local clock instead of the supervisor's 30s turn start")
    }
    return "row/tile state agreement over \(states.count) snapshots (\(rows.joined(separator: ", "))), two documented divergences (failed, starting), 30s elapsed from the stamped start on both surfaces and from the submission in the spawn window"
}

// MARK: - P3.2 · no surface may list managed records ungated
//
// The behavioural half of the gate is a compile-time fact inside Core
// (`reconciledRecords(_:)` needs a `Proof` nothing outside Core can mint), and
// `ManagedAgentSessionStore.loadAll()` stays public for Core's own reader and the
// store's round-trip check. This scan is what keeps the app target off it: an
// unreviewed `managedSessionStore.loadAll()` in `ContinuumApp.swift` would restore
// exactly the ungated listing P3.2 removed, and it would do it silently.
//
// It also pins the two swallowed reads out of existence: `(try? …) ?? []` around a
// listing turns a refusal into "no agents", which is the bug in its quietest form.
func checkManagedSessionReadGateSources() throws -> String {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var offenders: [String] = []
    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { continue }
        if trimmed.contains("managedSessionStore.loadAll()") {
            offenders.append("\(index + 1): ungated listing read — \(trimmed)")
        }
        if trimmed.contains("reconciledRecords"), trimmed.contains("try?") {
            offenders.append("\(index + 1): a swallowed listing read reports 'no agents' for a refusal — \(trimmed)")
        }
        if trimmed.contains("reconciledManagedSessionSource.records"), trimmed.contains("try?") {
            offenders.append("\(index + 1): a swallowed listing read reports 'no agents' for a refusal — \(trimmed)")
        }
    }
    guard offenders.isEmpty else {
        throw ScanError(description: "P3.2: \(offenders.count) ungated or swallowed managed-session listing read(s) in \(path):\n" + offenders.joined(separator: "\n"))
    }
    // Vacuity guard: the gated door must actually be in use, or an empty scan means
    // the app stopped listing agents rather than that it lists them safely.
    let gatedReads = lines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//")
            && (trimmed.contains("reconciledRecords(") || trimmed.contains("reconciledManagedSessionSource.records("))
    }
    guard !gatedReads.isEmpty else {
        throw ScanError(description: "P3.2: \(path) contains no gated listing read at all, so the scan above passed vacuously")
    }
    return "managed-session read gate: 0 ungated/swallowed listing reads in ContinuumApp.swift, \(gatedReads.count) gated reads present"
}
