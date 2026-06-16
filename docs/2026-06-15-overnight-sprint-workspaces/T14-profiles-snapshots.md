# T14 — Profiles / snapshots: store + restore-over / instantiate-as-new + session toggle

Status: todo
Tag: overnight
Depends on: T12 (bulletproof restore — atomic/debounce + crash-safe reload) · Blocks: —

## Goal
A *named saved workspace layout* (a "profile") you can re-apply. Two apply modes:
**restore-over** — replace THIS workspace's document with the profile (a manual
backup/restore-point of the workspace you're in), and **instantiate-as-new** — create a
brand-new workspace from the profile as a template. One toggle controls what a profile
captures: **snapshot** = layout + resumable session-state (terminal cwd/scrollback,
browser `interactionState` — the T13 fields); **template** = layout only, session-state
stripped. This is a *thin layer over the same serialized `WorkspaceDocument`* — not a new
persistence system. It reuses T12's `AtomicWriter`/store plumbing and T13's session fields.

## Exact scope — files & symbols
- **NEW `Sources/ContinuumRevivedCore/WorkspaceProfileStore.swift`** — the whole thin
  layer:
  - `public struct WorkspaceProfile: Codable, Equatable, Sendable` — the on-disk profile
    envelope: `schemaVersion: Int` (== `WorkspaceProfile.currentSchemaVersion`, start at
    `1`), `id: UUID`, `name: String`, `createdAt: Date`, `captureMode: WorkspaceProfileCaptureMode`,
    `document: WorkspaceDocument` (the captured layout, possibly session-stripped).
  - `public enum WorkspaceProfileCaptureMode: String, Codable, Equatable, Sendable, CaseIterable { case snapshot; case template }`.
  - `public enum WorkspaceProfileApplyMode: String, Codable, Equatable, Sendable, CaseIterable { case restoreOver; case instantiateAsNew }`.
  - `public struct WorkspaceProfileStore: Sendable` — mirrors `WorkspaceStore`'s shape
    (a `layout` with `applicationSupportDirectory`, an `AtomicWriter` with `backupsDirectory`,
    `init(applicationSupportDirectory:retainedBackups:)`). Methods:
    - `func saveProfile(_ profile: WorkspaceProfile) throws` — atomic-write to
      `…/profiles/<profile.id>.json`.
    - `func loadProfile(id: UUID) throws -> WorkspaceProfile` (validateSchema on load).
    - `func listProfiles() throws -> [WorkspaceProfile]` (decode every `*.json` in
      `…/profiles/`, sorted by `createdAt` then `id`, skipping unreadable ones).
    - `func deleteProfile(id: UUID) throws`.
    - `public func captureProfile(name:from document:mode:id:now:) -> WorkspaceProfile`
      — the pure capture: for `.template`, returns a profile whose `document` has the T13
      session-state **stripped** (see Data/API); for `.snapshot`, keeps it verbatim.
  - `public enum WorkspaceProfileApplicationError: Error, Equatable` (e.g.
    `.unknownFutureSchema(path:version:supported:)` to match the store family).
- **NEW `Sources/ContinuumRevivedCore/WorkspaceProfileConfig.swift`** — the configurable
  defaults (mirrors `DragMagnetizeConfig`):
  - `public enum WorkspaceProfileConfig` with
    `static let defaultCaptureModeKey = "continuum.workspaceProfile.defaultCaptureMode"`,
    `static let defaultCaptureMode: WorkspaceProfileCaptureMode = .snapshot`,
    `static let defaultApplyModeKey = "continuum.workspaceProfile.defaultApplyMode"`,
    `static let defaultApplyMode: WorkspaceProfileApplyMode = .restoreOver`, plus resolver
    funcs `captureMode(defaults:) -> WorkspaceProfileCaptureMode` and
    `applyMode(defaults:) -> WorkspaceProfileApplyMode` (read raw string, fall back to the
    default when absent OR when the stored string is not a valid case).
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append two `.choice` fields to
  the existing `id: "general"` section (default-snapshot capture mode; default-restore-over
  apply mode), bound to the two `WorkspaceProfileConfig` keys. Do NOT add a new section.
