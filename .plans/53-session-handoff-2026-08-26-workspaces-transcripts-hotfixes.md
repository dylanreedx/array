# 2026-08-26 Release and Hotfix Session Handoff

**Date:** 2026-08-26
**Current shipped release:** Array 0.5.20 (build 45)
**Release commit:** `0f1de01a09e15028c3a471906234696309c02de3`
**Status:** Workspace/transcript/agent-clock hotfix program shipped and live-data repair completed. Separate file/file-tree/IDE work remains uncommitted and is intentionally not part of 0.5.20.

## Executive summary

This session began with several symptoms that looked independent:

- zone renames reverted to the project name;
- switching workspaces showed the same canvas or returned to an empty canvas;
- creating a workspace could fail on a project ownership conflict;
- strict duplicate-membership validation could prevent Array from opening;
- closing/reopening an agent tile or switching away during a response could truncate its transcript;
- elapsed agent time reset around provider or subagent lifecycle boundaries;
- the compact provider selector became difficult to reach;
- the Markdown note/file surface and related file/IDE improvements needed to be integrated without mixing unfinished editing work into the hotfix.

The work shipped as a sequence of deliberately small releases from 0.5.13 through
0.5.20. The final model is:

1. A project has one authoritative workspace owner.
2. A workspace owns its own zones, viewport, focus, and mounted scene.
3. A project owns its project canvas/tile state.
4. `WorkspaceRuntime` is the persistence boundary for a mounted workspace.
5. A complete semantic transcript snapshot restores a tile; the bounded replay tail
   is only for live/lightweight consumption.
6. Agent elapsed time is anchored to the original active-turn timestamp and is not a
   view-local or provider-event-local clock.

The last apparent “save failure” was not a failed write. The workspace documents did
contain the zones, but stale registry ownership marked those zones foreign, so the
strict mount filter hid them after an A → B → A round trip. The live registry was
repaired without deleting or moving zones, tiles, project files, or transcripts, and
0.5.20 closes the production path that could create that contradiction again.

## Product decisions and invariants

### Workspace and project ownership

- A project belongs to exactly one workspace.
- Ordinary workspace switching never transfers project ownership.
- An explicit project move transfers the project and its zones as one operation.
- Legacy duplicate membership remains an integrity problem, but it must not make the
  app impossible to open when the project's authoritative `workspaceId` is known.
- No automatic repair may delete, merge, or silently move legacy zones.
- Selecting an already-owned project while adding a project/zone should offer to switch
  to its owning workspace using human-readable names. Cancelling or accepting that
  offer must not duplicate or transfer the project.
- Selecting an unowned project may assign it to the current workspace, but assignment
  must become durable before the zone is committed.
- A tile's project-persisted `zoneId` is meaningful only within its owning workspace.

### Workspace scene persistence

- Workspace documents own zone placement/name/geometry/color/collapse state, viewport,
  active zone, and focused tile.
- Project canvas files continue to own project tile state.
- Before switching, Array captures the complete visible departing state and saves it.
- The target is loaded and validated before the current scene is torn down.
- A save or target-load failure leaves the departing workspace mounted and interactive.
- Zone mutation has one writer: `WorkspaceRuntime`. Canvas gestures/callbacks update the
  runtime's in-memory `WorkspaceDocument`, then atomically persist that exact document.
- A non-empty `ZonePlacement.name` always wins over a registry project name. The project
  name is only a fallback for an unnamed zone.
- Rename propagation must update `liveZones`, the matching `ZoneLayer.placement`, its
  render model, `zoneRenderModels`, `zoneDisplayByZoneId`, existing chrome, the runtime
  document, and `WorkspaceStore` in one commit.
- Repeated A → B → A switching must reconstruct both workspaces exactly.

### Transcript restoration

- Reopening an agent tile or returning to its workspace installs a complete semantic
  transcript snapshot before attaching to a tail-only live stream.
- The 500-event replay buffer remains useful for lightweight consumers, but it is never
  a transcript reconstruction source.
- Snapshot-and-tail attachment is atomic at the supervisor boundary.
- Open streaming and Markdown parser state survive detach/reattach so a response loses
  and duplicates zero text, including when it exceeds `replayCap`.
- Closing a tile remains view-only; it does not stop or delete the underlying agent.

### Agent elapsed time

- The elapsed clock represents how long the active agent turn has actually been running.
- The supervisor's oldest active-turn timestamp is authoritative.
- Repeated provider `started` events, subagent boundaries, replay, tile reattachment, and
  workspace switching do not replace the original timestamp.
- Claude Code, Codex, and Pi expose the same product semantics even where their provider
  event vocabularies differ.

