import CryptoKit
import Foundation

public enum PushInterruptionLevel: String, Codable, Sendable {
    case passive
    case active
    case timeSensitive = "time-sensitive"
}

public enum PushDeepLinkTarget: String, Codable, Sendable {
    case approvalCard
    case agentDetail
    case agentsBoard
    case statusFooter
    case devices
}

public enum PushCategory: String, CaseIterable, Codable, Sendable {
    case approvalRequested = "N1"
    case agentWaitingForInput = "N2"
    case agentFinished = "N3"
    case agentFailed = "N4"
    case stillWorkingDigest = "N5"
    case desktopConnectionChanged = "N6"
    case deviceSecurityChanged = "N7"
    case sessionReapedOrRevived = "N8"

    public static let approveActionId = "continuum.push.action.approve"
    public static let denyActionId = "continuum.push.action.deny"
    public static let openActionId = "continuum.push.action.open"
    public static let approveActionTitle = "Approve"
    public static let denyActionTitle = "Deny"
    public static let openActionTitle = "Open"

    public var identifier: String { "continuum.push.\(rawValue)" }

    public var interruptionLevel: PushInterruptionLevel {
        switch self {
        case .approvalRequested, .agentWaitingForInput, .deviceSecurityChanged:
            return .timeSensitive
        case .agentFinished, .agentFailed:
            return .active
        case .stillWorkingDigest, .desktopConnectionChanged, .sessionReapedOrRevived:
            return .passive
        }
    }

    public var defaultEnabled: Bool {
        switch self {
        case .approvalRequested, .agentWaitingForInput, .agentFinished, .agentFailed, .stillWorkingDigest:
            return true
        case .desktopConnectionChanged, .deviceSecurityChanged, .sessionReapedOrRevived:
            return false
        }
    }

    public var isMuteable: Bool { self != .deviceSecurityChanged }

    public var actionIds: [String] {
        switch self {
        case .approvalRequested:
            return [Self.approveActionId, Self.denyActionId]
        case .agentWaitingForInput:
            return [Self.openActionId]
        case .agentFinished, .agentFailed, .stillWorkingDigest, .desktopConnectionChanged, .deviceSecurityChanged, .sessionReapedOrRevived:
            return []
        }
    }

    public var deepLinkTarget: PushDeepLinkTarget {
        switch self {
        case .approvalRequested:
            return .approvalCard
        case .agentWaitingForInput, .agentFinished, .agentFailed, .sessionReapedOrRevived:
            return .agentDetail
        case .stillWorkingDigest:
            return .agentsBoard
        case .desktopConnectionChanged:
            return .statusFooter
        case .deviceSecurityChanged:
            return .devices
        }
    }
}

public protocol PushCategoryPreferences: Sendable {
    func isEnabled(_ category: PushCategory) -> Bool
}

public struct DefaultPushCategoryPreferences: PushCategoryPreferences {
    public init() {}
    public func isEnabled(_ category: PushCategory) -> Bool { category.defaultEnabled }
}

public struct AllEnabledPushCategoryPreferences: PushCategoryPreferences {
    public init() {}
    public func isEnabled(_ category: PushCategory) -> Bool { true }
}

public struct PushPayload: Equatable, Sendable {
    private enum ReservedPayloadKey: String, CaseIterable {
        case aps
        case category
        case deepLink
        case actionIds
        case target
        case approvalRequestId
    }

    private static let reservedUserInfoKeys = Set(ReservedPayloadKey.allCases.map(\.rawValue))

    public var category: PushCategory
    public var title: String
    public var body: String
    public var deepLink: String
    public var approvalRequestId: String?
    public var userInfo: [String: String]

    public init(category: PushCategory, title: String, body: String, deepLink: String, approvalRequestId: String? = nil, userInfo: [String: String] = [:]) {
        self.category = category
        self.title = title
        self.body = Self.truncated(body)
        self.deepLink = deepLink
        self.approvalRequestId = approvalRequestId
        self.userInfo = userInfo
    }

