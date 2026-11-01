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
