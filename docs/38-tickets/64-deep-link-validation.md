# Deep-link validation — parse, resolve, and guard the agent push tap-target

> **RULING BANNER — C-20260705-028 (night3 B7 = 64 deep-link validation, orchestrator
> 2026-07-05). Binding; overrides the ticket text below where they conflict. This ticket was
> written before B2–B6 landed; the types it names are superseded. Verified code facts as of
> 5af822d: ticket 63's builders emit FIVE deep-link shapes via `PushDeepLinkTarget`
> (`APNSPushService.swift:226-239`): `.approvalCard` → `continuum://approval/<requestId>?tileId=<uuid>`
> (note the QUERY parameter — the ticket's "no query parameters" rule is amended for this one
> landed shape only), `.agentDetail` → `continuum://agent/<uuid>`, `.agentsBoard` →
> `continuum://agents`, `.statusFooter` → `continuum://status`, `.devices` →
> `continuum://devices`; the push payload's top-level key is `deepLink` (`encodedJSON`,
> `APNSPushService.swift:140`). There is NO `ActivityProjectionSnapshot`/`SidebarTileRow` on the
> projection wire — the landed types are `ActivityLogSnapshot.byTile: [UUID: TileActivity]`
> (`AgentActivityEvent.swift:131-134`) and `AgentsBoardProjection` (61a flat board — no
> workspace/zone tree). The iOS app is `ios/Continuum/Sources/ContinuumApp.swift`: TabView with
> per-tab `NavigationStack`s that have NO programmatic path binding yet
> (`AgentsBoardView` :332, `navigationDestination(for: UUID.self)` :356); the notification
> response handler (:60-72) currently handles ONLY the approve/deny/open ACTION buttons via
> `handlePushAction` (`APNSPushService.swift:618` returns nil for the default tap — a plain tap
> on a banner currently does nothing). `PairingURL.scheme == "continuum"`
> (`Auth/PairingURL.swift:26`) and pairing URLs carry credentials in the FRAGMENT — host `pair`
> must be rejected by this parser (pairing has its own parser) and fragments must never be
> logged.**
>
> 1. **Parser scope (supersedes the single-case enum):** `ContinuumDeepLink` in
>    `Sources/ContinuumRevivedCore/DeepLink.swift` parses ALL FIVE landed shapes into typed
>    cases: `.agent(tileId: UUID)`, `.approval(requestId: String, tileId: UUID)`, `.agentsBoard`,
>    `.status`, `.devices`. Typed `DeepLinkError` per the ticket, extended as needed
>    (`.unsupportedScheme`, `.unknownHost` — including `pair`, `.malformedPath`,
>    `.invalidTileId`, plus approval-shape failures: missing/non-UUID `tileId` query item, empty
>    requestId path component → `.malformedPath`). Defensive strictness kept: shapes that don't
>    define a query/fragment REJECT URLs carrying one; `.approval` accepts exactly the one
>    `tileId` query item; trailing-slash/empty-segment cases → `.malformedPath` via
>    `split(omittingEmptySubsequences:)`. (N1 always carries a non-empty requestId by B6's
>    firing rule — the builder's `?? ""` arm is defensive dead code; an empty-requestId approval
>    link is honestly malformed.)
> 2. **Resolution (landed projection types):** `resolve(_:in: ActivityLogSnapshot) throws ->
>    ResolvedDeepLink`. `.agent`/`.approval` require `snapshot.byTile[tileId]` present, else
>    `.tileNotFound(tileId:)` (covers cold-launch `.empty` snapshot, tombstoned, and stale-push
>    races — banner copy "This agent is no longer active"). `ResolvedDeepLink` is the navigation
>    currency: `.agentDetail(tileId: UUID, approvalRequestId: String?)` (approval links resolve
>    to the agent detail — that's where the B5 approval card lives), `.agentsBoard`, and
>    `.settings` (BOTH `.status` and `.devices` map here tonight — no status footer or devices
>    screen exists on iOS; the Settings tab is the diagnostics home. Honest fallback, revisit
>    when those surfaces land). `.agentsBoard`/`.settings` resolve without consulting the
>    snapshot.
> 3. **Pure tap-decision function in Core (shared-code rule):** the full raw-input path —
>    `userInfo` dictionary → extract `deepLink` string → parse → resolve → typed navigation
>    intent OR typed failure — is a pure Core function (e.g. `resolvePushTap(userInfo:snapshot:)`)
>    so CoreChecks gate the REAL decision path, not a re-implementation. The iOS coordinator is
>    thin glue: on `UNNotificationDefaultActionIdentifier` it calls that function with
>    `model.snapshot` and applies the intent (switch tab + push onto a NEW programmatic
>    `NavigationPath`/`[UUID]` binding added to the Agents stack); on any failure it shows the
>    non-blocking resolution banner. NO deferred navigation, NO caching the raw URL for later
>    (ticket's watch-out kept). Existing action-button path (`handlePushAction`) unchanged —
>    B7 adds the default-tap route beside it. `DeepLinkError` exhaustively switched per
>    Done-when.
> 4. **Logging/I5:** log scheme+host+path ONLY (the `redactedForLog` shape); never query (it
>    carries tileId), never fragment (pairing credentials live in fragments elsewhere in this
>    scheme — hard rule). The redaction helper may live in Core so it's checkable.
> 5. **Checks (this repo's convention — NO XCTest, supersedes the ticket's
>    `ContinuumRevivedCoreTests` naming):** new `DeepLinkTests.swift` in
>    `ContinuumRevivedCoreChecks` called from `main.swift`, matrix-wired (CoreChecks already
>    runs). Required tables: (a) **builder↔parser pin** — for each of the 8
>    `PushPayloadBuilder.fixturePayload(for:)` payloads, extract the REAL `deepLink` string,
>    parse must succeed and the parsed case must match the category's `deepLinkTarget` (single
>    source of truth, no independent literal list of what "should" parse); (b) rejection table
>    (wrong scheme, unknown host incl. `pair`, zero/extra segments, trailing slash, non-UUID
>    segment, empty approval requestId, missing/invalid approval `tileId` query, unexpected
>    query on `.agent`, fragment present); (c) resolve table over fixture `ActivityLogSnapshot`s
>    (present / absent / previously-present-now-omitted / `.empty` cold snapshot); (d) redaction
>    (URL with query+fragment → logged form contains neither); (e) `resolvePushTap` table
>    (default tap happy path, nil/absent `deepLink` key, malformed value, tile-absent →
>    typed failures; action-button ids still route to the B5/B6 path, not navigation). Round-trip
>    invariant kept from the ticket.
> 6. **ComponentLab (night-3 rule):** "Deep Link" card in
>    `Sources/ContinuumRevived/App/ComponentLab.swift` (follow the Push Smoke card pattern,
>    :428): rows for the 8 builder fixture links with parse→resolve outcome against a fixture
>    snapshot (one tile present/needsAttention, one absent) plus hostile rows (malformed shapes →
>    typed error names); extend the `--component-lab-check` assertion. The Mac app gets NO
>    `continuum://` route handling (ticket's scope-enforcement rule kept — the card renders
>    data only).
> 7. **Gates tonight:** `swift build` + full matrix green + `cd ios && xcodegen generate &&
>    xcodebuild … -destination 'generic/platform=iOS Simulator' build` clean. The ticket's
>    backend real-path check (live simulator push, real banner tap, cold-launch leg) and the
>    dogfood snippet are `device-gate-owed`; banner/nav visuals are `visual-gate-owed` (B9 sim
>    suite + morning screenshots). Do NOT fake either.

## What this delivers

When the iOS companion app receives a `continuum://agent/<tileId>` push notification and
the user taps it, this ticket ensures the app never navigates blindly. Before any screen
transition happens, the link is parsed into typed components, the `tileId` is validated as
a well-formed UUID, and the tile is looked up against the live activity projection to
confirm it is present and currently tracked. Only if all three checks pass does navigation
proceed to the agent detail screen. A malformed URL, a non-UUID path segment, or a tile
that is not in the projection each produce a typed rejection that the calling code can
handle explicitly — no silent no-ops, no partial navigations, no crashes.

The concrete outcome for the owner: tapping "Approval needed" on the iPhone goes straight
to the right agent tile without ever landing on a broken screen.

## How it fits

This ticket sits at the end of the push chain. The APNS push service builds an
`AgentAwarenessState` that carries a `deepLink` string and fires it toward the phone; the
iOS observer app receives the notification; this ticket is the guard that stands between
the raw push payload and the navigation call.

On the projection side, the validator reads the same activity tree the iOS observer
renders — the one-way `AgentStatus` snapshot delivered via the CloudKit activity
projection. It does not touch the 2D canvas, the spatial op-log, or any runtime binding;
it only needs to answer "is this `tileId` present and non-tombstoned in the current
projection?" That narrowness is deliberate: the validator is a pure function over a
snapshot, which makes it testable without a running app or network.

The `Scope` model is the gate on the control side. The iOS observer token carries only
`.observer` scope, so the validator can confirm that scope before attempting any
navigation — a malformed or downgraded token fails at the authorization check, not inside
the navigation coordinator.

Getting this right also unblocks the notification categories setting. That ticket wires
the four user-toggleable categories (approval, input, completion, failure) and relies on
the fact that every tapped notification resolves cleanly or fails explicitly; it cannot be
built safely until this validation layer exists.

## The approach

Define a `ContinuumDeepLink` enum in `ContinuumRevivedCore` with a single case for now:
`.agent(tileId: UUID)`. A static `parse(_: URL) throws -> ContinuumDeepLink` function
deconstructs any `continuum://` URL and produces a typed value or throws a
`DeepLinkError`. `DeepLinkError` is its own typed enum with cases for each failure mode:
`.unsupportedScheme`, `.unknownHost`, `.malformedPath`, `.invalidTileId`.

The URL shape that must succeed is exactly `continuum://agent/<uuid-string>` — scheme
`continuum`, host `agent`, one path component that is a valid UUID. No query parameters,
no fragments, no subpaths. Any deviation is a `DeepLinkError`. This is the same defensive
shape t3code's `normalizeThreadDeepLink` enforces: `notificationPayload.ts:47` requires
exactly `/threads/<a>/<b>` and rejects everything else before navigating.

Resolution is a second, distinct step from parsing. A free function
`resolve(_ link: ContinuumDeepLink, in projection: ActivityProjectionSnapshot) throws -> ResolvedDeepLink`
walks the projection snapshot and finds the `SidebarTileRow` whose `tileId` matches. If
the tile is absent from the projection (not yet delivered, tombstoned, or never known),
it throws `DeepLinkError.tileNotFound(tileId:)`. The resolved value is a
`ResolvedDeepLink` struct carrying the matching `SidebarTileRow` — enough for the
navigation coordinator to select the right screen without knowing the URL anymore.

The iOS navigation coordinator calls these two steps in order: parse first, then resolve
against the last-known projection snapshot. It does this synchronously before any
`UIScene` or SwiftUI navigation mutation. If either step throws, the coordinator logs the
failure (including the raw URL, redacted to scheme+host+path only — no fragment, no query
params that might carry sensitive data) and shows a brief non-blocking banner
("Notification link could not be resolved") rather than silently dropping the tap.

The APNS push service is responsible for producing well-formed links; this validator is
the defense against malformed payloads that arrive despite that (push delivery is
best-effort and payloads could be stale relative to a tile that was subsequently deleted).

## Where it lives

All parsing and resolution logic lives in `ContinuumRevivedCore` so it is importable by
both the Mac app and the iOS companion with no duplication.

- **`Sources/ContinuumRevivedCore/DeepLink.swift`** — new file. Houses `ContinuumDeepLink`
  enum, `DeepLinkError` enum, `ResolvedDeepLink` struct, `ContinuumDeepLink.parse(_:)`
  static method, and the `resolve(_:in:)` free function. No UIKit or SwiftUI imports;
  Foundation only.
- **`Sources/ContinuumRevivedCore/SidebarTree.swift`** — the existing
  `SidebarTileRow` struct (line 78) and `SidebarTree` struct (line 126) are the projection
  types the resolver walks. `SidebarTileRow.tileId: UUID` (line 79) is the key the
  resolver matches against. No changes to this file; it is a read-only dependency.
- **`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`** — the existing
  `AgentStatus` enum (line 85) is what `SidebarTileRow.agentStatus` carries; the resolver
  reads but does not mutate it.
- **iOS companion app** — a navigation coordinator (new file in the iOS target) calls
  `ContinuumDeepLink.parse(_:)` and `resolve(_:in:)` in sequence on every notification
  response. It holds a reference to the last-delivered `ActivityProjectionSnapshot` from
  the CloudKit subscription and passes it to `resolve`.
- **`Sources/ContinuumRevivedCore/ActivityProjectionSnapshot.swift`** — defined in the
  activity-projection-over-transport ticket. The resolver's second argument type; the
  validator treats it as an opaque readable snapshot with a `tileRows: [SidebarTileRow]`
  property iterable by the resolver.

## Implementation breadcrumbs

```swift
// DeepLink.swift — ContinuumRevivedCore

public enum DeepLinkError: Error, Equatable {
    case unsupportedScheme(String)
    case unknownHost(String)
    case malformedPath          // zero or >1 path components after stripping leading "/"
    case invalidTileId(String)  // path component present but not a valid UUID
    case tileNotFound(tileId: UUID)
}

public enum ContinuumDeepLink: Equatable, Sendable {
    case agent(tileId: UUID)

    public static func parse(_ url: URL) throws -> ContinuumDeepLink {
        guard url.scheme == "continuum" else {
            throw DeepLinkError.unsupportedScheme(url.scheme ?? "")
        }
        guard url.host == "agent" else {
            throw DeepLinkError.unknownHost(url.host ?? "")
        }
        // Strip leading "/" and split; we require exactly one segment.
        let components = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 1 else {
            throw DeepLinkError.malformedPath
        }
        let segment = String(components[0])
        guard let tileId = UUID(uuidString: segment) else {
            throw DeepLinkError.invalidTileId(segment)
        }
        return .agent(tileId: tileId)
    }
}

public struct ResolvedDeepLink: Equatable, Sendable {
    public let tileRow: SidebarTileRow
}

public func resolve(
    _ link: ContinuumDeepLink,
    in projection: ActivityProjectionSnapshot
) throws -> ResolvedDeepLink {
    switch link {
    case .agent(let tileId):
        // Walk every workspace → zone → tile in the snapshot.
        for workspace in projection.sidebarTree.workspaces {
            for zone in workspace.zones {
                if let row = zone.tiles.first(where: { $0.tileId == tileId }) {
                    return ResolvedDeepLink(tileRow: row)
                }
            }
        }
        throw DeepLinkError.tileNotFound(tileId: tileId)
    }
}
```

```swift
// iOS navigation coordinator (iOS target, not ContinuumRevivedCore)

func handleNotificationResponse(_ response: UNNotificationResponse) {
    // Extract raw URL string from push payload key "deepLink".
    guard
        let rawLink = response.notification.request.content.userInfo["deepLink"] as? String,
        let url = URL(string: rawLink)
    else {
        showResolutionBanner()
        return
    }

    do {
        let link = try ContinuumDeepLink.parse(url)
        // projectionSnapshot is the last ActivityProjectionSnapshot from the
        // CloudKit subscription; it is never nil after the first delivery.
        guard let snapshot = projectionSnapshot else {
            showResolutionBanner()   // projection not yet delivered; drop gracefully
            return
        }
        let resolved = try resolve(link, in: snapshot)
        navigate(to: resolved.tileRow)
    } catch {
        // Log scheme+host+path only; never log query/fragment (could carry sensitive data).
        logger.warning("deep-link resolution failed: \(url.redactedForLog) — \(error)")
        showResolutionBanner()
    }
}

// URL extension — iOS target only (not Core)
extension URL {
    var redactedForLog: String {
        "\(scheme ?? "?")://\(host ?? "?"):\(path)"
    }
}
```

The `navigate(to:)` call uses the iOS app's existing SwiftUI router or `UINavigationController`
to push the agent detail screen, passing `tileRow.tileId` as the key. It does not re-parse
the URL; the `ResolvedDeepLink` is the navigation currency from this point forward.

## How we test it

### Logic (pure Core checks)

Write a `DeepLinkTests` target in `ContinuumRevivedCoreTests` that exercises the parser
and resolver as pure functions over in-memory values — no app, no network, no iOS device.

- **Parse — valid link.** `URL(string: "continuum://agent/\(UUID().uuidString)")!` parses
  to `.agent(tileId:)` with the correct UUID.
- **Parse — wrong scheme.** `https://agent/<uuid>` throws `.unsupportedScheme("https")`.
- **Parse — wrong host.** `continuum://tile/<uuid>` throws `.unknownHost("tile")`.
- **Parse — zero path components.** `continuum://agent` (no path) throws `.malformedPath`.
- **Parse — extra path components.** `continuum://agent/<uuid>/extra` throws `.malformedPath`.
- **Parse — non-UUID segment.** `continuum://agent/not-a-uuid` throws `.invalidTileId("not-a-uuid")`.
- **Parse — empty UUID string.** `continuum://agent/` (trailing slash only) throws
  `.malformedPath` (empty components after split).
- **Resolve — tile present.** Build an `ActivityProjectionSnapshot` containing a
  `SidebarTileRow` with a known `tileId`; assert `resolve` returns a `ResolvedDeepLink`
  whose `tileRow.tileId` matches.
- **Resolve — tile absent.** Build a snapshot with no matching tile; assert `.tileNotFound`.
- **Resolve — tombstoned tile.** A snapshot that omits a tile that was previously present
  (simulating a deletion) must throw `.tileNotFound`, never return a stale row.
- **Round-trip invariant.** Parse a URL, then round-trip the extracted `tileId` back into a
  URL via `URL(string: "continuum://agent/\(tileId)")!`, re-parse, and assert equality.

These checks run entirely in the Core test target with no simulator and no network.

### Backend (real-path / integration)

The real-path check runs on a real iOS simulator with the iOS companion app installed and a
live CloudKit subscription delivering an `ActivityProjectionSnapshot`.

1. Start the Mac app with at least one managed agent tile in `needsAttention`.
2. Wait for the APNS push service to fire (or trigger it manually via a test-mode endpoint
   that calls `AgentPushService.publish` directly with a crafted `AgentAwarenessState`).
3. On the simulator, receive the notification. Assert that `UNNotification.request.content.userInfo`
   contains a `"deepLink"` key and that its value is a well-formed `continuum://agent/<uuid>` string.
4. Tap the notification banner. Assert that the navigation coordinator calls
   `ContinuumDeepLink.parse` without throwing, calls `resolve` without throwing, and pushes
   the agent detail screen with the correct `tileId`.
5. Now craft and deliver a malformed push payload (e.g., `"deepLink": "continuum://agent/not-a-uuid"`)
   via the test-mode endpoint. Assert that tapping the banner shows the "Notification link
   could not be resolved" banner and does not navigate.
6. Craft a valid UUID link for a `tileId` that does not exist in the current projection and
   deliver it. Assert the same banner appears and no navigation occurs.

This path exercises the real `UNNotificationResponse` → `handleNotificationResponse` →
`ContinuumDeepLink.parse` → `resolve` chain, including the real CloudKit projection snapshot
in memory.

### UX (visual gate + dogfood)

**Visual gate.** In the Component Lab, wire a fixture `ActivityProjectionSnapshot`
containing two tiles — one in `.needsAttention`, one in `.working` — and a notification
tap fixture with a `deepLink` pointing at the `needsAttention` tile. Render the iOS fleet
list view and drive the `handleNotificationResponse` path. Assert in the visual gate:
the agent detail screen for the correct tile appears, the tile's status indicator shows the
orange `needsAttention` diamond, and no other screen is pushed.

**Dogfood snippet.** With the Mac app running a managed agent in supervised mode (so the
agent raises a structured approval request):

1. On iPhone: ensure the Continuum iOS app is installed, the companion is paired, and the
   "Approval" notification category is enabled in system Settings > Notifications.
2. In the Mac app, trigger an approval from the managed agent (the agent must be in
   supervised / `on-request` mode).
3. Within a few seconds, a push arrives on iPhone: headline reads "Approval needed", body
   reads the agent tile's title.
4. Tap the notification banner.
5. The iOS app opens directly to the agent detail screen — not the fleet list, not the root
   — and the screen header shows the orange `needsAttention` indicator alongside the tile's
   name. The pending approval card is visible and actionable.
6. Rotate the phone or background/foreground the app; the screen must remain on the same
   agent detail without re-navigating to root.

If step 4 lands on the fleet list root instead of the agent detail, the deep-link
resolution path failed silently; stop and investigate the `projectionSnapshot` availability
at notification-tap time.

## Execution mode

**Needs-substrate.** The logic checks (parse, resolve) are pure and autonomous. But the
complete verification requires a real iOS device or simulator receiving a live APNS push,
a real CloudKit subscription delivering the activity projection, and a real managed agent
raising an approval. None of those three can be faked within the Core test target. The
backend real-path check requires the iOS simulator and the test-mode push endpoint; the
dogfood snippet requires a physical iPhone. An autonomous agent cannot complete the
verification without this substrate — it can author and pass the logic checks, but must
hand off the rest.

## Done when

- [ ] `ContinuumDeepLink.parse(_:)` compiles in `ContinuumRevivedCore` with no UIKit or
  SwiftUI imports; all eight logic check cases pass in the Core test target.
- [ ] `resolve(_:in:)` compiles against `ActivityProjectionSnapshot.sidebarTree`; the
  present/absent/tombstoned resolver checks all pass.
- [ ] The iOS navigation coordinator calls `parse` then `resolve` before any navigation
  mutation; there is no code path that navigates on a raw URL without going through both
  steps.
- [ ] A malformed `deepLink` in a push payload (wrong scheme, wrong host, non-UUID segment,
  extra path components) shows the resolution banner and makes zero navigation calls —
  verified in the backend real-path check against a live simulator.
- [ ] A valid `deepLink` for a deleted or absent tile shows the resolution banner and makes
  zero navigation calls.
- [ ] The dogfood snippet completes step 5 — the agent detail screen opens with the orange
  `needsAttention` indicator and the pending approval card visible — on a physical iPhone.
- [ ] No push payload field beyond scheme, host, and path is included in any log output;
  query parameters and fragments are always stripped before logging.
- [ ] The `DeepLinkError` type is exhaustively switched in the coordinator; adding a new
  error case causes a compiler warning, not a silent fallthrough.

## Depends on / unblocks

This ticket depends on the iOS observer app (which provides the UI surface the navigation
coordinator drives), the APNS push service (which produces the `continuum://agent/<tileId>`
links that this validator parses), and the activity-projection-over-transport work (which
delivers the `ActivityProjectionSnapshot` the resolver walks). All three must be at least
partially standing before the backend and dogfood verifications can run — the logic checks
can be written and passed independently.

It directly unblocks the notification categories setting, which wires four user-toggleable
categories to the interruptive and terminal phases. That work assumes every tapped
notification either resolves cleanly to a screen or fails explicitly; it cannot be built
safely without this guard in place first.

## Watch out for

**The hardest thing:** the resolver is called synchronously at notification-tap time, but
the `ActivityProjectionSnapshot` is delivered asynchronously by the CloudKit subscription.
If the app is cold-launched by the notification tap (rather than brought to the foreground),
the snapshot may not yet have arrived. The coordinator must not block the main thread
waiting for it; the correct behavior is to detect a nil snapshot, show the banner, and
surface a "tap to retry when loaded" affordance — not to defer navigation speculatively or
cache the raw URL for later. Implement this nil-snapshot path explicitly and cover it in
the backend real-path check; it is the most likely failure mode in production.

**Stale links.** A push for a tile that was deleted between send-time and tap-time is not
a bug — it is an expected race. The `.tileNotFound` path must be tested and the banner copy
must be user-friendly ("This agent is no longer active"), not an internal error string.

**URL parsing edge cases.** `URL(string:)` is more permissive than expected: it will
parse `continuum://agent/` (trailing slash) as a URL with an empty path. The parser must
use `split(separator:omittingEmptySubsequences:true)` so the trailing-slash case yields
zero components and throws `.malformedPath` rather than forwarding an empty string to
`UUID(uuidString:)`.

**Scope enforcement.** The `.observer` scope token does not grant any navigation capability
on the Mac host; validation and navigation are iOS-only. Do not add any route-handling in
the Mac app for the `continuum://agent/` scheme — that would expand the attack surface and
is not needed for the iOS observer use case.

**I5 boundary.** The `deepLink` field in the `AgentAwarenessState` payload carries only
the scheme, host, and tile UUID — never the tile's project name, agent kind, workspace, or
any transcript content. The validator must not log the full raw push payload; only the
parsed URL components (scheme, host, path) may appear in logs, and no query or fragment
is ever included in a `continuum://` deep link by construction.
