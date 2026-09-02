import Foundation
import ContinuumRevivedCore
import ContinuumRevivedRelayProtocol

// Ticket: docs/38-tickets/86-relay-sync-transport.md (slice 2, milestone B)
//
// The client side of the relay: a `SyncTransport` over the HTTP long-poll
// surface `RelayHTTPServer` serves. Both apps use it — the Mac publishes
// through `send(_:)`, the phone consumes `inbound` — and unlike the CloudKit
// transport there is NO app-owned fetch loop: `start()` owns polling, so the
// class of bug ticket 85 uncovered (receivers subscribed to a stream nothing
// feeds) cannot recur here.
//
// Lifecycle: `start()` begins hello → long-poll → yield; `stop()` ends both
// streams. Errors surface on `connectionState` (`.reconnecting` while
// backing off), and a `cursorUnrecoverable` refusal self-heals: the cursor
// resets to 0 and polling continues — the feed becomes whole again as soon
// as the publisher's next snapshot lands (the hub refuses holey feeds, so
// waiting is the only lossless move).
//
// The transport holds no storage: cursor persistence is the caller's job via
// `onCursorChange` (iOS wires it to UserDefaults), which keeps this file
// platform-free and the checks hermetic.
public final class RelaySyncTransport: SyncTransport, @unchecked Sendable {
    public enum APIVersion: Sendable, Equatable { case legacyV1, hardenedV2 }
    // @unchecked: mutable state (loopTask/cursor/stopped) is confined behind
    // `lock`; everything else is immutable config or thread-safe (URLSession,
    // AsyncStream continuations).

    public let inbound: AsyncStream<SyncMessage>
    public let connectionState: AsyncStream<ConnectionState>

    private let inboundContinuation: AsyncStream<SyncMessage>.Continuation
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    private let baseURL: URL
    private let bearerToken: String
    private let deviceLabel: String
    private let session: URLSession
    private let pollWaitMs: UInt64
    /// Reconnect backoff schedule; the last entry repeats. Injected so checks
    /// run in milliseconds while production waits like an adult.
    private let backoffNanoseconds: [UInt64]
    private let onCursorChange: (@Sendable (UInt64) -> Void)?
    /// Called with a human-readable line for every loop failure —
    /// `connectionState` deliberately stays coarse, but the app's file-sink
    /// diagnostics need the underlying error or reconnect loops are
    /// undebuggable (learned 2026-07-18, the hard way, twice).
    private let onDiagnostic: (@Sendable (String) -> Void)?
    private let apiVersion: APIVersion

    /// When true, the first successful hello fast-forwards the cursor to the
    /// hub's `latestSeq` — a live-only feed. The Mac uses this: its inbound
    /// leg only cares about messages that arrive while it runs (approval
    /// responses), and replaying the ring would mostly echo its own past
    /// publishes back at it.
    private let startAtHead: Bool

    private let lock = NSLock()
    private var loopTask: Task<Void, Never>?
    private var cursor: UInt64
    private var cursorInitialized = false
    private var stopped = false

