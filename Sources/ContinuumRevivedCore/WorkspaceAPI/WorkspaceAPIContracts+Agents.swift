import Foundation

// CX-01 Phase 2a (`.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`
// §11, §14.1, §17 Phase 2): bounded agent DISCOVERY (`agent.find`) and bounded,
// attributed INSPECTION (`agent.inspect`). Both are reads. Neither messages,
// interrupts, steers, marks visited or complete, changes focus, selection,
// camera or the armed zone, or touches any runner — the App service enforces
// that; these are the value contracts plus the pure ranking/bounding functions
// so the ranking is witnessable without a host.
//
// Everything a response says about another agent is a PROJECTION of what the
// host observed, never that agent's own claim; transcript text is returned as
// plain string data for the caller to read, never interpreted by the host.
// Missing evidence is reported as absent (`transcriptAvailable: false`), which
// is not evidence of inactivity.
//
// Grant policy decided here (§14.1): the session preset covers `agent.find`
// over the caller's OWN checkout (metadata only, no transcript text) and
// `agent.inspect` of the caller ITSELF. Inspecting any other agent needs a grant
// whose `inspectableAgentIds` names the target, which only the trusted approval
// UI mints (`scope_approval_required` → once / session). An explicit
// `checkoutHandle` outside the caller's discoverable set is `permission_denied`
// (cross-checkout discovery is not a Phase 2a scope prompt).

// MARK: - Shared projection identity

/// The host's observed operational state for one agent, coarse on purpose.
public enum AgentObservedStatus: String, Codable, Sendable, CaseIterable {
    case ready, starting, working, compacting, queued, needsAction, failed, restored, unknown
}

/// Identity fields every candidate and every inspection carries. Never a raw
/// path: the checkout is its opaque handle.
public struct AgentProjectionIdentity: Codable, Equatable, Sendable {
    public var agentId: AgentID
    public var displayName: String
    public var role: String?
    /// `AgentHarness.rawValue` ("Pi", "Claude Code", "Codex").
    public var harness: String
    public var checkoutHandle: CheckoutHandle
    public var projectId: UUID?
    public var zoneId: UUID?
    public var tileId: UUID?
    public var parentAgentId: AgentID?
    public var status: AgentObservedStatus
    /// When the host last observed activity for this agent.
    public var observedAt: Date

    public init(
        agentId: AgentID, displayName: String, role: String?, harness: String,
        checkoutHandle: CheckoutHandle, projectId: UUID?, zoneId: UUID?, tileId: UUID?,
        parentAgentId: AgentID?, status: AgentObservedStatus, observedAt: Date
    ) {
        self.agentId = agentId
        self.displayName = displayName
        self.role = role
        self.harness = harness
        self.checkoutHandle = checkoutHandle
        self.projectId = projectId
        self.zoneId = zoneId
        self.tileId = tileId
        self.parentAgentId = parentAgentId
        self.status = status
        self.observedAt = observedAt
    }
}

// MARK: - agent.find

public struct AgentFindRequest: Codable, Equatable, Sendable {
    public var query: String?
    public var checkoutHandle: CheckoutHandle?
    public var zoneId: UUID?
    public var limit: Int?

    public static let defaultLimit = 5
    public static let maxLimit = 10

    public init(query: String? = nil, checkoutHandle: CheckoutHandle? = nil, zoneId: UUID? = nil, limit: Int? = nil) {
        self.query = query
        self.checkoutHandle = checkoutHandle
        self.zoneId = zoneId
        self.limit = limit
    }

    /// 1...maxLimit, defaulting when absent. A model cannot ask for the world.
    public var effectiveLimit: Int { min(max(limit ?? Self.defaultLimit, 1), Self.maxLimit) }
}

/// What the host knows about one candidate BEFORE ranking. Built by the App
/// service from the supervisor's records; consumed by the pure ranker.
public struct AgentFindCandidateFacts: Equatable, Sendable {
    public var identity: AgentProjectionIdentity
    /// Latest prompt/task title the host holds, if any (metadata, not transcript).
    public var taskTitle: String?
    /// Checkout-relative paths the agent's tool events touched.
    public var referencedFiles: [String]
    public var evidenceAvailable: Bool
    public var isCaller: Bool

