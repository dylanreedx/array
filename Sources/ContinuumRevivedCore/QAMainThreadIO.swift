import Foundation

/// QA: blocking work the main thread did that it must not — a session file
/// read, a tmux command. Counted where the work happens, so a check can say
/// that a code path (a Terminal face ending, a pause ending, a followed
/// session's last read) kept the main thread free (`.plans/79` review #12;
/// `docs/internals/performance.md`). Two increments under a lock; nothing else.
public enum QAMainThreadIO {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts = (fileReads: 0, tmuxRuns: 0)

    public static var fileReads: Int { lock.withLock { counts.fileReads } }
    public static var tmuxRuns: Int { lock.withLock { counts.tmuxRuns } }

    static func noteFileRead() {
        guard Thread.isMainThread else { return }
        lock.withLock { counts.fileReads += 1 }
    }

    static func noteTmuxRun() {
        guard Thread.isMainThread else { return }
        lock.withLock { counts.tmuxRuns += 1 }
    }
}
