import Foundation

// CX-01 Phase 2b (`.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`, §10).
//
// Visible delegation with safe retry: the value contracts for `agent.delegate`,
// `agent.reveal` and `operation.get`, plus the pure operation store the host
// keeps behind them (§10.3). Codable, Sendable, no AppKit, no host paths on the
// wire. The App target's `WorkspaceAPIService+Delegation.swift` fulfils them
// over the supervisor's EXISTING child-creation path (`handleSpawnRequest`) and
// the existing managed-agent tile route; nothing here spawns anything.

// MARK: - Shared step vocabulary

/// One step of a multi-step operation, reported separately (§10.3): creation
/// (or adoption), tile attachment, durable state, presentation.
public enum WorkspaceOperationStepStatus: String, Codable, Sendable {
    case pending, succeeded, failed, skipped
}

public struct WorkspaceOperationSteps: Codable, Equatable, Sendable {
    public var creation: WorkspaceOperationStepStatus
    public var attachment: WorkspaceOperationStepStatus
    public var durability: WorkspaceOperationStepStatus
    public var presentation: WorkspaceOperationStepStatus

    public init(
        creation: WorkspaceOperationStepStatus = .pending,
        attachment: WorkspaceOperationStepStatus = .pending,
        durability: WorkspaceOperationStepStatus = .pending,
        presentation: WorkspaceOperationStepStatus = .pending
    ) {
        self.creation = creation
        self.attachment = attachment
        self.durability = durability
        self.presentation = presentation
    }

    public static let allPending = WorkspaceOperationSteps()
}

/// `accepted` — reserved, no effect yet; `committed` — every step it attempted
/// succeeded; `partial` — creation committed but a later step failed (retry only
/// that step, never the creation); `failed` — nothing was created; `expired` —
/// the record was evicted from the bounded store. An expired operation is never
/// "safe to repeat": its child may exist.
public enum WorkspaceOperationStatus: String, Codable, Sendable {
    case accepted, partial, committed, failed, expired
}

// MARK: - agent.delegate

public struct AgentDelegateRequest: Codable, Equatable, Sendable {
    public struct Placement: Codable, Equatable, Sendable {
        public var nearTileId: UUID?
        public init(nearTileId: UUID? = nil) { self.nearTileId = nearTileId }
    }

    /// The child's task. Model-authored text: local only.
    public var task: String
    public var title: String?
    /// Harness raw value. Phase 2b inherits the parent's; a different one is
    /// `unsupported`, never a silent change of provider (§10.1).
    public var provider: String?
    /// Fully qualified model id. Phase 2b inherits the parent's; a different one
    /// is `unsupported`, never a silent change of cost.
    public var model: String?
    public var placement: Placement?
    public var presentationPolicy: WorkspacePresentationPolicy
    /// REQUIRED for delegation: a spawn without a key cannot be retried safely.
    public var idempotencyKey: String?

    public init(
        task: String,
        title: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        placement: Placement? = nil,
        presentationPolicy: WorkspacePresentationPolicy = .defaultExplicitOpen,
        idempotencyKey: String? = nil
    ) {
        self.task = task
        self.title = title
        self.provider = provider
        self.model = model
        self.placement = placement
        self.presentationPolicy = presentationPolicy
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case task, title, provider, model, placement, presentationPolicy, presentation, idempotencyKey
    }

    /// Tolerant of the model-facing shape (`presentation`, short names, any
    /// subset). Unknown keys are ignored, so a forged `authorized` is inert.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decode(String.self, forKey: .task)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement)
        presentationPolicy = try WorkspacePresentationPolicy.decodeCanonicalOrShort(
            from: c, canonical: .presentationPolicy, short: .presentation)
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(task, forKey: .task)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(placement, forKey: .placement)
        try c.encode(presentationPolicy, forKey: .presentationPolicy)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
    }
}

