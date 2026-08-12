# Array

Array is a native macOS spatial workspace for coding agents: projects, agent
tiles, terminals, browsers, and dev servers live together on one infinite
canvas, so parallel work stays visible instead of stacking up in hidden tabs.
Swift/AppKit, SwiftPM (no Xcode project), hand-assembled .app bundle,
GhosttyKit for terminals, Sparkle for updates. Distributed to a friends alpha
from [arrayapp.dev](https://arrayapp.dev).

This file is the orientation for anyone (human or agent) working in the repo.
Docs index: [docs/README.md](docs/README.md). Release runbook:
[RELEASE.md](RELEASE.md). Versioning + ledger:
[docs/VERSIONING.md](docs/VERSIONING.md).

## What we can never compromise on

### 1. The user's real state is sacred

The prod copy in /Applications owns `~/Library/Application Support/Array` and
the `dev.arrayapp.macos` defaults domain. Dev builds and bare binaries are the
DEV channel (`AppChannel` in Core): "Array Dev" store, `.dev` defaults domain,
updater inert. Never point a dev build at prod state; QA additionally isolates
with `CONTINUUM_APP_SUPPORT` temp dirs.

**The split stops at the app's own state.** A PROJECT's state — canvas, tiles,
notes, managed sessions, lock — lives in `<project root>/.array/` and is keyed
by path, not by channel. Two installs pointed at one root will overwrite each
other's work no matter which channels they are (hazard 9). See the channel
section in
[docs/38-tickets/95-go-live.md](docs/38-tickets/95-go-live.md).

### 2. Witnessed behavior, not plausible behavior

Every substantive change carries a deterministic witness: a `--*-check`
self-check flag on the app binary, a CoreChecks section, or a bundle-harness
assertion — RED before the fix, GREEN after, runnable offline. If a claim has
no witness, it isn't verified. The matrix (`scripts/run-matrix.sh`) is the
gate; the KNOWN-RED legs are listed in `MATRIX_KNOWN_RED` inside that script
(7 as of 0.4.13, explained in the go-live doc) — do not chase them as
regressions and do not add new ones silently.

**A witness only counts if the gate reports it, and only if it watches
behaviour.** Both halves have failed here expensively. A check registered in
`run-matrix.sh` but sitting after a red leg never ran at all — the matrix used to
halt on the first failure, so a real run reported **4 of 135 app legs**, and a
check that had failed since the day it was written went unnoticed while every
image pasted into a composer was silently discarded (fixed in `865b0d3`; read the
summary the matrix now prints at the end, not the exit code alone). And a check
that asserted the app's *source contained a string* stayed green while a reviewer
inverted the exact behaviour it claimed to guard. Assert outcomes, and confirm a
real matrix run prints your leg.

### 3. CLIs own their auth — never API keys

Provider authentication is always the CLI's own login flow (pi's
`/login <provider>`, claude's login, codex's login — OAuth). Array observes
readiness (`pi auth check`), never stores credentials, never guides users to
paste API keys, and never re-implements a provider's auth.

### 4. Identity is two-layered, deliberately

The app is **Array** (bundle id `dev.arrayapp.macos`) everywhere a user can
see. Internal module names (`ContinuumRevived*`), historical tickets, and
legacy fixtures still say Continuum — that is intentional. Never rename
modules, never global find-replace the old name.

### 5. Exact model ids

`pi --model` takes a pattern; partial ids fuzzy-match and run the wrong model
silently. Every offered id is fully qualified (`provider/model`) and comes
verbatim from pi's own catalogue (`AgentModelCatalog`, live-probed at startup,
frozen fallback in QA).

## A small glossary

- **Tile** — one surface on the canvas: terminal, browser, file tree, diff
  review, note, or managed agent.
- **Zone** — a named region of the canvas grouping tiles.
- **Workspace / project** — a project is a filesystem root; the registry
  (`registry.json` in the app-support dir) records projects, workspaces, and
  the last-active pointers.
