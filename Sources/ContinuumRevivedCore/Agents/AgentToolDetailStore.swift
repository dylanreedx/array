import ContinuumRevivedAgentContent
import CryptoKit
import Foundation

/// Host-local limits for sanitized tool detail. Values are byte/line caps, not
/// layout hints; the store applies them before retaining any provider text.
public struct AgentToolDetailLimits: Equatable, Sendable {
    public var maxToolNameBytes: Int
    public var maxArgumentKeyBytes: Int
    public var maxFieldValueBytes: Int
    public var maxFieldValueLines: Int
    public var maxOutputBytes: Int
    public var maxOutputLines: Int
    public var maxArguments: Int
    public var maxAffectedFiles: Int
    /// A shell command's own bound. It is the row's headline and its expanded
    /// body, so the 8-line field cap would cut an ordinary heredoc.
    public var maxCommandBytes: Int
    public var maxCommandLines: Int

    public init(
        maxToolNameBytes: Int = 160,
        maxArgumentKeyBytes: Int = 256,
        maxFieldValueBytes: Int = 2_048,
        maxFieldValueLines: Int = 8,
        maxOutputBytes: Int = 16_384,
        maxOutputLines: Int = 200,
        maxArguments: Int = 100,
        maxAffectedFiles: Int = 50,
        maxCommandBytes: Int = 4_096,
        maxCommandLines: Int = 40
    ) {
        self.maxToolNameBytes = max(16, maxToolNameBytes)
        self.maxArgumentKeyBytes = max(16, maxArgumentKeyBytes)
        self.maxFieldValueBytes = max(16, maxFieldValueBytes)
        self.maxFieldValueLines = max(1, maxFieldValueLines)
        self.maxOutputBytes = max(16, maxOutputBytes)
        self.maxOutputLines = max(1, maxOutputLines)
        self.maxArguments = max(0, maxArguments)
        self.maxAffectedFiles = max(0, maxAffectedFiles)
        self.maxCommandBytes = max(16, maxCommandBytes)
        self.maxCommandLines = max(1, maxCommandLines)
    }
}

/// Deliberately non-Codable provider item key for host-local tool details.
public struct AgentToolDetailID: Hashable, Equatable, Sendable, ExpressibleByStringLiteral {
    public static let maxRawValueBytes = 256

    public let rawValue: String

    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        precondition(Self.isValid(value), "AgentToolDetailID string literals must be non-empty, bounded, and control-free")
        self.rawValue = value
    }

    public static func isValid(_ rawValue: String) -> Bool {
        !rawValue.isEmpty &&
        rawValue.utf8.count <= maxRawValueBytes &&
        !rawValue.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        SecretRedactor.redact(rawValue) == rawValue
    }
}

/// Host-local scope for a provider tool item. This is deliberately not Codable:
/// it prevents a provider item/tool-call ID from becoming a document, runtime,
/// or sync identity while still making retention collision-safe across agents,
/// threads, and turns.
public struct AgentToolDetailScope: Hashable, Equatable, Sendable {
    public let agentID: String
    public let threadID: String
    public let turnID: String
    public let provider: String

    public init?(agentID: String, threadID: String, turnID: String, provider: String) {
        let components = [agentID, threadID, turnID, provider]
        guard components.allSatisfy(Self.isValidComponent) else { return nil }
        self.agentID = agentID
        self.threadID = threadID
        self.turnID = turnID
        self.provider = provider
    }

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= AgentToolDetailID.maxRawValueBytes &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
            SecretRedactor.redact(value) == value
    }
}

/// Complete host-local lookup identity. Never concatenate these components into
/// a string: tuple fields must remain independently collision-safe.
public struct AgentToolDetailKey: Hashable, Equatable, Sendable {
    public let scope: AgentToolDetailScope
    public let providerItemID: AgentToolDetailID

    public init(scope: AgentToolDetailScope, providerItemID: AgentToolDetailID) {
        self.scope = scope
        self.providerItemID = providerItemID
    }

    var sortDescription: String {
        "\(scope.agentID)\u{001f}\(scope.threadID)\u{001f}\(scope.turnID)\u{001f}\(scope.provider)\u{001f}\(providerItemID.rawValue)"
    }
}

/// Raw adapter-owned key/value text handed to the host-local detail store. The
/// store sanitizes and bounds values before retaining them.
public struct AgentToolDetailField: Equatable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct AgentToolDetailStart: Equatable, Sendable {
    public var identity: AgentToolDetailKey
    public var providerItemID: AgentToolDetailID { identity.providerItemID }
    public var toolName: String
    public var arguments: [AgentToolDetailField]
    public var affectedFiles: [URL]
    public var fileChanges: [AgentToolDetailObservation.FileChange]
    public var parentItemID: String?
    /// Provider-authored timestamp. Retention/expiry uses host observation time,
    /// not this value.
    public var startedAt: Date?
    public var explicitSecrets: [String]

    public init(
        identity: AgentToolDetailKey,
        toolName: String,
        arguments: [AgentToolDetailField] = [],
        affectedFiles: [URL] = [], fileChanges: [AgentToolDetailObservation.FileChange] = [], parentItemID: String? = nil,
        startedAt: Date? = nil,
        explicitSecrets: [String] = []
    ) {
        self.identity = identity
        self.toolName = toolName
        self.arguments = arguments
        self.affectedFiles = affectedFiles
        self.fileChanges = fileChanges
        self.parentItemID = AgentToolDetailDisplaySanitizer.parentItemID(parentItemID)
        self.startedAt = startedAt
        self.explicitSecrets = explicitSecrets
    }

}

public struct AgentToolDetailEnd: Equatable, Sendable {
    public var identity: AgentToolDetailKey
    public var providerItemID: AgentToolDetailID { identity.providerItemID }
    public var output: String?
    public var status: AgentItemStatus
    public var exitCode: Int?
    public var affectedFiles: [URL]
    /// Provider-authored timestamp. Retention/expiry uses host observation time,
    /// not this value.
    public var endedAt: Date?
    public var explicitSecrets: [String]
    /// A shell's outcome beyond its exit code (timed out / interrupted /
    /// backgrounded), and the provider's own measured duration.
    public var shellOutcome: AgentShellStatus?
    public var reportedDuration: TimeInterval?

    public init(
        identity: AgentToolDetailKey,
        output: String? = nil,
        status: AgentItemStatus,
        exitCode: Int? = nil,
        affectedFiles: [URL] = [],
        endedAt: Date? = nil,
        explicitSecrets: [String] = [],
        shellOutcome: AgentShellStatus? = nil,
        reportedDuration: TimeInterval? = nil
    ) {
        self.identity = identity
        self.output = output
        self.status = status
        self.exitCode = exitCode
        self.affectedFiles = affectedFiles
        self.endedAt = endedAt
        self.explicitSecrets = explicitSecrets
        self.shellOutcome = shellOutcome
        self.reportedDuration = reportedDuration
    }

}

public struct AgentToolDetailBoundedText: Equatable, Sendable {
    public var text: String
    public var truncatedByBytes: Bool
    public var truncatedByLines: Bool
    public var redacted: Bool

    public init(text: String, truncatedByBytes: Bool = false, truncatedByLines: Bool = false, redacted: Bool = false) {
        self.text = text
        self.truncatedByBytes = truncatedByBytes
        self.truncatedByLines = truncatedByLines
        self.redacted = redacted
    }
}

public struct AgentToolDetailArgument: Equatable, Sendable {
    public var key: String
    public var value: AgentToolDetailBoundedText
    public var sensitiveKeyFiltered: Bool

    public init(key: String, value: AgentToolDetailBoundedText, sensitiveKeyFiltered: Bool = false) {
        self.key = key
        self.value = value
        self.sensitiveKeyFiltered = sensitiveKeyFiltered
    }
}

/// Sanitized, bounded, host-local tool detail. It intentionally has no Codable
/// conformance and must not be embedded in sync or normalized runtime events.
public struct AgentToolDetailRecord: Equatable, Sendable {
    public var identity: AgentToolDetailKey
    public var providerItemID: AgentToolDetailID { identity.providerItemID }
    public var toolName: String
    public var arguments: [AgentToolDetailArgument]
    public var output: AgentToolDetailBoundedText?
    public var status: AgentItemStatus
    public var exitCode: Int?
    public var startedAt: Date?
    public var endedAt: Date?
    /// Host observation time for local retention and merge ordering. Provider
    /// timestamps above are never used for expiry.
    public var updatedAt: Date
    public var affectedFiles: [URL]
    public var fileChanges: [AgentToolDetailObservation.FileChange]
    public var parentItemID: String?
    public var shellOutcome: AgentShellStatus?
    public var reportedDuration: TimeInterval?