- **`Sources/ContinuumRevivedCoreChecks/main.swift`** — extend the existing
  `// MARK: - Settings schema engine` `expectedKeys: Set<String>` literal (currently ~line
  3949, ending with `DragMagnetizeConfig.enabledKey,`) by appending
  `WorkspaceProfileConfig.defaultCaptureModeKey,` and `WorkspaceProfileConfig.defaultApplyModeKey,`
  — the engine's existing `Set(fieldKeys).count == fieldKeys.count` assertion (~line 3946)
  already guards against a key collision, and the `expectedKeys.isSubset(of:)` assertion
  (~line 3960) then proves both new keys are bound by a schema field. Also add a new
  `// MARK: - WorkspaceProfileStore` round-trip / capture-derivation table (RED first).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — add the
  `--workspace-profile-check` arg-dispatch block (model on the `--workspace-switch-check`
  block at ~:75) and a `static func runWorkspaceProfileSelfCheck() throws` on `AppDelegate`
  (model on `runWorkspaceSwitchSelfCheck` at ~:3946) that drives the REAL Core stores on
  disk (see check). This is the only App-target change.
- **`scripts/run-matrix.sh`** — register `run_app_check .build/debug/continuum-revived
  --workspace-profile-check` in the app-check list (alongside the other `--*-check` lines).

### Do NOT touch
- **T12's atomic/debounce layer** — `AtomicWriter`, `WorkspaceStore`,
  `WorkspaceDocumentSaveController`, the debounce/crash-safe reload. **Reuse** them; the
  profile store wraps a private `AtomicWriter` exactly like `WorkspaceStore` does, gaining
  atomic-write + backup-on-corruption for free. Do not modify `AtomicWriter`.
- **T13's session-resume *capture*** — terminal cwd/scrollback + browser `interactionState`
  capture into the `WorkspaceDocument` is T13's job. T14 only **copies or strips** whatever
  session fields T13 placed on `WorkspaceDocument`/`ZonePlacement`. Do not add new capture.
- **The sidebar UI** (T16) — no `NSOutlineView`, no profile-management UI here. ⌘K rows for
  profiles, if any, are out of scope (not in the charter task index for T14).
- `ZoneRuntimeController`, `WorkspaceRuntime`, `CanvasNSView`, `Registry`'s existing
  mutators except `createWorkspace` (which the check *calls*, does not modify), any AppKit
  beyond the one ContinuumApp dispatch+check func.

## Data / API changes (copy-pasteable)
```swift
// WorkspaceProfileStore.swift (NEW)
public enum WorkspaceProfileCaptureMode: String, Codable, Equatable, Sendable, CaseIterable {
    case snapshot   // layout + resumable session-state (T13 fields kept)
    case template   // layout only (T13 session fields stripped)
}

public enum WorkspaceProfileApplyMode: String, Codable, Equatable, Sendable, CaseIterable {
    case restoreOver       // overwrite THIS workspace's canvas.json with the profile
    case instantiateAsNew  // create a new workspace from the profile as a template
}

public struct WorkspaceProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var captureMode: WorkspaceProfileCaptureMode
    public var document: WorkspaceDocument
    public init(schemaVersion: Int = WorkspaceProfile.currentSchemaVersion,
                id: UUID = UUID(), name: String, createdAt: Date,
                captureMode: WorkspaceProfileCaptureMode, document: WorkspaceDocument)
    public func validateSchema(at url: URL) throws // throws WorkspaceProfileApplicationError.unknownFutureSchema
}

public struct WorkspaceProfileStore: Sendable {
    public init(applicationSupportDirectory: URL? = nil, retainedBackups: Int = 3)
    public var profilesDirectory: URL   // …/profiles/
    public func profileFile(id: UUID) -> URL  // …/profiles/<id>.json
    public func captureProfile(name: String, from document: WorkspaceDocument,
                               mode: WorkspaceProfileCaptureMode,
                               id: UUID = UUID(), now: Date) -> WorkspaceProfile
    public func saveProfile(_ profile: WorkspaceProfile) throws
    public func loadProfile(id: UUID) throws -> WorkspaceProfile
    public func listProfiles() throws -> [WorkspaceProfile]
    public func deleteProfile(id: UUID) throws
}

// WorkspaceProfileConfig.swift (NEW) — mirrors DragMagnetizeConfig's resolver shape.
public enum WorkspaceProfileConfig {
    public static let defaultCaptureModeKey = "continuum.workspaceProfile.defaultCaptureMode"
    public static let defaultCaptureMode: WorkspaceProfileCaptureMode = .snapshot
    public static let defaultApplyModeKey = "continuum.workspaceProfile.defaultApplyMode"
    public static let defaultApplyMode: WorkspaceProfileApplyMode = .restoreOver

    public static func captureMode(defaults: UserDefaults = .standard) -> WorkspaceProfileCaptureMode {
        guard let raw = defaults.string(forKey: defaultCaptureModeKey),
              let mode = WorkspaceProfileCaptureMode(rawValue: raw) else { return defaultCaptureMode }
        return mode
    }
    public static func applyMode(defaults: UserDefaults = .standard) -> WorkspaceProfileApplyMode {
        guard let raw = defaults.string(forKey: defaultApplyModeKey),
              let mode = WorkspaceProfileApplyMode(rawValue: raw) else { return defaultApplyMode }
        return mode
    }
}
```

