import Darwin
import Foundation

public enum CompanionTaskRunState: String, Codable, Sendable {
    case running, queued, unknown, needsInput, needsApproval, succeeded, failed, cancelled, interrupted
    public var terminal: Bool { [.succeeded, .failed, .cancelled, .interrupted].contains(self) }
}

public struct CompanionTaskRunHandle: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var runID: UUID
}

public struct CompanionTaskSnapshot: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public var agentID: UUID
        public var runID: UUID
        public var parentRunID: UUID?
        public var state: CompanionTaskRunState
        public var requestID: String?
    }
    public var taskID: UUID
    public var rootRunID: UUID
    public var membershipComplete: Bool
    public var members: [Member]
}

public struct CompanionTaskSnapshotBatch: Codable, Equatable, Sendable {
    public var publisherID: UUID
    public var revision: UInt64
    public var tasks: [CompanionTaskSnapshot]
}

public enum CompanionTaskLedgerError: Error { case invalidRun, invalidRequest, unsupportedVersion, revisionExhausted, capacityExceeded }

/// What an agent's explicit "I need you" (`agent.notify`) did to its run.
public enum CompanionAttentionOutcome: String, Sendable {
    /// The run now needs input under this request id.
    case recorded
    /// This exact request is already held.
    case alreadyRecorded
    /// The run already holds a different request; one alert per run.
    case coalesced
    /// The run has settled, so there is nothing left to hold.
    case notRunning
}

/// Host-local metadata only. Caller must explicitly supply user/delegation/queue
/// provenance; an agent's lifetime parent is never consulted. Commit precedes
/// mutation of in-memory truth. Streaming content never enters this store.
///
/// A change commits as one appended, fsynced line in `ledger.journal` holding
/// only the tasks, runs and pointers it touched; `ledger.json` is rewritten at
/// launch and once the journal passes `compactionThreshold`. Every change used
/// to rewrite the whole file on the main thread (encode, write, decode-verify),
/// and the ledger only grows: 4.5 MB in Dylan's app by 2026-11-11, rewritten
/// on every turn start and finish.
public final class CompanionTaskLedger: @unchecked Sendable {
    private struct Task: Codable, Equatable {
        var root: UUID
        var complete: Bool
        var createdRevision: UInt64 = 0
        var admissions: Set<UUID> = []
        var unknownBackground: Set<UUID> = []
        var unknownProviderRuns: Set<UUID> = []
        /// When this task or any of its runs last changed, in seconds since 1970.
        /// A number, not a Date: AtomicWriter writes ISO-8601 dates that this
        /// ledger's decoder (and every older build's) cannot read. Nil only in
        /// ledgers written before it existed; load stamps those with load time.
        var touchedAt: Double?
    }
    private struct Run: Codable, Equatable {
        var task: UUID
        var member: CompanionTaskSnapshot.Member
        var providerTurn: String?
        var pendingRequests: [String: CompanionTaskRunState] = [:]
        var observed: Bool = false
        var queued: Bool = false
        var appliedToParent: Bool = false
        // Optional so ledgers written before `agent.notify` still decode.
        /// The run's own `agent.notify` request. Unlike a provider request it
        /// outlives the turn.
        var heldAttention: String?
        /// The turn ended while holding attention: the run waits as needsInput
        /// until the agent's next accepted turn, which answers it.
        var awaitingAnswer: Bool?
    }
    private struct File: Codable, Equatable {
        var version = 1
        var publisherID = UUID()
        var revision: UInt64 = 0
        var tasks: [UUID: Task] = [:]
        var runs: [UUID: Run] = [:]
        var current: [UUID: UUID] = [:]
        var observations: [String: UUID] = [:]
    }
    /// One committed change: the new value of every key it touched, and the keys
    /// it removed. Absolute values, so replay never depends on a skipped line.
    private struct Delta: Codable {
        var revision: UInt64
        var publisherID: UUID
        var tasks: [UUID: Task] = [:]
        var removedTasks: [UUID] = []
        var runs: [UUID: Run] = [:]
        var removedRuns: [UUID] = []
        var current: [UUID: UUID] = [:]
        var removedCurrent: [UUID] = []
        var observations: [String: UUID] = [:]
        var removedObservations: [String] = []

