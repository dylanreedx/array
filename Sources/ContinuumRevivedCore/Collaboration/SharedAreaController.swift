import Foundation
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// One view's subscription. Constructing or stopping this connection has no
/// relationship to any source agent's execution lifetime.
public protocol SharedAreaControllerConnection: Sendable {
    func start() async -> AsyncStream<CollaborationSession.Status>
    func stop() async
}

/// The native controller has no runner, source-project filesystem or provider API.
/// A fixture can replace transport while keeping credential/cache admission real.
public protocol SharedAreaControllerTransport: Sendable {
    func identity() async throws -> Collaboration.Identity
    func state() async throws -> Collaboration.State
    func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection
    func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt
    func beginPresence() async throws -> Collaboration.PresenceSession
    func publishPresence(_ input: Collaboration.PresenceInput) async throws
    func endPresence(_ session: UUID) async throws
    func reportUsage(_ report: Collaboration.UsageReport) async throws
    func publishAgentProjection(object: UUID, report: Collaboration.AgentProjection.PublishReport) async throws
    func readAgentProjection(object: UUID, cursor: Collaboration.AgentProjection.Cursor?) async throws -> Collaboration.AgentProjection.Read
    /// A shared note, file, diff, browser or terminal (`Collaboration.LiveTile`).
    func publishLiveTileState(object: UUID, report: Collaboration.LiveTile.PublishState) async throws
    func appendLiveTileEvent(object: UUID, body: Collaboration.LiveTile.EventBody) async throws -> Collaboration.LiveTile.Appended
    func readLiveTile(object: UUID, request: Collaboration.LiveTile.ReadRequest) async throws -> Collaboration.LiveTile.Read
    /// The area's cursor lane: pointers both ways at the sender's rate. A
    /// transport without one throws, and presence stays on update pages.
    func openCursorLane() async throws -> any SharedAreaCursorLane
}

/// One open cursor lane. `messages` finishes when the connection ends.
public protocol SharedAreaCursorLane: Sendable {
    var messages: AsyncStream<Collaboration.CursorLaneMessage> { get }
    func send(_ input: Collaboration.PresenceInput) async throws
    func close() async
}

public extension SharedAreaControllerTransport {
    func beginPresence() async throws -> Collaboration.PresenceSession { throw CollaborationClientError.server(status: 503, code: "presenceUnavailable") }
    func publishPresence(_ input: Collaboration.PresenceInput) async throws { throw CollaborationClientError.server(status: 503, code: "presenceUnavailable") }
    func endPresence(_ session: UUID) async throws { throw CollaborationClientError.server(status: 503, code: "presenceUnavailable") }
    func reportUsage(_ report: Collaboration.UsageReport) async throws { throw CollaborationClientError.server(status: 503, code: "usageUnavailable") }
    func publishAgentProjection(object: UUID, report: Collaboration.AgentProjection.PublishReport) async throws {
        throw CollaborationClientError.server(status: 503, code: "projectionUnavailable")
    }
    func readAgentProjection(object: UUID, cursor: Collaboration.AgentProjection.Cursor?) async throws -> Collaboration.AgentProjection.Read {
        throw CollaborationClientError.server(status: 503, code: "projectionUnavailable")
    }
    func openCursorLane() async throws -> any SharedAreaCursorLane {
        throw CollaborationClientError.server(status: 501, code: "cursorLaneUnavailable")
    }
    func publishLiveTileState(object: UUID, report: Collaboration.LiveTile.PublishState) async throws {
        throw CollaborationClientError.server(status: 503, code: "liveTileUnavailable")
    }
    func appendLiveTileEvent(object: UUID, body: Collaboration.LiveTile.EventBody) async throws -> Collaboration.LiveTile.Appended {
        throw CollaborationClientError.server(status: 503, code: "liveTileUnavailable")
    }
    func readLiveTile(object: UUID, request: Collaboration.LiveTile.ReadRequest) async throws -> Collaboration.LiveTile.Read {
        throw CollaborationClientError.server(status: 503, code: "liveTileUnavailable")
    }
}

private struct SharedAreaAPICursorLane: SharedAreaCursorLane {
    let client: CollaborationCursorLaneClient
    var messages: AsyncStream<Collaboration.CursorLaneMessage> { client.messages }
    func send(_ input: Collaboration.PresenceInput) async throws { try await client.send(input) }
    func close() async { client.close() }
}

private actor SharedAreaAPIConnection: SharedAreaControllerConnection {
    private let session: CollaborationSession
    init(api: CollaborationAPI, area: UUID, initial: Collaboration.State) throws {
        session = try CollaborationSession(api: api, area: area, initial: initial)
    }
    func start() async -> AsyncStream<CollaborationSession.Status> { await session.start() }
    func stop() async { await session.stop() }
}

