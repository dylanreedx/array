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
        let icon: String
        let text: String
        let accessibilityLabel: String
        let detailText: String
        let isExternal: Bool
    }

    struct Activity: Equatable {
        let status: AgentStatus
        let text: String
        let elapsedText: String?
        let accessibilityLabel: String
        let detailText: String
        let showsThinkingIndicator: Bool
    }

    let location: Location
    let activity: Activity
    let context: AgentRadialContextMeterPresentation

    static func present(
        location snapshot: AgentLocationSnapshot,
        projectName: String? = nil,
        status: AgentStatus,
        startedAt: Date?,
        now: Date,
        contextWindow: AgentContextWindowSnapshot?
    ) -> AgentCompactStatusPresentation {
        let locationDetail = AgentLocationStatusPresenter.present(snapshot, projectName: projectName)
        return AgentCompactStatusPresentation(
            location: presentLocation(snapshot, detail: locationDetail, projectName: projectName),
            activity: presentActivity(status: status, startedAt: startedAt, now: now),
            context: AgentRadialContextMeterPresenter.present(contextWindow))
    }

    private static func presentLocation(
        _ snapshot: AgentLocationSnapshot,
        detail: AgentLocationStatusPresentation,
        projectName: String?
    ) -> Location {
        let rawText: String
        switch snapshot.workingLocation.relationToHome {
        case .root:
            rawText = "."
        case .inside:
            rawText = snapshot.workingLocation.relativePath ?? snapshot.workingLocation.directory.lastPathComponent
        case .outside:
            rawText = snapshot.workingLocation.directory.lastPathComponent.isEmpty
                ? snapshot.workingLocation.directory.path
                : snapshot.workingLocation.directory.lastPathComponent
        }
        let text = boundedSingleLine(rawText, fallback: ".", maximumLength: 180)
        let relation: String
        switch snapshot.workingLocation.relationToHome {
        case .root: relation = "project root"
        case .inside: relation = "inside project"
        case .outside: relation = "outside project"
        }
        let project = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectPhrase = project?.isEmpty == false ? " in \(project!)" : ""
        return Location(
            icon: snapshot.workingLocation.relationToHome == .outside ? "↗" : "⌂",
            text: text,
            accessibilityLabel: "Location\(projectPhrase): \(text), \(relation).",
            detailText: detail.detailText,
            isExternal: snapshot.workingLocation.relationToHome == .outside)
    }

    private static func presentActivity(
        status: AgentStatus,
        startedAt: Date?,
        now: Date
    ) -> Activity {
        let display = StatusChipPresenter.display(for: status)
        let elapsedSeconds = startedAt.map { max(0, now.timeIntervalSince($0)) }
        let elapsed = elapsedSeconds.map(AgentElapsedFormatter.elapsedLabel)
        let elapsedPhrase = elapsedSeconds.map { ", \(Int($0.rounded(.down))) seconds elapsed" } ?? ""
        let text = status == .needsAttention ? "Attention" : display.label
        return Activity(
            status: status,
            text: text,
            elapsedText: elapsed,
            accessibilityLabel: "Activity: \(display.label)\(elapsedPhrase).",
            detailText: elapsed.map { "Lifecycle: \(display.label) — elapsed \($0)" }
                ?? "Lifecycle: \(display.label)",
            showsThinkingIndicator: status == .working)
    }

    private static func boundedSingleLine(
        _ candidate: String?,
        fallback: String,
        maximumLength: Int
    ) -> String {
        let source = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = source?.isEmpty == false ? source! : fallback
        let flattened = chosen.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        let normalized = String(flattened).split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.count > maximumLength else { return normalized }
        return String(normalized.prefix(max(0, maximumLength - 1))) + "…"
    }
}

enum AgentRadialContextMeterState: String, Equatable, CaseIterable {
    case known
    case warning
    case critical
    case unknown
    case stale
}

struct AgentRadialContextMeterPresentation: Equatable {
    let state: AgentRadialContextMeterState
    /// 0...1 only when authoritative occupancy exists. Unknown and
    /// non-authoritative telemetry leave this nil; callers must not coerce nil to 0.
    let fraction: Double?
    let label: String
    let accessibilityLabel: String
    let detailText: String
    let warningMarker: String?
}

enum AgentRadialContextMeterPresenter {
    static let warningThreshold = 0.75
    static let criticalThreshold = 0.90

    static func present(_ snapshot: AgentContextWindowSnapshot?) -> AgentRadialContextMeterPresentation {
        guard let snapshot else {
            return unknownPresentation(reason: "No context-window telemetry has been observed.")
        }

        let freshness = freshnessLabel(snapshot.freshness)
        let source = sourceLabel(snapshot.source)
        let occupancy = snapshot.occupancyFraction.map { min(1, max(0, $0)) }
        let percent = occupancy.map { Int(($0 * 100).rounded()) }
        let state: AgentRadialContextMeterState
        let marker: String?
        if case .stale = snapshot.freshness {
            state = .stale
            marker = "⏱"
        } else if let occupancy {
            if occupancy >= criticalThreshold {
                state = .critical
                marker = "!"
            } else if occupancy >= warningThreshold {
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
        switch (state, percent) {
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
            fraction: occupancy,
            label: visualLabel,
            accessibilityLabel: accessibilityLabel(state: state, percent: percent, freshness: freshness),
            detailText: detailText(snapshot, source: source, freshness: freshness, percent: percent),
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
        percent: Int?
    ) -> String {
        var lines: [String] = []
        if snapshot.source.isAuthoritativeForContextOccupancy,
           let used = snapshot.usedTokens,
           let max = snapshot.maxTokens,
           max > 0 {
            let percentSuffix = percent.map { " (\($0)%)" } ?? ""
            lines.append("Authoritative context: \(used) / \(max) tokens\(percentSuffix)")
        } else {
            lines.append("Authoritative context: unknown")
            lines.append("Occupancy note: source is not authoritative for used/max context window.")
        }
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
