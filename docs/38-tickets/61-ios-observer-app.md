# iOS observer app — thin fleet-list client over the activity projection

## What this delivers

After this ticket lands, there is a working iOS application — a separate target in the Xcode project — that subscribes to the activity projection the Mac host publishes and renders a live, attention-first grouped list of every workspace, zone, and agent the host knows about. Tapping any agent row opens a read-only structured transcript showing its message and tool-call cards pulled from the same projection. A `needsAttention` agent's detail screen shows its sanitized approval request and the status glyph changes from the fleet list in real time as agents move through phases. The phone never spawns a tmux session, never drives an agent, and cannot mutate spatial state — the `Scope` OptionSet makes that guarantee at the type level, not a runtime conditional.

The system outcome is that the user can pick up their iPhone while agents run on the Mac (or a remote VPS), see immediately which one needs them, and read exactly what it was doing when it stopped — all from the same projection the Mac sidebar already consumes, with no new server and no new protocol.

## How it fits

This ticket sits at the top of the Phase 6 dependency stack. It requires the activity projection over transport to already exist and deliver a snapshot-then-tail stream to observers, and it requires the `Scope` OptionSet model to be defined so the iOS session can be granted `.observe` at pairing time. Both of those ship immediately before this ticket in Phase 6.

The projection this app subscribes to is the same `ActivityTreeSnapshot` the Mac sidebar's `SidebarTreeBuilder` consumes — defined in the sync/observation type split ticket and carried over the CloudKit transport by the activity-projection-over-transport ticket. The iOS app adds no new projection logic; it is a new renderer of an already-specified data shape.

What this ticket unblocks is equally concrete. The iOS approve action ticket — the symmetric `respondToApproval` command dispatched from the phone — depends on this observer being present and connected, because the approval dock only appears inside an agent detail screen that this ticket builds. The APNS push service ticket depends on having a registered device to push to, and the deep-link validation ticket depends on having a navigation stack to route into. All three follow directly from this one landing.

The iOS fleet list is also the mobile analog of the activity surface (the persistent left dock on Mac): same `SidebarTree` model, same precedence ladder (`needsAttention` → `working` → `stale` → `done` → `unknown`), same six glyphs and colors — just rendered as a `UITableView`/`List` rather than an `NSOutlineView`. The design decision made in the UX analysis holds: a phone needs this tree, not the 2D canvas.

## The approach

The iOS app is a new Xcode target — `ContinuumObserver` — sharing `ContinuumRevivedCore` as a Swift package dependency. It introduces no new shared types; it only adds a thin SwiftUI application layer that subscribes to `ActivityStoreProtocol.subscribe()`, maps the `ActivityTreeSnapshot` through the same `SidebarTreeBuilder.build(...)` call the Mac uses, and renders the result.

The connection to the host is the CloudKit private database transport already defined in the transport ticket. The iOS app creates an `ActivityStore` client (the read-only subscriber side of `ActivityStoreProtocol`) authenticated via the user's iCloud account — no pairing needed for the observation leg, because iCloud account identity is the shared secret. The `Scope` OptionSet established in ticket 59 gates the control leg: the phone holds `.observe` only, enforced by the type, until the pairing-token model (ticket 60) ships and expands scope to include `.approveActions`.

The fleet list sorts attention-first in a single pass: `needsAttention` rows first, then `working`, then all others in their natural workspace/zone order. This sort is a pure function over the `SidebarTree` — no special iOS logic, just the same `dominantKind` precedence the rollup already encodes.

Observed shell tiles display their metadata (agent kind glyph, title, phase text) but show "No transcript available" in place of the card list, with an honest explanatory note. Managed agent tiles show the full card list from the projection. This distinction is made by checking `TileActivity.agentKind` from the `ActivityTreeSnapshot` — managed agents have a populated `transcript` field; shell tiles do not, by construction of the activity event type.

The transcript card taxonomy on iOS mirrors the Mac managed tile exactly: message cards, tool-call cards (collapsed by default, tap to expand), plan cards, and diff cards — rendered as SwiftUI views rather than AppKit views, but sharing the same structural logic. Read-only means no input field, no approval dock (that ships in ticket 62), and no send button anywhere in this target.

