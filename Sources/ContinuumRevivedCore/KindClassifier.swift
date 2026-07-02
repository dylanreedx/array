import Foundation

public struct KindClassifier: Sendable {
    public init() {}

    public func classify(
        windowTarget: String,
        using control: any TmuxControl
    ) async throws -> AgentKind {
        let command = try await control.paneCurrentCommand(paneTarget: windowTarget)
        return AgentKind.from(processName: command)
    }
}

extension AgentKind {
    public static func from(processName raw: String) -> AgentKind {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "claude":
            return .claude
        case "pi":
            return .pi
        case "codex":
            return .codex
        case "node":
            return .unknown
        case "zsh", "bash", "fish", "sh":
            return .shell
        default:
            return .unknown
        }
    }
}
