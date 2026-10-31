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

    func present(_ target: ShareTarget, anchor: NSRect, in view: NSView) {
        let session = sessions[target.keys] ?? ShareLinkSession(target: target, links: links(), zones: zones(), pasteboard: pasteboard)
        sessions[target.keys] = session
        let content = ShareLinkPopoverView(session: session)
        content.lifetimeChoice.presentsOffscreenForQA = presentsOffscreenForQA
        content.onResize = { [weak self] size in self?.popover.resizeContent(to: size) }
        content.onDismiss = { [weak self] in self?.popover.dismiss() }
        popover.presentContent(content, size: content.preferredSize, anchor: anchor, relativeTo: view,
                               placementFrame: presentsOffscreenForQA ? view.window?.frame : nil,
                               takesFocus: !presentsOffscreenForQA,
                               accessibilityLabel: target.origin == .agent ? "Share this agent" : "Share area",
                               onClose: { [weak self] in self?.onClose?() })
        presentedView = content
        Task { await session.refreshAccess() }
    }

    func dismiss() { popover.dismiss() }
}
