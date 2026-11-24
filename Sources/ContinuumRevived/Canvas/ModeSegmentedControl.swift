import AppKit
import ContinuumRevivedAgentUI

/// A short choice shown side by side, every option visible at once, painted
/// from DesignTokens for the active appearance: the selected option sits on the
/// same `rowSelected` surface as the Terminal switch, the others rest on nothing
/// and read in secondary ink. It replaces the stock `NSSegmentedControl` in tile
/// headers, whose labels AppKit colours itself.
///
/// Hand-drawn and tracked like `FaceToggleControl`, for the same reason: it sits
/// in a draggable title bar, and a click must select an option on release inside
/// it without starting a tile drag. It never takes focus, so clicking it leaves
/// the text view's caret where it was.
@MainActor
final class ModeSegmentedControl: NSControl {
    static let height: CGFloat = 20
    private static let font = NSFont.systemFont(ofSize: 10, weight: .medium)

    private let labels: [String]
    private let segmentWidth: CGFloat
    private var pressed: Int?

    /// The chosen option, or -1 for none. Writing it never sends the action.
    var selectedSegment: Int = -1 {
        didSet {
            guard selectedSegment != oldValue else { return }
            setAccessibilityValue(labels.indices.contains(selectedSegment) ? labels[selectedSegment] : nil)
            needsDisplay = true
        }
    }
    var segmentCount: Int { labels.count }
    func label(forSegment index: Int) -> String? { labels.indices.contains(index) ? labels[index] : nil }

    /// `totalWidth` is split evenly, as the stock control's fixed widths were.
    init(labels: [String], totalWidth: CGFloat) {
        self.labels = labels
        self.segmentWidth = totalWidth / CGFloat(max(labels.count, 1))
        super.init(frame: NSRect(x: 0, y: 0, width: totalWidth, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: segmentWidth * CGFloat(labels.count), height: Self.height) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func segmentRect(_ index: Int) -> NSRect {
        let width = bounds.width / CGFloat(max(labels.count, 1))
        return NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
    }

    private func segment(at point: NSPoint) -> Int? {
        guard bounds.contains(point), !labels.isEmpty else { return nil }
        return min(labels.count - 1, max(0, Int(point.x / (bounds.width / CGFloat(labels.count)))))
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let radius = CornerStyle.current == .sharp ? 0 : CGFloat(Radius.card)
        for index in labels.indices {
            let rect = segmentRect(index).insetBy(dx: 1, dy: 1)
            let selected = index == selectedSegment
            if selected || index == pressed {
                AgentSurfaceRole.rowSelected.color.nsColor(for: theme).setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
            let ink = (selected ? TextToken.textPrimary : TextToken.textSecondary).color.nsColor(for: theme)
            let text = NSAttributedString(string: labels[index], attributes: [.font: Self.font, .foregroundColor: ink])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        defer { pressed = nil; needsDisplay = true }
        pressed = segment(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let hit = segment(at: convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                if let hit, hit == pressed {
                    selectedSegment = hit
                    _ = sendAction(action, to: target)
                }
                return
            }
        }
    }
}
