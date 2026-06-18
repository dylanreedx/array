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

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
