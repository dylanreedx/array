import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedAgentUI

/// Temporary source-canvas input surface. Drawing an area never creates a zone,
/// changes membership, saves the canvas or invokes a project runtime.
///
/// Two uses. File > Capture area hands back the dragged rectangle. The Share
/// tool (`onShare`, IN-CANVAS.md round 2 panel 3) hands back the tiles the
/// marquee fully covers, reporting them live as the drag goes.
@MainActor
final class SharedAreaCaptureSelectionView: NSView {
    weak var canvas: CanvasNSView?
    var onComplete: ((SharedArea.Rect) -> Void)?
    var onCancel: (() -> Void)?
    /// The Share tool: the covered tiles after every drag step.
    var onCoveredChange: ((Set<UUID>) -> Void)?
    /// The Share tool's release, with the covered tiles' union on screen.
    /// Nothing covered keeps the tool armed.
    var onShare: ((Set<UUID>, NSRect) -> Void)?
    private var origin: CGPoint?
    private var pointer: CGPoint?
    private var viewport: CanvasViewport?
    private(set) var covered: Set<UUID> = []
    private let hint = NSTextField(labelWithString: "Drag an area to review for sharing · Esc to cancel")
    private var isShareTool: Bool { onShare != nil }

    static let shareHint = "Share tool · drag over what you want to share · esc"

    /// The Share tool's overlay.
    convenience init(shareToolOn canvas: CanvasNSView) {
        self.init(canvas: canvas)
        hint.stringValue = Self.shareHint
        hint.setAccessibilityLabel("Share tool instructions")
        setAccessibilityLabel("Share tool")
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(canvas: CanvasNSView) {
        self.canvas = canvas
        super.init(frame: canvas.bounds)
        autoresizingMask = [.width, .height]
        hint.font = .token(.label)
        hint.alignment = .center
        hint.setAccessibilityLabel("Capture area instructions")
        addSubview(hint)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture area to share")
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        hint.textColor = TextToken.textPrimary.color.nsColor(for: effectiveAppearance.tokenTheme)
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        let frame: NSRect
        if isShareTool {
            // A pill centred at the top, drawn behind the label.
            let width = ceil(hint.intrinsicContentSize.width)
            frame = NSRect(x: floor((bounds.width - width) / 2), y: 22, width: width, height: ceil(hint.intrinsicContentSize.height))
        } else {
            frame = NSRect(x: 16, y: 18, width: max(0, bounds.width - 32), height: 28)
        }
        if hint.frame != frame { hint.frame = frame }
    }

    /// The release covered nothing shareable: say so in the hint and stay armed.
    func showRefusal(_ text: String) {
        hint.stringValue = text
        covered = []
        needsLayout = true
        needsDisplay = true
    }

    /// Tiles whose WORLD frame lies wholly inside the marquee.
    private func coveredTiles(from start: CGPoint, to end: CGPoint, viewport: CanvasViewport) -> [Tile] {
        guard let canvas else { return [] }
        let a = CanvasEngine.screenToWorld(start, viewport: viewport)
        let b = CanvasEngine.screenToWorld(end, viewport: viewport)
        let world = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        return canvas.allTilesInWorldFrames().filter { tile in
            world.contains(CGRect(x: tile.frame.x, y: tile.frame.y, width: tile.frame.width, height: tile.frame.height))
        }
    }

    private func updateCovered() {
        guard isShareTool, let origin, let pointer, let viewport else { return }
        let next = Set(coveredTiles(from: origin, to: pointer, viewport: viewport).map(\.id))
        guard next != covered else { return }
        covered = next
        onCoveredChange?(next)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Colors are resolved each draw; this transparent overlay owns no cached
        // CGColors or persistent canvas decoration.
        let theme = effectiveAppearance.tokenTheme
        if isShareTool {
            let pill = hint.frame.insetBy(dx: -12, dy: -6)
            let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            SurfaceToken.overlay.color.nsColor(for: theme).setFill()
            path.fill()
            path.lineWidth = CGFloat(LineWidth.hairline)
            AgentLineRole.decorativeHairline.color.nsColor(for: theme).setStroke()
            path.stroke()
        }
        guard let origin, let pointer else { return }
        let rect = NSRect(x: min(origin.x, pointer.x), y: min(origin.y, pointer.y),
            width: abs(pointer.x - origin.x), height: abs(pointer.y - origin.y))
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        (isShareTool ? AccentToken.accentInput.color : LineToken.borderStrong.color).nsColor(for: theme).setStroke()
        path.stroke()
        guard isShareTool, !covered.isEmpty else { return }
        // The count follows the pointer.
        let text = NSAttributedString(string: "\(covered.count) tile\(covered.count == 1 ? "" : "s")", attributes: [
            .font: NSFont.token(.caption), .foregroundColor: TextToken.textOnAccent.color.nsColor(for: theme)])
        let size = text.size()
        let badge = NSRect(x: pointer.x + 10, y: pointer.y + 10, width: ceil(size.width) + 12, height: ceil(size.height) + 4)
        AccentToken.accentInput.color.nsColor(for: theme).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        text.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 2))
    }
    override func mouseDown(with event: NSEvent) {
        guard let canvas else { return }
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil)
        pointer = origin; viewport = canvas.canvasState.viewport; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        updateCovered()
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let canvas, let origin, let viewport else { return }
        let end = convert(event.locationInWindow, from: nil)
        if isShareTool {
            pointer = end
            updateCovered()
            self.origin = nil; pointer = nil; needsDisplay = true
            guard canvas.canvasState.viewport == viewport, !covered.isEmpty else { return }
            let tiles = canvas.allTilesInWorldFrames().filter { covered.contains($0.id) }
            let union = tiles.map { CanvasEngine.tileScreenFrame($0.frame, viewport: viewport) }
                .reduce(NSRect.null) { $0.union($1) }
            onShare?(covered, convert(union, from: canvas))
            return
        }
        self.origin = nil; pointer = nil; needsDisplay = true
        guard abs(end.x - origin.x) >= 8, abs(end.y - origin.y) >= 8,
              canvas.canvasState.viewport == viewport else { return }
        let a = CanvasEngine.screenToWorld(origin, viewport: viewport)
        let b = CanvasEngine.screenToWorld(end, viewport: viewport)
        onComplete?(.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
    }
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

@MainActor
struct SharedAreaCaptureRequest {
    let id = UUID()
    weak var runtime: WorkspaceRuntime?
    let workspaceID: UUID
    let selection: SharedAreaPublication.Selection
}
