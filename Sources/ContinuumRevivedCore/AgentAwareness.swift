import ContinuumRevivedAgentUI
import Foundation

/// Secondary, privacy-safe milestones emitted by an agent. These never replace
/// the primary lifecycle state (working, needs attention, done, …).
public enum AgentSemanticSignalKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case gitPushSucceeded
    case gitMergeSucceeded
}

public enum AgentSignalKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case completed
    case failed
    case actionRequired
    case gitPushSucceeded
    case gitMergeSucceeded

    public var priority: Int {
        switch self {
        case .actionRequired: return 500
        case .failed: return 400
        case .completed: return 300
        case .gitMergeSucceeded: return 200
        case .gitPushSucceeded: return 100
        }
    }

    public var isPersistentAttention: Bool {
        switch self {
        case .actionRequired, .failed, .completed: return true
        case .gitPushSucceeded, .gitMergeSucceeded: return false
        }
    }

    public var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .actionRequired: return "Action required"
        case .gitPushSucceeded: return "Pushed"
        case .gitMergeSucceeded: return "Merged"
        }
    }

    public var symbolName: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .actionRequired: return "person.crop.circle.badge.exclamationmark"
        case .gitPushSucceeded: return "arrow.up.circle.fill"
        case .gitMergeSucceeded: return "arrow.triangle.merge"
        }
    }
}

public enum AgentSignalSource: String, Codable, Equatable, Sendable {
    case managedRuntime
    case observedTerminal
}

public struct AgentSignal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: AgentSignalKind
    public let agentID: AgentID?
    public let tileID: UUID?
    public let threadID: String?
    public let occurredAt: Date
    public let source: AgentSignalSource
    public let isPersistent: Bool

    public init(
        id: String,
        kind: AgentSignalKind,
        agentID: AgentID?,
        tileID: UUID?,
        threadID: String?,
        occurredAt: Date,
        source: AgentSignalSource,
        isPersistent: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.agentID = agentID
        self.tileID = tileID
        self.threadID = threadID
        self.occurredAt = occurredAt
        self.source = source
        self.isPersistent = isPersistent ?? kind.isPersistentAttention
    }
}

/// Pure transition/deduplication engine. The app owns retention and audio; this
/// reducer guarantees replays of a provider event do not ring twice.
public struct AgentSignalReducer: Sendable {
    public static let transientVisualDuration: TimeInterval = 3
    private var seenEventIDs: Set<String> = []
    private var lastObservedStatus: [UUID: AgentStatus] = [:]

    public init() {}

    public mutating func ingest(
        event: AgentRuntimeEvent,
        agentID: AgentID?,
        tileID: UUID?,
        source: AgentSignalSource = .managedRuntime,
        at now: Date = Date()
    ) -> AgentSignal? {
        let candidate: (AgentSignalKind, String, String?)?
        switch event {
        case .turnCompleted(let threadID, let turnID, let outcome, _):
            switch outcome {
            case .completed: candidate = (.completed, "turn:\(threadID):\(turnID):completed", threadID)
            case .failed: candidate = (.failed, "turn:\(threadID):\(turnID):failed", threadID)
            case .interrupted, .cancelled: candidate = nil
            }
        case .runtimeError(let threadID, let message):
            candidate = (.failed, "runtime:\(threadID ?? "unknown"):\(tileID?.uuidString ?? agentID?.rawValue.uuidString ?? "unknown"):\(Self.stableDigest(message))", threadID)
        case .requestOpened(let threadID, let requestID, _),
             .userInputRequested(let threadID, let requestID, _):
            candidate = (.actionRequired, "request:\(threadID):\(requestID)", threadID)
        case .semanticSignal(let threadID, let itemID, let semantic):
            let kind: AgentSignalKind = semantic == .gitPushSucceeded ? .gitPushSucceeded : .gitMergeSucceeded
            candidate = (kind, "semantic:\(threadID):\(itemID):\(semantic.rawValue)", threadID)
        default:
            candidate = nil
        }
        guard let candidate, seenEventIDs.insert(candidate.1).inserted else { return nil }
        return AgentSignal(
            id: candidate.1,
            kind: candidate.0,
            agentID: agentID,
            tileID: tileID,
            threadID: candidate.2,
            occurredAt: now,
            source: source)
    }

