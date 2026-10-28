import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Audits the menu AppKit actually validates and dispatches, including nested
/// commands. No QA replacement menu, provider processes, or tmux server.
@MainActor
enum AgentNativeMenuChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-native-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "array.check.agentNativeMenu.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure(description: "could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storeRoot = root.appendingPathComponent("store")
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: storeRoot))
        let tileID = UUID()
        let agentID = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode,
                                      model: "fixture/native-menu", thinking: "medium", tileId: tileID,
                                      displayName: "Native menu witness")
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "native-menu",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420), zPosition: .fromLegacyRank(1),
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        tile.identityStyleDefaults = defaults
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { tile.detach(); window.orderOut(nil) }
        tile.attach(agentID: agentID, supervisor: supervisor)
        tile.layoutSubtreeIfNeeded()

        var visitedItems = 0
        func audit(_ menu: NSMenu) throws {
            menu.update() // AppKit validation must preserve disabled command states.
            for item in menu.items {
                visitedItems += 1
                try expect(item.view == nil, "\(menu.title)/\(item.title) replaces the native menu row")
                if let child = item.submenu { try audit(child) }
            }
        }
        func menu() throws -> NSMenu {
            let result = tile.titleBarContextMenuForQA()
            try audit(result)
            return result
        }
        func submenu(_ title: String, in menu: NSMenu) throws -> NSMenu {
            guard let child = menu.items.first(where: { $0.title == title })?.submenu else {
                throw Failure(description: "missing native \(title) submenu")
            }
            return child
        }
        func item(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
            guard let result = menu.items.first(where: { $0.identifier?.rawValue == identifier }) else {
                throw Failure(description: "missing item \(identifier)")
            }
            return result
        }
        func invoke(_ item: NSMenuItem, in menu: NSMenu) throws {
            try expect(item.target != nil && item.action != nil, "\(item.title) has no target/action")
            menu.performActionForItem(at: menu.index(of: item))
        }

        for percent in AgentPageZoom.steps {
            let zoom = AgentPageZoom(percent: percent)
            tile.setPageZoom(zoom)
            let zoomMenu = try submenu("Zoom", in: menu())
            let readout = try item("agentTile.pageZoom.readout", in: zoomMenu)
            try expect(!readout.isEnabled && readout.title.contains(zoom.displayPercentage), "page zoom readout after native validation")
            for command in AgentPageZoomCommand.allCases {
                let entry = try item("agentTile.pageZoom.\(command.rawValue)", in: zoomMenu)
                try expect(entry.isEnabled == command.isEnabled(for: zoom), "\(percent)% \(command.rawValue) changed enabled state during native validation")
            }
        }
        tile.setPageZoom(.default)
        let zoomMenu = try submenu("Zoom", in: menu())
        try invoke(item("agentTile.pageZoom.zoomIn", in: zoomMenu), in: zoomMenu)
        try expect(tile.pageZoom.percent == 110, "native Zoom In did not change the real tile")
        let resetMenu = try submenu("Zoom", in: menu())
        try invoke(item("agentTile.pageZoom.reset", in: resetMenu), in: resetMenu)
        try expect(tile.pageZoom == .default, "native Actual Size did not reset the real tile")

        let colorMenu = try submenu("Color", in: menu())
        try expect(colorMenu.items.filter { $0.state == .on }.map(\.title) == ["None"], "initial native color checkmark")
        try invoke(item("agentTile.identityColor.purple", in: colorMenu), in: colorMenu)
        let persisted = try AgentStore(applicationSupportDirectory: storeRoot).load(id: agentID)
        try expect(persisted?.identityColor == "purple" && tile.identityColor != nil, "native color action must persist and paint")
        let selectedColors = try submenu("Color", in: menu()).items.filter { $0.state == .on }.map(\.title)
        try expect(selectedColors == ["Purple"], "native color checkmark did not follow selection")

        let toolsBefore = supervisor.records[agentID]?.workspaceToolsEnabled
        let toolsMenu = try menu()
        let tools = try item("agentTile.workspaceTools.toggle", in: toolsMenu)
        try expect(tools.state == (toolsBefore == true ? .on : .off), "native workspace tools checkmark")
        try invoke(tools, in: toolsMenu)
        try expect(supervisor.records[agentID]?.workspaceToolsEnabled == !(toolsBefore ?? false), "native workspace tools action did not toggle record")

        let sounds = try submenu("Sounds", in: menu())
        let kinds = AgentSignalKind.allCases.sorted { $0.priority > $1.priority }
        try expect(sounds.items.map(\.title) == kinds.map(\.displayName), "native sound event hierarchy changed")
        guard let kind = kinds.first else { throw Failure(description: "no sound event kinds") }
        let choices = try submenu(kind.displayName, in: sounds)
        try expect(choices.items.filter { $0.state == .on }.map(\.title) == ["Inherit global"], "initial native sound checkmark")
        guard let mute = choices.items.first(where: { $0.title == "Mute" }) else { throw Failure(description: "missing native Mute item") }
        try invoke(mute, in: choices)
        try expect(tile.tile.metadata.agentSoundOverrides?.values[kind] == .mute, "native nested Mute action did not update tile")
        let updatedSounds = try submenu("Sounds", in: menu())
        let updatedChoices = try submenu(kind.displayName, in: updatedSounds)
        try expect(updatedChoices.items.filter { $0.state == .on }.map(\.title) == ["Mute"], "nested native sound checkmark did not follow selection")

        var stops = 0
        var detaches = 0
        tile.onStopRun = { stops += 1 }
        tile.onClose = { detaches += 1 }
        let actions = try menu()
        guard let stop = actions.items.first(where: { $0.title == AgentTileHeaderView.stopActionTitle }),
              let detach = actions.items.first(where: { $0.title == AgentTileHeaderView.detachActionTitle }) else {
            throw Failure(description: "missing stop/detach native actions")
        }
        try invoke(stop, in: actions)
        try expect(stops == 1 && detaches == 0, "Stop must only dispatch Stop")
        try invoke(detach, in: actions)
        try expect(stops == 1 && detaches == 1, "Detach must only dispatch Detach")
        try expect(supervisor.records[agentID] != nil, "menu actions removed the agent record")
        return "\(visitedItems) native rows audited; validated zoom end stops; nested sounds, color persistence, workspace policy and distinct stop/detach dispatched"
    }
}
