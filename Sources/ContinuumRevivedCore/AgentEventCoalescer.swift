import Foundation

/// Per-turn producer-side batching of an agent's event stream.
///
/// A provider streams one `.contentDelta` per token. Each used to cost a main
/// queue hop plus the supervisor's whole delivery pass, whether or not anyone
/// could see the agent. This runs on the producer's own thread: it merges a run
/// of adjacent deltas that share (thread, turn, stream) into one event, and hops
/// to the consumer once per flush interval instead of once per token.
///
/// What it never does: reorder, drop or rewrite. Any event that is not a content
/// delta flushes the pending delta first and is emitted straight after it, so the
/// consumer sees exactly the sequence the provider sent, with adjacent text
/// concatenated. Lifecycle, tool, request and terminal events are never delayed.
///
/// Hidden agents (no presented tile) flush slowly; presented ones at display
/// rate. A reveal flushes at once.
public final class AgentEventCoalescer: @unchecked Sendable {
    public static let presentedInterval: TimeInterval = 1.0 / 60.0
    public static let hiddenInterval: TimeInterval = 0.25

    /// Checks only: behave as before the coalescer, one hop per event.
    nonisolated(unsafe) public static var qaPassThrough = false

    private let lock = NSLock()
    private var pending: AgentRuntimeEvent?
    private var timerArmed = false
    private var hops = 0
    private var merged = 0
    private let isPresented: @Sendable () -> Bool
    /// Called with the lock held, so emission order equals submission order.
    /// Must not block (the supervisor's is a `DispatchQueue.main.async`).
    private let emit: @Sendable (AgentRuntimeEvent) -> Void
    private let timerQueue: DispatchQueue

    public init(
        isPresented: @escaping @Sendable () -> Bool,
        emit: @escaping @Sendable (AgentRuntimeEvent) -> Void
    ) {
        self.isPresented = isPresented
        self.emit = emit
        self.timerQueue = DispatchQueue(label: "dev.arrayapp.agent-event-coalescer", qos: .userInitiated)
    }

    /// Events handed to the consumer, and deltas folded into an earlier one.
    public var counts: (emitted: Int, merged: Int) {
        lock.lock(); defer { lock.unlock() }
        return (hops, merged)
    }

    public func submit(_ event: AgentRuntimeEvent) {
        lock.lock(); defer { lock.unlock() }
        if Self.qaPassThrough { emitLocked(event); return }
        guard case let .contentDelta(thread, turn, kind, delta) = event else {
            flushLocked()
            emitLocked(event)
            return
        }
        if case let .contentDelta(pThread, pTurn, pKind, pDelta)? = pending,
           pThread == thread, pTurn == turn, pKind == kind {
            pending = .contentDelta(threadId: thread, turnId: turn, streamKind: kind, delta: pDelta + delta)
            merged += 1
        } else {
            flushLocked()
            pending = event
        }
        armTimerLocked()
    }

    /// Emits whatever is pending now. Called at the end of a run and on reveal.
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        flushLocked()
    }

    private func flushLocked() {
        guard let event = pending else { return }
        pending = nil
        emitLocked(event)
    }

    private func emitLocked(_ event: AgentRuntimeEvent) {
        hops += 1
        emit(event)
    }

    private func armTimerLocked() {
        guard !timerArmed else { return }
        timerArmed = true
        let interval = isPresented() ? Self.presentedInterval : Self.hiddenInterval
        timerQueue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.timerArmed = false
            self.flushLocked()
        }
    }
}

/// Which agents currently have a tile a person can see. Written from the main
/// actor, read from producer threads; default is hidden.
public final class AgentEventPresentation: @unchecked Sendable {
    private let lock = NSLock()
    private var presented: Set<UUID> = []
    private var coalescers: [UUID: [ObjectIdentifier: AgentEventCoalescer]] = [:]

    public init() {}

    public func isPresented(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return presented.contains(id)
    }

    /// Becoming visible flushes what a hidden agent was holding.
    public func setPresented(_ value: Bool, for id: UUID) {
        lock.lock()
        let changed = value ? presented.insert(id).inserted : presented.remove(id) != nil
        let live = value && changed ? Array((coalescers[id] ?? [:]).values) : []
        lock.unlock()
        for coalescer in live { coalescer.flush() }
    }

    public func register(_ coalescer: AgentEventCoalescer, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        coalescers[id, default: [:]][ObjectIdentifier(coalescer)] = coalescer
    }

    public func unregister(_ coalescer: AgentEventCoalescer, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        coalescers[id]?[ObjectIdentifier(coalescer)] = nil
        if coalescers[id]?.isEmpty == true { coalescers[id] = nil }
    }
}