- **Managed agent** — an agent tile Array runs headlessly through a provider
  CLI. Driven by `AgentSupervisor` → a runner behind the `AgentRunning` seam.
  Two backends today, chosen by `AgentSupervisor.productionRunner(for:)`:
  **claude CLI** (`ClaudeAgentRunner`, for `anthropic/*` models when `claude`
  is installed — runs on the user's own Claude subscription, no extra usage)
  and **pi** (`@earendil-works/pi-coding-agent`, `PiAgentRunner`, for
  everything else — the wide multi-provider catalogue). Distinct from a
  *claude/codex tile*, which is a plain terminal running that CLI
  interactively. See [.plans/01-provider-cli-backends.md](.plans/01-provider-cli-backends.md).
- **Launch profile** — palette entry describing what a terminal tile runs
  (`shell`, `claude`, `codex`, `nvim`, `custom`) — `LaunchProfileRegistry`.
- **Channel** — prod vs dev identity (see non-negotiable #1). Covers the app's
  own state only; a project's `.array/` is shared across channels.
- **The preview app** — `~/Desktop/Array Dev.app` on `~/array-scratch`, rebuilt
  by `scripts/dev-app.sh`. Distinct from Dylan's workspace, the prod copy in
  /Applications, which agents leave alone.
- **The matrix** — `scripts/run-matrix.sh`, the full offline verification
  suite: build, iOS build, checks executables, app self-check legs, bundle
  probe.
- **Self-check / witness** — a deterministic `--*-check` flag handled in
  `ContinuumApp.main()` before AppKit runs.
- **KNOWN-RED** — a documented pre-existing failing gate (see go-live doc);
  never bisect it as a regression.

## Where code lives

- `Sources/ContinuumRevived/` — the app target. `App/` (AppDelegate,
  supervisor, panels, spawner), `Canvas/` (tile NSViews),
  `TerminalEngine/` (GhosttyKit), `BrowserEngine/`.
- `Sources/ContinuumRevivedCore/` — platform-neutral core: registry, stores,
  launch profiles, agent records/providers, config types. Shared with iOS.
- `Sources/ContinuumRevivedSync/` — CloudKit/companion sync (gated off in the
  alpha).
- `Sources/ContinuumRevivedAgentContent/` / `…AgentUI/` — agent transcript
  semantics and shared agent-UI tokens. Dependency direction is one-way:
  Core → AgentContent/AgentUI, never the reverse.
- `Sources/ContinuumRevived*Checks/` — the checks executables (one per leg).
- `scripts/` — matrix, bundle assembly/verification, release pipeline,
  appcast.
- `Packaging/` — Info.plist (prod identity, dev defaults 0.1.0/1 — never
  version-bump in a commit) and the app icon.
- `docs/38-tickets/` — the ticket/program system; **history, do not move or
  rename** (code comments cite these paths). `docs/` proper is indexed by
  [docs/README.md](docs/README.md). `.plans/` holds numbered forward plans.
- `website/` — arrayapp.dev (Astro, deployed by Vercel from `main`), including
  `website/public/appcast.xml` (the Sparkle feed).

## The ways to hurt yourself

1. **Running a dev build against prod state** — see non-negotiable #1; the
   channel split makes the default safe, don't defeat it.
2. **Trusting a stale check binary** — always rebuild the checks product
   before believing a run (`swift build --product ContinuumRevivedCoreChecks`).
3. **HOME-based prefs isolation** — cfprefsd routes the standard defaults
   domain per-user regardless of `HOME`/`CFFIXED_USER_HOME`, and
   `defaults write <abs path>` writes the real domain. Only the channel split
   and explicit suite names isolate preferences.
4. **`grep -q` on a piped process under `set -o pipefail`** — grep exits at
   first match, SIGPIPE kills the producer, the pipeline "fails" though the
   work succeeded. Capture output first (see release-app.sh's notarize calls).
5. **Moving or renaming `docs/38-tickets/` files** — hundreds of code comments
   reference them as stable paths.
6. **Un-gated UI at boot** — anything that can present at startup must stay
   inert in QA (`--*-check` runs, `CONTINUUM_*` env) — the updater and the
   onboarding panel show the pattern.
7. **Guessing a `--*-check` flag** — an unknown flag falls through the whole
   check cascade and boots the FULL app (which then hangs your shell).
   Enumerate real flags from the source:
   `grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift`.
8. **A new `TokenThemed` view** — the ui-probe census will hunt it: it must
   render in an appearance-sweep surface AND an adopted surface, its owner
   name goes in `tokenAdoptedOwners` with owner-scoped legal values
   (`UIProbeAppearance.swift`), and resting states paint `nil`, never
   `.clear` (a painted transparent is an unregistered literal).
9. **Spawning a tile through `canvasView.install` + `saveCanvas(canvasState)`.**
   The canvas has TWO models for project tiles. At boot the flat
   `canvasState.tiles` (WORLD frames) owns the active project; once
   `WorkspaceRuntime` has called `setZones`, the active project's tiles live in a
   `ZoneLayer` (ZONE-LOCAL frames) and the flat collection still holds the
   DEPARTED project's. A spawn that ignores this installs into a stale model,
   frames the tile against a zone that is no longer on screen, and persists it
   through the wrong project's store — this is exactly what file opening did
   until `.plans/15`. Use `CanvasNSView.installProjectTile` and
   `TileSpawner.makeProjectTilePlacement`; terminal, note, browser, and agent
   spawns have NOT been migrated yet and still carry the bug.
10. **Two installs on ONE project root.** The channel split covers Application
   Support and the defaults domain. It does NOT cover a project: the canvas,
   tiles, notes, managed sessions and lock live in `<root>/.array/`, keyed by
   the filesystem path and nothing else. Two apps on one root share those files
   and the last writer wins — this really happened, and it took a canvas from
   nine tiles to one. `.array/lock` is an exclusive `flock`, so they cannot even
   be open at once; and because agent TILES live in the shared canvas while
   agent RECORDS are channel-split, the second app mints a duplicate agent for
   every tile it finds no record for. Give each install its own root.

## Running the app while Dylan is using it

Two installs, split by ROLE. Never by project — see hazard 9.

- **`/Applications/Array.app` is Dylan's workspace.** Prod channel, owns
  `~/Documents/personal`. He works in it all day. **Never rebuild it, never
  quit it, never point anything else at its project root.** It changes only
  when a real release ships (RELEASE.md) and he takes the update.
- **`~/Desktop/Array Dev.app` is the preview window.** Dev channel, pinned to
  `~/array-scratch`. Rebuild and relaunch it as often as you like; nothing in
  it is meant to survive.

```sh
scripts/dev-app.sh              # quit, rebuild, relaunch — ~16s
scripts/dev-app.sh --no-launch  # rebuild only
```

**Use that script; do not hand-roll the loop.** Four things it gets right that
cost a session to learn:

1. **Debug, never `--configuration release`.** Release is whole-module
   optimization — every edit recompiles the world, ~6 minutes, to look at a UI
   change. Debug is incremental: ~15s. Release configuration is for shipping.
2. **`CONTINUUM_PROJECT_ROOT` pins the project**, and it is the first rung of
   `ProjectRootResolver.resolve()` — ahead of the registry's last-active
   project. Wiping the dev store is NOT enough on its own; the app re-adopts
   the last root it knew.
3. **`open --env …`, never `App.app/Contents/MacOS/Array` directly.** The
   direct executable makes the app a child of the calling shell, so it dies
   when that shell's process group is torn down — which is exactly what happens
   when an agent runs a script. `nohup`/`disown` does not save it. Verify a
   launch AFTER your tool call returns, not while your shell is still alive.
4. **The scratch root is outside `~/Documents`.** `Documents`, `Desktop` and
   `Downloads` need an explicit folder grant
   (`requiresExplicitProjectFolderGrant`), and the dev bundle's ad-hoc
   signature changes on every rebuild, so that modal returns every launch — the
   app just sits there, apparently booting to nothing.

## Verifying

- Full gate: `scripts/run-matrix.sh`. It runs every leg and ends with a report —
  legs run, expected KNOWN-RED (from `MATRIX_KNOWN_RED`), any KNOWN-RED that
  unexpectedly PASSED, and real failures. Judge a run by that summary. Builds
  still halt on purpose; a failed build makes later results meaningless.
  `CONTINUUM_SKIP_UI_BASELINES=1` skips the two display-dependent baseline legs
  without touching a baseline. **Never** `CONTINUUM_UPDATE_BASELINES=1`.
  Editing that script: two program checks pin lines in it verbatim with
  `grep -Fxc` (one also locks its first four lines), and the committed inventory
  records legs by literal invocation, so renaming a wrapper reads as deleted
  checks.
- Targeted: `swift run ContinuumRevivedCoreChecks`, or a single app leg like
  `.build/debug/Array --onboarding-panel-check`. **Never guess a flag** — an
  unknown one falls through the cascade and boots the full app, hanging the
  shell. Enumerate:
  `grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift | sort -u`
- Performance: a new tile, renderer, or document view goes through the checklist
  in [docs/internals/performance.md](docs/internals/performance.md) before it
  ships. One view per content item and any measurement inside `layout()` are how
  the Markdown tile froze the app for three releases; that file also lists the
  OS reports to read FIRST when something is slow, because reasoning about it
  cost two of those releases.
- Bundle: `scripts/check-app-bundle.sh` (dev channel by default;
  `--channel prod` for release verification). It asserts identity, Sparkle
  embedding, launch smoke, and pollution guards over the real dirs.

## Releases

Follow [RELEASE.md](RELEASE.md) exactly. The build number (CFBundleVersion)
is Sparkle's comparison field: +1 every release, never reused. Both DMG
assets every release (`Array.dmg` constant + `Array-X.Y.Z.dmg`), regenerate
the appcast, append the ledger row in [docs/VERSIONING.md](docs/VERSIONING.md).
Work lands on `array/integration` and fast-forwards to `main` (Vercel deploys
the site + feed from `main`).

## Git

- Commits only under Dylan's identity. No AI-attribution trailers, no
  Co-Authored-By. No exceptions.
- Never commit: the Sparkle private EdDSA key (Keychain-only), `releases/`,
  `.env`, QA stores, signing material.