    public init(
        baseURL: URL,
        bearerToken: String,
        deviceLabel: String,
        initialCursor: UInt64 = 0,
        startAtHead: Bool = false,
        pollWaitMs: UInt64 = 25_000,
        backoffNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000, 15_000_000_000],
        session: URLSession = RelaySyncTransport.makeDefaultSession(),
        onCursorChange: (@Sendable (UInt64) -> Void)? = nil,
        onDiagnostic: (@Sendable (String) -> Void)? = nil,
        apiVersion: APIVersion = .legacyV1
    ) {
        precondition(!backoffNanoseconds.isEmpty, "backoff schedule must not be empty")
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.deviceLabel = deviceLabel
        self.startAtHead = startAtHead
        self.cursor = initialCursor
        self.pollWaitMs = pollWaitMs
        self.backoffNanoseconds = backoffNanoseconds
        self.session = session
        self.onCursorChange = onCursorChange
        self.onDiagnostic = onDiagnostic
        self.apiVersion = apiVersion

        var inboundContinuation: AsyncStream<SyncMessage>.Continuation!
        self.inbound = AsyncStream { inboundContinuation = $0 }
        self.inboundContinuation = inboundContinuation
        var stateContinuation: AsyncStream<ConnectionState>.Continuation!
        self.connectionState = AsyncStream { stateContinuation = $0 }
        self.stateContinuation = stateContinuation
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    /// Idempotent. Begins the hello → long-poll loop; a stopped transport
    /// cannot be restarted (make a new one — they're cheap).
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard loopTask == nil, !stopped else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let task = loopTask
        loopTask = nil
        lock.unlock()
        task?.cancel()
        stateContinuation.yield(.disconnected(reason: "stopped"))
        stateContinuation.finish()
        inboundContinuation.finish()
    }

    // MARK: SyncTransport

    public func send(_ message: SyncMessage) async throws {
        let body: Data
        do {
            body = try JSONEncoder().encode(message)
        } catch {
            throw SyncTransportError.sendFailed(reason: "encode: \(String(describing: error))")
        }
        let requestBody: Data
        let path: String
        let acceptedStatus: Int
        switch apiVersion {
        case .legacyV1:
            requestBody = body
            path = "/v1/publish"
            acceptedStatus = 200
        case .hardenedV2:
            let request = RelayPublishRequest(
                kind: "sync.message",
                payload: body,
                isSnapshot: Self.isSnapshot(message)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            requestBody = try encoder.encode(request)
            path = "/v2/events"
            acceptedStatus = 201
        }
        let reply: (Data, URLResponse)
        do {
            reply = try await session.data(for: makeRequest("POST", path: path, body: requestBody))
        } catch {
            throw SyncTransportError.notConnected
        }
        let status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == acceptedStatus else {
            let code = (try? JSONDecoder().decode(RelayErrorBody.self, from: reply.0))?.code ?? "http\(status)"
            throw SyncTransportError.sendFailed(reason: code)
        }
    }

    // MARK: Poll loop

    private func runLoop() async {
        var backoffIndex = 0
        var announcedConnected = false
        while !Task.isCancelled, !isStopped {
            do {
                if !announcedConnected {
                    try await hello()
                    stateContinuation.yield(.connected)
                    announcedConnected = true
                }
                let response = try await poll(after: currentCursor)
                backoffIndex = 0
                // Hub reset can also happen BETWEEN polls with no connection
                // error (fast restart on the same port): hello never re-runs,
                // so the stale-cursor detection must live here too — every
                // poll response carries the hub's latestSeq.
                if response.latestCursor < currentCursor {
                    onDiagnostic?("relay poll: hub reset detected (latestSeq \(response.latestCursor) < cursor \(currentCursor)) — cursor reset to 0")
                    advanceCursor(to: 0)
                    continue
                }
                for message in response.messages {
                    inboundContinuation.yield(message)
                }
                if response.latestDeliveredCursor > currentCursor {
                    advanceCursor(to: response.latestDeliveredCursor)
                }
                if apiVersion == .hardenedV2, response.messages.isEmpty {
                    try await Task.sleep(for: .milliseconds(750))
                }
            } catch let error as RelayClientError where error == .cursorUnrecoverable {
                // Self-heal: reset and wait for the publisher's next snapshot
                // (the hub refuses holey feeds; a fresh cursor becomes whole
                // the moment a bridging snapshot exists).
                onDiagnostic?("relay loop: cursorUnrecoverable — resetting cursor to 0")
                advanceCursor(to: 0)
                announcedConnected = false
                stateContinuation.yield(.reconnecting)
                await sleepBackoff(index: &backoffIndex)
            } catch is CancellationError {
                return
            } catch {
                onDiagnostic?("relay loop: \(String(describing: error))")
                announcedConnected = false
                stateContinuation.yield(.reconnecting)
                await sleepBackoff(index: &backoffIndex)
            }
        }
    }

    private enum RelayClientError: Error, Equatable {
        case cursorUnrecoverable
        case httpStatus(Int, code: String)
        case malformedResponse
    }

    private func hello() async throws {
        if apiVersion == .hardenedV2 {
            // Authentication is exercised by the first event read. The v2
            // store owns durable sequences, so there is no ephemeral hub
            // identity to negotiate before polling.
            return
        }
        let body = try JSONEncoder().encode(RelayHelloRequestBody(deviceLabel: deviceLabel, cursor: currentCursor == 0 ? nil : currentCursor))
        let (data, response) = try await session.data(for: makeRequest("POST", path: "/v1/hello", body: body))
        try Self.checkStatus(data: data, response: response)
        guard let welcome = try? JSONDecoder().decode(RelayHelloResponse.self, from: data) else {
            throw RelayClientError.malformedResponse
        }
        if consumeCursorFastForwardFlag() {
            advanceCursor(to: welcome.latestSeq)
        }
        // A cursor AHEAD of the hub proves the hub restarted (seq is
        // hub-lifetime-scoped and a cursor only advances by consuming) —
        // without this reset the client silently sees nothing until the new
        // hub's seq passes the stale cursor. Fresh feed + the publisher's
        // next snapshot make it whole, same as any fresh subscriber.
        if welcome.latestSeq < currentCursor {
            onDiagnostic?("relay hello: hub reset detected (latestSeq \(welcome.latestSeq) < cursor \(currentCursor)) — cursor reset to 0")
            advanceCursor(to: 0)
        }
    }

    private func consumeCursorFastForwardFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let shouldFastForward = startAtHead && !cursorInitialized
        cursorInitialized = true
        return shouldFastForward
    }

    /// Operator-only: registers another device's pairing token with the
    /// relay (the Mac calls this when a phone completes the pairing
    /// exchange, so the phone's existing bearer works against the relay).
    public func registerToken(_ token: String, scopes: Scope) async throws {
        if apiVersion == .hardenedV2 {
            // Hardened credentials are minted by the single-use pairing
            // exchange; caller-selected token registration is intentionally
            // unavailable in v2.
            return
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(RelayRegisterTokenRequestBody(token: token, scopeRawValue: scopes.rawValue))
        } catch {
            throw SyncTransportError.sendFailed(reason: "encode: \(String(describing: error))")
        }
        let reply: (Data, URLResponse)
        do {
            reply = try await session.data(for: makeRequest("POST", path: "/v1/tokens", body: body))
        } catch {
            throw SyncTransportError.notConnected
        }
        let status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 || status == 200 else {
            let code = (try? JSONDecoder().decode(RelayErrorBody.self, from: reply.0))?.code ?? "http\(status)"
            throw SyncTransportError.sendFailed(reason: code)
        }
    }

    private struct PollBatch {
        var messages: [SyncMessage]
        var latestCursor: UInt64
        var latestDeliveredCursor: UInt64
    }

    private func poll(after: UInt64) async throws -> PollBatch {
        if apiVersion == .hardenedV2 {
            let path = "/v2/events?cursor=\(after)"
            let (data, response) = try await session.data(for: makeRequest("GET", path: path, body: nil))
            try Self.checkStatus(data: data, response: response)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let page = try? decoder.decode(RelayEventPage.self, from: data) else {
                throw RelayClientError.malformedResponse
            }
            if consumeCursorFastForwardFlag() {
                let latest = UInt64(max(0, page.latestSequence))
                return PollBatch(messages: [], latestCursor: latest, latestDeliveredCursor: latest)
            }
            let events = ([page.snapshot].compactMap { $0 } + page.events)
                .filter { $0.sequence > Int64(after) }
                .sorted { $0.sequence < $1.sequence }
            let messages = events.compactMap { try? JSONDecoder().decode(SyncMessage.self, from: $0.payload) }
            let delivered = events.last.map { UInt64(max(0, $0.sequence)) } ?? after
            return PollBatch(
                messages: messages,
                latestCursor: UInt64(max(0, page.latestSequence)),
                latestDeliveredCursor: delivered
            )
        }
        let path = "/v1/poll?after=\(after)&waitMs=\(pollWaitMs)"
        let (data, response) = try await session.data(for: makeRequest("GET", path: path, body: nil))
        try Self.checkStatus(data: data, response: response)
        guard let decoded = try? JSONDecoder().decode(RelayPollResponse.self, from: data) else {
            throw RelayClientError.malformedResponse
        }
        return PollBatch(
            messages: decoded.envelopes.map(\.message),
            latestCursor: decoded.latestSeq,
            latestDeliveredCursor: decoded.envelopes.last?.seq ?? after
        )
    }

    private static func isSnapshot(_ message: SyncMessage) -> Bool {
        if case .snapshot = message { return true }
        return false
    }

    private static func checkStatus(data: Data, response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 200 else { return }
        let code = (try? JSONDecoder().decode(RelayErrorBody.self, from: data))?.code ?? "http\(status)"
        if status == 409, code == "cursorUnrecoverable" {
            throw RelayClientError.cursorUnrecoverable
        }
        throw RelayClientError.httpStatus(status, code: code)
    }

    /// The relay's own URL session.
    ///
    /// This used to default to `URLSession.shared`, which carries the process
    /// URL cache: a long-poll transport at a few requests a second per project
    /// therefore fed every relay response into `CFURLCache`'s SQLite store, and
    /// the baseline disk profile was dominated by `Cache.db` writes for bytes
    /// nothing ever reads back. Relay replies are cursor-addressed and consumed
    /// exactly once — there is no cache hit to be had, only the write.
    ///
    /// `urlCache = nil` removes the store; the request policy is belt and
    /// braces for anything constructing a transport with its own session.
    /// Cookies and credential reuse are not part of the protocol (every request
    /// carries a bearer token), so nothing here is load-bearing beyond the cache.
    /// WITNESS, and its limit. `ContinuumRevivedRelayChecks` asserts the
    /// CONFIGURATION — no cache on the default session, and a poll request that
    /// declines the cache — which catches a regression to `URLSession.shared` or
    /// a dropped policy. It does NOT observe cache writes against a live server;
    /// that would need a loopback probe of `URLCache.shared` with a positive
    /// control proving the response was cacheable in the first place. An earlier
    /// draft of this comment claimed a `--relay-cache-write-check` that was never
    /// written.
    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// QA: the session this transport will actually use, and one of the exact
    /// requests it will send. Both are needed to witness "an unchanged poll
    /// writes nothing to a response cache" against a real server rather than
    /// against a re-derivation of the transport's intent.
    public var qaSession: URLSession { session }
    public func qaPollRequest(path: String) -> URLRequest { makeRequest("GET", path: path, body: nil) }

    private func makeRequest(_ method: String, path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Must outlive the server's bounded long-poll wait (≤30s) or every
        // quiet poll dies as a client timeout and loops through backoff.
        request.timeoutInterval = 40
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func sleepBackoff(index: inout Int) async {
        let delay = backoffNanoseconds[min(index, backoffNanoseconds.count - 1)]
        index += 1
        try? await Task.sleep(nanoseconds: delay)
    }

    // MARK: Locked state

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private var currentCursor: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return cursor
    }

    private func advanceCursor(to newValue: UInt64) {
        lock.lock()
        cursor = newValue
        lock.unlock()
        onCursorChange?(newValue)
    }
}