## Where it lives

**New target:**

- `ContinuumObserver/` — new Xcode target, SwiftUI lifecycle, iOS 17+ deployment target
- `ContinuumObserver/ContinuumObserverApp.swift` — `@main` entry, sets up the `ActivityStoreClient` and injects it via environment
- `ContinuumObserver/FleetListView.swift` — root `List` grouped by `SidebarWorkspaceRow`, sections for zones, rows for tiles, sorted attention-first
- `ContinuumObserver/AgentDetailView.swift` — read-only transcript, driven by `TileActivity` from the snapshot; shows "No transcript available" for shell tiles
- `ContinuumObserver/TranscriptCardView.swift` — renders each `AgentActivityEvent` as the appropriate card kind (message / tool-call / plan / diff)
- `ContinuumObserver/StatusGlyphView.swift` — the six-state glyph+color rendering, shared by the fleet row and the detail header; reuses the exact palette from `docs/38-ux-analysis.md` §0

**Existing seams this ticket reads but does not modify:**

- `Sources/ContinuumRevivedCore/SidebarTree.swift:134` — `SidebarTreeBuilder.build(registry:documents:projectCanvases:agentStatusesByTileId:)` is called on iOS with the same signature; `SidebarTree`, `SidebarWorkspaceRow`, `SidebarZoneRow`, `SidebarTileRow` are the model types the fleet list renders directly
- `Sources/ContinuumRevivedCore/SidebarTree.swift:42` — `SidebarAgentStatusRollup.dominantKind` drives section header color and the attention-first sort key
- `Sources/ContinuumRevivedCore/SidebarTree.swift:51` — `SidebarAgentStatusRollup.displayText` is the section header subtitle ("1 working · 1 needs you")
- `Sources/ContinuumRevivedCore/SidebarTree.swift:3` — `SidebarAgentStatusKind` is the sort key enum; the fleet list sort maps `.needsAttention` → priority 0, `.working` → 1, all others → 2
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85` — `AgentStatus` is the six-case enum whose glyphs and colors `StatusGlyphView` renders verbatim
- `Sources/ContinuumRevivedCore/AgentActivityEvent.swift` (from ticket 8) — `ActivityTreeSnapshot`, `TileActivity`, and `ActivityStreamItem` are the types the observer subscribes to; `TileActivity.transcript: [AgentActivityEvent]?` is nil for shell tiles, populated for managed agents
- `Sources/ContinuumRevivedCore/ActivityStore.swift` (from ticket 8) — `ActivityStoreProtocol.subscribe()` returns `AsyncStream<ActivityStreamItem>` which drives the SwiftUI `@StateObject` view model

## Implementation breadcrumbs

```swift
// ContinuumObserverApp.swift — set up the store client and push it into the environment
@main struct ContinuumObserverApp: App {
    @StateObject private var fleetModel = FleetModel()
    var body: some Scene {
        WindowGroup { FleetListView().environmentObject(fleetModel) }
    }
}

// FleetModel.swift — observable wrapper around the projection stream
@MainActor final class FleetModel: ObservableObject {
    @Published var tree: SidebarTree = SidebarTree(workspaces: [])
    private var task: Task<Void, Never>?

    func connect(store: any ActivityStoreProtocol) {
        task = Task {
            for await item in store.subscribe() {
                switch item {
                case .snapshot(let snap):
                    // SidebarTreeBuilder.build uses the snapshot's byTile dictionary
                    tree = SidebarTreeBuilder.build(
                        registry: snap.registry,
                        documents: snap.documents,
                        agentStatusesByTileId: snap.byTile.mapValues(\.status)
                    )
                case .event(let event):
                    // apply incremental delta — update the specific tile row
                    tree = applyEvent(event, to: tree)
                }
            }
        }
    }
}

// FleetListView.swift — attention-first sort, grouped by workspace then zone
struct FleetListView: View {
    @EnvironmentObject var model: FleetModel

