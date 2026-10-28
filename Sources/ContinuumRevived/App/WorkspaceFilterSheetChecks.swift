import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The multi-workspace sidebar filter, driven and photographed in the shipped
/// views. `--workspace-filter-sheet-check` builds a production `AgentInboxView`
/// over three workspaces, opens the real checklist popover, toggles, peeks and
/// recolours through the list's own choose and accessory paths, and asserts what
/// the list then shows. It writes `qa-runs/workspace-filter-sheet/sheet.png` —
/// the inbox window composited with the popover's panel, in light and dark — for
/// a person to read.
///
/// Both windows sit just above the desktop, behind every app, and the panel is
/// presented without taking the keyboard.
@MainActor
enum WorkspaceFilterSheet {
    struct Failure: Error, CustomStringConvertible { let description: String }

    struct Workspace: Sendable {
        let id: UUID
        let name: String
        let colour: String
    }

    nonisolated static let now = Date(timeIntervalSince1970: 1_900_600_000)
    nonisolated static let array = Workspace(id: uuid(0x701), name: "Array", colour: "blue")
    nonisolated static let studio = Workspace(id: uuid(0x702), name: "Film", colour: "orange")
    nonisolated static let website = Workspace(id: uuid(0x703), name: "Website", colour: "purple")
    nonisolated static let workspaces = [array, studio, website]

