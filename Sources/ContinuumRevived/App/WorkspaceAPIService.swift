import AppKit
import ContinuumRevivedCore
import Foundation

// CX-01 Phase 1 (`.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`).
//
// The HOST side of the workspace API: a facade over the existing owners, never a
// second store. `dispatch` is THE entry point — the pi bridge (`handle`) and every
// witness call exactly this — and it runs the §14.2 pipeline: authenticate the
// caller by its supervisor-bound `AgentID`, check the host grant table
// mechanically, resolve the explicit target, preflight the presentation policy
// BEFORE any owner call with side effects, apply through
// `WorkspaceRuntime.executeOpen` (→ `TileSpawner.spawnFile`), then perform only
// the presentation the effective policy permits after rechecking the user's
// interaction generation. Results carry the ACTUAL identities and each step's
// outcome separately (§9.2).
//
// What the model supplies never grants anything: a forged `authorized` or
// `approvalRequestId` in a payload is not even decoded; grants are minted only
// here, from the persisted per-agent policy or from the trusted approval UI the
// app injects (§14.1).
@MainActor
final class WorkspaceAPIService {
    enum Reply: Equatable {
        /// A JSON object ready for the transport.
        case result([String: AnyHashableJSON])
        case error(WorkspaceAPIError)
        /// Cancelled before any effect (`result == nil`) or after a committed
        /// effect, in which case `result` is the completed `ArtifactOpenResult`.
        case cancelled(result: [String: AnyHashableJSON]?)

        static func == (lhs: Reply, rhs: Reply) -> Bool {
            switch (lhs, rhs) {
            case let (.result(a), .result(b)): return a == b
            case let (.error(a), .error(b)): return a == b
            case let (.cancelled(a), .cancelled(b)): return a == b
            default: return false
            }
        }
    }

    /// What the trusted host UI shows before minting extra scope (§14.1). Paths
    /// are for the USER's eyes in the alert; none of this returns to the model.
    struct ScopeApprovalPrompt: Equatable {
        let requestId: String
        let agentId: AgentID
        let agentDisplayName: String
        let checkout: CheckoutHandle
        let checkoutDisplayName: String
        let op: WorkspaceAPIOp
        let relativePath: String?
        /// Phase 2a `agent.inspect` of another agent: who would be inspected.
        var targetAgentId: AgentID? = nil
        var targetAgentDisplayName: String? = nil
    }

    /// `allowByPolicy` is never shown to anyone: `decideScope` returns it under
    /// Agent permissions `free` for a request inside the caller's project, and
    /// it mints a session grant marked `.permissionPolicy`.
    enum ScopeApprovalDecision: Equatable { case deny, allowOnce, allowForSession, allowByPolicy }
    typealias ApprovalHandler = (ScopeApprovalPrompt) -> ScopeApprovalDecision

    // Internal, not private: the `+Agents`, `+Canvas` and `+Delegation`
    // files extend this service; production callers outside it use only
    // `dispatch`/`handle`.
    let runtimeProvider: () -> WorkspaceRuntime?
    let canvasProvider: () -> CanvasNSView?
    let focusBrokerProvider: () -> FocusBroker?
    let supervisor: AgentSupervisor
    let registryStoreProvider: () -> RegistryStore?
    var boardRuntimeProvider: (UUID) -> BoardRuntime?
    let epoch: String
    /// Production: an NSAlert (`AppDelegate.presentWorkspaceToolApproval`). Checks
    /// inject a deterministic decision. This is the ONLY place a grant beyond the
    /// session preset can come from.
    var approvalHandler: ApprovalHandler
    /// Checks-only seams (pattern: `WorkspaceRuntime._relaunchSpy`). Production
    /// leaves both nil. `_beforeCommitHook` runs immediately before the owner
    /// effect; `_beforePresentationHook` immediately before the presentation
    /// generation recheck — a witness uses them to interleave user interaction
    /// or cancellation at the exact seam.
    var _beforeCommitHook: (() -> Void)?
    var _beforePresentationHook: (() -> Void)?
    /// Checks-only: hold a completed browser inventory so concurrent open
    /// admissions can be interleaved deterministically.
    var _browserInventoryReadHook: (() async -> Void)?
    var _afterBrowserScreenshotSaveHook: (() async -> Void)?
    var _afterBrowserScreenshotImportHook: (() async -> Void)?
    /// Checks-only: makes the presentation step of `agent.delegate` FAIL for the
    /// given tile with the returned message (§10.3 partial-failure witness).
    var _injectPresentationFailure: ((UUID) -> String?)?
    #if ARRAY_FILM
    /// Film build only (pattern: `AppDelegate.filmRevealCamera`): receives the
    /// viewport a `revealResult` presentation would cut to, so the director can glide
    /// there instead. Nil: the cut happens.
    var filmRevealCamera: ((CanvasViewport) -> Void)?
    #endif
    /// Production: `AppDelegate.wireManagedAgentTile` — binds a freshly installed
    /// managed-agent tile view to its agent (P2A.5). Checks may leave it nil; the
    /// durable record binding (`supervisor.attach`) happens regardless.
    var tileWiring: ((UUID, AgentID) -> Void)?
    /// CX-01 Phase 2b (§10.3): the bounded operation store behind
    /// `agent.delegate` / `operation.get`.
    var operations = WorkspaceOperationStore()
    let deviceAPI = IOSPreviewWorkspaceAPIState()
    lazy var deviceBuildJobs = IOSPreviewBuildJobs(sessions: deviceAPI.sessions, ownerIsRunning: { [weak self] id in
        self?.supervisor.isRunning(AgentID(rawValue: id)) == true
    })
    /// Encoded `agent.delegate` results by operationId, for same-key replays;
    /// pruned with the store's eviction.
    var delegateReplayResults: [String: [String: AnyHashableJSON]] = [:]
    /// Encoded `agent.message` results by operationId, for same-key replays.
    /// One delivery per key: a replay is answered from here and sends nothing.
    var messageReplayResults: [String: [String: AnyHashableJSON]] = [:]

    /// `agent.message` chains (`+Delegation`): per target, how many
    /// agent-started turns led to its current one, and the prompt time that
    /// turn was stamped with.
    struct MessageChain { let hops: Int; let promptAt: Date? }
    var messageChains: [AgentID: MessageChain] = [:]

