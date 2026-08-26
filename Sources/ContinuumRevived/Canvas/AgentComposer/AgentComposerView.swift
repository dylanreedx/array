import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// A view-owned snapshot of composer editing state. Tiles bind to this value;
/// they do not reach through the composer to mutate its NSTextView.
struct AgentComposerDraft: Equatable {
    var text: String
    var selection: NSRange
    var revision: UInt64
    var imageAttachments: [AgentPromptImageAttachment] = []
    var fileReferences: [AgentPromptFileReference] = []

    static let empty = AgentComposerDraft(text: "", selection: NSRange(location: 0, length: 0), revision: 0, imageAttachments: [], fileReferences: [])
}

/// Presentation-only composer variants (P4.10 owner direction). The full-turn
/// composer is the agent tile's command surface; the compact freeform shell is
/// the reusable response surface reviewed ahead of any provider response-mode
/// contract. The variant changes shell presentation only — intent, draft-store,
/// history, and action wiring are identical across variants, and nothing here
/// fabricates a response contract that `AgentRequestPayload` does not expose.
enum AgentComposerVariant {
    case fullTurn
    case compactFreeform

    var maximumVisibleLines: Int {
        switch self {
        case .fullTurn: return 8
        case .compactFreeform: return 4
        }
    }

    /// The compact shell completes references only; command completion stays a
    /// full-turn affordance.
    var completionTriggers: Set<Character> {
        switch self {
        case .fullTurn: return AgentCompletionQueryDetector.supportedTriggers
        case .compactFreeform: return ["@", "$"]
        }
    }

    var placeholder: String {
        switch self {
        case .fullTurn: return "Send a prompt to the agent…"
        case .compactFreeform: return "Write a response…"
        }
    }
}

/// Restricts an existing suggestion source to a variant's triggers without
/// duplicating provider logic. An excluded trigger yields no suggestions, so the
/// surface simply never opens for it.
private struct TriggerRestrictedCompletionSource: AgentCompletionSuggestionSource {
    let base: any AgentCompletionSuggestionSource
    let triggers: Set<Character>

    func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        guard triggers.contains(query.trigger) else { return [] }
        return await base.suggestions(for: query)
    }
}

/// Isolated custom composer shell. The surface and focus treatment are owned here
/// while `ComposerTextView` remains the native editing engine.
@MainActor
final class AgentComposerView: NSView, TokenThemed, ComposerTextViewObserver {
    let variant: AgentComposerVariant
    let textView: ComposerTextView
    private(set) var scrollView: NSScrollView
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let attachmentRail: ComposerImageAttachmentRailView
    private let attachmentRailHeightConstraint: NSLayoutConstraint
    private let fileReferenceRail: ComposerFileReferenceRailView
    private let fileReferenceRailHeightConstraint: NSLayoutConstraint
    private let replyOptionRail: ComposerReplyOptionRailView
    private let replyOptionRailHeightConstraint: NSLayoutConstraint
    private var replyOptions: [String] = []
    /// B4 — Array's own follow-up queue, rendered as chips above the composer.
    private let queuedMessageRail: ComposerQueuedMessageRailView
    private let queuedMessageRailHeightConstraint: NSLayoutConstraint
    /// Callbacks the tile wires to `AgentSupervisor`. Direct manipulation of
    /// Array's queue, never the turn in flight.
    var onCancelQueuedMessage: ((UUID) -> Void)?
    var onClearQueuedMessages: (() -> Void)?
    private var attachmentStore: AgentComposerAttachmentStore?
    private var importedAttachments: [AgentPromptImageAttachment] = []
    private var importedFileReferences: [AgentPromptFileReference] = []
    private var imageImportFailureCount = 0
    private var imageImportFailureCategories: [String] = []

    var onDraftChange: ((AgentComposerDraft) -> Void)?
    /// Existing fire-and-forget seam retained until live-tile migration. It does
    /// not imply acceptance and therefore never clears a persisted draft.
    var onSubmitPrompt: ((String) -> Void)?
    /// An acceptance-aware seam for owners that can synchronously accept/reject
    /// send intent. Only `true` clears the per-agent draft.
    var onSubmitIntent: ((String) -> Bool)?
    /// Semantic completion actions that belong to a provider adapter. Returning
    /// true means the action was accepted; a rejected action leaves the query
    /// text intact and never degrades into literal prompt text.
    var onCompletionAction: ((AgentCompletionPayload) -> Bool)?
    var onDismissSuggestions: (() -> Void)?
    /// Synchronous visual acknowledgement seam. Fired before draft-journal or
    /// attachment awaits so the transcript can respond in the submit frame.
    var onSubmissionStarted: ((AgentPrompt) -> Void)?
    var onSubmissionFinished: ((Bool) -> Void)?
    private(set) var draft: AgentComposerDraft = .empty
    private let completionController = CompletionPopoverController()
    // Keep an unbound composer useful as a real surface too. Managed tiles bind
    // their checkout-aware registry later, while palette/component surfaces can
    // still discover Array/provider commands without a separate wiring step.
    private var completionSource: any AgentCompletionSuggestionSource =
        AgentCompletionProviderRegistry(providers: [AgentCommandCompletionProvider()]
            + AgentCompletionFixtures.providers().filter { $0.providerID != "fixture.commands" })
    private var completionContext: AgentCompletionContext?
    /// `@` browsing state belongs to the live composer surface, never the draft.
    private var completionNavigationPath: String?
    private var draftStore: AgentComposerDraftStore?
    private var draftAgentID: AgentID?
    private weak var actionSink: (any AgentTileActionSink)?
    private var turnSnapshot: AgentTileTurnSnapshot?
    private var actionTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var submissionLease: AgentComposerSubmissionLease?
    private var submissionReleaseTask: Task<Void, Never>?
    private var pendingSubmittedPrompt: String?
    private var pendingSubmittedDraft: AgentComposerDraft?
    private var pendingSubmittedDraftAgentID: AgentID?
    private var pendingSubmittedLease: AgentComposerSubmissionLease?
    /// Deterministic component-check seam immediately before the draft-store
    /// actor await. Production leaves this nil; checks use it to cancel/rebind
    /// while lease admission is suspended without relying on scheduler timing.
    var qaBeforeSubmissionLeaseAcquisition: (() -> Void)?
    /// Deterministic component-check seam immediately before the sink handoff.
    /// Production leaves this nil; checks use it to cross cancellation/rebind
    /// after lease installation without relying on scheduler timing.
    var qaBeforeSubmissionSinkHandoff: (() -> Void)?
    /// Monotonic binding identity for every async composer task. Agent ID alone
    /// is insufficient when the same composer view is rebound more than once.
    private var bindingGeneration: UInt64 = 0
    private(set) var isEditorFocused = false
    private var isApplyingDraft = false
    private let heightController: ComposerHeightController

