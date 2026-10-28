import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Exercises the shipped trigger, panel and choice list. Offscreen AppKit views;
/// no live registry, project, preferences, terminal or provider is acquired.
@MainActor
enum WorkspaceSelectorChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws -> String {
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw Failure(description: message) }
        }
        let artifact = URL(fileURLWithPath: "qa-runs/workspace-selector", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        func capture(_ view: NSView, _ name: String) throws -> Data {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(description: "No bitmap for \(name)")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw Failure(description: "No PNG for \(name)")
            }
            try data.write(to: artifact.appendingPathComponent(name + ".png"))
            return data
        }
        let now = Date(timeIntervalSince1970: 1_900_500_000)
        func entry(_ n: Int, _ name: String) -> WorkspaceEntry {
            WorkspaceEntry(id: UUID(uuidString: String(format: "D0000000-0000-4000-8000-%012X", n))!,
                           name: name, projectIds: [], createdAt: now, updatedAt: now)
        }
        let personal = entry(1, "personal"), work = entry(2, "work"), duplicate = entry(3, "personal")
        var images: [Data] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let bar = WorkspaceTopBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            host.appearance = NSAppearance(named: appearance)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
            host.contentView = content
            bar.frame.origin.y = 392
            content.addSubview(bar)
            host.orderFrontOffscreenForChecks()
            defer { bar.titlePopoverForQA.dismiss(); host.orderOut(nil) }
            var switched: [UUID] = [], renamed: [UUID] = [], deleted: [UUID] = []
            var creates = 0
            bar.onSwitchWorkspace = { switched.append($0) }
            bar.onCreateWorkspace = { creates += 1 }
            bar.onRenameWorkspace = { renamed.append($0) }
            bar.onDeleteWorkspace = { deleted.append($0) }
            func reload(_ entries: [WorkspaceEntry] = [personal, work, duplicate]) {
                bar.reload(WorkspaceTopBarModel(currentWorkspaceId: personal.id, currentWorkspaceName: personal.name,
                    projectCount: 0, zoneCount: 0, saveState: .saved, workspaces: entries, managementMessage: nil))
                content.layoutSubtreeIfNeeded()
            }
            func openedList() throws -> ChoiceListView {
                guard bar.titlePopoverForQA.isPresented,
                      let panel = bar.titlePopoverForQA.panel,
                      let list = bar.titlePopoverForQA.listView else {
                    throw Failure(description: "\(name): workspace trigger did not open the shared AppKit choice panel")
                }
                panel.contentView?.layoutSubtreeIfNeeded()
                try expect(bar.titleButtonForQA.isActive, "\(name): open trigger has no active state")
                try expect(panel.parent === host, "\(name): dropdown is not owned by its window")
                try expect(list.accessibilityLabel() == "Workspaces", "\(name): wrong accessibility name")
                return list
            }
            reload()
            // AX invokes the production presentation, with identity and rendered checks.
            try expect(bar.titleButtonForQA.accessibilityPerformPress(), "AX press refused")
            let list = try openedList()
            try expect(list.qaRenderedRowHeight == 30, "Compact workspace rows are \(list.qaRenderedRowHeight)pt, expected 30pt")
            try expect(list.qaRowStates.filter(\.checkVisible).map(\.id) == [personal.id.uuidString], "Wrong rendered current-workspace checkmark")
            try expect(list.qaItems.filter { $0.title == "personal" }.map(\.id) == [personal.id.uuidString, duplicate.id.uuidString], "Duplicate names collapsed")
            try expect(list.qaItems.filter(\.separatorBefore).map(\.id) == ["workspace.create"], "Management section is not separated")
            try expect(list.qaTruncatedRowTitles.isEmpty, "Ordinary workspace labels are clipped")
            images.append(try capture(bar.titlePopoverForQA.surfaceView!, "workspace-menu-" + name))
            _ = try capture(bar, "workspace-trigger-" + name)
            let openedPanel = bar.titlePopoverForQA.panel
            let focused = list.focusedID
            reload()
            try expect(bar.titlePopoverForQA.panel === openedPanel && bar.titlePopoverForQA.isPresented
                       && list.focusedID == focused && bar.titleButtonForQA.isActive,
                       "Unchanged workspace refresh interrupted the open dropdown")
            for (id, color) in list.qaRowTitleColors where UUID(uuidString: id) != nil {
                try expect(color == TextToken.textPrimary.color.nsColor(for: host.effectiveAppearance.tokenTheme),
                           "\(name): rendered workspace text has the wrong appearance colour")
            }
            list.perform(.next)
            list.perform(.accept)
            try expect(switched == [work.id], "Keyboard selection dispatched the wrong workspace UUID")
            try expect(!bar.titlePopoverForQA.isPresented && !bar.titleButtonForQA.isActive, "Selection left dropdown active")
            try expect(host.firstResponder === bar.titleButtonForQA, "Selection did not return focus to trigger")
            try expect(bar.workspaceNameForQA == "personal", "Selection changed title before runtime confirmed switch")
            // Duplicate-name item must route to its own UUID; selecting current is inert.
            try expect(bar.selectWorkspaceForQA(duplicate.id), "Duplicate workspace selection refused")
            try expect(switched == [work.id, duplicate.id], "Duplicate name dispatched to the wrong workspace")
            _ = bar.selectWorkspaceForQA(personal.id)
            try expect(switched.count == 2, "Current workspace selection dispatched a redundant switch")
            _ = bar.clickCreateForQA(); _ = bar.clickRenameForQA(); _ = bar.clickDeleteForQA()
            try expect(creates == 1 && renamed == [personal.id] && deleted == [personal.id], "Management commands did not dispatch current identity")
            try expect(bar.workspaceNameForQA == "personal", "Management action replaced the workspace title")
            // Keyboard opening/Escape and press opening use the actual responder methods.
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
            bar.titleButtonForQA.keyDown(with: down)
            let escapedList = try openedList()
            escapedList.perform(.cancel)
            try expect(!bar.titlePopoverForQA.isPresented && !bar.titleButtonForQA.isActive && switched.count == 2, "Escape changed selection or retained active fill")
            let press = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            bar.titleButtonForQA.mouseDown(with: press)
            _ = try openedList()
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            try expect(!bar.titlePopoverForQA.isPresented && !bar.titleButtonForQA.isActive, "App deactivation did not dismiss and clear active fill")
            // Actual monitor filtering must consume a closing trigger click, so
            // delivery to mouseDown cannot reopen the menu on that same press.
            // The monitor supplies event.window in production. This offline host
            // supplies it explicitly: sandbox WindowServer denies NSEvent.window.
            _ = bar.titleButtonForQA.accessibilityPerformPress()
            let anchorPoint = bar.titleButtonForQA.convert(
                NSPoint(x: bar.titleButtonForQA.bounds.midX, y: bar.titleButtonForQA.bounds.midY), to: nil)
            let closingPress = NSEvent.mouseEvent(with: .leftMouseDown, location: anchorPoint,
                modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 1)!
            try expect(bar.titlePopoverForQA.filterPointerEvent(closingPress, originatingWindow: host) == nil
                       && !bar.titlePopoverForQA.isPresented && !bar.titleButtonForQA.isActive,
                       "Closing trigger click was delivered again and could reopen the dropdown")
            _ = bar.titleButtonForQA.accessibilityPerformPress()
            let outsidePress = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 580, y: 10),
                modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil,
                eventNumber: 3, clickCount: 1, pressure: 1)!
            try expect(bar.titlePopoverForQA.filterPointerEvent(outsidePress, originatingWindow: host) === outsidePress
                       && !bar.titlePopoverForQA.isPresented && !bar.titleButtonForQA.isActive,
                       "Outside click did not dismiss and continue to its intended target")
            // Owner dismissal, stale model replacement, switch lock and failure recovery.
            _ = bar.titleButtonForQA.accessibilityPerformPress()
            reload([personal])
            try expect(!bar.titlePopoverForQA.isPresented && !bar.titleButtonForQA.isActive, "Reload retained a stale menu")
            try expect(!bar.deleteEnabledForQA && bar.deleteMenuTitleForQA.contains("only workspace"), "Only-workspace Delete lost refusal")
            _ = bar.titleButtonForQA.accessibilityPerformPress()
            let only = try openedList()
            only.choose(id: "workspace.delete")
            try expect(deleted.count == 1, "Disabled Delete dispatched")
            only.perform(.last)
            try expect(only.focusedID == "workspace.rename", "Keyboard did not skip disabled Delete")
            _ = try capture(bar.titlePopoverForQA.surfaceView!, "workspace-only-" + name)
            reload()
            bar.beginSwitching(to: work.id, name: work.name)
            _ = bar.titleButtonForQA.accessibilityPerformPress()
            let switching = try openedList()
            try expect(switching.qaRowStates.filter(\.checkVisible).map(\.id) == [work.id.uuidString], "Switch progress check is not on target")
            switching.choose(id: duplicate.id.uuidString)
            try expect(switched.count == 2 && switching.qaItems.allSatisfy { !$0.enabled }, "Switch in flight allowed another action")
            bar.endSwitching(); reload()
            try expect(bar.workspaceNameForQA == "personal", "Failed switch did not restore confirmed name")
            // Long/large lists scroll and keyboard focus remains visible at the end.
            let many = [personal] + (4...40).map { entry($0, "Workspace \($0) — an extended workspace name") }
            reload(many)
            _ = bar.titleButtonForQA.accessibilityPerformPress()
            let longList = try openedList()
            let typeahead = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 10,
                windowNumber: host.windowNumber, context: nil, characters: "workspace 40", charactersIgnoringModifiers: "workspace 40",
                isARepeat: false, keyCode: 0)!
            longList.keyDown(with: typeahead)
            try expect(longList.focusedID == many.last?.id.uuidString && longList.qaFocusedRowIsVisible,
                       "Typeahead did not scroll the offscreen workspace into view")
            longList.perform(.last)
            try expect(longList.enclosingScrollView != nil && longList.qaFocusedRowIsVisible, "Long list cannot scroll keyboard focus into view")
            _ = try capture(bar.titlePopoverForQA.surfaceView!, "workspace-many-" + name)
            bar.titlePopoverForQA.dismiss()
            try expect(!bar.titleButtonForQA.isActive, "Explicit dismissal retained active fill")
            // The surface stays on a constrained display, independently of list length.
            bar.titlePopoverForQA.present(items: bar.titleItemsForQA, selectedID: personal.id.uuidString,
                presentation: .compactChoices, layout: .commands(CommandPopoverLayout()),
                anchor: bar.titleButtonForQA.bounds, relativeTo: bar.titleButtonForQA,
                placementFrame: host.frame.insetBy(dx: 20, dy: 140), onSelection: { _ in })
            try expect((bar.titlePopoverForQA.surfaceFrame?.height ?? 0) <= 140,
                       "Dropdown exceeds the available display height")
            bar.titlePopoverForQA.dismiss()
            // Removal tears down a live panel; no orphan window or active highlight.
            _ = bar.titleButtonForQA.accessibilityPerformPress()
            let panel = bar.titlePopoverForQA.panel
            bar.removeFromSuperview()
            try expect(!bar.titlePopoverForQA.isPresented && panel?.parent == nil && !bar.titleButtonForQA.isActive, "Detached selector leaked its panel")
        }
        try expect(images.count == 2 && images[0] != images[1], "Light/dark dropdown captures are identical")
        let unloaded = WorkspaceTopBarView(frame: .zero)
        try expect(!unloaded.deleteEnabledForQA && unloaded.deleteMenuTitleForQA.contains("loading"), "Unloaded Delete lost explanation")
        return "Workspace selector passed: native pointer/keyboard/AX presentation, UUID picks, rendered checks, management, switch lock, dismissal/focus, scrolling and light/dark captures at \(artifact.path)"
    }
}
