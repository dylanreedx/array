import ContinuumRevivedCore
import ContinuumRevivedRelayProtocol
import Foundation

/// Phone → Mac commands over the hosted relay (`/v2/commands`).
///
/// The phone used to send Stop and Approve as ordinary sync events. The hosted
/// relay only lets the Mac publish events, so it answered every one with 403
/// and nothing reached the Mac. Commands have their own queue: the relay checks
/// the phone's capability, records which phone sent it, and keeps it until the
/// Mac collects it or it expires; the Mac posts back what happened.
public struct RelayCommandChannel: Sendable {
    public enum Failure: Error, Equatable { case http(Int, code: String), malformedResponse }
    private let baseURL: URL
    private let bearerToken: String
    private let session: URLSession

    public init(baseURL: URL, bearerToken: String, session: URLSession = RelaySyncTransport.makeDefaultSession()) {
        self.baseURL = baseURL; self.bearerToken = bearerToken; self.session = session
    }

    // Phone
    public func submit(_ request: RelayCommandRequest) async throws -> RelayCommandReceipt {
        try await call("POST", "/v2/commands", body: request)
    }
    public func status(_ key: UUID) async throws -> RelayCommandStatus {
        try await call("GET", "/v2/commands/\(key.uuidString)", body: Optional<RelayCommandResult>.none)
    }
    /// Submits and waits up to `timeout` for the Mac's result. Returns the
    /// last status seen: still `pending` means the Mac has not collected it
    /// yet, and it will run if the Mac collects it within its lifetime.
    public func send(_ request: RelayCommandRequest, waitingUpTo timeout: Duration,
                     pollEvery interval: Duration = .milliseconds(500)) async throws -> RelayCommandStatus {
        _ = try await submit(request)
        let clock = ContinuousClock(), deadline = clock.now + timeout
        var latest = try await status(request.idempotencyKey)
        while latest.state == .pending, clock.now < deadline {
            try await Task.sleep(for: interval)
            latest = try await status(request.idempotencyKey)
        }
        return latest
    }

    // Mac
    public func pending() async throws -> RelayCommandPage {
        try await call("GET", "/v2/commands/pending", body: Optional<RelayCommandResult>.none)
    }
    public func complete(_ key: UUID, _ result: RelayCommandResult) async throws -> RelayCommandStatus {
        try await call("POST", "/v2/commands/\(key.uuidString)/result", body: result)
    }

