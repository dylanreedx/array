import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// Every kind a portal can hold. One line per kind: the portal lead owns the
/// `.agent` line; the per-kind helper replaces each `SharedPortalFallbackKind`
/// line with its own kind (`.plans/105-collaboration/PORTAL-CONTRACT.md`).
@MainActor
enum SharedPortalKinds {
    static func kind(for itemKind: SharedPortal.ItemKind) -> any SharedPortalKind {
        switch itemKind {
        case .agent: return SharedPortalAgentKind()
        case .note: return SharedPortalNoteKind()
        case .file: return SharedPortalCaptureKind(itemKind: .file)
        case .diff: return SharedPortalCaptureKind(itemKind: .diff)
        case .browser: return SharedPortalBrowserKind()
        case .terminal: return SharedPortalTerminalKind()
        case .board: return SharedPortalBoardKind()
        case .unknown: return SharedPortalFallbackKind(itemKind: .unknown)
        }
    }
    /// The kind a local tile shares as, or nil when it stays out of portals.
    static func kind(forTile kind: TileKind) -> (any SharedPortalKind)? {
        SharedPortal.ItemKind.forTile(kind).map { self.kind(for: $0) }
    }
}

/// Stands in for a kind until its real implementation lands, and for a kind
/// this build does not know. It publishes no content, so it can never leak
/// one, and draws a card naming the tile.
@MainActor
struct SharedPortalFallbackKind: SharedPortalKind {
    let itemKind: SharedPortal.ItemKind

    func shareRow(for tile: Tile) -> SharedPortalShareRow {
        itemKind == .terminal ? .init(included: true, badge: "Stays private") : .init(included: true, badge: "Title only")
    }
    func publishedTitle(for tile: Tile) -> String { itemKind == .terminal ? "Terminal" : tile.title }
    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft? { nil }
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)? { nil }
    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView {
        let host = guest.hostName
        let line = itemKind == .terminal ? "Terminal stays on \(host)'s Mac" : "\(host) shared this. It shows in a newer Array."
        return SharedPortalCardView(entry: entry, guest: guest, message: line)
    }
}

/// A titled card with one line of text: the fallback body, and the frame
/// kinds can reuse for their own placeholder states.
@MainActor
class SharedPortalCardView: SharedPortalItemView {
    private(set) var message: String
    init(entry: SharedPortal.Entry, guest: SharedPortalGuestContext, message: String) {
        self.message = message
        super.init(entry: entry, guest: guest)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("\(entry.title). \(message)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setMessage(_ text: String) {
        guard text != message else { return }
        message = text; setAccessibilityLabel("\(entry.title). \(text)"); needsDisplay = true
    }
    override var qaFacts: [String: String] { ["message": message, "editable": "false"] }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        SurfaceToken.tileBody.color.nsColor(in: self).setFill(); card.fill()
        LineToken.borderStrong.color.nsColor(in: self).setStroke(); card.lineWidth = 1; card.stroke()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.token(.label), .foregroundColor: TextToken.textPrimary.color.nsColor(in: self)]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.token(.body), .foregroundColor: TextToken.textSecondary.color.nsColor(in: self)]
        (entry.title as NSString).draw(in: NSRect(x: 16, y: 14, width: max(0, bounds.width - 32), height: 20), withAttributes: title)
        let size = (message as NSString).boundingRect(with: NSSize(width: max(0, bounds.width - 48), height: bounds.height),
                                                      options: [.usesLineFragmentOrigin], attributes: body).size
        (message as NSString).draw(with: NSRect(x: 24, y: bounds.midY - size.height / 2, width: max(0, bounds.width - 48), height: size.height + 2),
                                   options: [.usesLineFragmentOrigin], attributes: body)
    }
}
