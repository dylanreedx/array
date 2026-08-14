# Array

A native macOS spatial workspace for coding agents — projects, agent tiles,
terminals, browsers, and dev servers on one canvas. Swift/AppKit, SwiftPM,
GhosttyKit terminals, Sparkle updates. Download: [arrayapp.dev](https://arrayapp.dev).

- **Orientation + non-negotiables:** [AGENTS.md](AGENTS.md)
- **Docs index:** [docs/README.md](docs/README.md)
- **Release runbook:** [RELEASE.md](RELEASE.md) · ledger: [docs/VERSIONING.md](docs/VERSIONING.md)

## Build & run (dev)

```sh
swift build --product Array            # bare binary (dev channel by default)
.build/debug/Array                     # run it — uses "Array Dev" state, never prod

scripts/make-app-bundle.sh --configuration debug --output /tmp/ArrayDev.app
open /tmp/ArrayDev.app                 # a real bundle, still the dev channel
```

Dev builds are the **dev channel**: own Application Support dir ("Array Dev"),
own defaults domain, updater inert. Only `scripts/release-app.sh` produces the
prod identity.

## Verify

```sh
scripts/run-matrix.sh                  # the full offline gate
swift run ContinuumRevivedCoreChecks   # fast core leg
scripts/check-app-bundle.sh            # bundle harness (dev channel)
```

When these commands run inside an Array-managed Pi, Claude, or Codex agent,
the runner marks the environment so CoreChecks defers only its intentional
crashing subprocess witnesses; macOS otherwise attributes those crashes to the
GUI host and can terminate the self-hosting app. Real tmux checks still require
the disposable namespace supplied by `run-matrix.sh` and
`qa/run-autonomous.sh`. Run the complete crash-witness gate from an external
terminal or CI. See `AGENTS.md` under **Verifying**.

Two documented KNOWN-RED legs exist — see
[docs/38-tickets/95-go-live.md](docs/38-tickets/95-go-live.md) before assuming
a regression.
