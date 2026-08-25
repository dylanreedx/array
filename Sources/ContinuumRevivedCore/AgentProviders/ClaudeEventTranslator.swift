import ContinuumRevivedAgentContent
import Foundation

// Plan: .plans/01-provider-cli-backends.md (claude CLI backend, first slice).
//
// The PURE half of the claude adapter. Translates Claude Code's headless
// stream-json output (`claude -p --output-format stream-json --verbose
// --include-partial-messages`, verified live against claude 2.1.226 on
// 2026-08-09) into the normalized `AgentRuntimeEvent` the managed-agent tile
// already consumes. No process management here (that is ClaudeAgentRunner,
// the impure half) — line-in → events-out, exhaustively pinned in the matrix
// against the captured schema.
//
// I5 by construction, same as PiEventTranslator: `AgentRuntimeEvent` has no
// field for a cwd, a tool argument, or a tool result body, so mapping into it
// *drops* claude's sensitive payloads (init.cwd, tool_use.input,
// tool_result.content, assistant text bodies — text reaches the tile only as
// the deltas the user is meant to see). Tool items carry only the tool NAME.
// Proven in `runClaudeAgentBackendChecks`.
//
// Claude gives no turn ids either, and unlike pi its thread id (our minted
// session UUID) is STABLE across processes — so synthesized turn ids are
// salted with a per-process `runToken`, or a second prompt's stream would
// collide with the first prompt's turn and merge transcript cards.
//
// Sub-agent frames (`parent_tool_use_id` != null) are skipped everywhere:
// the top-level Task tool item already represents them, and interleaving a
// sub-agent's text into the main stream would garble the transcript.
public struct ClaudeEventTranslator {
    private var threadId: String = "claude-unknown"
    private let runToken: String
    private var turnCounter: Int = 0
    private var currentTurnId: String
    /// tool_use id → kind, so the matching tool_result completes with the
    /// same kind the start event carried.
    private var itemKinds: [String: ItemKind] = [:]
    private var seenItemIds = Set<String>()
    /// B6.2 — a compaction boundary has no tool_use id of its own, so this
    /// mints a stable-enough one for the item's begin/finish pair.
    private var compactionCounter: Int = 0
    private var workingDirectory: URL?
    private let now: @Sendable () -> Date

    /// Same host-local side channel as PiEventTranslator's: an explicit
    /// runtime cwd and a whitelisted operation/path projection, never the raw
    /// args. Fires on the translator's owner queue before the matching
    /// normalized event is returned.
    public var onRuntimeObservation: (@Sendable (AgentRuntimeObservation) -> Void)?

    /// C7 — an observed claude subagent, announced by an `Agent` (formerly
    /// `Task`) tool call. Exactly pi's `onSpawnRequest` seam and for exactly the
    /// same reason: **it never widens `AgentRuntimeEvent`** (I5), which is
    /// test-pinned, and `SpawnRequest` is deliberately non-Codable so a
    /// model-authored prompt cannot leave this host.
    ///
    /// The difference from pi is `observedOnly`: pi asks Array to START a child,
    /// while claude reports one it has ALREADY started inside itself. Array may
    /// watch that child; it must never claim to run it.
    public var onSpawnRequest: (@Sendable (SpawnRequest) -> Void)?

    public init(
        workingDirectory: URL? = nil,
        runToken: String = UUID().uuidString.lowercased().prefix(8).description,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.workingDirectory = workingDirectory?.standardizedFileURL
        self.runToken = runToken
        self.now = now
        self.currentTurnId = "claude-unknown#\(runToken)-t0"
    }

    /// Translate one line of claude stream-json output into zero or more
    /// normalized events. Unrecognised lines (thinking_tokens estimates,
    /// rate_limit_event telemetry, stream markers) return [].
    public mutating func translate(line: String) -> [AgentRuntimeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return []
        }

