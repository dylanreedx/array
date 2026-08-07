import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Pure, provider-neutral presentation for the compact bottom status row.
///
/// The model is deliberately non-Codable: it is a local UI projection that may
/// contain host-local tooltip text. Sync/storage payloads continue to carry only
/// their existing snapshots.
struct AgentCompactStatusPresentation: Equatable {
    struct Location: Equatable {
        let symbolName: String
        let text: String
        let accessibilityLabel: String
        let detailText: String
        let isExternal: Bool
    }

    struct Activity: Equatable {
        let phase: AgentCompactActivityPhase
        let symbolName: String
        let text: String
        let elapsedText: String?
        let accessibilityLabel: String
        let detailText: String
        let showsThinkingIndicator: Bool
    }

    let location: Location
    let activity: Activity
    let context: AgentRadialContextMeterPresentation

    /// Adapter seam for the current coarse facts. New provider/runtime wiring
    /// should construct `AgentCompactActivityInput` directly; this adapter only
    /// preserves today's `AgentStatus` + optional location evidence without
    /// pretending `AgentLocationSnapshot.what` is the full lifecycle truth.
    static func present(
        location snapshot: AgentLocationSnapshot,
        projectName: String? = nil,
        status: AgentStatus,
        startedAt: Date?,
        now: Date,
        contextWindow: AgentContextWindowSnapshot?,
        contextPolicy: AgentRadialContextMeterPolicy = .productionDefault
    ) -> AgentCompactStatusPresentation {
        present(
            location: snapshot,
            projectName: projectName,
            activity: activityInput(status: status, location: snapshot, phaseStartedAt: startedAt),
            now: now,
            contextWindow: contextWindow,
            contextPolicy: contextPolicy)
    }

    static func present(
        location snapshot: AgentLocationSnapshot,
        projectName: String? = nil,
        activity: AgentCompactActivityInput,
        now: Date,
        contextWindow: AgentContextWindowSnapshot?,
        contextPolicy: AgentRadialContextMeterPolicy = .productionDefault
    ) -> AgentCompactStatusPresentation {
        let locationDetail = AgentLocationStatusPresenter.present(snapshot, projectName: projectName)
        return AgentCompactStatusPresentation(
            location: presentLocation(snapshot, detail: locationDetail, projectName: projectName),
            activity: presentActivity(activity, now: now),
            context: AgentRadialContextMeterPresenter.present(contextWindow, policy: contextPolicy))
    }

    static func activityInput(
        status: AgentStatus,
        location snapshot: AgentLocationSnapshot,
        phaseStartedAt: Date?
    ) -> AgentCompactActivityInput {
        switch status {
        case .configuring:
            return AgentCompactActivityInput(phase: .starting, phaseStartedAt: phaseStartedAt)
        case .working:
            if let observed = snapshot.what {
                return AgentCompactActivityInput(
                    phase: AgentCompactActivityPhase(operation: observed.operation) ?? .thinking,
                    phaseStartedAt: observed.startedAt,
                    safeToolLabel: safeToolLabel(for: observed))
            }
            return AgentCompactActivityInput(
                phase: .thinking,
                phaseStartedAt: phaseStartedAt,
                evidenceNote: "Coarse working status; no current provider-neutral activity fact.")
        case .needsAttention:
            return AgentCompactActivityInput(phase: .waiting, phaseStartedAt: phaseStartedAt)
        case .idle, .done:
            return AgentCompactActivityInput(phase: .ready, phaseStartedAt: nil)
        case .stale:
            return AgentCompactActivityInput(
                phase: .ready,
                phaseStartedAt: nil,
                evidenceNote: "Coarse stale status; latest phase is not authoritative.")
        }
    }

    private static func presentLocation(
        _ snapshot: AgentLocationSnapshot,
        detail: AgentLocationStatusPresentation,
        projectName: String?
    ) -> Location {
        let homeName = boundedSingleLine(
            projectName,
            fallback: snapshot.home.projectRoot?.lastPathComponent ?? snapshot.home.checkoutRoot.lastPathComponent,
            maximumLength: 80)
        let rawText: String
        switch snapshot.workingLocation.relationToHome {
        case .root:
            rawText = homeName
        case .inside:
            rawText = snapshot.workingLocation.relativePath ?? snapshot.workingLocation.directory.lastPathComponent
        case .outside:
            rawText = snapshot.workingLocation.directory.lastPathComponent.isEmpty
                ? snapshot.workingLocation.directory.path
                : snapshot.workingLocation.directory.lastPathComponent
        }
        let text = boundedSingleLine(rawText, fallback: homeName, maximumLength: 180)
        let relation: String
        let symbolName: String
        switch snapshot.workingLocation.relationToHome {
        case .root:
            relation = "project root"
            symbolName = "house"
        case .inside:
            relation = "inside Home"
            symbolName = "folder"
        case .outside:
            relation = "outside Home"
            symbolName = "arrow.up.forward.square"
        }
        return Location(
            symbolName: symbolName,
            text: text,
            accessibilityLabel: "Home and Where: \(text), \(relation).",
            detailText: detail.detailText,
            isExternal: snapshot.workingLocation.relationToHome == .outside)
    }

