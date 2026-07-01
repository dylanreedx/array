# Invariant spine harness — wire I1–I8 into the check harness with measured-value manifests

## What this delivers

After this ticket, every phase that follows has a living, executable specification for
what "correct" means across the eight structural invariants that govern the entire
distributed-canvas program. Each invariant runs as a named check block inside
`ContinuumRevivedCoreChecks`, and every run writes a `manifest.json` whose fields carry
**measured values** — the actual tile count, the actual window targets, the actual
convergence hash, the actual payload fields — never a bare `{passed: true}`. Future
implementers cannot accidentally ship a regression without the manifest loudly reflecting
what broke and why.

From the system's perspective: the check harness becomes the first-class definition of
correctness that every autonomous coding session can run, read, and trust. It replaces
the implicit "we believe this is fine" with a numbered contract that exits nonzero and
names the failure precisely.

The invariant IDs I1–I8 are the *domain spine* — they are the eight structural
correctness properties of the whole program (binding bijection, no-mirror, no-session-leak,
convergence, sync-boundary purity, status soundness, snapshot round-trip, restart
survival). They are the one code vocabulary this ticket keeps, because they *are* the
thing being built. Everything else in this ticket is named in human terms so an
implementer never has to decode a reference.

## How it fits

The harness is the last piece of Phase 0 foundations and the one that gives every
subsequent phase its verification backbone. It builds directly on the snapshot types
established in the **session topology snapshot** ticket and the **activity tree snapshot**
ticket, and on the injectable substrates defined in the **injectable substrates** ticket
(the in-memory `TmuxControl` fake, the `FakeClock`, the `FakeHost`, and the
`FakeSyncTransport`). Those earlier pieces exist precisely so this harness can exercise
the invariants without a real tmux daemon, without wall-clock time, and without a real
network.

Once this ticket is complete, the session topology work (new tile spawned as a window in
a project session, the tmux window target captured at spawn, the dead-target fallback,
the grouped view sessions) has a harness ready to assert into on every build. The
convergence fuzz for I4, the taint scan for I5, the golden table for I6, and the
round-trip checks for I7 all live here. Phase 1 through Phase 8 each contribute
measured assertions to these same blocks rather than inventing new verification
infrastructure.

**Where the types this harness names actually come from (human ticket names, so the
implementer never has to guess who owns a type):**

- The op-log core types — `LoggedOp`, `OpId`, `Op`, the materialized state, and the
  `materialize(...)` fold — are owned by the **"Op enum & LoggedOp envelope"** ticket
  (which defines `Op`, `OpId`, `LoggedOp`, `FracIndex`) and the **"Op-log apply &
  compaction"** ticket (which defines `MaterializedState` and `materialize(...)`). The
  I4 convergence fuzz drives *those* real functions; this ticket does not redefine them.
- The two provably-disjoint payload families the I5 taint scan walks — `SpatialOp`
  (bidirectional sync) and `AgentActivityEvent` (one-way observation) — are owned by the
  **"Sync/observation type split"** ticket. The taint scanner itself
  (`taintCheck(_:)`, `TaintViolation`) is owned by the **"Taint scan for sync-boundary
  purity (I5)"** ticket. This ticket's I5 block calls those, it does not invent a
  "SyncBoundaryPayload" type — no such type exists in the program.
- The reconciliation snapshot `SessionTopologySnapshot` is owned by the **"Session
  topology snapshot type"** ticket; `ActivityTreeSnapshot` is owned by the **"Activity
  tree snapshot type"** ticket.
- The `TmuxControl` protocol + `InMemoryTmuxControl` fake, the `Clock` protocol +
  `FakeClock`, the `FakeHost`, and the `FakeSyncTransport` are owned by the **"Injectable
  substrates"** ticket. This harness *uses* them; it never redefines or stubs them (see
  "Where it lives").

## The approach

Each invariant gets its own named `do` block in `main.swift` of
`ContinuumRevivedCoreChecks`, following the existing pattern of the focus-history,
wheel-normalization, and Chrome-integration checks already there. Each block:

1. Constructs the minimal synthetic state needed to exercise its invariant using the
   injectable substrates (never touching a real tmux session, never sleeping on a clock).
