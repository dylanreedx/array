#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import Foundation
import ContinuumRevivedRelayProtocol

public struct RelayAPNSConfiguration: Sendable {
    public var keyID: String
    public var teamID: String
    public var privateKeyPEM: String
    public var topic: String
    public var production: Bool

    public init(keyID: String, teamID: String, privateKeyPEM: String, topic: String = "dev.dylanreedx.continuum", production: Bool = true) {
        self.keyID = keyID
        self.teamID = teamID
        self.privateKeyPEM = privateKeyPEM
        self.topic = topic
        self.production = production
    }
}

public struct RelayAPNSRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public var body: Data
    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url; self.headers = headers; self.body = body
    }
}

public struct RelayAPNSResponse: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data
    public var retryAfter: TimeInterval?
    public init(statusCode: Int, body: Data = Data(), retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode; self.body = body; self.retryAfter = retryAfter
    }
}

public protocol RelayAPNSTransport: Sendable {
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse
}

public struct RelayURLSessionAPNSTransport: RelayAPNSTransport {
    public init() {}
    public func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 20 // shorter than the durable attempt lease
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await URLSession.shared.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        let raw = http?.value(forHTTPHeaderField: "Retry-After")
        var delay = raw.flatMap(TimeInterval.init)
        if delay == nil, let raw {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            delay = formatter.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
        }
        return RelayAPNSResponse(statusCode: http?.statusCode ?? 0, body: body, retryAfter: delay)
    }
}

public protocol RelayEventPushDelivering: Sendable {
    func deliver(event: RelayEvent, instanceID: UUID) async
    func drainOutbox() async
    func deliverPublished(event: RelayEvent, instanceID: UUID) async
}

public extension RelayEventPushDelivering {
    func drainOutbox() async {}
    func deliverPublished(event: RelayEvent, instanceID: UUID) async { await deliver(event: event, instanceID: instanceID) }
}

