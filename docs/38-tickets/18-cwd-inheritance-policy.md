# cwd inheritance policy for new terminal tiles

Rests on decision **D12** (new-tile cwd inheritance) in `docs/38-locked-decisions.md`,
grounded by the "New-window cwd" section of
`docs/2026-06-30-orchestration-spikes/TOPOLOGY.md`.

## What this delivers

When you spawn a *new* terminal tile — via the command palette, a keyboard shortcut, or any
other new-tile path — it opens in the directory you were already working in, not always at
the project root. Concretely: if a terminal tile is the last-active tile, the new tile
inherits that tile's current working directory, as reported by the OSC-7 mechanism already
wired into `GhosttyTerminalRuntime.capturedCwd`. If no terminal is active (first tile in a
project, or the active tile is a browser or note tile), the new tile falls back cleanly to
the project root. The behavior is controlled by a `newTileCwd` setting with three options —
`inheritFocus`, `projectRoot`, `lastUsed` — defaulting to `inheritFocus`, persisted to
UserDefaults, and surfaced as a choice field in the Terminal section of Settings.

The result is that opening a second shell next to an active coding session "just works":
no `cd` ceremony, no disorientation.

**This ticket touches the fresh-spawn path only.** Restart / restore-from-descriptor is a
deliberately separate path that must keep its existing behavior — see "The restore boundary"
below, which is the one seam an implementer would otherwise have to stop and ask about.

## How it fits

Today, `TileSpawner.spawnTerminal(profileId:at:allowTmuxPersistence:)`
(`TileSpawner.swift:108`) resolves a `LaunchProfile` whose `cwd` comes from
`terminalProjectRoot()` (`TileSpawner.swift:112`, and the helper itself at
`TileSpawner.swift:217-219`), then hands that profile to the private
`spawnTerminal(profile:launchProfileId:agentDescriptor:createdAt:at:allowTmuxPersistence:)`
overload (`TileSpawner.swift:151`). The private overload tmux-wraps the profile
(`TileSpawner.swift:176-178`) and then persists the `TerminalSessionDescriptor` with
`cwd: launchProfile.cwd` (`TileSpawner.swift:194-207`). There is no per-spawn cwd override
and no concept of "what tile was active." This ticket threads a resolved cwd into the fresh
path at the point where the profile is built — before the profile reaches the private
overload — replacing the hard-coded project root with a policy-driven resolution.

It builds directly on the project-session topology design, which calls out cwd inheritance
as one of the core UX payoffs of the new layout (TOPOLOGY.md "New-window cwd", lines
440-471). It also mirrors the configurable-first pattern established by `SessionResumeConfig`
(`SessionResumeConfig.swift` — a pure `enum` with `…Key` / `…Default` statics and a
`(defaults:)` reader), adding a new config object — `NewTileCwdConfig` — to
`ContinuumRevivedCore` that the spawner consults.

This ticket does not implement the project-session tmux topology (one session per project,
tiles as windows). It implements the cwd resolution policy that makes sense now and that
the topology ticket will rely on unchanged: the resolution function is the same whether the
spawn ultimately calls `tmux new-session -A -c <cwd>` (current model) or
`tmux new-window -t <projectSession> -c <cwd>` (future topology). That means this ticket
ships independently and continues to work after the session topology lands — the resolved
cwd string is just passed to whichever tmux invocation is active.

## The restore boundary — read this before touching the spawner

The fresh-spawn path and the restore path are **different methods** and must resolve cwd by
**different rules**. This is the seam an unattended implementer must not blur:

- **Fresh spawn** — `spawnTerminal(profileId:at:allowTmuxPersistence:)`
  (`TileSpawner.swift:108`) → private `spawnTerminal(profile:…)` (`TileSpawner.swift:151`).
  The private overload builds the descriptor directly from `launchProfile.cwd`
  (`TileSpawner.swift:200`); there is **no** persisted-descriptor lookup here. This is the
  only path the new policy applies to. On a fresh spawn there is by definition no persisted
  post-`cd` cwd to honor, so the policy decides the cwd.

