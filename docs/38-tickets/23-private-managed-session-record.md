# Private managed-agent session record

## What this delivers

After this ticket, every managed agent tile has a durable, host-local record that carries
everything the host needs to re-bind the tile after an app restart: an opaque resume
cursor (the agent-kind-specific token that lets the adapter re-attach its session), an
opaque runtime payload (the tmux window target and other spawn-time facts), and a
last-seen timestamp that the idle reaper will later use. The record is stored entirely
within the project's `.continuum-revived/` state directory alongside the existing session
files, is never included in a sync operation, and contains no field that is valid to encode
into a spatial op or an activity event. That last point is enforced at the type level, not
by convention.

The concrete outcome for the system: the `tmuxWindowTarget` (`%pane_id`) captured at
spawn by the window-target capture seam has a permanent, private home. It no longer needs
to be jury-rigged into `TerminalSessionDescriptor`, and it will never accidentally flow
across the sync boundary. The observer and the lazy-resume logic (a later ticket) have a
clean, single-source record to interrogate.

## How it fits

This ticket builds directly on two completed foundations. The window-target capture seam
defines what `tmuxWindowTarget` is and guarantees it is captured synchronously at spawn —
this ticket is where that captured value is persisted for the long term. The sync and
observation type split establishes the fundamental invariant that the synced/projected
payload must not carry pids, pane targets, host-local handles, or transcript bodies (I5);
this ticket realizes that invariant for the session-identity case by giving those handles a
private, non-syncing home.

Without this record, the `tmuxWindowTarget` is either lost on restart or must be
smuggled into a synced type, which is exactly the sync-boundary contamination I5 forbids.
Without this record, the lazy-resume-on-focus ticket (the next piece in Phase 1) has
nowhere to load the cursor from and cannot implement the three-branch recovery logic
(adopt-existing → resume-from-cursor → fail-honestly) that the architecture requires.

This ticket does not implement lazy resume, the idle reaper, or the per-tile session
lifecycle. It defines and persists the record, proves the sync-boundary invariant holds for
it, and provides the read/write/delete API that future tickets consume.

## The approach

Define `ManagedAgentSessionRecord` as a `Codable, Equatable, Sendable` struct in
`ContinuumRevivedCore`. Its primary key is `tileId: UUID`. It carries:

- `agentKind: AgentKind` — the closed enum locked by D14
  (`shell | claude | codex | pi | managed | unknown`), telling future resume logic which
  adapter to hand the cursor to. **This enum is a hard build-order prerequisite.** Today
  `agentKind` is a free `String` everywhere in the tree (`AgentDescriptor.agentKind`,
  `TerminalSessionDescriptor.swift:95`; the launch/spawn seams in `LaunchProfileSpec.swift`
  and `TileSpawner`), and **no `enum AgentKind` exists in `Sources/` yet** — I checked. This
  record must not be landed against a `String`. The agent-kind enum ticket (D14) lands first;
  see "Depends on / unblocks" for why the ordering is not optional, and "Where it lives" for
  what to do if you are handed this ticket before that enum exists.
- `status: ManagedSessionStatus` — a narrow runtime status (`starting | running | stopped |
  error`) that mirrors t3code's `ProviderSessionRuntimeStatus`. This is distinct from the
  richer derived `AgentStatus` that observers and the UI consume. The narrow status is what
  the reaper and the runtime controller care about; the derived status lives in the activity
  projection and is never stored here.
- `lastSeenAt: Date` — bumped on every interaction. The idle reaper reads this field; it
  never touches the cursor or payload.
- `resumeCursor: Data?` — opaque bytes. For Claude, this encodes the `sessionId` from
  `~/.claude/sessions/<pid>.json`. For Pi, it encodes the `runId` (the run-dir basename
  under `<projectRoot>/.pi/agent-runs/`). For Codex, it encodes the rollout file path
  captured at spawn. For a headless managed agent, it encodes whatever the adapter's
  `startSession` response provides. The orchestration core never interprets these bytes;
  only the specific adapter does.
