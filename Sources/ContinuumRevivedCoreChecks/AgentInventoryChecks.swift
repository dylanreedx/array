import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2B.1-agent-inventory.md
//
// Four properties of the one derivation of "every agent":
//   1. UNION — 2 terminal sessions + 2 agents (one HEADLESS) yield 4 entries,
//      and the headless one is present with a nil tile hint. The headless case
//      is the whole reason this fold moved out of the companion closure: the
//      old enumeration filtered managed sessions by live canvas tiles, so an
//      agent with no tile could not appear at all.
//   2. DETERMINISM — the same inputs in a different array order produce an
//      identical snapshot and a byte-identical canonical encode. The phone
//      folds on `(sequence, replicaId)`, so a positional assignment that moved
//      with call order would silently reorder its timeline between publishes.
//   3. SEQUENCES — 1…N, contiguous and monotonic, terminals first.
//   4. I5 — the snapshot crosses the sync boundary; an `AgentRecord`'s `cwd`
//      and `worktreeBranch` must not travel in it, asserted with the same
//      taint scanner `AgentRecordChecks` uses plus a literal substring sweep.
//
// The companion path is NOT re-tested here: `DesktopCompanionSyncPublisherTests`
// already pins it and was deliberately left untouched, which is what makes it
// proof that promoting the fold changed no behaviour.

func runAgentInventoryChecks() {
    runAgentInventoryUnionCheck()
    runAgentInventoryDetachedHintCheck()
    runAgentInventoryDeterminismCheck()
    runAgentInventorySequenceCheck()
    runAgentInventorySyncBoundaryCheck()
    print("AgentInventory checks: terminal+agent union incl. headless, deterministic sequencing, and I5 purity passed")
}

// MARK: - Fixture

private let inventoryReplicaId = UUID(uuidString: "2B100000-0000-4000-8000-0000000000FF")!
private let inventoryNow = Date(timeIntervalSinceReferenceDate: 806_400_000)

private let terminalTileA = UUID(uuidString: "2B100000-0000-4000-8000-00000000A001")!
private let terminalTileB = UUID(uuidString: "2B100000-0000-4000-8000-00000000A002")!
private let tiledAgentId = AgentID(rawValue: UUID(uuidString: "2B100000-0000-4000-8000-00000000B001")!)
private let tiledAgentTile = UUID(uuidString: "2B100000-0000-4000-8000-00000000A003")!
private let headlessAgentId = AgentID(rawValue: UUID(uuidString: "2B100000-0000-4000-8000-00000000B002")!)

private func inventoryTerminalDescriptor(
    tileId: UUID,
    id: UUID,
    kind: AgentKind,
    status: AgentStatus
) -> TerminalSessionDescriptor {
    TerminalSessionDescriptor(
        id: id,
        tileId: tileId,
        launchProfileId: "default",
        command: "/bin/zsh",
        args: [],
        cwd: "/Users/qa/Documents/personal/continuum",
        env: [:],
        title: "terminal",
        createdAt: inventoryNow,
        lastStartedAt: inventoryNow,
        lastExit: nil,
        agentDescriptor: AgentDescriptor(
            agentKind: kind,
            worktreePath: nil,
            status: status,
            statusUpdatedAt: inventoryNow
        )
    )
}

private func inventoryAgentRecord(
    id: AgentID,
    displayName: String,
    tileId: UUID?,
    cwd: String = "/Users/qa/Documents/personal/continuum",
    worktreeBranch: String? = nil
) -> AgentRecord {
    AgentRecord(
        id: id,
        displayName: displayName,
        model: AgentModelConfig.defaultModel,
        thinking: AgentModelConfig.defaultThinking,
        cwd: cwd,
        worktreeBranch: worktreeBranch,
        createdAt: inventoryNow,
        lastActivityAt: inventoryNow.addingTimeInterval(30),
        tileId: tileId
    )
}

