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
    .respondToApproval: .orchestrationRead,
    .listDevices: .accessRead,
    .pairDevice: .accessWrite,
    .revokeDevice: .accessWrite,
]

public enum AuthError: Error, Equatable, Sendable {
    case missingScope(Scope)
    case unscopedMessage(ControlMessage)
}

public func authorize(_ message: ControlMessage, grantedScopes: Scope) throws {
    guard let required = requiredScope[message] else {
        throw AuthError.unscopedMessage(message)
    }
    guard grantedScopes.contains(required) else {
        throw AuthError.missingScope(required)
    }
}