- `runtimePayload: Data?` — opaque bytes encoding a JSON object whose shape is defined per
  agent kind, but whose required field is `tmuxWindowTarget: String` (the `%pane_id` from
  tmux). Additional fields (`cwd`, `modelSelection`) may be present for managed agents.
  Again, the core never interprets this beyond knowing the field exists.

Both `resumeCursor` and `runtimePayload` are `Data?` rather than typed structs because the
core must never be required to understand their internals. This mirrors t3code's
`Schema.NullOr(Schema.Unknown)` pattern for the same fields in `provider_session_runtime`.

Persistence goes through a new `ManagedAgentSessionStore`, which follows the same
`AtomicWriter`-backed pattern that `ProjectStore` already uses for session descriptors.
Records live at `<projectRoot>/.continuum-revived/managed-sessions/<tileId>.json`, one
file per tile. This keeps the private record directory co-located with the rest of
project-local state, makes individual-tile reads cheap, and avoids the need for a lock
when reading a single record.

The sync-boundary invariant is enforced at the type level by the sync and observation type
split: the spatial `Op` enum cannot represent a `ManagedAgentSessionRecord` because there
is no op variant for it, and `AgentActivityEvent` (the projected type) has no field for a
cursor or pane target. The taint scan check (a separate ticket) will assert this
mechanically by walking the synced/projected types and rejecting any field whose
`Mirror.displayStyle` encodes a type reachable from `ManagedAgentSessionRecord`. This
ticket's responsibility is to define the type so that it is simply not present in either
synced or projected envelopes, and to add an assertion to the taint scan target list.

## Where it lives

**New file:** `Sources/ContinuumRevivedCore/ManagedAgentSessionRecord.swift`
Defines `ManagedAgentSessionRecord`, `ManagedSessionStatus`, and `ManagedAgentSessionStore`.
This is a Core type because it needs to be visible to both the app layer (for write paths
in `ZoneRuntimeController`) and future test targets.

**Prerequisite type — `enum AgentKind` (owned by the D14 ticket).** This record's
`agentKind` field is typed as `AgentKind`, and `AgentKind` does not exist in `Sources/`
today (it is a free `String` at `TerminalSessionDescriptor.swift:95` and the spawn seams).
The self-contained shape D14 locks is:

```swift
public enum AgentKind: String, Codable, Equatable, Sendable {
    case shell, claude, codex, pi, managed, unknown
}
```

**If the D14 enum has already landed, use it as-is — do not redefine it here.** If you are
handed this ticket before D14 has landed, that is a workflow ordering error; the correct
action is to land D14 first, not to substitute a `String` and not to define a throwaway
`AgentKind` inside this file that D14 then has to reconcile. The "Done when: compile
cleanly" bar and the logic-check literals (`agentKind: .claude`) and the spawn-path literal
(`.shell`) all depend on this enum existing exactly once, in its own file, with these cases.
Confirm `enum AgentKind` resolves before writing a single line of this record.

**New file:** `Sources/ContinuumRevivedCore/ManagedAgentSessionStore.swift`
The `AtomicWriter`-backed store. Follows the exact pattern of `ProjectStore.saveSession`
(`ProjectStore.swift:136`) / `ProjectStore.loadSession` (`ProjectStore.swift:140`) for the
single-record read/write, and `ProjectStore.listSessions()` (`ProjectStore.swift:157`) for
the directory-enumeration path — read those three functions before writing this one, as the
`AtomicWriter` usage pattern (`writer.write(_:to:)` / `writer.read(at:)`), the
skip-unreadable-file `do/catch … continue` loop in `listSessions`, and the directory
conventions are already established and must be matched precisely. (Note: there is no
`loadAllSessions` in the tree — `listSessions()` is the real analogue for the enumerate-all
path, and it filters on `pathExtension == "json"` and skips unreadable entries rather than
crashing.)

**Modified:** `Sources/ContinuumRevivedCore/ProjectStoreLayout.swift` (or wherever the
layout struct lives — it is defined at `ProjectStore.swift:8`)
Add a `managedSessionsDirectory: URL` computed property alongside `sessionsDirectory`
(`ProjectStore.swift:27`) and a `managedSessionFile(tileId:) -> URL` method alongside
`sessionFile(id:)` (`ProjectStore.swift:71`).