    public func encodedJSON() throws -> Data {
        var root: [String: Any] = [:]
        for (key, value) in userInfo where !Self.reservedUserInfoKeys.contains(key) {
            root[key] = value
        }
        root[ReservedPayloadKey.aps.rawValue] = [
            "alert": ["title": title, "body": Self.truncated(body)],
            "category": category.identifier,
            "interruption-level": category.interruptionLevel.rawValue,
            "sound": "default"
        ]
        root[ReservedPayloadKey.category.rawValue] = category.rawValue
        root[ReservedPayloadKey.deepLink.rawValue] = deepLink
        root[ReservedPayloadKey.actionIds.rawValue] = category.actionIds
        root[ReservedPayloadKey.target.rawValue] = category.deepLinkTarget.rawValue
        if let approvalRequestId {
            root[ReservedPayloadKey.approvalRequestId.rawValue] = approvalRequestId
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard data.count <= 4096 else {
            throw APNSPushError.payloadTooLarge(bytes: data.count)
        }
        return data
    }

    public func encodedJSONString() throws -> String {
        String(decoding: try encodedJSON(), as: UTF8.self)
    }

    private static func truncated(_ value: String) -> String {
        if value.count <= 160 { return value }
        return String(value.prefix(157)) + "..."
    }
}

public struct PushPayloadBuilder: Sendable {
    public struct AgentContext: Sendable {
        public var tileId: UUID
        public var title: String
        public var detail: String
        public var approvalRequestId: String?

        public init(tileId: UUID, title: String, detail: String, approvalRequestId: String? = nil) {
            self.tileId = tileId
            self.title = title
            self.detail = detail
            self.approvalRequestId = approvalRequestId
        }
    }

    public static func approvalRequested(_ context: AgentContext) -> PushPayload {
        PushPayload(category: .approvalRequested, title: "Approval requested", body: context.detail, deepLink: deepLink(.approvalCard, tileId: context.tileId, approvalRequestId: context.approvalRequestId), approvalRequestId: context.approvalRequestId, userInfo: ["tileId": context.tileId.uuidString])
    }

    public static func agentWaitingForInput(_ context: AgentContext) -> PushPayload {
        PushPayload(category: .agentWaitingForInput, title: "Agent waiting for input", body: context.detail, deepLink: deepLink(.agentDetail, tileId: context.tileId), userInfo: ["tileId": context.tileId.uuidString])
    }

    public static func agentFinished(_ context: AgentContext) -> PushPayload {
        PushPayload(category: .agentFinished, title: "Agent finished", body: context.detail, deepLink: deepLink(.agentDetail, tileId: context.tileId), userInfo: ["tileId": context.tileId.uuidString])
    }

    public static func agentFailed(_ context: AgentContext) -> PushPayload {
        PushPayload(category: .agentFailed, title: "Agent failed", body: "The agent run failed.", deepLink: deepLink(.agentDetail, tileId: context.tileId), userInfo: ["tileId": context.tileId.uuidString])
    }

    public static func stillWorkingDigest(_ context: AgentContext) -> PushPayload {
        PushPayload(category: .stillWorkingDigest, title: "Still working", body: context.detail, deepLink: deepLink(.agentsBoard, tileId: context.tileId), userInfo: ["tileId": context.tileId.uuidString])
    }

    public static func desktopConnectionChanged(_ context: AgentContext) -> PushPayload {
        PushPayload(category: .desktopConnectionChanged, title: "Desktop connection changed", body: context.detail, deepLink: deepLink(.statusFooter, tileId: context.tileId), userInfo: ["tileId": context.tileId.uuidString])
    }

    public static func deviceSecurityChanged(_ context: AgentContext) -> PushPayload {
        PushPayload(category: .deviceSecurityChanged, title: "Device security changed", body: context.detail, deepLink: "\(PairingURL.scheme)://devices", userInfo: ["tileId": context.tileId.uuidString])
    }

    public static func sessionReapedOrRevived(_ context: AgentContext) -> PushPayload {
        PushPayload(category: .sessionReapedOrRevived, title: "Session changed", body: context.detail, deepLink: deepLink(.agentDetail, tileId: context.tileId), userInfo: ["tileId": context.tileId.uuidString])
    }

    public static func fixturePayload(for category: PushCategory, hostileRuntimeError: String = "") throws -> PushPayload {
        let tile = UUID(uuidString: "00000000-0000-4000-8000-000000000063")!
        let long = "This is a deliberately long notification body for the APNS payload builder table. It must truncate cleanly at one hundred sixty characters without leaking runtime data or transcript material."
        let context = AgentContext(tileId: tile, title: category.rawValue, detail: category == .agentFailed ? hostileRuntimeError : long, approvalRequestId: "approval-fixture")
        switch category {
        case .approvalRequested: return approvalRequested(context)
        case .agentWaitingForInput: return agentWaitingForInput(context)
        case .agentFinished: return agentFinished(context)
        case .agentFailed: return agentFailed(context)
        case .stillWorkingDigest: return stillWorkingDigest(context)
        case .desktopConnectionChanged: return desktopConnectionChanged(context)
        case .deviceSecurityChanged: return deviceSecurityChanged(context)
        case .sessionReapedOrRevived: return sessionReapedOrRevived(context)
        }
    }

