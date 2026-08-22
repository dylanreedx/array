import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A child process that leads its **own process group**, so stopping it stops
/// everything it launched. M1.8 (`.plans/46`).
///
/// **Why this exists at all.** All three managed-agent runners spawned through
/// Foundation `Process`, whose `terminate()` sends SIGTERM to exactly one pid.
/// A coding CLI is a process *tree* — the shells it runs, the MCP servers it
/// starts, the compilers and test runners its tools invoke — and every one of
/// those survived a Stop, holding files, ports and CPU. `Process` exposes no
/// process-group API of any kind, so this had to become a `posix_spawn`.
///
/// **Why it lives in Core.** The machinery already existed and was correct, but
/// it was walled inside the nested `AgentNameOneShot` enum in the **app** target,
/// and all three runners are in `ContinuumRevivedCore`, which cannot import the
/// app. So it is not "lift it up a level": the helper is built here, and
/// `AgentNameOneShot` becomes a client of it rather than its owner. M2 replaces
/// pi's *transport* and M7 replaces claude's and codex's — both on top of this
/// spawn rather than instead of it, so it is written once either way.
///
/// **`setpgid` after `Process.run()` does not work, and the reason is not
/// obvious.** It races the child's `exec` and returns EACCES on macOS once the
/// child has already exec'd. The group has to be requested at spawn time, which
/// is what `POSIX_SPAWN_SETPGROUP` + `posix_spawnattr_setpgroup(&attrs, 0)` does:
/// the child becomes the leader of a new group whose id is its own pid.
public final class ProcessGroupChild: @unchecked Sendable {
    public enum SpawnError: Error, CustomStringConvertible {
        case attributesUnavailable
        case fileActionsUnavailable
        case allocationFailed
        case spawnFailed(errnoCode: Int32, executable: String)

        public var description: String {
            switch self {
            case .attributesUnavailable: return "could not build posix_spawn attributes"
            case .fileActionsUnavailable: return "could not build posix_spawn file actions"
            case .allocationFailed: return "could not allocate the child's argv/envp"
            case let .spawnFailed(code, executable):
                return "could not launch \(executable): \(String(cString: strerror(code))) (\(code))"
            }
        }
    }

    /// What the child does with stdin.
    public enum StandardInput {
        /// A pipe the parent can write to and close. Not used by any runner today;
        /// it is what M2's rpc transport needs.
        case pipe
        /// `/dev/null`. Codex pins this today (`CodexAgentRunner.swift:338`) and
        /// must keep doing so — it otherwise reads the app's stdin.
        case nullDevice
        /// Inherit the parent's. pi's current behaviour.
        case inherit
    }

    public let pid: pid_t
    /// The child's process GROUP id. Equal to `pid`, because the child leads its
    /// own group — named separately so the signalling code reads honestly.
    public var processGroupId: pid_t { pid }
    public let standardOutput: FileHandle
    public let standardError: FileHandle
    /// Non-nil only for `.pipe`.
    public let standardInput: FileHandle?

    private let lock = NSLock()
    /// The RAW `wait(2)` status, kept raw because `AgentNameOneShot` decodes it
    /// with its own `processExitCode` and passes it around undecoded.
    private var reapedRaw: Int32?

    private init(pid: pid_t, standardOutput: FileHandle, standardError: FileHandle, standardInput: FileHandle?) {
        self.pid = pid
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardInput = standardInput
    }

    // MARK: - Spawning

