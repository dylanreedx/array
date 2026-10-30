import Foundation

extension Collaboration {
    /// Accounting for explicitly published agents on one execution host. Provider
    /// context occupancy and account billing limits are different measurements.
    public struct UsageSnapshot: Codable, Sendable, Equatable {
        public let host: SharedArea.ID<SharedArea.Host>
        public let sequence: UInt64
        public let inputTokens: UInt64
        public let outputTokens: UInt64
        public let todayInputTokens: UInt64
        public let todayOutputTokens: UInt64
        public let dayUTC: String
        public let observedSince: Date
        public let measuredAt: Date?
        public let coveredAgents: Int
        public let runningAgents: Int
        public let partial: Bool
        public init(host: SharedArea.ID<SharedArea.Host>, sequence: UInt64, inputTokens: UInt64,
                    outputTokens: UInt64, todayInputTokens: UInt64, todayOutputTokens: UInt64,
                    dayUTC: String, observedSince: Date, measuredAt: Date?, coveredAgents: Int,
                    runningAgents: Int, partial: Bool) {
            self.host = host; self.sequence = sequence; self.inputTokens = inputTokens; self.outputTokens = outputTokens
            self.todayInputTokens = todayInputTokens; self.todayOutputTokens = todayOutputTokens; self.dayUTC = dayUTC
            self.observedSince = observedSince; self.measuredAt = measuredAt; self.coveredAgents = coveredAgents
            self.runningAgents = runningAgents; self.partial = partial
        }
        public var valid: Bool {
            sequence > 0 && sequence <= UInt64(Int64.max) && inputTokens <= UInt64(Int64.max)
                && outputTokens <= UInt64(Int64.max) - inputTokens && todayInputTokens <= inputTokens
                && todayOutputTokens <= outputTokens && dayUTC.utf8.count == 10
                && dayUTC.enumerated().allSatisfy { index, value in
                    (index == 4 || index == 7) ? value == "-" : value.isASCII && value.isNumber
                } && ISO8601DateFormatter().date(from: dayUTC + "T00:00:00Z") != nil
                && observedSince.timeIntervalSince1970.isFinite && measuredAt?.timeIntervalSince1970.isFinite != false
                && (0...10_000).contains(coveredAgents) && (0...coveredAgents).contains(runningAgents)
        }
    }
    public struct UsageReport: Codable, Sendable {
        public let epoch: Int64
        public let snapshot: UsageSnapshot
        public init(epoch: Int64, snapshot: UsageSnapshot) { self.epoch = epoch; self.snapshot = snapshot }
    }
}