    private static func presentActivity(
        _ input: AgentCompactActivityInput,
        now: Date
    ) -> Activity {
        let phase = input.phase
        let label = input.visibleLabel
        let elapsedSeconds = input.phaseStartedAt.map { max(0, now.timeIntervalSince($0)) }
        let elapsed = phase.displaysElapsed ? elapsedSeconds.map(AgentElapsedFormatter.elapsedLabel) : nil
        let elapsedPhrase = elapsedSeconds.map { ", phase elapsed \(Int($0.rounded(.down))) seconds" } ?? ""
        var details = ["Activity phase: \(phase.spokenLabel)\(elapsedPhrase)."]
        if let safeToolLabel = input.safeToolLabel, !safeToolLabel.isEmpty {
            details.append("Safe tool label: \(safeToolLabel)")
        }
        if let evidenceNote = input.evidenceNote, !evidenceNote.isEmpty {
            details.append("Evidence note: \(evidenceNote)")
        }
        return Activity(
            phase: phase,
            symbolName: phase.symbolName,
            text: label,
            elapsedText: elapsed,
            accessibilityLabel: "Activity: \(phase.spokenLabel)\(elapsedPhrase).",
            detailText: details.joined(separator: "\n"),
            showsThinkingIndicator: phase.animatesThinkingIndicator)
    }

    private static func safeToolLabel(for observed: AgentObservedActivity) -> String? {
        guard let targetPath = observed.targetPath else { return nil }
        return boundedSingleLine(targetPath.lastPathComponent, fallback: nil, maximumLength: 48)
    }

    private static func boundedSingleLine(
        _ candidate: String?,
        fallback: String?,
        maximumLength: Int
    ) -> String {
        let source = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSource = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = source?.isEmpty == false ? source! : (fallbackSource?.isEmpty == false ? fallbackSource! : "—")
        let flattened = chosen.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        let normalized = String(flattened).split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.count > maximumLength else { return normalized }
        return String(normalized.prefix(max(0, maximumLength - 1))) + "…"
    }
}

struct AgentCompactActivityInput: Equatable {
    let phase: AgentCompactActivityPhase
    let phaseStartedAt: Date?
    let safeToolLabel: String?
    let evidenceNote: String?

    init(
        phase: AgentCompactActivityPhase,
        phaseStartedAt: Date?,
        safeToolLabel: String? = nil,
        evidenceNote: String? = nil
    ) {
        self.phase = phase
        self.phaseStartedAt = phaseStartedAt
        self.safeToolLabel = Self.sanitizedToolLabel(safeToolLabel)
        self.evidenceNote = evidenceNote
    }

    var visibleLabel: String {
        guard let safeToolLabel, !safeToolLabel.isEmpty else { return phase.visibleLabel }
        switch phase {
        case .reading: return "Reading \(safeToolLabel)"
        case .searching: return "Searching \(safeToolLabel)"
        case .editing: return "Editing \(safeToolLabel)"
        case .running: return "Running \(safeToolLabel)"
        default: return phase.visibleLabel
        }
    }

    private static func sanitizedToolLabel(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let scalars = candidate.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet(charactersIn: " ._+-@#").contains(scalar) {
                return Character(String(scalar))
            }
            return " "
        }
        let normalized = String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return normalized.count <= 48 ? normalized : String(normalized.prefix(47)) + "…"
    }
}

enum AgentCompactActivityPhase: String, Equatable, CaseIterable {
    case starting
    case thinking
    case responding
    case reading
    case searching
    case editing
    case running
    case waiting
    case ready
    case failed
    case interrupted

    init?(operation: AgentObservedActivity.Operation) {
        switch operation {
        case .reading, .inspecting: self = .reading
        case .editing: self = .editing
        case .running: self = .running
        case .searching: self = .searching
        case .thinking: self = .thinking
        case .waiting: self = .waiting
        case .completed: self = .ready
        case .interrupted: self = .interrupted
        case .failed: self = .failed
        case .messaging: self = .responding
        }
    }

