import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/55-synctransport-seam.md — "How we test it / Backend"
//
// Exercises the REAL `FakeSyncTransport` end to end with the REAL
// `ProjectStore`/`AtomicWriter` persistence layer on disk — not mocked, not a
// local fold helper. Proves ops received via the transport can be
// materialized and then persisted through the existing store without error,
// and that the persisted output is identical to what the store reads back.

private func backendFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/ContinuumRevivedSyncChecks/Fixtures", isDirectory: true)
        .appendingPathComponent(name, isDirectory: false)
}

func runSyncTransportBackendChecks() async throws {
    // Replica A "starts from" the real committed canvas.json fixture: it
    // reads the fixture's first tile and reproduces it via a createTile op
    // (the fixture itself was never produced by an op log — see the
    // ticket-06 backend check's own documented limitation — so this is the
    // faithful way to root this scenario in the real committed fixture).
    let canvasURL = backendFixtureURL("canvas.json")
    guard let canvasData = try? Data(contentsOf: canvasURL) else {
        fputs("FAIL: synctransport backend: could not read fixture \(canvasURL.path) from cwd \(FileManager.default.currentDirectoryPath)\n", stderr)
        exit(1)
    }
    let fixtureCanvas = try JSONCodec.makeCanvasDecoder().decode(CanvasState.self, from: canvasData)
    guard let seedTile = fixtureCanvas.tiles.first else {
        fputs("FAIL: synctransport backend: fixture canvas.json must contain at least one tile\n", stderr)
        exit(1)
    }

    let replicaAId = UUID(uuidString: "5EEDA000-0000-4000-8000-00000000000A")!
    let createOp = LoggedOp(
        opId: OpId(lamport: 1, replica: replicaAId),
        op: .createTile(id: seedTile.id, kind: seedTile.kind, title: seedTile.title, frame: seedTile.frame, zPosition: seedTile.zPosition)
    )
    let movedFrame = TileFrame(x: 42, y: 42, width: 300, height: 200)
    let moveOp = LoggedOp(opId: OpId(lamport: 2, replica: replicaAId), op: .setTileFrame(id: seedTile.id, frame: movedFrame))

    let transport = FakeSyncTransport(seed: 55)
    let (a, _) = await transport.makeReplica()
    let (b, _) = await transport.makeReplica()

    await transport.send(.op(createOp), from: a)
    await transport.send(.op(moveOp), from: a)
    for _ in 0..<5 { await transport.tick() }

    // `delivered(to:)` reads actor state populated synchronously inside
    // `deliver()` — by the time `tick()` above returns, both ops are
    // already recorded. No wall-clock wait needed (see SyncTransportTests.swift
    // for why a prior revision's Task+sleep drain was a real-time dependency
    // this suite must not have).
    let receivedMessages = await transport.delivered(to: b)
    expect(receivedMessages.count == 2, "synctransport backend: replica B receives exactly the createTile + setTileFrame ops via the fake, got \(receivedMessages.count)")
    let receivedOps: [LoggedOp] = receivedMessages.compactMap { if case .op(let logged) = $0 { return logged } else { return nil } }
    expect(receivedOps == [createOp, moveOp], "synctransport backend: the received ops are byte-identical to what A sent, in order")

    // On delivery, replica B materializes and persists through the REAL
    // ProjectStore (real AtomicWriter, real JSONCodec, real file system).
    let materialized = materialize(ops: receivedOps)
    expect(materialized.canvasState.tiles.count == 1, "synctransport backend: materialized canvas has exactly the one synced tile")
    expect(materialized.canvasState.tiles.first?.frame == movedFrame, "synctransport backend: the setTileFrame op won — materialized frame is the moved frame")
    expect(materialized.canvasState.tiles.allSatisfy { $0.runtimeRef == nil }, "synctransport backend: runtimeRef is nil on every materialized tile")

    let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }
    let store = ProjectStore(projectRoot: tmpRoot)
    try store.saveCanvas(materialized.canvasState)
    let loadedBack = try store.loadCanvas()

    expect(loadedBack == materialized.canvasState, "synctransport backend: ProjectStore.saveCanvas → loadCanvas round-trips the transport-delivered, materialized state byte-for-byte (struct-equal)")
    expect(loadedBack.tiles.allSatisfy { $0.runtimeRef == nil }, "synctransport backend: runtimeRef is nil on every tile in the LOADED state")

    // A fresh temp dir has no prior file, so AtomicWriter's write path never
    // has anything to back up — the backups directory must not exist at all,
    // proving the round-trip took the clean primary-write path, never the
    // backup-fallback read path.
    expect(!FileManager.default.fileExists(atPath: store.layout.backupsDirectory.path), "synctransport backend: no AtomicWriter backup fallback was triggered (backups directory was never created)")

    print("ContinuumRevivedSyncChecks passed: SyncTransport backend — createTile + setTileFrame round-trip FakeSyncTransport → materialize → real ProjectStore.saveCanvas/loadCanvas clean, runtimeRef nil throughout, no backup fallback")
}