    var sensitiveStartFingerprints: Set<String>
    var latestEndExplicitFingerprints: Set<String>
    var latestStartTimestamp: Date?
    var latestEndTimestamp: Date?
    // Equal/missing provider timestamps use these canonical payload keys. The
    // lexicographically larger key wins; identical keys are idempotent.
    var latestStartTieKey: String?
    var latestEndTieKey: String?
    // Parent observations form a set-valued lattice. One explicit value is
    // useful; conflicting explicit values are ambiguous and therefore expose
    // no parent rather than fabricating a winner from arrival order.
    package var observedParentItemIDs: Set<String>
    package var observedParentConflict: Bool

    public init(
        identity: AgentToolDetailKey,
        toolName: String = "Tool",
        arguments: [AgentToolDetailArgument] = [],
        output: AgentToolDetailBoundedText? = nil,
        status: AgentItemStatus = .inProgress,
        exitCode: Int? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        updatedAt: Date,
        affectedFiles: [URL] = [], fileChanges: [AgentToolDetailObservation.FileChange] = [], parentItemID: String? = nil,
        sensitiveStartFingerprints: Set<String> = [],
        latestEndExplicitFingerprints: Set<String> = [],
        latestStartTimestamp: Date? = nil,
        latestEndTimestamp: Date? = nil,
        latestStartTieKey: String? = nil,
        latestEndTieKey: String? = nil,
        observedParentItemIDs: Set<String> = [],
        observedParentConflict: Bool = false
    ) {
        self.identity = identity
        self.toolName = toolName
        self.arguments = arguments
        self.output = output
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt
        self.affectedFiles = affectedFiles
        self.fileChanges = fileChanges
        self.parentItemID = AgentToolDetailDisplaySanitizer.parentItemID(parentItemID)
        self.sensitiveStartFingerprints = sensitiveStartFingerprints
        self.latestEndExplicitFingerprints = latestEndExplicitFingerprints
        self.latestStartTimestamp = latestStartTimestamp
        self.latestEndTimestamp = latestEndTimestamp
        self.latestStartTieKey = latestStartTieKey
        self.latestEndTieKey = latestEndTieKey
        self.observedParentItemIDs = observedParentItemIDs.union(self.parentItemID.map { [$0] } ?? [])
        self.observedParentConflict = observedParentConflict || self.observedParentItemIDs.count > 1
        if self.observedParentConflict {
            self.parentItemID = nil
            self.observedParentItemIDs = []
        }
    }

    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// The provider's own measurement when it made one, else the span between
    /// the two observed instants.
    public var measuredDuration: TimeInterval? { reportedDuration ?? duration }
}

public struct AgentToolDetailSanitizer: Sendable {
    public static let redactionUnavailableMarker = "[redaction unavailable: output omitted]"

    public var limits: AgentToolDetailLimits
    // This key is generated when the sanitizer (and therefore its owning
    // store) is created. It is intentionally not Codable or persisted: secret
    // equality is useful only while associating this host-local lifecycle.
    private let fingerprintKey: SymmetricKey

    public init(
        limits: AgentToolDetailLimits = AgentToolDetailLimits(),
        fingerprintKey: SymmetricKey = SymmetricKey(size: .bits256)
    ) {
        self.limits = limits
        self.fingerprintKey = fingerprintKey
    }

    /// Tool titles are provider text, not trusted display labels. A title that
    /// looks like a path is omitted before it enters the retained record.
    public static func isPathBearingToolName(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        return value.contains("/") || value.contains("\\") ||
            value.hasPrefix("~") || value.hasPrefix(".") ||
            value.lowercased().hasPrefix("file:") || value.contains("://")
    }

    func sanitizeToolName(_ raw: String, explicitSecrets: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasControl = trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= limits.maxToolNameBytes,
              !hasControl,
              !Self.isPathBearingToolName(trimmed),
              SecretRedactor.redact(trimmed, explicitSecrets: explicitSecrets) == trimmed else { return "Tool" }
        return trimmed
    }

    func sanitizeArguments(_ fields: [AgentToolDetailField], explicitSecrets: [String]) -> [AgentToolDetailArgument] {
        guard limits.maxArguments > 0 else { return [] }
        let clippedFields = Array(fields.prefix(limits.maxArguments))
        let secrets = explicitSecrets + discoveredSensitiveValues(in: clippedFields)
        return clippedFields.map { field in
            let key = Self.sanitizedKey(field.key, explicitSecrets: secrets, maxBytes: limits.maxArgumentKeyBytes)
            if SecretRedactor.isSensitiveName(key) || SecretRedactor.isSensitiveName(field.key) {
                let bounded = boundText("[REDACTED]", maxBytes: limits.maxFieldValueBytes, maxLines: limits.maxFieldValueLines, redacted: true)
                return AgentToolDetailArgument(key: key, value: bounded, sensitiveKeyFiltered: true)
            }
            let redacted = SecretRedactor.redact(field.value, explicitSecrets: secrets)
            let isCommand = key == AgentToolDetailObservation.shellCommandKey
            return AgentToolDetailArgument(
                key: key,
                value: boundText(
                    redacted,
                    maxBytes: isCommand ? limits.maxCommandBytes : limits.maxFieldValueBytes,
                    maxLines: isCommand ? limits.maxCommandLines : limits.maxFieldValueLines,
                    redacted: redacted != field.value
                ),
                sensitiveKeyFiltered: false
            )
        }
    }

    func sensitiveFingerprints(in fields: [AgentToolDetailField], explicitSecrets: [String]) -> Set<String> {
        Set((explicitSecrets + discoveredSensitiveValues(in: fields)).compactMap { fingerprint($0) })
    }

    func discoveredSensitiveValues(in fields: [AgentToolDetailField]) -> [String] {
        fields.flatMap { field in
            let fieldValue = SecretRedactor.isSensitiveName(field.key) ? [field.value] : []
            return fieldValue + SecretRedactor.discoveredSensitiveValues(in: field.value)
        }
    }

    func discoveredSensitiveValues(in output: String?) -> [String] {
        guard let output else { return [] }
        return SecretRedactor.discoveredSensitiveValues(in: output)
    }

    func explicitFingerprints(_ explicitSecrets: [String]) -> Set<String> {
        Set(explicitSecrets.compactMap { fingerprint($0) })
    }

    func sanitizeOutput(
        _ raw: String?,
        explicitSecrets: [String],
        redactionSecrets: [String] = [],
        requiredStartFingerprints: Set<String>,
        associatedArguments: [AgentToolDetailArgument]
    ) -> AgentToolDetailBoundedText? {
        guard let raw else { return nil }
        let suppliedFingerprints = explicitFingerprints(explicitSecrets)
        guard requiredStartFingerprints.isSubset(of: suppliedFingerprints) else {
            return redactionUnavailableOutput()
        }
        let filteredArgumentMarkers = associatedArguments
            .filter { $0.sensitiveKeyFiltered }
            .map { $0.value.text }
            .filter { !$0.isEmpty && $0 != "[REDACTED]" }
        let redacted = SecretRedactor.redact(
            raw,
            explicitSecrets: explicitSecrets + redactionSecrets + filteredArgumentMarkers
        )
        return boundText(
            redacted,
            maxBytes: limits.maxOutputBytes,
            maxLines: limits.maxOutputLines,
            redacted: redacted != raw
        )
    }

    func redactionUnavailableOutput() -> AgentToolDetailBoundedText {
        boundText(
            Self.redactionUnavailableMarker,
            maxBytes: limits.maxOutputBytes,
            maxLines: limits.maxOutputLines,
            redacted: true
        )
    }

    func sanitizeFiles(_ files: [URL], existing: [URL], explicitSecrets: [String]) -> [URL] {
        guard limits.maxAffectedFiles > 0 else { return [] }
        var result: [URL] = []
        var seen = Set<String>()
        for file in existing + files {
            // Do not retain a made-up URL containing a redaction marker. A
            // path is useful only when it is still a reliable path.
            guard let sanitized = Self.sanitizedFileURL(file, explicitSecrets: explicitSecrets) else { continue }
            let path = sanitized.path
            guard seen.insert(path).inserted else { continue }
            result.append(sanitized)
            if result.count >= limits.maxAffectedFiles { break }
        }
        return result
    }