    var sortedWorkspaces: [SidebarWorkspaceRow] {
        model.tree.workspaces  // workspace order preserved; zone/tile rows sorted within
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedWorkspaces, id: \.workspaceId) { workspace in
                    Section(header: WorkspaceHeaderView(row: workspace)) {
                        ForEach(attentionFirstZones(workspace.zones), id: \.zoneId) { zone in
                            ZoneSection(zone: zone)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Agents")
        }
    }

    // Sort zones by dominantKind priority; tiles within each zone by the same key
    func attentionFirstZones(_ zones: [SidebarZoneRow]) -> [SidebarZoneRow] {
        zones
            .map { zone in
                var z = zone
                z.tiles = zone.tiles.sorted { a, b in
                    priority(a.agentStatus) < priority(b.agentStatus)
                }
                return z
            }
            .sorted { priority($0.agentStatusRollup.dominantKind) < priority($1.agentStatusRollup.dominantKind) }
    }

    // needsAttention=0, working=1, everything else=2
    func priority(_ kind: SidebarAgentStatusKind?) -> Int { ... }
    func priority(_ status: AgentStatus?) -> Int { ... }
}

// AgentDetailView.swift — read-only transcript, nil transcript shows honest note
struct AgentDetailView: View {
    let tileRow: SidebarTileRow
    @EnvironmentObject var model: FleetModel

