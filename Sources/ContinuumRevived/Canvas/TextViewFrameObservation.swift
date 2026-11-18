import AppKit
import ObjectiveC

extension NSView {
    /// AppKit registers every `NSTextView` whose superview is not a clip view as
    /// an observer of `NSView.frameDidChangeNotification` from ANY view, at the
    /// moment the text view is added to that superview
    /// (`-[NSTextView _setWatchingSuperviewClipView:]`). Nothing unregisters it:
    /// not detaching, not leaving the window. Every frame change anywhere in the
    /// app then walks one observer per such text view, and a text view outside a
    /// window costs the most. A visible-rows Markdown document builds every row
    /// and attaches only those near the clip, so the motion scene's 658 unattached
    /// row text views made one unrelated frame change cost 456 µs, and a zoom step
    /// makes hundreds of frame changes.
    ///
    /// A text view placed at an explicit frame by its owner gets nothing from that
    /// observation. A scroll view's document text view keeps AppKit's own clip
    /// observation, which it needs. Call after the subtree is built: attaching,
    /// detaching and re-rendering do not register again; only re-adding a text
    /// view to a superview does.
    func stopTextViewsObservingEveryViewFrame() {
        if let text = self as? NSTextView, !(text.superview is NSClipView) {
            NotificationCenter.default.removeObserver(text, name: NSView.frameDidChangeNotification, object: nil)
        }
        for child in subviews { child.stopTextViewsObservingEveryViewFrame() }
    }

    /// Stop a chrome subtree posting `NSView.frameDidChangeNotification`.
    ///
    /// Every `setFrame` on a view that posts walks AppKit's notification registrar,
    /// whatever the observers are. A tile's title bar and under-bar hold about 29
    /// labels, badges and buttons that nothing observes, and a zoom step re-frames
    /// them on every tile: on a quiet 12-tile canvas those posts were ~8 of the
    /// ~11 ms layout pass (`--tile-surface-residency-check`, 10.8 -> 2.6 ms per
    /// step). Scroll, clip and text views are left alone: AppKit observes them itself.
    func silenceFrameChangeNotifications() {
        // A scroll view's document view is observed by its clip view, which is
        // how the scroll view learns its content size changed.
        let isDocumentView = superview is NSClipView
        if !(self is NSScrollView), !(self is NSClipView), !isDocumentView,
           !keepsPostingFrameChanges, postsFrameChangedNotifications {
            postsFrameChangedNotifications = false
        }
        for child in subviews { child.silenceFrameChangeNotifications() }
    }

    /// Set while something observes this view's frame by notification (a popover
    /// anchor), so a chrome silencing pass leaves it posting.
    var keepsPostingFrameChanges: Bool {
        get { objc_getAssociatedObject(self, &frameChangeOptOutKey) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &frameChangeOptOutKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

nonisolated(unsafe) private var frameChangeOptOutKey: UInt8 = 0