/// Actual API/session adapter used by native views and by the localhost harness.
public struct SharedAreaAPITransport: SharedAreaControllerTransport {
    let api: CollaborationAPI
    let area: UUID
    public init(endpoint: CollaborationServiceEndpoint, credential: Collaboration.Credential, area: UUID) throws {
        // The endpoint type already rejected non-loopback plaintext URLs.
        api = try CollaborationAPI(baseURL: endpoint.canonicalURL, credential: credential.token,
            allowsInsecureLoopback: endpoint.canonicalURL.scheme == "http")
        self.area = area
    }
    public func identity() async throws -> Collaboration.Identity { try await api.identity() }
    public func state() async throws -> Collaboration.State { try await api.state(area: area) }
    public func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection {
        try SharedAreaAPIConnection(api: api, area: area, initial: initial)
    }
    public func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
        try await api.apply(area: area, mutation: mutation)
    }
    public func beginPresence() async throws -> Collaboration.PresenceSession { try await api.beginPresence(area: area) }
    public func publishPresence(_ input: Collaboration.PresenceInput) async throws { try await api.publishPresence(area: area, value: input) }
    public func endPresence(_ session: UUID) async throws { try await api.endPresence(area: area, session: session) }
    public func reportUsage(_ report: Collaboration.UsageReport) async throws { try await api.reportUsage(area: area, report: report) }
    public func publishAgentProjection(object: UUID, report: Collaboration.AgentProjection.PublishReport) async throws {
        try await api.publishAgentProjection(area: area, object: object, report: report)
    }
    public func readAgentProjection(object: UUID, cursor: Collaboration.AgentProjection.Cursor?) async throws -> Collaboration.AgentProjection.Read {
        try await api.readAgentProjection(area: area, object: object, cursor: cursor)
    }
    public func openCursorLane() async throws -> any SharedAreaCursorLane {
        SharedAreaAPICursorLane(client: try await api.openCursorLane(area: area))
    }
    public func publishLiveTileState(object: UUID, report: Collaboration.LiveTile.PublishState) async throws {
        try await api.publishLiveTileState(area: area, object: object, report: report)
    }
    public func appendLiveTileEvent(object: UUID, body: Collaboration.LiveTile.EventBody) async throws -> Collaboration.LiveTile.Appended {
        try await api.appendLiveTileEvent(area: area, object: object, body: body)
    }
    public func readLiveTile(object: UUID, request: Collaboration.LiveTile.ReadRequest) async throws -> Collaboration.LiveTile.Read {
        try await api.readLiveTile(area: area, object: object, request: request)
    }
}

/// Owns a native shared-area view, not the source tiles observed by that view.
/// Cached content is read-only until both the device identity and current area
/// membership have been checked online. Local camera and drafts are never sent.
@MainActor
public final class SharedAreaController {
    public enum Unavailability: Sendable, Equatable {
        case credentialsUnavailable, identityMismatch, accessDenied, incompatibleState, localPersistence, connectionEnded
    }
    public enum Status: Sendable, Equatable {
        case cached, connecting, connected, reconnecting, unavailable(Unavailability), closed
    }
    public enum SubmissionRejection: Sendable, Equatable {
        case notConnected, forbidden, invalidCommand, conflict, busy, localPersistence, unavailable
    }
    public enum Submission: Sendable {
        case accepted(Collaboration.Receipt)
        case rejected(SubmissionRejection)
        /// The request may already have committed. Keep its operation ID and
        /// private draft; an explicit identical retry can recover its receipt.
        case uncertain(operation: SharedArea.ID<SharedArea.Operation>)
    }
    public typealias TransportFactory = @Sendable (CollaborationServiceEndpoint, Collaboration.Credential, UUID) throws -> any SharedAreaControllerTransport

