import CryptoKit
import Foundation

// CX-01 Phase 0 (`.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`).
//
// The FROZEN v1 surface of the host-owned workspace API, and only the part the
// first slice needs: bounded self context and "open or reveal the document we
// are discussing in a tile". Pure value contracts — Codable, Sendable, no
// AppKit, no host paths on the wire. The App target owns the service that
// fulfils them (`WorkspaceAPIService`); provider adapters (the pi extension
// bridge) own transport encoding and nothing else.
//
// Deliberately absent from v1, per §17 Phase 0: an occurrence registry, a
// durable operation framework, `canvas.query` pagination/cursors, board and
// browser references, and the §14.4 codes those need (`ambiguous_target`,
// `busy`, `revision_conflict`, `stale_target`, `cursor_expired`,
// `durability_failed`). `partial` is a RESULT field here, not an error, because
// a document that opened while its relationship save failed is a success with
// a repairable step, not a failure (§9.2).

public enum WorkspaceAPISchema {
    public static let v1 = "array.workspace.v1"
}

public enum WorkspaceAPIOp: String, Codable, Sendable, CaseIterable {
    case workspaceContext = "workspace.context"
    case artifactOpen = "artifact.open"
    // CX-01 Phase 2b (§10): visible delegation with safe retry. Contracts in
    // `WorkspaceAPIContracts+Delegation.swift`.
    case agentDelegate = "agent.delegate"
    case agentReveal = "agent.reveal"
    case operationGet = "operation.get"
}

// MARK: - Identity

