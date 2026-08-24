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

    public init(
        maxToolNameBytes: Int = 160,
        maxArgumentKeyBytes: Int = 256,
        maxFieldValueBytes: Int = 2_048,
        maxFieldValueLines: Int = 8,
        maxOutputBytes: Int = 16_384,
        maxOutputLines: Int = 200,
        maxArguments: Int = 100,
        maxAffectedFiles: Int = 50
    ) {
        self.maxToolNameBytes = max(16, maxToolNameBytes)
        self.maxArgumentKeyBytes = max(16, maxArgumentKeyBytes)
        self.maxFieldValueBytes = max(16, maxFieldValueBytes)
        self.maxFieldValueLines = max(1, maxFieldValueLines)
        self.maxOutputBytes = max(16, maxOutputBytes)
        self.maxOutputLines = max(1, maxOutputLines)
        self.maxArguments = max(0, maxArguments)
        self.maxAffectedFiles = max(0, maxAffectedFiles)
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
    /// Provider-authored timestamp. Retention/expiry uses host observation time,
    /// not this value.
    public var startedAt: Date?
    public var explicitSecrets: [String]

    public init(
        identity: AgentToolDetailKey,
        toolName: String,
        arguments: [AgentToolDetailField] = [],
        affectedFiles: [URL] = [],
        startedAt: Date? = nil,
        explicitSecrets: [String] = []
    ) {
        self.identity = identity
        self.toolName = toolName
        self.arguments = arguments
        self.affectedFiles = affectedFiles
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

    public init(
        identity: AgentToolDetailKey,
        output: String? = nil,
        status: AgentItemStatus,
        exitCode: Int? = nil,
        affectedFiles: [URL] = [],
        endedAt: Date? = nil,
        explicitSecrets: [String] = []
    ) {
        self.identity = identity
        self.output = output
        self.status = status
        self.exitCode = exitCode
        self.affectedFiles = affectedFiles
        self.endedAt = endedAt
        self.explicitSecrets = explicitSecrets
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

    var sensitiveStartFingerprints: Set<String>
    var latestEndExplicitFingerprints: Set<String>
    var latestStartTimestamp: Date?
    var latestEndTimestamp: Date?
    // Equal/missing provider timestamps use these canonical payload keys. The
    // lexicographically larger key wins; identical keys are idempotent.
    var latestStartTieKey: String?
    var latestEndTieKey: String?

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
        affectedFiles: [URL] = [],
        sensitiveStartFingerprints: Set<String> = [],
        latestEndExplicitFingerprints: Set<String> = [],
        latestStartTimestamp: Date? = nil,
        latestEndTimestamp: Date? = nil,
        latestStartTieKey: String? = nil,
        latestEndTieKey: String? = nil
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
        self.sensitiveStartFingerprints = sensitiveStartFingerprints
        self.latestEndExplicitFingerprints = latestEndExplicitFingerprints
        self.latestStartTimestamp = latestStartTimestamp
        self.latestEndTimestamp = latestEndTimestamp
        self.latestStartTieKey = latestStartTieKey
        self.latestEndTieKey = latestEndTieKey
    }

    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
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
            return AgentToolDetailArgument(
                key: key,
                value: boundText(
                    redacted,
                    maxBytes: limits.maxFieldValueBytes,
                    maxLines: limits.maxFieldValueLines,
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
        affectedFiles: [URL]
    ) -> String {
        stableKey([
            stableTextKey(output),
            status.rawValue,
            exitCode.map(String.init) ?? "",
            affectedFiles.map(\.absoluteString).sorted().joined(separator: "\u{1f}")
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
        return digest.map { String(format: "%02x", $0) }.joined()
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
        let tieKey = sanitizer.stableStartTieKey(
            toolName: sanitizedToolName,
            arguments: sanitizedArguments,
            affectedFiles: sanitizedFiles
        )
        let existing = details[start.identity]
        var record = existing ?? AgentToolDetailRecord(identity: start.identity, updatedAt: observedAt)
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
            record.sensitiveStartFingerprints = sensitiveFingerprints
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
            record.sensitiveStartFingerprints.formUnion(sensitiveFingerprints)
            if record.output != nil,
               !record.sensitiveStartFingerprints.isSubset(of: record.latestEndExplicitFingerprints) {
                record.output = sanitizer.redactionUnavailableOutput()
            }
        }
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
            affectedFiles: sanitizedFiles
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
        var lines = [observableSummary(detail)]
        let fileLabel = observableFileAction(detail.toolName)
        for fileName in observableAffectedFileNames(detail) {
            lines.append("\(fileLabel): \(fileName)")
        }
        for argument in detail.arguments.prefix(4)
        where !argument.sensitiveKeyFiltered && !argument.value.redacted {
            let value = shortLine(argument.value.text)
            guard !value.isEmpty, !value.contains("[REDACTED]"),
                  !isPathBearingObservableValue(value) else { continue }
            lines.append("\(shortLine(argument.key, maxBytes: 48)): \(value)")
        }
        if let exitCode = detail.exitCode { lines.append("Exit code: \(exitCode)") }
        if let duration = detail.duration { lines.append("Duration: \(formatDuration(duration))") }
        return lines.prefix(12).joined(separator: "\n")
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

    private static func pureSummary(for detail: AgentToolDetailRecord) -> String? {
        let normalizedTool = safeToolName(detail.toolName).lowercased().filter { $0.isLetter || $0.isNumber }
        if let command = safeArgument(detail, keys: ["command", "cmd", "shellcommand"]),
           ["bash", "shell", "sh", "zsh", "command", "run"].contains(where: { normalizedTool.contains($0) }) {
            return "Ran \(command)"
        }
        if let query = safeArgument(detail, keys: ["query", "pattern", "regex", "search"]),
           ["grep", "search", "rg", "glob", "find"].contains(where: { normalizedTool.contains($0) }) {
            return "Searched for \u{201C}\(query)\u{201D}"
        }
        if let url = safeArgument(detail, keys: ["url"]),
           ["fetch", "web"].contains(where: { normalizedTool.contains($0) }) {
            return "Fetched \(url)"
        }
        if ["edit", "write", "patch"].contains(where: { normalizedTool.contains($0) }) {
            if let basename = affectedBasename(detail) ?? safeBasenameArgument(detail, keys: ["path", "file", "target"]) {
                return "Edited \(basename)"
            }
            return "Edited file"
        }
        if ["read", "open", "cat"].contains(where: { normalizedTool.contains($0) }) {
            if let basename = affectedBasename(detail) ?? safeBasenameArgument(detail, keys: ["path", "file"]) {
                return "Read \(basename)"
            }
            return "Read file"
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
        AgentToolDetailCollapsedPresentation(
            actionLine: shortLine(pureSummary(for: detail) ?? capitalizedPhrase(safeToolName(detail.toolName))),
            durationText: detail.duration.map(formatDuration)
        )
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

    private static func observableFileAction(_ toolName: String) -> String {
        let tool = safeToolName(toolName).lowercased().filter { $0.isLetter || $0.isNumber }
        if ["read", "open", "cat"].contains(where: { tool.contains($0) }) { return "Read" }
        if ["edit", "write", "patch"].contains(where: { tool.contains($0) }) { return "Changed" }
        if ["grep", "search", "find", "glob"].contains(where: { tool.contains($0) }) { return "Searched in" }
        return "File"
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
