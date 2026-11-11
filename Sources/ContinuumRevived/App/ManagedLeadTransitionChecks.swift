import AppKit
import ContinuumRevivedCore
import Foundation

/// A Managed lead keeps its brief across every context it enters, and no look
/// count refuses its reads. Real lead spawn, real mode switch and relaunch,
/// the real hook executable and the authenticated hook endpoint, for Claude
/// and Codex.
@MainActor
enum ManagedLeadTransitionChecks {
    static func expect(_ condition: Bool, _ message: String) throws {
        try ManagedModeChecks.expect(condition, "transition: " + message)
    }

    static func run() async throws {
        try await claude()
        try await codex()
        print("Managed lead transition checks passed: brief once on fresh startup, resume, compaction and each switch into Managed (Claude and Codex, including after relaunch); nine reads per request allowed; edits still denied")
    }

    static func claude() async throws {
        let b = try ManagedModeChecks.bench("managed-transition"); defer { b.tearDown() }
        func session(_ id: AgentID) -> String {
            AgentSupervisor.claudeRunnerConfig(for: b.supervisor.records[id]!).sessionId
        }
        /// How many briefs one SessionStart delivered: 0 or 1, never anything else.
        func briefs(_ id: AgentID, _ source: String) async throws -> Int {
            let out = try await ManagedModeChecks.hook(b, id, ["hook_event_name": "SessionStart", "source": source, "session_id": session(id)])
            if out.isEmpty { return 0 }
            try expect(out["additionalContext"] as? String == ManagedLeadHookState.brief, "unexpected SessionStart reply \(out)")
            return 1
        }

        // (d) A fresh Managed lead: one brief at startup, none on a repeat or a resume of that context.
        let fresh = try await ManagedModeChecks.delegate(b, mode: "managed", label: "fresh")
        try await ManagedModeChecks.settled(b, fresh)
        try expect(try await briefs(fresh, "startup") == 1, "fresh startup got no brief")
        try expect(try await briefs(fresh, "startup") == 0, "fresh startup briefed twice")
        try expect(try await briefs(fresh, "resume") == 0, "resume of a briefed context briefed it again")

        // (c) A Managed lead whose context never got the brief is briefed on resume, once.
        let resumed = try await ManagedModeChecks.delegate(b, mode: "managed", label: "resumed")
        try await ManagedModeChecks.settled(b, resumed)
        try expect(try await briefs(resumed, "resume") == 1, "resumed unbriefed lead got no brief")
        try expect(try await briefs(resumed, "resume") == 0, "resumed lead briefed twice")
        // ...and an app relaunch does not brief that context a second time.
        let restored = AgentSupervisor(store: AgentStore(smokeTest: false))
        restored.restore()
        let afterRelaunch = restored.managedHookReply(for: restored.records[resumed]!, payload:
            ["hook_event_name": "SessionStart", "source": "resume", "session_id": session(resumed)])
        restored.stopAll()
        try expect(afterRelaunch == nil, "relaunched app briefed an already-briefed context: \(String(describing: afterRelaunch))")

        // (c) Compaction replaces the context: one brief, and the resume after it adds none.
        try expect(try await briefs(resumed, "compact") == 1, "compaction got no brief")
        try expect(try await briefs(resumed, "resume") == 0, "resume after compaction briefed twice")
        try expect(try await briefs(resumed, "compact") == 1, "second compaction got no brief")

        // (a) No look count: nine reads, searches and commands in one request all pass.
        _ = try await ManagedModeChecks.hook(b, resumed, ["hook_event_name": "UserPromptSubmit"])
        for (tool, command) in [("Read", ""), ("Grep", ""), ("Glob", ""), ("Bash", "ls"), ("WebFetch", ""),
                                ("WebSearch", ""), ("mcp__other__search", ""), ("Read", ""), ("Bash", "cat Package.swift")] {
            let out = try await ManagedModeChecks.hook(b, resumed, ["hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": ["command": command]])
            try expect(out.isEmpty, "lead read refused: \(tool) \(out)")
        }

        // (c) A Free lead switched into Managed: the relaunch resumes, keeps edits
        // denied (b), and the brief arrives once; again after each switch back in.
        let switched = try await ManagedModeChecks.delegate(b, mode: nil, label: "switched")
        try await ManagedModeChecks.settled(b, switched)
        try expect(try await briefs(switched, "startup") == 0, "free lead got the brief")
        for round in 1...2 {
            try expect(b.supervisor.setMode(.managed, for: switched), "switch into Managed refused")
            try expect(b.supervisor.send("managed \(round)", to: switched), "turn after switch refused")
            try await ManagedModeChecks.settled(b, switched)
            let args = try ManagedModeChecks.argv(b, switched)
            try expect(args.contains("--resume") && args.contains("Edit,Write,MultiEdit,NotebookEdit,ListAgents"),
                       "switched lead did not relaunch resumed with edits denied: \(args)")
            try expect(try await briefs(switched, "resume") == 1, "switch \(round) into Managed got no brief")
            try expect(try await briefs(switched, "resume") == 0, "switch \(round) into Managed briefed twice")
            try expect(b.supervisor.setMode(.free, for: switched), "switch to Free refused")
            try expect(b.supervisor.send("free \(round)", to: switched), "free turn refused")
            try await ManagedModeChecks.settled(b, switched)
            try expect(try await briefs(switched, "resume") == 0, "free lead got the brief")
        }
    }

