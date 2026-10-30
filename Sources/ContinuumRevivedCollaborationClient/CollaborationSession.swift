import Foundation
import ContinuumRevivedCollaborationProtocol

/// A native view owns one session and stops it on close. The transport task holds
/// only a weak session reference; releasing the view/session cancels held reads.
public actor CollaborationSession {
    public enum Status: Sendable {
        case connected(CollaborationReplica)
        case reconnecting(CollaborationReplica?)
        case unavailable
        /// The service answered with a schema or document this build cannot
        /// apply. Not loss of access: the caller keeps its local cache intact.
        case incompatible
        case stopped
    }
    private let api: CollaborationAPI
    private let area: UUID
    private let sleep: @Sendable (Int) async throws -> Void
    private var replica: CollaborationReplica?
    private var through: UInt64?
    /// After a failure, probe with a 1ms held read before holding for 25s. It
    /// still passes subscription admission (429 while overloaded), but an idle
    /// healthy service answers at once instead of staying "reconnecting".
    private var recovering = false
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<Status>.Continuation?
    private var generation = UUID()
    public private(set) var status: Status = .stopped

    public init(api: CollaborationAPI, area: UUID, initial: Collaboration.State? = nil,
                sleep: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }) throws {
        self.api = api; self.area = area; self.sleep = sleep
        if let initial {
            guard initial.scope.area.rawValue == area else { throw CollaborationClientError.invalidSequence }
            replica = try CollaborationReplica(state: initial)
        }
    }
    deinit { task?.cancel(); continuation?.finish() }

    /// Full replica snapshots can coalesce for rendering. Durable events have
    /// already been validated/applied in order before each notification.
    public func start() async -> AsyncStream<Status> {
        await stop()
        let pair = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        let current = UUID(); generation = current
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.stop(generation: current) } }
        let api = api, area = area, sleeper = sleep
        task = Task { [weak self] in
            var backoff = 250
            while !Task.isCancelled {
                do {
                    guard let needsSnapshot = await self?.needsSnapshot(current) else { return }
                    if needsSnapshot {
                        let state = try await api.state(area: area)
                        guard await self?.install(state, generation: current) == true else { return }
                    }
                    guard let request = await self?.request(current) else { return }
                    let page = try await api.updates(area: area, request: request)
                    guard try await self?.receive(page, generation: current) == true else { return }
                    backoff = 250
                } catch {
                    if Task.isCancelled { return }
                    guard let retry = await self?.failed(error, generation: current), retry else { return }
                    do { try await sleeper(backoff) } catch { return }
                    backoff = min(backoff * 2, 10_000)
                }
            }
        }
        return pair.stream
    }
    public func stop() async { await stop(generation: generation) }
    private func stop(generation current: UUID) async {
        guard current == generation else { return }
        generation = UUID()
        let old = task; task = nil
        old?.cancel()
        continuation?.finish(); continuation = nil
        status = .stopped
        await old?.value
    }
    private func needsSnapshot(_ current: UUID) -> Bool? {
        guard current == generation else { return nil }
        return replica == nil
    }
    private func install(_ state: Collaboration.State, generation current: UUID) -> Bool {
        guard current == generation else { return false }
        guard state.scope.area.rawValue == area, let replica = try? CollaborationReplica(state: state) else {
            finishUnavailable(.incompatible)
            return false
        }
        self.replica = replica; through = nil
        emit(.connected(replica))
        return true
    }
    private func request(_ current: UUID) -> Collaboration.UpdateRequest? {
        guard current == generation, let replica else { return nil }
        return .init(after: replica.document.revision, through: through,
            presenceVersion: replica.presenceVersion, waitMilliseconds: through != nil ? 0 : recovering ? 1 : 25_000)
    }
    private func receive(_ page: Collaboration.Updates, generation current: UUID) throws -> Bool {
        guard current == generation, var replica else { return false }
        try replica.receive(page)
        self.replica = replica
        through = page.hasMore ? page.through : nil
        recovering = false
        // A bounded page short of its high-water mark is a stale prefix, not
        // the shared state. Report it as catching up until the tail completes.
        emit(page.hasMore ? .reconnecting(replica) : .connected(replica))
        return true
    }
    private func failed(_ error: any Error, generation current: UUID) -> Bool {
        guard current == generation else { return false }
        recovering = true
        if error is DecodingError || error is SharedArea.Failure {
            replica = nil; through = nil
            finishUnavailable(.incompatible)
            return false
        }
        if let error = error as? CollaborationClientError {
            switch error {
            // A compacted cursor ("snapshotRequired"), a gap or a revision
            // conflict all refetch the full snapshot; none is a silent gap.
            case .invalidSequence, .server(status: 409, code: _):
                replica = nil; through = nil
            // Subscription capacity is temporary, not a membership decision.
            // Keep the validated replica/cursor while the existing bounded
            // reconnect loop waits for another held read to release its slot.
            case .server(let status, _) where status == 429 || status >= 500: break
            default:
                finishUnavailable()
                return false
            }
        }
        emit(.reconnecting(replica))
        return true
    }
    private func finishUnavailable(_ terminal: Status = .unavailable) {
        replica = nil; through = nil
        emit(terminal)
        // Finishing a stream is not an explicit user close. Its termination
        // callback must not overwrite this terminal state with .stopped.
        generation = UUID(); task = nil
        let old = continuation; continuation = nil
        old?.finish()
    }
    private func emit(_ value: Status) { status = value; continuation?.yield(value) }
}
