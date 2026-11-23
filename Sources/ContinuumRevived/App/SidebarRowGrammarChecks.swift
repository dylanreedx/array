import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--sidebar-row-grammar-check`. Every state a sidebar row can be in
/// (`~/array-scratch/sidebar-row-states/STATES.md`), rendered through the
/// production `AgentInboxView` and its real cells, icons on and off, light and
/// dark, and held to one row grammar:
///
/// - G1 no row draws two characters;
/// - G2 one status signal per row (character, plate, gyro, dots, status glyph,
///   provider mark and fold glyph are all signals);
/// - G3 a nested helper is shifted by exactly one step: its character and its
///   title move by the same amount, and that amount is the depth-1 row's
///   distance from its character column to its title;
/// - G4 a title beside a pill keeps at least `pillTitleRoom` pt;
/// - G5 truncated helper titles all end at one x, whatever sits after them;
/// - G6 the lead's summary line leads with what is live, not the lifetime total;
/// - G7 every lead title starts at one x, identity colour or not.
///
/// `ARRAY_ROW_STATES_OUT` writes one contact sheet per kind (lead, helper,
/// nested) with columns icons-on light/dark, icons-off light/dark, and an
/// interaction column (selected + hovered, classic active style).
@MainActor
enum SidebarRowGrammarChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let now = Date(timeIntervalSinceReferenceDate: 820_000_000)
    static let width: CGFloat = 300
    /// At a 300 pt sidebar: a depth-1 helper keeps ~140 pt, a depth-2 one ~110.
    static let pillTitleRoom: CGFloat = 100
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "2E000000-0000-4000-8000-%012X", n))! }

    enum Kind: String, CaseIterable { case lead, helper, nested }

    // MARK: Fixture

    struct Spec {
        var n: Int
        var title: String
        var state: InboxState
        var parent: Int? = nil
        var depth = 0
        var model = "claude-sonnet-5-5"
        var colour: String? = nil
        var branch: String? = nil
        var outcome: AgentTerminalOutcome? = nil
        var unread = false
        var attention: InboxAttention = .none
        var report: InboxSelfReport? = nil
        var unconfirmed = false
        var failure: String? = nil
        var usageOut = false
        var standing = false
        var age: Double = 0
    }

    static func row(_ s: Spec) -> AgentInboxRow {
        let ended = now.addingTimeInterval(-30 - s.age)
        var r = AgentInboxRow(
            id: id(s.n), title: s.title, projectName: "Array", directoryName: "Array", state: s.state,
            attention: s.attention, model: s.model, branch: s.branch,
            elapsed: s.state == .working ? 250 : nil,
            elapsedStartedAt: s.state == .working ? now.addingTimeInterval(-250) : nil,
            lastActiveAt: ended, depth: s.depth, createdAt: now.addingTimeInterval(-Double(5000 - s.n)),
            parentId: s.parent.map(id), isUnconfirmed: s.unconfirmed,
            terminalEvent: s.outcome.map { AgentTerminalEvent(sequence: 1, turnID: "t", outcome: $0, endedAt: ended) },
            terminalIsUnread: s.unread, identityColor: s.colour, selfReport: s.report,
            characterActivity: AgentCharacterActivity(
                action: s.state == .working ? .read : nil, lastOutputAt: now.addingTimeInterval(-5),
                promptSentAt: now.addingTimeInterval(-300),
                endedAt: s.outcome == nil ? nil : ended,
                outcome: s.outcome.map { $0 == .succeeded ? .succeeded : .failed }))
        r.failureDetail = s.failure
        r.usageExhaustedNow = s.usageOut
        r.isStanding = s.standing
        return r
    }

    static let longTitle = "Array repo (Swift/AppKit, SwiftPM). Read CLAUDE.md first. Never call the plan tools"

    /// Every status a row can hold, as children of `parent` at `depth`.
    static func statusSpecs(base: Int, parent: Int?, depth: Int) -> [Spec] {
        [
            Spec(n: base + 1, title: "Working: audit the token usage", state: .working, parent: parent, depth: depth,
                 report: InboxSelfReport(now: "reading the cell layout")),
            Spec(n: base + 2, title: longTitle, state: .working, parent: parent, depth: depth),
            Spec(n: base + 3, title: "", state: .working, parent: parent, depth: depth),
            Spec(n: base + 4, title: "Needs you: approve the migration", state: .approval, parent: parent, depth: depth,
                 report: InboxSelfReport(needsYou: "approve the keychain move")),
            Spec(n: base + 5, title: "Done, unread: write the sign-in tests", state: .ready, parent: parent, depth: depth,
                 model: "gpt-5.5", outcome: .succeeded, unread: true),
            Spec(n: base + 6, title: "Done, read: bundle probe", state: .ready, parent: parent, depth: depth,
                 outcome: .succeeded, age: 600),
            Spec(n: base + 7, title: "Failed: migrate the keychain wrapper", state: .failed, parent: parent, depth: depth,
                 outcome: .failed, unread: true, failure: "error: build failed"),
            Spec(n: base + 8, title: "Interrupted: profile the pinch", state: .ready, parent: parent, depth: depth,
                 outcome: .interrupted, unread: true, failure: "Array restarted"),
            Spec(n: base + 9, title: "Paused on usage: draft the notes", state: .ready, parent: parent, depth: depth,
                 outcome: .interrupted, failure: "You've hit your usage limit", usageOut: true),
            Spec(n: base + 10, title: "Unconfirmed checks: " + longTitle, state: .ready, parent: parent, depth: depth,
                 outcome: .succeeded, report: InboxSelfReport(checksPassed: 3, checksFailed: 1)),
            Spec(n: base + 11, title: "Unconfirmed state: watch the relay", state: .working, parent: parent, depth: depth,
                 unconfirmed: true),
            Spec(n: base + 12, title: "Cancelled: tidy the benches", state: .ready, parent: parent, depth: depth,
                 outcome: .cancelled, unread: true),
        ]
    }

    static func rows(_ kind: Kind) -> [AgentInboxRow] {
        switch kind {
        case .lead:
            // Every status on a lead with no helpers, then a folded family.
            var specs = statusSpecs(base: 100, parent: nil, depth: 0).enumerated().map { index, spec -> Spec in
                var s = spec
                s.colour = ["teal", "purple", "orange", "blue", "pink", nil][index % 6]
                s.branch = index % 2 == 0 ? "agent/row-grammar" : nil
                return s
            }
            specs.append(Spec(n: 150, title: "Standing lead: release", state: .ready, colour: "teal",
                              outcome: .succeeded, standing: true))
            specs.append(Spec(n: 160, title: "Lead with helpers", state: .working, colour: "purple", branch: "agent/lead"))
            specs += (0..<3).map { Spec(n: 161 + $0, title: "Folded helper \($0)", state: .ready, parent: 160, depth: 1,
                                        outcome: .succeeded, age: 900) }
            return specs.map(row)
        case .helper:
            var specs = [Spec(n: 200, title: "Array release lead", state: .ready, colour: "teal", branch: "array/integration",
                              outcome: .succeeded, unread: true)]
            specs += statusSpecs(base: 200, parent: 200, depth: 1)
            // Enough finished helpers that the family folds ("N folded").
            specs += (0..<14).map { Spec(n: 230 + $0, title: "Finished helper \($0)", state: .ready, parent: 200, depth: 1,
                                         outcome: .succeeded, age: 3600 + Double($0)) }
            return specs.map(row)
        case .nested:
            var specs = [Spec(n: 300, title: "Array release lead", state: .working, colour: "teal", branch: "array/integration")]
            specs.append(Spec(n: 310, title: "Sidebar polish (has subagents)", state: .working, parent: 300, depth: 1,
                              report: InboxSelfReport(now: "critiquing stills")))
            specs.append(Spec(n: 311, title: "Cold critique of drawer stills", state: .working, parent: 310, depth: 2))
            specs.append(Spec(n: 312, title: "Measure the cell layout", state: .ready, parent: 310, depth: 2,
                              outcome: .succeeded, age: 120))
            specs.append(Spec(n: 313, title: "Unconfirmed: " + longTitle, state: .ready, parent: 310, depth: 2,
                              outcome: .succeeded, report: InboxSelfReport(checksPassed: 1, checksFailed: 2)))
            specs.append(Spec(n: 314, title: "Failed nested subagent", state: .failed, parent: 310, depth: 2,
                              outcome: .failed, unread: true, failure: "error"))
            specs.append(Spec(n: 320, title: "Resting helper with a subagent", state: .ready, parent: 300, depth: 1,
                              outcome: .succeeded, age: 300))
            specs.append(Spec(n: 321, title: "Its finished subagent", state: .ready, parent: 320, depth: 2,
                              outcome: .succeeded, age: 400))
            specs.append(Spec(n: 330, title: "Plain helper beside them", state: .working, parent: 300, depth: 1))
            return specs.map(row)
        }
    }

    // MARK: Run

    struct Report {
        var violations: [String] = []
        var notes: [String] = []
    }

    static func run() throws -> String {
        let out = ProcessInfo.processInfo.environment["ARRAY_ROW_STATES_OUT"].flatMap { $0.isEmpty ? nil : $0 }
        let suite = "ArrayRowGrammar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.windowIsVisible = { _ in true }
        controller.reduceMotion = { false }
        func configure(icons: Bool) {
            defaults.set(icons, forKey: AgentCharacterConfig.enabledKey)
            controller.adopt(defaults: defaults)
            controller.reload()
        }
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        func makeInbox(_ kind: Kind, _ appearance: NSAppearance.Name, style: SidebarActiveIndicatorStyle? = nil) -> (AgentInboxView, NSWindow) {
            if let style { defaults.set(style.rawValue, forKey: SidebarActiveIndicatorStyle.defaultsKey) }
            else { defaults.removeObject(forKey: SidebarActiveIndicatorStyle.defaultsKey) }
            let height: CGFloat = kind == .lead ? 1180 : kind == .helper ? 760 : 560
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: width, height: height), indicatorDefaults: defaults)
            inbox.clock = { now }
            inbox.onRowAction = { _, _ in }
            inbox.wiredRowActions = [.settle, .snooze, .popOut, .stopAgent]
            inbox.hoverCardEnabled = false
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.acceptsMouseMovedEvents = true
            window.appearance = NSAppearance(named: appearance)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            windows.append(window)
            inbox.reload(rows: rows(kind))
            inbox.layoutForQA()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            inbox.layoutForQA()
            return (inbox, window)
        }
        func capture(_ window: NSWindow) throws -> NSImage {
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]) else {
                throw Failure(description: "capture failed")
            }
            return NSImage(cgImage: image, size: window.frame.size)
        }

        var report = Report()
        var sheets: [Kind: [(String, NSImage)]] = [:]
        let tones: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        for kind in Kind.allCases {
            for icons in [true, false] {
                for (appearance, tone) in tones {
                    configure(icons: icons)
                    let (inbox, window) = makeInbox(kind, appearance)
                    audit(inbox, kind: kind, label: "\(kind.rawValue) icons-\(icons ? "on" : "off") \(tone)", report: &report)
                    if out != nil { sheets[kind, default: []].append(("icons \(icons ? "on" : "off") · \(tone)", try capture(window))) }
                }
            }
            // Interaction: a selected row and a hovered row, the classic (moving)
            // active style, icons on.
            for (appearance, tone) in tones {
                configure(icons: true)
                let (inbox, window) = makeInbox(kind, appearance, style: .classic)
                window.makeKey()
                let targets: (select: Int, hover: Int) = kind == .lead ? (102, 110) : kind == .helper ? (202, 210) : (311, 313)
                inbox.selectRowForQA(id: id(targets.select))
                inbox.layoutForQA()
                inbox.updateTrackingAreas()
                if let point = try? SidebarHelperHoverChecks.windowPoint(inbox, id: id(targets.hover)) {
                    try? SidebarHelperHoverChecks.crossing(.mouseEntered, at: point, inbox: inbox, window: window)
                    try? SidebarHelperHoverChecks.move(to: point, in: window)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                }
                audit(inbox, kind: kind, label: "\(kind.rawValue) interaction \(tone)", report: &report)
                if out != nil { sheets[kind, default: []].append(("selected + hover · classic · \(tone)", try capture(window))) }
            }
        }

        var written: [String] = []
        if let out {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            for kind in Kind.allCases {
                let path = "\(out)/\(kind.rawValue)-rows.png"
                try writeSheet(sheets[kind] ?? [], title: "\(kind.rawValue) rows", to: path)
                written.append(path)
            }
            let text = (["violations: \(report.violations.count)"] + report.violations + ["", "notes:"] + report.notes)
                .joined(separator: "\n")
            try text.write(toFile: "\(out)/grammar-report.txt", atomically: true, encoding: .utf8)
        }
        guard report.violations.isEmpty else {
            throw Failure(description: "\(report.violations.count) grammar violations:\n  "
                          + report.violations.prefix(40).joined(separator: "\n  "))
        }
        return "sidebar row grammar: G1-G6 hold over \(Kind.allCases.count) kinds x icons on/off x light/dark + interaction \(written.joined(separator: " "))"
    }

    // MARK: Audit

    static func audit(_ inbox: AgentInboxView, kind: Kind, label: String, report: inout Report) {
        let all = rows(kind)
        var cells: [(row: AgentInboxRow, cell: AgentInbox96CellView)] = []
        for row in all {
            guard let cell = inbox.cellForQA(id: row.id), cell.window != nil, !cell.isHidden,
                  cell.rowForQA?.id == row.id else { continue }
            cells.append((row, cell))
        }
        func name(_ row: AgentInboxRow) -> String { "\(label) «\(row.title.isEmpty ? "untitled" : String(row.title.prefix(28)))»" }
        for (row, cell) in cells {
            let signals = cell.rowSignalsForQA
            let characters = signals.filter { $0 == "character" || $0 == "plate" }.count
            if characters > 1 { report.violations.append("G1 two characters: \(name(row)) \(signals)") }
            if signals.count > 1 { report.violations.append("G2 \(signals.count) signals: \(name(row)) \(signals)") }
            report.notes.append("\(name(row)) signals=\(signals) title=\(cell.titleFrameForQA) char=\(cell.characterRectForQA.map { "\($0)" } ?? "-") pill=\(cell.reportPillFrameForQA.map { "\($0)" } ?? "-")")
            if let pill = cell.reportPillFrameForQA {
                let need = min(pillTitleRoom, cell.titleNaturalWidthForQA)
                if cell.titleFrameForQA.width + 0.5 < need {
                    report.violations.append("G4 title squeezed to \(Int(cell.titleFrameForQA.width)) pt beside a pill (needs \(Int(need))): \(name(row)) pill=\(pill)")
                }
            }
        }
        // G3: nested shift. Every nested row against its parent helper.
        let byId = Dictionary(uniqueKeysWithValues: cells.map { ($0.row.id, $0.cell) })
        for (row, cell) in cells where row.depth >= 2 {
            guard let parentId = row.parentId, let parent = byId[parentId] else { continue }
            // Title INK starts: the label's frame begins its own inset earlier.
            let inset = CGFloat(Metrics.cellTextInset)
            let pt = parent.titleFrameForQA.minX + inset, ct = cell.titleFrameForQA.minX + inset
            let shift = ct - pt
            if let pc = parent.characterColumnForQA, let cc = cell.characterColumnForQA {
                let step = pt - pc.minX
                let charShift = cc.minX - pc.minX
                if abs(charShift - step) > 0.5 || abs(shift - step) > 0.5 {
                    report.violations.append("G3 nested shift char=\(charShift) title=\(shift) step=\(step): \(name(row))")
                }
            } else if (parent.characterColumnForQA == nil) != (cell.characterColumnForQA == nil) {
                report.violations.append("G3 nested row and its parent disagree on a character column: \(name(row))")
            }
            if shift < 8 { report.violations.append("G3 nested title not indented (shift \(shift)): \(name(row))") }
        }
        // G5: truncated helper titles end at one x per depth.
        var ends: [Int: [(CGFloat, String)]] = [:]
        for (row, cell) in cells where row.depth > 0 && cell.titleNaturalWidthForQA > cell.titleFrameForQA.width + 1 {
            ends[row.depth, default: []].append((cell.titleFrameForQA.maxX, name(row)))
        }
        for (depth, list) in ends {
            guard let first = list.first else { continue }
            for (x, who) in list where abs(x - first.0) > 0.5 {
                report.violations.append("G5 depth \(depth) truncated title ends at \(x), not \(first.0): \(who)")
            }
        }
        // G7: lead titles start at one x.
        let leadStarts = cells.filter { $0.row.depth == 0 }.map { ($0.cell.titleFrameForQA.minX, name($0.row)) }
        if let first = leadStarts.first {
            for (x, who) in leadStarts where abs(x - first.0) > 0.5 {
                report.violations.append("G7 lead title starts at \(x), not \(first.0): \(who)")
            }
        }
        // G6: the summary line.
        for (id, line) in inbox.leadCountLinesForQA {
            let lead = all.first { $0.id == id }
            func descendants(_ parent: UUID) -> [AgentInboxRow] {
                all.filter { $0.parentId == parent }.flatMap { [$0] + descendants($0.id) }
            }
            let live = descendants(id).filter { $0.state == .working }.count
            if live > 0, !line.hasPrefix("\(live) working") {
                report.violations.append("G6 summary does not lead with what is live: \"\(line)\" (\(lead?.title ?? "?"))")
            }
            if line.range(of: #"^\d+ helpers?\b"#, options: .regularExpression) != nil, live > 0 {
                report.violations.append("G6 summary leads with the lifetime total: \"\(line)\"")
            }
            report.notes.append("\(label) summary: \(line)")
        }
    }

    // MARK: Sheet

    static func writeSheet(_ panels: [(String, NSImage)], title: String, to path: String) throws {
        guard !panels.isEmpty else { return }
        let pad: CGFloat = 16, header: CGFloat = 26
        let panelW = panels.map(\.1.size.width).max() ?? width
        let panelH = panels.map(\.1.size.height).max() ?? 400
        let size = NSSize(width: pad + CGFloat(panels.count) * (panelW + pad), height: header + pad + panelH + pad + 18)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure(description: "no sheet bitmap")
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        (title as NSString).draw(at: NSPoint(x: pad, y: size.height - header + 4), withAttributes: attributes)
        for (index, panel) in panels.enumerated() {
            let x = pad + CGFloat(index) * (panelW + pad)
            let y = size.height - header - pad - panel.1.size.height
            panel.1.draw(in: NSRect(x: x, y: y, width: panel.1.size.width, height: panel.1.size.height))
            (panel.0 as NSString).draw(at: NSPoint(x: x, y: y - 16), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no png") }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
