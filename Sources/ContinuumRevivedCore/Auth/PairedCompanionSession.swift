import Foundation
import Security

public struct PairedCompanionSession: Codable, Equatable, Sendable {
    public var instanceId: UUID
    public var userId: UUID
    public var deviceId: UUID
    public var sessionId: UUID
    public var token: String
    public var scopes: Scope
    public var issuedAt: Date
    public var expiresAt: Date

    public init(
        instanceId: UUID,
        userId: UUID,
        deviceId: UUID,
        sessionId: UUID,
        token: String,
        scopes: Scope,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.instanceId = instanceId
        self.userId = userId
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.token = token
        self.scopes = scopes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public enum PairedCompanionSessionState: Equatable, Sendable {
    case unpaired
    case paired(PairedCompanionSession)
    case expired(PairedCompanionSession)
    case revoked(PairedCompanionSession?)
    case unavailable(String)
}

public protocol PairedCompanionSessionStoring: Sendable {
    func loadState() -> PairedCompanionSessionState
    func save(_ session: PairedCompanionSession) throws
    func clear() throws
}

public final class InMemoryPairedCompanionSessionStore: PairedCompanionSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: PairedCompanionSession?

    public init(session: PairedCompanionSession? = nil) {
        self.session = session
    }

    public func loadState() -> PairedCompanionSessionState {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return .unpaired }
        return .paired(session)
    }

    public func save(_ session: PairedCompanionSession) throws {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    public func clear() throws {
        lock.lock()
        session = nil
        lock.unlock()
    }
}

public struct KeychainPairedCompanionSessionStore: PairedCompanionSessionStoring {
    private let service: String
    private let account: String

    public init(service: String = "dev.dylanreed.continuum.companion-session", account: String = "paired-session") {
        self.service = service
        self.account = account
    }

    public func loadState() -> PairedCompanionSessionState {
        var query = itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .unpaired }
        guard status == errSecSuccess,
              let data = result as? Data,
              let session = try? JSONDecoder().decode(PairedCompanionSession.self, from: data) else {
            return .unavailable(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain read failed")
        }
        return .paired(session)
    }

    public func save(_ session: PairedCompanionSession) throws {
        let data = try JSONEncoder().encode(session)
        var addQuery = itemQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(itemQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw AuthError.unknown }
            return
        }
        guard status == errSecSuccess else { throw AuthError.unknown }
    }

    public func clear() throws {
        let status = SecItemDelete(itemQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthError.unknown }
    }

    private func itemQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public struct CompanionUICapability: Equatable, Sendable {
    public var state: PairedCompanionSessionState

    public init(state: PairedCompanionSessionState) {
        self.state = state
    }

    public var scope: Scope {
        switch state {
        case .paired(let session):
            return session.scopes
        case .unpaired, .expired, .revoked, .unavailable:
            return []
        }
    }

    public var canStartTransport: Bool {
        if case .paired = state { return true }
        return false
    }

    public var canRespondToApproval: Bool {
        (try? authorize(.respondToApproval, grantedScopes: scope)) != nil
    }

    public var canEditCanvas: Bool {
        CanvasEditIntent.isEditingPermitted(scope: scope)
    }
}
