# Activity tree snapshot type

## What this delivers

A new `ActivityTreeSnapshot` type that carries the full sidebar tree — every workspace, zone, and tile row — together with the *evidence* behind each tile's status verdict. Before this ticket, a status in the tree is a bare enum value with no indication of what backed it: a caller cannot tell whether `working` came from a fresh file read two seconds ago or from a stale observation retained through a restart. After this ticket, every tile row in the snapshot bundles an `AgentSnapshot.Evidence` value alongside its `AgentStatus`, so the derivation function, the invariant spine, and any future observer can all verify the claim rather than trusting it. The snapshot is fully `Codable`, satisfies the I7 round-trip invariant, and is I5-clean — it carries zero pids, pane targets, host handles, or transcript bodies. This is a pure data-model addition to `SidebarTree.swift` in `ContinuumRevivedCore`; it ships no UI and touches no live observers.

## How it fits

This ticket builds directly on the agent-state-reader-protocol ticket. That ticket defines the `AgentSnapshot` type (with its nested `Evidence` struct: `source`, `lastEventType: String?`, `mtimeAgeSeconds: Double`) as the canonical, I5-clean output of any reader — it is the file that declares `AgentSnapshot.Evidence`, not the sync/observation type split (the split defines the separate `AgentActivityEvent` / `ActivityStore` observation layer and does not mention `AgentSnapshot` at all). The activity tree snapshot consumes the reader-protocol type: it lifts the per-tile `AgentSnapshot` into each `SidebarTileRow` and adds a top-level `ActivityTreeSnapshot` envelope that makes the whole tree serializable and verifiable as a unit.

Without this ticket, the invariant spine harness has no way to satisfy I6 ("every `working`/`done`/`needsAttention` is backed by fresh evidence") at the tree level — it can check individual `AgentSnapshot` values but cannot inspect the tree wholesale. Without this ticket, the session topology snapshot type also lacks its sibling: the architecture calls for *two* reconciliation oracles, one on the tmux side and one on the activity side, and the latter is what this ticket delivers. The feed-the-sidebar-tree-from-the-observer ticket (the Phase 4 work that renders the live dock) depends on this snapshot existing so the observer can write a `ActivityTreeSnapshot` and the dock can render from it rather than from raw mutable state.

## The approach

Extend the existing `SidebarTileRow` with an optional `evidence` field typed as `AgentSnapshot.Evidence`. The field is optional because not every tile is an observed agent — a plain `.terminal` tile with no reader produces no evidence, and that is represented as `nil` rather than a synthesized placeholder. `SidebarTileRow` gains `Codable` conformance; since it already carries `AgentStatus?` (which is `Codable`) and all its other fields are `String`, `UUID`, and `TileKind` (all `Codable`), the conformance is synthesized with no manual implementation.

`SidebarAgentStatusRollup`, `SidebarZoneRow`, `SidebarWorkspaceRow`, and `SidebarTree` all gain `Codable` conformance by the same logic — every field is already a codable primitive or a type that becomes codable in this ticket. No stored properties change shape; conformance is additive.

