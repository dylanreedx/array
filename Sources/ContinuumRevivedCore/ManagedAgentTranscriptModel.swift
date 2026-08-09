import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import Foundation

public enum ManagedTranscriptCardKind: String, Codable, Equatable, Sendable {
    case message
    /// What YOU sent. Previously user prompts were faked as assistant content
    /// deltas, so they rendered in a card titled "assistant".
    case userMessage
    case toolCall
    case plan
    case diff
    case error
}

public struct ManagedTranscriptCard: Codable, Equatable, Sendable {
    public var id: String
    public var kind: ManagedTranscriptCardKind
    public var title: String
    public var body: String
    public var itemKind: ItemKind?
    public var status: ItemStatus?

    public init(
        id: String,
        kind: ManagedTranscriptCardKind,
        title: String,
        body: String = "",
        itemKind: ItemKind? = nil,
        status: ItemStatus? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.itemKind = itemKind
        self.status = status
    }
}

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.5-compatibility-pipeline-harness.md
//
// The migration seam, and nothing more than a seam.
//
// Two transcript projections exist during the 91 program: the card model below,
// and the semantic document P1.x builds in `ContinuumRevivedAgentContent`. Both
// consume the SAME `AgentRuntimeEvent` stream plus the same locally-authored
// echoes (a user prompt and a notice are not provider events — see
// `appendUserPrompt`). So the compatibility harness that replays a fixture must
// be able to drive either one without knowing which it holds; that is this
// protocol's whole job. It deliberately declares no document, block, patch or
// parser type: P0.5 gates the floor, it does not build the new model.
public protocol AgentTranscriptProjecting {
    init(threadId: String)
    mutating func ingest(_ event: AgentRuntimeEvent)
    mutating func appendUserPrompt(_ text: String)
    mutating func appendNotice(id: String, title: String, text: String)
    var currentStatus: AgentStatus { get }
    var activeToolCount: Int { get }
    /// The ordered, view-free description the compatibility floor is stated in.
    var compatibilityRows: [AgentTranscriptCompatibilityRow] { get }
}

/// One row of a transcript projection, reduced to what the migration floor is
/// allowed to depend on: order, identity, visible body, and completion status.
///
/// `kind` is a string key rather than `ManagedTranscriptCardKind` because the
/// document projection's block vocabulary is a different and larger one. The
/// floor pins the keys today's pipeline produces; it does not require the new
/// model to adopt this enum. Temporary by construction — it retires with the
/// compatibility-removal ticket.
public struct AgentTranscriptCompatibilityRow: Equatable, Sendable {
    public var id: String
    public var kind: String
    public var body: String
    public var status: ItemStatus?

    public init(id: String, kind: String, body: String, status: ItemStatus? = nil) {
        self.id = id
        self.kind = kind
        self.body = body
        self.status = status
    }
}

public struct ManagedAgentTranscriptModel: Equatable, Sendable {
    public var threadId: String { semanticProjection.threadId }
    public var document: AgentDocument { semanticProjection.document }
    public var cards: [ManagedTranscriptCard] {
        ManagedTranscriptCardProjection.project(
            document,
            itemKindsByItemID: legacyItemKindsByItemID,
            itemStatusesByItemID: legacyItemStatusesByItemID,
            rawMarkupSourcesByEntryID: semanticProjection.compatibilityMarkupSourcesByEntryID
        )
    }
    public var currentStatus: AgentStatus { semanticProjection.currentStatus }
    public var events: [AgentRuntimeEvent] { semanticProjection.events }
    public var activeToolCount: Int { semanticProjection.activeToolCount }
    public var streamingMarkupParseCount: Int { semanticProjection.streamingMarkupParseCount }
    public var nextStreamingMarkupParseDeadline: TimeInterval? { semanticProjection.nextStreamingMarkupParseDeadline }

