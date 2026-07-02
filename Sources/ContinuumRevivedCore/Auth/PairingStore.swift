import Foundation

public enum PairingGrantUses: Equatable, Sendable {
    case singleUse
    case unbounded
}

public struct PairingGrant: Equatable, Sendable {
    public var id: UUID
    public var credential: String
    public var scopes: Scope
    public var label: String
    public var expiresAt: Date?
    public var remainingUses: PairingGrantUses

    public init(
        id: UUID,
        credential: String,
        scopes: Scope,
        label: String,
        expiresAt: Date?,
        remainingUses: PairingGrantUses
    ) {
        self.id = id
        self.credential = credential
        self.scopes = scopes
        self.label = label
        self.expiresAt = expiresAt
        self.remainingUses = remainingUses
    }
}

public actor PairingStore {
    private struct Record: Sendable {
        var grant: PairingGrant
        var consumedAt: Date?
        var revokedAt: Date?
    }

    private let clock: any Clock
    private let bootstrapGrant: BootstrapGrant?
    private var records: [String: Record] = [:]

    public init(clock: any Clock = SystemClock(), bootstrapGrant: BootstrapGrant? = nil) {
        self.clock = clock
        self.bootstrapGrant = bootstrapGrant
    }

    public func issue(scopes: Scope, ttl: TimeInterval, label: String) throws -> PairingGrant {
        let credential = try AuthRandom.pairingCredential()
        let grant = PairingGrant(
            id: UUID(),
            credential: credential,
            scopes: scopes,
            label: label,
            expiresAt: clock.now().addingTimeInterval(ttl),
            remainingUses: .singleUse
        )
        records[credential] = Record(grant: grant, consumedAt: nil, revokedAt: nil)
        return grant
    }

    public func revoke(id: UUID) {
        let now = clock.now()
        for key in records.keys {
            if records[key]?.grant.id == id {
                records[key]?.revokedAt = now
            }
        }
    }

    public func consume(_ credential: String) throws -> PairingGrant {
        if let bootstrapGrant, credential == bootstrapGrant.credential {
            return PairingGrant(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000054")!,
                credential: credential,
                scopes: bootstrapGrant.scopes,
                label: "bootstrap",
                expiresAt: nil,
                remainingUses: .unbounded
            )
        }

        guard var record = records[credential] else { throw AuthError.unknown }
        let now = clock.now()
        if record.revokedAt != nil { throw AuthError.revoked }
        if record.consumedAt != nil { throw AuthError.alreadyUsed }
        if let expiresAt = record.grant.expiresAt, expiresAt <= now { throw AuthError.expired }

        record.consumedAt = now
        records[credential] = record
        return record.grant
    }
}