/// Opaque, host-issued handle for one concrete checkout (a project root or an
/// agent's worktree). Derived deterministically from the CANONICAL root path
/// (`standardizedFileURL.resolvingSymlinksInPath`) so it is stable across
/// launches and matches `AgentRecord.checkoutRoot` / `ProjectEntry.rootPath`,
/// yet never carries the path itself. Resolvable only through the host's known
/// checkout table; a moved checkout mints a new handle (§7.2: stale handle →
/// re-resolve).
public struct CheckoutHandle: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let prefix = "ck_"
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix(Self.prefix) else { return nil }
        let hex = rawValue.dropFirst(Self.prefix.count)
        guard hex.count == 16, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let handle = CheckoutHandle(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a checkout handle"))
        }
        self = handle
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func derive(canonicalRoot: String) -> CheckoutHandle {
        let digest = SHA256.hash(data: Data(canonicalRoot.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return CheckoutHandle(rawValue: prefix + hex)!
    }

    /// The canonical spelling every derivation must use, so a root authored
    /// with a trailing slash, `/var` vs `/private/var`, or `~` maps to one handle.
    public static func canonicalRoot(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func < (lhs: CheckoutHandle, rhs: CheckoutHandle) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// The only artifact identity Phase 1 issues: a checkout handle plus the
/// checkout-relative path. Wire form is one string, `ck_<hex>:<relativePath>`,
/// so a model can quote it back verbatim.
public struct ArtifactHandle: Codable, Hashable, Sendable, CustomStringConvertible {
    public var checkoutHandle: CheckoutHandle
    public var relativePath: String

    public init(checkoutHandle: CheckoutHandle, relativePath: String) {
        self.checkoutHandle = checkoutHandle
        self.relativePath = relativePath
    }

    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":") else { return nil }
        guard let handle = CheckoutHandle(rawValue: String(rawValue[..<colon])) else { return nil }
        let path = String(rawValue[rawValue.index(after: colon)...])
        guard !path.isEmpty else { return nil }
        self.init(checkoutHandle: handle, relativePath: path)
    }

    public var rawValue: String { "\(checkoutHandle.rawValue):\(relativePath)" }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let handle = ArtifactHandle(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an artifact handle"))
        }
        self = handle
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Presentation policy (§16)

/// Five dimensions, evaluated BEFORE any owner call with navigation side
/// effects. The requested policy is intersected with the caller's grant; it is
/// never its own permission.
public struct WorkspacePresentationPolicy: Codable, Equatable, Sendable {
    public enum Workspace: String, Codable, Sendable { case preserve, allowSwitchToResolvedTarget }
    public enum ArmedZone: String, Codable, Sendable { case preserve, setResolvedTarget }
    public enum Selection: String, Codable, Sendable { case preserve, selectResult }
    public enum Camera: String, Codable, Sendable { case preserve, revealResult }
    public enum KeyboardFocus: String, Codable, Sendable { case preserve, enterResult }

    public var workspace: Workspace
    public var armedZone: ArmedZone
    public var selection: Selection
    public var camera: Camera
    public var keyboardFocus: KeyboardFocus
    /// Host-captured interaction generation the caller observed. When set, a
    /// newer user interaction defers every non-preserving dimension.
    public var expectedInteractionGeneration: UInt64?

    public init(
        workspace: Workspace = .preserve,
        armedZone: ArmedZone = .preserve,
        selection: Selection = .preserve,
        camera: Camera = .preserve,
        keyboardFocus: KeyboardFocus = .preserve,
        expectedInteractionGeneration: UInt64? = nil
    ) {
        self.workspace = workspace
        self.armedZone = armedZone
        self.selection = selection
        self.camera = camera
        self.keyboardFocus = keyboardFocus
        self.expectedInteractionGeneration = expectedInteractionGeneration
    }

    /// Background operations: nothing moves.
    public static let preserveAll = WorkspacePresentationPolicy()
    /// §16 default for an ordinary explicit open: preserve four, reveal within
    /// the current workspace.
    public static let defaultExplicitOpen = WorkspacePresentationPolicy(camera: .revealResult)

    /// Dimension-wise intersection: a dimension the ceiling does not permit
    /// collapses to `.preserve`.
    public func intersected(with ceiling: WorkspacePresentationPolicy) -> WorkspacePresentationPolicy {
        WorkspacePresentationPolicy(
            workspace: ceiling.workspace == .preserve ? .preserve : workspace,
            armedZone: ceiling.armedZone == .preserve ? .preserve : armedZone,
            selection: ceiling.selection == .preserve ? .preserve : selection,
            camera: ceiling.camera == .preserve ? .preserve : camera,
            keyboardFocus: ceiling.keyboardFocus == .preserve ? .preserve : keyboardFocus,
            expectedInteractionGeneration: expectedInteractionGeneration
        )
    }

    public var requestsAnyChange: Bool {
        workspace != .preserve || armedZone != .preserve || selection != .preserve
            || camera != .preserve || keyboardFocus != .preserve
    }
}

public enum WorkspacePresentationEffect: String, Codable, Sendable {
    case preserved, changed, deferred, unavailable
}

public struct WorkspacePresentationEffects: Codable, Equatable, Sendable {
    public var workspace: WorkspacePresentationEffect
    public var armedZone: WorkspacePresentationEffect
    public var selection: WorkspacePresentationEffect
    public var camera: WorkspacePresentationEffect
    public var keyboardFocus: WorkspacePresentationEffect

    public init(
        workspace: WorkspacePresentationEffect = .preserved,
        armedZone: WorkspacePresentationEffect = .preserved,
        selection: WorkspacePresentationEffect = .preserved,
        camera: WorkspacePresentationEffect = .preserved,
        keyboardFocus: WorkspacePresentationEffect = .preserved
    ) {
        self.workspace = workspace
        self.armedZone = armedZone
        self.selection = selection
        self.camera = camera
        self.keyboardFocus = keyboardFocus
    }

    public static let allPreserved = WorkspacePresentationEffects()
}

// MARK: - Freshness and coverage

public struct WorkspaceRevision: Codable, Equatable, Sendable {
    /// Distinguishes host instances; a handle minted under another epoch must be
    /// re-resolved rather than trusted.
    public var epoch: String
    /// Bumps on committed structural change (zones, tiles, links). Camera motion
    /// alone never bumps it (§7.2).
    public var structure: UInt64

    public init(epoch: String, structure: UInt64) {
        self.epoch = epoch
        self.structure = structure
    }
}

/// Hydration coverage is separate from visibility and permission. An empty page
/// never proves an unhydrated zone is empty (§6.2).
public struct WorkspaceCoverage: Codable, Equatable, Sendable {
    public var complete: Bool
    public var installedZoneIds: [UUID]
    public var unhydratedZoneIds: [UUID]

    public init(installedZoneIds: [UUID], unhydratedZoneIds: [UUID]) {
        self.installedZoneIds = installedZoneIds
        self.unhydratedZoneIds = unhydratedZoneIds
        self.complete = unhydratedZoneIds.isEmpty
    }
}

// MARK: - workspace.context

/// One remembered outcome of a caller's recent request, so a cancelled or timed
/// out invocation can still learn the identity a committed effect produced.
public struct WorkspaceRecentOperation: Codable, Equatable, Sendable {
    public var requestId: String
    public var op: WorkspaceAPIOp
    /// `ok`, `error:<code>`, `cancelledBeforeEffect`, `committedAfterCancel`.
    public var outcome: String
    public var tileId: UUID?

    public init(requestId: String, op: WorkspaceAPIOp, outcome: String, tileId: UUID? = nil) {
        self.requestId = requestId
        self.op = op
        self.outcome = outcome
        self.tileId = tileId
    }
}

/// The tiny automatic context (§7.1): self identity, Home/checkout handle,
/// workspace/zone, revision, coverage and the operations this grant allows.
/// Targets ~256 tokens; the host enforces a byte ceiling.
public struct WorkspaceContextResponse: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    public var agentId: AgentID
    public var checkoutHandle: CheckoutHandle?
    public var projectId: UUID?
    public var workspaceId: UUID
    public var zoneId: UUID?
    public var tileId: UUID?
    public var revision: WorkspaceRevision
    public var interactionGeneration: UInt64
    public var coverage: WorkspaceCoverage
    public var capabilities: [WorkspaceAPIOp]
    public var recentOperations: [WorkspaceRecentOperation]
    public var observedAt: Date

    public init(
        agentId: AgentID,
        checkoutHandle: CheckoutHandle?,
        projectId: UUID?,
        workspaceId: UUID,
        zoneId: UUID?,
        tileId: UUID?,
        revision: WorkspaceRevision,
        interactionGeneration: UInt64,
        coverage: WorkspaceCoverage,
        capabilities: [WorkspaceAPIOp],
        recentOperations: [WorkspaceRecentOperation],
        observedAt: Date
    ) {
        self.agentId = agentId
        self.checkoutHandle = checkoutHandle
        self.projectId = projectId
        self.workspaceId = workspaceId
        self.zoneId = zoneId
        self.tileId = tileId
        self.revision = revision
        self.interactionGeneration = interactionGeneration
        self.coverage = coverage
        self.capabilities = capabilities
        self.recentOperations = recentOperations
        self.observedAt = observedAt
    }

    /// The encoded ceiling the host enforces — roughly 300 tokens.
    ///
    /// CX-01 Phase 2b raised it from 1024: `capabilities` is authorization truth
    /// and must be complete, so the three delegation ops spend ~60 bytes of the
    /// budget, and the ceiling sheds `recentOperations` — the only way a caller
    /// cancelled after a committed effect learns the identity it produced. Paying
    /// for the new ops out of that history would have made the automatic context
    /// quietly less useful the more operations the API grew.
    public static let encodedByteCeiling = 1280
}

// MARK: - artifact.open

public struct ArtifactOpenRequest: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case openOrReveal, revealOnly }

    public struct TextLocation: Codable, Equatable, Sendable {
        public var line: Int
        public var column: Int?
        public init(line: Int, column: Int? = nil) { self.line = line; self.column = column }
    }

    public struct Placement: Codable, Equatable, Sendable {
        public var targetZoneId: UUID?
        public var nearTileId: UUID?
        public init(targetZoneId: UUID? = nil, nearTileId: UUID? = nil) {
            self.targetZoneId = targetZoneId
            self.nearTileId = nearTileId
        }
    }

    /// Explicit user-named checkout. Constrains resolution FIRST (§9.1 step 2).
    public var checkoutHandle: CheckoutHandle?
    /// Checkout-relative path; required unless `artifactHandle` supplies it.
    public var relativePath: String?
    /// A handle Array issued earlier. Must agree with any explicit checkout.
    public var artifactHandle: ArtifactHandle?
    public var mode: Mode
    public var location: TextLocation?
    public var placement: Placement?
    public var presentationPolicy: WorkspacePresentationPolicy
    /// Same key + same payload returns the prior result; same key + different
    /// payload is `idempotency_conflict`. Defaults to the transport request id.
    public var idempotencyKey: String?

    public init(
        checkoutHandle: CheckoutHandle? = nil,
        relativePath: String? = nil,
        artifactHandle: ArtifactHandle? = nil,
        mode: Mode = .openOrReveal,
        location: TextLocation? = nil,
        placement: Placement? = nil,
        presentationPolicy: WorkspacePresentationPolicy = .defaultExplicitOpen,
        idempotencyKey: String? = nil
    ) {
        self.checkoutHandle = checkoutHandle
        self.relativePath = relativePath
        self.artifactHandle = artifactHandle
        self.mode = mode
        self.location = location
        self.placement = placement
        self.presentationPolicy = presentationPolicy
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case checkoutHandle, relativePath, artifactHandle, mode, location, placement, presentationPolicy, presentation, idempotencyKey, line
    }

    /// Tolerant of the model-facing shape: `presentation` (short field names, any
    /// subset) and a bare `line` are accepted alongside the canonical fields.
    /// Unknown keys are ignored by construction, so a forged `authorized` or
    /// `approvalRequestId` in a payload is inert (§14.1).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkoutHandle = try c.decodeIfPresent(CheckoutHandle.self, forKey: .checkoutHandle)
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        artifactHandle = try c.decodeIfPresent(ArtifactHandle.self, forKey: .artifactHandle)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .openOrReveal
        if let location = try c.decodeIfPresent(TextLocation.self, forKey: .location) {
            self.location = location
        } else if let line = try c.decodeIfPresent(Int.self, forKey: .line) {
            self.location = TextLocation(line: line)
        } else {
            self.location = nil
        }
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement)
        if let policy = try c.decodeIfPresent(WorkspacePresentationPolicy.self, forKey: .presentationPolicy) {
            presentationPolicy = policy
        } else if let short = try c.decodeIfPresent(ShortPresentation.self, forKey: .presentation) {
            presentationPolicy = short.policy
        } else {
            presentationPolicy = .defaultExplicitOpen
        }
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(checkoutHandle, forKey: .checkoutHandle)
        try c.encodeIfPresent(relativePath, forKey: .relativePath)
        try c.encodeIfPresent(artifactHandle, forKey: .artifactHandle)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(placement, forKey: .placement)
        try c.encode(presentationPolicy, forKey: .presentationPolicy)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
    }

    /// The model-facing subset shape: every field optional, absent means the
    /// explicit-open default for that dimension.
    private struct ShortPresentation: Decodable {
        var camera: WorkspacePresentationPolicy.Camera?
        var keyboardFocus: WorkspacePresentationPolicy.KeyboardFocus?
        var selection: WorkspacePresentationPolicy.Selection?
        var workspace: WorkspacePresentationPolicy.Workspace?
        var armedZone: WorkspacePresentationPolicy.ArmedZone?
        var expectedInteractionGeneration: UInt64?

        var policy: WorkspacePresentationPolicy {
            let base = WorkspacePresentationPolicy.defaultExplicitOpen
            return WorkspacePresentationPolicy(
                workspace: workspace ?? base.workspace,
                armedZone: armedZone ?? base.armedZone,
                selection: selection ?? base.selection,
                camera: camera ?? base.camera,
                keyboardFocus: keyboardFocus ?? base.keyboardFocus,
                expectedInteractionGeneration: expectedInteractionGeneration)
        }
    }
}

