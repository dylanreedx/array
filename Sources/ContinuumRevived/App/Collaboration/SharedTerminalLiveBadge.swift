import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// On the host's own terminal while it is shared (`.plans/114-terminal-sharing`):
/// a "Live" badge at the right of the tile's under-bar, and Stop sharing,
/// which takes the terminal out of its share at once. Typing in the terminal
/// is unaffected; the badge only says that what it shows is being sent.
@MainActor
final class SharedTerminalLiveBadge: NSView {
    let stopButton = ChoiceAccessoryButton(accessory: .init(id: "stop", title: "Stop sharing", symbol: nil,
                                                            accessibilityLabel: "Stop sharing this terminal"))
    var onStop: (() -> Void)?
    static let text = "Live"
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stopButton.isDestructive = true
        stopButton.onPress = { [weak self] _ in self?.onStop?() }
        addSubview(stopButton)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Live: this terminal is shared")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var pillWidth: CGFloat {
        ceil((Self.text as NSString).size(withAttributes: [.font: NSFont.token(.caption)]).width) + 24
    }
    var preferredWidth: CGFloat { pillWidth + 6 + ChoiceAccessoryButton.width(for: stopButton.accessory, zoom: .default) }

    override func layout() {
        super.layout()
        let width = ChoiceAccessoryButton.width(for: stopButton.accessory, zoom: .default)
        stopButton.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let font = NSFont.token(.caption)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme)]
        let size = (Self.text as NSString).size(withAttributes: attributes)
        let pill = NSRect(x: 0, y: 1, width: pillWidth, height: bounds.height - 2)
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        AgentSurfaceRole.rowHover.color.nsColor(for: theme).setFill(); path.fill()
        NSColor.systemRed.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1; path.stroke()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: pill.minX + 7, y: pill.midY - 3.5, width: 7, height: 7)).fill()
        (Self.text as NSString).draw(at: NSPoint(x: pill.minX + 17, y: pill.midY - size.height / 2), withAttributes: attributes)
    }
}

extension AppDelegate {
    /// One badge on each shared terminal of this canvas, on its own or opted
    /// in inside a portal; none elsewhere. Called with the hosted marks.
    func refreshTerminalLiveBadges() {
        guard let canvas = canvasView else { return }
        var areas: [UUID: UUID] = [:]
        if let model = try? collaborationAccountModel(), let account = model.activeAccount?.id ?? model.selectedAccountID {
            for entry in hostedAgentShares?.entries(account: account) ?? [] { areas[entry.tile] = entry.area }
        }
        let portal = portalLiveTerminals()
        let shared = Set(areas.keys).union(portal.keys)
        for tile in canvas.allWorkspaceTiles() where tile.kind == .terminal {
            guard let view = canvas.tileView(for: tile.id) else { continue }
            let existing = view.liveBadge
            guard shared.contains(tile.id), let area = areas[tile.id] ?? portal[tile.id] else { view.installLiveBadge(nil); continue }
            let inPortal = areas[tile.id] == nil
            let badge = existing ?? SharedTerminalLiveBadge(frame: .zero)
            // On its own, Stop ends its share; in a portal, it takes only this
            // terminal out and leaves the portal going.
            let id = tile.id
            badge.onStop = { [weak self] in
                fputs("terminal badge: Stop sharing pressed (\(inPortal ? "portal" : "own share"))\n", stderr)
                Task { inPortal ? await self?.stopPortalTerminal(area: area, tile: id) : await self?.cancelAgentShare(area: area) }
            }
            // At the right of the tile's under-bar, which scales with the title bar.
            view.installLiveBadge(badge)
        }
    }
}
