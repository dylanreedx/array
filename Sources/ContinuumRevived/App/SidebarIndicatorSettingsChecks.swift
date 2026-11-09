import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// Real Settings choice -> isolated defaults -> setting event -> existing sidebar card.
@MainActor
enum SidebarIndicatorSettingsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    private static func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
    }
    private static func click(_ view: NSView) throws {
        guard let window = view.window else { throw Failure(description: "click target has no window") }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw Failure(description: "could not make mouse event")
            }
            return event
        }
        // Queue release before the down enters any AppKit tracking loop.
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        NSApp.sendEvent(try event(.leftMouseDown))
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(release)
        }
    }

    static func run() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suite = "array.sidebar-indicator-check.\(UUID().uuidString)"
            let defaults = QAIsolatedDefaults(isolatedSuiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            // Existing dev experiments cannot change the shipping default.
            defaults.set("current", forKey: "SidebarActiveIndicatorStyle")
            try expect(SidebarActiveIndicatorStyle.resolve(in: defaults) == .duplex, "missing preference must default to Duplex")
            defaults.set("invalid", forKey: SidebarActiveIndicatorStyle.defaultsKey)
            try expect(SidebarActiveIndicatorStyle.resolve(in: defaults) == .duplex, "invalid preference must fall back to Duplex")
            defaults.removeObject(forKey: SidebarActiveIndicatorStyle.defaultsKey)
            let model = SettingsModel(defaults: defaults, navKeymap: .resolve(defaults: defaults, warn: { _ in }), initialPaneID: "appearance")
            let fixture = SettingsFixtureWindow(model: model, size: NSSize(width: 1100, height: 1100), appearance: NSAppearance(named: appearance))
            defer { fixture.tearDown() }
            fixture.show(paneID: "appearance")
            if let entry = model.entries().first(where: { $0.field?.key == SidebarActiveIndicatorStyle.defaultsKey }) {
                model.reveal(entry)
                fixture.settle()
            }
            func control() throws -> ChoiceButton {
                guard let button = fixture.descendants(ChoiceButton.self).first(where: { $0.accessibilityLabel() == "Active agent" }) else {
                    throw Failure(description: "Appearance is missing the real Active agent ChoiceButton")
                }
                button.presentsOffscreenForQA = true
                return button
            }
            let initialButton = try control()
            try expect(initialButton.selectedID == "duplex", "Settings must show Duplex by default")
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 360, height: 1000), indicatorDefaults: defaults)
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            let id = UUID()
            inbox.openAgentId = id
            let lead = AgentInboxRow(id: id, title: "Active indicator witness", state: .working, createdAt: Date(), identityColor: "teal")
            let helpers = (0..<24).map { index in
                AgentInboxRow(id: UUID(), title: "Helper \(index)", state: .working,
                              depth: 1, createdAt: Date(), parentId: id)
            }
            inbox.reload(rows: [lead] + helpers)
            inbox.layoutForQA()
            inbox.rebuildRowsForQA()
            fixture.settle()
            guard let card = descendants(inbox, AgentInboxCardView.self).first(where: { $0.isRouteActive }) else {
                throw Failure(description: "sidebar did not render its real active card")
            }
            guard let tail = descendants(inbox, AgentInboxRemainderView.self).first else {
                throw Failure(description: "sidebar did not render the real N-more-helpers tail")
            }
            try expect(!tail.isSweepingForQA, "default Duplex left a Classic border slice on the helper tail")
            let builds = inbox.cellBuildCountForQA
            var renders: [Data] = []
            // Deliberately visit Gradient before Sheen: stale colour-stop counts
            // from a three-stop wash must not survive in a two-colour surface.
            for style in [SidebarActiveIndicatorStyle.classic, .gradient, .sheen, .duplex] {
                let button = try control()
                // Bring the label/help and control into the Form's viewport.
                button.scrollToVisible(button.bounds.insetBy(dx: 0, dy: -80))
                fixture.settle(0.2)
                try click(button)
                fixture.settle()
                guard let list = button.qaPresentedList, let row = list.rowView(id: style.rawValue) else {
                    throw Failure(description: "real choice popover did not offer \(style.title); presented=\(button.qaIsPopoverPresented), items=\(button.items.map(\.id))")
                }
                // Production choice panels take key focus. Keep that input state
                // while the QA placement remains outside every display.
                button.qaPresentedPanel?.makeKey()
                try click(row)
                fixture.settle()
                inbox.layoutForQA()
                try expect(!button.qaIsPopoverPresented, "choosing a style must close the popover")
                let fresh = QAIsolatedDefaults(isolatedSuiteName: suite)!
                try expect(SidebarActiveIndicatorStyle.resolve(in: fresh) == style, "\(style.title) did not persist across a fresh read")
                let updatedButton = try control()
                try expect(updatedButton.selectedID == style.rawValue, "Settings did not render its new choice")
                try expect(inbox.cellBuildCountForQA == builds, "changing the look rebuilt sidebar cells")
                try expect(card.isRouteActive && card.window === window, "style switch lost the active card")
                let layers = card.qaIndicatorLayers
                let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                try expect(tail.isSweepingForQA == (style == .classic && !reduced),
                           "the helper tail did not follow the live style's border policy")
                guard let shared = descendants(card.superview ?? card, InboxExpandedGroupLight.self).first else {
                    throw Failure(description: "expanded card has no shared light renderer")
                }
                let painted = shared.renderedLayersForChecks
                let gradients = painted.compactMap { $0 as? CAGradientLayer }
                try expect(shared.isHidden == (style == .classic), "shared group light visibility did not follow Settings")
                try expect(layers.wash.isHidden && layers.wash.animationKeys() == nil && layers.sheen.animationKeys() == nil,
                           "expanded group retained duplicate row-local light or motion")
                switch style {
                case .classic: break
                case .duplex:
                    try expect(gradients.filter { $0.type == .radial }.count == 2, "Duplex must paint two shared light fields")
                    try expect(gradients.contains { $0.animation(forKey: "group.focus") != nil } == !reduced, "shared Duplex breath policy wrong")
                case .gradient:
                    try expect(gradients.contains { $0.colors?.count == 3 && $0.mask is CAGradientLayer }, "Gradient lost its shared cascading wash")
                    try expect(gradients.contains { $0.animation(forKey: "group.orbit.startPoint")?.duration == 60 } == !reduced, "shared Gradient loop policy wrong")
                case .sheen:
                    try expect(painted.contains { $0 is CAShapeLayer }, "Sheen lost the even satin rim")
                    try expect(painted.contains { $0.animation(forKey: "group.sheen") != nil } == !reduced, "shared Sheen sweep policy wrong")
                }
                guard let rep = SettingsFixtureWindow.capture(card.superview ?? card), let png = rep.representation(using: .png, properties: [:]) else {
                    throw Failure(description: "active row could not render")
                }
                renders.append(png)
                shared.reducesMotionForChecks = true
                try expect(shared.renderedLayersForChecks.allSatisfy { $0.animationKeys() == nil }, "shared Reduce Motion retained an animation")
                shared.reducesMotionForChecks = false
                card.indicatorReducesMotion = true
                try expect(layers.wash.animationKeys() == nil && layers.sheen.animationKeys() == nil,
                           "Reduce Motion retained an alternative animation")
                card.indicatorReducesMotion = false
            }
            try expect(Set(renders).count == 4, "the four choices did not produce four rendered surfaces")
            inbox.openAgentId = nil
            inbox.layoutForQA()
            fixture.settle()
            try expect(descendants(inbox, InboxExpandedGroupLight.self).allSatisfy { $0.isHidden },
                       "closing the active agent retained its shared group light")
            inbox.openAgentId = id
            inbox.layoutForQA()
            fixture.settle()
            try expect(descendants(inbox, InboxExpandedGroupLight.self).contains { !$0.isHidden },
                       "reopening the active agent did not restore its shared group light")
            let finished = helpers.map { helper in
                AgentInboxRow(id: helper.id, title: helper.displayTitle, state: .ready, depth: 1, createdAt: Date(), parentId: id)
            }
            inbox.reload(rows: [lead] + finished)
            inbox.layoutForQA()
            fixture.settle()
            guard let resting = descendants(inbox, InboxExpandedGroupLight.self).first(where: { !$0.isHidden }),
                  let light = resting.renderedLayersForChecks.compactMap({ $0 as? CAGradientLayer }).last else {
                throw Failure(description: "finishing helpers lost the shared Duplex field")
            }
            try expect(light.startPoint.y < 0.5, "Duplex did not return focus to the lead when helpers finished")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try expect((light.animation(forKey: "group.settle.startPoint")?.duration ?? 0) > 0
                    || inbox.ownershipSliceForQA(id: id)?.focusChangedAt.map { CACurrentMediaTime() - $0 >= 0.6 } == true, "Duplex focus relocation did not ease on the render server")
            }
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("qa-runs/sidebar-indicator-settings")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if let snapshot = fixture.snapshot()?.representation(using: .png, properties: [:]) {
                try snapshot.write(to: output.appendingPathComponent(appearance == .aqua ? "settings-light.png" : "settings-dark.png"))
            }
            print("  \(appearance.rawValue): real Settings mouse events changed all four rendered styles in place; fresh-suite reads persisted each choice")
        }
    }
}

/// Immutable input for existing witnesses that specifically exercise Classic's
/// sweep/shimmer/fade. No preference writes and no fallback to an app domain.
final class ClassicSidebarDefaultsForChecks: UserDefaults, @unchecked Sendable {
    static func make() -> ClassicSidebarDefaultsForChecks {
        ClassicSidebarDefaultsForChecks(suiteName: "array.sidebar.classic-check.\(UUID().uuidString)")!
    }
    override func object(forKey key: String) -> Any? {
        key == SidebarActiveIndicatorStyle.defaultsKey ? SidebarActiveIndicatorStyle.classic.rawValue : nil
    }
}
