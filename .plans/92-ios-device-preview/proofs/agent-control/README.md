# Agent visual-control evidence — 2026-10-29

The implemented tool contract is [workspace iOS Preview](../../../../docs/internals/workspace-ios-preview.md).
The [progress note](../../agent-control-progress.md) records the initial slice and
remaining gates. All follow-up source and these proofs remain uncommitted.

- `offline-matrix-checks.log`: actual check output excerpt of the 12-leg passing
  targeted matrix; source log/digest recorded in `evidence-origin.json`. Build
  diagnostics are omitted, no check result is synthesized.
- `adoption-red.log`: behavioral failure before arbitrary simulator UUID adoption
  was replaced by template-based host creation and scoped durable receipts.
- `api-negative.log`: a changed retry key makes the exactly-one-effect assertion
  fail, proving that the effect witness observes actual dispatched taps.
- `controller-light.png` / `controller-dark.png`: actual rendered shared controls
  and agent-controller status, inspected in both appearances.
- `live-matrix.log` / `device-api-report.json`: **2/2 live gate PASS**, production
  API→fresh owned simulator→real UIKit portrait+landscape taps, same-key retry and
  stale geometry add no input, source template unchanged. Returned images are
  `device-api-after-tap.jpg` and `device-api-landscape-after-tap.jpg`.
- `mid-transition-negative.jpg` / `.log`: the failing test tapped while UIKit was
  still animating rotation. Its new bounds alone did not mean a settled visual
  target. The final witness waits for the app's actual transition completion;
  the production transform and tap implementation were not changed to hide it.
- `owned-device-cleanup-verification.json`: read-only existence check confirms
  all ten exact IDs from the final/diagnostic runs are absent, without touching
  other simulators.
- `dev-bundle-manifest.json`: actual isolated bundle verdict, eight self-checks,
  LaunchServices smoke, valid ad-hoc signature and pollution flags. The QA wrapper
  verifies/cleans an explicit disposable tmux socket between probes.

Raw logs, failure diagnosis and generated QA state are local under
`qa-runs/overnight-2026-10-29/ios-control/`; see its `HANDOFF.md`. No provider model
turn, full release matrix, release signing/notarization, sustained two-device
performance or Xcode27 compatibility is established by this evidence.
