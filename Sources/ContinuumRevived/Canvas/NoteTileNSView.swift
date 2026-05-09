import AppKit
import ContinuumRevivedCore
import Foundation

/// Tile view that hosts an editable plain-text NSTextView for note content.
/// The text view fills the tile body below the title bar; a scroll view
/// provides vertical scrolling for long notes.
@MainActor
final class NoteTileNSView: TileNSView, NSTextViewDelegate {
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    let noteId: UUID

    /// Fires whenever the text content changes. Spawner wires this to the
    /// debounced persistence handler so body changes flow into note files.
    var onTextChange: (() -> Void)?

    init(tile: Tile, noteId: UUID, initialBody: String) {
        self.noteId = noteId

        let tv = NSTextView()
        tv.isEditable = true
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = NSColor(white: 0.10, alpha: 1.0)
        tv.textColor = NSColor(white: 0.90, alpha: 1.0)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = initialBody
        tv.translatesAutoresizingMaskIntoConstraints = false

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.documentView = tv

        self.textView = tv
        self.scrollView = sv

        super.init(tile: tile)

        setContentView(sv)
        tv.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor).isActive = true
        tv.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func textDidChange(_ notification: Notification) { onTextChange?() }
}