    nonisolated private static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    static func rows() -> [AgentInboxRow] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func row(_ n: Int, _ title: String, _ ws: Workspace?, _ project: String, _ state: InboxState,
                 attention: InboxAttention = .none, harness: String = "Claude Code", elapsed: TimeInterval? = nil,
                 depth: Int = 0, parent: Int? = nil, colour: String? = nil, minutes: Double) -> AgentInboxRow {
            AgentInboxRow(
                id: uuid(n), title: title, projectName: project, projectId: uuid(0x800 + project.count),
                workspaceName: ws?.name, workspaceId: ws?.id, state: state, attention: attention,
                model: harness == "Codex" ? "gpt-6.1-sol" : "claude-opus-5-5", branch: "main",
                elapsed: elapsed, depth: depth, createdAt: ago(minutes), parentId: parent.map(uuid),
                harness: harness, identityColor: colour)
        }
        return [
            row(0x501, "Polish sidebar card hover interactions", array, "Array", .working, elapsed: 3_900,
                colour: "teal", minutes: 50),
            row(0x511, "Sidebar: fold button", array, "Array", .working, elapsed: 2_400, depth: 1, parent: 0x501, minutes: 49),
            row(0x512, "Sidebar: project icons", array, "Array", .ready, depth: 1, parent: 0x501, minutes: 48),
            row(0x502, "Retime the hero loop to the beat", studio, "film", .approval, attention: .unread, minutes: 45),
            row(0x503, "Fix zoom choppiness on pinch", array, "Array", .working, harness: "Codex", elapsed: 1_260, minutes: 40),
            row(0x504, "Ship the pricing page copy", website, "website", .ready, minutes: 35),
            row(0x505, "Render the dictation film master", studio, "film", .working, harness: "Codex", elapsed: 620, minutes: 30),
            row(0x506, "Fix the appcast link on mobile", website, "website", .working, elapsed: 300, minutes: 25),
            row(0x507, "Draft release notes for 0.7.32", array, "Array", .ready, minutes: 20),
            row(0x508, "Summarise overnight CI failures", nil, "Array", .ready, minutes: 15),
        ]
    }

    static let width: CGFloat = 320, height: CGFloat = 600
    /// Room to the right of the sidebar for the popover, which opens over the canvas.
    static let popoverRoom: CGFloat = 220

    static func run(outputDirectory: URL) async throws -> String {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--film") { return try await film(into: outputDirectory) }
        var bands: [(String, [(String, CGImage)])] = []
        var lines: [String] = try await liveness()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (shots, notes) = try await drive(appearance: appearance)
            bands.append((appearance == .darkAqua ? "dark" : "light", shots))
            lines += notes
        }
        let url = outputDirectory.appendingPathComponent("sheet.png")
        guard bands.allSatisfy({ !$0.1.isEmpty }) else {
            return (lines + ["no pictures: the window server returned none (display locked or asleep?)"]).joined(separator: "\n")
        }
        try writeSheet(bands, to: url)
        return (lines + [url.path]).joined(separator: "\n")
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    // MARK: - Liveness (.plans/87 step 1)

    /// Three facts the sheet's pictures cannot show: a toggle keeps the cells it
    /// does not remove, an open checklist's counts follow a push, and the host's
    /// stored include set comes back through the path the app boots through.
    private static func liveness() async throws -> [String] {
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        inbox.clock = { now }
        inbox.foldsUntouchedGroups = true
        inbox.prefersReducedMotion = { true }
        inbox.onRevealRow = { _ in }
        inbox.hoverCardEnabled = false
        let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = inbox
        window.ignoresMouseEvents = true
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let trigger = inbox.scopeButtonForQA
        trigger.presentsWithoutFocusForQA = true
        defer { trigger.dismissPopoverForQA() }
        inbox.scopeCatalog = workspaces.map { .workspaceID($0.id, $0.name) }
        inbox.currentWorkspaceId = array.id
        inbox.currentWorkspaceName = array.name
        inbox.setScope(.currentWorkspace)
        var all = rows()
        inbox.reload(rows: all)
        inbox.layoutForQA()
        let filmID = InboxScope.workspaceID(studio.id, "").storageValue

        // 1. Surviving cards keep their cell OBJECT across a toggle.
        func cells() -> [UUID: ObjectIdentifier] {
            inbox.qaMaterializedRowCells.reduce(into: [:]) { out, cell in
                if let id = cell.qaAgentID { out[id] = ObjectIdentifier(cell) }
            }
        }
        let before = cells()
        try expect(!before.isEmpty, "liveness: the Array list materialised no cells")
        trigger.presentPopover()
        try expect(trigger.choosePresentedItemForQA(id: filmID), "liveness: Film is not a row of the open checklist")
        inbox.layoutForQA()
        let after = cells()
        let rebuilt = before.filter { after[$0.key] != $0.value }.count
        try expect(rebuilt == 0, "liveness: \(rebuilt) of \(before.count) surviving cards were rebuilt by the Film toggle")
        try expect(after.count > before.count, "liveness: checking Film added no cards (\(before.count) → \(after.count))")

        // 2. With the checklist open, a push updates a workspace's counts in place.
        try expect(trigger.qaIsPopoverPresented, "liveness: the checklist closed on a toggle")
        func checklistCounts() -> String? { trigger.qaPresentedList?.qaItems.first { $0.id == filmID }?.detail }
        let detailBefore = checklistCounts()
        let arrival = AgentInboxRow(
            id: uuid(0x5F0), title: "Grade the launch reel", projectName: "film", projectId: uuid(0x804),
            workspaceName: studio.name, workspaceId: studio.id, state: .approval, attention: .unread,
            model: "claude-opus-5-5", branch: "main", elapsed: nil, depth: 0, createdAt: now,
            parentId: nil, harness: "Claude Code", identityColor: nil)
        all.append(arrival)
        inbox.apply(rows: all, changed: AgentsBoardChangeSet(added: [arrival.id], updated: [], removed: []))
        let detailAfter = checklistCounts()
        try expect(detailAfter != nil && detailAfter != detailBefore,
                   "liveness: the open checklist kept Film's counts at '\(detailBefore ?? "nil")' after a push added a Film agent")
        trigger.dismissPopoverForQA()

        // 3. The host restores a stored include set, through Core's resolver and the
        //    sidebar's own configure call — the pair the app boots through.
        let suite = "continuum.workspace-filter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ghost = uuid(0x7FF)
        let stored = InboxScope.normalized(InboxWorkspaceFilter(mode: .include, workspaces: [studio.id, website.id, ghost],
                                                                showsUnplaced: false))
        try expect(stored.storageValue.hasPrefix("workspaces:include:"), "liveness: the fixture is not an include set — \(stored.storageValue)")
        defaults.set(stored.storageValue, forKey: WorkspaceSidebarConfig.scopeKey)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let restored = sidebar.agentInbox
        restored.scopeCatalog = workspaces.map { .workspaceID($0.id, $0.name) }
        restored.currentWorkspaceId = array.id
        restored.currentWorkspaceName = array.name
        var writes = 0
        sidebar.configureInboxScope(WorkspaceSidebarConfig.resolveScope(defaults: defaults)) { _ in writes += 1 }
        restored.reload(rows: all)
        restored.layoutForQA()
        let shown = Set(restored.rowIdsForQA.compactMap { id in all.first { $0.id == id }.map(\.workspaceId) })
        try expect(restored.scope == stored, "liveness: the stored include set came back as \(restored.scope.storageValue)")
        try expect(shown == [studio.id, website.id], "liveness: the restored set shows Film and Website only — got \(shown)")
        try expect(writes == 0, "liveness: restoring the scope wrote it back \(writes) times")

        // 4. A deleted workspace left in the set: ignored for the title and the
        //    match, kept in storage.
        try expect(restored.scopeTriggerTitleForQA == "Film + Website",
                   "liveness: a deleted workspace in the set titles as '\(restored.scopeTriggerTitleForQA)'")
        try expect(restored.scope.storageValue.contains(ghost.uuidString.lowercased()),
                   "liveness: the deleted workspace was dropped from storage")
        let lone = InboxScope.normalized(InboxWorkspaceFilter(mode: .include, workspaces: [ghost], showsUnplaced: false))
        restored.setScope(lone)
        restored.layoutForQA()
        let loneShown = Set(restored.rowIdsForQA.compactMap { id in all.first { $0.id == id }.map(\.workspaceId) })
        try expect(loneShown == [array.id] && restored.scopeTriggerTitleForQA == InboxScope.currentWorkspaceTitle,
                   "liveness: a set of only a deleted workspace falls back to This workspace — got '\(restored.scopeTriggerTitleForQA)' over \(loneShown)")
        return ["liveness: \(before.count) cards kept across a toggle; Film counts '\(detailBefore ?? "")' → '\(detailAfter ?? "")'; include set restored"]
    }

    // MARK: - Driving the real list

    private static func drive(appearance: NSAppearance.Name) async throws -> ([(String, CGImage)], [String]) {
        let tag = appearance == .darkAqua ? "dark" : "light"
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        inbox.clock = { now }
        inbox.foldsUntouchedGroups = true
        inbox.prefersReducedMotion = { true }
        inbox.onRevealRow = { _ in }
        inbox.hoverCardEnabled = false
        let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = inbox
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        let trigger = inbox.scopeButtonForQA
        trigger.presentsWithoutFocusForQA = true
        defer { trigger.dismissPopoverForQA() }
        inbox.scopeCatalog = workspaces.map { .workspaceID($0.id, $0.name) }
        inbox.workspaceColourNames = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.colour) })
        inbox.currentWorkspaceId = array.id
        inbox.currentWorkspaceName = array.name
        var reported: [InboxScope] = []
        inbox.onScopeChange = { reported.append($0) }
        var recoloured: [(UUID, String)] = []
        inbox.onWorkspaceColourChange = { recoloured.append(($0, $1)) }
        inbox.setScope(.currentWorkspace)
        let all = rows()
        inbox.reload(rows: all)
        inbox.layoutForQA()

        var shots: [(String, CGImage)] = []
        func shoot(_ label: String) async throws {
            inbox.layoutForQA()
            try await Task.sleep(nanoseconds: 250_000_000)
            // The pictures are for a person; a locked or sleeping display gives the
            // window server nothing to hand back, and the assertions still stand.
            if let image = try? capture(window: window, panel: trigger.qaPresentedPanel) { shots.append((label, image)) }
        }
        func shownWorkspaces() -> Set<UUID?> {
            Set(inbox.rowIdsForQA.compactMap { id in all.first { $0.id == id }.map(\.workspaceId) })
        }
        func present() throws {
            trigger.presentPopover()
            guard let panel = trigger.qaPresentedPanel else { throw Failure(description: "\(tag): the checklist did not present") }
            // Behind every app, like the inbox window it belongs to.
            panel.level = window.level
            panel.ignoresMouseEvents = true
        }
        func choose(_ id: String) throws {
            try expect(trigger.choosePresentedItemForQA(id: id), "\(tag): '\(id)' is not a row of the open checklist")
        }
        let filmID = InboxScope.workspaceID(studio.id, "").storageValue
        let websiteID = InboxScope.workspaceID(website.id, "").storageValue

        // 1. Today: This workspace.
        try expect(shownWorkspaces() == [array.id], "\(tag): This workspace shows only Array — got \(shownWorkspaces())")
        try expect(inbox.scopeTriggerTitleForQA == "This workspace" && !inbox.marksWorkspacesForQA,
                   "\(tag): the default trigger reads This workspace with no marks")
        try await shoot("This workspace")

        // 2. Check Film from the open list: the popover stays, the list widens.
        try present()
        try choose(filmID)
        try expect(trigger.qaIsPopoverPresented, "\(tag): checking a box must leave the popover open")
        try expect(shownWorkspaces() == [array.id, studio.id], "\(tag): Array + Film shows both — got \(shownWorkspaces())")
        try expect(inbox.scopeTriggerTitleForQA == "Array + Film" && inbox.scopeTriggerSwatchCountForQA == 2,
                   "\(tag): the trigger reads '\(inbox.scopeTriggerTitleForQA)' with \(inbox.scopeTriggerSwatchCountForQA) dots")
        try expect(reported.last.map { InboxScope(storageValue: $0.storageValue) == $0 } == true,
                   "\(tag): the set is reported to the host in a storable form")
        let rowsInList = trigger.qaPresentedList?.qaItems ?? []
        // .plans/87: Array is in the set because it is the workspace on screen, and
        // `This workspace` carries that one tick; Array's own row draws no grey copy.
        try expect(rowsInList.first { $0.id == filmID }?.check == .on
                   && rowsInList.first { $0.id == InboxScope.currentWorkspace.storageValue }?.check == .on
                   && rowsInList.first { $0.id == InboxScope.workspaceID(array.id, "").storageValue }?.check == .off,
                   "\(tag): the open list's boxes follow the toggle — Film on, This workspace on, no grey tick on Array")

        // Peek: keyboard focus onto Film's row, every other card sinks.
        guard let list = trigger.qaPresentedList,
              let filmIndex = list.qaItems.filter(\.enabled).firstIndex(where: { $0.id == filmID }) else {
            throw Failure(description: "\(tag): no Film row to peek")
        }
        list.perform(.first)
        for _ in 0..<filmIndex { list.perform(.next) }
        try expect(inbox.peekWorkspace == studio.id, "\(tag): focusing Film's row peeks Film")
        try expect(inbox.marksWorkspacesForQA, "\(tag): a list spanning two workspaces carries edge marks")
        inbox.layoutForQA()
        var marked = 0, dimmed = 0
        for case let cell as AgentInbox96CellView in inbox.qaMaterializedRowCells {
            guard let id = cell.qaAgentID, let row = all.first(where: { $0.id == id }) else { continue }
            if cell.qaWorkspaceMarkFrame != nil { marked += 1 }
            if row.workspaceId != studio.id && cell.peekAlpha < 0.5 { dimmed += 1 }
            if row.workspaceId == studio.id && cell.peekAlpha < 1 {
                throw Failure(description: "\(tag): the peeked workspace's own card '\(row.title)' was dimmed")
            }
        }
        try expect(marked > 0 && dimmed > 0, "\(tag): \(marked) cards marked, \(dimmed) dimmed under the peek")
        try await shoot("Open · Film peeked")

        try expect(trigger.qaIsPopoverPresented, "\(tag): the popover must survive its trigger resizing to the new label")

        // 3. Closed: Array + Film with marks and dots, and no card left dimmed.
        trigger.dismissPopoverForQA()
        inbox.layoutForQA()
        try expect(inbox.peekWorkspace == nil
                   && inbox.qaMaterializedRowCells.allSatisfy { ($0 as? AgentInbox96CellView)?.peekAlpha ?? 1 == 1 },
                   "\(tag): closing the popover from its trigger ends the peek")
        try await shoot("Array + Film")

        // 4. All agents, then uncheck Film: an exclude set.
        try present()
        try choose(InboxScope.all.storageValue)
        try expect(!trigger.qaIsPopoverPresented, "\(tag): a pick closes the popover")
        try present()
        try choose(filmID)
        try expect(inbox.scopeTriggerTitleForQA == "All but Film",
                   "\(tag): unchecking from All reads All but Film — got '\(inbox.scopeTriggerTitleForQA)'")
        try expect(shownWorkspaces() == [array.id, website.id, nil],
                   "\(tag): All but Film keeps the rest, headless included — got \(shownWorkspaces())")
        try await shoot("All but Film")

        // 5. Only, by its accessory.
        try expect(trigger.pressPresentedAccessoryForQA(itemID: websiteID, accessoryID: "only"), "\(tag): Website's Only")
        try expect(shownWorkspaces() == [website.id], "\(tag): Only isolates Website — got \(shownWorkspaces())")

        // 6. The colour drill-in, and a colour chosen from it.
        try expect(trigger.pressPresentedAccessoryForQA(itemID: websiteID, accessoryID: "colour"), "\(tag): Website's colour button")
        try expect(trigger.qaPresentedList?.qaItems.first?.id == "colour:back", "\(tag): the palette replaces the scopes")
        try await shoot("Website · colour")
        try choose("colour:red")
        try expect(recoloured.last.map { $0.0 == website.id && $0.1 == "red" } == true, "\(tag): the colour is reported to the host")
        try expect(trigger.qaIsPopoverPresented
                   && trigger.qaPresentedList?.qaItems.first?.id == InboxScope.currentWorkspace.storageValue,
                   "\(tag): choosing a colour returns to the scopes, still open")
        trigger.dismissPopoverForQA()
        try expect(inbox.peekWorkspace == nil, "\(tag): closing the popover ends any peek")
        return (shots, ["\(tag): \(shots.count) frames, \(marked) marked cards, \(dimmed) dimmed under the peek"])
    }

    // MARK: - Film

    /// Frames every ~16ms through a check, an uncheck and a peek, motion on.
    /// `--workspace-filter-sheet-check --film` writes one strip per scene.
    private static func film(into directory: URL) async throws -> String {
        var lines: [String] = []
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let tag = appearance == .darkAqua ? "dark" : "light"
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            inbox.clock = { now }
            inbox.foldsUntouchedGroups = true
            inbox.prefersReducedMotion = { false }
            inbox.onRevealRow = { _ in }
            inbox.hoverCardEnabled = false
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = inbox
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            if let screen = NSScreen.main { window.setFrameOrigin(screen.visibleFrame.origin) }
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let trigger = inbox.scopeButtonForQA
            trigger.presentsWithoutFocusForQA = true
            defer { trigger.dismissPopoverForQA() }
            inbox.scopeCatalog = workspaces.map { .workspaceID($0.id, $0.name) }
            inbox.workspaceColourNames = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.colour) })
            inbox.currentWorkspaceId = array.id
            inbox.setScope(.currentWorkspace)
            inbox.reload(rows: rows())
            inbox.layoutForQA()
            try await Task.sleep(nanoseconds: 300_000_000)
            trigger.presentPopover()
            trigger.qaPresentedPanel?.level = window.level
            let filmID = InboxScope.workspaceID(studio.id, "").storageValue
            func scene(_ name: String, _ action: () throws -> Void) async throws {
                var frames: [(TimeInterval, CGImage)] = []
                let start = ProcessInfo.processInfo.systemUptime
                var panelXs = Set<Int>()
                func notePanel() { if let x = trigger.qaPresentedPanel?.frame.minX { panelXs.insert(Int(x)) } }
                notePanel()
                frames.append((0, try capture(window: window, panel: trigger.qaPresentedPanel)))
                let actionStart = ProcessInfo.processInfo.systemUptime
                try action()
                let actionMs = Int((ProcessInfo.processInfo.systemUptime - actionStart) * 1000)
                while ProcessInfo.processInfo.systemUptime - start < 0.32 {
                    try await Task.sleep(nanoseconds: 16_000_000)
                    notePanel()
                    frames.append((ProcessInfo.processInfo.systemUptime - start,
                                   try capture(window: window, panel: trigger.qaPresentedPanel)))
                }
                try expect(panelXs.count <= 1, "\(tag) \(name): the popover moved sideways during the toggle — x \(panelXs.sorted())")
                let url = directory.appendingPathComponent("film-\(tag)-\(name).png")
                try writeStrip(frames, to: url)
                lines.append("\(tag) \(name): action \(actionMs)ms, \(frames.count) frames → \(url.path)")
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            // Twenty toggles after a warm-up: the cost a click pays, median and p90.
            for reduced in [true, false] {
                inbox.prefersReducedMotion = { reduced }
                var samples: [Double] = []
                for index in 0..<22 {
                    let started = CACurrentMediaTime()
                    _ = trigger.choosePresentedItemForQA(id: filmID)
                    inbox.layoutSubtreeIfNeeded()
                    if index >= 2 { samples.append((CACurrentMediaTime() - started) * 1000) }
                    try await Task.sleep(nanoseconds: 260_000_000)
                }
                samples.sort()
                let line = String(format: "%@ toggle (%@): median %.1fms, p90 %.1fms over %d", tag,
                                  reduced ? "no motion" : "reflow",
                                  samples[samples.count / 2], samples[Int(Double(samples.count) * 0.9)], samples.count)
                // Printed now: a later scene's failure must not swallow the measurement.
                print(line)
                fflush(stdout)
            }
            try await scene("check-film") { _ = trigger.choosePresentedItemForQA(id: filmID) }
            try await scene("peek-film") {
                guard let list = trigger.qaPresentedList,
                      let index = list.qaItems.filter(\.enabled).firstIndex(where: { $0.id == filmID }) else { return }
                list.perform(.first)
                for _ in 0..<index { list.perform(.next) }
            }
            try await scene("uncheck-film") { _ = trigger.choosePresentedItemForQA(id: filmID) }
            inbox.layoutForQA()
            let stillDim = inbox.qaMaterializedRowCells.compactMap { $0 as? AgentInbox96CellView }
                .filter { $0.peekAlpha < 1 || $0.alphaValue < 1 }
            try expect(stillDim.isEmpty, "\(tag): after unchecking the peeked workspace, \(stillDim.count) cards stayed dimmed")
        }
        return lines.joined(separator: "\n")
    }

    /// Frames six to a row at half size, each labelled with its time.
    private static func writeStrip(_ frames: [(TimeInterval, CGImage)], to url: URL) throws {
        guard let first = frames.first?.1 else { return }
        let w = CGFloat(first.width) / 2, h = CGFloat(first.height) / 2
        let columns = 6, rows = (frames.count + columns - 1) / columns
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(w) * columns, pixelsHigh: Int(h) * rows,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.systemRed]
        for (index, frame) in frames.enumerated() {
            let x = CGFloat(index % columns) * w, y = CGFloat(rows - 1 - index / columns) * h
            context.cgContext.draw(frame.1, in: CGRect(x: x, y: y, width: w, height: h))
            ("\(Int(frame.0 * 1000))ms" as NSString).draw(at: CGPoint(x: x + 6, y: y + h - 26), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - Pictures

    /// The inbox window with the popover's panel composited at its own frame.
    private static func capture(window: NSWindow, panel: NSWindow?) throws -> CGImage {
        func grab(_ w: NSWindow) -> CGImage? {
            CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        }
        guard let base = grab(window) else { throw Failure(description: "window capture failed") }
        let scale = CGFloat(base.width) / window.frame.width
        let size = NSSize(width: window.frame.width + popoverRoom, height: window.frame.height)
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard let cg = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(description: "bitmap") }
        cg.setFillColor(CGColor(gray: 0.42, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: pixels))
        cg.draw(base, in: CGRect(x: 0, y: 0, width: window.frame.width * scale, height: window.frame.height * scale))
        if let panel, panel.isVisible, let image = grab(panel) {
            let frame = panel.frame
            let origin = CGPoint(x: (frame.minX - window.frame.minX) * scale, y: (frame.minY - window.frame.minY) * scale)
            cg.draw(image, in: CGRect(origin: origin, size: CGSize(width: frame.width * scale, height: frame.height * scale)))
        }
        guard let image = cg.makeImage() else { throw Failure(description: "composite") }
        return image
    }

    private static func writeSheet(_ bands: [(String, [(String, CGImage)])], to url: URL) throws {
        guard let first = bands.first?.1.first?.1 else { throw Failure(description: "no frames") }
        let cellW = CGFloat(first.width), cellH = CGFloat(first.height)
        let scale = cellW / (width + popoverRoom)
        let gap = 16 * scale, header = 26 * scale
        let columns = bands.map(\.1.count).max() ?? 0
        let sheetW = gap + (cellW + gap) * CGFloat(columns)
        let sheetH = (header + cellH + gap) * CGFloat(bands.count) + gap
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(sheetW), pixelsHigh: Int(sheetH),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { throw Failure(description: "bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.setFillColor(CGColor(gray: 0.3, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * scale, weight: .semibold), .foregroundColor: NSColor.white]
        for (b, band) in bands.enumerated() {
            let top = sheetH - gap - CGFloat(b) * (header + cellH + gap)
            for (i, shot) in band.1.enumerated() {
                let x = gap + CGFloat(i) * (cellW + gap)
                ("\(shot.0) — \(band.0)" as NSString).draw(at: CGPoint(x: x, y: top - header + 6 * scale), withAttributes: attrs)
                cg.draw(shot.1, in: CGRect(x: x, y: top - header - cellH, width: cellW, height: cellH))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "png") }
        try png.write(to: url)
    }
}