2. Runs the check logic against that state.
3. Writes a `manifest.json` to a temp directory for that run, where every field that
   matters is a measured value. The manifest schema is defined as a `Codable` struct in
   `ContinuumRevivedCore` so it can be shared with the real-path and UX check runners
   later.
4. Reads the manifest back from disk and asserts the decoded value equals the original.
5. Calls `expect(...)` for each assertion, making the run exit nonzero on the first
   failure so the CI matrix catches it.

The manifest writer is a small `InvariantManifest` type, not a framework. It carries an
`invariantId` string (e.g. `"I1-binding-bijection"`), a `measuredAt` ISO-8601 timestamp
from a fixed reference date or a `FakeClock` (never wall-clock inside the check), and a
`measurements` dictionary of `[String: JSONValue]` — the actual tile UUIDs, actual window
target strings, actual convergence hashes, actual payload field names. The file is written
with `JSONEncoder().encode(...)` and lands at `<tempDir>/invariant-<id>-<runId>.json`.

**One measurement-wrapper type, one name.** The dictionary value type is `JSONValue` — a
hand-rolled tagged union (string, int, double, bool, array, null). This ticket uses the
name **`JSONValue` everywhere**; there is no `AnyCodable`. If you see a stray "AnyCodable"
anywhere in your working memory of this design, it is the same thing under the wrong name
— the canonical name in `Sources/ContinuumRevivedCore/InvariantManifest.swift` is
`JSONValue`, and only `JSONValue` appears in the code.

For invariants that are currently stubs (I1, I2, I3, I4, I5, I8) because their underlying
implementations do not yet exist, the harness registers a **placeholder block** that
asserts only that some currently-existing type it will eventually lean on is present and
`Codable`. This means the block is not vacuously green — it still exercises real code —
but it correctly does not claim more than the current state of the codebase supports. The
placeholder comment is explicit: `// STUB: replace with real assertion when <human ticket
name> lands`. **Stub blocks still write a manifest, read it back, and assert equality**
(step 3–4 above apply to every block, stub or full) — the only thing a stub omits is the
real domain assertion, which it replaces with a smaller non-vacuous assertion plus an
`outcome: "stub"`.

For invariants whose logic is already available in the current codebase (I6 via
`AgentStatusEngine`, I7 via the existing `Codable` types), the check runs the full
assertion with measured output from day one.

No new build targets are introduced. The harness is one executable already in the
`Package.swift` dependency graph.

## Where it lives

All new Swift lives inside the two existing modules — no new targets, no new files
beyond what is needed.

**New file: `Sources/ContinuumRevivedCore/InvariantManifest.swift`**
Defines `InvariantManifest` (the Codable struct written per-run), `InvariantManifestWriter`
(writes to a given temp URL), and `JSONValue` (a thin JSON-value wrapper — a minimal
hand-rolled tagged union, not a dependency, matching the pattern of the rest of Core).
This is the *only* file that defines a new type in this ticket.

**Existing file: `Sources/ContinuumRevivedCoreChecks/main.swift`** (currently 325 KB,
already contains all other check blocks)
Eight new `do` blocks appended after the existing checks, one per invariant, each
prefixed with `// MARK: - Invariant <id>: <name>`.

Key types already in the codebase that the harness exercises:
- `AgentStatus` — `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85`
- `AgentStatusEngine` and `AgentStatusEngine.Configuration` — `Sources/ContinuumRevivedCore/AgentStatusEngine.swift:3` (Configuration at `:11`, exposing `workingHysteresis` and `staleTimeout`)
- `TerminalSessionDescriptor` — `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:3`
- `CanvasState`, `Tile`, `TileKind`, `TileFrame`, `RuntimeRef` — `Sources/ContinuumRevivedCore/CanvasState.swift:3`
- `WorkspaceDocument`, `ZonePlacement` — `Sources/ContinuumRevivedCore/WorkspaceDocument.swift:13`
- `SidebarTree`, `SidebarAgentStatusRollup`, `SidebarTreeBuilder` — `Sources/ContinuumRevivedCore/SidebarTree.swift:126`
- `QARunManifestReader`, `QAVerdict` — `Sources/ContinuumRevivedCore/QARunManifestReader.swift:3`

