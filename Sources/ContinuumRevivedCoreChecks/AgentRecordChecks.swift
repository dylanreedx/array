import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2A.1-agent-record.md
//
// Four properties, each with a negative test observed red before the final code
// (quoted at each check):
//   1. Codable round-trip is EXACT, including `Date` — the reason the record has
//      hand-written Codable at all.
//   2. A payload missing the newer optional fields still decodes (decode-forward).
//   3. `tileId == nil` is valid and is a view binding, not identity.
//   4. I5: the taint scanner FLAGS an encoded record, proving it is host-bound
//      and must never be published across the sync boundary.

func runAgentRecordChecks() {
    runAgentRecordRoundTripCheck()
    runAgentRecordForwardCompatCheck()
    runAgentRecordHeadlessTileBindingCheck()
    runAgentRecordSyncBoundaryTaintWitness()
    print("AgentRecord checks: exact Date round-trip, decode-forward, headless view binding, and I5 taint witness passed")
}

private func makeAgentRecordFixture(
    cwd: String = "/Users/qa/Documents/personal/continuum",
    tileId: UUID? = UUID(uuidString: "2A100000-0000-4000-8000-000000000009")!,
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 806_000_000.25),
    lastActivityAt: Date = Date(timeIntervalSinceReferenceDate: 806_000_123.75)
) -> AgentRecord {
    AgentRecord(
        id: AgentID(rawValue: UUID(uuidString: "2A100000-0000-4000-8000-000000000001")!),
        displayName: "Refactor the sidebar",
        role: "implementer",
        // Sourced from P0.10's single source of truth rather than re-typed, so
        // the fixture cannot drift from the id the app actually spawns with.
        model: AgentModelConfig.defaultModel,
        thinking: AgentModelConfig.defaultThinking,
        cwd: cwd,
        worktreeBranch: "agents/refactor-the-sidebar",
        projectId: UUID(uuidString: "2A100000-0000-4000-8000-000000000002")!,
        parentAgentID: AgentID(rawValue: UUID(uuidString: "2A100000-0000-4000-8000-000000000003")!),
        createdAt: createdAt,
        lastActivityAt: lastActivityAt,
        tileId: tileId
    )
}

// 1 · Round-trip. The Date half is the load-bearing one and is swept over REAL
// `Date()` values, not canned ones: `AgentActivityEvent` records that ~49% of
// `Date()` values fail `Date(timeIntervalSince1970: d.timeIntervalSince1970) == d`,
// so a single canned interval (which is exactly representable) would pass with
// the lossy spelling. The sweep is what makes the negative test bite.
// NEGATIVE TEST (observed red): encoding `createdAt` as
// `createdAt.timeIntervalSince1970` and decoding via `Date(timeIntervalSince1970:)`
// → "FAIL: AgentRecord round-trip is exact for real Date() values — 100 of 200
// differed". The canned fixture above passed that same edit, which is exactly why
// the sweep exists.
private func runAgentRecordRoundTripCheck() {
    let encoder = JSONCodec.makeEncoder()
    let decoder = JSONCodec.makeDecoder()

    let fixture = makeAgentRecordFixture()
    guard let data = try? encoder.encode(fixture),
          let decoded = try? decoder.decode(AgentRecord.self, from: data)
    else {
        fputs("FAIL: AgentRecord fixture failed to encode/decode\n", stderr)
        Foundation.exit(1)
    }
    expect(decoded == fixture, "AgentRecord Codable round-trip preserves every field")
    expect(decoded.createdAt == fixture.createdAt && decoded.lastActivityAt == fixture.lastActivityAt,
           "AgentRecord round-trip preserves both Dates exactly")

    var driftedDates = 0
    var sweptDates = 0
    for offset in 0..<200 {
        let now = Date().addingTimeInterval(TimeInterval(offset) * 0.001)
        let record = makeAgentRecordFixture(createdAt: now, lastActivityAt: now)
        guard let data = try? encoder.encode(record),
              let decoded = try? decoder.decode(AgentRecord.self, from: data)
        else {
            fputs("FAIL: AgentRecord failed to round-trip a real Date() value\n", stderr)
            Foundation.exit(1)
        }
        sweptDates += 1
        if decoded.createdAt != now || decoded.lastActivityAt != now {
            driftedDates += 1
        }
    }
    expect(sweptDates == 200, "AgentRecord Date sweep ran every case; got \(sweptDates)")
    expect(driftedDates == 0,
           "AgentRecord round-trip is exact for real Date() values — \(driftedDates) of \(sweptDates) differed")

    // The id's wire form is a bare UUID string, not a wrapper object, so an
    // `AgentID` key is readable in a persisted record and re-typing an existing
    // `UUID` field as `AgentID` is not a format break.
    // NEGATIVE TEST (observed red): deleting `AgentID`'s single-value Codable
    // → "FAIL: AgentID encodes as a bare UUID, not a wrapper object — got
    //    {"rawValue":"2A100000-0000-4000-8000-000000000001"}".
    guard let idData = try? encoder.encode(fixture.id),
          let idText = String(data: idData, encoding: .utf8)
    else {
        fputs("FAIL: AgentID failed to encode\n", stderr)
        Foundation.exit(1)
    }
    expect(idText == "\"2A100000-0000-4000-8000-000000000001\"",
           "AgentID encodes as a bare UUID, not a wrapper object — got \(idText)")
}

