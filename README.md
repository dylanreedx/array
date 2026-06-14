# Continuum Revived

> **Local-only warning for agent runs:** do not push or pull unless Dylan explicitly asks. Report local commit SHAs and artifact paths instead.

Continuum Revived is a native macOS mission-control app for AI coding work. It brings project zones, Ghostty-backed terminal tiles, browser tiles, notes, file trees, and eventually harness-run agent review into one keyboard-first spatial canvas. The product north star is [docs/20-product-vision.md](docs/20-product-vision.md).

## Current status

- Active development happens on `main` through Linear tickets.
- The app is SwiftPM-based and currently optimized for deterministic self-checks plus targeted external QA artifacts.
- Linear is the work source of truth; `.conductor/` is historical/supporting state, not the primary queue.

## Prerequisites

- macOS 14 or newer.
- Xcode command line tools with SwiftPM / Swift 6 support (`swift build`).
- Node.js for repository check scripts.
- A local Ghostty source checkout that provides `macos/GhosttyKit.xcframework`.

Prepare GhosttyKit before building:

```bash
# Optional when Ghostty lives somewhere else:
# export GHOSTTY_SRC=/path/to/ghostty-src
scripts/prepare-ghosttykit.sh
```

The script links `ThirdParty/GhosttyKit.xcframework` to the local Ghostty build artifact.

## Build and run

```bash
swift build
.build/debug/continuum-revived
```

Useful isolated app runs can set project/support roots so real state is not touched:

```bash
CONTINUUM_PROJECT_ROOT="$(mktemp -d)" \
CONTINUUM_APP_SUPPORT="$(mktemp -d)" \
.build/debug/continuum-revived --viewport-sanitize-check
```

## Fast verification matrix

Run the fast local matrix before handing off most changes:

```bash
./scripts/run-matrix.sh
```

It builds the package, runs core/palette/file-tree checks, exercises app `--*-check` flags, verifies the app bundle, checks root docs, and runs `git diff --check`. Some tickets require more than this; follow the ticket acceptance criteria and `docs/21-agent-workflow.md`.

## App bundle check/build

To build and verify a `.app` bundle with artifacts:

```bash
scripts/check-app-bundle.sh --configuration debug
```

For bundle creation only:

```bash
scripts/make-app-bundle.sh --configuration debug --output /tmp/ContinuumRevived.app
```

Bundle verification writes logs under `qa-runs/<timestamp>/app-bundle/` unless `--output-dir` is supplied.

## Nav-mode keymap defaults

Continuum reads nav-mode key overrides from `UserDefaults` keys under `continuum.keymap.*` at startup. Example for the bundled app domain:

```bash
defaults write com.continuum.revived continuum.keymap.leader control+g
defaults write com.continuum.revived continuum.keymap.up i
defaults write com.continuum.revived continuum.keymap.down m
defaults write com.continuum.revived continuum.keymap.left b
defaults write com.continuum.revived continuum.keymap.right r
```

Other single-character bindings: `nextZone`, `previousZone`, `zonePicker`, `workspacePicker`, `agentCycle`, `agentNeedsAttention`, `focusMode`, `deleteTile`. Unbundled `swift run` launches may use the executable's defaults domain rather than `com.continuum.revived`.

## QA artifacts

External QA flows live in `qa/` and are documented in `qa/README.md`. One-time setup:

```bash
qa/setup.sh
```

Session gate for changed-scope work:

```bash
qa/run-autonomous.sh --scope changed
```

QA and bundle checks write reviewable artifacts under `qa-runs/`; read each run's `verdict.md`, `manifest.json`, screenshots, and logs before claiming success.

## Canonical docs

- [CONTRIBUTING.md](CONTRIBUTING.md) — current contribution rules for humans and agents.
- [docs/README.md](docs/README.md) — documentation index, including historical planning docs.
- [docs/20-product-vision.md](docs/20-product-vision.md) — product vision and conflict resolver.
- [docs/21-agent-workflow.md](docs/21-agent-workflow.md) — binding agent workflow and honesty rules.
- [docs/22-linear-master-overnight-workflow.md](docs/22-linear-master-overnight-workflow.md) — coordinator/reviewer workflow.
- [qa/README.md](qa/README.md) — external QA setup, run, and review contract.

If these docs conflict, prefer the ticket and `docs/20-product-vision.md` / `docs/21-agent-workflow.md`; update stale docs deliberately instead of silently working around them.