    func sanitizeFileChanges(_ changes: [AgentToolDetailObservation.FileChange], explicitSecrets: [String]) -> [AgentToolDetailObservation.FileChange] {
        changes.prefix(24).compactMap { change in
            guard let path = AgentToolDetailDisplaySanitizer.path(change.path, explicitSecrets: explicitSecrets) else { return nil }
            let rename = change.renamePath.flatMap { candidate -> String? in
                AgentToolDetailDisplaySanitizer.path(candidate, explicitSecrets: explicitSecrets)
            }
            guard change.renamePath == nil || rename != nil else { return nil }
            let diff = AgentToolDetailDisplaySanitizer.diffPreview(change.diffPreview, explicitSecrets: explicitSecrets,
                maxBytes: limits.maxOutputBytes, maxLines: limits.maxOutputLines)
            // Counts are integers with no redaction surface, so they survive a
            // sanitizer pass that may well have dropped the preview they were
            // measured from.
            return .init(action: change.action, path: path, renamePath: rename, diffPreview: diff,
                addedLines: change.addedLines, removedLines: change.removedLines,
                countsAreLowerBound: change.countsAreLowerBound)
        }
    }

    func mergeFileChanges(_ lhs: [AgentToolDetailObservation.FileChange], _ rhs: [AgentToolDetailObservation.FileChange]) -> [AgentToolDetailObservation.FileChange] {
        var unique: [String: AgentToolDetailObservation.FileChange] = [:]
        for change in lhs + rhs {
            let key = [change.action.rawValue, change.path, change.renamePath ?? ""].joined(separator: "\u{1f}")
            if let prior = unique[key] {
                // The logical row is action/source/destination. Conflicting
                // explicit previews choose one actually observed value by a
                // stable total order; they never duplicate a disclosure row.
                let selectedDiff = [prior.diffPreview, change.diffPreview].compactMap { $0 }.max()
                // A measured count outranks an absent one, and an exact count
                // outranks a floor, so the join stays commutative: whichever
                // arrival order the two observations take, the richer fact wins.
                let priorIsBetter = prior.hasAnyMeasuredCount
                    && (!change.hasAnyMeasuredCount || (change.countsAreLowerBound && !prior.countsAreLowerBound))
                let counts = priorIsBetter ? prior : change
                unique[key] = .init(action: change.action, path: change.path,
                    renamePath: change.renamePath, diffPreview: selectedDiff,
                    addedLines: counts.addedLines, removedLines: counts.removedLines,
                    countsAreLowerBound: counts.countsAreLowerBound)
            } else {
                unique[key] = change
            }
        }
        return unique.sorted { $0.key < $1.key }.prefix(24).map(\.value)
    }

    func excludesSensitiveFingerprints(
        _ changes: [AgentToolDetailObservation.FileChange],
        fingerprints: Set<String>
    ) -> [AgentToolDetailObservation.FileChange] {
        guard !fingerprints.isEmpty else { return changes }
        let lengths = Set(fingerprints.compactMap { Int($0.split(separator: ":", maxSplits: 1).first ?? "") })
        guard lengths.count == 1, let length = lengths.first, length >= 4 else { return [] }
        let allFields = changes.flatMap { [$0.path, $0.renamePath].compactMap { $0 } }
        let candidateWindows = allFields.reduce(0) { $0 + max(0, $1.utf8.count - length + 1) }
        guard candidateWindows <= 1_024 else { return [] }
        return changes.compactMap { change in
            let fields = [change.path, change.renamePath].compactMap { $0 }
            guard !containsSensitiveFingerprint(fields, fingerprints: fingerprints) else { return nil }
            // The PREVIEW is dropped here (it is the text that could carry a
            // secret); the counts measured from it are integers and stay.
            return .init(action: change.action, path: change.path,
                renamePath: change.renamePath, diffPreview: nil,
                addedLines: change.addedLines, removedLines: change.removedLines,
                countsAreLowerBound: change.countsAreLowerBound)
        }
    }

    func exceedsSensitiveFingerprintWorkBudget(
        _ changes: [AgentToolDetailObservation.FileChange],
        fingerprints: Set<String>
    ) -> Bool {
        guard !fingerprints.isEmpty else { return false }
        let lengths = Set(fingerprints.compactMap { Int($0.split(separator: ":", maxSplits: 1).first ?? "") })
        guard lengths.count == 1, let length = lengths.first, length >= 4 else { return true }
        let fields = changes.prefix(24).flatMap { [$0.path, $0.renamePath].compactMap { $0 } }
        return fields.reduce(0) { $0 + max(0, $1.utf8.count - length + 1) } > 1_024
    }

    func containsSensitiveFingerprint(_ fields: [String], fingerprints: Set<String>) -> Bool {
        guard !fingerprints.isEmpty else { return false }
        let lengths = Set(fingerprints.compactMap { Int($0.split(separator: ":", maxSplits: 1).first ?? "") })
        // Short secrets and multiple lengths fail closed: exhaustive matching
        // would either miss substring capabilities or multiply hot-path work.
        guard lengths.count == 1, let length = lengths.first, length >= 4 else { return true }
        for field in fields {
            let bytes = Array(field.utf8)
            guard length <= bytes.count else { continue }
            for offset in 0...(bytes.count - length) {
                guard let candidate = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8),
                      let value = fingerprint(candidate) else { continue }
                if fingerprints.contains(value) { return true }
            }
        }
        return false
    }

    /// Stable, non-secret event keys used only to break same-ID timestamp ties.
    /// Every component is sanitized first. Ephemeral HMAC fingerprints remain
    /// separate and are used only for same-lifecycle output association.
    func stableStartTieKey(
        toolName: String,
        arguments: [AgentToolDetailArgument],
        affectedFiles: [URL]
    ) -> String {
        stableKey([
            toolName,
            arguments.map { stableArgumentKey($0) }.joined(separator: "\u{1f}"),
            affectedFiles.map(\.absoluteString).sorted().joined(separator: "\u{1f}")
        ])
    }

    func stableEndTieKey(
        output: AgentToolDetailBoundedText?,
        status: AgentItemStatus,
        exitCode: Int?,
        affectedFiles: [URL],
        shellOutcome: AgentShellStatus? = nil,
        reportedDuration: TimeInterval? = nil
    ) -> String {
        stableKey([
            stableTextKey(output),
            status.rawValue,
            exitCode.map(String.init) ?? "",
            affectedFiles.map(\.absoluteString).sorted().joined(separator: "\u{1f}"),
            shellOutcome?.rawValue ?? "",
            reportedDuration.map { String($0) } ?? ""
        ])
    }

    private func stableArgumentKey(_ argument: AgentToolDetailArgument) -> String {
        stableKey([
            argument.key,
            stableTextKey(argument.value),
            argument.sensitiveKeyFiltered ? "sensitive" : "ordinary"
        ])
    }

    private func stableTextKey(_ text: AgentToolDetailBoundedText?) -> String {
        guard let text else { return "<nil>" }
        return stableKey([
            text.text,
            text.truncatedByBytes ? "bytes" : "unbounded-bytes",
            text.truncatedByLines ? "lines" : "unbounded-lines",
            text.redacted ? "redacted" : "unredacted"
        ])
    }

    private func stableKey(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private func boundText(_ text: String, maxBytes: Int, maxLines: Int, redacted: Bool) -> AgentToolDetailBoundedText {
        let bounded = Self.boundText(text, maxBytes: maxBytes, maxLines: maxLines)
        return AgentToolDetailBoundedText(
            text: bounded.text,
            truncatedByBytes: bounded.truncatedByBytes,
            truncatedByLines: bounded.truncatedByLines,
            redacted: redacted
        )
    }

    private static func sanitizedKey(_ raw: String, explicitSecrets: [String], maxBytes: Int) -> String {
        let single = singleLine(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let controlFree = String(String.UnicodeScalarView(single.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? UnicodeScalar(0x20)! : scalar
        }))
        let redacted = SecretRedactor.redact(controlFree, explicitSecrets: explicitSecrets)
        let fallback = redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "value" : redacted
        return boundText(fallback, maxBytes: maxBytes, maxLines: 1).text
    }

    private static func singleLine(_ raw: String) -> String {
        raw
            .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? ""
    }


    private func fingerprint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digest = HMAC<SHA256>.authenticationCode(for: Data(trimmed.utf8), using: fingerprintKey)
        return "\(trimmed.utf8.count):" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedFileURL(_ file: URL, explicitSecrets: [String]) -> URL? {
        guard file.isFileURL else { return nil }
        let absolute = file.absoluteString
        let redactedAbsolute = SecretRedactor.redact(absolute, explicitSecrets: explicitSecrets)
        // Query credentials, URL userinfo, and explicit secret substrings make
        // the source path unreliable. Omit it rather than storing a fabricated
        // `file:///…/[REDACTED]` path.
        guard redactedAbsolute == absolute else { return nil }
        let standardized = file.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return standardized
    }

    private static let truncationMarker = "[truncated]"

    private static func boundText(_ text: String, maxBytes: Int, maxLines: Int) -> (text: String, truncatedByBytes: Bool, truncatedByLines: Bool) {
        let lineBounded = boundLines(text, maxLines: maxLines)
        let byteBounded = boundUTF8(lineBounded.text, maxBytes: maxBytes, maxLines: maxLines)
        return (byteBounded.text, byteBounded.truncated, lineBounded.truncated || byteBounded.truncatedByLines)
    }

    private static func boundLines(_ text: String, maxLines: Int) -> (text: String, truncated: Bool) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines else { return (text, false) }
        guard maxLines > 1 else { return (truncationMarker, true) }
        let prefix = lines.prefix(maxLines - 1).joined(separator: "\n")
        return (prefix.isEmpty ? truncationMarker : prefix + "\n" + truncationMarker, true)
    }

    private static func boundUTF8(_ text: String, maxBytes: Int, maxLines: Int) -> (text: String, truncated: Bool, truncatedByLines: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false, false) }
        let marker = truncationMarker
        let markerBytes = marker.utf8.count
        guard maxBytes > markerBytes, maxLines > 1 else { return (marker, true, maxLines <= 1) }
        let prefixBudget = maxBytes - markerBytes - 1
        guard prefixBudget > 0 else { return (marker, true, false) }
        var result = ""
        var byteCount = 0
        var lineCount = 1
        var truncatedByLines = false
        for character in text {
            if character.isNewline {
                guard lineCount < maxLines - 1 else {
                    truncatedByLines = true
                    break
                }
                lineCount += 1
            }
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= prefixBudget else { break }
            result.append(character)
            byteCount += bytes
        }
        while result.last?.isNewline == true { result.removeLast() }
        return (result.isEmpty ? marker : result + "\n" + marker, true, truncatedByLines)
    }
}