private struct InventoryFixture {
    var descriptors: [TerminalSessionDescriptor]
    var liveStatuses: [UUID: AgentStatus]
    var agents: [AgentRecord]
    var activityByAgent: [AgentID: [AgentActivityEventDraft]]
}

private func makeInventoryFixture(
    agentCwd: String = "/Users/qa/Documents/personal/continuum",
    worktreeBranch: String? = nil
) -> InventoryFixture {
    InventoryFixture(
        descriptors: [
            inventoryTerminalDescriptor(
                tileId: terminalTileA,
                id: UUID(uuidString: "2B100000-0000-4000-8000-00000000C001")!,
                kind: .shell,
                status: .idle
            ),
            inventoryTerminalDescriptor(
                tileId: terminalTileB,
                id: UUID(uuidString: "2B100000-0000-4000-8000-00000000C002")!,
                kind: .claude,
                status: .working
            ),
        ],
        liveStatuses: [
            terminalTileB: .working,
            headlessAgentId.rawValue: .working,
        ],
        agents: [
            inventoryAgentRecord(
                id: tiledAgentId,
                displayName: "Refactor the sidebar",
                tileId: tiledAgentTile,
                cwd: agentCwd,
                worktreeBranch: worktreeBranch
            ),
            // HEADLESS — running with no tile (P2A.6).
            inventoryAgentRecord(
                id: headlessAgentId,
                displayName: "Sweep the matrix",
                tileId: nil,
                cwd: agentCwd,
                worktreeBranch: worktreeBranch
            ),
        ],
        activityByAgent: [
            tiledAgentId: [
                AgentActivityEventDraft(
                    agentId: tiledAgentId.rawValue,
                    tileId: tiledAgentTile,
                    runId: "run-1",
                    tone: .info,
                    kind: "turn.started",
                    status: .working,
                    summary: "reading the sidebar",
                    occurredAt: inventoryNow.addingTimeInterval(10)
                ),
                AgentActivityEventDraft(
                    agentId: tiledAgentId.rawValue,
                    tileId: tiledAgentTile,
                    runId: "run-1",
                    tone: .approval,
                    kind: "needs-attention",
                    status: .needsAttention,
                    summary: "approve rm -rf?",
                    occurredAt: inventoryNow.addingTimeInterval(20),
                    approvalRequestId: "req-1"
                ),
            ],
        ]
    )
}

private func inventorySnapshot(_ fixture: InventoryFixture) -> ActivityLogSnapshot {
    AgentInventory.snapshot(
        terminalDescriptors: fixture.descriptors,
        liveStatuses: fixture.liveStatuses,
        agents: fixture.agents,
        activityByAgent: fixture.activityByAgent,
        replicaId: inventoryReplicaId,
        now: inventoryNow
    )
}