## Chronological implementation and release ledger

### Foundation before 0.5.13

`3ea476f5` merged provider lifecycle fixes across `AgentSupervisor`, Pi RPC/event
translation, prompt-image handling, awareness checks, and transcript compatibility.
This was part of the integration base used for the release train.

### 0.5.13 (build 38) — complete persistence and restoration baseline

Primary commits:

- `6f9eecca` — workspace persistence and transcript recovery
- `70802a71` — exclusive-ownership migration checks
- `dda407b5` — compact provider selector reachability
- `35623802` — workspace deletion ownership cleanup coverage
- `083d7ba6` / merge `fd06f7b5` — shared Markdown document surface from
  `array/note-file-markdown`
- release `6cdf7b2a`

Shipped behavior:

- `WorkspaceRuntime` became the workspace scene persistence boundary.
- Switching captures departing workspace state before installing the target.
- Custom zone names survive layout, refresh, switching, and relaunch.
- Registry validation and explicit project movement adopt exclusive ownership.
- The supervisor restores a complete semantic transcript snapshot before following the
  live tail.
- Streaming and Markdown state are carried across tile/workspace detach and reattach.
- The provider selector remains reachable in compact agent tiles.
- Notes and Markdown files share the native Preview / Split / Edit document surface.

The Markdown merge was intentionally limited to the shared document surface. It did not
include the later, uncommitted source-code and file-tree IDE work described below.

### 0.5.14 (build 39) — legacy duplicate membership launch recovery

Primary commit: `9f45eebe`; release `93fb014c`.

Strict global duplicate validation initially made Array refuse to open with legacy data.
The fix treats a project's durable `workspaceId` as authoritative for mounting while
preserving every conflicting membership/document for explicit repair. The integrity
audit still reports the duplicate; launch and safe switching no longer fail globally.

### 0.5.15 (build 40) — useful ownership-conflict handling

Primary commit: `f2bc01d4`; release `523c6331`.

- Workspace creation no longer gets trapped by a stale foreign zone in the workspace
  being left.
- Creation durability and navigation are reported separately, so a later switch failure
  cannot claim that workspace creation itself failed.
- Adding a project already owned elsewhere offers to switch to that workspace instead of
  exposing a raw UUID error.
- Targeted safe ownership assignment is not blocked by an unrelated legacy duplicate.

### 0.5.16 (build 41) — isolated canvases and monotonic agent time

Primary commits:

- `985d7552` — keep agent elapsed time monotonic
- `7632ebbe` — keep workspace canvases isolated
- release `fe791bf1` plus appcast repair commits `430c23b2` and `dbbdf881`

The agent clock now retains the supervisor's original active-turn timestamp across
Claude Code, Codex, Pi, subagent/provider lifecycle events, replay, and UI reattachment.

Workspace creation and switching gained production-path witnesses proving an empty new
workspace mounts zero departed zones and tiles. Legacy foreign zones remain preserved
on disk but are omitted from the wrong mounted scene.

The Sparkle feed was regenerated from the complete release archive after an incomplete
history was noticed; the public feed retains the full release chain.

### 0.5.17 (build 42) — persist selected workspace

Primary commit: `dfd0600a`; release `ee1ec80e`.

`lastActiveWorkspaceId` is written only after target preparation succeeds and before the
mounted scene changes. This fixed selection persistence, but startup could still allow
the compatibility project to override it.

### 0.5.18 (build 43) — honor selection at startup

Primary commit: `8a5418f5`; release `a8a9eb37`.

Startup began honoring the selected workspace instead of blindly following the globally
last-used project. A remaining compatibility-controller path could still inject a
foreign project into an empty selected workspace.

### 0.5.19 (build 44) — keep an empty workspace empty

Primary commit: `adb9a54e`; release `8fe897df`.

Startup no longer attaches a foreign compatibility controller, flat project tiles, or
an auto-created zone to an empty workspace. Project-root resolution prefers a project
authoritatively owned by the selected workspace.

### 0.5.20 (build 45) — prevent saved foreign zones from becoming invisible

Primary commit: `24517e16`; release `0f1de01a`.

The final production bug was in the project/Home picker confirmation path. It called
`CanvasNSView.commitProvisionalZone` for any selected project without first validating
or assigning ownership. A foreign project zone therefore entered the mounted workspace
document successfully, then disappeared on the next mount because `mountableZones`
correctly filtered it as foreign. This looked exactly like workspace save had failed.

The fix adds the invariant at both boundaries:

1. The AppDelegate picker path checks the live registry before committing.
   - Foreign owner: cancel the provisional zone before any persistence, dismiss the
     picker, and use the existing friendly switch-to-owner helper.
   - Unowned project: assign it to the mounted workspace and save the registry before
     committing the zone.
   - Error: cancel the provisional zone, show a management message, and persist nothing.
2. `WorkspaceRuntime.commitCreatedZone` independently rejects a foreign-owned project
   before changing its document/disk and assigns an unowned project before append/save.

The regression asserts that a foreign zone creation is rejected and that both the
runtime document and workspace document on disk remain byte-for-byte logically
unchanged.

## Live production data incident and repair

### Symptom

The installed app could switch to a workspace, show its zones as Saved, switch away,
and return to a canvas where those zones appeared gone.

### State found

Workspace documents still contained the zones, but registry ownership contradicted
them:

- `work` (`7A40C21D-18E6-4479-BC0E-5C74478471F9`) contained three Harmony zones,
  while Harmony declared/appeared in Default.
- `personal` (`42B93EF0-18DA-490F-901E-6488DC1B2B88`) contained one `personal`
  project zone, while its project list was empty and the personal project declared
  `work`.
- Registry membership also contained stale duplicates.

The strict mount filter was behaving as designed; the writer path had allowed an
invalid workspace/project relationship to become durable.

### Safety and backup

Array was quit before touching production state. The registry was backed up to:

`/Users/dylan/Library/Application Support/Array/backups/registry.before-workspace-owner-repair.2026-08-26T21-55-00Z.json`

Only this file was repaired:

`/Users/dylan/Library/Application Support/Array/registry.json`

No workspace document, project canvas, tile, zone, project file, managed-agent record,
or transcript was deleted, merged, or moved.

### Ownership repair applied

- `personal` project `AAEE0E7E-AA45-453E-841F-5981F597E6A5` → `personal`
  workspace.
- Harmony `375C6B1C-A16B-4C59-B561-C034E408FFEA` → `work` workspace.
- Selectus remains in Default.
- Documents remains in `work`.
- Workspace project lists are now exclusive:
  - Default: Selectus
  - work: Harmony and Documents
  - personal: personal

After relaunch, startup materialized a Documents zone alongside the three saved Harmony
zones, so the verified visible counts are:

- `work`: 2 projects, 4 zones, Saved
- `personal`: 1 project, 1 zone, Saved

A real installed-app `work → personal → work` round trip reproduced both canvases with
those exact counts.

If this incident must be audited or reversed, inspect the timestamped backup first. Do
not restore it blindly while Array is running, because it intentionally contains the
contradictory ownership that caused the incident.

## Verification performed

Focused and release verification for the final hotfix included:

```sh
swift build --product Array
.build/debug/Array --workspace-switch-check
.build/debug/Array --empty-workspace-creation-check
swift run ContinuumRevivedCoreChecks
git diff --check
scripts/check-app-bundle.sh --channel prod \
  --bundle qa-runs/20260826T215822Z/release/Array.app
```

The optimized build, Developer ID signing, notarization, stapling, and Gatekeeper audit
all passed. `ContinuumRevivedCoreChecks` includes expected negative/crash witnesses; the
suite's final result was green.

The installed 0.5.20 app was then exercised through the real UI:

1. Launch on `work`: 2 projects / 4 zones / Saved.
2. Switch to `personal`: 1 project / 1 zone / Saved.
3. Switch back to `work`: 2 projects / 4 zones / Saved.

## Release artifacts and publication

- Public release: <https://github.com/dylanreedx/array-releases/releases/tag/v0.5.20>
- Public appcast: <https://arrayapp.dev/appcast.xml>
- Release worktree DMG:
  `/tmp/array-release-0.5.13-candidate/qa-runs/20260826T215822Z/release/Array-0.5.20.dmg`
- Archived DMG:
  `/Users/dylan/Documents/personal/Array/releases/Array-0.5.20.dmg`
- SHA-256:
  `b542d8e296925fd618ce957715f4a00e55ee2bd31ec3704b6c8621de6fd27206`
- GitHub assets `Array.dmg` and `Array-0.5.20.dmg` have the same hash.
- Public branches `main` and `array/integration` both point to
  `0f1de01a09e15028c3a471906234696309c02de3`.
- `/Applications/Array.app` is 0.5.20 build 45 and was left open on `work`.
- The previous installed build is recoverable at
  `/Users/dylan/.Trash/Array-0.5.19-build44-workspace-backup.app`.

## Current repository/worktree state

### Clean release worktree

- Path: `/tmp/array-release-0.5.13-candidate`
- Branch name: `array/release-0.5.13`
- State at handoff: clean at the 0.5.20 release commit.