public struct ArtifactOpenResult: Codable, Equatable, Sendable {
    public enum Document: String, Codable, Sendable { case opened, existing, failed }
    public enum PlacementOutcome: String, Codable, Sendable { case created, existing, deferred, failed }
    public enum Relationship: String, Codable, Sendable { case persisted, unnecessary, failed }
    public enum Durability: String, Codable, Sendable { case committed, pending, failed }
    public enum Presentation: String, Codable, Sendable { case highlighted, navigated, deferred, unavailable }
    public enum Draft: String, Codable, Sendable { case preserved, notApplicable, unknown }

    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var artifactHandle: ArtifactHandle
    public var checkoutHandle: CheckoutHandle
    public var projectId: UUID?
    /// The actual tile identity. The existing tile UUID is the occurrence identity
    /// Phase 1 supports; duplicate appearances are refused, never guessed.
    public var tileId: UUID?
    public var document: Document
    public var placement: PlacementOutcome
    public var relationship: Relationship
    public var durability: Durability
    public var presentation: Presentation
    public var presentationEffects: WorkspacePresentationEffects
    public var actualWorldRect: CanvasWorldRect?
    public var actualZoneId: UUID?
    public var draft: Draft
    /// Any step failed after another committed. Retry only the failed step.
    public var partial: Bool
    public var failureMessage: String?

