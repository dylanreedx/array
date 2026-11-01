import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Someone else's agent on this canvas (`.plans/105-collaboration/SHARE-REDESIGN.md`,
/// mode A). An ordinary tile in this person's own zone: they move, resize and
/// close it like any other, and none of that reaches the owner's canvas. The
/// agent runs on its owner's Mac; this tile reads its projection and sends
/// prompts as `AgentPromptRequest`s. It is never a `.managedAgent` and never has
/// an `AgentRecord`.
///
/// Its body says one of four things:
/// - live: the owner's transcript, with the composer below it;
/// - offline: the same, dimmed, with "Dylan's Mac is offline"; prompts wait;
/// - stopped: "Dylan stopped sharing"; nothing new arrives and prompts are refused;
/// - placeholder: this install cannot open it (no account, or another one).
@MainActor
final class SharedAgentTileNSView: TileNSView {
    enum State: Equatable {
        case placeholder(String)
        case connecting
        case live
        case offline(lastSeen: Date?)
        case stopped(String)
    }

    let reference: SharedAgentTileReference?
    private(set) var state: State = .connecting
    private let body = SharedAgentTileBody()
    /// The session that feeds this tile; set by `AppDelegate.attachSharedAgentTile`.
    var session: SharedAgentTileSession?
    /// The tile left the window (unhydrated, workspace switch) or came back.
    var onWindowChange: ((SharedAgentTileNSView, Bool) -> Void)?

    override init(tile: Tile) {
        reference = tile.metadata.sharedAgent
        super.init(tile: tile)
        setContentView(body)
        let host = reference?.hostName ?? "Someone"
        apply(.placeholder("Shared by \(host) · sign in to see it"), hostName: host, colour: .systemOrange)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hostName: String { reference?.hostName ?? "Someone" }
    /// The owner's live view, once a session is attached.
    var live: SharedAgentLiveView? { body.live }
    var qaFooterText: String { body.footerText }
    var qaPlaceholderText: String? { body.placeholderText }

    func install(live: SharedAgentLiveView) { body.install(live: live) }

    /// One place for everything the state changes: the tab, the outline, the
    /// footer, the body's dimming.
    func apply(_ next: State, hostName: String, colour: NSColor) {
        state = next
        let mark: OwnershipMark
        switch next {
        case .placeholder:
            mark = .init(text: "\(hostName)'s · runs on \(hostName)'s Mac", colour: colour, outlined: true, dashed: true)
        case .connecting, .live:
            mark = .init(text: "\(hostName)'s · runs on \(hostName)'s Mac", colour: colour, outlined: true)
        case .offline:
            mark = .init(text: "\(hostName)'s · offline", colour: colour, outlined: true, dashed: true)
        case .stopped:
            mark = .init(text: "\(hostName)'s · no longer shared", colour: colour, outlined: true, dashed: true)
        }
        setOwnershipMark(mark)
        body.apply(next, hostName: hostName)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(self, window != nil)
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        if let live = body.live, live.offersComposer {
            window?.makeFirstResponder(live.composer.textView)
        } else {
            window?.makeFirstResponder(self)
        }
        return true
    }
}

/// The shared agent tile's body: the live view, and under it a footer when the
/// owner's Mac is offline or sharing stopped. A placeholder replaces both when
/// this install cannot open the agent.
@MainActor
final class SharedAgentTileBody: NSView {
    private(set) var live: SharedAgentLiveView?
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let footerLine = NSTextField(labelWithString: "")
    private let footerDetail = NSTextField(wrappingLabelWithString: "")
    private var showsFooter = false
    private var dimmed = false
    override var isFlipped: Bool { true }
    static let footerHeight: CGFloat = 54

    var footerText: String { showsFooter ? footerLine.stringValue + " · " + footerDetail.stringValue : "" }
    var placeholderText: String? { placeholder.isHidden ? nil : placeholder.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placeholder.font = .token(.body); placeholder.alignment = .center
        footerLine.font = .token(.label); footerLine.lineBreakMode = .byTruncatingTail
        footerDetail.font = .token(.caption); footerDetail.maximumNumberOfLines = 2
        for view in [placeholder, footerLine, footerDetail] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func install(live: SharedAgentLiveView) {
        guard self.live !== live else { return }
        self.live?.removeFromSuperview()
        self.live = live
        addSubview(live)
        live.isHidden = !placeholder.isHidden
        needsLayout = true
    }

    func apply(_ state: SharedAgentTileNSView.State, hostName: String) {
        var line = "", detail = ""
        var placeholderValue: String?
        switch state {
        case .placeholder(let text): placeholderValue = text
        case .connecting, .live: break
        case .offline(let lastSeen):
            line = "\(hostName)'s Mac is offline"
            detail = "Showing the last update, \(lastSeen.map { SharedAreaPersonColour.ago($0) } ?? "earlier"). Prompts wait until \(hostName)'s Mac is back."
        case .stopped(let text):
            line = text
            detail = "Nothing new arrives, and prompts are refused. What you already saw stays until you close this tile."
        }
        if placeholder.stringValue != (placeholderValue ?? "") { placeholder.stringValue = placeholderValue ?? "" }
        placeholder.isHidden = placeholderValue == nil
        live?.isHidden = placeholderValue != nil
        showsFooter = !line.isEmpty
        if footerLine.stringValue != line { footerLine.stringValue = line }
        if footerDetail.stringValue != detail { footerDetail.stringValue = detail }
        footerLine.isHidden = !showsFooter; footerDetail.isHidden = !showsFooter
        let dim: Bool = { if case .offline = state { return true }; if case .stopped = state { return true }; return false }()
        if dim != dimmed { dimmed = dim; live?.alphaValue = dim ? 0.55 : 1 }
        setAccessibilityLabel(placeholderValue ?? (showsFooter ? "\(line). \(detail)" : "Shared agent from \(hostName)"))
        needsLayout = true; needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        placeholder.frame = NSRect(x: inset, y: bounds.height / 2 - 24, width: max(0, bounds.width - 2 * inset), height: 48)
        let footer = showsFooter ? Self.footerHeight : 0
        let liveFrame = NSRect(x: inset, y: 8, width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - footer - 16))
        if let live, live.frame != liveFrame { live.frame = liveFrame }
        let top = bounds.height - footer
        footerLine.frame = NSRect(x: inset + 14, y: top + 8, width: max(0, bounds.width - 2 * inset - 14), height: 18)
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
        let top = bounds.height - Self.footerHeight
        LineToken.separator.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()
        TextToken.textSecondary.color.nsColor(in: self).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: top + 13, width: 7, height: 7)).fill()
    }
}
