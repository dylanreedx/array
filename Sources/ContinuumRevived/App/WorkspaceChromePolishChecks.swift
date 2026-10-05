import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
enum WorkspaceChromePolishChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let bar = WorkspaceTopBarView(frame: NSRect(x: 0, y: 568, width: 900, height: 32))
        host.addSubview(bar)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 568))
        host.addSubview(sidebar)
        let message = "Deleted workspace “Untitled Workspace”. Projects and project tile data were not deleted."
        bar.setManagementMessage(message, kind: .success)
        sidebar.setManagementMessage(message)
        host.layoutSubtreeIfNeeded()
        try expect(!bar.managementMessageIsVisibleForQA && !sidebar.managementMessageIsVisibleForQA, "notification is duplicated in navigation chrome")
        try expect(!bar.notificationView.isHidden && bar.notificationView.message == message && bar.notificationView.kind == .success, "success notification missing or styled as a warning")
        let cardFrame = bar.notificationView.frame
        try expect(cardFrame.maxY < bar.frame.minY && cardFrame.width <= 440 && cardFrame.height > 35, "notification must wrap below the bar: \(cardFrame)")
        var dismissed = false
        bar.notificationView.onDismiss = { dismissed = true }
        bar.notificationView.dismiss()
        try expect(dismissed && bar.notificationView.isHidden, "dismissal does not retire the notification")
        bar.setManagementMessage("Couldn't save workspace: the disk is full.", kind: .error)
        try expect(bar.notificationView.kind == .error && !bar.notificationView.isHidden, "error did not replace the success")
        RunLoop.current.run(until: Date().addingTimeInterval(6.1))
        try expect(!bar.notificationView.isHidden, "error expired before dismissal")
        bar.setManagementMessage("Workspace saved.", kind: .success)
        RunLoop.current.run(until: Date().addingTimeInterval(6.1))
        try expect(bar.notificationView.isHidden, "success did not expire")
        bar.setManagementMessage("The workspace changed while the picker was open.", kind: .warning)
        RunLoop.current.run(until: Date().addingTimeInterval(6.1))
        try expect(!bar.notificationView.isHidden, "warning expired before dismissal")

        let header = AgentTileHeaderView(frame: NSRect(x: 0, y: 0, width: 700, height: 65))
        let headerWindow = NSWindow(contentRect: header.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        headerWindow.contentView = header
        headerWindow.orderFrontOffscreenForChecks()
        defer { headerWindow.orderOut(nil) }
        let badge = AgentSignalBadgeView()
        header.installStatusBadge(badge)
        try expect(badge.superview != nil, "status badge was detached while installing the header")
        header.apply(.init(name: "Agent", status: .idle, stateLabel: "Idle", stateAccessibilityLabel: "Idle", revealRequestID: nil, availableActionDescription: "", branch: .init(text: "⎇ array/integration · shared", tooltip: "Shared checkout", isWarning: false), startedAt: nil, elapsedSeconds: nil))
        badge.apply(.init(id: "polish", kind: .completed, agentID: nil, tileID: nil, threadID: nil, occurredAt: Date(), source: .managedRuntime))
        headerWindow.layoutIfNeeded()
        header.layoutSubtreeIfNeeded()
        let badgeFrame = badge.convert(badge.bounds, to: header)
        try expect(!badgeFrame.intersects(header.qaBranchFrame), "completion badge overlaps branch: \(badgeFrame) / \(header.qaBranchFrame)")
        try expect(badgeFrame.width + 0.5 >= badge.intrinsicContentSize.width, "completion text is clipped: \(badgeFrame) / \(badge.intrinsicContentSize), header \(header.frame), branch \(header.qaBranchFrame)")
        func scale(_ view: NSView, _ zoom: AgentPageZoom) {
            (view as? AgentPageZoomScalable)?.applyPageZoom(zoom)
            view.subviews.forEach { scale($0, zoom) }
        }
        header.apply(.init(name: "Investigate workspace notifications and agent tile chrome", status: .working, stateLabel: "Working", stateAccessibilityLabel: "Working", revealRequestID: nil, availableActionDescription: "", branch: .init(text: "⎇ agent/investigate-notifications-and-header-layout-with-a-long-branch-name · shared", tooltip: "Shared checkout", isWarning: false), startedAt: Date().addingTimeInterval(-900), elapsedSeconds: 900))
        for width in [320, 360, 560, 700, 1200] {
            for percent in AgentPageZoom.steps {
                let zoom = AgentPageZoom(percent: percent)
                scale(header, zoom)
                headerWindow.setContentSize(NSSize(width: CGFloat(width), height: AgentTileHeaderView.preferredHeight(zoom: zoom)))
                for kind in AgentSignalKind.allCases {
                    badge.apply(.init(id: "polish", kind: kind, agentID: nil, tileID: nil, threadID: nil, occurredAt: Date(), source: .managedRuntime))
                    headerWindow.layoutIfNeeded()
                    header.layoutSubtreeIfNeeded()
                    let status = badge.convert(badge.bounds, to: header)
                    let branch = header.qaBranchFrame
                    try expect(!status.intersects(branch), "branch/status overlap at \(width) @\(percent)%")
                    try expect(status.minX >= 0 && status.maxX <= CGFloat(width) + 1 && branch.minX >= 0 && branch.maxX <= CGFloat(width) + 1, "branch/status exceeds header at \(width) @\(percent)%: \(status), \(branch)")
                    try expect(status.width + 0.5 >= badge.intrinsicContentSize.width, "status text clipped at \(width) @\(percent)%: \(status.width) / \(badge.intrinsicContentSize.width)")
                    try expect(badge.qaTextFits, "status label clips inside its badge at \(width) @\(percent)%")
                }
            }
        }
        scale(header, .default)
        headerWindow.setContentSize(NSSize(width: 700, height: AgentTileHeaderView.preferredHeight))
        header.layoutSubtreeIfNeeded()

        let tile = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Agent", frame: TileFrame(x: 0, y: 0, width: 700, height: 600), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        func visibleMenus(_ view: NSView) -> Int {
            if view.isHidden { return 0 }
            let own = (view as? NSControl).map { ["Agent actions", "Location actions"].contains($0.accessibilityLabel() ?? "") ? 1 : 0 } ?? 0
            return own + view.subviews.reduce(0) { $0 + visibleMenus($1) }
        }
        try expect(visibleMenus(tile) == 1, "agent tile must show exactly one action menu, found \(visibleMenus(tile))")
        var stopped = false
        var detached = false
        tile.onStopRun = { stopped = true }
        tile.onClose = { detached = true }
        let actions = tile.titleBarContextMenuForQA()
        for title in [AgentTileHeaderView.stopActionTitle, AgentTileHeaderView.detachActionTitle] {
            guard let item = actions.items.first(where: { $0.title == title }), let action = item.action else { throw Failure(description: "missing \(title)") }
            try expect(NSApp.sendAction(action, to: item.target, from: item), "menu action did not dispatch: \(title)")
        }
        try expect(stopped && detached, "top-bar stop/detach do not reach the tile callbacks")
        let footer = AgentComposerFooterView()
        try expect(footer.harnessButton.items.allSatisfy { $0.icon?.image() != nil }, "harness options must all have icons")
        let choices = ChoiceListView(items: footer.harnessButton.items, selectedID: footer.harnessButton.selectedID)
        try expect(choices.qaVisibleIconIDs == Set(footer.harnessButton.items.map(\.id)), "harness option icons are not rendered")
        try expect(ProviderModelGrouping.groups(from: footer.modelButton.items).flatMap(\.models).allSatisfy { $0.icon?.image() != nil }, "model picker projection lost provider icons")
        try expect(footer.harnessButton.selectedIcon?.image() != nil && footer.modelButton.selectedIcon?.image() != nil, "closed harness/model selectors need icons")
        let artifact = URL(fileURLWithPath: "qa-runs/chrome-polish", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        func capture(_ view: NSView, name: String) throws {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) { try data.write(to: artifact.appendingPathComponent(name)) }
        }
        let previewWindow = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.contentView = host
        previewWindow.orderFrontOffscreenForChecks()
        defer { previewWindow.orderOut(nil) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            host.appearance = NSAppearance(named: appearance)
            header.appearance = host.appearance
            host.wantsLayer = true
            header.wantsLayer = true
            host.layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(in: host)
            header.layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(in: header)
            host.layoutSubtreeIfNeeded()
            header.layoutSubtreeIfNeeded()
            try capture(host, name: "notification-\(name).png")
            try capture(header, name: "agent-header-\(name).png")
        }
        let placement = ZonePlacement(zoneId: UUID(), projectId: UUID(), origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 700, height: 180), color: "blue", collapsed: false, hydrationPolicy: .automatic, name: "Array")
        let zone = ZoneChromeNSView(placement: placement, presentation: .init(title: "Array", homeLabel: "Array / Project Root", isProvisional: false, agentStatusRollup: .empty, qaVerdict: nil))
        zone.frame = NSRect(x: 0, y: 0, width: 700, height: 180)
        previewWindow.contentView = zone
        previewWindow.layoutIfNeeded()
        try expect(zone.renderHeaderTextOffscreen() == ["Array", "Array / Project Root"], "zone header lost its Home or retained the redundant arrow")
        try capture(zone, name: "zone-home.png")
        footer.frame = NSRect(x: 0, y: 0, width: 700, height: 70)
        previewWindow.contentView = footer
        previewWindow.layoutIfNeeded()
        footer.layoutSubtreeIfNeeded()
        try capture(footer, name: "provider-selectors.png")
        print("Workspace chrome polish: single dismissible typed notification, non-overlapping branch/status, one agent menu, provider icons passed")
    }
}