- **Restart / restore** — `restartTerminalTile(tileId:)` (`TileSpawner.swift:276`) explicitly
  prefers the persisted descriptor's cwd over the resolved project root:
  `let restoredCwd = persistedDescriptor?.cwd ?? profile.cwd` (`TileSpawner.swift:303-304`).
  That is correct and intentional — a restored tile must reopen in the directory the user had
  `cd`'d into, captured from OSC-7 and flushed to the descriptor. **Do not** route
  `restartTerminalTile` through the new policy. The persisted cwd wins on restore; the policy
  wins on fresh spawn. These do not conflict because they never run on the same call.

So the rule is unambiguous: **persisted descriptor cwd wins on restore; policy wins on fresh
spawn.** The ticket's acceptance test asserts the fresh-spawn side precisely because that is
where the descriptor is first written from the policy-resolved cwd.

## The approach

Add `NewTileCwdConfig` to `ContinuumRevivedCore`: a pure-enum config object holding the
UserDefaults key (`continuum.terminal.newTileCwd`), the default policy (`inheritFocus`),
and a static resolver function that takes a `UserDefaults` and returns the decoded enum.
The enum cases are: `inheritFocus`, `projectRoot`, `lastUsed`.

Put the *decision logic* in a free function in Core with a fully injectable signature
(`resolveNewTileCwd(policy:focused:lastUsed:projectRoot:)`) so it is unit-testable without
AppKit, Ghostty, or a `TileSpawner` instance. `TileSpawner` calls this free function; it
holds no branching of its own beyond reading its provider and updating `lastSpawnedCwd`.

In `TileSpawner`, add a `focusedTerminalCwdProvider` closure property — injected by the site
that wires up the spawner (the AppDelegate block at `ContinuumApp.swift:2400-2438`), settable
in tests — that returns the `capturedCwd` of the last-active terminal runtime, or `nil` if
the active tile is not a terminal. The public
`spawnTerminal(profileId:at:allowTmuxPersistence:)` method, after resolving the
`LaunchProfile` from the registry, overrides that profile's `cwd` with the policy result
**before** passing it to the private overload — which means before tmux-wrapping, so the
inherited cwd lands in both the tmux `-c <cwd>` argv and the persisted descriptor. The
`projectRoot` passed to `registry.resolve` is unchanged (profile *selection* keys off the
project root, not the inherited cwd); only the resulting profile's `cwd` field is overridden.

The `lastUsed` case tracks the most-recently-resolved cwd in a private stored property on
`TileSpawner`. On first spawn it degrades to `projectRoot`. See "lastUsed scope" below for
exactly what "last" means.

Finally, add a `.choice` field to the Terminal section of `SettingsSchema` bound to
`NewTileCwdConfig.userDefaultsKey`, with options `["inheritFocus", "projectRoot",
"lastUsed"]` and default `"inheritFocus"`.

### lastUsed scope (pinned — D12 leaves this open, so this ticket closes it)

`lastSpawnedCwd` is an **in-memory stored property on the `TileSpawner` instance**. A
`TileSpawner` is constructed per active project/canvas (it holds a single `project` and
`canvasView`; see the construction at `ContinuumApp.swift:2400`). Therefore `lastUsed` scope
is: **the lifetime of that spawner instance — i.e. the current app process, for the currently
active project.** It is **not** persisted to UserDefaults or the descriptor, so it **resets on
relaunch** (first spawn after launch degrades to `projectRoot`), and it does **not** carry
across a project switch that rebuilds the spawner. This is the smallest correct choice: it
makes `lastUsed` mean "the last directory a new shell opened into during this session," which
is what the policy name implies, without introducing a new persistence surface. Do not persist
it; if cross-relaunch `lastUsed` is ever wanted, that is a follow-up that would store it on the
workspace document.

## Where it lives

