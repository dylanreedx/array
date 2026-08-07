import Foundation

/// Lossless source accumulation for the one open markup entry.
///
/// Parsing and presentation may be throttled, but appending never is. Keeping
/// this type separate from `StreamingMarkupParseScheduler` makes it impossible
/// for a coalesced parse request to discard provider source.
public struct StreamingMarkupBuffer: Equatable, Sendable {
    private var chunks: [String]

    public init(source: String = "") {
        self.chunks = source.isEmpty ? [] : [source]
    }

    /// Materializes the lossless source only at parser/compatibility boundaries.
    /// Deltas are retained as appended chunks so accumulation itself is O(delta)
    /// and does not repeatedly copy the answer-so-far string.
    public var source: String { chunks.joined() }

    public var isEmpty: Bool { chunks.isEmpty }

    public mutating func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        chunks.append(delta)
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        chunks.removeAll(keepingCapacity: keepingCapacity)
    }
}

/// Deterministic, clock-injected coalescing for streaming parser requests.
/// The caller owns the clock and invokes the parser only when this scheduler
/// returns true. `requestParse()` never owns or copies semantic source.
public struct StreamingMarkupParseScheduler: Equatable, Sendable {
    public let minimumInterval: TimeInterval
    public private(set) var hasPendingRequest: Bool
    private var lastParseTime: TimeInterval?

    public init(maximumParsesPerSecond: Double = 30) {
        precondition(maximumParsesPerSecond.isFinite && maximumParsesPerSecond > 0)
        self.minimumInterval = 1 / maximumParsesPerSecond
        self.hasPendingRequest = false
        self.lastParseTime = nil
    }

    public mutating func requestParse() {
        hasPendingRequest = true
    }

    public func nextReadyTime(now: TimeInterval) -> TimeInterval? {
        guard hasPendingRequest, now.isFinite else { return nil }
        guard let lastParseTime else { return now }
        guard now >= lastParseTime else { return lastParseTime + minimumInterval }
        return now - lastParseTime < minimumInterval ? lastParseTime + minimumInterval : now
    }

    public mutating func shouldParse(now: TimeInterval) -> Bool {
        guard hasPendingRequest, now.isFinite else { return false }
        if let lastParseTime {
            guard now >= lastParseTime else { return false }
            guard now - lastParseTime >= minimumInterval else { return false }
        }
        hasPendingRequest = false
        lastParseTime = now
        return true
    }

    /// Consumes a pending request without waiting for the coalescing interval.
    /// Used when an entry finishes so its final source is always parsed.
    public mutating func flush() -> Bool {
        guard hasPendingRequest else { return false }
        hasPendingRequest = false
        return true
    }
}
