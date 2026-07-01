# Taint scan for sync-boundary purity

## What this delivers

After this ticket lands, the project has a running core check that serializes every type
that can appear in a synced spatial payload or a projected activity payload, then walks the
resulting data and asserts that no pid, pane target, host-local handle, or transcript body
ever appears in it. If the check passes you have a machine-verified guarantee — not a code
review, not a convention — that the sync boundary is clean. If it fails the check process
exits non-zero, exactly like a type error: the invariant is enforced continuously, not just
at review time.

The human-visible outcome is the same as for the convergence guarantee: it is a safety
property the user never directly sees, but whose absence would eventually corrupt the fleet
picture on a second device or leak session internals into a cloud-synced payload. The check
running green on every commit is the proof that the architecture's most important boundary
is intact.

## How it fits

The **sync/observation type split ticket** (the preceding foundation work) defines two
disjoint type families. On the sync side, the **op enum & logged-op envelope ticket**
defines a closed `Op` enum whose cases can only carry tile positions, zone membership,
z-order, and tombstones, wrapped in a `LoggedOp` envelope. On the observation side, the
type-split ticket defines an `AgentActivityEvent` struct whose fields carry only derived
metadata. That type split makes sync-boundary purity *structurally* close to guaranteed —
but "structurally close" and "actually proven" are different things. A type system is
defeated the moment someone adds an `Any`-typed payload field, an opaque `Data` blob, or a
`[String: String]` dictionary that happens to carry a pid as a value. The taint scan is the
machine that catches exactly those cases.

This ticket depends directly on the **sync/observation type split ticket** and the **op
enum & logged-op envelope ticket**, which together define the payload types whose encoded
representations are scanned here. It does not depend on any transport, any real CloudKit
record, or any running agent — the check is purely about the shape of what *would* be sent,
not about an actual network transaction.