    private static func deepLink(_ target: PushDeepLinkTarget, tileId: UUID, approvalRequestId: String? = nil) -> String {
        switch target {
        case .approvalCard:
            return "\(PairingURL.scheme)://approval/\(approvalRequestId ?? "")?tileId=\(tileId.uuidString)"
        case .agentDetail:
            return "\(PairingURL.scheme)://agent/\(tileId.uuidString)"
        case .agentsBoard:
            return "\(PairingURL.scheme)://agents"
        case .statusFooter:
            return "\(PairingURL.scheme)://status"
        case .devices:
            return "\(PairingURL.scheme)://devices"
        }
    }
}

public struct PushIdentity: Hashable, Sendable {
    public var tileId: UUID
    public var status: AgentStatus
    public var approvalRequestId: String?
    public var summary: String

    public init(tileId: UUID, status: AgentStatus, approvalRequestId: String?, summary: String) {
        self.tileId = tileId
        self.status = status
        self.approvalRequestId = approvalRequestId
        self.summary = summary
    }
}

private struct PushPublishedIdentity: Hashable, Sendable {
    var category: PushCategory
    var identity: PushIdentity
}

public struct PushCandidate: Sendable {
    public let payload: PushPayload
    public let identity: PushIdentity
    public var category: PushCategory { payload.category }

    init(payload: PushPayload, identity: PushIdentity) {
        self.payload = payload
        self.identity = identity
    }
}

public struct PushFiringRuleTable: Sendable {
    public init() {}

    public func classify(previous: AgentStatus, event: AgentActivityEvent) -> PushCandidate? {
        let category: PushCategory
        if event.tone == .error {
            category = .agentFailed
        } else if event.status == .needsAttention, event.approvalRequestId != nil {
            category = .approvalRequested
        } else if event.status == .needsAttention {
            category = .agentWaitingForInput
        } else if event.status == .done {
            category = .agentFinished
        } else {
            return nil
        }

        if event.tone != .error, previous == event.status, category != .approvalRequested, category != .agentWaitingForInput {
            return nil
        }

        let context = PushPayloadBuilder.AgentContext(tileId: event.tileId, title: event.kind, detail: event.summary, approvalRequestId: event.approvalRequestId)
        let payload: PushPayload
        switch category {
        case .approvalRequested: payload = PushPayloadBuilder.approvalRequested(context)
        case .agentWaitingForInput: payload = PushPayloadBuilder.agentWaitingForInput(context)
        case .agentFinished: payload = PushPayloadBuilder.agentFinished(context)
        case .agentFailed: payload = PushPayloadBuilder.agentFailed(context)
        case .stillWorkingDigest, .desktopConnectionChanged, .deviceSecurityChanged, .sessionReapedOrRevived:
            return nil
        }
        return PushCandidate(payload: payload, identity: PushIdentity(tileId: event.tileId, status: event.status, approvalRequestId: event.approvalRequestId, summary: payload.body))
    }
}

public enum APNSEnvironment: String, Sendable {
    case sandbox
    case production

    public var host: String {
        switch self {
        case .sandbox: return "api.sandbox.push.apple.com"
        case .production: return "api.push.apple.com"
        }
    }
}

public struct APNSConfig: Equatable, Sendable {
    public var keyPath: String
    public var keyId: String
    public var teamId: String
    public var deviceToken: String?
    public var environment: APNSEnvironment

    public init(keyPath: String, keyId: String, teamId: String, deviceToken: String?, environment: APNSEnvironment = .production) {
        self.keyPath = keyPath
        self.keyId = keyId
        self.teamId = teamId
        self.deviceToken = deviceToken
        self.environment = environment
    }
}

public enum APNSEnvLoader {
    public static func defaultURL(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent(".continuum/apns.env")
    }

