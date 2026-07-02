import Foundation

// Ticket: docs/38-tickets/12-injectable-substrates.md
//
// The only blessed path to "now" for new topology/observer/transport code. New
// types in those layers take a `clock: any Clock` in their initializer (default
// `SystemClock()`) instead of calling `Date()` directly, so their time-gated logic
// can be exercised deterministically in the check harness via `FakeClock`.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class FakeClock: Clock, @unchecked Sendable {
    public var current: Date

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    public func now() -> Date { current }

    public func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }
}