/// Narrow APNs sender for relay-owned system surfaces. It projects only identifiers,
/// names and status; source summaries, transcripts, tools, filenames and paths are
/// never copied into an Apple-visible payload.
public actor RelayAPNSService<Transport: RelayAPNSTransport>: RelayEventPushDelivering {
    private let store: RelayStore
    private let configuration: RelayAPNSConfiguration
    private let transport: Transport
    private let signingKey: P256.Signing.PrivateKey
    private var cachedAuthorization: (value: String, createdAt: Date)?
    private let trace: @Sendable (RelayNotificationTrace) -> Void
    private let clock: @Sendable () -> Date

    public init(store: RelayStore, configuration: RelayAPNSConfiguration, transport: Transport,
                trace: @escaping @Sendable (RelayNotificationTrace) -> Void = RelayNotificationTrace.log,
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.store = store
        self.configuration = configuration
        self.transport = transport
        self.trace = trace
        self.clock = clock
        signingKey = try P256.Signing.PrivateKey(pemRepresentation: configuration.privateKeyPEM)
    }

    public func deliver(event: RelayEvent, instanceID: UUID) async {
        await deliver(event: event, instanceID: instanceID, committed: false)
    }

    public func deliverPublished(event: RelayEvent, instanceID: UUID) async {
        if event.kind == "task.batch.v1" { await deliverTaskBatch(event, instanceID: instanceID); return }
        await deliver(event: event, instanceID: instanceID, committed: true)
    }

    private func deliver(event: RelayEvent, instanceID: UUID, committed: Bool, alertOnly: Bool = false) async {
        let decision = RelaySystemSurfaceProjection.evaluate(event: event, instanceID: instanceID)
        func record(_ outcome: RelayNotificationTrace.Outcome, registration: RelayStoredPushRegistration? = nil, code: Int? = nil) {
            trace(.init(path: decision.path, instanceID: instanceID, eventSequence: event.sequence,
                        decisionID: decision.projection?.notificationIdentity,
                        registrationKind: registration?.kind.rawValue, registrationID: registration?.id,
                        deviceID: registration?.deviceID, outcome: outcome, statusCode: code))
        }
        if event.kind == "sync.message" {
            do {
                if try await store.taskNotificationOwner(instanceID: instanceID) != nil {
                    RelayNotificationOwnershipPath.legacySuppressed.log()
                    record(.taskOwnerSuppressed); return
                }
            } catch {
                // Unavailable ownership evidence cannot authorize a fallback to
                // legacy alerts or a second widget/Live Activity producer.
                RelayNotificationOwnershipPath.deliveryFailure.log()
                record(.preparationFailure); return
            }
        }
        guard let projection = decision.projection else { record(.unprojectable); return }
        do {
            if !committed { try await store.supersedeAlerts(projection: projection, now: clock()) }
            let registrations = try await store.pushRegistrations(instanceID: instanceID).filter { !alertOnly || $0.kind == .apns }
            guard !registrations.isEmpty else { record(.noRecipients); return }
            let authorization = try authorizationHeader(now: clock())
            for registration in registrations {
                if registration.kind == .apns {
                    guard projection.notification != nil else { record(.suppressed, registration: registration); continue }
                    // Committed publication already fixed the recipient set and
                    // queued intent in its transaction. A late detached task may
                    // wake delivery, but must never recreate superseded work or
                    // enroll a phone paired after that event was committed.
                    let queued = try await (committed
                        ? store.existingAlert(registrationID: registration.id, decisionID: projection.notificationIdentity)
                        : store.enqueueAlert(projection: projection, eventSequence: event.sequence, registrationID: registration.id, now: clock()))
                    switch queued {
                    case .deduplicated: record(.deduplicated, registration: registration)
                    case .capacityRejected: record(.capacityRejected, registration: registration)
                    case .suppressed: record(.suppressed, registration: registration)
                    case .queued, .pending: break
                    }
                    continue
                }
                guard let request = try makeRequest(registration: registration, projection: projection, authorization: authorization) else {
                    record(.suppressed, registration: registration)
                    continue
                }
                let response: RelayAPNSResponse
                do {
                    response = try await transport.send(request)
                } catch {
                    // Non-alert surfaces remain best effort. Alerts use the
                    // durable outbox below and never depend on republishing.
                    record(.transportFailure, registration: registration)
                    continue
                }
                if response.statusCode == 410 {
                    try await store.invalidatePushRegistration(id: registration.id)
                    record(.tokenInvalidated, registration: registration, code: response.statusCode)
                } else {
                    record(response.statusCode == 200 ? .acceptedByApple : .rejectedByApple,
                           registration: registration, code: response.statusCode)
                }
            }
            await drainAlerts(instanceID: instanceID)
        } catch {
            // Invalid APNs config, storage or projection cannot break relay sync.
            record(.preparationFailure)
        }
    }

    private func deliverTaskBatch(_ event: RelayEvent, instanceID: UUID) async {
        do {
            let batch = try JSONDecoder().decode(RelayTaskBatch.self, from: event.payload)
            guard let owner = try await store.taskNotificationOwner(instanceID: instanceID),
                  owner.publisherID == batch.publisherID, owner.revision == batch.revision else { RelayNotificationOwnershipPath.stale.log(); return }
            var projections: [RelaySystemSurfaceProjection] = []
            for task in batch.tasks {
                let payload = try JSONEncoder().encode(task)
                if let projection = RelaySystemSurfaceProjection.project(event: .init(kind: "task.state.v1", payload: payload), instanceID: instanceID) { projections.append(projection) }
                await deliver(event: .init(sequence: event.sequence, kind: "task.state.v1", payload: payload), instanceID: instanceID, committed: true, alertOnly: true)
            }
            let running = projections.reduce(0) { $0 + $1.runningCount }, attention = projections.reduce(0) { $0 + $1.attentionCount }
            let terminal = !projections.isEmpty && projections.allSatisfy(\.terminal)
            let failed = projections.contains { $0.terminalOutcome == "failed" }
            let cancelled = projections.contains { ["cancelled", "interrupted"].contains($0.terminalOutcome ?? "") }
            let aggregate = RelaySystemSurfaceProjection(instanceID: instanceID, agentID: nil, agentName: nil, workspaceName: nil,
                status: attention > 0 ? "needsAttention" : (running > 0 ? "working" : (terminal ? "done" : "stale")),
                runningCount: running, attentionCount: attention, terminal: terminal, notification: nil,
                terminalOutcome: terminal ? (failed ? "failed" : (cancelled ? "cancelled" : "succeeded")) : nil,
                notificationIdentity: "task-batch-\(batch.publisherID)-\(batch.revision)")
            guard let latest = try await store.taskNotificationOwner(instanceID: instanceID), latest == owner else { return }
            let authorization = try authorizationHeader(now: clock())
            for registration in try await store.pushRegistrations(instanceID: instanceID) where registration.kind != .apns {
                // Task ownership never repeatedly creates Live Activities. Existing
                // update tokens and background refresh still receive one aggregate.
                guard registration.kind != .liveActivityStart,
                      let request = try makeRequest(registration: registration, projection: aggregate, authorization: authorization) else { continue }
                let response = try await transport.send(request)
                if response.statusCode == 410 { try await store.invalidatePushRegistration(id: registration.id) }
                trace(.init(path: terminal ? .taskCompletion : .taskActive, instanceID: instanceID, eventSequence: event.sequence,
                    decisionID: aggregate.notificationIdentity, registrationKind: registration.kind.rawValue, registrationID: registration.id,
                    deviceID: registration.deviceID, outcome: response.statusCode == 200 ? .acceptedByApple : .rejectedByApple, statusCode: response.statusCode))
            }
        } catch { RelayNotificationOwnershipPath.deliveryFailure.log() }
    }

    public func drainOutbox() async { await drainAlerts(instanceID: nil) }

    private func drainAlerts(instanceID: UUID?) async {
        for _ in 0..<RelayOutboxPolicy.batchLimit {
            if Task.isCancelled { return }
            do {
                guard let claim = try await store.claimNextAlert(now: clock(), instanceID: instanceID) else { return }
                guard let recipient = try await store.prepareAlertRecipient(claim, now: clock()) else { continue }
                func record(_ outcome: RelayNotificationTrace.Outcome, code: Int? = nil) {
                    trace(.init(path: claim.intent.path, instanceID: claim.instanceID, eventSequence: claim.eventSequence,
                                decisionID: claim.decisionID, registrationKind: "apns", registrationID: claim.registrationID,
                                deviceID: recipient.registration.deviceID, outcome: outcome, statusCode: code))
                }
                var headers = ["authorization": try authorizationHeader(now: clock()), "content-type": "application/json",
                               "apns-topic": configuration.topic, "apns-push-type": "alert", "apns-priority": claim.intent.priority,
                               "apns-id": claim.apnsID, "apns-expiration": String(Int(claim.expiresAt.timeIntervalSince1970))]
                if let collapse = claim.intent.collapseID { headers["apns-collapse-id"] = collapse }
                let request = makeAPNSRequest(registration: recipient.registration, payload: claim.intent.payload, headers: headers)
                let response: RelayAPNSResponse
                do { response = try await transport.send(request) }
                catch {
                    try await store.finishAlertAttempt(claim, recipient: recipient, statusCode: nil, now: clock())
                    record(.transportFailure); continue
                }
                try await store.finishAlertAttempt(claim, recipient: recipient, statusCode: response.statusCode,
                                                   retryAfter: response.retryAfter, now: clock())
                record(response.statusCode == 200 ? .acceptedByApple : (response.statusCode == 410 ? .tokenInvalidated : .rejectedByApple), code: response.statusCode)
            } catch {
                // Pending intent and lease survive preparation/storage failure.
                // Error values can contain SQL/data, so never print them here.
                FileHandle.standardError.write(Data("{\"path\":\"OUT-12\",\"event\":\"outbox_worker_failed\",\"phase\":\"poll_or_attempt\"}\n".utf8))
                return
            }
        }
    }

    private func makeRequest(registration: RelayStoredPushRegistration, projection: RelaySystemSurfaceProjection, authorization: String) throws -> RelayAPNSRequest? {
        let payload: Data
        var headers = [
            "authorization": authorization,
            "content-type": "application/json",
        ]
        switch registration.kind {
        case .apns:
            return nil // exclusively owned by the durable alert outbox
        case .widget:
            payload = projection.backgroundPayload
            headers["apns-topic"] = configuration.topic
            headers["apns-push-type"] = "background"
            headers["apns-priority"] = "5"
            headers["apns-collapse-id"] = "array-widget-\(projection.instanceID.uuidString)"
        case .liveActivity, .liveActivityStart:
            payload = try projection.liveActivityPayload(start: registration.kind == .liveActivityStart)
            headers["apns-topic"] = configuration.topic + ".push-type.liveactivity"
            headers["apns-push-type"] = "liveactivity"
            headers["apns-priority"] = "10"
            headers["apns-collapse-id"] = "array-live-\(projection.instanceID.uuidString)"
        }
        guard !registration.token.isEmpty else { return nil }
        return makeAPNSRequest(registration: registration, payload: payload, headers: headers)
    }

    private func makeAPNSRequest(registration: RelayStoredPushRegistration, payload: Data, headers: [String: String]) -> RelayAPNSRequest {
        let token = registration.token.map { String(format: "%02x", $0) }.joined()
        let host = configuration.production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        return RelayAPNSRequest(url: URL(string: "https://\(host)/3/device/\(token)")!, headers: headers, body: payload)
    }

    private func authorizationHeader(now: Date = .init()) throws -> String {
        if let cachedAuthorization, (0..<(50 * 60)).contains(now.timeIntervalSince(cachedAuthorization.createdAt)) { return cachedAuthorization.value }
        let header = try Self.base64URL(JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": configuration.keyID]))
        let claims = try Self.base64URL(JSONSerialization.data(withJSONObject: ["iss": configuration.teamID, "iat": Int(now.timeIntervalSince1970)]))
        let unsigned = header + "." + claims
        let signature = try signingKey.signature(for: Data(unsigned.utf8))
        let value = "bearer " + unsigned + "." + Self.base64URL(signature.rawRepresentation)
        cachedAuthorization = (value, now)
        return value
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct RelaySystemSurfaceProjection: Sendable, Equatable {
    public struct Notification: Sendable, Equatable {
        var category: String; var title: String; var body: String; var interruption: String
        var agentID: UUID?; var approvalRequestID: String?; var coalesces: Bool
        var path: RelayNotificationPath
        var collapseID: String? = nil
        var taskID: UUID? = nil
        var runID: UUID? = nil
        var instanceID: UUID? = nil

        func encoded() throws -> Data {
            var root: [String: Any] = [
                "aps": ["alert": ["title": title, "body": body], "category": "continuum.push.\(category)", "interruption-level": interruption, "sound": "default"],
                "category": category,
                "notificationPath": path.rawValue,
                "deepLink": agentID.map { "array://agent/\($0.uuidString)" } ?? "array://agents",
            ]
            if let agentID { root["agentId"] = agentID.uuidString }
            if let taskID, let runID, let instanceID, let agentID {
                root["taskId"] = taskID.uuidString
                root["runId"] = runID.uuidString
                root["instanceId"] = instanceID.uuidString
                root["deepLink"] = "array://agent/\(agentID.uuidString)?task=\(taskID.uuidString)&run=\(runID.uuidString)&instance=\(instanceID.uuidString)"
            }
            if let approvalRequestID { root["approvalRequestId"] = approvalRequestID }
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            guard data.count <= 4096 else { throw RelayStoreError.payloadTooLarge }
            return data
        }
    }

    public var instanceID: UUID
    public var agentID: UUID?
    public var agentName: String?
    public var workspaceName: String?
    public var status: String
    public var runningCount: Int
    public var attentionCount: Int
    public var terminal: Bool
    public var notification: Notification?
    public var terminalOutcome: String?
    public var notificationIdentity: String
    public var notificationTaskID: UUID? = nil

    var outboxSubject: String { notificationTaskID.map { "task:\($0.uuidString)" } ?? "agent:\(agentID?.uuidString ?? "unknown")" }

    /// A rejected new state may still identify a known subject. Withhold its
    /// old pending alerts; never infer identity through unrelated envelopes.
    static func rejectedOutboxSubject(event: RelayEvent) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: event.payload)) as? [String: Any] else { return nil }
        if event.kind == "task.state.v1", let id = (root["taskID"] as? String).flatMap(UUID.init(uuidString:)) {
            return "task:\(id.uuidString)"
        }
        guard event.kind == "sync.message", let envelope = root["activity"], let activity = findActivity(in: envelope),
              let id = (activity["agentId"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return "agent:\(id.uuidString)"
    }

    public static func project(event: RelayEvent, instanceID: UUID) -> Self? {
        evaluate(event: event, instanceID: instanceID).projection
    }

    public static func evaluate(event: RelayEvent, instanceID: UUID) -> RelayNotificationDecision {
        if event.kind == "task.state.v1" { return evaluateTask(event: event, instanceID: instanceID) }
        guard event.kind == "sync.message",
              let root = (try? JSONSerialization.jsonObject(with: event.payload)) as? [String: Any],
              let envelope = root["activity"],
              let activity = findActivity(in: envelope) else { return .init(path: .unprojectable, projection: nil) }
        guard let status = string(activity["status"]) else {
            return .init(path: .unsupportedState, projection: nil)
        }
        let outcome = string(activity["terminalOutcome"])
        if let rawOutcome = activity["terminalOutcome"], !(rawOutcome is NSNull), !(rawOutcome is String) {
            return .init(path: .unsupportedState, projection: nil)
        }
        guard let agentID = string(activity["agentId"]).flatMap(UUID.init(uuidString:)) else {
            return .init(path: .invalidIdentity, projection: nil)
        }
        guard ["configuring", "working", "idle", "needsAttention", "done", "stale"].contains(status),
              outcome == nil || ["succeeded", "failed", "runtimeError", "cancelled", "interrupted"].contains(outcome!) else {
            return .init(path: .unsupportedState, projection: nil)
        }
        let approval = string(activity["approvalRequestId"])
        let agentName = safeName(string(activity["agentName"]) ?? string(activity["name"]) ?? string(activity["title"]))
        let workspaceName = safeName(string(activity["workspaceName"]) ?? string(activity["workspace"]))
        let terminal = status != "working" && status != "configuring" && status != "needsAttention"
            && status != "stale" && (status == "done" || outcome != nil)
        let notification: Notification?
        let path: RelayNotificationPath
        if status == "needsAttention", approval != nil {
            path = .approval
            notification = .init(category: "N1", title: "Approval requested", body: named(agentName, suffix: "needs approval."), interruption: "time-sensitive", agentID: agentID, approvalRequestID: approval, coalesces: false, path: path)
        } else if status == "needsAttention" {
            path = .input
            notification = .init(category: "N2", title: "Agent waiting for input", body: named(agentName, suffix: "is waiting for input."), interruption: "time-sensitive", agentID: agentID, approvalRequestID: nil, coalesces: false, path: path)
        } else if !terminal {
            path = .progress
            notification = nil
        } else if outcome == "cancelled" || outcome == "interrupted" {
            path = .cancelled
            notification = nil
        } else if outcome == "failed" || outcome == "runtimeError" {
            path = .failure
            notification = .init(category: "N4", title: "Agent failed", body: named(agentName, suffix: "failed."), interruption: "active", agentID: agentID, approvalRequestID: nil, coalesces: true, path: path)
        } else if outcome == "succeeded" || status == "done" {
            path = .completion
            notification = .init(category: "N3", title: "Agent finished", body: named(agentName, suffix: "completed."), interruption: "active", agentID: agentID, approvalRequestID: nil, coalesces: true, path: path)
        } else {
            path = .progress
            notification = nil // ordinary progress never banners
        }
        // Hash only identity/state metadata, never summary, names or transcript.
        // Relay sequence changes on republish; the source identity must not.
        let identityKeys = ["agentId", "approvalRequestId", "runId"]
        var identity = activity.filter { identityKeys.contains($0.key) }
        identity["path"] = path.rawValue
        // AgentInventory rebuilds positional sequence numbers. Prefer the
        // original event's timestamp; neither renumbering nor a relay restart
        // creates a new event. Category is already captured by the path.
        if let occurredAt = activity["occurredAtReferenceInterval"] as? NSNumber {
            identity["occurredAtReferenceInterval"] = occurredAt
        } else {
            identity["sequence"] = activity["sequence"]
            identity["replicaId"] = activity["replicaId"]
        }
        let encodedIdentity = (try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])) ?? Data()
        let notificationIdentity = SHA256.hash(data: encodedIdentity).map { String(format: "%02x", $0) }.joined()
        return .init(path: path, projection: .init(instanceID: instanceID, agentID: agentID, agentName: agentName, workspaceName: workspaceName, status: status, runningCount: ["working", "configuring"].contains(status) ? 1 : 0, attentionCount: status == "needsAttention" ? 1 : 0, terminal: terminal, notification: notification, terminalOutcome: outcome, notificationIdentity: notificationIdentity))
    }

    var backgroundPayload: Data {
        (try? JSONSerialization.data(withJSONObject: ["aps": ["content-available": 1], "reason": "relay-state", "instanceId": instanceID.uuidString], options: [.sortedKeys])) ?? Data()
    }

    func liveActivityPayload(start: Bool) throws -> Data {
        let terminalPhase: String = ["cancelled", "interrupted"].contains(terminalOutcome ?? "") ? "idle"
            : (["failed", "runtimeError"].contains(terminalOutcome ?? "") ? "failed" : "completed")
        let phase: String = attentionCount > 0 ? "attention" : (terminal ? terminalPhase : (runningCount > 0 ? "working" : "idle"))
        var content: [String: Any] = [
            "runningCount": runningCount, "attentionCount": attentionCount, "phase": phase,
            "statusText": status,
        ]
        if let agentID { content["agentID"] = agentID.uuidString }
        if let agentName { content["agentName"] = agentName }
        if let workspaceName { content["workspaceName"] = workspaceName }
        var aps: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970), "event": terminal ? "end" : (start ? "start" : "update"), "content-state": content]
        if start {
            aps["attributes-type"] = "ArrayAgentActivityAttributes"
            aps["attributes"] = ["instanceID": instanceID.uuidString, "macName": "Mac"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])
        guard data.count <= 4096 else { throw RelayStoreError.payloadTooLarge }
        return data
    }

    private static func findActivity(in value: Any, depth: Int = 0) -> [String: Any]? {
        guard depth < 16 else { return nil }
        if let object = value as? [String: Any] {
            if object["status"] != nil, object["agentId"] != nil { return object }
            // Only known Codable activity envelopes, aggregate dictionaries and
            // history may be traversed. Future message kinds fail closed.
            let envelopeKeys = Set(["_0", "event", "snapshot", "byAgent", "byTile", "recent"])
            for key in object.keys.sorted() where envelopeKeys.contains(key) || UUID(uuidString: key) != nil {
                if key == "recent", let recent = object[key] as? [Any] {
                    // Core folds this ring in canonical source order. Older
                    // terminal items must not override its current event.
                    if let latest = recent.last,
                       let result = findActivity(in: latest, depth: depth + 1) { return result }
                } else if let child = object[key],
                          let result = findActivity(in: child, depth: depth + 1) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array { if let result = findActivity(in: child, depth: depth + 1) { return result } }
        }
        return nil
    }
    private static func string(_ value: Any?) -> String? { value as? String }
    private static func safeName(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains("\\"), clean.count <= 80 else { return nil }
        return clean
    }
    private static func named(_ name: String?, suffix: String) -> String { name.map { "\($0) \(suffix)" } ?? "An agent \(suffix)" }
}