// 1 · The union, including the agent that has no tile.
// NEGATIVE TEST (observed red): skipping records with `tileId == nil` in
// `AgentInventory.snapshot` — the enumeration the old companion path effectively
// had, since it filtered managed sessions by live canvas tiles — → "FAIL: 2
// terminal + 2 agents fold into 4 inventory entries — got 3". The headless
// entry is also asserted by identity, hint, status and summary, so a fold that
// produced four entries with the wrong one missing is red too.
private func runAgentInventoryUnionCheck() {
    let snapshot = inventorySnapshot(makeInventoryFixture())

    expect(snapshot.byAgent.count == 4,
           "2 terminal + 2 agents fold into 4 inventory entries — got \(snapshot.byAgent.count)")
    for expected in [terminalTileA, terminalTileB, tiledAgentId.rawValue, headlessAgentId.rawValue] {
        expect(snapshot.byAgent[expected] != nil,
               "the inventory is keyed by agent identity and contains \(expected) — got \(Array(snapshot.byAgent.keys))")
    }

    guard let headless = snapshot.byAgent[headlessAgentId.rawValue] else {
        fputs("FAIL: a headless agent is in the inventory — \(snapshot.byAgent.count) entries: \(Array(snapshot.byAgent.keys))\n", stderr)
        Foundation.exit(1)
    }
    expect(headless.tileId == nil, "a headless agent's tile hint is nil — got \(String(describing: headless.tileId))")
    // Synthesised from `liveStatuses`, keyed by AGENT identity (the record has
    // no tile to key it by, which is the case a tile-keyed status map loses).
    expect(headless.status == .working, "a headless agent's live status is read by agent id — got \(headless.status)")
    expect(headless.lastSummary == "Sweep the matrix working",
           "the synthesised summary is the agent's display name and status — got \(headless.lastSummary)")

    guard let tiled = snapshot.byAgent[tiledAgentId.rawValue] else {
        fputs("FAIL: the tiled agent is in the inventory\n", stderr)
        Foundation.exit(1)
    }
    // Recorded events WIN over the synthetic fallback: the fallback exists only
    // for an agent that has not produced a timeline yet.
    expect(tiled.recent.count == 2, "a recorded timeline is folded in whole — got \(tiled.recent.count) event(s)")
    expect(tiled.status == .needsAttention, "status comes off the canonically-last recorded event — got \(tiled.status)")
    expect(tiled.tileId == tiledAgentTile, "a tiled agent keeps its view hint — got \(String(describing: tiled.tileId))")

    guard let terminal = snapshot.byAgent[terminalTileB] else {
        fputs("FAIL: the terminal session is in the inventory\n", stderr)
        Foundation.exit(1)
    }
    expect(terminal.status == .working, "a terminal session's live status wins over its descriptor — got \(terminal.status)")
    expect(terminal.tileId == terminalTileB,
           "a terminal session's tile id is both its identity and its hint — got \(String(describing: terminal.tileId))")
}

// 1b · A headless agent that ALREADY HAS a timeline. The check above only
// covers the synthetic-fallback half, and the two halves take different code
// paths: recorded drafts carry the tile hint they were recorded with, so an
// agent that has since detached would keep advertising a tile it no longer has
// — "Show on canvas" on the phone pointing at nothing. The record is the
// current binding and wins.
// NEGATIVE TEST (observed red): inheriting the draft's hint (`: recorded`
// instead of `: recorded.map { rebound($0, toTile: record.tileId) }`) → "FAIL: a
// detached agent's recorded events do not keep advertising the tile they were
// recorded on — got Optional(2B100000-0000-4000-8000-00000000A003)".
private func runAgentInventoryDetachedHintCheck() {
    var fixture = makeInventoryFixture()
    // The tiled agent detaches: its record loses the binding, its already-recorded
    // drafts still carry it.
    fixture.agents = fixture.agents.map { record in
        guard record.id == tiledAgentId else { return record }
        var detached = record
        detached.tileId = nil
        return detached
    }
    let snapshot = inventorySnapshot(fixture)

    guard let detached = snapshot.byAgent[tiledAgentId.rawValue] else {
        fputs("FAIL: a detached agent is still in the inventory\n", stderr)
        Foundation.exit(1)
    }
    expect(detached.tileId == nil,
           "a detached agent's recorded events do not keep advertising the tile they were recorded on — got \(String(describing: detached.tileId))")
    expect(detached.recent.allSatisfy { $0.tileId == nil },
           "every event of a detached agent is rebound, not just the canonically-last one")
    // Only the hint moves: identity, order and content are untouched.
    expect(detached.recent.map(\.kind) == ["turn.started", "needs-attention"],
           "rebinding the hint does not reorder or drop events — got \(detached.recent.map(\.kind))")
    expect(detached.status == .needsAttention && detached.lastSummary == "approve rm -rf?",
           "rebinding the hint does not change the derived status or summary")
    expect(detached.recent.allSatisfy { $0.agentId == tiledAgentId.rawValue },
           "rebinding the hint does not touch the aggregate key")
}