    public init(identity: AgentProjectionIdentity, taskTitle: String? = nil, referencedFiles: [String] = [], evidenceAvailable: Bool, isCaller: Bool) {
        self.identity = identity
        self.taskTitle = taskTitle
        self.referencedFiles = referencedFiles
        self.evidenceAvailable = evidenceAvailable
        self.isCaller = isCaller
    }
}

public struct AgentFindCandidate: Codable, Equatable, Sendable {
    public var agent: AgentProjectionIdentity
    public var isCaller: Bool
    public var score: Int
    /// Explainable, lexical (§11): every reason names what matched.
    public var matchReasons: [String]
    /// Whether `agent.inspect` would have transcript evidence to show. Metadata
    /// only — no content crosses here.
    public var evidenceAvailable: Bool

    public init(agent: AgentProjectionIdentity, isCaller: Bool, score: Int, matchReasons: [String], evidenceAvailable: Bool) {
        self.agent = agent
        self.isCaller = isCaller
        self.score = score
        self.matchReasons = matchReasons
        self.evidenceAvailable = evidenceAvailable
    }
}

public struct AgentFindResponse: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    /// Always true: this is the host's projection, not any agent's own account.
    public var projection: Bool = true
    public var query: String?
    public var candidates: [AgentFindCandidate]
    /// The top two scores tie. The caller must present them, never pick one.
    public var ambiguous: Bool
    /// Candidates were shed to fit the byte ceiling; narrow the query.
    public var truncated: Bool
    public var observedAt: Date

    public init(query: String?, candidates: [AgentFindCandidate], ambiguous: Bool, truncated: Bool, observedAt: Date) {
        self.query = query
        self.candidates = candidates
        self.ambiguous = ambiguous
        self.truncated = truncated
        self.observedAt = observedAt
    }

    public static let encodedByteCeiling = 8 * 1024
}

/// §11 ranking, pure and deterministic. Exact id/name first, then lexical
/// task/name/role/file matches, then supporting evidence: same checkout, same
/// zone, activity, recency. A query that matches nothing lexically excludes the
/// candidate; with no query every candidate is ranked on supporting evidence.
public enum AgentFindRanker {
    public struct Context: Equatable, Sendable {
        public var callerCheckout: CheckoutHandle
        public var callerZoneId: UUID?
        public var now: Date
        public init(callerCheckout: CheckoutHandle, callerZoneId: UUID?, now: Date) {
            self.callerCheckout = callerCheckout
            self.callerZoneId = callerZoneId
            self.now = now
        }
    }

    public struct Ranking: Equatable, Sendable {
        public var candidates: [AgentFindCandidate]
        public var ambiguous: Bool
    }

    public static let exactIdScore = 1000
    public static let exactNameScore = 900
    public static let namePhraseScore = 500
    public static let nameTokenScore = 120
    public static let taskTokenScore = 100
    public static let fileTokenScore = 100
    public static let roleTokenScore = 80
    public static let sameCheckoutScore = 40
    public static let sameZoneScore = 30
    public static let workingScore = 20
    public static let recentScore = 10
    public static let recentWindow: TimeInterval = 10 * 60

    public static func rank(query rawQuery: String?, context: Context, candidates: [AgentFindCandidateFacts], limit: Int) -> Ranking {
        let query = (rawQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).filter { $0.count >= 2 }
        var scored: [AgentFindCandidate] = []
        for facts in candidates {
            let identity = facts.identity
            var score = 0
            var reasons: [String] = []
            if !query.isEmpty {
                let name = identity.displayName.lowercased()
                let id = identity.agentId.rawValue.uuidString.lowercased()
                if query == id {
                    score += exactIdScore; reasons.append("exact agentId")
                } else if query == name {
                    score += exactNameScore; reasons.append("exact name")
                } else if name.contains(query) {
                    score += namePhraseScore; reasons.append("name contains \"\(query)\"")
                } else {
                    for token in tokens where name.contains(token) {
                        score += nameTokenScore; reasons.append("name matches \"\(token)\"")
                    }
                }
                if let role = identity.role?.lowercased() {
                    for token in tokens where role.contains(token) {
                        score += roleTokenScore; reasons.append("role matches \"\(token)\"")
                    }
                }
                if let task = facts.taskTitle?.lowercased() {
                    for token in tokens where task.contains(token) {
                        score += taskTokenScore; reasons.append("task mentions \"\(token)\"")
                    }
                }
                for token in tokens {
                    if let file = facts.referencedFiles.first(where: { $0.lowercased().contains(token) }) {
                        score += fileTokenScore; reasons.append("referenced file \(file)")
                    }
                }
                // Lexical miss: not a candidate for this query at all.
                guard score > 0 else { continue }
            }
            if identity.checkoutHandle == context.callerCheckout {
                score += sameCheckoutScore; reasons.append("same checkout")
            }
            if let zone = context.callerZoneId, identity.zoneId == zone {
                score += sameZoneScore; reasons.append("same zone")
            }
            if identity.status == .working {
                score += workingScore; reasons.append("working now")
            }
            if context.now.timeIntervalSince(identity.observedAt) <= recentWindow {
                score += recentScore; reasons.append("active recently")
            }
            if facts.isCaller { reasons.append("this is you") }
            scored.append(AgentFindCandidate(
                agent: identity, isCaller: facts.isCaller, score: score,
                matchReasons: reasons, evidenceAvailable: facts.evidenceAvailable))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.agent.observedAt != b.agent.observedAt { return a.agent.observedAt > b.agent.observedAt }
            return a.agent.agentId.rawValue.uuidString < b.agent.agentId.rawValue.uuidString
        }
        let ambiguous = scored.count >= 2 && scored[0].score == scored[1].score
        return Ranking(candidates: Array(scored.prefix(max(limit, 1))), ambiguous: ambiguous)
    }
}