    public static func load(from url: URL = defaultURL(), homeDirectory: String = NSHomeDirectory(), defaultEnvironment: APNSEnvironment = .production) -> APNSConfig? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, homeDirectory: homeDirectory, defaultEnvironment: defaultEnvironment)
    }

    public static func parse(_ text: String, homeDirectory: String, defaultEnvironment: APNSEnvironment = .production) -> APNSConfig? {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value.replacingOccurrences(of: "$HOME", with: homeDirectory)
        }
        guard let keyPath = values["CONTINUUM_APNS_KEY_PATH"], !keyPath.isEmpty,
              let keyId = values["CONTINUUM_APNS_KEY_ID"], !keyId.isEmpty,
              let teamId = values["CONTINUUM_APPLE_TEAM_ID"], !teamId.isEmpty else {
            return nil
        }
        let environment = values["CONTINUUM_APNS_ENV"].flatMap(APNSEnvironment.init(rawValue:)) ?? defaultEnvironment
        return APNSConfig(keyPath: keyPath, keyId: keyId, teamId: teamId, deviceToken: values["CONTINUUM_APNS_DEVICE_TOKEN"], environment: environment)
    }
}

public enum APNSPushError: Error, Equatable, Sendable {
    case payloadTooLarge(bytes: Int)
    case invalidURL
    case missingPrivateKey
}

public struct APNSJWTSigner: Sendable {
    private let teamId: String
    private let keyId: String
    private let privateKey: P256.Signing.PrivateKey

    public init(teamId: String, keyId: String, privateKey: P256.Signing.PrivateKey) {
        self.teamId = teamId
        self.keyId = keyId
        self.privateKey = privateKey
    }

    public init(config: APNSConfig) throws {
        let pem = try String(contentsOfFile: config.keyPath, encoding: .utf8)
        try self.init(teamId: config.teamId, keyId: config.keyId, pemRepresentation: pem)
    }

    public init(teamId: String, keyId: String, pemRepresentation: String) throws {
        self.teamId = teamId
        self.keyId = keyId
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pemRepresentation)
    }

    public static func ephemeralForChecks(teamId: String, keyId: String) -> APNSJWTSigner {
        APNSJWTSigner(teamId: teamId, keyId: keyId, privateKey: P256.Signing.PrivateKey())
    }

    public func sign(issuedAt: Date = Date()) throws -> String {
        let header: [String: Any] = ["alg": "ES256", "kid": keyId]
        let claims: [String: Any] = ["iss": teamId, "iat": Int(issuedAt.timeIntervalSince1970)]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let signingInput = base64URLEncode(headerData) + "." + base64URLEncode(claimsData)
        let signature = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + base64URLEncode(signature)
    }

    public func verifies(_ jwt: String) throws -> Bool {
        let parts = jwt.split(separator: ".").map(String.init)
        guard parts.count == 3 else { return false }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: base64URLDecode(parts[2]))
        return privateKey.publicKey.isValidSignature(signature, for: signed)
    }
}

public func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

public func base64URLDecode(_ text: String) -> Data {
    var base64 = text
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64 += String(repeating: "=", count: padding)
    return Data(base64Encoded: base64) ?? Data()
}

public protocol APNSHTTPClient: Sendable {
    func send(_ request: URLRequest, body: Data) async throws -> APNSHTTPResponse
}

public struct APNSHTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var reason: String?

    public init(statusCode: Int, reason: String? = nil) {
        self.statusCode = statusCode
        self.reason = reason
    }

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reason = object["reason"] as? String,
              !reason.isEmpty else {
            self.reason = nil
            return
        }
        self.reason = reason
    }
}

public struct URLSessionAPNSHTTPClient: APNSHTTPClient {
    public init() {}

    public func send(_ request: URLRequest, body: Data) async throws -> APNSHTTPResponse {
        var request = request
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return APNSHTTPResponse(statusCode: status, body: data)
    }
}

public final class RecordingAPNSHTTPClient: APNSHTTPClient, @unchecked Sendable {
    public private(set) var requests: [(request: URLRequest, body: Data)] = []
    private var responses: [APNSHTTPResponse]

    public init(statuses: [Int]) {
        self.responses = statuses.map { APNSHTTPResponse(statusCode: $0) }
    }

    public init(responses: [APNSHTTPResponse]) {
        self.responses = responses
    }

    public func send(_ request: URLRequest, body: Data) async throws -> APNSHTTPResponse {
        requests.append((request, body))
        if responses.isEmpty {
            return APNSHTTPResponse(statusCode: 200)
        }
        return responses.removeFirst()
    }
}

public enum APNSPublishOutcome: Equatable, Sendable, CustomStringConvertible {
    case sent(statusCode: Int)
    case deduplicated
    case noConfig
    case noDeviceToken
    case categoryDisabled
    case tokenExpired
    case providerTokenExpired
    case failed(statusCode: Int)