**Modified:** `Sources/ContinuumRevived/App/ZoneRuntimeController.swift:6`
Add a `ManagedAgentSessionStore` property, initialized in `init(root:acquireLock:)` at
line 54. Wire a write call into the tile-spawn path (wherever `saveSession` is currently
called after a terminal tile spawns) to persist the initial record with `status: .running`
and the captured `tmuxWindowTarget` packed into `runtimePayload`.

**Modified:** `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`, the `close()`
method (line 78)
On controller close, iterate live runtimes and update each managed record's `status` to
`.stopped` and bump `lastSeenAt`, mirroring how `lastExit` is written to session
descriptors in `close()` at line 86–91.

**Key invariant sites (for the done-when checks):**
- `TerminalSessionDescriptor` (`TerminalSessionDescriptor.swift:3`) must gain no
  `tmuxWindowTarget`, `resumeCursor`, or `runtimePayload` field as a result of this ticket.
- `AgentDescriptor` (`TerminalSessionDescriptor.swift:94`) must gain no such field either.
- The spatial `Op` enum (defined by the op enum ticket) must have no variant mentioning
  `ManagedAgentSessionRecord`.

## Implementation breadcrumbs

```swift
// ManagedAgentSessionRecord.swift — in ContinuumRevivedCore

public enum ManagedSessionStatus: String, Codable, Equatable, Sendable {
    case starting
    case running
    case stopped
    case error
}

public struct ManagedAgentSessionRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let tileId: UUID
    public var agentKind: AgentKind          // enum AgentKind from D14 — must already exist
    public var status: ManagedSessionStatus
    public var lastSeenAt: Date
    public var resumeCursor: Data?           // opaque; nil until the adapter provides one
    public var runtimePayload: Data?         // opaque; must contain tmuxWindowTarget at spawn

    public init(
        tileId: UUID,
        agentKind: AgentKind,
        status: ManagedSessionStatus = .starting,
        lastSeenAt: Date,
        resumeCursor: Data? = nil,
        runtimePayload: Data? = nil
    ) { … }
}

// Convenience: pack the window target into runtimePayload at spawn time.
// The adapter and the lazy-resume ticket will add additional fields; the core only cares
// that tmuxWindowTarget is present and round-trips faithfully.
extension ManagedAgentSessionRecord {
    public struct RuntimePayloadFields: Codable {
        public var tmuxWindowTarget: String   // the %pane_id, e.g. "%12"
        public var cwd: String?
        // additional adapter-specific fields are encoded alongside these and survive
        // the round-trip because they fall through as unknown keys in decoding
    }

    public func tmuxWindowTarget() -> String? {
        guard let data = runtimePayload,
              let fields = try? JSONDecoder().decode(RuntimePayloadFields.self, from: data)
        else { return nil }
        return fields.tmuxWindowTarget
    }

    public static func makeRuntimePayload(windowTarget: String, cwd: String?) -> Data? {
        try? JSONEncoder().encode(RuntimePayloadFields(tmuxWindowTarget: windowTarget, cwd: cwd))
    }
}
```

```swift
// ManagedAgentSessionStore.swift — in ContinuumRevivedCore

public final class ManagedAgentSessionStore: Sendable {
    private let writer: AtomicWriter
    private let layout: ProjectStoreLayout

    public init(projectRoot: URL) {
        self.layout = ProjectStoreLayout(projectRoot: projectRoot)
        self.writer = AtomicWriter(/* same config as ProjectStore's writer */)
    }

    public func upsert(_ record: ManagedAgentSessionRecord) throws {
        // Create directory on first write, as ProjectStore does for sessionsDirectory.
        let dir = layout.managedSessionsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writer.write(record, to: layout.managedSessionFile(tileId: record.tileId))
    }

    public func load(tileId: UUID) throws -> ManagedAgentSessionRecord? {
        // Return nil if not found (no record for this tile yet), throw on corrupt data.
        let url = layout.managedSessionFile(tileId: tileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try writer.read(at: url)
    }

    public func delete(tileId: UUID) throws {
        let url = layout.managedSessionFile(tileId: tileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func loadAll() throws -> [ManagedAgentSessionRecord] {
        // Mirror ProjectStore.listSessions() (ProjectStore.swift:157) — enumerate the
        // directory with contentsOfDirectory, filter pathExtension == "json", decode each
        // file, and skip unreadable/corrupt files (its do/catch … continue) rather than
        // crashing the load path.
        let dir = layout.managedSessionsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, …)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in try? writer.read(at: url) as ManagedAgentSessionRecord }
    }
}
```

