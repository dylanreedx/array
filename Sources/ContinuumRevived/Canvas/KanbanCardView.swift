import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// KB-01. One task. Plan: .plans/60-kanban-board.md
//
// A pure renderer: it owns no board state and never mutates one. Selection and
// editing are told to it; edits leave through `onCommit`. The board's authority
// is `BoardRuntime`, so two tiles showing one board cannot disagree.
//
// A card reads as a RAISED object on the lane: its own light fill, a soft
// shadow, no resting border. The lane behind it is the recessed surface. An
// outlined card on a near-identical fill read as a wireframe, which is what the
// first pass looked like.

@MainActor
final class KanbanCardView: NSView, TokenThemed {
    let cardId: UUID

    /// Fires when an inline title edit is committed. The tile turns it into a
    /// `BoardCommand`; the view never writes the model.
    var onCommit: ((String) -> Void)?
    var onEndEditing: (() -> Void)?

    private let titleField: NSTextField
    /// Small, quiet row: body indicator, link count, assignee. Hidden entirely
    /// when a task carries none of them, so a plain card stays plain.
    private let metaLabel = NSTextField(labelWithString: "")
    private(set) var isSelected = false
    private(set) var isEditing = false
    private(set) var isLifted = false
    /// The carried copy must be invisible to hit-testing, or it masks the agent
    /// tile the drag is hunting for.
    var ignoresHitTesting = false

    static let horizontalPadding: CGFloat = 11
    static let verticalPadding: CGFloat = 9
    static let metaHeight: CGFloat = 14
    static let minimumHeight: CGFloat = 42

    init(card: BoardCard, assigneeName: String?) {
        self.cardId = card.id
        titleField = NSTextField(wrappingLabelWithString: card.title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0
        // A real shadow, not a border, is what makes a card sit ON the lane.
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 2.5
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        layer?.masksToBounds = false

        titleField.font = NSFont.token(.body)
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        titleField.isBordered = false
        titleField.lineBreakMode = .byTruncatingTail
        // Three lines then ellipsis. A task title is a sentence, not a label, but
        // one paste must not reflow the whole lane.
        titleField.maximumNumberOfLines = 3
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.delegate = nil
        addSubview(titleField)

        metaLabel.font = NSFont.token(.caption)
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(card: card, assigneeName: assigneeName)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var title: String { titleField.stringValue }

    // MARK: - Content

    func update(card: BoardCard, assigneeName: String?) {
        if titleField.stringValue != card.title, !isEditing {
            titleField.stringValue = card.title
        }
        let meta = Self.metaText(for: card, assigneeName: assigneeName)
        metaLabel.stringValue = meta ?? ""
        metaLabel.isHidden = meta == nil
        setAccessibilityLabel(Self.accessibilityLabel(for: card, assigneeName: assigneeName))
        needsLayout = true
    }

    /// The quiet second line. Nil means "this task has nothing extra", and the
    /// card renders one line shorter.
    static func metaText(for card: BoardCard, assigneeName: String?) -> String? {
        var parts: [String] = []
        if let assigneeName { parts.append("◆ \(assigneeName)") }
        if !card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("≡") }
        if !card.links.isEmpty { parts.append("\(card.links.count) linked") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    static func accessibilityLabel(for card: BoardCard, assigneeName: String?) -> String {
        var label = card.title.isEmpty ? "Untitled task" : card.title
        if let assigneeName { label += ", assigned to \(assigneeName)" }
        if !card.body.isEmpty { label += ", has notes" }
        return label
    }

    // MARK: - Height

    /// Height for a given width. Measured HERE and cached by the lane, never
    /// inside `layout()`: per-layout text measurement is how the Markdown tile
    /// froze the app for three releases (docs/internals/performance.md).
    static func height(for card: BoardCard, assigneeName: String?, width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - horizontalPadding * 2)
        let font = NSFont.token(.body)
        let attributed = NSAttributedString(
            string: card.title.isEmpty ? " " : card.title, attributes: [.font: font])
        let bounding = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let measured = min(ceil(bounding.height), lineHeight * 3)
        let meta = metaText(for: card, assigneeName: assigneeName) == nil ? 0 : metaHeight + 3
        return max(minimumHeight, measured + meta + verticalPadding * 2)
    }

    // MARK: - Pointer

    private var tile: KanbanTileNSView? {
        var view: NSView? = superview
        while let current = view {
            if let tile = current as? KanbanTileNSView { return tile }
            view = current.superview
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        ignoresHitTesting ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        // Editing owns the pointer while it is editing; a drag must not start
        // from inside a text selection.
        guard !isEditing else { super.mouseDown(with: event); return }
        // A Cmd/Space-modified press belongs to the canvas camera, which claims it
        // before the tile ever routes here. Never start a card drag on one.
        if event.modifierFlags.contains(.command) { super.mouseDown(with: event); return }
        guard let tile else { super.mouseDown(with: event); return }
        // Double-click edits outright. Without this the ONLY route into editing was
        // a mouseUp branch that could never run, because mouseDown always opened a
        // drag session and mouseUp therefore always took the drag path — which is
        // exactly why a card could not be renamed after it was created.
        if event.clickCount >= 2 {
            tile.setFocusState(.editing(cardId))
            return
        }
        let wasSelected = isSelected
        tile.setFocusState(.selected(cardId))
        tile.beginCardDrag(cardId: cardId, event: event, wasSelected: wasSelected)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tile, tile.dragSession != nil else { super.mouseDragged(with: event); return }
        tile.continueCardDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let tile, tile.dragSession != nil else { super.mouseUp(with: event); return }
        tile.finishCardDrag()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - Self.horizontalPadding * 2)
        let metaSpace = metaLabel.isHidden ? 0 : Self.metaHeight + 3
        titleField.frame = NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: width,
            height: max(0, bounds.height - Self.verticalPadding * 2 - metaSpace))
        metaLabel.frame = NSRect(
            x: Self.horizontalPadding,
            y: max(0, bounds.height - Self.verticalPadding - Self.metaHeight),
            width: width,
            height: Self.metaHeight)
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

    /// Raises the card while the pointer carries it, so the copy under the cursor
    /// reads as picked up rather than as a duplicate lying flat.
    func applyLiftedChrome() {
        layer?.shadowOpacity = 0.30
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: 5)
    }

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.target = self
        titleField.action = #selector(commitEdit)
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
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

    @objc private func commitEdit() { endEditing(commit: true) }

    // MARK: - Tokens

    func applyTokens() {
        // A resting card paints its own fill — the token, never `.clear`. A
        // painted transparent reads to the colour census as an unregistered
        // literal (hazard 8).
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(in: self)
        // Selection is a ring; a resting card has NO border, which is what lets
        // the shadow do the separating.
        layer?.borderWidth = (isSelected || isEditing) ? 2 : 0
        layer?.borderColor = (isSelected || isEditing)
            ? LineToken.borderStrong.color.cgColor(in: self) : nil
        layer?.shadowColor = NSColor.black.cgColor
        layer?.opacity = isLifted ? 0.32 : 1
        titleField.textColor = TextToken.textPrimary.color.nsColor(in: self)
        metaLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func isAccessibilitySelected() -> Bool { isSelected }
}
