import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

@MainActor
final class SharedAreaCaptureWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let content: SharedAreaCaptureView
    var onClose: (() -> Void)?
    init(coordinator: SharedAreaCaptureCoordinator) {
        content = SharedAreaCaptureView(coordinator: coordinator)
        window = CollaborationWindow(contentRect: .init(x: 0, y: 0, width: 780, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Review sharing"
        window.minSize = .init(width: 680, height: 780)
        window.isReleasedWhenClosed = false; window.contentView = content; window.delegate = self
        window.initialFirstResponder = content.initialKeyView
        content.onRequestClose = { [weak self] in self?.window.performClose(nil) }
        window.center()
    }
    func show() { CollaborationWindow.present(window) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard content.coordinator.canClose else { content.explainPendingDelivery(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        content.stop()
        let controller = content.coordinator.controller
        Task { await controller.close() }
        onClose?()
    }
}

/// One content reader and one miniature layout renderer serve the complete
/// review. The source picker pages its choices rather than retaining a row view
/// or constructing a popover entry for every tile in a large workspace.
@MainActor
final class SharedAreaCaptureView: NSView, TokenThemed, NSTextViewDelegate {
    let coordinator: SharedAreaCaptureCoordinator
    var onRequestClose: (() -> Void)?
    private let title = NSTextField(labelWithString: "Review what you share")
    private let explanation = NSTextField(wrappingLabelWithString: "Choose which notes become shared content and which agents become observations. Source tiles and code stay in their owner's checkout.")
    private let summary = NSTextField(labelWithString: "")
    let sourceChoice = ChoiceButton(title: "Selected tiles")
    private let pageBack = ComposerActionButton(presentation: CollaborationHubView.action("Previous", symbol: "chevron.left"))
    private let pageNext = ComposerActionButton(presentation: CollaborationHubView.action("Next", symbol: "chevron.right"))
    let modeChoice = ChoiceButton(title: "Choose sharing mode")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let reader = NSTextView()
    private let readerScroll = NSScrollView()
    private let layoutLabel = NSTextField(labelWithString: "Shared arrangement")
    private let layoutPreview = SharedAreaCaptureLayoutView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = ComposerActionButton(presentation: CollaborationHubView.action("Refresh review", symbol: "arrow.clockwise"))
    private let closeButton = ComposerActionButton(presentation: CollaborationHubView.action("Cancel", symbol: "xmark"))
    private let shareButton = ComposerActionButton(presentation: CollaborationHubView.action("Share selection", symbol: "person.2"))
    private var selectedSource: SharedAreaPublication.SourceKey?
    private var page = 0
    private let pageSize = 40
    private var task: Task<Void, Never>?
    private(set) var isStopped = false
    private var lastAdmission: Admission?
    private struct Admission: Equatable {
        let status: SharedAreaController.Status
        let canSubmit: Bool
        let submitting: Bool
    }

    /// The first stop when the review window opens.
    var initialKeyView: NSView { sourceChoice }
    override func keyDown(with event: NSEvent) {
        if !CollaborationKeyLoop.handleTab(event, in: window) { super.keyDown(with: event) }
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        CollaborationKeyLoop.moveFocus(from: textView, command: commandSelector)
    }
    init(coordinator: SharedAreaCaptureCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .init(x: 0, y: 0, width: 780, height: 800))
        wantsLayer = true
        for view in [title, explanation, summary, sourceChoice, pageBack, pageNext, modeChoice, detail,
                     readerScroll, layoutLabel, layoutPreview, message, refreshButton, closeButton, shareButton] { addSubview(view) }
        title.font = .token(.title)
        for label in [explanation, detail, message] { label.font = .token(.body); label.isSelectable = true }
        for label in [summary, layoutLabel] { label.font = .token(.label) }
        message.setAccessibilityLabel("Sharing review status")
        sourceChoice.setAccessibilityLabel("Tile to review")
        modeChoice.setAccessibilityLabel("Sharing mode")
        reader.isEditable = false; reader.isSelectable = true; reader.isRichText = false
        reader.isVerticallyResizable = true; reader.isHorizontallyResizable = false
        reader.minSize = .zero; reader.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        reader.autoresizingMask = [.width]; reader.textContainer?.widthTracksTextView = true
        reader.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        reader.textContainerInset = .init(width: Space.m, height: Space.m)
        reader.setAccessibilityLabel("Captured content to share")
        reader.delegate = self
        CollaborationKeyLoop.link([sourceChoice, pageBack, pageNext, modeChoice, reader, refreshButton, closeButton, shareButton])
        readerScroll.documentView = reader; readerScroll.hasVerticalScroller = true
        readerScroll.drawsBackground = false; readerScroll.borderType = .noBorder
        sourceChoice.onSelection = { [weak self] item in
            guard let self, let row = coordinator.review.rows.first(where: { Self.key($0.source) == item.id }) else { return }
            selectedSource = row.source; refreshSelected()
        }
        modeChoice.onSelection = { [weak self] item in
            guard let self, let source = selectedSource, let mode = Self.mode(item.id) else { return }
            do { try coordinator.setMode(mode, for: source) }
            catch { show(error) }
        }
        pageBack.target = self; pageBack.action = #selector(previousPage)
        pageNext.target = self; pageNext.action = #selector(nextPage)
        refreshButton.target = self; refreshButton.action = #selector(refreshReview)
        closeButton.target = self; closeButton.action = #selector(closeReview)
        shareButton.target = self; shareButton.action = #selector(shareSelection)
        coordinator.onChange = { [weak self] in self?.refresh() }
        // This review owns a separate area controller, never the controller
        // mounted in a shared scene. Its connection lifetime is review-local.
        coordinator.controller.onChange = { [weak self] in self?.refreshAdmission() }
        setAccessibilityRole(.group); setAccessibilityLabel("Review sharing")
        refresh(); applyTokens()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    func stop() {
        isStopped = true; coordinator.onChange = nil; coordinator.controller.onChange = nil
        task?.cancel(); task = nil
    }
    func explainPendingDelivery() { coordinator.cancel() }

    private func refresh() {
        guard !isStopped else { return }
        let rows = coordinator.review.rows
        let pages = max(1, (rows.count + pageSize - 1) / pageSize)
        page = min(page, pages - 1)
        let start = page * pageSize, end = min(rows.count, start + pageSize)
        let currentRows = Array(rows[start..<end])
        if !currentRows.contains(where: { $0.source == selectedSource }) { selectedSource = currentRows.first?.source }
        sourceChoice.items = currentRows.enumerated().map { offset, row in
            ChoiceItem(id: Self.key(row.source), title: "\(start + offset + 1). \(row.localTitle.isEmpty ? row.tileKind.displayName : row.localTitle)", detail: Self.disposition(row))
        }
        sourceChoice.selectedID = selectedSource.map(Self.key)
        summary.stringValue = "\(coordinator.readyCount) included · \(coordinator.pendingCount) need a choice · \(coordinator.excludedCount) excluded · page \(page + 1) of \(pages)"
        refreshActions()
        message.stringValue = coordinator.message
        layoutPreview.documentEdits = coordinator.review.manifest.edits
        layoutLabel.stringValue = "Shared arrangement · \(coordinator.readyCount) included objects"
        if coordinator.readyCount > 128 { layoutLabel.stringValue += " · preview shows first 128" }
        refreshSelected()
    }
    private func refreshAdmission() {
        guard !isStopped else { return }
        let current = Admission(status: coordinator.controller.status, canSubmit: coordinator.controller.canSubmit,
            submitting: coordinator.controller.isSubmitting)
        guard current != lastAdmission else { return }
        lastAdmission = current
        refreshActions()
        modeChoice.isEnabled = coordinator.canEditReview
    }
    private func refreshActions() {
        let heldFocus = CollaborationKeyLoop.holdFocus(in: window)
        defer { CollaborationKeyLoop.restoreFocus(heldFocus, in: window) }
        let pages = max(1, (coordinator.review.rows.count + pageSize - 1) / pageSize)
        let reviewing = coordinator.state == .reviewing
        sourceChoice.isEnabled = reviewing
        pageBack.presentation = CollaborationHubView.action("Previous", symbol: "chevron.left", enabled: reviewing && page > 0)
        pageNext.presentation = CollaborationHubView.action("Next", symbol: "chevron.right", enabled: reviewing && page + 1 < pages)
        refreshButton.presentation = CollaborationHubView.action("Refresh review", symbol: "arrow.clockwise", enabled: reviewing)
        closeButton.presentation = CollaborationHubView.action(coordinator.state == .published ? "Close" : "Cancel", symbol: "xmark", enabled: coordinator.canClose)
        shareButton.presentation = CollaborationHubView.action(coordinator.state == .uncertain ? "Check delivery" : "Share selection", symbol: coordinator.state == .uncertain ? "arrow.clockwise" : "person.2",
            enabled: coordinator.state == .uncertain || coordinator.canConfirm, loading: coordinator.state == .submitting)
    }
    private func refreshSelected() {
        let heldFocus = CollaborationKeyLoop.holdFocus(in: window)
        defer { CollaborationKeyLoop.restoreFocus(heldFocus, in: window) }
        guard let row = coordinator.review.rows.first(where: { $0.source == selectedSource }) else {
            modeChoice.items = []; reader.string = ""; detail.stringValue = "No tile is selected."; return
        }
        var items = [ChoiceItem(id: "review", title: "Choose what to share", enabled: false)]
        switch row.tileKind {
        case .note:
            items += [ChoiceItem(id: "agreement", title: "Agreement snapshot", detail: "A captured revision teammates can discuss and revise"),
                      ChoiceItem(id: "discussion", title: "Discussion snapshot", detail: "Captured note text as the first shared message")]
        case .managedAgent:
            items.append(ChoiceItem(id: "agent", title: "Agent observation", detail: "Host-owned reference; history excluded, control needs a separate handoff"))
        case .diffReview:
            items += [ChoiceItem(id: "artifact", title: "Diff snapshot", detail: "These changes as they are now; untracked files are not included"),
                      ChoiceItem(id: "artifact-untracked", title: "Diff snapshot with untracked files", detail: "Also includes every untracked, unignored file")]
        case .file:
            items.append(ChoiceItem(id: "artifact", title: "File snapshot", detail: "The saved file as it is now; teammates cannot edit your copy"))
        default: break
        }
        items.append(ChoiceItem(id: "omit", title: "Keep private", detail: "Exclude this tile from the shared arrangement"))
        modeChoice.items = items
        modeChoice.selectedID = coordinator.modes[row.source].map(Self.modeID) ?? "review"
        // ChoiceButton selects its first enabled entry by default. A neutral
        // trigger is essential: merely opening review must never opt in a note.
        if coordinator.modes[row.source] == nil { modeChoice.setPresentationTitle("Choose what to share") }
        modeChoice.isEnabled = coordinator.canEditReview
        detail.stringValue = Self.disposition(row)
        switch row.disposition {
        case .ready(.agreement), .ready(.discussion): reader.string = row.previewText ?? ""
        case .ready(.artifact), .unsupported(.unavailableArtifact):
            reader.string = coordinator.artifactSummary(row.source) ?? "Choose a snapshot mode to capture it."
        case .ready(.agentObservation): reader.string = "This shares an opaque reference to the host's agent. Agent history, prompts, terminal contents, files and checkout changes are not included. Execution stays on the original host; control needs a separate accepted handoff."
        case .omitted: reader.string = "This tile stays private and will not appear in the shared arrangement."
        case .unsupported: reader.string = "This tile cannot be published in this version. It is excluded from the shared arrangement."
        default: reader.string = "Choose a sharing mode to preview exactly what becomes shared."
        }
    }
    @objc private func previousPage() { guard page > 0 else { return }; page -= 1; selectedSource = nil; refresh() }
    @objc private func nextPage() { guard (page + 1) * pageSize < coordinator.review.rows.count else { return }; page += 1; selectedSource = nil; refresh() }
    @objc private func refreshReview() {
        do { try coordinator.refreshReview() } catch { show(error) }
    }
    @objc private func closeReview() {
        guard coordinator.canClose else { explainPendingDelivery(); return }
        if coordinator.state != .published { coordinator.cancel() }
        onRequestClose?()
    }
    @objc private func shareSelection() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            if coordinator.state == .uncertain { await coordinator.checkDelivery() } else { await coordinator.confirm() }
            task = nil
        }
    }
    private func show(_ error: any Error) { message.stringValue = SharedAreaCaptureCoordinator.message(for: error) }
    private static func key(_ value: SharedAreaPublication.SourceKey) -> String { "\(value.projectID.uuidString)/\(value.tileID.uuidString)" }
    private static func mode(_ value: String) -> SharedAreaInventory.Mode? {
        switch value {
        case "agent": .agentObservation; case "agreement": .agreement; case "discussion": .discussion; case "omit": .omit
        case "artifact": .artifact; case "artifact-untracked": .artifactWithUntracked; default: nil
        }
    }
    private static func modeID(_ value: SharedAreaInventory.Mode) -> String {
        switch value { case .agentObservation: "agent"; case .agreement: "agreement"; case .discussion: "discussion"; case .artifact: "artifact"; case .artifactWithUntracked: "artifact-untracked"; case .liveTile: "live"; case .omit: "omit" }
    }
    private static func disposition(_ row: SharedAreaPublication.Row) -> String {
        switch row.disposition {
        case .needsReview: return "\(row.tileKind.displayName) · needs your choice"
        case .omitted: return "\(row.tileKind.displayName) · kept private"
        case .unsupported(.unavailableAgent): return "Managed agent unavailable · excluded"
        case .unsupported(.unavailableContentRevision): return "Note content unavailable · excluded"
        case .unsupported(.unavailableArtifact): return "\(row.tileKind.displayName) · snapshot not captured yet"
        case .ready(.artifact): return "Snapshot · exact bytes as captured now; your checkout is not shared"
        case .unsupported: return "\(row.tileKind.displayName) · sharing unsupported; excluded"
        case .ready(.agentObservation): return "Agent observation · history excluded; separate handoff for control"
        case .ready(.agreement): return "Agreement · captured text, independent of the source note"
        case .ready(.discussion): return "Discussion · captured first message"
        case .ready: return "Included"
        }
    }

    override func layout() {
        super.layout()
        let margin = CGFloat(Space.xl), width = max(1, bounds.width - 2 * margin)
        func place(_ view: NSView, y: CGFloat, h: CGFloat, left: CGFloat = 0, w: CGFloat? = nil) {
            let frame = NSRect(x: margin + left, y: y, width: w ?? width, height: h)
            if view.frame != frame { view.frame = frame }
        }
        place(title, y: 22, h: 28); place(explanation, y: 58, h: 50); place(summary, y: 116, h: 22)
        place(sourceChoice, y: 146, h: 32, w: width - 210)
        place(pageBack, y: 146, h: 32, left: width - 200, w: 95); place(pageNext, y: 146, h: 32, left: width - 95, w: 95)
        place(modeChoice, y: 190, h: 32, w: min(width, 330)); place(detail, y: 232, h: 38)
        place(readerScroll, y: 280, h: max(110, bounds.height - 620))
        let layoutTop = max(400, bounds.height - 330)
        place(layoutLabel, y: layoutTop, h: 20); place(layoutPreview, y: layoutTop + 28, h: 130)
        place(message, y: bounds.height - 160, h: 88)
        place(refreshButton, y: bounds.height - 56, h: 32, w: 150)
        place(closeButton, y: bounds.height - 56, h: 32, left: width - 280, w: 100)
        place(shareButton, y: bounds.height - 56, h: 32, left: width - 170, w: 170)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        for label in [title, layoutLabel] { label.textColor = TextToken.textPrimary.color.nsColor(in: self) }
        for label in [explanation, summary, detail, message] { label.textColor = TextToken.textSecondary.color.nsColor(in: self) }
        reader.font = .token(.body); reader.textColor = TextToken.textPrimary.color.nsColor(in: self)
        reader.backgroundColor = SurfaceToken.tileBody.color.nsColor(in: self)
        layoutPreview.needsDisplay = true
    }
}

@MainActor
private final class SharedAreaCaptureLayoutView: NSView {
    var documentEdits: [SharedArea.Edit] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(in: self).setFill(); bounds.fill()
        let positions = documentEdits.compactMap { edit -> SharedArea.Position? in if case .admit(_, let position) = edit { return position }; return nil }
        guard let first = positions.first else { return }
        var union = NSRect(x: first.rect.x, y: first.rect.y, width: first.rect.width, height: first.rect.height)
        for position in positions.dropFirst() { union = union.union(.init(x: position.rect.x, y: position.rect.y, width: position.rect.width, height: position.rect.height)) }
        let zoom = min((bounds.width - 20) / max(1, union.width), (bounds.height - 20) / max(1, union.height))
        let offset = NSPoint(x: bounds.midX - union.midX * zoom, y: bounds.midY - union.midY * zoom)
        TextToken.textSecondary.color.nsColor(in: self).setStroke()
        // The mini-map is a review aid; the full membership count remains
        // explicit above it when a capture exceeds this drawing budget.
        for position in positions.prefix(128) {
            let rect = NSRect(x: position.rect.x * zoom + offset.x, y: position.rect.y * zoom + offset.y,
                width: max(1, position.rect.width * zoom), height: max(1, position.rect.height * zoom))
            let path = NSBezierPath(rect: rect); path.lineWidth = 1; path.stroke()
        }
    }
}