The taint scan unblocks the transport work (the **SyncTransport seam ticket** and the
**CloudKit transport implementation ticket**) with confidence: before any real bytes travel
over CloudKit, the taint check has already proven that no op or activity event carries
forbidden content. It also unblocks the **activity projection over transport ticket** and
the **iOS observer app ticket**, both of which are predicated on the guarantee that the
projection payload is clean enough to ship to a second device. The **invariant spine harness
ticket** wires this check into the matrix so every subsequent ticket in the program inherits
the gate automatically — that wiring is that ticket's job, not this one's (see the "How we
test it" note on the manifest).

## The approach

Serialize a representative population of `LoggedOp` values (one wrapping each `Op` case:
create-tile, set-tile-frame, set-tile-zone membership, set-zone-position z-order,
delete-tile tombstone, and the rest) and `AgentActivityEvent` values (each tone, each
status, with summary strings that are intentionally terse) using the same `JSONEncoder` that
the real transport will use. Then walk the resulting JSON trees with a recursive taint
scanner that looks for any string value matching a set of forbidden patterns, and any
integer value that falls in a plausible pid range. Assert that the scanner finds nothing.
This is the complete approach — no partial credit, no "mostly clean," no exclusions.

The forbidden-pattern set is precise and closed:

- **Pid-shaped integers:** any integer in the range `2 ... 4_194_304` (the macOS PID ceiling
  at 22-bit) appearing as a JSON number value.
- **Pane-target strings:** any string that matches `^%\d+$` (the tmux `%pane_id` format).
- **Host-local path strings:** any string that begins with `/Users/`, `/home/`, `~/`, or
  `/var/folders/` — the prefixes that characterize per-host filesystem paths.
- **Transcript bodies:** any string longer than 512 characters. The metadata fields that
  legitimately appear in a payload (`summary`, `kind`) are all short by design. A string
  longer than 512 characters is structurally inconsistent with the allowed fields and is the
  signature of a transcript body leaking in.

The scanner is itself a pure Swift function: `func taintCheck(_ value: Any) -> [TaintViolation]`,
where `Any` is the result of `JSONSerialization.jsonObject(with:)` applied to the encoded
payload. It recurses into dictionaries and arrays. Each violation carries the JSON key path
where it was found and the matched pattern, so a failure message is immediately actionable.

The population of test payloads is constructed in the check harness. The check does not try
to fuzz-generate every possible encoding; it constructs one instance per `Op` case and one
per `AgentActivityEvent` configuration, encodes each independently, and scans each. The
construction uses literal UUIDs and fixed-string values so the check is fully deterministic
— no randomness, no clock dependency.

## Where it lives

The taint scanner itself lives in `Sources/ContinuumRevivedCore/` as a new file,
`SyncPayloadTaintScanner.swift`. It is pure Foundation (no AppKit, no network), so it
belongs in Core where it can also be called from future transport-layer defensive checks.
Its public surface is small: one struct (`TaintViolation`), one enum (`TaintPattern`), and
one free function (`taintCheck`).

The check harness that exercises the scanner lives in
`Sources/ContinuumRevivedCoreChecks/main.swift`, alongside every other core check in the
project. That file already contains the `expect` helper (defined at the top of the file) and
the pattern of running discrete labeled check blocks in `do` scopes. The new block follows
that exact pattern.

The types being scanned are defined by the dependency tickets and live in
`Sources/ContinuumRevivedCore/`:

- `Op`, `LoggedOp`, `OpId`, and `FracIndex` are in `SpatialOp.swift` (created by the op enum
  & logged-op envelope ticket).
- `AgentActivityEvent` and `ActivityEventTone` are in `AgentActivityEvent.swift` (created by
  the sync/observation type split ticket).

The taint scanner does not import those types by referencing their internals; it operates on
the encoded JSON data that the transport would actually transmit. This is intentional:
encoding then scanning tests the *wire representation*, not the Swift value, which is the
only representation that matters for the guarantee. (The harness does construct instances of
those types to encode them — so it depends on the types existing — but the scanner function
is type-agnostic.)

The existing `AgentStatus` enum is at `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85`
(six cases: `configuring`, `working`, `idle`, `needsAttention`, `done`, `stale`) — it is the
status vocabulary `AgentActivityEvent.status` uses, so the harness enumerates all six. The
`AtomicWriter` at `Sources/ContinuumRevivedCore/AtomicWriter.swift` is context for the
persistence primitive the activity store uses, but it is not a dependency of this ticket.

## Confirming the dependency shapes before you build

The breadcrumbs below construct concrete instances of `Op`, `LoggedOp`, and
`AgentActivityEvent`. Those instances must match the types **as they actually shipped** in
the two dependency tickets. Before writing the harness, open `SpatialOp.swift` and
`AgentActivityEvent.swift` and read the real definitions — case labels, associated-value
names, and field names — then adjust the constructor calls below to match. The shapes below
reflect the dependency tickets' locked designs, but the code is the source of truth: if a
case was renamed or a field added, follow the code, not this prose.

The two shapes the breadcrumbs assume (from the dependency tickets' locked designs):

- `Op` is a closed enum with cases including `createTile(id:kind:title:frame:zIndex:)`,
  `deleteTile(id:)`, `setTileFrame(id:frame:)`, `setTileZone(tileId:zoneId:)`,
  `setZonePosition(id:position:)`. `LoggedOp` wraps it as `{ opId: OpId, op: Op }` where
  `OpId` is `{ lamport: UInt64, replica: UUID }`.
- `AgentActivityEvent` has exactly these stored fields: `sequence: UInt64`,
  `replicaId: UUID`, `tileId: UUID`, `runId: String?`, `tone: ActivityEventTone`,
  `kind: String`, `status: AgentStatus`, `summary: String`, `occurredAt: Date`. The tone
  type is `ActivityEventTone` with four cases: `info`, `tool`, `approval`, `error`.

If either dependency file does not exist yet, stop — see the note at the end of this ticket.

## Implementation breadcrumbs

The following pseudo-code steers the correct pattern. It is not a verbatim implementation;
the real code will have fuller Swift syntax and access modifiers, and the constructor calls
must be reconciled against the shipped dependency types (see the section above).

```swift
// Sources/ContinuumRevivedCore/SyncPayloadTaintScanner.swift

public struct TaintViolation: Equatable, Sendable {
    public let keyPath: String        // e.g. "byTile.uuid.summary"
    public let pattern: TaintPattern
    public let offendingValue: String // truncated to 200 chars for readability
}

public enum TaintPattern: String, Equatable, Sendable {
    case pidShapedInteger             // Int in 2...4_194_304
    case paneTargetString             // matches ^%\d+$
    case hostLocalPath                // begins with /Users/, /home/, ~/, /var/folders/
    case transcriptBody               // String.count > 512
}

/// Walk any JSON-deserialized tree (Dictionary, Array, String, NSNumber, NSNull)
/// and return every taint violation found.
public func taintCheck(_ value: Any, keyPath: String = "") -> [TaintViolation] {
    switch value {
    case let dict as [String: Any]:
        return dict.flatMap { key, child in
            taintCheck(child, keyPath: keyPath.isEmpty ? key : "\(keyPath).\(key)")
        }
    case let array as [Any]:
        return array.enumerated().flatMap { idx, child in
            taintCheck(child, keyPath: "\(keyPath)[\(idx)]")
        }
    case let str as String:
        var violations: [TaintViolation] = []
        if str.count > 512 {
            violations.append(.init(keyPath: keyPath, pattern: .transcriptBody,
                                    offendingValue: String(str.prefix(200))))
        }
        if str.range(of: #"^%\d+$"#, options: .regularExpression) != nil {
            violations.append(.init(keyPath: keyPath, pattern: .paneTargetString,
                                    offendingValue: str))
        }
        let hostPrefixes = ["/Users/", "/home/", "~/", "/var/folders/"]
        if hostPrefixes.contains(where: { str.hasPrefix($0) }) {
            violations.append(.init(keyPath: keyPath, pattern: .hostLocalPath,
                                    offendingValue: String(str.prefix(200))))
        }
        return violations
    case let num as NSNumber:
        // GUARD FIRST: a UInt64 sequence/lamport value can exceed Int.max. Calling
        // intValue on it truncates on 32-bit and is meaningless on 64-bit. If it is
        // bigger than Int.max it cannot be a pid, so return clean early. This guard is
        // mandatory — the "Watch out for" section explains why.
        if num.uint64Value > UInt64(Int.max) {
            return []
        }
        let i = num.intValue
        if i >= 2 && i <= 4_194_304 && !isKnownSafeInteger(i) {
            return [.init(keyPath: keyPath, pattern: .pidShapedInteger,
                          offendingValue: "\(i)")]
        }
        return []
    default:
        return []
    }
}

// Safe integers are those that appear legitimately in the payload for non-pid
// reasons. Start with an empty set (return false). If a legitimate Int in
// 2...4_194_304 ever appears in a real payload, model it explicitly here with a
// documented reason — never widen the scanner's pid range to hide it.
private func isKnownSafeInteger(_ i: Int) -> Bool { false }
```

```swift
// Inside Sources/ContinuumRevivedCoreChecks/main.swift — new block

// MARK: - Sync-boundary purity taint scan

do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    // ── Spatial ops ──────────────────────────────────────────────────────
    // Construct one LoggedOp per Op case. Use fixed UUID literals so the check
    // is deterministic. Reconcile these constructors against SpatialOp.swift.
    let fixedTile = UUID(uuidString: "FACADE00-0000-4000-8000-000000000001")!
    let fixedZone = UUID(uuidString: "FACADE00-0000-4000-8000-000000000002")!
    let fixedReplica = UUID(uuidString: "FACADE00-0000-4000-8000-000000000003")!

    // Build one instance of EVERY Op case. The list below covers the cases the
    // dependency ticket locked; if the shipped enum has more, add them here too —
    // the "Done when" criterion requires one LoggedOp per Op case, no gaps.
    let ops: [Op] = [
        .createTile(id: fixedTile, kind: .terminal, title: "auth",
                    frame: TileFrame(x: 100, y: 200, width: 400, height: 300), zIndex: 1),
        .deleteTile(id: fixedTile),
        .setTileFrame(id: fixedTile,
                      frame: TileFrame(x: 10, y: 20, width: 30, height: 40)),
        .setTileZone(tileId: fixedTile, zoneId: fixedZone),
        .setZonePosition(id: fixedZone, position: .first),
        // … remaining Op cases (createZone, deleteZone, setZoneOrigin,
        //   setZoneSize, setZoneName, setZoneColor, setTileTitle, etc.)
        //   — enumerate ALL of them; see SpatialOp.swift for the full list.
    ]
    var scannedOpCount = 0
    for op in ops {
        let logged = LoggedOp(
            opId: OpId(lamport: 5_000_000, replica: fixedReplica),  // above pid ceiling on purpose
            op: op
        )
        let data = try encoder.encode(logged)
        let json = try JSONSerialization.jsonObject(with: data)
        let violations = taintCheck(json)
        expect(violations.isEmpty,
               "LoggedOp wrapping \(op) is taint-free; found: \(violations)")
        scannedOpCount += 1
    }

    // ── Activity events ───────────────────────────────────────────────────
    // One AgentActivityEvent per (tone × status) combination. Full cross-product
    // so EVERY tone and EVERY status is exercised — no zip() that silently drops
    // the shorter list.
    let statuses: [AgentStatus] = [.configuring, .working, .idle, .needsAttention, .done, .stale]
    let tones: [ActivityEventTone] = [.info, .tool, .approval, .error]
    var scannedEventCount = 0
    for tone in tones {
        for status in statuses {
            let event = AgentActivityEvent(
                sequence: 5_000_000,   // ABOVE the pid ceiling (4_194_304) — see note below
                replicaId: fixedReplica,
                tileId: fixedTile,
                runId: nil,            // no runId in projection payloads
                tone: tone,
                kind: "turn.started",
                status: status,
                summary: "Refactoring auth guard",   // short; must stay < 512 chars
                occurredAt: Date(timeIntervalSinceReferenceDate: 0)  // fixed, not wall-clock
            )
            let data = try encoder.encode(event)
            let json = try JSONSerialization.jsonObject(with: data)
            let violations = taintCheck(json)
            expect(violations.isEmpty,
                   "AgentActivityEvent tone=\(tone) status=\(status) is taint-free; found: \(violations)")
            scannedEventCount += 1
        }
    }
    // 4 tones × 6 statuses = 24 combinations, all scanned clean.
    expect(scannedEventCount == 24,
           "scanned every tone×status combination; got \(scannedEventCount)")

    // ── Deliberate failure probe ──────────────────────────────────────────
    // Confirm the scanner DOES catch a deliberately poisoned payload,
    // so a future false-negative isn't invisible.
    struct PoisonedPayload: Encodable {
        let pid: Int           // pid-shaped integer
        let pane: String       // matches ^%\d+$
        let body: String       // exceeds 512 chars
        let path: String       // host-local path
    }
    let poison = PoisonedPayload(
        pid: 12345,
        pane: "%42",
        body: String(repeating: "x", count: 600),
        path: "/Users/dylan/.claude/sessions/12345.json"
    )
    let poisonData = try encoder.encode(poison)
    let poisonJson = try JSONSerialization.jsonObject(with: poisonData)
    let poisonViolations = taintCheck(poisonJson)
    expect(poisonViolations.count >= 4,
           "scanner detects all four violation kinds in a known-bad payload; got \(poisonViolations.count)")
}
```

Two things to get right in the breadcrumbs that are easy to get wrong:

First, integer fields that carry monotonic counters — `AgentActivityEvent.sequence`
(`UInt64`) and `OpId.lamport` (`UInt64`) — must use a value **outside** `2 ... 4_194_304` in
the test construction. Use a value **above** the ceiling, e.g. `5_000_000`. The earlier draft
of this ticket used `42`, which is **wrong**: `42` is inside `2 ... 4_194_304`, so it would
trip the pid-shaped-integer rule. Any value in `2 ... 4_194_304` trips the scanner; `0` and
`1` are below the range and would pass, but `5_000_000` is used here so the fixtures also
exercise the above-`Int.max`-guard path realistically and read as plausible sequence numbers.

Second, the deliberate-failure probe exists to prevent the scanner from silently becoming a
no-op (e.g., if `JSONSerialization.jsonObject` is given malformed data and returns an empty
dictionary). The probe catches a scanner that passes everything by confirming it still
catches something it should catch. Both directions of the test matter.

## How we test it

### Logic (pure Core checks)

The entire ticket is a Core check. The block in `ContinuumRevivedCoreChecks/main.swift`
covers three cases:

1. **Clean spatial ops:** one `LoggedOp` per `Op` case, each encodes and scans clean. The
   check fails if any case carries a field the type-split work accidentally allowed to carry
   a runtime handle.
2. **Clean activity events:** one `AgentActivityEvent` per (tone × status) combination — the
   full 4 × 6 = 24 cross-product, asserted by `scannedEventCount == 24` — each encodes and
   scans clean. This catches the case where, for example, `runId` is set to a pid-derived
   string or `summary` is set to a full transcript excerpt.
3. **Deliberate-failure probe:** a `PoisonedPayload` that carries all four violation kinds is
   scanned, and the check asserts the scanner returns at least four violations. This proves
   the scanner is live, not silently passing everything.

The check is deterministic: fixed UUID literals, a fixed `Date`, and no calls to `Date()`,
`UUID()`, or any random source. It runs in the existing `ContinuumRevivedCoreChecks`
executable in under a millisecond. No network, no daemon, no file I/O beyond the existing
process output.

### Backend (real-path / integration, not bypassed)

There is no live-transport real-path check for this ticket because the invariant is about
payload shape, not about a live transport. The real-path enforcement of this scanner happens
later, in the **SyncTransport seam ticket**, which will call `taintCheck` inside its fake's
`send` path so any future encoded payload that would travel over the wire is also scanned at
the transport seam before it is dispatched. That wiring is the responsibility of that ticket,
not this one. This ticket's job is to deliver the scanner and prove the current payload types
are clean.

Because the scanner encodes and scans the **actual** shipped `LoggedOp` and
`AgentActivityEvent` types (not a stand-in), the three-case check above *is* the real-path
check for what this ticket owns: it exercises the exact `JSONEncoder` →
`JSONSerialization.jsonObject` → `taintCheck` pipeline the transport will use.

**On the invariant-spine manifest.** This ticket does **not** write a
`qa-runs/<ts>/…/manifest.json` file, and its "Done when" list does not require one — the
harness that produces per-invariant manifests is stood up by the **invariant spine harness
ticket**, which is a separate deliverable. When that ticket lands, it will wire this check's
result (scan timestamp, payloads-scanned counts, violation list, probe count) into the
matrix manifest. Until then, this ticket's falsifiable acceptance is the exit code and the
absence of `FAIL:` lines from `swift run ContinuumRevivedCoreChecks` — everything the "Done
when" list asserts is verifiable by running that one command.

### UX (visual gate + dogfood snippet)

This ticket draws no pixels. The UX gate is indirect: the invariant it enforces is what makes
the iOS observer's payload safe to ship — no transcript bodies, no host paths, no session
handles reaching the phone. The dogfood verification of *that* is deferred to the **iOS
observer app ticket**, where the concrete dogfood step is: confirm that the push payload
contains only a `phase`, a `headline`, and a `detail` of at most 160 characters (the locked
push-payload limit), with no body text and no filesystem paths.

For this ticket specifically, the dogfood check is: run the `ContinuumRevivedCoreChecks`
binary (`swift run ContinuumRevivedCoreChecks` from the repo root) and see that it exits 0
with the taint-scan block printing no `FAIL:` lines. That is the complete human-facing
verification for a pure logic check.

## Execution mode

**Autonomous.** The check is a pure Swift executable with no external dependencies: no
AppKit, no network, no tmux daemon, no cloud account, no iOS device. Its inputs are literal
constants constructed in the harness; its outputs are pass/fail assertions. Every requirement
— the scanner returning zero violations for clean payloads, and at least four violations for
the known-bad probe — is fully machine-verifiable in a single `swift run` invocation. No
human eyes are needed to interpret the result. **Precondition:** both dependency files
(`SpatialOp.swift`, `AgentActivityEvent.swift`) must already be present in the working tree;
this is verifiable up front (see the final note) and does not require a human decision.

## Done when

- [ ] `Sources/ContinuumRevivedCore/SyncPayloadTaintScanner.swift` exists and compiles,
  exporting `TaintViolation`, `TaintPattern`, and the `taintCheck(_:keyPath:)` free function.
- [ ] The new block in `Sources/ContinuumRevivedCoreChecks/main.swift` runs and passes:
  one `LoggedOp` per `Op` case encodes and scans clean; every (tone × status) combination
  of `AgentActivityEvent` — all 4 × 6 = 24 — encodes and scans clean (asserted by the
  `scannedEventCount == 24` check); and the deliberate-failure probe detects at least four
  violations.
- [ ] The `taintCheck` NSNumber branch guards `num.uint64Value > UInt64(Int.max)` and returns
  clean early **before** calling `num.intValue`, matching the "Watch out for" rule exactly.
- [ ] Running `swift run ContinuumRevivedCoreChecks` exits 0 with no `FAIL:` lines.
- [ ] No existing check in `ContinuumRevivedCoreChecks/main.swift` is broken by the new
  additions.
- [ ] The `isKnownSafeInteger` helper starts empty (returning `false` unconditionally) and
  any future addition requires an inline comment explaining why that integer is not a pid.

(The invariant-spine manifest entry is explicitly **not** an acceptance item here — it is
owned by the invariant spine harness ticket, as noted in "How we test it".)

## Depends on / unblocks

This ticket depends directly on the **sync/observation type split ticket**, which defines
`AgentActivityEvent` and `ActivityEventTone`, and on the **op enum & logged-op envelope
ticket**, which defines `Op`, `LoggedOp`, `OpId`, and `FracIndex`. Both must land first
because they define the payload types that are scanned here. Without those types existing in
the codebase, the harness cannot be compiled — the scanner function itself is type-agnostic,
but the population it scans is built from those concrete types.

The scanned unit on the spatial side is the **`LoggedOp` envelope**, not the bare `Op`: the
transport encodes the envelope (which adds `opId: OpId` with a `lamport: UInt64` and a
`replica: UUID`), so the scan population wraps every `Op` in a `LoggedOp` before encoding.
That is why the breadcrumbs encode `LoggedOp`, not `Op` directly — the scanner must see
exactly what the transport encodes.

This ticket unblocks the **SyncTransport seam ticket**, which can then wire `taintCheck` into
its fake's `send` path for continuous enforcement at the transport boundary. It unblocks the
**activity projection over transport ticket**, which can proceed knowing the event type it
projects is proven clean. And it unblocks the **iOS observer app ticket**, which is
predicated on the guarantee that what arrives on the phone carries no host-local or
session-internal content.

## Watch out for

**The integer range trap.** The pid-ceiling check (`2 ... 4_194_304`) will fire on any
integer field in that range that is legitimate — including a lamport clock value of `42`, a
tile z-index of `7`, or a small count of `3`. The implementation must ensure that sequence
and lamport values in the test population are **above** `4_194_304` (the breadcrumbs use
`5_000_000`); `0` and `1` also pass but do not exercise the guard path. If a legitimate
payload field genuinely needs an integer in the pid range for a non-pid reason, it must be
registered in `isKnownSafeInteger` with a comment, not silently exempted by widening the
scanner's range. Widening the range to avoid a false positive is the failure mode that
defeats the whole check.

**`JSONSerialization` quirks on `UInt64`.** Swift's `JSONEncoder` encodes `UInt64` as a JSON
number. `JSONSerialization.jsonObject` decodes JSON numbers as `NSNumber`. Sequence and
lamport values are `UInt64` and can exceed `Int64.max`. `NSNumber.intValue` on a value above
`Int.max` truncates and is meaningless. **Guard against this by checking
`num.uint64Value > UInt64(Int.max)` before calling `intValue`, and return clean early** — if
the value exceeds `Int.max` it cannot be a pid. The breadcrumb `taintCheck` above already
has this guard as its first NSNumber statement; the two parts of this ticket agree, and the
"Done when" list requires it.

**The type split's `Any`-typed escape hatch.** If the sync/observation type-split work
introduces any field typed as `Codable` (protocol existential), `AnyCodable`, or `Data` with
an opaque blob, the taint scanner will receive an already-decoded blob it cannot inspect. The
scanner operates on the JSON tree after `JSONSerialization`; a `Data` field encodes as a
Base64 string, which the host-path and transcript-body pattern checks will not catch. If the
type-split work includes any opaque `Data` fields, add a dedicated Base64-decode-then-re-scan
step in the taint checker for those fields. The private managed-session record (which carries
opaque resume-cursor and runtime-payload `Data` — defined in the **private managed-session
record ticket**) must never appear in the synced or projected payload at all — the taint scan
is not a substitute for keeping it out of the `Op` and `AgentActivityEvent` types entirely.

**Reconcile constructors against the shipped types.** The breadcrumb constructors
(`Op.createTile(id:kind:title:frame:zIndex:)`, `LoggedOp(opId:op:)`,
`AgentActivityEvent(sequence:replicaId:tileId:runId:tone:kind:status:summary:occurredAt:)`)
mirror the dependency tickets' locked designs, but the implementer must open `SpatialOp.swift`
and `AgentActivityEvent.swift` and match the real signatures — case labels and field order
can differ from prose. A mismatch is a compile error, caught immediately, not a silent bug.

**Precondition: if `SpatialOp.swift` or `AgentActivityEvent.swift` are not present** (because
a dependency ticket has not landed), do not stub the types out as placeholders and proceed.
The check has no value against a placeholder. Verify presence first — for example,
`ls Sources/ContinuumRevivedCore/SpatialOp.swift Sources/ContinuumRevivedCore/AgentActivityEvent.swift`
should list both, and `swift build` should compile the target — and only then begin. This is
a mechanical precondition check, not a judgement call: both files present and the target
building green means proceed; either missing means the dependency ticket is not done yet.
