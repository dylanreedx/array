import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// KB-01. One card. Plan: .plans/60-kanban-board.md
//
// A pure renderer: it owns no board state and never mutates one. Selection and
// editing are told to it; edits leave through `onCommit`. The board's authority
// is `BoardRuntime`, so two tiles showing one board cannot disagree.

@MainActor
final class KanbanCardView: NSView, TokenThemed {
    let cardId: UUID

    /// Fires when an inline edit is committed (Return or focus loss). The tile
    /// turns it into a `BoardCommand`; the view never writes the model.
    var onCommit: ((String) -> Void)?
    var onEndEditing: (() -> Void)?

    private let titleField: NSTextField
    private(set) var isSelected = false
    private(set) var isEditing = false
    /// True while this card is the one under the pointer in a drag. The lifted
    /// copy is drawn in the tile's overlay; the original renders as the vacated
    /// slot rather than disappearing, so the column's height never jumps.
    private(set) var isLifted = false

    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 8
    static let minimumHeight: CGFloat = 40

    init(cardId: UUID, title: String) {
        self.cardId = cardId
        titleField = NSTextField(wrappingLabelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        titleField.font = NSFont.token(.body)
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        titleField.isBordered = false
        titleField.lineBreakMode = .byTruncatingTail
        // Two lines then ellipsis. A long title must not grow the card without
        // bound, or one paste reflows the whole column.
        titleField.maximumNumberOfLines = 2
        titleField.cell?.truncatesLastVisibleLine = true
        addSubview(titleField)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var title: String {
        get { titleField.stringValue }
        set {
            guard titleField.stringValue != newValue else { return }
            titleField.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Height

    /// Height for a given width. Measured HERE and cached by the column, never
    /// inside `layout()`: per-layout text measurement is how the Markdown tile
    /// froze the app for three releases (docs/internals/performance.md).
    static func height(for title: String, width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - horizontalPadding * 2)
        let font = NSFont.token(.body)
        let attributed = NSAttributedString(string: title.isEmpty ? " " : title, attributes: [.font: font])
        let bounding = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        // Clamped to the two lines the label will actually render.
        let measured = min(ceil(bounding.height), lineHeight * 2)
        return max(minimumHeight, measured + verticalPadding * 2)
    }

    override func layout() {
        super.layout()
        titleField.frame = NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: max(0, bounds.width - Self.horizontalPadding * 2),
            height: max(0, bounds.height - Self.verticalPadding * 2))
    }

    // MARK: - State

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        applyTokens()
    }

    func setLifted(_ lifted: Bool) {
        guard isLifted != lifted else { return }
        isLifted = lifted
        applyTokens()
    }

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.drawsBackground = false
        titleField.target = self
        titleField.action = #selector(commitEdit)
        window?.makeFirstResponder(titleField)
        applyTokens()
    }

    func endEditing(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        if commit { onCommit?(titleField.stringValue) }
        titleField.isEditable = false
        titleField.isSelectable = false
        applyTokens()
        onEndEditing?()
    }

    @objc private func commitEdit() {
        endEditing(commit: true)
    }

    // MARK: - Tokens

    func applyTokens() {
        // A resting card paints its own fill — the token, never `.clear`. A
        // painted transparent reads to the colour census as an unregistered
        // literal (hazard 8).
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        layer?.borderColor = (isSelected || isEditing
            ? LineToken.borderStrong.color
            : LineToken.border.color).cgColor(in: self)
        layer?.borderWidth = (isSelected || isEditing) ? 2 : 1
        // The lifted original is the vacated slot: dimmed, still occupying its
        // space so nothing below it jumps.
        layer?.opacity = isLifted ? 0.35 : 1
        titleField.textColor = TextToken.textPrimary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    // MARK: - Accessibility

    override func accessibilityLabel() -> String? {
        titleField.stringValue.isEmpty ? "Untitled card" : titleField.stringValue
    }

    override func isAccessibilitySelected() -> Bool { isSelected }
}