    public var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .sent(let statusCode): return "sent(\(statusCode))"
        case .deduplicated: return "deduplicated"
        case .noConfig: return "noConfig"
        case .noDeviceToken: return "noDeviceToken"
        case .categoryDisabled: return "categoryDisabled"
        case .tokenExpired: return "tokenExpired"
        case .providerTokenExpired: return "providerTokenExpired"
        case .failed(let statusCode): return "failed(\(statusCode))"
        }
    }
}

public actor APNSPushService {
    private let config: APNSConfig?
    private let httpClient: any APNSHTTPClient
    private let preferences: any PushCategoryPreferences
    private let injectedSigner: APNSJWTSigner?
    private var lastPublished: [UUID: PushPublishedIdentity] = [:]

    public init(config: APNSConfig? = APNSEnvLoader.load(), httpClient: any APNSHTTPClient = URLSessionAPNSHTTPClient(), preferences: any PushCategoryPreferences = PersistedPushCategoryPreferences(), signer: APNSJWTSigner? = nil) {
        self.config = config
        self.httpClient = httpClient
        self.preferences = preferences
        self.injectedSigner = signer
    }

    public func publish(payload: PushPayload) async throws -> APNSPublishOutcome {
        try await publish(payload: payload, identity: Self.identity(derivedFrom: payload))
    }

    private func publish(payload: PushPayload, identity: PushIdentity) async throws -> APNSPublishOutcome {
        guard let config else {
            print("APNS push skipped: no apns.env config")
            return .noConfig
        }
        guard let token = config.deviceToken, !token.isEmpty else {
            print("APNS push skipped: no device token configured")
            return .noDeviceToken
        }
        let category = payload.category
        if category.isMuteable, !preferences.isEnabled(category) {
            return .categoryDisabled
        }
        let publishedIdentity = PushPublishedIdentity(category: category, identity: identity)
        if lastPublished[identity.tileId] == publishedIdentity {
            return .deduplicated
        }
        let jwt = try (injectedSigner ?? APNSJWTSigner(config: config)).sign()
        let urlString = "https://\(config.environment.host)/3/device/\(token)"
        guard let url = URL(string: urlString) else { throw APNSPushError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue("dev.dylanreedx.continuum", forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        let response = try await httpClient.send(request, body: try payload.encodedJSON())
        switch response.statusCode {
        case 200:
            lastPublished[identity.tileId] = publishedIdentity
            return .sent(statusCode: 200)
        case 410:
            return .tokenExpired
        case 403 where response.reason == "ExpiredProviderToken":
            return .providerTokenExpired
        default:
            return .failed(statusCode: response.statusCode)
        }
    }

    private static func identity(derivedFrom payload: PushPayload) -> PushIdentity {
        let tileId = payload.userInfo["tileId"].flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
        return PushIdentity(
            tileId: tileId,
            status: payload.category.identityStatus,
            approvalRequestId: payload.approvalRequestId,
            summary: payload.body
        )
    }
}

private extension PushCategory {
    var identityStatus: AgentStatus {
        switch self {
        case .approvalRequested, .agentWaitingForInput:
            return .needsAttention
        case .agentFinished, .agentFailed:
            return .done
        case .stillWorkingDigest:
            return .working
        case .desktopConnectionChanged, .deviceSecurityChanged, .sessionReapedOrRevived:
            return .idle
        }
    }
}

public struct PushApprovalResponseIntent: Equatable, Sendable {
    public var tileId: UUID
    public var requestId: String
    public var decision: ApprovalDecision

    public init(tileId: UUID, requestId: String, decision: ApprovalDecision) {
        self.tileId = tileId
        self.requestId = requestId
        self.decision = decision
    }
}

public func handlePushAction(actionId: String, userInfo: [AnyHashable: Any], grantedScope: Scope) -> PushApprovalResponseIntent? {
    let decision: ApprovalDecision
    switch actionId {
    case PushCategory.approveActionId:
        decision = .accept
    case PushCategory.denyActionId:
        decision = .decline
    default:
        return nil
    }
    guard let requestId = userInfo["approvalRequestId"] as? String,
          let tileString = userInfo["tileId"] as? String,
          let tileId = UUID(uuidString: tileString),
          (try? authorize(.respondToApproval, grantedScopes: grantedScope)) != nil else {
        return nil
    }
    return PushApprovalResponseIntent(tileId: tileId, requestId: requestId, decision: decision)
}