**New file — Core config object + pure resolver:**
- `Sources/ContinuumRevivedCore/NewTileCwdConfig.swift`
  - `public enum NewTileCwdPolicy: String, CaseIterable, Sendable { case inheritFocus,
    projectRoot, lastUsed }`
  - `public enum NewTileCwdConfig` with `userDefaultsKey`, `defaultPolicy`, and
    `policy(defaults:) -> NewTileCwdPolicy`.
  - `public func resolveNewTileCwd(policy:focused:lastUsed:projectRoot:) -> String` — the
    pure decision function, no side effects, unit-testable in Core.

**Modified — spawner (`Sources/ContinuumRevived/App/TileSpawner.swift`):**
- Stored-properties region (the `var`/`weak var` block that starts at
  `TileSpawner.swift:27` with `weak var canvasView` and runs through the browser/persistence
  handler closures near `:65`): add
  `var focusedTerminalCwdProvider: (() -> String?)?` and
  `private var lastSpawnedCwd: String?` alongside the other injectable closures (place them
  next to `terminalProjectContextProvider` at `:45`, which is the analogous injected provider).
- `spawnTerminal(profileId:at:allowTmuxPersistence:)` (`TileSpawner.swift:108-134`): after the
  `switch resolution { case let .found(p): profile = p … }` block (`:119-124`) that yields
  `profile`, and **before** the `return spawnTerminal(profile: profile, …)` call (`:126-133`),
  compute the policy-resolved cwd and rebuild `profile` with that cwd (see breadcrumbs). Pass
  the rebuilt profile to the private overload. Leave the `registry.resolve(… in: projectRoot …)`
  call at `:113-118` unchanged.
- New method `resolvedSpawnCwd(projectRoot:) -> String` (private) — reads the policy from
  `defaults`, reads `focusedTerminalCwdProvider?()`, calls the pure `resolveNewTileCwd(…)`
  free function, writes `lastSpawnedCwd`, returns the string. Its only side effect is the
  `lastSpawnedCwd` write.
- `terminalProjectRoot()` (`TileSpawner.swift:217-219`): unchanged; still used for profile
  resolution and agent descriptors.
- `restartTerminalTile(tileId:)` (`TileSpawner.swift:276`) and its
  `persistedDescriptor?.cwd ?? profile.cwd` logic (`:303-304`): **unchanged** — see "The
  restore boundary."
- `spawnHarnessRoleRun` (`TileSpawner.swift:136`): unchanged — see "Watch out for."

**Modified — Settings schema (`Sources/ContinuumRevivedCore/SettingsSchema.swift`):**
- Terminal section (`SettingsSchema.swift:133-164`, the `SettingsSection(id: "terminal" …)`
  whose `fields` array currently ends with the two `TerminalScrollConfig` `.text` entries at
  `:153-162`): append a `.choice` entry after the last field, before the closing `]`.

**Modified — spawner wire-up (`Sources/ContinuumRevived/App/ContinuumApp.swift`):**
- The block that assigns the spawner's injected closures (`ContinuumApp.swift:2408-2437`,
  where `spawner.terminalProjectContextProvider = …` is set at `:2423`): add the
  `spawner.focusedTerminalCwdProvider = { … }` assignment next to it. This block already
  captures `canvasView`, which is what the provider reads.

## Implementation breadcrumbs

```swift
// NewTileCwdConfig.swift (Core — new file)
import Foundation

public enum NewTileCwdPolicy: String, CaseIterable, Sendable {
    case inheritFocus   // OSC-7 cwd from the last-active terminal tile
    case projectRoot    // always terminalProjectRoot() — today's behavior
    case lastUsed       // last cwd resolved by a fresh spawn in this spawner instance
}

public enum NewTileCwdConfig {
    public static let userDefaultsKey = "continuum.terminal.newTileCwd"
    public static let defaultPolicy = NewTileCwdPolicy.inheritFocus

    public static func policy(defaults: UserDefaults = .standard) -> NewTileCwdPolicy {
        guard let raw = defaults.string(forKey: userDefaultsKey) else { return defaultPolicy }
        return NewTileCwdPolicy(rawValue: raw) ?? defaultPolicy
    }
}

// Pure decision function — the whole policy, injectable, no AppKit / no TileSpawner.
public func resolveNewTileCwd(
    policy: NewTileCwdPolicy,
    focused: String?,
    lastUsed: String?,
    projectRoot: String
) -> String {
    switch policy {
    case .inheritFocus: return focused ?? projectRoot
    case .projectRoot:  return projectRoot
    case .lastUsed:     return lastUsed ?? projectRoot
    }
}
```