    static func codex() async throws {
        let b = try ManagedCodexChecks.bench(); let restore = ManagedCodexChecks.runEnvironment(b)
        defer { b.tearDown(); restore() }
        /// Briefs the real configured hook delivered during one launch.
        func launchBriefs(_ thread: String, pid: Int?) -> Int {
            ManagedCodexChecks.rows(b, kind: "hook", session: thread)
                .filter { $0["pid"] as? Int == pid && ManagedCodexChecks.output($0)["additionalContext"] as? String == ManagedLeadHookState.brief }.count
        }
        func lastPID(_ thread: String) -> Int? { ManagedCodexChecks.rows(b, kind: "launch", session: thread).last?["pid"] as? Int }

        // (d) and the per-turn resume: Codex resumes its thread on every turn.
        let managed = try await ManagedCodexChecks.delegate(b, mode: "managed")
        try await ManagedModeChecks.settled(b, managed)
        let mid = try ManagedCodexChecks.thread(b, managed)
        try expect(launchBriefs(mid, pid: lastPID(mid)) == 1, "Codex fresh launch not briefed once")
        try expect(b.supervisor.send("second", to: managed), "Codex second turn refused")
        try await ManagedModeChecks.settled(b, managed)
        try expect(launchBriefs(mid, pid: lastPID(mid)) == 0, "Codex per-turn resume briefed again")
        try expect(ManagedCodexChecks.rows(b, kind: "hook", session: mid).contains {
            ManagedCodexChecks.output($0)["permissionDecisionReason"] as? String == ManagedLeadHookState.editDenial
        }, "Codex real hook did not deny the edit")

        // (c) Compaction through the endpoint: once.
        let compact: [String: Any] = ["hook_event_name": "SessionStart", "source": "compact", "session_id": mid]
        try expect(try await ManagedModeChecks.hook(b, managed, compact)["additionalContext"] as? String == ManagedLeadHookState.brief, "Codex compaction got no brief")
        try expect(try await ManagedModeChecks.hook(b, managed, ["hook_event_name": "SessionStart", "source": "resume", "session_id": mid]).isEmpty, "Codex resume after compaction briefed twice")

        // (a) No look count; (b) edits denied.
        _ = try await ManagedModeChecks.hook(b, managed, ["hook_event_name": "UserPromptSubmit"])
        for tool in ["exec_command", "read_file", "grep_files", "list_dir", "web_search", "shell", "view_image", "mcp__other__search", "exec_command"] {
            let out = try await ManagedModeChecks.hook(b, managed, ["hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": ["cmd": "ls", "command": "ls"]])
            try expect(out.isEmpty, "Codex lead read refused: \(tool) \(out)")
        }
        let edit = try await ManagedModeChecks.hook(b, managed, ["hook_event_name": "PreToolUse", "tool_name": "apply_patch", "tool_input": ["command": "patch"]])
        try expect(edit["permissionDecision"] as? String == "deny" && edit["permissionDecisionReason"] as? String == ManagedLeadHookState.editDenial, "Codex edit not denied: \(edit)")

        // (c) Switched into Managed: the real relaunch's own hook briefs once.
        let free = try await ManagedCodexChecks.delegate(b, mode: nil)
        try await ManagedModeChecks.settled(b, free)
        let sid = try ManagedCodexChecks.thread(b, free)
        try expect(launchBriefs(sid, pid: lastPID(sid)) == 0, "Codex free lead got the brief")
        try expect(b.supervisor.setMode(.managed, for: free), "Codex switch refused")
        try expect(b.supervisor.send("now managed", to: free), "Codex turn after switch refused")
        try await ManagedModeChecks.settled(b, free)
        try expect(ManagedCodexChecks.rows(b, kind: "launch", session: sid).last?["request"].flatMap { ($0 as? [String: Any])?["method"] as? String } == "thread/resume", "Codex switch did not resume the thread")
        try expect(launchBriefs(sid, pid: lastPID(sid)) == 1, "Codex switch into Managed not briefed once")
        try expect(b.supervisor.send("again", to: free), "Codex next turn refused")
        try await ManagedModeChecks.settled(b, free)
        try expect(launchBriefs(sid, pid: lastPID(sid)) == 0, "Codex switched lead briefed again next turn")
    }
}