    // Shared with `WorkspaceAPIService+Canvas.swift` (same pipeline, other file).
    var grants: [AgentID: [WorkspaceToolGrant]] = [:]
    private var revocationGenerations: [AgentID: UInt64] = [:]
    var approvalPromptCount = 0
    /// Gated requests approved by Agent permissions `free` without a prompt.
    var policyApprovalCount = 0
    private struct CachedOpen { let payloadHash: String; let result: ArtifactOpenResult }
    private var idempotency: [AgentID: [String: CachedOpen]] = [:]
    private var idempotencyOrder: [AgentID: [String]] = [:]
    private var recentOperations: [AgentID: [WorkspaceRecentOperation]] = [:]
    struct CachedCanvasApply { let payloadHash: String; let result: CanvasApplyResult }
    var canvasApplyIdempotency: [AgentID: [String: CachedCanvasApply]] = [:]
    var canvasApplyIdempotencyOrder: [AgentID: [String]] = [:]
    struct CachedBoardApply { let payloadHash: String; let result: BoardApplyResult }
    var boardApplyIdempotency: [AgentID: [String: CachedBoardApply]] = [:]
    var boardApplyIdempotencyOrder: [AgentID: [String]] = [:]
    struct CachedAgentUpdate { let payloadHash: String; let result: AgentUpdateResult }
    var agentUpdateIdempotency: [AgentID: [String: CachedAgentUpdate]] = [:]
    var agentUpdateIdempotencyOrder: [AgentID: [String]] = [:]
    struct BrowserAuditEntry {
        let agentId: AgentID
        let operation: WorkspaceAPIOp
        let outcome: String
        let at: Date
    }
    private var browserAudits: [UUID: [BrowserAuditEntry]] = [:]
    var browserAuditPresentation: ((UUID, [BrowserAuditEntry]) -> Void)?
    func browserAudit(for tileId: UUID) -> [BrowserAuditEntry] { browserAudits[tileId] ?? [] }
    func clearBrowserAudit(for tileId: UUID) { browserAudits[tileId] = nil }
    let browserActionQueue = BrowserActionQueue()
    let browserOpenAdmission = BrowserOpenAdmission()
    struct BrowserHandOver {
        let agentId: AgentID
        let generation: UInt64
        let runtimeId: UUID
        let userInputCount: Int
    }
    var browserHandOvers: [UUID: BrowserHandOver] = [:]
    var browserUserTakenOver: Set<UUID> = []
    enum BrowserDomainDecision { case deny, allowOnce, allowForSession }
    /// Closes a browser approval that is still on screen. Its request answers
    /// "denied" on its own; this only removes the stale sheet.
    typealias BrowserApprovalDismissal = @MainActor () -> Void
    /// (agent, tile, host, reply): which tile is asking travels with the host.
    typealias BrowserDomainApprovalHandler = (AgentID, UUID, String, @escaping @MainActor (BrowserDomainDecision) -> Void) -> BrowserApprovalDismissal
    var browserDomainApprovalHandler: BrowserDomainApprovalHandler = { _, _, _, reply in reply(.deny); return {} }
    typealias BrowserHandOverApprovalHandler = (AgentID, UUID, Bool, @escaping @MainActor (Bool) -> Void) -> BrowserApprovalDismissal
    var browserHandOverApprovalHandler: BrowserHandOverApprovalHandler = { _, _, _, reply in reply(false); return {} }
    var browserDomainApprovals: [AgentID: Set<String>] = [:]
    /// Tiles with a browser approval on screen. One per tile: page script
    /// must not be able to stack a sheet per navigation.
    var browserPromptsPending: Set<UUID> = []
    var browserRuntimeWiring: ((WKWebViewBrowserRuntime, UUID) -> Void)?
    var browserIdleClose: ((UUID, AgentID) -> Bool)?
    var browserControlPresentation: ((UUID, AgentID, Bool, Bool) -> Void)?
    struct BrowserGateInstallation { let runtimeId: UUID; let generation: UInt64; let agentId: AgentID; let inputCount: Int }
    var browserGateInstallations: [UUID: BrowserGateInstallation] = [:]
    var browserLeaseLedger: BrowserLeaseLedger?
    private var browserLeaseEventObserver: UUID?

    @discardableResult
    func installBrowserLeaseLedger(_ ledger: BrowserLeaseLedger) -> Bool {
        guard let mounted = runtimeProvider(), browserLeaseLedger == nil || browserLeaseLedger === ledger else { return false }
        browserLeaseLedger = ledger
        ledger.onEngagementChanged = { [weak self] tile, agent, engaged in
            self?.browserControlPresentation?(tile, agent, engaged, false)
        }
        if browserLeaseEventObserver == nil {
            browserLeaseEventObserver = supervisor.addDeliveredEventObserver { [weak self] agentId, event in
                let changed: Bool
                switch event {
                case .turnStarted: changed = self?.browserLeaseLedger?.observeTurn(agentId, running: true) ?? false
                case .turnCompleted: changed = self?.browserLeaseLedger?.observeTurn(agentId, running: false) ?? false
                default: changed = false
                }
                if changed { DispatchQueue.main.async { [weak self] in self?.runtimeProvider()?.reconcileHydration(rearmForCamera: false) } }
            }
        }
        mounted.browserLeaseProtectionProvider = { [weak self] in
            self?.browserLeaseLedger?.protectedTileIds() ?? []
        }
        mounted.browserLeaseRunningTileIdsProvider = { [weak self] in
            self?.browserLeaseLedger?.runningTileIds() ?? []
        }
        return true
    }
    struct CachedAgentNotify { let payloadHash: String; let result: AgentNotifyResult }
    var agentNotifyIdempotency: [AgentID: [String: CachedAgentNotify]] = [:]
    var agentNotifyIdempotencyOrder: [AgentID: [String]] = [:]
    /// What `agent.notify` can promise about a phone. The app answers from its
    /// companion diagnostics; nothing here is persisted.
    var companionNotifyDelivery: () -> AgentNotifyResult.PhoneDelivery = { .unknown }
    static let idempotencyCapacity = 64
    private static let recentOperationsCapacity = 16

    init(
        runtime: @escaping () -> WorkspaceRuntime?,
        canvas: @escaping () -> CanvasNSView?,
        focusBroker: @escaping () -> FocusBroker?,
        supervisor: AgentSupervisor,
        registryStore: @escaping () -> RegistryStore?,
        boardRuntime: @escaping (UUID) -> BoardRuntime? = { _ in nil },
        epoch: String,
        approvalHandler: @escaping ApprovalHandler,
        tileWiring: ((UUID, AgentID) -> Void)? = nil,
        browserDomainApprovalHandler: BrowserDomainApprovalHandler? = nil,
        browserHandOverApprovalHandler: BrowserHandOverApprovalHandler? = nil,
        browserRuntimeWiring: ((WKWebViewBrowserRuntime, UUID) -> Void)? = nil,
        browserIdleClose: ((UUID, AgentID) -> Bool)? = nil,
        browserControlPresentation: ((UUID, AgentID, Bool, Bool) -> Void)? = nil,
        browserAuditPresentation: ((UUID, [BrowserAuditEntry]) -> Void)? = nil,
        companionNotifyDelivery: @escaping () -> AgentNotifyResult.PhoneDelivery = { .unknown }
    ) {
        self.runtimeProvider = runtime
        self.canvasProvider = canvas
        self.focusBrokerProvider = focusBroker
        self.supervisor = supervisor
        self.registryStoreProvider = registryStore
        self.boardRuntimeProvider = boardRuntime
        self.epoch = epoch
        self.approvalHandler = approvalHandler
        self.tileWiring = tileWiring
        if let browserDomainApprovalHandler { self.browserDomainApprovalHandler = browserDomainApprovalHandler }
        if let browserHandOverApprovalHandler { self.browserHandOverApprovalHandler = browserHandOverApprovalHandler }
        self.browserRuntimeWiring = browserRuntimeWiring
        self.browserIdleClose = browserIdleClose
        self.browserControlPresentation = browserControlPresentation
        self.browserAuditPresentation = browserAuditPresentation
        self.companionNotifyDelivery = companionNotifyDelivery
    }

