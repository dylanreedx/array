import AppKit

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
}
