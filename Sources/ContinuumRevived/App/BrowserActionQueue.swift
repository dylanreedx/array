import ContinuumRevivedCore
import Foundation

/// Owns action ordering and retry identity for the browser API. The caller
/// supplies a fresh runtime lookup and non-prompting grant check for every
/// queued action. The check must have no side effects: it runs again at the
/// commit boundary, for retries, and before returning an asynchronous result.
@MainActor
final class BrowserActionQueue {
    typealias Reply = WorkspaceAPIService.Reply
    typealias Action = @MainActor (Date) async -> Reply
    typealias Completion = @MainActor (Reply) -> Void
    typealias Authorization = @MainActor () -> WorkspaceAPIError?

    private struct Waiter {
        let authorize: Authorization
        let completion: Completion
    }

    private struct Key: Hashable {
        let agent: AgentID
        let key: String
    }

    private final class Entry {
        let key: Key
        let tile: UUID
        let operation: String
        let payload: String
        let deadline: Date
        let inputCount: Int
        let authorizationGeneration: UInt64
        let authorizationContext: String
        var currentInputCount: (@MainActor () -> Int?)?
        var authorize: Authorization?
        var action: Action?
        var waiters: [Waiter]
        var actionStarted = false
        var reply: Reply?
        var completionOrdinal: UInt64 = 0

        init(key: Key, tile: UUID, operation: String, payload: String, deadline: Date, inputCount: Int, authorizationGeneration: UInt64, authorizationContext: String,
             currentInputCount: @escaping @MainActor () -> Int?,
             authorize: @escaping @MainActor () -> WorkspaceAPIError?,
             action: @escaping Action, completion: @escaping Completion) {
            self.key = key
            self.tile = tile
            self.operation = operation
            self.payload = payload
            self.deadline = deadline
            self.inputCount = inputCount
            self.authorizationGeneration = authorizationGeneration
            self.authorizationContext = authorizationContext
            self.currentInputCount = currentInputCount
            self.authorize = authorize
            self.action = action
            self.waiters = [Waiter(authorize: authorize, completion: completion)]
        }
    }

    private var entries: [Key: Entry] = [:]
    private var pending: [UUID: [Key]] = [:]
    private var active: [UUID: Key] = [:]
    private var completed: [AgentID: [Key]] = [:]
    private var nextCompletionOrdinal: UInt64 = 0
    private let capacity = 64
    static let imageCacheByteLimit = 8 * 1_024 * 1_024
    var qaCachedImageBytes: Int {
        entries.values.reduce(0) { total, entry in
            guard case let .result(fields)? = entry.reply,
                  let data = fields["image"]?.object?["data"]?.string else { return total }
            return total + data.utf8.count
        }
    }

    /// Whether a retry of this key would be answered from the queue's history.
    func holds(agentId: AgentID, key: String) -> Bool { entries[Key(agent: agentId, key: key)] != nil }

