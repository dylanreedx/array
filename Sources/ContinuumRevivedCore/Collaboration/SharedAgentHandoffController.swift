import Foundation
import GRDB
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

public struct SharedAgentPendingIntent: Codable, Equatable, Sendable {
    public enum Action: Codable, Equatable, Sendable {
        case control(Collaboration.AgentControlMutation)
        case prompt(Collaboration.AgentPromptRequest)
    }
    public let object: SharedArea.ID<SharedArea.Object>
    public let action: Action
    public var id: UUID { switch action { case .control(let value): value.id; case .prompt(let value): value.id } }
    public init(object: SharedArea.ID<SharedArea.Object>, action: Action) { self.object = object; self.action = action }
}
public struct SharedAgentHandoffDraft: Codable, Equatable, Sendable {
    public var recipient: String
    public var text: String
    public var context: SharedArea.ID<SharedArea.Revision>?
    public var mode: Collaboration.AgentPromptMode
    public init(recipient: String = "", text: String = "", context: SharedArea.ID<SharedArea.Revision>? = nil,
                mode: Collaboration.AgentPromptMode = .send) {
        self.recipient = recipient; self.text = text; self.context = context; self.mode = mode
    }
}
public enum SharedAgentHandoffError: Error, LocalizedError {
    case unavailable, busy, pendingDelivery, invalidRecipient, noContext, sourceChanged
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Reconnect the shared workspace and its source host."
        case .busy: return "A handoff action is already running."
        case .pendingDelivery: return "Check delivery of the saved handoff request before creating another."
        case .invalidRecipient: return "Enter the collaboration ID of an invited teammate."
        case .noContext: return "Choose a current shared agreement revision before sending a prompt."
        case .sourceChanged: return "The source or its control changed. Refresh before preparing another handoff."
        }
    }
}

/// A per-device pending human intent, separate from both a provider's auth and
/// the host's irreversible attempt journal. Save precedes service submission.
public final class SharedAgentHandoffIntentStore: @unchecked Sendable {
    private let db: DatabaseQueue
    public init(directory: URL, device: UUID) throws {
        guard directory.isFileURL else { throw SharedAgentHostJournalError.invalidDirectory }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SharedAgentHostJournalError.invalidDirectory }
        let file = directory.appendingPathComponent("agent-client-\(device.uuidString).sqlite")
        if fm.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw SharedAgentHostJournalError.invalidDirectory }
        var config = Configuration(); config.busyMode = .timeout(2)
        db = try DatabaseQueue(path: file.path, configuration: config)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS handoff_client_schema(version INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO handoff_client_schema(version) SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM handoff_client_schema)")
            guard try Int.fetchOne(db, sql: "SELECT version FROM handoff_client_schema") == 1 else { throw SharedAgentHostJournalError.invalidState }
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS handoff_pending(singleton INTEGER PRIMARY KEY CHECK(singleton=1), intent BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS handoff_recent(singleton INTEGER PRIMARY KEY CHECK(singleton=1), receipt BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS handoff_drafts(object TEXT PRIMARY KEY NOT NULL, draft BLOB NOT NULL)")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func load() throws -> SharedAgentPendingIntent? {
        try db.read { db in
            guard let bytes = try Data.fetchOne(db, sql: "SELECT intent FROM handoff_pending WHERE singleton=1") else { return nil }
            return try JSONDecoder().decode(SharedAgentPendingIntent.self, from: bytes)
        }
    }
    public func save(_ intent: SharedAgentPendingIntent) throws {
        try db.write { db in
            let data = try JSONEncoder().encode(intent)
            if let bytes = try Data.fetchOne(db, sql: "SELECT intent FROM handoff_pending WHERE singleton=1") {
                guard try JSONDecoder().decode(SharedAgentPendingIntent.self, from: bytes) == intent else { throw SharedAgentHandoffError.pendingDelivery }
                return
            }
            try db.execute(sql: "INSERT INTO handoff_pending(singleton,intent) VALUES (1,?)", arguments: [data])
        }
    }
    public func clear(_ intent: SharedAgentPendingIntent) throws {
        try db.write { db in
            guard let bytes = try Data.fetchOne(db, sql: "SELECT intent FROM handoff_pending WHERE singleton=1") else { return }
            guard try JSONDecoder().decode(SharedAgentPendingIntent.self, from: bytes) == intent else { throw SharedAgentHandoffError.pendingDelivery }
            try db.execute(sql: "DELETE FROM handoff_pending WHERE singleton=1")
        }
    }
    public func recentReceipt() throws -> Collaboration.AgentDispatchReceipt? {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT receipt FROM handoff_recent WHERE singleton=1") else { return nil }
            return try JSONDecoder().decode(Collaboration.AgentDispatchReceipt.self, from: data)
        }
    }
    public func saveReceipt(_ receipt: Collaboration.AgentDispatchReceipt) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO handoff_recent(singleton,receipt) VALUES (1,?) ON CONFLICT(singleton) DO UPDATE SET receipt=excluded.receipt",
                arguments: [try JSONEncoder().encode(receipt)])
        }
    }
    public func acknowledge(_ intent: SharedAgentPendingIntent, receipt: Collaboration.AgentDispatchReceipt?) throws {
        try db.write { db in
            guard let bytes = try Data.fetchOne(db, sql: "SELECT intent FROM handoff_pending WHERE singleton=1"),
                  try JSONDecoder().decode(SharedAgentPendingIntent.self, from: bytes) == intent else { throw SharedAgentHandoffError.pendingDelivery }
            if let receipt {
                try db.execute(sql: "INSERT INTO handoff_recent(singleton,receipt) VALUES (1,?) ON CONFLICT(singleton) DO UPDATE SET receipt=excluded.receipt",
                    arguments: [try JSONEncoder().encode(receipt)])
            }
            try db.execute(sql: "DELETE FROM handoff_pending WHERE singleton=1")
        }
    }
    public func draft(object: SharedArea.ID<SharedArea.Object>) throws -> SharedAgentHandoffDraft {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT draft FROM handoff_drafts WHERE object=?", arguments: [object.rawValue.uuidString]) else { return .init() }
            return try JSONDecoder().decode(SharedAgentHandoffDraft.self, from: data)
        }
    }
    public func saveDraft(_ draft: SharedAgentHandoffDraft, object: SharedArea.ID<SharedArea.Object>) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO handoff_drafts(object,draft) VALUES (?,?) ON CONFLICT(object) DO UPDATE SET draft=excluded.draft",
                arguments: [object.rawValue.uuidString, try JSONEncoder().encode(draft)])
        }
    }
}

