import Foundation

public struct TerminalWheelSettings: Equatable, Sendable {
    public var preciseMultiplier: Double
    public var lineMultiplier: Double
    public var maxAbsDeltaPerEvent: Double?

    public init(preciseMultiplier: Double, lineMultiplier: Double, maxAbsDeltaPerEvent: Double?) {
        self.preciseMultiplier = preciseMultiplier
        self.lineMultiplier = lineMultiplier
        self.maxAbsDeltaPerEvent = maxAbsDeltaPerEvent
    }

    public static let `default` = TerminalWheelSettings(
        preciseMultiplier: 1.0,
        lineMultiplier: 1.0,
        maxAbsDeltaPerEvent: nil
    )
}

public struct TerminalWheelInput: Equatable, Sendable {
    public var deltaX: Double
    public var deltaY: Double
    public var hasPreciseScrollingDeltas: Bool

    public init(deltaX: Double, deltaY: Double, hasPreciseScrollingDeltas: Bool) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
    }
}

public struct TerminalWheelOutput: Equatable, Sendable {
    public var deltaX: Double
    public var deltaY: Double

    public init(deltaX: Double, deltaY: Double) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

public enum TerminalWheelNormalizer {
    public static func normalize(_ input: TerminalWheelInput, settings: TerminalWheelSettings = .default) -> TerminalWheelOutput {
        let multiplier = input.hasPreciseScrollingDeltas ? settings.preciseMultiplier : settings.lineMultiplier
        let x = sanitized(input.deltaX) * multiplier
        let y = sanitized(input.deltaY) * multiplier
        guard let maxAbsDeltaPerEvent = settings.maxAbsDeltaPerEvent, maxAbsDeltaPerEvent.isFinite, maxAbsDeltaPerEvent > 0 else {
            return TerminalWheelOutput(deltaX: x, deltaY: y)
        }
        return TerminalWheelOutput(
            deltaX: min(max(x, -maxAbsDeltaPerEvent), maxAbsDeltaPerEvent),
            deltaY: min(max(y, -maxAbsDeltaPerEvent), maxAbsDeltaPerEvent)
        )
    }

    /// Packed `ghostty_input_scroll_mods_t`: bit 0 is precision, bits 1-3 the
    /// momentum phase. Ghostty reads precise deltas as pixels and plain ones as
    /// wheel ticks (x cell height), so dropping the bit makes a trackpad scroll
    /// many times too far. `momentumPhase` is `NSEvent.Phase.rawValue`.
    public static func ghosttyScrollMods(precise: Bool, momentumPhase: UInt) -> Int32 {
        let momentum: Int32
        switch momentumPhase {
        case 0x1: momentum = 1 // began
        case 0x4: momentum = 2 // stationary
        case 0x2: momentum = 3 // changed
        case 0x8: momentum = 4 // ended
        case 0x10: momentum = 5 // cancelled
        case 0x20: momentum = 6 // mayBegin
        default: momentum = 0
        }
        return (precise ? 1 : 0) | (momentum << 1)
    }

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