public struct AgentDelegateResult: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var status: WorkspaceOperationStatus
    /// The ACTUAL child identity, whatever happened after creation.
    public var childAgentId: AgentID?
    public var parentAgentId: AgentID
    public var tileId: UUID?
    public var provider: String?
    public var model: String?
    public var steps: WorkspaceOperationSteps
    public var presentation: ArtifactOpenResult.Presentation
    public var presentationEffects: WorkspacePresentationEffects
    public var actualWorldRect: CanvasWorldRect?
    public var actualZoneId: UUID?
    /// nil = unknown (no child, or the host cannot tell).
    public var childRunning: Bool?
    /// A step failed after creation committed. Retry only `retryOp`.
    public var partial: Bool
    /// `agent.reveal` when presentation (or attachment) is what failed. Never
    /// `agent.delegate`: the child exists.
    public var retryOp: WorkspaceAPIOp?
    public var failureMessage: String?

    public init(
        operationId: String,
        status: WorkspaceOperationStatus,
        childAgentId: AgentID?,
        parentAgentId: AgentID,
        tileId: UUID?,
        provider: String?,
        model: String?,
        steps: WorkspaceOperationSteps,
        presentation: ArtifactOpenResult.Presentation,
        presentationEffects: WorkspacePresentationEffects,
        actualWorldRect: CanvasWorldRect?,
        actualZoneId: UUID?,
        childRunning: Bool?,
        partial: Bool,
        retryOp: WorkspaceAPIOp? = nil,
        failureMessage: String? = nil
    ) {
        self.operationId = operationId
        self.status = status
        self.childAgentId = childAgentId
        self.parentAgentId = parentAgentId
        self.tileId = tileId
        self.provider = provider
        self.model = model
        self.steps = steps
        self.presentation = presentation
        self.presentationEffects = presentationEffects
        self.actualWorldRect = actualWorldRect
        self.actualZoneId = actualZoneId
        self.childRunning = childRunning
        self.partial = partial
        self.retryOp = retryOp
        self.failureMessage = failureMessage
    }
}

// MARK: - agent.reveal

public struct AgentRevealRequest: Codable, Equatable, Sendable {
    public var agentId: AgentID
    public var presentationPolicy: WorkspacePresentationPolicy

    public init(agentId: AgentID, presentationPolicy: WorkspacePresentationPolicy = .defaultExplicitOpen) {
        self.agentId = agentId
        self.presentationPolicy = presentationPolicy
    }

    private enum CodingKeys: String, CodingKey { case agentId, presentationPolicy, presentation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.decode(AgentID.self, forKey: .agentId)
        presentationPolicy = try WorkspacePresentationPolicy.decodeCanonicalOrShort(
            from: c, canonical: .presentationPolicy, short: .presentation)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentId, forKey: .agentId)
        try c.encode(presentationPolicy, forKey: .presentationPolicy)
    }
}

public struct AgentRevealResult: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var agentId: AgentID
    public var tileId: UUID
    public var actualZoneId: UUID?
    public var actualWorldRect: CanvasWorldRect?
    public var presentation: ArtifactOpenResult.Presentation
    public var presentationEffects: WorkspacePresentationEffects

    public init(
        operationId: String,
        agentId: AgentID,
        tileId: UUID,
        actualZoneId: UUID?,
        actualWorldRect: CanvasWorldRect?,
        presentation: ArtifactOpenResult.Presentation,
        presentationEffects: WorkspacePresentationEffects
    ) {
        self.operationId = operationId
        self.agentId = agentId
        self.tileId = tileId
        self.actualZoneId = actualZoneId
        self.actualWorldRect = actualWorldRect
        self.presentation = presentation
        self.presentationEffects = presentationEffects
    }
}

// MARK: - agent.message

/// What the HOST OBSERVED of the delivery, and nothing more. `delivered` — the
/// child's own send path took the text and started a turn with it; `queued` —
/// the send path held it for a turn that has not finished (reserved: today's
/// `AgentSupervisor.send` either delivers into the child's runner or declines);
/// `refused` — the send path declined and the child was never prompted. It is
/// never the child's ANSWER: that is collected the existing way.
public enum AgentMessageDelivery: String, Codable, Sendable {
    case delivered, queued, refused
}

public struct AgentMessageRequest: Codable, Equatable, Sendable {
    /// The child to message. Children of the caller only — a sibling, the
    /// caller's own parent and an unrelated agent are all refused.
    public var agentId: AgentID
    /// Model-authored text, delivered verbatim as the child's user turn. The
    /// host never interprets it.
    public var text: String
    /// A message must not steal the user's view, so the default preserves all
    /// five dimensions (unlike an explicit open).
    public var presentationPolicy: WorkspacePresentationPolicy
    /// REQUIRED: without it a retry after a dropped answer double-prompts a
    /// running agent.
    public var idempotencyKey: String?

