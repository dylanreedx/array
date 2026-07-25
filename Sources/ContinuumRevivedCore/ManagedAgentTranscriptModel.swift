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

public struct ManagedAgentTranscriptModel: Equatable, Sendable {
    public private(set) var threadId: String
    public private(set) var cards: [ManagedTranscriptCard] = []
    public private(set) var currentStatus: AgentStatus = .configuring
    public private(set) var events: [AgentRuntimeEvent] = []

    private var activeToolCardIdsByItemId: [String: String] = [:]
    private var lastAssistantCardId: String?
    private var lastReasoningCardId: String?
    /// Bound on retained raw events. Status is derived from recent activity, so
    /// a window is sufficient — without this, a long-lived agent grows the
    /// array without limit and re-scans all of it on every ingest.
    private static let eventWindow = 400

    public init(threadId: String) {
        self.threadId = threadId
    }

    public var activeToolCount: Int { activeToolCardIdsByItemId.count }

    public mutating func ingest(_ event: AgentRuntimeEvent) {
        events.append(event)
        if events.count > Self.eventWindow { events.removeFirst(events.count - Self.eventWindow) }
        currentStatus = deriveAgentStatus(signals: deriveStatusSignals(from: events, threadId: threadId, engineStatus: .idle))

        switch event {
        case .turnStarted(let tid, _) where tid == threadId:
            // Each turn's assistant text is its own card. Without this reset,
            // a new turn's deltas append to the previous turn's card and the
            // whole conversation renders as one concatenated blob.
            endStreamingRuns()
        case .contentDelta(let tid, _, let streamKind, let delta) where tid == threadId:
            ingestContentDelta(streamKind: streamKind, delta: delta)
        case .itemStarted(let tid, let itemId, let kind, let title) where tid == threadId:
            ingestItemStarted(itemId: itemId, kind: kind, title: title)
        case .itemCompleted(let tid, let itemId, let kind, let status) where tid == threadId:
            ingestItemCompleted(itemId: itemId, kind: kind, status: status)
        case .turnCompleted(let tid, _, _, _) where tid == threadId:
            endStreamingRuns()
        default:
            break
        }
    }

    /// Appends the prompt the USER just submitted as its own card. Not an
    /// AgentRuntimeEvent: providers never emit user text, so a local echo must
    /// not ride the provider channel. Ends any open run so the agent's reply
    /// starts a fresh card below.
    public mutating func appendUserPrompt(_ text: String) {
        endStreamingRuns()
        cards.append(ManagedTranscriptCard(
            id: "user-\(cards.count + 1)", kind: .userMessage, title: "you", body: text))
        endStreamingRuns()
    }

    /// End any open assistant/reasoning card run so the NEXT delta starts a new
    /// card. Called at turn boundaries and whenever a different card kind is
    /// inserted — otherwise post-tool narration would append to the pre-tool
    /// assistant card and render above the tool call (out of order).
    private mutating func endStreamingRuns() {
        lastAssistantCardId = nil
        lastReasoningCardId = nil
    }

    private mutating func ingestContentDelta(streamKind: ContentStreamKind, delta: String) {
        switch streamKind {
        case .assistant:
            lastReasoningCardId = nil
            if let index = indexOfCard(id: lastAssistantCardId) {
                cards[index].body += delta
            } else {
                let id = "assistant-\(cards.count + 1)"
                cards.append(ManagedTranscriptCard(id: id, kind: .message, title: "assistant", body: delta))
                lastAssistantCardId = id
            }
        case .reasoning:
            lastAssistantCardId = nil
            if let index = indexOfCard(id: lastReasoningCardId) {
                cards[index].body += delta
            } else {
                let id = "reasoning-\(cards.count + 1)"
                cards.append(ManagedTranscriptCard(id: id, kind: .message, title: "reasoning", body: delta))
                lastReasoningCardId = id
            }
        case .commandOutput:
            endStreamingRuns()
            let id = "output-\(cards.count + 1)"
            cards.append(ManagedTranscriptCard(id: id, kind: .toolCall, title: "command output", body: delta, itemKind: .commandExecution, status: .inProgress))
        }
    }

    private mutating func ingestItemStarted(itemId: String, kind: ItemKind, title: String?) {
        // A tool/diff/plan/error card breaks any open assistant/reasoning run,
        // so subsequent narration forms a NEW card below this one.
        endStreamingRuns()
        let cardKind: ManagedTranscriptCardKind
        switch kind {
        case .plan:
            cardKind = .plan
        case .fileChange:
            cardKind = .diff
        case .error:
            cardKind = .error
        default:
            cardKind = .toolCall
        }
        let displayTitle = title ?? kind.rawValue
        let card = ManagedTranscriptCard(id: itemId, kind: cardKind, title: displayTitle, itemKind: kind, status: .inProgress)
        cards.append(card)
        if cardKind == .toolCall || cardKind == .diff || cardKind == .plan {
            activeToolCardIdsByItemId[itemId] = itemId
        }
    }

    private mutating func ingestItemCompleted(itemId: String, kind: ItemKind, status: ItemStatus) {
        if let index = indexOfCard(id: activeToolCardIdsByItemId[itemId] ?? itemId) {
            cards[index].status = status
            cards[index].itemKind = kind
        }
        activeToolCardIdsByItemId.removeValue(forKey: itemId)
    }

    private func indexOfCard(id: String?) -> Int? {
        guard let id else { return nil }
        return cards.firstIndex { $0.id == id }
    }
}
