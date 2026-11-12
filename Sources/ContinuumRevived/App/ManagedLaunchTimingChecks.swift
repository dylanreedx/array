import AppKit
import ContinuumRevivedCore
import Foundation

/// Targeted-only measurement of what Array adds around a Managed run, with a
/// fake Claude CLI that answers at once, so the numbers are Array's and not a
/// model's. Prints numbers and asserts nothing about time.
///
/// - lead launch: a new top-level Managed Claude agent, from the composer's
///   production entry (`AgentSupervisor.accept(.sendPrompt)`) to its CLI
///   session process starting;
/// - first reply: the same submission to the first assistant text Array
///   delivers (`addDeliveredEventObserver`), the moment a tile could show it.
///   Claude's text arrives as partial `stream_event` deltas, so the fixture
///   streams one before its whole message;
/// - delegate to helper launch: production `agent.delegate` dispatch from a
///   running Managed lead to the helper's CLI session starting;
/// - helper result to lead turn: the helper CLI writing its result to the
///   lead's CLI reading the next user turn Array sends it;
/// - watchdog sweep: one `sweepHelperWatchdog` pass on the main actor over a
///   store of 2,000 finished helpers.
///
/// "Started" is the birth time of a marker the disposable `claude` wrapper
/// creates before it execs the fixture, only for a session launch
/// (`--session-id` or `--resume`, never a `--tools` probe or titler run), and
/// named for the launching agent (`ARRAY_AGENT_ID`), so a lead woken in a
/// helper's shared checkout is never read as the helper's launch. Version and
/// hook probes on the way count as launch cost. The fixture writes its own
/// result and receipt times. All times are CLOCK_REALTIME nanoseconds. The
/// file compiles unchanged on origin/array/integration, so the same leg
/// measures both sides.
@MainActor
enum ManagedLaunchTimingChecks {
    static let warmup = 3
    static let samples = 20
    static let sweepHelpers = 2_000