```swift
// In ZoneRuntimeController — additions, not rewrites

// Property (alongside projectStore at line 9):
private var managedSessionStore: ManagedAgentSessionStore

// In init(root:acquireLock:) at line 54, after constructing projectStore:
self.managedSessionStore = ManagedAgentSessionStore(projectRoot: projectRoot)

// At tile spawn (wherever saveSession is called for a new terminal tile),
// also write the initial managed record:
let payload = ManagedAgentSessionRecord.makeRuntimePayload(
    windowTarget: capturedWindowTarget,   // the %pane_id from the target-capture seam
    cwd: descriptor.cwd
)
let record = ManagedAgentSessionRecord(
    tileId: descriptor.tileId,
    agentKind: .shell,                    // updated to .claude/.pi/etc. by the reader later
    status: .running,
    lastSeenAt: Date(),
    runtimePayload: payload
)
try? managedSessionStore.upsert(record)   // non-fatal; tile is live regardless

// In close() at line 78, alongside the lastExit write loop (lines 86–91):
for runtime in runtimes {
    if var record = try? managedSessionStore.load(tileId: runtime.tileId) {
        record.status = .stopped
        record.lastSeenAt = Date()
        try? managedSessionStore.upsert(record)
    }
}
```

The `upsert` at spawn uses `try?` because a failure to write the managed record is not fatal
— the tile is already live, and the consequence is only that lazy resume will fail honestly
on the next restart (branch 2 of the three-branch recovery: "no cursor, fail honestly").
The taint scan check will separately assert that no value of type
`ManagedAgentSessionRecord` is reachable from any spatial op or activity event by walking
their `Mirror` trees in a test. Add `ManagedAgentSessionRecord` to the taint scan's
forbidden-type list in the check defined by the taint scan ticket.

## How we test it

### Logic (pure Core checks)

Write a self-contained Core check (following the pattern in `ZoneRuntimeController`'s
`runHydrationLifecycleSelfCheck()` and `runSaveIsolationSelfCheck()`) that exercises the
store's full contract without any app or tmux involvement.

The check seeds a temporary project directory, constructs a `ManagedAgentSessionStore`, and
asserts the following in sequence, recording all measured values in a `manifest.json`:

1. **Round-trip**: write a record with a known `tileId`, `agentKind: .claude`, `status:
   .running`, a non-nil `resumeCursor` (arbitrary bytes), and a `runtimePayload` encoding a
   specific `tmuxWindowTarget` string (e.g. `"%42"`). Load it back. Assert byte-equality of
   the loaded record with the written one.
2. **Window-target extraction**: call `tmuxWindowTarget()` on the loaded record and assert
   it returns `"%42"` exactly.
3. **Upsert semantics**: write a second record for the same `tileId` with `status: .stopped`.
   Load it back. Assert `status == .stopped` and all other fields match the second write.
4. **Delete**: call `delete(tileId:)`. Assert `load(tileId:)` returns `nil`.
5. **Missing file**: call `load(tileId:)` for a UUID that was never written. Assert `nil`
   is returned, no exception thrown.
6. **loadAll**: write three records for three distinct tile IDs. Call `loadAll()`. Assert
   the result contains exactly three records. Count is a measured value in the manifest
   (`"loadAllCount": 3`), not a boolean.
