import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Shell rows in a managed agent's transcript (launch polish, item J).
//
// Reported: a Codex transcript was a stack of rows each reading "Shell", a
// subtitle "Exit code: 0" and "0.0s ✓"; a Claude transcript read "Bash ·
// 0.1s ✓". Neither said what ran.
//
// Each harness's REAL translator is fed its real event shapes, and every event
// and observation goes in through the same doors production uses — the tile's
// `ingest(_:originalEvent:)` for events, the list's `captureRuntimeObservation`
// for the host-local side channel (what the supervisor's observer calls). The
// row is then drawn by the production `ToolCallRenderer` from the block the
// list itself composes, and the assertions read the words on that view.
@MainActor
enum ShellToolRowChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func fail(_ message: String) -> Failure { Failure(description: message) }

    static func run() async throws {
        // Every harness runs and reports, so one red harness cannot hide another.
        var lines: [String] = []
        var failures: [String] = []
        for section in [checkCodexAppServer, checkCodexExecArgv, checkClaude, checkPi] {
            do { lines += try await section() } catch { failures.append(String(describing: error)) }
        }
        guard failures.isEmpty else { throw fail(failures.joined(separator: "\n")) }
        for line in lines { print("  \(line)") }
        print("ShellToolRowChecks passed: \(lines.count) shell rows across codex app-server, codex exec, claude and pi name the command, hide a zero exit, badge a non-zero one, and show a duration only when it is real")
    }

    // MARK: - Harness drivers

    /// What a reader sees on one row, collapsed and then expanded.
    struct RenderedRow: CustomStringConvertible {
        let title: String
        let status: String
        let compact: String
        let expandedSummary: String
        let expandedOutput: String
        /// The height the list reserves for the row collapsed.
        let collapsedHeight: CGFloat
        var collapsed: String { [title, status, compact].joined(separator: " | ") }
        var description: String {
            "title='\(title)' status='\(status)' compact='\(compact)' expanded='\(expandedSummary)' output='\(expandedOutput.prefix(80))'"
        }
    }

    private static func makeTile(_ title: String) -> (ManagedAgentTileNSView, NSWindow) {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: title,
            frame: TileFrame(x: 0, y: 0, width: 620, height: 640),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 620, height: 640)
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        tile.qaTranscriptForChecks?.bindToolDetailAgent(AgentID(rawValue: UUID()))
        return (tile, window)
    }

    /// Feeds raw provider lines through one translator into one tile, the way
    /// production delivers them: observations as the translator fires them,
    /// then the events it returns, each rebound to the tile's thread.
    private static func drive(
        _ tile: ManagedAgentTileNSView,
        lines: [String],
        translate: (String, @escaping @Sendable (AgentRuntimeObservation) -> Void) -> [AgentRuntimeEvent]
    ) {
        final class Inbox: @unchecked Sendable {
            var observations: [AgentRuntimeObservation] = []
        }
        for line in lines {
            let inbox = Inbox()
            let events = translate(line) { inbox.observations.append($0) }
            for observation in inbox.observations {
                tile.qaTranscriptForChecks?.captureRuntimeObservation(observation)
            }
            for event in events {
                tile.ingest(event.withThreadId(tile.qaThreadIdForChecks), originalEvent: event)
            }
        }
    }

    /// The tool blocks in the tile's document, keyed by provider item id.
    private static func toolBlocks(_ tile: ManagedAgentTileNSView) -> [String: AgentNodeID] {
        var result: [String: AgentNodeID] = [:]
        for entry in tile.qaDocumentForChecks.entries {
            guard case let .providerItem(_, itemID?) = entry.provenance,
                  let block = entry.blocks.first(where: { $0.kind == .toolCall }) else { continue }
            result[itemID] = block.id
        }
        return result
    }

    /// The detail store is written on detached tasks, one per observation, each
    /// with its own refresh. Wait for the presented rows to stop moving.
    private static func settle(_ tile: ManagedAgentTileNSView) async throws {
        func snapshot() -> [String] {
            toolBlocks(tile).sorted { $0.key < $1.key }.map { _, id in
                String(describing: tile.qaTranscriptForChecks?.qaPresentedToolBlock(for: id))
            }
        }
        let deadline = Date().addingTimeInterval(5)
        var previous = snapshot()
        var stable = 0
        while Date() < deadline {
            await tile.qaTranscriptForChecks?.qaWaitForToolDetailRefresh()
            try? await Task.sleep(nanoseconds: 5_000_000)
            let current = snapshot()
            stable = current == previous ? stable + 1 : 0
            previous = current
            if stable >= 20 { return }
        }
        throw fail("settle: the presented tool rows never stopped changing within 5s")
    }

    /// Draws one row with the production renderer, reads it collapsed, opens
    /// its disclosure the way a click does, and reads it again.
    private static func render(_ tile: ManagedAgentTileNSView, itemID: String) throws -> RenderedRow {
        guard let blockID = toolBlocks(tile)[itemID] else {
            throw fail("\(itemID): no tool row in the document (have \(toolBlocks(tile).keys.sorted()))")
        }
        guard let block = tile.qaTranscriptForChecks?.qaPresentedToolBlock(for: blockID) else {
            throw fail("\(itemID): the list composed no presented tool block")
        }
        let renderer = ToolCallRenderer()
        guard let view = renderer.makeView() as? ToolCallView else { throw fail("renderer made no ToolCallView") }
        let context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        let width: CGFloat = 560
        // Collapsed first: the default for a settled row. A failed or running
        // row defaults OPEN, so read its collapsed face by closing it.
        view.frame = NSRect(x: 0, y: 0, width: width, height: renderer.measure(block: block, width: width, context: context))
        renderer.update(view: view, block: block, context: context)
        if view.isExpanded { view.disclosureButton.performClick(nil) }
        view.layoutSubtreeIfNeeded()
        let title = view.titleLabel.stringValue
        let status = view.statusLabel.stringValue
        let compact = view.summaryLabel.isHidden ? "" : view.summaryLabel.stringValue
        if !view.isExpanded, !view.disclosureButton.isHidden { view.disclosureButton.performClick(nil) }
        view.frame.size.height = 600
        view.layoutSubtreeIfNeeded()
        let expandedSummary = view.isExpanded && !view.summaryLabel.isHidden ? view.summaryLabel.stringValue : ""
        let expandedOutput = view.isExpanded && !view.outputScrollView.isHidden ? view.outputTextView.string : ""
        guard case let .toolCall(payload) = block.payload else { throw fail("\(itemID): not a tool call") }
        let collapsedHeight = ToolCallView.measuredHeight(
            summary: payload.summary,
            title: ToolCallView.safeSingleLine(payload.name, fallback: "Tool"),
            statusLabel: payload.status.agentToolStatusPresentation.label,
            outputText: payload.presentedOutputText, outputNote: payload.presentedOutputNote,
            shell: payload.presentedShell, width: width, expanded: false, zoom: context.pageZoom)
        let row = RenderedRow(title: title, status: status, compact: compact,
                              expandedSummary: expandedSummary, expandedOutput: expandedOutput,
                              collapsedHeight: collapsedHeight)
        // A run of commands reads like a terminal log: one line per command,
        // with nothing beneath it until the reader opens it.
        guard compact.isEmpty, collapsedHeight == ToolCallView.rowHeight(zoom: context.pageZoom) else {
            throw fail("\(itemID): a collapsed shell row must be one line (\(collapsedHeight)pt vs \(ToolCallView.rowHeight)pt) — \(row)")
        }
        return row
    }

    /// The description + command headline is painted from registered tokens
    /// in BOTH appearances, and repaints when the appearance flips: the
    /// description in primary text, the command in secondary text.
    private static func checkShellTitleTokens(_ tile: ManagedAgentTileNSView, itemID: String) throws {
        guard let blockID = toolBlocks(tile)[itemID],
              let block = tile.qaTranscriptForChecks?.qaPresentedToolBlock(for: blockID) else {
            throw fail("\(itemID): no presented row to check tokens on")
        }
        let renderer = ToolCallRenderer()
        guard let view = renderer.makeView() as? ToolCallView else { throw fail("renderer made no ToolCallView") }
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 40)
        let context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        for (name, theme) in [(NSAppearance.Name.darkAqua, TokenTheme.dark), (.aqua, .light)] {
            view.appearance = NSAppearance(named: name)
            renderer.update(view: view, block: block, context: context)
            view.viewDidChangeEffectiveAppearance()
            let title = view.titleLabel.attributedStringValue
            guard title.length > 2 else { throw fail("\(itemID) \(theme): the title has no attributed runs") }
            let descriptionColor = title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            let commandColor = title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor
            let primary = context.tokens.primaryText.color.nsColor(for: theme)
            let secondary = context.tokens.secondaryText.color.nsColor(for: theme)
            guard descriptionColor == primary, commandColor == secondary, primary != secondary else {
                throw fail("\(itemID) \(theme): the headline must paint the description in primaryText and the command in secondaryText, got \(String(describing: descriptionColor)) / \(String(describing: commandColor))")
            }
            let commandFont = title.attribute(.font, at: title.length - 1, effectiveRange: nil) as? NSFont
            guard commandFont?.isFixedPitch == true else {
                throw fail("\(itemID) \(theme): the command must be set in the mono token, got \(String(describing: commandFont))")
            }
        }
    }

    // MARK: - Shared assertions

    private static func expectHeadline(_ row: RenderedRow, contains command: String, _ label: String) throws {
        guard row.title.contains(command) else {
            throw fail("\(label): the row must name the command '\(command)' — \(row)")
        }
    }

    private static func expectNoExitText(_ row: RenderedRow, _ label: String) throws {
        let visible = [row.collapsed, row.expandedSummary].joined(separator: " | ")
        for noise in ["Exit code", "exit code", "Exit 0", "exit 0", "Command exited", "Completed"] where visible.contains(noise) {
            throw fail("\(label): a successful command must show no exit status, found '\(noise)' — \(row)")
        }
    }

    private static func expectNoDuration(_ row: RenderedRow, _ label: String) throws {
        if row.status.range(of: #"\d+(\.\d)?s\b"#, options: .regularExpression) != nil {
            throw fail("\(label): no real duration exists, so none may be shown — \(row)")
        }
    }

    private static func expectFailure(_ row: RenderedRow, exit code: Int, stderr: String, _ label: String) throws {
        guard row.status.contains("exit \(code)") else {
            throw fail("\(label): a failing command must carry an 'exit \(code)' badge — \(row)")
        }
        guard !row.collapsed.contains("Exit code") else {
            throw fail("\(label): the badge replaces the 'Exit code' line, it does not join it — \(row)")
        }
        guard row.expandedOutput.contains(stderr) else {
            throw fail("\(label): the expanded output must carry the command's stderr '\(stderr)' — \(row)")
        }
    }

    private static func expectRunning(_ row: RenderedRow, _ label: String) throws {
        guard row.status.contains(AgentItemStatus.inProgress.agentToolStatusPresentation.glyph) else {
            throw fail("\(label): a running command must show the running state — \(row)")
        }
    }

    // MARK: - Codex, app-server (the production default transport)

    private static func checkCodexAppServer() async throws -> [String] {
        let (tile, window) = makeTile("shell-codex-appserver")
        defer { window.orderOut(nil) }
        let thread = "00000000-0000-4000-8000-000000000001"
        let turn = "00000000-0000-4000-8000-000000000002"
        func item(_ id: String, _ command: String, cwd: String = "/tmp/fixture", output: String?, exit: Int?, status: String, durationMs: Int?) -> String {
            let fields: [String: Any?] = [
                "aggregatedOutput": output, "command": command, "commandActions": [] as [Any],
                "cwd": cwd, "durationMs": durationMs, "exitCode": exit, "id": id, "pluginId": nil,
                "processId": "4242", "scriptPath": nil, "source": "unifiedExecStartup",
                "status": status, "type": "commandExecution",
            ]
            let data = try! JSONSerialization.data(withJSONObject: fields.mapValues { $0 ?? NSNull() }, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        func frame(_ method: String, _ item: String) -> String {
            #"{"method":"\#(method)","params":{"item":\#(item),"threadId":"\#(thread)","turnId":"\#(turn)"}}"#
        }
        let multiLine = "/bin/zsh -lc \"set -e\nfor f in a b; do\n  echo \\\"$f\\\"\ndone\""
        let lines: [String] = [
            #"{"method":"thread/started","params":{"thread":{"id":"\#(thread)","cwd":"/tmp/fixture"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"\#(thread)","turn":{"id":"\#(turn)","items":[],"status":"inProgress","error":null}}}"#,
            // Verbatim from `codex-appserver-single-agent.jsonl` (codex-cli
            // 0.148.0): both frames emitted in the same millisecond, durationMs 0.
            #"{"emittedAtMs": 1787613786101, "method": "item/started", "params": {"item": {"aggregatedOutput": null, "command": "/bin/zsh -lc 'echo hi-from-codex'", "commandActions": [{"command": "echo hi-from-codex", "type": "unknown"}], "cwd": "/tmp/fixture", "durationMs": null, "exitCode": null, "id": "exec-fixture0005", "pluginId": null, "processId": "12081", "scriptPath": null, "source": "unifiedExecStartup", "status": "inProgress", "type": "commandExecution"}, "startedAtMs": 1787613786098, "threadId": "00000000-0000-4000-8000-000000000001", "turnId": "00000000-0000-4000-8000-000000000002"}}"#,
            #"{"emittedAtMs": 1787613786101, "method": "item/completed", "params": {"completedAtMs": 1787613786099, "item": {"aggregatedOutput": "hi-from-codex\n", "command": "/bin/zsh -lc 'echo hi-from-codex'", "commandActions": [{"command": "echo hi-from-codex", "type": "unknown"}], "cwd": "/tmp/fixture", "durationMs": 0, "exitCode": 0, "id": "exec-fixture0005", "pluginId": null, "processId": "12081", "scriptPath": null, "source": "unifiedExecStartup", "status": "completed", "type": "commandExecution"}, "threadId": "00000000-0000-4000-8000-000000000001", "turnId": "00000000-0000-4000-8000-000000000002"}}"#,
            frame("item/started", item("exec-fail", "/bin/zsh -lc 'ls /nope'", output: nil, exit: nil, status: "inProgress", durationMs: nil)),
            frame("item/completed", item("exec-fail", "/bin/zsh -lc 'ls /nope'", output: "ls: /nope: No such file or directory\n", exit: 2, status: "failed", durationMs: 1240)),
            frame("item/started", item("exec-multi", multiLine, output: nil, exit: nil, status: "inProgress", durationMs: nil)),
            frame("item/completed", item("exec-multi", multiLine, output: "a\nb\n", exit: 0, status: "completed", durationMs: 3400)),
            frame("item/started", item("exec-running", "/bin/zsh -lc 'sleep 30'", cwd: "/tmp/fixture/sub", output: nil, exit: nil, status: "inProgress", durationMs: nil)),
        ]
        // A clock that never moves: every arrival gap is zero, so any duration
        // the row prints has to have come from codex's own `durationMs`.
        var translator = CodexAppServerEventTranslator(
            workingDirectory: URL(fileURLWithPath: "/tmp/fixture"),
            now: { Date(timeIntervalSinceReferenceDate: 813_000_000) })
        drive(tile, lines: lines) { line, sink in
            translator.onRuntimeObservation = sink
            return translator.translate(line: line)
        }
        try await settle(tile)

        let ok = try render(tile, itemID: "exec-fixture0005")
        try expectHeadline(ok, contains: "echo hi-from-codex", "codex app-server success")
        guard !ok.title.contains("zsh"), !ok.title.contains("-lc") else {
            throw fail("codex app-server success: the login-shell wrapper must be unwrapped — \(ok)")
        }
        try expectNoExitText(ok, "codex app-server success")
        try expectNoDuration(ok, "codex app-server success (durationMs 0, same-ms frames)")

        let failed = try render(tile, itemID: "exec-fail")
        try expectHeadline(failed, contains: "ls /nope", "codex app-server exit 2")
        try expectFailure(failed, exit: 2, stderr: "No such file or directory", "codex app-server exit 2")
        guard failed.status.contains("1.2s") else {
            throw fail("codex app-server exit 2: codex measured 1240ms, so the row must say 1.2s — \(failed)")
        }

        let multi = try render(tile, itemID: "exec-multi")
        guard multi.title.hasPrefix("set -e"), multi.title.contains("…") else {
            throw fail("codex app-server multi-line: the headline is the first line, marked as continuing — \(multi)")
        }
        guard multi.expandedSummary.contains("done"), multi.expandedSummary.contains("for f in a b") else {
            throw fail("codex app-server multi-line: the expanded row must show the whole command — \(multi)")
        }
        try expectNoExitText(multi, "codex app-server multi-line")

        let running = try render(tile, itemID: "exec-running")
        try expectHeadline(running, contains: "sleep 30", "codex app-server running")
        try expectRunning(running, "codex app-server running")
        guard running.expandedSummary.contains("sub") else {
            throw fail("codex app-server running: a cwd away from the agent's home must be shown — \(running)")
        }
        return [ok, failed, multi, running].map(\.description)
    }

    // MARK: - Codex, exec --json (argv form)

    private static func checkCodexExecArgv() async throws -> [String] {
        let (tile, window) = makeTile("shell-codex-exec")
        defer { window.orderOut(nil) }
        // `codex exec --json`: the 0.145 capture sends `command` as a joined
        // string (`codex-exec-single-agent-parity.jsonl`); older builds sent the
        // argv array. Both reach the same row.
        let lines = [
            #"{"type":"thread.started","thread_id":"019fe980-21f0-7df1-b2a0-49d7839c7937"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":["bash","-lc","git status --short"],"aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":["bash","-lc","git status --short"],"aggregated_output":" M README.md\n","exit_code":0,"status":"completed"}}"#,
            #"{"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \"wc -l note.txt && sed -n '1p' note.txt\"","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \"wc -l note.txt && sed -n '1p' note.txt\"","aggregated_output":"       1 note.txt\nedited\n","exit_code":0,"status":"completed"}}"#,
        ]
        var translator = CodexEventTranslator(runToken: "shell", now: { Date(timeIntervalSinceReferenceDate: 813_000_000) })
        drive(tile, lines: lines) { line, sink in
            translator.onRuntimeObservation = sink
            return translator.translate(line: line)
        }
        try await settle(tile)
        let argv = try render(tile, itemID: "shell-item_1")
        try expectHeadline(argv, contains: "git status --short", "codex exec argv")
        guard !argv.title.contains("bash") else {
            throw fail("codex exec argv: [\"bash\",\"-lc\",…] must be unwrapped — \(argv)")
        }
        try expectNoExitText(argv, "codex exec argv")
        try expectNoDuration(argv, "codex exec argv (same-instant frames)")
        let joined = try render(tile, itemID: "shell-item_2")
        try expectHeadline(joined, contains: "wc -l note.txt && sed -n '1p' note.txt", "codex exec joined string")
        return [argv, joined].map(\.description)
    }

    // MARK: - Claude Code

    private static func checkClaude() async throws -> [String] {
        let (tile, window) = makeTile("shell-claude")
        defer { window.orderOut(nil) }
        // stream-json shapes: Bash `input` is {command, description?, timeout?,
        // run_in_background?}; a failing command's tool_result is `is_error`
        // with "Exit code N" as its first line (shape confirmed against real
        // claude session logs); the frame carries `tool_use_result`.
        func use(_ id: String, _ input: String) -> String {
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":\#(input)}]},"parent_tool_use_id":null}"#
        }
        func result(_ id: String, content: String, isError: Bool, extra: String) -> String {
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"\#(content)","is_error":\#(isError)}]},"parent_tool_use_id":null,"tool_use_result":\#(extra)}"#
        }
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"shell-claude","cwd":"/tmp/fixture","model":"claude-fixture"}"#,
            use("toolu_desc", #"{"command":"ls -la .build","description":"List the build products"}"#),
            result("toolu_desc", content: "total 0", isError: false,
                   extra: #"{"stdout":"total 0","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}"#),
            use("toolu_fail", #"{"command":"ls /nope"}"#),
            result("toolu_fail", content: #"Exit code 2\nls: /nope: No such file or directory"#, isError: true,
                   extra: #""Error: Exit code 2\nls: /nope: No such file or directory""#),
            use("toolu_ok", #"{"command":"git status --short"}"#),
            result("toolu_ok", content: " M README.md", isError: false,
                   extra: #"{"stdout":" M README.md","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}"#),
            // Real claude 2.1 shapes from session logs: a run_in_background
            // call, and a call claude moved to the background at its timeout.
            use("toolu_bg", #"{"command":"npm run dev","run_in_background":true}"#),
            result("toolu_bg", content: "Command running in background with ID: b3qp2iimv.", isError: false,
                   extra: #"{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"b3qp2iimv"}"#),
            use("toolu_timeout", #"{"command":"swift build","timeout":600000}"#),
            result("toolu_timeout", content: "Command did not complete within its 600s timeout and was moved to the background (ID: bbvgt4q80).", isError: false,
                   extra: #"{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"bbvgt4q80","timedOutAfterMs":600000}"#),
            use("toolu_running", #"{"command":"sleep 30","description":"Wait for the server"}"#),
        ]
        final class Clock: @unchecked Sendable {
            var tick: TimeInterval = 0
            func next() -> Date { tick += 0.4; return Date(timeIntervalSinceReferenceDate: 813_000_000 + tick) }
        }
        let clock = Clock()
        var translator = ClaudeEventTranslator(runToken: "shell", now: { clock.next() })
        drive(tile, lines: lines) { line, sink in
            translator.onRuntimeObservation = sink
            return translator.translate(line: line)
        }
        try await settle(tile)

        let described = try render(tile, itemID: "toolu_desc")
        guard described.title.contains("List the build products"), described.title.contains("ls -la .build") else {
            throw fail("claude with description: the row must read the description AND the command — \(described)")
        }
        try expectNoExitText(described, "claude with description")
        try checkShellTitleTokens(tile, itemID: "toolu_desc")

        let failed = try render(tile, itemID: "toolu_fail")
        try expectHeadline(failed, contains: "ls /nope", "claude exit 2")
        guard failed.title != "Bash" else { throw fail("claude exit 2: the row still reads only 'Bash' — \(failed)") }
        try expectFailure(failed, exit: 2, stderr: "No such file or directory", "claude exit 2")

        let ok = try render(tile, itemID: "toolu_ok")
        try expectHeadline(ok, contains: "git status --short", "claude success")
        try expectNoExitText(ok, "claude success")

        let background = try render(tile, itemID: "toolu_bg")
        try expectHeadline(background, contains: "npm run dev", "claude background")
        guard background.status.contains("background") else {
            throw fail("claude background: a backgrounded command must say so — \(background)")
        }
        let timedOut = try render(tile, itemID: "toolu_timeout")
        try expectHeadline(timedOut, contains: "swift build", "claude timeout")
        guard timedOut.status.contains("timed out"),
              !timedOut.status.contains(AgentItemStatus.completed.agentToolStatusPresentation.glyph) else {
            throw fail("claude timeout: a timed-out command must carry its own badge and no success glyph — \(timedOut)")
        }

        let running = try render(tile, itemID: "toolu_running")
        guard running.title.contains("Wait for the server"), running.title.contains("sleep 30") else {
            throw fail("claude running: the row must name the command while it runs — \(running)")
        }
        try expectRunning(running, "claude running")
        return [described, failed, ok, background, timedOut, running].map(\.description)
    }

    // MARK: - Pi

    private static func checkPi() async throws -> [String] {
        let (tile, window) = makeTile("shell-pi")
        defer { window.orderOut(nil) }
        // pi's `bash` tool: args {command, timeout?}. A non-zero exit throws, so
        // `tool_execution_end` is `isError` and the result text ends with pi's
        // own "Command exited with code N" status line (bash.js appendStatus).
        let lines = [
            #"{"type":"session","id":"shell-pi","cwd":"/tmp/fixture"}"#,
            #"{"type":"agent_start"}"#,
            #"{"ts":"2026-10-16T10:00:00.000Z","type":"tool_execution_start","toolCallId":"pi_ok","toolName":"bash","args":{"command":"echo ok"}}"#,
            #"{"ts":"2026-10-16T10:00:00.300Z","type":"tool_execution_end","toolCallId":"pi_ok","toolName":"bash","result":{"content":[{"type":"text","text":"ok"}]},"isError":false}"#,
            #"{"ts":"2026-10-16T10:00:01.000Z","type":"tool_execution_start","toolCallId":"pi_fail","toolName":"bash","args":{"command":"ls /nope"}}"#,
            #"{"ts":"2026-10-16T10:00:03.500Z","type":"tool_execution_end","toolCallId":"pi_fail","toolName":"bash","result":{"content":[{"type":"text","text":"ls: /nope: No such file or directory\n\nCommand exited with code 2"}]},"isError":true}"#,
            #"{"ts":"2026-10-16T10:00:03.600Z","type":"tool_execution_start","toolCallId":"pi_timeout","toolName":"bash","args":{"command":"sleep 99","timeout":5}}"#,
            #"{"ts":"2026-10-16T10:00:08.600Z","type":"tool_execution_end","toolCallId":"pi_timeout","toolName":"bash","result":{"content":[{"type":"text","text":"Command timed out after 5 seconds"}]},"isError":true}"#,
            #"{"ts":"2026-10-16T10:00:08.700Z","type":"tool_execution_start","toolCallId":"pi_abort","toolName":"bash","args":{"command":"tail -f log.txt"}}"#,
            #"{"ts":"2026-10-16T10:00:09.700Z","type":"tool_execution_end","toolCallId":"pi_abort","toolName":"bash","result":{"content":[{"type":"text","text":"line 1\n\nCommand aborted"}]},"isError":true}"#,
            #"{"ts":"2026-10-16T10:00:10.000Z","type":"tool_execution_start","toolCallId":"pi_running","toolName":"bash","args":{"command":"sleep 30","timeout":60}}"#,
        ]
        var translator = PiEventTranslator(now: { Date(timeIntervalSinceReferenceDate: 813_000_000) })
        drive(tile, lines: lines) { line, sink in
            translator.onRuntimeObservation = sink
            return translator.translate(line: line)
        }
        try await settle(tile)

        let ok = try render(tile, itemID: "pi_ok")
        try expectHeadline(ok, contains: "echo ok", "pi success")
        try expectNoExitText(ok, "pi success")

        let failed = try render(tile, itemID: "pi_fail")
        try expectHeadline(failed, contains: "ls /nope", "pi exit 2")
        try expectFailure(failed, exit: 2, stderr: "No such file or directory", "pi exit 2")
        guard failed.status.contains("2.5s") else {
            throw fail("pi exit 2: pi stamped 2.5s between start and end — \(failed)")
        }

        let timedOut = try render(tile, itemID: "pi_timeout")
        guard timedOut.status.contains("timed out"), !timedOut.collapsed.contains("Command timed out") else {
            throw fail("pi timeout: the row must badge 'timed out' rather than print pi's status line — \(timedOut)")
        }
        let aborted = try render(tile, itemID: "pi_abort")
        guard aborted.status.contains("interrupted"), aborted.expandedOutput.contains("line 1"),
              !aborted.expandedOutput.contains("Command aborted") else {
            throw fail("pi abort: the row must badge 'interrupted' and keep the output above pi's status line — \(aborted)")
        }

        let running = try render(tile, itemID: "pi_running")
        try expectHeadline(running, contains: "sleep 30", "pi running")
        try expectRunning(running, "pi running")
        return [ok, failed, timedOut, aborted, running].map(\.description)
    }
}