The two `SettingsSchema` `.choice` fields appended to the `general` section (after the
`DragMagnetizeConfig.enabledKey` toggle), copy-pasteable — modeled on the existing
`DeleteConfirmPolicy` `.choice` (options are `rawValue`s, default is a `rawValue`):
```swift
.choice(
    key: WorkspaceProfileConfig.defaultCaptureModeKey,
    label: "Default Profile Capture",
    options: WorkspaceProfileCaptureMode.allCases.map(\.rawValue),   // ["snapshot","template"]
    default: WorkspaceProfileConfig.defaultCaptureMode.rawValue       // "snapshot"
),
.choice(
    key: WorkspaceProfileConfig.defaultApplyModeKey,
    label: "Default Profile Apply",
    options: WorkspaceProfileApplyMode.allCases.map(\.rawValue),     // ["restoreOver","instantiateAsNew"]
    default: WorkspaceProfileConfig.defaultApplyMode.rawValue         // "restoreOver"
),
```

**Stripping for `.template` (the load-bearing detail).** T13 will have added resumable
session-state to the serialized layout (charter §1.3: terminal cwd + scrollback snapshot,
browser `interactionState`). T14 must reference T13's EXACT field(s) — they are NOT in the
model today. `captureProfile(mode: .template, …)` returns a profile whose `document` has
those fields cleared (set to `nil`/empty) on **every** zone/tile so the template is purely
layout (origin/size/color/name/navKey/viewport/zOrder, no live session). `mode: .snapshot`
copies the document verbatim. **See the NEEDS-HUMAN flag in Out of scope** — the precise
field name/path to strip is owned by T13 and must be filled in when T13 lands.

**Apply semantics (driven through the real stores, no new types needed):**
- `restoreOver(workspaceId, from profile)`:
  `WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(profile.document)`
  — overwrites that workspace's `canvas.json` (AtomicWriter backs up the prior file). The
  Registry is untouched (same workspace id/name).
- `instantiateAsNew(name, from profile, registry, now)`:
  `registry.createWorkspace(name:now:)` → new workspace id; then
  `WorkspaceStore(workspaceId: newId, applicationSupportDirectory: appSupport).save(profile.document)`;
  persist the registry via `RegistryStore(applicationSupportDirectory: appSupport).save(registry)`.
  These call sites live in the check (T14 ships no orchestrator — the orchestrator wiring
  into ⌘K/menu is a later task; T14 proves the store + the two apply recipes work against
  disk).

> **Hermeticity (load-bearing).** `WorkspaceStore`'s init is
> `init(workspaceId:applicationSupportDirectory:retainedBackups:)` and `RegistryStore`'s is
> `init(applicationSupportDirectory:retainedBackups:)`; **`WorkspaceProfileStore` must take
> the same `applicationSupportDirectory:` first/only-optional param**. The check constructs
> **every** store (`WorkspaceProfileStore`, every `WorkspaceStore(workspaceId:…)`, the
> `RegistryStore`) with the *same* `applicationSupportDirectory: appSupport` temp dir it
> created. Omitting that arg makes the store fall back to `CONTINUUM_APP_SUPPORT`/the real
> app-support dir — a different location than the files the check writes — so the on-disk
> assertions would silently read the wrong tree. Pass `appSupport` everywhere.

