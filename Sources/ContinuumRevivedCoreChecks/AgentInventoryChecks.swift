import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedSync
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
    runCrossProjectWalkChecks()
    print("AgentInventory checks: terminal+agent union incl. headless, deterministic sequencing, I5 purity, and the cross-project walk passed")
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

// MARK: - P2B.2 · cross-project walk
//
// Ticket: docs/38-tickets/90-agent-ux/P2B.2-cross-project-walk.md
//
// Four properties of "an agent elsewhere is still an agent":
//   1. UNION ACROSS ROOTS — two project roots with one legacy
//      `ManagedAgentSessionRecord` each yield both, tagged with the project they
//      came from, and both reach the published inventory through the SAME fold
//      the companion path calls. A third root that does not exist on disk is
//      skipped, not thrown.
//   2. ORDER — the result is ordered by identity, not by registry order. The
//      fold downstream assigns sequence numbers POSITIONALLY, so a walk that
//      moved with the registry would renumber unrelated agents' events between
//      two publishes of identical state.
//   3. DEDUP — the same root reached twice (two registry entries, one path,
//      which is what re-adding a project produces) lists each agent once.
//   4. CACHE — a read inside the TTL does not touch the disk again, and the
//      first read after it does. This is the packet's "cache per wake": the
//      inbox refreshes far more often than a project gains an agent.
//
// Everything here is driven off a real temp directory through the real
// `ManagedAgentSessionStore`, because the whole ticket is about files that are
// not reachable from the active controller.

private let walkNow = Date(timeIntervalSinceReferenceDate: 806_500_000)
private let walkProjectA = UUID(uuidString: "2B200000-0000-4000-8000-0000000000A1")!
private let walkProjectB = UUID(uuidString: "2B200000-0000-4000-8000-0000000000B1")!
private let walkProjectMissing = UUID(uuidString: "2B200000-0000-4000-8000-0000000000C1")!
private let walkTileA = UUID(uuidString: "2B200000-0000-4000-8000-0000000000A2")!
private let walkTileB = UUID(uuidString: "2B200000-0000-4000-8000-0000000000B2")!
private let walkTileLate = UUID(uuidString: "2B200000-0000-4000-8000-0000000000B3")!
private let walkTileLater = UUID(uuidString: "2B200000-0000-4000-8000-0000000000B4")!

private func runCrossProjectWalkChecks() {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-cross-project-walk-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let rootA = temp.appendingPathComponent("project-a", isDirectory: true)
    let rootB = temp.appendingPathComponent("project-b", isDirectory: true)
    // Never created. A registry keeps entries for projects that have been moved
    // or deleted, and an inbox that threw on one of them would list nobody.
    let rootMissing = temp.appendingPathComponent("project-gone", isDirectory: true)

    do {
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try ManagedAgentSessionStore(projectRoot: rootA).upsert(walkRecord(tileId: walkTileA, kind: .claude, status: .running))
        try ManagedAgentSessionStore(projectRoot: rootB).upsert(walkRecord(tileId: walkTileB, kind: .codex, status: .stopped))
    } catch {
        fputs("FAIL: the cross-project walk fixture could not be written: \(error)\n", stderr)
        Foundation.exit(1)
    }

    let roots = [
        CrossProjectManagedSessionWalk.Root(projectId: walkProjectA, projectRoot: rootA),
        CrossProjectManagedSessionWalk.Root(projectId: walkProjectB, projectRoot: rootB),
        CrossProjectManagedSessionWalk.Root(projectId: walkProjectMissing, projectRoot: rootMissing),
    ]

    // P3.2: the walk is now behind the sweep, so every check below needs the
    // sweep's proof — which is the point. This one source arms them all.
    let proof = runReconciledSourceRefusalCheck(roots: roots)

    runCrossProjectWalkUnionCheck(roots: roots, proof: proof)
    runCrossProjectWalkOrderCheck(roots: roots, proof: proof)
    runCrossProjectWalkDedupCheck(rootA: rootA, proof: proof)
    runCrossProjectWalkCacheCheck(roots: roots, rootB: rootB, proof: proof)
    runReconciledSourceLateRootCheck(temp: temp)
    runReconciledSourceRootMappingCheck()
}