    /// The fixture CLI. Each user turn it reads appends `turn <ns> <agent>`
    /// to `timing.log` in its directory; each result it writes is preceded by
    /// `result <ns> <agent>`.
    static let fixture = #"""
    #!/usr/bin/env python3
    import json, os, sys, time
    args = sys.argv[1:]
    if '--version' in args: print('fixture-claude-timing'); sys.exit(0)
    if '--help' in args: print('--settings <file-or-json>'); sys.exit(0)
    if '--tools' in args and '--settings' in args:  # the hook-surface probe
        import subprocess
        hooks = []
        for event, groups in json.loads(args[args.index('--settings')+1])['hooks'].items():
            for group in groups:
                for hook in group['hooks']:
                    hooks.append(dict(event=event, source='flagSettings', type=hook['type'], commandText=hook['command'],
                                      timeout=hook['timeout'], matcher=group.get('matcher', '')))
                    if event == 'SessionStart': subprocess.run(hook['command'], shell=True, check=True)
        for line in sys.stdin:
            r = json.loads(line)
            if r.get('request', {}).get('subtype') == 'get_hooks_listing':
                print(json.dumps(dict(type='control_response', response=dict(subtype='success', request_id=r['request_id'],
                    response=dict(eventCatalog=[dict(name=h['event']) for h in hooks], hooks=hooks)))), flush=True)
        sys.exit(0)
    if '--tools' in args: sys.exit(0)
    sid = args[args.index('--resume')+1] if '--resume' in args else args[args.index('--session-id')+1]
    me = os.environ.get('ARRAY_AGENT_ID', 'none')
    def log(kind):
        with open('timing.log', 'a') as f: f.write('%s %d %s\n' % (kind, time.time_ns(), me))
    def emit(o): print(json.dumps(o), flush=True)
    n = 0
    for line in sys.stdin:
        o = json.loads(line)
        if o.get('type') != 'user': continue
        log('turn')
        n += 1
        emit({'type':'system','subtype':'init','session_id':sid,'model':'claude-haiku-5-5','tools':[]})
        emit({'type':'stream_event','session_id':sid,'parent_tool_use_id':None,
              'event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'done'}}})
        emit({'type':'assistant','session_id':sid,'parent_tool_use_id':None,
              'message':{'id':'msg_%d_%d' % (os.getpid(), n),'type':'message','role':'assistant','model':'claude-haiku-5-5',
                         'content':[{'type':'text','text':'done'}]}})
        log('result')
        emit({'type':'result','subtype':'success','is_error':False,'session_id':sid,'result':'done','duration_ms':1,'num_turns':1})
    """#

    static func realtimeNanos() -> Int64 {
        var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    /// Birth time of `agent`'s launch marker in `dir`, once one exists.
    static func markerBirth(in dir: URL, agent: AgentID) -> Int64? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let tag = "launch-mark-" + agent.rawValue.uuidString.lowercased() + "-"
        for name in names where name.lowercased().hasPrefix(tag) {
            var st = stat()
            if stat(dir.appendingPathComponent(name).path, &st) == 0 {
                return Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
            }
        }
        return nil
    }

    /// `kind` times `agent`'s fixture logged in `dir`, oldest first.
    static func logged(_ kind: String, in dir: URL, agent: AgentID) -> [Int64] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("timing.log"), encoding: .utf8) else { return [] }
        let id = agent.rawValue.uuidString.lowercased()
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == kind, parts[2].lowercased() == id else { return nil }
            return Int64(parts[1])
        }
    }

    static func describe(_ name: String, _ values: [Double]) {
        let s = values.sorted()
        func p(_ q: Double) -> Double { s[max(0, min(s.count - 1, Int(ceil(Double(s.count) * q)) - 1))] }
        print(String(format: "managed timing %@ n=%d median=%.1f p95=%.1f min=%.1f max=%.1f ms",
                     name, s.count, p(0.5), p(0.95), s.first ?? 0, s.last ?? 0))
    }

    static func run() async throws {
        let b = try ManagedModeChecks.bench("launch-timing")
        defer { b.tearDown() }
        let fm = FileManager.default
        let real = b.binDir.appendingPathComponent("claude-fixture.py")
        try fixture.write(to: real, atomically: true, encoding: .utf8)
        let wrapper = """
        #!/bin/sh
        case " $* " in *" --tools "*) ;; *" --session-id "*|*" --resume "*) : > "launch-mark-${ARRAY_AGENT_ID:-none}-$$" ;; esac
        exec /usr/bin/env python3 '\(real.path)' "$@"
        """
        let cli = b.binDir.appendingPathComponent("claude")
        try wrapper.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let supervisor = b.supervisor
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, true, b)

        // The first assistant event Array delivers for each agent after a mark.
        var firstReply: [AgentID: Int64] = [:]
        let observer = supervisor.addDeliveredEventObserver { id, event in
            guard firstReply[id] == nil else { return }
            switch event {
            case .itemStarted, .contentDelta, .itemCompleted: firstReply[id] = realtimeNanos()
            default: break
            }
        }
        defer { supervisor.removeDeliveredEventObserver(observer) }

        func waitStarted(_ dir: URL, _ agent: AgentID, _ what: String) async throws -> Int64 {
            try await AgentPresenceChecks.eventually("\(what) CLI never started", timeout: 20) { markerBirth(in: dir, agent: agent) != nil }
            return markerBirth(in: dir, agent: agent)!
        }
        func idle(_ id: AgentID) async throws {
            try await AgentPresenceChecks.eventually("agent did not settle", timeout: 20) {
                supervisor.records[id]?.latestTurnAt != nil && !supervisor.isRunning(id)
            }
        }

        // Leads: a fresh Managed agent per sample, request at the composer entry.
        var launch: [Double] = [], reply: [Double] = []
        for i in 0..<(warmup + samples) {
            let cwd = b.binDir.appendingPathComponent("lead-\(i)", isDirectory: true)
            try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode,
                                      model: ManagedModeChecks.model, thinking: AgentModelConfig.defaultThinking)
            _ = supervisor.setMode(.managed, for: id)
            let t0 = realtimeNanos()
            let accepted = await supervisor.accept(.sendPrompt(AgentPrompt("launch timing")), for: id)
            try ManagedModeChecks.expect(accepted == .accepted, "lead submission refused")
            let started = try await waitStarted(cwd, id, "lead")
            try await AgentPresenceChecks.eventually("lead's first reply never arrived", timeout: 20) { firstReply[id] != nil }
            if i >= warmup {
                launch.append(Double(started - t0) / 1_000_000)
                reply.append(Double(firstReply[id]! - t0) / 1_000_000)
            }
            try await idle(id)
            supervisor.stop(id)
        }
        describe("lead-launch", launch)
        describe("lead-first-reply", reply)

        // Delegation round trip from the fixture's Managed Claude lead, running.
        let lead = b.f.agentId
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try ManagedModeChecks.expect(supervisor.setProviderSettings(agentID: lead, harness: .claudeCode, model: ManagedModeChecks.model),
                                     "could not select the lead's harness")
        _ = supervisor.setMode(.managed, for: lead)
        try ManagedModeChecks.expect(supervisor.effectiveMode(for: lead) == .managed, "the fixture agent is not a Managed lead")
        let leadDir = URL(fileURLWithPath: supervisor.records[lead]!.cwd, isDirectory: true)
        try ManagedModeChecks.expect(await supervisor.accept(.sendPrompt(AgentPrompt("start")), for: lead) == .accepted,
                                     "lead start refused")
        _ = try await waitStarted(leadDir, lead, "lead")
        try await idle(lead)

        var delegated: [Double] = [], wake: [Double] = []
        var lastChild: AgentID?
        for i in 0..<(warmup + samples) {
            let turnsBefore = logged("turn", in: leadDir, agent: lead).count
            let t0 = realtimeNanos()
            let answer = b.f.api.dispatch(agentId: lead, requestId: "launch-\(i)", op: "agent.delegate",
                                          payload: ["task": "launch timing \(i)", "title": "Launch \(i)",
                                                    "harness": "Claude Code", "model": "\(ManagedModeChecks.model)",
                                                    "idempotencyKey": "launch-key-\(i)-\(UUID().uuidString)"])
            guard case let .result(result) = answer,
                  let child = result["childAgentId"]?.string.flatMap(UUID.init(uuidString:)).map(AgentID.init(rawValue:)),
                  let childCwd = supervisor.records[child]?.cwd else {
                throw WorkspaceAgentReportChecks.Failure(description: "managed-timing: delegation failed: \(answer)")
            }
            let childDir = URL(fileURLWithPath: childCwd, isDirectory: true)
            lastChild = child
            let started = try await waitStarted(childDir, child, "helper")
            try await AgentPresenceChecks.eventually("helper never wrote its result", timeout: 20) {
                !logged("result", in: childDir, agent: child).isEmpty
            }
            try await AgentPresenceChecks.eventually("the lead never got a turn after the helper's result", timeout: 30) {
                logged("turn", in: leadDir, agent: lead).count > turnsBefore
            }
            let resultAt = logged("result", in: childDir, agent: child)[0]
            let wokeAt = logged("turn", in: leadDir, agent: lead)[turnsBefore]
            if i >= warmup {
                delegated.append(Double(started - t0) / 1_000_000)
                wake.append(Double(wokeAt - resultAt) / 1_000_000)
            }
            try await idle(child)
            supervisor.stop(child)
            try await idle(lead)
        }
        describe("delegate-to-helper-launch", delegated)
        describe("helper-result-to-lead-turn", wake)

        // The 30-second helper watchdog sweep on the main actor, over a store
        // holding `sweepHelpers` finished helpers (the owner's store held about
        // 2,200 agents): copies of one real helper record under new ids,
        // restored by a fresh supervisor.
        let support = AgentStore().layout.applicationSupportDirectory
        let template = AgentStoreLayout(applicationSupportDirectory: support).agentFile(id: lastChild!)
        let seeded = b.binDir.appendingPathComponent("sweep-support", isDirectory: true)
        let seededLayout = AgentStoreLayout(applicationSupportDirectory: seeded)
        try fm.createDirectory(at: seededLayout.agentsDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: AgentStoreLayout(applicationSupportDirectory: support).agentFile(id: lead), to: seededLayout.agentFile(id: lead))
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: template)) as? [String: Any] else {
            throw WorkspaceAgentReportChecks.Failure(description: "managed-timing: helper record unreadable")
        }
        for _ in 0..<sweepHelpers {
            let id = UUID()
            object["id"] = (object["id"] is String) ? id.uuidString as Any : ["rawValue": id.uuidString] as Any
            try JSONSerialization.data(withJSONObject: object).write(to: seededLayout.agentFile(id: AgentID(rawValue: id)))
        }
        let swept = AgentSupervisor(store: AgentStore(applicationSupportDirectory: seeded))
        swept.restore()
        defer { swept.stopAll() }
        let helpersRestored = swept.records.values.filter { $0.parentAgentID != nil }.count
        var sweeps: [Double] = []
        for i in 0..<(warmup + samples) {
            let start = realtimeNanos()
            await swept.sweepHelperWatchdog()
            if i >= warmup { sweeps.append(Double(realtimeNanos() - start) / 1_000_000) }
        }
        describe("watchdog-sweep-\(helpersRestored)-helpers", sweeps)
        print("Managed launch timing printed (no timing assertions)")
    }
}