public actor AgentToolDetailStore {
    private var details: [AgentToolDetailKey: AgentToolDetailRecord] = [:]
    public nonisolated let currentDate: @Sendable () -> Date
    public nonisolated let timeToLive: TimeInterval
    private let sanitizer: AgentToolDetailSanitizer
    private var expiryTask: Task<Void, Never>?

    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        timeToLive: TimeInterval = 60 * 60,
        limits: AgentToolDetailLimits = AgentToolDetailLimits()
    ) {
        self.currentDate = clock
        self.timeToLive = max(0, timeToLive)
        self.sanitizer = AgentToolDetailSanitizer(limits: limits)
    }

    /// Stop the local reaper when its owning session is torn down. The weak
    /// capture in the task also makes store deallocation cancellation-safe.
    public func shutdown() {
        expiryTask?.cancel()
        expiryTask = nil
    }

    @discardableResult
    public func recordStart(_ start: AgentToolDetailStart) -> AgentToolDetailRecord {
        let observedAt = currentDate()
        // A zero-TTL store has terminal cleanup semantics: a new event never
        // resurrects an older record, even if the background task has not run.
        expireLocked(at: observedAt)
        startExpiryTaskIfNeeded()
        let implicitSecrets = sanitizer.discoveredSensitiveValues(in: start.arguments)
        let eventSecrets = start.explicitSecrets + implicitSecrets
        let sanitizedToolName = sanitizer.sanitizeToolName(start.toolName, explicitSecrets: eventSecrets)
        let sanitizedArguments = sanitizer.sanitizeArguments(start.arguments, explicitSecrets: eventSecrets)
        let sanitizedFiles = sanitizer.sanitizeFiles(start.affectedFiles, existing: [], explicitSecrets: eventSecrets)
        let sensitiveFingerprints = sanitizer.sensitiveFingerprints(in: start.arguments, explicitSecrets: start.explicitSecrets)
        let existing = details[start.identity]
        let knownFingerprints = (existing?.sensitiveStartFingerprints ?? []).union(sensitiveFingerprints)
        let sanitizedChanges = sanitizer.exceedsSensitiveFingerprintWorkBudget(
            start.fileChanges, fingerprints: knownFingerprints
        ) ? [] : sanitizer.sanitizeFileChanges(start.fileChanges, explicitSecrets: eventSecrets)
        let tieKey = sanitizer.stableStartTieKey(
            toolName: sanitizedToolName,
            arguments: sanitizedArguments,
            affectedFiles: sanitizedFiles
        )
        var record = existing ?? AgentToolDetailRecord(identity: start.identity, updatedAt: observedAt)
        record.sensitiveStartFingerprints.formUnion(sensitiveFingerprints)
        let shouldApplyStart = isNewer(
            timestamp: start.startedAt,
            tieKey: tieKey,
            than: record.latestStartTimestamp,
            existingTieKey: record.latestStartTieKey
        )
        if shouldApplyStart {
            record.toolName = sanitizedToolName
            record.arguments = sanitizedArguments
            // Missing provider timestamps remain missing. Using arrival time
            // here would make equal/absent timestamp races nondeterministic.
            record.startedAt = start.startedAt
            record.latestStartTimestamp = start.startedAt
            record.latestStartTieKey = tieKey
            if record.output != nil,
               !record.sensitiveStartFingerprints.isSubset(of: record.latestEndExplicitFingerprints) {
                record.output = sanitizer.redactionUnavailableOutput()
            }
        } else if record.latestStartTieKey == tieKey,
                  record.latestStartTimestamp == start.startedAt {
            // A fully sanitized tie key intentionally hides secret values. If
            // two starts collide there, retain the union of their opaque
            // same-lifecycle associations instead of whichever arrived first.
            // This makes later output handling fail closed for every candidate
            // secret while keeping the secrets themselves out of the record.
            if record.output != nil,
               !record.sensitiveStartFingerprints.isSubset(of: record.latestEndExplicitFingerprints) {
                record.output = sanitizer.redactionUnavailableOutput()
            }
        }
        // Explicit file and parent facts are monotonic and independent of the
        // name/argument timestamp winner. This join is commutative, associative
        // and idempotent, so weak/rich arrival permutations converge.
        // Re-run prior facts through newly learned explicit secrets, then use
        // opaque fingerprints to make the reverse order fail closed too.
        let resanitizedExisting = sanitizer.sanitizeFileChanges(record.fileChanges, explicitSecrets: eventSecrets)
        record.fileChanges = sanitizer.excludesSensitiveFingerprints(
            sanitizer.mergeFileChanges(resanitizedExisting, sanitizedChanges),
            fingerprints: record.sensitiveStartFingerprints)
        record.observedParentItemIDs = Set(record.observedParentItemIDs.filter {
            !sanitizer.containsSensitiveFingerprint([$0], fingerprints: record.sensitiveStartFingerprints)
        })
        if !record.observedParentConflict,
           let parent = AgentToolDetailDisplaySanitizer.parentItemID(start.parentItemID, explicitSecrets: eventSecrets),
           !sanitizer.containsSensitiveFingerprint([parent], fingerprints: record.sensitiveStartFingerprints) {
            if let existingParent = record.observedParentItemIDs.first, existingParent != parent {
                record.observedParentItemIDs = []
                record.observedParentConflict = true
            } else {
                record.observedParentItemIDs = [parent]
            }
        }
        record.parentItemID = record.observedParentConflict ? nil : record.observedParentItemIDs.first
        record.updatedAt = observedAt
        record.affectedFiles = sanitizer.sanitizeFiles(start.affectedFiles, existing: record.affectedFiles, explicitSecrets: eventSecrets)
        details[start.identity] = record
        if timeToLive == 0 { expireLocked(at: observedAt) }
        return record
    }

    @discardableResult
    public func recordEnd(_ end: AgentToolDetailEnd) -> AgentToolDetailRecord {
        let observedAt = currentDate()
        expireLocked(at: observedAt)
        startExpiryTaskIfNeeded()
        let implicitSecrets = sanitizer.discoveredSensitiveValues(in: end.output)
        let eventSecrets = end.explicitSecrets + implicitSecrets
        let explicitFingerprints = sanitizer.explicitFingerprints(end.explicitSecrets)
        let sanitizedOutput = sanitizer.sanitizeOutput(
            end.output,
            explicitSecrets: end.explicitSecrets,
            redactionSecrets: implicitSecrets,
            requiredStartFingerprints: details[end.identity]?.sensitiveStartFingerprints ?? [],
            associatedArguments: details[end.identity]?.arguments ?? []
        )
        let sanitizedFiles = sanitizer.sanitizeFiles(end.affectedFiles, existing: [], explicitSecrets: eventSecrets)
        let tieKey = sanitizer.stableEndTieKey(
            output: sanitizedOutput,
            status: end.status,
            exitCode: end.exitCode,
            affectedFiles: sanitizedFiles,
            shellOutcome: end.shellOutcome,
            reportedDuration: end.reportedDuration
        )
        let existing = details[end.identity]
        var record = existing ?? AgentToolDetailRecord(identity: end.identity, updatedAt: observedAt)
        let shouldApplyEnd = isNewer(
            timestamp: end.endedAt,
            tieKey: tieKey,
            than: record.latestEndTimestamp,
            existingTieKey: record.latestEndTieKey
        )
        if shouldApplyEnd {
            record.output = sanitizedOutput
            record.status = end.status
            record.exitCode = end.exitCode
            record.shellOutcome = end.shellOutcome
            record.reportedDuration = end.reportedDuration
            record.endedAt = end.endedAt
            record.latestEndTimestamp = end.endedAt
            record.latestEndTieKey = tieKey
            record.latestEndExplicitFingerprints = explicitFingerprints
        }
        record.updatedAt = observedAt
        record.affectedFiles = sanitizer.sanitizeFiles(end.affectedFiles, existing: record.affectedFiles, explicitSecrets: eventSecrets)
        details[end.identity] = record
        if timeToLive == 0 { expireLocked(at: observedAt) }
        return record
    }

    public func detail(for identity: AgentToolDetailKey) -> AgentToolDetailRecord? {
        expireLocked(at: currentDate())
        return details[identity]
    }

    public func allDetails() -> [AgentToolDetailRecord] {
        expireLocked(at: currentDate())
        return details.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.identity.sortDescription < rhs.identity.sortDescription }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    @discardableResult
    public func expireNow() -> [AgentToolDetailID] {
        expireLocked(at: currentDate())
    }

    private func isNewer(timestamp: Date?, tieKey: String, than existingTimestamp: Date?, existingTieKey: String?) -> Bool {
        switch (timestamp, existingTimestamp) {
        case let (lhs?, rhs?):
            if lhs != rhs { return lhs > rhs }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        // Explicit tie policy: canonical sanitized payload keys are compared
        // lexicographically, and equal keys are idempotent.
        return tieKey > (existingTieKey ?? "")
    }

    private func startExpiryTaskIfNeeded() {
        guard expiryTask == nil else { return }
        // Polling is bounded to one second for long-lived sessions and remains
        // short for tests/short TTLs. The task sleeps without retaining the
        // actor, then briefly asks it to reap; shutdown can therefore cancel
        // it without a retain cycle.
        let pollSeconds = min(max(timeToLive / 10, 0.01), 1.0)
        let pollNanos = UInt64(pollSeconds * 1_000_000_000)
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pollNanos)
                } catch {
                    return
                }
                guard let self, await self.reapFromExpiryTask() else { return }
            }
        }
    }

    private func reapFromExpiryTask() -> Bool {
        _ = expireLocked(at: currentDate())
        let remains = !details.isEmpty
        if !remains { expiryTask = nil }
        return remains
    }

    @discardableResult
    private func expireLocked(at now: Date) -> [AgentToolDetailID] {
        let expiredKeys = details
            .filter { now.timeIntervalSince($0.value.updatedAt) >= timeToLive }
            .map { $0.key }
            .sorted { $0.sortDescription < $1.sortDescription }
        for key in expiredKeys { details.removeValue(forKey: key) }
        return expiredKeys.map(\.providerItemID)
    }
}

