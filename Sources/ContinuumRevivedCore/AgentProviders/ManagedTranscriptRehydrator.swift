import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import Foundation

// Plan: .plans/03-transcript-rehydration.md (transcript rehydration on resume).
//
// When a managed-agent tile is restored across a relaunch the agent RECORD and
// the provider CONVERSATION both survive (continuity is derived from the agent
// id), but the desktop transcript is gone — it lived only in the view. This
// rehydrator reads the previous session's transcript from the provider's own
// session `.jsonl` and reconstructs the sequence of `AgentRuntimeEvent`s (plus
// the user's own prompts) that the tile's projection already knows how to
// render. No new content-rendering path: the same block renderers rebuild.
//
// DISPLAY-ONLY, NEVER RE-SYNC (I5). The provider translators
// (`PiEventTranslator`, `ClaudeEventTranslator`) DROP message bodies because
// their output crosses the companion sync boundary. Rehydration deliberately
// RESTORES bodies, so the reconstructed steps are for LOCAL display only: the
// supervisor seeds them into a display-history buffer the tile reads directly,
// never through `deliver`/`events(for:)`, so they are never re-published to the
// syncable activity timeline (`managedAgentActivityByAgent` /
// `ManagedAgentActivityBridge`). See `AgentSupervisor.seedRehydratedTranscript`.
//
// The pure parse (line-in → steps-out) is cross-platform and pinned in the
// matrix against fixtures captured live 2026-08-09. Only the file locate/read is
// macOS-gated: Core is shared with iOS, which has no filesystem-home APIs.

/// One reconstructed step of a prior conversation. A user prompt is not a
/// provider `AgentRuntimeEvent` (the projection routes prompts through
/// `appendUserPrompt`, and there is no user `ContentStreamKind`), so the two
/// cases are kept distinct and replayed through their matching projection seam.
public enum RehydratedTranscriptStep: Equatable, Sendable {
    case userPrompt(String)
    case event(AgentRuntimeEvent)
}

/// The reconstructed prior conversation, bounded and self-describing. `steps`
/// replay in order; `restoredMessageCount` counts the conversational messages
/// (user + assistant) actually kept; `omittedEarlier` is true when a cap or a
/// byte-truncated read dropped earlier history — surfaced in the boundary notice
/// so nothing is silently lost (AGENTS.md "no silent caps").
public struct RehydratedTranscript: Equatable, Sendable {
    public var steps: [RehydratedTranscriptStep]
    public var restoredMessageCount: Int
    public var omittedEarlier: Bool

    public init(steps: [RehydratedTranscriptStep], restoredMessageCount: Int, omittedEarlier: Bool) {
        self.steps = steps
        self.restoredMessageCount = restoredMessageCount
        self.omittedEarlier = omittedEarlier
    }

    /// The boundary card that leads the rehydrated cards, so the restored
    /// history is legible and clearly separated from the live turns that append
    /// below it.
    public var boundaryNoticeText: String {
        let noun = restoredMessageCount == 1 ? "message" : "messages"
        let base = "Previous session — \(restoredMessageCount) \(noun) restored"
        return omittedEarlier ? base + " · earlier history not shown" : base
    }

    /// Convenience for tests: the events (dropping the user-prompt steps).
    public var events: [AgentRuntimeEvent] {
        steps.compactMap { if case let .event(event) = $0 { return event } else { return nil } }
    }
}

/// Caps on how much prior history a rehydrate replays. Session files reach
/// hundreds of messages; a bounded read keeps the tile responsive and the
/// off-main read cheap.
public struct RehydrationLimits: Equatable, Sendable {
    /// Most recent normalized messages kept (user/assistant/toolResult).
    public var maxMessages: Int
    /// Tail bytes read from the session file. A larger file is truncated and
    /// the truncation is surfaced (`omittedEarlier`).
    public var maxBytes: Int

