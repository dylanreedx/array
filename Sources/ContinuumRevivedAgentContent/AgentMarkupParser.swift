import Foundation

/// Parser-owned diagnostic vocabulary. Parser adapters report safe structural
/// facts here; third-party AST nodes and provider source never escape through it.
public struct AgentMarkupDiagnostic: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Equatable, Sendable {
        case warning
        case error
    }

    public var severity: Severity
    public var code: String
    public var sourceRange: AgentSourceRange?

    public init(severity: Severity, code: String, sourceRange: AgentSourceRange? = nil) {
        self.severity = severity
        self.code = code
        self.sourceRange = sourceRange
    }
}

/// Platform-neutral result of parsing one markup entry.
public struct AgentMarkupParse: Codable, Equatable, Sendable {
    public var blocks: [AgentBlock]
    public var diagnostics: [AgentMarkupDiagnostic]

    public init(blocks: [AgentBlock], diagnostics: [AgentMarkupDiagnostic] = []) {
        self.blocks = blocks
        self.diagnostics = diagnostics
    }
}

/// Owned seam between provider markup and the semantic AgentContent document.
/// Implementations may use a third-party parser internally, but its AST must not
/// appear in this protocol or in `AgentMarkupParse`.
public protocol AgentMarkupParsing: Sendable {
    func parse(_ source: String, entryID: AgentNodeID, previous: [AgentBlock]) -> AgentMarkupParse
}
