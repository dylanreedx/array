// Film harness: pi agents, and the streaming cadence every harness shares.
//
// A pi agent's turn is fed to the agent's production `PiEventTranslator` as the JSON
// lines `pi --mode rpc` prints (the shapes the translator's own comments pin, captured
// from pi 0.85): `session`, `agent_start`, `message_start`/`message_update`
// (`text_delta`, `thinking_delta`), `tool_execution_start`/`_end`, `turn_end`,
// `agent_end`. Its events are restamped onto the tile's thread and delivered through
// the supervisor, exactly as `feedCodex` does for codex.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import ContinuumRevivedCore
import Foundation

extension FilmDirector {
    /// How far a streamed `say`/`think` of `count` characters has reached on this frame,
    /// or nil when nothing new goes out.
    ///
    /// Without `streamHz` (every committed scene): each frame sends up to the next whole
    /// word. With it (`streamHz: 30`): a delta goes out only every `fps / streamHz`
    /// frames, cut where the text has reached rather than at a word, which is how a
    /// provider streams (token deltas) and how fast production presents them
    /// (`AgentTranscriptUpdateScheduler` and `StreamingMarkupParseScheduler`, 30 Hz).
    func streamTarget(_ characters: [Character], action: FilmAction, local: Int, sent: Int) -> Int? {
        let count = characters.count
        if action.duration == 0 { return count > sent ? count : nil }
        let reached = min(count, Int((Double(local + 1) / Double(action.duration + 1) * Double(count)).rounded()))
        if let hz = scene.streamHz {
            let step = max(1, Int((fps / Double(hz)).rounded()))
            guard local % step == 0 || local == action.duration else { return nil }
            return reached > sent ? reached : nil
        }
        var target = reached
        while target < count, characters[target] != " ", characters[target] != "\n" { target += 1 }
        return target > sent ? target : nil
    }

    func applyPi(_ agentKey: String, action: FilmAction, key: String, local: Int) throws {
        guard var agent = agents[agentKey] else { throw FilmError("unknown agent \(agentKey)") }
        defer { agents[agentKey] = agent }
        if let text = action.say ?? action.think {
            let isProse = action.say != nil
            if local == 0 {
                // A new assistant message; prose after prose is a new paragraph, as for claude.
                actionState["\(key)/paragraph"] = isProse && agent.proseOpen
                try feedPi(["type": "message_start", "message": ["role": "assistant"]], agentKey: agentKey, agent: agent)
            }
            let paragraph = (actionState["\(key)/paragraph"] as? Bool) == true ? "\n\n" : ""
            let characters = Array(paragraph + text)
            let sent = (actionState[key] as? Int) ?? 0
            agent.proseOpen = isProse
            guard let target = streamTarget(characters, action: action, local: local, sent: sent) else { return }
            try feedPi(["type": "message_update", "assistantMessageEvent": [
                "type": isProse ? "text_delta" : "thinking_delta", "delta": String(characters[sent..<target]),
            ]], agentKey: agentKey, agent: agent)
            actionState[key] = target
            return
        }
        guard local == 0 else { return }
        agent.proseOpen = false
        if let prompt = action.prompt {
            agentView(agentKey)?.appendUserPrompt(prompt)
        } else if let turn = action.turn {
            switch turn {
            case "start":
                if agent.turnCount == 0 {
                    var session: [String: Any] = ["type": "session", "id": "film-pi-\(agentKey)"]
                    if let root = supervisor.records[agent.agentId]?.checkoutRoot { session["cwd"] = root }
                    try feedPi(session, agentKey: agentKey, agent: agent, ago: action.ago ?? 0)
                }
                agent.turnCount += 1
                try feedPi(["type": "agent_start"], agentKey: agentKey, agent: agent, ago: action.ago ?? 0)
            case "done", "failed":
                let runner = FilmAgentRunner.inFlight(for: agent.agentId)
                try feedPi(["type": "turn_end", "message": ["role": "assistant", "stopReason": turn == "done" ? "stop" : "error"]],
                           agentKey: agentKey, agent: agent)
                try feedPi(["type": "agent_end"], agentKey: agentKey, agent: agent, through: runner)
                if runner != nil { pendingRunnerCompletions.insert(agentKey) }
            default:
                throw FilmError("turn \(turn)")
            }
        } else if let tool = action.tool, let name = tool.name {
            actionState["piTool/\(agentKey)/\(tool.id)"] = tool
            try feedPi(["type": "tool_execution_start", "toolCallId": tool.id, "toolName": name, "args": try resolvedInput(tool)],
                       agentKey: agentKey, agent: agent)
        } else if let toolId = action.toolDone, let tool = actionState["piTool/\(agentKey)/\(toolId)"] as? FilmAction.Tool {
            try feedPi(["type": "tool_execution_end", "toolCallId": tool.id, "toolName": tool.name ?? "",
                        "result": ["content": [["type": "text", "text": tool.output ?? ""]]],
                        "isError": action.status == "failed"],
                       agentKey: agentKey, agent: agent)
        }
        delegate.filmRefreshAgentSurfaces()
    }

    /// One pi rpc line through the agent's production translator. `through`: a real
    /// composer send's runner, which reports the run's end the way the pi process would.
    func feedPi(_ object: [String: Any], agentKey: String, agent: AgentHandle, ago: Double = 0,
                through runner: FilmAgentRunner? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let epoch = filmEpoch, shift = Self.filmWallShift
        var translator = piTranslators[agentKey] ?? PiEventTranslator(
            workingDirectory: supervisor.records[agent.agentId].map { URL(fileURLWithPath: $0.checkoutRoot, isDirectory: true) },
            now: { epoch.addingTimeInterval(shift + FilmDirector.filmSeconds) })
        let box = FilmObservationBox()
        translator.onRuntimeObservation = box.append
        let events = translator.translate(line: String(decoding: data, as: UTF8.self))
        translator.onRuntimeObservation = nil
        piTranslators[agentKey] = translator
        for observation in box.drain() where !Self.isProviderThreadObservation(observation) {
            supervisor.qaObserve(observation, for: agent.agentId)
        }
        if let runner {
            runner.complete(with: events.map { $0.withThreadId(agent.threadId) })
            return
        }
        for event in events { deliver(event.withThreadId(agent.threadId), to: agent, ago: ago) }
    }
}
#endif
