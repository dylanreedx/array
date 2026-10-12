import Foundation

/// How many times this process opened the files the sidebar is built from — the
/// registry, a workspace document, a project canvas, a project's session
/// directory. A witness reads the DELTA across one action (an agent event push, a
/// workspace switch) to prove the action's disk cost as an outcome, not as a
/// reading of the source. Production never reads it; incrementing is a lock and
/// an add.
public final class StoreReadProbe: @unchecked Sendable {
    public static let shared = StoreReadProbe()
    private let lock = NSLock()
    private var reads = 0

    public var count: Int { lock.withLock { reads } }

    func record() { lock.withLock { reads += 1 } }
}
