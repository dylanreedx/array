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

        let panelEvidence = try checkChoicePresentation(tile: tile, window: window, supervisor: supervisor, agentID: agentID)

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
        return "\(panelEvidence); \(visitedItems) native menu-model rows audited; validated zoom end stops; nested sounds, color persistence, workspace policy and distinct stop/detach dispatched"
    }

    /// The menu MODEL above cannot prove which UI opens. These assertions drive
    /// the actual header control, presented Choice panels and production rows.
    private static func checkChoicePresentation(
        tile: ManagedAgentTileNSView, window: NSWindow,
        supervisor: AgentSupervisor, agentID: AgentID
    ) throws -> String {
        // The renderer retains the real control outside the subview tree and
        // paints its cached pixels inline. Follow that production owner.
        guard let button = tile.titleBarActionsButtonForQA as? AgentTileOverflowButton else {
            throw Failure(description: "the actual agent tile has no actions button")
        }
        let priorPointer = ManagedAgentTileNSView.qaPointerInside
        let priorButtons = ManagedAgentTileNSView.chromePressedMouseButtons
        ManagedAgentTileNSView.qaPointerInside = { _ in false }
        ManagedAgentTileNSView.chromePressedMouseButtons = { 0 }
        defer {
            ManagedAgentTileNSView.qaPointerInside = priorPointer
            ManagedAgentTileNSView.chromePressedMouseButtons = priorButtons
        }
        window.makeFirstResponder(nil)
        _ = tile.restChromeIfIdle()
        try expect(tile.qaChromeCanvas != nil && tile.isChromeResting && tile.titleBarControlsAreDrawn,
                   "idle fixture must retain the released cached chrome renderer")
        try expect(tile.qaDrawnTitleBarControls.contains { $0 === button },
                   "the resting titlebar must retain its actions control behind cached pixels")
        // RED on the former stock-menu implementation: AX press did nothing.
        try expect(button.accessibilityPerformPress(), "AX pressing Agent actions must open the shared Choice menu")
        guard let controller = tile.qaActionsMenuController, controller.isPresented else {
            throw Failure(description: "Agent actions presented no shared Choice panel")
        }
        defer { controller.dismiss() }
        try expect(!tile.isChromeResting, "opening the shared menu must wake cached chrome")
        try expect(!tile.restChromeForCameraMotion(pressBelongsToPan: true),
                   "camera motion must not rest chrome while the actions menu is open")
        try expect(controller.isPresented && !tile.isChromeResting,
                   "a camera rest attempt must preserve the visible menu and its live anchor")
        let artifacts = try AgentFaceChecks.runDirectory("agent-choice-menu")
        func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        func list(_ depth: Int) throws -> ChoiceListView {
            guard controller.qaPopovers.indices.contains(depth),
                  let list = controller.qaPopovers[depth].listView,
                  let panel = list.window, panel.isVisible else {
                throw Failure(description: "no actual visible Choice panel at depth \(depth)")
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            try expect(list.frame.width > 0 && list.frame.height > 0, "Choice panel has empty layout")
            return list
        }
        func row(_ title: String, depth: Int) throws -> NSView {
            let choices = try list(depth)
            guard let index = choices.items.firstIndex(where: { $0.title == title }),
                  let children = choices.accessibilityChildren() as? [NSView],
                  children.indices.contains(index) else {
                throw Failure(description: "no rendered accessible \(title) row at depth \(depth)")
            }
            return children[index]
        }
        func key(_ code: UInt16, text: String = "", depth: Int) throws {
            let choices = try list(depth)
            guard let panel = choices.window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: code) else {
                throw Failure(description: "could not create panel keyboard event")
            }
            panel.makeFirstResponder(choices)
            panel.sendEvent(event)
            pump()
        }
        func hover(_ title: String, depth: Int) throws {
            let target = try row(title, depth: depth)
            guard let panel = target.window,
                  let event = NSEvent.enterExitEvent(with: .mouseEntered,
                    location: target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                    trackingNumber: 0, userData: nil) else {
                throw Failure(description: "could not create production row hover event")
            }
            target.mouseEntered(with: event)
            // Hover intentionally goes through the row's event handler and any
            // controller dwell timer, rather than a QA submenu-opening method.
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        func click(_ title: String, depth: Int) throws {
            let target = try row(title, depth: depth)
            guard let panel = target.window else { throw Failure(description: "row lost its panel") }
            try AgentFaceChecks.click(AgentFaceChecks.windowPoint(of: target.bounds, in: target), in: panel)
            pump()
        }
        func capture(_ name: String, depth: Int) throws {
            let choices = try list(depth)
            guard let content = choices.window?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw Failure(description: "could not render presented menu")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                throw Failure(description: "presented menu rendered no PNG")
            }
            try png.write(to: artifacts.appendingPathComponent(name + ".png"))
        }
        func captureCascade(_ name: String) throws {
            let panels = controller.qaPopovers.compactMap { $0.listView?.window }
            try expect(!panels.isEmpty, "no visible cascade to capture")
            let union = panels.map(\.frame).reduce(NSRect.null) { $0.union($1) }
            guard union.width > 0, union.height > 0, union.width < 4000, union.height < 4000,
                  let context = CGContext(data: nil, width: Int(ceil(union.width * 2)),
                    height: Int(ceil(union.height * 2)), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(description: "could not allocate cascade capture")
            }
            context.scaleBy(x: 2, y: 2)
            for panel in panels {
                guard let content = panel.contentView,
                      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                    throw Failure(description: "could not capture a cascade member")
                }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { throw Failure(description: "cascade member has no pixels") }
                let frame = panel.frame.offsetBy(dx: -union.minX, dy: -union.minY)
                context.draw(image, in: frame)
            }
            guard let image = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw Failure(description: "cascade capture rendered no PNG")
            }
            try png.write(to: artifacts.appendingPathComponent(name + ".png"))
        }
        // Traverse NSApplication's event queue so local monitor consumption
        // and dispatch both run; direct list/window responder calls skip them.
        func postAndDispatch(_ event: NSEvent, matching mask: NSEvent.EventTypeMask) {
            NSApplication.shared.postEvent(event, atStart: true)
            if let queued = NSApplication.shared.nextEvent(matching: mask,
                until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(queued)
            }
            pump()
        }
        func openByPointer() throws {
            guard let actions = tile.qaBandControlFrames.first(where: { $0.name == "actions" }) else {
                throw Failure(description: "no actual titlebar actions hit target")
            }
            try AgentFaceChecks.click(AgentFaceChecks.windowPoint(of: actions.frame, in: tile), in: window)
            pump()
            try expect(controller.isPresented, "pointer click on Agent actions opened no shared Choice menu")
        }

        // Root and nested surfaces are rendered in both real appearances. The
        // source NSMenu remains only an action model, never the presented UI.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            controller.dismiss()
            window.appearance = NSAppearance(named: appearance)
            tile.appearance = window.appearance
            try openByPointer()
            let root = try list(0)
            try expect(root.items.contains { $0.title == "Sounds" } && root.items.contains { $0.title == "Zoom" },
                       "the presented root omits production submenu rows")
            try capture("root-\(appearance.rawValue)", depth: 0)
            try key(6, text: "zoom", depth: 0)
            try key(124, depth: 0)
            let zoom = try list(1)
            try expect(zoom.items.contains { $0.title == "Zoom In" }, "Right Arrow did not present Zoom child")
            try expect(zoom.items.contains { $0.title == "Actual Size" && !$0.enabled },
                       "presented Actual Size must be visibly disabled at 100%")
            try expect(!(try row("Actual Size", depth: 1)).accessibilityPerformPress(),
                       "a disabled rendered row must reject AX activation")
            try capture("zoom-\(appearance.rawValue)", depth: 1)
            try captureCascade("zoom-cascade-\(appearance.rawValue)")
            try key(123, depth: 1)
            try expect(controller.qaPopovers.count == 1, "Left Arrow did not return to the root")
            try key(53, depth: 0)
            try expect(!controller.isPresented, "Escape left the Choice menu chain visible")
        }

        try openByPointer()
        try hover("Zoom", depth: 0)
        _ = try list(1)
        guard let actionsFrame = tile.qaBandControlFrames.first(where: { $0.name == "actions" })?.frame,
              let triggerPress = NSEvent.mouseEvent(with: .leftMouseDown,
                location: AgentFaceChecks.windowPoint(of: actionsFrame, in: tile), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 1) else {
            throw Failure(description: "could not create root trigger re-click")
        }
        postAndDispatch(triggerPress, matching: .leftMouseDown)
        try expect(!controller.isPresented && controller.qaPopovers.isEmpty,
                   "root trigger re-click with a child must close the cascade without reopening it")

        try openByPointer()
        let shortcutList = try list(0)
        guard let shortcutPanel = shortcutList.window,
              let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shortcutPanel.windowNumber,
                context: nil, characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24) else {
            throw Failure(description: "could not create Command-equals menu shortcut")
        }
        postAndDispatch(shortcut, matching: .keyDown)
        try expect(tile.pageZoom.percent == 110 && !controller.isPresented,
                   "Command-equals through the actual menu monitor must zoom the tile and close the cascade")
        tile.setPageZoom(.default)

        try openByPointer()
        try hover("Zoom", depth: 0)
        _ = try list(1)
        try click("Zoom In", depth: 1)
        try expect(tile.pageZoom.percent == 110 && !controller.isPresented,
                   "clicking rendered Zoom In must reflow the real tile and dismiss the chain")
        tile.setPageZoom(.default)

        // Real nested hover, then an actual accessible row press dispatches the
        // same menu command as pointer/keyboard, without invoking NSMenu directly.
        try openByPointer()
        try hover("Sounds", depth: 0)
        guard let kind = AgentSignalKind.allCases.sorted(by: { $0.priority > $1.priority }).first else {
            throw Failure(description: "no sound kinds")
        }
        try hover(kind.displayName, depth: 1)
        try capture("sound-nested-dark", depth: 2)
        try captureCascade("sound-cascade-dark")
        let muteRow = try row("Mute", depth: 2)
        try expect(muteRow.accessibilityPerformPress(), "AX pressing nested Mute failed")
        try expect(tile.tile.metadata.agentSoundOverrides?.values[kind] == .mute && !controller.isPresented,
                   "rendered nested Mute must change tile and dismiss all panels")
        // Restore initial sound state for the model audit below, via the UI.
        try openByPointer()
        try hover("Sounds", depth: 0)
        try hover(kind.displayName, depth: 1)
        try click("Inherit global", depth: 2)

        try openByPointer()
        try key(8, text: "color", depth: 0)
        try key(124, depth: 0)
        try key(35, text: "purple", depth: 1)
        try key(36, depth: 1)
        try expect(supervisor.records[agentID]?.identityColor == "purple" && !controller.isPresented,
                   "keyboard selection in visible Color submenu did not change the real agent")
        try openByPointer()
        try hover("Color", depth: 0)
        try click("None", depth: 1)

        try openByPointer()
        guard let outside = NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw Failure(description: "could not create outside click")
        }
        NSApplication.shared.sendEvent(outside)
        pump()
        try expect(!controller.isPresented, "outside click left shared Choice panels visible")
        window.makeFirstResponder(nil)
        _ = tile.restChromeIfIdle()
        try expect(tile.isChromeResting && tile.titleBarControlsAreDrawn,
                   "dismissed actions menu must allow cached chrome to rest again")
        try expect(tile.titleBarActionsButtonForQA === button
                   && tile.qaDrawnTitleBarControls.contains { $0 === button },
                   "menu presentation must retain the original cached titlebar control")
        // Remove the actual owning tile from its window with nested panels
        // open. The view's production lifecycle must dismiss every panel.
        try openByPointer()
        try hover("Zoom", depth: 0)
        _ = try list(1)
        let removedPanels = controller.qaPopovers.compactMap { $0.listView?.window }
        window.contentView = nil
        pump()
        try expect(!controller.isPresented && removedPanels.allSatisfy { !$0.isVisible },
                   "removing the tile owner left a root or child menu window visible")
        window.contentView = tile
        tile.layoutSubtreeIfNeeded()
        return "actual shared Choice panels: pointer/keyboard/AX, nested hover, trigger toggle, modified shortcut, owner teardown, dismissal, light/dark captures at \(artifacts.path)"
    }

}
