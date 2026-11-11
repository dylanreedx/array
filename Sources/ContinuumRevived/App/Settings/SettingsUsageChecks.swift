import AppKit
import ContinuumRevivedCore
import Foundation

/// `--settings-usage-check`: the production Settings model and Usage pane, in the
/// offscreen fixture window, over a ledger this check writes with the ledger
/// writer's own row type into a temporary directory. Asserts the words the rows
/// rendered (`SettingsModel.renderedTexts`).
@MainActor
enum SettingsUsageChecks {
    typealias Row = ManagedRunLedger.Row
    typealias Counts = TokenUsageSnapshot.TypedCounts

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let ledger = RunLedgerUsageReader.ledgerURL(applicationSupport: root)
        try write(fixture(now: now), to: ledger)

        try withPane(ledger: ledger) { fixture, defaults in
            let model = fixture.model
            // Settings opened on another pane: nothing counted yet.
            try expect(model.usage.qaRuns.isEmpty, "the usage count ran before its pane was shown")
            fixture.select("usage")
            try waitReady(fixture)
            let texts = model.renderedTexts

            // 1. Tasks closed in the last 7 days, coverage and the split.
            try expect(texts["usage.closed"] == "5", "tasks closed: \(texts["usage.closed"] ?? "nil")")
            try expect(texts["usage.fullyCounted"] == "2 of 5", "fully counted: \(texts["usage.fullyCounted"] ?? "nil")")
            try expect(texts["usage.split"] == "3 solo · 1 with one helper · 1 with two or more", "split: \(texts["usage.split"] ?? "nil")")
            try expect(texts["usage.notCounted"] == "Listed below but not counted: 1 still open, 1 interrupted.",
                       "open and interrupted: \(texts["usage.notCounted"] ?? "nil")")

            // 2. Exact totals by type, lead against helpers; unknown never reads as 0.
            let expected: [String: String] = [
                "usage.tokens.uncachedInput.lead": "511 · + unknown in 1 of 5",
                "usage.tokens.cacheRead.lead": "5,102 · + unknown in 1 of 5",
                "usage.tokens.cacheWrite.lead": "223 · + unknown in 2 of 5",
                "usage.tokens.output.lead": "139 · + unknown in 1 of 5",
                "usage.tokens.uncachedInput.helpers": "40 · + unknown in 1 of 5",
                "usage.tokens.cacheRead.helpers": "320 · + unknown in 1 of 5",
                "usage.tokens.cacheWrite.helpers": "70 · + unknown in 1 of 5",
                "usage.tokens.output.helpers": "46 · + unknown in 1 of 5",
                "usage.tokens.uncachedInput.all": "551 · + unknown in 2 of 5",
                "usage.tokens.cacheWrite.all": "293 · + unknown in 3 of 5",
            ]
            for (id, value) in expected.sorted(by: { $0.key < $1.key }) {
                try expect(texts[id] == value, "\(id) rendered \(texts[id] ?? "nil"), expected \(value)")
            }

            // 3. A task whose helper usage is incomplete says unknown, beside the known part.
            let rows = (0..<7).compactMap { texts["usage.task.\($0)"] }
            try expect(rows.count == 7, "the period lists 7 tasks (5 closed, 1 open, 1 interrupted), got \(rows.count)")
            guard let fanned = rows.first(where: { $0.contains("2 helpers") }) else { throw Failure("no two-helper task row") }
            try expect(fanned.contains("Helpers: input, not cached 10 · read from cache 20 · written to cache 30 · output 40, each plus an unknown part")
                       && fanned.contains("Helper Codex (gpt-x)"),
                       "the two-helper task must show its helpers' partial count as unknown: \(fanned)")
            guard let oneHelper = rows.first(where: { $0.contains("1 helper") }) else { throw Failure("no one-helper task row") }
            try expect(oneHelper.contains("Time to answer 16 min · active 11 min"),
                       "time to answer and active time (overlap counted once): \(oneHelper)")
            try expect(rows.contains { $0.contains("Still open, not counted") } && rows.contains { $0.contains("Interrupted, not counted") },
                       "open and interrupted tasks are listed")
            guard let silent = rows.first(where: { $0.contains("Harness and model unknown") && $0.contains("Closed") }) else { throw Failure("no unrecorded task row") }
            try expect(silent.contains("Lead: unknown") && !silent.contains(" 0 "),
                       "a task with no usage rows reads unknown, never 0: \(silent)")
            try expect(model.renderedTexts["usage.recordingOff"] == nil, "recording is on, but the page says it is off")

            // Export: the figures on screen, holding no names. Every string is an
            // id, a model or harness id, a date, or one of the report's fixed words.
            let export = root.appendingPathComponent("export.json")
            try model.usage.export(to: export)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: export))
            var strings: [String] = []
            func walk(_ value: Any) {
                if let dict = value as? [String: Any] { dict.values.forEach(walk) }
                else if let array = value as? [Any] { array.forEach(walk) }
                else if let string = value as? String { strings.append(string) }
            }
            walk(json)
            let fixed: Set<String> = ["week", "lead", "helpers", "open", "closed", "interrupted", "Claude Code", "Codex", "claude-x", "gpt-x"]
            let stray = strings.filter { !fixed.contains($0) && UUID(uuidString: $0) == nil && ISO8601DateFormatter().date(from: $0) == nil }
            try expect(stray.isEmpty, "the export holds words that are not ids: \(stray)")
            let exported = (json as? [String: Any])?["tokens"] as? [String: Any]
            let lead = exported?["lead"] as? [String: Any]
            try expect((lead?["uncachedInput"] as? [String: Any])?["known"] as? Int == 511
                       && (lead?["uncachedInput"] as? [String: Any])?["unknown"] as? Int == 1,
                       "the export must carry the figures on screen: \(String(describing: lead?["uncachedInput"]))")

            // 4. Both appearances render, recording on, last 7 days.
            try render(fixture, name: "light", appearance: .aqua)
            try render(fixture, name: "dark", appearance: .darkAqua)
            fixture.window.appearance = NSAppearance(named: .aqua)

            // 5. The period chooser, through the production choice button.
            guard let chooser = fixture.descendants(ChoiceButton.self).first(where: { $0.accessibilityIdentifier() == "ArraySettingsUsagePeriod" }) else {
                throw Failure("the period chooser is not a ChoiceButton")
            }
            chooser.presentsOffscreenForQA = true
            try expect(chooser.chooseForQA(id: UsageReport.Period.month.rawValue), "could not choose Last 30 days")
            chooser.dismissPresentedPopover()
            try waitReady(fixture, closed: "6")
            try expect(model.renderedTexts["usage.tokens.uncachedInput.lead"] == "1,511 · + unknown in 1 of 6"
                       && model.renderedTexts["usage.split"] == "4 solo · 1 with one helper · 1 with two or more",
                       "30 days must add the older task: \(model.renderedTexts["usage.tokens.uncachedInput.lead"] ?? "nil")")

            // 6. Off the main thread, and only while the pane is shown.
            try expect(!model.usage.qaRuns.isEmpty && model.usage.qaRuns.allSatisfy { !$0.onMain }, "a count ran on the main thread")
            let runs = model.usage.qaRuns.count
            fixture.select("general")
            model.usage.select(.all)
            fixture.settle(0.3)
            try expect(model.usage.qaRuns.count == runs, "a count ran while another pane was shown")

            // 7. Recording off: stated, the old records still shown, and the switch writes the key.
            fixture.select("usage")
            try waitReady(fixture, closed: "7")
            let switches = fixture.descendants(NSSwitch.self)
            try expect(switches.count == 1, "the Usage pane must draw the recording switch, drew \(switches.count)")
            switches[0].performClick(nil)
            fixture.settle()
            try expect(defaults.object(forKey: AgentTokenTelemetryConfig.enabledKey) as? Bool == false,
                       "the switch must write \(AgentTokenTelemetryConfig.enabledKey)")
            try expect(model.renderedTexts["usage.recordingOff"]?.hasPrefix("Token recording is off.") == true
                       && model.renderedTexts["usage.closed"] == "7",
                       "recording off must say so and keep showing what is on disk")

        }

        // 8. An empty ledger: a plain empty state, no figures.
        try withPane(ledger: root.appendingPathComponent("missing/ledger.jsonl")) { fixture, _ in
            fixture.select("usage")
            try waitReady(fixture)
            let texts = fixture.model.renderedTexts
            try expect(texts["usage.empty"]?.hasPrefix("No Managed tasks are recorded") == true, "the empty ledger has no empty state")
            try expect(!texts.keys.contains { $0.hasPrefix("usage.tokens.") || $0 == "usage.closed" }, "the empty ledger shows figures")
        }

        try timeLargeLedger(root: root, now: now)
    }

    // MARK: Fixture

    /// Five tasks closed in the last week, one 20 days ago, one open and one
    /// interrupted. Expected figures are worked by hand in `run`.
    static func fixture(now: Date) -> [Row] {
        var rows: [Row] = []
        var serial = 0
        func row(_ kind: String, _ task: UUID, _ agent: UUID, _ at: Date, part: UUID? = nil, outcome: String? = nil) -> Row {
            serial += 1
            var row = Row(kind: kind, task: task, agent: agent, part: part, source: "fixture/\(serial)", outcome: outcome)
            row.at = at
            return row
        }
        func usage(_ task: UUID, _ agent: UUID, _ at: Date, _ harness: String, _ model: String, _ counts: Counts?, incomplete: [String]? = nil) -> Row {
            var r = row("usage", task, agent, at)
            (r.harness, r.model, r.tokens, r.incomplete) = (harness, model, counts, incomplete)
            return r
        }
        func turn(_ task: UUID, _ agent: UUID, _ start: Date, _ seconds: TimeInterval) -> [Row] {
            [row("working", task, agent, start), row("turnEnded", task, agent, start.addingTimeInterval(seconds), outcome: "completed")]
        }
        func task(ago: TimeInterval, lead harness: String = "Claude Code", model: String = "claude-x", _ build: (UUID, UUID, Date) -> [Row], close: TimeInterval?, kind: String = "taskClosed") {
            let (id, lead, start) = (UUID(), UUID(), now.addingTimeInterval(-ago))
            rows.append(row("taskOpened", id, lead, start))
            rows += build(id, lead, start)
            if let close { rows.append(row(kind, id, lead, start.addingTimeInterval(close))) }
        }
        // Solo, Claude, fully counted: 5 minutes.
        task(ago: 7_200, { id, lead, s in
            turn(id, lead, s, 300) + [usage(id, lead, s.addingTimeInterval(300), "Claude Code", "claude-x", .init(uncachedInput: 100, cacheRead: 1_000, cacheWrite: 200, output: 50))]
        }, close: 300)
        // Solo, Codex: cache write unknown.
        task(ago: 86_400, { id, lead, s in
            turn(id, lead, s, 60) + [usage(id, lead, s.addingTimeInterval(60), "Codex", "gpt-x", .init(uncachedInput: 400, cacheRead: 4_000, cacheWrite: nil, output: 80))]
        }, close: 60)
        // One helper, fully counted. Lead 0-60 and 900-960, helper 30-600: active 660 s, answer 960 s.
        task(ago: 3 * 86_400, { id, lead, s in
            let helper = UUID()
            return [row("delegated", id, helper, s.addingTimeInterval(20), part: helper)]
                + turn(id, lead, s, 60) + turn(id, helper, s.addingTimeInterval(30), 570) + turn(id, lead, s.addingTimeInterval(900), 60)
                + [usage(id, lead, s.addingTimeInterval(960), "Claude Code", "claude-x", .init(uncachedInput: 10, cacheRead: 100, cacheWrite: 20, output: 5)),
                   usage(id, helper, s.addingTimeInterval(600), "Claude Code", "claude-x", .init(uncachedInput: 30, cacheRead: 300, cacheWrite: 40, output: 6))]
        }, close: 960)
        // Two helpers; the Codex helper's usage is incomplete.
        task(ago: 4 * 86_400, { id, lead, s in
            let (a, b) = (UUID(), UUID())
            return [row("delegated", id, a, s, part: a), row("delegated", id, b, s, part: b)]
                + turn(id, lead, s, 30) + turn(id, a, s, 100) + turn(id, b, s, 100) + turn(id, lead, s.addingTimeInterval(120), 30)
                + [usage(id, lead, s.addingTimeInterval(150), "Claude Code", "claude-x", .init(uncachedInput: 1, cacheRead: 2, cacheWrite: 3, output: 4)),
                   usage(id, a, s.addingTimeInterval(100), "Claude Code", "claude-x", .init(uncachedInput: 10, cacheRead: 20, cacheWrite: 30, output: 40)),
                   usage(id, b, s.addingTimeInterval(100), "Codex", "gpt-x", nil, incomplete: ["noBaseline"])]
        }, close: 150)
        // Solo, closed while recording was off: no usage rows at all.
        task(ago: 6 * 86_400, { id, lead, s in turn(id, lead, s, 90) }, close: 90)
        // Solo, 20 days ago: only in 30 days and all time.
        task(ago: 20 * 86_400, { id, lead, s in
            turn(id, lead, s, 60) + [usage(id, lead, s.addingTimeInterval(60), "Claude Code", "claude-x", .init(uncachedInput: 1_000, cacheRead: 0, cacheWrite: 0, output: 1_000))]
        }, close: 60)
        // Still open; and one interrupted. Listed, never counted.
        task(ago: 3_600, { id, lead, s in [row("working", id, lead, s)] }, close: nil)
        task(ago: 2 * 86_400, { id, lead, s in
            turn(id, lead, s, 40) + [usage(id, lead, s.addingTimeInterval(40), "Claude Code", "claude-x", .init(uncachedInput: 9_999, cacheRead: 9_999, cacheWrite: 9_999, output: 9_999))]
        }, close: 40, kind: "taskInterrupted")
        // A task closed before this all-time window only matters for "All time".
        task(ago: 400 * 86_400, { id, lead, s in turn(id, lead, s, 10) }, close: 10)
        return rows
    }

    static func write(_ rows: [Row], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var data = Data()
        for row in rows { data.append(try encoder.encode(row)); data.append(10) }
        try data.write(to: url)
    }

    // MARK: Driving

    static func withPane(ledger: URL, _ body: (SettingsFixtureWindow, UserDefaults) throws -> Void) throws {
        let suite = "continuum.settingsUsage.selfcheck.\(UUID().uuidString)"
        guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else { throw Failure("could not create the isolated defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsModel(defaults: defaults, navKeymap: .resolve(defaults: defaults, warn: { _ in }), initialPaneID: "general")
        model.usage.ledgerURL = ledger
        // Tall enough that every listed task is on screen and renders its words.
        let fixture = SettingsFixtureWindow(model: model, size: NSSize(width: 1_100, height: 2_400), appearance: NSAppearance(named: .aqua))
        defer { fixture.tearDown() }
        fixture.show(paneID: "general")
        try body(fixture, defaults)
    }

    static func waitReady(_ fixture: SettingsFixtureWindow, closed: String? = nil, timeout: TimeInterval = 60) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            fixture.settle(0.03)
            if case .ready = fixture.model.usage.phase,
               closed == nil || fixture.model.renderedTexts["usage.closed"] == closed { return }
        }
        throw Failure("the usage pane did not finish counting (closed=\(fixture.model.renderedTexts["usage.closed"] ?? "nil"))")
    }

    static func render(_ fixture: SettingsFixtureWindow, name: String, appearance: NSAppearance.Name) throws {
        fixture.window.appearance = NSAppearance(named: appearance)
        fixture.settle(0.2)
        guard let rep = fixture.snapshot() else { throw Failure("could not render \(name)") }
        let metrics = VisualSnapshot.metrics(of: rep)
        try expect(!metrics.isBlank, "\(name) rendered blank")
        let luminance = SettingsFixtureWindow.meanLuminance(rep)
        try expect(appearance == .darkAqua ? luminance < 0.35 : luminance > 0.6, "\(name) luminance \(luminance)")
        let dir = URL(fileURLWithPath: "/tmp/usage-page", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        // The lower half, for review: the pane's scroll view at its end.
        if let scroll = fixture.descendants(NSScrollView.self).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
           let document = scroll.documentView {
            let top = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0))
            fixture.settle(0.2)
            if let lower = fixture.snapshot() {
                try? lower.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-lower.png"))
            }
            scroll.contentView.scroll(to: top)
            fixture.settle(0.1)
        }
        print("settings-usage: \(name) render luminance \(String(format: "%.2f", luminance)) -> /tmp/usage-page/\(name).png")
    }

    /// Prints timings for a large ledger; asserts only that it counts right.
    static func timeLargeLedger(root: URL, now: Date) throws {
        let ledger = root.appendingPathComponent("large/run-ledger/ledger.jsonl")
        var rows: [Row] = []
        let tasks = 25_000
        for index in 0..<tasks {
            let (id, lead, helper) = (UUID(), UUID(), UUID())
            let start = now.addingTimeInterval(-Double(index) * 60)
            func r(_ kind: String, _ agent: UUID, _ offset: TimeInterval) -> Row {
                var row = Row(kind: kind, task: id, agent: agent, source: "large/\(index)/\(kind)/\(agent)")
                row.at = start.addingTimeInterval(offset)
                return row
            }
            var usage = r("usage", lead, 50)
            (usage.harness, usage.model, usage.tokens) = ("Claude Code", "claude-x", .init(uncachedInput: 1, cacheRead: 2, cacheWrite: 3, output: 4))
            rows += [r("taskOpened", lead, 0), r("submission", lead, 0), r("delegated", helper, 1), r("working", lead, 0),
                     r("turnEnded", lead, 5), r("working", helper, 2), r("reported", helper, 40), r("turnEnded", helper, 40),
                     usage, r("working", lead, 41), r("turnEnded", lead, 50), r("taskClosed", lead, 50)]
        }
        try write(rows, to: ledger)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: ledger.path)[.size] as? NSNumber)?.intValue ?? 0
        try withPane(ledger: ledger) { fixture, _ in
            let open = Date()
            fixture.model.selectPane("usage")
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            let mainMs = Date().timeIntervalSince(open) * 1_000
            try waitReady(fixture)
            let readyMs = Date().timeIntervalSince(open) * 1_000
            // Bounded: the list draws one page of rows, however long the ledger.
            try expect(fixture.model.renderedTexts["usage.task.\(SettingsUsageModel.page - 1)"] != nil
                       && fixture.model.renderedTexts["usage.task.\(SettingsUsageModel.page)"] == nil,
                       "the task list must draw exactly \(SettingsUsageModel.page) rows on a large ledger")
            fixture.model.usage.select(.all)
            let periodStart = Date()
            try waitReady(fixture, closed: UsageWords.count(tasks))
            let periodMs = Date().timeIntervalSince(periodStart) * 1_000
            guard let first = fixture.model.usage.qaRuns.first, let second = fixture.model.usage.qaRuns.last else { throw Failure("no timed run") }
            print(String(format: "settings-usage: large ledger %d rows, %.1f MB, %d tasks", rows.count, Double(bytes) / 1_048_576, tasks))
            print(String(format: "settings-usage: main thread to show the pane %.1f ms; first figures on screen %.0f ms (read %.0f ms, report %.0f ms, off main)",
                         mainMs, readyMs, first.readSeconds * 1_000, first.reportSeconds * 1_000))
            print(String(format: "settings-usage: period change to All time %.0f ms (cached read %.1f ms, report %.0f ms)",
                         periodMs, second.readSeconds * 1_000, second.reportSeconds * 1_000))
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }
}
