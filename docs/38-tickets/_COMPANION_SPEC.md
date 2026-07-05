# Companion app spec — Continuum for iPhone (v1, night-3 build)

Dylan's brief (2026-07-04): feature-rich over pretty; every connection the desktop now offers gets
used; **live and bidirectional** — move a tile on desktop, see it on the phone, and vice versa; view
AND edit workspaces/canvas in the MVP; mostly observing + gating (approvals); push notifications are
first-class with a mapped taxonomy and a real test method. UX gets dogfooded and iterated after.

Display name **Continuum** · bundle id **com.dylanreed.continuum** (Dylan's call 2026-07-04; immutable
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
2. **T2 simulator (tonight, scripted):** `xcrun simctl push booted io.bannockburn.continuum <payload>.apns`
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