    public private(set) var status: Status
    public private(set) var document: SharedArea.Document?
    public private(set) var scope: Collaboration.Scope?
    public private(set) var presence: [Collaboration.Presence] = []
    /// Execution-host liveness from the relay; empty means no host has proved it is alive.
    public private(set) var hostLiveness: [Collaboration.HostLiveness] = []
    /// What each person in the area is called. The relay's member record wins;
    /// a presence label fills in for a relay that sends none. Never cleared on
    /// disconnect or loss of access: a name is what explains who left.
    public private(set) var memberNames: [SharedArea.ID<SharedArea.Person>: String] = [:]
    /// Latest revision per artifact from the last authority frame (COL-16).
    public private(set) var artifactHeads: [Collaboration.Artifact.Head] = []
    /// Artifact routes ride the admitted transport; nil until identity and
    /// membership are confirmed online, like every other request.
    public var artifactTransport: (any SharedAreaArtifactTransport)? { transport as? any SharedAreaArtifactTransport }
    public private(set) var isSubmitting = false
    public private(set) var lastPersistenceError: (any Error)?
    public var onChange: (@MainActor () -> Void)?
    private var changeObservers: [UUID: @MainActor () -> Void] = [:]
    @discardableResult public func addChangeObserver(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); changeObservers[id] = observer; return id
    }
    public func removeChangeObserver(_ id: UUID) { changeObservers.removeValue(forKey: id) }

    /// A teammate's pointer from the cursor lane. Applied to `presence` without
    /// a change notification (that would refresh the whole scene up to 60
    /// times a second per teammate); only cursor observers hear it.
    public struct CursorUpdate: Sendable, Equatable {
        public let device: UUID
        public let cursor: Collaboration.Point?
        public let viewport: SharedArea.Rect?
        /// The sender's sample time, seconds on its own clock; nil from pages.
        public let sentAt: Double?
    }
    public enum CursorLaneState: Sendable, Equatable { case off, connecting, live }
    /// `.off` when this transport or relay has no lane: presence rides pages only.
    public private(set) var cursorLaneState: CursorLaneState = .off
    /// Lane frames applied, for the motion witness.
    public private(set) var cursorLaneFramesApplied = 0
    private var cursorObservers: [UUID: @MainActor (CursorUpdate) -> Void] = [:]
    @discardableResult public func addCursorObserver(_ observer: @escaping @MainActor (CursorUpdate) -> Void) -> UUID {
        let id = UUID(); cursorObservers[id] = observer; return id
    }
    public func removeCursorObserver(_ id: UUID) { cursorObservers.removeValue(forKey: id) }
    public var view: SharedAreaLocalView { localState?.view ?? .init() }
    public var drafts: [SharedAreaLocalDraft] { localState?.drafts ?? [] }
    public var sourceBindings: [SharedAreaLocalSourceBinding] { localState?.sourceBindings ?? [] }
    public var identity: Collaboration.Identity { credentialScope.identity }
    public var localAreaDirectory: URL { localStore.layout.areaDirectory }
    public var storageDirectory: URL { localStore.layout.areaDirectory }
    public var pendingOperations: [SharedAreaPendingOperation] { localState?.operations.filter(\.isPending) ?? [] }
    public var deliveryRecords: [SharedAreaPendingOperation] { localState?.operations ?? [] }
    public func deliveryRecord(for operation: SharedArea.ID<SharedArea.Operation>) -> SharedAreaPendingOperation? {
        localState?.operations.first { $0.command.id == operation }
    }
    public var canSubmit: Bool { status == .connected && scope?.role != .viewer && scope != nil && !isSubmitting && pendingOperations.isEmpty }
    public func canSubmit(_ command: SharedArea.Command) -> Bool {
        status == .connected && scope?.canSubmit(command) == true && !isSubmitting
            && (pendingOperations.isEmpty || pendingOperations.contains { $0.command == command })
    }

    public func beginPresence() async throws -> Collaboration.PresenceSession {
        guard status == .connected, let transport else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        let current = generation
        let value = try await transport.beginPresence()
        guard generation == current, status == .connected else {
            try? await transport.endPresence(value.id)
            throw CollaborationClientError.server(status: 409, code: "superseded")
        }
        return value
    }
    public func publishPresence(_ input: Collaboration.PresenceInput) async throws {
        guard status == .connected, let transport else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        let current = generation
        if let lane = cursorLane {
            // The relay no longer knows this session (it restarted): the caller
            // begins a new one, as it does when a page publish is refused.
            if rejectedCursorSessions.contains(input.session) { throw CollaborationClientError.server(status: 400, code: "invalidRequest") }
            do { try await lane.send(input) }
            catch { try await transport.publishPresence(input) }
        } else {
            try await transport.publishPresence(input)
        }
        guard generation == current, status == .connected else { throw CollaborationClientError.server(status: 409, code: "superseded") }
    }
    public func endPresence(_ session: UUID) async throws {
        guard status == .connected, let transport else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        let current = generation
        try await transport.endPresence(session)
        guard generation == current else { throw CollaborationClientError.server(status: 409, code: "superseded") }
    }

    public func reportUsage(_ snapshot: Collaboration.UsageSnapshot) async throws {
        guard status == .connected, let transport, let scope, snapshot.valid else {
            throw CollaborationClientError.server(status: 503, code: "notConnected")
        }
        let current = generation
        try await transport.reportUsage(.init(epoch: scope.epoch, snapshot: snapshot))
        guard generation == current, status == .connected else { throw CollaborationClientError.server(status: 409, code: "superseded") }
    }

    /// COL-15. The host publishes its own agents' projections; any member reads.
    public func publishAgentProjection(object: SharedArea.ID<SharedArea.Object>, batch: Collaboration.AgentProjection.Batch) async throws {
        guard status == .connected, let transport, let scope else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        let current = generation
        try await transport.publishAgentProjection(object: object.rawValue, report: .init(epoch: scope.epoch, batch: batch))
        guard generation == current, status == .connected else { throw CollaborationClientError.server(status: 409, code: "superseded") }
    }
    public func readAgentProjection(object: SharedArea.ID<SharedArea.Object>, cursor: Collaboration.AgentProjection.Cursor?) async throws -> Collaboration.AgentProjection.Read {
        guard status == .connected, let transport else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        return try await transport.readAgentProjection(object: object.rawValue, cursor: cursor)
    }

    /// A shared note, file, diff, browser or terminal. The host writes state;
    /// any member reads, and appends input where the kind takes it.
    public func publishLiveTileState(object: SharedArea.ID<SharedArea.Object>, host: SharedArea.ID<SharedArea.Host>,
                                     state: Collaboration.LiveTile.State) async throws {
        guard status == .connected, let transport, let scope else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        try await transport.publishLiveTileState(object: object.rawValue, report: .init(epoch: scope.epoch, host: host, state: state))
    }
    public func appendLiveTileEvent(object: SharedArea.ID<SharedArea.Object>, body: Collaboration.LiveTile.EventBody) async throws -> Collaboration.LiveTile.Appended {
        guard status == .connected, let transport else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        return try await transport.appendLiveTileEvent(object: object.rawValue, body: body)
    }
    public func readLiveTile(object: SharedArea.ID<SharedArea.Object>, request: Collaboration.LiveTile.ReadRequest) async throws -> Collaboration.LiveTile.Read {
        guard status == .connected, let transport else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        return try await transport.readLiveTile(object: object.rawValue, request: request)
    }

    private let localStore: SharedAreaLocalStore
    private let credentialStore: CollaborationCredentialStore
    private let credentialScope: CollaborationCredentialScope
    private let transportFactory: TransportFactory
    private var localState: SharedAreaLocalState?
    private var transport: (any SharedAreaControllerTransport)?
    private var connection: (any SharedAreaControllerConnection)?
    private var updateTask: Task<Void, Never>?
    private var retiringConnections: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var admittedRevision: UInt64?
    private var admittedEpoch: Int64?
    private var isRecoveringOperations = false
    private var recoveryTask: Task<Void, Never>?
    private var uploadPass: Task<Void, Never>?
    private var cursorLane: (any SharedAreaCursorLane)?
    private var cursorLaneTask: Task<Void, Never>?
    /// The newest (session, sequence) the lane delivered for each device, so a
    /// slower update page never moves a cursor back.
    private var laneCursors: [UUID: (session: UUID, sequence: UInt64)] = [:]
    private var rejectedCursorSessions: Set<UUID> = []

    public init(localStore: SharedAreaLocalStore, credentialStore: CollaborationCredentialStore,
                credentialScope: CollaborationCredentialScope,
                bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                transportFactory: @escaping TransportFactory = SharedAreaController.liveTransport) throws {
        guard localStore.scope.person == credentialScope.identity.person,
              localStore.scope.endpoint == credentialScope.endpoint.canonicalString,
              localStore.scope.channelNamespace == AppChannel.bundledDefaultsDomain(bundleIdentifier: bundleIdentifier),
              credentialStore.namespace == CollaborationCredentialStore.namespace(bundleIdentifier: bundleIdentifier) else {
            throw CollaborationCredentialStoreError.scopeMismatch
        }
        self.localStore = localStore; self.credentialStore = credentialStore
        self.credentialScope = credentialScope; self.transportFactory = transportFactory
        localState = try localStore.load()
        if localState?.accessDenied == true {
            document = nil; status = .unavailable(.accessDenied)
        } else {
            document = localState?.document
            status = document == nil ? .closed : .cached
        }
    }
    deinit { updateTask?.cancel(); recoveryTask?.cancel(); cursorLaneTask?.cancel() }
    public nonisolated static func liveTransport(endpoint: CollaborationServiceEndpoint, credential: Collaboration.Credential, area: UUID) throws -> any SharedAreaControllerTransport {
        try SharedAreaAPITransport(endpoint: endpoint, credential: credential, area: area)
    }

    /// Reopening revalidates authority; neither a cache nor an old live Scope is
    /// sufficient to submit. A late completion belongs only to this generation.
    public func open() async {
        let current = UUID(); generation = current
        recoveryTask?.cancel(); recoveryTask = nil
        stopCursorLane()
        let previous = connection; connection = nil
        let retirements = Array(retiringConnections.values)
        updateTask?.cancel(); updateTask = nil; transport = nil
        admittedRevision = nil; admittedEpoch = nil
        scope = nil; presence = []; hostLiveness = []; artifactHeads = []; isSubmitting = false
        document = localState?.accessDenied == true ? nil : localState?.document
        status = .connecting; changed()
        await previous?.stop()
        await awaitRetirements(retirements)
        guard generation == current else { return }
        let active: any SharedAreaControllerTransport
        do {
            guard let credential = try credentialStore.load(for: credentialScope) else {
                failClosed(.credentialsUnavailable, generation: current); return
            }
            active = try transportFactory(credentialScope.endpoint, credential, localStore.scope.area.rawValue)
        } catch {
            failClosed(.credentialsUnavailable, generation: current); return
        }
        do {
            let verified = try await active.identity()
            guard generation == current else { return }
            guard verified == credentialScope.identity else {
                failClosed(.identityMismatch, generation: current); return
            }
            let state = try await active.state()
            guard generation == current else { return }
            let replica = try CollaborationReplica(state: state)
            let covered = try install(replica)
            transport = active; status = covered ? .connected : .reconnecting; changed()
            let next = try await active.connection(initial: state)
            guard generation == current else { await next.stop(); return }
            connection = next
            let stream = await next.start()
            guard generation == current else { await next.stop(); return }
            updateTask = Task { [weak self] in
                for await value in stream {
                    guard !Task.isCancelled else { return }
                    self?.receive(value, generation: current)
                }
                self?.streamEnded(generation: current)
            }
            startCursorLane(active, generation: current)
            // Only document mutations are queued here. Executable host commands
            // have a separate admission ledger and never enter this outbox.
            _ = await recoverPendingOperations()
        } catch {
            guard generation == current else { return }
            if isAccessFailure(error) {
                failClosed(.accessDenied, generation: current)
            } else if error is SharedAreaLocalStoreError {
                lastPersistenceError = error
                failClosed(.localPersistence, generation: current)
            } else if error is DecodingError || error is SharedArea.Failure || error is CollaborationClientError {
                // Retryable service faults still allow an explicit reopen;
                // malformed authority/document data never enables mutations.
                if let client = error as? CollaborationClientError, case let .server(code, _) = client, code >= 500 {
                    scope = nil; status = .reconnecting; changed()
                } else { failClosed(.incompatibleState, generation: current) }
            } else {
                scope = nil; status = .reconnecting; changed()
            }
        }
    }

    public func close() async {
        generation = UUID()
        recoveryTask?.cancel(); recoveryTask = nil
        stopCursorLane()
        let previous = connection; connection = nil
        let retirements = Array(retiringConnections.values)
        updateTask?.cancel(); updateTask = nil; transport = nil
        admittedRevision = nil; admittedEpoch = nil
        scope = nil; presence = []; hostLiveness = []; artifactHeads = []; document = nil; isSubmitting = false
        status = .closed; changed()
        await previous?.stop()
        await awaitRetirements(retirements)
    }

    /// A view save reloads the latest local generation before applying only its
    /// own field. This preserves drafts written by another controller/view.
    public func setView(_ value: SharedAreaLocalView) throws {
        try persist { $0.view = value }
        changed()
    }
    public func saveDraft(_ value: SharedAreaLocalDraft) throws {
        try persist { state in
            if let index = state.drafts.firstIndex(where: { $0.id == value.id }) { state.drafts[index] = value }
            else { state.drafts.append(value) }
        }
        changed()
    }
    public func removeDraft(id: UUID) throws {
        try persist { $0.drafts.removeAll { $0.id == id } }
        changed()
    }

    public func submit(_ command: SharedArea.Command, preserving draft: SharedAreaLocalDraft? = nil) async -> Submission {
        await submit(command, preserving: draft, publication: nil)
    }

    /// Exact reviewed content/bindings and its intent are persisted together
    /// before any remote effect. Relaunch recovers this record, not a new review.
    public func submitPublication(_ publication: SharedAreaPublication.Confirmed) async -> Submission {
        guard publication.author == credentialScope.identity.person,
              publication.command.area == localStore.scope.area else { return .rejected(.forbidden) }
        return await submit(publication.command, preserving: nil, publication: publication)
    }

    /// Endorses exactly the revision the person was shown, as the verified
    /// person. If a teammate has since revised it, this is a conflict, so an
    /// endorsement can never land on words the endorser did not see.
    public func endorse(_ revision: SharedArea.ID<SharedArea.Revision>) async -> Submission {
        guard let document else { return .rejected(.notConnected) }
        return await submit(.init(area: document.id, expectedRevision: document.revision,
            edits: [.endorse(.init(revision: revision, person: credentialScope.identity.person))]))
    }

    /// A deliberate rebase of a private agreement draft onto the current
    /// revision. The text is unchanged and nothing is sent; the author reads the
    /// teammate's revision and saves again when ready.
    @discardableResult
    public func rebaseDraft(id: UUID) throws -> SharedAreaLocalDraft {
        guard var draft = drafts.first(where: { $0.id == id }), let object = draft.object,
              let current = document?.currentRevision(of: object) else { throw SharedAreaLocalStoreError.invalidState }
        draft.basedOn = current.id
        try saveDraft(draft)
        return draft
    }

    public func retryPending(_ operation: SharedArea.ID<SharedArea.Operation>) async -> Submission {
        if status != .connected { await open() }
        guard let record = deliveryRecord(for: operation) else { return .rejected(.invalidCommand) }
        return await submit(record.command, preserving: nil, publication: nil)
    }

    /// Recover exact data intents in durable order after identity/membership has
    /// been verified again. Current conflicts never rebase an operation ID.
    @discardableResult
    public func recoverPendingOperations() async -> [SharedArea.ID<SharedArea.Operation>: Submission] {
        guard !isRecoveringOperations else { return [:] }
        isRecoveringOperations = true
        defer { isRecoveringOperations = false }
        if status != .connected { await open() }
        guard status == .connected else { return [:] }
        var results: [SharedArea.ID<SharedArea.Operation>: Submission] = [:]
        for record in pendingOperations {
            guard status == .connected else { break }
            results[record.command.id] = await submit(record.command, preserving: nil, publication: nil)
        }
        if status == .connected { scheduleUploads() }
        return results
    }

    /// Written before the publication that admits these objects is sent, so an
    /// accepted arrangement still gets its exact bytes after a failed upload,
    /// a reconnect or a relaunch (COL-16).
    public func stageArtifactUploads(_ captures: [Collaboration.Artifact.Capture], for operation: SharedArea.ID<SharedArea.Operation>) throws {
        for capture in captures { try localStore.stageUpload(.init(operation: operation, capture: capture)) }
    }
    public var stagedArtifactUploads: [SharedAreaPendingArtifactUpload] { localStore.stagedUploads() }

    /// Uploads each staged revision whose item the document admits. The service
    /// is asked first, so a revision that already landed (its reply lost, or the
    /// app quit before forgetting it) is never sent again. A failure stays
    /// staged for the next open or reconnect.
    public func uploadStagedArtifacts() async {
        while let running = uploadPass { await running.value }
        // The pass clears itself, so no waiter can see a finished pass as running.
        let pass = Task { await runUploadPass(); uploadPass = nil }
        uploadPass = pass
        await pass.value
    }
    private func scheduleUploads() {
        guard uploadPass == nil, localStore.hasStagedUploads else { return }
        Task { [weak self] in await self?.uploadStagedArtifacts() }
    }
    /// Why the most recent staged upload did not land; nil after a clean pass.
    public private(set) var lastArtifactUploadError: (any Error)?
    private func runUploadPass() async {
        lastArtifactUploadError = nil
        for upload in localStore.stagedUploads() {
            guard status == .connected, let transport = artifactTransport, let epoch = scope?.epoch, let document else {
                lastArtifactUploadError = SharedAreaArtifactUploadDeferral(status: status, hasTransport: artifactTransport != nil); return
            }
            let object = upload.manifest.object
            guard document.items.contains(where: { $0.id == object && $0.kind == .artifact }) else {
                // Never admitted (refused, or never sent) or since removed.
                if deliveryRecord(for: upload.operation)?.isPending != true { localStore.removeStagedUpload(revision: upload.manifest.id) }
                continue
            }
            do {
                let state = try await transport.artifactState(object: object.rawValue)
                // A different revision already leading means this first one can never land.
                if !state.revisions.contains(where: { $0.id == upload.manifest.id }), state.latest == nil {
                    _ = try await transport.publishArtifact(epoch: epoch, capture: upload.capture)
                }
                localStore.removeStagedUpload(revision: upload.manifest.id)
            } catch { lastArtifactUploadError = error; continue }
        }
    }

    private func submit(_ command: SharedArea.Command, preserving draft: SharedAreaLocalDraft?,
                        publication: SharedAreaPublication.Confirmed?) async -> Submission {
        if let draft, deliveryRecord(for: command.id) == nil {
            do { try saveDraft(draft) }
            catch { lastPersistenceError = error; changed(); return .rejected(.localPersistence) }
        }
        guard status == .connected, let scope, let transport, let document else { return .rejected(.notConnected) }
        guard !isSubmitting else { return .rejected(.busy) }
        let existing = deliveryRecord(for: command.id)
        if let existing, existing.command != command { return .rejected(.invalidCommand) }
        if let existing, !existing.isPending { return result(for: existing) }
        guard scope.canSubmit(command) else { return existing == nil ? .rejected(.forbidden) : .uncertain(operation: command.id) }
        guard existing != nil || pendingOperations.isEmpty else { return .rejected(.busy) }
        var candidate = document
        let outcome: SharedArea.Outcome
        do { outcome = try candidate.apply(command) }
        catch SharedArea.Failure.conflict {
            if let existing {
                do { try finishOperation(existing.command.id, state: .rejected(.conflict)) }
                catch { lastPersistenceError = error; changed(); return .uncertain(operation: command.id) }
            }
            return .rejected(.conflict)
        }
        catch { return existing == nil ? .rejected(.invalidCommand) : .uncertain(operation: command.id) }
        let wasPending = existing != nil
        let current = generation
        isSubmitting = true
        do {
            if let publication { try publication.validateBindings(in: candidate, person: credentialScope.identity.person) }
            let newRecord = SharedAreaPendingOperation(command: command, actor: credentialScope.identity,
                publication: publication.map { .init(reviewDigest: $0.reviewDigest, author: $0.author, host: $0.host) },
                sourceBindings: publication?.sourceBindings ?? [], preservedDraft: draft, attempts: 1)
            try persist { state in
                if let index = state.operations.firstIndex(where: { $0.command.id == command.id }) {
                    guard state.operations[index].command == command, state.operations[index].isPending,
                          state.operations[index].attempts < UInt64.max else { throw SharedAreaLocalStoreError.invalidState }
                    if let publication {
                        guard state.operations[index].publication == .init(reviewDigest: publication.reviewDigest, author: publication.author, host: publication.host),
                              state.operations[index].sourceBindings == publication.sourceBindings else { throw SharedAreaLocalStoreError.invalidState }
                    }
                    state.operations[index].attempts += 1
                } else {
                    guard !state.operations.contains(where: \.isPending) else { throw SharedAreaLocalStoreError.staleGeneration }
                    try newRecord.validate(scope: state.scope)
                    if let publication { try publication.retainBindings(in: &state) }
                    state.operations.append(newRecord)
                }
            }
        } catch {
            isSubmitting = false; lastPersistenceError = error; changed()
            return wasPending ? .uncertain(operation: command.id) : .rejected(.localPersistence)
        }
        changed()
        do {
            let receipt = try await transport.apply(.init(epoch: scope.epoch, command: command))
            guard generation == current else { return .uncertain(operation: command.id) }
            let expectedReceiptRevision: UInt64
            switch outcome { case .applied(let revision), .duplicate(let revision): expectedReceiptRevision = revision }
            guard receipt.revision == expectedReceiptRevision else {
                failClosed(.incompatibleState, generation: current)
                return .uncertain(operation: command.id)
            }
            do {
                // Document, cursor, final receipt and only the submitted draft
                // are one atomic state. Newer snapshots and edited drafts win.
                try persist { state in
                    if state.appliedRevision < receipt.revision { state.document = candidate }
                    state.observedMembershipEpoch = max(state.observedMembershipEpoch, scope.epoch)
                    try Self.finishOperation(command.id, state: .accepted(receipt.revision), in: &state)
                }
                self.document = localState?.document
                admittedRevision = max(admittedRevision ?? 0, receipt.revision)
            } catch {
                failClosed(.localPersistence, generation: current); lastPersistenceError = error
                return .uncertain(operation: command.id)
            }
            isSubmitting = false; changed(); return .accepted(receipt)
        } catch {
            guard generation == current else { return .uncertain(operation: command.id) }
            isSubmitting = false
            if let record = deliveryRecord(for: command.id), !record.isPending {
                changed(); return result(for: record)
            }
            if let client = error as? CollaborationClientError, case let .server(status, code) = client, (400..<500).contains(status) {
                if status == 409, code == "staleEpoch" {
                    // Epoch rejection says nothing about an earlier uncertain
                    // attempt. Keep the exact record and refresh authority. One
                    // automatic refresh is enough; a still-stale retry remains
                    // pending for explicit delivery checking, avoiding a loop.
                    self.status = .reconnecting
                    if !wasPending {
                        Task { [weak self] in
                            await Task.yield()
                            guard let self, self.generation == current else { return }
                            await self.open()
                        }
                    }
                    changed(); return .uncertain(operation: command.id)
                }
                let definitive = [400, 401, 403, 404, 422].contains(status)
                    || (status == 409 && ["conflict", "revisionConflict"].contains(code))
                if !wasPending, definitive {
                    let reason: SharedAreaPendingOperation.Rejection = status == 409 ? .conflict : status == 401 || status == 403 || status == 404 ? .forbidden : .invalidCommand
                    do { try finishOperation(command.id, state: .rejected(reason)) }
                    catch { lastPersistenceError = error; changed(); return .uncertain(operation: command.id) }
                    if isAccessFailure(error), status != 403 { failClosed(.accessDenied, generation: current) }
                    changed()
                    return reason == .conflict ? .rejected(.conflict) : reason == .forbidden ? .rejected(.forbidden) : .rejected(.invalidCommand)
                }
                if isAccessFailure(error), status != 403 { failClosed(.accessDenied, generation: current) }
            }
            changed()
            return .uncertain(operation: command.id)
        }
    }

    private func result(for record: SharedAreaPendingOperation) -> Submission {
        switch record.state {
        case .pending: return .uncertain(operation: record.command.id)
        case .accepted(let revision): return .accepted(.init(revision: revision, duplicate: true))
        case .rejected(.conflict): return .rejected(.conflict)
        case .rejected(.forbidden): return .rejected(.forbidden)
        case .rejected(.invalidCommand): return .rejected(.invalidCommand)
        }
    }
    private func finishOperation(_ operation: SharedArea.ID<SharedArea.Operation>, state: SharedAreaPendingOperation.State) throws {
        try persist { try Self.finishOperation(operation, state: state, in: &$0) }
    }
    private static func finishOperation(_ operation: SharedArea.ID<SharedArea.Operation>, state result: SharedAreaPendingOperation.State,
                                        in state: inout SharedAreaLocalState) throws {
        guard let index = state.operations.firstIndex(where: { $0.command.id == operation }) else { throw SharedAreaLocalStoreError.invalidState }
        state.operations[index].state = result
        if case .accepted = result, let draft = state.operations[index].preservedDraft {
            state.drafts.removeAll { $0 == draft }
        }
        let completed = state.operations.filter { !$0.isPending }
        let retired = Set(completed.prefix(max(0, completed.count - 64)).map { $0.command.id })
        state.operations.removeAll { retired.contains($0.command.id) }
    }

    private func receive(_ value: CollaborationSession.Status, generation current: UUID) {
        guard generation == current else { return }
        switch value {
        case .connected(let replica):
            let wasConnected = status == .connected
            let oldRevision = document?.revision, oldEpoch = scope?.epoch
            do {
                status = try install(replica) ? .connected : .reconnecting
                changed()
                if status == .connected, !pendingOperations.isEmpty, !isSubmitting,
                   !wasConnected || oldRevision != document?.revision || oldEpoch != scope?.epoch {
                    scheduleRecovery()
                }
                if status == .connected, !wasConnected { scheduleUploads() }
            }
            catch let error as CollaborationClientError {
                failClosed(.incompatibleState, generation: current); lastPersistenceError = error
            }
            catch { failClosed(.localPersistence, generation: current); lastPersistenceError = error }
        case .reconnecting:
            // The last accepted content stays visible, but queued execution and
            // mutations are never inferred from a cached or disconnected Scope.
            scope = nil; status = .reconnecting; changed()
        case .unavailable:
            failClosed(.accessDenied, generation: current)
        case .incompatible:
            failClosed(.incompatibleState, generation: current)
        case .stopped:
            failClosed(.connectionEnded, generation: current)
        }
    }
    private func scheduleRecovery() {
        guard recoveryTask == nil, !isRecoveringOperations else { return }
        recoveryTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            _ = await recoverPendingOperations()
            recoveryTask = nil
        }
    }
    private func streamEnded(generation current: UUID) {
        guard generation == current else { return }
        failClosed(.connectionEnded, generation: current)
    }
    @discardableResult private func install(_ replica: CollaborationReplica, preservingPresence: Bool = false) throws -> Bool {
        guard replica.scope.area == localStore.scope.area else { throw CollaborationClientError.invalidSequence }
        let reconciled = try (localState?.operations ?? []).map { try $0.reconciled(with: replica.document) }
        let needsReconciliation = reconciled != (localState?.operations ?? [])
        // A presence-only frame must not rewrite/back up the complete document.
        // A new durable revision reloads disk so another view's newer snapshot,
        // camera or draft is never replaced by this view's delayed page.
        if localState?.document != replica.document || localState?.observedMembershipEpoch != replica.scope.epoch || localState?.accessDenied != false || needsReconciliation {
            let seed = SharedAreaLocalState(scope: localStore.scope, document: replica.document, observedMembershipEpoch: replica.scope.epoch)
            let cached = try localStore.load() ?? localState
            if let cached, cached.appliedRevision == replica.document.revision,
               cached.document != replica.document { throw CollaborationClientError.invalidSequence }
            if (cached?.appliedRevision ?? 0) <= replica.document.revision
                || (cached?.observedMembershipEpoch ?? 0) < replica.scope.epoch
                || (cached?.accessDenied == true && (cached?.observedMembershipEpoch ?? 0) <= replica.scope.epoch) {
                try persist(seed: seed) { state in
                    if state.appliedRevision == replica.document.revision && state.document != replica.document {
                        throw CollaborationClientError.invalidSequence
                    }
                    if state.appliedRevision <= replica.document.revision { state.document = replica.document }
                    state.observedMembershipEpoch = max(state.observedMembershipEpoch, replica.scope.epoch)
                    if replica.scope.epoch >= state.observedMembershipEpoch { state.accessDenied = false }
                    for record in state.operations where record.isPending {
                        let next = try record.reconciled(with: replica.document)
                        if next != record { try Self.finishOperation(record.command.id, state: next.state, in: &state) }
                    }
                }
            } else { localState = cached }
        }
        admittedRevision = max(admittedRevision ?? 0, replica.document.revision)
        admittedEpoch = max(admittedEpoch ?? 0, replica.scope.epoch)
        document = localState?.accessDenied == true ? nil : localState?.document
        if scope == nil || replica.scope.epoch >= scope!.epoch { scope = replica.scope }
        if !preservingPresence { presence = mergingLaneCursors(replica.presence); hostLiveness = replica.hosts ?? []; artifactHeads = replica.artifactHeads }
        for member in replica.members ?? [] { memberNames[member.person] = member.label }
        for peer in replica.presence where replica.members?.contains(where: { $0.person == peer.identity.person }) != true {
            if let label = peer.label, memberNames[peer.identity.person] == nil { memberNames[peer.identity.person] = label }
        }
        return document != nil && (admittedRevision ?? 0) >= (localState?.appliedRevision ?? 0)
            && (admittedEpoch ?? 0) >= (localState?.observedMembershipEpoch ?? 0)
    }
    private func persist(seed: SharedAreaLocalState? = nil, _ edit: (inout SharedAreaLocalState) throws -> Void) throws {
        // Retry only CAS contention, never corrupt/future/recovery documents.
        for attempt in 0..<3 {
            guard var state = try localStore.load() ?? localState ?? seed else { throw SharedAreaLocalStoreError.invalidState }
            try edit(&state)
            do {
                localState = try localStore.save(state)
                lastPersistenceError = nil
                return
            } catch SharedAreaLocalStoreError.staleGeneration where attempt < 2 { continue }
        }
        throw SharedAreaLocalStoreError.staleGeneration
    }
    private func failClosed(_ reason: Unavailability, generation current: UUID) {
        guard generation == current else { return }
        // Suppress this cache on reopen too. Keep private drafts and source IDs
        // for recovery; they remain incapable of authorizing reads or effects.
        // An incompatible schema is not loss of access: leave the cache bytes,
        // drafts and outbox exactly as they were so a newer build can read them.
        if reason != .incompatibleState {
            do {
                if try localStore.load() != nil || localState != nil { try persist { $0.accessDenied = true } }
            }
            catch { lastPersistenceError = error }
        }
        generation = UUID()
        stopCursorLane()
        let previous = connection; connection = nil
        updateTask?.cancel(); updateTask = nil; transport = nil
        admittedRevision = nil; admittedEpoch = nil
        document = nil; scope = nil; presence = []; hostLiveness = []; artifactHeads = []; isSubmitting = false
        status = .unavailable(reason); changed()
        if let previous {
            let retirement = UUID()
            retiringConnections[retirement] = Task { [weak self] in
                await previous.stop()
                self?.retiringConnections.removeValue(forKey: retirement)
            }
        }
    }
    private func awaitRetirements(_ pending: [Task<Void, Never>]) async {
        // Each task owns one already-retired connection. Waiting cannot stop a
        // connection that a newer open generation has since installed.
        for task in pending { await task.value }
    }
    private func isAccessFailure(_ error: any Error) -> Bool {
        if let client = error as? CollaborationClientError, case let .server(status, _) = client { return [401, 403, 404].contains(status) }
        return false
    }
    private func changed() {
        onChange?()
        for observer in Array(changeObservers.values) { observer() }
    }

    // MARK: Cursor lane

    /// Keeps the lane open while this generation is connected, reconnecting
    /// with backoff. A relay that refuses the upgrade (an older relay answers
    /// 404) is not retried: presence stays on update pages, as before the lane.
    private func startCursorLane(_ transport: any SharedAreaControllerTransport, generation current: UUID) {
        cursorLaneTask?.cancel()
        cursorLaneState = .connecting
        cursorLaneTask = Task { [weak self] in
            var backoff = 500
            while !Task.isCancelled {
                do {
                    let lane = try await transport.openCursorLane()
                    // Only `self?` across awaits: a dropped controller is not kept
                    // alive by its own lane.
                    guard !Task.isCancelled, self?.adoptCursorLane(lane, generation: current) == true else { await lane.close(); return }
                    backoff = 500
                    for await message in lane.messages {
                        guard !Task.isCancelled else { break }
                        self?.receiveCursorLane(message, generation: current)
                    }
                    await lane.close()
                    guard !Task.isCancelled, self?.cursorLaneEnded(.connecting, generation: current) == true else { return }
                } catch CollaborationClientError.server(let status, _) where (400..<500).contains(status) || status == 501 {
                    _ = self?.cursorLaneEnded(.off, generation: current)
                    return
                } catch {
                    guard !Task.isCancelled, self?.cursorLaneEnded(.connecting, generation: current) == true else { return }
                }
                do { try await Task.sleep(for: .milliseconds(backoff)) } catch { return }
                backoff = min(backoff * 2, 30_000)
            }
        }
    }
    private func adoptCursorLane(_ lane: any SharedAreaCursorLane, generation current: UUID) -> Bool {
        guard generation == current else { return false }
        cursorLane = lane; cursorLaneState = .live
        return true
    }
    private func cursorLaneEnded(_ next: CursorLaneState, generation current: UUID) -> Bool {
        guard generation == current else { return false }
        cursorLane = nil; cursorLaneState = next
        return true
    }
    private func stopCursorLane() {
        cursorLaneTask?.cancel(); cursorLaneTask = nil
        if let lane = cursorLane { Task { await lane.close() } }
        cursorLane = nil; cursorLaneState = .off
        laneCursors = [:]; rejectedCursorSessions = []
    }
    private func receiveCursorLane(_ message: Collaboration.CursorLaneMessage, generation current: UUID) {
        guard generation == current, status == .connected else { return }
        if let session = message.rejectedSession { rejectedCursorSessions.insert(session); return }
        guard let frame = message.frame, frame.identity.device != identity.device else { return }
        let device = frame.identity.device
        if let seen = laneCursors[device], seen.session == frame.session, frame.sequence <= seen.sequence { return }
        laneCursors[device] = (frame.session, frame.sequence)
        cursorLaneFramesApplied += 1
        let expires = Date().addingTimeInterval(15)
        let update = CursorUpdate(device: device, cursor: frame.cursor, viewport: frame.viewport, sentAt: frame.sentAt)
        guard let index = presence.firstIndex(where: { $0.identity.device == device }) else {
            // A teammate the pages have not shown yet: one full change.
            presence.append(.init(identity: frame.identity, cursor: frame.cursor, viewport: frame.viewport, expiresAt: expires,
                label: memberNames[frame.identity.person], session: frame.session, sequence: frame.sequence))
            changed()
            for observer in Array(cursorObservers.values) { observer(update) }
            return
        }
        let old = presence[index]
        presence[index] = .init(identity: old.identity, cursor: frame.cursor, viewport: frame.viewport, expiresAt: max(old.expiresAt, expires),
            label: old.label, usage: old.usage, session: frame.session, sequence: frame.sequence)
        // Appearing, disappearing or a view starting/stopping changes more
        // than a position: hit targets, follow targets. Those are rare.
        let shapeChanged = (old.cursor == nil) != (frame.cursor == nil) || (old.viewport?.valid == true) != (frame.viewport?.valid == true)
        if shapeChanged { changed() }
        for observer in Array(cursorObservers.values) { observer(update) }
    }
    /// A page's presence, keeping any cursor the lane has already delivered
    /// newer than the page's copy of the same session.
    private func mergingLaneCursors(_ incoming: [Collaboration.Presence]) -> [Collaboration.Presence] {
        guard !laneCursors.isEmpty else { return incoming }
        return incoming.map { page in
            let device = page.identity.device
            guard let lane = laneCursors[device], let session = page.session, session == lane.session,
                  let sequence = page.sequence, sequence < lane.sequence,
                  let current = presence.first(where: { $0.identity.device == device }) else { return page }
            return .init(identity: page.identity, cursor: current.cursor, viewport: current.viewport, expiresAt: page.expiresAt,
                label: page.label, usage: page.usage, session: lane.session, sequence: lane.sequence)
        }
    }
}