/// WHICH normalized items carry a host-local detail record.
///
/// TR-03 — this predicate existed twice: once in `AgentTranscriptListView`
/// (production) and once, hand-copied, in `ComponentLab`'s review fixture. A
/// change to one silently stopped the other from matching production, which is
/// the failure mode where a fixture keeps passing about a surface it no longer
/// resembles. One definition, both callers.
public enum AgentToolDetailPolicy {
    public static func carriesHostLocalDetail(_ kind: ItemKind) -> Bool {
        switch kind {
        case .commandExecution, .fileChange, .mcpToolCall, .webSearch: return true
        // A delegation row publishes the same whitelisted argument fields every
        // other row does (claude's `description`/`subagent_type`, pi's). The
        // child's own TRANSCRIPT is a different thing and is still not this.
        case .subagent: return true
        case .assistantMessage, .reasoning, .plan, .error: return false
        // An unknown kind has no whitelist to publish through.
        case .compaction, .unknown: return false
        }
    }
}

/// `.plans/45` S3 — what a collapsed action-first tool row shows: the action
/// sentence and, when both instants are known, the duration for the trailing
/// column. Status stays out; the row renders its lifecycle separately.
public struct AgentToolDetailCollapsedPresentation: Equatable, Sendable {
    public let actionLine: String
    public let durationText: String?

    public init(actionLine: String, durationText: String?) {
        self.actionLine = actionLine
        self.durationText = durationText
    }
}

public struct AgentToolDetailCompactPresentation: Equatable, Sendable {
    public var title: String
    public var statusText: String
    public var summary: String
    public var accessibilitySummary: String

    public init(title: String, statusText: String, summary: String, accessibilitySummary: String) {
        self.title = title
        self.statusText = statusText
        self.summary = summary
        self.accessibilitySummary = accessibilitySummary
    }
}

public struct AgentToolDetailExpandedPresentation: Equatable, Sendable {
    public var header: String
    public var arguments: [AgentToolDetailArgument]
    public var output: AgentToolDetailBoundedText?
    public var statusText: String
    public var exitCodeText: String?
    public var timingText: String?
    public var affectedFiles: [URL]
    public var accessibilitySummary: String

    public init(
        header: String,
        arguments: [AgentToolDetailArgument],
        output: AgentToolDetailBoundedText?,
        statusText: String,
        exitCodeText: String?,
        timingText: String?,
        affectedFiles: [URL],
        accessibilitySummary: String
    ) {
        self.header = header
        self.arguments = arguments
        self.output = output
        self.statusText = statusText
        self.exitCodeText = exitCodeText
        self.timingText = timingText
        self.affectedFiles = affectedFiles
        self.accessibilitySummary = accessibilitySummary
    }
}

