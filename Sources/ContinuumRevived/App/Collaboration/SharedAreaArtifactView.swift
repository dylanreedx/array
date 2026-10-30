import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// Read-only view of one shared artifact (COL-16). It shows exactly one
/// revision: the live latest by default, or a revision pinned for review. The
/// two never merge, and an approval is reported against its own revision.
/// Bytes come verified from the service into memory; nothing here can touch a
/// checkout. One text view renders the whole entry (no per-line views).
@MainActor
final class SharedAreaArtifactView: NSView {
    typealias Artifact = Collaboration.Artifact
    let controller: SharedAreaController
    let person: SharedArea.ID<SharedArea.Person>
    private(set) var object: SharedArea.ID<SharedArea.Object>?
    private(set) var state: Artifact.State?
    private(set) var contents: CollaborationArtifactContents?
    /// nil follows the live latest; a value stays on that revision.
    private(set) var pinned: SharedArea.ID<Artifact.RevisionTag>?
    private(set) var selectedPath: String?
    private(set) var loads = 0
    var summaryText: String { summary.stringValue }
    var applicabilityText: String { applicability.stringValue }
    var coverageText: String { coverage.stringValue }
    var renderedText: String { text.string }
    var renderedStorage: NSAttributedString? { text.textStorage.map { NSAttributedString(attributedString: $0) } }
    private(set) var loadTask: Task<Void, Never>?

    private let summary = NSTextField(labelWithString: "")
    private let applicability = NSTextField(labelWithString: "")
    private let coverage = NSTextField(wrappingLabelWithString: "")
    private let revisionChoice = ChoiceButton(title: "Revision")
    private let entryChoice = ChoiceButton(title: "Files")
    private let reviewChoice = ChoiceButton(title: "Review")
    private let text = NSTextView()
    private let scroll = NSScrollView()
    private var lastHead: Artifact.Head?
    private var generation = 0
    override var isFlipped: Bool { true }

