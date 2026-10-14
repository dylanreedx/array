import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
enum FloatingToolbarChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    static func run() throws {
        try checkCommandRegistryDrivesButtons()
        try checkEdgeOrientationAndSnapping()
        try checkFreePositionAndEdgeThreshold()
        try checkButtonVisibilityAndAgentChoices()
        try checkChoicePopoversSurvivePointerTransitions()
        try checkControllerDragEndAndPersistence()
        try checkControllerShowMakesVisiblePanel()
        try checkSettingsWriteAndReset()
        print("floating-toolbar: visible command buttons, free/snap position restore, provider and fan-out choices, settings visibility, and reset")
    }

    private static func checkCommandRegistryDrivesButtons() throws {
        let expected = CommandRegistry.definitions().compactMap(\.floatingToolbarItem)
        let view = FloatingToolbarView(frame: NSRect(x: 0, y: 0, width: 640, height: 64))
        let suite = "array.floatingToolbar.check.buttons.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated button preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        view.defaults = defaults
        view.rebuildButtons()
        try expect(view.qaButtonTitles == expected.map(\.title),
                   "toolbar buttons diverged from CommandRegistry.definitions()")
        try expect(view.qaButtonsRemainVisible, "default hover-label mode hid the toolbar buttons")
        view.alwaysVisible = true
        try expect(view.qaButtonsRemainVisible && view.qaShowsLabelsAlways,
                   "Always Show Labels hid buttons or failed to enable persistent labels")
        try expect(expected.contains(where: { $0.action == .createZone }),
                   "Create Zone is missing from the command-backed toolbar")
        try expect(expected.contains(where: { $0.action == .terminalProfiles }),
                   "Terminal profile popover is missing from the command-backed toolbar")
        try expect(expected.contains(where: { $0.action == .palette(.newManagedAgent) }),
                   "Agent provider popover is missing from the command-backed toolbar")
        try expect(Set(expected.map(\.title)).count == expected.count,
                   "two toolbar commands render the same title")
    }

    private static func checkFreePositionAndEdgeThreshold() throws {
        let screen = NSRect(x: -1_200, y: 80, width: 1_600, height: 900)
        let size = NSSize(width: 320, height: 60)
        let free = NSRect(x: -760, y: 410, width: size.width, height: size.height)
        let margin = FloatingToolbarGeometry.positionMargin
        let normalized = FloatingToolbarGeometry.normalizedFreePosition(free, screen: screen, margin: margin)
        let restored = FloatingToolbarGeometry.restoredFreeFrame(
            screen: screen, xFraction: normalized.x, yFraction: normalized.y, size: size, margin: margin)
        try expect(abs(restored.minX - free.minX) < 0.01 && abs(restored.minY - free.minY) < 0.01,
                   "free normalized x/y did not round-trip after relaunch")
        let far = FloatingToolbarGeometry.distanceToNearestEdge(free, screen: screen)
        try expect(far.distance > FloatingToolbarGeometry.edgeSnapThreshold,
                   "an interior toolbar position fell within the snap threshold")
        let nearLeft = NSRect(x: screen.minX + 20, y: 410, width: size.width, height: size.height)
        let near = FloatingToolbarGeometry.distanceToNearestEdge(nearLeft, screen: screen)
        try expect(near.edge == .left && near.distance == 20,
                   "a toolbar within 24 pt of the left edge was not selected for snapping")
        let snapped = FloatingToolbarGeometry.snappedFrame(nearLeft, screen: screen, edge: near.edge, size: size, margin: margin)
        try expect(abs(snapped.minX - screen.minX - margin) < 0.01,
                   "near-edge release did not snap to the edge margin")
        let corner = NSRect(x: screen.minX + 18, y: screen.maxY - size.height - 18, width: size.width, height: size.height)
        try expect(FloatingToolbarEdge.nearest(to: corner, within: screen, preferredEdge: .top) == .top
                   && FloatingToolbarEdge.nearest(to: corner, within: screen, preferredEdge: .left) == .left,
                   "an exact edge-distance tie did not keep the current edge as its preference")
    }

    private static func checkButtonVisibilityAndAgentChoices() throws {
        let suite = "array.floatingToolbar.check.visibility.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated visibility preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let definitions = CommandRegistry.definitions().filter { $0.floatingToolbarItem != nil }
        guard let first = definitions.first, let firstItem = first.floatingToolbarItem else {
            throw Failure(description: "the command registry has no toolbar items")
        }
        let key = FloatingToolbarConfig.itemVisibleKey(commandID: first.id.rawValue)
        let view = FloatingToolbarView(frame: NSRect(x: 0, y: 0, width: 640, height: 64))
        view.defaults = defaults
        view.rebuildButtons()
        let allCount = view.qaVisibleButtonCount
        defaults.set(false, forKey: key)
        view.rebuildButtons()
        try expect(view.qaVisibleButtonCount == allCount - 1 && !view.qaButtonTitles.contains(firstItem.title),
                   "the per-command visibility preference did not remove its toolbar button")
        let settings = FloatingToolbarSettingsView(defaults: defaults)
        try settings.qaActivateControl("ArrayFloatingToolbarSetting.\(key)")
        try expect(defaults.bool(forKey: key), "the per-command Settings choice did not persist its toggle")

        let choices = FloatingToolbarView.qaAgentChoices
        try expect(choices.map(\.0) == ["Claude Code", "Codex", "Pi", "Fan Out Selected Tickets…"],
                   "the Agent popover lost human provider labels or its fan-out action")
        try expect(choices.contains(where: { $0.1 == .agentHarness(.claudeCode) })
                   && choices.contains(where: { $0.1 == .agentHarness(.codex) })
                   && choices.contains(where: { $0.1 == .agentHarness(.pi) })
                   && choices.contains(where: { $0.1 == .fanOutQueueSelection }),
                   "Agent popover choices did not route to distinct providers and fan-out")
    }

    private static func checkChoicePopoversSurvivePointerTransitions() throws {
        let cases: [(String, String, (FloatingToolbarView) -> Bool)] = [
            ("Choose an agent action", "Agent", { $0.qaOpenAgentChoicesPopover() }),
            ("Choose a terminal profile", "Terminal", { $0.qaOpenTerminalProfilesPopover() }),
        ]
        var failures: [String] = []
        for (title, ownerButton, openChoices) in cases {
            do {
                let toolbar = FloatingToolbarView(frame: NSRect(x: 0, y: 0, width: 640, height: 64))
                let host = NSWindow(
                    contentRect: NSRect(x: 120, y: 120, width: 700, height: 100),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                host.isReleasedWhenClosed = false
                host.contentView = toolbar
                host.orderFrontRegardless()
                defer { host.close() }
                toolbar.terminalProfiles = { [FloatingToolbarProfile(id: "default", title: "Default")] }
                toolbar.layoutSubtreeIfNeeded()

                try expect(openChoices(toolbar), "\(title) did not open")
                try expect(toolbar.qaDispatchMouseExitButton(titled: ownerButton),
                           "could not dispatch the owning button's real mouseExited event")
                try expect(toolbar.qaChoicePopoverTitle == title,
                           "mouseExited from \(ownerButton) closed \(title)")
                try expect(toolbar.qaDispatchMouseEnteredButton(titled: "Zone"),
                           "could not dispatch mouseEntered to a different command")
                try expect(toolbar.qaChoicePopoverTitle == title && !toolbar.qaHoverPopoverIsShown,
                           "mouseEntered on another command replaced or covered \(title)")
            } catch {
                failures.append("\(title): \(error)")
            }
        }
        try expect(failures.isEmpty, failures.joined(separator: "; "))
    }

    private static func checkControllerDragEndAndPersistence() throws {
        let suite = "array.floatingToolbar.check.drag.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated drag preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = NSRect(x: -1_400, y: 80, width: 1_600, height: 1_200)
        var callbackPersistenceWitness: [Bool] = []
        let controller = FloatingToolbarController(
            defaults: defaults,
            terminalProfiles: { [] },
            onSelection: { _ in }
        )
        controller.onPositionChanged = {
            callbackPersistenceWitness.append(
                defaults.object(forKey: FloatingToolbarConfig.positionXKey) != nil
                    && defaults.object(forKey: FloatingToolbarConfig.positionYKey) != nil
            )
        }

        let noMove = NSRect(x: -900, y: 470, width: 320, height: 60)
        controller.qaEndDrag(startingAt: noMove.origin, frame: noMove, screen: screen)
        try expect(callbackPersistenceWitness.isEmpty && defaults.object(forKey: FloatingToolbarConfig.positionXKey) == nil,
                   "a click/no-motion end saved a position or advanced onboarding")

        let programmaticNearEdge = NSRect(x: screen.minX + 16, y: 500, width: 320, height: 60)
        controller.qaSetPanelFrame(programmaticNearEdge)
        try expect(controller.qaPanelFrame == programmaticNearEdge && callbackPersistenceWitness.isEmpty,
                   "a programmatic panel move triggered edge snapping or the drag callback")

        let free = NSRect(x: -720, y: 460, width: 320, height: 60)
        controller.qaEndDrag(startingAt: programmaticNearEdge.origin, frame: free, screen: screen)
        try expect(callbackPersistenceWitness == [true]
                   && defaults.object(forKey: FloatingToolbarConfig.positionXKey) != nil
                   && defaults.object(forKey: FloatingToolbarConfig.positionYKey) != nil
                   && defaults.string(forKey: FloatingToolbarConfig.positionEdgeKey) == FloatingToolbarEdge.top.rawValue,
                   "a real interior drag did not persist free x/y and last orientation before onboarding")
        let freeFrame = controller.qaPanelFrame ?? .zero
        let storedX = defaults.double(forKey: FloatingToolbarConfig.positionXKey)
        let storedY = defaults.double(forKey: FloatingToolbarConfig.positionYKey)
        let restoredFreeFrame = FloatingToolbarGeometry.restoredFreeFrame(
            screen: screen,
            xFraction: CGFloat(storedX),
            yFraction: CGFloat(storedY),
            size: freeFrame.size,
            margin: FloatingToolbarGeometry.positionMargin
        )
        try expect(abs(restoredFreeFrame.minX - freeFrame.minX) < 0.01
                   && abs(restoredFreeFrame.minY - freeFrame.minY) < 0.01
                   && FloatingToolbarGeometry.distanceToNearestEdge(restoredFreeFrame, screen: screen).distance > FloatingToolbarGeometry.edgeSnapThreshold,
                   "the controller's persisted free drag did not restore to the same unsnapped position")
        controller.qaEndDrag(startingAt: freeFrame.origin, frame: freeFrame, screen: screen)
        try expect(callbackPersistenceWitness == [true]
                   && defaults.double(forKey: FloatingToolbarConfig.positionXKey) == storedX
                   && defaults.double(forKey: FloatingToolbarConfig.positionYKey) == storedY,
                   "a no-motion drag end changed the saved position or repeated onboarding")

        let nearRight = NSRect(x: screen.maxX - 18 - 320, y: 600, width: 320, height: 60)
        controller.qaEndDrag(startingAt: freeFrame.origin, frame: nearRight, screen: screen)
        let snapped = controller.qaPanelFrame ?? .zero
        try expect(callbackPersistenceWitness == [true, true]
                   && defaults.string(forKey: FloatingToolbarConfig.positionEdgeKey) == FloatingToolbarEdge.right.rawValue
                   && abs(screen.maxX - snapped.maxX - FloatingToolbarGeometry.positionMargin) < 0.01
                   && snapped.height > snapped.width,
                   "a real near-edge drag did not snap, switch orientation, persist, and signal onboarding")
        controller.close()
    }

    private static func checkEdgeOrientationAndSnapping() throws {
        let screen = NSRect(x: 100, y: 200, width: 1_200, height: 800)
        let view = FloatingToolbarView(frame: NSRect(x: 0, y: 0, width: 640, height: 64))
        let cases: [(FloatingToolbarEdge, NSRect)] = [
            (.top, NSRect(x: 500, y: 950, width: 300, height: 60)),
            (.right, NSRect(x: 1_230, y: 500, width: 60, height: 300)),
            (.bottom, NSRect(x: 500, y: 190, width: 300, height: 60)),
            (.left, NSRect(x: 90, y: 500, width: 60, height: 300)),
        ]
        for (expected, frame) in cases {
            let actual = FloatingToolbarEdge.nearest(to: frame, within: screen)
            try expect(actual == expected, "nearest-edge snap chose \(actual) for \(expected) frame")
            let orientation = actual.orientation
            view.orientation = orientation
            try expect((expected == .top || expected == .bottom) == (orientation == .horizontal),
                       "toolbar orientation does not follow its snapped edge")
            try expect(view.qaOrientation == orientation,
                       "AppKit toolbar stack did not switch orientation at the \(expected) edge")
            let margin = FloatingToolbarGeometry.positionMargin
            let snapped = FloatingToolbarGeometry.snappedFrame(frame, screen: screen, edge: actual, size: frame.size, margin: margin)
            let edgeDistance: CGFloat
            switch expected {
            case .top: edgeDistance = abs(screen.maxY - snapped.maxY - margin)
            case .bottom: edgeDistance = abs(snapped.minY - screen.minY - margin)
            case .left: edgeDistance = abs(snapped.minX - screen.minX - margin)
            case .right: edgeDistance = abs(screen.maxX - snapped.maxX - margin)
            }
            try expect(edgeDistance < 0.01, "snap did not place the toolbar at the shared edge margin from the \(expected) edge")
            let stored = FloatingToolbarGeometry.normalizedPosition(snapped, screen: screen, edge: expected, margin: margin)
            let restored = FloatingToolbarGeometry.restoredFrame(screen: screen, edge: expected, along: stored, size: frame.size, margin: margin)
            try expect(abs(restored.midX - snapped.midX) < 0.01 && abs(restored.midY - snapped.midY) < 0.01,
                       "persisted edge fraction did not restore the toolbar to its snapped position")
        }
    }

    private static func checkControllerShowMakesVisiblePanel() throws {
        let suite = "array.floatingToolbar.check.show.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated show preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FloatingToolbarConfig.visibleKey)

        let host = NSWindow(
            contentRect: NSRect(x: 160, y: 180, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        host.isReleasedWhenClosed = false
        host.orderFrontRegardless()
        defer { host.close() }
        let controller = FloatingToolbarController(
            defaults: defaults,
            terminalProfiles: { [] },
            onSelection: { _ in }
        )
        defer { controller.close() }

        controller.show(near: host)
        try expect(controller.qaPanelIsVisible,
                   "controller.show(near:) did not order the native toolbar panel onscreen")
        try expect(controller.qaPanelHasTokenPaintedRoot,
                   "visible toolbar panel did not have its token-painted FloatingToolbarView root")
        try expect((controller.qaPanelWindowNumber ?? 0) > 0,
                   "visible toolbar panel did not receive an AppKit window number")
    }

    private static func checkSettingsWriteAndReset() throws {
        let suite = "array.floatingToolbar.check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated toolbar preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FloatingToolbarConfig.visibleKey)
        defaults.set("left", forKey: FloatingToolbarConfig.positionEdgeKey)
        defaults.set(0.62, forKey: FloatingToolbarConfig.positionAlongEdgeKey)
        let view = FloatingToolbarSettingsView(defaults: defaults)
        try view.qaActivateControl("ArrayFloatingToolbarSetting.\(FloatingToolbarConfig.visibleKey)")
        try expect(!defaults.bool(forKey: FloatingToolbarConfig.visibleKey),
                   "the Show Floating Toolbar control did not persist its toggle")
        try view.qaActivateControl("ArrayFloatingToolbarResetPosition")
        try expect(defaults.object(forKey: FloatingToolbarConfig.positionEdgeKey) == nil
                   && defaults.object(forKey: FloatingToolbarConfig.positionAlongEdgeKey) == nil
                   && defaults.object(forKey: FloatingToolbarConfig.positionXKey) == nil
                   && defaults.object(forKey: FloatingToolbarConfig.positionYKey) == nil,
                   "Reset Position did not clear the globally persisted edge and offset")
    }
}