Types this harness *names by ticket* but does not define — they arrive from their owning
tickets, and the stub blocks reference them **only in comments** until they land:
- `SessionTopologySnapshot` — from the **"Session topology snapshot type"** ticket (the
  tmux reconciliation oracle — sessions, window targets, cwd, foreground command)
- `ActivityTreeSnapshot` — from the **"Activity tree snapshot type"** ticket (the activity
  tree plus the evidence behind each status)
- `TmuxControl` protocol + `InMemoryTmuxControl` fake, `Clock` + `FakeClock`, `FakeHost`,
  `FakeSyncTransport` — from the **"Injectable substrates"** ticket
- `LoggedOp`, `OpId`, `Op` — from the **"Op enum & LoggedOp envelope"** ticket;
  `MaterializedState` and `materialize(...)` — from the **"Op-log apply & compaction"**
  ticket
- `SpatialOp` and `AgentActivityEvent` — from the **"Sync/observation type split"**
  ticket; `taintCheck(_:)` and `TaintViolation` — from the **"Taint scan for sync-boundary
  purity (I5)"** ticket

**The stub rule for these not-yet-existing types: reference them in comments only. Do NOT
define local stand-in types (no `TmuxControlStub`, no `FakeClockStub`) inside the check
file.** The injectable-substrates ticket is a hard prerequisite of this one precisely so
that `TmuxControl`/`FakeClock`/etc. are already real, importable types by the time this
harness is written — there is nothing to stub. A stub block that needs to be
non-vacuous asserts against a type that *already exists today* (e.g. `AgentStatus`,
`TerminalSessionDescriptor`, `CanvasState`), never against a fabricated local placeholder.
This keeps the harness honest and means there are no `// delete this later` stand-ins to
track down and remove.

## Implementation breadcrumbs

```swift
// Sources/ContinuumRevivedCore/InvariantManifest.swift

public struct InvariantManifest: Codable, Sendable {
    public var invariantId: String          // e.g. "I1-binding-bijection"
    public var runId: String                // UUID string
    public var measuredAt: String           // ISO-8601 from a fixed date / FakeClock, never Date()
    public var measurements: [String: JSONValue]  // real counts, hashes, field names
    public var outcome: String              // "pass" | "stub" | "fail" (written before exit)
    public var failureReason: String?       // set only on outcome == "fail"
}

// JSONValue: a hand-rolled enum for String | Int | Double | Bool | [JSONValue] | null
// — no external dependency, and the ONLY name used for this wrapper (never "AnyCodable").

// The `outcome` field is a bare String on the wire (keeps the manifest trivially
// forward-compatible), but it is NOT free-typed at the call site. Callers construct it
// through a small helper enum so a typo cannot ship:
public enum InvariantOutcome: String {
    case pass, stub, fail
}
// Every block sets `outcome: InvariantOutcome.pass.rawValue` (or `.stub` / `.fail`),
// never a hand-typed "pass" literal. This is the "validate against fixed constants at the
// call site" rule from "Watch out for" made concrete: the enum is the validator.

public struct InvariantManifestWriter {
    public static func write(_ manifest: InvariantManifest, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let file = dir.appendingPathComponent("invariant-\(manifest.invariantId)-\(manifest.runId).json")
        try data.write(to: file)
    }
}
```

