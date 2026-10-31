import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// One colour per person, the same on every surface: avatar, cursor, the
/// outline on their tiles and the follow frame. The area's host is purple; no
/// person is blue, because blue is the canvas's selection ring
/// (`.plans/105-collaboration/IN-CANVAS.md`, "The people and the content").
enum SharedAreaPersonColour {
    static let hostName = "purple"
    /// Never red: a person in red reads as an error.
    static let palette = ["orange", "mint", "yellow", "teal"]

    static func name(for person: SharedArea.ID<SharedArea.Person>, host: SharedArea.ID<SharedArea.Person>?) -> String {
        if person == host { return hostName }
        let hash = person.rawValue.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[hash % palette.count]
    }
    static func color(for person: SharedArea.ID<SharedArea.Person>, host: SharedArea.ID<SharedArea.Person>?) -> NSColor {
        AgentInboxView.identityDotColour(named: name(for: person, host: host))
    }
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        let letters = words.prefix(2).compactMap(\.first).map(String.init)
        return (letters.isEmpty ? "?" : letters.joined()).uppercased()
    }
    /// The person whose Mac runs the area's agents: the owner of most of its
    /// hosted items, else whoever owns the area.
    static func host(of document: SharedArea.Document?, me: SharedArea.ID<SharedArea.Person>,
                     role: Collaboration.Role?) -> SharedArea.ID<SharedArea.Person>? {
        let owners = (document?.items ?? []).compactMap { $0.source?.owner }
        let counts = Dictionary(owners.map { ($0, 1) }, uniquingKeysWith: +)
        if let top = counts.max(by: { $0.value == $1.value ? $0.key.rawValue.uuidString > $1.key.rawValue.uuidString : $0.value < $1.value }) {
            return top.key
        }
        return role == .owner ? me : nil
    }
    /// "4 min ago", for an offline host's last update.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }

    static func drawAvatar(initials: String, colour: NSColor, in rect: NSRect, dimmed: Bool, ring: NSColor?, view: NSView) {
        if let ring { ring.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2)).fill() }
        (dimmed ? SurfaceToken.tileChrome.color.nsColor(in: view) : colour).setFill()
        NSBezierPath(ovalIn: rect).fill()
        if dimmed {
            colour.withAlphaComponent(0.7).setStroke()
            let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)); edge.lineWidth = 1; edge.stroke()
        }
        let text = NSAttributedString(string: initials, attributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.42, weight: .semibold),
            .foregroundColor: dimmed ? colour : NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

