import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/02-op-enum-logged-op-envelope.md
// Logic (pure Core) checks for OpId, Op, LoggedOp, FracIndex, and
// JSONCodec.makeOpLogEncoder(). All in-process, no daemon, no network,
// no wall clock.

private func allOpCases() -> [Op] {
    let id1 = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let id2 = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let frame = TileFrame(x: 10, y: 20, width: 300, height: 400)
    let origin = ZonePoint(x: 5, y: 6)
    let size = ZoneSize(width: 100, height: 200)
    return [
        .createTile(id: id1, kind: .terminal, title: "shell", frame: frame, zPosition: .fromLegacyRank(3)),
        .deleteTile(id: id1),
        .createZone(id: id1, projectId: id2, origin: origin, size: size, name: "zone", color: "#ff0000"),
        .createZone(id: id1, projectId: nil, origin: origin, size: size, name: "ambient", color: "#00ff00"),
        .deleteZone(id: id1),
        .setTileFrame(id: id1, frame: frame),
        .setTileZIndex(id: id1, z: FracIndex(value: 0.875)),
        .setTileTitle(id: id1, title: "renamed"),
        .setTileKind(id: id1, kind: .note),
        .setTileCollapsed(id: id1, collapsed: true),
        .setZoneOrigin(id: id1, origin: origin),
        .setZoneSize(id: id1, size: size),
        .setZoneName(id: id1, name: "zone name"),
        .setZoneColor(id: id1, color: "#0000ff"),
        .setZoneCollapsed(id: id1, collapsed: false),
        .setZoneProjectId(id: id1, projectId: id2),
        .setZoneProjectId(id: id1, projectId: nil),
        .setZonePosition(id: id1, position: FracIndex(value: 0.5)),
        .setTileZone(tileId: id1, zoneId: id2),
        .setTileZone(tileId: id1, zoneId: nil),
        .setLastActiveTile(id: id1),
        .setLastActiveTile(id: nil),
        .setLastActiveZone(id: id1),
        .setLastActiveZone(id: nil)
    ]
}

/// I5 structural scan: encode an `Op` and confirm the raw bytes contain none
/// of the tokens that would indicate host-local/tainted data leaked into the
/// sync boundary. Returns the scanned byte count for the manifest line.
private func scanForBannedTokens(_ op: Op) -> Int {
    let data = try! JSONCodec.makeOpLogEncoder().encode(op)
    let string = String(data: data, encoding: .utf8)!
    let bannedTokens = [
        "runtimeRef", "%", "/Users/", "continuum-", "ssh://",
        "command", "args", "env", "scrollback"
    ]
    for token in bannedTokens {
        expect(!string.contains(token), "I5 scan found banned token '\(token)' in encoded Op: \(string)")
    }
    return data.count
}

