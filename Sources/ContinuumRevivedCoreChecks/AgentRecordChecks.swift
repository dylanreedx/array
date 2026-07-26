import ContinuumRevivedAgentUI
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
    // Ticket: docs/38-tickets/90-agent-ux/P4.1-lifecycle-state.md
    runAgentRecordLifecycleCheck()
    print("AgentRecord checks: exact Date round-trip, decode-forward, headless view binding, I5 taint witness, and P4.1 lifecycle persistence passed")
}

private func makeAgentRecordFixture(
    cwd: String = "/Users/qa/Documents/personal/continuum",
    tileId: UUID? = UUID(uuidString: "2A100000-0000-4000-8000-000000000009")!,
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 806_000_000.25),
    lastActivityAt: Date = Date(timeIntervalSinceReferenceDate: 806_000_123.75),
    settledOverride: SettledOverride = .default,
    settledAt: Date? = nil,
    snoozedUntil: Date? = nil,
    snoozedAt: Date? = nil,
    archivedAt: Date? = nil
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
        // P2D.6. Non-nil so the round-trip's `decoded == fixture` covers the
        // fan-out mapping: an agent that comes back from a relaunch without it
        // has nothing to check off when it finishes.
        sourceItemId: "ENG-214",
        createdAt: createdAt,
        lastActivityAt: lastActivityAt,
        tileId: tileId,
        settledOverride: settledOverride,
        settledAt: settledAt,
        snoozedUntil: snoozedUntil,
        snoozedAt: snoozedAt,
        archivedAt: archivedAt
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
                && decoded.parentAgentID == nil && decoded.tileId == nil
                && decoded.sourceItemId == nil,
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
    // P4.1 note: `settledOverride` was an unknown key when this fixture was
    // written and is a REAL one now — but `"snoozed"` is still not one of its
    // three words, so the payload keeps its meaning here (a value from a build
    // this one does not know) and the assertion below pins the tolerant read.
    do {
        let decoded = try decoder.decode(AgentRecord.self, from: Data(fromTheFuture.utf8))
        expect(decoded.displayName == "From a newer build",
               "AgentRecord ignores an unknown future key rather than throwing")
        expect(decoded.schemaVersion == 2,
               "AgentRecord carries a newer schemaVersion through rather than clamping it — got \(decoded.schemaVersion)")
        expect(decoded.settledOverride == .neutral,
               "an override word from a newer build reads as .neutral rather than throwing away the record — got \(decoded.settledOverride.rawValue)")
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

// 5 · P4.1 — the lifecycle facts persist, round-trip exactly, and default to
// "nobody has said anything". Ticket:
// docs/38-tickets/90-agent-ux/P4.1-lifecycle-state.md
//
// This is the record half of the packet's Verify line; the enum half is
// `runAgentLifecycleChecks()` in ContinuumRevivedAgentUIChecks, which cannot
// import Core and so cannot see an `AgentRecord`.
//
// Four properties:
//   a. A new record is `.neutral` with all three dates nil, and writes NO
//      lifecycle keys at all.
//   b. A record written before this ticket (no keys) decodes to exactly that —
//      the packet's named case.
//   c. Every non-default combination round-trips, dates included, over real
//      `Date()` values for the same reason check 1 sweeps them.
//   d. `archived` ≠ `settled`: the two dates are independent fields, so a row
//      that was settled and later archived remembers both.
// NEGATIVE TESTS (all observed red at exit 1 against the final code, quoted at
// their assertions).
private func runAgentRecordLifecycleCheck() {
    let encoder = JSONCodec.makeEncoder()
    let decoder = JSONCodec.makeDecoder()

    // a · the resting state, and its wire form.
    // NEGATIVE TEST (observed red): `settledOverride: SettledOverride = .settled`
    // in AgentRecord.init → "FAIL: a fresh AgentRecord has had nothing said
    // about it — got settled".
    // Built WITHOUT the lifecycle arguments rather than through the fixture:
    // the fixture forwards `settledOverride:` explicitly (it has to, so the
    // other cases below can set it), which would mask a changed default in
    // `AgentRecord.init`. Measured — the first spelling of this check passed
    // against `settledOverride: SettledOverride = .settled` in the initialiser.
    let fresh = AgentRecord(
        id: AgentID(rawValue: UUID(uuidString: "2A100000-0000-4000-8000-000000000031")!),
        displayName: "Nobody has ruled on this",
        model: AgentModelConfig.defaultModel,
        thinking: AgentModelConfig.defaultThinking,
        cwd: "/Users/qa/fresh",
        createdAt: Date(timeIntervalSinceReferenceDate: 806_000_000.25),
        lastActivityAt: Date(timeIntervalSinceReferenceDate: 806_000_123.75))
    expect(fresh.settledOverride == .neutral,
           "a fresh AgentRecord has had nothing said about it — got \(fresh.settledOverride.rawValue)")
    expect(fresh.settledAt == nil && fresh.snoozedUntil == nil && fresh.snoozedAt == nil
            && fresh.archivedAt == nil,
           "a fresh AgentRecord carries no lifecycle dates")

    // NEGATIVE TEST (observed red): dropping the `!= .default` guard in
    // `encode(to:)` → "FAIL: a record nobody has ruled on writes no lifecycle
    // keys at all — got …"settledOverride":"neutral"…".
    guard let freshData = try? encoder.encode(fresh),
          let freshText = String(data: freshData, encoding: .utf8)
    else {
        fputs("FAIL: a fresh AgentRecord failed to encode\n", stderr)
        Foundation.exit(1)
    }
    for key in ["settledOverride", "settledAtReferenceInterval",
                "snoozedUntilReferenceInterval", "snoozedAtReferenceInterval",
                "archivedAtReferenceInterval"] {
        expect(!freshText.contains(key),
               "a record nobody has ruled on writes no lifecycle keys at all — got \(freshText)")
    }

    // b · a record written BEFORE this ticket. Byte-for-byte the payload P2A.1
    // wrote, so this is the real pre-P4.1 shape rather than a re-encode of
    // today's type.
    // NEGATIVE TESTS, reported where they actually landed rather than where I
    // expected them. `decodeIfPresent` → `decode` for `settledOverride` alone is
    // red at CHECK 1 ("FAIL: AgentRecord fixture failed to encode/decode"),
    // because a `.neutral` record omits the key — so it does not witness THIS
    // assertion. The edit that does is BOTH halves at once (always encode the
    // override, and require it on the way in), which keeps check 1 green and is
    // red at "FAIL: AgentRecord decodes a payload missing every newer optional
    // field: DecodingError.keyNotFound: Key 'settledOverride' not found …" —
    // P2A.1's own decode-forward fixture, one assertion ahead of the pre-P4.1
    // payload below, which is the same property caught one step earlier.
    let beforeThisTicket = """
    {
      "schemaVersion": 1,
      "id": "2A100000-0000-4000-8000-000000000021",
      "displayName": "Written before P4.1",
      "model": "openai-codex/gpt-5.6-sol",
      "thinking": "medium",
      "cwd": "/Users/qa/before",
      "createdAtReferenceInterval": 806000000.25,
      "lastActivityAtReferenceInterval": 806000001.5
    }
    """
    do {
        let decoded = try decoder.decode(AgentRecord.self, from: Data(beforeThisTicket.utf8))
        expect(decoded.settledOverride == .neutral,
               "a record written before P4.1 defaults to .neutral — got \(decoded.settledOverride.rawValue)")
        expect(decoded.settledAt == nil && decoded.snoozedUntil == nil && decoded.snoozedAt == nil
                && decoded.archivedAt == nil,
               "a record written before P4.1 has no lifecycle dates")
    } catch {
        fputs("FAIL: a record written before P4.1 still decodes: \(error)\n", stderr)
        Foundation.exit(1)
    }

    // c · every non-default value round-trips, dates included. The sweep uses
    // real `Date()` values, not canned ones: a canned interval is exactly
    // representable and would pass the lossy `timeIntervalSince1970` spelling
    // the packet warns about.
    // NEGATIVE TEST (observed red): switching all three lifecycle dates to
    // `timeIntervalSince1970` on BOTH sides — the spelling that looks correct
    // and is not — → "FAIL: AgentRecord round-trips every lifecycle date
    // exactly — 104 of 200 differed", and 93 and 107 on two further runs. That
    // ~half is the floating-point drift the reference interval exists to avoid,
    // and it is why the sweep uses real `Date()` values: the canned fixtures
    // elsewhere in this function are exactly representable and stay green under
    // the same edit.
    var driftedLifecycle = 0
    var sweptLifecycle = 0
    for offset in 0..<200 {
        let now = Date().addingTimeInterval(TimeInterval(offset) * 0.001)
        let override = SettledOverride.allCases[offset % SettledOverride.allCases.count]
        let record = makeAgentRecordFixture(
            settledOverride: override,
            settledAt: now,
            snoozedUntil: now.addingTimeInterval(1_800),
            // P4.6's schema addition, swept with the other three: the newness
            // test compares failures against this date, so drift on reload
            // would move the line between "already seen" and "new".
            snoozedAt: now.addingTimeInterval(-60),
            archivedAt: now.addingTimeInterval(3_600))
        guard let data = try? encoder.encode(record),
              let decoded = try? decoder.decode(AgentRecord.self, from: data)
        else {
            fputs("FAIL: an AgentRecord carrying lifecycle state failed to round-trip\n", stderr)
            Foundation.exit(1)
        }
        sweptLifecycle += 1
        if decoded != record { driftedLifecycle += 1 }
        expect(decoded.settledOverride == override,
               "the stored override survives the round-trip — wrote \(override.rawValue), read \(decoded.settledOverride.rawValue)")
    }
    expect(sweptLifecycle == 200, "the lifecycle sweep ran every case; got \(sweptLifecycle)")
    expect(driftedLifecycle == 0,
           "AgentRecord round-trips every lifecycle date exactly — \(driftedLifecycle) of \(sweptLifecycle) differed")

    // The pin is persisted as its own word, not folded into the default on the
    // way out — an `.active` record that reloaded as `.neutral` would be
    // auto-settled by P4.3 on the next sweep, which is the exact failure the
    // tri-state exists to prevent.
    let pinned = makeAgentRecordFixture(settledOverride: .active)
    guard let pinnedData = try? encoder.encode(pinned),
          let pinnedText = String(data: pinnedData, encoding: .utf8),
          let reloadedPin = try? decoder.decode(AgentRecord.self, from: pinnedData)
    else {
        fputs("FAIL: a pinned AgentRecord failed to round-trip\n", stderr)
        Foundation.exit(1)
    }
    expect(pinnedText.contains("\"settledOverride\":\"active\""),
           "a keep-active pin is written as its own word — got \(pinnedText)")
    expect(reloadedPin.settledOverride == .active,
           "a keep-active pin survives a reload — got \(reloadedPin.settledOverride.rawValue)")

    // d · archived ≠ settled. Settled stays in the list; archived leaves it. Two
    // independent fields, so a row that was settled on Monday and archived on
    // Tuesday remembers both dates rather than overwriting one with the other.
    // NEGATIVE TEST (observed red): `archivedAt` encoded to
    // `.settledAtReferenceInterval` — the two fields collapsed into one key.
    // Red three runs out of three, at the SWEEP above rather than here ("FAIL:
    // AgentRecord round-trips every lifecycle date exactly — 200 of 200
    // differed"), because the sweep sets both dates and so meets the collapse
    // first. Recorded where it lands, not where it was aimed.
    let settledOn = Date(timeIntervalSinceReferenceDate: 806_100_000.5)
    let archivedOn = Date(timeIntervalSinceReferenceDate: 806_186_400.75)
    let both = makeAgentRecordFixture(
        settledOverride: .settled, settledAt: settledOn, archivedAt: archivedOn)
    guard let bothData = try? encoder.encode(both),
          let reloaded = try? decoder.decode(AgentRecord.self, from: bothData)
    else {
        fputs("FAIL: a settled-then-archived AgentRecord failed to round-trip\n", stderr)
        Foundation.exit(1)
    }
    expect(reloaded.settledAt == settledOn && reloaded.archivedAt == archivedOn,
           "settling and archiving are two facts, not one — settledAt \(String(describing: reloaded.settledAt)) archivedAt \(String(describing: reloaded.archivedAt))")
    expect(reloaded.snoozedUntil == nil,
           "a settled-then-archived record was never snoozed")

    // A snooze reaches into the FUTURE, unlike the other two, and that is not a
    // decode error to be clamped away.
    let wakesAt = Date().addingTimeInterval(86_400)
    // P4.6. The two halves of a snooze: when it ENDS and when it was SET. Both
    // are stored, because the early-wake rule compares a failure against the
    // second one — `snoozedUntil` cannot stand in for it, and a snooze whose
    // moment was lost on reload would wake on everything it had already seen.
    let setAt = Date().addingTimeInterval(-120)
    let snoozed = makeAgentRecordFixture(snoozedUntil: wakesAt, snoozedAt: setAt)
    guard let snoozedData = try? encoder.encode(snoozed),
          let reloadedSnooze = try? decoder.decode(AgentRecord.self, from: snoozedData)
    else {
        fputs("FAIL: a snoozed AgentRecord failed to round-trip\n", stderr)
        Foundation.exit(1)
    }
    expect(reloadedSnooze.snoozedUntil == wakesAt,
           "a wake-up time in the future round-trips unchanged")
    // NEGATIVE TEST (observed red): `snoozedAt` encoded to
    // `.snoozedUntilReferenceInterval` — the two halves collapsed into one key,
    // which is the mistake a fourth date beside a similarly-named third invites.
    expect(reloadedSnooze.snoozedAt == setAt && reloadedSnooze.snoozedUntil != reloadedSnooze.snoozedAt,
           "when a snooze was set and when it ends are two facts — snoozedAt \(String(describing: reloadedSnooze.snoozedAt)) snoozedUntil \(String(describing: reloadedSnooze.snoozedUntil))")
    expect(reloadedSnooze.settledOverride == .neutral,
           "snoozing is not settling — the override is untouched by a snooze")

    // I5, restated for the new fields: they are dates and a word, so the taint
    // scanner still flags exactly one thing in this record — the host path. A
    // lifecycle field that ever carried a path or a note would break this.
    guard let taintData = try? encoder.encode(both),
          let taintJson = try? JSONSerialization.jsonObject(with: taintData)
    else {
        fputs("FAIL: a lifecycle-carrying AgentRecord failed to encode for the taint witness\n", stderr)
        Foundation.exit(1)
    }
    expect(taintCheck(taintJson).count == 1,
           "the lifecycle fields add nothing for the taint scanner to flag — found \(taintCheck(taintJson))")
}
