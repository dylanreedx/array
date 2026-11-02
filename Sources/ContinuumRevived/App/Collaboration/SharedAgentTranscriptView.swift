import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// A teammate's view of a shared agent's transcript, drawn by the renderer the
/// owner's tile uses (`AgentTranscriptDocumentFeed.makeSurface`), from the
/// owner's own document as the mirror rebuilt it. Nothing here re-describes a
/// block: tools, subagents, plans, diffs and markup render exactly as they do
/// on the host. Only the render context differs: there is no supervisor here,
/// so provider requests show as history and local files do not open.
@MainActor
final class SharedAgentTranscriptView: NSView {
    typealias Wire = SharedAgentTranscriptWire
    typealias Lane = Collaboration.AgentTranscript

    let surface: any AgentTranscriptSurface
    private let toolDetailStore = AgentToolDetailStore()
    private var feed = AgentTranscriptDocumentFeed()
    private(set) var mirror = Wire.Mirror()
    private(set) var cursor: Lane.Cursor?
    private(set) var renderError: (any Error)?
    private(set) var appliedFrames = 0
    private(set) var installedCheckpoints = 0
    /// transcript-subagents: live status for `.agentReference` chips and
    /// message senders. Unavailable until a resolver is supplied.
    var agentStatus: AgentReferenceStatusSource = .unavailable { didSet { refreshRenderContext() } }
    var agentMessageSenders: AgentMessageSenderSource = .unavailable { didSet { refreshRenderContext() } }
    /// transcript-characters: a chip's or message card's character and pose,
    /// from the roster's facts. Unavailable still draws the id's own character, idle.
    var agentCharacters: AgentCharacterSource = .unavailable { didSet { refreshRenderContext() } }
    var onRevealAgent: ((_ agentID: UUID, _ parentAgentID: UUID) -> Void)?
    var onOpenWebLink: ((URL, AgentLinkOpenTarget) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        surface = AgentTranscriptDocumentFeed.makeSurface(toolDetailStore: toolDetailStore)
        super.init(frame: frameRect)
        addSubview(surface)
        setAccessibilityElement(false)
        refreshRenderContext()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if surface.frame != bounds { surface.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshRenderContext()
    }

    /// The document as rendered (what parity compares with the host tile's).
    var qaMirrorDocument: AgentDocument { mirror.document }

    /// Applies one lane read. Returns false when the mirror needs a resnapshot:
    /// the cursor is dropped and the next read starts over. Never guesses.
    @discardableResult
    func receive(_ read: Lane.Read) -> Bool {
        var next = mirror
        var touched = Wire.Mirror.Touched()
        var position: Lane.Cursor?
        do {
            let frames: [Lane.Frame]
            switch read {
            case let .resnapshot(checkpoint, list, _):
                let body = try Wire.decode(Wire.Checkpoint.self, from: checkpoint.body)
                touched = try next.install(body)
                position = .init(generation: checkpoint.generation, through: checkpoint.through)
                installedCheckpoints += 1
                frames = list
            case let .frames(generation, list, _):
                guard let cursor, cursor.generation == generation else { self.cursor = nil; return false }
                position = cursor
                frames = list
            }
            for frame in frames {
                guard let at = position, frame.generation == at.generation else { throw Wire.Mirror.Failure.schema }
                if frame.sequence <= at.through { continue }
                guard frame.sequence == at.through + 1 else { throw Wire.Mirror.Failure.schema }
                let step = try next.apply(try Wire.decode(Wire.Patch.self, from: frame.body))
                touched.ids.formUnion(step.ids); touched.structural = touched.structural || step.structural
                position = .init(generation: at.generation, through: frame.sequence)
                appliedFrames += 1
            }
        } catch {
            renderError = error
            cursor = nil
            return false
        }
        cursor = position
        guard next != mirror else { return true }
        mirror = next
        present(touched)
        return true
    }

    /// Another agent: forget this one's document.
    func reset() {
        guard cursor != nil || !mirror.document.entries.isEmpty else { return }
        mirror = Wire.Mirror(); cursor = nil
        present(.init(ids: [], structural: true))
    }

    private func present(_ touched: Wire.Mirror.Touched) {
        do {
            try feed.present(mirror.document.entries, touched: touched.ids, structural: touched.structural, final: true, to: surface)
            renderError = nil
        } catch {
            renderError = error
        }
    }

    private func refreshRenderContext() {
        try? surface.updateRenderContext(AgentRenderContext(
            actions: AgentRenderActions { [weak self] action in self?.perform(action) },
            tokens: .transcript,
            appearance: effectiveTokenTheme,
            agentStatus: agentStatus,
            agentMessageSenders: agentMessageSenders,
            agentCharacters: agentCharacters,
            // No runner answers a provider request from here: approvals and
            // questions read as history, with no buttons that cannot work.
            canRespondToRequests: false))
    }

    /// Read-only. Local paths belong to the owner's Mac and do not open here.
    private func perform(_ action: AgentRenderAction) {
        switch action {
        case let .activateLink(_, url, target): onOpenWebLink?(url, target)
        case let .revealAgent(_, agentID, parentAgentID): onRevealAgent?(agentID, parentAgentID)
        default: break
        }
    }
}