        init(from old: File, to new: File) {
            revision = new.revision
            publisherID = new.publisherID
            (tasks, removedTasks) = Self.diff(old.tasks, new.tasks)
            (runs, removedRuns) = Self.diff(old.runs, new.runs)
            (current, removedCurrent) = Self.diff(old.current, new.current)
            (observations, removedObservations) = Self.diff(old.observations, new.observations)
        }

        private static func diff<K: Hashable, V: Equatable>(_ old: [K: V], _ new: [K: V]) -> ([K: V], [K]) {
            (new.filter { old[$0.key] != $0.value }, old.keys.filter { new[$0] == nil })
        }

        func apply(to file: inout File) {
            file.revision = revision
            for key in removedTasks { file.tasks.removeValue(forKey: key) }
            file.tasks.merge(tasks) { $1 }
            for key in removedRuns { file.runs.removeValue(forKey: key) }
            file.runs.merge(runs) { $1 }
            for key in removedCurrent { file.current.removeValue(forKey: key) }
            file.current.merge(current) { $1 }
            for key in removedObservations { file.observations.removeValue(forKey: key) }
            file.observations.merge(observations) { $1 }
        }
    }
    /// Journal bytes that trigger a full rewrite of `ledger.json`. A turn's
    /// change is about 1 KB, so this is hundreds of changes per rewrite.
    public static let compactionThreshold = 512 * 1024
    private let lock = NSLock()
    private let url: URL
    private let journalURL: URL
    private var journalBytes = 0
    private let writer: AtomicWriter
    private var file: File
    private let clock: @Sendable () -> Date
    /// A task with no live run leaves the published batch this long after its
    /// last change. Far longer than the relay's one-hour alert lifetime, so a
    /// task never leaves while an alert for it can still be pending.
    public static let quietTaskWindow: TimeInterval = 24 * 3600