    /// 8 KB of UTF-8. A brief longer than this belongs in a fresh delegation,
    /// not in a turn the child has to read in one go.
    public static let textByteCeiling = 8 * 1024

    public init(
        agentId: AgentID,
        text: String,
        presentationPolicy: WorkspacePresentationPolicy = .preserveAll,
        idempotencyKey: String? = nil
    ) {
        self.agentId = agentId
        self.text = text
        self.presentationPolicy = presentationPolicy
        self.idempotencyKey = idempotencyKey
    }

    /// Pure bounds, shared by the host and the checks: nil when the request is
    /// well formed, otherwise the `invalid_request` message.
    public func validationFailure() -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "text is required: an empty message would start a turn with nothing in it."
        }
        let bytes = text.utf8.count
        if bytes > Self.textByteCeiling {
            return "text is \(bytes) bytes of UTF-8; the ceiling is \(Self.textByteCeiling). Send a shorter message, or delegate a new child with the full brief."
        }
        let key = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty {
            return "idempotencyKey is required for agent.message: a retry without one would prompt the child twice."
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case agentId, text, presentationPolicy, presentation, idempotencyKey
    }

    /// Tolerant of the model-facing shape (`presentation`, any subset of
    /// dimensions). Unknown keys are ignored, so nothing in the payload can
    /// widen the caller's own grant.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.decode(AgentID.self, forKey: .agentId)
        text = try c.decode(String.self, forKey: .text)
        presentationPolicy = try WorkspacePresentationPolicy.decodeCanonicalOrShort(
            from: c, canonical: .presentationPolicy, short: .presentation, base: .preserveAll)
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentId, forKey: .agentId)
        try c.encode(text, forKey: .text)
        try c.encode(presentationPolicy, forKey: .presentationPolicy)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
    }
}

/// Delivery only. There is deliberately no field for the child's reply: the
/// caller collects that the existing way (`wait_agents`, or `agent.inspect`).
public struct AgentMessageResult: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var delivery: AgentMessageDelivery
    public var childAgentId: AgentID
    public var parentAgentId: AgentID
    /// nil = unknown (the host cannot tell).
    public var childRunning: Bool?
    /// Present only when the send path exposes a queue position for the child.
    public var queuePosition: Int?
    /// Why the send path declined, when `delivery == .refused`.
    public var refusalReason: String?
    public var presentation: ArtifactOpenResult.Presentation
    public var presentationEffects: WorkspacePresentationEffects

    public init(
        operationId: String,
        delivery: AgentMessageDelivery,
        childAgentId: AgentID,
        parentAgentId: AgentID,
        childRunning: Bool?,
        queuePosition: Int? = nil,
        refusalReason: String? = nil,
        presentation: ArtifactOpenResult.Presentation = .deferred,
        presentationEffects: WorkspacePresentationEffects = .allPreserved
    ) {
        self.operationId = operationId
        self.delivery = delivery
        self.childAgentId = childAgentId
        self.parentAgentId = parentAgentId
        self.childRunning = childRunning
        self.queuePosition = queuePosition
        self.refusalReason = refusalReason
        self.presentation = presentation
        self.presentationEffects = presentationEffects
    }
}

// MARK: - operation.get

public struct OperationGetRequest: Codable, Equatable, Sendable {
    public var operationId: String?
    public var idempotencyKey: String?

    public init(operationId: String? = nil, idempotencyKey: String? = nil) {
        self.operationId = operationId
        self.idempotencyKey = idempotencyKey
    }
}

public struct OperationGetResult: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var op: WorkspaceAPIOp?
    public var status: WorkspaceOperationStatus
    public var steps: WorkspaceOperationSteps?
    public var childAgentId: AgentID?
    public var tileId: UUID?
    /// nil = unknown.
    public var childRunning: Bool?
    public var failureCode: String?
    public var failureMessage: String?
    public var createdAt: Date?

    public init(
        operationId: String,
        op: WorkspaceAPIOp?,
        status: WorkspaceOperationStatus,
        steps: WorkspaceOperationSteps?,
        childAgentId: AgentID?,
        tileId: UUID?,
        childRunning: Bool?,
        failureCode: String? = nil,
        failureMessage: String? = nil,
        createdAt: Date? = nil
    ) {
        self.operationId = operationId
        self.op = op
        self.status = status
        self.steps = steps
        self.childAgentId = childAgentId
        self.tileId = tileId
        self.childRunning = childRunning
        self.failureCode = failureCode
        self.failureMessage = failureMessage
        self.createdAt = createdAt
    }
}