public enum AgentToolDetailPresenter {
    /// One fail-closed boundary for provider-owned records. Store capture and
    /// view/provider closures both pass through this method; callers cannot
    /// bypass the title, detail, or accessibility policy by pre-sanitizing.
    public static func sanitizedProviderRecord(_ record: AgentToolDetailRecord) -> AgentToolDetailRecord? {
        guard record.identity.scope.agentID.isEmpty == false,
              record.identity.scope.threadID.isEmpty == false,
              record.identity.scope.turnID.isEmpty == false,
              record.identity.scope.provider.isEmpty == false else { return nil }
        let safeName = safeToolName(record.toolName)
        let safeArguments = record.arguments.prefix(100).map { argument in
            let rawKey = boundedSingleLine(argument.key, maxBytes: 256)
            let key = rawKey.isEmpty || rawKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                ? "value" : rawKey
            let (value, neutralized) = neutralizedProviderValue(argument.value.text, maxBytes: 2_048, maxLines: 8)
            let bounded = boundedText(value, maxBytes: 2_048, maxLines: 8)
            return AgentToolDetailArgument(
                key: key,
                value: AgentToolDetailBoundedText(
                    text: bounded,
                    truncatedByBytes: bounded.utf8.count < value.utf8.count,
                    truncatedByLines: value.split(separator: "\n", omittingEmptySubsequences: false).count > 8,
                    redacted: argument.value.redacted || neutralized
                ),
                sensitiveKeyFiltered: argument.sensitiveKeyFiltered || neutralized
            )
        }
        let safeOutput: AgentToolDetailBoundedText? = record.output.map { output in
            let (value, neutralized) = neutralizedProviderValue(output.text, maxBytes: 16_384, maxLines: 200)
            let bounded = boundedText(value, maxBytes: 16_384, maxLines: 200)
            return AgentToolDetailBoundedText(
                text: bounded,
                truncatedByBytes: bounded.utf8.count < value.utf8.count,
                truncatedByLines: value.split(separator: "\n", omittingEmptySubsequences: false).count > 200,
                redacted: output.redacted || neutralized
            )
        }
        var sanitized = record
        sanitized.toolName = safeName
        sanitized.arguments = Array(safeArguments)
        sanitized.output = safeOutput
        sanitized.fileChanges = Array(record.fileChanges.prefix(24).compactMap { change in
            guard let path = AgentToolDetailDisplaySanitizer.path(change.path) else { return nil }
            let rename = change.renamePath.flatMap { AgentToolDetailDisplaySanitizer.path($0) }
            let diff = AgentToolDetailDisplaySanitizer.diffPreview(change.diffPreview, maxBytes: 16_384, maxLines: 200)
            return AgentToolDetailObservation.FileChange(
                action: change.action, path: path, renamePath: rename, diffPreview: diff,
                addedLines: change.addedLines, removedLines: change.removedLines,
                countsAreLowerBound: change.countsAreLowerBound)
        })
        sanitized.parentItemID = AgentToolDetailDisplaySanitizer.parentItemID(record.parentItemID)
        sanitized.observedParentItemIDs = Set(sanitized.parentItemID.map { [$0] } ?? [])
        sanitized.observedParentConflict = false
        // Provider closures cannot attest that a URL was sanitized. Do not
        // retain or render provider paths at this boundary.
        sanitized.affectedFiles = []
        return sanitized
    }