The historical branch name predates the hotfix train; do not infer its shipped version
from the branch label.

### Primary user checkout

- Path: `/Users/dylan/Documents/personal/Array`
- Checked-out branch: local `array/integration`
- The local checkout is behind the remote release line and intentionally dirty with
  user-owned, unrelated file/file-tree work.
- It was not reset, cleaned, rebased, fast-forwarded, staged, or committed during the
  release work.

Do not blindly update this checkout until the uncommitted work is coordinated. Remote
`main` and `array/integration` already contain the release.

## Separate in-progress work — not in 0.5.20

The primary checkout contains a second development stream focused on a more authentic
IDE feel for agent-driven work. Its emphasis is observing and understanding code changes
made by agents, not turning Array into a full human-first code editor.

Current modified/untracked scope includes:

- `Package.swift`
- `Sources/ContinuumRevived/App/FileOpenChecks.swift`
- `Sources/ContinuumRevived/Canvas/FileTileNSView.swift`
- `Sources/ContinuumRevived/Canvas/FileTreeOutlineModel.swift`
- `Sources/ContinuumRevived/Canvas/FileTreeTileNSView.swift`
- `Sources/ContinuumRevivedCore/FilePreview.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- `Sources/ContinuumRevivedFileTreeChecks/main.swift`
- `Sources/ContinuumRevived/Canvas/CodeLineNumberRulerView.swift`
- `Sources/ContinuumRevived/Canvas/CodeSyntaxHighlighter.swift`
- `.plans/52-note-file-markdown-document-surface.md`

Observed direction in that work:

- source-language classification;
- native syntax highlighting and line-number rulers;
- clean live refresh when an agent/external process edits a file;
- improved file-tree fuzzy search;
- path context and collapse controls;
- stronger file/file-tree production checks.

This work must be reviewed, completed, and released separately. It should preserve the
already-shipped shared Markdown document surface and the workspace/project ownership
invariants above.

## Sound/status observations

The configurable visual and sound indicators shipped in 0.5.12. During this session the
recent sound changes appeared to be working, but the long-lived Claude Code session had
not yet produced enough observed terminal transitions to claim exhaustive real-provider
coverage. The elapsed-time reset was separately reproduced and fixed in 0.5.16.

Future provider dogfood should explicitly distinguish:

- no notification because the agent has not reached a qualifying completion/attention
  transition;
- a correctly deduplicated notification;
- a missing provider lifecycle mapping;
- system notification/audio settings suppressing an otherwise emitted signal.

## Regression matrix to preserve

Future workspace or transcript work should retain production-entry-point coverage for:

1. Inline-rename a project zone; verify after layout, sidebar refresh, workspace round
   trip, and relaunch.
2. Verify custom zone names beat registry project names in boot, install, hydration, and
   switch paths.
3. Mutate every persisted zone property plus viewport/focus in A; immediately switch to
   B and back; compare document and visible scene exactly.
4. Inject departing-save and target-load failure; verify A remains mounted and usable.
5. Feed duplicate legacy membership; preserve all data, report integrity, and mount only
   the authoritative owner.
6. Select a foreign project through the real Home/project picker; verify the provisional
   zone is removed and neither runtime nor disk document changes.
7. Select an unowned project; verify ownership is durable before its zone is committed.
8. Stream more than `replayCap`, close/reopen or switch away/back mid-response, and
   compare the complete transcript, live continuation, tool details, Markdown state,
   and observer counts.
9. Emit repeated provider/subagent start boundaries across Claude Code, Codex, and Pi;
   verify the elapsed clock remains anchored to the oldest active-turn timestamp.
10. Drive `mountWorkspaceSceneAtBoot` and real hydration paths. A checks-only installer
    is not evidence of production behavior.

## Lessons from the hotfix train

- “The canvas is empty” does not prove the document failed to save. Inspect the saved
  workspace document and the ownership filter together.
- Read and write invariants must exist at the UI path and at the runtime persistence
  boundary. A UI-only check is insufficient protection against another caller.
- A strict integrity rule needs a non-destructive migration/repair experience. Blocking
  startup with raw UUIDs is not an acceptable user path.
- Compatibility boot logic must never override an explicit workspace selection.
- Tests must drive the production mount and picker/hydration paths; direct model
  installers repeatedly hid real wiring failures.
- Release notes should say when one hotfix is superseded by the next. The 0.5.17–0.5.19
  sequence each closed a real layer while exposing the next compatibility path.
- Preserve user-owned work during emergency releases. The clean release worktree kept
  the file/IDE stream intact while allowing a signed, notarized hotfix train.