    public mutating func ingestObservedStatus(
        _ status: AgentStatus,
        tileID: UUID,
        at now: Date = Date()
    ) -> AgentSignal? {
        let previous = lastObservedStatus.updateValue(status, forKey: tileID)
        guard previous != status else { return nil }
        let kind: AgentSignalKind?
        switch status {
        case .needsAttention: kind = .actionRequired
        case .done: kind = .completed
        default: kind = nil
        }
        guard let kind else { return nil }
        let id = "observed:\(tileID.uuidString):\(kind.rawValue):\(now.timeIntervalSinceReferenceDate)"
        return AgentSignal(id: id, kind: kind, agentID: nil, tileID: tileID, threadID: nil,
                           occurredAt: now, source: .observedTerminal)
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public struct AgentSoundReference: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AgentSoundRule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var sound: AgentSoundReference

    public init(enabled: Bool = false, sound: AgentSoundReference) {
        self.enabled = enabled
        self.sound = sound
    }
}

public struct AgentSoundRules: Codable, Equatable, Sendable {
    public var rules: [AgentSignalKind: AgentSoundRule]

    public init(rules: [AgentSignalKind: AgentSoundRule] = Self.defaults) {
        self.rules = rules
    }

    public static let defaults: [AgentSignalKind: AgentSoundRule] = [
        .completed: AgentSoundRule(sound: AgentSoundReference(rawValue: "bloom")),
        .failed: AgentSoundRule(sound: AgentSoundReference(rawValue: "radar")),
        .actionRequired: AgentSoundRule(sound: AgentSoundReference(rawValue: "beacon")),
        .gitPushSucceeded: AgentSoundRule(sound: AgentSoundReference(rawValue: "orbit")),
        .gitMergeSucceeded: AgentSoundRule(sound: AgentSoundReference(rawValue: "prism")),
    ]
}

public enum AgentSoundOverride: Codable, Equatable, Sendable {
    case inherit
    case mute
    case sound(AgentSoundReference)
}

public struct AgentSoundOverrides: Codable, Equatable, Sendable {
    public var values: [AgentSignalKind: AgentSoundOverride]
    public init(values: [AgentSignalKind: AgentSoundOverride] = [:]) { self.values = values }
}

public struct AgentSoundManifestEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: AgentSoundReference
    public var name: String
    public var family: String
    public var filename: String
    public var duration: TimeInterval
    public var imported: Bool

    public init(id: AgentSoundReference, name: String, family: String, filename: String,
                duration: TimeInterval, imported: Bool = false) {
        self.id = id
        self.name = name
        self.family = family
        self.filename = filename
        self.duration = duration
        self.imported = imported
    }
}

public enum AgentSoundConfig {
    public static let masterEnabledKey = "continuum.agentSounds.enabled"
    public static let volumeKey = "continuum.agentSounds.volume"
    public static let defaultVolume = 0.72

    public static func enabledKey(for kind: AgentSignalKind) -> String {
        "continuum.agentSounds.\(kind.rawValue).enabled"
    }

    public static func soundKey(for kind: AgentSignalKind) -> String {
        "continuum.agentSounds.\(kind.rawValue).sound"
    }

    public static func resolvedRules(defaults: UserDefaults = .standard) -> AgentSoundRules {
        var values = AgentSoundRules.defaults
        for kind in AgentSignalKind.allCases {
            guard let suggested = values[kind] else { continue }
            let enabled = defaults.object(forKey: enabledKey(for: kind)) == nil
                ? false : defaults.bool(forKey: enabledKey(for: kind))
            let sound = AgentSoundReference(rawValue: defaults.string(forKey: soundKey(for: kind)) ?? suggested.sound.rawValue)
            values[kind] = AgentSoundRule(enabled: enabled, sound: sound)
        }
        return AgentSoundRules(rules: values)
    }

