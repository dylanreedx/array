import Foundation
import ContinuumRevivedAgentContent

/// The visible, bounded result of the host's tool-detail presenter. This is
/// distinct from a detail record: provider identities, file URLs, arguments
/// that are not shown, and sanitizer bookkeeping never cross this boundary.
public enum SharedAgentToolPresentation: Codable, Equatable, Sendable {
    public struct Shell: Codable, Equatable, Sendable {
        public var command: String
        public var description: String?
        public var cwd: String?
        public var output: String?
        public var sharesOutput: Bool
        public var exitCode: Int?
        public var duration: TimeInterval?
        public var status: String

        init(_ shell: AgentShellInvocation, sharedOutput: String?) {
            command = shell.command; description = shell.description; cwd = shell.cwd
            sharesOutput = shell.output != nil && shell.output == sharedOutput
            output = sharesOutput ? nil : shell.output
            exitCode = shell.exitCode; duration = shell.duration; status = shell.status.rawValue
        }
        func invocation(sharedOutput: String?) -> AgentShellInvocation? {
            guard let status = AgentShellStatus(rawValue: status) else { return nil }
            return AgentShellInvocation(command: command, description: description, cwd: cwd,
                                        output: sharesOutput ? sharedOutput : output, exitCode: exitCode, duration: duration, status: status)
        }
    }
    public struct Tool: Codable, Equatable, Sendable {
        public var name: String
        public var summary: String?
        public var toolName: String?
        public var duration: String?
        public var output: String?
        public var outputNote: String?
        public var shell: Shell?
    }
    public struct Diff: Codable, Equatable, Sendable {
        public var files: [AgentDiffFileSummary]
        public var pending: Bool
        public var totalLines: Int?
    }
    case tool(Tool)
    case diff(Diff)

    /// Call with the host view's *presented* block, after its detail store has
    /// sanitized and bounded the provider observation.
    public init?(presented block: AgentBlock) {
        switch block.payload {
        case let .toolCall(tool):
            self = .tool(Tool(name: tool.name, summary: tool.summary, toolName: tool.presentedToolNameText,
                              duration: tool.presentedTrailingDetailText, output: tool.presentedOutputText,
                              outputNote: tool.presentedOutputNote, shell: tool.presentedShell.map { Shell($0, sharedOutput: tool.presentedOutputText) }))
        case let .diff(diff):
            self = .diff(Diff(files: SharedAgentTranscriptSafeBudget.visibleFiles(diff.files), pending: diff.presentedFilesArePending,
                              totalLines: diff.presentedTotalLines))
        default: return nil
        }
    }

    /// Reconstitute the view-only fields on a copy. The semantic document and
    /// its identities are not changed, and the guest retains disclosure state.
    public func applying(to block: AgentBlock) -> AgentBlock {
        var copy = block
        switch (self, block.payload) {
        case let (.tool(value), .toolCall(original)):
            var tool = original
            tool.name = value.name; tool.summary = value.summary
            tool.presentedToolNameText = value.toolName; tool.presentedTrailingDetailText = value.duration
            tool.presentedOutputText = value.output; tool.presentedOutputNote = value.outputNote
            tool.presentedShell = value.shell?.invocation(sharedOutput: value.output)
            copy.payload = .toolCall(tool)
        case let (.diff(value), .diff(original)):
            var diff = original
            diff.files = value.files; diff.presentedFilesArePending = value.pending
            diff.presentedTotalLines = value.totalLines
            copy.payload = .diff(diff)
        default: break
        }
        return copy
    }
}
