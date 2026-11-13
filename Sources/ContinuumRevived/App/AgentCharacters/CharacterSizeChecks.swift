import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters/README.md › character size (0.7.40 polish).
//
// `--character-size-check`: Settings › Agent characters › Character
// size, driven through the setting's own change notification (what the Settings
// pane posts), on a real agent tile attached to a real supervisor and the real
// sidebar. At Small, Medium and Large (1, 1.5, 2.25):
// - the agent tile's title bar is 24 × factor tall, or today's floored bar (28
//   at 100%, more zoomed out) when that is taller, and the body starts 24 × factor
//   down (plus the under-bar) at 100%, and lower but never covered when zoomed
//   out (f56a0e79); zoomed far out every size draws like Small;
// - at Medium and Large the header character is a whole number of device pixels
//   per art pixel at 100%, from a device-pixel origin (the sidebar's rule; Small
//   keeps today's 7/6 pt per art pixel exactly), and sits centred in the bar
//   with the mark, the title, the pill, ⋯ and ×;
// - the provider mark is round(14 × factor), the title 12 × (1 + (factor − 1)/2);
// - a tile with no character (a note) keeps today's bar;
// - the sidebar lead row's second line grows by 16 × (factor − 1), its
//   character is crisp and centred with its mark, and its title keeps its size;
// - Small is pixel-identical to the state before any size was ever written.
// Captures every size in both appearances to qa-runs/agent-characters/size-*.
@MainActor
enum CharacterSizeChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// The setting's key and the factor each value stands for, written here
    /// rather than read from the feature so the check states the contract.
    static let key = "agentCharacters.size"
    static let sizes: [(name: String, factor: CGFloat)] = [("small", 1), ("medium", 1.5), ("large", 2.25)]

    static func whole(_ value: CGFloat) -> Bool { abs(value - value.rounded()) < 0.01 }

    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-character-size-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ArrayCharacterSizeChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        // Still poses, so two captures of one state are byte-comparable.
        defaults.set(AgentCharacterConfig.Motion.never.rawValue, forKey: AgentCharacterConfig.motionKey)
        controller.adopt(defaults: defaults)
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/agent-characters", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }
        let agentID = supervisor.spawn(
            role: nil, prompt: nil, cwd: work, harness: .claudeCode,
            model: "anthropic/claude-haiku-4-5-20251001", thinking: "low", displayName: "Rework the sign-in screen")

        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.focusBroker = FocusBroker()
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 520)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let tile = Tile(id: UUID(), kind: .managedAgent, title: "Rework the sign-in screen",
                        frame: TileFrame(x: 40, y: 40, width: 520, height: 360),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil,
                        metadata: TileMetadata(launchProfileId: "managed"))
        let view = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: view, for: tile)
        view.attach(agentID: agentID, supervisor: supervisor)
        let note = Tile(id: UUID(), kind: .note, title: "Notes", frame: TileFrame(x: 600, y: 40, width: 300, height: 200),
                        zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let noteView = TileNSView(tile: note)
        canvas.install(tileView: noteView, for: note)
        canvas.layoutSubtreeIfNeeded()
        try expect(pump(until: { view.qaCharacterRect != nil }), "the header shows a character for an attached agent")

        // The sidebar: one lead row for the same agent.
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let inboxWindow = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        inboxWindow.contentView = inbox
        inboxWindow.orderFrontOffscreenForChecks()
        defer { inboxWindow.orderOut(nil) }
        // The sidebar check's failed lead row: it carries a provider mark and a
        // branch, and nothing on it moves (a working row's spinner would make two
        // captures of one state differ).
        let sidebarRow = SidebarCharacterChecks.stillsRows()[4]
        let rowID = sidebarRow.id
        inbox.clock = { SidebarCharacterChecks.now }
        inbox.reload(rows: [sidebarRow])
        inbox.layoutForQA()

        let backing = window.backingScaleFactor
        func settle() {
            _ = pump(until: { false }, timeout: 0.15)
            canvas.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            inbox.layoutForQA()
            inbox.cellForQA(id: rowID)?.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            inbox.displayIfNeeded()
        }
        func choose(_ value: String?) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            SettingChangeEvent.post(SettingID(rawValue: key))
            settle()
        }
        func header() -> Data? {
            let band = NSRect(x: 0, y: 0, width: view.bounds.width, height: 60)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: band) else { return nil }
            view.cacheDisplay(in: band, to: rep)
            return rep.tiffRepresentation
        }
        func row() -> Data? {
            guard let cell = inbox.cellForQA(id: rowID),
                  let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { return nil }
            cell.cacheDisplay(in: cell.bounds, to: rep)
            return rep.tiffRepresentation
        }

        // Before any size is written: the picture Small must reproduce.
        settle()
        let todayHeader = header(), todayRow = row()
        let todayRowHeight = inbox.rowHeightForQA(id: rowID)
        func titleHeight() -> CGFloat? {
            inbox.cellForQA(id: rowID)?.characterNeighboursForQA.first { $0.name == "title" }?.frame.height
        }
        let todayTitleHeight = titleHeight()

        var report: [String] = []
        for (name, factor) in sizes {
            choose(name)
            // The sidebar is never zoomed: the nearest whole device pixels per art pixel.
            let perArt = (factor * backing).rounded(.toNearestOrAwayFromZero) / backing
            let tolerance = 0.5 / backing + 0.01
            for zoom in [1.0, 0.5] {
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                settle()
                let where_ = "\(name) at zoom \(zoom)"
                // Today's bar at this zoom: 24 pt, floored to 28 screen px (28 at 100%).
                let floor = max(TileNSView.titleBarHeight, TileNSView.minScreenGrabPx / CGFloat(TileNSView.chromeScaleBucket(for: zoom)))
                let chrome = floor / 24
                // The size raises the design height; the floor applies on top.
                let expectedBar = max(24 * factor, floor)
                let bar = view.chromeBarHeight
                try expect(abs(bar - expectedBar) < 0.01, "\(where_): the agent tile's title bar is \(expectedBar) pt, got \(bar)")
                // The size sets the design bar; the body starts under it and under
                // the under-bar, which owns its own height (`--tile-chrome-scale-check`).
                // f56a0e79: zoomed out, the readable bar and under-bar grow in world
                // units and the body moves down with them so nothing covers it. So at
                // 100% the body starts where it always did, and when zoomed out it
                // never starts higher than that. That nothing covers it is the
                // containment witnesses' (--agent-tile-fit-check and the composer's).
                let under = view.underBarWorldHeight
                let atNatural = 24 * factor + (under == 0 ? 0 : (under * TileNSView.minScreenGrabPx / TileNSView.titleBarHeight).rounded(.up))
                let top = view.contentTopInsetWorldHeight
                try expect(abs(view.naturalTitleBarHeight - 24 * factor) < 0.01
                           && (zoom == 1 ? abs(top - atNatural) < 0.01 : top >= atNatural - 0.01),
                           "\(where_): the body starts \(zoom == 1 ? "" : "at least ")\(atNatural) pt down, under a \(24 * factor) pt bar (\(view.naturalTitleBarHeight), \(top))")
                try expect(noteView.chromeBarHeight == floor, "\(where_): a note (no character) keeps today's \(floor) pt bar, got \(noteView.chromeBarHeight)")
                guard let sprite = view.qaCharacterRect, let mark = view.qaProviderMarkRect,
                      let barView = view.qaTitleBarView else {
                    throw Failure(description: "\(where_): no character or no mark in the header")
                }
                // Medium and Large at their own scale take the sidebar's whole-pixel
                // rule; Small, and any size once the floor is larger, draw at the
                // chrome scale exactly as Small always has.
                let ownScale = factor > chrome
                let sizeScale = max(factor, chrome)
                let art = ownScale ? perArt : sizeScale
                try expect(abs(sprite.width - 20 * art) < 0.01 && abs(sprite.height - 12 * art) < 0.01,
                           "\(where_): the header character is 20 x 12 art at \(art) pt each, got \(sprite.size)")
                if ownScale {
                    try expect(whole(art * CGFloat(zoom) * backing), "\(where_): \(art * backing) device px per art px is whole")
                    // The tile sits on whole points (world 40, 40 at 1).
                    let inWindow = barView.convert(sprite, to: nil)
                    try expect(whole(inWindow.minX * backing) && whole(inWindow.minY * backing),
                               "\(where_): the header character starts on a device pixel (\(inWindow.origin) at \(backing)x)")
                }
                let markSide = (14 * factor).rounded() * sizeScale / factor
                try expect(abs(mark.width - markSide) < 0.01, "\(where_): the mark is \(markSide) pt, got \(mark.width)")
                // The character is centred in its bubble at the tile's top-right corner.
                guard let bubble = view.agentBubbleFrame else { throw Failure(description: "\(where_): no bubble") }
                let spriteInTile = barView.convert(sprite, to: view)
                try expect(abs(spriteInTile.midY - bubble.midY) < tolerance && abs(spriteInTile.midX - bubble.midX) < tolerance,
                           "\(where_): the character is centred in its bubble (\(spriteInTile) in \(bubble))")
                try expect(abs(mark.midY - bar / 2) < 0.01, "\(where_): the mark is centred in the bar (\(mark.midY))")
                let close = view.qaCloseButtonFrame
                try expect(abs(close.midY - bar / 2) < 0.01, "\(where_): × stays centred (\(close.midY))")
                if let actions = view.titleBarActionsFrameForQA {
                    try expect(abs(actions.midY - bar / 2) < 0.01, "\(where_): ⋯ stays centred (\(actions.midY))")
                }
                if let pill = view.qaStatusPillRectInBar() {
                    try expect(abs(pill.midY - bar / 2) < 0.01, "\(where_): the status pill stays centred (\(pill.midY))")
                    try expect(!pill.intersects(sprite), "\(where_): the character never sits under the pill")
                }
                if let title = view.qaTitleRectInBar(), title.width > 0 {
                    try expect(abs(title.midY - bar / 2) < 0.51, "\(where_): the title is centred (\(title.midY))")
                    try expect(title.minX >= sprite.maxX, "\(where_): the title starts after the character")
                }
                let titleSize = 12 * max(1 + (factor - 1) / 2, chrome)
                try expect(abs(view.qaTitleFontWorldSize - titleSize) < 0.01,
                           "\(where_): the title is \(titleSize) pt (half the step, never below Small's), got \(view.qaTitleFontWorldSize)")
                report.append("\(name) at \(Int(zoom * 100))%: bar \(bar) pt, header \(art * CGFloat(zoom) * backing) px/art px")
            }
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            settle()

            // Sidebar: the row, the slot, the mark.
            guard let cell = inbox.cellForQA(id: rowID), let rowSprite = cell.characterRectForQA,
                  let rowMark = cell.providerMarkRectForQA, let rowHeight = inbox.rowHeightForQA(id: rowID),
                  let todayRowHeight else {
                let cell = inbox.cellForQA(id: rowID)
                throw Failure(description: "\(name): no sidebar row (\(cell != nil)), character (\(cell?.characterRectForQA as Any)) or mark (\(cell?.providerMarkRectForQA as Any)), height \(inbox.rowHeightForQA(id: rowID) as Any), today \(todayRowHeight as Any)")
            }
            try expect(abs(rowHeight - (todayRowHeight + Double(16 * (factor - 1)))) < 0.01,
                       "\(name): the sidebar row is \(todayRowHeight + Double(16 * (factor - 1))) pt, got \(rowHeight)")
            try expect(abs(rowSprite.width - 20 * perArt) < 0.01 && abs(rowSprite.height - 12 * perArt) < 0.01,
                       "\(name): the row's character is crisp at \(perArt * backing) device px per art px, got \(rowSprite.size)")
            let rowInWindow = cell.convert(rowSprite, to: nil)
            try expect(whole(rowInWindow.minX * inboxWindow.backingScaleFactor) && whole(rowInWindow.minY * inboxWindow.backingScaleFactor),
                       "\(name): the row's character starts on a device pixel (\(rowInWindow.origin))")
            try expect(abs(rowMark.width - (12 * factor).rounded()) < 0.01, "\(name): the row's mark is \((12 * factor).rounded()) pt")
            try expect(abs(rowSprite.midY - rowMark.midY) <= 1, "\(name): the row's character is centred with its mark")
            try expect(titleHeight() == todayTitleHeight, "\(name): the row's title keeps its type size")
            for neighbour in cell.characterNeighboursForQA where neighbour.frame.intersects(rowSprite) {
                throw Failure(description: "\(name): the row's character covers the \(neighbour.name)")
            }
            report.append("row \(rowHeight) pt, row sprite \(Int(perArt * backing)) px/art px")

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                inboxWindow.appearance = NSAppearance(named: appearance)
                settle()
                let tone = appearance == .aqua ? "light" : "dark"
                try SidebarCharacterChecks.capture(window, to: out.appendingPathComponent("size-\(name)-tile-\(tone).png"))
                try SidebarCharacterChecks.capture(inboxWindow, to: out.appendingPathComponent("size-\(name)-row-\(tone).png"))
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 0.5))
                settle()
                try SidebarCharacterChecks.capture(window, to: out.appendingPathComponent("size-\(name)-tile50-\(tone).png"))
                canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
                settle()
            }
            window.appearance = nil
            inboxWindow.appearance = nil
            settle()
        }

        // Back to Small: exactly today's pixels, in the header and in the row.
        choose("small")
        try expect(header() == todayHeader, "Small draws the header byte-identical to before any size was set")
        let smallRow = row()
        if smallRow != todayRow {
            try? todayRow?.write(to: out.appendingPathComponent("size-row-today.tiff"))
            try? smallRow?.write(to: out.appendingPathComponent("size-row-small.tiff"))
        }
        try expect(smallRow == todayRow, "Small draws the sidebar row byte-identical to before any size was set")
        try expect(inbox.rowHeightForQA(id: rowID) == todayRowHeight, "Small keeps today's row height")
        // Characters off at Large: no taller bar or row for a character nobody sees.
        choose("large")
        defaults.set(false, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()
        settle()
        try expect(view.chromeBarHeight == noteView.chromeBarHeight, "characters off: the agent bar is today's even at Large, got \(view.chromeBarHeight)")
        try expect(inbox.rowHeightForQA(id: rowID) == todayRowHeight, "characters off: today's row height even at Large")
        return "Character size checks passed at \(backing)x: " + report.joined(separator: "; ")
            + "; centred with mark, title, ⋯ and × at zoom 1 and 0.5; a note keeps today's bar; Small is byte-identical to today; off at Large changes nothing"
    }
}
