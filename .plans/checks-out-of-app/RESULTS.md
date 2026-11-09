# Checks out of the release app: first slice

Base: c476ced9. Branch: array/checks-out-of-app.

Use ARRAY_CHECKS, defined by SwiftPM for debug only. This keeps witnesses in the
same module as the real production entry points without copying implementations
or expanding their access levels. Explicit release witness builds can opt in with
-Xswiftc -DARRAY_CHECKS. Ordinary release builds omit this slice.

Scope: TileSurfaceResidencyChecks (3,248 lines), TranscriptRhythmChecks (2,902),
AgentFirstPaintChecks (2,852), FileOpenChecks (1,992): 10,994 lines, plus eight
main dispatch branches. Debug contains identical witness implementations. Normal
production paths are unchanged. Probe/lab types have production references (for
example Component Lab uses SidebarScreenshotChecks); gating the entire 100k lines
requires a separate review of these boundaries and the inline AppDelegate checks.

Release flags: the eight removed branches fall through to the existing unknown
check guard, which exits 1 before normal boot. Other check branches remain in this
first slice, including those required by check-app-bundle.sh. Consequently a
zero-count strings search for '-check' is NOT achieved by this slice.

Packaging blocker: release's lock re-exec discarded arguments already consumed by
its parser and immediately failed '--output <path> is required'. Preserve original
argv for the re-exec. This failure was observed before the fix; the baseline
packaging command completed after the fix. No new verifier tooling.

## Measurements and verification

Logs: qa-runs/checks-out-of-app (untracked, disposable).
Baseline command: /usr/bin/time -p scripts/make-app-bundle.sh --configuration release
--channel prod --output ~/array-scratch/checks-out-of-app/Before.app.
Fresh worktree with no build products; GhosttyKit prepared by existing script.
Before release: 1115.32 seconds; raw executable 150802488 bytes.
Before initial debug: 119.99 seconds. One-comment edit in ContinuumApp.swift:
before incremental 36.41 seconds, after incremental 39.44 seconds.
Gated debug build: PASS (86.05 seconds). No debug speed gain demonstrated.

IMPORTANT: two unrelated Swift builds started during baseline compilation; Array
and Chrome were also using CPU. These are observed timings, NOT a controlled
quiet-machine performance comparison. Dependency checkout happened only before
the baseline. After release retains checkouts but starts with no release products.

Targeted debug: 9/10 passed. Transcript rhythm, active-context file open, Markdown
performance, agent local-file links, Markdown preview, gesture telemetry, agent
first paint, workspace API open, app-support channels passed. Surface residency
failed: 'flag off must still pay the native cascade — a gesture that laid nothing
out was not a gesture'. Cause unresolved; do not label it pre-existing without a
baseline witness. All targeted runs use isolated roots/app support, disable tmux,
and unset inherited TMUX/TMUX_PANE. Full matrix owns its verified private socket.

The packaging script performs its normal mandatory ad hoc signing; no Developer
ID signing, notarization, release assets, pushes or /Applications changes.

## Scope correction after release compile

The first release attempt failed in AppThemeChecks.swift:23 and
CanvasZoomInvalidationProbeChecks.swift:223 because both depend on
TileSurfaceResidencyChecks. That file and its two dispatch branches are now
left unchanged. Final scope is THREE pure-check files, 7,746 lines, SIX branches.
The final release retry reuses dependencies compiled during the failed clean
attempt; its wall time is not a clean-build comparison. Earlier scope and
incremental measurements above describe the four-file candidate. Debug bodies
are unchanged between these candidates. The full 100k-line extraction is not
complete, and no release-speed improvement is established by these measurements.

The release retry ran 894.18 seconds but FAILED: ContinuumApp.swift was modified
during compilation while removing the residency dispatch gates. This was an
execution error, not a release compiler incompatibility. No after binary/size or
bundle result from that attempt is valid. The queued verifier continued into the
full matrix; release verification must be repeated after its lock is released.
