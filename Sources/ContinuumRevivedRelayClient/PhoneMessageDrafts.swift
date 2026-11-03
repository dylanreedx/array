import Foundation
import ContinuumRevivedRelayProtocol

/// What became of a message the phone sent an agent (plan 104 step 3).
public enum PhoneMessageDelivery: Equatable, Sendable {
    /// The agent took it.
    case accepted
    /// Queued at the relay; the Mac has not answered yet.
    case waiting
    /// Final: the Mac (or relay) said no. A new attempt needs a new seal.
    case refused(String)
    /// Not known to have arrived; resending the same sealed bytes is safe.
    case unreachable(String)
}

/// One agent's phone message: the text, and the request sealed for it.
/// A message is sealed once; a retry after a network failure resends the same
/// bytes under the same idempotency key, so the relay and the Mac's journal
/// keep it one command and the agent gets one prompt. Editing after a failure
/// starts a new message. The draft is kept until the Mac says the agent took it.
public struct PhoneMessageDraft: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var inFlight: RelayCommandRequest?
    public private(set) var delivery: PhoneMessageDelivery?
    public private(set) var sending = false
    private var sentText: String?

    public init() {}

    /// Sending, or the Mac has not answered yet: the text cannot change.
    public var locked: Bool { sending || delivery == .waiting }

    /// The key to ask the relay about while the Mac has not answered.
    public var pollKey: UUID? { delivery == .waiting ? inFlight?.idempotencyKey : nil }

    public mutating func edit(_ newText: String) {
        guard !locked else { return }
        text = newText
        // A failed send with different text is a new message.
        if let sentText, newText != sentText { inFlight = nil; self.sentText = nil }
    }

    /// The request to send: the one already sealed for this text, else a new
    /// seal. Nil when nothing could be sealed (the reason is in `delivery`).
    public mutating func beginSend(seal: (String) -> RelayCommandRequest?) -> RelayCommandRequest? {
        if inFlight == nil || sentText != text {
            inFlight = seal(text)
            sentText = text
        }
        guard let inFlight else {
            delivery = .refused("Pair this iPhone again from your Mac to send messages.")
            return nil
        }
        sending = true
        delivery = nil
        return inFlight
    }

    /// Records the answer for `key`. An answer for a message this draft has
    /// already moved past is ignored.
    public mutating func finish(_ result: PhoneMessageDelivery, for key: UUID) {
        guard inFlight?.idempotencyKey == key else { return }
        sending = false
        delivery = result
        switch result {
        case .accepted:
            text = ""; inFlight = nil; sentText = nil
        case .refused:
            // Final answer for that seal; the next try is a new message.
            inFlight = nil; sentText = nil
        case .waiting, .unreachable:
            break
        }
    }
}

/// The phone's drafts, one per agent, held by the app model rather than the
/// composer view: leaving an agent and coming back restores the text, the
/// waiting state and the same sealed request, so a resend keeps its key.
public struct PhoneMessageDrafts: Equatable, Sendable {
    private var byAgent: [UUID: PhoneMessageDraft] = [:]

    public init() {}

    public subscript(agentId: UUID) -> PhoneMessageDraft {
        get { byAgent[agentId] ?? PhoneMessageDraft() }
        set { byAgent[agentId] = newValue == PhoneMessageDraft() ? nil : newValue }
    }
}