## The check, written FIRST (spec-as-test) — `--workspace-profile-check`
**App check** (so it can drive the real on-disk store family and `Registry`), registered in
`scripts/run-matrix.sh` + the `ContinuumApp.swift` arg dispatch (~:75 block pattern);
implemented as `AppDelegate.runWorkspaceProfileSelfCheck()` (~:3946 pattern, which models the
exact temp-dir + on-disk `WorkspaceStore`/`RegistryStore` shape to copy). It uses a single
temp `applicationSupportDirectory` named `appSupport` (`URL(fileURLWithPath:
NSTemporaryDirectory()).appendingPathComponent("continuum-workspace-profile-check-\(UUID())")`,
`defer`-removed) and drives the **production** `WorkspaceProfileStore` / `WorkspaceStore` /
`RegistryStore` — never a hand-rolled writer — **all constructed with that same `appSupport`**
(see Hermeticity note above). Fixed UUIDs + fixed `now` values so every value is hand-derivable.

Setup (all values fixed):
- **Fixed timestamps** (distinct, so `listProfiles`' `createdAt` sort in assertion 9 is
  deterministic): `nowBase = Date(timeIntervalSince1970: 1_800_000_000)`; capture P1 with
  `now1 = nowBase`, P2 with `now2 = nowBase.addingTimeInterval(60)` — so `now1 < now2`.
- **Fixed UUIDs:** `W0` (the source workspace), `P1` (snapshot profile id), `P2` (template
  profile id), `P3` (future-schema profile id), plus the project/zone ids used in `srcDoc`.
- A source `WorkspaceDocument` `srcDoc` with viewport `CanvasViewport(x:10,y:20,zoom:1.5)`,
  `zoneZOrder` set, one project zone (`projectId` set, `name:"API"`, `navKey:"a"`, origin
  `ZonePoint(x:0,y:0)`, size `ZoneSize(width:800,height:600)`) **carrying a non-empty T13
  session field**, and one group zone (`projectId: nil`, `name:"Scratch"`, navKey `nil`) —
  also carrying session-state if group tiles hold it.
- Save `srcDoc` as workspace `W0`'s `canvas.json` via
  `WorkspaceStore(workspaceId: W0, applicationSupportDirectory: appSupport).save(srcDoc)`.
- Seed a `Registry` (`var registry = Registry.empty()`; `registry.createWorkspace(id: W0,
  name: "Source", now: now1)`) and persist it with
  `RegistryStore(applicationSupportDirectory: appSupport).save(registry)` — one workspace
  entry `W0`.
- Construct the profile store once:
  `let store = WorkspaceProfileStore(applicationSupportDirectory: appSupport)`.

Assertions (each enumerated; reviewer can compute the expected value):
> **Assertion ordering is load-bearing.** Run assertions 1–9 in number order, then 10
> (future-schema) **last**: assertion 10 writes a `schemaVersion:2` file into `…/profiles/`,
> and assertion 9 asserts `listProfiles()` returns **exactly** `[P1, P2]`. `listProfiles`
> decodes the envelope but does **not** call `validateSchema` per-entry (it only skips files
> that fail to *decode*), so a future-schema P3 would decode fine and pollute the list — keep
> P3 written only after assertion 9 has run. (Alternatively, if you make `listProfiles` skip
> future-schema entries too, document that and assertion 9 may run after 10; the default spec
> is decode-only-skip + ordered 9-before-10.)

1. **Capture snapshot — round-trips through disk.** `store.captureProfile(name: "Snap",
   from: srcDoc, mode: .snapshot, id: P1, now: now1)` → `store.saveProfile(...)` →
   `store.loadProfile(id: P1)` equals the captured profile (`==`); file exists at
   `appSupport/profiles/<P1>.json`; `loaded.captureMode == .snapshot`; `loaded.name == "Snap"`;
   `loaded.createdAt == now1`; `loaded.schemaVersion == 1`.
2. **Snapshot keeps session-state.** `loaded.document` `==` `srcDoc` exactly — i.e. the
   non-empty T13 session field on both zones survives. (Assert the field on the project
   zone is the same non-empty value, NOT nil.)
