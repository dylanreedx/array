import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--zone-cancel-menu-check`: the menu a new zone offers when its project
/// chooser is dismissed ("Keep Choosing" / "Cancel and Delete New Zone").
///
/// Drives the production `ProjectHomePickerController` through its real
/// dismissal path into a canvas that carries a real, installed floating
/// toolbar, then reads the presented panel back:
///  * every two-line row draws its title and subtitle in frames that do not
///    intersect, inside the row, and every row has the same height;
///  * the menu surface never intersects the toolbar's bar, on every edge the
///    bar can rest on, and stays inside the canvas viewport;
///  * the surface's border is at most 0.5pt and the window casts no
///    server-drawn shadow (whose rim is the "thick light border");
///  * the destructive row's title is painted in the failure accent.
@MainActor
enum ZoneCancelMenuChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    /// Where the zone's menu is anchored relative to the bar. A zone drawn
    /// right against the bar anchors just beside it; one whose corner lands
    /// under the bar anchors ON it — the case that put the menu over the bar.
    enum AnchorCase: String, CaseIterable { case beside, onBar }

    static func run() throws {
        for edge in FloatingToolbarEdge.allCases {
            for anchorCase in AnchorCase.allCases {
                try checkMenu(edge: edge, anchorCase: anchorCase)
            }
        }
    }

    private static func checkMenu(edge: FloatingToolbarEdge, anchorCase: AnchorCase) throws {
        let suite = "array.zoneCancelMenu.check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated toolbar preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(edge.rawValue, forKey: FloatingToolbarConfig.positionEdgeKey)

        let size = NSSize(width: 1100, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let pane = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = pane
        let canvas = NSView(frame: pane.bounds)
        canvas.autoresizingMask = [.width, .height]
        pane.addSubview(canvas)
        let host = FloatingToolbarHostView(
            defaults: defaults,
            terminalProfiles: { [FloatingToolbarProfile(id: "shell", title: "Shell")] },
            onSelection: { _ in })
        host.reduceMotion = { true }
        host.install(in: pane)
        window.orderFrontOffscreenForChecks()
        pane.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        let bar = host.toolbar
        try expect(!bar.isHidden && bar.frame.width > 0, "[\(edge)/\(anchorCase)] the toolbar fixture did not rest a visible bar")
        let barScreen = window.convertToScreen(bar.convert(bar.bounds, to: nil))

        // The worst case: the zone was drawn right against the bar, so the
        // menu's anchor sits just beside it, on the canvas side.
        let barInCanvas = canvas.convert(bar.bounds, from: bar)
        var anchor: NSPoint
        switch edge {
        case .bottom: anchor = NSPoint(x: barInCanvas.midX, y: barInCanvas.maxY + 2)
        case .top: anchor = NSPoint(x: barInCanvas.midX, y: barInCanvas.minY - 2)
        case .left: anchor = NSPoint(x: barInCanvas.maxX + 2, y: barInCanvas.midY)
        case .right: anchor = NSPoint(x: barInCanvas.minX - 2, y: barInCanvas.midY)
        }
        if anchorCase == .onBar { anchor = NSPoint(x: barInCanvas.midX, y: barInCanvas.midY) }

        let project = ProjectEntry(
            id: UUID(), name: "Fixture", rootPath: NSTemporaryDirectory(),
            workspaceId: nil, lastOpenedAt: Date(), pinned: false)
        let picker = ProjectHomePickerController()
        defer { picker.dismiss(cancelled: false) }
        picker.present(
            projects: [project],
            anchor: anchor,
            relativeTo: canvas,
            confirmsDestructiveCancellation: true,
            onConfirm: { _ in },
            onCancel: {})
        picker.qaRequestDismissal()

        let popover = picker.qaPopover
        guard let list = popover.listView, let panel = popover.panel,
              let surface = popover.surfaceFrame, let surfaceView = popover.surfaceView else {
            throw Failure(description: "[\(edge)/\(anchorCase)] the cancel confirmation did not present")
        }
        try expect(list.qaItems.map(\.id) == ["keep", "cancel"],
                   "[\(edge)/\(anchorCase)] expected the Keep Choosing / Cancel menu, got \(list.qaItems.map(\.id))")
        list.layoutSubtreeIfNeeded()

        // 1. Row anatomy.
        let heights = Set(list.subviews.filter { $0.accessibilityRole() == .row }.map(\.frame.height))
        try expect(heights.count == 1, "[\(edge)/\(anchorCase)] the menu mixes row heights \(heights.sorted())")
        let rowHeight = list.qaRenderedRowHeight
        for (item, frames) in zip(list.qaItems, list.qaRowTextFrames) {
            let rowBounds = NSRect(x: 0, y: 0, width: .greatestFiniteMagnitude, height: rowHeight)
            try expect(rowBounds.contains(frames.title),
                       "[\(edge)/\(anchorCase)] \"\(item.title)\" title \(frames.title) leaves its \(rowHeight)pt row")
            if let detail = frames.detail {
                try expect(!frames.title.intersects(detail),
                           "[\(edge)/\(anchorCase)] \"\(item.title)\" title \(frames.title) overlaps its subtitle \(detail)")
                try expect(rowBounds.contains(detail),
                           "[\(edge)/\(anchorCase)] \"\(item.title)\" subtitle \(detail) leaves its \(rowHeight)pt row")
            }
        }

        // 2. Placement: clear of the bar, inside the canvas.
        try expect(!surface.intersects(barScreen),
                   "[\(edge)/\(anchorCase)] the menu \(surface) covers the floating toolbar \(barScreen)")
        let canvasScreen = window.convertToScreen(canvas.convert(canvas.visibleRect, to: nil))
        try expect(canvasScreen.contains(surface),
                   "[\(edge)/\(anchorCase)] the menu \(surface) leaves the canvas viewport \(canvasScreen)")

        // 3. Border: one hairline, and no server shadow rim.
        try expect(!panel.hasShadow,
                   "[\(edge)/\(anchorCase)] the menu window casts a server shadow, whose rim draws a light border around it")
        let border = surfaceView.layer?.borderWidth ?? 0
        try expect(border > 0 && border <= 0.5, "[\(edge)/\(anchorCase)] the menu's border is \(border)pt, not a ≤0.5pt hairline")

        // 4. The destructive row speaks in the destructive colour.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            list.applyTokens()
            let theme: TokenTheme = appearance == .darkAqua ? .dark : .light
            let expected = AccentToken.accentFailed.color.nsColor(for: theme).usingColorSpace(.sRGB)
            let painted = list.qaRowTitleColors.first(where: { $0.id == "cancel" })?.color?.usingColorSpace(.sRGB)
            try expect(painted != nil && expected != nil && painted!.isApproximately(expected!),
                       "[\(edge)/\(anchorCase)] the destructive row's title is \(String(describing: painted)) in \(appearance.rawValue), not the failure accent")
            let keep = list.qaRowTitleColors.first(where: { $0.id == "keep" })?.color?.usingColorSpace(.sRGB)
            try expect(keep.map { !$0.isApproximately(expected!) } ?? false,
                       "[\(edge)/\(anchorCase)] Keep Choosing must not take the destructive colour")
        }
    }
}

private extension NSColor {
    func isApproximately(_ other: NSColor) -> Bool {
        abs(redComponent - other.redComponent) < 0.01
            && abs(greenComponent - other.greenComponent) < 0.01
            && abs(blueComponent - other.blueComponent) < 0.01
    }
}