    public init(
        operationId: String,
        artifactHandle: ArtifactHandle,
        checkoutHandle: CheckoutHandle,
        projectId: UUID?,
        tileId: UUID?,
        document: Document,
        placement: PlacementOutcome,
        relationship: Relationship,
        durability: Durability,
        presentation: Presentation,
        presentationEffects: WorkspacePresentationEffects,
        actualWorldRect: CanvasWorldRect?,
        actualZoneId: UUID?,
        draft: Draft,
        partial: Bool,
        failureMessage: String? = nil
    ) {
        self.operationId = operationId
        self.artifactHandle = artifactHandle
        self.checkoutHandle = checkoutHandle
        self.projectId = projectId
        self.tileId = tileId
        self.document = document
        self.placement = placement
        self.relationship = relationship
        self.durability = durability
        self.presentation = presentation
        self.presentationEffects = presentationEffects
        self.actualWorldRect = actualWorldRect
        self.actualZoneId = actualZoneId
        self.draft = draft
        self.partial = partial
        self.failureMessage = failureMessage
    }
}

// MARK: - Errors (§14.4, Phase 1 subset)

public struct WorkspaceAPIError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case invalidRequest = "invalid_request"
        case targetConflict = "target_conflict"
        case scopeApprovalRequired = "scope_approval_required"
        case presentationRequired = "presentation_required"
        case notFound = "not_found"
        case unsupported
        case permissionDenied = "permission_denied"
        case idempotencyConflict = "idempotency_conflict"
        case outcomeUnknown = "outcome_unknown"
    }

    public var code: Code
    /// Bounded, human explanation. Never an absolute path; never an identity the
    /// caller is not permitted to know.
    public var message: String
    /// Host-minted id of the approval prompt that was shown (or denied).
    public var approvalRequestId: String?
    /// For `presentation_required`: the dimensions the only available route
    /// would have to change.
    public var requiredEffects: WorkspacePresentationEffects?

    public init(code: Code, message: String, approvalRequestId: String? = nil, requiredEffects: WorkspacePresentationEffects? = nil) {
        self.code = code
        self.message = message
        self.approvalRequestId = approvalRequestId
        self.requiredEffects = requiredEffects
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

// MARK: - Grants (§14.1)

/// One host-maintained grant. Grants are minted ONLY by the host — from the
/// persisted per-agent policy or from a trusted approval UI event — never from
/// anything a model supplies.
public struct WorkspaceToolGrant: Codable, Equatable, Sendable {
    public enum Issuer: Codable, Equatable, Sendable {
        case sessionPolicy
        case userApprovalOnce(requestId: String)
        case userApprovalSession(requestId: String)
    }

    public var grantId: UUID
    public var agentId: AgentID
    public var checkoutHandles: Set<CheckoutHandle>
    public var operations: Set<WorkspaceAPIOp>
    /// The most this grant lets presentation do; requests are intersected with it.
    public var presentationCeiling: WorkspacePresentationPolicy
    public var issuer: Issuer
    /// The host's revocation generation when issued; a grant from an older
    /// generation is dead.
    public var revocationGeneration: UInt64
    public var singleUse: Bool

    public init(
        grantId: UUID = UUID(),
        agentId: AgentID,
        checkoutHandles: Set<CheckoutHandle>,
        operations: Set<WorkspaceAPIOp>,
        presentationCeiling: WorkspacePresentationPolicy,
        issuer: Issuer,
        revocationGeneration: UInt64,
        singleUse: Bool = false
    ) {
        self.grantId = grantId
        self.agentId = agentId
        self.checkoutHandles = checkoutHandles
        self.operations = operations
        self.presentationCeiling = presentationCeiling
        self.issuer = issuer
        self.revocationGeneration = revocationGeneration
        self.singleUse = singleUse
    }

    /// The Phase 1 preset: the read/open/reveal ops within the agent's own
    /// concrete checkout; presentation may reveal the camera and nothing else.
    /// Delegation (`agent.delegate`) is NOT in the preset (§14.1): the first
    /// delegation per agent session goes through the trusted approval UI.
    public static let phase1Ceiling = WorkspacePresentationPolicy(camera: .revealResult)
    public static let phase1Operations: Set<WorkspaceAPIOp> = [.workspaceContext, .artifactOpen, .agentReveal, .operationGet]

    public static func phase1Preset(agentId: AgentID, checkout: CheckoutHandle, generation: UInt64) -> WorkspaceToolGrant {
        WorkspaceToolGrant(
            agentId: agentId,
            checkoutHandles: [checkout],
            operations: phase1Operations,
            presentationCeiling: phase1Ceiling,
            issuer: .sessionPolicy,
            revocationGeneration: generation)
    }
}

public enum WorkspaceToolGrantEvaluator {
    public enum Verdict: Equatable, Sendable {
        case allowed(grantId: UUID, effectivePolicy: WorkspacePresentationPolicy)
        case scopeApprovalRequired(missing: CheckoutHandle)
        case denied
    }

    /// Mechanical check: a live grant (current generation) for this agent that
    /// names the operation and the checkout. Among several, the widest ceiling
    /// wins so a session approval is not shadowed by a single-use one.
    public static func evaluate(
        agentId: AgentID,
        op: WorkspaceAPIOp,
        checkout: CheckoutHandle,
        requested: WorkspacePresentationPolicy,
        grants: [WorkspaceToolGrant],
        currentGeneration: UInt64
    ) -> Verdict {
        let live = grants.filter { $0.agentId == agentId && $0.revocationGeneration == currentGeneration }
        guard !live.isEmpty else { return .denied }
        let matching = live.filter { $0.operations.contains(op) && $0.checkoutHandles.contains(checkout) }
        if let grant = matching.max(by: { ceilingRank($0.presentationCeiling) < ceilingRank($1.presentationCeiling) }) {
            return .allowed(grantId: grant.grantId, effectivePolicy: requested.intersected(with: grant.presentationCeiling))
        }
        if live.contains(where: { $0.operations.contains(op) }) {
            return .scopeApprovalRequired(missing: checkout)
        }
        return .denied
    }

    private static func ceilingRank(_ policy: WorkspacePresentationPolicy) -> Int {
        (policy.workspace == .preserve ? 0 : 1) + (policy.armedZone == .preserve ? 0 : 1)
            + (policy.selection == .preserve ? 0 : 1) + (policy.camera == .preserve ? 0 : 1)
            + (policy.keyboardFocus == .preserve ? 0 : 1)
    }
}

/// Settings ▸ Agents: whether NEW agents are created with workspace tools
/// enabled. Existing records keep their own flag (`AgentRecord.workspaceToolsEnabled`);
/// nothing migrates silently (§14.1).
public enum WorkspaceToolsConfig {
    public static let newAgentsEnabledKey = "continuum.agents.workspaceTools.newAgentsEnabled"

    public static func enabledForNewAgents(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: newAgentsEnabledKey) as? Bool ?? false
    }
}