The new `ActivityTreeSnapshot` wraps a `SidebarTree` with a `capturedAt` date (the evidence clock, always a file mtime, never `Date.now()` — consistent with the clock discipline established by the readers), a `replicaId` string (reserved for the op-log context, populated with the host's stable device identity when the snapshot is produced by a real observer, empty string in tests), and a top-level `rollup` that summarizes the entire snapshot's attention state. The rollup is derived eagerly at construction time from the tree so callers never recompute it.

`AgentSnapshot.Evidence` is defined in the agent-state-reader-protocol ticket, but this ticket must declare a local copy of the minimal shape if `AgentSnapshot.Evidence` from that ticket has not yet landed, and remove the duplicate once it has. The forward-declaration trigger is keyed to the presence of `AgentSnapshot.Evidence` specifically — not to any other Phase 3 ticket — because that is the only ticket that ships the type. The ticket notes this dependency explicitly rather than leaving it as a silent assumption.

`SidebarTreeBuilder` gains an overload that accepts `[UUID: AgentSnapshot]` (keyed by tile id) alongside the existing `[UUID: AgentStatus]` overload. The new overload threads `snapshot.evidence` into each `SidebarTileRow` and derives `AgentStatus` from `snapshot.status` — the caller no longer maintains two separate maps. The old overload is preserved unchanged so no existing call site breaks.

## Where it lives

All changes are confined to `Sources/ContinuumRevivedCore/SidebarTree.swift`. No other source file is modified by this ticket.

Existing symbols extended:
- `SidebarTileRow` (line 78) — adds `public var evidence: AgentSnapshot.Evidence?`; gains `Codable`
- `SidebarAgentStatusRollup` (line 21) — gains `Codable`
- `SidebarZoneRow` (line 92) — gains `Codable`
- `SidebarWorkspaceRow` (line 114) — gains `Codable`
- `SidebarTree` (line 126) — gains `Codable`
- `SidebarTreeBuilder` (line 134) — adds the `agentSnapshots:` overload

New symbols added in the same file:
- `ActivityTreeSnapshot` — a `Codable, Equatable, Sendable` struct wrapping `SidebarTree` with `capturedAt: Date`, `replicaId: String`, and `rollup: SidebarAgentStatusRollup`
- `ActivityTreeSnapshot.make(tree:capturedAt:replicaId:)` — static factory that derives `rollup` from the tree and constructs the envelope

If `AgentSnapshot.Evidence` is not yet available from the agent-state-reader-protocol ticket, declare it inline in `SidebarTree.swift` as a forward declaration:

```swift
// Temporary forward declaration — remove once AgentSnapshot.Evidence
// from the agent-state-reader-protocol ticket lands.
public extension AgentSnapshot {
    struct Evidence: Codable, Equatable, Sendable {
        public var source: String
        public var lastEventType: String?
        public var mtimeAgeSeconds: Double
    }
}
```

This forward declaration lives at the top of `SidebarTree.swift`, above the `SidebarAgentStatusKind` definition, and is removed as a mechanical cleanup step once the agent-state-reader-protocol ticket merges. Do not tie the removal to the sync/observation type split landing — that split never defines `AgentSnapshot.Evidence`, so treating it as satisfied would leave you compiling against a type that still does not exist.

## Implementation breadcrumbs

The implementation follows this exact order. Do not reorder — each step compiles independently.

**Step 1.** Add `Codable` conformance to every existing struct in `SidebarTree.swift`. Because all stored properties are already `Codable`, the conformance is synthesized; just add `: Codable` to each struct declaration. Add conformance in bottom-up order: `SidebarAgentStatusKind` (it's an enum with a `String` raw value, so `Codable` is also synthesized), `SidebarAgentStatusRollup`, `SidebarTileRow`, `SidebarZoneRow`, `SidebarWorkspaceRow`, `SidebarTree`.

**Step 2.** Add `evidence: AgentSnapshot.Evidence?` to `SidebarTileRow`. Place it after `agentStatus`. Update the designated `init` to accept `evidence: AgentSnapshot.Evidence? = nil`. This is source-compatible — all existing call sites that don't pass `evidence` continue to compile.

**Step 3.** Define `ActivityTreeSnapshot` after the `SidebarTree` definition:

```swift
public struct ActivityTreeSnapshot: Codable, Equatable, Sendable {
    public let tree: SidebarTree
    public let capturedAt: Date          // file-mtime clock, not Date.now()
    public let replicaId: String         // stable device id; empty string in tests
    public let rollup: SidebarAgentStatusRollup   // derived at construction, not stored raw

    public static func make(
        tree: SidebarTree,
        capturedAt: Date,
        replicaId: String
    ) -> ActivityTreeSnapshot {
        let allStatuses = tree.workspaces
            .flatMap(\.zones)
            .flatMap(\.tiles)
            .compactMap(\.agentStatus)
        let rollup = SidebarAgentStatusRollup.make(statuses: allStatuses)
        return ActivityTreeSnapshot(tree: tree, capturedAt: capturedAt, replicaId: replicaId, rollup: rollup)
    }
}
```

**Step 4.** Add the `agentSnapshots:` overload to `SidebarTreeBuilder`. Place it directly below the existing `build(registry:documents:projectCanvases:agentStatusesByTileId:)` method:

```swift
public static func build(
    registry: Registry,
    documents: [UUID: WorkspaceDocument],
    projectCanvases: [UUID: CanvasState] = [:],
    agentSnapshots: [UUID: AgentSnapshot]       // keyed by tile id
) -> SidebarTree {
    // Derive the agentStatusesByTileId map from snapshots so the existing
    // build path handles all the zone/tile assembly logic unchanged.
    let statusMap = agentSnapshots.mapValues(\.status)
    // Re-use the existing builder to produce the tree structure.
    var tree = build(
        registry: registry,
        documents: documents,
        projectCanvases: projectCanvases,
        agentStatusesByTileId: statusMap
    )
    // Thread evidence into each tile row. Walk every tile by id and attach.
    for wi in tree.workspaces.indices {
        for zi in tree.workspaces[wi].zones.indices {
            for ti in tree.workspaces[wi].zones[zi].tiles.indices {
                let tileId = tree.workspaces[wi].zones[zi].tiles[ti].tileId
                tree.workspaces[wi].zones[zi].tiles[ti].evidence =
                    agentSnapshots[tileId]?.evidence
            }
        }
    }
    return tree
}
```

Note: `SidebarTree`, `SidebarWorkspaceRow`, `SidebarZoneRow` must have `var` (not `let`) collections for the index-mutation to work. They already use `var tiles: [SidebarTileRow]` and `var zones: [SidebarZoneRow]`; verify and change `workspaces` on `SidebarTree` to `var` if it is currently `let`.

**Step 5.** Verify the file compiles cleanly with no other changes. Run `swift build --target ContinuumRevivedCore`. If `AgentSnapshot.Evidence` from the agent-state-reader-protocol ticket is not yet available, add the forward declaration from the seams section above.

## How we test it

### Logic (pure Core checks)

All tests live in `Tests/ContinuumRevivedCoreTests/ActivityTreeSnapshotTests.swift`. They use no real files, no tmux, no clock calls — everything is constructed inline.

**Round-trip (I7).** Construct an `ActivityTreeSnapshot` with two workspaces, three zones, five tiles, three of which carry evidence values. Encode with `JSONEncoder`, decode with `JSONDecoder`, assert `decoded == original`. This test is the literal I7 invariant. Run it on every configuration: all evidence present, no evidence present, mixed.

**Rollup derivation.** Build an `ActivityTreeSnapshot.make(tree:capturedAt:replicaId:)` where the tree has two `needsAttention` tiles, one `working` tile, and two tiles with `nil` agentStatus. Assert `rollup.needsAttention == 2`, `rollup.working == 1`, `rollup.unknown == 0` (nil status tiles do not contribute). Assert `rollup.dominantKind == .needsAttention`.

**Evidence threading.** Call `SidebarTreeBuilder.build(registry:documents:projectCanvases:agentSnapshots:)` with a synthetic registry containing two tiles, one with a full `AgentSnapshot` (kind `.claude`, status `.working`, evidence with source `"claude:sessions/pid.json"`, `lastEventType: "assistant"`, `mtimeAgeSeconds: 12.4`) and one with no snapshot. Assert the first tile's `evidence` is non-nil and its `source` equals `"claude:sessions/pid.json"`. Assert the second tile's `evidence` is nil. Assert both tiles carry the expected `agentStatus`.

**I5 taint scan (snapshot shape).** Encode an `ActivityTreeSnapshot` to JSON. Assert the JSON string contains none of the strings `"pid"`, `"paneId"`, `"windowTarget"`, `"content"`, `"body"`, `"prompt"`. This is a string-search taint check on the serialized form, not just on the type — it catches any future field added to `Evidence` that accidentally includes a forbidden key name.

**Codable conformance of each struct independently.** Write one round-trip test per struct: `SidebarAgentStatusRollup`, `SidebarZoneRow`, `SidebarWorkspaceRow`, `SidebarTree`. This catches any future field addition to these structs that breaks `Codable` synthesis before it reaches the snapshot test.

### Backend (real-path integration)

This ticket's scope is a pure data-model addition — it writes no files, touches no tmux, and has no observer — so there is no backend integration path to drive in isolation. The backend check for this type is instead defined as a contract that the invariant spine harness will exercise once the observer lands: "every `ActivityTreeSnapshot` produced by a live `SessionObserver` round-trips cleanly and satisfies I7." That contract is named here so the spine harness ticket can wire it in. Until then, the logic tests above are the proof.

What this ticket does provide for the backend path: the `ActivityTreeSnapshot.make` factory is written so a future observer needs only to call it with the tree it already holds and its device's stable id — the contract is simple enough to test now and trust later.

### UX (visual gate + dogfood snippet)

This ticket adds no UI, so there is no rendered dock to gate visually — the pixel-level visual gate for the sidebar lives in the two downstream tickets that actually draw it: feed the sidebar tree from the observer, and render the left dock. Those tickets carry the "open the app, look at the dock" gate.

But the strict bar still requires a concrete, do-this-see-this dogfood snippet in *this* ticket, and there is one that a developer can run against the pure data model without any rendering path. It exercises the exact deliverables — the `agentSnapshots:` overload, evidence threading, and the `ActivityTreeSnapshot.make` envelope — and shows the human the evidence that used to be invisible. Run it as a one-off test or from a scratch executable in the package:

```swift
// Dogfood: prove evidence is now attached and serialized, by eye.
let tree = SidebarTreeBuilder.build(
    registry: demoRegistry,          // two workspaces, one zone, three tiles
    documents: demoDocuments,
    agentSnapshots: [
        claudeTileId: AgentSnapshot(
            kind: .claude, status: .working, title: "refactor auth", mode: "normal",
            asOf: fixedMtime, detail: nil,
            evidence: .init(source: "claude:sessions/pid.json",
                            lastEventType: "assistant", mtimeAgeSeconds: 12.4)),
        // terminalTileId intentionally omitted → no reader → nil evidence
    ]
)
let snap = ActivityTreeSnapshot.make(tree: tree, capturedAt: fixedMtime, replicaId: "")
let json = String(data: try JSONEncoder().encode(snap), encoding: .utf8)!
print(json)
```

What you should see, by eye, in the printed JSON:
- The Claude tile carries an `evidence` object with `"source":"claude:sessions/pid.json"`, `"lastEventType":"assistant"`, `"mtimeAgeSeconds":12.4` — the status is no longer a bare enum, the backing is visible.
- The plain terminal tile has no `evidence` key (it is `nil`, not a synthesized placeholder).
- The top-level `rollup` reads `"working":1`, `"needsAttention":0` — derived from the tree, not hand-set.
- A search of the printed string for `pid`, `paneId`, `windowTarget`, `content`, `body`, `prompt` returns nothing — the I5 shape guarantee, confirmed by human eye on the same output the automated taint scan asserts.

This is the honest dogfood for a pure data-model ticket: the developer reads the serialized snapshot and confirms the evidence is present, the negatives are truly absent, and no forbidden field leaked — the same claim the rendered dock will later make visually, verifiable now without any UI. The rendered-dock visual gate is deferred to the feed-the-sidebar-tree and render-the-left-dock tickets, as noted above.

## Execution mode

**Autonomous.** Every deliverable in this ticket is a pure Swift data-model addition in `ContinuumRevivedCore`. There are no UI changes, no tmux calls, no file I/O, no real agents, no cloud accounts, and no device required. The correctness proof is a set of `XCTest` logic checks: round-trip encode/decode, rollup arithmetic, evidence threading, and the I5 taint scan. All of these run in the Swift test runner against in-memory data structures. A green matrix is both necessary and sufficient — no human eyes are needed to verify data-model correctness.

## Done when

- [ ] `ActivityTreeSnapshot` compiles in `ContinuumRevivedCore` with `Codable, Equatable, Sendable` conformances.
- [ ] `ActivityTreeSnapshot.make(tree:capturedAt:replicaId:)` correctly derives `rollup` from the tree's tile statuses, verified by the rollup-derivation test.
- [ ] `SidebarTileRow` carries `evidence: AgentSnapshot.Evidence?` and remains source-compatible — all existing call sites compile without changes.
- [ ] `SidebarTreeBuilder.build(registry:documents:projectCanvases:agentSnapshots:)` overload exists and threads `AgentSnapshot.evidence` into each corresponding `SidebarTileRow`.
- [ ] I7 round-trip test passes: encode → decode → equal for `ActivityTreeSnapshot`, tested with mixed evidence (some tiles have evidence, some do not).
- [ ] Rollup-derivation test passes with the exact counts asserted above.
- [ ] Evidence-threading test passes: the snapshot-bearing tile has non-nil evidence with the expected `source` string; the tile with no snapshot has nil evidence.
- [ ] I5 taint scan passes: JSON encoding of a populated `ActivityTreeSnapshot` contains none of the forbidden key names.
- [ ] `swift build --target ContinuumRevivedCore` and `swift test --filter ActivityTreeSnapshotTests` both pass clean with zero warnings introduced by this ticket.
- [ ] If the forward `AgentSnapshot.Evidence` declaration was added, a TODO comment marks it for removal once the agent-state-reader-protocol ticket lands.

## Depends on / unblocks

This ticket depends on the agent-state-reader-protocol ticket, which defines `AgentSnapshot` and its nested `Evidence` struct (`source`, `lastEventType: String?`, `mtimeAgeSeconds: Double`) — the type that `SidebarTileRow.evidence` is typed against. That is the sole source of `AgentSnapshot.Evidence`; the sync/observation type split is a different ticket that defines the `AgentActivityEvent` / `ActivityStore` observation layer and never declares `AgentSnapshot`, so it must not be named as the source here. If the agent-state-reader-protocol ticket has not yet merged, the forward declaration in the seams section bridges the gap and is removed once `AgentSnapshot.Evidence` specifically lands.

This ticket is a prerequisite for the invariant spine harness: the spine's I6 check at the tree level (every claimed status is backed by fresh evidence) needs the `evidence` field on `SidebarTileRow` to exist before it can walk the snapshot and assert. Without this ticket, the harness can only check individual `AgentSnapshot` values, not the assembled tree.

This ticket also directly unblocks the feed-the-sidebar-tree-from-the-observer work. That ticket drives the `SessionObserver`'s output into the tree builder; it can use the `agentSnapshots:` overload introduced here to produce a fully-evidenced tree in one call rather than maintaining a separate status map.

## Watch out for

**The clock.** `capturedAt` on `ActivityTreeSnapshot` must be set to the file mtime of the most recently read evidence file — never to `Date()`. The architecture bans wall-clock "now" in the core (consistent with the fake-clock substrate and the configurable-first doctrine). A test that constructs a snapshot with `capturedAt: Date()` should instead use a fixed date literal. If the field is ever set to `Date.now()` at an observer call site, the staleness calculation (`now - asOf`) becomes trivially zero and stale detection silently breaks.

**Mutability of the tree.** The evidence-threading step in the `agentSnapshots:` overload walks the tree by index and mutates individual `SidebarTileRow.evidence` values. This requires `var` collections all the way down: `SidebarTree.workspaces`, `SidebarWorkspaceRow.zones`, and `SidebarZoneRow.tiles` must all be `var`. `SidebarTree.workspaces` is currently declared as a stored property without a mutability annotation; check whether it is `var` or `let` and change it to `var` if needed. Failing to do this will produce a compile error in the overload that is confusing to diagnose if you don't already know the root cause.

**The forward declaration lifecycle.** If the `AgentSnapshot.Evidence` forward declaration is added because the agent-state-reader-protocol ticket hasn't landed yet, it must not be left permanently. Mark it with a `// TODO: remove once AgentSnapshot.Evidence from the agent-state-reader-protocol ticket is available` comment directly above the declaration. Key the removal to `AgentSnapshot.Evidence` existing — not to the sync/observation type split merging, which never delivers that type. When the agent-state-reader-protocol ticket does merge, the removal is mechanical: delete the forward declaration block and verify the build is clean. Leaving it in place will cause a redefinition error the moment `AgentSnapshot.Evidence` is defined in its home file (`AgentStateReader.swift`).

**I5 is a shape guarantee, not a runtime check.** The taint scan in the logic tests checks the JSON output of a real encoded value, which is the honest proof. Do not substitute a structural inspection of `AgentSnapshot.Evidence`'s field names — that would only check the current fields, not catch a future field addition. The string-search on the encoded JSON catches any field at any depth.
