import AppKit
import ContinuumRevivedCore

/// Every Share entry point ends here: the agent header's Share, the sidebar
/// row's Share, the Share tool's release and the palette. One popover at a
/// time, anchored to what is being shared; one session per set of tiles, so
/// reopening shows the same link.
@MainActor
final class ShareEntryCoordinator {
    private let links: () -> ShareLinkServing
    private let zones: () -> SharedZoneCreating
    private let pasteboard: NSPasteboard
    private var sessions: [Set<SharedAreaPublication.SourceKey>: ShareLinkSession] = [:]
    private let popover = ChoicePopoverController()
    private(set) weak var presentedView: ShareLinkPopoverView?
    /// The view the popover hangs from: the shared tile itself.
    private(set) weak var qaAnchorView: NSView?
    /// Who has access, each time the open popover reads it: (area, names).
    var onAccessRefreshed: ((UUID, [String]) -> Void)?
    /// The popover closed: the Share tool's rings clear here.
    var onClose: (() -> Void)?

    init(links: @escaping () -> ShareLinkServing, zones: @escaping () -> SharedZoneCreating, pasteboard: NSPasteboard = .general) {
        self.links = links; self.zones = zones; self.pasteboard = pasteboard
    }

    /// Checks only: the popover and its lifetime list open beside an
    /// off-display fixture window, never on the user's screen.
    var presentsOffscreenForQA = false
    var isPresented: Bool { popover.isPresented }
    var qaPanel: NSPanel? { popover.panel }
    /// Why the popover last closed itself, for a check that finds it closed.
    var qaLastSelfDismissal: String? { popover.qaLastSelfDismissal }

    /// How often an open popover re-reads who has access.
    static let accessRefreshInterval: Duration = .seconds(2)
    private var accessRefresh: Task<Void, Never>?

    func present(_ target: ShareTarget, anchor: NSRect, in view: NSView) {
        // Tiles already lent to an area open that area's session: the one that
        // shared them, holding its link, or after a relaunch a fresh one.
        let session = target.area.flatMap { area in sessions.values.first { $0.area == area } }
            ?? sessions[target.keys]
            ?? ShareLinkSession(target: target, links: links(), zones: zones(), pasteboard: pasteboard)
        if target.area == nil { sessions[target.keys] = session }
        let content = ShareLinkPopoverView(session: session)
        content.lifetimeChoice.presentsOffscreenForQA = presentsOffscreenForQA
        content.onResize = { [weak self] size in self?.popover.resizeContent(to: size) }
        content.onDismiss = { [weak self] in self?.popover.dismiss() }
        popover.presentContent(content, size: content.preferredSize, anchor: anchor, relativeTo: view,
                               placementFrame: Self.placementFrame(for: view) ?? (presentsOffscreenForQA ? view.window?.frame : nil),
                               takesFocus: !presentsOffscreenForQA,
                               accessibilityLabel: target.origin == .agent ? "Share this agent" : "Share area",
                               onClose: { [weak self] in
                                   self?.accessRefresh?.cancel(); self?.accessRefresh = nil
                                   self?.onClose?()
                               })
        presentedView = content
        qaAnchorView = view
        // Live: someone joining shows while the popover is open.
        accessRefresh?.cancel()
        accessRefresh = Task { [weak self, weak session] in
            while !Task.isCancelled, let session {
                await session.refreshAccess()
                if let area = session.area { self?.onAccessRefreshed?(area, session.people.map(\.label)) }
                try? await Task.sleep(for: Self.accessRefreshInterval)
                guard self?.isPresented == true else { return }
            }
        }
    }

    func dismiss() { popover.dismiss() }

    /// The visible canvas on screen: the popover slides and flips inside it, so
    /// it never sits over the sidebar or off the canvas, however far off the
    /// edge the tile it shares is.
    static func placementFrame(for view: NSView) -> NSRect? {
        var ancestor: NSView? = view
        while let current = ancestor, !(current is CanvasNSView) { ancestor = current.superview }
        guard let canvas = ancestor, let window = canvas.window else { return nil }
        return window.convertToScreen(canvas.convert(canvas.visibleRect, to: nil))
    }
}