```swift
// Sources/ContinuumRevivedCoreChecks/main.swift  — appended after existing blocks

// A tiny helper both full and stub blocks call, so EVERY block writes-then-reads-back.
// This is why there is never an unused `manifest` variable anywhere in this ticket:
// the manifest is always consumed by writing it and reading it back.
func writeAndVerify(_ manifest: InvariantManifest) throws {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-\(manifest.invariantId)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try InvariantManifestWriter.write(manifest, to: tmpDir)
    let file = tmpDir.appendingPathComponent("invariant-\(manifest.invariantId)-\(manifest.runId).json")
    let readBack = try JSONDecoder().decode(InvariantManifest.self, from: Data(contentsOf: file))
    expect(readBack == manifest, "\(manifest.invariantId): manifest round-trips through the real filesystem")
    print("\(manifest.invariantId): manifest at \(file.path)")
}

// MARK: - Invariant I6: Status soundness

do {
    // Full assertion: AgentStatusEngine is the existing pure derivation.
    // Every signal combination maps to a measured status; unknown never fabricates.
    //
    // MEASURED-VALUE RULE: the timing thresholds in the manifest are READ from the same
    // Configuration value we inject into the engine — they are never typed as literals.
    // The engine's `configuration` property is private, so we hold our own Configuration
    // and inject it; the manifest then reports exactly what the engine ran with.
    let config = AgentStatusEngine.Configuration()   // default: hysteresis 5s, stale 300s
    let fakeNow = Date(timeIntervalSince1970: 1_800_000_000)
    var engine = AgentStatusEngine(initialStatus: .configuring, now: fakeNow, configuration: config)

    // No signals → status stays as initialised, never fabricates a deep status
    let afterTick = engine.tick(at: fakeNow.addingTimeInterval(10))
    expect(afterTick == .configuring, "I6: no-signal tick must not fabricate a new status")

    // Stale timeout: at/after config.staleTimeout with no signals, becomes .stale
    let afterStale = engine.tick(at: fakeNow.addingTimeInterval(config.staleTimeout + 1))
    expect(afterStale == .stale, "I6: past staleTimeout with no signals must yield .stale, never a fabricated status")

    // needsAttention from title wins over working from output
    var attentionEngine = AgentStatusEngine(initialStatus: .idle, now: fakeNow, configuration: config)
    _ = attentionEngine.ingest(.outputActivity, at: fakeNow.addingTimeInterval(1))
    let afterAttention = attentionEngine.ingest(.terminalTitle("Agent needs attention"), at: fakeNow.addingTimeInterval(2))
    expect(afterAttention == .needsAttention, "I6: needsAttention from title beats outputActivity")

    // explicit signal takes precedence over inferred signal
    var explicitEngine = AgentStatusEngine(initialStatus: .idle, now: fakeNow, configuration: config)
    _ = explicitEngine.ingest(.outputActivity, at: fakeNow.addingTimeInterval(1))          // infers .working
    let afterExplicit = explicitEngine.ingest(.explicit(.done), at: fakeNow.addingTimeInterval(2))
    expect(afterExplicit == .done, "I6: explicit signal overrides inferred signal")

    // The count below is the FALSIFIABLE contract: these are exactly the four cases the
    // block asserts, one measured entry each. Adding a fifth case is a deliberate change
    // that MUST bump this literal in the same commit (see "Watch out for"). There is no
    // "at minimum" here — four is the number, and the enumerated cases above are four.
    let measurements: [String: JSONValue] = [
        "checked_signal_combinations": .int(4),
        "stale_timeout_seconds": .double(config.staleTimeout),        // sourced from live Configuration
        "hysteresis_seconds": .double(config.workingHysteresis),      // sourced from live Configuration
        "attention_beats_working": .bool(true),
        "explicit_beats_inferred": .bool(true)
    ]
    let manifest = InvariantManifest(
        invariantId: "I6-status-soundness",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: fakeNow),
        measurements: measurements,
        outcome: InvariantOutcome.pass.rawValue,
        failureReason: nil
    )
    try writeAndVerify(manifest)
}

// MARK: - Invariant I7: Snapshot round-trip

do {
    // TerminalSessionDescriptor, CanvasState, WorkspaceDocument are all Codable.
    // Round-trip each through JSONEncoder/JSONDecoder and assert FULL-VALUE equality.
    //
    // ROUND-TRIP CONTRACT (stated explicitly because these two fields are the ones most
    // likely to silently break equality across a schema bump):
    //   - schemaVersion MUST survive the round trip. The custom Decoder decodes it as a
    //     REQUIRED key (container.decode, non-optional), so any encode that drops it makes
    //     the decode throw — the assertion below would fail loudly, not silently.
    //   - scrollback MUST survive the round trip. It is decoded with decodeIfPresent, so a
    //     nil round-trips to nil and a set value round-trips to the same value; the
    //     equality assertion is what guarantees a set scrollback is preserved.
    // We construct the descriptor WITH an explicit schemaVersion and a non-nil scrollback
    // so both load-bearing fields are actually exercised by the equality check.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let tileId = UUID(uuidString: "B0000000-0000-4000-8000-000000000701")!
    let descriptor = TerminalSessionDescriptor(
        schemaVersion: TerminalSessionDescriptor.currentSchemaVersion,   // explicit, not the default
        id: UUID(uuidString: "B0000000-0000-4000-8000-000000000702")!,
        tileId: tileId,
        launchProfileId: "default",
        command: "/bin/zsh",
        args: [],
        cwd: "/tmp/i7-fixture",
        env: ["TERM": "xterm-256color"],
        title: "I7 fixture",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastStartedAt: Date(timeIntervalSince1970: 1_800_000_001),
        lastExit: nil,
        agentDescriptor: AgentDescriptor(
            agentKind: "claude",
            worktreePath: nil,
            status: .working,
            statusUpdatedAt: Date(timeIntervalSince1970: 1_800_000_002),
            runId: nil
        ),
        scrollback: "line-1\nline-2"    // non-nil so the round-trip actually exercises it
    )
    let encoded = try encoder.encode(descriptor)
    let decoded = try decoder.decode(TerminalSessionDescriptor.self, from: encoded)
    expect(decoded == descriptor, "I7: TerminalSessionDescriptor round-trip must be equal (incl. schemaVersion + scrollback)")

    // The field count is WHATEVER IS MEASURED from the encoded JSON — never a hardcoded
    // number. It varies with which optional fields are non-nil (e.g. lastExit == nil is
    // omitted by TerminalLastExit's encodeIfPresent path), so a fixed literal would be a
    // guess and non-falsifiable. We record the measured count and the sorted field names,
    // so a future field addition shows up as a diff in the manifest, not as a broken
    // literal in this ticket.
    let fieldNames = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        .map { Array($0.keys).sorted() } ?? []
    let manifest = InvariantManifest(
        invariantId: "I7-snapshot-round-trip",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000)),
        measurements: [
            "types_checked": .int(3),   // descriptor, CanvasState, WorkspaceDocument
            "descriptor_field_count": .int(fieldNames.count),   // MEASURED, not a fixed 14/15
            "descriptor_fields": .array(fieldNames.map { .string($0) }),
            "schema_version_preserved": .bool(decoded.schemaVersion == descriptor.schemaVersion),
            "scrollback_preserved": .bool(decoded.scrollback == descriptor.scrollback)
        ],
        outcome: InvariantOutcome.pass.rawValue,
        failureReason: nil
    )
    try writeAndVerify(manifest)
}

// MARK: - Invariant I1: Binding bijection (STUB — real assertion lands with the "Capture tmuxWindowTarget at spawn" ticket)

do {
    // STUB: replace with real assertion when "Capture tmuxWindowTarget at spawn" lands.
    // When real: construct an InMemoryTmuxControl fake (from the "Injectable substrates"
    // ticket), spawn two tiles, read back the SessionTopologySnapshot (from the "Session
    // topology snapshot type" ticket), assert each tile maps to exactly one distinct
    // window target and no orphan window exists.
    //
    // Measured values that will appear in the real manifest:
    //   tile_count: Int, window_target_count: Int, orphan_window_count: Int,
    //   tile_ids: [String], window_targets: [String]
    //
    // For now this block asserts one real property of a type that EXISTS TODAY, so it is
    // non-vacuous. It references SessionTopologySnapshot / InMemoryTmuxControl ONLY in the
    // comments above — it defines no local stand-in types.
    let statusData = try JSONEncoder().encode(AgentStatus.working)
    let statusRound = try JSONDecoder().decode(AgentStatus.self, from: statusData)
    expect(statusRound == .working, "I1 stub: AgentStatus.working codable round-trip")

    let manifest = InvariantManifest(
        invariantId: "I1-binding-bijection",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000)),
        measurements: [
            "stub": .bool(true),
            "depends_on": .string("Capture tmuxWindowTarget at spawn")
        ],
        outcome: InvariantOutcome.stub.rawValue,
        failureReason: nil
    )
    // Stubs write-and-read-back exactly like full blocks. No unused variable, no warning.
    try writeAndVerify(manifest)
}
```

