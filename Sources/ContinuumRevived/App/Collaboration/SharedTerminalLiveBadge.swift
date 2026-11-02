import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// On the host's own terminal while it is shared (`.plans/114-terminal-sharing`):
/// a "Live" badge at the right of the tile's ownership strip, and Stop sharing,
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
    /// One badge on each shared terminal of this canvas; none elsewhere.
    /// Called with the hosted marks.
    func refreshTerminalLiveBadges(shared: Set<UUID>, areas: [UUID: UUID]) {
        guard let canvas = canvasView else { return }
        for tile in canvas.allWorkspaceTiles() where tile.kind == .terminal {
            guard let view = canvas.tileView(for: tile.id) else { continue }
            let existing = view.subviews.compactMap { $0 as? SharedTerminalLiveBadge }.first
            guard shared.contains(tile.id), let area = areas[tile.id] else { existing?.removeFromSuperview(); continue }
            let badge = existing ?? SharedTerminalLiveBadge(frame: .zero)
            let width = badge.preferredWidth
            badge.frame = NSRect(x: view.bounds.width - width - 8, y: TileNSView.titleBarHeight + 1, width: width, height: TileNSView.ownershipStripHeight - 2)
            badge.autoresizingMask = [.minXMargin, .maxYMargin]
            badge.onStop = { [weak self] in Task { await self?.cancelAgentShare(area: area) } }
            // Above the strip it sits on.
            view.addSubview(badge, positioned: .above, relativeTo: nil)
        }
    }
}