// MARK: - agent.inspect

public struct AgentInspectRequest: Codable, Equatable, Sendable {
    public var agentId: AgentID
    public var maxEvents: Int?

    public static let defaultMaxEvents = 12
    public static let maxMaxEvents = 50

    public init(agentId: AgentID, maxEvents: Int? = nil) {
        self.agentId = agentId
        self.maxEvents = maxEvents
    }

    public var effectiveMaxEvents: Int { min(max(maxEvents ?? Self.defaultMaxEvents, 1), Self.maxMaxEvents) }
}

/// One bounded piece of transcript evidence. `text` is DATA from another
/// agent's transcript: quoted, never interpreted, never a command.
public struct AgentInspectEvidenceItem: Codable, Equatable, Sendable {
    /// `user`, `assistant`, `reasoning`, `system`, `toolCall`, `commandOutput`,
    /// `error`, `fileReferences`, `notice`.
    public var kind: String
    public var at: Date?
    public var text: String

    public init(kind: String, at: Date?, text: String) {
        self.kind = kind
        self.at = at
        self.text = text
    }
}

public struct AgentInspectResponse: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    /// Always true: the host's projection of what it observed.
    public var projection: Bool = true
    public var agent: AgentProjectionIdentity
    public var isCaller: Bool
    public var lastActivityAt: Date
    public var latestPromptAt: Date?
    public var latestTurnAt: Date?
    /// Outcome of the last finished turn the host recorded, if any.
    public var terminalOutcome: String?
    /// The latest user prompt's first line, when the transcript holds one.
    public var promptTitle: String?
    public var transcriptAvailable: Bool
    /// Newest last. Hard byte cap; see `recentEventsTruncated`.
    public var recentEvents: [AgentInspectEvidenceItem]
    public var recentEventsTruncated: Bool
    /// Checkout-relative paths only; anything outside the agent's checkout is dropped.
    public var referencedFiles: [String]
    /// Where the evidence came from (`supervisor.transcriptProjection`, `record`).
    public var evidenceSource: String
    /// Set when evidence is absent: absence is not proof of inactivity.
    public var note: String?
    public var observedAt: Date

    public init(
        agent: AgentProjectionIdentity, isCaller: Bool, lastActivityAt: Date, latestPromptAt: Date?,
        latestTurnAt: Date?, terminalOutcome: String?, promptTitle: String?, transcriptAvailable: Bool,
        recentEvents: [AgentInspectEvidenceItem], recentEventsTruncated: Bool, referencedFiles: [String],
        evidenceSource: String, note: String?, observedAt: Date
    ) {
        self.agent = agent
        self.isCaller = isCaller
        self.lastActivityAt = lastActivityAt
        self.latestPromptAt = latestPromptAt
        self.latestTurnAt = latestTurnAt
        self.terminalOutcome = terminalOutcome
        self.promptTitle = promptTitle
        self.transcriptAvailable = transcriptAvailable
        self.recentEvents = recentEvents
        self.recentEventsTruncated = recentEventsTruncated
        self.referencedFiles = referencedFiles
        self.evidenceSource = evidenceSource
        self.note = note
        self.observedAt = observedAt
    }

    /// The excerpt's own cap (text bytes), separate from the whole-response cap.
    public static let excerptByteCeiling = 4 * 1024
    public static let referencedFilesCap = 20
    public static let encodedByteCeiling = 12 * 1024
    public static let absentEvidenceNote = "No transcript evidence is held for this agent in this host session. Absence of evidence is not evidence that the agent did nothing."
}

