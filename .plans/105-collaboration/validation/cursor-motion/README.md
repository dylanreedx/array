# Collaborator cursor lag: where the time went

Measured 1 November 2026 against 0.7.37 (2af6fdd8), after Dylan's two-Mac test
reported cursors lagging badly on both screens.

## Stage by stage

| Stage | Measured | Verdict |
|---|---|---|
| Network | one warm HTTPS request to relay.arrayapp.dev: 60-110 ms (curl, HTTP/2, connection reused) | the floor; not changed |
| Relay (real `continuum-relay`, local) | publish to waiting receiver: 2-4 ms; 20 Hz per-sender cap with a trailing flush | not the cause |
| Receiver transport | one long-poll page per round trip: 7.6-9.6 positions/s at a 100 ms round trip | the cadence limit; unchanged (a streaming lane would need a relay change) |
| Sender | one request in flight, 50 ms window counted from when a send FINISHED, and a move during a flight was DROPPED; only the 1 s timer re-sent it | **bug**: the final position landed up to ~1 s late; 6.4 sends/s |
| Receive apply | a presence page to B's model (controller, scene refresh, publisher, overlay): 0.1-0.3 ms | not the cause |
| Repaint | one overlay paint: 0.03 ms; painted at the next frame | not the cause |
| Presentation | the cursor was drawn where each page put it, so it jumped 5-10 times a second | **the stutter** |

`relay_presence.py` drives the real relay with two HTTP clients and an
injected one-way delay. `--collaboration-cursor-motion-check` drives the real
publisher (posted 60 Hz mouse events), controller and overlay through a relay
model calibrated on those numbers (50 ms each way, 20 Hz coalescing, one page
per round trip), and stops the mouse just after the 1 s timer ticks.

## Before and after (`--collaboration-cursor-motion-check`, 100 ms round trip)

| | before | after |
|---|---|---|
| final position reaches the relay after the mouse stops | 887-895 ms | 41-127 ms |
| final position painted on the other Mac | 944-950 ms | 267-327 ms |
| sends per second during motion | 6.4 | 9.5-9.6 |
| display frames where the cursor moved | 11% | 92-100% |
| largest single-frame jump (mean step ~2.7 pt) | ~26 pt | 3.4-6.0 pt |
| cursor behind the mouse, median | 194-200 ms (stepping) | 220-241 ms (smooth) |

The glide costs about 30-40 ms of average lag during motion in exchange for
continuous movement; it is capped at 120 ms and skipped under Reduce Motion.

## The cursor lane (native refresh rate)

Measured 1 November 2026 on `array/mp-cursor-stream`, after Dylan reported
teammate cursors still looked like ~20 fps.

**What limited them.** The transport. A held update read brings one page per
network round trip, so at 100 ms a teammate's cursor arrived 7-10 times a
second however often it was sent (and the relay woke readers at most 20 times
a second). The glide above hid the jumps by animating between those few
positions, but each segment was a straight line at a constant speed: the
motion changed direction ~9 times a second and paused whenever a page was
late. That reads as ~20 fps.

**What changed.**

- Relay: `GET /collaboration/v1/areas/<area>/cursor-stream`, upgraded to a
  WebSocket. Bearer and active membership are checked before the upgrade (a
  non-member gets 404 and no frame). Each frame is relayed to the area's other
  lanes the moment it arrives; no 20 Hz coalescing. The abuse limit is a
  per-lane token bucket, 90 frames/s sustained and 30 deep; over it, only the
  newest frame is kept and relayed when a token refills, so the last position
  is never lost. Up to 4 lanes per device per area, 4096 per relay. Removal and
  device revocation close lanes. Every frame still updates the same presence
  entry (pages wake at 20 Hz as before), so a viewer without a lane sees the
  pointer exactly as before. Pages now carry each cursor's session and
  sequence.
- App: the controller opens the lane once connected and keeps it open with
  backoff; a relay that refuses it (404 from an older relay) leaves presence on
  pages, as before. Lane frames update `presence` without the whole-scene
  change notification; only cursor observers hear them. The publisher sends at
  up to 60 Hz on the lane (50 ms on pages) and stamps each position with when
  it was sampled. The overlay plays each cursor back from a short buffer,
  `delay` behind the newest position: the jitter seen plus 1.5 sample
  intervals, 30 ms minimum and 130 ms maximum. That is 30-50 ms on the lane and
  the 130 ms cap on pages. The delay grows by at most 5 ms a sample while a
  cursor moves (faster would run playback backwards), and a held cursor always
  starts moving from where it is drawn. Lane positions play back at the spacing they were
  sampled, whatever the network did to them. A display link drives it and
  stops when nothing is moving. Each frame repaints only each cursor's old and
  new rect, so a frame costs O(teammates), never O(tiles).

**Witness.** `--collaboration-cursor-motion-check` now runs the real
`continuum-relay` (built beside Array) behind a loopback proxy that holds every
byte 50 ms each way, with the production API transport, controller, publisher
and overlay. It measures update pages alone (the lane refused, as an older
relay does), then the lane, each with B's frames stepped at 60 Hz and at 120 Hz.
`ContinuumRevivedCollaborationServiceChecks --cursor-lane-only` covers the
store's admission, fan-out, page agreement, stale/unknown frames, token bucket,
limits and revocation, and on macOS the WebSocket upgrade and a frame across
the real relay server.

Three runs on the final code (ranges):

| 100 ms round trip, real relay | pages only, 60 Hz | pages only, 120 Hz | lane, 60 Hz | lane, 120 Hz |
|---|---|---|---|---|
| frames on which the cursor moved | 93.0-93.7% | 90.9-94.4% | 100% | 100% |
| positions B received per second | 8.3 | 7.9-8.3 | 54.1-56.6 | 55.8-57.0 |
| largest step / mean step | 5.8-6.7 / 2.4-2.5 pt | 2.9-3.1 / 1.2 pt | 3.1-3.6 / 2.5 pt | 1.8-2.2 / 1.3 pt |
| final position painted after the mouse stopped | 262-392 ms | 271-277 ms | 151-156 ms | 134-143 ms |
| cursor behind the mouse, median | 251-356 ms | 259-358 ms | 152-171 ms | 152 ms |
| one playback frame on B (advance + paint), median | 0.19-0.21 ms | 0.14-0.19 ms | 0.19-0.20 ms | 0.17-0.18 ms |

The previous check (modelled relay, glide renderer, before this change):
9.2-9.6 positions/s, the glide running on 76-79% of sampled frames, final
position painted 226-260 ms after the mouse stopped.

Of the ~150 ms the cursor trails the mouse on the lane, 100 ms is the network
(50 ms each way, sender to relay to receiver), up to 17 ms the sender's 60 Hz
window, and 30-40 ms the playback buffer.
