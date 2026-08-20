# Agent tile identity and elapsed-time semantics

## Problem

Managed agents currently have competing identities. The canvas drag chrome is
seeded from `Tile.title`, which is the model display name at spawn, while the
in-tile header and sidebar observe `AgentRecord.displayName`. A generated or
manual conversation name therefore leaves the most persistent identifier on the
canvas saying `Agent · GPT-5.6 Sol` while the body and sidebar say something else.

The tile body then repeats the name and status immediately below the drag chrome.
The duplicate costs vertical space, makes it unclear which title owns rename and
accessibility, and lets the two surfaces drift.

The redesigned sidebar also overloads one number with two meanings. `row.elapsed`
is the duration of a live turn, but the production cell falls back to time since a
ready row's terminal event or last activity. Once a successful result is read its
`Done` word intentionally disappears, leaving a bare value such as `5m` beside an
idle agent. That value refreshes when interaction rebuilds the cell and on the
settle-nudge cadence, not on a clock owned by live execution.

## Decisions

1. `AgentRecord.humanDisplayName` is the sole managed-agent identity.
2. Canvas chrome presents `Agent · <conversation name>` and observes the same
   record updates as the sidebar. `Tile.title` remains persistence/fallback data;
   copying the record name into it would create another owner.
3. The bundled provider silhouette precedes the chrome title. It is metadata, not
   part of the title string, and uses the same opaque black/white accessibility
   treatment as the sidebar and hover card.
4. Model and harness remain in the composer controls, sidebar hover detail and
   tooltips. They never replace the conversation name.
5. Elapsed means current execution duration only. Ready, failed, stopped,
   cancelled, restored and queued-without-execution rows show no elapsed value.
   Completion time remains available in hover detail; parked History rows retain
   their explicitly relative lifecycle time.
6. A stamped turn start is the only elapsed anchor. Presentation defensively
   requires `.working` even if malformed input carries an old timestamp.
7. One inbox-owned timer updates materialized visible working rows. Cells never
   own timers, hover never advances time, and the timer is absent when no visible
   working row exists.

## Surface anatomy

- Canvas drag chrome: provider mark, `Agent · <name>`, operational status, actions.
- Tile body: transcript, compact Home/Where/What activity, composer and provider
  controls. The duplicated identity header is retired after its branch/action
  witnesses move to the canvas chrome and compact status row.
- Sidebar row: project, canonical name, live status and live elapsed only.
- Sidebar hover: full project/device/branch/model and last-activity detail.

## Naming lifecycle

`New agent` is the sentinel until the first accepted prompt supplies a local seed
or the existing generated-name one-shot lands a concise proposal. Both write the
agent record through its existing compare-and-swap rules. Manual rename remains
authoritative and a late generated result cannot overwrite it. Every surface
observes the resulting record value; no surface runs its own generator.

## Delivery slices

1. Add a managed-agent chrome identity override and bundled provider mark; wire
   record-name and provider-setting changes to it.
2. Make sidebar elapsed live-only and add the shared visible-row clock.
3. Move any unique branch/action affordance out of `AgentTileHeaderView`, remove
   that duplicate body header, and reclaim its height.
4. Gate canonical-name propagation, provider-mark contrast, idle-without-time,
   pointer-independent ticking, immediate completion teardown, and zero idle
   timers.

## Performance and accessibility invariants

- A clock tick changes label content only; it does not rebuild transcript layout,
  re-run naming, decode an image or reload offscreen rows.
- The provider image is decorative. The accessible title remains the full
  `Agent · <name>` and the exact model remains available as help/tooltip text.
- Provider marks resolve to opaque black in Aqua and opaque white in Dark Aqua.
- Detaching the inbox/window invalidates its timer. Scrolling starts or stops it
  according to the newly materialized rows.
