import Foundation

// Ticket: docs/38-tickets/12-injectable-substrates.md
//
// RULING (2026-07-01, see docs/38-tickets/12-injectable-substrates.md): ticket 02
// already shipped `OpId` and `LoggedOp { opId; op: Op }` in SpatialOp.swift. This
// ticket reuses ticket 02's `OpId` verbatim (no re-declaration) and names its own
// op-agnostic transport envelope `TransportLoggedOp` to avoid colliding with ticket
// 02's typed `LoggedOp`. The two coexist: `LoggedOp` carries a typed `Op` for the
// spatial fold; `TransportLoggedOp` carries an opaque `payload` the transport never
// inspects. Fields match SYNC-MODEL.md:294-318 verbatim (modulo the rename) so a
// future `ContinuumRevivedSync` target can re-home this without a rename.
//
// The transport is deliberately op-agnostic: it sorts/dedupes by `opId` and never
// references the spatial `Op` enum.
public struct TransportLoggedOp: Codable, Sendable, Equatable {
    public var opId: OpId
    public var payload: Data

    public init(opId: OpId, payload: Data) {
        self.opId = opId
        self.payload = payload
    }
}