The same stub pattern applies to the other stub invariants, each naming its owning ticket
in human form in the `depends_on` field and in the STUB comment:

- **I2 (no-mirror)** — depends on the **"Grouped view session per tile"** ticket.
- **I3 (no-session-leak)** — depends on the **"Project session naming & lifecycle
  ownership"** ticket.
- **I8 (restart survival)** — depends on the **"Capture tmuxWindowTarget at spawn"** ticket
  and the real-tmux reattach path.
- **I4 (convergence fuzz)** — depends on the **"Op enum & LoggedOp envelope"** ticket
  (for `LoggedOp`/`OpId`/`Op`) and the **"Op-log apply & compaction"** ticket (for
  `MaterializedState`/`materialize(...)`); the real assertion is the N-replica random-op
  shuffle asserting byte-identical encoded materialized state, and it graduates in the
  **"Convergence fuzz: write the I4 RED→GREEN tripwire"** ticket.
- **I5 (taint scan)** — depends on the **"Sync/observation type split"** ticket (for
  `SpatialOp` and `AgentActivityEvent`) and the **"Taint scan for sync-boundary purity
  (I5)"** ticket (for `taintCheck(_:)` and `TaintViolation`). There is no
  "SyncBoundaryPayload" type; the scan walks `SpatialOp` and `AgentActivityEvent`
  instances for forbidden fields (pid, pane target, runtime handle, transcript body).

