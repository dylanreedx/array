import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

@MainActor
final class SharedAreaHandoffWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let object: SharedArea.ID<SharedArea.Object>
    let content: SharedAreaHandoffView
    var onClose: (() -> Void)?
    init(model: SharedAgentHandoffController, object: SharedArea.ID<SharedArea.Object>) {
        self.object = object
        content = SharedAreaHandoffView(model: model, object: object)
        window = CollaborationWindow(contentRect: .init(x: 0, y: 0, width: 780, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Agent handoff"; window.minSize = .init(width: 700, height: 780)
        window.isReleasedWhenClosed = false; window.contentView = content; window.delegate = self
        window.initialFirstResponder = content.initialKeyView
        window.center()
    }
    func show() { CollaborationWindow.present(window); content.refreshFromAuthority() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        do { try content.prepareToClose(); return true }
        catch {
            let alert = NSAlert()
            alert.messageText = "Your private handoff draft could not be saved"
            alert.informativeText = "This window stays open so you can copy your draft or retry saving."
            alert.beginSheetModal(for: sender, completionHandler: nil)
            return false
        }
    }
    func windowWillClose(_ notification: Notification) { content.stop(); onClose?() }
}

/// Native controls reuse Array's choice/action components. The backdrop is
/// resolved on each draw rather than retaining an unobserved CGColor layer.
@MainActor
final class SharedAreaHandoffView: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    let model: SharedAgentHandoffController
    let object: SharedArea.ID<SharedArea.Object>
    private let heading = NSTextField(labelWithString: "Hand agent control to a teammate")
    private let explanation = NSTextField(wrappingLabelWithString: "The agent and checkout stay on their original host. An accepted handoff lets the invited teammate send the next reviewed prompt; it does not copy files or provider login.")
    private let controlLabel = NSTextField(wrappingLabelWithString: "Checking current control…")
    private let recipientLabel = NSTextField(labelWithString: "Teammate")
    private let contextLabel = NSTextField(labelWithString: "Shared agreement and timing")
    private let promptLabel = NSTextField(labelWithString: "Prompt")
    private let recipient = NSTextField(string: "")
    private let offer = ComposerActionButton(presentation: CollaborationHubView.action("Offer handoff", symbol: "person.badge.plus"))
    private let accept = ComposerActionButton(presentation: CollaborationHubView.action("Accept handoff", symbol: "person.crop.circle.badge.checkmark"))
    private let reclaim = ComposerActionButton(presentation: CollaborationHubView.action("Reclaim control", symbol: "arrow.uturn.backward"))
    private let contextChoice = ChoiceButton(title: "Shared agreement revision")
    private let modeChoice = ChoiceButton(title: "Prompt timing")
    private let contextReader = NSTextView()
    private let contextScroll = NSScrollView()
    private let prompt = NSTextView()
    private let promptScroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let hostWarning = NSTextField(wrappingLabelWithString: "")
    /// The executing host's relay liveness. Nil provider: liveness is not known
    /// to this dialog and no warning is shown.
    var hostLiveness: (@MainActor () -> Collaboration.HostLiveness?)? { didSet { refreshActions() } }
    private let refresh = ComposerActionButton(presentation: CollaborationHubView.action("Refresh", symbol: "arrow.clockwise"))
    private let check = ComposerActionButton(presentation: CollaborationHubView.action("Check delivery", symbol: "checkmark.circle"))
    private let send = ComposerActionButton(presentation: CollaborationHubView.action("Send reviewed prompt", symbol: "arrow.up"))
    private var task: Task<Void, Never>?
    private var stopped = false
    private var contexts: [SharedArea.Context] = []
    private var documentRevision: UInt64?
    private var preferredContext: SharedArea.ID<SharedArea.Revision>?
    private var draftDirty = false
    private var draftLoadFailed = false
    private var draftTimer: Timer?
    override var isFlipped: Bool { true }

    init(model: SharedAgentHandoffController, object: SharedArea.ID<SharedArea.Object>) {
        self.model = model; self.object = object
        super.init(frame: .init(x: 0, y: 0, width: 780, height: 820))
        heading.font = .token(.title)
        for label in [explanation, controlLabel, status, hostWarning] { label.font = .token(.body); label.isSelectable = true }
        hostWarning.setAccessibilityLabel("Host availability warning"); hostWarning.isHidden = true
        for label in [recipientLabel, contextLabel, promptLabel] { label.font = .token(.label) }
        // Fields and editors are transparent; `draw` paints their wells.
        recipient.font = .token(.body); recipient.isBezeled = false; recipient.drawsBackground = false; recipient.focusRingType = .none
        recipient.delegate = self
        recipient.placeholderString = "Teammate collaboration ID"; recipient.setAccessibilityLabel("Handoff recipient collaboration ID")
        configure(contextReader, scroll: contextScroll, editable: false, label: "Reviewed shared agreement")
        configure(prompt, scroll: promptScroll, editable: true, label: "Prompt for handed-off agent")
        prompt.delegate = self
        modeChoice.items = [.init(id: "send", title: "Send now", detail: "The host can refuse while its turn is busy"),
                            .init(id: "queue", title: "Queue for next turn", detail: "Array's durable next-turn queue on the original host")]
        modeChoice.selectedID = "send"
        modeChoice.onSelection = { [weak self] _ in self?.scheduleDraftSave(); self?.refreshActions() }
        contextChoice.onSelection = { [weak self] _ in self?.updateContext(); self?.scheduleDraftSave() }
        for (button, selector) in [(offer, #selector(offerHandoff)), (accept, #selector(acceptHandoff)),
                                   (reclaim, #selector(reclaimControl)), (refresh, #selector(refreshAction)),
                                   (check, #selector(checkDelivery)), (send, #selector(sendPrompt))] {
            button.target = self; button.action = selector
        }
        for child in [heading, explanation, controlLabel, recipientLabel, contextLabel, promptLabel, recipient, offer, accept, reclaim, contextChoice, modeChoice,
                      contextScroll, promptScroll, status, hostWarning, refresh, check, send] { addSubview(child) }
        do {
            let draft = try model.draft(object: object)
            prompt.string = draft.text; recipient.stringValue = draft.recipient; preferredContext = draft.context
            modeChoice.selectedID = draft.mode.rawValue
            if prompt.string.isEmpty, let pending = model.pending, case .prompt(let saved) = pending.action, pending.object == object { prompt.string = saved.text }
        } catch { draftLoadFailed = true }
        model.onChange = { [weak self] in self?.reload() }
        setAccessibilityRole(.group); setAccessibilityLabel("Agent handoff")
        contextReader.delegate = self
        CollaborationKeyLoop.link([recipient, offer, accept, reclaim, contextChoice, modeChoice, contextReader, prompt, refresh, check, send])
        reload(); applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func stop() { stopped = true; draftTimer?.invalidate(); draftTimer = nil; task?.cancel(); task = nil; model.onChange = nil }
    func prepareToClose() throws { draftTimer?.invalidate(); draftTimer = nil; try saveDraft() }
    func refreshHostLiveness() { refreshActions() }
    func refreshFromAuthority() { run { [weak self] in guard let self else { return }; await model.refresh(object: object) } }
    func textDidChange(_ notification: Notification) { scheduleDraftSave(); refreshActions() }
    override func keyDown(with event: NSEvent) {
        if !CollaborationKeyLoop.handleTab(event, in: window) { super.keyDown(with: event) }
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        CollaborationKeyLoop.moveFocus(from: textView, command: commandSelector)
    }
    /// The first stop when the handoff window opens.
    var initialKeyView: NSView { recipient }
    func controlTextDidChange(_ notification: Notification) { scheduleDraftSave() }
    private func scheduleDraftSave() {
        guard !stopped, !draftLoadFailed else { return }
        draftDirty = true; draftTimer?.invalidate()
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                do { try self?.saveDraft() }
                catch { self?.status.stringValue = "The private draft could not be saved. Keep this window open or copy your text." }
            }
        }
    }
    private func saveDraft() throws {
        guard !draftLoadFailed, draftDirty else { return }
        let selected = contextChoice.selectedID.flatMap(UUID.init(uuidString:)).map { SharedArea.ID<SharedArea.Revision>($0) } ?? preferredContext
        let draft = SharedAgentHandoffDraft(recipient: recipient.stringValue, text: prompt.string, context: selected,
            mode: modeChoice.selectedID == "queue" ? .queue : .send)
        try model.saveDraft(draft, object: object)
        preferredContext = selected; draftDirty = false
    }
    private func configure(_ view: NSTextView, scroll: NSScrollView, editable: Bool, label: String) {
        view.isEditable = editable; view.isSelectable = true; view.isRichText = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = .init(width: Space.m, height: Space.m)
        view.font = .token(.body); view.setAccessibilityLabel(label)
        view.drawsBackground = false
        scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
    }
    private func reload() {
        let heldFocus = CollaborationKeyLoop.holdFocus(in: window)
        defer { CollaborationKeyLoop.restoreFocus(heldFocus, in: window) }
        guard !stopped else { return }
        if let control = model.control, control.object == object {
            let owner = control.source.owner == model.identity.person ? "you" : String(control.source.owner.rawValue.uuidString.prefix(8))
            let current = control.controller == model.identity.person ? "you" : String(control.controller.rawValue.uuidString.prefix(8))
            controlLabel.stringValue = "Original host owner: \(owner). Current controller: \(current)."
            if let offer = control.offer { controlLabel.stringValue += " Handoff offered to \(offer.recipient == model.identity.person ? "you" : String(offer.recipient.rawValue.uuidString.prefix(8)))." }
        } else { controlLabel.stringValue = "Control is unavailable until the original host reconnects and registers this agent." }
        if documentRevision != model.areaState?.document.revision {
            documentRevision = model.areaState?.document.revision
            contexts = model.latestContexts
            let previous = contextChoice.selectedID ?? preferredContext?.rawValue.uuidString
            contextChoice.items = contexts.prefix(100).map {
                .init(id: $0.id.rawValue.uuidString, title: "Agreement \($0.id.rawValue.uuidString.prefix(8))", detail: String($0.text.prefix(100)))
            }
            if let previous, contextChoice.items.contains(where: { $0.id == previous }) { contextChoice.selectedID = previous }
            updateContext()
        }
        status.stringValue = model.message
        if draftLoadFailed { status.stringValue = "The saved private draft could not be read. Existing data was preserved; reconnect after repairing local storage." }
        if contexts.count > 100 { status.stringValue += " Showing the first 100 agreement revisions; use a smaller shared area to review another." }
        refreshActions()
    }
    private func updateContext() {
        if let raw = contextChoice.selectedID, let id = UUID(uuidString: raw) { preferredContext = .init(id) }
        contextReader.string = contexts.first(where: { $0.id.rawValue.uuidString == contextChoice.selectedID })?.text ?? "Create a shared agreement, then choose its reviewed revision here."
        refreshActions()
    }
    private func refreshActions() {
        let heldFocus = CollaborationKeyLoop.holdFocus(in: window)
        defer { CollaborationKeyLoop.restoreFocus(heldFocus, in: window) }
        let control = model.control, idle = !model.isBusy && model.pending == nil && !draftLoadFailed
        let owner = control?.source.owner == model.identity.person
        let usable = control?.object == object && control?.epoch == model.areaState?.scope.epoch && model.areaState?.scope.role != .viewer
        offer.presentation = CollaborationHubView.action("Offer handoff", symbol: "person.badge.plus", enabled: idle && owner && usable)
        accept.presentation = CollaborationHubView.action("Accept handoff", symbol: "person.crop.circle.badge.checkmark",
            enabled: idle && usable && control?.offer?.recipient == model.identity.person)
        reclaim.presentation = CollaborationHubView.action("Reclaim control", symbol: "arrow.uturn.backward", enabled: idle && owner && usable)
        let warning = modeChoice.selectedID == "send" ? hostLiveness.flatMap { SharedAreaHostLivenessCopy.sendNowWarning($0()) } : nil
        if hostWarning.stringValue != (warning ?? "") || hostWarning.isHidden != (warning == nil) {
            hostWarning.stringValue = warning ?? ""; hostWarning.isHidden = warning == nil; needsLayout = true
        }
        send.presentation = CollaborationHubView.action(warning == nil ? "Send reviewed prompt" : "Send now anyway",
            symbol: warning == nil ? "arrow.up" : "exclamationmark.triangle",
            enabled: idle && usable && control?.controller == model.identity.person && contextChoice.selectedID != nil && !prompt.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        check.presentation = CollaborationHubView.action("Check delivery", symbol: "checkmark.circle", enabled: !model.isBusy && model.pending != nil)
        refresh.presentation = CollaborationHubView.action("Refresh", symbol: "arrow.clockwise", enabled: !model.isBusy)
        contextChoice.isEnabled = idle; modeChoice.isEnabled = idle; recipient.isEnabled = idle
        prompt.isEditable = !draftLoadFailed
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard task == nil, !stopped else { return }
        task = Task { [weak self] in await action(); self?.task = nil }
    }
    @objc private func refreshAction() { refreshFromAuthority() }
    @objc private func offerHandoff() {
        guard let id = UUID(uuidString: recipient.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status.stringValue = "Enter the collaboration ID of the invited teammate."; return
        }
        run { [weak self] in await self?.model.offer(to: .init(id)) }
    }
    @objc private func acceptHandoff() { run { [weak self] in await self?.model.acceptOffer() } }
    @objc private func reclaimControl() { run { [weak self] in await self?.model.reclaim() } }
    @objc private func checkDelivery() { run { [weak self] in await self?.model.checkDelivery() } }
    @objc private func sendPrompt() {
        guard let raw = contextChoice.selectedID, let id = UUID(uuidString: raw) else { return }
        let text = prompt.string, previousReceipt = model.receipt?.command.id
        let mode: Collaboration.AgentPromptMode = modeChoice.selectedID == "queue" ? .queue : .send
        do { draftDirty = true; try saveDraft() }
        catch { status.stringValue = "The private draft could not be saved. Nothing was sent."; return }
        run { [weak self] in
            guard let self else { return }
            await model.send(text: text, context: .init(id), mode: mode)
            if model.pending == nil, let receipt = model.receipt, receipt.command.id != previousReceipt,
               receipt.command.text == text, prompt.string == text {
                prompt.string = ""; scheduleDraftSave()
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.panel.color.nsColor(in: self).setFill(); bounds.fill()
        // Editable wells use the same body surface as the hub's text fields.
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        for well in [recipientWell, contextScroll.frame, promptScroll.frame] {
            NSBezierPath(roundedRect: well, xRadius: Radius.card, yRadius: Radius.card).fill()
        }
    }
    private var recipientWell = NSRect.zero
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        for label in [heading, recipientLabel, contextLabel, promptLabel, recipient] { label.textColor = TextToken.textPrimary.color.nsColor(in: self) }
        for label in [explanation, controlLabel, status] { label.textColor = TextToken.textSecondary.color.nsColor(in: self) }
        hostWarning.textColor = TextToken.textPrimary.color.nsColor(in: self)
        for view in [contextReader, prompt] { view.textColor = TextToken.textPrimary.color.nsColor(in: self) }
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        let margin = CGFloat(Space.xl), width = max(1, bounds.width - 2 * margin), row: CGFloat = 32
        var moved = false
        func place(_ view: NSView, _ y: CGFloat, _ height: CGFloat, x: CGFloat = 0, w: CGFloat? = nil) {
            let next = NSRect(x: margin + x, y: y, width: w ?? width, height: height)
            if view.frame != next { view.frame = next; moved = true }
        }
        place(heading, 20, 28); place(explanation, 52, 40); place(controlLabel, 96, 36)
        place(recipientLabel, 140, 18)
        let well = NSRect(x: margin, y: 162, width: width - 182, height: row)
        if recipientWell != well { recipientWell = well; moved = true }
        place(recipient, well.midY - 11, 22, x: CGFloat(Space.m), w: well.width - 2 * CGFloat(Space.m))
        place(offer, 162, row, x: width - 170, w: 170)
        place(accept, 206, row, w: 200); place(reclaim, 206, row, x: 212, w: 200)
        place(contextLabel, 254, 18)
        place(contextChoice, 276, row, w: width - 227); place(modeChoice, 276, row, x: width - 215, w: 215)
        // Below the fixed rows: agreement reader, prompt editor, status, actions.
        let warningTop = bounds.height - 104, statusTop = warningTop - (hostWarning.isHidden ? 0 : 44), flexible = max(0, statusTop - 12 - 316 - 12 - 22)
        let contextHeight = max(96, (flexible * 0.4).rounded())
        place(contextScroll, 316, contextHeight)
        place(promptLabel, 316 + contextHeight + 12, 18)
        let promptTop = 316 + contextHeight + 34
        place(promptScroll, promptTop, max(96, statusTop - 12 - promptTop))
        place(status, statusTop, 40)
        place(hostWarning, warningTop, hostWarning.isHidden ? 0 : 40)
        place(refresh, bounds.height - 52, row, w: 110); place(check, bounds.height - 52, row, x: 122, w: 170)
        place(send, bounds.height - 52, row, x: width - 230, w: 230)
        if moved { needsDisplay = true }
    }
}