/// The area's strip over its zone's header: a quiet Shared pill, a live dot
/// with who hosts it, and the people in it. Clicking a teammate's avatar
/// follows their view; that is the only thing it takes clicks for.
@MainActor
final class SharedAreaZoneHeaderView: NSView {
    /// QA (presence budget): while set, who asked this view to repaint, so a
    /// repaint the budget catches names its cause. Nil, and free, otherwise.
    static var qaRepaintTrace: [String]?
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        if Self.qaRepaintTrace != nil { Self.qaRepaintTrace!.append(SharedAreaRepaintTrace.line(for: self)) }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if Self.qaRepaintTrace != nil { Self.qaRepaintTrace!.append("\(type(of: self)) backing changed") }
    }
    struct Member: Equatable {
        let person: SharedArea.ID<SharedArea.Person>
        /// Set while the person is present with a device that can be followed.
        let device: UUID?
        let name: String
        let colour: String
        let online: Bool
    }
    let controller: SharedAreaController
    var person: SharedArea.ID<SharedArea.Person>?
    var onFollow: ((UUID) -> Void)?
    private(set) var members: [Member] = []
    private(set) var statusText = ""
    private(set) var hostOffline = false
    private(set) var host: SharedArea.ID<SharedArea.Person>?
    /// Why the area ended for this person, shown in place of the live status.
    var endingText: String?
    /// The device currently followed: its avatar carries a ring.
    var followedDevice: UUID? { didSet { if oldValue != followedDevice { needsDisplay = true } } }
    private(set) var drawCount = 0
    private var connection: SharedAreaController.Status = .closed
    override var isFlipped: Bool { true }

    init(controller: SharedAreaController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Shared area people")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(document: SharedArea.Document?, hosts: [Collaboration.HostLiveness]) {
        refresh(document: document, hosts: hosts, presence: controller.presence, status: controller.status)
    }
    func refresh(document: SharedArea.Document?, hosts: [Collaboration.HostLiveness],
                 presence: [Collaboration.Presence], status connection: SharedAreaController.Status) {
        guard let me = person else { return }
        self.connection = connection
        let host = SharedAreaPersonColour.host(of: document, me: me, role: controller.scope?.role)
        let now = Date()
        var seen = Set<SharedArea.ID<SharedArea.Person>>()
        var next: [Member] = []
        func add(_ person: SharedArea.ID<SharedArea.Person>, device: UUID?, label: String?, online: Bool) {
            guard seen.insert(person).inserted else { return }
            // The relay's member record names people; presence only says who is here.
            let recorded = controller.memberNames[person] ?? label
            let name = person == me ? (recorded ?? "You") : (recorded.map { String($0.prefix(28)) } ?? "Teammate")
            next.append(.init(person: person, device: person == me ? nil : device, name: name,
                              colour: SharedAreaPersonColour.name(for: person, host: host), online: online))
        }
        if let host {
            let present = presence.first(where: { $0.identity.person == host && $0.expiresAt > now })
            let hostItems = (document?.items ?? []).filter { $0.source?.owner == host }
            let offline = !hostItems.isEmpty && hostItems.allSatisfy {
                SharedAreaHostLivenessCopy.liveness(for: $0, in: hosts)?.state == .offline
            }
            add(host, device: present?.identity.device, label: present?.label, online: host == me || (present != nil && !offline))
        }
        for peer in presence where peer.expiresAt > now {
            add(peer.identity.person, device: peer.identity.device, label: peer.label, online: true)
        }
        for owner in (document?.items ?? []).compactMap({ $0.source?.owner }) { add(owner, device: nil, label: nil, online: false) }
        add(me, device: nil, label: nil, online: true)
        let hostItems = (document?.items ?? []).filter { $0.source?.owner == host && host != me }
        let offline = !hostItems.isEmpty && hostItems.allSatisfy {
            SharedAreaHostLivenessCopy.liveness(for: $0, in: hosts)?.state == .offline
        }
        let hostName = host.map { hostID in hostID == me ? "you" : (next.first(where: { $0.person == hostID })?.name ?? "a teammate") }
        let status: String
        switch connection {
        case .connected:
            if offline, let hostName { status = "\(hostName)'s Mac is offline" }
            else { status = hostName.map { "Live · hosted by \($0)" } ?? "Live" }
        case .connecting: status = "Connecting…"
        case .reconnecting: status = "Reconnecting · read-only"
        case .cached: status = "Cached · connect to edit"
        case .unavailable: status = "Shared area unavailable"
        case .closed: status = "Closed"
        }
        let shown = endingText ?? status
        guard next != members || shown != statusText || offline != hostOffline || host != self.host else { return }
        members = next; statusText = shown; hostOffline = offline; self.host = host
        setAccessibilityValue(([status] + members.map(\.name)).joined(separator: ", "))
        needsDisplay = true
    }

    private static let avatar: CGFloat = 20, step: CGFloat = 17
    /// Where each member's avatar is drawn, right to left from the strip's end.
    func avatarFrames() -> [(member: Member, frame: NSRect)] {
        var x = bounds.maxX - 12 - Self.avatar
        var result: [(Member, NSRect)] = []
        for member in members.reversed() {
            result.append((member, NSRect(x: x, y: (bounds.height - Self.avatar) / 2, width: Self.avatar, height: Self.avatar)))
            x -= Self.step
        }
        return result.reversed()
    }
    func avatarFrame(for person: SharedArea.ID<SharedArea.Person>) -> NSRect? {
        avatarFrames().first(where: { $0.member.person == person })?.frame
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return avatarFrames().contains(where: { $0.member.device != nil && $0.frame.contains(local) }) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let hit = avatarFrames().last(where: { $0.frame.contains(local) }), let device = hit.member.device else { return }
        onFollow?(device)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        let frames = avatarFrames()
        for (member, frame) in frames {
            let colour = AgentInboxView.identityDotColour(named: member.colour)
            SharedAreaPersonColour.drawAvatar(initials: SharedAreaPersonColour.initials(member.name), colour: colour, in: frame,
                dimmed: !member.online, ring: member.device != nil && member.device == followedDevice ? colour : SurfaceToken.canvas.color.nsColor(in: self), view: self)
        }
        let left = (frames.first?.frame.minX ?? bounds.maxX) - 12
        let status = NSAttributedString(string: statusText, attributes: [
            .font: NSFont.token(.caption), .foregroundColor: TextToken.textSecondary.color.nsColor(in: self)])
        let size = status.size()
        let textX = max(90, left - size.width)
        status.draw(in: NSRect(x: textX, y: (bounds.height - size.height) / 2, width: max(0, left - textX), height: size.height))
        let dot = NSRect(x: textX - 12, y: bounds.midY - 3.5, width: 7, height: 7)
        (hostOffline || connection != .connected ? TextToken.textSecondary.color.nsColor(in: self)
            : AccentToken.accentDone.color.nsColor(in: self)).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let pillText = NSAttributedString(string: "Shared", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: TextToken.textSecondary.color.nsColor(in: self)])
        let pillSize = pillText.size()
        let pill = NSRect(x: dot.minX - 12 - pillSize.width - 16, y: bounds.midY - 10, width: pillSize.width + 16, height: 20)
        guard pill.minX > 0 else { return }
        LineToken.border.color.nsColor(in: self).withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        path.lineWidth = 1; path.stroke()
        pillText.draw(at: NSPoint(x: pill.minX + 8, y: pill.midY - pillSize.height / 2))
    }
}