/// Canonical, order-free serialisation of a snapshot.
///
/// Every field the published snapshot carries — the snapshot cursor, each
/// agent's derived status / summary / updatedAt / tile hint, and every event in
/// its `recent` — with ONE thing normalised: the dictionary key type.
///
/// NOT `JSONCodec.makeEncoder().encode(snapshot)` directly. `byAgent` is a
/// `[UUID: …]` dictionary, and Swift encodes a non-String-keyed dictionary as an
/// UNKEYED array in `Dictionary` iteration order, which `.sortedKeys` cannot
/// reach — so a byte difference there could mean nothing more than two dicts
/// hashing into different bucket orders, and the check would be a flake rather
/// than a proof. Re-keyed by UUID string, `.sortedKeys` makes the encoding
/// canonical and the comparison meaningful; nothing is dropped in the process.
private struct CanonicalInventory: Encodable {
    var snapshotSequence: UInt64
    var snapshotReplicaId: UUID
    var byAgent: [String: AgentActivity]
}

private func canonicalInventoryEncoding(_ snapshot: ActivityLogSnapshot) -> Data {
    let canonical = CanonicalInventory(
        snapshotSequence: snapshot.snapshotSequence,
        snapshotReplicaId: snapshot.snapshotReplicaId,
        byAgent: Dictionary(uniqueKeysWithValues: snapshot.byAgent.map { ($0.key.uuidString, $0.value) })
    )
    let encoder = JSONCodec.makeEncoder(prettyPrinted: true)  // .sortedKeys
    guard let data = try? encoder.encode(canonical) else {
        fputs("FAIL: the inventory snapshot failed to encode\n", stderr)
        Foundation.exit(1)
    }
    return data
}

// 2 · Determinism. Same set of inputs, different array order → same snapshot.
// NEGATIVE TEST (observed red): dropping both `sorted` calls in `AgentInventory`
// and enumerating `terminalDescriptors` / `agents` as given → "FAIL: the
// inventory is independent of input array order" (the snapshots differ outright;
// the byte comparison behind it is the stricter half, and is what catches a
// difference that `Equatable` would see through).
private func runAgentInventoryDeterminismCheck() {
    let fixture = makeInventoryFixture()
    var reordered = fixture
    reordered.descriptors.reverse()
    reordered.agents.reverse()

    let first = inventorySnapshot(fixture)
    let second = inventorySnapshot(reordered)

    expect(first == second, "the inventory is independent of input array order")
    expect(canonicalInventoryEncoding(first) == canonicalInventoryEncoding(second),
           "the inventory is byte-identical for the same inputs in a different order")
    // And stable across repeated calls with the identical input, so the phone is
    // not re-sequenced by a republish of unchanged state.
    expect(canonicalInventoryEncoding(inventorySnapshot(fixture)) == canonicalInventoryEncoding(first),
           "the inventory is byte-identical when the same input is folded twice")
}

// 3 · Sequences: contiguous 1…N, terminals numbered before agents.
// NEGATIVE TEST (observed red): starting the agent loop's counter at
// `sortedDescriptors.count + 10` → "FAIL: inventory sequences are contiguous
// 1…5 — got [1, 2, 13, 14, 15]". Recorded honestly: the more obvious edit —
// starting it at 0 — is red too, but at the DETERMINISM check above, because
// colliding sequences make the canonical order itself ambiguous (its message
// alternated between the two byte assertions run to run). A gap is the edit
// that isolates THIS assertion.
private func runAgentInventorySequenceCheck() {
    let fixture = makeInventoryFixture()
    let snapshot = inventorySnapshot(fixture)
    let events = snapshot.byAgent.values.flatMap(\.recent).sorted { $0.sequence < $1.sequence }
    // 2 terminals + 2 recorded events for the tiled agent + 1 synthetic for the
    // headless one.
    let sequences = events.map(\.sequence)
    expect(sequences == [1, 2, 3, 4, 5],
           "inventory sequences are contiguous 1…5 — got \(sequences)")
    expect(snapshot.snapshotSequence == 5,
           "the snapshot sequence is the last event folded in — got \(snapshot.snapshotSequence)")

    let terminalSequences = events.filter { $0.kind == "desktop.degradedStatus" }.map(\.sequence)
    expect(terminalSequences == [1, 2],
           "terminal sessions are numbered first, in tile order — got \(terminalSequences)")
    expect(events.allSatisfy { $0.replicaId == inventoryReplicaId },
           "every event carries the host's replica id")
}

