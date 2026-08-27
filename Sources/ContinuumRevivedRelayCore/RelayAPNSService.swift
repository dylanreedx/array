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
    public init(statusCode: Int, body: Data = Data()) { self.statusCode = statusCode; self.body = body }
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
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await URLSession.shared.data(for: urlRequest)
        return RelayAPNSResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
    }
}

public protocol RelayEventPushDelivering: Sendable {
    func deliver(event: RelayEvent, instanceID: UUID) async
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

    public init(store: RelayStore, configuration: RelayAPNSConfiguration, transport: Transport) throws {
        self.store = store
        self.configuration = configuration
        self.transport = transport
        signingKey = try P256.Signing.PrivateKey(pemRepresentation: configuration.privateKeyPEM)
    }

    public func deliver(event: RelayEvent, instanceID: UUID) async {
        guard let projection = RelaySystemSurfaceProjection.project(event: event, instanceID: instanceID) else { return }
        do {
            let registrations = try await store.pushRegistrations(instanceID: instanceID)
            let authorization = try authorizationHeader()
            for registration in registrations {
                guard let request = try makeRequest(registration: registration, projection: projection, authorization: authorization) else { continue }
                do {
                    let response = try await transport.send(request)
                    if response.statusCode == 410 {
                        try? await store.invalidatePushRegistration(id: registration.id)
                    }
                } catch {
                    // Push is deliberately best effort. The durable event and live relay
                    // fanout have already succeeded and must never be rolled back.
                    continue
                }
            }
        } catch {
            // Invalid APNs config, storage or projection cannot break relay sync.
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
            guard let notification = projection.notification else { return nil }
            payload = try notification.encoded()
            headers["apns-topic"] = configuration.topic
            headers["apns-push-type"] = "alert"
            headers["apns-priority"] = notification.interruption == "passive" ? "5" : "10"
            if notification.coalesces { headers["apns-collapse-id"] = "array-terminal-\(projection.instanceID.uuidString)" }
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
        let token = registration.token.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return nil }
        let host = configuration.production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        return RelayAPNSRequest(url: URL(string: "https://\(host)/3/device/\(token)")!, headers: headers, body: payload)
    }

    private func authorizationHeader(now: Date = .init()) throws -> String {
        if let cachedAuthorization, now.timeIntervalSince(cachedAuthorization.createdAt) < 50 * 60 { return cachedAuthorization.value }
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

        func encoded() throws -> Data {
            var root: [String: Any] = [
                "aps": ["alert": ["title": title, "body": body], "category": "continuum.push.\(category)", "interruption-level": interruption, "sound": "default"],
                "category": category,
                "deepLink": agentID.map { "array://agent/\($0.uuidString)" } ?? "array://agents",
            ]
            if let agentID { root["agentId"] = agentID.uuidString }
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

    public static func project(event: RelayEvent, instanceID: UUID) -> Self? {
        guard event.kind == "sync.message",
              let root = try? JSONSerialization.jsonObject(with: event.payload),
              let activity = findActivity(in: root) else { return nil }
        let status = string(activity["status"]) ?? "idle"
        let outcome = string(activity["terminalOutcome"])
        let agentID = string(activity["agentId"]).flatMap(UUID.init(uuidString:))
        let approval = string(activity["approvalRequestId"])
        let agentName = safeName(string(activity["agentName"]) ?? string(activity["name"]) ?? string(activity["title"]))
        let workspaceName = safeName(string(activity["workspaceName"]) ?? string(activity["workspace"]))
        let terminal = status == "done" || outcome != nil
        let notification: Notification?
        if status == "needsAttention", approval != nil {
            notification = .init(category: "N1", title: "Approval requested", body: named(agentName, suffix: "needs approval."), interruption: "time-sensitive", agentID: agentID, approvalRequestID: approval, coalesces: false)
        } else if status == "needsAttention" {
            notification = .init(category: "N2", title: "Agent waiting for input", body: named(agentName, suffix: "is waiting for input."), interruption: "time-sensitive", agentID: agentID, approvalRequestID: nil, coalesces: false)
        } else if outcome == "failed" || outcome == "runtimeError" {
            notification = .init(category: "N4", title: "Agent failed", body: named(agentName, suffix: "failed."), interruption: "active", agentID: agentID, approvalRequestID: nil, coalesces: true)
        } else if outcome == "succeeded" || status == "done" {
            notification = .init(category: "N3", title: "Agent finished", body: named(agentName, suffix: "completed."), interruption: "active", agentID: agentID, approvalRequestID: nil, coalesces: true)
        } else {
            notification = nil // ordinary progress never banners
        }
        return .init(instanceID: instanceID, agentID: agentID, agentName: agentName, workspaceName: workspaceName, status: status, runningCount: ["working", "configuring"].contains(status) ? 1 : 0, attentionCount: status == "needsAttention" ? 1 : 0, terminal: terminal, notification: notification)
    }

    var backgroundPayload: Data {
        (try? JSONSerialization.data(withJSONObject: ["aps": ["content-available": 1], "reason": "relay-state", "instanceId": instanceID.uuidString], options: [.sortedKeys])) ?? Data()
    }

    func liveActivityPayload(start: Bool) throws -> Data {
        let phase: String = attentionCount > 0 ? "attention" : (terminal ? (status == "done" ? "completed" : "failed") : (runningCount > 0 ? "working" : "idle"))
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

    private static func findActivity(in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if object["status"] != nil, object["agentId"] != nil { return object }
            for child in object.values { if let result = findActivity(in: child) { return result } }
        } else if let array = value as? [Any] {
            for child in array { if let result = findActivity(in: child) { return result } }
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
