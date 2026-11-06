# Pointer isolation investigation (partial)

Bench: `.worktrees/pointer-isolation`, branch `array/pointer-isolation`, base `0533e3f0`. No push, preview launch, live tile input, CGEvent posting, pointer warp, activation, standard-default writes, tmux or full matrix.

## Findings

1. **Hover theft — UNTESTED.** The engine monitor excludes passive pointer events. Real mouse tracking can therefore reach WebKit independently of direct agent delivery. The prior research reports no page mousemove/hover in its inactive off-screen probe. That is no proof of isolation or of theft. CSS hover, mouseleave dropdown and tooltip interleavings still need new behavioral witnesses.
2. **Native select tracking — UNTESTED.** Stage 1 preflight recognizes HTML selects and associated labels, including the active key target. That source inspection does not establish universal popup prevention: arbitrary callbacks, delayed/cached showPicker remain a documented gap. No new native-menu tracking experiment ran here.
3. **Down/up split — UNTESTED.** deliverClick calls down then up synchronously, but nested framework tracking can reenter. The existing experimental witness interleaves an in-tile key through NSApp.sendEvent during click and confirms immediate durable takeover. Mouse drags and clicks between down/up were not tested here; atomicity is not established.
4. **Canvas hover side effects — UNTESTED.** TileNSView forwards entered/exited to relationship hover and completion-hover hooks. Canvas residency independently samples mouseLocationOutsideOfEventStream and stamps pointer-rest liveness. Filtering NSEvents alone would not cover that reader. No browser surface-swap or runtime-state witness ran here.
5. **Real-pointer readers — UNTESTED.** Canvas residency uses the real window pointer absent its existing checks provider. wakeAgentChromeUnderPointer also samples it, but explicitly targets ManagedAgentTileNSView. BrowserAutomation direct click geometry uses the requested CSS position and view conversions. No exhaustive WebKit cursor/read audit or behavior claim.
6. **False scroll takeover — PROVEN, fixed for camera-session follow-through.** After pinch/zoom, CanvasCameraDriver.isCameraSessionActive keeps precise scroll routed to the camera even over web content. BrowserAutomation independently hit-tested it and durably revoked the browser lease. The monitor now recognizes that same camera-session condition before takeover, independent of local-monitor order. Ordinary in-tile scroll after the session still takes over. Phase-only, momentum, modifier changes and Space/Cmd pointer pans remain UNTESTED; this is not a universal scroll-routing claim.

## Witness and build evidence

Extended the existing matrix-registered `--browser-durable-takeover-check` with mounted workspace/tools/queue behavior: start a camera zoom session, send a synthetic scroll through NSApp.sendEvent over the browser, assert unchanged input generation; end the camera session and assert in-tile scroll takes over. Existing checks assert durable fencing and handback. The matrix already invokes this flag with both backend settings; no new flag or verifier was introduced. Full matrix intentionally not run.

- Initial debug build exit 0: `/tmp/pointer-build.log` (176.25s). Updated-witness build exit 0: `/tmp/pointer-red-build.log`.
- RED before production fix: `/tmp/pointer-red.log`, exit 1 at camera-follow-through assertion. This first run omitted explicit CONTINUUM_APP_SUPPORT isolation and read the dev registry during restore (including stale project records); no production state was targeted. Do not repeat that omission.
- An isolated run started before the replacement binary finished linking also failed the same assertion: `/tmp/pointer-green-0.log`. It exercised the old binary and is additional red evidence, not a green result.
- Fixed debug build actual exit 0: `/tmp/pointer-green-build.log` (53.60s).
- GREEN after confirmed build: `/tmp/pointer-final-0.log`, exit 0, default backend; `/tmp/pointer-final-1.log`, exit 0, focus-free backend. Explicit unique /tmp app-support/project dirs, ARRAY_AGENT_ID unset, TERM=xterm-256color, stdin /dev/null and `/tmp/exc-probe/noexc`; tmux disabled. No display failure requiring caffeinate retry.
- `git diff --check` passed.
- `scripts/benches.sh` ran at pickup; inventory reported 157 benches needing a look and none safe to return. This unlanded bench must remain available for the lead.

## Remaining work

The requested investigation is incomplete. Passive pointer filtering, atomic click protection and universal popup prevention have NOT been implemented. The other five hypotheses need production-path red witnesses before changes. A physical-mouse test still needs a separately authorized safe setup to verify hover/dropdown/tooltip behavior and actual trackpad phase/momentum routing; synthetic off-screen events alone cannot establish real-pointer coexistence. focusFreeInputEnabled still defaults false. No private API was added.