```swift
// TileSpawner.swift — new stored properties, beside terminalProjectContextProvider (~:45)
var focusedTerminalCwdProvider: (() -> String?)?
private var lastSpawnedCwd: String?
```

```swift
// TileSpawner.swift — new private helper (side effect: writes lastSpawnedCwd)
private func resolvedSpawnCwd(projectRoot: String) -> String {
    let policy = NewTileCwdConfig.policy(defaults: defaults)
    let focused = focusedTerminalCwdProvider?()   // nil when active tile is not a terminal
    let resolved = resolveNewTileCwd(
        policy: policy,
        focused: focused,
        lastUsed: lastSpawnedCwd,
        projectRoot: projectRoot
    )
    lastSpawnedCwd = resolved
    return resolved
}
```

```swift
// TileSpawner.swift — inside spawnTerminal(profileId:at:allowTmuxPersistence:),
// after the `switch resolution { case let .found(p): profile = p … }` block (~:124)
// and BEFORE `return spawnTerminal(profile: profile, …)` (~:126).
//
// LaunchProfile is a STRUCT with exactly four fields
// (command, arguments, cwd, title) and NO with(cwd:) helper today
// (verified: Sources/ContinuumRevivedCore/LaunchProfile.swift:3-15).
// Rebuild it copying all four fields, overriding only cwd:
let inheritedCwd = resolvedSpawnCwd(projectRoot: projectRoot)
let effectiveProfile = LaunchProfile(
    command: profile.command,
    arguments: profile.arguments,
    cwd: inheritedCwd,          // <-- the only field that changes
    title: profile.title
)
// Then pass effectiveProfile (not profile) to the private overload:
return spawnTerminal(
    profile: effectiveProfile,
    launchProfileId: spec.id,
    agentDescriptor: agentDescriptor(for: spec, projectRoot: projectRoot, at: now),
    createdAt: now,
    at: worldPoint,
    allowTmuxPersistence: allowTmuxPersistence
)
```

Doing the override here (before the private overload) means the inherited cwd reaches
`tmuxWrappedProfileIfAvailable` (`TileSpawner.swift:221`), so it is baked into the tmux
`-c <cwd>` argv, and it is what gets written to the descriptor at `TileSpawner.swift:200`.
That is exactly what the backend test asserts.

Optional cleanup (only if you find yourself repeating the four-field copy at another call
site): add `func with(cwd: String) -> LaunchProfile` to `LaunchProfile`. It does **not**
exist today. For a single call site the inline copy above is enough — do not add the helper
speculatively.

```swift
// SettingsSchema.swift — Terminal section, append after the last TerminalScrollConfig
// .text field (~:162), before the closing `]` of the fields array (~:163).
// .choice signature (verified SettingsField.swift:17):
//   case choice(key: String, label: String, options: [String], default: String)
.choice(
    key: NewTileCwdConfig.userDefaultsKey,
    label: "New Shell Directory",
    options: NewTileCwdPolicy.allCases.map(\.rawValue),
    default: NewTileCwdConfig.defaultPolicy.rawValue
),
```

```swift
// ContinuumApp.swift — beside `spawner.terminalProjectContextProvider = …` (~:2423),
// in the same closure-assignment block that already captures canvasView.
// Focus source of truth per TOPOLOGY.md:459 — last-active tile's runtime cwd, NOT
// focusBroker.activeSurface. lastActiveTileId is kept in sync with focus by
// ZoneRuntimeController (see :103), and TileSpawner already reads it the same way (:872).
spawner.focusedTerminalCwdProvider = { [weak canvasView] in
    guard let canvasView,
          let tileId = canvasView.canvasState.lastActiveTileId,
          let terminalView = canvasView.tileView(for: tileId) as? TerminalTileNSView
    else { return nil }
    return terminalView.runtime.capturedCwd   // TerminalTileNSView.runtime :11; capturedCwd :171
}
```