// 2 · Decode-forward, both directions of drift: a payload written by an older
// build (no newer optional keys) decodes, and a payload written by a NEWER build
// (an unknown key) decodes rather than throwing.
// NEGATIVE TESTS (both observed red): `role` decoded with `decode` instead of
// `decodeIfPresent` → "FAIL: AgentRecord decodes a payload missing every newer
// optional field: keyNotFound(CodingKeys(stringValue: "role" …"; and
// `schemaVersion` decoded as `AgentRecord.currentSchemaVersion` instead of read
// off the payload → "FAIL: AgentRecord carries a newer schemaVersion through
// rather than clamping it — got 1".
private func runAgentRecordForwardCompatCheck() {
    let decoder = JSONCodec.makeDecoder()

    // Exactly the non-optional keys, and nothing else.
    let minimal = """
    {
      "schemaVersion": 1,
      "id": "2A100000-0000-4000-8000-000000000011",
      "displayName": "Minimal",
      "model": "openai-codex/gpt-5.6-sol",
      "thinking": "medium",
      "cwd": "/Users/qa/minimal",
      "createdAtReferenceInterval": 806000000.25,
      "lastActivityAtReferenceInterval": 806000001.5
    }
    """
    do {
        let decoded = try decoder.decode(AgentRecord.self, from: Data(minimal.utf8))
        expect(decoded.role == nil && decoded.worktreeBranch == nil && decoded.projectId == nil
                && decoded.parentAgentID == nil && decoded.tileId == nil,
               "AgentRecord decodes absent optional fields as nil")
        expect(decoded.createdAt == Date(timeIntervalSinceReferenceDate: 806_000_000.25),
               "AgentRecord decodes createdAt from the reference interval")
    } catch {
        fputs("FAIL: AgentRecord decodes a payload missing every newer optional field: \(error)\n", stderr)
        Foundation.exit(1)
    }

    // A record written by a NEWER build must still load: a key this build has
    // never heard of must not be fatal, and neither must a higher schemaVersion
    // (decode-forward means the version travels through, not that it is pinned).
    let fromTheFuture = """
    {
      "schemaVersion": 2,
      "id": "2A100000-0000-4000-8000-000000000012",
      "displayName": "From a newer build",
      "model": "openai-codex/gpt-5.6-sol",
      "thinking": "high",
      "cwd": "/Users/qa/future",
      "createdAtReferenceInterval": 806000000.25,
      "lastActivityAtReferenceInterval": 806000001.5,
      "settledOverride": "snoozed"
    }
    """
    do {
        let decoded = try decoder.decode(AgentRecord.self, from: Data(fromTheFuture.utf8))
        expect(decoded.displayName == "From a newer build",
               "AgentRecord ignores an unknown future key rather than throwing")
        expect(decoded.schemaVersion == 2,
               "AgentRecord carries a newer schemaVersion through rather than clamping it — got \(decoded.schemaVersion)")
    } catch {
        fputs("FAIL: AgentRecord rejected a payload carrying an unknown future key: \(error)\n", stderr)
        Foundation.exit(1)
    }

    expect(AgentRecord.currentSchemaVersion == 1,
           "AgentRecord schemaVersion starts at 1; got \(AgentRecord.currentSchemaVersion)")
}

