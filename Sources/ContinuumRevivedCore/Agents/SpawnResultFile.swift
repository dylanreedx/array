import Foundation

// The file channel that makes `spawn_agent` collectable.
//
// Witnessed live 2026-08-22: a managed pi agent's model called Array's
// `spawn_agent` tool twice; both children ran, but the tool is fire-and-forget,
// so the model had no way to collect their results, slept in a loop, gave up
// and redid the work itself. Separately, when Array REFUSED a spawn the model
// still saw "spawned: <role>" — `refuseSpawn` synthesizes transcript items the
// model never receives.
//
// The channel is deliberately a FILE, not IPC: production pi is one process
// per turn (`PiAgentRunner`), the extension is re-instantiated every turn and
// keeps no memory across turns, and pi enforces no tool timeout — so the
// extension's `wait_agents` tool simply polls
// `<parent cwd>/.array/spawn-results/<toolCallId>.json` until every requested
// handle reaches a terminal status. `.array/` is project-local scratch, keyed
// by the parent's working directory — the same directory `ctx.cwd` names
// inside the extension.
//
// Array writes three times per spawn:
//   1. `refused`   — synchronously, with the refusal reason (the first time a
//                    refusal is visible to the MODEL rather than only the UI),
//   2. `spawned`   — right after a successful launch,
//   3. terminal    — from the child's `.turnCompleted`, carrying the child's
//                    final assistant text (capped; truncation is noted).
public struct SpawnResultFile: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    /// Bytes of `finalText` kept in a terminal result. The child's full answer
    /// stays in its own transcript; this is a courier, not an archive.
    public static let finalTextByteCap = 32 * 1024

    public enum Status: String, Codable, Sendable {
        case deliveryPending = "delivery_pending"
        case alreadyDelivered = "already_delivered"
        case spawned
        case refused
        case completed
        case failed
        case interrupted
    }

    public var turnIdentity: String?
    public var recipientId: UUID?
    public var deliveredVia: String?
    public var deliveryReceipt: String?

    public var schema: Int
    public var toolCallId: String
    public var status: Status
    public var agentId: UUID?
    public var role: String?
    public var reason: String?
    public var finalText: String?
    /// True when `finalText` was cut at `finalTextByteCap`.
    public var finalTextTruncated: Bool?
    public var endedAt: Date?
    /// `.plans/102` P2a: the `array_report` the child filed during the turn
    /// this result settles. Absent (and not encoded) when it filed none, so a
    /// courier without a report is the same file as before.
    public var report: AgentReport?

    public init(
        schema: Int = SpawnResultFile.currentSchema,
        toolCallId: String,
        status: Status,
        agentId: UUID? = nil,
        role: String? = nil,
        reason: String? = nil,
        finalText: String? = nil,
        finalTextTruncated: Bool? = nil,
        endedAt: Date? = nil,
        report: AgentReport? = nil,
        turnIdentity: String? = nil,
        recipientId: UUID? = nil,
        deliveredVia: String? = nil,
        deliveryReceipt: String? = nil
    ) {
        self.turnIdentity = turnIdentity
        self.recipientId = recipientId
        self.deliveredVia = deliveredVia
        self.deliveryReceipt = deliveryReceipt
        self.schema = schema
        self.toolCallId = toolCallId
        self.status = status
        self.agentId = agentId
        self.role = role
        self.reason = reason
        self.finalText = finalText
        self.finalTextTruncated = finalTextTruncated
        self.endedAt = endedAt
        self.report = report
    }

    /// `<parent cwd>/.array/spawn-results` — the directory the extension polls.
    public static func directory(parentCwd: String) -> URL {
        URL(fileURLWithPath: parentCwd, isDirectory: true)
            .appendingPathComponent(".array", isDirectory: true)
            .appendingPathComponent("spawn-results", isDirectory: true)
    }

    /// The handle becomes a path component, so it is validated as one — the
    /// same rule `ObservedRunHandle.validated` applies to pi's runId. nil means
    /// "do not write a file for this call".
    public static func validatedHandle(_ toolCallId: String?) -> String? {
        guard let trimmed = toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 256,
              !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains("\\"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    public static func url(parentCwd: String, handle: String) -> URL {
        directory(parentCwd: parentCwd).appendingPathComponent("\(handle).json", isDirectory: false)
    }

    /// Cap model-bound text at `finalTextByteCap` UTF-8 bytes on a character
    /// boundary. Returns the kept text and whether anything was cut.
    public static func cappedFinalText(_ text: String) -> (text: String, truncated: Bool) {
        guard text.utf8.count > finalTextByteCap else { return (text, false) }
        var kept = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > finalTextByteCap { break }
            kept.append(character)
            bytes += size
        }
        return (kept, true)
    }

    /// The courier as last written, or nil when there is none (or it is
    /// unreadable). `operation.get` reads it for a delegated child's answer.
    public static func read(parentCwd: String, handle: String) -> SpawnResultFile? {
        guard let handle = validatedHandle(handle),
              let data = try? Data(contentsOf: url(parentCwd: parentCwd, handle: handle)) else { return nil }
        return try? JSONCodec.makeDecoder().decode(SpawnResultFile.self, from: data)
    }

    public struct Delivery: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable { case available, offered, stagingWake, delivered }
        public var phase: Phase = .available
        public var helper: UUID
        public var turn: String
        public var recipient: UUID
        public var receipt = UUID().uuidString
        public var requestId: String?
        public var leaseUntil: Date?
        public var wakeID: UUID?
        public var text: String?
        public var capturedReport: Bool?
        public var result: SpawnResultFile?
        public var dueAt: Date
        public var completedAt: Date
        public var via: String?
        public init(helper: UUID, turn: String, recipient: UUID, wakeID: UUID? = nil, text: String? = nil, now: Date) {
            self.helper = helper; self.turn = turn; self.recipient = recipient
            self.wakeID = wakeID; self.text = text; self.dueAt = now.addingTimeInterval(8); self.completedAt = now
        }
    }
    public static func deliveryURL(parentCwd: String, helper: UUID, turn: String, recipient: UUID) -> URL? {
        guard validatedHandle(turn) != nil else { return nil }
        return directory(parentCwd: parentCwd).appendingPathComponent(".deliveries", isDirectory: true)
            .appendingPathComponent("\(helper.uuidString)-\(turn)-\(recipient.uuidString).json")
    }
    public static func delivery(parentCwd: String, helper: UUID, turn: String, recipient: UUID) throws -> Delivery? {
        guard let url = deliveryURL(parentCwd: parentCwd, helper: helper, turn: turn, recipient: recipient) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        do { return try JSONCodec.makeDecoder().decode(Delivery.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    public static func saveDelivery(_ delivery: Delivery, parentCwd: String) throws {
        guard let url = deliveryURL(parentCwd: parentCwd, helper: delivery.helper, turn: delivery.turn, recipient: delivery.recipient) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try AtomicWriter(retainedBackups: 0).write(delivery, to: url)
    }
    public static func deliveries(parentCwd: String, recipient: UUID) throws -> [Delivery] {
        let dir = directory(parentCwd: parentCwd).appendingPathComponent(".deliveries")
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try urls.filter { $0.pathExtension == "json" }.map {
            try JSONCodec.makeDecoder().decode(Delivery.self, from: Data(contentsOf: $0))
        }.filter { $0.recipient == recipient }
    }
    public static func markDelivered(_ delivery: Delivery, parentCwd: String) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(parentCwd: parentCwd), includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard var file = read(parentCwd: parentCwd, handle: url.deletingPathExtension().lastPathComponent),
                  file.agentId == delivery.helper, file.turnIdentity == delivery.turn, file.recipientId == delivery.recipient else { continue }
            file.deliveredVia = delivery.via; file.deliveryReceipt = delivery.receipt
            write(file, parentCwd: parentCwd)
        }
    }
    public func compactDeliveryResult(_ delivery: Delivery, pending: Bool = false) -> SpawnResultFile {
        var result = self
        result.status = pending ? .deliveryPending : .alreadyDelivered
        result.finalText = nil; result.finalTextTruncated = nil; result.report = nil
        result.deliveryReceipt = delivery.receipt
        result.reason = pending
            ? "Helper delivery pending; retry after its bounded collection lease."
            : "Helper turn already delivered; see the earlier helper update or collected result. To recover a lost response, repeat operation.get with deliveryReceipt \(delivery.receipt)."
        return result
    }
    /// Host-only: caller identity comes from the authenticated HTTP/stdio bridge,
    /// never from a courier or extension environment variable. Actor-serialized.
    public static func collect(parentCwd: String, handle: String, recipient: UUID, requestId: String,
                               receipt: String? = nil, acknowledge: Bool = false, now: Date = Date(),
                               snapshot: SpawnResultFile? = nil) throws -> SpawnResultFile? {
        let saved = try deliveries(parentCwd: parentCwd, recipient: recipient).first {
            $0.result?.toolCallId == handle && ((receipt != nil && $0.receipt == receipt) || $0.requestId == requestId)
        }
        let file: SpawnResultFile
        if let savedSnapshot = saved?.result { file = savedSnapshot }
        else if let snapshot { file = snapshot }
        else {
            guard let handle = validatedHandle(handle) else { throw CocoaError(.fileReadInvalidFileName) }
            do { file = try JSONCodec.makeDecoder().decode(SpawnResultFile.self, from: Data(contentsOf: url(parentCwd: parentCwd, handle: handle))) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
        guard file.recipientId == recipient else { throw CocoaError(.fileReadNoPermission) }
        guard file.status != .spawned, let helper = file.agentId, let turn = file.turnIdentity else { return file }
        var state = try saved ?? delivery(parentCwd: parentCwd, helper: helper, turn: turn, recipient: recipient)
            ?? Delivery(helper: helper, turn: turn, recipient: recipient, now: now)
        if acknowledge {
            guard receipt == state.receipt, state.phase == .offered || state.phase == .delivered else {
                throw CocoaError(.fileReadCorruptFile)
            }
            state.phase = .delivered; state.via = state.via ?? "collection"; state.leaseUntil = nil
            try saveDelivery(state, parentCwd: parentCwd)
            markDelivered(state, parentCwd: parentCwd)
            return file.compactDeliveryResult(state)
        }
        if state.phase == .stagingWake { return file.compactDeliveryResult(state, pending: true) }
        if state.phase == .delivered {
            if receipt == state.receipt || state.requestId == requestId {
                var replay = file; replay.deliveryReceipt = state.receipt; return replay
            }
            return file.compactDeliveryResult(state)
        }
        if state.phase == .offered, (state.leaseUntil ?? .distantPast) > now {
            if state.requestId == requestId || receipt == state.receipt {
                var replay = file; replay.deliveryReceipt = state.receipt; return replay
            }
            return file.compactDeliveryResult(state, pending: true)
        }
        state.phase = .offered; state.requestId = requestId; state.receipt = UUID().uuidString
        state.result = file
        state.leaseUntil = now.addingTimeInterval(30)
        try saveDelivery(state, parentCwd: parentCwd)
        var offered = file; offered.deliveryReceipt = state.receipt
        return offered
    }

    /// Atomic write via the records' own idiom (no backups: one file per call,
    /// last status wins). Failures are reported, not thrown — a result file is
    /// best-effort courier state and must never fail a spawn.
    @discardableResult
    public static func write(
        _ result: SpawnResultFile,
        parentCwd: String,
        warn: (String) -> Void = { _ in }
    ) -> Bool {
        guard let handle = validatedHandle(result.toolCallId) else { return false }
        var result = result
        if let helper = result.agentId, let turn = result.turnIdentity, let recipient = result.recipientId {
            do {
                if var state = try delivery(parentCwd: parentCwd, helper: helper, turn: turn, recipient: recipient) {
                    if state.phase == .available { state.result = result; try saveDelivery(state, parentCwd: parentCwd) }
                    if state.phase == .delivered { result.deliveredVia = state.via; result.deliveryReceipt = state.receipt }
                }
            } catch { warn("Helper courier journal unavailable; result remains retryable") }
        }
        do {
            try AtomicWriter(retainedBackups: 0).write(result, to: url(parentCwd: parentCwd, handle: handle))
            return true
        } catch {
            warn("SpawnResultFile: could not write \(result.status.rawValue) for \(handle): \(error)")
            return false
        }
    }
}