## How we test it

### Logic (pure Core checks)

In a `@Test` function in `ContinuumRevivedCore` (no AppKit, no Ghostty), against the free
functions in `NewTileCwdConfig.swift`:

- `NewTileCwdConfig.policy(defaults:)` returns `inheritFocus` when no key is set.
- `NewTileCwdConfig.policy(defaults:)` returns `projectRoot` when the key holds `"projectRoot"`.
- `NewTileCwdConfig.policy(defaults:)` returns `inheritFocus` (the default) when the key holds
  an unrecognized value.
- `resolveNewTileCwd(policy: .inheritFocus, focused: "/x", lastUsed: nil, projectRoot: "/root")`
  returns `"/x"`.
- `resolveNewTileCwd(policy: .inheritFocus, focused: nil, lastUsed: nil, projectRoot: "/root")`
  returns `"/root"`.
- `resolveNewTileCwd(policy: .lastUsed, focused: "/x", lastUsed: nil, projectRoot: "/root")`
  returns `"/root"` (no prior spawn → degrade to project root; `focused` is ignored under
  `lastUsed`).
- `resolveNewTileCwd(policy: .lastUsed, focused: nil, lastUsed: "/prev", projectRoot: "/root")`
  returns `"/prev"`.
- `resolveNewTileCwd(policy: .projectRoot, focused: "/x", lastUsed: "/prev", projectRoot: "/root")`
  returns `"/root"` (always project root regardless of the others).

Use a scratch `UserDefaults(suiteName: "test.\(UUID())")!` for the `policy(defaults:)` cases.

### Backend (real-path / integration — not bypassed)

Follow the **existing** terminal self-check harness pattern, not a hypothetical one:
`TileSpawner.runTerminalTmuxPersistenceSelfCheck()` (`TileSpawner.swift:3137`) is a
`static func … throws -> URL` that builds a real `TileSpawner` with a real
`GhosttyRuntimeContext`, real `ProjectStore`, and scratch `UserDefaults`, spawns via
`spawnTerminal(profileId: "shell")`, loads the persisted `TerminalSessionDescriptor` from the
store, and asserts on `descriptor.cwd` (see its `spawnAndDescriptor` helper at
`TileSpawner.swift:3195-3207` and the cwd assertions at `:3264`, `:3276`). These checks are
invoked from `ContinuumApp` behind a CommandLine flag (e.g. the
`--terminal-tmux-persistence-check` branch at `ContinuumApp.swift:1867`), and write a
measured `manifest.json` — mirror that.

Add a new `static func runNewTileCwdSelfCheck() throws -> URL` in the same
`#if …`/self-check region, reusing that `makeSpawner` + `spawnAndDescriptor` pattern:

1. Build a spawner rooted at a temp `projectRoot`, with a scratch `UserDefaults`.
2. **inheritFocus with a focused terminal:** set the policy key to `"inheritFocus"`, set
   `spawner.focusedTerminalCwdProvider = { "/tmp/inherit-<uuid>" }` (a real existing temp
   dir), call `spawnTerminal(profileId: "shell")`, load the descriptor, and assert
   `descriptor.cwd == "/tmp/inherit-<uuid>"`. This is reachable precisely because the fresh
   path writes the descriptor from `launchProfile.cwd` at `TileSpawner.swift:200`, and the
   override rebuilds the profile before the private overload — there is no
   persisted-descriptor preference on the fresh path to swallow it (that logic lives only in
   `restartTerminalTile`, which this test does not call).
3. **inheritFocus with no focused terminal:** set `focusedTerminalCwdProvider = { nil }`,
   spawn a second tile, assert `descriptor.cwd == projectRoot`.
