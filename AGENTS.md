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
with `CONTINUUM_APP_SUPPORT` temp dirs. See the channel section in
[docs/38-tickets/95-go-live.md](docs/38-tickets/95-go-live.md).

### 2. Witnessed behavior, not plausible behavior

Every substantive change carries a deterministic witness: a `--*-check`
self-check flag on the app binary, a CoreChecks section, or a bundle-harness
assertion — RED before the fix, GREEN after, runnable offline. If a claim has
no witness, it isn't verified. The matrix (`scripts/run-matrix.sh`) is the
gate; two KNOWN-RED pre-existing legs are documented in the go-live doc — do
not chase them as regressions and do not add new ones silently.

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
- **Managed agent** — an agent tile Array runs headlessly through **pi**
  (`@earendil-works/pi-coding-agent`, host-installed npm CLI). Driven by
  `AgentSupervisor` → `PiAgentRunner`. Distinct from a *claude/codex tile*,
  which is a plain terminal running that CLI interactively.
- **Launch profile** — palette entry describing what a terminal tile runs
  (`shell`, `claude`, `codex`, `nvim`, `custom`) — `LaunchProfileRegistry`.
- **Channel** — prod vs dev identity (see non-negotiable #1).
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

## Verifying

- Full gate: `scripts/run-matrix.sh` (KNOWN-RED legs documented in the
  go-live doc).
- Targeted: `swift run ContinuumRevivedCoreChecks`, or a single app leg like
  `.build/debug/Array --onboarding-panel-check`.
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