// MARK: - P3.2 · the listing is only readable once the sweep has committed

// Ticket: docs/38-tickets/94-sidebar-native-ux/P3.2-gated-snapshot-read.md
//
// Returns the proof the walk checks below need, so obtaining one is itself part of
// the assertion: there is no way to read a listing without a sweep having run.
private func runReconciledSourceRefusalCheck(roots: [CrossProjectManagedSessionWalk.Root]) -> ManagedSessionReconciliation.Proof {
    let source = ReconciledManagedSessionSource(ttl: 2)
    expect(!source.isReconciled,
           "a freshly constructed source has reconciled nothing — reconciliation is an explicit call, never an init side effect (§5.15)")
    expect(source.sweptRootCount == 0,
           "constructing a source sweeps no root, so a fixture that merely builds one cannot have its records rewritten under it — got \(source.sweptRootCount)")

    // THE REFUSAL. Not an empty array: a caller cannot tell `[]` from "you have no
    // agents", and treating the refusal as no-agents is the bug in a quieter form.
    var refusal: Error?
    do {
        let served = try source.records(roots: roots, now: walkNow)
        fputs("FAIL: a listing read BEFORE the sweep committed returned \(served.count) records instead of refusing — an unreconciled read is exactly what P3.1 exists to prevent, and returning [] would blank the inbox and publish an empty inventory to the phone\n", stderr)
        Foundation.exit(1)
    } catch {
        refusal = error
    }
    expect(refusal is ReconciledManagedSessionSource.NotReady,
           "the refusal is an explicit not-ready value the caller must handle — got \(String(describing: refusal))")
    expect((refusal as? ReconciledManagedSessionSource.NotReady)?.description.contains("not committed") == true,
           "the not-ready value says what it means, so a log line can explain a blank inbox — got \(String(describing: refusal))")
    do {
        _ = try source.proof()
        fputs("FAIL: the sweep's proof was mintable before any sweep ran, so the active project's own store could be listed unreconciled\n", stderr)
        Foundation.exit(1)
    } catch {
        expect(error is ReconciledManagedSessionSource.NotReady,
               "proof() refuses with the same not-ready value — got \(error)")
    }

    // Arming it. The sweep terminalizes A's `.running` record; B's is already
    // `.stopped` and is not rewritten.
    let summary: ReconciledManagedSessionSource.SweepSummary
    let proof: ManagedSessionReconciliation.Proof
    do {
        summary = try source.reconcile(roots: roots, reason: .continuumRestarted, now: walkNow)
        proof = try source.proof()
    } catch {
        fputs("FAIL: the launch sweep over three registry roots failed: \(error)\n", stderr)
        Foundation.exit(1)
    }
    expect(source.isReconciled, "the source is armed once a sweep has committed")
    expect(summary.sweptRoots == 3 && summary.alreadySweptRoots == 0,
           "the sweep visits every root once, including the one whose directory is gone — got \(summary)")
    expect(summary.terminalized == 1,
           "exactly the one record claiming liveness is terminalized (A running; B already stopped) — got \(summary)")
    expect(roots.allSatisfy { source.hasReconciled($0) },
           "every root the sweep visited is recorded as swept, so a later read does not re-stat it")

    // The refusal cached nothing: this read sees the DISK, not an empty answer
    // cached while the source was refusing (design: "TTL cache no pre-sweep serve").
    do {
        let served = try source.records(roots: roots, now: walkNow)
        expect(served.count == 2,
               "the first read after arming enumerates the disk rather than serving an answer cached during the refusal — got \(served.count)")
        expect(served.allSatisfy { $0.record.status.isTerminal },
               "a gated listing can only report records the sweep already terminalized — got \(served.map { $0.record.status.rawValue })")
        expect(served.contains { $0.record.endedReason == .continuumRestarted },
               "the swept record reached the listing with the reason it was cancelled for — got \(served.map { String(describing: $0.record.endedReason) })")
    } catch {
        fputs("FAIL: a listing read after the sweep committed still refused: \(error)\n", stderr)
        Foundation.exit(1)
    }

    let idempotent: ReconciledManagedSessionSource.SweepSummary
    do {
        idempotent = try source.reconcile(roots: roots, reason: .continuumQuit, now: walkNow.addingTimeInterval(60))
    } catch {
        fputs("FAIL: a second sweep over the same roots failed: \(error)\n", stderr)
        Foundation.exit(1)
    }
    expect(idempotent.sweptRoots == 0 && idempotent.alreadySweptRoots == 3,
           "a root swept in this process is never swept again — got \(idempotent)")
    return proof
}

