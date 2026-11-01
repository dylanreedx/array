import ContinuumRevivedAgentUI
import Foundation

// Plan: .plans/110-agent-characters/README.md, slice 2 (§2.3 "action from the
// latest tool step", §4.1)
/// What a character needs from an agent's turn, from the facts Array already keeps.
public enum AgentCharacterActivityProjection {
    /// The loop a tool step acts out. Claude's built-in tools reach Array as tool
    /// calls or commands titled with the tool's name, pi's with lowercase names,
    /// and Codex's commands with the command line, so the title decides once the
    /// kind alone cannot.
    public static func action(kind: ItemKind, title: String?) -> AgentCharacterLoop {
        switch kind {
        case .fileChange: return .type
        case .webSearch: return .dabble
        case .reasoning, .plan, .assistantMessage, .subagent, .compaction, .error: return .think
        case .commandExecution: return commandAction(title)
        case .mcpToolCall, .unknown: return toolAction(title)
        }
    }

    /// A command line: what its program does. A bare tool name ("Bash") runs.
    static func commandAction(_ title: String?) -> AgentCharacterLoop {
        let words = (title ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        // Skip `cd dir &&`-style prefixes and env assignments to reach the program.
        var index = 0
        while index < words.count, words[index].contains("=") && !words[index].hasPrefix("-") { index += 1 }
        guard index < words.count else { return .run }
        let program = (words[index] as NSString).lastPathComponent.lowercased()
        switch program {
        case "rg", "grep", "egrep", "fgrep", "ag", "ack", "find", "fd", "ls", "tree", "glob", "locate":
            return .dabble
        case "cat", "head", "tail", "less", "more", "bat", "nl", "wc":
            return .read
        case "sed" where words.dropFirst(index + 1).first == "-n":
            return .read
        default:
            return toolAction(words[index]) == .think ? .run : toolAction(words[index])
        }
    }

    /// A named tool: its kind, by the one tool classifier the transcript uses.
    static func toolAction(_ title: String?) -> AgentCharacterLoop {
        switch AgentToolKind.resolve(toolName: title?.split(whereSeparator: \.isWhitespace).first.map(String.init)) {
        case .edit: return .type
        case .read: return .read
        case .search, .fetch: return .dabble
        case .shell: return .run
        case .todo, .delegate: return .think
        case .unknown:
            let text = title ?? ""
            if ["Searching", "Looking", "Listing"].contains(where: { text.hasPrefix($0) }) { return .dabble }
            if text.hasPrefix("Reading") { return .read }
            return .think
        }
    }

    /// The character's view of an agent: the live turn when there is one, the
    /// durable terminal event and prompt stamp otherwise.
    public static func activity(presence: AgentTurnPresence?, terminalEvent: AgentTerminalEvent?,
                                latestPromptAt: Date?) -> AgentCharacterActivity {
        var activity = AgentCharacterActivity()
        // The record's prompt stamp is the person pressing Return. The presence's
        // `submittedAt` is also the provider's own start for a turn it began by
        // itself, which is not a prompt to notice, so it is not read here.
        activity.promptSentAt = latestPromptAt
        if let presence {
            let step: AgentTurnPresence.Tool?
            if case let .tool(open) = presence.phase { step = open } else { step = presence.lastTool }
            activity.action = step.map { action(kind: $0.kind, title: $0.title) }
            activity.lastOutputAt = presence.lastProviderActivityAt ?? presence.turnStartedAt
            activity.stepFailedAt = presence.lastStepFailedAt
            switch presence.phase {
            case let .settled(cause):
                activity.outcome = cause == .completed ? .succeeded : .stopped
                activity.endedAt = presence.settledAt
            case .failed:
                activity.outcome = .failed
                activity.endedAt = presence.settledAt
            case .idle, .starting, .thinking, .tool, .writing:
                break
            }
        }
        if activity.outcome == nil, let terminalEvent {
            switch terminalEvent.outcome {
            case .succeeded: activity.outcome = .succeeded
            case .failed, .runtimeError: activity.outcome = .failed
            case .interrupted, .cancelled: activity.outcome = .stopped
            }
            activity.endedAt = terminalEvent.endedAt
        }
        return activity
    }
}