    public static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        standardInput: StandardInput = .inherit,
        /// `argv[0]`, when it must differ from the executable path. `Process` always
        /// passes the path; `AgentNameOneShot` passes a bare `sh` and a login shell's
        /// own basename, and argv[0] is not cosmetic for a shell.
        argv0: String? = nil
    ) throws -> ProcessGroupChild {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe? = standardInput == .pipe ? Pipe() : nil

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw SpawnError.fileActionsUnavailable
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if case .pipe = standardInput {
            posix_spawn_file_actions_adddup2(&fileActions, stdinPipe!.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        }
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        if case .nullDevice = standardInput {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }

        // Close EVERY original descriptor the child does not need, including the
        // sources of the dup2s above.
        //
        // Both halves are load-bearing and one of them was learned the hard way.
        // Leaving the parent's READ ends open in the child is the obvious leak.
        // Leaving the dup2 SOURCES open is the subtle one: the child then holds a
        // second reference to its own stdin read end, so a provider that closes
        // fd 0 does not close the pipe, the parent's write never gets EPIPE, and
        // an input-failure path waits out its whole timeout instead of failing
        // fast. Same on the other side — a duplicate stdout write end means EOF
        // never arrives until the whole tree exits.
        var toClose: [Int32] = [
            stdoutPipe.fileHandleForReading.fileDescriptor,
            stderrPipe.fileHandleForReading.fileDescriptor,
            stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderrPipe.fileHandleForWriting.fileDescriptor
        ]
        if let stdinPipe {
            toClose.append(stdinPipe.fileHandleForReading.fileDescriptor)
            toClose.append(stdinPipe.fileHandleForWriting.fileDescriptor)
        }
        let reserved: Set<Int32> = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
        for descriptor in Set(toClose) where !reserved.contains(descriptor) {
            posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }
        if let currentDirectory {
            _ = currentDirectory.path.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0)
            }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw SpawnError.attributesUnavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        // THE point of this whole type. Requested at spawn time because a
        // `setpgid` after the fact races the child's exec and returns EACCES.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw SpawnError.attributesUnavailable
        }

        var argv: [UnsafeMutablePointer<CChar>?] = []
        var envp: [UnsafeMutablePointer<CChar>?] = []
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        for value in [argv0 ?? executable] + arguments {
            guard let pointer = strdup(value) else { throw SpawnError.allocationFailed }
            argv.append(pointer)
        }
        argv.append(nil)
        for value in environment.map({ "\($0.key)=\($0.value)" }).sorted() {
            guard let pointer = strdup(value) else { throw SpawnError.allocationFailed }
            envp.append(pointer)
        }
        envp.append(nil)

        var pid: pid_t = 0
        let result = executable.withCString { path in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envpBuffer in
                    posix_spawn(&pid, path, &fileActions, &attributes,
                                argvBuffer.baseAddress, envpBuffer.baseAddress)
                }
            }
        }
        guard result == 0 else {
            throw SpawnError.spawnFailed(errnoCode: result, executable: executable)
        }

        // The parent closes the child's ends, for the same reason in reverse.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()

        return ProcessGroupChild(
            pid: pid,
            standardOutput: stdoutPipe.fileHandleForReading,
            standardError: stderrPipe.fileHandleForReading,
            standardInput: stdinPipe?.fileHandleForWriting
        )
    }

    // MARK: - Waiting

    /// Blocks until the child exits and returns its exit code (or `128 + signal`
    /// for a signalled child, matching what a shell reports and what
    /// `Process.terminationStatus` would have shown for a normal exit).
    @discardableResult
    public func wait() -> Int32 {
        if let raw = lock.withLock({ reapedRaw }) { return Self.exitCode(fromRaw: raw) }
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) < 0 {
            if errno == EINTR { continue }
            // ECHILD: already reaped, by `terminateGroup`'s WNOHANG loop.
            return lock.withLock { reapedRaw }.map(Self.exitCode(fromRaw:)) ?? 0
        }
        lock.withLock { reapedRaw = raw }
        return Self.exitCode(fromRaw: raw)
    }

    /// One non-blocking reap attempt, returning the RAW `wait(2)` status.
    ///
    /// For a caller that owns its own timeout policy and must never block —
    /// `AgentNameOneShot`, whose whole point is that a normally-exited leader can
    /// leave a descendant holding the pipes, so `waitUntilExit` would wait forever.
    @discardableResult
    public func pollExitRaw() -> Int32? {
        if let raw = lock.withLock({ reapedRaw }) { return raw }
        var raw: Int32 = 0
        let result = waitpid(pid, &raw, WNOHANG)
        guard result == pid else { return nil }
        lock.withLock { reapedRaw = raw }
        return raw
    }

    /// The RAW status if this child has already been reaped, without attempting one.
    public var reapedRawStatus: Int32? { lock.withLock { reapedRaw } }

    private static func exitCode(fromRaw raw: Int32) -> Int32 {
        // WIFEXITED/WTERMSIG are macros; Swift does not import them.
        if raw & 0x7F == 0 { return (raw >> 8) & 0xFF }
        return 128 + (raw & 0x7F)
    }

    // MARK: - Stopping

    /// The two graces this codebase uses, as VALUES rather than two code paths.
    ///
    /// Decided 2026-08-22: one escalation routine, two graces. The interactive
    /// Stop keeps ~0.15s so the button feels instant; the harness path keeps the
    /// 2.0s `HarnessRunControl` already uses. The grace is a parameter, not a fork
    /// in the logic — two routines is how they drift.
    public enum Grace {
        /// A human pressed Stop and is watching the button.
        public static let interactive: TimeInterval = 0.15
        /// A harness run being torn down; nobody is waiting on a frame.
        public static let harness: TimeInterval = 2.0
    }

    /// SIGTERM the whole group, wait out the grace, then SIGKILL whatever is left.
    ///
    /// Signals the GROUP (`kill(-pgid, …)`), which is the entire point: SIGTERM to
    /// the leader alone leaves every shell, MCP server and tool subprocess the
    /// agent started running.
    ///
    /// Every `waitpid` here is `WNOHANG`. That is deliberate and load-bearing: a
    /// wedged child must not turn cleanup into a second hang, which is the trap
    /// the one-shot path already learned.
    public func terminateGroup(graceSeconds: TimeInterval = Grace.interactive) {
        if Self.groupExists(processGroupId) {
            _ = kill(-processGroupId, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            _ = pollExitRaw()
            if !Self.groupExists(processGroupId) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if Self.groupExists(processGroupId) {
            _ = kill(-processGroupId, SIGKILL)
        }
        let reapDeadline = Date().addingTimeInterval(graceSeconds)
        while reapedRawStatus == nil && Date() < reapDeadline {
            _ = pollExitRaw()
            if reapedRawStatus == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        // Do NOT wait again past the bound. A wedged child must not turn cleanup
        // into a second hang; the pipe readers have their own bounded finish.
    }

    /// Whether anything is still alive in the group. `EPERM` counts as alive: the
    /// group exists, this process merely may not signal it.
    public static func groupExists(_ pgid: pid_t) -> Bool {
        guard pgid > 1 else { return false }
        return kill(-pgid, 0) == 0 || errno == EPERM
    }
}
