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
    private let assignButton = NSButton(title: "Assign agent", target: nil, action: nil)
    private let grip = NSTextField(labelWithString: "⠿")
    private let thumbnail = NSImageView()
    private let contextMenuController = ChoicePopoverController()
    private var thumbnailID: UUID?
    private var thumbnailTask: Task<Void, Never>?
    private static let thumbnails = ComposerImageIOThumbnailPipeline()
    private var hasImage = false
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
    static let verticalPadding: CGFloat = 12
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
        titleField.lineBreakMode = .byWordWrapping
        // Three lines then ellipsis. A task title is a sentence, not a label, but
        // one paste must not reflow the whole lane.
        titleField.maximumNumberOfLines = 3
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.delegate = nil
        addSubview(titleField)

        metaLabel.font = NSFont.token(.caption)
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)
        assignButton.isBordered = false
        assignButton.alignment = .left
        assignButton.cell?.lineBreakMode = .byTruncatingTail
        assignButton.font = NSFont.token(.caption)
        assignButton.imageScaling = .scaleProportionallyDown
        assignButton.target = self
        assignButton.action = #selector(assignAgent)
        assignButton.toolTip = "Choose an agent, or drag this task onto an agent tile"
        addSubview(assignButton)
        grip.font = NSFont.systemFont(ofSize: 16)
        grip.setAccessibilityElement(false)
        addSubview(grip)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.layer?.masksToBounds = true
        addSubview(thumbnail)
        toolTip = "Click for task details · Drag to move or assign to an agent"

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
        hasImage = !card.attachments.isEmpty
        thumbnail.isHidden = !hasImage
        let symbol = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        assignButton.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Agent")?
            .withSymbolConfiguration(symbol)
        assignButton.imagePosition = .imageLeading
        assignButton.title =  (assigneeName ?? (card.assignee == nil ? "Assign agent" : "Unavailable agent")) + "  ▾"
        assignButton.setAccessibilityLabel(assigneeName.map { "Assigned agent: " + $0 } ?? "Assign agent")
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
        if !card.attachments.isEmpty { parts.append("\(card.attachments.count) image\(card.attachments.count == 1 ? "" : "s")") }
        if !card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Notes") }
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
        let textWidth = max(1, width - horizontalPadding * 2 - 16)
        let font = NSFont.token(.body)
        let attributed = NSAttributedString(
            string: card.title.isEmpty ? " " : card.title, attributes: [.font: font])
        let bounding = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let measured = min(ceil(bounding.height), lineHeight * 3)
        let meta = metaText(for: card, assigneeName: assigneeName) == nil ? 0 : metaHeight + 3
        return max(minimumHeight, measured + meta + verticalPadding * 2 + 27 + (card.attachments.isEmpty ? 0 : 54))
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
        if ignoresHitTesting { return nil }
        if isEditing { return super.hitTest(point) }
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        let local = convert(point, from: superview)
        if assignButton.frame.contains(local) { return assignButton }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // Editing owns the pointer while it is editing; a drag must not start
        // from inside a text selection.
        guard !isEditing else { super.mouseDown(with: event); return }
        if event.modifierFlags.contains(.control) {
            presentContextMenu(for: event)
            return
        }
        // A Cmd/Space-modified press belongs to the canvas camera, which claims it
        // before the tile ever routes here. Never start a card drag on one.
        if event.modifierFlags.contains(.command) { super.mouseDown(with: event); return }
        guard let tile else { super.mouseDown(with: event); return }
        tile.setFocusState(.selected(cardId))
        tile.beginCardDrag(cardId: cardId, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tile, tile.dragSession != nil else { super.mouseDragged(with: event); return }
        tile.continueCardDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let tile, tile.dragSession != nil else { super.mouseUp(with: event); return }
        tile.finishCardDrag()
    }

    override func rightMouseDown(with event: NSEvent) { presentContextMenu(for: event) }

    /// Cards use Array's token-painted command surface rather than AppKit's stock
    /// menu. The same controller supplies hover, keyboard navigation, VoiceOver,
    /// destructive styling, screen-edge placement, and outside-click dismissal.
    private func presentContextMenu(for event: NSEvent) {
        guard !isEditing else { return }
        tile?.setFocusState(.selected(cardId))
        let point = convert(event.locationInWindow, from: nil)
        presentContextItems(contextItems(), anchor: NSRect(origin: point, size: .zero), label: "Task actions")
    }

    private func presentContextItems(_ items: [ChoiceItem], anchor: NSRect, label: String) {
        contextMenuController.present(
            items: items,
            selectedID: nil,
            presentation: .commands,
            anchor: anchor,
            relativeTo: self,
            accessibilityLabel: label,
            onSelection: { [weak self] item in self?.performContextChoice(item.id, anchor: anchor) },
            focusReturnView: self
        )
    }

    private func contextItems() -> [ChoiceItem] {
        [
            ChoiceItem(id: "open", title: "Open Details", icon: .system("rectangle.and.pencil.and.ellipsis")),
            ChoiceItem(id: "move", title: "Move to…", icon: .system("arrow.right.circle")),
            ChoiceItem(id: "assign", title: "Assign to…", icon: .system("person.crop.circle.badge.plus")),
            ChoiceItem(id: "delete", title: "Delete Task", icon: .system("trash"), destructive: true),
        ]
    }

    private func moveItems() -> [ChoiceItem] {
        guard let tile, let card = tile.board.card(cardId) else { return [] }
        return [ChoiceItem(id: "back", title: "Task actions", icon: .system("chevron.left"))] +
            tile.board.orderedColumns.map { column in
                ChoiceItem(
                    id: "move:\(column.id.uuidString)", title: column.name,
                    icon: column.id == card.columnId ? .system("checkmark") : nil,
                    enabled: column.id != card.columnId
                )
            }
    }

    private func assignmentItems() -> [ChoiceItem] {
        guard let tile, let card = tile.board.card(cardId) else { return [] }
        let unassigned = ChoiceItem(
            id: "assign:none", title: "Unassigned",
            icon: card.assignee == nil ? .system("checkmark") : .system("person.crop.circle.badge.xmark"),
            enabled: card.assignee != nil
        )
        return [ChoiceItem(id: "back", title: "Task actions", icon: .system("chevron.left")), unassigned] +
            (tile.taskAgents?() ?? []).map { agent in
                ChoiceItem(
                    id: "assign:\(agent.id.rawValue.uuidString)", title: agent.name,
                    icon: agent.id == card.assignee ? .system("checkmark") : .system("person.crop.circle"),
                    enabled: agent.id != card.assignee
                )
            }
    }

    private func performContextChoice(_ id: String, anchor: NSRect) {
        switch id {
        case "open": tile?.openTask(cardId)
        case "move": presentContextItems(moveItems(), anchor: anchor, label: "Move task")
        case "assign": presentContextItems(assignmentItems(), anchor: anchor, label: "Assign task")
        case "delete": tile?.deleteTaskFromMenu(cardId)
        case "back": presentContextItems(contextItems(), anchor: anchor, label: "Task actions")
        default:
            if id.hasPrefix("move:"), let uuid = UUID(uuidString: String(id.dropFirst(5))) {
                tile?.moveTaskFromMenu(cardId, to: uuid)
            } else if id == "assign:none" {
                tile?.assignTaskFromMenu(cardId, to: nil)
            } else if id.hasPrefix("assign:"), let uuid = UUID(uuidString: String(id.dropFirst(7))) {
                tile?.assignTaskFromMenu(cardId, to: AgentID(rawValue: uuid))
            }
        }
    }

    var qaContextItems: [ChoiceItem] { contextItems() }
    var qaMoveItems: [ChoiceItem] { moveItems() }
    var qaAssignmentItems: [ChoiceItem] { assignmentItems() }
    var qaContextMenuIsPresented: Bool { contextMenuController.isPresented }
    var qaPresentedContextItems: [ChoiceItem] { contextMenuController.listView?.qaItems ?? [] }
    func qaPerformContextChoice(_ id: String) { performContextChoice(id, anchor: .zero) }
    func qaDismissContextMenu() { contextMenuController.dismiss() }
    var qaAssigneeImageAspectRatio: CGFloat {
        guard let size = assignButton.image?.size, size.height > 0 else { return 0 }
        return size.width / size.height
    }
    var qaAssigneeImageScaling: NSImageScaling { assignButton.imageScaling }

    // MARK: - Layout

    @objc private func assignAgent() { tile?.openTask(cardId, assign: true) }
    override func resetCursorRects() {
        super.resetCursorRects()
        if !isEditing { addCursorRect(bounds, cursor: .openHand) }
    }
    func loadThumbnail(card: BoardCard, store: BoardAttachmentStore?, boardID: UUID) {
        guard let attachment = card.attachments.first, let store else {
            thumbnailTask?.cancel(); thumbnailID = nil; thumbnail.image = nil; return
        }
        guard thumbnailID != attachment.id else { return }
        thumbnailTask?.cancel(); thumbnailID = attachment.id; thumbnail.image = nil
        let url = store.fileURL(boardID: boardID, attachmentID: attachment.id)
        thumbnailTask = Task { @MainActor [weak self] in
            guard let result = try? await Self.thumbnails.thumbnail(for: url, maxPixelSize: 180), !Task.isCancelled,
                  self?.thumbnailID == attachment.id else { return }
            self?.thumbnail.image = NSImage(data: result.pngData)
        }
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - Self.horizontalPadding * 2)
        let metaSpace = metaLabel.isHidden ? 0 : Self.metaHeight + 3
        let imageSpace: CGFloat = hasImage ? 54 : 0
        titleField.frame = NSRect(x: Self.horizontalPadding, y: Self.verticalPadding,
            width: width - 16, height: max(0, bounds.height - Self.verticalPadding * 2 - metaSpace - 27 - imageSpace))
        grip.frame = NSRect(x: bounds.width - 24, y: 10, width: 15, height: 20)
        thumbnail.frame = NSRect(x: Self.horizontalPadding, y: titleField.frame.maxY + 6, width: 76, height: 46)
        metaLabel.frame = NSRect(x: Self.horizontalPadding, y: bounds.height - Self.verticalPadding - 27 - Self.metaHeight,
                                width: width, height: Self.metaHeight)
        assignButton.frame = NSRect(x: Self.horizontalPadding - 2, y: bounds.height - Self.verticalPadding - 21,
                                   width: width + 2, height: 23)
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
        grip.textColor = TextToken.textSecondary.color.nsColor(in: self)
        assignButton.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func isAccessibilitySelected() -> Bool { isSelected }
}