func runSpatialOpTests() {
    // MARK: Round-trip (I7) — every Op case, exhaustive switch.
    let cases = allOpCases()
    var totalScannedBytes = 0
    for op in cases {
        let encoded = try! JSONCodec.makeOpLogEncoder().encode(op)
        let decoded = try! JSONCodec.makeDecoder().decode(Op.self, from: encoded)
        expect(decoded == op, "Op round-trip mismatch for \(op)")

        // Exhaustive switch: if a new Op case is added and this switch is
        // not updated, this fails to compile (the correct failure mode).
        switch op {
        case .createTile, .deleteTile, .createZone, .deleteZone,
             .setTileFrame, .setTileZIndex, .setTileTitle, .setTileKind, .setTileCollapsed,
             .setZoneOrigin, .setZoneSize, .setZoneName, .setZoneColor, .setZoneCollapsed,
             .setZoneProjectId, .setZonePosition, .setTileZone,
             .setLastActiveTile, .setLastActiveZone:
            break
        }

        // Backend stand-in (data-layer ticket): Op round-trips through real
        // Data bytes; the disk/teardown real-path lives in the
        // convergence-fuzz ticket.
        totalScannedBytes += scanForBannedTokens(op)
    }
    print("I5 op-enum scan: \(cases.count) cases, 0 forbidden tokens, taint:none (\(totalScannedBytes) bytes scanned)")

    // MARK: Frozen-discriminator fixture decode (wire-format drift guard)
    let fixedId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let fixedZone = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    // Wire amendment (ticket 04, pre-transport): createTile carries zPosition
    // (FracIndex) instead of the legacy Int zIndex; setTileZIndex carries z
    // (FracIndex). Amended while zero producers/consumers/persisted op logs
    // exist — see the Op enum doc comment.
    let createTileFixture = """
    {"createTile":{"frame":{"height":400,"width":300,"x":10,"y":20},"id":"11111111-1111-4111-8111-111111111111","kind":"terminal","title":"shell","zPosition":0.75}}
    """
    let decodedCreateTile = try! JSONCodec.makeDecoder().decode(Op.self, from: Data(createTileFixture.utf8))
    expect(
        decodedCreateTile == .createTile(id: fixedId, kind: .terminal, title: "shell", frame: TileFrame(x: 10, y: 20, width: 300, height: 400), zPosition: FracIndex(value: 0.75)),
        "createTile fixture decode mismatch"
    )

    // A pre-amendment payload (Int "zIndex") must fail LOUDLY (keyNotFound),
    // never silently misread.
    let legacyCreateTileFixture = """
    {"createTile":{"frame":{"height":400,"width":300,"x":10,"y":20},"id":"11111111-1111-4111-8111-111111111111","kind":"terminal","title":"shell","zIndex":3}}
    """
    do {
        _ = try JSONCodec.makeDecoder().decode(Op.self, from: Data(legacyCreateTileFixture.utf8))
        expect(false, "decoding the pre-amendment createTile payload (Int zIndex) must throw, not succeed")
    } catch {
        // expected: loud failure, no silent misread
    }

    let setTileZIndexFixture = """
    {"setTileZIndex":{"id":"11111111-1111-4111-8111-111111111111","z":0.875}}
    """
    let decodedSetTileZIndex = try! JSONCodec.makeDecoder().decode(Op.self, from: Data(setTileZIndexFixture.utf8))
    expect(
        decodedSetTileZIndex == .setTileZIndex(id: fixedId, z: FracIndex(value: 0.875)),
        "setTileZIndex fixture decode mismatch"
    )

    let legacySetTileZIndexFixture = """
    {"setTileZIndex":{"id":"11111111-1111-4111-8111-111111111111","zIndex":3}}
    """
    do {
        _ = try JSONCodec.makeDecoder().decode(Op.self, from: Data(legacySetTileZIndexFixture.utf8))
        expect(false, "decoding the pre-amendment setTileZIndex payload (Int zIndex) must throw, not succeed")
    } catch {
        // expected: loud failure, no silent misread
    }

    let setTileFrameFixture = """
    {"setTileFrame":{"frame":{"height":400,"width":300,"x":10,"y":20},"id":"11111111-1111-4111-8111-111111111111"}}
    """
    let decodedSetTileFrame = try! JSONCodec.makeDecoder().decode(Op.self, from: Data(setTileFrameFixture.utf8))
    expect(
        decodedSetTileFrame == .setTileFrame(id: fixedId, frame: TileFrame(x: 10, y: 20, width: 300, height: 400)),
        "setTileFrame fixture decode mismatch"
    )

    let setTileZoneFixture = """
    {"setTileZone":{"tileId":"11111111-1111-4111-8111-111111111111","zoneId":"22222222-2222-4222-8222-222222222222"}}
    """
    let decodedSetTileZone = try! JSONCodec.makeDecoder().decode(Op.self, from: Data(setTileZoneFixture.utf8))
    expect(
        decodedSetTileZone == .setTileZone(tileId: fixedId, zoneId: fixedZone),
        "setTileZone fixture decode mismatch"
    )

    let unknownDiscriminatorFixture = """
    {"setTileFrobnicate":{"id":"11111111-1111-4111-8111-111111111111"}}
    """
    do {
        _ = try JSONCodec.makeDecoder().decode(Op.self, from: Data(unknownDiscriminatorFixture.utf8))
        expect(false, "decoding an unknown Op discriminator should throw, not succeed")
    } catch {
        // expected
    }

    // MARK: OpId ordering
    let replicaA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    let replicaB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    expect(replicaA.uuidString < replicaB.uuidString, "test fixture assumption: replicaA sorts before replicaB")

    expect(OpId(lamport: 1, replica: replicaA) < OpId(lamport: 2, replica: replicaA), "lower lamport sorts first at same replica")
    expect(OpId(lamport: 2, replica: replicaA) < OpId(lamport: 2, replica: replicaB), "same lamport breaks tie by replica id")

    let shuffled = [
        OpId(lamport: 2, replica: replicaB),
        OpId(lamport: 1, replica: replicaB),
        OpId(lamport: 2, replica: replicaA),
        OpId(lamport: 1, replica: replicaA)
    ]
    let expectedOrder = [
        OpId(lamport: 1, replica: replicaA),
        OpId(lamport: 1, replica: replicaB),
        OpId(lamport: 2, replica: replicaA),
        OpId(lamport: 2, replica: replicaB)
    ]
    expect(shuffled.sorted() == expectedOrder, "OpId total order over a shuffled array")

    // MARK: FracIndex invariants
    expect(FracIndex.between(FracIndex(value: 0.25), FracIndex(value: 0.75)).value == 0.5, "between(0.25, 0.75) should be the exact midpoint 0.5")

    // Boundary anchors are concrete in-interval values, not sentinels.
    expect(FracIndex.first.value == 0.25, "FracIndex.first must be exactly 0.25")
    expect(FracIndex.last.value == 0.75, "FracIndex.last must be exactly 0.75")

    // Prepend rule: inserting before the current lowest item x uses
    // between(.first, x), and the result sorts strictly before x and
    // strictly after .first.
    let existingLowest = FracIndex(value: 0.4)
    let prepended = FracIndex.between(.first, existingLowest)
    expect(prepended > FracIndex.first && prepended < existingLowest, "prepend via between(.first, x) must land strictly between .first and x")

    // Append rule: inserting after the current highest item x uses
    // between(x, .last), and the result sorts strictly after x and
    // strictly before .last.
    let existingHighest = FracIndex(value: 0.6)
    let appended = FracIndex.between(existingHighest, .last)
    expect(appended > existingHighest && appended < FracIndex.last, "append via between(x, .last) must land strictly between x and .last")

    // between(.first, .first) must trap in debug (precondition), not
    // silently return .first. A Swift `precondition` isn't catchable
    // in-process, so re-exec this same executable with a hook env var and
    // assert the child crashes (abnormal termination), not a clean exit.
    do {
        let executablePath = CommandLine.arguments[0]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.environment = ["CRCC_TRAP_TEST": "FracIndex.between.equal"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try! process.run()
        process.waitUntilExit()
        let crashed = process.terminationStatus != 0 || process.terminationReason == .uncaughtSignal
        expect(crashed, "between(.first, .first) must trap (precondition) instead of returning a value")
    }

    let fracEncoded = try! JSONCodec.makeEncoder().encode(FracIndex(value: 0.3))
    let fracDecoded = try! JSONCodec.makeDecoder().decode(FracIndex.self, from: fracEncoded)
    expect(fracDecoded.value == 0.3, "FracIndex round-trips via Codable")

    let fracTable: [FracIndex] = [
        FracIndex(value: 0.1), FracIndex(value: 0.3), FracIndex(value: 0.5),
        FracIndex(value: 0.7), FracIndex(value: 0.9)
    ]
    for i in 0..<fracTable.count {
        for j in 0..<fracTable.count {
            for k in 0..<fracTable.count {
                if fracTable[i] < fracTable[j] && fracTable[j] < fracTable[k] {
                    expect(fracTable[i] < fracTable[k], "FracIndex comparability must be transitive")
                }
            }
        }
    }

    // FracIndex precision exhaustion: after N `between` calls, the result
    // stays strictly between the anchors for reasonable N (documents the
    // eventual IEEE 754 collapse point without hitting it here).
    let lo = FracIndex.first
    var hi = FracIndex.last
    for _ in 0..<40 {
        let mid = FracIndex.between(lo, hi)
        expect(mid.value > lo.value && mid.value < hi.value, "between() must stay strictly inside its bounds for reasonable N")
        hi = mid
    }

    // MARK: FracIndex hardening (ticket 04A)

    // Hashable: equal values hash equal; a Set keyed on FracIndex behaves.
    expect(
        Set([FracIndex(value: 0.5), FracIndex(value: 0.5), FracIndex(value: 0.25)]).count == 2,
        "FracIndex Hashable: duplicate values collapse in a Set"
    )

    // distribute(count:): n strictly increasing values, all inside (0, 1).
    let distributed = FracIndex.distribute(count: 7)
    expect(distributed.count == 7, "distribute(7) yields 7 positions")
    expect(FracIndex.distribute(count: 0).isEmpty, "distribute(0) yields no positions")
    for (a, b) in zip(distributed, distributed.dropFirst()) {
        expect(a < b, "distribute() must be strictly increasing")
    }
    expect(
        distributed.allSatisfy { $0.value > 0 && $0.value < 1 },
        "distribute() values all inside the open interval"
    )

    // fromLegacyRank: strictly monotonic over mixed-sign ranks, all in (0, 1).
    let legacyRanks = [-100_000, -99, -2, -1, 0, 1, 2, 3, 99, 1000, 100_000]
    let mapped = legacyRanks.map(FracIndex.fromLegacyRank)
    for (a, b) in zip(mapped, mapped.dropFirst()) {
        expect(a < b, "fromLegacyRank must preserve strict integer order")
    }
    expect(mapped.allSatisfy { $0.value > 0 && $0.value < 1 }, "fromLegacyRank values all inside (0, 1)")
    expect(
        FracIndex.fromLegacyRank(5) == FracIndex.fromLegacyRank(5),
        "fromLegacyRank is deterministic (equal ranks map to equal positions)"
    )

    // after(): 1_000 successive bring-to-fronts never leave (0, 1), are
    // nondecreasing, stay strictly increasing for at least the first 50, and
    // at precision exhaustion return the input (a tie) rather than trapping.
    var front = FracIndex(value: 0.5)
    var strictlyIncreasingPrefix = 0
    var sawExhaustionTie = false
    for i in 0..<1_000 {
        let next = FracIndex.after(front)
        expect(next.value > 0 && next.value < 1, "after() must stay inside (0, 1) at step \(i)")
        expect(next.value >= front.value, "after() must never move an item DOWN at step \(i)")
        if next.value > front.value {
            if !sawExhaustionTie { strictlyIncreasingPrefix += 1 }
        } else {
            sawExhaustionTie = true
        }
        front = next
    }
    expect(strictlyIncreasingPrefix >= 50, "after() must produce distinct positions for at least the first 50 promotions, got \(strictlyIncreasingPrefix)")
    expect(sawExhaustionTie, "1000 promotions must reach the documented precision-exhaustion tie (sort stays total via id tie-break)")

    // before(): mirror-image floor behavior.
    var back = FracIndex(value: 0.5)
    for i in 0..<1_000 {
        let next = FracIndex.before(back)
        expect(next.value > 0 && next.value < 1, "before() must stay inside (0, 1) at step \(i)")
        expect(next.value <= back.value, "before() must never move an item UP at step \(i)")
        back = next
    }

    // Tie-break determinism: identical positions sort by id, same result on
    // every pass, and swapping the ids reverses the order.
    struct ZItem { let id: UUID; let z: FracIndex }
    let idLow = UUID(uuidString: "0000000A-0000-4000-8000-000000000001")!
    let idHigh = UUID(uuidString: "0000000B-0000-4000-8000-000000000001")!
    let tie = FracIndex(value: 0.5)
    func sortedIds(_ items: [ZItem]) -> [UUID] {
        items.sorted { lhs, rhs in
            if lhs.z != rhs.z { return lhs.z > rhs.z }
            return lhs.id.uuidString > rhs.id.uuidString
        }.map(\.id)
    }
    let orderA = sortedIds([ZItem(id: idLow, z: tie), ZItem(id: idHigh, z: tie)])
    let orderB = sortedIds([ZItem(id: idHigh, z: tie), ZItem(id: idLow, z: tie)])
    expect(orderA == [idHigh, idLow] && orderA == orderB, "tied FracIndex positions must sort deterministically by id, input-order-independent")

    // MARK: LoggedOp
    let loggedOp = LoggedOp(opId: OpId(lamport: 1, replica: replicaA), op: .setTileFrame(id: fixedId, frame: TileFrame(x: 10, y: 20, width: 300, height: 400)))
    let loggedOpEncoded = try! JSONCodec.makeOpLogEncoder().encode(loggedOp)
    let loggedOpDecoded = try! JSONCodec.makeDecoder().decode(LoggedOp.self, from: loggedOpEncoded)
    expect(loggedOpDecoded == loggedOp, "LoggedOp round-trips through the op-log encoder")

    // MARK: makeOpLogEncoder canonical key order
    // 1. Byte-stable across calls.
    let data1 = try! JSONCodec.makeOpLogEncoder().encode(loggedOp)
    let data2 = try! JSONCodec.makeOpLogEncoder().encode(loggedOp)
    expect(data1 == data2, "makeOpLogEncoder must produce byte-identical output across separate encoder instances")

    // 2. Keys are actually sorted: "frame" < "id" lexicographically inside
    // the setTileFrame payload container.
    let bytesString = String(data: data1, encoding: .utf8)!
    let frameRange = bytesString.range(of: "\"frame\"")
    let idRange = bytesString.range(of: "\"id\"")
    expect(frameRange != nil && idRange != nil, "expected both 'frame' and 'id' keys present in encoded bytes")
    expect(frameRange!.lowerBound < idRange!.lowerBound, "sortedKeys must place 'frame' before 'id'")

    // 3. Same value regardless of encoder.
    let plainEncoded = try! JSONCodec.makeEncoder(prettyPrinted: false).encode(loggedOp)
    let decodedFromPlain = try! JSONCodec.makeDecoder().decode(LoggedOp.self, from: plainEncoded)
    let decodedFromOpLog = try! JSONCodec.makeDecoder().decode(LoggedOp.self, from: data1)
    expect(decodedFromPlain == loggedOp, "plain encoder round-trips to the same LoggedOp value")
    expect(decodedFromOpLog == decodedFromPlain, "both encoders decode back to equal LoggedOp values")

    print("SpatialOpTests passed")
}