    static let cornerRadius = CGFloat(AgentTileRadius.composer)
    static let internalPadding = CGFloat(Space.l)
    static let idleBorderWidth: CGFloat = 1
    static let focusedBorderWidth: CGFloat = 2
    static let maximumVisibleLines = AgentComposerVariant.fullTurn.maximumVisibleLines
    static let compactMaximumVisibleLines = AgentComposerVariant.compactFreeform.maximumVisibleLines

    init(frame frameRect: NSRect, variant: AgentComposerVariant) {
        self.variant = variant
        heightController = ComposerHeightController(
            maximumVisibleLines: variant.maximumVisibleLines
        )
        textView = ComposerTextView(frame: .zero)
        scrollView = NSScrollView(frame: .zero)
        attachmentRail = ComposerImageAttachmentRailView(frame: .zero)
        attachmentRailHeightConstraint = attachmentRail.heightAnchor.constraint(equalToConstant: 0)
        fileReferenceRail = ComposerFileReferenceRailView(frame: .zero)
        fileReferenceRailHeightConstraint = fileReferenceRail.heightAnchor.constraint(equalToConstant: 0)
        replyOptionRail = ComposerReplyOptionRailView(frame: .zero)
        replyOptionRailHeightConstraint = replyOptionRail.heightAnchor.constraint(equalToConstant: 0)
        queuedMessageRail = ComposerQueuedMessageRailView(frame: .zero)
        queuedMessageRailHeightConstraint = queuedMessageRail.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = false

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        attachmentRail.translatesAutoresizingMaskIntoConstraints = false
        attachmentRail.onRemoveAttachment = { [weak self] attachment in
            self?.removeAttachment(attachment)
        }
        fileReferenceRail.translatesAutoresizingMaskIntoConstraints = false
        fileReferenceRail.onRemove = { [weak self] reference in
            self?.removeFileReference(reference)
        }
        replyOptionRail.translatesAutoresizingMaskIntoConstraints = false
        replyOptionRail.onSelect = { [weak self] option in
            self?.acceptReplyOption(option)
        }
        queuedMessageRail.translatesAutoresizingMaskIntoConstraints = false
        queuedMessageRail.onRemove = { [weak self] messageID in
            self?.onCancelQueuedMessage?(messageID)
        }
        queuedMessageRail.onClearAll = { [weak self] in
            self?.onClearQueuedMessages?()
        }
        addSubview(replyOptionRail)
        addSubview(fileReferenceRail)
        addSubview(attachmentRail)
        addSubview(queuedMessageRail)
        addSubview(scrollView)

        placeholderLabel.stringValue = variant.placeholder
        placeholderLabel.font = .token(.body)
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.setAccessibilityElement(false)
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            replyOptionRailHeightConstraint,
            replyOptionRail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.internalPadding),
            replyOptionRail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.internalPadding),
            replyOptionRail.topAnchor.constraint(equalTo: topAnchor),
            fileReferenceRailHeightConstraint,
            fileReferenceRail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.internalPadding),
            fileReferenceRail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.internalPadding),
            fileReferenceRail.topAnchor.constraint(equalTo: replyOptionRail.bottomAnchor),
            attachmentRailHeightConstraint,
            attachmentRail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.internalPadding),
            attachmentRail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.internalPadding),
            attachmentRail.topAnchor.constraint(equalTo: fileReferenceRail.bottomAnchor),
            queuedMessageRailHeightConstraint,
            queuedMessageRail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.internalPadding),
            queuedMessageRail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.internalPadding),
            queuedMessageRail.topAnchor.constraint(equalTo: attachmentRail.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.internalPadding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.internalPadding),
            scrollView.topAnchor.constraint(equalTo: queuedMessageRail.bottomAnchor, constant: Self.internalPadding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.internalPadding),
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor),
        ])

        textView.composerObserver = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readabilityOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        textView.applyTokens()
        updatePlaceholder()
        applyTokens()
    }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, variant: .fullTurn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        // Reads the last layout-pass measurement only. Measuring here would
        // mutate the text container while AppKit may be querying intrinsic size
        // inside a live window display transaction, and the invalidated layout
        // then resizes the text view mid-display — an uncaught AppKit
        // needs-display-during-display exception that killed the v2 boot at the
        // P5.5 installed-candidate launch. Before the first layout pass, fall
        // back to one line of the current font without touching TextKit state.
        let editorHeight: CGFloat
        if let measurement = heightController.measurement {
            editorHeight = measurement.visibleEditorHeight
        } else {
            let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            editorHeight = textView.layoutManager?.defaultLineHeight(for: font)
                ?? ceil(font.ascender - font.descender + font.leading)
        }
        let railHeight = attachmentRail.isHidden ? 0 : ComposerImageAttachmentRailView.railHeight + Self.internalPadding
        let fileRailHeight = fileReferenceRail.isHidden ? 0 : ComposerFileReferenceRailView.railHeight
        let optionRailHeight = replyOptionRail.isHidden ? 0 : ComposerReplyOptionRailView.railHeight
        let queuedRailHeight = queuedMessageRail.isHidden ? 0 : ComposerQueuedMessageRailView.railHeight
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: editorHeight + (Self.internalPadding * 2) + railHeight + fileRailHeight + optionRailHeight + queuedRailHeight
        )
    }

    override func layout() {
        super.layout()
        updateEditorGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            completionController.dismiss()
        } else if isEditorFocused {
            refreshCompletionSuggestions()
        }
    }

    override func becomeFirstResponder() -> Bool {
        // Delegate to the editor WITHOUT reentering makeFirstResponder from
        // inside the window's own makeFirstResponder pass — the outer pass
        // re-installs this shell over the editor after the reentrant call
        // returns, leaving a first responder with no caret that drops
        // keystrokes. Accept, then hand off once the pass has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === self else { return }
            window.makeFirstResponder(self.textView)
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the shell's padding ring must land in the editor, and the
        // event must be CONSUMED: forwarding to super walks the responder chain
        // up to the canvas, whose mouseDown deselects the tile and takes first
        // responder back — the "first click does nothing" of the P5.5 live
        // finding (defect 5). The ring is the only thing this shell hit-tests
        // to itself, so nothing else loses the event.
        window?.makeFirstResponder(textView)
    }

    /// Attaches persistence to agent identity rather than tile identity. Calling
    /// this again is the detach/re-attach seam: the newly bound agent's local
    /// draft replaces the editor contents when its load completes.
    func bindAttachmentStore(_ store: AgentComposerAttachmentStore, agentID: AgentID) {
        cancelActionTaskForRebind()
        bindingGeneration &+= 1
        attachmentStore = store
        draftAgentID = agentID
    }

    func bindDraftStore(_ store: AgentComposerDraftStore, agentID: AgentID) {
        cancelActionTaskForRebind()
        bindingGeneration &+= 1
        let generation = bindingGeneration
        draftStore = store
        draftAgentID = agentID
        let releaseTask = submissionReleaseTask
        submissionReleaseTask = nil
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            await releaseTask?.value
            // A relaunch can occur after the supervisor accepted a prompt but
            // before Pi emitted the first turn-start. Recover the durable
            // submission journal before reading the ordinary draft file. A
            // journal still owned by a live submission is deliberately left
            // untouched; completion/error recovery owns that decision.
            let recoveryState = try? await store.submissionRecoveryState(for: agentID)
            let shouldRecover: Bool
            if case .some(.pending(active: true)) = recoveryState {
                shouldRecover = false
            } else if case .some(.confirming(active: true)) = recoveryState {
                shouldRecover = false
            } else {
                shouldRecover = true
            }
            let recovered = shouldRecover ? (try? await store.restoreSubmission(for: agentID)) ?? nil : nil
            let hasRecovery = await store.hasSubmissionRecovery(for: agentID)
            guard !Task.isCancelled, let self,
                  self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            let stored: ContinuumRevivedCore.AgentComposerDraft?
            if let recovered {
                stored = recovered
            } else if hasRecovery {
                // Keep the ordinary draft hidden while recovery is blocked; a
                // later rebind/relaunch gets another chance without losing refs.
                stored = nil
            } else {
                stored = await store.load(for: agentID)
            }
            guard !Task.isCancelled, self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            guard let stored else {
                self.importedAttachments = []
                self.importedFileReferences = []
                self.updateAttachmentRail()
                self.updateFileReferenceRail()
                self.apply(.empty)
                return
            }
            var resolved: [AgentPromptImageAttachment] = []
            let boundAttachmentStore = self.attachmentStore
            if let boundAttachmentStore {
                for attachment in stored.imageAttachments {
                    guard !Task.isCancelled,
                          self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
                    if let storedAttachment = try? await boundAttachmentStore.storedAttachment(for: attachment.attachmentID) {
                        guard !Task.isCancelled,
                              self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
                        resolved.append(storedAttachment.promptAttachment)
                    }
                }
            }
            guard !Task.isCancelled, self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            let resolvedFileReferences = self.resolvedFileReferences(from: stored.fileReferences)
            self.importedAttachments = resolved
            self.importedFileReferences = resolvedFileReferences
            self.updateAttachmentRail()
            self.updateFileReferenceRail()
            self.apply(AgentComposerDraft(
                text: stored.text,
                selection: NSRange(
                    location: stored.selection.lowerBound,
                    length: stored.selection.count
                ),
                revision: 0,
                imageAttachments: resolved,
                fileReferences: resolvedFileReferences
            ))
        }
    }

    private func isCurrentBinding(agentID: AgentID, generation: UInt64) -> Bool {
        draftAgentID == agentID && bindingGeneration == generation
    }

    /// Runtime command/file/skill adapters replace the bounded fixture registry at
    /// this host-local seam. Query text and path suggestions never enter sync data.
    func bindCompletionRegistry(_ registry: AgentCompletionProviderRegistry) {
        bindCompletionSource(registry)
    }

    /// Compiles the agent-owned history seam before P5.4 binds this composer into
    /// the live tile. History remains host-local and separate from draft storage.
    func bindPromptHistory(_ history: AgentPromptHistory, agentID: AgentID) {
        pendingSubmittedPrompt = nil
        textView.bindPromptHistory(history, agentID: agentID)
    }

    /// Binds execution by agent identity. Rebinding cancels only the UI's wait for
    /// acceptance; it never cancels an accepted agent action or the agent itself.
    func bindActionSink(
        _ sink: any AgentTileActionSink,
        agentID: AgentID,
        snapshot: AgentTileTurnSnapshot
    ) {
        cancelActionTaskForRebind()
        bindingGeneration &+= 1
        actionSink = sink
        draftAgentID = agentID
        turnSnapshot = snapshot
    }

    func updateTurnSnapshot(_ snapshot: AgentTileTurnSnapshot) {
        turnSnapshot = snapshot
    }

    /// B4 — pending chips for Array's own follow-up queue. `paused` mirrors
    /// `AgentSupervisor.isQueuePaused(for:)`: held after an interrupted turn so
    /// the chips do not imply they are about to run.
    func updateQueuedMessages(_ messages: [AgentComposerQueuedMessage], paused: Bool) {
        queuedMessageRail.setMessages(messages, paused: paused)
        queuedMessageRailHeightConstraint.constant = messages.isEmpty ? 0 : ComposerQueuedMessageRailView.railHeight
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func unbindActionSink() {
        cancelActionTaskForRebind()
        bindingGeneration &+= 1
        actionSink = nil
        turnSnapshot = nil
        updateQueuedMessages([], paused: false)
    }

    private func cancelActionTaskForRebind() {
        actionTask?.cancel()
        actionTask = nil
        guard let lease = submissionLease, let store = draftStore else { return }
        submissionLease = nil
        let releaseTask = Task {
            await store.relinquishSubmission(for: lease.agentID, ownership: lease)
            _ = try? await store.restoreSubmission(for: lease.agentID, ownership: lease)
        }
        submissionReleaseTask = releaseTask
        clearPendingSubmission(lease)
    }

    /// Stop follows the same acceptance-aware sink as send. The future primary
    /// action control calls this rather than reaching into AgentSupervisor.
    func requestStop() {
        submitBoundIntent(.stop, submittedPrompt: nil, submittedRevision: draft.revision)
    }

    func apply(_ newDraft: AgentComposerDraft) {
        let utf16Count = (newDraft.text as NSString).length
        let location = min(max(newDraft.selection.location, 0), utf16Count)
        let length = min(max(newDraft.selection.length, 0), utf16Count - location)
        let safeSelection = NSRange(location: location, length: length)

        isApplyingDraft = true
        if textView.string != newDraft.text { textView.string = newDraft.text }
        textView.setSelectedRange(safeSelection)
        importedAttachments = newDraft.imageAttachments
        importedFileReferences = newDraft.fileReferences
        updateAttachmentRail()
        updateFileReferenceRail()
        draft = AgentComposerDraft(
            text: newDraft.text,
            selection: safeSelection,
            revision: newDraft.revision,
            imageAttachments: importedAttachments,
            fileReferences: importedFileReferences
        )
        isApplyingDraft = false
        updatePlaceholder()
        updateReplyOptionRail()
        editorContentsChanged()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = AgentSurfaceRole.composer.color.cgColor(for: theme)
        layer?.borderColor = (isEditorFocused ? AgentLineRole.focusRing : .decorativeHairline).color.cgColor(for: theme)
        layer?.borderWidth = isEditorFocused ? Self.focusedBorderWidth : Self.idleBorderWidth
        placeholderLabel.font = .token(.body)
        placeholderLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        // Update existing draft attributes as well as typing attributes so
        // TextKit line metrics follow token/readability changes immediately.
        let editorFont = NSFont.token(.body)
        textView.font = editorFont
        if let textStorage = textView.textStorage, textStorage.length > 0 {
            textStorage.addAttribute(
                .font, value: editorFont,
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        textView.applyTokens()
        textView.layoutManager?.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0),
            actualCharacterRange: nil
        )
        editorContentsChanged()
    }

    @objc private func readabilityOptionsDidChange(_ notification: Notification) {
        applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func composerTextDidChange(_ textView: ComposerTextView) {
        publishDraftChange()
        updatePlaceholder()
        // The chips withdraw as soon as there is a draft, and come back if the
        // user clears it again.
        updateReplyOptionRail()
        editorContentsChanged()
        refreshCompletionSuggestions()
    }

    func composerSelectionDidChange(_ textView: ComposerTextView) {
        publishDraftChange()
        refreshCompletionSuggestions()
    }

    func composerRequestedAttachmentImport(
        _ textView: ComposerTextView,
        intake: ComposerPasteboardIntake
    ) {
        importFileReferences(intake.fileReferences)
        importImages(intake.images)
    }

    private func importImages(_ decoded: [ComposerDecodedImagePasteboardItem]) {
        guard !decoded.isEmpty else { return }
        guard let attachmentStore, let agentID = draftAgentID else {
            recordImageImportFailures(decoded.count, category: "attachment-store-unavailable")
            return
        }
        let generation = bindingGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            var failures = 0
            for item in decoded {
                guard self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
                do {
                    let validation = try AgentComposerImageValidation(
                        validatedContentType: item.managedContentType,
                        pixelWidth: item.pixelWidth,
                        pixelHeight: item.pixelHeight,
                        byteCount: item.byteCount
                    )
                    let stored: AgentComposerStoredAttachment
                    switch item.source {
                    case .data(let data):
                        stored = try await attachmentStore.importValidatedPastedImage(
                            data, displayName: item.suggestedFilename,
                            validation: validation, forDraftOf: agentID
                        )
                    case .fileURL(let url):
                        stored = try await attachmentStore.importValidatedLocalImageFile(
                            url, displayName: item.suggestedFilename,
                            validation: validation, forDraftOf: agentID
                        )
                    }
                    guard self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
                    self.importedAttachments.append(stored.promptAttachment)
                } catch {
                    // Keep successful siblings, but do not let a rejected item
                    // turn the whole user interaction into an unexplained no-op.
                    failures += 1
                }
            }
            if failures > 0 {
                self.recordImageImportFailures(failures, category: "attachment-store-rejected")
            }
            self.updateAttachmentRail()
            self.publishDraftChange()
            self.editorContentsChanged()
        }
    }

    private func importFileReferences(_ decoded: [AgentPromptFileReference]) {
        guard draftAgentID != nil else { return }
        guard !decoded.isEmpty else { return }
        // Reference-only: no bytes are read or copied. Dedup by path so the same
        // file dropped twice is one chip.
        addFileReferences(decoded)
    }

    private func recordImageImportFailures(_ count: Int, category: String) {
        guard count > 0 else { return }
        imageImportFailureCount += count
        imageImportFailureCategories.append(contentsOf: repeatElement(category, count: count))
        // Deliberately omit filenames, paths, bytes, prompt text, and the raw
        // Error description: attachment-store errors can carry local context.
        NSLog("AgentComposerView: %ld image attachment import(s) failed [%@]", count, category)
    }

    func composerFocusDidChange(_ textView: ComposerTextView, focused: Bool) {
        isEditorFocused = focused
        applyTokens()
        if focused {
            refreshCompletionSuggestions()
        } else {
            completionController.dismiss()
        }
    }

    func composerHasSendableAttachments(_ textView: ComposerTextView) -> Bool {
        !importedAttachments.isEmpty || !importedFileReferences.isEmpty
    }

    func composerRequestedSend(_ textView: ComposerTextView) {
        let prompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !importedAttachments.isEmpty || !importedFileReferences.isEmpty else { return }
        if let snapshot = turnSnapshot, actionSink != nil, draftAgentID != nil {
            let resolver = AgentComposerIntentState(
                executionState: snapshot.executionState,
                capabilities: snapshot.capabilities
            )
            let intent: AgentComposerIntent?
            if !importedAttachments.isEmpty || !importedFileReferences.isEmpty {
                let attachedPrompt = AgentPrompt(
                    text: prompt,
                    imageAttachments: importedAttachments,
                    fileReferences: importedFileReferences
                )
                switch snapshot.executionState {
                case .ready:
                    intent = .sendPrompt(attachedPrompt)
                case .working:
                    // Honest resolution, not a forced send: a mid-turn attachment
                    // must go through the same steer/queue gate as text alone, or
                    // be refused, rather than blindly retrying `.sendPrompt` while
                    // a turn is running (which the supervisor refuses as
                    // `.turnNotReady`, rolling back the optimistic bubble).
                    intent = resolver.workingDraftIntent(prompt: attachedPrompt)
                }
            } else {
                intent = snapshot.executionState == .working
                    ? resolver.workingDraftIntent(draft: prompt)
                    : resolver.primaryIntent(draft: prompt)
            }
            guard let intent else { return }
            submitBoundIntent(
                intent,
                submittedPrompt: prompt,
                submittedRevision: draft.revision
            )
        } else if let onSubmitIntent {
            pendingSubmittedPrompt = nil
            guard onSubmitIntent(prompt) else { return }
            completeAcceptedSend(prompt)
        } else if let onSubmitPrompt {
            pendingSubmittedPrompt = prompt
            onSubmitPrompt(prompt)
        }
    }

    /// Lets an asynchronous/fire-and-forget owner acknowledge acceptance later.
    /// A click or rejected request must not call this method.
    func acceptCurrentSendIntent() {
        guard let prompt = pendingSubmittedPrompt else { return }
        completeAcceptedSend(prompt)
    }

    func composerRequestedCompletionCommand(
        _ textView: ComposerTextView,
        command: ChoiceListCommand
    ) -> Bool {
        if command == .ascend {
            return ascendCompletionNavigation(in: textView)
        }
        if command == .accept,
           let active = AgentCompletionQueryDetector.activeQuery(
               in: textView.string,
               selection: textView.selectedRange()
           ), active.trigger == "@", active.text.isEmpty,
              let root = completionContext?.checkoutRoot.standardizedFileURL,
              let current = completionNavigationURL(checkoutRoot: root),
              current.path != "/" {
            // Return can arrive during the same refresh gap as Backspace. The
            // synthetic `../` row is always first in a nested empty-query scope,
            // so accepting it while the replacement panel is still loading is
            // equivalent to selecting that row. A stale panel can still expose
            // the previous scope's focused directory for one event; its
            // breadcrumb cannot match the current navigation path.
            let expectedBreadcrumb = completionBreadcrumb(
                directory: current,
                checkoutRoot: root
            )
            let panelIsCurrent = completionController.isPresented
                && completionController.qaBreadcrumb == expectedBreadcrumb
            let focusedTitle = completionController.qaFocusedTitle
            if !panelIsCurrent || focusedTitle == "../" {
                return ascendCompletionNavigation(in: textView)
            }
        }
        return completionController.perform(command)
    }

    private func ascendCompletionNavigation(in textView: ComposerTextView) -> Bool {
        guard let active = AgentCompletionQueryDetector.activeQuery(
            in: textView.string,
            selection: textView.selectedRange()
        ), active.trigger == "@", active.text.isEmpty,
              let root = completionContext?.checkoutRoot.standardizedFileURL,
              let current = completionNavigationURL(checkoutRoot: root),
              current.path != "/" else { return false }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        completionNavigationPath = completionNavigationPath(
            for: parent,
            checkoutRoot: root
        )
        refreshCompletionSuggestions()
        return true
    }

    private func completionNavigationURL(checkoutRoot: URL) -> URL? {
        guard let path = completionNavigationPath, !path.isEmpty else { return checkoutRoot }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return checkoutRoot.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    private func completionNavigationPath(
        for directory: URL,
        checkoutRoot: URL
    ) -> String? {
        let directory = directory.standardizedFileURL
        if directory.path == checkoutRoot.path { return nil }
        if directory.path.hasPrefix(checkoutRoot.path + "/") {
            return String(directory.path.dropFirst(checkoutRoot.path.count + 1))
        }
        return directory.path
    }

    private func completionBreadcrumb(directory: URL, checkoutRoot: URL) -> String {
        if directory.path == checkoutRoot.path
            || directory.path.hasPrefix(checkoutRoot.path + "/") {
            let relative = directory.path == checkoutRoot.path
                ? ""
                : String(directory.path.dropFirst(checkoutRoot.path.count + 1))
            return (["Home"] + relative
                .split(separator: "/").map(String.init)).joined(separator: "  ›  ")
        }
        let homeComponents = checkoutRoot.pathComponents
        let directoryComponents = directory.pathComponents
        var commonCount = 0
        while commonCount < min(homeComponents.count, directoryComponents.count),
              homeComponents[commonCount] == directoryComponents[commonCount] {
            commonCount += 1
        }
        let ascents = Array(
            repeating: "..",
            count: max(0, homeComponents.count - commonCount)
        )
        let descendants = directoryComponents.dropFirst(commonCount)
            .filter { $0 != "/" }
        return (["Home"] + ascents + descendants).joined(separator: "  ›  ")
    }

    func composerRequestedDismissSuggestions(_ textView: ComposerTextView) {
        completionController.dismiss()
        onDismissSuggestions?()
    }

    private func refreshCompletionSuggestions() {
        guard isEditorFocused, window != nil else {
            completionController.dismiss()
            return
        }
        let activeQuery = AgentCompletionQueryDetector.activeQuery(
            in: textView.string,
            selection: textView.selectedRange()
        )
        if activeQuery?.trigger != "@" { completionNavigationPath = nil }
        completionController.update(
            text: textView.string,
            selection: textView.selectedRange(),
            source: TriggerRestrictedCompletionSource(
                base: completionSource,
                triggers: variant.completionTriggers
            ),
            context: completionContext,
            navigationPath: completionNavigationPath,
            anchor: completionAnchor(),
            relativeTo: textView
        ) { [weak self] completion, replacementRange in
            self?.acceptCompletion(completion, replacementRange: replacementRange)
        }
    }

    private func acceptCompletion(_ completion: AgentCompletion, replacementRange: NSRange) {
        switch completion.payload {
        case .insertText:
            assertionFailure("Text completions are applied by CompletionPopoverController")
        case let .file(reference):
            textView.insertCompletion("", replacementRange: replacementRange)
            addFileReferences([reference])
        case let .directory(target):
            guard let root = completionContext?.checkoutRoot.standardizedFileURL else { return }
            let directory = target.directoryURL.standardizedFileURL
            guard directory.isFileURL else { return }
            let nextNavigationPath = completionNavigationPath(
                for: directory,
                checkoutRoot: root
            )
            // TextKit reports replacement and selection changes synchronously.
            // Those callbacks refresh completion state, and can clear a newly
            // assigned navigation path while the query is between its old text
            // and the replacement `@`. Commit the target only after that native
            // replacement cycle completes.
            textView.insertCompletion("@", replacementRange: replacementRange)
            completionNavigationPath = nextNavigationPath
            DispatchQueue.main.async { [weak self] in self?.refreshCompletionSuggestions() }
        case .skill, .promptTemplate, .runtimeCommand, .command:
            guard onCompletionAction?(completion.payload) == true else { return }
            // Fix 2a: a command picked from this popover used to skip the
            // optimistic echo that `submitBoundIntent` paints for a typed send,
            // so invoking the exact same command two ways produced two
            // different appearances — silent here, an immediate bubble there.
            // Echo the same text a typed acceptance would have shown.
            if case let .command(invocation) = completion.payload {
                let echoText = invocation.arguments.isEmpty
                    ? completion.insertionText
                    : "\(completion.insertionText) \(invocation.arguments.joined(separator: " "))"
                onSubmissionStarted?(AgentPrompt(echoText))
            }
            textView.insertCompletion("", replacementRange: replacementRange)
        }
    }

    private func completionAnchor() -> NSRect {
        guard let window else { return .zero }
        let length = (textView.string as NSString).length
        let location = min(max(textView.selectedRange().location, 0), length)
        let screenRect = textView.firstRect(
            forCharacterRange: NSRange(location: location, length: 0),
            actualRange: nil
        )
        var localRect = textView.convert(window.convertFromScreen(screenRect), from: nil)
        localRect.size.width = max(localRect.width, 1)
        localRect.size.height = max(localRect.height, textView.font?.pointSize ?? 1)
        return localRect
    }

    private func publishDraftChange() {
        guard !isApplyingDraft else { return }
        let textChanged = textView.string != draft.text
        draft = AgentComposerDraft(
            text: textView.string,
            selection: textView.selectedRange(),
            revision: textChanged ? draft.revision &+ 1 : draft.revision,
            imageAttachments: importedAttachments,
            fileReferences: importedFileReferences
        )
        onDraftChange?(draft)
        if let draftStore, let draftAgentID {
            let persisted = ContinuumRevivedCore.AgentComposerDraft(
                text: draft.text,
                selection: draft.selection.location..<(draft.selection.location + draft.selection.length),
                updatedAt: Date(),
                imageAttachments: importedAttachments.map { AgentComposerDraftImageAttachment(metadata: $0.metadata) },
                fileReferences: persistedFileReferences()
            )
            Task { await draftStore.save(persisted, for: draftAgentID) }
        }
    }

    /// Reference-only draft projection: the path IS the payload, so it persists
    /// directly (host-local draft store, never synced) — no managed-store id.
    private func persistedFileReferences() -> [AgentComposerDraftFileReference] {
        importedFileReferences.map {
            AgentComposerDraftFileReference(
                displayName: $0.displayName,
                contentType: $0.contentType,
                path: $0.fileURL.path
            )
        }
    }

    /// Rebuilds live file references from a persisted draft, dropping any whose
    /// file no longer exists or is unreadable (a reference is only useful if the
    /// agent can still Read it).
    private func resolvedFileReferences(
        from persisted: [AgentComposerDraftFileReference]
    ) -> [AgentPromptFileReference] {
        persisted.compactMap { stored in
            let url = URL(fileURLWithPath: stored.path)
            guard FileManager.default.isReadableFile(atPath: stored.path) else { return nil }
            return AgentPromptFileReference(
                displayName: stored.displayName,
                contentType: stored.contentType,
                fileURL: url
            )
        }
    }

    /// Completes the pre-handoff failure path for the exact lease that this
    /// composer acquired. Relinquishing first records the token-qualified
    /// authority required by the store's restore guard; no unqualified caller
    /// can consume another live composer's journal.
    private func restorePreHandoffSubmission(
        _ lease: AgentComposerSubmissionLease,
        store: AgentComposerDraftStore,
        agentID: AgentID,
        generation: UInt64
    ) async {
        await store.relinquishSubmission(for: agentID, ownership: lease)
        guard let restored = try? await store.restoreSubmission(for: agentID, ownership: lease) else {
            if isCurrentBinding(agentID: agentID, generation: generation) {
                clearPendingSubmission(lease)
            }
            return
        }
        guard isCurrentBinding(agentID: agentID, generation: generation) else { return }
        await applyPersistedDraft(
            restored,
            agentID: agentID,
            generation: generation
        )
        guard isCurrentBinding(agentID: agentID, generation: generation) else { return }
        clearPendingSubmission(lease)
    }

    private func submitBoundIntent(
        _ intent: AgentComposerIntent,
        submittedPrompt: String?,
        submittedRevision: UInt64
    ) {
        guard actionTask == nil, let actionSink, let agentID = draftAgentID else { return }
        let generation = bindingGeneration
        let isPromptSubmission: Bool
        if case .sendPrompt = intent { isPromptSubmission = true } else { isPromptSubmission = false }
        let previewPrompt: AgentPrompt?
        switch intent {
        case let .send(text): previewPrompt = AgentPrompt(text)
        case let .sendPrompt(prompt): previewPrompt = prompt
        default: previewPrompt = nil
        }
        if let previewPrompt { onSubmissionStarted?(previewPrompt) }
        actionTask = Task { @MainActor [weak self, weak actionSink] in
            var reportedResolution = false
            // Install this before any actor await. An exclusive-lease rejection,
            // cancellation, or bind change must never strand this composer latch.
            defer {
                if let self, self.isCurrentBinding(agentID: agentID, generation: generation) {
                    self.actionTask = nil
                    if previewPrompt != nil, !reportedResolution {
                        self.onSubmissionFinished?(false)
                    }
                }
            }
            guard let self, self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            let draftStore = self.draftStore
            var lease: AgentComposerSubmissionLease?
            if isPromptSubmission {
                do {
                    self.qaBeforeSubmissionLeaseAcquisition?()
                    guard let draftStore,
                          let acquired = try await draftStore.beginSubmissionLease(
                            for: agentID,
                            draft: self.currentPersistedDraft()
                          ) else { return }
                    lease = acquired
                    guard !Task.isCancelled,
                          self.isCurrentBinding(agentID: agentID, generation: generation) else {
                        await self.restorePreHandoffSubmission(
                            acquired,
                            store: draftStore,
                            agentID: agentID,
                            generation: generation
                        )
                        return
                    }
                    self.submissionLease = acquired
                    self.pendingSubmittedDraft = self.draft
                    self.pendingSubmittedDraftAgentID = agentID
                    self.pendingSubmittedLease = acquired
                    self.qaBeforeSubmissionSinkHandoff?()
                } catch {
                    return
                }
            }
            // After this point the sink owns the outcome and recovery must not
            // duplicate delivery or restore it speculatively.
            guard self.isCurrentBinding(agentID: agentID, generation: generation),
                  !Task.isCancelled,
                  let sink = actionSink else {
                if let lease, let draftStore {
                    await self.restorePreHandoffSubmission(
                        lease,
                        store: draftStore,
                        agentID: agentID,
                        generation: generation
                    )
                }
                return
            }
            // Clearing the pre-handoff lease marker is the ownership transition:
            // cancellation/rebind can no longer undo a handoff already in flight.
            self.submissionLease = nil
            let acceptance = await sink.accept(intent, for: agentID)
            if previewPrompt != nil {
                reportedResolution = true
                self.onSubmissionFinished?(acceptance == .accepted)
            }
            guard acceptance == .accepted else {
                if let lease, let draftStore {
                    // The sink may have suspended after this task cleared
                    // submissionLease. Refusal still owns the exact durable
                    // journal; restore it independently of the old view
                    // generation, then let generation gate only UI application.
                    await self.restorePreHandoffSubmission(
                        lease,
                        store: draftStore,
                        agentID: agentID,
                        generation: generation
                    )
                }
                return
            }
            guard self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            if let submittedPrompt {
                self.completeAcceptedSend(
                    submittedPrompt,
                    submittedRevision: submittedRevision,
                    retainRecoveryUntilStart: isPromptSubmission
                )
            }
        }
    }

    private func completeAcceptedSend(
        _ prompt: String,
        submittedRevision: UInt64? = nil,
        retainRecoveryUntilStart: Bool = false
    ) {
        textView.recordAcceptedPrompt(prompt)
        pendingSubmittedPrompt = nil
        if let submittedRevision {
            let currentPrompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard draft.revision == submittedRevision, currentPrompt == prompt else { return }
        }
        clearAcceptedDraft(retainRecoveryUntilStart: retainRecoveryUntilStart)
    }

    private func currentPersistedDraft() -> ContinuumRevivedCore.AgentComposerDraft {
        ContinuumRevivedCore.AgentComposerDraft(
            text: draft.text,
            selection: draft.selection.location..<(draft.selection.location + draft.selection.length),
            updatedAt: Date(),
            imageAttachments: importedAttachments.map { AgentComposerDraftImageAttachment(metadata: $0.metadata) },
            fileReferences: persistedFileReferences()
        )
    }

    private func applyPersistedDraft(
        _ persisted: ContinuumRevivedCore.AgentComposerDraft,
        agentID: AgentID,
        generation: UInt64
    ) async {
        guard !Task.isCancelled, isCurrentBinding(agentID: agentID, generation: generation) else { return }
        // Recovery is keyed by the durable draft references, not by whichever
        // tile happened to own the rail. Resolve the persisted list in order and
        // never filter it against the current tile's transient array.
        var resolved: [AgentPromptImageAttachment] = []
        let boundAttachmentStore = attachmentStore
        for reference in persisted.imageAttachments {
            guard !Task.isCancelled, isCurrentBinding(agentID: agentID, generation: generation) else { return }
            var didResolve = false
            if let boundAttachmentStore {
                do {
                    if let stored = try await boundAttachmentStore.storedAttachment(for: reference.attachmentID) {
                        guard !Task.isCancelled, isCurrentBinding(agentID: agentID, generation: generation) else { return }
                        resolved.append(stored.promptAttachment)
                        didResolve = true
                    }
                } catch {
                    // Keep the durable reference in the draft store; a later
                    // rebind can retry local capability resolution.
                }
            }
            guard !Task.isCancelled, isCurrentBinding(agentID: agentID, generation: generation) else { return }
            if !didResolve,
               let existing = importedAttachments.first(where: { $0.metadata.id == reference.attachmentID }) {
                resolved.append(existing)
            }
        }
        guard !Task.isCancelled, isCurrentBinding(agentID: agentID, generation: generation) else { return }
        let resolvedFileReferences = resolvedFileReferences(from: persisted.fileReferences)
        importedAttachments = resolved
        importedFileReferences = resolvedFileReferences
        apply(AgentComposerDraft(
            text: persisted.text,
            selection: NSRange(location: persisted.selection.lowerBound, length: persisted.selection.count),
            revision: draft.revision &+ 1,
            imageAttachments: resolved,
            fileReferences: resolvedFileReferences
        ))
    }

    private func clearPendingSubmission(_ lease: AgentComposerSubmissionLease) {
        guard pendingSubmittedLease == lease else { return }
        pendingSubmittedLease = nil
        pendingSubmittedDraft = nil
        pendingSubmittedDraftAgentID = nil
    }

    /// Called by the tile only after an authoritative successful turn
    /// completion. Queue acceptance and `.turnStarted` deliberately leave the
    /// recovery journal intact so a later provider/runtime error can restore it.
    func confirmPromptSubmissionCompleted() {
        guard let draftStore,
              let agentID = draftAgentID,
              pendingSubmittedDraft != nil,
              pendingSubmittedDraftAgentID == agentID else { return }
        let generation = bindingGeneration
        pendingSubmittedDraft = nil
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            do {
                let lease = self.pendingSubmittedLease
                let confirmed: Bool
                if let lease {
                    confirmed = try await draftStore.confirmSubmissionStarted(
                        for: agentID, ownership: lease
                    )
                } else {
                    confirmed = try await draftStore.confirmSubmissionStarted(for: agentID)
                }
                guard confirmed, self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
                self.pendingSubmittedDraftAgentID = nil
                self.pendingSubmittedLease = nil
            } catch {
                guard self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
                self.restorePromptSubmission(
                    using: draftStore,
                    agentID: agentID,
                    generation: generation
                )
            }
        }
    }

    /// Launch/start failures restore the exact durable draft and attachments.
    func restorePromptSubmission() {
        guard let draftStore, let agentID = draftAgentID else { return }
        restorePromptSubmission(using: draftStore, agentID: agentID, generation: bindingGeneration)
    }

    private func restorePromptSubmission(
        using draftStore: AgentComposerDraftStore,
        agentID: AgentID,
        generation: UInt64
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            if let restored = try? await draftStore.restoreSubmission(for: agentID) {
                guard self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
                await self.applyPersistedDraft(
                    restored,
                    agentID: agentID,
                    generation: generation
                )
            }
            guard self.isCurrentBinding(agentID: agentID, generation: generation) else { return }
            self.pendingSubmittedDraft = nil
            self.pendingSubmittedDraftAgentID = nil
            self.pendingSubmittedLease = nil
        }
    }

    private func clearAcceptedDraft(retainRecoveryUntilStart: Bool = false) {
        if !retainRecoveryUntilStart, let draftStore, let draftAgentID {
            Task { await draftStore.resolveSendIntent(for: draftAgentID, accepted: true) }
        }
        apply(.empty)
    }

    private func updateAttachmentRail() {
        attachmentRail.setItems(importedAttachments.map { ComposerImageAttachmentRailItem(attachment: $0) })
        attachmentRailHeightConstraint.constant = importedAttachments.isEmpty ? 0 : ComposerImageAttachmentRailView.railHeight
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The choices the last settled turn offered, from
    /// `AgentReplyOptionDetector`. The owner recomputes this per document
    /// version; the composer decides whether to SHOW them, because only it knows
    /// whether the user has already started writing.
    func setReplyOptions(_ options: [String]) {
        guard replyOptions != options else { return }
        replyOptions = options
        updateReplyOptionRail()
    }

    private func updateReplyOptionRail() {
        // An offer is for a reply not yet started. Once there is a draft — typed,
        // restored, or a chip already taken — the chips would be competing with
        // the user's own words, and pressing one would replace them.
        let visible = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? replyOptions : []
        replyOptionRail.setOptions(visible)
        replyOptionRailHeightConstraint.constant =
            visible.isEmpty ? 0 : ComposerReplyOptionRailView.railHeight
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Writes the choice into the editor as one undo unit, through the same
    /// primitive a completion uses — so the text arrives exactly as typed text
    /// does: the observer fires, the draft is journaled, and the send path sees
    /// nothing special. Deliberately does NOT send: the user presses send, and a
    /// wrongly-detected chip costs them a word to delete, not a turn.
    private func acceptReplyOption(_ option: String) {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertCompletion(option, replacementRange: fullRange)
        textView.window?.makeFirstResponder(textView)
    }

    private func updateFileReferenceRail() {
        fileReferenceRail.setReferences(importedFileReferences)
        fileReferenceRailHeightConstraint.constant = importedFileReferences.isEmpty ? 0 : ComposerFileReferenceRailView.railHeight
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func addFileReferences(_ references: [AgentPromptFileReference]) {
        var existingPaths = Set(importedFileReferences.map(\.fileURL.path))
        for reference in references where !existingPaths.contains(reference.fileURL.path) {
            existingPaths.insert(reference.fileURL.path)
            importedFileReferences.append(reference)
        }
        updateFileReferenceRail()
        publishDraftChange()
        editorContentsChanged()
    }

    private func removeFileReference(_ reference: AgentPromptFileReference) {
        importedFileReferences.removeAll { $0.fileURL.path == reference.fileURL.path }
        updateFileReferenceRail()
        publishDraftChange()
    }

    private func removeAttachment(_ attachment: AgentPromptImageAttachment) {
        importedAttachments.removeAll { $0.metadata.id == attachment.metadata.id }
        updateAttachmentRail()
        publishDraftChange()
        if let attachmentStore {
            Task { try? await attachmentStore.cleanupUnreferencedDraftAttachments(
                retaining: Set(importedAttachments.map { $0.metadata.id }), graceInterval: 60
            ) }
        }
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    private func editorContentsChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateEditorGeometry() {
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let previousHeight = heightController.measurement?.visibleEditorHeight
        let measurement = heightController.update(
            textView: textView, scrollView: scrollView, width: viewport.width
        )
        if let previousHeight, abs(previousHeight - measurement.visibleEditorHeight) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    // Deterministic AppKit probes; not a tile integration seam.
    var qaReplyOptionChipTitles: [String] { replyOptionRail.qaChipTitles }
    var qaDraftText: String { draft.text }
    @discardableResult
    func qaPressReplyOptionChip(titled title: String) -> Bool {
        replyOptionRail.qaPressChip(titled: title)
    }
    var qaFileReferenceCount: Int { importedFileReferences.count }
    var qaFileReferenceRailNames: [String] { fileReferenceRail.qaDisplayNames }
    var qaFileReferenceRailAccessibilityLabels: [String] { fileReferenceRail.qaAccessibilityLabels }
    var qaHasSendableAttachments: Bool { composerHasSendableAttachments(textView) }
    var qaImageAttachmentCount: Int { importedAttachments.count }
    var qaImageAttachmentContentTypes: [String?] { importedAttachments.map(\.metadata.contentType) }
    var qaImageImportFailureCount: Int { imageImportFailureCount }
    var qaImageImportFailureCategories: [String] { imageImportFailureCategories }

    /// Drives the exact method a completion accept — whether from a click, an
    /// arrow-navigated Enter, or typeahead — funnels through, so a check can
    /// exercise the real acceptance path without a live popover window.
    func qaAcceptCompletionForChecks(_ completion: AgentCompletion, replacementRange: NSRange) {
        acceptCompletion(completion, replacementRange: replacementRange)
    }

    func qaImportFileReferences(from pasteboard: NSPasteboard) {
        importFileReferences(ComposerFileReferencePasteboardDecoder.decodedReferences(from: pasteboard))
    }

    /// Test-only attachment injection that skips the pasteboard decode path —
    /// used to drive the mid-turn attachment intent witness without a real drag
    /// or paste.
    func qaAddFileReferenceForChecks(_ reference: AgentPromptFileReference) {
        addFileReferences([reference])
    }

    func qaRemoveFileReference(at index: Int) {
        guard importedFileReferences.indices.contains(index) else { return }
        removeFileReference(importedFileReferences[index])
    }

    func qaRemoveImageAttachment(at index: Int) {
        guard importedAttachments.indices.contains(index) else { return }
        removeAttachment(importedAttachments[index])
    }

    var qaFileReferences: [AgentPromptFileReference] { importedFileReferences }

    func qaResolveFileReferences(
        from persisted: [AgentComposerDraftFileReference]
    ) -> [AgentPromptFileReference] {
        resolvedFileReferences(from: persisted)
    }

    var qaPlaceholderVisible: Bool { !placeholderLabel.isHidden }
    var qaPlaceholderColor: NSColor? { placeholderLabel.textColor }
    var qaHeightMeasurement: ComposerHeightController.Measurement? { heightController.measurement }
    var qaCompletionIsPresented: Bool { completionController.isPresented }
    var qaCompletionTitles: [String] { completionController.qaTitles }
    var qaCompletionDetails: [String?] { completionController.qaDetails }
    var qaCompletionFocusedTitle: String? { completionController.qaFocusedTitle }
    var qaCompletionPanelFrame: NSRect? { completionController.qaPanelFrame }
    var qaCompletionBreadcrumb: String? { completionController.qaBreadcrumb }
    var qaCompletionFooter: String? { completionController.qaFooter }
    var qaCompletionFocusedRowIsVisible: Bool { completionController.qaFocusedRowIsVisible }
    var qaCompletionRequestStartCount: Int { completionController.qaRequestStartCount }
    var qaCompletionContext: AgentCompletionContext? { completionContext }

    func qaBindCompletionSource(_ source: any AgentCompletionSuggestionSource) {
        bindCompletionSource(source)
    }

    func qaBindCompletionContext(_ context: AgentCompletionContext?) {
        bindCompletionContext(context)
    }

    private func bindCompletionSource(_ source: any AgentCompletionSuggestionSource) {
        completionController.dismiss()
        completionSource = source
        refreshCompletionSuggestions()
    }

    func bindCompletionContext(_ context: AgentCompletionContext?) {
        completionController.dismiss()
        completionNavigationPath = nil
        completionContext = context
        refreshCompletionSuggestions()
    }
}