    var tileActivity: TileActivity? {
        model.currentSnapshot?.byTile[tileRow.tileId]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Persistent status header — same anatomy as the Mac managed tile
            AgentDetailHeaderView(row: tileRow)
            Divider()
            if let transcript = tileActivity?.transcript, !transcript.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(transcript) { event in
                            TranscriptCardView(event: event)
                        }
                    }
                    .padding()
                }
            } else {
                // Shell tiles, or managed tiles with no events yet
                ContentUnavailableView(
                    "No transcript",
                    systemImage: "terminal",
                    description: Text("This agent runs in a terminal tile. Its transcript isn't available in the observer.")
                )
            }
        }
        .navigationTitle(tileRow.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// StatusGlyphView.swift — the single source of glyph/color truth on iOS
struct StatusGlyphView: View {
    let status: AgentStatus
    // Glyphs and colors from docs/38-ux-analysis.md §0 — verbatim
    var glyph: String {
        switch status {
        case .working:        return "●"
        case .needsAttention: return "◆"
        case .done:           return "✓"
        case .stale:          return "◌"
        case .configuring:    return "◍"
        case .idle:           return "○"
        }
    }
    var color: Color {
        switch status {
        case .working:        return .blue          // .systemBlue
        case .needsAttention: return .orange        // .systemOrange
        case .done:           return .green         // .systemGreen
        case .stale:          return Color(.systemGray)
        case .configuring:    return Color(.systemTeal)
        case .idle:           return Color(.tertiaryLabel)
        }
    }
    var body: some View {
        Text(glyph).foregroundStyle(color).monospacedDigit()
    }
}
```

The `applyEvent` incremental delta function in `FleetModel` is a pure function — it takes the current `SidebarTree` and an `AgentActivityEvent`, finds the affected `SidebarTileRow` by `tileId`, updates its `agentStatus`, recomputes the parent `SidebarZoneRow`'s rollup via `SidebarAgentStatusRollup.make(statuses:)`, and returns the new tree. It does not rebuild the whole tree from scratch on every event; only the affected zone row is recomputed. This keeps the `List` diff minimal.

## How we test it

### Logic (pure Core checks)

The attention-first sort is a pure function over `SidebarTree` and belongs in the Core test suite. Write a table-driven check: construct `SidebarTree` values with known per-tile statuses, call `attentionFirstZones`, and assert the output order. The table must cover: a `needsAttention` tile in a lower zone sorts before a `working` tile in a higher zone; ties within a zone preserve original order; an all-`idle` tree has stable order. The `StatusGlyphView` glyph/color mapping is also table-driven: for each of the six `AgentStatus` cases, assert the correct glyph string and color name. These run in the Core target with no device.

The `applyEvent` incremental delta function gets its own table: start from a known `SidebarTree`, apply a sequence of `AgentActivityEvent` values (one status change per event), and assert the resulting tree matches `SidebarTreeBuilder.build(...)` called fresh with the same statuses. This proves the incremental path and the full rebuild produce byte-identical results.

### Backend (real-path integration, not bypassed)

The real-path check drives the actual `ActivityStore.subscribe()` stream — not a mock — through `FleetModel.connect(store:)` and asserts the `SidebarTree` produced on the subscriber side matches what the publisher side built. Concretely: use the injectable fake sync transport from the injectable-substrates ticket to deliver a scripted sequence of `ActivityStreamItem` values (one snapshot, then three incremental events), drive `FleetModel` with them, and assert the final `tree.workspaces[0].zones[0].tiles` order is attention-first with the correct statuses. The manifest written to `qa-runs/<ts>/ios-observer/manifest.json` carries the ordered tile IDs, their status strings, and the zone rollup `displayText` — measured values, never `{passed:true}`.

This check runs on macOS in the Core target (no device required) because `FleetModel` and `SidebarTreeBuilder` are pure Swift and the fake transport is in-process.

### UX (visual gate + dogfood snippet)

The fleet list and agent detail header are SwiftUI views — not AppKit — so the `cacheDisplay` snapshot path the Component Lab uses for Mac views does not apply. Instead: add a `ContinuumObserver` scheme to the Component Lab's companion iOS simulator run, render `FleetListView` seeded with a fixture `SidebarTree` (three workspaces, mixed statuses including two `needsAttention` agents) against an opaque background, take a simulator screenshot via `XCUIScreen.main.screenshot()`, and assert the PNG is non-blank using the same `VisualSnapshot.metrics` non-degenerate check the Mac Lab uses. The screenshot is written to `qa-runs/<ts>/ios-observer/fleet-list.png`.

**Dogfood snippet.** Build and run `ContinuumObserver` on a paired iPhone (or the iOS simulator with iCloud signed in) while the Mac host has at least one running agent and one agent in `needsAttention`.

> Open the `ContinuumObserver` app on the iPhone → the root screen shows "Agents" with your workspaces grouped by zone → the `needsAttention` agent appears at the top of its zone section with an **orange `◆`** glyph and phase text "needs you" → tap that row → the detail screen opens showing the agent's message and tool-call cards, with the header glyph **orange `◆`** and elapsed timer → scroll down to the most recent tool-call card and verify it shows the correct verb and target → background the Mac agent by letting it finish → within a few seconds the fleet list updates: the former `needsAttention` row moves down, its glyph changes to **green `✓`**, and its phase text reads "done". Tap a shell agent row → the detail screen shows "No transcript" with the terminal icon and the explanatory note; no approval dock appears anywhere in this target.

## Execution mode

**Needs-substrate.** The fleet list and transcript rendering can be exercised with fake data in a simulator, and the logic and backend checks run on macOS without a device. But proving the end-to-end subscription — that the iOS app actually receives live `ActivityStreamItem` events from the Mac host over the CloudKit transport — requires a real iCloud account signed in on both sides and a real paired device. The simulator with a signed-in iCloud account is the minimum viable substrate; a physical iPhone is the honest one. Neither the CloudKit private database nor the APNS push infrastructure can be exercised without real Apple credentials, which excludes fully autonomous proof.

## Done when

- [ ] `ContinuumObserver` target builds for iOS 17+ with `ContinuumRevivedCore` as a package dependency and no new shared types introduced
- [ ] The fleet list renders `SidebarTree` grouped by workspace and zone, with attention-first sort applied within each zone, using the six status glyphs and colors from the UX analysis vocabulary verbatim
- [ ] Zone section headers show `SidebarAgentStatusRollup.displayText` and are colored by `dominantKind`
- [ ] Tapping a managed agent row opens the detail screen with a scrollable card list sourced from `TileActivity.transcript`; tapping a shell agent row opens the detail screen showing "No transcript" with no approval dock present
- [ ] The `AgentStatus` → glyph/color table-driven Core check passes for all six cases
- [ ] The attention-first sort table-driven Core check passes for all ordering scenarios described above
- [ ] The `applyEvent` incremental delta Core check passes: incremental and full-rebuild paths produce byte-identical `SidebarTree` values
- [ ] The real-path backend check runs against the fake transport, delivers snapshot + three incremental events, and the manifest at `qa-runs/<ts>/ios-observer/manifest.json` contains the correct ordered tile IDs and statuses
- [ ] The iOS simulator visual gate produces a non-blank `fleet-list.png` at `qa-runs/<ts>/ios-observer/`
- [ ] The dogfood snippet produces exactly the described sequence of glyph and phase-text transitions on a real device or iCloud-signed simulator
- [ ] No `AgentActivityEvent` transcript body, pid, pane target, or runtime handle appears in any type the iOS app reads — confirmed by the taint-scan check (I5) already in the invariant spine harness

## Depends on / unblocks

This ticket depends on the activity projection over transport being delivered — that projection is the `AsyncStream<ActivityStreamItem>` stream the iOS app subscribes to, and without it there is nothing to subscribe to. It also depends on the `Scope` OptionSet model being defined so the iOS session can be typed as `.observe`-only at the call site; without the type, the scope guarantee is a convention rather than a compile-time property.

It unblocks the iOS approve action ticket directly: the approval dock lives inside `AgentDetailView`, which this ticket creates, and the approve action ticket extends that view with the dock and the `respondToApproval` call. It unblocks the APNS push service ticket because a registered iOS device is required to receive pushes, and registration happens at app launch in this target. It unblocks deep-link validation because the `continuum://agent/<tileId>` scheme must route into the navigation stack this ticket establishes.

## Watch out for

**The transcript is read from the projection, not from the Mac's local store.** There is no direct file access from the iOS app to the Mac's `~/.claude/sessions/` or `.pi/agent-runs/`. The only transcript data available is what the Mac published into the activity projection, which by construction carries only derived status and structured event metadata — never raw transcript bodies (I5). If an implementer finds themselves reaching for a file path or a raw body on iOS, that is a stop condition: the design is wrong, not the constraint.

**`SidebarTreeBuilder.build(...)` takes a `Registry` and a `[UUID: WorkspaceDocument]`.** These come from the spatial sync layer, not the activity projection alone. The iOS app must reconstruct them from the synced spatial state (tiles, zones, positions) delivered over the CloudKit transport. If the spatial sync (ticket 57) has not landed yet, the fleet list cannot be built from `SidebarTreeBuilder` and must use a degraded path that renders only the `ActivityTreeSnapshot.byTile` dictionary directly — acknowledging that zone grouping will be absent until spatial state arrives. Document this graceful degradation explicitly in `FleetListView` with a `#if SPATIAL_SYNC_AVAILABLE` compile flag or a runtime guard on the presence of registry data, so the ticket does not block on spatial sync being complete but degrades honestly when it is not.

**The incremental `applyEvent` path must stay identical to the full-rebuild path.** If they diverge — even transiently, during a reconnect gap — the fleet list will show stale zone rollups or incorrect sort order. The Core check described above is the only guard against silent drift. Do not skip it.

**SwiftUI `List` diffing on `SidebarTree` changes.** `SidebarWorkspaceRow`, `SidebarZoneRow`, and `SidebarTileRow` are `Equatable` and `Sendable`; make sure their identifiers (`workspaceId`, `zoneId`, `tileId`) are stable across snapshot redeliveries so SwiftUI can diff rows rather than rebuilding the whole list on every event. A rebuild on every incremental event will be visually jarring.

**iCloud account availability.** The CloudKit transport assumes the user's iCloud account is available. If it is not — device is not signed in, account is restricted — the fleet list must show a clear, actionable error state ("Sign in to iCloud in Settings to observe your agents"), not a blank screen or a crash. This is a first-launch condition that the dogfood pass will catch if tested on a fresh device.
