import AppKit
import ContinuumRevivedAgentUI

@MainActor
final class CodeLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func visibleBoundsChanged() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        bounds.fill()

        layoutManager.ensureLayout(for: container)
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        guard glyphRange.location != NSNotFound else { return }
        let source = textView.string as NSString
        var charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        source.getLineStart(&charIndex, end: nil, contentsEnd: nil, for: NSRange(location: charIndex, length: 0))
        let prefix = source.substring(to: min(charIndex, source.length))
        var lineNumber = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: TextToken.textSecondary.color.nsColor(in: self)
        ]

        while charIndex < source.length {
            let lineRange = source.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyph = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            let point = textView.convert(fragment.origin, to: self)
            if point.y > bounds.maxY { break }
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: point.y), withAttributes: attributes)
            charIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }
    }
}
