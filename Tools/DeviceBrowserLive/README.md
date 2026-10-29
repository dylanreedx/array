# Live device/browser acceptance

Run explicitly; this spends real Codex/Pi usage and boots new simulators:

```sh
ARRAY_DEVICE_BROWSER_LIVE=1 scripts/check-device-browser-live.sh
```

The default matrix never runs this witness. It requires Xcode, an available iOS
simulator template, xcodegen, Python 3, Node, and signed-in Codex/Pi CLIs. Array's
production integrity-pinned helper installer supplies its simulator transport.
Optional exact catalogue selections:
`ARRAY_DEVICE_BROWSER_LIVE_CODEX_MODEL` / `ARRAY_DEVICE_BROWSER_LIVE_PI_MODEL`.
`ARRAY_DEVICE_BROWSER_LIVE_HARNESSES=codex` (or `pi`) limits an explicit retry
to one harness; the default attempts both.
`ARRAY_DEVICE_BROWSER_LIVE_OUT` selects the artifacts directory (use a fresh one).

The Swift witness mounts a disposable workspace in a test-owned offscreen window
(for trusted native WebKit input; it never activates or uses the preview app) and uses the production runner
factory, transcript/draft stores, workspace MCP host, and Pi bridge. Reply
observers record requests and responses without changing the response delivered
to the runner. Screenshot bytes are saved separately from JSON evidence.

Each harness reads/clicks a loopback counter page, then lists templates, creates
its own simulator, builds/installs a tiny UIKit app through device.build_run,
observes/taps/re-observes, and closes its attachment. Independent server counts
and UIKit state-file readback guard the model's final claims. Ask first is tested
with a trusted approval-handler denial followed by approval and a real build.
This tests grant decisions; it does not establish human approval-sheet UX.

Only simulators created in this run's private managed-device ledger are cleaned
up. The Python fallback also refuses any UUID present before the test. Neither
an existing booted simulator nor the shared preview app is adopted. All tmux
verification uses a verified disposable namespace. A failed phase remains in the
journal and the other harness is still attempted when safe.