/// The discussion dock's surface inside the zone's right edge. Its controls
/// are the scene's own reader, composer and agreement panel laid over it.
@MainActor
final class SharedAreaZoneDockView: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Discussion and agreements")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(CornerRole.card.radius)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        SurfaceToken.panel.color.nsColor(in: self).setFill(); shape.fill()
        LineToken.separator.color.nsColor(in: self).setStroke(); shape.lineWidth = 1; shape.stroke()
        LineToken.separator.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: 60, width: bounds.width, height: 1).fill()
    }
}

/// Holds the agents' live views under the shared canvas, so the canvas can
/// draw selection over them. Passes clicks through where no agent is.
@MainActor
final class SharedAreaZoneAgentLayer: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A published agent in place inside the zone: the host's projection with its
/// own composer below it (`SharedAgentLiveView`, full access: a teammate
/// prompts it, and it runs on its owner's Mac), and whose it is and where it
/// runs. Offline, the composer goes and a footer says so: the view keeps its
/// place, dimmed, dashed, with the time of its last update. On its owner's own
/// canvas the footer points at the agent's real tile instead.
@MainActor
final class SharedAreaZoneAgentView: NSView {
    /// QA (presence budget): while set, who asked this view to repaint, so a
    /// repaint the budget catches names its cause. Nil, and free, otherwise.
    static var qaRepaintTrace: [String]?
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        if Self.qaRepaintTrace != nil { Self.qaRepaintTrace!.append(SharedAreaRepaintTrace.line(for: self)) }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if Self.qaRepaintTrace != nil { Self.qaRepaintTrace!.append("\(type(of: self)) backing changed") }
    }
    /// What sits under the live view: its composer, or a line saying why not.
    enum FooterMode: Equatable { case composer, offline, mine }
    static let headerHeight: CGFloat = 34
    static let footerHeight: CGFloat = 54
    let live: SharedAgentLiveView
    private(set) var footerMode: FooterMode = .composer
    private(set) var object: SharedArea.ID<SharedArea.Object>?
    private(set) var ownerColour: NSColor = .systemOrange
    private(set) var offline = false
    private(set) var isMine = false
    private(set) var isSelected = false
    private(set) var chipText = ""
    var footerText: String { footerLine.stringValue + " · " + footerDetail.stringValue }
    var titleText: String { title.stringValue }
    private let title = NSTextField(labelWithString: "Shared agent")
    private let footerLine = NSTextField(labelWithString: "")
    private let footerDetail = NSTextField(labelWithString: "")
    private var chipRect: NSRect = .zero
    override var isFlipped: Bool { true }

    init(controller: SharedAreaController) {
        live = SharedAgentLiveView(controller: controller)
        super.init(frame: .zero)
        wantsLayer = true
        title.font = .token(.label); title.lineBreakMode = .byTruncatingTail
        footerLine.font = .token(.label); footerLine.lineBreakMode = .byTruncatingTail
        footerDetail.font = .token(.caption); footerDetail.lineBreakMode = .byTruncatingTail
        for view in [title, live, footerLine, footerDetail] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        applyAppearance()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(item: SharedArea.Item, in document: SharedArea.Document?, liveness: Collaboration.HostLiveness?,
              ownerName: String, isMine: Bool, colour: NSColor, selected: Bool) {
        object = item.id
        self.isMine = isMine
        let wasOffline = offline
        offline = liveness?.state == .offline
        let changed = colour != ownerColour || selected != isSelected || wasOffline != offline
        ownerColour = colour; isSelected = selected
        live.hostOnline = liveness.map { $0.state == .online ? true : $0.state == .offline ? false : nil } ?? nil
        // The live view polls its own object; re-showing the same one on every
        // scene refresh would only restart work it is already doing.
        if live.object != item.id || !live.isPolling { live.show(object: item.id, in: document) }
        let possessive = isMine ? "Yours" : "\(ownerName)'s"
        let chip = isMine ? "Yours · shared" : offline ? "\(possessive) · offline" : "\(possessive) · on \(ownerName)'s Mac"
        let chipChanged = chip != chipText
        chipText = chip
        let titleValue = isMine ? "Agent · shared from this Mac" : "Agent · \(possessive)"
        if title.stringValue != titleValue { title.stringValue = titleValue }
        let line: String, detail: String
        let mode: FooterMode
        if isMine {
            mode = .mine
            line = "Your agent, as teammates see it"
            detail = "It runs on this Mac. Open its own tile to prompt it."
        } else if offline {
            mode = .offline
            line = "\(ownerName)'s Mac is offline"
            detail = "Showing the last update, \(liveness.map { SharedAreaPersonColour.ago($0.lastSeen) } ?? "earlier"). Nothing runs until \(ownerName) is back."
        } else {
            // Full access: the live view's own composer is the footer.
            mode = .composer
            line = ""; detail = ""
        }
        let modeChanged = mode != footerMode
        footerMode = mode
        for label in [footerLine, footerDetail] where label.isHidden != (mode == .composer) { label.isHidden = mode == .composer }
        if footerLine.stringValue != line { footerLine.stringValue = line }
        if footerDetail.stringValue != detail { footerDetail.stringValue = detail }
        let alpha: CGFloat = offline ? 0.55 : 1
        if live.alphaValue != alpha { live.alphaValue = alpha; title.alphaValue = alpha }
        setAccessibilityLabel(mode == .composer ? "\(titleValue), \(chipText)." : "\(titleValue), \(chipText). \(line).")
        // Presence frames refresh the scene many times a second: only a change
        // to what this view draws lays it out or paints it again.
        if changed || chipChanged || modeChanged { needsLayout = true; needsDisplay = true }
    }
    func stop() { live.stop() }

    override func layout() {
        super.layout()
        let chip = (chipText as NSString).size(withAttributes: [.font: NSFont.token(.caption)]).width + 34
        chipRect = NSRect(x: max(120, bounds.width - chip - 12), y: 7, width: min(chip, bounds.width - 132), height: 20)
        title.frame = .init(x: 14, y: 9, width: max(0, chipRect.minX - 22), height: 18)
        let footer = footerMode == .composer ? 0 : Self.footerHeight
        live.frame = .init(x: 12, y: Self.headerHeight + 8, width: max(0, bounds.width - 24),
                           height: max(0, bounds.height - Self.headerHeight - footer - 16))
        let footerTop = bounds.height - Self.footerHeight
        footerLine.frame = .init(x: 30, y: footerTop + 9, width: max(0, bounds.width - 44), height: 18)
        footerDetail.frame = .init(x: 14, y: footerTop + 30, width: max(0, bounds.width - 28), height: 16)
    }

    /// The header strip is the drag handle: the shared canvas above takes it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.y >= Self.headerHeight else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        title.textColor = TextToken.textPrimary.color.nsColor(in: self)
        footerLine.textColor = TextToken.textPrimary.color.nsColor(in: self)
        footerDetail.textColor = TextToken.textSecondary.color.nsColor(in: self)
        needsDisplay = true
    }

    /// Paints, for the budget witness.
    private(set) var drawCount = 0
    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        let radius = CGFloat(CornerRole.card.radius)
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        SurfaceToken.tileBody.color.nsColor(in: self).withAlphaComponent(offline ? 0.7 : 1).setFill(); body.fill()
        NSGraphicsContext.saveGraphicsState(); body.addClip()
        SurfaceToken.tileChrome.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight).fill()
        LineToken.separator.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: 1).fill()
        if footerMode != .composer { NSRect(x: 0, y: bounds.height - Self.footerHeight, width: bounds.width, height: 1).fill() }
        NSGraphicsContext.restoreGraphicsState()
        // Whose it is: a hairline in the owner's colour, dashed while offline.
        if !isMine || isSelected {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            outline.lineWidth = 1.5
            if offline { outline.setLineDash([5, 4], count: 2, phase: 0) }
            (isMine ? LineToken.borderStrong.color.nsColor(in: self) : ownerColour.withAlphaComponent(0.85)).setStroke()
            outline.stroke()
        }
        // The ownership chip.
        if chipRect.width > 20 {
            let chip = NSBezierPath(roundedRect: chipRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            SurfaceToken.tileBody.color.nsColor(in: self).setFill(); chip.fill()
            ownerColour.withAlphaComponent(0.55).setStroke(); chip.lineWidth = 1; chip.stroke()
            NSBezierPath(ovalIn: NSRect(x: chipRect.minX + 6, y: chipRect.midY - 6, width: 12, height: 12)).fill(with: offline ? SurfaceToken.tileChrome.color.nsColor(in: self) : ownerColour)
            (chipText as NSString).draw(in: NSRect(x: chipRect.minX + 24, y: chipRect.minY + 3, width: chipRect.width - 30, height: 16),
                withAttributes: [.font: NSFont.token(.caption), .foregroundColor: TextToken.textSecondary.color.nsColor(in: self)])
        }
        // The footer's state dot.
        guard footerMode != .composer else { return }
        let dot = NSRect(x: 14, y: bounds.height - Self.footerHeight + 14, width: 7, height: 7)
        (offline ? TextToken.textSecondary.color.nsColor(in: self) : AccentToken.accentWorking.color.nsColor(in: self)).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

private extension NSBezierPath {
    func fill(with colour: NSColor) { colour.setFill(); fill() }
}

/// What a zone says when the area has ended for this person: their access was
/// removed, the host took everything back, or it can't be reached. Never an
/// empty shell left silently on the canvas: one action takes the zone away.
@MainActor
final class SharedAreaZoneEndedView: NSView {
    enum Ending: Equatable {
        case accessRemoved(host: String?)
        case stoppedSharing(host: String)
        case unreachable(SharedAreaController.Unavailability)

        var title: String {
            switch self {
            case .accessRemoved: return "Your access was removed"
            case .stoppedSharing(let host): return "\(host) stopped sharing"
            case .unreachable: return "This shared area can't be reached"
            }
        }
        var detail: String {
            switch self {
            case .accessRemoved(let host):
                return "\(host ?? "The host") stopped sharing this area with you. Nothing here reaches their Mac any more."
            case .stoppedSharing:
                return "Everything that was shared here has been taken back."
            case .unreachable(let reason):
                switch reason {
                case .credentialsUnavailable: return "This Mac isn't signed in to the area any more."
                case .identityMismatch: return "This Mac's sign-in doesn't match the area."
                case .incompatibleState: return "This area needs a newer version of Array."
                case .localPersistence: return "Array couldn't read what this Mac saved for the area."
                case .connectionEnded, .accessDenied: return "The connection to the area ended."
                }
            }
        }
    }
    var onRemove: (() -> Void)?
    private(set) var ending: Ending?
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let removeButton = ComposerActionButton(presentation: CollaborationHubView.action("Remove from canvas", symbol: "xmark.circle"))
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        titleLabel.font = .token(.title); titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .token(.body); detailLabel.maximumNumberOfLines = 3
        removeButton.target = self; removeButton.action = #selector(removePressed(_:))
        removeButton.setAccessibilityLabel("Remove this shared area from the canvas")
        for view in [titleLabel, detailLabel, removeButton] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        applyAppearance()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ next: Ending?) {
        guard next != ending else { return }
        ending = next
        isHidden = next == nil
        titleLabel.stringValue = next?.title ?? ""
        detailLabel.stringValue = next?.detail ?? ""
        setAccessibilityLabel(next.map { "\($0.title). \($0.detail)" })
        needsLayout = true; needsDisplay = true
    }
    @objc private func removePressed(_ sender: Any?) { onRemove?() }

    override func layout() {
        super.layout()
        let width = bounds.width - 48
        titleLabel.frame = .init(x: 24, y: 22, width: width, height: 26)
        detailLabel.frame = .init(x: 24, y: 54, width: width, height: 60)
        let size = removeButton.fittingSize
        removeButton.frame = .init(x: 24, y: bounds.height - size.height - 20, width: size.width, height: size.height)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(CornerRole.card.radius)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        SurfaceToken.panel.color.nsColor(in: self).setFill(); shape.fill()
        LineToken.border.color.nsColor(in: self).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

/// One line per repaint request, for the presence budget witness.
enum SharedAreaRepaintTrace {
    static func line(for view: NSView) -> String {
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(7).map {
            String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ").prefix(140))
        }
        return "\(type(of: view)) " + frames.joined(separator: " <- ")
    }
}