    var visibleLabel: String {
        switch self {
        case .starting: return "Starting"
        case .thinking: return "Thinking"
        case .responding: return "Responding"
        case .reading: return "Reading"
        case .searching: return "Searching"
        case .editing: return "Editing"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }

    var spokenLabel: String { visibleLabel.lowercased() }

    var symbolName: String {
        switch self {
        case .starting: return "play.circle"
        case .thinking: return "ellipsis.bubble"
        case .responding: return "text.bubble"
        case .reading: return "doc.text"
        case .searching: return "magnifyingglass"
        case .editing: return "pencil"
        case .running: return "terminal"
        case .waiting: return "hourglass"
        case .ready: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .interrupted: return "pause.circle"
        }
    }

    var animatesThinkingIndicator: Bool {
        switch self {
        case .starting, .thinking, .responding, .reading, .searching, .editing, .running:
            return true
        case .waiting, .ready, .failed, .interrupted:
            return false
        }
    }

    var displaysElapsed: Bool {
        switch self {
        case .ready:
            return false
        case .starting, .thinking, .responding, .reading, .searching, .editing, .running, .waiting, .failed, .interrupted:
            return true
        }
    }
}

enum AgentRadialContextMeterState: String, Equatable, CaseIterable {
    case known
    case warning
    case critical
    case unknown
    case stale
}

struct AgentRadialContextMeterPolicy: Equatable {
    let warningThreshold: Double?
    let criticalThreshold: Double?

    /// Production default until the owner/coordinator approves a warning policy:
    /// show authoritative occupancy, but do not promote it to warning/critical.
    static let productionDefault = AgentRadialContextMeterPolicy(warningThreshold: nil, criticalThreshold: nil)

    static func thresholds(warning: Double, critical: Double) -> AgentRadialContextMeterPolicy {
        AgentRadialContextMeterPolicy(warningThreshold: warning, criticalThreshold: critical)
    }
}

struct AgentRadialContextMeterPresentation: Equatable {
    let state: AgentRadialContextMeterState
    /// Authoritative raw fraction when valid. It may exceed 1.0; drawing clamps
    /// the arc only, while labels/tooltips preserve the raw used/max arithmetic.
    let fraction: Double?
    let label: String
    let accessibilityLabel: String
    let detailText: String
    let warningMarker: String?
}

enum AgentRadialContextMeterPresenter {
    static func present(
        _ snapshot: AgentContextWindowSnapshot?,
        policy: AgentRadialContextMeterPolicy = .productionDefault
    ) -> AgentRadialContextMeterPresentation {
        guard let snapshot else {
            return unknownPresentation(reason: "No context-window telemetry has been observed.")
        }

        let freshness = freshnessLabel(snapshot.freshness)
        let source = sourceLabel(snapshot.source)
        let arithmetic = authoritativeArithmetic(snapshot)
        let rawPercent = arithmetic.map { Int(($0.fraction * 100).rounded()) }
        let renderFraction = arithmetic?.fraction
        let state: AgentRadialContextMeterState
        let marker: String?
        if case .stale = snapshot.freshness {
            state = .stale
            marker = "⏱"
        } else if let fraction = arithmetic?.fraction {
            if let critical = policy.validCriticalThreshold, fraction >= critical {
                state = .critical
                marker = "!"
            } else if let warning = policy.validWarningThreshold, fraction >= warning {
                state = .warning
                marker = "⚠︎"
            } else {
                state = .known
                marker = nil
            }
        } else {
            state = .unknown
            marker = nil
        }

        let visualLabel: String
        switch (state, rawPercent) {
        case (.unknown, _):
            visualLabel = "unknown"
        case (.stale, let value?):
            visualLabel = "stale \(value)%"
        case (.stale, nil):
            visualLabel = "stale"
        case (.warning, let value?):
            visualLabel = "⚠︎ \(value)%"
        case (.critical, let value?):
            visualLabel = "! \(value)%"
        case (_, let value?):
            visualLabel = "\(value)%"
        case (_, nil):
            visualLabel = "unknown"
        }

        return AgentRadialContextMeterPresentation(
            state: state,
            fraction: renderFraction,
            label: visualLabel,
            accessibilityLabel: accessibilityLabel(state: state, percent: rawPercent, freshness: freshness),
            detailText: detailText(snapshot, source: source, freshness: freshness, arithmetic: arithmetic, policy: policy),
            warningMarker: marker)
    }

    private static func unknownPresentation(reason: String) -> AgentRadialContextMeterPresentation {
        AgentRadialContextMeterPresentation(
            state: .unknown,
            fraction: nil,
            label: "unknown",
            accessibilityLabel: "Context window usage unknown.",
            detailText: "Authoritative context: unknown\nFreshness: unknown\n\(reason)",
            warningMarker: nil)
    }