@MainActor
public final class SharedAgentHandoffController {
    public let identity: Collaboration.Identity
    public let transport: any SharedAgentHandoffTransport
    public let areaDirectory: URL
    public private(set) var areaState: Collaboration.State?
    public private(set) var control: Collaboration.AgentControlState?
    public private(set) var pending: SharedAgentPendingIntent?
    public private(set) var receipt: Collaboration.AgentDispatchReceipt?
    public private(set) var isBusy = false
    /// The last refresh was refused for membership, not lost in transit.
    private var refreshDenied = false
    public private(set) var message = "Refresh to check the source host and current control."
    public var onChange: (@MainActor () -> Void)?
    /// What this device's prompts gave each agent incarnation, by host acceptance.
    public let freshness: SharedAgentFreshnessLedger
    private let intents: SharedAgentHandoffIntentStore
    public init(identity: Collaboration.Identity, transport: any SharedAgentHandoffTransport, directory: URL) throws {
        self.identity = identity; self.transport = transport; areaDirectory = directory
        intents = try .init(directory: directory, device: identity.device)
        freshness = try .init(directory: directory.appendingPathComponent("freshness", isDirectory: true))
        pending = try intents.load()
        receipt = try intents.recentReceipt()
        if pending != nil { message = "A saved handoff request needs a delivery check. Its original identity is retained." }
    }
    public var latestContexts: [SharedArea.Context] {
        guard let document = areaState?.document else { return [] }
        var latest: [SharedArea.ID<SharedArea.Object>: SharedArea.Context] = [:]
        for context in document.contexts where document.items.contains(where: { $0.id == context.object }) { latest[context.object] = context }
        return latest.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }
    public func draft(object: SharedArea.ID<SharedArea.Object>) throws -> SharedAgentHandoffDraft { try intents.draft(object: object) }
    public func saveDraft(_ draft: SharedAgentHandoffDraft, object: SharedArea.ID<SharedArea.Object>) throws { try intents.saveDraft(draft, object: object) }
    public func refresh(object: SharedArea.ID<SharedArea.Object>) async {
        guard !isBusy else { return }
        isBusy = true; changed(); defer { isBusy = false; changed() }
        do {
            areaState = try await transport.state()
            control = try await transport.control(object: object.rawValue)
            if let receipt {
                let fresh = try await transport.receipt(id: receipt.command.id)
                try intents.saveReceipt(fresh); self.receipt = fresh
                try freshness.record(fresh)
            }
            // Settles older prompts too. One unreadable receipt (its requester
            // was removed) stays unsettled rather than failing the refresh.
            for id in try freshness.unsettledCommands() where id != receipt?.command.id {
                if let settled = try? await transport.receipt(id: id) { try freshness.record(settled) }
            }
            pending = try intents.load()
            message = pending == nil ? "Execution stays on the original host. Anyone in the area may prompt it; handoff says who is driving." : "A saved request needs a delivery check before another action."
            refreshDenied = false
        } catch {
            control = nil; areaState = nil; message = Self.failureMessage(error)
            if let failure = error as? CollaborationClientError, case let .server(status, _) = failure { refreshDenied = [401, 403, 404].contains(status) }
        }
    }
    public func offer(to person: SharedArea.ID<SharedArea.Person>) async {
        guard let control, person != identity.person else { message = SharedAgentHandoffError.invalidRecipient.localizedDescription; changed(); return }
        await mutate(.offer(.init(id: UUID(), recipient: person)), control: control)
    }
    public func acceptOffer() async {
        guard let control, let offer = control.offer, offer.recipient == identity.person else { return }
        await mutate(.accept(offer: offer.id), control: control)
    }
    public func reclaim() async { guard let control else { return }; await mutate(.reclaim, control: control) }
    public func send(text: String, context: SharedArea.ID<SharedArea.Revision>, mode: Collaboration.AgentPromptMode = .send) async {
        guard let state = areaState, let control, latestContexts.contains(where: { $0.id == context }) else {
            message = SharedAgentHandoffError.noContext.localizedDescription; changed(); return
        }
        let request = Collaboration.AgentPromptRequest(epoch: state.scope.epoch, controlRevision: control.revision,
            hostGeneration: control.hostGeneration, contextRevision: context, text: text, mode: mode)
        await saveAndDeliver(.init(object: control.object, action: .prompt(request)))
    }
    /// Full access: any member who may prompt sends to the shared agent, with
    /// no control handoff and no agreement revision. The prompt runs on the
    /// source host, after any prompt that reached the service before it.
    /// Anything but `.queued` leaves the sender's draft where it was.
    public enum PromptOutcome: Equatable, Sendable {
        case queued
        /// The service said no: access ended, or the agent's host changed.
        case refused
        /// Not known to have arrived. The saved request is checked again.
        case unresolved
    }
    @discardableResult
    public func prompt(object: SharedArea.ID<SharedArea.Object>, text: String) async -> PromptOutcome {
        await refresh(object: object)
        guard let state = areaState, let control, control.object == object else {
            if refreshDenied { message = "Refused: you no longer have access to this agent."; changed(); return .refused }
            message = SharedAgentHandoffError.unavailable.localizedDescription; changed(); return .unresolved
        }
        let request = Collaboration.AgentPromptRequest(epoch: state.scope.epoch, controlRevision: control.revision,
            hostGeneration: control.hostGeneration, text: text, mode: .send)
        await saveAndDeliver(.init(object: object, action: .prompt(request)))
        if receipt?.command.id == request.id, pending == nil { return receipt?.phase == .refused ? .refused : .queued }
        return pending == nil ? .refused : .unresolved
    }
    /// Re-reads the last prompt's receipt. A sender whose access ended can no
    /// longer read it; a prompt the host had not yet admitted can then never
    /// run, because admission rechecks membership, so it reads refused.
    public func refreshReceipt() async {
        guard let current = receipt, !current.phase.isFinal else { return }
        do {
            let fresh = try await transport.receipt(id: current.command.id)
            try intents.saveReceipt(fresh); receipt = fresh
            try freshness.record(fresh)
        } catch let failure as CollaborationClientError {
            guard case let .server(status, _) = failure, [401, 403, 404].contains(status),
                  current.phase == .queued || current.phase == .claimed else { return }
            receipt = .init(command: current.command, phase: .refused, claimID: current.claimID)
            message = "Refused: you no longer have access to this agent."
        } catch { return }
        changed()
    }
    public func checkDelivery() async {
        guard !isBusy, let pending else { return }
        isBusy = true; changed(); defer { isBusy = false; changed() }
        await deliver(pending)
    }
    private func mutate(_ action: Collaboration.AgentControlAction, control: Collaboration.AgentControlState) async {
        guard let state = areaState else { return }
        let request = Collaboration.AgentControlMutation(epoch: state.scope.epoch, expectedRevision: control.revision,
            hostGeneration: control.hostGeneration, action: action)
        await saveAndDeliver(.init(object: control.object, action: .control(request)))
    }
    private func saveAndDeliver(_ intent: SharedAgentPendingIntent) async {
        guard !isBusy, pending == nil else { message = SharedAgentHandoffError.pendingDelivery.localizedDescription; changed(); return }
        do { try intents.save(intent); pending = intent }
        catch { message = "The handoff request could not be saved. Nothing was sent."; changed(); return }
        isBusy = true; changed(); defer { isBusy = false; changed() }
        await deliver(intent)
    }
    private func deliver(_ intent: SharedAgentPendingIntent) async {
        var acknowledged = false
        do {
            switch intent.action {
            case .control(let request):
                control = try await transport.change(object: intent.object.rawValue, request: request)
                message = "Control updated. Refresh shows the latest accepted handoff."
            case .prompt(let request):
                receipt = try await transport.send(object: intent.object.rawValue, request: request)
                message = Self.receiptMessage(receipt!.phase)
            }
            acknowledged = true
            let delivered: Collaboration.AgentDispatchReceipt? = switch intent.action { case .prompt: receipt; case .control: nil }
            try intents.acknowledge(intent, receipt: delivered); pending = nil
            if let delivered { try freshness.record(delivered) }
            areaState = try await transport.state()
            control = try await transport.control(object: intent.object.rawValue)
        } catch {
            if acknowledged {
                message = "The service accepted this request. Refresh to update its current presentation."
                return
            }
            if let failure = error as? CollaborationClientError, case let .server(status, code) = failure,
               status == 403 || (status == 409 && code != "changedIntent") {
                // These routes check their durable idempotency receipt before
                // control/epoch refusal. This response proves this exact intent
                // cannot apply; monotonic generations prevent a late old apply.
                do { try intents.clear(intent); pending = nil }
                catch { message = "The refused request could not be cleared locally. Check it again."; return }
                message = "This request was not accepted. " + Self.failureMessage(failure)
                return
            }
            // Keep exact intent after transport loss or current-scope rejection.
            // Newer permission/revision state cannot disprove an earlier commit.
            message = "Delivery is unresolved. Check this saved request again. " + Self.failureMessage(error)
        }
    }
    public static func receiptMessage(_ phase: Collaboration.AgentDispatchPhase) -> String {
        switch phase {
        case .queued: return "Saved for the original host. It has not accepted the prompt yet."
        case .claimed: return "The original host claimed the request; provider submission is not confirmed."
        case .dispatching: return "The original host is attempting submission. Completion is not confirmed."
        case .accepted: return "Accepted by Array on the original host. This is not a claim that the turn completed."
        case .refused: return "The host refused this request. Refresh and review current control before trying another."
        case .uncertain: return "Provider submission is unknown after interruption. Array will not replay this prompt automatically."
        }
    }
    private static func failureMessage(_ error: any Error) -> String {
        if let error = error as? SharedAgentHandoffError { return error.localizedDescription }
        if let error = error as? CollaborationClientError, case let .server(status, _) = error {
            if [401, 403, 404].contains(status) { return "Current membership, source-host ownership or control does not permit this action." }
            if status == 409 { return "The source, agreement revision or control changed; refresh before preparing a new request." }
        }
        return "The local collaboration service or source host is unavailable."
    }
    private func changed() { onChange?() }
}
