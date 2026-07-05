import Foundation

public enum ControlMessage: String, CaseIterable, Sendable {
    case subscribeActivity
    case subscribeSpatial
    case moveTile
    case resizeTile
    case spawnTerminal
    case sendKeys
    case respondToApproval
    case listDevices
    case pairDevice
    case revokeDevice
}

public let requiredScope: [ControlMessage: Scope] = [
    .subscribeActivity: .orchestrationRead,
    .subscribeSpatial: .orchestrationRead,
    .moveTile: .orchestrationOperate,
    .resizeTile: .orchestrationOperate,
    .spawnTerminal: .orchestrationOperate,
    .sendKeys: .terminalOperate,
    .respondToApproval: .orchestrationOperate,
    .listDevices: .accessRead,
    .pairDevice: .accessWrite,
    .revokeDevice: .accessWrite,
]

public enum AuthError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknown
    case expired
    case alreadyUsed
    case revoked
    case scopeNotGranted
    case invalidToken
    case missingScope(Scope)
    case unscopedMessage(ControlMessage)

    public var description: String {
        switch self {
        case .unknown: return "unknown"
        case .expired: return "expired"
        case .alreadyUsed: return "alreadyUsed"
        case .revoked: return "revoked"
        case .scopeNotGranted: return "scopeNotGranted"
        case .invalidToken: return "invalidToken"
        case .missingScope(let scope): return "missingScope(\(scope.rawValue))"
        case .unscopedMessage(let message): return "unscopedMessage(\(message.rawValue))"
        }
    }
}

public func authorize(_ message: ControlMessage, grantedScopes: Scope) throws {
    guard let required = requiredScope[message] else {
        throw AuthError.unscopedMessage(message)
    }
    guard grantedScopes.contains(required) else {
        throw AuthError.missingScope(required)
    }
}

public func authorize(_ message: ControlMessage, session: AuthSession) throws {
    try authorize(message, grantedScopes: session.scopes)
}