    /// Provider closures are an untrusted composition seam. Enforce the same
    /// title rule again before either visible text or accessibility receives it.
    public static func safeToolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= AgentToolDetailLimits().maxToolNameBytes,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !AgentToolDetailSanitizer.isPathBearingToolName(trimmed),
              SecretRedactor.redact(trimmed) == trimmed else { return "Tool" }
        return trimmed
    }

    private static func neutralizedProviderValue(_ raw: String, maxBytes: Int, maxLines: Int) -> (String, Bool) {
        let redacted = SecretRedactor.redact(raw)
        let hasPath = raw.contains("/") || raw.contains("\\") || raw.contains("://")
        let hasControl = raw.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        let hasTooManyLines = raw.split(separator: "\n", omittingEmptySubsequences: false).count > maxLines
        guard redacted == raw, !hasPath, !hasControl, !hasTooManyLines,
              raw.utf8.count <= maxBytes else { return ("[REDACTED]", true) }
        return (raw, false)
    }

    private static func boundedSingleLine(_ raw: String, maxBytes: Int) -> String {
        boundedText(raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "", maxBytes: maxBytes, maxLines: 1)
    }

    private static func boundedText(_ raw: String, maxBytes: Int, maxLines: Int) -> String {
        let normalized = raw.replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let lineLimited = lines.prefix(maxLines).joined(separator: "\n")
        guard lineLimited.utf8.count > maxBytes else { return lineLimited }
        let marker = "[truncated]"
        let budget = max(0, maxBytes - marker.utf8.count - 1)
        var result = ""
        for character in lineLimited where result.utf8.count + String(character).utf8.count <= budget {
            result.append(character)
        }
        return result + "\n" + marker
    }

    public static func compact(_ detail: AgentToolDetailRecord) -> AgentToolDetailCompactPresentation {
        let status = statusText(detail.status)
        let safeName = safeToolName(detail.toolName)
        let duration = detail.duration.map(formatDuration)
        let fileText: String? = detail.affectedFiles.isEmpty ? nil : "\(detail.affectedFiles.count) file\(detail.affectedFiles.count == 1 ? "" : "s")"
        let coreSummary = observableSummary(detail)
        let suffix = [status, duration, fileText].compactMap { $0 }.joined(separator: " · ")
        let summary = shortLine(suffix.isEmpty ? coreSummary : "\(coreSummary) · \(suffix)")
        return AgentToolDetailCompactPresentation(
            title: safeName,
            statusText: status,
            summary: summary,
            accessibilitySummary: accessibilitySummary(for: detail, status: status)
        )
    }

    /// The action/result text a tool row can show beside its separately rendered
    /// lifecycle. Keeping status out prevents a completed row from saying
    /// “Completed” twice (or composing a stale detail status with the semantic one).
    public static func observableSummary(_ detail: AgentToolDetailRecord) -> String {
        shortLine(pureSummary(for: detail) ?? safeToolName(detail.toolName))
    }

    /// Host-local disclosure text. The first line is the compact row summary;
    /// subsequent lines are genuinely additional, already-sanitized facts. File
    /// locations are abbreviated to their final two components so the operator
    /// can distinguish targets without printing a home directory or machine path.
    public static func observableDisclosureText(_ detail: AgentToolDetailRecord) -> String {
        // T2 (2026-08-25) — Dylan: "there is a lot of doubling." A row's TITLE is
        // `collapsed(_:).actionLine`; every line here that merely restates it is
        // the same fact shouted twice, and it cost a body line on most rows.
        //
        // `echo` is what the title will already be saying. When there IS an
        // action sentence the first line repeats it verbatim and the renderer
        // strips it by exact match. When there is NOT, the title falls back to
        // `capitalizedPhrase(toolName)` while this line used to fall back to the
        // *un*-capitalized `safeToolName` — "Bash" over "bash",
        // "Delegate_agent" over "delegate_agent" — which no exact-match dedupe
        // could ever catch. A line that is only the tool name adds nothing over a
        // title that is only the tool name, so emit none.
        // A shell row's body is the command itself (and where it ran), never an
        // "Exit code: 0" line: the exit status is the row's badge, and only
        // when it is not zero.
        let shell = shellInvocation(detail)
        if let shell, !shell.command.isEmpty {
            // Any file the provider tied to the call stays listed: the command
            // narrates, it does not name the file.
            let label = AgentToolKind.shell.fileLineLabel
            return ([shell.disclosureText] + observableAffectedFileNames(detail).map { "\(label): \($0)" })
                .prefix(12).joined(separator: "\n")
        }
        let actionLine = pureSummary(for: detail).map { shortLine($0) }
        let echo = actionLine
            ?? shortLine(capitalizedPhrase(AgentToolKind.humanizedToolName(safeToolName(detail.toolName))))
        var lines: [String] = []
        if let actionLine { lines.append(actionLine) }
        // An MCP row's title names the server and the tool; the line under it is
        // the argument saying what it was FOR (the JQL, the query, the issue).
        // `server` is in the title already; a board change's `op` is its verb.
        var argumentKeysSaid: Set<String> = []
        if mcpToolName(detail) != nil {
            argumentKeysSaid.insert("server")
            if let primary = mcpPrimaryArgument(detail) {
                lines.append(shortLine(primary.value))
                argumentKeysSaid.insert(primary.key)
            }
        } else if ArrayWorkspaceTool(toolName: safeToolName(detail.toolName)) == .boardApply {
            argumentKeysSaid.insert("op")
        }
        let kind = AgentToolKind.resolve(toolName: safeToolName(detail.toolName))
        let fileLabel = kind.fileLineLabel
        let affectedFileNames = observableAffectedFileNames(detail)
        // Suppression is only sound when there is exactly ONE affected file: the
        // title names at most one basename ("Edited foo.js"), so with two or
        // more files ("index.ts" from two different directories is a common
        // real-world collision) dropping every line that happens to share that
        // basename would hide files the title never actually distinguished.
        // Multi-file rows always keep their file lines.
        for fileName in affectedFileNames {
            // "Read foo.js" over "Read: …/dir/foo.js" — the title already names
            // the basename, and the directory it came from is still there
            // expanded. The argument loop below has had this suppression since
            // `.plans/45`; the file line never did.
            guard !(affectedFileNames.count == 1 && echoNamesFile(echo, fileName, kind: kind)) else { continue }
            lines.append("\(fileLabel): \(fileName)")
        }
        for change in detail.fileChanges.prefix(12) {
            let destination = change.renamePath.map { " → \($0)" } ?? ""
            lines.append("\(change.action.rawValue.capitalized): \(change.path)\(destination)")
            if let diff = change.diffPreview, !diff.isEmpty { lines.append(diff) }
        }
        for argument in detail.arguments.prefix(4)
        where !argument.sensitiveKeyFiltered && !argument.value.redacted
            && !argumentKeysSaid.contains(argument.key) {
            let value = shortLine(argument.value.text)
            guard !value.isEmpty, !value.contains("[REDACTED]"),
                  !isPathBearingObservableValue(value) else { continue }
            // `.plans/45` — the action sentence already SAYS the argument
            // ("Searched for “recent sports headline”"); repeating it as
            // "query: recent sports headline" underneath is noise, and it was
            // visible on every row of the real replayed turn.
            // Reads `echo` rather than `lines[0]`, which is no longer guaranteed
            // to exist — and which was the wrong string anyway whenever the title
            // was the tool-name fallback.
            guard !echo.contains(value) else { continue }
            lines.append("\(shortLine(argument.key, maxBytes: 48)): \(value)")
        }
        // A shell's exit status is its row's badge (and nothing at all when it
        // is zero) — never a body line. Other tools keep theirs.
        if shell == nil, let exitCode = detail.exitCode { lines.append("Exit code: \(exitCode)") }
        // No "Duration:" line. `.plans/45` — the row's trailing column already
        // reads "4.0s ✓"; a second copy underneath is the same echo the query
        // line was, and it cost a full body line on every settled row.
        return lines.prefix(12).joined(separator: "\n")
    }

    /// Whether the title already names this file, so a "Read: …/dir/foo.js" line
    /// underneath a "Read foo.js" title would be doubling. Compares the basename,
    /// because the line carries an abbreviated path and the title carries the
    /// bare name.
    ///
    /// Restricted to the kinds whose sentence `pureSummary` actually builds
    /// AROUND a basename ("Edited <basename>" / "Read <basename>"). For any
    /// other kind the title's words are unrelated narration (a shell
    /// description, a search query), and a substring hit there is a
    /// coincidence, not doubling — e.g. an affected file literally named "test"
    /// must not be swallowed by the title "Run the npm tests".
    private static func echoNamesFile(_ echo: String, _ fileName: String, kind: AgentToolKind) -> Bool {
        guard kind.actionLineNamesABasename else { return false }
        let basename = fileName.split(separator: "/").last.map(String.init) ?? fileName
        guard !basename.isEmpty else { return false }
        return echo.contains(basename)
    }

    /// TR-01 — every file ONE operation touched, as the change card presents it.
    ///
    /// Two host-local sources describe the same operation and neither is
    /// sufficient alone. `affectedFiles` holds full URLs but arrives from the
    /// activity channel, which carries a SINGLE target — a codex change that
    /// rewrote four files landed here as one. `fileChanges` holds every file
    /// with its action and counts, but its paths were reduced to basenames at
    /// the privacy boundary. The card was built from `affectedFiles` alone,
    /// which is why a four-file change drew one row and why a claude edit whose
    /// path never resolved drew none at all.
    ///
    /// So: walk `fileChanges` in provider order, borrowing the richer display
    /// name from the matching URL when there is one, then append any URL no
    /// change claimed. Matching is by basename and each URL is consumed once,
    /// so two files with the same basename in different directories stay two
    /// rows.
    public static func observableChangedFiles(_ detail: AgentToolDetailRecord) -> [AgentDiffFileSummary] {
        var availableURLs = detail.affectedFiles
        var result: [AgentDiffFileSummary] = []
        for change in detail.fileChanges.prefix(maxObservableFiles) {
            guard !change.path.isEmpty else { continue }
            let changeBasename = change.path.split(separator: "/").last.map(String.init) ?? change.path
            let matchIndex = availableURLs.firstIndex { $0.lastPathComponent == changeBasename }
            let name: String
            if let matchIndex {
                name = abbreviatedFilePath(availableURLs.remove(at: matchIndex))
            } else {
                name = change.path
            }
            result.append(AgentDiffFileSummary(
                displayName: change.renamePath.map { "\(name) → \($0)" } ?? name,
                addedLineCount: change.addedLines,
                removedLineCount: change.removedLines,
                countsAreLowerBound: change.countsAreLowerBound,
                action: diffAction(change.action)
            ))
        }
        for url in availableURLs.prefix(max(0, maxObservableFiles - result.count)) {
            result.append(AgentDiffFileSummary(displayName: abbreviatedFilePath(url)))
        }
        return result
    }

    /// The store's own cap on how many rows one operation may publish. The card
    /// shows fewer and says "+N more"; this only stops an unbounded provider
    /// list from becoming unbounded presentation work.
    private static let maxObservableFiles = 24

    private static func diffAction(_ action: AgentToolDetailObservation.FileAction) -> AgentDiffFileAction {
        switch action {
        case .add: return .add
        case .edit: return .edit
        case .write: return .write
        case .delete: return .delete
        case .rename: return .rename
        case .unknown: return .unknown
        }
    }

    /// Display-only host-local file names for transcript composition. These are
    /// deliberately abbreviated before leaving the presenter so a renderer can
    /// never accidentally receive an absolute machine path.
    public static func observableAffectedFileNames(_ detail: AgentToolDetailRecord) -> [String] {
        detail.affectedFiles.prefix(6).map(abbreviatedFilePath)
    }

    public static func expanded(_ detail: AgentToolDetailRecord) -> AgentToolDetailExpandedPresentation {
        let status = statusText(detail.status)
        let exitText = detail.exitCode.map { "Exit \($0)" }
        let timing = detail.duration.map { "Duration \(formatDuration($0))" }
        return AgentToolDetailExpandedPresentation(
            header: compact(detail).summary,
            arguments: detail.arguments,
            output: detail.output,
            statusText: status,
            exitCodeText: exitText,
            timingText: timing,
            affectedFiles: detail.affectedFiles,
            accessibilitySummary: accessibilitySummary(for: detail, status: status)
        )
    }

    /// TR-03. The kind comes from `AgentToolKind`, the one classifier the icon
    /// and the fold noun also read, so a row can no longer be drawn as one kind
    /// of work and described as another.
    ///
    /// Every branch is CONDITIONAL on the datum it needs. It used to be enough
    /// for the tool NAME to look like an edit — a `TodoWrite` was titled "Edited
    /// file" though it touched no file at all, and any MCP tool whose name
    /// contained "create" would have joined it. A kind with nothing to say now
    /// falls through to the provider's own summary, and then to the tool name.
    private static func pureSummary(for detail: AgentToolDetailRecord) -> String? {
        // Array's own workspace tools: a fixed sentence per tool, named by the
        // `relativePath` basename the provider whitelists forward as `file`.
        if let tool = ArrayWorkspaceTool(toolName: safeToolName(detail.toolName)) {
            if tool == .boardApply { return boardChangeLine(detail) }
            return tool.actionLine(fileBasename: safeBasenameArgument(detail, keys: ["file", "relativepath"]))
        }
        // Someone else's MCP server: "Atlassian · Search Jira issues using JQL".
        // codex reports the server beside a bare tool name, as `server`.
        if let mcp = mcpToolName(detail) { return mcp.title }
        switch AgentToolKind.resolve(toolName: safeToolName(detail.toolName)) {
        case .shell:
            // A shell row with a command is titled by `shellInvocation` (see
            // `collapsed`) and never reaches here. What does is a shell whose
            // command did not cross, which keeps claude's `description` below.
            break
        case .search:
            if let query = safeArgument(detail, keys: ["query", "pattern", "regex", "search"]) {
                return "Searched for \u{201C}\(query)\u{201D}"
            }
        case .fetch:
            if let url = safeArgument(detail, keys: ["url"]) { return "Fetched \(url)" }
        case .edit:
            if let basename = affectedBasename(detail) ?? safeBasenameArgument(detail, keys: ["path", "file", "target"]) {
                return "Edited \(basename)"
            }
        case .read:
            if let basename = affectedBasename(detail) ?? safeBasenameArgument(detail, keys: ["path", "file"]) {
                return "Read \(basename)"
            }
        case .delegate:
            // The role, when the provider published one — claude sends
            // `subagent_type`, and a role id is publishable (`RoleRegistry`
            // reads them out of project files). The `description` below is the
            // richer line and wins when both are present.
            if let description = safeArgument(detail, keys: ["description"]) {
                return capitalizedPhrase(description)
            }
            if let role = safeArgument(detail, keys: ["subagenttype", "agent", "role"]) {
                return "Delegated to \(role)"
            }
        case .todo, .unknown:
            break
        }
        // `.plans/45` S3 — claude's Bash/Task `description` is the sanctioned
        // human summary and already reads as an action ("List files in the
        // build directory"); surface it capitalized rather than prefixed.
        if let description = safeArgument(detail, keys: ["description"]) {
            return capitalizedPhrase(description)
        }
        return nil
    }

    /// `.plans/45` S3 — the collapsed action-first row: the SENTENCE is the
    /// row ("Searched for \u{201C}...\u{201D}", "Edited Foo.swift"), with the duration for
    /// the trailing column. The tool name survives only as the fallback, and
    /// capitalized — pi reports names like "search" in lowercase (C6).
    public static func collapsed(_ detail: AgentToolDetailRecord) -> AgentToolDetailCollapsedPresentation {
        // A shell row is titled by what ran: claude's description when it gave
        // one (the renderer sets the command beside it), else the command.
        if let shell = shellInvocation(detail) {
            if !shell.command.isEmpty {
                return AgentToolDetailCollapsedPresentation(
                    actionLine: shell.description.map(capitalizedPhrase) ?? shell.headline,
                    durationText: shell.durationText)
            }
            // The command was withheld ("Show shell commands in transcripts" off,
            // or an old record): the row names the description or the tool, but
            // keeps the shell's own duration — the provider's measurement, and
            // none when there is nothing real to show.
            return AgentToolDetailCollapsedPresentation(
                actionLine: shortLine(
                    pureSummary(for: detail)
                        ?? capitalizedPhrase(AgentToolKind.humanizedToolName(safeToolName(detail.toolName)))
                ),
                durationText: shell.durationText)
        }
        return AgentToolDetailCollapsedPresentation(
            actionLine: shortLine(
                pureSummary(for: detail)
                    ?? capitalizedPhrase(AgentToolKind.humanizedToolName(safeToolName(detail.toolName)))
            ),
            durationText: detail.duration.map(formatDuration)
        )
    }

    /// Launch polish, item J — the one shell shape every harness's command row
    /// is drawn from. Nil for anything that is not a shell tool. A shell whose
    /// command never crossed (an old record, a redacted key) still gets a
    /// shape, with an empty command, so its exit status is still told the same
    /// way.
    public static func shellInvocation(_ detail: AgentToolDetailRecord) -> AgentShellInvocation? {
        guard AgentToolKind.resolve(toolName: safeToolName(detail.toolName)) == .shell else { return nil }
        func argument(_ key: String) -> String? {
            detail.arguments.first { $0.key == key && !$0.sensitiveKeyFiltered }
                .map { $0.value.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        let status: AgentShellStatus
        switch detail.status {
        case .pending, .inProgress:
            status = .running
        case .interrupted, .cancelled:
            status = detail.shellOutcome ?? .interrupted
        case .completed, .failed:
            if let outcome = detail.shellOutcome {
                status = outcome
            } else if let exitCode = detail.exitCode, exitCode != 0 {
                status = .failed
            } else {
                status = detail.status == .failed ? .failed : .succeeded
            }
        }
        return AgentShellInvocation(
            command: argument(AgentToolDetailObservation.shellCommandKey) ?? "",
            description: safeArgument(detail, keys: ["description"]),
            cwd: argument(AgentToolDetailObservation.shellCwdKey),
            output: detail.output?.text,
            exitCode: detail.exitCode,
            duration: detail.measuredDuration,
            status: status)
    }

    private static func mcpToolName(_ detail: AgentToolDetailRecord) -> MCPToolName? {
        let name = safeToolName(detail.toolName)
        guard ArrayWorkspaceTool(toolName: name) == nil else { return nil }
        return MCPToolName(toolName: name, server: safeArgument(detail, keys: ["server"]))
    }

    /// The one argument an MCP row shows under its title, in order of how much
    /// it says. A path never shows (the disclosure rule); a web URL may.
    private static let mcpPrimaryArgumentKeys = ["jql", "cql", "query", "q", "search", "issuekey", "issueidorkey", "url"]

    private static func mcpPrimaryArgument(_ detail: AgentToolDetailRecord) -> (key: String, value: String)? {
        for key in mcpPrimaryArgumentKeys {
            guard let argument = detail.arguments.first(where: {
                $0.key.lowercased().filter { $0.isLetter || $0.isNumber } == key
            }), let value = safeArgument(detail, keys: [key]) else { continue }
            let isWebURL = value.hasPrefix("https://") || value.hasPrefix("http://")
            guard isWebURL || !isPathBearingObservableValue(value) else { continue }
            return (argument.key, value)
        }
        return nil
    }

    /// `array_board_apply`'s sentence from the op and the names the host's reply
    /// carries. The reply is read only when it arrived whole: a clipped or
    /// redacted reply is not half-parsed into a name.
    private static func boardChangeLine(_ detail: AgentToolDetailRecord) -> String {
        var result: [String: Any]?
        if let output = detail.output, !output.truncatedByBytes, !output.truncatedByLines, !output.redacted,
           let object = (try? JSONSerialization.jsonObject(with: Data(output.text.utf8))) as? [String: Any],
           object["status"] as? String == "ok" {
            result = object["result"] as? [String: Any]
        }
        func name(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.contains("[REDACTED]") else { return nil }
            return text
        }
        let op = name(result?["op"]) ?? safeArgument(detail, keys: ["op"])
        let card = result?["card"] as? [String: Any]
        let inputTitle = (op == "create" || op == "edit") ? safeArgument(detail, keys: ["title"]) : nil
        return ArrayWorkspaceTool.boardChangeLine(
            op: op,
            cardTitle: name(result?["cardTitle"]) ?? name(card?["title"]) ?? inputTitle,
            columnName: name(result?["columnName"]),
            assigneeName: name(result?["assigneeName"]))
    }

    private static func capitalizedPhrase(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    private static func shortLine(_ raw: String, maxBytes: Int = 180) -> String {
        let normalized = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard normalized.utf8.count > maxBytes else { return normalized }
        let marker = "…"
        let budget = maxBytes - marker.utf8.count
        var prefix = ""
        var count = 0
        for character in normalized {
            let bytes = String(character).utf8.count
            guard count + bytes <= budget else { break }
            prefix.append(character)
            count += bytes
        }
        return prefix + marker
    }

    private static func safeArgument(_ detail: AgentToolDetailRecord, keys: Set<String>) -> String? {
        detail.arguments.first { argument in
            keys.contains(argument.key.lowercased().filter { $0.isLetter || $0.isNumber }) &&
            !argument.sensitiveKeyFiltered &&
            !argument.value.redacted &&
            !argument.value.text.contains("[REDACTED]") &&
            !argument.value.text.contains("[truncated]")
        }?.value.text
    }

    private static func safeBasenameArgument(_ detail: AgentToolDetailRecord, keys: Set<String>) -> String? {
        guard let value = safeArgument(detail, keys: keys) else { return nil }
        let basename = URL(fileURLWithPath: value).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    private static func affectedBasename(_ detail: AgentToolDetailRecord) -> String? {
        guard let url = detail.affectedFiles.first else { return nil }
        let basename = url.lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    private static func abbreviatedFilePath(_ file: URL) -> String {
        let components = file.standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard let basename = components.last else { return "File" }
        guard components.count > 1 else { return basename }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private static func isPathBearingObservableValue(_ value: String) -> Bool {
        value.contains("/") || value.contains("\\") || value.contains("://") || value.hasPrefix("~")
    }

    private static func statusText(_ status: AgentItemStatus) -> String {
        switch status {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 10 {
            return String(format: "%.1fs", duration)
        }
        return "\(Int(duration.rounded()))s"
    }

    private static func accessibilitySummary(for detail: AgentToolDetailRecord, status: String) -> String {
        let safeName = safeToolName(detail.toolName)
        var parts = safeName == "Tool" ? ["Tool details", status] : ["Tool", safeName, status]
        if let duration = detail.duration { parts.append("duration \(formatDuration(duration))") }
        if detail.output != nil { parts.append("output available") }
        if !detail.arguments.isEmpty { parts.append("\(detail.arguments.count) arguments") }
        if !detail.affectedFiles.isEmpty { parts.append("\(detail.affectedFiles.count) affected files") }
        return parts.joined(separator: ", ")
    }
}