/// Keeps the NEWEST items whose UTF-8 text fits under the ceiling; the oldest
/// fall off first. An item that alone exceeds the ceiling is cut to fit and
/// marked. Pure, so the cap is witnessable.
public enum AgentInspectExcerpt {
    public static func bound(_ items: [AgentInspectEvidenceItem], maxItems: Int, byteCeiling: Int) -> (items: [AgentInspectEvidenceItem], truncated: Bool) {
        var truncated = items.count > maxItems
        var kept: [AgentInspectEvidenceItem] = []
        var bytes = 0
        for item in items.suffix(max(maxItems, 0)).reversed() {
            let size = item.text.utf8.count
            if bytes + size <= byteCeiling {
                kept.append(item)
                bytes += size
                continue
            }
            if kept.isEmpty {
                var cut = item
                cut.text = truncate(item.text, byteCeiling: byteCeiling)
                kept.append(cut)
            }
            truncated = true
            break
        }
        return (kept.reversed(), truncated)
    }

    /// Cuts on a CHARACTER boundary with the marker's own bytes reserved, so the
    /// result is never over the ceiling (slicing UTF-8 bytes can both split a
    /// scalar and GROW the string through replacement characters).
    public static func truncate(_ text: String, byteCeiling: Int) -> String {
        let marker = "…"
        let budget = max(byteCeiling - marker.utf8.count, 0)
        var out = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > budget { break }
            out.append(character)
            bytes += size
        }
        return out + marker
    }
}

// MARK: - Grants for agent scope (§14.1)

public extension WorkspaceToolGrantEvaluator {
    enum AgentInspectVerdict: Equatable, Sendable {
        case allowed(grantId: UUID)
        case scopeApprovalRequired(target: AgentID)
        case denied
    }

    /// Mechanical: a live grant for the caller naming `agent.inspect` AND the
    /// target agent. A durable grant is preferred over a single-use one so a
    /// session approval is never spent as a once-grant. Holding `agent.inspect`
    /// for some agents but not this one is the approval seam.
    static func evaluateAgentInspect(
        agentId: AgentID, target: AgentID, grants: [WorkspaceToolGrant], currentGeneration: UInt64
    ) -> AgentInspectVerdict {
        let live = grants.filter { $0.agentId == agentId && $0.revocationGeneration == currentGeneration }
        guard !live.isEmpty else { return .denied }
        let matching = live.filter { $0.operations.contains(.agentInspect) && $0.inspectableAgentIds.contains(target) }
        if let grant = matching.first(where: { !$0.singleUse }) ?? matching.first {
            return .allowed(grantId: grant.grantId)
        }
        if live.contains(where: { $0.operations.contains(.agentInspect) }) {
            return .scopeApprovalRequired(target: target)
        }
        return .denied
    }

    /// The checkouts whose agents `agent.find` may list for this caller: every
    /// live grant naming the op contributes its checkouts.
    static func discoverableCheckouts(agentId: AgentID, grants: [WorkspaceToolGrant], currentGeneration: UInt64) -> Set<CheckoutHandle> {
        grants.filter { $0.agentId == agentId && $0.revocationGeneration == currentGeneration && $0.operations.contains(.agentFind) }
            .reduce(into: Set<CheckoutHandle>()) { $0.formUnion($1.checkoutHandles) }
    }

    /// Agents the caller may inspect regardless of checkout (self by preset, plus
    /// approved targets); `agent.find` lists them too so an approved target is
    /// discoverable.
    static func inspectableAgents(agentId: AgentID, grants: [WorkspaceToolGrant], currentGeneration: UInt64) -> Set<AgentID> {
        grants.filter { $0.agentId == agentId && $0.revocationGeneration == currentGeneration && $0.operations.contains(.agentInspect) }
            .reduce(into: Set<AgentID>()) { $0.formUnion($1.inspectableAgentIds) }
    }
}