// 3 · `tileId` is a VIEW BINDING, not identity. Two things are asserted, because
// only together do they say it: a headless record (`tileId == nil`) is valid AND
// round-trips with the key ABSENT rather than as an explicit null; and rebinding
// or clearing the tile leaves `id` untouched, so the same agent survives losing
// its view.
// NEGATIVE TEST (observed red): `encodeIfPresent(tileId …)` changed to
// `encode(tileId …)` → "FAIL: a headless AgentRecord omits the tileId key
// entirely — got {"tileId":null …".
private func runAgentRecordHeadlessTileBindingCheck() {
    let encoder = JSONCodec.makeEncoder()
    let decoder = JSONCodec.makeDecoder()

    let headless = makeAgentRecordFixture(tileId: nil)
    guard let data = try? encoder.encode(headless),
          let text = String(data: data, encoding: .utf8),
          let decoded = try? decoder.decode(AgentRecord.self, from: data)
    else {
        fputs("FAIL: a headless AgentRecord failed to round-trip\n", stderr)
        Foundation.exit(1)
    }
    expect(!text.contains("tileId"),
           "a headless AgentRecord omits the tileId key entirely — got \(text)")
    expect(decoded == headless && decoded.tileId == nil,
           "a headless AgentRecord (tileId == nil) is valid and round-trips")

    var agent = makeAgentRecordFixture()
    let identity = agent.id
    agent.tileId = UUID(uuidString: "2A100000-0000-4000-8000-0000000000AA")!
    expect(agent.id == identity, "rebinding tileId does not change the agent's id")
    agent.tileId = nil
    expect(agent.id == identity, "closing the tile (tileId = nil) does not change the agent's id")
    expect(agent == makeAgentRecordFixture(tileId: nil),
           "an agent that lost its tile equals its own headless form — the tile is one view, not the entity")
}

// 4 · I5 witness. `AgentRecord` is host-bound: encode it, walk the wire form
// with the Core taint scanner, and it MUST be flagged — that is the property
// that makes publishing one a detectable mistake rather than a silent leak on
// somebody else's device.
//
// Asserted by pattern AND key path, not just "some violation": a record flagged
// for the wrong reason (say a pid-shaped integer) would otherwise pass this
// check while saying nothing about the host path.
//
// `SyncPayloadTaintScanner` recognises a host path by PREFIX, so the witness
// sweeps EVERY prefix it knows rather than the one shape a `/Users/` fixture
// happens to have — a scanner that only ever saw one of the four would report a
// worktree under `/var/folders/` (P2C's temp roots) as clean.
//
// HONEST LIMIT, recorded rather than papered over: because that set is finite, a
// cwd outside it (`/tmp/...`, below) is NOT flagged, and the discriminating case
// is here to make that visible instead of implied. So this check is a BACKSTOP
// for the common case, not a proof of the invariant. The invariant is that
// nothing publishes this type; P2A.2 owns the store that must uphold it, and a
// publisher-side guard belongs there, not in a file this packet names.
// NEGATIVE TESTS (both observed red): swapping the `/Users/` root for
// `/tmp/continuum-qa` → "FAIL: an AgentRecord with cwd /tmp/continuum-qa is
// flagged host-bound by the taint scanner — found []"; and dropping the
// `/var/folders/` root from the sweep → "FAIL: the I5 witness swept every
// host-path prefix the scanner knows; got 3". Recorded honestly: the more obvious edit —
// dropping `cwd` from `AgentRecord.encode(to:)` — is red too, but at check 1
// ("round-trip preserves every field"), not here, so it does not witness THIS
// assertion.
private func runAgentRecordSyncBoundaryTaintWitness() {
    let encoder = JSONCodec.makeEncoder()

    let hostRoots = [
        "/Users/qa/Documents/personal/continuum",
        "/home/qa/continuum",
        "~/continuum",
        "/var/folders/3s/qqwk1k6n6dq40lmvnzh/T/continuum-worktree-1",
    ]
    var witnessedRoots = 0
    for cwd in hostRoots {
        let record = makeAgentRecordFixture(cwd: cwd)
        guard let data = try? encoder.encode(record),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            fputs("FAIL: AgentRecord failed to encode for the taint witness\n", stderr)
            Foundation.exit(1)
        }
        let violations = taintCheck(json)
        expect(violations.contains { $0.keyPath == "cwd" && $0.pattern == .hostLocalPath },
               "an AgentRecord with cwd \(cwd) is flagged host-bound by the taint scanner — found \(violations)")
        expect(violations.count == 1,
               "the host path is the ONLY thing the scanner flags in an AgentRecord — found \(violations)")
        witnessedRoots += 1
    }
    // Floored at 4 = the scanner's four host prefixes, so shrinking the sweep is
    // red rather than quietly narrowing what the witness covers.
    expect(witnessedRoots == 4,
           "the I5 witness swept every host-path prefix the scanner knows; got \(witnessedRoots)")

    let notAHostPath = makeAgentRecordFixture(cwd: "/tmp/continuum-qa")
    guard let cleanData = try? encoder.encode(notAHostPath),
          let cleanJson = try? JSONSerialization.jsonObject(with: cleanData)
    else {
        fputs("FAIL: AgentRecord failed to encode for the discriminating taint case\n", stderr)
        Foundation.exit(1)
    }
    expect(taintCheck(cleanJson).isEmpty,
           "the taint flag comes from the host path itself, not from the record's shape")
}
