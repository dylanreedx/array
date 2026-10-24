import Darwin
import Foundation

/// libghostty starts sentry-native's Breakpad backend inside `ghostty_init()`, and
/// Breakpad registers a TASK exception port for the four crash exceptions. Task
/// exception ports are inherited across fork and exec, so every process Array
/// starts afterwards (agent CLIs, their shells, the checks and test binaries
/// those agents build) reports its crashes to Array's Breakpad thread, which
/// writes a dump and `_exit`s ARRAY. Measured 2026-10-24: three live Array
/// sessions ended within a second of an agent's `/tmp` test binary failing a
/// `try!` (EXC_BREAKPOINT); an `abort()` in another child (EXC_CRASH, outside
/// Breakpad's mask) left Array running. Because the exit is clean, macOS wrote
/// no Array crash report.
///
/// Clearing the ports after the bootstrap sends a crash, in Array or in any
/// child, to the host port, i.e. ReportCrash, which only reports it.
enum ChildCrashIsolation {
    /// Breakpad's `kExceptionMask`.
    static let crashMask = exception_mask_t(
        EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT)

    /// How long the last `detachInProcessHandler` waited for Breakpad to arrive.
    nonisolated(unsafe) private(set) static var lastWait: TimeInterval?

    /// libghostty starts Sentry on its own thread inside `ghostty_init()`
    /// (ghostty src/crash/sentry.zig), so the ports are claimed a moment AFTER
    /// it returns. Clearing them at once loses that race and Breakpad installs
    /// itself afterwards: wait for it, bounded, then clear.
    @discardableResult
    static func detachInProcessHandler(waitingUpTo timeout: TimeInterval = 1) -> Bool {
        let start = Date()
        while handledCrashMasks().isEmpty, Date().timeIntervalSince(start) < timeout {
            usleep(1_000)
        }
        lastWait = Date().timeIntervalSince(start)
        return task_set_exception_ports(
            mach_task_self_, crashMask, mach_port_t(MACH_PORT_NULL),
            exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE)
        ) == KERN_SUCCESS
    }

    /// The crash masks this task still routes to a live port. Empty once detached.
    static func handledCrashMasks() -> [exception_mask_t] {
        let capacity = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: capacity)
        var ports = [mach_port_t](repeating: 0, count: capacity)
        var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
        var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
        var count = mach_msg_type_number_t(capacity)
        let result = task_get_exception_ports(
            mach_task_self_, crashMask, &masks, &count, &ports, &behaviors, &flavors)
        guard result == KERN_SUCCESS else { return [crashMask] }
        return (0..<Int(count)).compactMap { index in
            let port = ports[index]
            return port != mach_port_t(MACH_PORT_NULL) && port != mach_port_t.max // MACH_PORT_DEAD
                ? masks[index] : nil
        }
    }
}

/// `--child-crash-isolation-check`: after the production bootstrap, a child that
/// traps must die of its own SIGTRAP and leave this process running.
enum ChildCrashIsolationChecks {
    /// Handled at the top of `main`, before `ghostty_init()`, so the child keeps
    /// exactly the ports it inherited from the check.
    static let trapChildFlag = "--qa-trap-child"

    static func trapChild() -> Never {
        fatalError("deliberate trap for --child-crash-isolation-check")
    }

    static func run() throws -> String {
        struct Failure: Error, CustomStringConvertible { let description: String }
        // Spawn only when this process routes crashes nowhere. With a handler
        // still installed the trap would reach it, and if that handler were
        // inherited it could be a live Array's.
        // Give a late Breakpad the same second production waits for it, so a
        // detach that ran before Sentry finished starting cannot pass.
        Thread.sleep(forTimeInterval: 1)
        let handled = ChildCrashIsolation.handledCrashMasks()
        guard handled.isEmpty else {
            throw Failure(description: "after ghostty_init this process still routes crash exceptions "
                + "(masks \(handled.map { String(format: "0x%x", $0) })) to an in-process handler; "
                + "a crashing child would exit the app")
        }
        guard let executable = Bundle.main.executableURL else {
            throw Failure(description: "no executable to spawn as the trapping child")
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = [trapChildFlag]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        guard child.terminationReason == .uncaughtSignal, child.terminationStatus == SIGTRAP else {
            throw Failure(description: "the trapping child should die of SIGTRAP; it ended with "
                + "reason \(child.terminationReason.rawValue) status \(child.terminationStatus)")
        }
        let waited = ChildCrashIsolation.lastWait.map { String(format: "%.0f ms", $0 * 1000) } ?? "no detach"
        return "ChildCrashIsolationChecks passed: a child's trap stayed in the child (Breakpad detached after \(waited))"
    }
}
