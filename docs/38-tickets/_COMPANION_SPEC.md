# Companion app spec — Continuum for iPhone (v1, night-3 build)

Dylan's brief (2026-07-04): feature-rich over pretty; every connection the desktop now offers gets
used; **live and bidirectional** — move a tile on desktop, see it on the phone, and vice versa; view
AND edit workspaces/canvas in the MVP; mostly observing + gating (approvals); push notifications are
first-class with a mapped taxonomy and a real test method. UX gets dogfooded and iterated after.

Display name **Continuum** · bundle id **dev.dylanreed.continuum** (Dylan's call 2026-07-04; immutable
once the App Store Connect record exists tomorrow morning).

## 1. Architecture — the phone is a replica, not a viewer

```
desktop Continuum                         iPhone Continuum
┌─────────────────────┐    CloudKit     ┌──────────────────────┐
│ CanvasState/Workspace│  (57: transport │ materialized replica │
│  ops → op-log (02/06)│◄──── impl of ──►│  op-log apply (06)   │
│ ActivityStore (08)   │   55 seam,      │ canvas view + editor │
│  → projection (58)   │   66 supervisor)│ status board (58)    │
│ approvals (62/70)    │                 │ approvals + push     │
└─────────────────────┘                 └──────────────────────┘
```

- **Spatial sync = the op-log, both directions.** Phone edits emit the same frozen-wire `Op`s
  (`setTileFrame`, `setTileZone`, `setZonePosition`, `bringToFront`…) the desktop emits; both sides
  materialize via ticket 06 and converge per ticket 07's proven oracle. Delete-wins via 05 tombstones.
- **Agent liveness = the activity projection (58):** snapshot-then-tail of `AgentActivityEvent`s →
  per-tile status pills. I5 holds by construction (metadata + ≤500-char summaries only).
- **Connection = 66 supervisor** over the **57 CloudKit transport** (CKRecord op envelopes +
  CKDatabaseSubscription; silent push nudges fetch). Reconnect/offline behavior inherited.
- **Auth = 54 GRDB-backed pairing + 59/60 scopes.** Phone pairs once (persisted!). Default grant:
  `observer + respond-to-own-approvals`; **editing requires `operator`** — the canvas is read-only
  until the paired device holds operator scope (toggle on desktop: Settings → Devices).
- **Honest performance envelope:** CloudKit propagation is ~1–3 s typical (silent-push nudge + fetch),
  not frame-locked mirroring. Edits sync **on gesture end** (drag ends → one `setTileFrame` op), which
  reads as "live" at this cadence. The 55 seam means a faster direct channel (WebSocket/Multipeer) can
  replace CloudKit later without touching app code. v1 does NOT stream mid-drag frames.

## 2. Feature set (MVP tonight)

1. **Workspace switcher** — list synced workspaces; switch the phone's view; shows per-workspace
   agent-attention count.
2. **Canvas** — pan/zoom spatial view of tiles + zones (frames, titles, kind glyphs, z-order, zone
   tints, membership). **Edit with operator scope:** drag to move (op on drop), pinch handles to
   resize, drag into/out of zones (membership register), tap-hold → bring to front. Tile
   create/delete/spawn is DEFERRED (tiles own desktop runtimes; creating headless tiles from the
   phone needs a design pass — v1.1).
3. **Agents board** — the glanceable list: every tile with an agent, live status pill
   (working / needs-you / waiting-input / idle / done / stale), last-activity summary line, elapsed.
   Sort: needs-you first. This is the screen you'll live on.
4. **Agent detail card** — status history (fold of its events), the pending approval or question if
   any, approve/deny buttons, jump-to-tile (centers the canvas).
5. **Approvals inbox** — every pending approval across workspaces; approve/deny per C-20260702-012
   (session must own the approval or hold operator+ — never bare observer).
6. **Notifications** — full taxonomy below, per-category settings (ticket 65), deep links (64).
7. **Pairing + status footer** — QR/code pairing (60), connection state from the 66 supervisor
   (live / reconnecting / offline with age), scope badge.

