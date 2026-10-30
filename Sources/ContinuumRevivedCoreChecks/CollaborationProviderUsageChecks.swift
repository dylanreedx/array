import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCore
import Foundation

// COL-17: exact teammate-usage totals from the committed CLI captures. Every
// case drives the production translator, `SharedAreaUsageNormalizer` and the
// durable `SharedAreaUsageLedger`, so a figure here is the figure a teammate's
// hover card would read. The overlap traps are each pinned by number:
//
// - Claude's per-request assistant frames vs its per-run result,
// - a subagent's usage, which is outside `result.usage` and inside `modelUsage`,
// - a result re-reported with the same `uuid`, and a process-cumulative
//   `modelUsage` on a CLI that numbers its results,
// - Codex `cached_input_tokens`, a subset of `input_tokens`,
// - a forked Codex thread inheriting its parent's cumulative total,
// - a Codex counter that goes down, and reports that arrive late.
func runCollaborationProviderUsageChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-provider-usage-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = Date(timeIntervalSince1970: 1_900_000_000)

    func lines(_ name: String) -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            expect(false, "provider usage: committed capture \(name) is missing")
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// One fresh ledger and one agent's normalizer. `session` names the
    /// provider session the agent record holds at each event, as
    /// `AgentRecord.codexThreadId` does in production.
    final class Agent {
        let ledger: SharedAreaUsageLedger
        var normalizer: SharedAreaUsageNormalizer
        var clock: Date
        var unattributable = 0
        init(root: URL, harness: AgentHarness, start: Date, sharing: SharedAreaUsageLedger? = nil) {
            ledger = try! sharing ?? SharedAreaUsageLedger(directory: root.appendingPathComponent(UUID().uuidString), host: .init())
            normalizer = SharedAreaUsageNormalizer(source: UUID().uuidString, harness: harness,
                startedAt: start, providerSessionAtStart: nil)
            clock = start
        }
        func deliver(_ events: [AgentRuntimeEvent], session: String? = nil) {
            for event in events {
                clock = clock.addingTimeInterval(1)
                switch event {
                case .turnStarted(_, let turn): normalizer.turnStarted(turn)
                case .tokenUsageUpdated(let thread, let value):
                    switch normalizer.usage(value, providerSession: session, thread: thread,
                                            latestTurnAt: nil, receivedAt: clock) {
                    case .record(let observation)?:
                        // Provider times can be ahead of this fixed clock.
                        _ = try! ledger.record(observation, at: max(clock, observation.observedAt))
                    case .unattributable?: unattributable += 1
                    case nil: break
                    }
                default: break
                }
            }
        }
        func total() -> (input: UInt64, output: UInt64, partial: Bool) {
            let value = try! ledger.snapshot(coveredAgents: 1, runningAgents: 0, at: clock.addingTimeInterval(1))
            return (value.inputTokens, value.outputTokens, value.partial)
        }
    }

    // Claude: subagent overlap and request-vs-run overlap. claude-subagent-turn
    // has two main requests (assistant frames, each re-sent while streaming),
    // a general-purpose subagent with its own requests, task_progress and
    // task_notification totals, the Task tool's own usage block, and one result.
    // `modelUsage` is the inclusive account: fable 8 + 54,846 + 23,249 and a
    // haiku side call of 933 → 79,036 in; 484 + 16 → 500 out. The result's
    // main-only `usage` (51,671 / 330) undercounts the subagent; adding any of
    // the other reports on top double counts it.
    do {
        let agent = Agent(root: root, harness: .claudeCode, start: base)
        var translator = ClaudeEventTranslator(runToken: "usage", now: { base })
        let events = translator.translate(stream: lines("claude-subagent-turn.jsonl"))
        let requests = events.filter { if case .contextWindowUpdated = $0 { return true }; return false }.count
        agent.deliver(events)
        let total = agent.total()
        expect(requests >= 2 && total.input == 79_036 && total.output == 500,
               "provider usage: claude subagent run must count the inclusive result once (79,036 / 500) "
               + "beside \(requests) request observations; got \(total.input) / \(total.output)")
        print("PASS provider usage: claude subagent and per-request frames count once inside the inclusive result (79,036 / 500)")
    }

    // Claude: the same result re-reported after a background subagent finished.
    // claude-async-subagent carries the result twice with one `uuid`, across a
    // second init (a new turn); it is still one run.
    do {
        let agent = Agent(root: root, harness: .claudeCode, start: base)
        var translator = ClaudeEventTranslator(runToken: "usage", now: { base })
        let events = translator.translate(stream: lines("claude-async-subagent.jsonl"))
        let results = events.filter { if case .tokenUsageUpdated = $0 { return true }; return false }.count
        agent.deliver(events)
        let total = agent.total()
        expect(results == 2 && total.input == 79_036 && total.output == 500,
               "provider usage: a result reported twice must count once; \(results) reports gave \(total.input) / \(total.output)")
        print("PASS provider usage: claude result re-reported outside its run (same uuid, new turn) counts once")
    }

    // Claude: a CLI that numbers results reports `modelUsage` cumulatively for
    // the process. claude-background-result-turn has result 0 (52,314 / 250)
    // and result 1 whose cumulative is 137,919 / 1,093 and whose own share is
    // 85,605 / 843. Exact total = the final cumulative, not 52,314 + 137,919.
    do {
        let agent = Agent(root: root, harness: .claudeCode, start: base)
        var translator = ClaudeEventTranslator(runToken: "usage", now: { base })
        agent.deliver(translator.translate(stream: lines("claude-background-result-turn.jsonl")))
        let total = agent.total()
        expect(total.input == 137_919 && total.output == 1_093,
               "provider usage: claude numbered results must sum their own shares (137,919 / 1,093); got \(total.input) / \(total.output)")
        // The same CLI shape with the share field dropped still yields only the
        // second result's own share, from the cumulative difference.
        let stripped = lines("claude-background-result-turn.jsonl").map { line -> String in
            guard var object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "result" else { return line }
            object.removeValue(forKey: "model_usage_since_last_result")
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let fallback = Agent(root: root, harness: .claudeCode, start: base)
        var second = ClaudeEventTranslator(runToken: "usage", now: { base })
        fallback.deliver(second.translate(stream: stripped))
        let derived = fallback.total()
        expect(derived.input == 137_919 && derived.output == 1_093,
               "provider usage: a cumulative modelUsage without its share field must not be re-added; got \(derived.input) / \(derived.output)")
        print("PASS provider usage: claude process-cumulative modelUsage counts each result's share once (137,919 / 1,093)")
    }

    // Claude 2.1.291: one request, its assistant frame sent twice while
    // streaming, and the result. 2 + 10,695 + 11,239 = 21,936 in, 124 out.
    do {
        let agent = Agent(root: root, harness: .claudeCode, start: base)
        var translator = ClaudeEventTranslator(runToken: "usage", now: { base })
        agent.deliver(translator.translate(stream: lines("claude-2.1.291-opus-turn.jsonl")))
        let total = agent.total()
        expect(total.input == 21_936 && total.output == 124,
               "provider usage: claude single-request run must count 21,936 / 124 once; got \(total.input) / \(total.output)")
        print("PASS provider usage: claude repeated request frames and the run result count once (21,936 / 124)")
    }

    // Codex exec: `cached_input_tokens` (59,392) is a subset of `input_tokens`
    // (64,925). Exact total 64,925 / 286, never 124,317.
    do {
        let agent = Agent(root: root, harness: .codex, start: base)
        var translator = CodexEventTranslator(runToken: "usage", now: { base })
        agent.deliver(translator.translate(stream: lines("codex-exec-single-agent-parity.jsonl")), session: "exec-thread")
        let total = agent.total()
        expect(total.input == 64_925 && total.output == 286,
               "provider usage: codex cached input is a subset of input (64,925 / 286); got \(total.input) / \(total.output)")
        print("PASS provider usage: codex cached-input subset is not added again (64,925 / 286)")
    }

    // Codex app-server: four cumulative `total`s on one thread (16,047 →
    // 64,996). Exact total is the last, not their 161,820 sum.
    let single = lines("codex-appserver-single-agent.jsonl")
    let parentThread = "00000000-0000-4000-8000-000000000001"
    let parent = Agent(root: root, harness: .codex, start: base)
    do {
        var translator = CodexAppServerEventTranslator(now: { base })
        parent.deliver(translator.translate(stream: single), session: parentThread)
        let total = parent.total()
        expect(total.input == 64_996 && total.output == 313,
               "provider usage: codex app-server cumulative totals must count by high-water (64,996 / 313); got \(total.input) / \(total.output)")
        print("PASS provider usage: codex app-server cumulative totals count once by high-water (64,996 / 313)")
    }

    // Codex delegation: the parent thread and its child thread each report
    // their own cumulative total. The runner routes child-thread frames to the
    // child, so each thread is its own counter: parent 32,244 / 92 + child
    // 32,537 / 170 = 64,781 / 262, never the larger one alone.
    do {
        var translator = CodexAppServerEventTranslator(now: { base })
        let events = translator.translate(stream: lines("codex-appserver-delegating-turn.jsonl"))
        let ledgerRoot = root.appendingPathComponent("delegation")
        let ledger = try! SharedAreaUsageLedger(directory: ledgerRoot, host: .init())
        var byThread: [String: SharedAreaUsageNormalizer] = [:]
        var clock = base
        for case let .tokenUsageUpdated(thread, value) in events {
            clock = clock.addingTimeInterval(1)
            var normalizer = byThread[thread] ?? SharedAreaUsageNormalizer(source: thread, harness: .codex,
                startedAt: base, providerSessionAtStart: nil)
            if case .record(let observation)? = normalizer.usage(value, providerSession: thread, thread: thread,
                                                                  latestTurnAt: nil, receivedAt: clock) {
                _ = try! ledger.record(observation, at: max(clock, observation.observedAt))
            }
            byThread[thread] = normalizer
        }
        let total = try! ledger.snapshot(coveredAgents: 2, runningAgents: 0, at: clock.addingTimeInterval(1))
        expect(byThread.count == 2 && total.inputTokens == 64_781 && total.outputTokens == 262,
               "provider usage: codex parent and child threads count once each (64,781 / 262); got \(total.inputTokens) / \(total.outputTokens)")
        print("PASS provider usage: codex parent and delegated child threads each count once (64,781 / 262)")
    }

    // Codex fork. A thread forked from the parent (`forkedFromId`) reports a
    // cumulative total that already contains the parent's 64,996 / 313. Only
    // what it adds after the fork counts: 81,096 → 97,300 makes the agent's
    // total 97,300 / 400, never 64,996 + 97,300.
    func forkFrame(_ thread: String, _ input: Int, _ output: Int, _ emitted: Int) -> String {
        #"{"emittedAtMs":\#(emitted),"method":"thread/tokenUsage/updated","params":{"threadId":"\#(thread)","turnId":"fork-turn","tokenUsage":{"last":{"inputTokens":16100,"outputTokens":40,"totalTokens":16140},"total":{"inputTokens":\#(input),"outputTokens":\#(output),"cachedInputTokens":11008,"totalTokens":\#(input + output)},"modelContextWindow":258400}}}"#
    }
    let forkThread = "00000000-0000-4000-8000-0000000000f0"
    let forkStarted = #"{"method":"thread/started","params":{"thread":{"id":"\#(forkThread)","forkedFromId":"\#(parentThread)","cliVersion":"0.148.0","cwd":"/tmp/fixture"}}}"#
    do {
        var translator = CodexAppServerEventTranslator(now: { base })
        let fork = translator.translate(stream: [forkStarted,
            forkFrame(forkThread, 81_096, 353, 1_787_613_900_000),
            forkFrame(forkThread, 97_300, 400, 1_787_613_910_000)])
        parent.deliver(fork, session: forkThread)
        let total = parent.total()
        expect(total.input == 97_300 && total.output == 400,
               "provider usage: a forked codex thread must count only its post-fork delta (97,300 / 400); got \(total.input) / \(total.output)")
        print("PASS provider usage: forked codex thread counts only what it adds after the fork (97,300 / 400)")

        // A replacement thread smaller than its predecessor cannot carry the
        // whole history; it sets a baseline and coverage is partial.
        let fresh = Agent(root: root, harness: .codex, start: base)
        var again = CodexAppServerEventTranslator(now: { base })
        fresh.deliver(again.translate(stream: single), session: parentThread)
        fresh.deliver(again.translate(stream: [forkFrame(forkThread, 9_000, 20, 1_787_613_900_000),
            forkFrame(forkThread, 12_000, 30, 1_787_613_910_000)]), session: forkThread)
        let small = fresh.total()
        expect(small.input == 64_996 + 3_000 && small.output == 313 + 10 && small.partial,
               "provider usage: a smaller replacement thread must set a baseline, then count its growth; got \(small)")
        print("PASS provider usage: a replacement thread below its parent only sets a baseline and reports partial")
    }

    // A forked COPY: a second agent whose only thread was forked from the
    // first agent's (`forkedFromId` on `thread/started`). It has no previous
    // thread of its own, so only codex's own lineage field can tell the ledger
    // its totals contain the parent's. Derived from the real single-agent
    // capture: the fork's frames carry that capture's totals on top of the
    // parent's final 64,996 / 313. Exact = 64,996 + 64,996 / 313 + 313, never
    // the fork in full (194,988).
    do {
        let source = Agent(root: root, harness: .codex, start: base)
        var parentTranslator = CodexAppServerEventTranslator(now: { base })
        source.deliver(parentTranslator.translate(stream: single), session: parentThread)
        let copyThread = "00000000-0000-4000-8000-0000000000c0"
        let forked = single.map { line -> String in
            guard var object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  var params = object["params"] as? [String: Any] else { return line }
            switch object["method"] as? String {
            case "thread/started"?:
                guard var thread = params["thread"] as? [String: Any] else { return line }
                thread["id"] = copyThread; thread["forkedFromId"] = parentThread; params["thread"] = thread
            case "thread/tokenUsage/updated"?:
                guard var usage = params["tokenUsage"] as? [String: Any], var total = usage["total"] as? [String: Any] else { return line }
                total["inputTokens"] = ((total["inputTokens"] as? Int) ?? 0) + 64_996
                total["outputTokens"] = ((total["outputTokens"] as? Int) ?? 0) + 313
                usage["total"] = total; params["tokenUsage"] = usage; params["threadId"] = copyThread
                object["emittedAtMs"] = ((object["emittedAtMs"] as? Int) ?? 0) + 600_000
            default: return line
            }
            object["params"] = params
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        var copyTranslator = CodexAppServerEventTranslator(now: { base })
        let copyEvents = copyTranslator.translate(stream: forked)
        let lineage = copyEvents.compactMap { event -> String? in
            if case let .tokenUsageUpdated(_, value) = event { return value.accountingForkedFrom }
            return nil
        }
        let copy = Agent(root: root, harness: .codex, start: base, sharing: source.ledger)
        copy.clock = source.clock
        copy.deliver(copyEvents, session: copyThread)
        let total = copy.total()
        expect(!lineage.isEmpty && lineage.allSatisfy { $0 == parentThread } && total.input == 129_992 && total.output == 626,
               "provider usage: a forked copy must count only what its thread adds (129,992 / 626) from codex's forkedFromId; lineage \(lineage), got \(total.input) / \(total.output)")
        print("PASS provider usage: codex forkedFromId marks a forked copy's inherited total; only its own growth counts (129,992 / 626)")
    }

    // Codex reset and late reports. The cumulative drops from 64,996 to 1,200
    // in a NEWER frame: that is a new baseline (no negative, no re-add), then
    // 5,200 adds 4,000. A replay of an older frame afterwards adds nothing.
    do {
        let agent = Agent(root: root, harness: .codex, start: base)
        var translator = CodexAppServerEventTranslator(now: { base })
        agent.deliver(translator.translate(stream: single), session: parentThread)
        agent.deliver(translator.translate(stream: [forkFrame(parentThread, 1_200, 10, 1_787_614_000_000),
            forkFrame(parentThread, 5_200, 30, 1_787_614_010_000)]), session: parentThread)
        let reset = agent.total()
        expect(reset.input == 68_996 && reset.output == 333 && reset.partial,
               "provider usage: a codex counter reset must re-baseline without negative or double count (68,996 / 333, partial); got \(reset)")
        let replay = single.filter { $0.contains("thread/tokenUsage/updated") }
        agent.deliver(translator.translate(stream: replay + [forkFrame(parentThread, 5_100, 29, 1_787_614_005_000)]),
                      session: parentThread)
        let late = agent.total()
        expect(late.input == 68_996 && late.output == 333,
               "provider usage: late codex totals must add nothing after a reset; got \(late)")
        print("PASS provider usage: codex reset re-baselines (68,996 / 333, partial) and late frames add nothing")
    }

    // Pi: `message_end` and `turn_end` report the same response, and a replay
    // from a fresh translator (relaunch) reports it again: one message counts
    // once. A message with no identity cannot be counted exactly.
    do {
        let agent = Agent(root: root, harness: .pi, start: base)
        var translator = PiEventTranslator(now: { base })
        let message = #"{"type":"message_end","message":{"role":"assistant","responseId":"resp-1","usage":{"input":1026,"output":43,"cacheRead":7,"cacheWrite":11,"totalTokens":1069,"cost":{"total":0.00642}},"timestamp":1785037741229}}"#
        let second = #"{"type":"message_end","message":{"role":"assistant","responseId":"resp-2","usage":{"input":620,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":625,"cost":{"total":0.00258}},"timestamp":1785037745000}}"#
        let duplicate = #"{"type":"turn_end","message":{"role":"assistant","responseId":"resp-1","usage":{"input":1026,"output":43,"cacheRead":7,"cacheWrite":11,"totalTokens":1069,"cost":{"total":0.00642}},"timestamp":1785037741229}}"#
        let anonymous = #"{"type":"message_end","message":{"role":"assistant","usage":{"input":10,"output":1}}}"#
        agent.deliver(translator.translate(stream: [message, second]))
        var replay = PiEventTranslator(now: { base })
        agent.deliver(replay.translate(stream: [duplicate]))
        let counted = agent.total()
        // Pi's cache counters are separate from `input`: 1,026 + 7 + 11 = 1,044.
        expect(counted.input == 1_044 + 620 && counted.output == 48,
               "provider usage: pi messages must sum once with separate cache counters (1,664 / 48); got \(counted)")
        agent.deliver(replay.translate(stream: [anonymous]))
        expect(agent.unattributable == 1 && agent.total().input == 1_664,
               "provider usage: a pi message without identity must stay uncounted and unattributable")
        print("PASS provider usage: pi messages count once (1,664 / 48); identity-less usage stays unattributable")
    }

    // Ledger order: reports carry provider time. A counter's report older
    // than its newest is late and never counted, before or after a reset.
    do {
        let ledger = try! SharedAreaUsageLedger(directory: root.appendingPathComponent("order"), host: .init())
        func observe(_ input: UInt64, _ output: UInt64, _ seconds: TimeInterval) -> Collaboration.UsageSnapshot {
            try! ledger.record(.init(counter: "cumulative", input: input, output: output,
                observedAt: base.addingTimeInterval(seconds), initialBelongsToToday: true), at: base.addingTimeInterval(100))
        }
        _ = observe(100, 10, 1)
        _ = observe(160, 20, 3)
        let early = observe(130, 15, 2)
        _ = observe(20, 2, 4)
        let lateAfterReset = observe(160, 20, 3)
        let grown = observe(50, 5, 5)
        expect(early.inputTokens == 160 && lateAfterReset.inputTokens == 160 && grown.inputTokens == 190
               && grown.outputTokens == 23 && grown.partial,
               "provider usage: ledger ordering must ignore late reports and re-baseline resets; got \(early.inputTokens), \(lateAfterReset.inputTokens), \(grown.inputTokens)/\(grown.outputTokens)")
        print("PASS provider usage: late reports are ignored before and after a reset; growth after reset counts once")
    }
}