    func submit(tileId: UUID, agentId: AgentID, key: String, operation: String, payload: String,
                deadline: Date, inputCount: Int, authorizationGeneration: UInt64 = 0, authorizationContext: String = "",
                currentInputCount: @escaping @MainActor () -> Int?,
                authorize: @escaping @MainActor () -> WorkspaceAPIError?,
                action: @escaping Action, completion: @escaping Completion) {
        let identity = Key(agent: agentId, key: key)
        if let existing = entries[identity] {
            guard existing.authorizationGeneration == authorizationGeneration, existing.authorizationContext == authorizationContext else {
                completion(.error(WorkspaceAPIError(code: .permissionDenied,
                    message: "Browser access was revoked since this request. Start a new request.")))
                return
            }
            // A cached outline or image must not escape after access was revoked.
            if let error = authorize() { completion(.error(error)); return }
            guard existing.tile == tileId, existing.operation == operation, existing.payload == payload else {
                completion(.error(WorkspaceAPIError(code: .idempotencyConflict,
                    message: "This idempotencyKey was already used for a different browser action.")))
                return
            }
            // Keep uncertain effects uncertain, even after the user takes over.
            if case let .error(error)? = existing.reply, error.code == .outcomeUnknown {
                completion(.error(error))
                return
            }
            guard let current = currentInputCount() else {
                completion(.error(WorkspaceAPIError(code: .browserNotLive, message: "This browser is not live. Reload the tile.")))
                return
            }
            guard current == existing.inputCount else {
                completion(.error(WorkspaceAPIError(code: .targetConflict,
                    message: "The user took control of this browser. Wait, then take a fresh snapshot.")))
                return
            }
            if let reply = existing.reply { completion(reply) }
            else { existing.waiters.append(Waiter(authorize: authorize, completion: completion)) }
            return
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining.isFinite, remaining <= 60 else {
            completion(.error(WorkspaceAPIError(code: .invalidRequest,
                message: "A browser action deadline must be finite and at most 60 seconds away.")))
            return
        }
        guard (pending[tileId]?.count ?? 0) < capacity else {
            completion(.error(WorkspaceAPIError(code: .busy,
                message: "This browser already has too many queued actions. Wait before trying again.")))
            return
        }
        // An uncertain action is a tombstone: evicting it could replay a
        // click or type whose outcome is unknown. Make room only by discarding
        // settled, non-uncertain results, and fail closed if none remain.
        guard reserveSlot(for: agentId) else {
            completion(.error(WorkspaceAPIError(code: .busy,
                message: "Too many browser actions are pending or have uncertain outcomes. Start a new agent session if more actions are needed.")))
            return
        }
        let entry = Entry(key: identity, tile: tileId, operation: operation, payload: payload, deadline: deadline,
                          inputCount: inputCount, authorizationGeneration: authorizationGeneration, authorizationContext: authorizationContext, currentInputCount: currentInputCount,
                          authorize: authorize, action: action, completion: completion)
        entries[identity] = entry
        pending[tileId, default: []].append(identity)
        let delay = max(0, deadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak entry] in
            guard let self, let entry, entry.reply == nil else { return }
            if self.active[entry.tile] == entry.key {
                // The operation may already have taken effect. Reply at the
                // deadline but retain the barrier until the operation returns.
                self.finish(entry, .error(WorkspaceAPIError(code: .outcomeUnknown,
                    message: "The browser action timed out and may have taken effect. Take a fresh snapshot before deciding what to do.")))
            } else {
                self.pending[entry.tile]?.removeAll { $0 == entry.key }
                self.finish(entry, .error(WorkspaceAPIError(code: .busy,
                    message: "The browser action expired in the queue before it ran. Take a fresh snapshot and try again.")))
                self.startNext(on: entry.tile)
            }
        }
        startNext(on: tileId)
    }

    private func startNext(on tile: UUID) {
        guard active[tile] == nil else { return }
        while active[tile] == nil, let key = pending[tile]?.first {
            pending[tile]?.removeFirst()
            guard let entry = entries[key], entry.reply == nil else { continue }
            if let failure = validationFailure(entry) {
                finish(entry, failure)
                continue
            }
            active[tile] = key
            Task { @MainActor [weak self] in
                guard let self else { return }
                if entry.reply == nil {
                    if let failure = self.validationFailure(entry) {
                        self.finish(entry, failure)
                    } else if let action = entry.action {
                        entry.actionStarted = true
                        let reply = await action(entry.deadline)
                        if entry.reply == nil { self.finish(entry, reply) }
                    }
                }
                if self.active[tile] == key { self.active[tile] = nil }
                self.trimCompleted(for: key.agent)
                self.startNext(on: tile)
            }
            return
        }
        if pending[tile]?.isEmpty == true { pending[tile] = nil }
    }