    init(controller: SharedAreaController, person: SharedArea.ID<SharedArea.Person>) {
        self.controller = controller; self.person = person
        super.init(frame: .zero)
        isHidden = true
        summary.font = .token(.label); summary.lineBreakMode = .byTruncatingTail
        applicability.font = .token(.label); applicability.lineBreakMode = .byTruncatingTail
        coverage.font = .token(.label); coverage.maximumNumberOfLines = 3
        text.isEditable = false; text.isSelectable = true; text.isRichText = true
        text.font = .token(.bodyMono); text.textContainerInset = .init(width: 8, height: 8)
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = text
        revisionChoice.onSelection = { [weak self] item in self?.selectRevision(item.id) }
        entryChoice.onSelection = { [weak self] item in self?.selectedPath = item.id; self?.render() }
        reviewChoice.onSelection = { [weak self] item in self?.review(item.id) }
        for view in [summary, applicability, coverage, revisionChoice, entryChoice, reviewChoice, scroll] { addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Shared artifact")
        applyAppearance()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called on every selection change; nil or a non-artifact hides the view.
    func show(object value: SharedArea.ID<SharedArea.Object>?, in document: SharedArea.Document?) {
        let visible = value != nil && document?.items.contains(where: { $0.id == value && $0.kind == .artifact }) == true
        if isHidden == visible { isHidden = !visible; superview?.needsLayout = true }
        guard visible else {
            if object != nil { generation += 1; loadTask?.cancel(); object = nil; state = nil; contents = nil; pinned = nil; lastHead = nil }
            return
        }
        guard value != object else { return }
        generation += 1; loadTask?.cancel()
        object = value; state = nil; contents = nil; pinned = nil; selectedPath = nil
        lastHead = controller.artifactHeads.first { $0.object == value }
        render(); load()
    }

    /// Authority frames carry each artifact's head. Only a change for this
    /// object refetches; following-latest also moves to the new revision.
    func headsChanged(_ heads: [Artifact.Head]) {
        guard let object, !isHidden else { return }
        let head = heads.first { $0.object == object }
        guard head != lastHead else { return }
        lastHead = head
        load()
    }

    private func load() {
        guard let object else { return }
        guard let transport = controller.artifactTransport else {
            summary.stringValue = "Connect to read this artifact"; applicability.stringValue = ""; return
        }
        generation += 1
        let current = generation, revision = pinned
        loadTask = Task { [weak self] in
            do {
                let state = try await transport.artifactState(object: object.rawValue)
                let target = revision ?? state.latest?.manifest.id
                var contents: CollaborationArtifactContents?
                if let target { contents = try await transport.readArtifact(object: object.rawValue, revision: target.rawValue) }
                guard let self, current == self.generation else { return }
                self.loads += 1
                self.state = state; self.contents = contents
                if self.selectedPath == nil || contents?.record.manifest.entries.contains(where: { $0.path == self.selectedPath }) != true {
                    self.selectedPath = contents?.record.manifest.entries.first { $0.coverage == .included }?.path
                }
                self.render()
            } catch {
                guard let self, current == self.generation else { return }
                self.summary.stringValue = "This artifact is unavailable"
                self.applicability.stringValue = "It may have been unpublished, or your access changed."
                self.text.string = ""; self.contents = nil
            }
        }
    }

    private func render() {
        guard let state else {
            summary.stringValue = object == nil ? "" : "Loading artifact…"
            applicability.stringValue = ""; coverage.stringValue = ""; text.string = ""
            revisionChoice.items = []; entryChoice.items = []; reviewChoice.items = []
            return
        }
        guard let record = contents?.record else {
            summary.stringValue = "No revision published yet"
            applicability.stringValue = "The owner's snapshot has not been uploaded."
            coverage.stringValue = ""; text.string = ""; revisionChoice.items = []; entryChoice.items = []; reviewChoice.items = []
            return
        }
        let latest = state.latest?.sequence ?? record.sequence
        summary.stringValue = record.sequence == latest
            ? "Revision \(record.sequence) · live latest" + (pinned != nil ? " · pinned for review" : "")
            : "Revision \(record.sequence) · pinned for review · latest is revision \(latest)"
        let summaryRow = state.revisions.first { $0.id == record.manifest.id }
        applicability.stringValue = Self.describe(summaryRow?.applicability, sequence: { id in state.revisions.first { $0.id == id }?.sequence })
        let reviews = state.reviews.filter { $0.review.revision == record.manifest.id }
        let elsewhere = state.reviews.filter { $0.review.revision != record.manifest.id }
        let d = record.manifest.declaration
        var lines = [Self.range(d) + " · " + Self.counts(record.manifest)]
        if !reviews.isEmpty { lines.append(reviews.map { Self.reviewLine($0, mine: $0.review.author == person) }.joined(separator: "; ")) }
        if !elsewhere.isEmpty { lines.append(elsewhere.count == 1 ? "1 review on another revision does not apply here" : "\(elsewhere.count) reviews on other revisions do not apply here") }
        coverage.stringValue = lines.joined(separator: "\n")
        revisionChoice.items = [ChoiceItem(id: "latest", title: "Follow latest", detail: "Revision \(latest)")]
            + state.revisions.reversed().map { row in
                ChoiceItem(id: row.id.rawValue.uuidString, title: "Revision \(row.sequence)",
                           detail: Self.describe(row.applicability, sequence: { id in state.revisions.first { $0.id == id }?.sequence }))
            }
        revisionChoice.setPresentationTitle("Revision \(record.sequence)")
        entryChoice.items = record.manifest.entries.map { entry in
            ChoiceItem(id: entry.path, title: entry.path, detail: entry.coverage == .included ? entry.change.rawValue : "\(entry.coverage.rawValue) · not included",
                       enabled: entry.coverage == .included)
        }
        entryChoice.selectedID = selectedPath
        entryChoice.setPresentationTitle(selectedPath.map { "File · " + $0 } ?? "Files")
        let writable = controller.canSubmit
        reviewChoice.items = [
            ChoiceItem(id: "approve", title: "Approve revision \(record.sequence)", detail: "Pinned to these exact bytes", enabled: writable),
            ChoiceItem(id: "requestChanges", title: "Request changes on revision \(record.sequence)", enabled: writable)
        ]
        reviewChoice.setPresentationTitle("Review")
        guard let path = selectedPath, let entry = record.manifest.entries.first(where: { $0.path == path }),
              let bytes = contents?.bytes[path] else { text.string = "No included content in this revision."; return }
        let body = String(decoding: bytes, as: UTF8.self)
        if entry.mediaType == "text/x-diff" {
            text.textStorage?.setAttributedString(DiffReviewTileNSView.render(GitDiffParser.parse(body), theme: effectiveTokenTheme))
        } else {
            text.textStorage?.setAttributedString(NSAttributedString(string: body, attributes: [
                .font: NSFont.token(.bodyMono), .foregroundColor: TextToken.textPrimary.color.nsColor(in: self)]))
        }
    }

    private func selectRevision(_ id: String) { showRevision(id == "latest" ? nil : UUID(uuidString: id).map { .init($0) }) }
    /// nil follows the live latest; a revision stays pinned until changed.
    func showRevision(_ revision: SharedArea.ID<Artifact.RevisionTag>?) { pinned = revision; load() }
    var textBackground: NSColor { text.backgroundColor }
    /// Approving pins the view to the approved revision so the person keeps
    /// looking at what they approved when the owner publishes a new one.
    private func review(_ verdict: String) {
        guard let object, let record = contents?.record, let transport = controller.artifactTransport,
              let epoch = controller.scope?.epoch, let value = Artifact.Verdict(rawValue: verdict) else { return }
        pinned = record.manifest.id
        Task { [weak self] in
            do {
                _ = try await transport.reviewArtifact(object: object.rawValue,
                    request: .init(epoch: epoch, revision: record.manifest.id, verdict: value, note: ""))
                self?.load()
            } catch { self?.applicability.stringValue = "The review could not be saved. Your access may have changed." }
        }
    }

    static func describe(_ value: Artifact.Applicability?, sequence: (SharedArea.ID<Artifact.RevisionTag>) -> UInt64?) -> String {
        switch value {
        case .current?: return "Current · matches the owner's latest snapshot"
        case .superseded(let newer)?: return "Superseded by revision \(sequence(newer).map(String.init) ?? "?") · reviews here do not carry forward"
        case .sourceChanged?: return "Source changed on the owner's Mac · not applicable"
        case nil: return ""
        }
    }
    private static func range(_ d: Artifact.Declaration) -> String {
        switch d.range {
        case .files: return "Saved file contents"
        case .workingTree: return d.includesUntracked ? "Working tree with selected untracked files" : "Working tree vs HEAD"
        case .staged: return "Staged changes"
        case .branch: return "Committed branch changes only"
        }
    }
    private static func counts(_ m: Artifact.Manifest) -> String {
        let included = m.entries.filter { $0.coverage == .included }.count
        var parts = ["\(included) included"]
        if m.entries.count > included { parts.append("\(m.entries.count - included) declared without content") }
        let omitted = m.declaration.omittedChangedPaths + m.declaration.omittedUntrackedPaths
        if omitted > 0 { parts.append("\(omitted) not shared") }
        return parts.joined(separator: ", ")
    }
    private static func reviewLine(_ value: Artifact.ReviewState, mine: Bool) -> String {
        let who = mine ? "You" : "A teammate"
        let verb = value.review.verdict == .approve ? "approved" : value.review.verdict == .requestChanges ? "requested changes on" : "commented on"
        let still: String
        switch value.applicability {
        case .current: still = ""
        case .superseded: still = " (superseded)"
        case .sourceChanged: still = " (no longer applies)"
        }
        return "\(who) \(verb) this revision\(still)"
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        func place(_ view: NSView, _ frame: NSRect) { if view.frame != frame { view.frame = frame } }
        place(summary, .init(x: 0, y: 0, width: w, height: 18))
        place(applicability, .init(x: 0, y: 20, width: w, height: 18))
        place(coverage, .init(x: 0, y: 40, width: w, height: 46))
        // The inspector is narrow: two short choices share a row and the
        // file path gets the full width so it does not truncate early.
        let half = (w - 6) / 2, row = ChoiceButton.controlHeight + 6
        place(revisionChoice, .init(x: 0, y: 90, width: half, height: ChoiceButton.controlHeight))
        place(reviewChoice, .init(x: half + 6, y: 90, width: half, height: ChoiceButton.controlHeight))
        place(entryChoice, .init(x: 0, y: 90 + row, width: w, height: ChoiceButton.controlHeight))
        let top = 90 + 2 * row
        place(scroll, .init(x: 0, y: top, width: w, height: max(40, bounds.height - top)))
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance(); render() }
    private func applyAppearance() {
        summary.textColor = TextToken.textPrimary.color.nsColor(in: self)
        for label in [applicability, coverage] { label.textColor = TextToken.textSecondary.color.nsColor(in: self) }
        text.backgroundColor = SurfaceToken.tileBody.color.nsColor(in: self)
    }
}
