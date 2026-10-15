import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// T5b (`.plans/69`, D1) — what the steering/queue rail shows. Built by
/// `AgentSupervisor.queueRailState(for:)` from the durable queue and the steers
/// in flight; the rail renders it and owns no queue state of its own.
struct ComposerQueueRailState: Equatable {
    enum ItemKind: Equatable {
        /// Held by Array until the next tool call: editable and cancellable.
        case heldSteer
        /// Handed to the provider, awaiting its receipt: no longer Array's.
        case deliveringSteer
        case queued
        /// A queued `/compact`: it can be reordered or deleted, never edited.
        case compaction
    }

    struct Item: Equatable {
        let id: UUID
        let text: String
        let attachmentCount: Int
        let kind: ItemKind
    }

    /// Why the queue is held instead of draining on its own.
    enum Pause: Equatable {
        case afterStop
        case afterRelaunch
        case afterCompaction
        case held

        var title: String {
            switch self {
            case .afterStop: return "Paused after Stop"
            case .afterRelaunch: return "Paused after relaunch"
            case .afterCompaction: return "Paused, compaction did not finish"
            case .held: return "Paused"
            }
        }
    }

    var steers: [Item] = []
    var queued: [Item] = []
    var pause: Pause?

    static let empty = ComposerQueueRailState()
    var isEmpty: Bool { steers.isEmpty && queued.isEmpty }
}

/// B4 → T5b — Array's steering and follow-up queue, as two sections:
/// "Steering · after next tool call" and "Queued · after this turn", each shown
/// only when it has items. Since the 2026-10-13 owner review the tile docks it
/// at the foot of the transcript, just above the composer, and each pending
/// message reads as a quieter user message — the same left rule, dimmed text —
/// with send-now, edit and delete appearing under the pointer. Follow-ups stack
/// in drain order and reorder by drag. Direct manipulation of Array's queue:
/// nothing here touches the turn in flight except send-now on a follow-up,
/// which is D2's force send.
///
/// The rail itself paints nothing (it sits on the transcript's own surface);
/// each item row paints only its rule.
@MainActor
final class ComposerQueuedMessageRailView: NSView, TokenThemed, AgentPageZoomScalable {
    /// Visible item rows before the rail scrolls: four, and half of a fifth so
    /// the scroll reads at a glance. The rail can never push the transcript off
    /// a small tile.
    static let maximumVisibleRows = 4.5