    public init(applicationSupportDirectory: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.clock = clock
        let directory = applicationSupportDirectory.appendingPathComponent("companion-tasks", isDirectory: true)
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("ledger.json")
        journalURL = directory.appendingPathComponent("ledger.journal")
        writer = AtomicWriter(backupsDirectory: backups, retainedBackups: 3)
        let hasBackups = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).isEmpty == false
        if FileManager.default.fileExists(atPath: url.path) || hasBackups {
            file = try writer.read(at: url, decoder: JSONDecoder())
            guard file.version == 1 else { throw CompanionTaskLedgerError.unsupportedVersion }
            Self.replayJournal(at: journalURL, onto: &file)
            // The base does not hold the last session's journal yet. Fold it in
            // before this launch writes anything, so no failed startup write can
            // trim a committed line; if this throws, the journal is untouched.
            journalBytes = ((try? FileManager.default.attributesOfItem(atPath: journalURL.path)[.size]) as? Int) ?? 0
            if journalBytes > 0 { try compact(file) }
        } else {
            file = File()
            try? FileManager.default.removeItem(at: journalURL)
            try writer.write(file, to: url)
        }
        // A persisted running/queued/attention fact is not a live observation.
        // Restart can never turn lost work into successful completion.
        try change { next in
            // A run waiting on a person finished its turn; that wait is a settled
            // fact, not lost work, so it survives a restart as it was.
            for id in Array(next.runs.keys) where !next.runs[id]!.member.state.terminal && next.runs[id]!.awaitingAnswer != true {
                next.runs[id]!.member.state = .unknown
                next.tasks[next.runs[id]!.task]!.complete = false
            }
        }
        // Tasks from before `touchedAt` count from now, so none leaves the
        // batch sooner than a full window after this upgrade.
        let now = clock().timeIntervalSince1970
        try change(touching: false) { next in
            for id in Array(next.tasks.keys) where next.tasks[id]!.touchedAt == nil { next.tasks[id]!.touchedAt = now }
        }
    }

    /// Lines whose revision is past the base, in order. An unreadable line is a
    /// change that never committed (a torn append, or one whose fsync failed and
    /// threw), so it is skipped; a line from another publisher is never applied.
    private static func replayJournal(at url: URL, onto file: inout File) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let delta = try? decoder.decode(Delta.self, from: Data(line)),
                  delta.publisherID == file.publisherID, delta.revision > file.revision else { continue }
            delta.apply(to: &file)
        }
    }

    /// Commit point for one change: the line is on stable storage. A failed
    /// append trims the journal back so a torn line cannot precede the next one.
    /// It trims to the length the file had before this write, never to a count
    /// kept in memory: a count that disagrees with the file would cut committed
    /// lines, or pad with zeros that swallow the next one. Each line also starts
    /// on a fresh line, so a tail whose trim failed is skipped on its own instead
    /// of gluing itself to the next committed change.
    private func append(_ delta: Delta) throws {
        var data = Data([UInt8(ascii: "\n")])
        data.append(try JSONEncoder().encode(delta))
        data.append(UInt8(ascii: "\n"))
        let fd = Darwin.open(journalURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var status = stat()
        guard Darwin.fstat(fd, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let committed = status.st_size
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, Darwin.fsync(fd) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            _ = Darwin.ftruncate(fd, committed)
            throw POSIXError(code)
        }
        journalBytes = Int(committed) + data.count
    }

    /// The base takes every change; only then is the journal emptied. A journal
    /// that fails to empty is harmless: its lines are at or below the base's
    /// revision, so replay skips them.
    private func compact(_ next: File) throws {
        try writer.write(next, to: url)
        let fd = Darwin.open(journalURL.path, O_WRONLY | O_TRUNC | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        if Darwin.fsync(fd) == 0 { journalBytes = 0 }
        Darwin.close(fd)
    }

    @discardableResult
    private func change<T>(touching: Bool = true, _ body: (inout File) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var next = file
        let result = try body(&next)
        if next != file {
            if touching { Self.stamp(&next, against: file, at: clock().timeIntervalSince1970) }
            guard file.revision < UInt64.max else { throw CompanionTaskLedgerError.revisionExhausted }
            next.revision = max(next.revision, file.revision + 1)
            if journalBytes >= Self.compactionThreshold {
                try compact(next)
            } else {
                try append(Delta(from: file, to: next))
            }
            file = next
        }
        return result
    }

    /// Stamps every task whose own record or any of whose runs changed.
    private static func stamp(_ next: inout File, against old: File, at now: Double) {
        var touched = Set<UUID>()
        for (id, task) in next.tasks where old.tasks[id] != task { touched.insert(id) }
        for (id, run) in next.runs where old.runs[id] != run { touched.insert(run.task) }
        for (id, run) in old.runs where next.runs[id] == nil { touched.insert(run.task) }
        for id in touched where next.tasks[id] != nil { next.tasks[id]!.touchedAt = now }
    }

    public func currentRun(agentID: UUID) -> CompanionTaskRunHandle? {
        lock.lock(); defer { lock.unlock() }
        guard let id = file.current[agentID], let run = file.runs[id] else { return nil }
        return .init(taskID: run.task, runID: id)
    }
    public var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return file.revision }

    public func reserveQueued(agentID: UUID, itemID: UUID, newTask: Bool = false) throws -> CompanionTaskRunHandle {
        try change { next in
            if let existing = next.runs[itemID] { return .init(taskID: existing.task, runID: itemID) }
            // Work sent to an agent that is waiting on a person answers it, so it
            // continues that task instead of opening a new one.
            let waiting = Self.awaitingRun(agentID: agentID, in: next)
            let parentID = waiting ?? next.current[agentID]
            let parent = parentID.flatMap { next.runs[$0] }
            let continuing = waiting != nil
                || (!newTask && (parent.map { p in next.runs.values.contains { $0.task == p.task && !$0.member.state.terminal } } ?? false))
            let taskID = continuing ? parent!.task : UUID()
            if !continuing { next.tasks[taskID] = .init(root: itemID, complete: true, createdRevision: next.revision) }
            next.tasks[taskID]!.admissions.insert(itemID)
            next.runs[itemID] = .init(task: taskID, member: .init(agentID: agentID, runID: itemID,
                parentRunID: continuing ? parentID : nil, state: .queued), queued: true)
            return .init(taskID: taskID, runID: itemID)
        }
    }

    public func resolveQueuedReservation(_ handle: CompanionTaskRunHandle, accepted: Bool) throws {
        try change { next in
            guard next.tasks[handle.taskID]?.admissions.remove(handle.runID) != nil else { return }
            if !accepted {
                next.runs.removeValue(forKey: handle.runID)
                if next.tasks[handle.taskID]?.root == handle.runID { next.tasks.removeValue(forKey: handle.taskID) }
            }
        }
    }

    public func reconcileQueued(agentID: UUID, itemIDs: [UUID]) throws {
        try change { next in
            for id in itemIDs {
                if next.runs[id] != nil {
                    if next.runs[id]!.queued { next.runs[id]!.member.state = .queued }
                } else {
                    let task = UUID()
                    next.tasks[task] = .init(root: id, complete: false, createdRevision: next.revision)
                    next.runs[id] = .init(task: task, member: .init(agentID: agentID, runID: id, parentRunID: nil, state: .queued), queued: true)
                    if let current = next.current[agentID], let run = next.runs[current] { next.tasks[run.task]!.complete = false }
                }
            }
        }
    }

    public func applyQueuedToParent(_ itemID: UUID) throws {
        try change { next in
            guard next.runs[itemID]?.queued == true else { return }
            next.runs[itemID]!.queued = false; next.runs[itemID]!.appliedToParent = true
            next.runs[itemID]!.member.state = .running
            if let parent = next.runs[itemID]!.member.parentRunID, let state = next.runs[parent]?.member.state, state.terminal {
                // A receipt after the parent result may belong to a promoted
                // provider turn. Consumption alone cannot prove its completion.
                next.runs[itemID]!.member.state = .unknown
                next.tasks[next.runs[itemID]!.task]!.complete = false
            }
        }
    }

    public func settleHostWork(_ itemID: UUID, state: CompanionTaskRunState) throws {
        try change { next in
            guard state.terminal || state == .unknown else { return }
            next.runs[itemID]?.member.state = state
            if state == .unknown, let task = next.runs[itemID]?.task { next.tasks[task]?.complete = false }
        }
    }

    public func beginHostWork(_ itemID: UUID) throws {
        try change { next in next.runs[itemID]?.queued = false; next.runs[itemID]?.member.state = .running }
    }

    public func begin(agentID: UUID, parent: CompanionTaskRunHandle? = nil, queuedID: UUID? = nil) throws -> CompanionTaskRunHandle {
        try begin(agentID: agentID, parent: parent, queuedID: queuedID, answers: true)
    }

    /// `answers`: an accepted turn answers a waiting run. Unsolicited provider
    /// work does not; the person still has to.
    private func begin(agentID: UUID, parent: CompanionTaskRunHandle?, queuedID: UUID?, answers: Bool) throws -> CompanionTaskRunHandle {
        try change { next in
            if let queuedID, let run = next.runs[queuedID], run.member.agentID == agentID {
                if answers { Self.answerAwaiting(agentID: agentID, in: &next) }
                next.runs[queuedID]!.member.state = .running
                next.runs[queuedID]!.queued = false
                next.runs[queuedID]!.appliedToParent = false
                next.tasks[run.task]?.admissions.remove(queuedID)
                next.current[agentID] = queuedID
                return .init(taskID: run.task, runID: queuedID)
            }
            let answered = answers ? Self.answerAwaiting(agentID: agentID, in: &next) : nil
            let parent = parent ?? answered
            let runID = UUID(), taskID = parent?.taskID ?? UUID()
            if let parent {
                guard next.runs[parent.runID]?.task == parent.taskID else { throw CompanionTaskLedgerError.invalidRun }
            } else { next.tasks[taskID] = .init(root: runID, complete: true, createdRevision: next.revision) }
            next.runs[runID] = .init(task: taskID, member: .init(agentID: agentID, runID: runID, parentRunID: parent?.runID, state: .running))
            next.current[agentID] = runID
            return .init(taskID: taskID, runID: runID)
        }
    }

    /// Unsolicited/provider-owned work with no accepted user origin remains
    /// explicitly unknown. It may surface an actionable request, never completion.
    public func ensureUnknown(agentID: UUID) throws -> CompanionTaskRunHandle {
        if let current = currentRun(agentID: agentID) { return current }
        return try beginUnknown(agentID: agentID)
    }

    public func beginUnknown(agentID: UUID) throws -> CompanionTaskRunHandle {
        let handle = try begin(agentID: agentID, parent: nil, queuedID: nil, answers: false)
        try change { next in next.tasks[handle.taskID]!.complete = false; next.runs[handle.runID]!.member.state = .unknown }
        return handle
    }

    public func adoptObserved(agentID: UUID, parent: CompanionTaskRunHandle, sourceID: String) throws -> CompanionTaskRunHandle {
        try change { next in
            if let id = next.observations[sourceID], let run = next.runs[id] { return .init(taskID: run.task, runID: id) }
            guard next.runs[parent.runID]?.task == parent.taskID else { throw CompanionTaskLedgerError.invalidRun }
            let id = UUID()
            next.runs[id] = .init(task: parent.taskID, member: .init(agentID: agentID, runID: id, parentRunID: parent.runID, state: .running), observed: true)
            next.observations[sourceID] = id; next.current[agentID] = id
            return .init(taskID: parent.taskID, runID: id)
        }
    }

    /// The admission barrier is committed before an attachment/store await.
    public func reserveAdmission(parent: CompanionTaskRunHandle) throws -> UUID {
        try change { next in
            guard next.runs[parent.runID]?.task == parent.taskID else { throw CompanionTaskLedgerError.invalidRun }
            let id = UUID(); next.tasks[parent.taskID]!.admissions.insert(id); return id
        }
    }

    public func finishAdmission(_ admission: UUID, parent: CompanionTaskRunHandle, agentID: UUID, queuedID: UUID?) throws {
        try change { next in
            guard next.tasks[parent.taskID]?.admissions.remove(admission) != nil else { throw CompanionTaskLedgerError.invalidRun }
            if let queuedID {
                next.runs[queuedID] = .init(task: parent.taskID, member: .init(agentID: agentID, runID: queuedID, parentRunID: parent.runID, state: .queued))
            }
        }
    }

    public func cancelQueued(_ queuedID: UUID) throws {
        try change { next in
            guard next.runs[queuedID]?.member.state == .queued || next.runs[queuedID]?.member.state == .unknown else { return }
            next.runs[queuedID]?.member.state = .cancelled
        }
    }

    /// The supervisor passes the run bound to its validated runner generation.
    /// Provider turn IDs additionally fence delayed frames within a reused CLI.
    public func observe(_ event: AgentRuntimeEvent, run: CompanionTaskRunHandle, allowSyntheticTerminal: Bool = false) throws {
        try change { next in
            guard var stored = next.runs[run.runID], stored.task == run.taskID else { throw CompanionTaskLedgerError.invalidRun }
            guard !stored.member.state.terminal, stored.awaitingAnswer != true else { return }
            var reconcileRequests = false
            switch event {
            case .turnStarted(_, let turn):
                if stored.providerTurn == nil { stored.providerTurn = turn; reconcileRequests = true }
                else if stored.providerTurn != turn { return }
            case .turnCompleted(_, let turn, let outcome, _):
                if !stored.observed, !allowSyntheticTerminal, let known = stored.providerTurn, known != turn { return }
                if outcome == .completed, !stored.observed, stored.providerTurn == nil {
                    stored.member.state = .unknown; next.tasks[run.taskID]!.complete = false
                } else if outcome == .completed, let held = stored.heldAttention {
                    // The agent asked for a person and its turn ended: it now
                    // waits, so neither success nor completion is claimed yet.
                    stored.pendingRequests = [held: .needsInput]
                    stored.member.state = .needsInput; stored.member.requestID = held
                    stored.awaitingAnswer = true
                } else {
                    stored.heldAttention = nil
                    switch outcome {
                    case .completed: stored.member.state = .succeeded
                    case .failed: stored.member.state = .failed
                    case .cancelled: stored.member.state = .cancelled
                    case .interrupted: stored.member.state = .interrupted
                    }
                    stored.member.requestID = nil
                }
            case .requestOpened(_, let id, let kind):
                stored.pendingRequests[id] = kind == .toolUserInput ? .needsInput : .needsApproval; reconcileRequests = true
            case .userInputRequested(_, let id, _):
                stored.pendingRequests[id] = .needsInput; reconcileRequests = true
            case .requestResolved(_, let id, _), .userInputResolved(_, let id):
                stored.pendingRequests.removeValue(forKey: id); reconcileRequests = true
            case .sessionStateChanged(.stopped):
                stored.member.state = .interrupted; stored.member.requestID = nil; stored.heldAttention = nil
            case .runtimeError, .sessionStateChanged(.error): stored.member.state = .unknown
            default: return
            }
            if reconcileRequests { Self.reconcileRequests(&stored) }
            if let request = stored.member.requestID,
               request.isEmpty || request.utf8.count > 200 || request.contains("/") || request.contains("\\") || request.contains(where: { $0.isNewline }) {
                stored.member.requestID = nil; stored.member.state = .unknown; next.tasks[run.taskID]!.complete = false
            }
            next.runs[run.runID] = stored
            if stored.member.state.terminal {
                for id in next.runs.keys where next.runs[id]!.member.parentRunID == run.runID && next.runs[id]!.appliedToParent {
                    next.runs[id]!.member.state = stored.member.state
                }
            }
        }
    }

    /// An agent's explicit "I need you" (`agent.notify`). It enters the same
    /// request path as a provider's own question, so the relay's task policy
    /// decides the alert; one held request per run, so a run cannot re-alert.
    public func holdAttention(_ run: CompanionTaskRunHandle, requestID: String) throws -> CompanionAttentionOutcome {
        guard Self.isValidRequestID(requestID) else { throw CompanionTaskLedgerError.invalidRequest }
        return try change { next in
            guard var stored = next.runs[run.runID], stored.task == run.taskID else { throw CompanionTaskLedgerError.invalidRun }
            if stored.heldAttention == requestID { return .alreadyRecorded }
            if stored.heldAttention != nil { return .coalesced }
            guard !stored.member.state.terminal, stored.awaitingAnswer != true else { return .notRunning }
            stored.heldAttention = requestID
            stored.pendingRequests[requestID] = .needsInput
            Self.reconcileRequests(&stored)
            next.runs[run.runID] = stored
            return .recorded
        }
    }

    /// The agent withdraws its own request before its turn ends. A run already
    /// waiting on a person is answered only by its next turn.
    @discardableResult
    public func releaseAttention(_ run: CompanionTaskRunHandle) throws -> Bool {
        try change { next in
            guard var stored = next.runs[run.runID], stored.task == run.taskID else { throw CompanionTaskLedgerError.invalidRun }
            guard let held = stored.heldAttention, stored.awaitingAnswer != true, !stored.member.state.terminal else { return false }
            stored.heldAttention = nil
            stored.pendingRequests.removeValue(forKey: held)
            Self.reconcileRequests(&stored)
            next.runs[run.runID] = stored
            return true
        }
    }

    private static func reconcileRequests(_ stored: inout Run) {
        let ordered = stored.pendingRequests.keys.sorted()
        let selected = ordered.first { stored.pendingRequests[$0] == .needsApproval } ?? ordered.first
        stored.member.requestID = selected
        stored.member.state = selected.flatMap { stored.pendingRequests[$0] } ?? .running
    }

    private static func isValidRequestID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && !id.contains("/") && !id.contains("\\") && !id.contains(where: { $0.isNewline })
    }

    private static func awaitingRun(agentID: UUID, in file: File) -> UUID? {
        file.runs.first { $0.value.member.agentID == agentID && $0.value.awaitingAnswer == true }?.key
    }

    /// The waiting run got its answer: its turn had succeeded, and the task
    /// carries on in the turn that answered it.
    @discardableResult
    private static func answerAwaiting(agentID: UUID, in next: inout File) -> CompanionTaskRunHandle? {
        guard let id = awaitingRun(agentID: agentID, in: next), var run = next.runs[id] else { return nil }
        run.awaitingAnswer = nil; run.heldAttention = nil; run.pendingRequests = [:]
        run.member.state = .succeeded; run.member.requestID = nil
        next.runs[id] = run
        for child in next.runs.keys where next.runs[child]!.member.parentRunID == id && next.runs[child]!.appliedToParent {
            next.runs[child]!.member.state = .succeeded
        }
        return .init(taskID: run.task, runID: id)
    }

    public func markIncomplete(_ run: CompanionTaskRunHandle) throws {
        try change { next in next.tasks[run.taskID]?.complete = false }
    }

    public func setBackgroundUnknown(_ run: CompanionTaskRunHandle, unknown: Bool) throws {
        try change { next in
            if unknown { next.tasks[run.taskID]?.unknownBackground.insert(run.runID) }
            else { next.tasks[run.taskID]?.unknownBackground.remove(run.runID) }
        }
    }

    public func setProviderMembershipUnknown(_ run: CompanionTaskRunHandle, unknown: Bool) throws {
        try change { next in
            if unknown { next.tasks[run.taskID]?.unknownProviderRuns.insert(run.runID) }
            else { next.tasks[run.taskID]?.unknownProviderRuns.remove(run.runID) }
        }
    }

    public func snapshot(revisionFloor: UInt64 = 0) throws -> CompanionTaskSnapshotBatch {
        // A restored backup marks every task incomplete. That is not activity:
        // it must not pull every old task back onto the wire.
        try change(touching: false) { next in
            if revisionFloor > next.revision {
                guard revisionFloor < UInt64.max else { throw CompanionTaskLedgerError.revisionExhausted }
                next.revision = revisionFloor + 1
                // A restored backup cannot prove what happened after its write.
                for id in next.tasks.keys { next.tasks[id]!.complete = false }
            }
        }
        lock.lock(); defer { lock.unlock() }
        // Never truncate live/unknown membership to make a payload fit. A host
        // that exhausts the bounded wire contract withholds publication instead.
        let runsByTask = Dictionary(grouping: file.runs.values, by: \.task)
        let unsettled = Set(file.tasks.keys.filter { id in
            let task = file.tasks[id]!
            return !task.complete || !task.admissions.isEmpty || !task.unknownBackground.isEmpty || !task.unknownProviderRuns.isEmpty
                || (runsByTask[id] ?? []).contains { !$0.member.state.terminal }
        })
        // Live work always rides: a run working, queued or waiting on a person,
        // or an admission in flight. Everything else (unknown, incomplete or
        // settled) rides for `quietTaskWindow` after its last change, then
        // leaves the wire but stays in the ledger; any change brings it back.
        // Without this, every restart's unknown tasks stayed on the wire for
        // ever and the batch grew towards the 512-task cap.
        let live = Set(file.tasks.keys.filter { id in
            !file.tasks[id]!.admissions.isEmpty || (runsByTask[id] ?? []).contains {
                [.running, .queued, .needsInput, .needsApproval].contains($0.member.state)
            }
        })
        let cutoff = clock().timeIntervalSince1970 - Self.quietTaskWindow
        let taskTable = file.tasks
        let recent = { (id: UUID) in (taskTable[id]!.touchedAt ?? 0) > cutoff }
        // Retain local provenance/tombstones, but bound settled wire history.
        // Unknown/live tasks are never evicted to make room for recent history.
        let history = file.tasks.keys.filter { !unsettled.contains($0) && recent($0) }.sorted {
            let lhs = file.tasks[$0]!.createdRevision, rhs = file.tasks[$1]!.createdRevision
            return lhs == rhs ? $0.uuidString < $1.uuidString : lhs > rhs
        }
        let selected = live.union(unsettled.filter(recent)).union(history.prefix(128))
        guard selected.count <= 512, selected.reduce(0, { $0 + (runsByTask[$1]?.count ?? 0) }) <= 4096,
              selected.allSatisfy({ (runsByTask[$0]?.count ?? 0) <= 1000 }) else { throw CompanionTaskLedgerError.capacityExceeded }
        let tasks = selected.sorted { $0.uuidString < $1.uuidString }.map { id in
            let task = file.tasks[id]!
            let members = (runsByTask[id] ?? []).map(\.member).sorted { $0.runID.uuidString < $1.runID.uuidString }
            return CompanionTaskSnapshot(taskID: id, rootRunID: task.root, membershipComplete: task.complete && task.admissions.isEmpty && task.unknownBackground.isEmpty && task.unknownProviderRuns.isEmpty,
                                         members: members)
        }
        return .init(publisherID: file.publisherID, revision: file.revision, tasks: tasks)
    }
}