Each stub block runs a non-vacuous assertion on some currently-existing type so it cannot
trivially pass by doing nothing, and each writes-then-reads-back its manifest via the same
`writeAndVerify` helper. The I4 stub block is marked with the tripwire comment:
`// TRIPWIRE: this fuzz must go RED→GREEN before any SyncTransport implementation is committed.`

## How we test it

### Logic (pure Core checks)

The check harness is itself the logic test. Running `swift build` followed by
`./scripts/run-matrix.sh` (or directly running the `ContinuumRevivedCoreChecks`
executable) exercises every block. The exit code is the verdict: zero means all
`expect(...)` calls passed, nonzero means a failure with its message on stderr.

Specific logic assertions added by this ticket:

- `InvariantManifest` encodes and decodes round-trip through `JSONEncoder`/`JSONDecoder`
  with all fields preserved (tests the manifest writer itself, not just the invariants).
- `InvariantManifest` with `outcome: "fail"` and a `failureReason` encodes with the
  reason field present; one with `outcome: "pass"` and `failureReason: nil` encodes with
  `failureReason` absent (verifies the `Codable` conditional-encode logic).
- Every `outcome` value is produced through `InvariantOutcome.<case>.rawValue`, never a
  hand-typed string literal — so a misspelling is a compile error, not a silent wrong
  value on disk.
- The I6 block covers exactly these four signal combinations, each a measured manifest
  entry, and the manifest's `checked_signal_combinations` literal equals four (the
  falsifiable contract; a fifth case bumps the literal in the same commit): no-signal →
  no fabrication; past-stale-timeout → `.stale`; `needsAttention` from title beats
  `.outputActivity`; explicit signal takes precedence over inferred signal. The
  `stale_timeout_seconds` and `hysteresis_seconds` fields are read from the injected
  `AgentStatusEngine.Configuration`, not typed as literals.
- The I7 block covers `TerminalSessionDescriptor` round-trip equality (all fields,
  including `schemaVersion` and `scrollback`), `CanvasState` round-trip equality, and
  `WorkspaceDocument` round-trip equality. The manifest records the **measured** field
  count and the actual field names found in the encoded JSON, so a future field addition
  is visible in the manifest diff — no field count is hardcoded.
- Each stub block asserts at least one currently-existing type property (proving the stub
  is not vacuously green) and writes a manifest with `outcome: "stub"`.

### Backend (real-path / integration)

