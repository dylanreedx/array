import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Which agreement revision the selected agent's host last accepted, against
/// the area's current revision. It reports host acceptance only and offers no
/// send: a newer revision reaches an agent only through a deliberate handoff.
@MainActor
final class SharedAreaAgentFreshnessView: NSView {
    static let height: CGFloat = 112
    static let caveat = SharedAgentContextFreshness.caveat
    var statusText: String { status.stringValue }
    var noticeText: String { notice.stringValue }
    var caveatText: String { caveatLabel.stringValue }
    var statusColor: NSColor? { status.textColor }
    /// True when the caveat's full text fits its frame; it must never clip.
    var caveatFits: Bool {
        caveatLabel.cell?.cellSize(forBounds: .init(x: 0, y: 0, width: caveatLabel.frame.width, height: .greatestFiniteMagnitude)).height ?? .infinity
            <= caveatLabel.frame.height + 0.5
    }

    private let title = NSTextField(labelWithString: "Agreement context")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private let caveatLabel = NSTextField(wrappingLabelWithString: SharedAreaAgentFreshnessView.caveat)
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        isHidden = true
        title.font = .token(.label)
        status.font = .token(.label); status.maximumNumberOfLines = 2
        notice.font = .token(.label); notice.lineBreakMode = .byTruncatingTail
        caveatLabel.font = .token(.label); caveatLabel.maximumNumberOfLines = 2
        for view in [title, status, notice, caveatLabel] { addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent agreement context")
        applyAppearance()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(agent: SharedArea.ID<SharedArea.Object>?, in document: SharedArea.Document?, model: SharedAgentFreshnessModel?) {
        let visible = agent != nil && document?.items.contains(where: { $0.id == agent && $0.kind == .agentObservation }) == true
        if isHidden == visible { isHidden = !visible; superview?.needsLayout = true }
        guard visible, let agent, let document else { return }
        guard let model else {
            status.stringValue = "Agreement delivery is tracked on the agent's publishing host."
            notice.stringValue = ""; return
        }
        model.refreshIfNeeded(document)
        guard let entries = model.freshness(agent: agent, in: document) else {
            status.stringValue = "Waiting for the agent's host to confirm its current session."
            notice.stringValue = ""; return
        }
        guard !entries.isEmpty else {
            status.stringValue = "No working agreement in this workspace."
            notice.stringValue = ""; return
        }
        let several = entries.count > 1
        status.stringValue = entries.prefix(2).enumerated().map { index, entry in
            (several ? "Agreement \(index + 1): " : "") + entry.freshness.label
        }.joined(separator: "\n") + (entries.count > 2 ? " (+\(entries.count - 2) more)" : "")
        notice.stringValue = entries.lazy.compactMap { Self.notice($0.freshness, in: document) }.first ?? ""
    }

    /// In-flight and failed sends are reported beside the baseline, never as it.
    static func notice(_ freshness: SharedAgentContextFreshness, in document: SharedArea.Document) -> String? {
        func ordinal(_ context: SharedArea.Context?) -> String {
            // Freshness only folds prompts that carried a revision.
            guard let context else { return "A prompt" }
            let history = document.contexts.filter { $0.object == context.object }
            return history.firstIndex(of: context).map { "Revision \($0 + 1)" } ?? "A revision"
        }
        if let awaiting = freshness.awaitingHost { return "\(ordinal(awaiting.context)) is waiting for the host to accept it." }
        if let unresolved = freshness.unresolved {
            switch unresolved.phase {
            case .refused: return "\(ordinal(unresolved.command.context)) was refused by the host and was not delivered."
            case .uncertain: return "\(ordinal(unresolved.command.context)) has an unknown outcome. Array will not resend it."
            default: return nil
            }
        }
        return nil
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        title.frame = .init(x: 0, y: 0, width: width, height: 17)
        status.frame = .init(x: 0, y: 20, width: width, height: 32)
        notice.frame = .init(x: 0, y: 54, width: width, height: 17)
        caveatLabel.frame = .init(x: 0, y: 74, width: width, height: 36)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        for label in [title, status] { label.textColor = TextToken.textPrimary.color.nsColor(in: self) }
        for label in [notice, caveatLabel] { label.textColor = TextToken.textSecondary.color.nsColor(in: self) }
    }
}

/// How a discussion post shows a shared agent result: the post, the frozen
/// quote, exactly where it came from and what is known about that source now.
@MainActor
enum SharedAreaExcerptPresentation {
    static func entry(for post: SharedArea.Post, in document: SharedArea.Document, model: SharedAgentFreshnessModel?) -> String {
        guard let excerpt = post.excerpt else { return post.text }
        let availability = model.map { $0.availability(of: excerpt, in: document) }
            ?? excerpt.availability(in: document, currentGeneration: nil, currentArtifactRevision: { _ in nil })
        return [post.text, "", "Quoted agent result", "“\(excerpt.text)”", sourceLine(excerpt), availabilityText(availability)]
            .joined(separator: "\n")
    }
    static func sourceLine(_ excerpt: Collaboration.ResultExcerpt) -> String {
        let source = excerpt.source
        var parts = ["Turn \(source.turn)"]
        if let position = source.position { parts.append("event \(position.sequence)") }
        parts.append("host \(short(source.host.rawValue))")
        parts.append("session \(short(source.incarnation.hostGeneration))")
        if let artifact = source.artifact {
            parts.append("artifact revision \(short(artifact.revision)) (\(artifact.contentDigest.prefix(12)))")
        }
        return parts.joined(separator: " · ")
    }
    static func availabilityText(_ availability: Collaboration.ResultExcerpt.Availability) -> String {
        switch availability {
        case .linked: return "From the agent's current session."
        case .sourceRemoved: return "Original unavailable: the agent is no longer in this workspace."
        case .sourceReplaced: return "Original unavailable: the agent's session was replaced on its host."
        case .sourceUnchecked: return "Original not checked: the agent's host has not confirmed its session."
        case let .artifactChanged(current): return "The artifact changed after this quote (latest revision \(short(current)))."
        case .artifactRemoved: return "The quoted artifact is no longer shared."
        case .artifactUnchecked: return "The artifact's latest revision has not been checked."
        }
    }
    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
}

extension SharedAreaSceneView {
    /// Shares a frozen agent result into a discussion as one post. Only the
    /// agent's owner may; the reducer refuses anyone else. Nothing is sent to
    /// any agent.
    func shareResultExcerpt(_ excerpt: Collaboration.ResultExcerpt, into discussion: SharedArea.ID<SharedArea.Object>,
                            note: String) async -> SharedAreaController.Submission {
        guard let document = controller.document else { return .rejected(.notConnected) }
        let post = SharedArea.Post(id: .init(), object: discussion, author: person, text: note, excerpt: excerpt)
        return await controller.submit(.init(area: document.id, expectedRevision: document.revision, edits: [.post(post)]))
    }
}
