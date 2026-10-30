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
    private let api: CollaborationAPI
    private let area: UUID
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
    public private(set) var isSubmitting = false
    public private(set) var lastPersistenceError: (any Error)?
    public var onChange: (@MainActor () -> Void)?
    public var view: SharedAreaLocalView { localState?.view ?? .init() }
    public var drafts: [SharedAreaLocalDraft] { localState?.drafts ?? [] }
    public var canSubmit: Bool { status == .connected && scope?.role != .viewer && scope != nil }
    public func canSubmit(_ command: SharedArea.Command) -> Bool {
        status == .connected && scope?.canSubmit(command) == true
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
    deinit { updateTask?.cancel() }
    public nonisolated static func liveTransport(endpoint: CollaborationServiceEndpoint, credential: Collaboration.Credential, area: UUID) throws -> any SharedAreaControllerTransport {
        try SharedAreaAPITransport(endpoint: endpoint, credential: credential, area: area)
    }

    /// Reopening revalidates authority; neither a cache nor an old live Scope is
    /// sufficient to submit. A late completion belongs only to this generation.
    public func open() async {
        let current = UUID(); generation = current
        let previous = connection; connection = nil
        let retirements = Array(retiringConnections.values)
        updateTask?.cancel(); updateTask = nil; transport = nil
        admittedRevision = nil; admittedEpoch = nil
        scope = nil; presence = []; isSubmitting = false
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
                    status = .reconnecting; changed()
                } else { failClosed(.incompatibleState, generation: current) }
            } else {
                status = .reconnecting; changed()
            }
        }
    }

    public func close() async {
        generation = UUID()
        let previous = connection; connection = nil
        let retirements = Array(retiringConnections.values)
        updateTask?.cancel(); updateTask = nil; transport = nil
        admittedRevision = nil; admittedEpoch = nil
        scope = nil; presence = []; document = nil; isSubmitting = false
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

    /// Confirmed source bindings are retained privately before a request can
    /// commit remotely. Missing objects still resolve as unavailable. This is
    /// not a durable command outbox: callers must retain this exact Confirmed
    /// value for an explicit retry after an uncertain response.
    public func submitPublication(_ publication: SharedAreaPublication.Confirmed) async -> Submission {
        guard publication.author == credentialScope.identity.person,
              publication.command.area == localStore.scope.area else { return .rejected(.forbidden) }
        return await submit(publication.command, preserving: nil, publication: publication)
    }

    private func submit(_ command: SharedArea.Command, preserving draft: SharedAreaLocalDraft?,
                        publication: SharedAreaPublication.Confirmed?) async -> Submission {
        if let draft {
            do { try saveDraft(draft) }
            catch { lastPersistenceError = error; changed(); return .rejected(.localPersistence) }
        }
        guard status == .connected, let scope, let transport, let document else { return .rejected(.notConnected) }
        guard !isSubmitting else { return .rejected(.busy) }
        guard scope.canSubmit(command) else { return .rejected(.forbidden) }
        var candidate = document
        let outcome: SharedArea.Outcome
        do { outcome = try candidate.apply(command) }
        catch SharedArea.Failure.conflict { return .rejected(.conflict) }
        catch { return .rejected(.invalidCommand) }
        if let publication {
            do {
                try publication.validateBindings(in: candidate, person: credentialScope.identity.person)
                if !publication.sourceBindings.isEmpty {
                    try persist { state in try publication.retainBindings(in: &state) }
                }
            } catch {
                lastPersistenceError = error; changed()
                return .rejected(.localPersistence)
            }
        }
        let current = generation
        isSubmitting = true; changed()
        do {
            let receipt = try await transport.apply(.init(epoch: scope.epoch, command: command))
            guard generation == current else { return .uncertain(operation: command.id) }
            let expectedReceiptRevision: UInt64
            switch outcome {
            case .applied(let revision), .duplicate(let revision): expectedReceiptRevision = revision
            }
            guard receipt.revision == expectedReceiptRevision else {
                failClosed(.incompatibleState, generation: current)
                return .uncertain(operation: command.id)
            }
            if let visible = self.document, receipt.revision > visible.revision {
                guard candidate.revision == receipt.revision else {
                    failClosed(.incompatibleState, generation: current)
                    return .uncertain(operation: command.id)
                }
                // The acknowledgement proves this deterministic candidate was
                // accepted. A newer stream snapshot always wins over it.
                do {
                    _ = try install(CollaborationReplica(state: .init(scope: self.scope ?? scope, document: candidate)), preservingPresence: true)
                } catch {
                    failClosed(.localPersistence, generation: current)
                    lastPersistenceError = error
                    return .accepted(receipt)
                }
            }
            if let draft {
                do {
                    try persist { state in state.drafts.removeAll { $0.id == draft.id && $0 == draft } }
                } catch { lastPersistenceError = error }
            }
            isSubmitting = false; changed()
            return .accepted(receipt)
        } catch {
            guard generation == current else { return .uncertain(operation: command.id) }
            isSubmitting = false
            if let client = error as? CollaborationClientError, case .server(status: 403, code: _) = client {
                // An area member can lack permission for this object/action.
                // The denied operation does not establish membership revocation.
                changed()
                return .rejected(.forbidden)
            }
            if isAccessFailure(error) {
                failClosed(.accessDenied, generation: current)
                return .rejected(.unavailable)
            }
            changed()
            if let client = error as? CollaborationClientError, case .server(status: 409, code: _) = client { return .rejected(.conflict) }
            if let client = error as? CollaborationClientError, case let .server(status, _) = client, (400..<500).contains(status) {
                return .rejected(.invalidCommand)
            }
            return .uncertain(operation: command.id)
        }
    }

    private func receive(_ value: CollaborationSession.Status, generation current: UUID) {
        guard generation == current else { return }
        switch value {
        case .connected(let replica):
            do { status = try install(replica) ? .connected : .reconnecting; changed() }
            catch let error as CollaborationClientError {
                failClosed(.incompatibleState, generation: current); lastPersistenceError = error
            }
            catch { failClosed(.localPersistence, generation: current); lastPersistenceError = error }
        case .reconnecting:
            // The last accepted content stays visible, but queued execution and
            // mutations are never inferred from a cached or disconnected Scope.
            status = .reconnecting; changed()
        case .unavailable:
            failClosed(.accessDenied, generation: current)
        case .stopped:
            failClosed(.connectionEnded, generation: current)
        }
    }
    private func streamEnded(generation current: UUID) {
        guard generation == current else { return }
        failClosed(.connectionEnded, generation: current)
    }
    @discardableResult private func install(_ replica: CollaborationReplica, preservingPresence: Bool = false) throws -> Bool {
        guard replica.scope.area == localStore.scope.area else { throw CollaborationClientError.invalidSequence }
        // A presence-only frame must not rewrite/back up the complete document.
        // A new durable revision reloads disk so another view's newer snapshot,
        // camera or draft is never replaced by this view's delayed page.
        if localState?.document != replica.document || localState?.observedMembershipEpoch != replica.scope.epoch || localState?.accessDenied != false {
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
                }
            } else { localState = cached }
        }
        admittedRevision = max(admittedRevision ?? 0, replica.document.revision)
        admittedEpoch = max(admittedEpoch ?? 0, replica.scope.epoch)
        document = localState?.accessDenied == true ? nil : localState?.document
        if scope == nil || replica.scope.epoch >= scope!.epoch { scope = replica.scope }
        if !preservingPresence { presence = replica.presence }
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
        do {
            if try localStore.load() != nil || localState != nil { try persist { $0.accessDenied = true } }
        }
        catch { lastPersistenceError = error }
        generation = UUID()
        let previous = connection; connection = nil
        updateTask?.cancel(); updateTask = nil; transport = nil
        admittedRevision = nil; admittedEpoch = nil
        document = nil; scope = nil; presence = []; isSubmitting = false
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
    private func changed() { onChange?() }
}