The invariant harness in this ticket is fully in-process and needs no real tmux daemon.
The backend/real-path proof for I1, I2, I3, and I8 is deferred to the tickets that
implement the underlying mechanisms (the **"Capture tmuxWindowTarget at spawn"**,
**"Grouped view session per tile"**, and **"Project session naming & lifecycle
ownership"** tickets). When those tickets land, they replace the stub block content with
real assertions and change the manifest `outcome` from `"stub"` to `"pass"`.

The `InvariantManifestWriter` is tested against the real filesystem in the check
itself: every block (full and stub) creates a temp directory via `writeAndVerify`, writes
the manifest, reads it back, and asserts the decoded value equals the original. This is a
real filesystem round-trip, not a mock, and it runs in the matrix on every build.

### UX (visual gate + dogfood snippet)

The harness has no direct UI surface, so there is no visual gate for this ticket. The
dogfood path is: after running the matrix, the manifest files are readable JSON in the
temp directory (each block prints its manifest path). The concrete verification:

Open Terminal, navigate to the project root, and run:

```
swift build 2>&1 | tail -5
.build/debug/ContinuumRevivedCoreChecks 2>&1 | grep -E "^(FAIL|PASS|I[0-9])"
```

A passing run exits with code 0 and produces no `FAIL:` lines on stderr. Each invariant
block prints its `I<n>-...: manifest at <path>` line (visible in the output). Opening one
of those JSON files in any editor shows **measured** values — for I7 something like
`"descriptor_field_count": 15, "descriptor_fields": ["agentDescriptor","args",...]`
(the count is whatever the encoder actually produced for this fixture, not a number typed
into this ticket), `"schema_version_preserved": true`, `"outcome": "pass"` — never
`{"passed": true}`. Note the count is not asserted to be any specific value in this
ticket; it is reported as measured, and its exact value is confirmed the first time you
run the harness, not predicted here.

## Execution mode

**Autonomous.** Every assertion in this ticket is a pure in-process check: the
`AgentStatusEngine`, `TerminalSessionDescriptor`, `CanvasState`, and
`InvariantManifest` logic runs without a tmux daemon, without a real clock, without a
real filesystem beyond a temp directory that the check creates and removes itself. The
stub blocks are intentionally incomplete but are also deterministic and non-flaky. The
matrix runs the executable and checks the exit code; this is exactly the proof the
autonomous coding loop needs, with no human eyes required.

## Done when

- [ ] `Sources/ContinuumRevivedCore/InvariantManifest.swift` exists and defines
  `InvariantManifest` (Codable, Sendable), `InvariantManifestWriter.write(_:to:)`,
  `JSONValue` (the hand-rolled tagged-union for measurement values — the only name for
  this type), and `InvariantOutcome` (the enum whose `.rawValue` every call site uses to
  set `outcome`).
- [ ] Eight `// MARK: - Invariant I<n>:` blocks are present in
  `Sources/ContinuumRevivedCoreChecks/main.swift`, one for each of I1–I8.
- [ ] I6 and I7 blocks contain full (non-stub) assertions and write manifests with
  `outcome: "pass"` and measured fields. I6's timing fields are sourced from the injected
  `AgentStatusEngine.Configuration`; I7's `descriptor_field_count` is the measured count
  from the encoded JSON, not a literal.
- [ ] I1, I2, I3, I4, I5, I8 blocks contain stub assertions on currently-existing types
  and write manifests with `outcome: "stub"`, with explicit `depends_on` fields naming
  the owning tickets in human form.
- [ ] **Every** block — full and stub alike — writes a manifest, reads it back from disk,
  and asserts the decoded `InvariantManifest` equals the original (via the shared
  `writeAndVerify` helper). No block leaves a manifest unwritten or a variable unused.
- [ ] No local stand-in types are defined in the check file. `TmuxControl`, `FakeClock`,
  `SessionTopologySnapshot`, `SpatialOp`, etc. are referenced only in stub comments and
  come from their owning tickets; they are never redefined or stubbed here.
- [ ] `swift build` succeeds with **no warnings** in the `ContinuumRevivedCore` and
  `ContinuumRevivedCoreChecks` targets. (There is no unused-variable workaround anywhere,
  because every manifest is consumed by `writeAndVerify` — the no-warnings bar and the
  breadcrumbs are consistent.)
- [ ] Running `.build/debug/ContinuumRevivedCoreChecks` exits with code 0.
- [ ] No manifest file contains only `{"passed": true}` or an equivalent content-free
  verdict; every manifest has at least one field in `measurements` with a real value.
- [ ] The I4 stub block contains the tripwire comment: `// TRIPWIRE: this fuzz must go
  RED→GREEN before any SyncTransport implementation is committed.`

## Depends on / unblocks

This ticket depends on the **"Session topology snapshot type"** and **"Activity tree
snapshot type"** tickets being defined (so the stub blocks can name those types in
comments), and on the **"Injectable substrates"** ticket being landed (so the harness can
name — and later use — the real `TmuxControl` fake, `FakeClock`, `FakeHost`, and
`FakeSyncTransport` rather than any local stand-in). The stub blocks reference the
not-yet-existing spatial/topology types only in comments, so the harness can be written
before their *full implementations* land; but the injectable-substrates types are a hard
prerequisite precisely so there is nothing to stub locally.

