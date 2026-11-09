import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `--agent-identity-color-check`: an agent's identity colour, end to end.
///
/// Driven through the production seams only: the tile's own Color submenu item
/// (its target and action, as AppKit sends them), `AgentSupervisor.setIdentityColor`
/// behind it, a real `ManagedAgentTileNSView` bound to that supervisor in an
/// offscreen window, the Settings model's own write for the style (into a SUITE,
/// never the real domain), and the sidebar's row menu and cells fed by the
/// production row builder. Every assertion is an outcome — a persisted record, a
/// view on screen with a colour, an outline width — never a string in source.
@MainActor
enum AgentIdentityColorChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    /// sRGB components, so a tint can be compared whatever space it was built in.
    private static func components(_ color: CGColor?) -> [CGFloat]? {
        guard let color,
              let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count == 4 else { return nil }
        return parts
    }

    private static func same(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
        guard let a = components(lhs), let b = components(rhs) else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }

    private static func describe(_ color: CGColor?) -> String {
        components(color).map { $0.map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? "nil"
    }

    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-identity-color-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "array.check.agentIdentityColor.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            throw Failure(description: "could not open the check's defaults suite")
        }
        defer { suite.removePersistentDomain(forName: suiteName) }

        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: storeRoot))
        let tileId = UUID()
        let agentId = supervisor.spawn(
            role: nil, prompt: nil, cwd: project, harness: .claudeCode,
            model: "fixture/identity-colour", thinking: "medium", tileId: tileId,
            displayName: "Colour witness")

        // 1. THE MODEL. No colour by default, and a record written before the field
        //    existed decodes unchanged: nil, never a crash or a default tint.
        guard let fresh = supervisor.records[agentId] else { throw Failure(description: "spawn minted no record") }
        try expect(fresh.identityColor == nil, "a new agent has no colour, got \(fresh.identityColor ?? "")")
        let legacyJSON = try JSONEncoder().encode(fresh)
        let legacyObject = try JSONSerialization.jsonObject(with: legacyJSON) as? [String: Any] ?? [:]
        try expect(legacyObject["identityColor"] == nil,
                   "a colourless record writes no identityColor key, so old builds read it unchanged")
        let legacy = try JSONDecoder().decode(AgentRecord.self, from: legacyJSON)
        try expect(legacy == fresh, "a record without the key decodes to the same record")

        // 2. THE TILE AT REST, bound to the real supervisor in a real window.
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileId, kind: .managedAgent, title: "identity-colour",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420), zPosition: .fromLegacyRank(1),
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        tile.identityStyleDefaults = suite
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        try expect(tile.qaIdentityColorMenuEntries().isEmpty,
                   "a tile with no agent offers no Color menu — the colour belongs to the agent")
        tile.attach(agentID: agentId, supervisor: supervisor)
        tile.layoutSubtreeIfNeeded()
        var changeCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: ManagedAgentTileNSView.identityColorDidChangeNotification, object: tile, queue: nil
        ) { _ in changeCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        func assertRest(_ stage: String) throws {
            try expect(tile.identityColor == nil, "\(stage): identityColor is nil")
            try expect(tile.qaIdentityBar == nil, "\(stage): no title-bar wash at rest")
            try expect(tile.layer?.borderWidth == 0,
                       "\(stage): the tile paints a zero-width perimeter at rest, got \(tile.layer?.borderWidth ?? -1)")
        }
        try assertRest("before any pick")
        let menu = tile.qaIdentityColorMenuEntries()
        try expect(menu.map(\.title) == ["None"] + ZoneColorConfig.palette.map(\.capitalized),
                   "the Color submenu is None then the zone palette in its order, got \(menu.map(\.title))")
        try expect(menu.filter(\.isOn).map(\.title) == ["None"], "None is checked at rest, got \(menu.filter(\.isOn).map(\.title))")

        // 3. PICK PURPLE through the real menu item.
        try expect(tile.qaInvokeIdentityColorMenuItem("agentTile.identityColor.purple"), "the Purple item is invocable")
        try expect(supervisor.records[agentId]?.identityColor == "purple",
                   "the pick lands on the record, got \(supervisor.records[agentId]?.identityColor ?? "nil")")
        let reloaded = try AgentStore(applicationSupportDirectory: storeRoot).load(id: agentId)
        try expect(reloaded?.identityColor == "purple",
                   "the colour is on disk: a fresh store reads \(reloaded?.identityColor ?? "nil")")
        let relaunched = AgentSupervisor(store: AgentStore(applicationSupportDirectory: storeRoot))
        _ = relaunched.restore()
        try expect(relaunched.records[agentId]?.identityColor == "purple",
                   "a relaunched supervisor restores the colour, got \(relaunched.records[agentId]?.identityColor ?? "nil")")
        try expect(changeCount == 1, "the tile announced exactly one identity change, got \(changeCount)")
        let purple = ZoneChromeNSView.color(named: "purple")
        try expect(same(tile.identityColor?.cgColor, purple.cgColor),
                   "the dictation hook reads the resolved tint: \(describe(tile.identityColor?.cgColor))")
        try expect(same(tile.qaDictationPillForChecks.tint?.cgColor, purple.cgColor),
                   "a purple agent's dictation pill draws purple: \(describe(tile.qaDictationPillForChecks.tint?.cgColor))")
        try expect(tile.qaIdentityColorMenuEntries().filter(\.isOn).map(\.title) == ["Purple"],
                   "the checkmark moved to Purple")

        // 4. TOP BAR (the default style): the whole title bar washed in the muted tint.
        tile.layoutSubtreeIfNeeded()
        guard let wash = tile.qaIdentityBar else {
            throw Failure(description: "top-bar mode washed no title bar for a purple agent")
        }
        try expect(wash.frame.width == tile.bounds.width && wash.frame.height == TileNSView.titleBarHeight,
                   "the wash covers the whole title bar: \(wash.frame)")
        let mutedBar = purple.withAlphaComponent(ManagedAgentTileNSView.identityBarAlpha).cgColor
        try expect(same(wash.color, mutedBar),
                   "the title bar is purple at \(ManagedAgentTileNSView.identityBarAlpha) alpha, got \(describe(wash.color))")
        try expect(tile.layer?.borderWidth == 0, "top-bar mode leaves the outline alone")

        // 5. FULL BORDER through the Settings model's own write.
        let model = SettingsModel(defaults: suite, navKeymap: .default)
        guard let styleField = model.sections.flatMap(\.fields).first(where: { $0.key == AgentIdentityColorConfig.styleKey }) else {
            throw Failure(description: "Settings offers no '\(AgentIdentityColorConfig.styleKey)' row")
        }
        guard case let .choice(_, label, options, defaultValue, titles) = styleField else {
            throw Failure(description: "the style row is not a choice")
        }
        try expect(label == "Agent colour shows as" && options == ["topBar", "border"] && defaultValue == "topBar"
                    && titles["topBar"] == "Top bar" && titles["border"] == "Full border",
                   "the style row reads Top bar / Full border, default Top bar — got \(label) \(options) \(defaultValue) \(titles)")
        model.write(.string(AgentIdentityColorStyle.border.rawValue), to: styleField)
        tile.layoutSubtreeIfNeeded()
        try expect(tile.qaIdentityBar == nil, "full-border mode removes the title-bar wash")
        try expect(tile.layer?.borderWidth == ManagedAgentTileNSView.identityBorderWidth,
                   "full-border mode draws the outline at \(ManagedAgentTileNSView.identityBorderWidth), got \(tile.layer?.borderWidth ?? -1)")
        let mutedBorder = purple.withAlphaComponent(ManagedAgentTileNSView.identityBorderAlpha).cgColor
        try expect(same(tile.layer?.borderColor, mutedBorder),
                   "the outline is muted purple, got \(describe(tile.layer?.borderColor))")
        try expect(suite.string(forKey: AgentIdentityColorConfig.styleKey) == "border",
                   "the Settings write landed in the check's suite, which is what the tile read")
        // An appearance flip re-runs applyTokens; it must not reset the outline.
        tile.applyTokens()
        try expect(tile.layer?.borderWidth == ManagedAgentTileNSView.identityBorderWidth,
                   "applyTokens keeps the identity outline in full-border mode")

        // 6. BACK TO TOP BAR, then NONE: the exact rest state returns.
        model.write(.string(AgentIdentityColorStyle.topBar.rawValue), to: styleField)
        try expect(tile.qaIdentityBar != nil && tile.layer?.borderWidth == 0,
                   "switching back to top bar restores the title-bar wash and drops the outline")
        model.write(.string(AgentIdentityColorStyle.border.rawValue), to: styleField)
        try expect(tile.qaInvokeIdentityColorMenuItem("agentTile.identityColor.none"), "the None item is invocable")
        try expect(supervisor.records[agentId]?.identityColor == nil, "None clears the record")
        let clearedOnDisk = try AgentStore(applicationSupportDirectory: storeRoot).load(id: agentId)
        try expect(clearedOnDisk != nil && clearedOnDisk?.identityColor == nil, "None is on disk too")
        try expect(tile.qaDictationPillForChecks.tint == nil, "None returns the dictation pill to the input accent")
        try assertRest("after None in full-border mode")
        model.write(.string(AgentIdentityColorStyle.topBar.rawValue), to: styleField)
        try assertRest("after None in top-bar mode")
        try expect(changeCount == 2, "set and clear are two announcements, got \(changeCount)")

        // 7. THE SIDEBAR: rows from the production builder, the row menu's Color
        //    palette, the dot on the card and on the slim row.
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        inbox.wiredRowActions = AppDelegate.wiredInboxRowActions
        inbox.onRowAction = { _, _ in }
        inbox.onIdentityColorSelection = { ids, color in
            AppDelegate.applyIdentityColorFromInbox(ids, color: color, supervisor: supervisor)
        }
        let inboxWindow = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        inboxWindow.contentView = inbox
        inboxWindow.orderFrontOffscreenForChecks()
        defer { inboxWindow.orderOut(nil) }
        let now = Date()
        func rows(settled: Bool = false) throws -> [AgentInboxRow] {
            guard var record = supervisor.records[agentId] else { throw Failure(description: "the record vanished") }
            if settled { record.settledOverride = .settled; record.settledAt = now }
            return [AgentInboxRowBuilder.row(
                from: AgentsBoardRow(agentId: agentId.rawValue, status: .idle, lastSummary: "",
                                     recent: [], updatedAt: now),
                record: record, now: now)]
        }
        func drawn(_ stage: String) throws -> (dot: (frame: NSRect, colour: NSColor)?, title: NSRect) {
            inbox.layoutSubtreeIfNeeded()
            guard let found = inbox.identityDotForQA(agentId: agentId.rawValue) else {
                throw Failure(description: "\(stage): the inbox drew no cell for the agent")
            }
            return found
        }
        inbox.reload(rows: try rows())
        let cardRest = try drawn("card at rest")
        try expect(cardRest.dot == nil, "card at rest: no dot without a colour")

        try expect(inbox.openRowMenuForQA(clickedRowId: agentId.rawValue), "the row menu opens on the agent")
        try expect(inbox.rowMenuTitlesForQA.contains(InboxRowAction.color.title(forCount: 1)),
                   "the row menu offers Color ›, got \(inbox.rowMenuTitlesForQA)")
        try expect(inbox.pickRowMenuItemForQA(.color), "Color › is live")
        try expect(inbox.identityColorChoiceTitlesForQA == ["None"] + ZoneColorConfig.palette.map(\.capitalized),
                   "the row palette matches the tile's, got \(inbox.identityColorChoiceTitlesForQA)")
        try expect(inbox.chooseIdentityColorForQA("Blue"), "Blue is pickable")
        try expect(supervisor.records[agentId]?.identityColor == "blue", "the row pick lands on the record")
        try expect(same(tile.identityColor?.cgColor, ZoneChromeNSView.color(named: "blue").cgColor)
                    && tile.qaIdentityBar != nil,
                   "a pick in the sidebar repaints the agent's open tile")

        inbox.reload(rows: try rows())
        let card = try drawn("card with a colour")
        guard let cardDot = card.dot else { throw Failure(description: "card: the dot is missing for a blue agent") }
        let blueDot = AgentInboxView.identityDotColour(named: "blue").cgColor
        try expect(same(cardDot.colour.cgColor, blueDot), "card: the dot is muted blue, got \(describe(cardDot.colour.cgColor))")
        try expect(cardDot.frame.width == AgentInboxView.identityDotSide && cardDot.frame.height == AgentInboxView.identityDotSide,
                   "card: the dot is \(AgentInboxView.identityDotSide)pt, got \(cardDot.frame)")
        try expect(cardDot.frame.maxX < card.title.minX && cardDot.frame.minY >= card.title.minY
                    && cardDot.frame.maxY <= card.title.maxY,
                   "card: the dot leads the name inside its band — dot \(cardDot.frame), title \(card.title)")

        inbox.reload(rows: try rows(settled: true))
        let slim = try drawn("slim row with a colour")
        guard let slimDot = slim.dot else { throw Failure(description: "slim: the dot is missing for a blue agent") }
        try expect(same(slimDot.colour.cgColor, blueDot), "slim: the dot is muted blue")
        try expect(slimDot.frame.maxX <= slim.title.minX && slimDot.frame.midY >= slim.title.minY
                    && slimDot.frame.midY <= slim.title.maxY,
                   "slim: the dot sits before the name on its line — dot \(slimDot.frame), title \(slim.title)")

        // None from the row menu: the record clears and both rows lay out as before.
        try expect(inbox.openRowMenuForQA(clickedRowId: agentId.rawValue) && inbox.pickRowMenuItemForQA(.color)
                    && inbox.chooseIdentityColorForQA("None"), "None is pickable from the row menu")
        try expect(supervisor.records[agentId]?.identityColor == nil, "row None clears the record")
        try assertRest("after a row-menu None")
        inbox.reload(rows: try rows(settled: true))
        let slimRest = try drawn("slim at rest")
        try expect(slimRest.dot == nil, "slim at rest: no dot")
        inbox.reload(rows: try rows())
        let cardCleared = try drawn("card cleared")
        try expect(cardCleared.dot == nil && cardCleared.title.minX == cardRest.title.minX,
                   "card cleared: no dot and the name back at x=\(cardRest.title.minX), got \(cardCleared.title.minX)")

        return "AgentIdentityColor: no colour by default and legacy records decode unchanged; the tile's Color "
            + "submenu (None + \(ZoneColorConfig.palette.count) zone colours) persisted purple through the supervisor, "
            + "a fresh store and a relaunch; the whole title bar washed at "
            + "\(ManagedAgentTileNSView.identityBarAlpha) alpha; Settings' Full border swapped it "
            + "for a \(ManagedAgentTileNSView.identityBorderWidth)pt outline at \(ManagedAgentTileNSView.identityBorderAlpha) "
            + "alpha that survives applyTokens; None restored the zero-perimeter rest state; the sidebar row menu's "
            + "Color › set blue (repainting the open tile) with a \(AgentInboxView.identityDotSide)pt dot before the name "
            + "on the card and the slim row, and its None put the name back where it was"
    }
}