    private func validationFailure(_ entry: Entry) -> Reply? {
        guard entry.deadline > Date() else {
            return .error(WorkspaceAPIError(code: .busy,
                message: "The browser action expired before it ran. Take a fresh snapshot and try again."))
        }
        guard let authorize = entry.authorize, let currentInputCount = entry.currentInputCount else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "The browser action is no longer available."))
        }
        if let error = authorize() { return .error(error) }
        guard let current = currentInputCount() else {
            return .error(WorkspaceAPIError(code: .browserNotLive,
                message: "This browser is not live. Use array_browser_navigate with reload to restart the tile."))
        }
        guard current == entry.inputCount else {
            return .error(WorkspaceAPIError(code: .targetConflict,
                message: "The user took control of this browser. Wait, then take a fresh snapshot."))
        }
        return nil
    }

    private func finish(_ entry: Entry, _ reply: Reply) {
        guard entry.reply == nil else { return }
        // Once an async action has started, access may be revoked before it
        // returns. Do not cache or deliver a page result produced after that.
        let accessChanged = entry.actionStarted && entry.authorize?() != nil
        let userTookOver = entry.actionStarted && entry.currentInputCount?() != entry.inputCount
        let finalReply: Reply = accessChanged || userTookOver ? Self.revokedInFlight : reply
        entry.reply = finalReply
        nextCompletionOrdinal &+= 1
        entry.completionOrdinal = nextCompletionOrdinal
        completed[entry.key.agent, default: []].append(entry.key)
        trimImageCache()
        let waiters = entry.waiters
        entry.waiters.removeAll()
        // The retry cache holds results, never closures that retain a runtime,
        // workspace or service. An already-running Task holds its own action.
        entry.currentInputCount = nil
        entry.authorize = nil
        entry.action = nil
        trimCompleted(for: entry.key.agent)
        for waiter in waiters {
            if let error = waiter.authorize() {
                waiter.completion(entry.actionStarted ? Self.revokedInFlight : .error(error))
            } else {
                waiter.completion(finalReply)
            }
        }
    }

    /// A screenshot retry can hold megabytes. Keep a global bound, replacing
    /// older image replies with tombstones rather than replaying a capture.
    /// Waiters for the original operation still receive its actual result.
    private func trimImageCache() {
        while qaCachedImageBytes > Self.imageCacheByteLimit {
            guard let oldest = entries.values.filter({ entry in
                guard case let .result(fields)? = entry.reply else { return false }
                return fields["image"]?.object?["data"]?.string != nil
            }).min(by: { $0.completionOrdinal < $1.completionOrdinal }) else { return }
            oldest.reply = .error(WorkspaceAPIError(code: .outcomeUnknown,
                message: "The screenshot was captured but its cached image expired. Use a new request for another capture."))
        }
    }

    private static var revokedInFlight: Reply {
        .error(WorkspaceAPIError(code: .outcomeUnknown,
            message: "Access or control changed while the browser action was in progress; it may have taken effect. Wait, then take a fresh snapshot."))
    }

    private func mayEvict(_ key: Key) -> Bool {
        guard let entry = entries[key] else { return true }
        if active[entry.tile] == key { return false }
        if case let .error(error)? = entry.reply, error.code == .outcomeUnknown { return false }
        return entry.reply != nil
    }

    private func reserveSlot(for agent: AgentID) -> Bool {
        while entries.keys.lazy.filter({ $0.agent == agent }).count >= capacity {
            guard let index = completed[agent]?.firstIndex(where: mayEvict) else { return false }
            let key = completed[agent]!.remove(at: index)
            entries[key] = nil
        }
        return true
    }

    private func trimCompleted(for agent: AgentID) {
        while (completed[agent]?.count ?? 0) > capacity {
            guard let index = completed[agent]?.firstIndex(where: mayEvict) else { break }
            let key = completed[agent]!.remove(at: index)
            entries[key] = nil
        }
        if completed[agent]?.isEmpty == true { completed[agent] = nil }
    }
}
