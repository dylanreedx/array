import Foundation

public struct ActivitySnapshotCache: Sendable {
    private let fileURL: URL
    private let writer: AtomicWriter
    private let clock: any Clock
    private let debounce: TimeInterval
    private var lastWrittenSequence: UInt64
    private var pending: (snapshot: ActivityLogSnapshot, dueAt: Date)?

    public init(
        fileURL: URL,
        clock: any Clock = SystemClock(),
        debounce: TimeInterval = ConnectionSupervisorSettings.defaults.snapshotDebounce,
        writer: AtomicWriter = AtomicWriter()
    ) {
        self.fileURL = fileURL
        self.clock = clock
        self.debounce = debounce
        self.writer = writer
        if let existing: ActivityLogSnapshot = try? writer.read(at: fileURL) {
            self.lastWrittenSequence = existing.snapshotSequence
        } else {
            self.lastWrittenSequence = 0
        }
    }

    public func load() -> ActivityLogSnapshot? {
        try? writer.read(at: fileURL)
    }

    public mutating func update(_ snapshot: ActivityLogSnapshot) throws {
        guard snapshot.snapshotSequence > lastWrittenSequence else { return }
        pending = (snapshot, clock.now().addingTimeInterval(debounce))
    }

    public mutating func flushDueWrites() throws {
        guard let pending, clock.now() >= pending.dueAt else { return }
        try writer.write(pending.snapshot, to: fileURL)
        lastWrittenSequence = pending.snapshot.snapshotSequence
        self.pending = nil
    }
}
