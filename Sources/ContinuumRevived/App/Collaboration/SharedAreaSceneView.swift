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
    var onRequestHandoff: ((SharedArea.ID<SharedArea.Object>) -> Void)? {
        didSet { lastControlsKey = nil; if isMounted { refreshReader(); refreshControls() } }
    }
    var onLocalCameraNavigation: (() -> Void)?
    var onCanvasTransformChange: (() -> Void)?
    var areaCanvasView: NSView { canvas }
    var localViewCamera: SharedAreaLocalView { localCamera }
    var geometryLedgerFile: URL? { geometryLedgerStore?.file }
    var hasPendingGeometry: Bool { pendingGeometry != nil }
    private(set) var mountCount = 0
    /// Writes of this person's private camera/focus. Follow traffic must not add any.
    private(set) var privateViewWrites = 0
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
    private(set) lazy var agreementPanel = SharedAreaAgreementView(controller: controller)
    private(set) lazy var freshnessPanel = SharedAreaAgentFreshnessView()
    /// Per-agent agreement freshness and excerpt source checks (COL-14).
    var agentFreshness: SharedAgentFreshnessModel? {
        didSet {
            oldValue?.stopWatchingLedger()
            agentFreshness?.onChange = { [weak self] in self?.refreshFreshness() }
            agentFreshness?.startWatchingLedger()
        }
    }
    private(set) lazy var artifactPanel = SharedAreaArtifactView(controller: controller, person: person)
    private(set) lazy var livePanel = SharedAgentLiveView(controller: controller)
    private var localCamera = SharedAreaLocalView()
    private var cameraDirty = false
    private var cameraTimer: Timer?
    private var draftTimer: Timer?
    private var activeDraft: SharedAreaLocalDraft?
    private var draftDirty = false
    private var knownDocument: SharedArea.Document?
    private var knownHosts: [Collaboration.HostLiveness] = []
    private var readerIndex = 0
    private var displayedContextRevision: SharedArea.ID<SharedArea.Revision>?
    private var followsLatestEntry = true
    private var uncertainCommand: SharedArea.Command?
    private var uncertainDraft: SharedAreaLocalDraft?
    private var pendingCreatedObject: SharedArea.ID<SharedArea.Object>?
    private var actionTask: Task<Void, Never>?
    private var geometryHistory = SharedAreaGeometryHistory()
    private var pendingGeometry: SharedAreaGeometryHistory.Mutation?
    private var geometryLedgerStore: SharedAreaGeometryLedgerStore?
    private var geometryLedger: SharedAreaGeometryLedger?
    private var geometryUnavailable = false
    private var geometryRecoveryTask: Task<Void, Never>?
    private var attemptedGeometryRecovery = false
    private var geometryGesture: GeometryGesture?
    private struct GeometryGesture {
        let document: SharedArea.Document
        let placements: Set<SharedArea.ID<SharedArea.Placement>>
        let kind: SharedAreaGeometryHistory.Kind
        var frames: [SharedArea.ID<SharedArea.Placement>: SharedArea.Rect]
    }
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
        let pendingCount: Int
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
        canvas.onBeginGeometry = { [weak self] placements, kind in self?.beginGeometry(placements: placements, kind: kind) ?? false }
        canvas.onPreviewGeometry = { [weak self] frames in _ = self?.updateGeometry(frames: frames) }
        canvas.onFinishGeometry = { [weak self] in
            self?.actionTask = Task { [weak self] in await self?.finishGeometry() }
        }
        canvas.onCancelGeometry = { [weak self] in self?.cancelGeometry() }
        canvas.onUndoGeometry = { [weak self] in
            self?.actionTask = Task { [weak self] in await self?.undoSharedGeometry() }
        }
        canvas.onRedoGeometry = { [weak self] in
            self?.actionTask = Task { [weak self] in await self?.redoSharedGeometry() }
        }
        canvas.canUndoGeometry = { [weak self] in self?.canUndoSharedGeometry ?? false }
        canvas.canRedoGeometry = { [weak self] in self?.canRedoSharedGeometry ?? false }
        for view in [canvas, titleLabel, statusLabel, objectNavigator, actions, detailLabel, entryLabel, history, readerScroll, editorScroll, postButton, messageLabel] {
            addSubview(view)
        }
        addSubview(agreementPanel)
        addSubview(freshnessPanel)
        addSubview(artifactPanel)
        addSubview(livePanel)
        agreementPanel.onRebaseDraft = { [weak self] in self?.rebaseAgreementDraft() }
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
        geometryHistory = .init(); pendingGeometry = nil
        geometryLedgerStore = nil; geometryLedger = nil; geometryUnavailable = false; attemptedGeometryRecovery = false
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
        livePanel.stop()
        cameraTimer?.invalidate(); cameraTimer = nil
        draftTimer?.invalidate(); draftTimer = nil
        actionTask?.cancel(); actionTask = nil
        geometryRecoveryTask?.cancel(); geometryRecoveryTask = nil
        cancelGeometry()
        if uncertainCommand == nil { pendingCreatedObject = nil }
        knownDocument = nil
        artifactPanel.show(object: nil, in: nil)
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
        let agreement = !agreementPanel.isHidden ? SharedAreaAgreementView.height + 8
            : !freshnessPanel.isHidden ? SharedAreaAgentFreshnessView.height + 8 : 0
        setFrame(agreementPanel, .init(x: x, y: header + 106, width: width, height: SharedAreaAgreementView.height))
        setFrame(freshnessPanel, .init(x: x, y: header + 106, width: width, height: SharedAreaAgentFreshnessView.height))
        setFrame(readerScroll, .init(x: x, y: header + 106 + agreement, width: width, height: max(48, editorTop - header - 118 - agreement)))
        // A selected agent's live view takes the reader's place.
        setFrame(livePanel, readerScroll.frame)
        setFrame(editorScroll, .init(x: x, y: editorTop, width: width, height: 112))
        setFrame(postButton, .init(x: x, y: editorTop + 122, width: min(width, 160), height: ComposerActionButton.controlHeight))
        setFrame(artifactPanel, .init(x: x, y: header + 106, width: width, height: max(160, editorTop + 112 - header - 106)))
        setFrame(messageLabel, .init(x: x, y: editorTop + 161, width: width, height: 17))
        onCanvasTransformChange?()
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
    /// The preview text the canvas draws for a visible card, nil when the card
    /// is not drawn or the zoom hides previews.
    func renderedCardPreview(for object: SharedArea.ID<SharedArea.Object>) -> String? {
        isMounted ? canvas.renderedPreview(for: object) : nil
    }
    func setCamera(_ value: SharedAreaLocalView) throws {
        guard [value.x, value.y, value.zoom].allSatisfy(\.isFinite), value.zoom > 0 else { throw SharedArea.Failure.invalidGeometry }
        if value.x != localCamera.x || value.y != localCamera.y || value.zoom != localCamera.zoom { cancelGeometry() }
        localCamera = value; cameraDirty = true
        privateViewWrites += 1
        try controller.setView(value)
        cameraDirty = false
        canvas.setCamera(value)
        onCanvasTransformChange?()
    }
    /// Follow drives the private camera from a teammate's published viewport.
    /// It is presentation only: not local navigation, and not saved per frame.
    @discardableResult
    func applyFollowedCamera(_ value: SharedAreaLocalView) -> Bool {
        guard isMounted, [value.x, value.y, value.zoom].allSatisfy(\.isFinite), value.zoom > 0 else { return false }
        var next = value; next.focusedObject = selectedObject
        guard next != localCamera else { return false }
        if geometryGesture != nil { cancelGeometry() }
        cameraTimer?.invalidate(); cameraTimer = nil
        localCamera = next; cameraDirty = true
        canvas.setCamera(localCamera)
        onCanvasTransformChange?()
        return true
    }
    /// Saves a followed camera once, when following ends.
    func persistFollowedCamera() throws { if cameraDirty { try setCamera(localCamera) } }
    func selectObject(_ object: SharedArea.ID<SharedArea.Object>?) throws {
        try prepareToClose()
        var candidate = localCamera
        candidate.focusedObject = object
        // A failed focus write leaves the previous target and its draft intact.
        privateViewWrites += 1
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
    /// Points are scene-relative screen points, including the canvas header
    /// offset, and portable area points independent of each person's camera.
    func screenPoint(forAreaPoint point: CGPoint) -> CGPoint {
        canvas.convert(.init(x: (point.x - localCamera.x) * localCamera.zoom,
                             y: (point.y - localCamera.y) * localCamera.zoom), to: self)
    }
    func areaPoint(forScreenPoint point: CGPoint) -> CGPoint {
        let local = canvas.convert(point, from: self)
        return .init(x: localCamera.x + local.x / localCamera.zoom,
                     y: localCamera.y + local.y / localCamera.zoom)
    }
    var canUndoSharedGeometry: Bool {
        guard isMounted, !geometryUnavailable, controller.canSubmit, !controller.isSubmitting, pendingGeometry == nil,
              geometryGesture == nil, let document = controller.document else { return false }
        return geometryHistory.canUndo(in: document)
    }
    var isGeometryGestureActive: Bool { geometryGesture != nil }
    var canRedoSharedGeometry: Bool {
        guard isMounted, !geometryUnavailable, controller.canSubmit, !controller.isSubmitting, pendingGeometry == nil,
              geometryGesture == nil, let document = controller.document else { return false }
        return geometryHistory.canRedo(in: document)
    }
    @discardableResult
    func beginGeometry(placements: Set<SharedArea.ID<SharedArea.Placement>>,
                       kind: SharedAreaGeometryHistory.Kind = .move) -> Bool {
        guard isMounted, !geometryUnavailable, geometryLedger != nil, controller.canSubmit, !controller.isSubmitting,
              pendingGeometry == nil, uncertainCommand == nil, geometryGesture == nil,
              kind == .move || kind == .resize, !placements.isEmpty, placements.count <= 128,
              let document = controller.document else { return false }
        let selected = document.positions.filter { placements.contains($0.id) }
        guard selected.count == placements.count else { return false }
        // Taking hold of shared content ends follow; a followed camera frame
        // would otherwise cancel this gesture.
        onLocalCameraNavigation?()
        geometryGesture = .init(document: document, placements: placements, kind: kind,
            frames: Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.rect) }))
        canvas.geometryEnabled = true
        lastControlsKey = nil
        refreshControls()
        return true
    }
    @discardableResult
    func updateGeometry(frames: [SharedArea.ID<SharedArea.Placement>: SharedArea.Rect]) -> Bool {
        guard var gesture = geometryGesture, Set(frames.keys) == gesture.placements,
              frames.values.allSatisfy(\.valid) else { return false }
        gesture.frames = frames; geometryGesture = gesture
        canvas.setPreview(frames)
        return true
    }
    func cancelGeometry() {
        geometryGesture = nil
        canvas.cancelGeometryGesture()
        canvas.setPreview([:])
        lastControlsKey = nil
    }
    func finishGeometry() async {
        guard let gesture = geometryGesture else { return }
        guard controller.canSubmit, !controller.isSubmitting,
              controller.document?.revision == gesture.document.revision else {
            cancelGeometry(); messageLabel.stringValue = "Workspace changed. Move canceled."; refresh(); return
        }
        do {
            let mutation = try geometryHistory.move(in: gesture.document, frames: gesture.frames, kind: gesture.kind)
            geometryGesture = nil
            await submitGeometry(mutation)
        } catch SharedAreaGeometryHistory.Failure.unchanged {
            cancelGeometry(); refreshControls()
        } catch {
            cancelGeometry(); messageLabel.stringValue = "That layout change is unavailable."; refreshControls()
        }
    }
    func undoSharedGeometry() async {
        guard isMounted, !geometryUnavailable, controller.canSubmit, !controller.isSubmitting, pendingGeometry == nil,
              geometryGesture == nil, let document = controller.document else { return }
        do { await submitGeometry(try geometryHistory.undo(in: document)) }
        catch { messageLabel.stringValue = "Undo cannot replace a newer layout change." }
    }
    func redoSharedGeometry() async {
        guard isMounted, !geometryUnavailable, controller.canSubmit, !controller.isSubmitting, pendingGeometry == nil,
              geometryGesture == nil, let document = controller.document else { return }
        do { await submitGeometry(try geometryHistory.redo(in: document)) }
        catch { messageLabel.stringValue = "Redo cannot replace a newer layout change." }
    }
    func checkPendingDelivery() async {
        if geometryUnavailable {
            geometryUnavailable = false; geometryLedgerStore = nil; geometryLedger = nil
            if let document = controller.document { loadGeometryLedger(area: document.id) }
        }
        if controller.status != .connected { await controller.open() }
        _ = await controller.recoverPendingOperations()
        reconcileDeliveredOperations()
        if let mutation = pendingGeometry, !geometryUnavailable,
           controller.deliveryRecord(for: mutation.command.id) == nil, controller.canSubmit {
            await submitGeometry(mutation, prepared: true)
        }
        refresh()
    }
    private func submitGeometry(_ mutation: SharedAreaGeometryHistory.Mutation, prepared: Bool = false) async {
        let generation = mountGeneration
        if !prepared {
            do {
                guard let store = geometryLedgerStore, var ledger = geometryLedger, ledger.pending == nil else {
                    throw SharedAreaLocalStoreError.invalidState
                }
                ledger.history = geometryHistory; ledger.pending = mutation
                geometryLedger = try store.save(ledger)
                pendingGeometry = mutation
            } catch {
                // Nothing was sent. If disk still holds the last accepted
                // generation, the write never landed and later moves stay safe;
                // anything else needs the explicit delivery check to recover.
                geometryUnavailable = !geometryLedgerUnchanged()
                canvas.setPreview([:])
                messageLabel.stringValue = "Could not retain layout history. Nothing sent."
                lastControlsKey = nil; refresh(); return
            }
        }
        let result = await controller.submit(mutation.command)
        guard isMounted, generation == mountGeneration else { return }
        if let current = pendingGeometry, current.command.id != mutation.command.id { return }
        switch result {
        case .accepted(let receipt):
            do {
                try acknowledgeGeometry(mutation, revision: receipt.revision)
                messageLabel.stringValue = "Layout saved"
            }
            catch { geometryUnavailable = true; messageLabel.stringValue = "Layout saved; Undo recovery needs attention." }
        case .uncertain:
            messageLabel.stringValue = "Layout delivery unknown. Check delivery."
        case .rejected(let reason):
            // Only a definitive authority receipt/snapshot can discard prepared
            // intent; a disconnected or failed local attempt remains recoverable.
            if let record = controller.deliveryRecord(for: mutation.command.id), case .rejected = record.state {
                do { try rejectPreparedGeometry(mutation) } catch { geometryUnavailable = true }
            }
            messageLabel.stringValue = reason == .conflict ? "Workspace changed. Move canceled." : "Layout change unavailable."
            if reason == .conflict { await controller.open() }
        }
        if geometryGesture == nil { canvas.setPreview([:]) }
        lastControlsKey = nil; refresh()
    }
    private func reconcileDeliveredOperations() {
        if let mutation = pendingGeometry, !geometryUnavailable {
            do {
                if let record = controller.deliveryRecord(for: mutation.command.id) {
                    switch record.state {
                    case .pending: break
                    case .accepted(let revision):
                        try acknowledgeGeometry(mutation, revision: revision); messageLabel.stringValue = "Layout saved"
                    case .rejected:
                        try rejectPreparedGeometry(mutation); messageLabel.stringValue = "Layout change was not accepted."
                    }
                }
                if pendingGeometry != nil, controller.status == .connected, var probe = controller.document {
                    do {
                        if case .duplicate(let revision) = try probe.apply(mutation.command) {
                            try acknowledgeGeometry(mutation, revision: revision)
                        }
                    } catch SharedArea.Failure.conflict where probe.revision > mutation.command.expectedRevision {
                        try rejectPreparedGeometry(mutation)
                    }
                }
            } catch {
                geometryUnavailable = true; messageLabel.stringValue = "Layout recovery needs attention. Check delivery."
            }
        }
        if let command = uncertainCommand, let record = controller.deliveryRecord(for: command.id) {
            switch record.state {
            case .pending: break
            case .accepted:
                uncertainCommand = nil; uncertainDraft = nil
                if let draft = activeDraft, !controller.drafts.contains(where: { $0.id == draft.id }), editor.string == draft.text {
                    activeDraft = nil; editor.string = ""; draftDirty = false
                }
                if let created = pendingCreatedObject { pendingCreatedObject = nil; try? selectObject(created) }
                messageLabel.stringValue = "Saved"
            case .rejected:
                uncertainCommand = nil; uncertainDraft = nil; pendingCreatedObject = nil
                messageLabel.stringValue = "Change was not accepted. Draft retained."
            }
        }
    }
    private func loadGeometryLedger(area: SharedArea.ID<SharedArea.Area>) {
        guard geometryLedgerStore == nil, !geometryUnavailable else { return }
        do {
            let store = try SharedAreaGeometryLedgerStore(directory: controller.storageDirectory, identity: controller.identity, area: area)
            let ledger = try store.load() ?? .init(identity: controller.identity, area: area)
            geometryLedgerStore = store; geometryLedger = ledger
            geometryHistory = ledger.history; pendingGeometry = ledger.pending
        } catch {
            geometryUnavailable = true; messageLabel.stringValue = "Layout history is unavailable. Existing work is preserved."
        }
    }
    private func geometryLedgerUnchanged() -> Bool {
        guard let store = geometryLedgerStore, let held = geometryLedger, held.pending == nil else { return false }
        do {
            guard let disk = try store.load() else { return held.generation == 0 }
            return disk.generation == held.generation && disk.pending == nil
        } catch { return false }
    }
    private func acknowledgeGeometry(_ mutation: SharedAreaGeometryHistory.Mutation, revision: UInt64) throws {
        if geometryHistory.acknowledgedRevision(for: mutation.command.id) == revision { return }
        guard let store = geometryLedgerStore, var ledger = geometryLedger,
              ledger.pending?.command == mutation.command else { throw SharedAreaLocalStoreError.invalidState }
        var history = ledger.history
        try history.acknowledge(mutation, revision: revision)
        ledger.history = history; ledger.pending = nil
        let accepted = try store.save(ledger)
        geometryLedger = accepted; geometryHistory = history
        if pendingGeometry?.command.id == mutation.command.id { pendingGeometry = nil }
        canvas.setPreview([:]); lastControlsKey = nil
    }
    private func rejectPreparedGeometry(_ mutation: SharedAreaGeometryHistory.Mutation) throws {
        guard let store = geometryLedgerStore, var ledger = geometryLedger,
              ledger.pending?.command == mutation.command else { return }
        ledger.pending = nil
        geometryLedger = try store.save(ledger)
        if pendingGeometry?.command.id == mutation.command.id { pendingGeometry = nil }
        canvas.setPreview([:]); lastControlsKey = nil
    }
    private var pendingDeliveryCount: Int {
        var ids = Set(controller.pendingOperations.map { $0.command.id })
        if let pendingGeometry { ids.insert(pendingGeometry.command.id) }
        return ids.count
    }
    func fitContent() throws {
        guard let positions = controller.document?.positions, let first = positions.first else { return }
        onLocalCameraNavigation?()
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
        if let area = controller.document?.id { loadGeometryLedger(area: area) }
        reconcileDeliveredOperations()
        if !cameraDirty { localCamera = controller.view }
        let current = controller.document
        let changed = current?.id != knownDocument?.id || current?.revision != knownDocument?.revision
        if let gesture = geometryGesture, current?.revision != gesture.document.revision {
            cancelGeometry(); messageLabel.stringValue = "Workspace changed. Move canceled."
        } else if geometryGesture != nil, controller.status != .connected || controller.scope == nil || controller.scope?.role == .viewer {
            // Permission is rechecked on every authority frame, not only at
            // release: a downgraded editor must not keep previewing an edit.
            cancelGeometry(); messageLabel.stringValue = "Editing access changed. Move canceled."
        }
        if changed {
            knownDocument = current; knownHosts = controller.hostLiveness
            canvas.install(document: current, hosts: knownHosts, camera: localCamera, selected: selectedObject)
            if activeDraft == nil, let object = selectedObject {
                activeDraft = controller.drafts.last(where: { $0.object == object })
                editor.string = activeDraft?.text ?? ""
            }
            refreshReader()
        } else if controller.hostLiveness != knownHosts {
            // Host liveness changes without a document revision.
            knownHosts = controller.hostLiveness
            canvas.install(document: current, hosts: knownHosts, camera: localCamera, selected: selectedObject)
            refreshReader()
        } else { canvas.setCamera(localCamera) }
        statusLabel.stringValue = statusText
        artifactPanel.headsChanged(controller.artifactHeads)
        canvas.geometryEnabled = !geometryUnavailable && geometryLedger != nil && controller.canSubmit && !controller.isSubmitting && pendingGeometry == nil && uncertainCommand == nil
        if controller.status != .connected { attemptedGeometryRecovery = false }
        if let mutation = pendingGeometry, !geometryUnavailable, !attemptedGeometryRecovery,
           geometryRecoveryTask == nil, controller.canSubmit, controller.deliveryRecord(for: mutation.command.id) == nil {
            attemptedGeometryRecovery = true
            geometryRecoveryTask = Task { [weak self] in
                guard let self else { return }
                defer { geometryRecoveryTask = nil }
                await submitGeometry(mutation, prepared: true)
            }
        }
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
        agreementPanel.show(agreement: selectedObject, in: knownDocument, draft: activeDraft)
        freshnessPanel.show(agent: selectedObject, in: knownDocument, model: agentFreshness)
        livePanel.show(object: selectedObject, in: knownDocument)
        let key = ControlsKey(status: controller.status, submitting: controller.isSubmitting, canSubmit: controller.canSubmit,
            epoch: controller.scope?.epoch, role: controller.scope?.role.rawValue,
            documentRevision: controller.document?.revision, selected: selectedObject,
            hasText: !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            uncertain: uncertainCommand != nil, camera: controller.view, pendingCount: pendingDeliveryCount)
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
            .init(id: "undo-layout", title: "Undo layout change", icon: .system("arrow.uturn.backward"), enabled: canUndoSharedGeometry),
            .init(id: "redo-layout", title: "Redo layout change", icon: .system("arrow.uturn.forward"), enabled: canRedoSharedGeometry),
            .init(id: "delivery", title: "Check pending delivery (\(pendingDeliveryCount))", icon: .system("arrow.clockwise"), enabled: !controller.isSubmitting && (pendingDeliveryCount > 0 || geometryUnavailable)),
            .init(id: "handoff", title: "Hand agent off…", icon: .system("person.2"), enabled: writable && selectedObject.flatMap { selected in controller.document?.items.first(where: { $0.id == selected && $0.kind == .agentObservation }) } != nil && onRequestHandoff != nil),
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
        // An artifact replaces the text reader and composer with its own
        // read-only revision view; everything else keeps the reader.
        artifactPanel.show(object: selectedObject, in: knownDocument)
        for view in [readerScroll, editorScroll, postButton] as [NSView] { view.isHidden = !artifactPanel.isHidden }
        // A selected agent's live view takes the reader's place, entry navigation included.
        livePanel.show(object: selectedObject, in: knownDocument)
        if !livePanel.isHidden { readerScroll.isHidden = true }
        entryLabel.isHidden = !livePanel.isHidden; history.isHidden = !livePanel.isHidden
        guard let document = knownDocument, let object = selectedObject,
              let item = document.items.first(where: { $0.id == object }) else {
            detailLabel.stringValue = activeDraft == nil ? "Select an object" : "Private draft"
            entryLabel.stringValue = ""; reader.string = ""; history.items = []; displayedContextRevision = nil
            return
        }
        detailLabel.stringValue = Self.title(for: item.kind)
        let entries: [String]
        switch item.kind {
        case .discussion:
            entries = document.posts.filter { $0.object == object }.map { SharedAreaExcerptPresentation.entry(for: $0, in: document, model: agentFreshness) }
        case .agreement: entries = document.contexts.filter { $0.object == object }.map(\.text)
        case .agentObservation:
            let host = SharedAreaHostLivenessCopy.cardLine(SharedAreaHostLivenessCopy.liveness(for: item, in: knownHosts))
            entries = [host + " " + (onRequestHandoff == nil
                ? "This is an observation of an agent on its publishing host. Transcript history and execution controls are not available in this shared view yet."
                : "History is not shared. Execution stays on the original publishing host; control requires a separate accepted handoff. Use Hand agent off in Workspace to review it.")]
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
    private func refreshFreshness() {
        guard isMounted else { return }
        freshnessPanel.show(agent: selectedObject, in: knownDocument, model: agentFreshness)
        refreshReader()
    }
    private func navigateHistory(_ action: String) {
        if action == "earlier" { readerIndex = max(0, readerIndex - 1); followsLatestEntry = false }
        if action == "later" { readerIndex += 1; followsLatestEntry = false }
        if action == "latest" { followsLatestEntry = true }
        refreshReader()
    }
    private func performAction(_ action: String) {
        switch action {
        case "undo-layout": actionTask = Task { [weak self] in await self?.undoSharedGeometry() }
        case "redo-layout": actionTask = Task { [weak self] in await self?.redoSharedGeometry() }
        case "delivery": actionTask = Task { [weak self] in await self?.checkPendingDelivery() }
        case "handoff": if let selectedObject { onRequestHandoff?(selectedObject) }
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
    private func rebaseAgreementDraft() {
        guard let id = activeDraft?.id else { return }
        do { try saveCurrentDraft(); activeDraft = try controller.rebaseDraft(id: id) } catch { showPrivateSaveFailure() }
        lastControlsKey = nil; refreshControls()
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
        onLocalCameraNavigation?()
        if geometryGesture != nil { cancelGeometry() }
        localCamera = value; localCamera.focusedObject = selectedObject; cameraDirty = true
        canvas.setCamera(localCamera)
        onCanvasTransformChange?()
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
private final class SharedAreaSceneCanvas: NSView, NSUserInterfaceValidations {
    struct Card {
        let position: SharedArea.Position
        let title: String
        let preview: String
    }
    var onSelect: ((SharedArea.ID<SharedArea.Object>?) -> Void)?
    var onCamera: ((SharedAreaLocalView, Bool) -> Void)?
    var onCycleSelection: ((Bool) -> Void)?
    var onBeginGeometry: ((Set<SharedArea.ID<SharedArea.Placement>>, SharedAreaGeometryHistory.Kind) -> Bool)?
    var onPreviewGeometry: (([SharedArea.ID<SharedArea.Placement>: SharedArea.Rect]) -> Void)?
    var onFinishGeometry: (() -> Void)?
    var onCancelGeometry: (() -> Void)?
    var onUndoGeometry: (() -> Void)?
    var onRedoGeometry: (() -> Void)?
    var canUndoGeometry: (() -> Bool)?
    var canRedoGeometry: (() -> Bool)?
    var geometryEnabled = false { didSet { if oldValue != geometryEnabled { needsDisplay = true } } }
    private var cards: [Card] = []
    private var hasDocument = false
    private var camera = SharedAreaLocalView()
    private var selected: SharedArea.ID<SharedArea.Object>?
    private var panStart: (point: NSPoint, camera: SharedAreaLocalView)?
    private var selectedPlacements = Set<SharedArea.ID<SharedArea.Placement>>()
    private var previewFrames: [SharedArea.ID<SharedArea.Placement>: SharedArea.Rect] = [:]
    private struct GeometryDrag {
        let point: NSPoint
        let camera: SharedAreaLocalView
        let positions: [SharedArea.Position]
        let kind: SharedAreaGeometryHistory.Kind
        var changed = false
    }
    private var geometryDrag: GeometryDrag?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Shared objects")
        setAccessibilityHelp("Drag to move shared objects. Shift-click selects a group. Drag its lower-right handle to resize. Command-Z undoes your layout change. Tab navigates objects; arrow keys pan; Escape cancels a gesture.")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func install(document: SharedArea.Document?, hosts: [Collaboration.HostLiveness] = [], camera: SharedAreaLocalView, selected: SharedArea.ID<SharedArea.Object>?) {
        self.camera = camera; self.selected = selected
        hasDocument = document != nil
        let items = Dictionary(uniqueKeysWithValues: (document?.items ?? []).map { ($0.id, $0) })
        let posts = Dictionary(grouping: document?.posts ?? [], by: \.object)
        let contexts = Dictionary(grouping: document?.contexts ?? [], by: \.object)
        cards = (document?.positions ?? []).sorted { $0.z == $1.z ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.z < $1.z }.compactMap { position in
            guard let item = items[position.object] else { return nil }
            let body: String
            switch item.kind {
            case .agentObservation:
                body = SharedAreaHostLivenessCopy.cardLine(SharedAreaHostLivenessCopy.liveness(for: item, in: hosts))
                    + "\nAgent stays on its publishing host.\nSelect it to follow its work live."
            case .artifact: body = "Artifact content unavailable."
            case .discussion: body = posts[item.id]?.last?.text ?? "No messages yet."
            case .agreement: body = contexts[item.id]?.last?.text ?? "No agreement revision yet."
            }
            return Card(position: position, title: SharedAreaSceneView.title(for: item.kind), preview: String(body.prefix(800)))
        }
        selectedPlacements.formIntersection(Set(cards.map { $0.position.id }))
        if selectedPlacements.isEmpty, let selected,
           let position = cards.last(where: { $0.position.object == selected })?.position { selectedPlacements = [position.id] }
        needsDisplay = true
    }
    func setCamera(_ value: SharedAreaLocalView) {
        guard value != camera else { return }
        if geometryDrag != nil, value.x != camera.x || value.y != camera.y || value.zoom != camera.zoom {
            cancelGeometryGesture(); onCancelGeometry?()
        }
        camera = value; needsDisplay = true
    }
    func setPreview(_ frames: [SharedArea.ID<SharedArea.Placement>: SharedArea.Rect]) {
        guard frames != previewFrames else { return }
        previewFrames = frames; needsDisplay = true
    }
    func cancelGeometryGesture() { geometryDrag = nil; previewFrames = [:]; needsDisplay = true }
    func setSelection(_ value: SharedArea.ID<SharedArea.Object>?) {
        selected = value; needsDisplay = true
        if let value {
            if !cards.contains(where: { selectedPlacements.contains($0.position.id) && $0.position.object == value }),
               let position = cards.last(where: { $0.position.object == value })?.position { selectedPlacements = [position.id] }
        } else { selectedPlacements.removeAll() }
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
            guard let frame = screenFrame(previewFrames[card.position.id] ?? card.position.rect), frame.intersects(bounds) else { continue }
            if result.count == 128 { omitted = true; break }
            result.append((card, frame))
        }
        return (Array(result.reversed()), omitted)
    }
    func renderedFrame(for object: SharedArea.ID<SharedArea.Object>) -> NSRect? {
        visibleCards().cards.first(where: { $0.card.position.object == object })?.frame
    }
    func renderedPreview(for object: SharedArea.ID<SharedArea.Object>) -> String? {
        guard camera.zoom >= 0.35 else { return nil }
        return visibleCards().cards.first(where: { $0.card.position.object == object })?.card.preview
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
            let highlighted = selectedPlacements.contains(card.position.id)
            (highlighted ? LineToken.borderStrong : .border).color.nsColor(in: self).setStroke()
            path.lineWidth = highlighted ? 2 : 1; path.stroke()
            NSBezierPath(rect: frame.insetBy(dx: 10, dy: 10)).addClip()
            draw(card.title, rect: .init(x: frame.minX + 14, y: frame.minY + 13, width: max(0, frame.width - 28), height: 22), role: .title, color: .textPrimary)
            if camera.zoom >= 0.35 {
                draw(card.preview, rect: .init(x: frame.minX + 14, y: frame.minY + 47, width: max(0, frame.width - 28), height: max(0, frame.height - 86)), role: .body, color: .textPrimary)
                draw("Preview · select to read full entries", rect: .init(x: frame.minX + 14, y: frame.maxY - 27, width: max(0, frame.width - 28), height: 16), role: .label, color: .textSecondary)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if geometryEnabled, let frame = selectedGroupFrame() {
            LineToken.borderStrong.color.nsColor(in: self).setStroke()
            if selectedPlacements.count > 1 {
                let outline = NSBezierPath(rect: frame.insetBy(dx: -3, dy: -3))
                outline.setLineDash([4, 3], count: 2, phase: 0); outline.lineWidth = 1; outline.stroke()
            }
            let handle = NSRect(x: frame.maxX - 4, y: frame.maxY - 4, width: 8, height: 8)
            SurfaceToken.tileBody.color.nsColor(in: self).setFill(); handle.fill()
            NSBezierPath(rect: handle).stroke()
        }
        if visible.omitted { draw("Showing up to 128 visible objects · zoom in to inspect", rect: .init(x: 16, y: bounds.height - 30, width: bounds.width - 32, height: 18), role: .label, color: .textSecondary) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        panStart = nil
        let group = selectedGroupFrame()
        let resize = geometryEnabled && group.map { NSRect(x: $0.maxX - 10, y: $0.maxY - 10, width: 20, height: 20).contains(point) } == true
        if resize { startGeometry(at: point, kind: .resize); return }
        if let entry = visibleCards().cards.reversed().first(where: { $0.frame.contains(point) }) {
            let id = entry.card.position.id
            if !event.modifierFlags.intersection([.shift, .command]).isEmpty {
                if selectedPlacements.contains(id) { selectedPlacements.remove(id) } else { selectedPlacements.insert(id) }
            } else if !selectedPlacements.contains(id) { selectedPlacements = [id] }
            let active = selectedPlacements.contains(id) ? entry.card.position.object
                : cards.last(where: { selectedPlacements.contains($0.position.id) })?.position.object
            onSelect?(active)
            if geometryEnabled && selectedPlacements.contains(id) { startGeometry(at: point, kind: .move) }
        } else { selectedPlacements.removeAll(); onSelect?(nil); panStart = (point, camera) }
    }
    private func startGeometry(at point: NSPoint, kind: SharedAreaGeometryHistory.Kind) {
        let positions = cards.filter { selectedPlacements.contains($0.position.id) }.map(\.position)
        guard !positions.isEmpty, onBeginGeometry?(Set(positions.map(\.id)), kind) == true else { return }
        geometryDrag = .init(point: point, camera: camera, positions: positions, kind: kind)
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 6 && modifiers == .command { onUndoGeometry?() }
        else if event.keyCode == 6 && modifiers == [.command, .shift] { onRedoGeometry?() }
        else if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onCycleSelection?(event.modifierFlags.contains(.shift))
        } else if event.keyCode == 53 {
            if geometryDrag != nil { cancelGeometryGesture(); onCancelGeometry?() }
            else { window?.selectNextKeyView(self) }
        } else if (123...126).contains(event.keyCode) && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            // Keyboard camera pan, in screen points so every zoom moves alike.
            let step = (event.modifierFlags.contains(.shift) ? 240 : 60) / camera.zoom
            var moved = camera
            switch event.keyCode {
            case 123: moved.x -= step
            case 124: moved.x += step
            case 125: moved.y += step
            default: moved.y -= step
            }
            onCamera?(moved, true)
        } else { super.keyDown(with: event) }
    }
    @objc func undo(_ sender: Any?) { onUndoGeometry?() }
    @objc func redo(_ sender: Any?) { onRedoGeometry?() }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return canUndoGeometry?() == true }
        if item.action == #selector(redo(_:)) { return canRedoGeometry?() == true }
        return true
    }
    override func mouseDragged(with event: NSEvent) {
        if var drag = geometryDrag {
            guard camera.x == drag.camera.x, camera.y == drag.camera.y, camera.zoom == drag.camera.zoom else {
                cancelGeometryGesture(); onCancelGeometry?(); return
            }
            let point = convert(event.locationInWindow, from: nil)
            guard abs(point.x - drag.point.x) + abs(point.y - drag.point.y) >= 3 else { return }
            let dx = Double(point.x - drag.point.x) / drag.camera.zoom
            let dy = Double(point.y - drag.point.y) / drag.camera.zoom
            guard dx.isFinite && dy.isFinite else { return }
            let frames: [SharedArea.ID<SharedArea.Placement>: SharedArea.Rect]
            if drag.kind == .resize {
                let minX = drag.positions.map(\.rect.x).min()!, minY = drag.positions.map(\.rect.y).min()!
                let width = drag.positions.map { $0.rect.x + $0.rect.width }.max()! - minX
                let height = drag.positions.map { $0.rect.y + $0.rect.height }.max()! - minY
                let sx = max(drag.positions.map { 80 / $0.rect.width }.max() ?? 1, (width + dx) / width)
                let sy = max(drag.positions.map { 60 / $0.rect.height }.max() ?? 1, (height + dy) / height)
                frames = Dictionary(uniqueKeysWithValues: drag.positions.map { position in
                    (position.id, .init(x: minX + (position.rect.x - minX) * sx,
                        y: minY + (position.rect.y - minY) * sy,
                        width: position.rect.width * sx, height: position.rect.height * sy))
                })
            } else {
                frames = Dictionary(uniqueKeysWithValues: drag.positions.map { position in
                    (position.id, .init(x: position.rect.x + dx, y: position.rect.y + dy,
                        width: position.rect.width, height: position.rect.height))
                })
            }
            guard frames.values.allSatisfy(\.valid) else { return }
            drag.changed = true; geometryDrag = drag
            onPreviewGeometry?(frames)
            return
        }
        guard let panStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        var moved = panStart.camera
        moved.x -= (point.x - panStart.point.x) / moved.zoom; moved.y -= (point.y - panStart.point.y) / moved.zoom
        onCamera?(moved, false)
    }
    override func mouseUp(with event: NSEvent) {
        if let drag = geometryDrag {
            mouseDragged(with: event)
            geometryDrag = nil
            if drag.changed || !previewFrames.isEmpty { onFinishGeometry?() } else { onCancelGeometry?() }
            return
        }
        if panStart != nil { panStart = nil; onCamera?(camera, true) }
    }
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
        guard values.allSatisfy(\.isFinite), (values[0] + values[2]).isFinite, (values[1] + values[3]).isFinite else { return nil }
        return .init(x: values[0], y: values[1], width: values[2], height: values[3])
    }
    private func selectedGroupFrame() -> NSRect? {
        let frames = cards.filter { selectedPlacements.contains($0.position.id) }
            .compactMap { screenFrame(previewFrames[$0.position.id] ?? $0.position.rect) }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
    private func draw(_ text: String, rect: NSRect, role: TextRole, color: TextToken) {
        guard rect.width > 0, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: NSFont.token(role), .foregroundColor: color.color.nsColor(in: self), .paragraphStyle: paragraph
        ])
    }
}