7. **Sync-boundary isolation**: assert via `Mirror` reflection that
   `ManagedAgentSessionRecord` is not a case or associated value of any type in the spatial
   `Op` enum, and not a field on `AgentActivityEvent` or `ActivityTreeSnapshot`. If the
   op enum or activity types are not yet present (earlier tickets not yet landed), skip
   with a clearly logged note rather than a false pass.

The manifest must carry measured values: the raw bytes of the written and loaded record
(as hex strings), the extracted window target string, the loadAll count.

### Backend (real-path integration)

Spawn a real terminal tile through the full app path (using `TileSpawner` against a live
`ProjectStore` and `ZoneRuntimeController` on a temporary project root), confirm the tile
receives a tmux window target from the target-capture seam, then read the managed session
file on disk at `<projectRoot>/.continuum-revived/managed-sessions/<tileId>.json` and
assert: the file exists, it parses as a valid `ManagedAgentSessionRecord`, the
`tmuxWindowTarget()` accessor returns a non-empty string beginning with `%`, and the
`agentKind` is `.shell`. This must run against a real tmux daemon — no fake. It may be
gated behind the `gated real-tmux` harness flag consistent with the invariant spine.

Then call `controller.close()` and re-read the file. Assert `status == .stopped`.

Finally, assert that `ProjectStore` has no field named `tmuxWindowTarget`, `resumeCursor`,
or `runtimePayload` on `TerminalSessionDescriptor` or `AgentDescriptor` by loading the
session file written during the same spawn and verifying those keys are absent from the raw
JSON. This is the backend half of the sync-boundary assertion: what lands on disk in the
session file must not contain the private fields, because the session file is the type that
today's (pre-sync) code treats as the stable record. The managed-session file is a distinct
physical file.

### UX (visual gate and dogfood snippet)

There is no direct visual surface for this ticket — `ManagedAgentSessionRecord` is an
internal, host-local, never-projected record with no place in the sidebar, the canvas, or
any tile header. That is a fact to respect, not to route around: the sidebar's tile-status
seam (`WorkspaceSidebarView.statusPresentation` → `text(for:)`,
`WorkspaceSidebarView.swift:541–568`, read via `tileStatusTextForQA`,
`ContinuumApp.swift:5130–5157`) renders the **derived** `AgentStatus`
(`working` / `needs you` / `done` / `stale` / `unknown` / `no agent`) — it does **not**
render `agentKind`, there is no code path that turns an agent kind into a header label, and
nothing there renders the string `"shell"`. Do **not** invent a "tile-status derivation
function" that maps this record to a header label; no such seam exists, and asserting one
would be a fabricated gate.

The honest visual gate is therefore a **Component Lab fixture that renders the record's own
measurable fields** — a self-contained inspector card, not a hijack of the tile-status
surface. Add a `LabContent.staticCard` entry (the pattern at `ComponentLab.swift:23`, wired
through `LabCatalog.entries`, `ComponentLab.swift:354`) named e.g.
"Managed session record". Its `make: () -> NSView` closure loads the same canned
`ManagedAgentSessionRecord` the logic check wrote (or constructs an equivalent fixture) and
renders three text rows into an `NSView`:

- `agentKind` — rendered as its raw enum value (e.g. `"shell"`). This value comes straight
  off `record.agentKind.rawValue`; it is a field readout, **not** a derived status label.
- `status` — the narrow `ManagedSessionStatus.rawValue` (e.g. `"running"`).
- `tmuxWindowTarget` — the string returned by `record.tmuxWindowTarget()` (e.g. `"%42"`).

The gate asserts each of the three rows renders a **non-empty, non-crash** string and that
the values equal the fixture's inputs exactly (`agentKind` row == `"shell"` **because the
fixture's `agentKind` is `.shell`**, `status` row == `"running"`, `tmuxWindowTarget` row ==
the seeded `%`-prefixed value). Screenshot the card; the manifest records all three rendered
strings as measured values. The point of the gate is that the private record's fields
round-trip to a rendered surface faithfully — it explicitly does **not** claim the record
influences any production status label, because it must not.

