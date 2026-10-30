import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedAgentUI

/// Temporary source-canvas input surface. Drawing an area never creates a zone,
/// changes membership, saves the canvas or invokes a project runtime.
@MainActor
final class SharedAreaCaptureSelectionView: NSView {
    weak var canvas: CanvasNSView?
    var onComplete: ((SharedArea.Rect) -> Void)?
    var onCancel: (() -> Void)?
    private var origin: CGPoint?
    private var pointer: CGPoint?
    private var viewport: CanvasViewport?
    private let hint = NSTextField(labelWithString: "Drag an area to review for sharing · Esc to cancel")
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
        let frame = NSRect(x: 16, y: 18, width: max(0, bounds.width - 32), height: 28)
        if hint.frame != frame { hint.frame = frame }
    }
    override func draw(_ dirtyRect: NSRect) {
        // Colors are resolved each draw; this transparent overlay owns no cached
        // CGColors or persistent canvas decoration.
        guard let origin, let pointer else { return }
        let rect = NSRect(x: min(origin.x, pointer.x), y: min(origin.y, pointer.y),
            width: abs(pointer.x - origin.x), height: abs(pointer.y - origin.y))
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        LineToken.borderStrong.color.nsColor(for: effectiveAppearance.tokenTheme).setStroke()
        path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard let canvas else { return }
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil)
        pointer = origin; viewport = canvas.canvasState.viewport; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let canvas, let origin, let viewport else { return }
        let end = convert(event.locationInWindow, from: nil)
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