What this ticket unblocks: every subsequent Phase 0, 1, 2, and 3 ticket has a named,
numbered block to write assertions into. The session topology work (**"New terminal tile
spawns a window in the project session"**, **"Capture tmuxWindowTarget at spawn"**,
**"Grouped view session per tile"**, **"Project release = detach"**) each upgrades its
corresponding stub block from `outcome: "stub"` to `outcome: "pass"` with real measured
fields, closing the feedback loop for the autonomous coding loop.

## Watch out for

**The hardest thing to get right is keeping stub blocks non-vacuous.** A stub that just
writes a manifest and exits with code 0 without asserting anything is a fake-green —
it satisfies the letter of "the block exists" while proving nothing. Every stub block
must `expect(...)` at least one real property of a currently-existing type. The rule:
if removing the `expect` call from a stub block changes the outcome, it is non-vacuous.
If removing it makes no difference, the stub is fake-green and must be fixed. (The
`writeAndVerify` call also carries an `expect`, but that proves the manifest writer, not
the invariant — a stub must have its *own* domain-adjacent assertion on top of it.)

**The manifest `outcome` field is load-bearing for the overnight loop.** The `_PROGRESS.md`
protocol distinguishes `done`, `skipped`, and `in-progress`, and the autonomous loop
reads manifest files to know which invariants have graduated from stub to full. If the
`outcome` field is misspelled or omitted, that signal is lost. This is why `outcome` is
never a hand-typed string: every call site sets it via `InvariantOutcome.<case>.rawValue`,
so the compiler is the validator against the fixed set `pass | stub | fail`. Do not
validate at decode time (a decoded manifest may legitimately carry a future value) — the
guarantee lives at the write call site, in the enum.

**The I6 `checked_signal_combinations` count is a falsifiable literal, not a ceiling.**
The block asserts exactly four signal combinations and the manifest reports `4`. This is a
contract, not an "at minimum." If you add a fifth combination, you bump the literal to `5`
in the same commit — the number must always equal the count of enumerated `expect`ed
cases in the block. Never write `4` while enumerating a different number of cases.

**Never hardcode a "measured" value.** Two specific traps: (1) I6's `stale_timeout_seconds`
and `hysteresis_seconds` come from the injected `AgentStatusEngine.Configuration`
(`config.staleTimeout`, `config.workingHysteresis`), never from a typed-in `300`/`5`;
(2) I7's `descriptor_field_count` is `fieldNames.count` measured from the encoded JSON,
never a typed-in `14`/`15`. A number that looks like a measurement but is actually a guess
violates the whole thesis of this ticket and is not falsifiable.

**Wall-clock `Date()` is banned inside any check block.** Using `Date()` instead of a
fixed reference date makes manifests non-reproducible and can cause time-dependent
assertions to flake on a slow CI runner. Every `measuredAt` field must come from a
fixed `Date(timeIntervalSince1970: ...)` or from a `FakeClock` value. The real-path
tickets that run against a live tmux daemon are the only ones permitted to use
wall-clock time, and they record it in a separate `wallClockAt` field distinct from
`measuredAt`.

**`JSONValue` creep.** The hand-rolled `JSONValue` enum must stay minimal — string, int,
double, bool, array, null — and must not grow into a general JSON library. It is the one
and only measurement-wrapper type (there is no `AnyCodable`). If a measurement needs a
nested object, use a flat key-path string (`"tile_0_id"`, `"tile_1_id"`) rather than a
nested `JSONValue.object` case that does not exist in the enum. Adding `object` support is
a scope expansion that is explicitly out of scope here.