Dogfood snippet: open the app on any project that already has a terminal tile. Open
Terminal.app alongside it. Navigate to the project's `.continuum-revived/managed-sessions/`
directory. Spawn a new tile in Continuum (File menu or the new-tile keybind). Within one
second of the tile appearing, a file named `<tileId>.json` should appear in
`managed-sessions/`. Open it with `cat` and confirm: `status` is `"running"`,
`runtimePayload` contains a key `tmuxWindowTarget` with a value beginning with `%`. Quit
Continuum. Reload the file and confirm `status` is `"stopped"`. If no file appears, the
upsert-at-spawn path is broken; if the file appears but `tmuxWindowTarget` is absent, the
payload packing from the target-capture seam is not wired.

## Execution mode

Autonomous. The logic check is a pure Core self-check with no UI, no live agent, and no
cloud dependency. The backend check requires a real tmux daemon but uses the existing
gated real-tmux harness path, which the invariant spine already provisions. The taint scan
check is a pure type-reflection walk. All three produce manifests with measured values.
No human eyes are required for the pass/fail determination; the manifest is the verdict.

## Done when

- [ ] The D14 `enum AgentKind` prerequisite is confirmed present in `Sources/` (it does not
  exist today) — this box is the gate that stops the ticket from starting against a `String`.
- [ ] `ManagedAgentSessionRecord` and `ManagedSessionStatus` are defined in
  `Sources/ContinuumRevivedCore/ManagedAgentSessionRecord.swift`, compile cleanly (which
  requires `AgentKind` to resolve, per the box above), and pass the round-trip and
  window-target-extraction assertions in the logic check.
- [ ] `ManagedAgentSessionStore` is defined in
  `Sources/ContinuumRevivedCore/ManagedAgentSessionStore.swift`, backed by `AtomicWriter`,
  and passes all seven logic-check assertions (round-trip, upsert, delete, missing-file nil,
  loadAll count = 3 as a measured value).
- [ ] `ProjectStoreLayout` exposes `managedSessionsDirectory` and
  `managedSessionFile(tileId:)` alongside the analogous session-file members.
- [ ] `ZoneRuntimeController` holds a `ManagedAgentSessionStore` property, writes an
  initial record at tile spawn with a non-nil `runtimePayload` encoding the
  `tmuxWindowTarget`, and updates each record's status to `.stopped` and bumps
  `lastSeenAt` in `close()`.
- [ ] `TerminalSessionDescriptor` and `AgentDescriptor` have gained no new fields as a
  result of this ticket (verified by the backend check's raw-JSON assertion).
- [ ] The logic check's sync-boundary Mirror assertion either passes (no `ManagedAgentSessionRecord`
  reachable from `Op` or activity types) or is logged as a conditional skip with a clear
  reason (prerequisite tickets not yet landed) — a false pass is not acceptable.
- [ ] The backend real-tmux check passes: the managed session file exists on disk within
  one second of tile spawn, `tmuxWindowTarget()` returns a non-empty `%`-prefixed string,
  and `status` updates to `"stopped"` after `controller.close()`.
- [ ] A qa-run manifest exists with the following measured keys at non-degenerate values:
  `roundTripBytesMatch: true`, `extractedWindowTarget: "%42"` (or whatever the test seeded),
  `loadAllCount: 3`, `syncBoundaryViolationsFound: 0`, and the three fixture-card readouts
  (`labAgentKindRendered: "shell"`, `labStatusRendered: "running"`,
  `labWindowTargetRendered: "%42"`).
- [ ] The Component Lab "Managed session record" fixture card renders all three field rows
  (`agentKind`, `status`, `tmuxWindowTarget`) as non-empty, non-crash strings equal to the
  fixture's inputs, and the manifest records all three rendered strings as measured values.
  The card renders record fields only; it asserts no influence on any production status label.

## Depends on / unblocks

This ticket depends on the window-target capture seam being complete and providing a
durable `tmuxWindowTarget` string at spawn time. Without that seam, the `runtimePayload`
at spawn will be nil, which means the backend check for `tmuxWindowTarget` cannot pass.
It also depends on the sync and observation type split having established the `Op` enum
and the `AgentActivityEvent` type, so the Mirror-based taint assertion has real types to
walk. If those types are absent, the taint assertion skips conditionally as described above.