/// N10's property: a root that appears AFTER the arming sweep is swept on the way
/// in, exactly once. A launch-only sweep leaves every project the human has not
/// opened yet reporting `running` off disk, and roots do appear late —
/// `WorkspaceRuntime` opens a project's controller on a workspace switch.
private func runReconciledSourceLateRootCheck(temp: URL) {
    let early = temp.appendingPathComponent("late-early", isDirectory: true)
    let late = temp.appendingPathComponent("late-appeared", isDirectory: true)
    let earlyRoot = CrossProjectManagedSessionWalk.Root(projectId: walkProjectA, projectRoot: early)
    let lateRoot = CrossProjectManagedSessionWalk.Root(projectId: walkProjectB, projectRoot: late)
    let lateTile = UUID(uuidString: "2B200000-0000-4000-8000-0000000000D1")!
    let afterTile = UUID(uuidString: "2B200000-0000-4000-8000-0000000000D2")!
    let source = ReconciledManagedSessionSource(ttl: 0)
    do {
        try FileManager.default.createDirectory(at: early, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)
        try ManagedAgentSessionStore(projectRoot: late).upsert(walkRecord(tileId: lateTile, kind: .managed, status: .running))
        // Armed on the EARLY root only — the booted project, which is all a
        // launch-time sweep can know about.
        try source.reconcile(roots: [earlyRoot], reason: .continuumRestarted, now: walkNow)
    } catch {
        fputs("FAIL: the late-root fixture could not be written: \(error)\n", stderr)
        Foundation.exit(1)
    }
    expect(!source.hasReconciled(lateRoot),
           "fixture check: the late root really has not been swept yet, or the assertion below is vacuous")

    do {
        let served = try source.records(roots: [earlyRoot, lateRoot], now: walkNow.addingTimeInterval(1))
        guard let discovered = served.first(where: { $0.record.tileId == lateTile }) else {
            fputs("FAIL: the record in the late-appearing root did not reach the listing at all — served \(served.map(\.record.tileId))\n", stderr)
            Foundation.exit(1)
        }
        expect(discovered.record.status == .cancelled,
               "a root first seen AFTER the arming sweep is swept on the way in — its record reads \(discovered.record.status.rawValue), and a launch-only sweep is what leaves it saying running")
        expect(discovered.record.endedReason == .continuumRestarted,
               "the lazily swept record carries the arming sweep's reason — got \(String(describing: discovered.record.endedReason))")
        expect(source.hasReconciled(lateRoot),
               "the late root is now recorded as swept")
    } catch {
        fputs("FAIL: the listing refused after the late root appeared: \(error)\n", stderr)
        Foundation.exit(1)
    }

    // ONCE per root, not once per read: a record written after that root was swept
    // is LIVE, and re-sweeping on every listing would cancel a running agent.
    do {
        try ManagedAgentSessionStore(projectRoot: late).upsert(walkRecord(tileId: afterTile, kind: .managed, status: .running))
        let served = try source.records(roots: [earlyRoot, lateRoot], now: walkNow.addingTimeInterval(2))
        let fresh = served.first(where: { $0.record.tileId == afterTile })
        expect(fresh?.record.status == .running,
               "a record created after its root was swept still claims liveness — the sweep is once per root, not once per read, or listing the inbox would cancel the agent you just spawned (got \(String(describing: fresh?.record.status.rawValue)))")
    } catch {
        fputs("FAIL: the post-sweep listing failed: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

/// ONE mapping from registry to roots, so the sweep and the listing cannot disagree
/// about which roots exist — a root swept under one mapping and listed under another
/// is an unswept listing with no symptom.
private func runReconciledSourceRootMappingCheck() {
    var registry = Registry.empty()
    let presentId = UUID(uuidString: "2B200000-0000-4000-8000-0000000000E1")!
    let missingId = UUID(uuidString: "2B200000-0000-4000-8000-0000000000E2")!
    registry.projects = [
        ProjectEntry(id: presentId, name: "Present", rootPath: "/tmp/continuum-present",
                     workspaceId: nil, lastOpenedAt: walkNow, pinned: false, missing: false),
        ProjectEntry(id: missingId, name: "Gone", rootPath: "/tmp/continuum-gone",
                     workspaceId: nil, lastOpenedAt: walkNow, pinned: false, missing: true),
    ]
    let roots = ReconciledManagedSessionSource.roots(in: registry)
    expect(roots.count == 2,
           "a project marked missing still contributes a root — its checkout may hold records claiming liveness, and the walk skips a path that is not there anyway (got \(roots.count))")
    expect(roots.map(\.projectId) == [presentId, missingId],
           "each root carries its project's id, which is the row context's only way back to the project — got \(roots.map(\.projectId))")
    expect(roots.first?.projectRoot.path == "/tmp/continuum-present",
           "a root's URL is its project's rootPath — got \(String(describing: roots.first?.projectRoot.path))")
}

/// The gated walk, for the four checks whose subject is the walk itself. Holding a
/// `Proof` is the whole precondition, and it can only have come from a sweep.
private func walkRecords(
    roots: [CrossProjectManagedSessionWalk.Root],
    now: Date,
    proof: ManagedSessionReconciliation.Proof
) -> [CrossProjectManagedSessionWalk.Discovered] {
    do {
        return try CrossProjectManagedSessionWalk().records(roots: roots, now: now, proof: proof)
    } catch {
        fputs("FAIL: the gated cross-project walk threw: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

private func walkRecord(tileId: UUID, kind: AgentKind, status: ManagedSessionStatus) -> ManagedAgentSessionRecord {
    ManagedAgentSessionRecord(
        tileId: tileId,
        agentKind: kind,
        status: status,
        lastSeenAt: walkNow
    )
}

/// 1 · Both projects' agents are found, tagged with their project, and reach the
/// published inventory. Only ONE of these roots can be the active project, so a
/// walk that only saw the active one would return a single entry here — which is
/// exactly today's behaviour without this ticket.
private func runCrossProjectWalkUnionCheck(roots: [CrossProjectManagedSessionWalk.Root], proof: ManagedSessionReconciliation.Proof) {
    let found = walkRecords(roots: roots, now: walkNow, proof: proof)
    expect(found.count == 2,
           "two project roots with one record each fold into 2 discovered agents, and a root that does not exist is skipped — got \(found.count)")
    expect(found.contains(where: { $0.projectId == walkProjectA && $0.record.tileId == walkTileA }),
           "the record in project A is found and tagged with project A — got \(found.map { ($0.projectId, $0.record.tileId) })")
    expect(found.contains(where: { $0.projectId == walkProjectB && $0.record.tileId == walkTileB }),
           "the record in the NON-ACTIVE project B is found and tagged with project B — got \(found.map { ($0.projectId, $0.record.tileId) })")
    expect(!found.contains(where: { $0.projectId == walkProjectMissing }),
           "a project root that no longer exists on disk contributes nothing")

    // The published inventory, through the same entry point the app's companion
    // closure calls — an agent that the walk finds but the fold drops is still
    // invisible, so the union is asserted at the payload, not at the walk alone.
    let snapshot = DegradedDesktopActivitySnapshotSource.snapshot(
        descriptors: [],
        liveStatuses: [:],
        managedAgents: found.map { discovered in
            DesktopManagedAgentActivity(
                agentId: discovered.record.tileId,
                tileId: discovered.record.tileId,
                agentKind: discovered.record.agentKind,
                status: .idle,
                updatedAt: discovered.record.lastSeenAt
            )
        },
        replicaId: inventoryReplicaId,
        now: walkNow
    )
    expect(Set(snapshot.byAgent.keys) == Set([walkTileA, walkTileB]),
           "agents from BOTH projects appear in the published inventory — got \(snapshot.byAgent.keys.sorted { $0.uuidString < $1.uuidString })")
}

/// 2 · Registry order must not reach the output.
private func runCrossProjectWalkOrderCheck(roots: [CrossProjectManagedSessionWalk.Root], proof: ManagedSessionReconciliation.Proof) {
    let forward = walkRecords(roots: roots, now: walkNow, proof: proof)
    let reversed = walkRecords(roots: roots.reversed(), now: walkNow, proof: proof)
    expect(forward == reversed,
           "the walk's order is independent of registry order — got \(forward.map(\.record.tileId)) vs \(reversed.map(\.record.tileId))")
    expect(forward.map(\.projectId) == forward.map(\.projectId).sorted { $0.uuidString < $1.uuidString },
           "the walk is ordered by project identity — got \(forward.map(\.projectId))")
}

/// 3 · One path, two registry entries — an agent is listed once.
private func runCrossProjectWalkDedupCheck(rootA: URL, proof: ManagedSessionReconciliation.Proof) {
    let duplicated = [
        CrossProjectManagedSessionWalk.Root(projectId: walkProjectA, projectRoot: rootA),
        CrossProjectManagedSessionWalk.Root(projectId: walkProjectB, projectRoot: rootA),
    ]
    let found = walkRecords(roots: duplicated, now: walkNow, proof: proof)
    expect(found.count == 1,
           "two registry entries pointing at ONE root list that root's agent once — got \(found.count)")
}

/// 4 · The cache holds for its TTL and no longer.
private func runCrossProjectWalkCacheCheck(roots: [CrossProjectManagedSessionWalk.Root], rootB: URL, proof: ManagedSessionReconciliation.Proof) {
    let walk = CrossProjectManagedSessionWalk(ttl: 2)
    func served(_ now: Date, _ walkRoots: [CrossProjectManagedSessionWalk.Root]) -> [CrossProjectManagedSessionWalk.Discovered] {
        do { return try walk.records(roots: walkRoots, now: now, proof: proof) }
        catch {
            fputs("FAIL: the gated cross-project walk threw: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
    expect(served(walkNow, roots).count == 2, "the cache check starts from the 2 agents on disk")

    // A record that appears AFTER the first read is the only way to tell a cache
    // hit from a re-read: same inputs, different disk.
    try? ManagedAgentSessionStore(projectRoot: rootB).upsert(walkRecord(tileId: walkTileLate, kind: .pi, status: .running))

    expect(served(walkNow.addingTimeInterval(1), roots).count == 2,
           "a read inside the TTL is served from cache and does not re-enumerate the disk — got \(served(walkNow.addingTimeInterval(1), roots).count)")
    expect(served(walkNow.addingTimeInterval(2), roots).count == 3,
           "the first read after the TTL sees the new agent — got \(served(walkNow.addingTimeInterval(2), roots).count)")

    // Clocks move backwards (sleep/wake, NTP). A cache entry stamped in the
    // future must not become immortal. Discriminating only because the disk
    // changed again since the read now cached: same roots, same TTL window by
    // arithmetic, so a cache hit here would report the stale 3.
    try? ManagedAgentSessionStore(projectRoot: rootB).upsert(walkRecord(tileId: walkTileLater, kind: .pi, status: .running))
    expect(served(walkNow.addingTimeInterval(-3600), roots).count == 4,
           "a backwards clock jump re-reads instead of serving a cache entry stamped in the future — got \(served(walkNow.addingTimeInterval(-3600), roots).count)")

    // A changed root set must not be served from a cache keyed on the old one.
    let narrowed = Array(roots.prefix(1))
    expect(served(walkNow.addingTimeInterval(-3600), narrowed).count == 1,
           "a different root set re-reads rather than reusing the cached answer — got \(served(walkNow.addingTimeInterval(-3600), narrowed).count)")
}
