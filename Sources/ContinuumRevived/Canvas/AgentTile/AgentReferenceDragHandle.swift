import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// This is a copy source, never a tile move source. In particular a selected
/// group does not turn one reference into a group move or a group reference.
@MainActor
final class AgentReferenceDragHandle: NSControl, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.arrayapp.agent-reference.v1")
    private static weak var tracking: AgentReferenceDragHandle?
    weak var tileView: ManagedAgentTileNSView?
    var referenceProvider: (() -> AgentPromptReference?)?
    private var downEvent: NSEvent?
    private var panning = false
    private(set) var startedDragCount = 0
    /// The offline witness records the real drag setup without asking AppKit
    /// to enter its modal native drag loop.
    var dragSessionForChecks: ((NSPasteboardItem) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reference agent")
        setAccessibilityHelp("Drag onto another agent to add a reference to its draft.")
        toolTip = "Reference agent — drag onto another agent"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func isTracking(in window: NSWindow?) -> Bool {
        (tracking != nil && tracking?.window === window) || AgentTileReferenceMove.isTracking(in: window)
    }

    static func reference(from pasteboard: NSPasteboard) -> AgentPromptReference? {
        reference(from: pasteboard.data(forType: pasteboardType))
    }

    static func reference(from data: Data?) -> AgentPromptReference? {
        guard let data, data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(AgentPromptReference.self, from: data)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let size = min(bounds.width, bounds.height) * 0.58
        guard let image = CanvasSymbolImage.image(named: "at", pointSize: size),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        TextToken.textSecondary.color.nsColor(in: self).setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
    }

    override func mouseDown(with event: NSEvent) {
        panning = tileView?.canvas?.pointerPanRequested(for: event) == true
        if panning { tileView?.mouseDown(with: event); return }
        downEvent = event
        Self.tracking = self
    }

    override func mouseDragged(with event: NSEvent) {
        if panning { tileView?.mouseDragged(with: event); return }
        guard let downEvent,
              hypot(event.locationInWindow.x - downEvent.locationInWindow.x,
                    event.locationInWindow.y - downEvent.locationInWindow.y) >= 3,
              let reference = referenceProvider?(),
              let data = try? JSONEncoder().encode(reference) else { return }
        self.downEvent = nil
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        startedDragCount += 1
        if let dragSessionForChecks { dragSessionForChecks(item); return }
        let preview = NSImage(size: NSSize(width: 180, height: 30), flipped: false) { rect in
            SurfaceToken.tileChrome.color.nsColor(in: self).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            ("@ " + reference.displayName as NSString).draw(
                in: rect.insetBy(dx: 8, dy: 6), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: TextToken.textPrimary.color.nsColor(in: self)])
            return true
        }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let point = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(NSRect(origin: point, size: preview.size), contents: preview)
        beginDraggingSession(with: [draggingItem], event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if panning { tileView?.mouseUp(with: event) }
        panning = false
        downEvent = nil
        Self.tracking = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        downEvent = nil
        Self.tracking = nil
    }
}
