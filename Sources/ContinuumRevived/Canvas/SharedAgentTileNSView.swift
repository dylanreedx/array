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
    /// An attach is under way: hydration and joining the window both ask.
    var attaching = false
    /// The tile left the window (unhydrated, workspace switch) or came back.
    var onWindowChange: ((SharedAgentTileNSView, Bool) -> Void)?

    override init(tile: Tile) {
        reference = tile.metadata.sharedAgent
        super.init(tile: tile)
        setContentView(body)
        let host = reference?.hostName ?? "Someone"
        apply(.placeholder("Shared by \(host) · sign in to see it"), hostName: host, colour: .systemOrange)
        enableTitleBarActions()
        setTileActionLabels(close: "Close shared view", stop: AgentTileHeaderView.stopActionTitle)
        setStopActionUnavailable("Only \(host) can stop it, on \(host)'s Mac.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hostName: String { reference?.hostName ?? "Someone" }
    /// The owner's live view, once a session is attached.
    var live: SharedAgentLiveView? { body.live }
    var qaFooterText: String { body.footerText }
    var qaPlaceholderText: String? { body.placeholderText }

    func install(live: SharedAgentLiveView) {
        body.install(live: live)
        live.onChromeChange = { [weak self] in self?.applyHostChrome() }
        applyHostChrome()
    }

    // MARK: The host tile's chrome (agent-chrome)

    /// The host tile's under-bar header: branch, Managed, status.
    let agentHeader = AgentTileHeaderView()
    private var showsHostChrome = false

    /// Title bar, under-bar, identity and character, from the host's chrome.
    /// Before the host sends any (an older host) the tile keeps its own title.
    func applyHostChrome() {
        guard let live = body.live, let chrome = live.chrome else {
            guard showsHostChrome else { return }
            showsHostChrome = false
            setTitleBarIdentity(title: nil)
            setTitleBarTint(nil)
            layer?.borderWidth = 0
            agentStatus = nil
            setAgentStatusLabel(nil)
            setAgentCharacter(agentID: nil, snapshot: nil)
            body.fillsBody = false
            return
        }
        if !showsHostChrome {
            showsHostChrome = true
            agentHeader.showsElapsedTime = false
            setUnderBarAccessory(agentHeader, height: AgentTileHeaderView.preferredHeight(zoom: .default))
            body.fillsBody = true
        }
        setTitleBarIdentity(title: chrome.title, providerModel: chrome.model)
        let identity = SharedAgentChromePresenter.identity(chrome)
        setTitleBarTint(identity.bar)
        layer?.borderWidth = identity.border == nil ? 0 : ManagedAgentTileNSView.identityBorderWidth
        layer?.borderColor = identity.border?.cgColor
        agentStatus = chrome.header.status
        setAgentStatusLabel(chrome.header.stateLabel)
        agentHeader.showsManaged = chrome.header.managed
        agentHeader.apply(SharedAgentChromePresenter.header(chrome))
        if let pick = live.titleCharacter {
            setAgentCharacter(agentID: pick.agentID, snapshot: pick.input.snapshot, characterName: pick.input.characterName,
                              shared: pick.input.shared.map { ($0.set, $0.assignment) })
        } else {
            setAgentCharacter(agentID: nil, snapshot: nil)
        }
        setStopActionUnavailable("Only \(hostName) can stop it, on \(hostName)'s Mac.")
    }

    /// The host tile's ⋯ items, each disabled with why: they change the agent
    /// on its owner's Mac, which nothing here can do.
    override func makeAdditionalTitleBarMenuItems() -> [NSMenuItem] {
        guard showsHostChrome else { return [] }
        let host = hostName
        func unavailable(_ title: String, _ reason: String) -> NSMenuItem {
            let item = ChoiceDetailMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.detail = reason
            item.identifier = NSUserInterfaceItemIdentifier("sharedAgent.menu." + title)
            return item
        }
        return [
            unavailable("Zoom", "Page zoom is on \(host)'s tile only."),
            unavailable("Sounds", "This agent's sounds play on \(host)'s Mac."),
            unavailable("Rename", "Only \(host) can rename it."),
            unavailable("Color", "Only \(host) can change its colour."),
            unavailable("Character", "Only \(host) can choose its character."),
            unavailable("Workspace Tools", "\(host) decides what tools it has."),
            unavailable("Show Background Processes", "Its processes run on \(host)'s Mac."),
        ]
    }

    /// QA: the chrome as this tile shows it, for the host/guest comparison.
    var qaChromeFacts: [String: String] {
        var facts: [String: String] = [:]
        SharedAgentChromeFacts.read(tile: self, header: agentHeader, into: &facts)
        if let live = body.live { facts.merge(live.strip.qaFacts) { first, _ in first } }
        return facts
    }

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
    /// The live view draws the host tile's chrome: it takes the whole body,
    /// edge to edge, as the host tile's content does.
    var fillsBody = false { didSet { if fillsBody != oldValue { needsLayout = true } } }
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
        let liveFrame = fillsBody
            ? NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - footer))
            : NSRect(x: inset, y: 8, width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - footer - 16))
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

/// "Dylan shared an agent with you. It runs on Dylan's Mac." with Show, at the
/// top of the canvas for a few seconds after a link lands a shared agent.
@MainActor
final class SharedAgentArrivalBanner: NSView {
    let text: String
    var onShow: (() -> Void)?
    private let colour: NSColor
    private var showRect: NSRect = .zero
    override var isFlipped: Bool { true }

    init(text: String, colour: NSColor) {
        self.text = text; self.colour = colour
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(text + " Show")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.token(.label), .foregroundColor: TextToken.textPrimary.color.nsColor(in: self)]
    }
    private var showAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.token(.label), .foregroundColor: AccentToken.accentWorking.color.nsColor(in: self)]
    }
    var preferredSize: NSSize {
        let body = (text as NSString).size(withAttributes: textAttributes).width
        let show = ("Show" as NSString).size(withAttributes: showAttributes).width
        return NSSize(width: ceil(body + show + 58), height: 30)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        SurfaceToken.tileChrome.color.nsColor(in: self).setFill(); pill.fill()
        LineToken.borderStrong.color.nsColor(in: self).setStroke(); pill.lineWidth = 1; pill.stroke()
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: bounds.midY - 5, width: 10, height: 10)).fill()
        let size = (text as NSString).size(withAttributes: textAttributes)
        (text as NSString).draw(at: NSPoint(x: 30, y: bounds.midY - size.height / 2), withAttributes: textAttributes)
        let show = ("Show" as NSString).size(withAttributes: showAttributes)
        showRect = NSRect(x: bounds.width - show.width - 14, y: bounds.midY - show.height / 2, width: show.width, height: show.height)
        ("Show" as NSString).draw(at: showRect.origin, withAttributes: showAttributes)
    }
    override func mouseDown(with event: NSEvent) { onShow?() }
    override func accessibilityPerformPress() -> Bool { onShow?(); return true }
}