    private func call<Body: Encodable, Reply: Decodable>(_ method: String, _ path: String, body: Body?) async throws -> Reply {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let body {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.http(status, code: (try? JSONDecoder().decode(RelayErrorResponse.self, from: data))?.code ?? "http\(status)")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let reply = try? decoder.decode(Reply.self, from: data) else { throw Failure.malformedResponse }
        return reply
    }
}

/// The `approval.respond` payload. Plain JSON: a decision and the request it
/// answers, no conversation content.
public struct CompanionApprovalCommand: Codable, Sendable, Equatable {
    public var requestId: String; public var decision: ApprovalDecision
    public init(requestId: String, decision: ApprovalDecision) { self.requestId = requestId; self.decision = decision }
}

/// `transcript.request`: which key the phone can open and the version it
/// already shows. No transcript content travels this way; the Mac answers by
/// publishing the encrypted transcript as an event.
public struct CompanionTranscriptRequest: Codable, Sendable, Equatable {
    public var keyID: UUID; public var knownVersion: UInt64?
    public init(keyID: UUID, knownVersion: UInt64?) { self.keyID = keyID; self.knownVersion = knownVersion }
}

/// What the Mac did with a `transcript.request`.
public enum CompanionTranscriptOutcome: String, Codable, Sendable {
    /// The encrypted transcript is on its way as an event.
    case published
    /// The phone already shows this version.
    case unchanged
    /// The Mac has no transcript for that agent.
    case unavailable
    /// The Mac holds no key with that id: the phone was paired before the
    /// pairing secret existed, or by another Mac.
    case unknownKey
    case unauthorized
    /// Publishing the event failed (for example the relay refused its size).
    case failed
}

/// `agent.message`: the phone's text, sealed (`TranscriptSyncCrypto.sealMessage`).
/// The relay sees the key id and ciphertext only.
public struct CompanionSealedMessage: Codable, Sendable, Equatable {
    public var keyID: UUID; public var combined: Data
    public init(keyID: UUID, combined: Data) { self.keyID = keyID; self.combined = combined }
}

/// What the Mac did with the phone's message.
public enum AgentMessageOutcome: String, Codable, Sendable {
    /// The agent took it, as if typed into its composer.
    case accepted
    /// A turn is running; the phone keeps the draft. Queueing and steering
    /// from the phone come later, once witnessed.
    case busy
    /// The agent's CLI cannot take a prompt now (signed out, not installed).
    case notReady
    case notFound
    case empty
    /// Refused for another reason (the session is held elsewhere, a shared
    /// agent's control rules).
    case refused
    case unauthorized
    /// The Mac holds no key with that id.
    case unknownKey
    /// It did not open: wrong key, tampered, or replayed under another command.
    case invalid
    /// A Mac with no message handler.
    case unsupported
    /// The Mac restarted while handing this to the agent; it may or may not
    /// have arrived. The Mac does not hand it over a second time.
    case interrupted
}

/// What the Mac has done with each `agent.message`, on disk, so a restart
/// cannot hand the same message to an agent twice.
///
/// The receiver marks a message started before handing it to the agent and
/// records the result after. A Mac that dies in between finds the started mark
/// when the relay lists the command again, and answers `interrupted` instead
/// of running it. Entries are dropped after `RelayCommandLimits.retention`,
/// long after the relay stops listing the command.
public struct CompanionCommandJournal: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var startedAt: Date; public var result: RelayCommandResult?
    }
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func entries() -> [UUID: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let stored = (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
        // Keys differing only in case parse to one UUID; keep either, never trap.
        return Dictionary(stored.compactMap { key, entry in UUID(uuidString: key).map { ($0, entry) } },
                          uniquingKeysWith: { first, _ in first })
    }
    public func entry(_ key: UUID) -> Entry? { entries()[key] }

    public func markStarted(_ key: UUID, at date: Date = Date()) throws {
        try update(now: date) { $0[key] = Entry(startedAt: date, result: nil) }
    }
    public func record(_ key: UUID, _ result: RelayCommandResult, at date: Date = Date()) throws {
        try update(now: date) { $0[key] = Entry(startedAt: $0[key]?.startedAt ?? date, result: result) }
    }

    private func update(now: Date, _ change: (inout [UUID: Entry]) -> Void) throws {
        var all = entries().filter { now.timeIntervalSince($0.value.startedAt) < RelayCommandLimits.retention }
        change(&all)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Dictionary(uniqueKeysWithValues: all.map { ($0.key.uuidString, $0.value) }))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// The Mac's side: collects pending commands, runs each once, posts the result.
///
/// Collection is by "everything not yet answered", not by a cursor, so a
/// command sent while the Mac was asleep or offline is still collected when it
/// returns (the event feed starts at its head and would have skipped it). A
/// result that fails to post is kept and re-posted without running the
/// command again. With a journal, an `agent.message` is also never run twice
/// across a restart (see `CompanionCommandJournal`); the other kinds are safe
/// to repeat.
public actor CompanionCommandReceiver {
    public typealias Handler = @Sendable (RelayCommand) async -> RelayCommandResult
    private let channel: RelayCommandChannel
    private let handler: Handler
    private let interval: Duration
    private let onDiagnostic: (@Sendable (String) -> Void)?
    private let journal: CompanionCommandJournal?
    private var unreported: [UUID: RelayCommandResult] = [:]
    private var draining = false
    private var loop: Task<Void, Never>?

    public init(channel: RelayCommandChannel, interval: Duration = .seconds(2), journal: CompanionCommandJournal? = nil,
                onDiagnostic: (@Sendable (String) -> Void)? = nil, handler: @escaping Handler) {
        self.channel = channel; self.interval = interval; self.journal = journal
        self.onDiagnostic = onDiagnostic; self.handler = handler
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self, interval] in
            // A relay without the command queue (older than schema 6) answers
            // 404 forever: back off to a minute and log once per failure streak.
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                do { _ = try await self.drain(); failures = 0 } catch is CancellationError { return } catch {
                    if failures == 0 { await self.report("command collection failed: \(error)") }
                    failures += 1
                }
                let delay = failures == 0 ? interval : min(interval * (1 << min(failures, 5)), .seconds(60))
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil }

    /// One pass. Returns how many commands were run (not re-posted).
    @discardableResult
    public func drain() async throws -> Int {
        guard !draining else { return 0 }
        draining = true; defer { draining = false }
        var ran = 0
        let commands = try await channel.pending().commands
        defer {
            // A full listing names every command still owed a result; any
            // other kept result was posted already (its reply lost) or expired.
            if commands.count < RelayCommandLimits.pageSize {
                let listed = Set(commands.map(\.idempotencyKey))
                unreported = unreported.filter { listed.contains($0.key) }
            }
        }
        for command in commands {
            let result: RelayCommandResult
            if let kept = unreported[command.idempotencyKey] { result = kept } else {
                if let journal, command.kind == RelayCommandKind.agentMessage {
                    guard let journaled = await runOnce(command, journal: journal) else { continue }
                    (result, ran) = (journaled.result, ran + (journaled.ran ? 1 : 0))
                } else {
                    result = await handler(command); ran += 1
                }
                unreported[command.idempotencyKey] = result
            }
            do {
                _ = try await channel.complete(command.idempotencyKey, result)
                unreported[command.idempotencyKey] = nil
            } catch {
                report("command result not posted (kept for retry): \(error)")
            }
        }
        return ran
    }

    /// Runs a message unless the journal says an earlier process already
    /// started it. Nil when the started mark cannot be written: running it
    /// unrecorded could run it twice, so it waits for the next pass.
    private func runOnce(_ command: RelayCommand, journal: CompanionCommandJournal) async -> (result: RelayCommandResult, ran: Bool)? {
        let key = command.idempotencyKey
        if let entry = journal.entry(key) {
            if let result = entry.result { return (result, false) }
            let result = RelayCommandResult(outcome: AgentMessageOutcome.interrupted.rawValue)
            do { try journal.record(key, result) } catch { report("command journal not written: \(error)") }
            return (result, false)
        }
        do { try journal.markStarted(key) } catch {
            report("command journal not written; message held: \(error)")
            return nil
        }
        let result = await handler(command)
        do { try journal.record(key, result) } catch { report("command journal not written: \(error)") }
        return (result, true)
    }

    private func report(_ line: String) { onDiagnostic?(line) }
}
