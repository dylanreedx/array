import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// A dedicated portable scene. Nothing here knows how to construct a local tile,
/// acquire a project, arm its creation scope, or start/stop an agent executor.
@MainActor
final class SharedAreaSceneView: NSView, TokenThemed, NSTextViewDelegate {
    let controller: SharedAreaController
    let person: SharedArea.ID<SharedArea.Person>
    var onRequestInvite: (() -> Void)?
    private(set) var mountCount = 0
    private(set) var isMounted = false
    private(set) var selectedObject: SharedArea.ID<SharedArea.Object>?
    var draftText: String { editor.string }
    var selectedEntryText: String { reader.string }

    private let titleLabel = NSTextField(labelWithString: "Shared workspace")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "Select an object")
    private let entryLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let actions = ChoiceButton(title: "Workspace")
    private let objectNavigator = ChoiceButton(title: "Objects")
    private let history = ChoiceButton(title: "History")
    private let reader = NSTextView()
    private let readerScroll = NSScrollView()
    private let editor = NSTextView()
    private let editorScroll = NSScrollView()
    private let postButton = ComposerActionButton(presentation: .init(primaryAction: .send, title: "Post", symbolName: "arrow.up",
        accessibilityLabel: "Post to discussion", isEnabled: false, isLoading: false, secondaryActions: []))
    private let canvas = SharedAreaSceneCanvas(frame: .zero)
    private var localCamera = SharedAreaLocalView()
    private var cameraDirty = false
    private var cameraTimer: Timer?
    private var draftTimer: Timer?
    private var activeDraft: SharedAreaLocalDraft?
    private var draftDirty = false
    private var knownDocument: SharedArea.Document?
    private var readerIndex = 0
    private var displayedContextRevision: SharedArea.ID<SharedArea.Revision>?
    private var followsLatestEntry = true
    private var uncertainCommand: SharedArea.Command?
    private var uncertainDraft: SharedAreaLocalDraft?
    private var pendingCreatedObject: SharedArea.ID<SharedArea.Object>?
    private var actionTask: Task<Void, Never>?
    private var mountGeneration = UUID()
    private var lastControlsKey: ControlsKey?
    private struct ControlsKey: Equatable {
        let status: SharedAreaController.Status
        let submitting: Bool
        let canSubmit: Bool
        let epoch: Int64?
        let role: String?
        let documentRevision: UInt64?
        let selected: SharedArea.ID<SharedArea.Object>?
        let hasText: Bool
        let uncertain: Bool
        let camera: SharedAreaLocalView
    }

    override var isFlipped: Bool { true }

    init(controller: SharedAreaController, person: SharedArea.ID<SharedArea.Person>) {
        self.controller = controller; self.person = person
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = .token(.title)
        for label in [statusLabel, entryLabel, messageLabel] { label.font = .token(.label); label.lineBreakMode = .byTruncatingTail }
        detailLabel.font = .token(.title); detailLabel.lineBreakMode = .byTruncatingTail
        configureText(reader, scroll: readerScroll, editable: false)
        configureText(editor, scroll: editorScroll, editable: true)
        editor.delegate = self
        editor.setAccessibilityLabel("Private discussion or agreement draft")
        reader.setAccessibilityLabel("Selected shared entry")
        actions.popoverPresentation = .commands
        actions.keepsSelectionForItem = { _ in false }
        actions.onSelection = { [weak self] item in self?.performAction(item.id) }
        objectNavigator.onSelection = { [weak self] item in
            guard let self, let id = UUID(uuidString: item.id),
                  self.canvas.visibleObjects.contains(where: { $0.id.rawValue == id }) else { return }
            do { try self.selectObject(.init(id)) } catch { self.showPrivateSaveFailure() }
        }
        history.popoverPresentation = .commands
        history.keepsSelectionForItem = { _ in false }
        history.onSelection = { [weak self] item in self?.navigateHistory(item.id) }
        postButton.target = self; postButton.action = #selector(postFromButton(_:))
        canvas.onSelect = { [weak self] object in
            do { try self?.selectObject(object) } catch { self?.showPrivateSaveFailure() }
        }
        canvas.onCamera = { [weak self] camera, complete in self?.navigate(camera, complete: complete) }
        canvas.onCycleSelection = { [weak self] backwards in
            do { try self?.selectNextObject(backwards: backwards) } catch { self?.showPrivateSaveFailure() }
        }
        for view in [canvas, titleLabel, statusLabel, objectNavigator, actions, detailLabel, entryLabel, history, readerScroll, editorScroll, postButton, messageLabel] {
            addSubview(view)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Shared workspace")
        applyTokens()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called by the production scene mount. The window owner owns open/close.
    func mount() {
        guard !isMounted else { return }
        mountGeneration = UUID(); lastControlsKey = nil
        isMounted = true; mountCount += 1
        localCamera = controller.view; selectedObject = localCamera.focusedObject
        controller.onChange = { [weak self] in self?.refresh() }
        refresh()
    }
    func unmount() {
        guard isMounted else { return }
        mountGeneration = UUID()
        do { try prepareToClose() } catch { showPrivateSaveFailure() }
        isMounted = false
        controller.onChange = nil
        cameraTimer?.invalidate(); cameraTimer = nil
        draftTimer?.invalidate(); draftTimer = nil
        actionTask?.cancel(); actionTask = nil
        if uncertainCommand == nil { pendingCreatedObject = nil }
        knownDocument = nil
        canvas.install(document: nil, camera: localCamera, selected: nil)
        reader.string = ""; entryLabel.stringValue = ""; detailLabel.stringValue = "Closed shared workspace"
        editor.isEditable = false; postButton.isEnabled = false
    }

    override func layout() {
        super.layout()
        let margin = CGFloat(Space.l), header: CGFloat = 66
        let inspector = min(340, max(270, bounds.width * 0.34))
        let split = max(180, bounds.width - inspector)
        setFrame(titleLabel, .init(x: margin, y: 11, width: max(120, bounds.width - 340), height: 22))
        setFrame(statusLabel, .init(x: margin, y: 36, width: max(120, bounds.width - 340), height: 17))
        setFrame(objectNavigator, .init(x: bounds.width - 288, y: 17, width: 130, height: ChoiceButton.controlHeight))
        setFrame(actions, .init(x: bounds.width - 146, y: 17, width: 130, height: ChoiceButton.controlHeight))
        setFrame(canvas, .init(x: 0, y: header, width: split, height: max(0, bounds.height - header)))
        let x = split + margin, width = max(1, bounds.width - x - margin)
        setFrame(detailLabel, .init(x: x, y: header + 12, width: width, height: 22))
        setFrame(entryLabel, .init(x: x, y: header + 39, width: width, height: 18))
        setFrame(history, .init(x: x, y: header + 63, width: min(148, width), height: ChoiceButton.controlHeight))
        let editorTop = max(header + 220, bounds.height - 190)
        setFrame(readerScroll, .init(x: x, y: header + 106, width: width, height: max(48, editorTop - header - 118)))
        setFrame(editorScroll, .init(x: x, y: editorTop, width: width, height: 112))
        setFrame(postButton, .init(x: x, y: editorTop + 122, width: min(width, 160), height: ComposerActionButton.controlHeight))
        setFrame(messageLabel, .init(x: x, y: editorTop + 161, width: width, height: 17))
    }

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        detailLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        for label in [statusLabel, entryLabel, messageLabel] { label.textColor = TextToken.textSecondary.color.nsColor(in: self) }
        for textView in [reader, editor] {
            textView.font = .token(.body)
            textView.textColor = TextToken.textPrimary.color.nsColor(in: self)
            textView.backgroundColor = SurfaceToken.tileBody.color.nsColor(in: self)
            textView.insertionPointColor = TextToken.textPrimary.color.nsColor(in: self)
        }
        canvas.needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }

    /// Scene-relative frames of the cards actually eligible to be drawn. It is
    /// also the geometry seam used by native interaction witnesses.
    func renderedFrame(for object: SharedArea.ID<SharedArea.Object>) -> NSRect? {
        guard isMounted, let rect = canvas.renderedFrame(for: object) else { return nil }
        return canvas.convert(rect, to: self)
    }
    func setCamera(_ value: SharedAreaLocalView) throws {
        guard [value.x, value.y, value.zoom].allSatisfy(\.isFinite), value.zoom > 0 else { throw SharedArea.Failure.invalidGeometry }
        localCamera = value; cameraDirty = true
        try controller.setView(value)
        cameraDirty = false
        canvas.setCamera(value)
    }
    func selectObject(_ object: SharedArea.ID<SharedArea.Object>?) throws {
        try prepareToClose()
        var candidate = localCamera
        candidate.focusedObject = object
        // A failed focus write leaves the previous target and its draft intact.
        try controller.setView(candidate)
        selectedObject = object
        localCamera = candidate
        activeDraft = object.flatMap { wanted in controller.drafts.last(where: { $0.object == wanted }) }
        editor.string = activeDraft?.text ?? ""
        draftDirty = false; followsLatestEntry = true
        canvas.setSelection(object)
        refreshReader()
        refreshControls()
    }
    func selectNextObject(backwards: Bool = false) throws {
        let objects = canvas.visibleObjects.map(\.id)
        guard !objects.isEmpty else { return }
        let target: Int
        if let selectedObject, let current = objects.firstIndex(of: selectedObject) {
            target = (current + (backwards ? objects.count - 1 : 1)) % objects.count
        } else { target = backwards ? objects.count - 1 : 0 }
        try selectObject(objects[target])
    }
    /// Shares the exact visible-object hit routine used by mouseDown.
    func object(at point: NSPoint) -> SharedArea.ID<SharedArea.Object>? {
        guard isMounted else { return nil }
        return canvas.object(at: canvas.convert(point, from: self))
    }
    func fitContent() throws {
        guard let positions = controller.document?.positions, let first = positions.first else { return }
        var rect = NSRect(x: first.rect.x, y: first.rect.y, width: first.rect.width, height: first.rect.height)
        for position in positions.dropFirst() { rect = rect.union(.init(x: position.rect.x, y: position.rect.y, width: position.rect.width, height: position.rect.height)) }
        let width = max(1, canvas.bounds.width - 64), height = max(1, canvas.bounds.height - 64)
        let zoom = max(0.1, min(2, min(width / rect.width, height / rect.height)))
        try setCamera(.init(x: rect.midX - canvas.bounds.width / zoom / 2,
            y: rect.midY - canvas.bounds.height / zoom / 2, zoom: zoom, focusedObject: selectedObject))
    }

    func createObject(kind: SharedArea.Kind) async {
        guard isMounted, uncertainCommand == nil, !controller.isSubmitting, controller.canSubmit,
              kind == .discussion || kind == .agreement, let document = controller.document else { return }
        do { try prepareToClose() } catch { showPrivateSaveFailure(); return }
        let item = SharedArea.Item(id: .init(), kind: kind)
        let rect = SharedArea.Rect(x: localCamera.x + 32 / localCamera.zoom, y: localCamera.y + 32 / localCamera.zoom, width: 480, height: 360)
        let z = document.positions.map(\.z).max().map { $0 == Int.max ? $0 : $0 + 1 } ?? 0
        let command = SharedArea.Command(area: document.id, expectedRevision: document.revision,
            edits: [.admit(item, .init(id: .init(), object: item.id, rect: rect, z: z))])
        pendingCreatedObject = item.id
        await finishSubmission(command, draft: nil)
    }

    func submitDraft() async {
        guard isMounted else { return }
        if let uncertainCommand { await finishSubmission(uncertainCommand, draft: uncertainDraft); return }
        guard let document = controller.document, let object = selectedObject,
              let item = document.items.first(where: { $0.id == object }),
              item.kind == .discussion || item.kind == .agreement else { return }
        guard !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try saveCurrentDraft() } catch { showPrivateSaveFailure(); return }
        guard let draft = activeDraft else { return }
        let edit: SharedArea.Edit = item.kind == .discussion
            ? .post(.init(id: .init(), object: object, author: person, text: draft.text))
            : .context(.init(id: .init(), object: object, parent: draft.basedOn, author: person, text: draft.text))
        await finishSubmission(.init(area: document.id, expectedRevision: document.revision, edits: [edit]), draft: draft)
    }

    func setDraftText(_ text: String) {
        guard editor.isEditable else { return }
        editor.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    }

    func textDidChange(_ notification: Notification) {
        guard isMounted else { return }
        draftDirty = true
        if activeDraft == nil, let object = selectedObject {
            activeDraft = .init(object: object, basedOn: displayedContextRevision, text: editor.string)
        }
        draftTimer?.invalidate()
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.saveCurrentDraft() } catch { self.showPrivateSaveFailure() }
            }
        }
        refreshControls()
    }

    private func refresh() {
        guard isMounted else { return }
        if !cameraDirty { localCamera = controller.view }
        let current = controller.document
        let changed = current?.id != knownDocument?.id || current?.revision != knownDocument?.revision
        if changed {
            knownDocument = current
            canvas.install(document: current, camera: localCamera, selected: selectedObject)
            if activeDraft == nil, let object = selectedObject {
                activeDraft = controller.drafts.last(where: { $0.object == object })
                editor.string = activeDraft?.text ?? ""
            }
            refreshReader()
        } else { canvas.setCamera(localCamera) }
        statusLabel.stringValue = statusText
        refreshControls()
    }
    private var statusText: String {
        switch controller.status {
        case .cached: return "Cached · connect to edit"
        case .connecting: return "Connecting…"
        case .connected: return controller.scope?.role == .viewer ? "Connected · view only" : "Connected"
        case .reconnecting: return "Reconnecting · read-only"
        case .unavailable: return "Shared workspace unavailable"
        case .closed: return "Closed"
        }
    }
    private func refreshControls() {
        let key = ControlsKey(status: controller.status, submitting: controller.isSubmitting, canSubmit: controller.canSubmit,
            epoch: controller.scope?.epoch, role: controller.scope?.role.rawValue,
            documentRevision: controller.document?.revision, selected: selectedObject,
            hasText: !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            uncertain: uncertainCommand != nil, camera: controller.view)
        guard key != lastControlsKey else { return }
        lastControlsKey = key
        let writable = controller.canSubmit && !controller.isSubmitting
        objectNavigator.items = canvas.visibleObjects.map { object in
            .init(id: object.id.rawValue.uuidString, title: object.title + " · " + String(object.id.rawValue.uuidString.prefix(4)))
        }
        objectNavigator.selectedID = selectedObject?.rawValue.uuidString
        objectNavigator.selectedTitleOverride = "Objects"
        objectNavigator.isEnabled = !objectNavigator.items.isEmpty
        actions.items = [
            .init(id: "discussion", title: "New discussion", icon: .system("bubble.left"), enabled: writable && uncertainCommand == nil),
            .init(id: "agreement", title: "New agreement", icon: .system("doc.text"), enabled: writable && uncertainCommand == nil),
            .init(id: "fit", title: "Fit shared content", icon: .system("arrow.up.left.and.arrow.down.right"), enabled: controller.document?.positions.isEmpty == false),
            .init(id: "invite", title: "Invite collaborator…", icon: .system("person.badge.plus"), enabled: controller.status == .connected && controller.scope?.allows(.manageSharing) == true)
        ]
        actions.setPresentationTitle("Workspace")
        let kind = selectedObject.flatMap { object in knownDocument?.items.first(where: { $0.id == object })?.kind }
        let canCompose = kind == .discussion || kind == .agreement
        editor.isEditable = canCompose && uncertainCommand == nil
        postButton.presentation = .init(primaryAction: .send,
            title: uncertainCommand != nil ? "Check delivery" : kind == .agreement ? "Save revision" : "Post",
            symbolName: uncertainCommand != nil ? "arrow.clockwise" : "arrow.up",
            accessibilityLabel: uncertainCommand != nil ? "Check the previous delivery outcome" : kind == .agreement ? "Save an agreement revision" : "Post to discussion",
            isEnabled: writable && (uncertainCommand != nil || (canCompose && !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)),
            isLoading: controller.isSubmitting, secondaryActions: [])
    }
    private func refreshReader() {
        guard let document = knownDocument, let object = selectedObject,
              let item = document.items.first(where: { $0.id == object }) else {
            detailLabel.stringValue = activeDraft == nil ? "Select an object" : "Private draft"
            entryLabel.stringValue = ""; reader.string = ""; history.items = []; displayedContextRevision = nil
            return
        }
        detailLabel.stringValue = Self.title(for: item.kind)
        let entries: [String]
        switch item.kind {
        case .discussion: entries = document.posts.filter { $0.object == object }.map(\.text)
        case .agreement: entries = document.contexts.filter { $0.object == object }.map(\.text)
        case .agentObservation:
            entries = ["This is an observation of an agent on its publishing host. Transcript history and execution controls are not available in this shared view yet."]
        case .artifact: entries = ["This artifact's content is not available in this view."]
        }
        if followsLatestEntry { readerIndex = max(0, entries.count - 1) }
        readerIndex = min(max(0, readerIndex), max(0, entries.count - 1))
        let revisions = item.kind == .agreement ? document.contexts.filter { $0.object == object }.map(\.id) : []
        displayedContextRevision = revisions.indices.contains(readerIndex) ? revisions[readerIndex] : nil
        let text = entries.isEmpty ? (item.kind == .agreement ? "No agreement revision yet." : "No discussion messages yet.") : entries[readerIndex]
        if reader.string != text { reader.string = text; reader.scrollRangeToVisible(.init(location: 0, length: 0)) }
        entryLabel.stringValue = entries.isEmpty ? "" : "Entry \(readerIndex + 1) of \(entries.count) · full entry"
        history.items = [
            .init(id: "earlier", title: "Earlier entry", enabled: readerIndex > 0),
            .init(id: "later", title: "Later entry", enabled: readerIndex + 1 < entries.count),
            .init(id: "latest", title: "Latest entry", enabled: !entries.isEmpty)
        ]
        history.setPresentationTitle("History")
    }
    private func navigateHistory(_ action: String) {
        if action == "earlier" { readerIndex = max(0, readerIndex - 1); followsLatestEntry = false }
        if action == "later" { readerIndex += 1; followsLatestEntry = false }
        if action == "latest" { followsLatestEntry = true }
        refreshReader()
    }
    private func performAction(_ action: String) {
        switch action {
        case "discussion", "agreement":
            actionTask = Task { [weak self] in await self?.createObject(kind: action == "discussion" ? .discussion : .agreement) }
        case "fit": do { try fitContent() } catch { showPrivateSaveFailure() }
        case "invite": onRequestInvite?()
        default: break
        }
    }
    @objc private func postFromButton(_ sender: Any?) { actionTask = Task { [weak self] in await self?.submitDraft() } }
    private func finishSubmission(_ command: SharedArea.Command, draft: SharedAreaLocalDraft?) async {
        let generation = mountGeneration
        let outcome = await controller.submit(command, preserving: draft)
        guard isMounted, generation == mountGeneration else { return }
        switch outcome {
        case .accepted:
            uncertainCommand = nil; uncertainDraft = nil
            messageLabel.stringValue = "Saved"
            if let draft, activeDraft?.id == draft.id, editor.string == draft.text {
                activeDraft = nil; editor.string = ""; draftDirty = false
            }
            if let created = pendingCreatedObject { pendingCreatedObject = nil; try? selectObject(created) }
            followsLatestEntry = true; refreshReader()
        case .rejected(let reason):
            uncertainCommand = nil; uncertainDraft = nil; pendingCreatedObject = nil
            switch reason {
            case .conflict: messageLabel.stringValue = "Workspace changed. Draft retained."
            case .forbidden: messageLabel.stringValue = "Action unavailable. Draft retained."
            default: messageLabel.stringValue = "Could not save. Draft retained."
            }
        case .uncertain:
            uncertainCommand = command; uncertainDraft = draft
            messageLabel.stringValue = "Delivery unknown. Draft retained."
        }
        refreshControls()
    }
    private func saveCurrentDraft() throws {
        draftTimer?.invalidate(); draftTimer = nil
        guard draftDirty, let object = selectedObject else { return }
        var draft = activeDraft ?? .init(object: object, basedOn: displayedContextRevision, text: editor.string)
        draft.text = editor.string
        try controller.saveDraft(draft)
        activeDraft = draft; draftDirty = false
    }
    private func navigate(_ value: SharedAreaLocalView, complete: Bool) {
        localCamera = value; localCamera.focusedObject = selectedObject; cameraDirty = true
        canvas.setCamera(localCamera)
        cameraTimer?.invalidate(); cameraTimer = nil
        if complete {
            do { try setCamera(localCamera) } catch { showPrivateSaveFailure() }
        } else {
            cameraTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    do { try self.setCamera(self.localCamera) } catch { self.showPrivateSaveFailure() }
                }
            }
        }
    }
    /// The window owner can refuse closing if a private draft/view cannot save.
    func prepareToClose() throws {
        try saveCurrentDraft()
        if cameraDirty { try setCamera(localCamera) }
    }
    private func showPrivateSaveFailure() { messageLabel.stringValue = "Could not save private changes" }
    private func configureText(_ text: NSTextView, scroll: NSScrollView, editable: Bool) {
        text.isEditable = editable; text.isSelectable = true; text.isRichText = false
        text.allowsUndo = editable; text.font = .token(.body)
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.minSize = .zero; text.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainerInset = .init(width: 10, height: 10)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false; scroll.drawsBackground = false; scroll.documentView = text
    }
    private func setFrame(_ view: NSView, _ frame: NSRect) { if view.frame != frame { view.frame = frame } }
    static func title(for kind: SharedArea.Kind) -> String {
        switch kind { case .agentObservation: return "Agent observation"; case .artifact: return "Artifact"; case .discussion: return "Discussion"; case .agreement: return "Working agreement" }
    }
}