    deinit {
        MainActor.assumeIsolated {
            if let browserLeaseEventObserver {
                supervisor.removeDeliveredEventObserver(browserLeaseEventObserver)
            }
        }
    }

    // MARK: - Revocation (§14.1)

    /// The revocation generation of ONE principal. Every authorization check
    /// compares a grant's stamp against its own agent's generation, so revoking
    /// one agent cannot invalidate another agent's live approvals. Zero until
    /// that agent has been revoked at least once.
    func revocationGeneration(for agentId: AgentID) -> UInt64 {
        revocationGenerations[agentId] ?? 0
    }

    /// Drops every minted grant for the agent and bumps THAT agent's generation,
    /// so a request already past its grant check fails its recheck before any
    /// effect — and no other agent's grants are touched.
    func revoke(agentId: AgentID) {
        grants[agentId] = nil
        deviceAPI.sessions.revoke(principal: agentId.rawValue)
        browserDomainApprovals[agentId] = nil
        releaseHandedOverBrowsers(revoking: agentId)
        revocationGenerations[agentId] = revocationGeneration(for: agentId) &+ 1
    }

    func policyChanged(agentId: AgentID, enabled: Bool) {
        if !enabled { revoke(agentId: agentId) }
    }

    /// QA: the grants currently held for an agent.
    func qaGrants(for agentId: AgentID) -> [WorkspaceToolGrant] { grants[agentId] ?? [] }

    // MARK: - Bridge entry

    /// The pi bridge's entry: answers the call on its own transport and folds
    /// cancellation into the §15 contract — before the effect nothing happens;
    /// after a committed effect the completed identity is reported, never undone.
    func handle(agentId: AgentID, call: PiHostToolCall) {
        let request = call.request
        if call.isCancelled {
            if let op = WorkspaceAPIOp(rawValue: request.op) {
                remember(agentId: agentId, WorkspaceRecentOperation(requestId: request.requestId, op: op, outcome: "cancelledBeforeEffect"))
            }
            call.respond(.cancelled())
            return
        }
        dispatchAsync(
            agentId: agentId,
            requestId: request.requestId,
            op: request.op,
            payload: request.payload,
            isCancelled: { call.isCancelled }
        ) { reply in
            call.respond(Self.transportResponse(for: reply))
        }
    }

