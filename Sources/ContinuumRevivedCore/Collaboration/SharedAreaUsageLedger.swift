import CryptoKit
import Darwin
import Foundation
import ContinuumRevivedCollaborationProtocol

/// Per-host accounting for explicitly published agents. Counter identities stay
/// private. A second view/restart rereads the same atomic high-water marks.
public struct SharedAreaUsageLedger: Sendable {
    public struct Observation: Sendable {
        public let counter: String
        public let input: UInt64
        public let output: UInt64
        public let observedAt: Date
        /// A session total first seen midway through a day has no trustworthy
        /// day attribution. Retain its reported total, then count later deltas.
        public let initialBelongsToToday: Bool
        public init(counter: String, input: UInt64, output: UInt64, observedAt: Date, initialBelongsToToday: Bool) {
            self.counter = counter; self.input = input; self.output = output; self.observedAt = observedAt
            self.initialBelongsToToday = initialBelongsToToday
        }
    }
    public enum Failure: Error { case invalidObservation, corrupt, exhausted, changedScope }
    private struct Count: Codable { var input: UInt64 = 0; var output: UInt64 = 0 }
    private struct State: Codable {
        var schema = 1
        let host: SharedArea.ID<SharedArea.Host>
        let since: Date
        var sequence: UInt64 = 0
        var counters: [String: Count] = [:]
        var days: [String: Count] = [:]
        var total = Count()
        var measuredAt: Date?
        var partial = false
        var coveragePartial: Bool?
        var running = 0
        var covered = 0
        var day = ""
    }
    private let directory: URL
    private let file: URL
    private let host: SharedArea.ID<SharedArea.Host>
    private let writer: AtomicWriter

    public init(directory: URL, host: SharedArea.ID<SharedArea.Host>) throws {
        guard directory.isFileURL else { throw Failure.changedScope }
        self.directory = directory.appendingPathComponent("usage-\(host.rawValue.uuidString)", isDirectory: true)
        self.file = self.directory.appendingPathComponent("ledger.json"); self.host = host
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard try self.directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.changedScope }
        writer = AtomicWriter(backupsDirectory: self.directory.appendingPathComponent("backups"), retainedBackups: 3)
    }
    public static func dayUTC(_ date: Date) -> String {
        let calendar = Calendar(identifier: .iso8601)
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    public static func privateCounter(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func record(_ observation: Observation, at now: Date = Date()) throws -> Collaboration.UsageSnapshot {
        guard !observation.counter.isEmpty, observation.counter.utf8.count <= 512,
              observation.input <= UInt64(Int64.max), observation.output <= UInt64(Int64.max) - observation.input,
              observation.observedAt.timeIntervalSince1970.isFinite,
              observation.observedAt <= now.addingTimeInterval(300) else { throw Failure.invalidObservation }
        return try transaction(now: now) { state in
            let key = Self.privateCounter([observation.counter])
            guard state.counters.count < 250_000 || state.counters[key] != nil else { throw Failure.exhausted }
            let old = state.counters[key]
            let next = Count(input: max(old?.input ?? 0, observation.input), output: max(old?.output ?? 0, observation.output))
            let delta = Count(input: next.input - (old?.input ?? 0), output: next.output - (old?.output ?? 0))
            guard old == nil || delta.input != 0 || delta.output != 0 else { return false }
            state.counters[key] = next
            try Self.add(delta, into: &state.total)
            if old != nil || observation.initialBelongsToToday {
                let day = Self.dayUTC(observation.observedAt)
                var value = state.days[day] ?? Count()
                try Self.add(delta, into: &value); state.days[day] = value
            } else { state.partial = true }
            state.measuredAt = max(state.measuredAt ?? observation.observedAt, observation.observedAt)
            return true
        }
    }

    public func snapshot(coveredAgents: Int, runningAgents: Int, partial: Bool = false, at now: Date = Date()) throws -> Collaboration.UsageSnapshot {
        guard (0...10_000).contains(coveredAgents), (0...coveredAgents).contains(runningAgents) else { throw Failure.invalidObservation }
        return try transaction(now: now) { state in
            let changed = state.covered != coveredAgents || state.running != runningAgents || state.coveragePartial != partial
            state.covered = coveredAgents; state.running = runningAgents; state.coveragePartial = partial
            return changed
        }
    }
    private static func add(_ delta: Count, into value: inout Count) throws {
        let (input, a) = value.input.addingReportingOverflow(delta.input)
        let (output, b) = value.output.addingReportingOverflow(delta.output)
        guard !a, !b, input <= UInt64(Int64.max), output <= UInt64(Int64.max) - input else { throw Failure.exhausted }
        value = Count(input: input, output: output)
    }
    private func transaction(now: Date, edit: (inout State) throws -> Bool) throws -> Collaboration.UsageSnapshot {
        let descriptor = Darwin.open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.corrupt }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Failure.corrupt }
        defer { _ = flock(descriptor, LOCK_UN) }
        var state: State
        if FileManager.default.fileExists(atPath: file.path) {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.changedScope }
            do { state = try JSONCodec.makeDecoder().decode(State.self, from: Data(contentsOf: file)) }
            catch { throw Failure.corrupt }
            guard state.schema == 1, state.host == host, state.sequence > 0 else { throw Failure.changedScope }
        } else {
            let backups = directory.appendingPathComponent("backups")
            if FileManager.default.fileExists(atPath: backups.path),
               try !FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty { throw Failure.corrupt }
            state = State(host: host, since: now)
        }
        let changed = try edit(&state)
        let day = Self.dayUTC(now)
        if changed || state.sequence == 0 || state.day != day {
            guard state.sequence < UInt64(Int64.max) else { throw Failure.exhausted }
            state.sequence += 1; state.day = day
            try StoreFileWriter.perform(.write, at: file) { try writer.write(state, to: file) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let today = state.days[day] ?? Count()
        return .init(host: host, sequence: state.sequence, inputTokens: state.total.input, outputTokens: state.total.output,
            todayInputTokens: today.input, todayOutputTokens: today.output, dayUTC: day,
            observedSince: state.since, measuredAt: state.measuredAt, coveredAgents: state.covered,
            runningAgents: state.running, partial: state.partial || (state.coveragePartial ?? false))
    }
}