        switch type {
        case "system":
            let subtype = object["subtype"] as? String
            if subtype == "compact_boundary" {
                return translateCompactBoundary(object)
            }
            guard subtype == "init" else { return [] }
            if let id = object["session_id"] as? String {
                threadId = id
            }
            if let cwd = object["cwd"] as? String,
               let directory = Self.absoluteDirectory(cwd) {
                workingDirectory = directory
                onRuntimeObservation?(.workingDirectory(directory, observedAt: now()))
            }
            // One `claude -p` process is exactly one turn, so init is claude's
            // session + agent_start + turn_start rolled into one line.
            turnCounter += 1
            currentTurnId = "\(threadId)#\(runToken)-t\(turnCounter)"
            return [
                .sessionStateChanged(.ready),
                .sessionStateChanged(.running),
                .turnStarted(threadId: threadId, turnId: currentTurnId),
            ]

        case "stream_event":
            guard !Self.isSubagentFrame(object) else { return [] }
            return translateStreamEvent(object)

        case "assistant":
            guard !Self.isSubagentFrame(object) else { return [] }
            return translateAssistantMessage(object)

        case "user":
            guard !Self.isSubagentFrame(object) else { return [] }
            return translateUserMessage(object)

        case "result":
            return translateResult(object)

        default:
            // thinking_tokens estimates, rate_limit_event, tool progress
            // telemetry, etc. — nothing the normalized timeline needs.
            return []
        }
    }

    /// Convenience: translate a whole stream (e.g. a captured fixture).
    public mutating func translate(stream lines: [String]) -> [AgentRuntimeEvent] {
        lines.flatMap { translate(line: $0) }
    }

    private static func isSubagentFrame(_ object: [String: Any]) -> Bool {
        guard let parent = object["parent_tool_use_id"] else { return false }
        return !(parent is NSNull)
    }

    // MARK: - stream_event (partial-message deltas)

    private func translateStreamEvent(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let event = object["event"] as? [String: Any],
              (event["type"] as? String) == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String
        else { return [] }
        switch deltaType {
        case "text_delta":
            guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.contentDelta(threadId: threadId, turnId: currentTurnId, streamKind: .assistant, delta: text)]
        case "thinking_delta":
            guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
            return [.contentDelta(threadId: threadId, turnId: currentTurnId, streamKind: .reasoning, delta: text)]
        default:
            // input_json_delta streams tool ARGUMENTS — I5-sensitive, and the
            // complete assistant message carries the tool_use anyway.
            return []
        }
    }

    // MARK: - assistant messages (tool starts)

    private mutating func translateAssistantMessage(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }
        var events: [AgentRuntimeEvent] = []
        for block in content {
            guard (block["type"] as? String) == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String,
                  seenItemIds.insert(id).inserted
            else { continue }
            // The whitelisted projection goes out of band; the event below
            // carries the tool NAME only, never `input` (I5).
            if let onRuntimeObservation,
               let input = block["input"] as? [String: Any],
               let activity = Self.toolActivity(
                   toolName: name,
                   input: input,
                   workingDirectory: workingDirectory,
                   at: now()) {
                onRuntimeObservation(.toolActivity(itemId: id, activity: activity))
            }
            // `.plans/45` S2 — the detail supply behind the tool rows. Same
            // side channel, one level richer: whitelisted argument FIELDS
            // (query/url/pattern/basename/description — a command body never),
            // bound at construction and store-sanitized on top.
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: id, detail: AgentToolDetailObservation(
                    phase: .started,
                    toolName: name,
                    fields: Self.toolDetailFields(
                        toolName: name, input: block["input"] as? [String: Any] ?? [:]),
                    observedAt: now()
                )))
            }
            // The tool call IS the announcement. `id` is what every one of that
            // child's frames carries in `parent_tool_use_id`, so it is the only
            // stable way to tie the child's work back to the call that made it.
            if let onSpawnRequest,
               let request = SpawnRequest.parseClaudeAgentTool(
                   toolName: name,
                   args: block["input"] as? [String: Any] ?? [:],
                   toolUseID: id) {
                onSpawnRequest(request)
            }
            let kind = Self.itemKind(forTool: name)
            itemKinds[id] = kind
            events.append(.itemStarted(threadId: threadId, itemId: id, kind: kind, title: name))
        }
        // Assistant TEXT blocks are deliberately not emitted: the same prose
        // already streamed as text_delta events, and emitting both would
        // duplicate every reply in the transcript.
        return events
    }

    // MARK: - user messages (tool results)

    private mutating func translateUserMessage(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }
        var events: [AgentRuntimeEvent] = []
        for block in content {
            guard (block["type"] as? String) == "tool_result",
                  let toolUseId = block["tool_use_id"] as? String
            else { continue }
            let isError = (block["is_error"] as? Bool) ?? false
            // `.plans/45` S2 — a bounded output preview for the expanded pane.
            // Emitted BEFORE `.itemCompleted` (observation delivery is FIFO),
            // so the host can fold it into the one recordEnd it issues there.
            if let onRuntimeObservation {
                onRuntimeObservation(.toolDetail(itemId: toolUseId, detail: AgentToolDetailObservation(
                    phase: .ended,
                    outputPreview: Self.toolResultPreview(block["content"]),
                    observedAt: now()
                )))
            }
            events.append(.itemCompleted(
                threadId: threadId,
                itemId: toolUseId,
                kind: itemKinds.removeValue(forKey: toolUseId) ?? .commandExecution,
                status: isError ? .failed : .completed
            ))
        }
        return events
    }

    // MARK: - system/compact_boundary (context reset)

    /// A compaction just rewrote this session's history: the LLM's context
    /// dropped from `pre_tokens` to `post_tokens`. Without this, the ring kept
    /// showing the pre-compaction percentage for the whole following interval
    /// — a confidently wrong number — because the guard above discarded every
    /// non-init system frame. Captured live (claude 2.1.241, `/compact` on a
    /// resumed session): `compact_metadata.trigger`/`pre_tokens`/`post_tokens`
    /// are real fields; `messages_summarized`, speculated from binary strings,
    /// did not appear and is not read.
    //
    // No `maxTokens` here: this frame states the new token count, not the
    // model's window size, so the ring's denominator is left to whatever the
    // next authoritative reading provides — never fabricated from this event.
    private mutating func translateCompactBoundary(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        guard let metadata = object["compact_metadata"] as? [String: Any],
              let postTokens = Self.intValue(metadata["post_tokens"])
        else { return [] }
        let trigger = metadata["trigger"] as? String
        let preTokens = Self.intValue(metadata["pre_tokens"])
        let automatic = trigger != "manual"
        // B6.2 — the compaction block kind. `itemStarted`/`itemCompleted` fire
        // back-to-back because the boundary is already resolved by the time
        // claude reports it; there is no in-progress interval to show.
        compactionCounter += 1
        let itemID = "compaction#\(runToken)-\(compactionCounter)"
        let title = AgentCompactionPayload.encodeTitle(
            preTokens: preTokens, postTokens: postTokens, automaticCompaction: automatic)
        return [
            .itemStarted(threadId: threadId, itemId: itemID, kind: ItemKind(rawValue: "compaction"), title: title),
            .itemCompleted(threadId: threadId, itemId: itemID, kind: ItemKind(rawValue: "compaction"), status: .completed),
            .contextWindowUpdated(threadId: threadId, snapshot: AgentContextWindowSnapshot(
                usedTokens: postTokens,
                maxTokens: nil,
                automaticCompaction: automatic,
                observedAt: now(),
                source: .claudeCompactBoundary,
                freshness: .live
            )),
        ]
    }

    // MARK: - result (usage + turn completion)

    private func translateResult(_ object: [String: Any]) -> [AgentRuntimeEvent] {
        // A result with no init before it is a run that never started — the
        // shape `--resume` emits for an unknown session. The runner reports
        // that from exit+stderr (and retries as `--session-id`); emitting a
        // completion for a turn that never began would paint a spurious
        // failed turn during the retry.
        guard turnCounter > 0 else { return [] }
        var events: [AgentRuntimeEvent] = []
        let isError = (object["is_error"] as? Bool) ?? false
        let totalCost = Self.doubleValue(object["total_cost_usd"])

        if let usage = object["usage"] as? [String: Any] {
            let input = Self.intValue(usage["input_tokens"])
            let output = Self.intValue(usage["output_tokens"])
            let cacheRead = Self.intValue(usage["cache_read_input_tokens"])
            let cacheWrite = Self.intValue(usage["cache_creation_input_tokens"])
            // Claude reports the cached context separately from the tiny
            // uncached remainder; the summed figure is what "input" means
            // everywhere else in the app (pi reports it pre-summed).
            let summedInput = (input ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
            let total = summedInput + (output ?? 0)
            // A failed-before-start result carries an all-zero usage block;
            // publishing it would clobber real telemetry with zeros.
            if total > 0 {
                events.append(.tokenUsageUpdated(
                    threadId: threadId,
                    snapshot: TokenUsageSnapshot(
                        inputTokens: summedInput,
                        outputTokens: output ?? 0,
                        totalCostUsd: totalCost)
                ))
                events.append(.contextWindowUpdated(threadId: threadId, snapshot: AgentContextWindowSnapshot(
                    usedTokens: nil,
                    maxTokens: nil,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    totalProcessedTokens: total,
                    totalCostUsd: totalCost,
                    automaticCompaction: nil,
                    observedAt: now(),
                    source: .claudeResultUsage,
                    freshness: .live
                )))
            }
        }

        // errorMessage is the SUBTYPE ("error_max_turns"), never the result
        // body — the body can quote tool output (I5). Launch/auth failures
        // don't reach here at all: the runner surfaces those from exit+stderr.
        let subtype = object["subtype"] as? String
        events.append(.turnCompleted(
            threadId: threadId,
            turnId: currentTurnId,
            outcome: isError ? .failed : .completed,
            errorMessage: isError ? subtype : nil
        ))
        events.append(.sessionStateChanged(.ready))
        return events
    }

    // MARK: - host-local tool observation

    /// Claude tool names/arg keys, same whitelist philosophy as pi's: preserve
    /// only an operation and an optional filesystem scope; commands, queries,
    /// prompts, and bodies stay opaque.
    private static func toolActivity(
        toolName: String,
        input: [String: Any],
        workingDirectory: URL?,
        at observedAt: Date
    ) -> AgentObservedActivity? {
        let operation: AgentObservedActivity.Operation
        let pathKeys: [String]
        switch toolName.lowercased() {
        case "read":
            operation = .reading
            pathKeys = ["file_path", "path"]
        case "edit", "write", "multiedit", "notebookedit":
            operation = .editing
            pathKeys = ["file_path", "notebook_path", "path"]
        case "bash":
            // Never retain or parse input.command.
            operation = .running
            pathKeys = []
        case "grep", "glob", "websearch", "webfetch":
            operation = .searching
            pathKeys = ["path"]
        default:
            operation = .inspecting
            pathKeys = []
        }
        let target = pathKeys.lazy.compactMap { input[$0] as? String }.first
            .flatMap { resolvedTarget($0, workingDirectory: workingDirectory) }
        return AgentObservedActivity(
            operation: operation,
            targetPath: target,
            startedAt: observedAt,
            updatedAt: observedAt,
            evidenceSource: .toolEvent)
    }

    /// `.plans/45` S2 — the argument whitelist for `.toolDetail`, per tool per
    /// key. The rule: preserve what a human would say the tool is DOING (the
    /// query, the URL, the pattern, the file's basename, claude's own
    /// `description` summary) and nothing it is doing it WITH. `Bash.command`
    /// never crosses — `description` is the sanctioned summary; full paths
    /// stay on the activity channel, only the basename rides here.
    private static func toolDetailFields(
        toolName: String,
        input: [String: Any]
    ) -> [(key: String, value: String)] {
        func string(_ key: String) -> String? {
            guard let value = input[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return trimmed
        }
        // KEY-driven for the same reason pi's is: a tool name this switch has
        // never heard of still deserves its query shown, and the privacy rule
        // is about which KEYS may cross — never `command`, never a prompt.
        var fields: [(key: String, value: String)] = []
        if let query = string("query") { fields.append((key: "query", value: query)) }
        if let pattern = string("pattern") { fields.append((key: "pattern", value: pattern)) }
        if let url = string("url") { fields.append((key: "url", value: url)) }
        if let path = string("file_path") ?? string("notebook_path") ?? string("path") {
            fields.append((key: "file", value: URL(fileURLWithPath: path).lastPathComponent))
        }
        if let description = string("description") {
            fields.append((key: "description", value: description))
        }
        // A ROLE ID, and role ids are publishable — `RoleRegistry` reads them out
        // of project files and the inbox already shows them. `prompt` on the same
        // tool stays out: it is a model-authored command body, and bodies never
        // cross this boundary.
        if let subagentType = string("subagent_type") {
            fields.append((key: "subagent_type", value: subagentType))
        }
        return fields
    }

    /// A bounded plain-text preview of a `tool_result`'s content: the string
    /// form, or the joined text blocks. Anything else stays opaque.
    private static func toolResultPreview(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            guard !parts.isEmpty else { return nil }
            text = parts.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let maximumObservedPathBytes = 4_096

    private static func absoluteDirectory(_ raw: String) -> URL? {
        guard isSafePathText(raw) else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    private static func resolvedTarget(_ raw: String, workingDirectory: URL?) -> URL? {
        guard isSafePathText(raw) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        guard let workingDirectory else { return nil }
        return workingDirectory.appendingPathComponent(expanded).standardizedFileURL
    }

    private static func isSafePathText(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= maximumObservedPathBytes else { return false }
        return !raw.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as Double where value.isFinite:
            return Int(value)
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double where value.isFinite:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue.isFinite ? value.doubleValue : nil
        default:
            return nil
        }
    }

    // MARK: - tool → ItemKind

    /// Same coarse buckets as pi's mapping: the exact tool name rides `title`.
    static func itemKind(forTool tool: String) -> ItemKind {
        switch tool.lowercased() {
        case "edit", "write", "multiedit", "notebookedit":
            return .fileChange
        case "websearch", "webfetch":
            return .webSearch
        case "agent", "task":
            // Fell to `.commandExecution` through `default:`. Delegating to a
            // child is not running a command, and the row that says so is the
            // parent's index into work that happened somewhere else.
            return .subagent
        default:
            return .commandExecution
        }
    }
}
