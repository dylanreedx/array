import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Endorsement and draft freshness for the selected working agreement. It
/// speaks only for the agreement's current revision, and it never sends
/// anything to an agent: an endorsement is a person's statement to people.
@MainActor
final class SharedAreaAgreementView: NSView {
    static let height: CGFloat = 108
    static let guidance = "Shared instructions for people and their agents. Array does not enforce them."
    let controller: SharedAreaController
    /// The scene flushes its editor, then rebases through the controller.
    var onRebaseDraft: (() -> Void)?
    private(set) var currentRevision: SharedArea.Context?
    var summaryText: String { summary.stringValue }
    var noticeText: String { notice.stringValue }
    var guidanceText: String { guidanceLabel.stringValue }
    var summaryColor: NSColor? { summary.textColor }
    var canEndorse: Bool { endorseButton.presentation.isEnabled }
    var canRebase: Bool { !rebaseButton.isHidden && rebaseButton.presentation.isEnabled }
    /// The panel's stops in the scene's keyboard order.
    var keyViews: [NSView] { [endorseButton, rebaseButton] }

    private let summary = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private let guidanceLabel = NSTextField(wrappingLabelWithString: SharedAreaAgreementView.guidance)
    private let endorseButton = ComposerActionButton(presentation: CollaborationHubView.action("Endorse", symbol: "checkmark.seal"))
    private let rebaseButton = ComposerActionButton(presentation: CollaborationHubView.action("Rebase draft", symbol: "arrow.triangle.branch"))
    private var revisionNumber = 0
    private var draftIsStale = false
    private var outcome = ""
    private var endorsing = false
    override var isFlipped: Bool { true }

    init(controller: SharedAreaController) {
        self.controller = controller
        super.init(frame: .zero)
        isHidden = true
        summary.font = .token(.label); summary.lineBreakMode = .byTruncatingTail
        notice.font = .token(.label); notice.lineBreakMode = .byTruncatingTail
        guidanceLabel.font = .token(.label); guidanceLabel.maximumNumberOfLines = 2
        endorseButton.target = self; endorseButton.action = #selector(endorseFromButton(_:))
        rebaseButton.target = self; rebaseButton.action = #selector(rebaseFromButton(_:))
        for view in [summary, endorseButton, rebaseButton, notice, guidanceLabel] { addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Working agreement endorsements")
        applyAppearance()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called whenever the scene's selection, document or draft changes.
    func show(agreement: SharedArea.ID<SharedArea.Object>?, in document: SharedArea.Document?, draft: SharedAreaLocalDraft?) {
        let visible = agreement != nil && document?.items.contains(where: { $0.id == agreement && $0.kind == .agreement }) == true
        if isHidden == visible { isHidden = !visible; superview?.needsLayout = true }
        guard visible, let agreement, let document else { currentRevision = nil; outcome = ""; return }
        let revisions = document.contexts.filter { $0.object == agreement }
        if currentRevision?.id != revisions.last?.id { outcome = "" }
        currentRevision = revisions.last; revisionNumber = revisions.count
        let endorsers = currentRevision.map { document.endorsements(of: $0.id).map(\.person) } ?? []
        let mine = endorsers.contains(controller.identity.person)
        if currentRevision == nil {
            setText(summary, "No revision yet · nothing to endorse")
        } else {
            setText(summary, "Revision \(revisionNumber) · " + Self.endorsementText(endorsers.count, includesYou: mine))
        }
        draftIsStale = currentRevision != nil && draft?.object == agreement && draft?.basedOn != currentRevision?.id
        // Endorsing disables the button a keyboard user just pressed.
        let heldFocus = CollaborationKeyLoop.holdFocus(in: window)
        defer { CollaborationKeyLoop.restoreFocus(heldFocus, in: window) }
        // Assign only on change: a reassigned presentation lays the button out
        // again, and this runs on every scene refresh, presence frames included.
        let endorse = CollaborationHubView.action(mine ? "Endorsed" : "Endorse revision \(revisionNumber)",
            symbol: mine ? "checkmark.seal.fill" : "checkmark.seal",
            enabled: currentRevision != nil && !mine && !endorsing && controller.canSubmit, loading: endorsing)
        if endorseButton.presentation != endorse { endorseButton.presentation = endorse }
        if rebaseButton.isHidden == draftIsStale { rebaseButton.isHidden = !draftIsStale }
        let rebase = CollaborationHubView.action("Rebase draft", symbol: "arrow.triangle.branch", enabled: draftIsStale)
        if rebaseButton.presentation != rebase { rebaseButton.presentation = rebase }
        setText(notice, draftIsStale
            ? "Your draft is based on an earlier revision. Read revision \(revisionNumber), then rebase."
            : outcome)
    }
    /// Unchanged text is not reassigned; a reassigned label lays out again.
    private func setText(_ field: NSTextField, _ value: String) { if field.stringValue != value { field.stringValue = value } }

    /// Endorses the revision this view is showing, never a newer one.
    func endorseCurrentRevision() async {
        guard let revision = currentRevision?.id, !endorsing else { return }
        endorsing = true; outcome = ""
        let result = await controller.endorse(revision)
        endorsing = false
        switch result {
        case .accepted: outcome = ""
        case .rejected(.conflict): outcome = "This agreement changed. Read the new revision before endorsing."
        case .rejected: outcome = "Could not endorse this revision."
        case .uncertain: outcome = "Delivery unknown. Check pending delivery."
        }
        notice.stringValue = outcome
    }

    static func endorsementText(_ count: Int, includesYou: Bool) -> String {
        guard count > 0 else { return "not endorsed yet" }
        let others = count - (includesYou ? 1 : 0)
        let teammates = others == 1 ? "1 teammate" : "\(others) teammates"
        if includesYou { return others == 0 ? "endorsed by you" : "endorsed by you and \(teammates)" }
        return "endorsed by \(teammates)"
    }

    @objc private func endorseFromButton(_ sender: Any?) { Task { [weak self] in await self?.endorseCurrentRevision() } }
    @objc private func rebaseFromButton(_ sender: Any?) { onRebaseDraft?() }

    override func layout() {
        super.layout()
        let width = bounds.width, button = min(160, max(80, (width - 8) / 2))
        summary.frame = .init(x: 0, y: 0, width: width, height: 18)
        endorseButton.frame = .init(x: 0, y: 22, width: button, height: ComposerActionButton.controlHeight)
        rebaseButton.frame = .init(x: button + 8, y: 22, width: button, height: ComposerActionButton.controlHeight)
        notice.frame = .init(x: 0, y: 58, width: width, height: 17)
        guidanceLabel.frame = .init(x: 0, y: 77, width: width, height: 30)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        summary.textColor = TextToken.textPrimary.color.nsColor(in: self)
        for label in [notice, guidanceLabel] { label.textColor = TextToken.textSecondary.color.nsColor(in: self) }
    }
}