    public static func resolvedVolume(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: volumeKey) != nil else { return defaultVolume }
        return min(1, max(0, defaults.double(forKey: volumeKey)))
    }

    public static func resolvedSound(
        for kind: AgentSignalKind,
        tileOverrides: AgentSoundOverrides?,
        available: Set<AgentSoundReference>,
        defaults: UserDefaults = .standard
    ) -> AgentSoundReference? {
        guard defaults.bool(forKey: masterEnabledKey),
              let global = resolvedRules(defaults: defaults).rules[kind] else { return nil }
        switch tileOverrides?.values[kind] ?? .inherit {
        case .mute: return nil
        case .sound(let sound) where available.contains(sound): return sound
        case .sound: return global.enabled && available.contains(global.sound) ? global.sound : nil
        case .inherit: return global.enabled && available.contains(global.sound) ? global.sound : nil
        }
    }
}

public enum AgentExecutionModeSource: String, Codable, Equatable, Sendable {
    case inherited
    case sessionOverride
    case unavailable
}

public struct AgentExecutionModeSnapshot: Codable, Equatable, Sendable {
    public var identifier: String
    public var displayName: String
    public var source: AgentExecutionModeSource
    public var supportsPlan: Bool

    public init(identifier: String, displayName: String, source: AgentExecutionModeSource,
                supportsPlan: Bool) {
        self.identifier = identifier
        self.displayName = displayName
        self.source = source
        self.supportsPlan = supportsPlan
    }
}

/// Recognizes real Git executable invocations without retaining the command.
/// The provider adapter invokes this before dropping the sensitive payload and
/// emits only the returned semantic value after a successful tool completion.
public enum AgentGitOperationClassifier {
    public static func operations(in shell: String) -> Set<AgentSemanticSignalKind> {
        commandSegments(in: shell).reduce(into: Set<AgentSemanticSignalKind>()) { result, segment in
            guard let subcommand = gitSubcommand(in: segment) else { return }
            if subcommand == "push" { result.insert(.gitPushSucceeded) }
            if subcommand == "merge" { result.insert(.gitMergeSucceeded) }
        }
    }

    private static func gitSubcommand(in original: [String]) -> String? {
        var tokens = original
        while let first = tokens.first, first.contains("=") && !first.hasPrefix("-") {
            tokens.removeFirst()
        }
        if tokens.first == "command" { tokens.removeFirst() }
        if tokens.first == "env" {
            tokens.removeFirst()
            while let first = tokens.first, first.hasPrefix("-") || first.contains("=") { tokens.removeFirst() }
        }
        // `env -i PATH=/bin command git …` is a common fully isolated form.
        // Wrapper recognition is deliberately structural; quoted mentions in
        // arbitrary output never reach this classifier.
        if tokens.first == "command" { tokens.removeFirst() }
        guard let executable = tokens.first,
              URL(fileURLWithPath: executable).lastPathComponent == "git" else { return nil }
        tokens.removeFirst()
        let optionsWithValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" { index += 1; break }
            if !token.hasPrefix("-") { return token.lowercased() }
            let option = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            index += optionsWithValue.contains(option) && !token.contains("=") ? 2 : 1
        }
        return index < tokens.count ? tokens[index].lowercased() : nil
    }

    private static func commandSegments(in shell: String) -> [[String]] {
        var segments: [[String]] = [[]]
        var token = ""
        var quote: Character?
        var escaped = false

        func finishToken() {
            if !token.isEmpty { segments[segments.count - 1].append(token); token = "" }
        }
        func finishSegment() {
            finishToken()
            if !segments.last!.isEmpty { segments.append([]) }
        }

        for character in shell {
            if escaped { token.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { token.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; continue }
            if character.isWhitespace { finishToken(); continue }
            if character == ";" || character == "|" || character == "&" || character == "\n" {
                finishSegment(); continue
            }
            token.append(character)
        }
        finishToken()
        return segments.filter { !$0.isEmpty }
    }
}
