import Foundation

extension Collaboration {
    /// Control of an already published source. Execution and provider login
    /// remain on `source.host`; this never imports an agent into the recipient.
    public struct AgentHandoffOffer: Codable, Equatable, Sendable {
        public let id: UUID
        public let recipient: SharedArea.ID<SharedArea.Person>
        public init(id: UUID, recipient: SharedArea.ID<SharedArea.Person>) { self.id = id; self.recipient = recipient }
    }
    public struct AgentControlState: Codable, Equatable, Sendable {
        public let area: SharedArea.ID<SharedArea.Area>
        public let object: SharedArea.ID<SharedArea.Object>
        public let source: SharedArea.Source
        public let hostGeneration: UUID
        public let epoch: Int64
        public var revision: UInt64
        public var controller: SharedArea.ID<SharedArea.Person>
        public var offer: AgentHandoffOffer?
        public init(area: SharedArea.ID<SharedArea.Area>, object: SharedArea.ID<SharedArea.Object>, source: SharedArea.Source,
                    hostGeneration: UUID, epoch: Int64, revision: UInt64, controller: SharedArea.ID<SharedArea.Person>, offer: AgentHandoffOffer? = nil) {
            self.area = area; self.object = object; self.source = source; self.hostGeneration = hostGeneration
            self.epoch = epoch; self.revision = revision; self.controller = controller; self.offer = offer
        }
    }
    public struct AgentHostRegistration: Codable, Equatable, Sendable {
        public let epoch: Int64
        public let object: SharedArea.ID<SharedArea.Object>
        public let generation: UUID
        public init(epoch: Int64, object: SharedArea.ID<SharedArea.Object>, generation: UUID) {
            self.epoch = epoch; self.object = object; self.generation = generation
        }
    }
    public enum AgentControlAction: Codable, Equatable, Sendable {
        case offer(AgentHandoffOffer)
        case accept(offer: UUID)
        case reclaim
    }
    public struct AgentControlMutation: Codable, Equatable, Sendable {
        public let id: UUID
        public let epoch: Int64
        public let expectedRevision: UInt64
        public let hostGeneration: UUID
        public let action: AgentControlAction
        public init(id: UUID = UUID(), epoch: Int64, expectedRevision: UInt64, hostGeneration: UUID, action: AgentControlAction) {
            self.id = id; self.epoch = epoch; self.expectedRevision = expectedRevision; self.hostGeneration = hostGeneration; self.action = action
        }
    }
    public enum AgentPromptMode: String, Codable, Sendable { case send, queue }
    public struct AgentPromptRequest: Codable, Equatable, Sendable {
        public let id: UUID
        public let epoch: Int64
        public let controlRevision: UInt64
        public let hostGeneration: UUID
        /// An agreement revision the prompt carries, when the sender chose one.
        /// Full access sends without one.
        public let contextRevision: SharedArea.ID<SharedArea.Revision>?
        public let text: String
        public let mode: AgentPromptMode
        public init(id: UUID = UUID(), epoch: Int64, controlRevision: UInt64, hostGeneration: UUID,
                    contextRevision: SharedArea.ID<SharedArea.Revision>? = nil, text: String, mode: AgentPromptMode = .send) {
            self.id = id; self.epoch = epoch; self.controlRevision = controlRevision; self.hostGeneration = hostGeneration
            self.contextRevision = contextRevision; self.text = text; self.mode = mode
        }
    }
    public enum AgentDispatchPhase: String, Codable, Sendable {
        case queued, claimed, dispatching, accepted, refused, uncertain
        public var isFinal: Bool { self == .accepted || self == .refused || self == .uncertain }
    }
    public struct AgentDispatchCommand: Codable, Equatable, Sendable {
        public let id: UUID
        public let area: SharedArea.ID<SharedArea.Area>
        public let object: SharedArea.ID<SharedArea.Object>
        public let source: SharedArea.Source
        public let requester: Identity
        public let epoch: Int64
        public let controlRevision: UInt64
        public let hostGeneration: UUID
        public let context: SharedArea.Context?
        public let text: String
        public let mode: AgentPromptMode
        public init(id: UUID, area: SharedArea.ID<SharedArea.Area>, object: SharedArea.ID<SharedArea.Object>, source: SharedArea.Source,
                    requester: Identity, epoch: Int64, controlRevision: UInt64, hostGeneration: UUID, context: SharedArea.Context?, text: String,
                    mode: AgentPromptMode = .send) {
            self.id = id; self.area = area; self.object = object; self.source = source; self.requester = requester; self.epoch = epoch
            self.controlRevision = controlRevision; self.hostGeneration = hostGeneration; self.context = context; self.text = text; self.mode = mode
        }
        /// Deliberate, immutable context plus authenticated human attribution.
        /// No local path, provider credential or hidden history is synthesized.
        public var promptText: String {
            guard let context else { return "From collaboration participant \(requester.person.rawValue.uuidString)\n\n---\n\(text)" }
            return "Shared context revision \(context.id.rawValue.uuidString)\nFrom collaboration participant \(requester.person.rawValue.uuidString)\n\n\(context.text)\n\n---\n\(text)"
        }
    }
    public struct AgentDispatchReceipt: Codable, Equatable, Sendable {
        public let command: AgentDispatchCommand
        public let phase: AgentDispatchPhase
        public let claimID: UUID?
        public init(command: AgentDispatchCommand, phase: AgentDispatchPhase, claimID: UUID? = nil) {
            self.command = command; self.phase = phase; self.claimID = claimID
        }
    }
    public struct AgentHostClaim: Codable, Equatable, Sendable {
        public let claimID: UUID
        public let hostGeneration: UUID
        public init(claimID: UUID, hostGeneration: UUID) { self.claimID = claimID; self.hostGeneration = hostGeneration }
    }
    public struct AgentHostOutcome: Codable, Equatable, Sendable {
        public let claim: AgentHostClaim
        public let phase: AgentDispatchPhase
        public init(claim: AgentHostClaim, phase: AgentDispatchPhase) { self.claim = claim; self.phase = phase }
    }
}