// MARK: - Operation store (§10.3)

/// One reserved operation. Keyed by (caller, idempotencyKey); bound to the
/// normalized payload hash so the same key cannot be reused for a different
/// intent.
public struct WorkspaceOperationRecord: Codable, Equatable, Sendable {
    public var operationId: String
    public var agentId: AgentID
    public var op: WorkspaceAPIOp
    public var idempotencyKey: String
    public var payloadHash: String
    public var status: WorkspaceOperationStatus
    public var steps: WorkspaceOperationSteps
    public var childAgentId: AgentID?
    public var tileId: UUID?
    public var failureCode: String?
    public var failureMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        operationId: String, agentId: AgentID, op: WorkspaceAPIOp, idempotencyKey: String,
        payloadHash: String, createdAt: Date
    ) {
        self.operationId = operationId
        self.agentId = agentId
        self.op = op
        self.idempotencyKey = idempotencyKey
        self.payloadHash = payloadHash
        self.status = .accepted
        self.steps = .allPending
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

/// What survives eviction: enough to say `expired` (and the child identity, if
/// one was ever bound) instead of "unknown", so an old delegation never looks
/// safely repeatable.
public struct WorkspaceOperationTombstone: Codable, Equatable, Sendable {
    public var operationId: String
    public var agentId: AgentID
    public var idempotencyKey: String
    public var childAgentId: AgentID?

    public init(operationId: String, agentId: AgentID, idempotencyKey: String, childAgentId: AgentID?) {
        self.operationId = operationId
        self.agentId = agentId
        self.idempotencyKey = idempotencyKey
        self.childAgentId = childAgentId
    }
}

/// Pure, bounded, in-memory (one host session). Retention: `capacity` live
/// records (default 200) evicted oldest-first into `tombstoneCapacity`
/// tombstones (default 2000). Lookups are always scoped to the caller: another
/// agent's operation is `unknown`, never disclosed.
public struct WorkspaceOperationStore: Equatable, Sendable {
    public enum Reservation: Equatable, Sendable {
        /// Fresh reservation — the caller owns the record and must drive it.
        case reserved(WorkspaceOperationRecord)
        /// Same key, same payload: return this record's outcome, do nothing.
        case replay(WorkspaceOperationRecord)
        /// Same key, different payload.
        case conflict(existing: WorkspaceOperationRecord)
        /// The key belongs to an evicted operation. Its child may exist.
        case expired(WorkspaceOperationTombstone)
    }

    public enum Lookup: Equatable, Sendable {
        case found(WorkspaceOperationRecord)
        case expired(WorkspaceOperationTombstone)
        case unknown
    }

    public let capacity: Int
    public let tombstoneCapacity: Int
    private var records: [String: WorkspaceOperationRecord] = [:]
    /// Insertion order of `records` keys (operationIds), oldest first.
    private var order: [String] = []
    private var tombstones: [WorkspaceOperationTombstone] = []

    public init(capacity: Int = 200, tombstoneCapacity: Int = 2000) {
        self.capacity = max(1, capacity)
        self.tombstoneCapacity = max(0, tombstoneCapacity)
    }

    public var count: Int { records.count }
    public var tombstoneCount: Int { tombstones.count }

    /// Reserve BEFORE dispatching the effect (§10.2). Deduplicates by
    /// (agentId, idempotencyKey) and binds the payload hash.
    public mutating func reserve(
        agentId: AgentID, op: WorkspaceAPIOp, idempotencyKey: String, payloadHash: String,
        operationId: String, now: Date = Date()
    ) -> Reservation {
        if let existing = record(agentId: agentId, idempotencyKey: idempotencyKey) {
            guard existing.payloadHash == payloadHash else { return .conflict(existing: existing) }
            // A failure that created nothing does not burn the key: the same
            // intent may be retried once the cause (a cap, a refusal) is gone.
            // Anything past creation is replayed, never re-run.
            if existing.status == .failed, existing.steps.creation != .succeeded {
                records[existing.operationId] = nil
                order.removeAll { $0 == existing.operationId }
            } else {
                return .replay(existing)
            }
        }
        if let tombstone = tombstones.last(where: { $0.agentId == agentId && $0.idempotencyKey == idempotencyKey }) {
            return .expired(tombstone)
        }
        let record = WorkspaceOperationRecord(
            operationId: operationId, agentId: agentId, op: op, idempotencyKey: idempotencyKey,
            payloadHash: payloadHash, createdAt: now)
        records[operationId] = record
        order.append(operationId)
        evictIfNeeded()
        return .reserved(record)
    }

    /// Drop a reservation that never had an effect (cancelled before creation),
    /// so the key is free again. A record whose creation step succeeded is never
    /// released — the child exists.
    public mutating func release(operationId: String) {
        guard let record = records[operationId], record.steps.creation != .succeeded else { return }
        records[operationId] = nil
        order.removeAll { $0 == operationId }
    }

    public mutating func update(operationId: String, now: Date = Date(), _ mutate: (inout WorkspaceOperationRecord) -> Void) {
        guard var record = records[operationId] else { return }
        mutate(&record)
        record.updatedAt = now
        records[operationId] = record
    }

    public func record(operationId: String) -> WorkspaceOperationRecord? { records[operationId] }

    public func record(agentId: AgentID, idempotencyKey: String) -> WorkspaceOperationRecord? {
        records.values.first { $0.agentId == agentId && $0.idempotencyKey == idempotencyKey }
    }

    /// Caller-scoped: an operationId owned by another agent is `unknown`.
    public func lookup(agentId: AgentID, operationId: String) -> Lookup {
        if let record = records[operationId] {
            return record.agentId == agentId ? .found(record) : .unknown
        }
        if let tombstone = tombstones.last(where: { $0.operationId == operationId && $0.agentId == agentId }) {
            return .expired(tombstone)
        }
        return .unknown
    }

    public func lookup(agentId: AgentID, idempotencyKey: String) -> Lookup {
        if let record = record(agentId: agentId, idempotencyKey: idempotencyKey) { return .found(record) }
        if let tombstone = tombstones.last(where: { $0.agentId == agentId && $0.idempotencyKey == idempotencyKey }) {
            return .expired(tombstone)
        }
        return .unknown
    }

    private mutating func evictIfNeeded() {
        while order.count > capacity {
            let evictedId = order.removeFirst()
            guard let evicted = records.removeValue(forKey: evictedId) else { continue }
            guard tombstoneCapacity > 0 else { continue }
            tombstones.append(WorkspaceOperationTombstone(
                operationId: evicted.operationId, agentId: evicted.agentId,
                idempotencyKey: evicted.idempotencyKey, childAgentId: evicted.childAgentId))
            if tombstones.count > tombstoneCapacity { tombstones.removeFirst(tombstones.count - tombstoneCapacity) }
        }
    }
}

// MARK: - Decoding helper shared by the delegation requests

extension WorkspacePresentationPolicy {
    /// The model-facing subset shape: every field optional, absent means the
    /// explicit-open default for that dimension. Mirrors
    /// `ArtifactOpenRequest`'s private `ShortPresentation`.
    struct Short: Decodable {
        var camera: Camera?
        var keyboardFocus: KeyboardFocus?
        var selection: Selection?
        var workspace: Workspace?
        var armedZone: ArmedZone?
        var expectedInteractionGeneration: UInt64?

        func policy(base: WorkspacePresentationPolicy) -> WorkspacePresentationPolicy {
            WorkspacePresentationPolicy(
                workspace: workspace ?? base.workspace,
                armedZone: armedZone ?? base.armedZone,
                selection: selection ?? base.selection,
                camera: camera ?? base.camera,
                keyboardFocus: keyboardFocus ?? base.keyboardFocus,
                expectedInteractionGeneration: expectedInteractionGeneration)
        }
    }

    /// `base` is what an ABSENT dimension means for this operation: revealing
    /// for an explicit open, preserving for a message that must not steal the
    /// user's view.
    static func decodeCanonicalOrShort<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, canonical: K, short: K,
        base: WorkspacePresentationPolicy = .defaultExplicitOpen
    ) throws -> WorkspacePresentationPolicy {
        if let policy = try container.decodeIfPresent(WorkspacePresentationPolicy.self, forKey: canonical) { return policy }
        if let shortForm = try container.decodeIfPresent(Short.self, forKey: short) { return shortForm.policy(base: base) }
        return base
    }
}