4. **projectRoot policy:** set the key to `"projectRoot"`, set
   `focusedTerminalCwdProvider = { "/tmp/should-be-ignored" }`, spawn, assert
   `descriptor.cwd == projectRoot`.
5. Write a `manifest.json` carrying the measured cwds for each case (not `{passed:true}`).

This exercises the full fresh-spawn path from policy resolution through tmux-wrap (when
enabled) into descriptor persistence, with no mocking of the spawner's internals — the only
injected seam is the `focusedTerminalCwdProvider` closure, which is the same seam the app
wires in production.

### UX (visual gate + dogfood snippet)

Visual gate: open Settings (⌘,), navigate to the Terminal section, confirm a "New Shell
Directory" choice row is present with three options: "inheritFocus", "projectRoot",
"lastUsed". The current selection should read "inheritFocus". Change it to "projectRoot",
close and reopen Settings — it must still read "projectRoot".

Dogfood snippet: Open Continuum on any project. Spawn a terminal tile and `cd` into a
subdirectory — for example `mkdir -p /tmp/test-inherit && cd /tmp/test-inherit`. Wait for
the shell prompt to settle (OSC-7 has fired once a prompt has rendered; one prompt render is
enough). With that tile active (focus border lit), spawn a second terminal tile via File >
New Shell (or the command palette "New Terminal"). The second tile must open in
`/tmp/test-inherit`, not the project root — confirm by running `pwd`. Next, click a
non-terminal tile (browser or note) so the active tile is no longer a terminal, then spawn a
third tile — it must open at the project root.

## Execution mode

Supervised. The logic and backend checks are deterministic and fully exercisable without a
display (the backend self-check builds a real Ghostty context headlessly, as the existing
tmux-persistence check already does). But the UX gate — confirming the Settings row renders,
persists on reopen, and that a real Ghostty surface actually opens at the inherited directory
— requires launching the app and observing the terminal prompt. The OSC-7 path is real I/O
(the shell must emit it) and cannot be simulated without a running terminal surface.

## Done when

- [ ] `NewTileCwdConfig.swift` exists in `ContinuumRevivedCore`, compiles cleanly, and exports
      `NewTileCwdPolicy` (three cases), `NewTileCwdConfig` (`userDefaultsKey`, `defaultPolicy`,
      `policy(defaults:)`), and the pure `resolveNewTileCwd(policy:focused:lastUsed:projectRoot:)`
      function.
- [ ] `TileSpawner` has `focusedTerminalCwdProvider` and `lastSpawnedCwd` properties and a
      private `resolvedSpawnCwd(projectRoot:)` method that delegates to `resolveNewTileCwd`.
- [ ] `spawnTerminal(profileId:at:allowTmuxPersistence:)` rebuilds the `LaunchProfile` with the
      policy-resolved cwd (four-field copy, cwd overridden) before calling the private overload;
      the `registry.resolve(… in: projectRoot …)` call is unchanged.
- [ ] `restartTerminalTile` is untouched — persisted-descriptor cwd still wins on restore.
- [ ] `spawnHarnessRoleRun` is untouched — harness runs still launch at project root.
- [ ] `ContinuumApp.swift` wires `focusedTerminalCwdProvider` (in the `:2408-2437` closure
      block) to read `canvasState.lastActiveTileId` → `TerminalTileNSView` → `runtime.capturedCwd`.
- [ ] `SettingsSchema` Terminal section includes the `.choice` field bound to
      `NewTileCwdConfig.userDefaultsKey` with options `["inheritFocus", "projectRoot", "lastUsed"]`.
- [ ] Pure Core logic tests pass: all `resolveNewTileCwd` and `policy(defaults:)` cases covered.
- [ ] `runNewTileCwdSelfCheck` passes: descriptor `cwd` equals the injected focused path under
      `inheritFocus` with a focused provider; equals `projectRoot` under `inheritFocus` with a nil
      provider; equals `projectRoot` under the `projectRoot` policy even with a non-nil provider.