    /// The native-provider MCP entry (`WorkspaceMCPHost` → here). The host has
    /// already matched the per-agent token; identity is the supervisor's record
    /// for that agent, exactly as on the pi bridge.
    func handleMCPRequest(_ request: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard let agentText = request["agentId"] as? String,
              let agentUUID = UUID(uuidString: agentText),
              let record = supervisor.records[AgentID(rawValue: agentUUID)],
              let op = request["op"] as? String,
              let requestID = request["requestId"] as? String,
              let payload = request["payload"] as? [String: Any] else {
            completion(["schema": WorkspaceAPISchema.v1, "status": "error",
                        "error": ["code": "invalid_request", "message": "Malformed workspace request"]])
            return
        }
        dispatchAsync(agentId: record.id, requestId: requestID, op: op, payload: payload) { reply in
            let encoded = Self.transportResponse(for: reply).encodedValue(requestId: requestID)
            completion((try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]) ??
                ["schema": WorkspaceAPISchema.v1, "status": "error",
                 "error": ["code": "outcome_unknown", "message": "Array produced an unreadable reply"]])
        }
    }

    /// The same entry for callers that need the answer in hand (checks, the
    /// film harness). It goes through the production async path; an op that
    /// had not answered by return would read as `outcome_unknown`.
    func handleMCPRequest(_ request: [String: Any]) -> [String: Any] {
        var answer: [String: Any]?
        handleMCPRequest(request) { answer = $0 }
        return answer ?? ["schema": WorkspaceAPISchema.v1, "status": "error",
                          "error": ["code": "outcome_unknown", "message": "Array has not answered this request yet"]]
    }

    static func transportResponse(for reply: Reply) -> PiHostToolResponse {
        switch reply {
        case let .result(object):
            return .ok(Self.plain(object))
        case let .error(error):
            var details: [String: Any] = [:]
            if let id = error.approvalRequestId { details["approvalRequestId"] = id }
            if let effects = error.requiredEffects, let encoded = Self.jsonObject(effects) {
                details["requiredEffects"] = Self.plain(encoded)
            }
            return .error(error.code.rawValue, error.message, details: details.isEmpty ? nil : details)
        case let .cancelled(result):
            return .cancelled(result: result.map(Self.plain))
        }
    }

    // MARK: - Dispatch (§14.2)

    /// The answer-later entry both transports use (`.plans/80`, S1). Native
    /// device operations validate grants and await their own bounded transport;
    /// synchronous operations continue through `dispatch`. Completion runs
    /// exactly once on the main actor.
    func dispatchAsync(
        agentId: AgentID,
        requestId: String,
        op: String,
        payload: [String: Any],
        isCancelled: @escaping () -> Bool = { false },
        completion: @escaping (Reply) -> Void
    ) {
        if let operation = WorkspaceAPIOp(rawValue: op), WorkspaceAPIOp.deviceOperations.contains(operation) {
            Task { @MainActor in
                completion(await self.deviceDispatch(agentId: agentId, requestId: requestId, op: operation, payload: payload, isCancelled: isCancelled))
            }
            return
        }
        if let operation = WorkspaceAPIOp(rawValue: op), operation == .browserOpen {
            dispatchBrowserOpen(agentId: agentId, requestId: requestId, payload: payload,
                                isCancelled: isCancelled, completion: completion)
            return
        }
        if let operation = WorkspaceAPIOp(rawValue: op), [.browserNavigate, .browserSnapshot, .browserClick, .browserType,
            .browserPressKey, .browserScroll, .browserWaitFor, .browserScreenshot, .browserEvaluate, .browserConsole].contains(operation) {
            dispatchBrowserAction(agentId: agentId, requestId: requestId, operation: operation, payload: payload,
                                  isCancelled: isCancelled, completion: completion)
            return
        }
        completion(dispatch(agentId: agentId, requestId: requestId, op: op, payload: payload, isCancelled: isCancelled))
    }

    /// THE host entry point. `isCancelled` is polled at the commit boundary and
    /// before presentation; the default never cancels.
    func dispatch(
        agentId: AgentID,
        requestId: String,
        op opName: String,
        payload: [String: Any],
        isCancelled: () -> Bool = { false }
    ) -> Reply {
        guard let op = WorkspaceAPIOp(rawValue: opName) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Unknown operation \(opName). Supported: \(WorkspaceAPIOp.allCases.map(\.rawValue).joined(separator: ", "))."))
        }
        // Principal: the supervisor's record for the bound runner. Nothing in
        // `payload` is consulted for identity or permission.
        guard let record = supervisor.records[agentId] else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Unknown caller."))
        }
        guard record.workspaceToolsEnabled else {
            // Deliberately names no path, zone or tile (§14.4 permission_denied).
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools are not enabled for this agent. The user can enable them from the agent's menu in Array."))
        }
        guard let runtime = runtimeProvider(), let canvas = canvasProvider() else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "No workspace is mounted."))
        }
        let ownHandle = Self.ownCheckoutHandle(record)
        seedGrantsIfNeeded(agentId: agentId, checkout: ownHandle)
        dropPolicyGrantsUnlessFree(agentId: agentId)

        switch op {
        case .deviceList, .deviceOpen, .deviceObserve, .deviceAct, .deviceClose, .deviceBuildRun:
            return .error(WorkspaceAPIError(code: .unsupported, message: "Device operations require the asynchronous workspace entry."))
        case .workspaceContext:
            return context(agentId: agentId, record: record, ownHandle: ownHandle, runtime: runtime, canvas: canvas)
        case .artifactOpen:
            return open(agentId: agentId, record: record, ownHandle: ownHandle, requestId: requestId,
                        payload: payload, runtime: runtime, canvas: canvas, isCancelled: isCancelled)
        case .agentUpdate:
            return updateAgent(agentId: agentId, record: record, ownHandle: ownHandle, requestId: requestId,
                               payload: payload, runtime: runtime, canvas: canvas, isCancelled: isCancelled)
        case .agentNotify:
            return notify(agentId: agentId, requestId: requestId, payload: payload, isCancelled: isCancelled)
        case .agentFind:
            return findAgents(agentId: agentId, record: record, ownHandle: ownHandle, payload: payload, runtime: runtime, canvas: canvas)
        case .agentInspect:
            return inspectAgent(agentId: agentId, record: record, ownHandle: ownHandle, payload: payload, canvas: canvas, isCancelled: isCancelled)
        case .canvasQuery:
            return canvasQuery(agentId: agentId, record: record, ownHandle: ownHandle, payload: payload, runtime: runtime, canvas: canvas)
        case .canvasApply:
            return canvasApply(agentId: agentId, record: record, ownHandle: ownHandle, requestId: requestId,
                               payload: payload, runtime: runtime, canvas: canvas, isCancelled: isCancelled)
        case .agentDelegate:
            return delegate(agentId: agentId, record: record, ownHandle: ownHandle, requestId: requestId,
                            payload: payload, runtime: runtime, canvas: canvas, isCancelled: isCancelled)
        case .agentReveal:
            return reveal(agentId: agentId, record: record, ownHandle: ownHandle, requestId: requestId,
                          payload: payload, runtime: runtime, canvas: canvas)
        case .operationGet:
            return operationGet(agentId: agentId, ownHandle: ownHandle, requestId: requestId, payload: payload)
        case .agentMessage:
            return message(agentId: agentId, record: record, ownHandle: ownHandle, requestId: requestId,
                           payload: payload, runtime: runtime, canvas: canvas, isCancelled: isCancelled)
        case .boardQuery:
            return boardQuery(agentId: agentId, record: record, ownHandle: ownHandle,
                              payload: payload, runtime: runtime)
        case .boardApply:
            return boardApply(agentId: agentId, record: record, ownHandle: ownHandle,
                              requestId: requestId, payload: payload, runtime: runtime,
                              isCancelled: isCancelled)
        case .browserOpen, .browserNavigate, .browserSnapshot, .browserClick, .browserType,
             .browserPressKey, .browserScroll, .browserWaitFor, .browserScreenshot, .browserEvaluate, .browserConsole:
            return .error(WorkspaceAPIError(code: .unsupported, message: "Browser tools are not available yet."))
        }
    }

    // MARK: - workspace.context (§7.1)

    private func context(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle,
        runtime: WorkspaceRuntime, canvas: CanvasNSView
    ) -> Reply {
        let verdict = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .workspaceContext, checkout: ownHandle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId))
        guard case .allowed = verdict else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not read workspace context."))
        }
        let zoneId = record.tileId.flatMap { canvas.zoneId(containing: $0) }
        let projectId = record.projectId
            ?? zoneId.flatMap { id in runtime.document.zones.first(where: { $0.zoneId == id })?.projectId }
        let projectZones = runtime.document.zonesInZOrder.filter { $0.projectId != nil && $0.projectId == projectId }
        let installed = projectId.map { canvas.installedZoneIds(forProjectId: $0) } ?? []
        let coverage = WorkspaceCoverage(
            installedZoneIds: projectZones.filter { installed.contains($0.zoneId) }.map(\.zoneId),
            unhydratedZoneIds: projectZones.filter { !installed.contains($0.zoneId) }.map(\.zoneId))
        // Only operations a tool reaches: pi and the MCP server both register
        // `WorkspaceMCPToolCatalog`'s tools, so an op outside it is not callable
        // and must not be advertised as if it were.
        let exposed = WorkspaceAPIOp.allCases.filter(WorkspaceMCPToolCatalog.exposedOperations.contains)
        // Under Agent permissions `free` a gated op inside the project needs no
        // prompt, so it is callable now and must not read as approval-required.
        let free = supervisor.workspaceToolsPermission() == .free
        let capabilities = exposed.filter { op in
            if free, WorkspaceAPIOp.approvalGatedOperations.contains(op) { return true }
            if case .allowed = WorkspaceToolGrantEvaluator.evaluate(
                agentId: agentId, op: op, checkout: ownHandle, requested: .preserveAll,
                grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) { return true }
            return false
        }
        let approvalRequired = exposed.filter {
            WorkspaceAPIOp.approvalGatedOperations.contains($0) && !capabilities.contains($0)
        }
        var response = WorkspaceContextResponse(
            agentId: agentId,
            checkoutHandle: ownHandle,
            projectId: projectId,
            workspaceId: runtime.workspaceId,
            zoneId: zoneId,
            tileId: record.tileId,
            revision: WorkspaceRevision(epoch: epoch, structure: runtime.structuralRevision),
            interactionGeneration: runtime.interactionGeneration,
            coverage: coverage,
            capabilities: capabilities,
            approvalRequired: approvalRequired,
            recentOperations: recentOperations[agentId] ?? [],
            observedAt: Date(),
            displayName: record.humanDisplayName,
            nameSource: record.displayNameSource.workspaceAPINameSource)
        // Enforce the byte ceiling by shedding history, newest kept, never by
        // truncating identity.
        while let data = try? Self.encoder.encode(response),
              data.count > WorkspaceContextResponse.encodedByteCeiling,
              !response.recentOperations.isEmpty {
            response.recentOperations.removeFirst()
        }
        guard let object = Self.jsonObject(response) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Context could not be encoded."))
        }
        return .result(object)
    }

    // MARK: - artifact.open (§9)

    struct KnownCheckout {
        let handle: CheckoutHandle
        let root: URL
        let projectId: UUID?
        let displayName: String
    }

    /// Registry projects ∪ agent checkout roots (`checkoutRoot`, not `cwd`) —
    /// the same two sources as `AppDelegate.resolveDocumentLocation`.
    func knownCheckouts() -> [CheckoutHandle: KnownCheckout] {
        var known: [CheckoutHandle: KnownCheckout] = [:]
        if let registry = try? registryStoreProvider()?.loadOrEmpty() {
            for project in registry.projects where !project.missing {
                let canonical = CheckoutHandle.canonicalRoot(project.rootPath)
                let handle = CheckoutHandle.derive(canonicalRoot: canonical)
                known[handle] = KnownCheckout(
                    handle: handle, root: URL(fileURLWithPath: canonical, isDirectory: true),
                    projectId: project.id, displayName: project.name)
            }
        }
        for record in supervisor.records.values {
            let canonical = CheckoutHandle.canonicalRoot(record.checkoutRoot)
            let handle = CheckoutHandle.derive(canonicalRoot: canonical)
            guard known[handle] == nil else { continue }
            known[handle] = KnownCheckout(
                handle: handle, root: URL(fileURLWithPath: canonical, isDirectory: true),
                projectId: record.projectId, displayName: URL(fileURLWithPath: canonical).lastPathComponent)
        }
        return known
    }

    static func ownCheckoutHandle(_ record: AgentRecord) -> CheckoutHandle {
        CheckoutHandle.derive(canonicalRoot: CheckoutHandle.canonicalRoot(record.checkoutRoot))
    }

    private func open(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView,
        isCancelled: () -> Bool
    ) -> Reply {
        // 1. Schema. Unknown keys are ignored by construction.
        let request: ArtifactOpenRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(ArtifactOpenRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The open request could not be decoded: \(error.localizedDescription)"))
        }
        let generationAtDispatch = runtime.interactionGeneration

        // 2. Idempotency: same key + same payload replays; same key + different
        //    payload is a different intent hiding behind an old key.
        let idempotencyKey = request.idempotencyKey ?? requestId
        let payloadHash = Self.payloadHash(request)
        if let cached = idempotency[agentId]?[idempotencyKey] {
            guard cached.payloadHash == payloadHash else {
                return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "This idempotencyKey was already used with a different request. New intent needs a new key."))
            }
            guard let object = Self.jsonObject(cached.result) else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "Cached result could not be encoded."))
            }
            return .result(object)
        }

        // 3. Target precedence (§9.1 step 2): explicit checkout first; a handle
        //    must agree with it; otherwise the handle; otherwise the caller's own
        //    checkout. Never the active project's namesake.
        let known = knownCheckouts()
        let target: KnownCheckout
        let relativePath: String
        if let explicit = request.checkoutHandle {
            guard let checkout = known[explicit] else {
                return .error(WorkspaceAPIError(code: .notFound, message: "Unknown checkout handle \(explicit.rawValue). Re-resolve it through array_workspace_context."))
            }
            if let handle = request.artifactHandle, handle.checkoutHandle != explicit {
                return .error(WorkspaceAPIError(code: .targetConflict, message: "artifactHandle names a different checkout than checkoutHandle. Reconcile them; Array will not choose one."))
            }
            if let handle = request.artifactHandle, let path = request.relativePath, handle.relativePath != path {
                return .error(WorkspaceAPIError(code: .targetConflict, message: "artifactHandle and relativePath disagree. Reconcile them; Array will not choose one."))
            }
            guard let path = request.relativePath ?? request.artifactHandle?.relativePath else {
                return .error(WorkspaceAPIError(code: .invalidRequest, message: "relativePath (or an artifactHandle) is required."))
            }
            target = checkout
            relativePath = path
        } else if let handle = request.artifactHandle {
            guard let checkout = known[handle.checkoutHandle] else {
                return .error(WorkspaceAPIError(code: .notFound, message: "The artifactHandle's checkout is not known to this host. Re-resolve it."))
            }
            if let path = request.relativePath, path != handle.relativePath {
                return .error(WorkspaceAPIError(code: .targetConflict, message: "artifactHandle and relativePath disagree. Reconcile them; Array will not choose one."))
            }
            target = checkout
            relativePath = handle.relativePath
        } else {
            guard let path = request.relativePath else {
                return .error(WorkspaceAPIError(code: .invalidRequest, message: "relativePath is required."))
            }
            let canonical = CheckoutHandle.canonicalRoot(record.checkoutRoot)
            target = known[ownHandle] ?? KnownCheckout(
                handle: ownHandle, root: URL(fileURLWithPath: canonical, isDirectory: true),
                projectId: record.projectId, displayName: URL(fileURLWithPath: canonical).lastPathComponent)
            relativePath = path
        }

        // 4. Grant, on the resolved checkout handle — before the path discloses
        //    anything beyond the handle the caller already supplied. "Allow once"
        //    means this one request: the grant is spent the moment it authorizes,
        //    whatever the request then does, so a refusal cannot leave a live
        //    once-grant behind for a later request to ride.
        let effectivePolicy: WorkspacePresentationPolicy
        var approvalRequestId: String?
        switch WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .artifactOpen, checkout: target.handle,
            requested: request.presentationPolicy, grants: grants[agentId] ?? [],
            currentGeneration: revocationGeneration(for: agentId)) {
        case .denied:
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not open documents."))
        case .scopeApprovalRequired:
            let promptId = UUID().uuidString
            approvalRequestId = promptId
            let decision = decideScope(ScopeApprovalPrompt(
                requestId: promptId, agentId: agentId, agentDisplayName: record.displayName,
                checkout: target.handle, checkoutDisplayName: target.displayName,
                op: .artifactOpen, relativePath: relativePath),
                withinCallerProject: Self.sameProject(record, target.projectId))
            if isCancelled() {
                remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .artifactOpen, outcome: "cancelledBeforeEffect"))
                return .cancelled(result: nil)
            }
            // The prompt ran arbitrary UI; the policy may have flipped meanwhile.
            guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools were disabled for this agent.", approvalRequestId: promptId))
            }
            switch decision {
            case .deny:
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "The user declined access to that checkout.", approvalRequestId: promptId))
            case .allowOnce:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [target.handle], operations: [.artifactOpen],
                    presentationCeiling: WorkspaceToolGrant.phase1Ceiling,
                    issuer: .userApprovalOnce(requestId: promptId),
                    revocationGeneration: revocationGeneration(for: agentId), singleUse: true))
            case .allowForSession, .allowByPolicy:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [target.handle], operations: [.artifactOpen],
                    presentationCeiling: WorkspaceToolGrant.phase1Ceiling,
                    issuer: Self.sessionIssuer(decision, requestId: promptId),
                    revocationGeneration: revocationGeneration(for: agentId)))
            }
            guard case let .allowed(_, policy) = WorkspaceToolGrantEvaluator.evaluate(
                agentId: agentId, op: .artifactOpen, checkout: target.handle,
                requested: request.presentationPolicy, grants: grants[agentId] ?? [],
                currentGeneration: revocationGeneration(for: agentId)) else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "Approval did not take.", approvalRequestId: promptId))
            }
            effectivePolicy = policy
        case let .allowed(_, policy):
            effectivePolicy = policy
        }
        consumeSingleUseGrant(agentId: agentId, checkout: target.handle)
        let generationAtGrant = revocationGeneration(for: agentId)

        // 5. Resolve the path inside the target checkout with the existing
        //    resolver: canonical, symlink-aware, component containment, regular file.
        let link: AgentLocalFileLink
        switch AgentLocalFileLinkResolver.resolve(destination: relativePath, checkoutRoot: target.root) {
        case let .success(resolved):
            link = resolved
        case let .failure(failure):
            switch failure {
            case .notARegularFile:
                return .error(WorkspaceAPIError(code: .notFound, message: "\(relativePath) is not a file in that checkout.", approvalRequestId: approvalRequestId))
            default:
                return .error(WorkspaceAPIError(code: .invalidRequest, message: "\(relativePath) does not resolve inside the checkout (\(failure)).", approvalRequestId: approvalRequestId))
            }
        }
        let location = DocumentLocationResolver.resolve(
            fileURL: URL(fileURLWithPath: link.path),
            explicitRoot: DocumentLocationRoot(rootURL: target.root, projectId: target.projectId))
        guard let projectId = target.projectId else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "That checkout is not a registered project, so it has no zone to open into."))
        }
        let artifactHandle = ArtifactHandle(checkoutHandle: target.handle, relativePath: link.relativePathDisplay(root: target.root) ?? relativePath)

        // 6. Preflight the destination and every presentation dimension BEFORE
        //    any owner effect.
        let anchorCandidate = request.placement?.nearTileId ?? record.tileId
        let preflight = runtime.preflightExplicitOpen(
            location: location, projectId: projectId,
            destinationZoneId: request.placement?.targetZoneId, anchorTileId: anchorCandidate)
        let plan: WorkspaceRuntime.ExplicitOpenPlan
        switch preflight {
        case let .presentationRequired(targetWorkspaceId):
            return .error(WorkspaceAPIError(
                code: .presentationRequired,
                message: "That document's project lives in another workspace (\(targetWorkspaceId.uuidString)); opening it would switch workspaces, which this operation does not do. Ask the user to switch, or use Show Result.",
                approvalRequestId: approvalRequestId,
                requiredEffects: WorkspacePresentationEffects(workspace: .changed)))
        case let .unsupported(reason):
            return .error(WorkspaceAPIError(code: .unsupported, message: reason, approvalRequestId: approvalRequestId))
        case let .ready(ready):
            plan = ready
        }
        if request.mode == .revealOnly, plan.existingTileId == nil {
            return .error(WorkspaceAPIError(code: .notFound, message: "\(artifactHandle.relativePath) is not open in a tile; use mode openOrReveal to open it.", approvalRequestId: approvalRequestId))
        }

        // 7. Recheck authorization immediately before the effect (§14.1): the
        //    policy flag and the revocation generation the grant was checked under.
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true,
              revocationGeneration(for: agentId) == generationAtGrant else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Access was revoked before the document was opened.", approvalRequestId: approvalRequestId))
        }

        // 8. Cancellation before the effect: nothing happens.
        if isCancelled() {
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .artifactOpen, outcome: "cancelledBeforeEffect"))
            return .cancelled(result: nil)
        }
        _beforeCommitHook?()
        Self.debugDelayIfRequested()

        // 9. Apply through the owner. The anchor only counts when it lives in the
        //    destination zone: `spawnFile` stamps the new tile with the ANCHOR's
        //    zone, so an anchor elsewhere would mis-stamp it.
        let anchor = plan.anchorTileId.flatMap { canvas.zoneId(containing: $0) == plan.zoneId ? $0 : nil }
        let spawner: TileSpawner
        do {
            spawner = try runtime.ensureSpawner(forProjectId: projectId)
        } catch {
            return .error(WorkspaceAPIError(code: .unsupported, message: "project_unavailable: \(error.localizedDescription)", approvalRequestId: approvalRequestId))
        }
        let execution = runtime.executeOpen(
            location: location, spawner: spawner, zoneId: plan.zoneId,
            anchorTileId: anchor, worldPoint: nil, linkTo: agentId)

        var result = ArtifactOpenResult(
            operationId: requestId,
            artifactHandle: artifactHandle,
            checkoutHandle: target.handle,
            projectId: projectId,
            tileId: execution.document.tileId,
            document: .failed,
            placement: .failed,
            relationship: .unnecessary,
            durability: .failed,
            presentation: .unavailable,
            presentationEffects: .allPreserved,
            actualWorldRect: nil,
            actualZoneId: nil,
            draft: .unknown,
            partial: false)
        switch execution.document {
        case .opened:
            result.document = .opened
            result.placement = .created
            result.draft = .notApplicable
        case .existing:
            result.document = .existing
            result.placement = .existing
            // The owner was never asked to reload or replace: `spawnFile` returns
            // `.alreadyOpen` before touching the tile, so its draft is untouched
            // by construction (and asserted by the witness).
            result.draft = .preserved
        case let .failed(message):
            result.failureMessage = message
            result.partial = true
        }
        switch execution.relationship {
        case .persisted: result.relationship = .persisted
        case .unnecessary: result.relationship = .unnecessary
        case let .failed(message):
            result.relationship = .failed
            result.partial = true
            result.failureMessage = message
        }
        if let tileId = execution.document.tileId {
            result.durability = result.relationship == .failed ? .failed : .committed
            result.actualZoneId = canvas.zoneId(containing: tileId)
            if let snapshot = canvas.navigationTileSnapshot(for: tileId) {
                result.actualWorldRect = CanvasWorldRect(snapshot.worldFrame)
            }
            if let line = request.location?.line, let view = canvas.tileView(for: tileId) as? FileTileNSView {
                view.reveal(line: line, column: request.location?.column)
            }
        }

        // 10. Cancellation after the effect: report what happened, present nothing.
        if isCancelled(), let tileId = execution.document.tileId {
            result.presentation = .deferred
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .artifactOpen, outcome: "committedAfterCancel", tileId: tileId))
            cache(agentId: agentId, key: idempotencyKey, hash: payloadHash, result: result)
            return .cancelled(result: Self.jsonObject(result))
        }

        // 11. Presentation: only what the effective policy permits, only if the
        //     user has not moved since dispatch, and only while still authorized.
        if let tileId = execution.document.tileId {
            _beforePresentationHook?()
            let stillAllowed = supervisor.records[agentId]?.workspaceToolsEnabled == true
                && revocationGeneration(for: agentId) == generationAtGrant
            if stillAllowed {
                let (presentation, effects) = present(
                    tileId: tileId, policy: effectivePolicy, generationAtDispatch: generationAtDispatch,
                    runtime: runtime, canvas: canvas)
                result.presentation = presentation
                result.presentationEffects = effects
            } else {
                result.presentation = .unavailable
            }
        }

        remember(agentId: agentId, WorkspaceRecentOperation(
            requestId: requestId, op: .artifactOpen,
            outcome: result.partial ? "partial" : "ok", tileId: execution.document.tileId))
        cache(agentId: agentId, key: idempotencyKey, hash: payloadHash, result: result)
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Result could not be encoded."))
        }
        return .result(object)
    }

    // MARK: - Presentation (§16)

    func present(
        tileId: UUID, policy: WorkspacePresentationPolicy, generationAtDispatch: UInt64,
        runtime: WorkspaceRuntime, canvas: CanvasNSView
    ) -> (ArtifactOpenResult.Presentation, WorkspacePresentationEffects) {
        var effects = WorkspacePresentationEffects.allPreserved
        guard policy.requestsAnyChange else { return (.deferred, effects) }

        // Newer user intent wins: a stale request never restores old state over it.
        let expected = policy.expectedInteractionGeneration ?? generationAtDispatch
        if runtime.interactionGeneration != expected {
            if policy.workspace != .preserve { effects.workspace = .deferred }
            if policy.armedZone != .preserve { effects.armedZone = .deferred }
            if policy.selection != .preserve { effects.selection = .deferred }
            if policy.camera != .preserve { effects.camera = .deferred }
            if policy.keyboardFocus != .preserve { effects.keyboardFocus = .deferred }
            return (.deferred, effects)
        }

        // Phase 1 never switches workspaces or re-arms on a caller's behalf.
        if policy.workspace != .preserve { effects.workspace = .unavailable }
        if policy.armedZone != .preserve { effects.armedZone = .unavailable }

        var navigated = false
        if policy.camera == .revealResult {
            if let framed = canvas.framedViewportForTileJump(tileId) {
                let visible = CGSize(
                    width: canvas.bounds.width > 0 ? canvas.bounds.width : 1280,
                    height: canvas.bounds.height > 0 ? canvas.bounds.height : 720)
                // Revealing into an unarmed zone would re-arm it through the
                // debounced camera rule (`reconcileHydration` → `.camera`). Targeting
                // is not arming (§16), so that reveal is unavailable unless the
                // policy permits the arming.
                let wouldArm = CanvasEngine.cameraArmedZone(
                    zones: canvas.renderedZonesInZOrder, viewport: framed, visibleSize: visible)
                if policy.armedZone == .preserve, let wouldArm, wouldArm != runtime.document.lastActiveZoneId {
                    effects.camera = .unavailable
                } else {
                    #if ARRAY_FILM
                    if let filmRevealCamera { filmRevealCamera(framed) } else { canvas.setViewport(framed) }
                    #else
                    canvas.setViewport(framed)
                    #endif
                    effects.camera = .changed
                    navigated = true
                }
            } else {
                effects.camera = .unavailable
            }
        }
        if policy.keyboardFocus == .enterResult {
            if let broker = focusBrokerProvider(), broker.enterScope(.tile(tileId), reason: .tileSpawned) {
                effects.keyboardFocus = .changed
                // Selection follows focus in lockstep (`markActive`).
                if policy.selection == .selectResult { effects.selection = .changed }
                navigated = true
            } else {
                effects.keyboardFocus = .unavailable
                if policy.selection == .selectResult { effects.selection = .unavailable }
            }
        } else if policy.selection == .selectResult {
            // Selection cannot move without focus without breaking the lockstep
            // invariant between `activeSurface` and `lastActiveTileId`.
            effects.selection = .unavailable
        }
        return (navigated ? .navigated : .unavailable, effects)
    }

    // MARK: - Snapshot projection (first production consumer of the pure index)

    /// Authoritative host models → `CanvasEntityIndexSnapshot`. Tiles come only
    /// from INSTALLED layers (`tilesInWorldFrames(forZoneId:)`); a zone without a
    /// layer is marked stale "unhydrated" and contributes no tiles, so absence is
    /// never inferred from an unhydrated zone. A tile id mounted twice cannot be
    /// fed to the first-wins index; the projection refuses instead.
    static func snapshot(
        runtime: WorkspaceRuntime, canvas: CanvasNSView, records: [AgentRecord], observedAt: Date = Date()
    ) -> Result<CanvasEntityIndexSnapshot, WorkspaceAPIError> {
        var zones: [CanvasEntityIndexZoneSnapshot] = []
        var tiles: [CanvasEntityIndexTileSnapshot] = []
        var seenTileIds = Set<UUID>()
        var installedTileIds = Set<UUID>()
        for zone in canvas.renderedZonesInZOrder {
            let worldTiles = canvas.tilesInWorldFrames(forZoneId: zone.zoneId)
            zones.append(CanvasEntityIndexZoneSnapshot(
                id: zone.zoneId,
                label: zone.name.isEmpty ? "Zone" : zone.name,
                frame: CanvasWorldRect(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height),
                projectId: zone.projectId,
                isCollapsed: zone.collapsed,
                freshness: worldTiles == nil ? .stale(observedAt: observedAt, reason: "unhydrated") : nil))
            for tile in worldTiles ?? [] {
                guard seenTileIds.insert(tile.id).inserted else {
                    return .failure(WorkspaceAPIError(code: .unsupported, message: "duplicate_occurrence"))
                }
                installedTileIds.insert(tile.id)
                tiles.append(CanvasEntityIndexTileSnapshot(
                    id: tile.id,
                    kind: indexKind(tile.kind),
                    label: tile.title,
                    worldFrame: CanvasWorldRect(tile.frame),
                    zoneId: zone.zoneId,
                    projectId: zone.projectId,
                    boardId: tile.metadata.boardId))
            }
        }
        let agents = records.map { record in
            CanvasEntityIndexAgentSnapshot(
                id: record.id,
                label: record.displayName,
                associatedTileIds: record.tileId.map { [$0] } ?? [],
                projectId: record.projectId,
                visibility: record.tileId.map { installedTileIds.contains($0) } == true ? .visible : .detached)
        }
        return .success(CanvasEntityIndexSnapshot(observedAt: observedAt, zones: zones, tiles: tiles, agents: agents))
    }

    private static func indexKind(_ kind: TileKind) -> CanvasEntityIndexTileKind {
        switch kind {
        case .terminal: return .terminal
        case .browser, .browserInspector: return .browser
        case .note: return .note
        case .file: return .file
        case .fileTree: return .fileTree
        case .runArtifacts: return .runArtifacts
        case .managedAgent: return .managedAgent
        case .ticketQueue, .conductorQueue, .diffReview, .kanban, .iosPreview: return .tile
        }
    }

    // MARK: - Grants, cache, history

    func seedGrantsIfNeeded(agentId: AgentID, checkout: CheckoutHandle) {
        let live = (grants[agentId] ?? []).filter { $0.revocationGeneration == revocationGeneration(for: agentId) }
        if live.contains(where: { $0.issuer == .sessionPolicy }) { return }
        grants[agentId] = live + [WorkspaceToolGrant.phase1Preset(agentId: agentId, checkout: checkout, generation: revocationGeneration(for: agentId))]
    }

    // MARK: - Agent permissions

    /// The one place a gated operation decides whether to ask. Under Agent
    /// permissions `free`, a request that stays inside the caller's own
    /// project is approved without a prompt; anything else — every request
    /// under `askFirst`/`off`, and a cross-project one under `free` — goes to
    /// the trusted approval UI. Either way the caller mints the grant and runs
    /// its own rechecks, so revocation and the per-agent switch still win.
    func decideScope(_ prompt: ScopeApprovalPrompt, withinCallerProject: Bool) -> ScopeApprovalDecision {
        if withinCallerProject, supervisor.workspaceToolsPermission() == .free {
            policyApprovalCount += 1
            return .allowByPolicy
        }
        approvalPromptCount += 1
        return approvalHandler(prompt)
    }

    static func sessionIssuer(_ decision: ScopeApprovalDecision, requestId: String) -> WorkspaceToolGrant.Issuer {
        decision == .allowByPolicy ? .permissionPolicy(requestId: requestId) : .userApprovalSession(requestId: requestId)
    }

    /// Both agents belong to one known project. An agent with no project
    /// stamp is never "inside" anything, so it is asked.
    static func sameProject(_ record: AgentRecord, _ projectId: UUID?) -> Bool {
        guard let own = record.projectId else { return false }
        return projectId == own
    }

    /// Leaving `free` takes back what `free` granted: the next gated request
    /// asks, exactly as if the agent had never been approved by the policy.
    func dropPolicyGrantsUnlessFree(agentId: AgentID) {
        guard let held = grants[agentId], supervisor.workspaceToolsPermission() != .free else { return }
        grants[agentId] = held.filter { grant in
            if case .permissionPolicy = grant.issuer { return false }
            return true
        }
    }

    func mint(_ grant: WorkspaceToolGrant) {
        grants[grant.agentId, default: []].append(grant)
    }

    private func consumeSingleUseGrant(agentId: AgentID, checkout: CheckoutHandle) {
        guard var live = grants[agentId] else { return }
        // Only when no durable grant also covers the checkout: a session grant
        // must not be shadowed away by spending a once-grant beside it.
        let durable = live.contains { !$0.singleUse && $0.checkoutHandles.contains(checkout) && $0.operations.contains(.artifactOpen) && $0.revocationGeneration == revocationGeneration(for: agentId) }
        guard !durable, let index = live.firstIndex(where: { $0.singleUse && $0.checkoutHandles.contains(checkout) }) else { return }
        live.remove(at: index)
        grants[agentId] = live
    }

    private func cache(agentId: AgentID, key: String, hash: String, result: ArtifactOpenResult) {
        idempotency[agentId, default: [:]][key] = CachedOpen(payloadHash: hash, result: result)
        idempotencyOrder[agentId, default: []].append(key)
        while (idempotencyOrder[agentId]?.count ?? 0) > Self.idempotencyCapacity {
            let evicted = idempotencyOrder[agentId]!.removeFirst()
            idempotency[agentId]?[evicted] = nil
        }
    }

    func remember(agentId: AgentID, _ operation: WorkspaceRecentOperation) {
        if operation.op.rawValue.hasPrefix("browser."), let tileId = operation.tileId {
            browserAudits[tileId, default: []].append(BrowserAuditEntry(
                agentId: agentId, operation: operation.op, outcome: operation.outcome, at: Date()))
            if (browserAudits[tileId]?.count ?? 0) > 64 { browserAudits[tileId]?.removeFirst() }
            browserAuditPresentation?(tileId, browserAudits[tileId] ?? [])
        }
        recentOperations[agentId, default: []].append(operation)
        while (recentOperations[agentId]?.count ?? 0) > Self.recentOperationsCapacity {
            recentOperations[agentId]?.removeFirst()
        }
    }

    /// QA: what `workspace.context` will report as history.
    func qaRecentOperations(for agentId: AgentID) -> [WorkspaceRecentOperation] { recentOperations[agentId] ?? [] }

    // MARK: - Encoding helpers

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func payloadHash(_ request: ArtifactOpenRequest) -> String {
        var normalized = request
        normalized.idempotencyKey = nil
        guard let data = try? encoder.encode(normalized) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonObject<T: Encodable>(_ value: T) -> [String: AnyHashableJSON]? {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object.mapValues(AnyHashableJSON.init(any:))
    }

    static func plain(_ object: [String: AnyHashableJSON]) -> [String: Any] {
        object.mapValues(\.value)
    }

    /// Debug-only lane aid: widens the window between grant check and commit so
    /// the cancellation contract can be exercised against real pi. Never set in
    /// production; ignored in release builds.
    private static func debugDelayIfRequested() {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CONTINUUM_WORKSPACE_API_DELAY_MS"],
           let ms = Int(raw), ms > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(Double(ms) / 1000))
        }
        #endif
    }
}

/// A JSON value with `Equatable` for check assertions. Wraps what
/// `JSONSerialization` produces.
struct AnyHashableJSON: Equatable, CustomStringConvertible {
    let value: Any

    init(any value: Any) { self.value = value }

    static func == (lhs: AnyHashableJSON, rhs: AnyHashableJSON) -> Bool {
        (lhs.value as? NSObject) == (rhs.value as? NSObject)
    }

    var description: String { String(describing: value) }
    var string: String? { value as? String }
    var bool: Bool? { value as? Bool }
    var int: Int? { (value as? NSNumber)?.intValue }
    var object: [String: AnyHashableJSON]? { (value as? [String: Any])?.mapValues(AnyHashableJSON.init(any:)) }
    var array: [AnyHashableJSON]? { (value as? [Any])?.map(AnyHashableJSON.init(any:)) }
}

private extension AgentLocalFileLink {
    /// The checkout-relative spelling of a resolved link, for the handle Array
    /// hands back. nil when the resolved path is not inside the root (it always is
    /// after `AgentLocalFileLinkResolver`, but this stays defensive).
    func relativePathDisplay(root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = URL(fileURLWithPath: path).pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