    public init(maxMessages: Int = 80, maxBytes: Int = 512 * 1024) {
        self.maxMessages = maxMessages
        self.maxBytes = maxBytes
    }
}

/// Provider-neutral intermediate the two readers normalize into, so the
/// turn-boundary/cap assembly has exactly one definition.
struct NormalizedTranscriptMessage: Equatable {
    enum Role: Equatable { case userPrompt, assistant, toolResult, compaction }
    struct ToolCall: Equatable { var id: String; var name: String; var detail: String? = nil }

    var role: Role
    /// User prompt text, or the assistant's visible text.
    var text: String = ""
    /// Assistant reasoning ("thinking").
    var reasoning: String = ""
    /// Assistant tool calls, in order.
    var toolCalls: [ToolCall] = []
    /// Whether this normalized row represents a conversational message for the
    /// restored-count notice. Codex reasoning/tool rows are separate rollout
    /// records belonging to the assistant message, so they set this false.
    var countsAsMessage: Bool = true
    /// toolResult: which tool call it completes, and whether it failed.
    var toolCallId: String = ""
    var toolFailed: Bool = false
    /// B6.3 — compaction: pi's persisted `tokensBefore`, the one real field its
    /// session-file `compaction` entry carries (see `AgentCompactionPayload`'s
    /// doc comment for what it does not carry).
    var compactionTokensBefore: Int?
    var compactionTokensAfter: Int?
    var compactionAfterEstimated: Bool = false
    var compactionBoundaryID: String?
    var compactionTrigger: AgentCompactionTrigger = .unknown("")
    var compactionProvider: String?
}

public enum ManagedTranscriptRehydrator {
    /// The pi session id Array derives for an agent (mirrors
    /// `AgentSupervisor.sessionId(for:)`; the app-side witness cross-checks the
    /// two so they cannot drift). Pi names its session file `<ts>_<sessionId>.jsonl`.
    public static func piSessionId(forAgentUUID uuid: UUID) -> String {
        "array-agent-\(uuid.uuidString)"
    }

