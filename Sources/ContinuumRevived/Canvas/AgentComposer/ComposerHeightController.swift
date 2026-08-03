import AppKit

/// Owns width-sensitive TextKit measurement for the composer. It changes frames
/// and scroller state in place; Auto Layout constraints remain owned by the shell.
@MainActor
final class ComposerHeightController {
    struct Measurement: Equatable {
        let contentHeight: CGFloat
        let lineHeight: CGFloat
        let visibleEditorHeight: CGFloat
        let isVerticallyScrollable: Bool
    }

    let maximumVisibleLines: Int
    private(set) var measurement: Measurement?

    init(maximumVisibleLines: Int = 8) {
        precondition(maximumVisibleLines > 0)
        self.maximumVisibleLines = maximumVisibleLines
    }

    @discardableResult
    func update(textView: NSTextView, scrollView: NSScrollView, width: CGFloat) -> Measurement {
        let measured = measure(textView: textView, width: width)
        measurement = measured

        // Overlay scrollers do not change the TextKit width when the threshold is
        // crossed, avoiding a width/height feedback loop at the eight-line cap.
        scrollView.scrollerStyle = .overlay
        // Install the native vertical scroller only once content exceeds the
        // eight-line viewport. Overlay style keeps that transition from changing
        // the TextKit width and feeding back into the measured height.
        scrollView.hasVerticalScroller = measured.isVerticallyScrollable
        scrollView.autohidesScrollers = true

        let documentHeight = max(scrollView.contentSize.height, measured.visibleEditorHeight, measured.contentHeight)
        let size = NSSize(width: max(0, width), height: documentHeight)
        if textView.frame.size != size {
            textView.setFrameSize(size)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if !measured.isVerticallyScrollable, scrollView.contentView.bounds.origin != .zero {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Text replacement and growth must not leave the insertion point below
        // the capped viewport. NSTextView retains native selection/IME behavior.
        if textView.selectedRange().location != NSNotFound {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        return measured
    }

    func measure(textView: NSTextView, width: CGFloat) -> Measurement {
        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender + font.leading)
        let safeWidth = max(1, width)

        let usedHeight: CGFloat
        if let textContainer = textView.textContainer, let layoutManager = textView.layoutManager {
            // Mutation-idempotent: resizing the container invalidates TextKit
            // layout, and invalidating during a live window display transaction
            // makes the subsequent draw resize the text view mid-display — which
            // AppKit terminates with an uncaught needs-display-during-display
            // exception (found at the P5.5 installed-candidate launch). Only a
            // real width change may invalidate.
            let target = NSSize(width: safeWidth, height: .greatestFiniteMagnitude)
            // This controller owns the container width explicitly. Width tracking
            // must stay OFF: in a live window whose clip view is momentarily
            // zero-width (the tile's first display transaction at boot), a
            // tracking container and TextKit's usage resize fight each other on
            // every display pass until AppKit terminates the app with a
            // needs-display-during-display exception (found at the P5.5
            // installed-candidate launch).
            if textContainer.widthTracksTextView {
                textContainer.widthTracksTextView = false
            }
            if textContainer.containerSize != target {
                textContainer.containerSize = target
            }
            layoutManager.ensureLayout(for: textContainer)
            usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        } else {
            usedHeight = lineHeight
        }
        let contentHeight = max(lineHeight, usedHeight)
        let maximumHeight = lineHeight * CGFloat(maximumVisibleLines)
        let scrollable = contentHeight > maximumHeight + 0.5

        return Measurement(
            contentHeight: contentHeight,
            lineHeight: lineHeight,
            visibleEditorHeight: min(contentHeight, maximumHeight),
            isVerticallyScrollable: scrollable
        )
    }
}