    private static func accessibilityLabel(
        state: AgentRadialContextMeterState,
        percent: Int?,
        freshness: String
    ) -> String {
        switch (state, percent) {
        case (.unknown, _): return "Context window usage unknown. Freshness: \(freshness)."
        case (.stale, let value?): return "Context window usage stale, \(value) percent."
        case (.stale, nil): return "Context window usage stale and unknown."
        case (.warning, let value?): return "Context window warning, \(value) percent used."
        case (.critical, let value?): return "Context window critical, \(value) percent used."
        case (_, let value?): return "Context window \(value) percent used. Freshness: \(freshness)."
        case (_, nil): return "Context window usage unknown. Freshness: \(freshness)."
        }
    }

    private static func detailText(
        _ snapshot: AgentContextWindowSnapshot,
        source: String,
        freshness: String,
        arithmetic: (used: Int, max: Int, fraction: Double)?,
        policy: AgentRadialContextMeterPolicy
    ) -> String {
        var lines: [String] = []
        if let arithmetic {
            let percent = Int((arithmetic.fraction * 100).rounded())
            lines.append("Authoritative context: \(arithmetic.used) / \(arithmetic.max) tokens (\(percent)%)")
        } else {
            lines.append("Authoritative context: unknown")
            if !snapshot.source.isAuthoritativeForContextOccupancy {
                lines.append("Occupancy note: source is not authoritative for used/max context window.")
            } else if let used = snapshot.usedTokens, used < 0 {
                lines.append("Occupancy note: invalid negative used token count was rejected.")
            } else if let max = snapshot.maxTokens, max <= 0 {
                lines.append("Occupancy note: invalid max token count was rejected.")
            } else {
                lines.append("Occupancy note: authoritative source did not provide valid used/max context window.")
            }
        }
        lines.append("Threshold policy: \(policy.detailLabel)")
        lines.append("Source: \(source)")
        lines.append("Freshness: \(freshness)")
        lines.append("Observed: \(ISO8601DateFormatter().string(from: snapshot.observedAt))")

        let usageFields = [
            snapshot.inputTokens.map { "input \($0)" },
            snapshot.outputTokens.map { "output \($0)" },
            snapshot.cacheReadTokens.map { "cache read \($0)" },
            snapshot.cacheWriteTokens.map { "cache write \($0)" },
            snapshot.totalProcessedTokens.map { "processed \($0)" },
            snapshot.totalCostUsd.map { String(format: "cost $%.4f", $0) },
        ].compactMap { $0 }
        if usageFields.isEmpty {
            lines.append("Per-message/cache/cost fields: unavailable")
        } else {
            lines.append("Per-message/cache/cost fields: " + usageFields.joined(separator: ", "))
        }
        if let automaticCompaction = snapshot.automaticCompaction {
            lines.append("Automatic compaction: \(automaticCompaction ? "enabled" : "disabled")")
        }
        return lines.joined(separator: "\n")
    }

    private static func authoritativeArithmetic(_ snapshot: AgentContextWindowSnapshot) -> (used: Int, max: Int, fraction: Double)? {
        guard snapshot.source.isAuthoritativeForContextOccupancy,
              let used = snapshot.usedTokens,
              let max = snapshot.maxTokens,
              used >= 0,
              max > 0
        else { return nil }
        return (used, max, Double(used) / Double(max))
    }

    private static func sourceLabel(_ source: AgentContextWindowTelemetrySource) -> String {
        switch source {
        case .providerSessionStats: return "provider session stats"
        case .piMessageUsage: return "per-message usage"
        case .unknown(let raw): return "unknown (\(raw))"
        }
    }

    private static func freshnessLabel(_ freshness: AgentContextWindowFreshness) -> String {
        switch freshness {
        case .live: return "live"
        case .stale: return "stale"
        case .unknown(let raw): return "unknown (\(raw))"
        }
    }
}

private extension AgentRadialContextMeterPolicy {
    var validWarningThreshold: Double? {
        guard let warningThreshold, warningThreshold >= 0 else { return nil }
        if let criticalThreshold, criticalThreshold >= 0, warningThreshold > criticalThreshold { return nil }
        return warningThreshold
    }

    var validCriticalThreshold: Double? {
        guard let criticalThreshold, criticalThreshold >= 0 else { return nil }
        return criticalThreshold
    }

    var detailLabel: String {
        switch (validWarningThreshold, validCriticalThreshold) {
        case (nil, nil): return "warning/critical disabled"
        case (let warning?, let critical?): return "warning \(Int((warning * 100).rounded()))%, critical \(Int((critical * 100).rounded()))%"
        case (let warning?, nil): return "warning \(Int((warning * 100).rounded()))%, critical disabled"
        case (nil, let critical?): return "warning disabled, critical \(Int((critical * 100).rounded()))%"
        }
    }
}