- [ ] Dogfood snippet confirmed: second shell opens in the `cd`-to directory of the active tile;
      third shell (after focusing a non-terminal) opens at project root.
- [ ] Settings row visible, three options present, selection persists across reopen.
- [ ] No existing tests regress (in particular `runTerminalTmuxPersistenceSelfCheck` still passes —
      its `descriptor.cwd == root` assertions at `:3264`/`:3276` hold because that check has no
      focused provider wired, so `inheritFocus` degrades to `projectRoot`).

## Depends on / unblocks

Self-contained on its primary code path. It depends on the spawner and the last-active-tile
tracking existing at their current seams (both live: `canvasState.lastActiveTileId` at
`CanvasState.swift:10`, read by `TileSpawner` at `:872`) and on `capturedCwd` being available
on `GhosttyTerminalRuntime` (`GhosttyTerminalRuntime.swift:171`). It does not depend on the
session-topology ticket; the resolved cwd string slots cleanly into both the current
`tmux new-session -A -c <cwd>` path and the future `tmux new-window -t <proj> -c <cwd>` path
with no change to this ticket's interface.

This ticket unblocks the session-topology ticket's cwd injection point: the topology ticket
can call `resolvedSpawnCwd` (or the `resolveNewTileCwd` free function) without reimplementing
the policy, and both tickets ship independently on the same `spawnTerminal` seam.

## Watch out for

**LaunchProfile is a struct with four fields and no `with(cwd:)` helper — do not fabricate an
`environment:` argument.** Verified at `Sources/ContinuumRevivedCore/LaunchProfile.swift:3-15`:
`init(command:arguments:cwd:title:)`. There is no `environment` field. Copy all four fields,
override only `cwd`.

**Override before the private overload, not inside it, and before tmux-wrapping.** The private
overload calls `tmuxWrappedProfileIfAvailable` at `TileSpawner.swift:176-178`, which bakes the
cwd into the tmux `-c <cwd>` argv. If you override the cwd *after* wrapping, the descriptor and
the tmux argv disagree. Rebuild the profile in the public method before the `return
spawnTerminal(profile:…)` call.

**Do not route restore through the policy.** `restartTerminalTile`'s
`persistedDescriptor?.cwd ?? profile.cwd` (`TileSpawner.swift:303-304`) is the correct restore
rule and must stay. Persisted cwd wins on restore; policy wins on fresh spawn. They never run
on the same call, so there is no conflict — but wiring the policy into restart would silently
break "reopen where I left off."

**Harness-role spawns.** `spawnHarnessRoleRun` (`TileSpawner.swift:136`) builds its own
`LaunchProfile` via `HarnessRoleRunBuilder` and must always launch at project root, not the
active tile's cwd. Do not route it through `resolvedSpawnCwd`.

**`focusedTerminalCwdProvider` nil in tests / when unwired.** When the provider is not set
(unit tests that construct `TileSpawner` directly) or returns nil (active tile is not a
terminal), `resolveNewTileCwd` under `inheritFocus` falls back to `projectRoot`. This is the
correct silent degradation and is exactly why the existing
`runTerminalTmuxPersistenceSelfCheck` keeps passing without changes.

**OSC-7 not yet fired.** `GhosttyTerminalRuntime.capturedCwd` falls back to the launch
profile's cwd when no OSC-7 has been emitted by the shell
(`GhosttyTerminalRuntime.swift:171-173`). If the active tile was just spawned and its shell
has not yet rendered a prompt, the "inherited" path is the tile's own launch cwd — usually
correct (it was opened at project root or from a prior spawn), but it can confuse the dogfood
check if you spawn two tiles in rapid succession before any prompt appears. Document this in a
code comment; do not add a workaround.

**Settings key collision.** `continuum.terminal.newTileCwd` does not exist today (grepped: no
hits in `Sources/`). The resolver's `?? defaultPolicy` fallback means a stray value can't
crash the app, but confirm the key stays unique before shipping.
