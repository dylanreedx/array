import AppKit
import ContinuumRevivedAgentUI

@MainActor
private final class ChoicePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the anchored panel and all dismissal observers. Closures capture the
/// controller weakly so presenting a choice never extends a tile's lifetime.
@MainActor
final class ChoicePopoverController {
    private(set) var panel: NSPanel?
    private(set) var listView: ChoiceListView?

    private weak var anchorView: NSView?
    private weak var parentWindow: NSWindow?
    private var anchorWasPostingFrameChanges: Bool?
    // AppKit monitor/observer tokens are main-thread resources but are not marked
    // Sendable. `nonisolated(unsafe)` lets nonisolated deinit remove them; every
    // read/write elsewhere remains confined to this @MainActor type.
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var anchorWindowObservation: NSKeyValueObservation?

    var isPresented: Bool { panel?.isVisible == true }

    deinit {
        // This controller is created, retained, and released only by MainActor
        // views. Swift deinitializers are nonisolated, so state the invariant while
        // synchronously restoring the anchor and detaching any visible child panel.
        MainActor.assumeIsolated { dismiss() }
    }

    func present(
        items: [ChoiceItem],
        selectedID: String?,
        anchor: NSRect,
        relativeTo view: NSView,
        onSelection: @escaping (ChoiceItem) -> Void
    ) {
        dismiss()
        guard !items.isEmpty, let window = view.window else { return }

        let list = ChoiceListView(items: items, selectedID: selectedID)
        let contentSize = list.intrinsicContentSize
        let panel = ChoicePanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.contentView = list
        panel.setFrame(Self.panelFrame(
            contentSize: contentSize,
            anchor: anchor,
            relativeTo: view,
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        ), display: false)

        self.panel = panel
        listView = list
        anchorView = view
        parentWindow = window
        anchorWasPostingFrameChanges = view.postsFrameChangedNotifications

        list.onSelection = { [weak self] item in
            self?.dismiss()
            onSelection(item)
        }
        list.onDismiss = { [weak self] in self?.dismiss() }

        window.addChildWindow(panel, ordered: .above)
        installDismissalObservers(for: window, anchor: view)
        panel.orderFront(nil)
        panel.makeKey()
        panel.makeFirstResponder(list)
    }

    func dismiss() {
        removeDismissalObservers()
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        listView = nil
        anchorView = nil
        parentWindow = nil
    }

    /// Places below when it fits, otherwise above, then clamps both axes to the
    /// screen's visible frame. Inputs and output are screen coordinates.
    static func panelFrame(
        contentSize: NSSize,
        anchor: NSRect,
        relativeTo view: NSView,
        visibleFrame: NSRect
    ) -> NSRect {
        guard let window = view.window else { return NSRect(origin: .zero, size: contentSize) }
        let windowAnchor = view.convert(anchor, to: nil)
        let screenAnchor = window.convertToScreen(windowAnchor)
        let gap = CGFloat(Space.s)
        let roomBelow = screenAnchor.minY - visibleFrame.minY
        let roomAbove = visibleFrame.maxY - screenAnchor.maxY
        let placeBelow = roomBelow >= contentSize.height + gap || roomBelow >= roomAbove
        var origin = NSPoint(
            x: screenAnchor.minX,
            y: placeBelow ? screenAnchor.minY - contentSize.height - gap : screenAnchor.maxY + gap
        )
        origin.x = min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - contentSize.width))
        origin.y = min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - contentSize.height))
        return NSRect(origin: origin, size: contentSize)
    }

    private func installDismissalObservers(for window: NSWindow, anchor: NSView) {
        let center = NotificationCenter.default
        if let panel {
            // The panel becomes key when presented, so observing the parent window
            // would consume that expected transition and miss the later real
            // resignation. Dismiss when the interactive panel itself loses key.
            observers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: anchor, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        anchor.postsFrameChangedNotifications = true
        anchorWindowObservation = anchor.observe(\.window, options: [.old, .new]) { [weak self] _, change in
            // `window` is optional, so KVO wraps both values in a second Optional.
            let oldWindow = change.oldValue ?? nil
            let newWindow = change.newValue ?? nil
            guard oldWindow != nil, newWindow == nil else { return }
            // NSView window changes are AppKit-main-thread events.
            MainActor.assumeIsolated { self?.dismiss() }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.dismiss() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    private func removeDismissalObservers() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        anchorWindowObservation?.invalidate()
        anchorWindowObservation = nil
        if let anchorWasPostingFrameChanges {
            anchorView?.postsFrameChangedNotifications = anchorWasPostingFrameChanges
        }
        anchorWasPostingFrameChanges = nil
    }
}