// 4 · I5. The snapshot is published to the phone; `AgentRecord` is host-bound.
// Asserted two ways because each alone is weak: the taint scanner recognises a
// host path by PREFIX (so a branch name would slip past it), and a substring
// sweep alone would pass on a scanner-flagged path shape it did not think to
// look for. The record fixture's cwd is one of the scanner's known prefixes.
// NEGATIVE TESTS (both observed red): carrying the record's cwd out on the
// synthetic draft (`runId: record.cwd`) → "FAIL: no host-bound field of an
// AgentRecord reaches the published snapshot — found [TaintViolation(keyPath:
// "byAgent[3].recent[0].runId", pattern: hostLocalPath, offendingValue:
// "/Users/qa/.../p2b1-secret")]"; and the same edit spelled
// `runId: record.worktreeBranch` → "FAIL: the published snapshot does not carry
// AgentRecord.worktreeBranch" — which the scanner does NOT flag (a branch name
// is not a path prefix), and is exactly why the substring sweep is here beside
// it. `runId` rather than `summary` on purpose: a leak through the summary is
// caught one check earlier, so it would witness the wrong assertion.
private func runAgentInventorySyncBoundaryCheck() {
    let secretCwd = "/Users/qa/Documents/personal/continuum-worktrees/p2b1-secret"
    let secretBranch = "agents/p2b1-secret-branch"
    let snapshot = inventorySnapshot(makeInventoryFixture(agentCwd: secretCwd, worktreeBranch: secretBranch))

    let encoder = JSONCodec.makeEncoder()
    guard let data = try? encoder.encode(snapshot),
          let json = try? JSONSerialization.jsonObject(with: data),
          let text = String(data: data, encoding: .utf8)
    else {
        fputs("FAIL: the inventory snapshot failed to encode for the I5 witness\n", stderr)
        Foundation.exit(1)
    }

    // Lamport sequence numbers are positional here (1…N), so they land inside
    // the scanner's pid window (2…4_194_304) — a counter and a pid are the same
    // shape. Ruling C-20260701-008 (quoted at `SyncPayloadTaintScanner`) puts
    // counts and indices outside taint, and the existing projection fixtures
    // side-step it by stamping 5_000_000, which this fold cannot do without
    // giving up positional sequencing. Excluded NARROWLY — by key path AND by
    // pattern — so any other violation, at any key, is still red.
    let violations = taintCheck(json)
    let unexpected = violations.filter {
        !($0.keyPath.lowercased().hasSuffix("sequence") && $0.pattern == .pidShapedInteger)
    }
    expect(unexpected.isEmpty,
           "no host-bound field of an AgentRecord reaches the published snapshot — found \(unexpected)")
    expect(!violations.contains { $0.pattern == .hostLocalPath },
           "no host path of any shape reaches the published snapshot — found \(violations)")
    expect(!text.contains(secretCwd),
           "the published snapshot does not carry AgentRecord.cwd")
    expect(!text.contains(secretBranch),
           "the published snapshot does not carry AgentRecord.worktreeBranch")
    // Discriminating case: the sweep is only meaningful if those strings were
    // actually in the input the fold read. A fixture that never set them would
    // pass the two assertions above while proving nothing.
    let fixture = makeInventoryFixture(agentCwd: secretCwd, worktreeBranch: secretBranch)
    guard let recordData = try? encoder.encode(fixture.agents),
          let recordText = String(data: recordData, encoding: .utf8)
    else {
        fputs("FAIL: the I5 witness fixture failed to encode\n", stderr)
        Foundation.exit(1)
    }
    expect(recordText.contains(secretCwd) && recordText.contains(secretBranch),
           "the I5 witness fed the fold records that really do carry a host path and a branch")
}
