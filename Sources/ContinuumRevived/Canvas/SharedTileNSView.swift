import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Someone else's note, file, diff, browser or terminal on this canvas
/// (`.plans/105-collaboration/SHARE-KINDS.md`): the same contract as a shared
/// agent tile. An ordinary tile in this person's zone; moving, resizing or
/// closing it never reaches the owner's canvas. Its body is a
/// `LiveTileBodyView`; under it a footer says when the owner's Mac is offline
/// or sharing stopped. An install that cannot open it shows a placeholder.
@MainActor
final class SharedTileNSView: TileNSView {
    let reference: SharedAgentTileReference?
    let liveKind: Collaboration.LiveTile.Kind?
    private(set) var state: SharedAgentTileNSView.State = .connecting
    let body: LiveTileBodyView?
    private let container = SharedTileContainer()
    var session: SharedTileSession?
    var attaching = false
    var onWindowChange: ((SharedTileNSView, Bool) -> Void)?

    override init(tile: Tile) {
        reference = tile.metadata.sharedTile
        liveKind = reference?.liveKind.flatMap(Collaboration.LiveTile.Kind.init(rawValue:))
        body = liveKind.map { LiveTileBodyView(kind: $0, hostName: tile.metadata.sharedTile?.hostName ?? "Someone") }
        super.init(tile: tile)
        container.install(body)
        setContentView(container)
        let host = reference?.hostName ?? "Someone"
        apply(.placeholder(liveKind == nil ? "Shared by \(host) · this version of Array can't show it"
                                           : "Shared by \(host) · sign in to see it"), hostName: host, colour: .systemOrange)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hostName: String { reference?.hostName ?? "Someone" }
    var qaFooterText: String { container.footerText }
    var qaPlaceholderText: String? { container.placeholderText }

    /// "Dylan's browser", "Dylan's note": what the tab calls it.
    var ownedNoun: String { liveKind == .terminal ? "Terminal" : liveKind.map(LiveTileBodyView.noun) ?? "tile" }

    func apply(_ next: SharedAgentTileNSView.State, hostName: String, colour: NSColor) {
        state = next
        let mark: OwnershipMark
        switch next {
        case .placeholder:
            mark = .init(text: "\(hostName)'s \(ownedNoun) · on \(hostName)'s Mac", colour: colour, outlined: true, dashed: true)
        case .connecting, .live:
            mark = .init(text: "\(hostName)'s \(ownedNoun) · on \(hostName)'s Mac", colour: colour, outlined: true)
        case .offline:
            mark = .init(text: "\(hostName)'s \(ownedNoun) · offline", colour: colour, outlined: true, dashed: true)
        case .stopped:
            mark = .init(text: "\(hostName)'s \(ownedNoun) · no longer shared", colour: colour, outlined: true, dashed: true)
        }
        setOwnershipMark(mark)
        body?.hostName = hostName
        container.apply(next, hostName: hostName, noun: ownedNoun)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(self, window != nil)
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        if let body, body.qaEditable { window?.makeFirstResponder(body.qaTextView) } else { window?.makeFirstResponder(self) }
        return true
    }
}

/// The body, a footer when offline or stopped, or a placeholder instead of both.
@MainActor
final class SharedTileContainer: NSView {
    private var body: LiveTileBodyView?
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let footerLine = NSTextField(labelWithString: "")
    private let footerDetail = NSTextField(wrappingLabelWithString: "")
    private var showsFooter = false
    override var isFlipped: Bool { true }

    var footerText: String { showsFooter ? footerLine.stringValue + " · " + footerDetail.stringValue : "" }
    var placeholderText: String? { placeholder.isHidden ? nil : placeholder.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placeholder.font = .token(.body); placeholder.alignment = .center
        footerLine.font = .token(.label); footerLine.lineBreakMode = .byTruncatingTail
        footerDetail.font = .token(.caption); footerDetail.maximumNumberOfLines = 2
        for view in [placeholder, footerLine, footerDetail] { addSubview(view) }
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func install(_ body: LiveTileBodyView?) {
        self.body = body
        if let body { addSubview(body, positioned: .below, relativeTo: nil) }
    }

    func apply(_ state: SharedAgentTileNSView.State, hostName: String, noun: String) {
        var line = "", detail = "", placeholderValue: String?
        switch state {
        case .placeholder(let text): placeholderValue = text
        case .connecting, .live: break
        case .offline(let lastSeen):
            line = "\(hostName)'s Mac is offline"
            detail = "Showing the last update, \(lastSeen.map { SharedAreaPersonColour.ago($0) } ?? "earlier"). It comes back when \(hostName)'s Mac does."
        case .stopped(let text):
            line = text
            detail = "Nothing new arrives, and nothing you do is sent. What you already saw stays until you close this tile."
        }
        placeholder.stringValue = placeholderValue ?? ""
        placeholder.isHidden = placeholderValue == nil
        body?.isHidden = placeholderValue != nil
        showsFooter = !line.isEmpty
        footerLine.stringValue = line; footerDetail.stringValue = detail
        footerLine.isHidden = !showsFooter; footerDetail.isHidden = !showsFooter
        let dim: Bool = { if case .offline = state { return true }; if case .stopped = state { return true }; return false }()
        body?.alphaValue = dim ? 0.55 : 1
        body?.inputEnabled = { if case .stopped = state { return false }; if case .placeholder = state { return false }; return true }()
        needsLayout = true; needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let footer: CGFloat = showsFooter ? 54 : 0
        placeholder.frame = NSRect(x: inset, y: bounds.height / 2 - 24, width: max(0, bounds.width - 2 * inset), height: 48)
        body?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - footer))
        let top = bounds.height - footer
        footerLine.frame = NSRect(x: inset, y: top + 8, width: max(0, bounds.width - 2 * inset), height: 18)
        footerDetail.frame = NSRect(x: inset, y: top + 26, width: max(0, bounds.width - 2 * inset), height: 26)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        placeholder.textColor = TextToken.textSecondary.color.nsColor(in: self)
        footerLine.textColor = TextToken.textPrimary.color.nsColor(in: self)
        footerDetail.textColor = TextToken.textSecondary.color.nsColor(in: self)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        bounds.fill()
        guard showsFooter else { return }
        LineToken.separator.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: bounds.height - 54, width: bounds.width, height: 1).fill()
    }
}