    static func rowHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(28)) }
    static func headerHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(20)) }
    static func verticalInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.s)) }
    /// The transcript's own content inset, so a pending message's rule lines
    /// up with the sent messages' rules above it.
    static func horizontalInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }

    /// The full height of `state`'s rows, scrolled or not.
    static func contentHeight(for state: ComposerQueueRailState, zoom: AgentPageZoom) -> CGFloat {
        let sections = (state.steers.isEmpty ? 0 : 1) + (state.queued.isEmpty ? 0 : 1)
        let items = state.steers.count + state.queued.count
        return CGFloat(sections) * headerHeight(zoom: zoom) + CGFloat(items) * rowHeight(zoom: zoom)
    }

    /// The rail's reserved height at `zoom`: its rows plus insets, clamped to
    /// `maximumVisibleRows`; zero when there is nothing to show.
    static func railHeight(for state: ComposerQueueRailState, zoom: AgentPageZoom) -> CGFloat {
        guard !state.isEmpty else { return 0 }
        let sections = (state.steers.isEmpty ? 0 : 1) + (state.queued.isEmpty ? 0 : 1)
        let cap = CGFloat(sections) * headerHeight(zoom: zoom) + CGFloat(maximumVisibleRows) * rowHeight(zoom: zoom)
        return min(contentHeight(for: state, zoom: zoom), cap) + verticalInset(zoom: zoom) * 2
    }

    private(set) var pageZoom: AgentPageZoom = .default
    private(set) var state = ComposerQueueRailState.empty

    private let scrollView = NSScrollView(frame: .zero)
    private let documentView = FlippedContainerView(frame: .zero)
    /// Where a dragged follow-up will land. Painted only during a drag.
    private let dropIndicator = NSView(frame: .zero)
    private var rows: [NSView] = []
    private var drag: (id: UUID, from: Int, target: Int, startY: CGFloat, moved: Bool)?

    /// Deletes one item. Never touches the turn in flight.
    var onRemove: ((UUID) -> Void)?
    /// "Clear" — every queued follow-up at once.
    var onClearAll: (() -> Void)?
    /// Resumes a paused queue (`AgentSupervisor.resumeQueue`).
    var onResume: (() -> Void)?
    /// ⤒ — a held steer is handed over now; a follow-up is force-sent (D2).
    var onSendNow: ((UUID) -> Void)?
    /// ✎ — the owner decides whether the item can come back into the draft.
    var onEdit: ((UUID) -> Void)?
    /// A follow-up dragged to `index` among the follow-ups.
    var onMove: ((UUID, Int) -> Void)?
    /// The rail hid (nothing pending) or showed; its host follows.
    var onVisibilityChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.railHeight(for: state, zoom: pageZoom))
    }

    /// This rail's reserved height at its own zoom.
    var railHeight: CGFloat { Self.railHeight(for: state, zoom: pageZoom) }

    func setState(_ newState: ComposerQueueRailState) {
        guard newState != state || rows.isEmpty != newState.isEmpty else { return }
        state = newState
        if let drag, !newState.queued.contains(where: { $0.id == drag.id }) { endDrag() }
        rebuildRows()
        isHidden = newState.isEmpty
        onVisibilityChange?(isHidden)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The item ↑ on an empty draft edits: the last follow-up, else the last
    /// held steer. Compaction and delivering steers cannot be edited.
    var lastEditableItemID: UUID? {
        state.queued.last { $0.kind == .queued }?.id ?? state.steers.last { $0.kind == .heldSteer }?.id
    }

    private func rebuildRows() {
        for row in rows { row.removeFromSuperview() }
        rows = []
        let theme = effectiveTokenTheme
        if !state.steers.isEmpty {
            rows.append(QueueRailHeaderRow(
                symbol: state.pause == nil ? "arrow.turn.down.right" : "pause",
                title: "Steering \u{00B7} " + (state.pause?.title ?? "after next tool call"),
                pause: state.queued.isEmpty ? state.pause : nil, showsClear: false, rail: self))
            for item in state.steers { rows.append(QueueRailItemRow(item: item, number: nil, rail: self)) }
        }
        if !state.queued.isEmpty {
            rows.append(QueueRailHeaderRow(
                symbol: state.pause == nil ? "clock" : "pause",
                title: "Queued \u{00B7} " + (state.pause?.title ?? "after this turn"),
                pause: state.pause, showsClear: state.queued.count > 1, rail: self))
            for (index, item) in state.queued.enumerated() {
                rows.append(QueueRailItemRow(item: item, number: index + 1, rail: self))
            }
        }
        for row in rows {
            documentView.addSubview(row)
            (row as? QueueRailRow)?.apply(zoom: pageZoom, theme: theme)
        }
        documentView.addSubview(dropIndicator)
        setAccessibilityLabel(state.pause.map { "Steering and queued messages, \($0.title.lowercased())" }
            ?? "Steering and queued messages")
    }

    override func layout() {
        super.layout()
        let inset = Self.verticalInset(zoom: pageZoom)
        let side = Self.horizontalInset(zoom: pageZoom)
        scrollView.place(NSRect(
            x: side, y: inset, width: max(0, bounds.width - side * 2), height: max(0, bounds.height - inset * 2)))
        let content = Self.contentHeight(for: state, zoom: pageZoom)
        let width = scrollView.contentSize.width
        documentView.place(NSRect(x: 0, y: 0, width: width, height: content))
        var y: CGFloat = 0
        for row in rows {
            let height = row is QueueRailHeaderRow ? Self.headerHeight(zoom: pageZoom) : Self.rowHeight(zoom: pageZoom)
            row.place(NSRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        scrollView.hasVerticalScroller = content > scrollView.frame.height + 0.5
        layoutDropIndicator()
    }

    func applyTokens() {
        layer?.backgroundColor = nil
        let theme = effectiveTokenTheme
        dropIndicator.layer?.backgroundColor = drag?.moved == true
            ? AgentLineRole.focusRing.color.cgColor(for: theme) : nil
        for case let row as QueueRailRow in rows { row.apply(zoom: pageZoom, theme: theme) }
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        let theme = effectiveTokenTheme
        for case let row as QueueRailRow in rows { row.apply(zoom: zoom, theme: theme) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func configureViews() {
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Steering and queued messages")
        setAccessibilityHelp("Steers wait for the agent's next tool call; queued messages run one per turn after this one.")
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        dropIndicator.wantsLayer = true
        dropIndicator.isHidden = true
        dropIndicator.setAccessibilityElement(false)

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        addSubview(scrollView)
    }

    // MARK: - Row actions

    fileprivate func sendNow(_ id: UUID) { onSendNow?(id) }
    fileprivate func edit(_ id: UUID) { onEdit?(id) }
    fileprivate func remove(_ id: UUID) { onRemove?(id) }
    fileprivate func clearAll() { onClearAll?() }
    fileprivate func resume() { onResume?() }

    /// Moves a follow-up by one place — the keyboard/VoiceOver twin of a drag.
    fileprivate func nudge(_ id: UUID, by offset: Int) -> Bool {
        guard let from = state.queued.firstIndex(where: { $0.id == id }) else { return false }
        let to = from + offset
        guard state.queued.indices.contains(to) else { return false }
        commitMove(id, from: from, to: to)
        return true
    }

    private func commitMove(_ id: UUID, from: Int, to: Int) {
        guard from != to, state.queued.indices.contains(from) else { return }
        // Shown at once; the supervisor's own repaint confirms the same order.
        var next = state
        let item = next.queued.remove(at: from)
        next.queued.insert(item, at: min(to, next.queued.count))
        setState(next)
        onMove?(id, to)
    }

    // MARK: - Drag to reorder

    /// The y of the gap above follow-up `index`, in document coordinates.
    private func gapY(_ index: Int) -> CGFloat {
        let steerRows = state.steers.isEmpty ? 0 : Self.headerHeight(zoom: pageZoom)
            + CGFloat(state.steers.count) * Self.rowHeight(zoom: pageZoom)
        return steerRows + Self.headerHeight(zoom: pageZoom) + CGFloat(index) * Self.rowHeight(zoom: pageZoom)
    }

    fileprivate func dragBegan(_ id: UUID, event: NSEvent) {
        guard let from = state.queued.firstIndex(where: { $0.id == id }) else { return }
        let y = documentView.convert(event.locationInWindow, from: nil).y
        drag = (id, from, from, y, false)
    }

    fileprivate func dragMoved(_ event: NSEvent) {
        guard var current = drag else { return }
        let y = documentView.convert(event.locationInWindow, from: nil).y
        if !current.moved, abs(y - current.startY) < CGFloat(pageZoom.scaled(4)) { return }
        current.moved = true
        let row = Self.rowHeight(zoom: pageZoom)
        let gap = Int(((y - gapY(0)) / row).rounded())
        current.target = min(max(gap, 0), state.queued.count)
        drag = current
        documentView.autoscroll(with: event)
        for case let itemRow as QueueRailItemRow in rows where itemRow.itemID == current.id {
            itemRow.alphaValue = 0.5
        }
        applyTokens()
        layoutDropIndicator()
    }

    fileprivate func dragEnded() {
        guard let finished = drag else { return }
        endDrag()
        guard finished.moved else { return }
        // A gap below the item's own place lands one earlier once it has left it.
        let to = finished.target > finished.from ? finished.target - 1 : finished.target
        commitMove(finished.id, from: finished.from, to: to)
    }

    private func endDrag() {
        drag = nil
        for row in rows { row.alphaValue = 1 }
        applyTokens()
        layoutDropIndicator()
    }

    private func layoutDropIndicator() {
        guard let drag, drag.moved else {
            dropIndicator.isHidden = true
            return
        }
        dropIndicator.isHidden = false
        let thickness = CGFloat(pageZoom.scaled(2))
        dropIndicator.place(NSRect(
            x: 0, y: gapY(drag.target) - thickness / 2, width: documentView.bounds.width, height: thickness))
    }

    // MARK: - QA seams

    var qaIsPaused: Bool { state.pause != nil }
    var qaSectionTitles: [String] { rows.compactMap { ($0 as? QueueRailHeaderRow)?.qaTitle } }
    var qaQueuedTexts: [String] { state.queued.map(\.text) }
    var qaSteerTexts: [String] { state.steers.map(\.text) }
    var qaItemRows: [QueueRailItemRow] { rows.compactMap { $0 as? QueueRailItemRow } }
    var qaHasVerticalScroller: Bool { scrollView.hasVerticalScroller }
    var qaContentHeight: CGFloat { Self.contentHeight(for: state, zoom: pageZoom) }
    var qaScrollViewHeight: CGFloat { scrollView.frame.height }

    func qaRow(for id: UUID) -> QueueRailItemRow? { qaItemRows.first { $0.itemID == id } }

    /// Presses the queued header's Resume button through its own target/action.
    @discardableResult
    func qaPressResume() -> Bool {
        rows.compactMap { $0 as? QueueRailHeaderRow }.first { $0.qaHasResume }?.qaPressResume() ?? false
    }

    var qaResumeIsOffered: Bool { rows.contains { ($0 as? QueueRailHeaderRow)?.qaHasResume == true } }

    /// Presses the queued header's Clear button through its own target/action.
    @discardableResult
    func qaPressClear() -> Bool {
        rows.compactMap { $0 as? QueueRailHeaderRow }.first { $0.qaHasClear }?.qaPressClear() ?? false
    }

    /// Drives a real drag of follow-up `from` to the gap above follow-up `gap`
    /// (`queued.count` = the end) through the row's own mouse handlers, with
    /// window-coordinate events, exactly as AppKit delivers them.
    func qaDragQueuedItem(from: Int, toGap gap: Int) -> Bool {
        guard state.queued.indices.contains(from),
              let row = qaRow(for: state.queued[from].id), let window else { return false }
        func event(_ type: NSEvent.EventType, documentY: CGFloat) -> NSEvent? {
            let point = documentView.convert(NSPoint(x: row.frame.midX, y: documentY), to: nil)
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown, documentY: row.frame.midY),
              let moved = event(.leftMouseDragged, documentY: gapY(gap)),
              let up = event(.leftMouseUp, documentY: gapY(gap)) else { return false }
        row.mouseDown(with: down)
        row.mouseDragged(with: moved)
        row.mouseUp(with: up)
        return true
    }
}

/// Docks the pending rail as an arranged subview of a vertical stack (the
/// tile's, between transcript and compose strip). Hidden whenever the rail is,
/// so an empty queue takes no space and leaves no zero-height view behind. A
/// stack DETACHES a hidden view and drops every constraint that tied it in, so
/// the dock re-pins its width to whatever superview it lands in.
@MainActor
final class PendingMessageDockView: NSView {
    let rail: ComposerQueuedMessageRailView
    private var widthPin: NSLayoutConstraint?

    init(rail: ComposerQueuedMessageRailView) {
        self.rail = rail
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rail)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: trailingAnchor),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = rail.isHidden
        rail.onVisibilityChange = { [weak self] hidden in self?.isHidden = hidden }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        widthPin?.isActive = false
        widthPin = nil
        guard let superview else { return }
        let pin = widthAnchor.constraint(equalTo: superview.widthAnchor)
        pin.isActive = true
        widthPin = pin
    }

    /// The vertical space the dock takes in its stack: none while hidden.
    var occupiedHeight: CGFloat { isHidden || superview == nil ? 0 : frame.height }
}

/// A rail row's zoom/theme contract; the rail delivers both, rows do not walk.
@MainActor
private protocol QueueRailRow: NSView {
    func apply(zoom: AgentPageZoom, theme: TokenTheme)
}

private extension NSView {
    /// performance.md trap 3: a frame assignment that changes nothing still
    /// re-dirties layout.
    func place(_ frame: NSRect) {
        if self.frame != frame { self.frame = frame }
    }
}

@MainActor
private func queueRailIconButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: "", target: target, action: action)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.setButtonType(.momentaryPushIn)
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone
    button.setAccessibilityLabel(label)
    button.toolTip = label
    button.identifier = NSUserInterfaceItemIdentifier(symbol)
    return button
}