3. **Capture template — session stripped.** `store.captureProfile(name: "Tmpl", from:
   srcDoc, mode: .template, id: P2, now: now2)` → save → load → `loaded.captureMode ==
   .template`; for **every** zone in `loaded.document`, the T13 session field is
   nil/empty; **but** layout fields are intact: project zone `name=="API"`,
   `navKey=="a"`, origin `(0,0)`, size `(800,600)`; group zone `projectId == nil`,
   `name=="Scratch"`; `loaded.document.viewport == srcDoc.viewport`;
   `loaded.document.zoneZOrder == srcDoc.zoneZOrder`. (Proves template == layout-only.)
4. **Template is NOT equal to the snapshot doc.** `loadProfile(P2).document != srcDoc`
   (because session-state differs) yet `loadProfile(P1).document == srcDoc`. (Proves the
   strip actually happened and isn't a no-op.)
5. **Apply restore-over — overwrites THIS workspace's document.** First mutate W0 on disk
   (save a *different* doc `dirtyDoc` with viewport `CanvasViewport(x:999,y:999,zoom:3)`
   via `WorkspaceStore(workspaceId: W0, applicationSupportDirectory: appSupport).save(dirtyDoc)`).
   Then run the restore-over recipe:
   `WorkspaceStore(workspaceId: W0, applicationSupportDirectory: appSupport).save(store.loadProfile(id: P1).document)`.
   Assert `WorkspaceStore(workspaceId: W0, applicationSupportDirectory: appSupport).load() == srcDoc`
   (the profile's captured doc), NOT `dirtyDoc`. Assert the reloaded
   `RegistryStore(applicationSupportDirectory: appSupport).load().workspaces` still has
   exactly the one workspace `W0` (count == 1, id unchanged) — restore-over does not create
   a workspace.
6. **Restore-over leaves a backup (restore-point semantics).** After assertion 5,
   `appSupport/workspaces/<W0>/backups/` contains at least one `canvas.*.json` backup (the
   AtomicWriter backed up the prior file before each overwrite — by now both `srcDoc` and
   `dirtyDoc` have been backed up), i.e. restore-over is itself reversible. (Assert the
   backups dir contains ≥1 file matching `canvas.*.json`.)
7. **Apply instantiate-as-new — creates a NEW workspace from the template.** Run the
   instantiate recipe with the **template** profile P2:
   `registry.createWorkspace(name: "From Template", now: now2)` → `newId`;
   `WorkspaceStore(workspaceId: newId, applicationSupportDirectory: appSupport).save(store.loadProfile(id: P2).document)`;
   `RegistryStore(applicationSupportDirectory: appSupport).save(registry)`. Assert: a NEW
   `appSupport/workspaces/<newId>/canvas.json` exists and
   `WorkspaceStore(workspaceId: newId, applicationSupportDirectory: appSupport).load() ==
   store.loadProfile(id: P2).document` (layout-only); the reloaded
   `RegistryStore(applicationSupportDirectory: appSupport).load().workspaces` count == 2 and
   contains an entry named "From Template" with id `newId`; W0's canvas.json is **unchanged**
   by the instantiate (`WorkspaceStore(workspaceId: W0, …).load() == srcDoc`, still the
   restored doc from assertion 5).
8. **Instantiate from a snapshot carries session-state into the new workspace.** Repeat the
   instantiate recipe with P1 (snapshot):
   `registry.createWorkspace(name: "From Snapshot", now: now2)` → `newId2`;
   `WorkspaceStore(workspaceId: newId2, applicationSupportDirectory: appSupport).save(store.loadProfile(id: P1).document)`.
   Assert `WorkspaceStore(workspaceId: newId2, applicationSupportDirectory: appSupport).load() ==
   srcDoc` (session field non-nil). (Proves the apply mode is orthogonal to the capture
   mode: instantiate works for both; the difference is purely what was captured.)
9. **listProfiles enumerates both, sorted, skips garbage.** Write a junk `notjson.json`
   into `appSupport/profiles/`; `store.listProfiles()` returns exactly `[P1, P2]` (by id),
   ordered by `createdAt` (P1 before P2 since `now1 < now2`), tie-broken by `id`, and does
   NOT throw on the junk file. (Run this **before** assertion 10 writes P3 — see the
   ordering note above.)
10. **Future-schema profile is refused.** Encode a `WorkspaceProfile` with
    `schemaVersion: 2` to `appSupport/profiles/<P3>.json`; `store.loadProfile(id: P3)` throws
    `WorkspaceProfileApplicationError.unknownFutureSchema(path:version:supported:)` with
    `version == 2`, `supported == 1`. (Forward-compat guard, matching the store family.)
11. **Configurable defaults resolve.** With an empty `UserDefaults` suite,
    `WorkspaceProfileConfig.captureMode(defaults:) == .snapshot` and `.applyMode(defaults:)
    == .restoreOver`; set the keys to the other valid cases → resolvers return them; set a
    bogus string → resolvers fall back to the defaults. (Drives the same path Settings
    reads.)

Plus a **Core round-trip table** in `ContinuumRevivedCoreChecks/main.swift`
(`// MARK: - WorkspaceProfileStore`): `WorkspaceProfile` Codable round-trip; `captureProfile`
template-strip derivation on a hand-built doc (assert the exact stripped vs kept fields);
the `WorkspaceProfileConfig` resolver default/override/bogus table; and the SettingsSchema
`expectedKeys` extension proving both keys are represented and unique.

Run it → **RED** (no `WorkspaceProfileStore` type yet → the app check fails to compile, and
the Core table fails on the missing symbol; the *behavioral* RED is assertions 3/4 — the
template strip — and 5/7, which fail until the apply recipes work). Implement to GREEN.

## Implementation steps
1. **RED:** add the `// MARK: - WorkspaceProfileStore` Core table + the two new
   `expectedKeys` + write `runWorkspaceProfileSelfCheck` and register `--workspace-profile-check`
   in both ContinuumApp dispatch and run-matrix.sh. `swift build` → expect compile failure
   on the missing `WorkspaceProfile*` symbols (acceptable RED for the type-introducing step);
   then once stubs compile, the strip/apply assertions must FAIL on the assertion.
2. Create `WorkspaceProfileConfig.swift` (keys + defaults + resolvers) and append its two
   `.choice` fields to the `general` section of `SettingsSchema`.
3. Create `WorkspaceProfileStore.swift`: the `WorkspaceProfile` envelope + `validateSchema`,
   the `captureMode`/`applyMode` enums, the store wrapping a private `AtomicWriter`
   (`backupsDirectory = profilesDirectory/backups`), and `saveProfile`/`loadProfile`/
   `listProfiles`/`deleteProfile`/`captureProfile`. Implement the **template strip** against
   T13's session field(s) — if T13 has not landed, see the NEEDS-HUMAN flag.
4. `swift build`; run the Core table → GREEN; run `--workspace-profile-check` → GREEN.
5. `./scripts/run-matrix.sh --fast` (the new app check + Core + settings-schema all green).

RED→GREEN boundary: the missing-symbol compile error is the type-introduction RED; the
behavioral RED that proves the *feature* is assertions 3/4 (template strip) and 5–8 (apply
recipes), which must fail on the assertion before step 3 is filled in.

## Acceptance criteria
- [ ] `WorkspaceProfileStore` saves/loads/lists/deletes profiles atomically via a reused
      `AtomicWriter` (backup-on-corruption), under `…/profiles/`.
- [ ] `captureProfile(.snapshot)` keeps T13 session-state; `(.template)` strips it on every
      zone while preserving all layout fields — both asserted by `==`/`!=` against `srcDoc`.
- [ ] restore-over overwrites THIS workspace's `canvas.json` (and leaves a backup), creating
      no new workspace; instantiate-as-new creates a new workspace + canvas.json + registry
      entry, leaving the source workspace untouched.
- [ ] Apply mode is orthogonal to capture mode (assertions 7 vs 8).
- [ ] Future-schema profile refused; `listProfiles` skips garbage and sorts deterministically.
- [ ] `WorkspaceProfileConfig` default-snapshot + default-restore-over keys persisted, both
      in `SettingsSchema` (general section), both in the conflict-guard `expectedKeys`,
      resolvers fall back on bogus input.
- [ ] Did NOT touch `AtomicWriter`/`WorkspaceStore`/save-controller, T13 capture, or the
      sidebar. Fast matrix green.
- [ ] Commit `feat(workspaces): profiles — snapshot/template capture + restore-over/instantiate`.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --workspace-profile-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh --fast
```

## Review rubric
- **Bypass audit (critical):** assertions 1/5/7/9/10 must go through the production
  `WorkspaceProfileStore`/`WorkspaceStore`/`RegistryStore` and read **the files back from
  disk** (`load()`/`listProfiles()`/`fileExists`), not assert on the in-memory value the
  check just built. A check that asserts `captureProfile(...)` equals a hand-built struct
  *without a disk round-trip* proves only the pure fn — the store path must be exercised.
- **The strip must be proven non-trivial:** assertion 4 (`template.document != srcDoc` AND
  `snapshot.document == srcDoc`) is the guard against a strip that's a silent no-op. If the
  check only asserts `template != nil` it would still pass with NO stripping — REWORK.
- **restore-over vs instantiate are genuinely different:** assertion 5 asserts the Registry
  workspace count is **unchanged**; assertion 7 asserts it **incremented** and the source
  W0 doc is untouched. A check that conflates them (both create a workspace, or both
  overwrite W0) is wrong.
- **Backup/restore-point claim (assertion 6)** is proven by an actual file in the backups
  dir, not by absence of error.
- **Configurable bits:** both `WorkspaceProfileConfig` keys appear in `SettingsSchema`'s
  general section AND in the `expectedKeys` conflict-guard set; the unique-keys assertion
  still holds (no key collision with an existing pref); resolvers fall back on a bogus
  stored string (not just on absence).
- **Reuse, not reinvention:** the store wraps `AtomicWriter`; it does NOT hand-roll JSON
  writes or its own backup logic. `AtomicWriter` itself is unchanged.
- **Hand-derive one value:** recompute `loaded.document.viewport` for the template
  (`(10,20,1.5)` — unchanged by strip) and confirm assertion 3 matches.

## Out of scope / gotchas
- **⚠ NEEDS-HUMAN — T13 session-state field is not yet defined.** `WorkspaceDocument`
  today (read 2026-06-15) is `{ schemaVersion, viewport, zones:[ZonePlacement], zoneZOrder,
  lastActiveZoneId }` and `ZonePlacement` is `{ zoneId, projectId, origin, size, color,
  collapsed, hydrationPolicy }` — **there is no session-state field**. T13 ("terminal
  cwd+scrollback, browser interactionState") is *not written* (no `T13-*.md` exists yet)
  and T01 will additionally add `name`/`navKey` and make `projectId` optional. The
  template-strip in `captureProfile(.template)` and assertions 2/3/4/8 depend on the EXACT
  T13 field name, location (on `WorkspaceDocument`? on `ZonePlacement`? on a per-tile
  sub-document?), and emptiness sentinel (nil vs empty string vs empty array). **Do not
  invent it.** When T13 lands, fill in: (a) the field path the strip clears, (b) the
  "non-empty session" fixture in the check setup, (c) the empty-sentinel the template
  assertions compare against. If T14 is started before T13, implement the store + apply
  modes + config (assertions 1, 5–7, 9–11 are fully specifiable now) and leave the
  session-keep/strip assertions (2, 3, 4, 8) as the explicit GREEN gate that unblocks once
  T13's field exists.
- T01 changes `ZonePlacement` (`projectId: UUID?`, `+name`, `+navKey`); the check's fixture
  zones must use the post-T01 signature (group zone uses `projectId: nil`). T12 (this task's
  dependency) lands after T01/T02, so by the time T14 runs the model already has those.
- The *orchestrator/UI* that calls these recipes (a menu item, ⌘K row, or the T16 sidebar's
  "Save as profile…" / "Apply profile…") is **not** in T14 — T14 ships the store + the two
  proven apply recipes (exercised in the check) + the config. Wiring a user entry point is a
  follow-up; do not widen scope into AppKit beyond the one ContinuumApp check func.
- `…/profiles/` lives directly under `applicationSupportDirectory` (a sibling of
  `workspaces/` and `registry.json`), so it is shared across workspaces — a profile is a
  global named layout, not per-workspace. Keep its `AtomicWriter` backups under
  `profilesDirectory/backups` to avoid colliding with `WorkspaceStore`'s per-workspace
  `backups/` (the AtomicWriter backup-name prefix is the file stem, so a shared backups dir
  would mix `canvas.*` and `<id>.*` — keep them separate).
- Stale SourceKit "cannot find WorkspaceProfileStore" diagnostics are noise pre-build;
  `swift build` is authoritative.