**Hard prerequisite — the agent-kind closed enum (D14) must land before this ticket.**
`ManagedAgentSessionRecord.agentKind` is typed as `AgentKind`, and `enum AgentKind` does
not exist in `Sources/` today — `agentKind` is a free `String` at
`TerminalSessionDescriptor.swift:95` and at the spawn seams (`LaunchProfileSpec.swift`,
`TileSpawner`). Because of that, this ticket **cannot** satisfy its own "compile cleanly"
bar, nor the logic-check literal `agentKind: .claude`, nor the spawn-path literal `.shell`,
until D14 has introduced `enum AgentKind` (see "Where it lives" for the exact shape). This
is not a soft "prefer" ordering — an agent handed this ticket in isolation, before D14, will
not be able to name the type and must stop rather than substitute a `String` or define a
throwaway enum. The workflow must schedule D14 first; the two are not independently
buildable. Attempting to land this one first would require a placeholder type that D14 then
has to reconcile — avoid that entirely by respecting the order.

This ticket directly unblocks the lazy-resume-on-focus ticket, which reads a
`ManagedAgentSessionRecord` from the store to execute its three-branch recovery logic. It
also unblocks the idle reaper ticket, which reads `lastSeenAt` and `status` to determine
which sessions to detach. Neither of those tickets can make meaningful progress without a
concrete, persisted record to load.

## Watch out for

**The hardest thing: keeping `runtimePayload` truly opaque in the core while still
providing the `tmuxWindowTarget()` accessor without leaking interpretation into the wrong
layer.** The accessor defined on `ManagedAgentSessionRecord` decodes only
`RuntimePayloadFields` — a type that lives in Core because the window target is a
Core-level concern (it is needed for I1, the binding-bijection invariant). Additional
adapter-specific payload fields (`modelSelection`, adapter session tokens) must never be
decoded in Core; they are decoded only by the adapter in the managed tier, which is a
later ticket. Do not add adapter-specific fields to `RuntimePayloadFields`. Encode them
alongside the Core fields using the "unknown keys survive round-trip" property of
`JSONDecoder`'s default behavior — this is not an assumption to make lightly, so the
round-trip logic check must include a test that seeds extra keys in the JSON and confirms
they survive a decode→encode cycle.

**Stop condition — do not add `tmuxWindowTarget` to `TerminalSessionDescriptor`.** If the
window-target capture seam landed `tmuxWindowTarget` as a field on the session descriptor,
that is a sync-boundary violation and must be removed as part of this ticket, not accepted
as-is. The descriptor is (or will become) a synced type; the window target is a private,
host-local handle. The right home is `ManagedAgentSessionRecord.runtimePayload`.

**Stop condition — do not invent a `ManagedAgentSessionRecord` field on `Tile` or
`CanvasState`.** These types are the spatial layer and will sync. If an earlier ticket
added a placeholder field there, remove it.

**`AtomicWriter` directory creation order.** The managed-sessions directory does not exist
on a fresh project. The `upsert` implementation must call
`FileManager.default.createDirectory(at: managedSessionsDirectory,
withIntermediateDirectories: true)` before the first write, exactly as `ProjectStore` does
for `sessionsDirectory`. Forgetting this causes `AtomicWriter` to fail silently (or throw)
on every new project, which means the record is never persisted and the backend check fails.

**`loadAll` corruption tolerance.** `loadAll` must skip individual corrupt files with a
log, not abort the entire load. A corrupt file can arrive if the app crashed mid-write. The
`AtomicWriter` backup mechanism reduces this risk but does not eliminate it; `loadAll`'s
`compactMap { try? … }` pattern is intentional and must not be changed to `map { try … }`.

**The managed-session store must not be shared across projects.** Each
`ZoneRuntimeController` owns its own `ManagedAgentSessionStore` scoped to its `projectRoot`.
Records from one project are invisible to another project's controller. This mirrors the
per-project isolation of `ProjectStore`.