    /// The claude session id Array derives for an agent (mirrors
    /// `AgentSupervisor.claudeSessionId(for:)`). Claude names its session file
    /// `<sessionId>.jsonl` and validates UUID format, so the agent id itself IS
    /// the conversation id, lowercased.
    public static func claudeSessionId(forAgentUUID uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    /// Coarse tool → ItemKind buckets, matching `ClaudeEventTranslator`'s: the
    /// exact tool name rides `title`.
    static func itemKind(forTool tool: String) -> ItemKind {
        switch tool.lowercased() {
        case "edit", "write", "multiedit", "notebookedit":
            return .fileChange
        case "websearch", "webfetch":
            return .webSearch
        // Matching `ClaudeEventTranslator` means matching its `.subagent` case
        // too, or a REHYDRATED transcript buckets a delegation as a command
        // while the live one does not.
        case "agent", "task", "spawn_agent", "delegate_agent":
            return .subagent
        default:
            return .commandExecution
        }
    }

    /// Reconstructs a bounded, replayable transcript from normalized messages.
    /// One turn spans from an assistant reply up to the next user prompt, so the
    /// tool lifecycle stays inside its turn exactly as the live flow produces it.
    static func assemble(
        _ messages: [NormalizedTranscriptMessage],
        threadId: String,
        truncated: Bool,
        limits: RehydrationLimits
    ) -> RehydratedTranscript {
        var kept = messages
        var omitted = truncated
        if kept.count > limits.maxMessages {
            kept = Array(kept.suffix(limits.maxMessages))
            omitted = true
        }

        var steps: [RehydratedTranscriptStep] = []
        var turnCounter = 0
        var openTurnId: String?
        var itemKinds: [String: ItemKind] = [:]
        var messageCount = 0
        var compactionCounter = 0

        func closeTurn() {
            guard let turnId = openTurnId else { return }
            steps.append(.event(.turnCompleted(
                threadId: threadId, turnId: turnId, outcome: .completed, errorMessage: nil)))
            openTurnId = nil
        }
        func ensureTurn() -> String {
            if let turnId = openTurnId { return turnId }
            turnCounter += 1
            let turnId = "rehydrated-t\(turnCounter)"
            steps.append(.event(.turnStarted(threadId: threadId, turnId: turnId)))
            openTurnId = turnId
            return turnId
        }

        for message in kept {
            switch message.role {
            case .userPrompt:
                closeTurn()
                steps.append(.userPrompt(message.text))
                if message.countsAsMessage { messageCount += 1 }
            case .assistant:
                let turnId = ensureTurn()
                if !message.reasoning.isEmpty {
                    steps.append(.event(.contentDelta(
                        threadId: threadId, turnId: turnId, streamKind: .reasoning, delta: message.reasoning)))
                }
                if !message.text.isEmpty {
                    steps.append(.event(.contentDelta(
                        threadId: threadId, turnId: turnId, streamKind: .assistant, delta: message.text)))
                }
                for call in message.toolCalls {
                    let kind = itemKind(forTool: call.name)
                    itemKinds[call.id] = kind
                    // Surface the command in the title so a rehydrated card reads
                    // "Bash · ls && cat …" instead of an opaque, contextless
                    // "Bash". Display-only (rehydration never re-syncs); the live
                    // translator keeps name-only for the I5 sync boundary.
                    let title = call.detail.map { "\(call.name) · \($0)" } ?? call.name
                    steps.append(.event(.itemStarted(
                        threadId: threadId, itemId: call.id, kind: kind, title: title)))
                }
                if message.countsAsMessage { messageCount += 1 }
            case .toolResult:
                _ = ensureTurn()
                let kind = itemKinds[message.toolCallId] ?? .commandExecution
                steps.append(.event(.itemCompleted(
                    threadId: threadId,
                    itemId: message.toolCallId,
                    kind: kind,
                    status: message.toolFailed ? .failed : .completed)))
            case .compaction:
                // B6.3 — mirrors B6.2's claude compaction item exactly (same
                // ItemKind, same decodable title), so the same projection
                // logic renders it collapsed and attributed to the harness.
                // Not wrapped in a turn: like claude's compact_boundary, this
                // is a system-level boundary, not part of a turn's own work.
                compactionCounter += 1
                let itemID = message.compactionBoundaryID ?? "rehydrated-compaction-\(compactionCounter)"
                steps.append(.event(.compactionChanged(
                    threadId: threadId,
                    event: AgentCompactionLifecycleEvent(
                        boundaryID: itemID,
                        phase: .succeeded,
                        trigger: message.compactionTrigger,
                        beforeTokens: message.compactionTokensBefore.map {
                            AgentCompactionTokenReading($0, precision: .exact)
                        },
                        afterTokens: message.compactionTokensAfter.map {
                            AgentCompactionTokenReading(
                                $0, precision: message.compactionAfterEstimated ? .estimated : .exact)
                        },
                        provider: message.compactionProvider ?? "provider"
                    ))))
                let title = AgentCompactionPayload.encodeTitle(
                    preTokens: message.compactionTokensBefore,
                    postTokens: message.compactionTokensAfter,
                    automaticCompaction: nil)
                let compactionKind = ItemKind.compaction
                steps.append(.event(.itemStarted(
                    threadId: threadId, itemId: itemID, kind: compactionKind, title: title)))
                steps.append(.event(.itemCompleted(
                    threadId: threadId, itemId: itemID, kind: compactionKind, status: .completed)))
            }
        }
        closeTurn()

        return RehydratedTranscript(
            steps: steps, restoredMessageCount: messageCount, omittedEarlier: omitted)
    }

    // MARK: - JSON helper (cross-platform)

    static func jsonObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

#if os(macOS)

extension ManagedTranscriptRehydrator {
    /// Everything a rehydrate needs, resolved on the main thread by the
    /// supervisor and then read off it. Value types so it can cross to a
    /// background task.
    public struct Inputs: Sendable, Equatable {
        public var agentUUID: UUID
        public var cwd: String
        public var model: String
        public var harness: AgentHarness?
        public var claudeCLIAvailable: Bool
        public var homeURL: URL
        public var codexThreadId: String?
        public var codexHomeURL: URL
        public var limits: RehydrationLimits

        public init(
            agentUUID: UUID,
            cwd: String,
            model: String,
            harness: AgentHarness? = nil,
            claudeCLIAvailable: Bool,
            homeURL: URL,
            codexThreadId: String? = nil,
            codexHomeURL: URL? = nil,
            limits: RehydrationLimits = RehydrationLimits()
        ) {
            self.agentUUID = agentUUID
            self.cwd = cwd
            self.model = model
            self.harness = harness
            self.claudeCLIAvailable = claudeCLIAvailable
            self.homeURL = homeURL
            self.codexThreadId = codexThreadId
            self.codexHomeURL = codexHomeURL
                ?? homeURL.appendingPathComponent(".codex", isDirectory: true)
            self.limits = limits
        }
    }

    /// Reads the previous session's transcript. Claude and Pi use Array-derived
    /// identities; Codex is accepted only when its session_meta exactly matches
    /// the persisted `codexThreadId`. The runner's preferred route wins when its
    /// proven file exists, preventing an older provider file from hiding the
    /// current conversation.
    ///
    /// Call OFF the main thread: session files run to hundreds of messages.
    public static func rehydrate(_ inputs: Inputs) -> RehydratedTranscript? {
        let threadId = "rehydrated-\(inputs.agentUUID.uuidString)"
        let claudeURL = ClaudeSessionTranscriptReader.sessionFileURL(
            homeURL: inputs.homeURL,
            cwd: inputs.cwd,
            sessionId: claudeSessionId(forAgentUUID: inputs.agentUUID))
        let piURL = PiSessionTranscriptReader.locateSessionFile(
            homeURL: inputs.homeURL,
            cwd: inputs.cwd,
            sessionId: piSessionId(forAgentUUID: inputs.agentUUID))
        let codexURL = inputs.codexThreadId.flatMap {
            CodexSessionTranscriptReader.locateRollout(
                codexHomeURL: inputs.codexHomeURL, threadId: $0)
        }

        guard let harness = inputs.harness else { return nil }

        switch harness {
        case .claudeCode:
            return ClaudeSessionTranscriptReader.read(
                sessionFileURL: claudeURL, threadId: threadId, limits: inputs.limits)
        case .codex:
            guard let codexURL, let codexThreadId = inputs.codexThreadId else { return nil }
            return CodexSessionTranscriptReader.read(
                sessionFileURL: codexURL, threadId: codexThreadId, limits: inputs.limits)
        case .pi:
            guard let piURL else { return nil }
            return PiSessionTranscriptReader.read(
                sessionFileURL: piURL, threadId: threadId, limits: inputs.limits)
        }
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads the tail of a `.jsonl` file bounded to `maxBytes`, returning the
    /// lines and whether the file was larger than the window (a truncated read
    /// drops the first, partial line). Mirrors `ClaudeAgentStateReader`'s tail
    /// strategy.
    static func readTailLines(at url: URL, maxBytes: Int) -> (lines: [String], truncated: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let cap = UInt64(max(0, maxBytes))
        let truncated = size > cap
        let start = truncated ? size - cap : 0
        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return ([], truncated) }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            // A truncated read almost certainly cut the first line mid-way.
            if truncated, !text.hasPrefix("\n"), !lines.isEmpty {
                lines.removeFirst()
            }
            return (lines, truncated)
        } catch {
            return ([], truncated)
        }
    }
}

#endif  // os(macOS)