## 3. Notification taxonomy (the full map — ticket 63/64/65)

| # | category | trigger (source) | priority | actionable | deep link |
|---|---|---|---|---|---|
| N1 | **Approval requested** | managed agent raises permission request (70/62) | time-sensitive | **Approve / Deny** on lock screen | approval card |
| N2 | **Agent waiting for input** | `userInputRequested` (67 adapter → 73 card) | time-sensitive | **Open** | agent detail |
| N3 | **Agent finished** | status → `done` | active | — | agent detail |
| N4 | **Agent failed** | `runtimeError` / status error | active | — | agent detail |
| N5 | **Still working (digest)** | agent working > N min (configurable) | passive | — | agents board |
| N6 | **Desktop offline / back online** | 66 supervisor loses/regains the desktop replica | passive | — | status footer |
| N7 | **New device paired / scope changed** | 54/60 pairing events (SECURITY — not muteable) | time-sensitive | — | devices |
| N8 | **Session reaped / revived** | 21 reaper detach, lazy-resume failure (24) | passive | — | agent detail |

Rules: N1/N2 are the reason the app exists — default ON, time-sensitive interruption level. N3–N5
default ON but quiet. N6/N8 default OFF (opt-in). N7 always delivers. Every category individually
toggleable (65) + a global quiet-hours switch. Approve-from-lock-screen carries ONLY the approval id —
the action round-trips through the scope gate server-side; a stolen notification can't approve
someone else's request.

## 4. Push test method (3 tiers — how we CONFIRM behavior)

1. **T1 headless (tonight, in the matrix):** payload-builder checks — every category N1–N8 produces a
   correct APNS JSON (category id, interruption level, deep-link userInfo, action ids); scope-gate
   round-trip test for the Approve action against the real authorize() path.
2. **T2 simulator (tonight, scripted):** `xcrun simctl push booted dev.dylanreed.continuum <payload>.apns`
   for each category — verifies banner rendering, lock-screen actions, category settings honored,
   deep-link routing — **no real APNS needed**. A script `scripts/push-sim-test.sh` fires all 8 in
   sequence; screenshots into the morning report.
3. **T3 device (morning, with you):** real APNS sandbox push through the key at
   `~/.continuum/secrets/AuthKey_RV677784MJ.p8` (Key RV677784MJ, team 46TTB6J9DZ) once TestFlight is
   on your phone: a `--push-test` flag on the desktop app fires one real push per category; your
   checklist confirms each lands + actions work end-to-end (incl. Approve from lock screen actually
   approving on the desktop).

## 5. What this changes in tonight's Track B (supersedes the bare ticket list)

Order: **60 pairing → 57 CloudKit transport → 61a status board + agent detail → 61b canvas
view/editor (op-emitting) → 62 approvals + scope gate → 63 push sender + N1–N8 payloads →
64 deep links → 65 category settings → T2 simulator push suite.** 61b (canvas editor) is the
biggest new surface; if the night runs long it degrades gracefully: view-only canvas ships, edit
gestures become the first morning-after item. Everything else is unchanged from _NIGHT3_PLAN.md.

## 6. Screens (the design tonight's 61a/61b implement — wireframes in the sprint-map artifact, tab 5)

**Navigation:** iOS tab bar — **Agents** (home) · **Canvas** · **Approvals** (badged) · **Settings**.
Workspace switcher is a compact menu in the top bar of Agents + Canvas (shared selection). Agent
detail pushes onto whichever tab invoked it. Dark-only v1 (matches desktop).

### 6.1 Agents board (home — the screen Dylan lives on)
- Top bar: workspace menu (name + attention count) · connection dot.
- **Needs-you section pinned first** (orange-tinted rows): agents with pending approval/question.
- Rows: status dot+pill (working=blue pulse, needs-you=orange, waiting=amber, done=green, idle=grey,
  stale=hollow), kind glyph (pi/claude/codex/shell), tile title, one-line last-activity summary,
  elapsed (tabular). Tap → detail. Pull-to-refresh forces a snapshot re-fetch.
