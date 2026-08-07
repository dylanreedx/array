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
    public var providerItemID: AgentToolDetailID
    public var toolName: String
    public var arguments: [AgentToolDetailField]
    public var affectedFiles: [URL]
    /// Provider-authored timestamp. Retention/expiry uses host observation time,
    /// not this value.
    public var startedAt: Date?
    public var explicitSecrets: [String]

    public init(
        providerItemID: AgentToolDetailID,
        toolName: String,
        arguments: [AgentToolDetailField] = [],
        affectedFiles: [URL] = [],
        startedAt: Date? = nil,
        explicitSecrets: [String] = []
    ) {
        self.providerItemID = providerItemID
        self.toolName = toolName
        self.arguments = arguments
        self.affectedFiles = affectedFiles
        self.startedAt = startedAt
        self.explicitSecrets = explicitSecrets
    }
}

public struct AgentToolDetailEnd: Equatable, Sendable {
    public var providerItemID: AgentToolDetailID
    public var output: String?
    public var status: AgentItemStatus
    public var exitCode: Int?
    public var affectedFiles: [URL]
    /// Provider-authored timestamp. Retention/expiry uses host observation time,
    /// not this value.
    public var endedAt: Date?
    public var explicitSecrets: [String]

    public init(
        providerItemID: AgentToolDetailID,
        output: String? = nil,
        status: AgentItemStatus,
        exitCode: Int? = nil,
        affectedFiles: [URL] = [],
        endedAt: Date? = nil,
        explicitSecrets: [String] = []
    ) {
        self.providerItemID = providerItemID
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
    public var providerItemID: AgentToolDetailID
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

    public init(
        providerItemID: AgentToolDetailID,
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
        latestEndTimestamp: Date? = nil
    ) {
        self.providerItemID = providerItemID
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
    }

    public var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

public struct AgentToolDetailSanitizer: Sendable {
    public static let redactionUnavailableMarker = "[redaction unavailable: output omitted]"

    public var limits: AgentToolDetailLimits

    public init(limits: AgentToolDetailLimits = AgentToolDetailLimits()) {
        self.limits = limits
    }

    func sanitizeToolName(_ raw: String, explicitSecrets: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Tool" : trimmed
        return boundText(
            SecretRedactor.redact(Self.singleLine(candidate), explicitSecrets: explicitSecrets),
            maxBytes: limits.maxToolNameBytes,
            maxLines: 1,
            redacted: false
        ).text
    }

    func sanitizeArguments(_ fields: [AgentToolDetailField], explicitSecrets: [String]) -> [AgentToolDetailArgument] {
        guard limits.maxArguments > 0 else { return [] }
        let clippedFields = Array(fields.prefix(limits.maxArguments))
        let secrets = explicitSecrets + Self.sensitiveValues(in: clippedFields)
        return clippedFields.map { field in
            let key = Self.sanitizedKey(field.key, explicitSecrets: secrets, maxBytes: limits.maxArgumentKeyBytes)
            if Self.isSensitiveKey(key) || Self.isSensitiveKey(field.key) {
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
        Set((explicitSecrets + Self.sensitiveValues(in: fields)).compactMap(Self.fingerprint))
    }

    func explicitFingerprints(_ explicitSecrets: [String]) -> Set<String> {
        Set(explicitSecrets.compactMap(Self.fingerprint))
    }

    func sanitizeOutput(
        _ raw: String?,
        explicitSecrets: [String],
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
        let redacted = SecretRedactor.redact(raw, explicitSecrets: explicitSecrets + filteredArgumentMarkers)
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
            guard let sanitized = Self.sanitizedFileURL(file, explicitSecrets: explicitSecrets) else { continue }
            let path = sanitized.path
            guard seen.insert(path).inserted else { continue }
            result.append(sanitized)
            if result.count >= limits.maxAffectedFiles { break }
        }
        return result
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

    private static func sensitiveValues(in fields: [AgentToolDetailField]) -> [String] {
        fields.compactMap { field in
            guard isSensitiveKey(field.key) else { return nil }
            let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        let sensitiveFragments = [
            "password", "passwd", "pwd", "secret", "token", "apikey", "authorization",
            "auth", "credential", "credentials", "cookie", "session", "signin", "signing",
            "signature", "private", "privatekey", "access", "accesskey", "refreshkey", "clientsecret",
            "sshkey", "jwt", "bearer"
        ]
        return sensitiveFragments.contains { normalized.contains($0) }
    }

    private static func fingerprint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var data = Data("AgentToolDetailStore.secret.v1\0".utf8)
        data.append(Data(trimmed.utf8))
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedFileURL(_ file: URL, explicitSecrets: [String]) -> URL? {
        guard file.isFileURL else { return nil }
        var path = file.standardizedFileURL.path
        path = SecretRedactor.redact(path, explicitSecrets: explicitSecrets)
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
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
    private var details: [AgentToolDetailID: AgentToolDetailRecord] = [:]
    private let clock: @Sendable () -> Date
    private let timeToLive: TimeInterval
    private let sanitizer: AgentToolDetailSanitizer

    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        timeToLive: TimeInterval = 60 * 60,
        limits: AgentToolDetailLimits = AgentToolDetailLimits()
    ) {
        self.clock = clock
        self.timeToLive = max(0, timeToLive)
        self.sanitizer = AgentToolDetailSanitizer(limits: limits)
    }

    @discardableResult
    public func recordStart(_ start: AgentToolDetailStart) -> AgentToolDetailRecord {
        let observedAt = clock()
        let eventTimestamp = start.startedAt ?? observedAt
        let existing = details[start.providerItemID]
        var record = existing ?? AgentToolDetailRecord(providerItemID: start.providerItemID, updatedAt: observedAt)
        let shouldApplyStart = record.latestStartTimestamp.map { eventTimestamp > $0 } ?? true
        if shouldApplyStart {
            record.toolName = sanitizer.sanitizeToolName(start.toolName, explicitSecrets: start.explicitSecrets)
            record.arguments = sanitizer.sanitizeArguments(start.arguments, explicitSecrets: start.explicitSecrets)
            record.startedAt = eventTimestamp
            record.latestStartTimestamp = eventTimestamp
            record.sensitiveStartFingerprints = sanitizer.sensitiveFingerprints(in: start.arguments, explicitSecrets: start.explicitSecrets)
            if record.output != nil,
               !record.sensitiveStartFingerprints.isSubset(of: record.latestEndExplicitFingerprints) {
                record.output = sanitizer.redactionUnavailableOutput()
            }
        } else if record.startedAt == nil {
            record.startedAt = eventTimestamp
        }
        record.updatedAt = observedAt
        record.affectedFiles = sanitizer.sanitizeFiles(start.affectedFiles, existing: record.affectedFiles, explicitSecrets: start.explicitSecrets)
        details[start.providerItemID] = record
        return record
    }

    @discardableResult
    public func recordEnd(_ end: AgentToolDetailEnd) -> AgentToolDetailRecord {
        let observedAt = clock()
        let eventTimestamp = end.endedAt ?? observedAt
        let existing = details[end.providerItemID]
        var record = existing ?? AgentToolDetailRecord(providerItemID: end.providerItemID, updatedAt: observedAt)
        let shouldApplyEnd = record.latestEndTimestamp.map { eventTimestamp > $0 } ?? true
        if shouldApplyEnd {
            record.output = sanitizer.sanitizeOutput(
                end.output,
                explicitSecrets: end.explicitSecrets,
                requiredStartFingerprints: record.sensitiveStartFingerprints,
                associatedArguments: record.arguments
            )
            record.status = end.status
            record.exitCode = end.exitCode
            record.endedAt = eventTimestamp
            record.latestEndTimestamp = eventTimestamp
            record.latestEndExplicitFingerprints = sanitizer.explicitFingerprints(end.explicitSecrets)
        } else if record.endedAt == nil {
            record.endedAt = eventTimestamp
        }
        record.updatedAt = observedAt
        record.affectedFiles = sanitizer.sanitizeFiles(end.affectedFiles, existing: record.affectedFiles, explicitSecrets: end.explicitSecrets)
        details[end.providerItemID] = record
        return record
    }

    public func detail(for providerItemID: AgentToolDetailID) -> AgentToolDetailRecord? {
        expireLocked(at: clock())
        return details[providerItemID]
    }

    public func allDetails() -> [AgentToolDetailRecord] {
        expireLocked(at: clock())
        return details.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.providerItemID.rawValue < rhs.providerItemID.rawValue }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    @discardableResult
    public func expireNow() -> [AgentToolDetailID] {
        expireLocked(at: clock())
    }

    @discardableResult
    private func expireLocked(at now: Date) -> [AgentToolDetailID] {
        guard timeToLive >= 0 else { return [] }
        let expired = details
            .filter { now.timeIntervalSince($0.value.updatedAt) > timeToLive }
            .map { $0.key }
            .sorted { $0.rawValue < $1.rawValue }
        for key in expired { details.removeValue(forKey: key) }
        return expired
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
    public static func compact(_ detail: AgentToolDetailRecord) -> AgentToolDetailCompactPresentation {
        let status = statusText(detail.status)
        let duration = detail.duration.map(formatDuration)
        let fileText: String? = detail.affectedFiles.isEmpty ? nil : "\(detail.affectedFiles.count) file\(detail.affectedFiles.count == 1 ? "" : "s")"
        let coreSummary = pureSummary(for: detail) ?? detail.toolName
        let suffix = [status, duration, fileText].compactMap { $0 }.joined(separator: " · ")
        let summary = suffix.isEmpty ? coreSummary : "\(coreSummary) · \(suffix)"
        return AgentToolDetailCompactPresentation(
            title: detail.toolName,
            statusText: status,
            summary: summary,
            accessibilitySummary: accessibilitySummary(for: detail, status: status)
        )
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
        let normalizedTool = detail.toolName.lowercased().filter { $0.isLetter || $0.isNumber }
        if let command = safeArgument(detail, keys: ["command", "cmd", "shellcommand"]),
           ["bash", "shell", "sh", "zsh", "command", "run"].contains(where: { normalizedTool.contains($0) }) {
            return "Ran \(command)"
        }
        if let query = safeArgument(detail, keys: ["query", "pattern", "regex", "search"]),
           ["grep", "search", "rg"].contains(where: { normalizedTool.contains($0) }) {
            return "Searched for \(query)"
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
        return nil
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
        var parts = ["Tool", detail.toolName, status]
        if let duration = detail.duration { parts.append("duration \(formatDuration(duration))") }
        if detail.output != nil { parts.append("output available") }
        if !detail.arguments.isEmpty { parts.append("\(detail.arguments.count) arguments") }
        if !detail.affectedFiles.isEmpty { parts.append("\(detail.affectedFiles.count) affected files") }
        return parts.joined(separator: ", ")
    }
}