/// One bounded drawing surface. Content is prepared only when the durable
/// document changes, never in layout or in response to a pointer packet.
@MainActor
private final class SharedAreaSceneCanvas: NSView {
    struct Card {
        let position: SharedArea.Position
        let title: String
        let preview: String
    }
    var onSelect: ((SharedArea.ID<SharedArea.Object>?) -> Void)?
    var onCamera: ((SharedAreaLocalView, Bool) -> Void)?
    var onCycleSelection: ((Bool) -> Void)?
    private var cards: [Card] = []
    private var hasDocument = false
    private var camera = SharedAreaLocalView()
    private var selected: SharedArea.ID<SharedArea.Object>?
    private var panStart: (point: NSPoint, camera: SharedAreaLocalView)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Shared objects")
        setAccessibilityHelp("Tab selects the next visible object. Shift-Tab selects the previous object. Escape returns to the workspace controls.")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func install(document: SharedArea.Document?, camera: SharedAreaLocalView, selected: SharedArea.ID<SharedArea.Object>?) {
        self.camera = camera; self.selected = selected
        hasDocument = document != nil
        let items = Dictionary(uniqueKeysWithValues: (document?.items ?? []).map { ($0.id, $0) })
        let posts = Dictionary(grouping: document?.posts ?? [], by: \.object)
        let contexts = Dictionary(grouping: document?.contexts ?? [], by: \.object)
        cards = (document?.positions ?? []).sorted { $0.z == $1.z ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.z < $1.z }.compactMap { position in
            guard let item = items[position.object] else { return nil }
            let body: String
            switch item.kind {
            case .agentObservation: body = "Agent stays on its publishing host.\nTranscript history is not shared yet."
            case .artifact: body = "Artifact content unavailable."
            case .discussion: body = posts[item.id]?.last?.text ?? "No messages yet."
            case .agreement: body = contexts[item.id]?.last?.text ?? "No agreement revision yet."
            }
            return Card(position: position, title: SharedAreaSceneView.title(for: item.kind), preview: String(body.prefix(800)))
        }
        needsDisplay = true
    }
    func setCamera(_ value: SharedAreaLocalView) { guard value != camera else { return }; camera = value; needsDisplay = true }
    func setSelection(_ value: SharedArea.ID<SharedArea.Object>?) {
        selected = value; needsDisplay = true
        setAccessibilityValue(cards.first(where: { $0.position.object == value })?.title)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    var visibleObjects: [(id: SharedArea.ID<SharedArea.Object>, title: String)] {
        var seen = Set<SharedArea.ID<SharedArea.Object>>()
        return visibleCards().cards.compactMap { entry in
            guard seen.insert(entry.card.position.object).inserted else { return nil }
            return (entry.card.position.object, entry.card.title)
        }
    }
    private func visibleCards() -> (cards: [(card: Card, frame: NSRect)], omitted: Bool) {
        var result: [(card: Card, frame: NSRect)] = []
        var omitted = false
        for card in cards.reversed() {
            guard let frame = screenFrame(card.position.rect), frame.intersects(bounds) else { continue }
            if result.count == 128 { omitted = true; break }
            result.append((card, frame))
        }
        return (Array(result.reversed()), omitted)
    }
    func renderedFrame(for object: SharedArea.ID<SharedArea.Object>) -> NSRect? {
        visibleCards().cards.first(where: { $0.card.position.object == object })?.frame
    }
    func object(at point: NSPoint) -> SharedArea.ID<SharedArea.Object>? {
        visibleCards().cards.reversed().first(where: { $0.frame.contains(point) })?.card.position.object
    }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.canvas.color.nsColor(in: self).setFill(); bounds.fill()
        if cards.isEmpty {
            draw(hasDocument ? "A shared place for your work" : "Shared content unavailable", rect: bounds.insetBy(dx: 28, dy: 28), role: .title, color: .textPrimary)
            draw(hasDocument ? "Add a discussion or working agreement from Workspace." : "Connect to confirm access to this workspace.", rect: bounds.insetBy(dx: 28, dy: 58), role: .body, color: .textSecondary)
            return
        }
        let visible = visibleCards()
        for (card, frame) in visible.cards {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds).addClip()
            let radius = CGFloat(CornerRole.card.radius)
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            SurfaceToken.tileBody.color.nsColor(in: self).setFill(); path.fill()
            (selected == card.position.object ? LineToken.borderStrong : .border).color.nsColor(in: self).setStroke()
            path.lineWidth = selected == card.position.object ? 2 : 1; path.stroke()
            NSBezierPath(rect: frame.insetBy(dx: 10, dy: 10)).addClip()
            draw(card.title, rect: .init(x: frame.minX + 14, y: frame.minY + 13, width: max(0, frame.width - 28), height: 22), role: .title, color: .textPrimary)
            if camera.zoom >= 0.35 {
                draw(card.preview, rect: .init(x: frame.minX + 14, y: frame.minY + 47, width: max(0, frame.width - 28), height: max(0, frame.height - 86)), role: .body, color: .textPrimary)
                draw("Preview · select to read full entries", rect: .init(x: frame.minX + 14, y: frame.maxY - 27, width: max(0, frame.width - 28), height: 16), role: .label, color: .textSecondary)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if visible.omitted { draw("Showing up to 128 visible objects · zoom in to inspect", rect: .init(x: 16, y: bounds.height - 30, width: bounds.width - 32, height: 18), role: .label, color: .textSecondary) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let object = object(at: point) {
            onSelect?(object)
        } else { onSelect?(nil); panStart = (point, camera) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onCycleSelection?(event.modifierFlags.contains(.shift))
        } else if event.keyCode == 53 {
            window?.selectNextKeyView(self)
        } else { super.keyDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let panStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        var moved = panStart.camera
        moved.x -= (point.x - panStart.point.x) / moved.zoom; moved.y -= (point.y - panStart.point.y) / moved.zoom
        onCamera?(moved, false)
    }
    override func mouseUp(with event: NSEvent) { if panStart != nil { panStart = nil; onCamera?(camera, true) } }
    override func scrollWheel(with event: NSEvent) {
        var moved = camera
        moved.x += event.scrollingDeltaX / moved.zoom; moved.y += event.scrollingDeltaY / moved.zoom
        onCamera?(moved, event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended)
    }
    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var moved = camera
        let areaX = moved.x + point.x / moved.zoom, areaY = moved.y + point.y / moved.zoom
        moved.zoom = min(8, max(0.1, moved.zoom * (1 + event.magnification)))
        moved.x = areaX - point.x / moved.zoom; moved.y = areaY - point.y / moved.zoom
        onCamera?(moved, event.phase == .ended || event.phase == .cancelled)
    }
    private func screenFrame(_ rect: SharedArea.Rect) -> NSRect? {
        let values = [(rect.x - camera.x) * camera.zoom, (rect.y - camera.y) * camera.zoom, rect.width * camera.zoom, rect.height * camera.zoom]
        guard values.allSatisfy(\.isFinite) else { return nil }
        return .init(x: values[0], y: values[1], width: values[2], height: values[3])
    }
    private func draw(_ text: String, rect: NSRect, role: TextRole, color: TextToken) {
        guard rect.width > 0, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: NSFont.token(role), .foregroundColor: color.color.nsColor(in: self), .paragraphStyle: paragraph
        ])
    }
}