    /// The semantic projection is the only mutable transcript owner. Legacy
    /// cards are rebuilt on read from its document; there is no second array to
    /// update, reconcile, or accidentally leave stale.
    private var semanticProjection: AgentTranscriptProjection
    /// Temporary compatibility metadata for a distinction the P1 semantic
    /// tool-call payload does not encode. This is not a second transcript:
    /// identity, order, title, body, and lifecycle remain document-derived.
    private var legacyItemKindsByItemID: [String: ItemKind] = [:]
    /// Diff and error payloads cannot represent completion status in the P1
    /// semantic schema. Retain that temporary legacy display metadata beside
    /// item kind while the card renderer remains live; transcript content and
    /// lifecycle are still owned exclusively by the document.
    private var legacyItemStatusesByItemID: [String: ItemStatus] = [:]
    private var hasSeenTurnStart = false

    public init(threadId: String) {
        semanticProjection = AgentTranscriptProjection(threadId: threadId)
    }

    public init(
        threadId: String,
        monotonicNow: @escaping @Sendable () -> TimeInterval
    ) {
        semanticProjection = AgentTranscriptProjection(threadId: threadId, monotonicNow: monotonicNow)
    }

    public mutating func ingest(_ event: AgentRuntimeEvent) {
        switch event {
        case .itemStarted(let tid, let itemID, let kind, _) where tid == threadId:
            legacyItemKindsByItemID[itemID] = kind
            legacyItemStatusesByItemID[itemID] = .inProgress
        case .itemCompleted(let tid, let itemID, let kind, let status) where tid == threadId:
            legacyItemKindsByItemID[itemID] = kind
            legacyItemStatusesByItemID[itemID] = status
        default:
            break
        }
        if case .turnStarted(let tid, _) = event, tid == threadId {
            hasSeenTurnStart = true
        }
        // The legacy bootstrap path emitted adjacent assistant deltas with
        // synthetic, differing turn IDs before the first real turnStarted.
        // Normalize only that historical prefix so it remains one semantic
        // entry/card; real provider turns retain their provider identity.
        if !hasSeenTurnStart,
           case .contentDelta(let tid, _, let streamKind, let delta) = event,
           tid == threadId {
            semanticProjection.ingest(.contentDelta(
                threadId: tid,
                turnId: "compatibility-bootstrap",
                streamKind: streamKind,
                delta: delta
            ))
        } else {
            semanticProjection.ingest(event)
        }
    }

    public mutating func appendUserPrompt(_ text: String) {
        semanticProjection.appendUserPrompt(text)
    }

    /// Echoes one accepted semantic prompt, including images, through the same
    /// projection used by provider history. The caller owns idempotence; this
    /// overload keeps local prompt/image blocks together rather than exposing
    /// transport paths to the transcript model.
    public mutating func appendUserPrompt(id: AgentNodeID, prompt: AgentPrompt) {
        do { _ = try semanticProjection.appendUserPrompt(id: id, prompt: prompt) }
        catch { /* fail closed; provider events remain authoritative */ }
    }

    public mutating func appendNotice(id: String, title: String, text: String) {
        semanticProjection.appendNotice(id: id, title: title, text: text)
    }

    @discardableResult
    public mutating func flushPendingStreamingMarkupIfDue() -> Bool {
        semanticProjection.flushPendingStreamingMarkupIfDue()
    }

    @discardableResult
    public mutating func flushPendingStreamingMarkup() -> Bool {
        semanticProjection.flushPendingStreamingMarkup()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadId == rhs.threadId
            && lhs.document == rhs.document
            && lhs.currentStatus == rhs.currentStatus
            && lhs.events == rhs.events
            && lhs.activeToolCount == rhs.activeToolCount
            && lhs.semanticProjection.compatibilityMarkupSourcesByEntryID == rhs.semanticProjection.compatibilityMarkupSourcesByEntryID
            && lhs.cards == rhs.cards
            && lhs.compatibilityRows == rhs.compatibilityRows
            && lhs.legacyItemKindsByItemID == rhs.legacyItemKindsByItemID
            && lhs.legacyItemStatusesByItemID == rhs.legacyItemStatusesByItemID
            && lhs.hasSeenTurnStart == rhs.hasSeenTurnStart
    }
}

extension ManagedAgentTranscriptModel: AgentTranscriptProjecting {
    public var compatibilityRows: [AgentTranscriptCompatibilityRow] {
        cards.map {
            AgentTranscriptCompatibilityRow(
                id: $0.id,
                kind: $0.kind.rawValue,
                body: $0.body,
                status: $0.status
            )
        }
    }
}