- Footer strip: connection state from the supervisor — `live` / `reconnecting (12s)` / `offline —
  showing data as of 14:32`. Never hide staleness (I4 honesty).

### 6.2 Agent detail
- Header: title, kind, status pill, elapsed, workspace.
- If pending: **approval/question card** at top — requested action summary, age, Approve / Deny
  (scope-gated; buttons disabled with "observer scope" hint if not permitted).
- Status timeline: folded event history (status transitions + summaries, newest first).
- Actions: "Show on canvas" (switches to Canvas tab, centers tile).

### 6.3 Canvas (the replica)
- Pinch-zoom / pan; fit-all button. Tiles = rounded rects (title, kind glyph, status dot); zones =
  tinted regions with headers; z-order honored (zPosition).
- Observer scope: read-only, small lock badge in toolbar.
- Operator scope edits: drag tile → ghost outline follows finger, **op emitted on drop**, subtle
  pending shimmer until the transport acks; pinch-handles resize; drag into/out of zone highlights
  membership change; long-press → Bring to front. Failure → toast + snap back (never silently lost).
- Remote changes animate in (~1–3 s after desktop edit — the honest CloudKit cadence).

### 6.4 Approvals inbox
- All pending across workspaces, grouped by workspace; row: agent, action summary, age.
- Swipe right = Approve, swipe left = Deny (with confirm); or open → full card.
- Empty state: "Nothing needs you." + last-checked stamp.

### 6.5 Pairing (first run) + Settings
- First run: explainer → **scan the QR the desktop shows** (Settings → Devices → Pair new device) →
  confirm device name + granted scope (observer default) → land on Agents. Token flow per ticket 60;
  re-pair and unpair live in Settings → This device.
- Settings: notification categories N1–N8 (toggles per §3 defaults; N7 shown but locked ON) + quiet
  hours; Devices (this device's scope badge; operator granted from DESKTOP only — phone can't
  self-escalate); Connection diagnostics (transport state, last sync, replica id); About.

### 6.6 State rules (all screens)
- **Cold connect:** skeleton rows ≤2 s (cursor:nil snapshot per B0b ruling), then live.
- **Offline:** banner + all timestamps switch to "as of HH:MM" — stale data stays visible, never blanked.
- **Empty workspace:** friendly zero-state with a pointer to spawn agents on desktop.
- Haptics on: approval sent, op ack, connection regained. No sounds v1.

## 2026-07-06 amendment — explicit instance pairing + asleep/offline semantics

The v1 spec above still describes the desired mobile surfaces, but the auth/source-of-truth assumption is amended:

- The iPhone pairs to a **Continuum instance**, not to iCloud.
- CloudKit may remain the same-iCloud dogfood transport, but it is not identity, ownership, scope, or truth.
- Pairing is personal/MVP device enrollment: physical QR/token from the Mac, one local owner user, long-lived device session until revoked.
- Capability scope comes from the Continuum session, not a static iOS default or iCloud account membership.

Read `_PAIR_TO_INSTANCE_PLAN.md` first. Implement `79-pair-to-instance-auth-boundary.md` before rewriting/resuming ticket 75.

Offline/freshness is also a first-class product state, not an error fallback:

- A paired phone can be live, syncing, stale, asleep/offline, or unpaired.
- If cached canvas/agent state exists, keep showing it with `as of` copy; never blank it just because the Mac is asleep.
- “Canvas asleep” is friendly UI copy for cached/stale mode. Diagnostics should state what is known: last heartbeat, last snapshot, last fetch, last error.
- Mutating actions are disabled while stale/offline for MVP; no offline approval/canvas-op queue yet.

Implement `80-companion-offline-freshness.md` before the desktop publisher rewrite so ticket 75 publishes the right heartbeat/freshness metadata from the start.