/// "Steering · after next tool call" / "Queued · after this turn" (or why it is
/// paused, with Resume).
@MainActor
private final class QueueRailHeaderRow: NSView, QueueRailRow {
    private let icon = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let symbol: String
    private let pause: ComposerQueueRailState.Pause?
    private weak var rail: ComposerQueuedMessageRailView?
    private var zoom: AgentPageZoom = .default
    /// Measured when the font changes, never inside `layout()` (performance.md).
    private var titleHeight: CGFloat = 0
    private var buttonSizes: [ObjectIdentifier: NSSize] = [:]

    init(symbol: String, title: String, pause: ComposerQueueRailState.Pause?, showsClear: Bool,
         rail: ComposerQueuedMessageRailView) {
        self.symbol = symbol
        self.pause = pause
        self.rail = rail
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityRole(.staticText)
        icon.imageScaling = .scaleNone
        icon.setAccessibilityElement(false)
        addSubview(icon)
        addSubview(titleLabel)
        for (button, action, label) in [
            (resumeButton, #selector(resumePressed(_:)), "Resume the paused queue"),
            (clearButton, #selector(clearPressed(_:)), "Clear queued messages"),
        ] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.setButtonType(.momentaryPushIn)
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
        }
        resumeButton.isHidden = pause == nil
        clearButton.isHidden = !showsClear
        addSubview(resumeButton)
        addSubview(clearButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(zoom: AgentPageZoom, theme: TokenTheme) {
        self.zoom = zoom
        icon.image = CanvasSymbolImage.image(named: symbol, pointSize: CGFloat(zoom.scaled(10)), weight: .regular)
        titleLabel.font = .token(.caption, zoom: zoom)
        resumeButton.font = .token(.caption, zoom: zoom)
        clearButton.font = .token(.caption, zoom: zoom)
        // A paused queue says so in the attention accent, not a quiet grey.
        let tone = pause == nil ? TextToken.textSecondary.color : AccentToken.accentApproval.color
        icon.contentTintColor = tone.nsColor(for: theme)
        titleLabel.textColor = tone.nsColor(for: theme)
        resumeButton.contentTintColor = AccentToken.accentInput.color.nsColor(for: theme)
        clearButton.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        titleHeight = titleLabel.intrinsicContentSize.height
        for button in [clearButton, resumeButton] {
            buttonSizes[ObjectIdentifier(button)] = button.intrinsicContentSize
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let gap = CGFloat(zoom.scaled(Space.s))
        let iconSide = CGFloat(zoom.scaled(14))
        icon.place(NSRect(x: 0, y: floor((bounds.height - iconSide) / 2), width: iconSide, height: iconSide))
        var trailing = bounds.width
        for button in [clearButton, resumeButton] where !button.isHidden {
            let size = buttonSizes[ObjectIdentifier(button)] ?? .zero
            trailing -= size.width
            button.place(NSRect(x: trailing, y: floor((bounds.height - size.height) / 2), width: size.width, height: size.height))
            trailing -= gap * 2
        }
        titleLabel.place(NSRect(
            x: icon.frame.maxX + gap, y: floor((bounds.height - titleHeight) / 2),
            width: max(0, trailing - icon.frame.maxX - gap), height: titleHeight))
    }

    @objc private func resumePressed(_ sender: NSButton) { rail?.resume() }
    @objc private func clearPressed(_ sender: NSButton) { rail?.clearAll() }

    var qaTitle: String { titleLabel.stringValue }
    var qaHasResume: Bool { !resumeButton.isHidden }
    var qaHasClear: Bool { !clearButton.isHidden }
    func qaPressClear() -> Bool {
        guard !clearButton.isHidden else { return false }
        clearButton.performClick(nil)
        return true
    }
    func qaPressResume() -> Bool {
        guard !resumeButton.isHidden else { return false }
        resumeButton.performClick(nil)
        return true
    }
}

/// One held steer, delivering steer or follow-up, drawn as a pending user
/// message: the user turn's left rule in a quieter line role, the text dimmed
/// and on one line, and `↑ ✎ ✕` (send now, edit, delete) appearing only under
/// the pointer. A delivering steer instead says "Sending…", always.
///
/// `TokenThemed` because the rule is a sublayer of the row's own layer; at rest
/// that rule is the only colour the row paints — no fill, and no fill on the
/// hover-only buttons either.
@MainActor
final class QueueRailItemRow: NSView, QueueRailRow, TokenThemed {
    let itemID: UUID
    let kind: ComposerQueueRailState.ItemKind
    /// The pending twin of `UserPromptView`'s authorship rule.
    private let rule = CALayer()
    private let textLabel = NSTextField(labelWithString: "")
    private let attachmentIcon = NSImageView(frame: .zero)
    private let attachmentLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private var sendNowButton: NSButton!
    private var editButton: NSButton!
    private var removeButton: NSButton!
    private weak var rail: ComposerQueuedMessageRailView?
    private var zoom: AgentPageZoom = .default
    private var theme: TokenTheme = .dark
    private var isHovered = false
    private var hoverArea: NSTrackingArea?
    /// Measured when the font changes, never inside `layout()` (performance.md).
    private var textHeight: CGFloat = 0
    private var stateSize = NSSize.zero
    private var attachmentSize = NSSize.zero

    fileprivate init(item: ComposerQueueRailState.Item, number: Int?, rail: ComposerQueuedMessageRailView) {
        itemID = item.id
        kind = item.kind
        self.rail = rail
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(rule)
        let oneLine = item.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        let preview = oneLine.isEmpty ? (item.attachmentCount > 0 ? "Attachment" : "Empty message") : oneLine
        textLabel.stringValue = preview
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.maximumNumberOfLines = 1
        textLabel.setAccessibilityElement(false)
        attachmentIcon.imageScaling = .scaleNone
        attachmentIcon.isHidden = item.attachmentCount == 0
        attachmentIcon.setAccessibilityElement(false)
        attachmentLabel.stringValue = item.attachmentCount > 1 ? "\(item.attachmentCount)" : ""
        attachmentLabel.isHidden = item.attachmentCount < 2
        attachmentLabel.setAccessibilityElement(false)
        stateLabel.stringValue = item.kind == .deliveringSteer ? "Sending\u{2026}" : ""
        stateLabel.isHidden = item.kind != .deliveringSteer
        stateLabel.setAccessibilityElement(false)
        for view in [textLabel, attachmentIcon, attachmentLabel, stateLabel] as [NSView] { addSubview(view) }

        let what: String
        switch item.kind {
        case .heldSteer: what = "Steer, held until the next tool call"
        case .deliveringSteer: what = "Steer being delivered, no longer editable"
        case .queued, .compaction: what = "Queued message \(number ?? 0) of \(rail.state.queued.count)"
        }
        let attachments = item.attachmentCount == 0 ? ""
            : item.attachmentCount == 1 ? ", 1 attachment" : ", \(item.attachmentCount) attachments"
        let sendNowLabel = item.kind == .heldSteer ? "Send steer now" : "Interrupt and send now"
        sendNowButton = queueRailIconButton(
            symbol: Self.sendNowSymbol, label: "\(sendNowLabel): \(preview)", target: self, action: #selector(sendNowPressed(_:)))
        editButton = queueRailIconButton(
            symbol: Self.editSymbol, label: "Edit: \(preview)", target: self, action: #selector(editPressed(_:)))
        removeButton = queueRailIconButton(
            symbol: Self.removeSymbol, label: "Delete: \(preview)", target: self, action: #selector(removePressed(_:)))
        // A delivering steer is the provider's now: nothing to send, edit or
        // delete. A queued compaction has no text to edit, and send-now would
        // only put it back (`sendQueuedItemNow` runs prompts).
        sendNowButton.isHidden = item.kind == .deliveringSteer || item.kind == .compaction
        editButton.isHidden = item.kind != .heldSteer && item.kind != .queued
        removeButton.isHidden = item.kind == .deliveringSteer
        for button in actionButtons {
            // Hover-only, but still in the accessibility tree and still
            // reachable by VoiceOver: transparent, never hidden.
            button.alphaValue = 0
            addSubview(button)
        }

        toolTip = item.text.isEmpty ? preview : item.text
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(what): \(preview)\(attachments)")
        if item.kind == .queued || item.kind == .compaction {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Move up") { [weak self] in
                    guard let self else { return false }
                    return self.rail?.nudge(self.itemID, by: -1) ?? false
                },
                NSAccessibilityCustomAction(name: "Move down") { [weak self] in
                    guard let self else { return false }
                    return self.rail?.nudge(self.itemID, by: 1) ?? false
                },
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One weight and size for all three, lighter than the old ⤒ ✎ ✕ set.
    private static let sendNowSymbol = "arrow.up"
    private static let editSymbol = "pencil"
    private static let removeSymbol = "xmark"

    private var actionButtons: [NSButton] { [sendNowButton!, editButton!, removeButton!] }
    private var reorders: Bool { kind == .queued || kind == .compaction }

    func apply(zoom: AgentPageZoom, theme: TokenTheme) {
        self.zoom = zoom
        self.theme = theme
        textLabel.font = .token(.body, zoom: zoom)
        attachmentLabel.font = .token(.caption, zoom: zoom)
        stateLabel.font = .token(.caption, zoom: zoom)
        attachmentIcon.image = CanvasSymbolImage.image(named: "paperclip", pointSize: CGFloat(zoom.scaled(10)), weight: .regular)
        for (button, symbol) in zip(actionButtons, [Self.sendNowSymbol, Self.editSymbol, Self.removeSymbol]) {
            button.image = CanvasSymbolImage.image(named: symbol, pointSize: CGFloat(zoom.scaled(11)), weight: .regular)
        }
        textHeight = textLabel.intrinsicContentSize.height
        stateSize = stateLabel.intrinsicContentSize
        attachmentSize = attachmentLabel.intrinsicContentSize
        applyTokens()
        needsLayout = true
    }

    func applyTokens() {
        layer?.backgroundColor = nil
        let secondary = TextToken.textSecondary.color.nsColor(for: theme)
        rule.backgroundColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        // Pending, not sent: every word one step quieter than a sent message.
        textLabel.textColor = secondary
        attachmentIcon.contentTintColor = secondary
        attachmentLabel.textColor = secondary
        stateLabel.textColor = secondary
        for button in actionButtons { button.contentTintColor = secondary }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        theme = effectiveTokenTheme
        applyTokens()
    }

    override func layout() {
        super.layout()
        let gap = CGFloat(zoom.scaled(Space.s))
        let side = CGFloat(zoom.scaled(20))
        func centered(_ height: CGFloat) -> CGFloat { floor((bounds.height - height) / 2) }
        let ruleInset = CGFloat(zoom.scaled(Space.xs))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rule.frame = NSRect(
            x: 0, y: ruleInset, width: UserPromptView.ruleWidth(zoom: zoom),
            height: max(0, bounds.height - ruleInset * 2))
        CATransaction.commit()
        // The prose column starts where a sent message's does.
        let x = UserPromptView.leadingInset(zoom: zoom)
        // The action slots are reserved even at rest, so the text never
        // reflows when the pointer arrives.
        var trailing = bounds.width
        for button in [removeButton!, editButton!, sendNowButton!] where !button.isHidden {
            trailing -= side
            button.place(NSRect(x: trailing, y: centered(side), width: side, height: side))
        }
        if !stateLabel.isHidden {
            trailing -= stateSize.width + gap
            stateLabel.place(NSRect(x: trailing, y: centered(stateSize.height), width: stateSize.width, height: stateSize.height))
        }
        if !attachmentLabel.isHidden {
            trailing -= attachmentSize.width + gap
            attachmentLabel.place(NSRect(
                x: trailing, y: centered(attachmentSize.height), width: attachmentSize.width, height: attachmentSize.height))
        }
        if !attachmentIcon.isHidden {
            let iconSide = CGFloat(zoom.scaled(14))
            trailing -= iconSide + (attachmentLabel.isHidden ? gap : 0)
            attachmentIcon.place(NSRect(x: trailing, y: centered(iconSide), width: iconSide, height: iconSide))
        }
        textLabel.place(NSRect(x: x, y: centered(textHeight), width: max(0, trailing - gap - x), height: textHeight))
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        for button in actionButtons { button.alphaValue = hovered ? 1 : 0 }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if reorders { addCursorRect(textLabel.frame, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard reorders else { return super.mouseDown(with: event) }
        rail?.dragBegan(itemID, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard reorders else { return super.mouseDragged(with: event) }
        rail?.dragMoved(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard reorders else { return super.mouseUp(with: event) }
        rail?.dragEnded()
    }

    @objc private func sendNowPressed(_ sender: NSButton) { rail?.sendNow(itemID) }
    @objc private func editPressed(_ sender: NSButton) { rail?.edit(itemID) }
    @objc private func removePressed(_ sender: NSButton) { rail?.remove(itemID) }

    // MARK: - QA seams

    var qaText: String { textLabel.stringValue }
    var qaOffersSendNow: Bool { !sendNowButton.isHidden }
    var qaOffersEdit: Bool { !editButton.isHidden }
    var qaOffersRemove: Bool { !removeButton.isHidden }
    var qaShowsAttachments: Bool { !attachmentIcon.isHidden }
    var qaButtonSide: CGFloat { sendNowButton.isHidden ? removeButton.frame.width : sendNowButton.frame.width }
    var qaControlLabels: [String] {
        actionButtons.filter { !$0.isHidden }.compactMap { $0.accessibilityLabel() }
    }
    var qaActionsVisible: Bool {
        actionButtons.contains { !$0.isHidden && $0.alphaValue > 0 }
    }
    var qaRestingPaintsNil: Bool {
        layer?.backgroundColor == nil && actionButtons.allSatisfy { $0.layer?.backgroundColor == nil }
    }
    /// The pointer entering or leaving, through the row's own handlers.
    func qaHover(_ inside: Bool) {
        guard let event = NSEvent.enterExitEvent(
            with: inside ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil) else { return }
        if inside { mouseEntered(with: event) } else { mouseExited(with: event) }
    }
    func qaPressSendNow() { sendNowButton.performClick(nil) }
    func qaPressEdit() { editButton.performClick(nil) }
    func qaPressRemove() { removeButton.performClick(nil) }
}
