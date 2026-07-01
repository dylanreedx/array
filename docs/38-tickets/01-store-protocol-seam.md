# Put the project and workspace stores behind a protocol

Rests on **D3** (op-log sync re-models state behind a store seam) and **D26** (the store-protocol seam is retrofit-hostile, so it is stood up in phase 0). See `docs/38-locked-decisions.md`.

## What this delivers

After this ticket lands, every call site that currently constructs a concrete `ProjectStore` or `WorkspaceStore` holds a value typed to a protocol instead. The local-JSON implementation is unchanged and remains the default. No feature changes, no new behavior. What the system gains is a clean swap point: when the sync work arrives — the CloudKit transport (D4), the op-log (D3), or the Loro fallback — it can drop a synced implementation behind the same protocol without touching a single call site. Without this seam that swap is a surgery across the entire app; with it, it is a one-line injection.

The second thing this delivers is a forcing function for honesty about what the stores actually do. Extracting a protocol requires reading every public method on both concrete types and deciding what belongs on the contract and what is implementation detail. That process has surfaced store misuse before.

## How it fits

This is the first ticket in the foundations phase, and it deliberately has no dependencies — nothing it needs to wait for, nothing that blocks it from starting today. It does, however, unblock a significant portion of what follows. The op-log core cannot be injected at the store level without a seam to inject into. The CloudKit transport cannot be swapped in without a protocol behind which it hides. The sync/observation type split (I5) needs a store abstraction to enforce the boundary at the type level. And the injectable substrates — the fake sync transport, the fake clock — all assume the store is an abstract type that tests can replace. In short, this ticket is cheap to do now, retrofit-hostile to do later (the surface area only grows), and blocks roughly a third of the phase-0 work until it ships.

## The approach

Declare two protocols — `ProjectStoring` and `WorkspaceStoring` — in `ContinuumRevivedCore`, mirroring the *persistent-read/write* surface of the existing concrete structs. Rename nothing on the concrete types. Migrate every call site that holds a concrete `ProjectStore` or `WorkspaceStore` **as a stored property, a computed forwarding property, or a function parameter** to the protocol type. Keep the concrete structs as the sole default implementations; no new implementations are introduced here. The concrete types continue to be constructed at the edges (app startup, `ZoneRuntimeController` init, test harnesses) and then passed inward as the protocol.

The protocols carry the persistent-read/write surface: the save/load/try-load methods for each data kind that `ProjectStore` manages today, plus save/load/try-load/delete for `WorkspaceDocument` on `WorkspaceStoring`. They also carry **four new named methods** that encapsulate what a handful of call sites currently reach into `layout` to do (see "The `layout` decision" below). They do **not** carry `layout` itself.

`SessionPruner.pruneExitedSessions(in:)` currently takes a concrete `ProjectStore` — migrate its parameter to `any ProjectStoring`. Same for `TileSpawner`'s stored `projectStore` property and `ZoneRuntimeController`'s stored `projectStore` property. `WorkspaceDocumentSaveController`'s stored `store: WorkspaceStore` becomes `store: any WorkspaceStoring`. `ContinuumApp`'s computed forwarding property `projectStore` (which reads through `activeController.projectStore`) becomes `(any ProjectStoring)?` automatically once `ZoneRuntimeController.projectStore` migrates. Every other local that constructs a store and passes it somewhere follows the same pattern: construct the concrete type, then treat it as the protocol at the receiving parameter/property.

No new file is strictly required for the protocols, but a single `StoreProtocols.swift` in `ContinuumRevivedCore` is the clean home.

## The `layout` decision (pre-decided — no per-site judgement)

`ProjectStore` exposes a public `layout: ProjectStoreLayout` property (`ProjectStore.swift:77`). `ProjectStoreLayout` is a bag of URLs and path-helper functions (`browserFile`, `fileTreeIndexFile`, `noteFile(id:)`, `reviewFile(id:)`, `sessionFile(id:)`, etc.). These URLs are an implementation detail of the *local-JSON* backing: a CloudKit-backed store (D4) has no local file paths to return, so `layout` **must not appear on `ProjectStoring`** — promoting it would force every synced implementation to fabricate nonsensical local URLs.

`layout` stays a property of the concrete `ProjectStore` type only. It remains reachable, unchanged, from any call site that holds a **concrete** store (all of which are test/check locals — see the audit below). It becomes unreachable only from the **migrated** call sites (stored/computed properties and parameters now typed `any ProjectStoring`).

**The complete set of migrated-property call sites that reach `.layout` — and their exact, pre-decided resolution:**

There are exactly **four** such sites in the whole codebase. Each is resolved by a **named method on the protocol** that encapsulates the *intent* (not the path), modelled on the existing `deleteSession(id:)` method (`ProjectStore.swift:150`), which already does "construct URL from `layout`, check existence, remove" entirely inside the store.

| # | Site | What it does today | Pre-decided resolution |
|---|---|---|---|
| 1 | `TileSpawner.swift:1327` — `!FileManager.default.fileExists(atPath: projectStore.layout.browserFile.path)` in a `catch` `where` clause distinguishing "no backup because genuinely absent" from "corrupt" | probes whether the browser-state file exists | Add `func browserStateFileExists() -> Bool` to `ProjectStore` (body: `FileManager.default.fileExists(atPath: layout.browserFile.path)`) and to the protocol. Rewrite the `where` clause to `where !projectStore.browserStateFileExists()`. |
| 2 | `TileSpawner.swift:3823` — `FileManager.default.fileExists(atPath: projectStore.layout.fileTreeIndexFile.path)` to label a failure `"corrupt"` vs `"missing"` | probes whether the file-tree index file exists | Add `func fileTreeStateFileExists() -> Bool` to `ProjectStore` (body: `FileManager.default.fileExists(atPath: layout.fileTreeIndexFile.path)`) and to the protocol. Rewrite the ternary to key off `projectStore.fileTreeStateFileExists()`. |
| 3 | `ContinuumApp.swift:3074` — `try? FileManager.default.removeItem(at: projectStore.layout.noteFile(id: noteId))` when deleting a note tile | deletes a note's markdown body file | Add `func deleteNoteBody(id: UUID) throws` to `ProjectStore` (body mirrors `deleteSession`: `let url = layout.noteFile(id: id); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }`) and to the protocol. Rewrite the site to `try? projectStore.deleteNoteBody(id: noteId)`. |
| 4 | `ContinuumApp.swift:3095` — `try? FileManager.default.removeItem(at: projectStore.layout.reviewFile(id: reviewId))` when deleting a diff-review tile | deletes a review sidecar file | Add `func deleteReviewCommentState(reviewId: UUID) throws` to `ProjectStore` (body mirrors `deleteSession` using `layout.reviewFile(id:)`) and to the protocol. Rewrite the site to `try? projectStore.deleteReviewCommentState(reviewId: reviewId)`. |

**Every other `.layout` access in the codebase is on a concrete local and does not migrate.** They keep touching `layout` directly and are unaffected because they never become existentials:

- `TileSpawner.swift` — lines 2061, 2259, 2261, 2286, 2316, 2318, 2342, 4116, 4129, 4155, 4156 are all on concrete `store` / `corruptStore` / `corruptSpawnStore` locals inside embedded check functions.
- `ContinuumApp.swift` — lines 418, 419, 424, 3095-neighbours 5470, 6637, 8046, 8055, 10675, 10676, 10737, 13217, 13221, 13222, 13350, 13407, 14421, 14460, 14465, 14480, 15335, 15347 are on concrete `store` / `lastStore` / `deletedStore` / freshly-constructed `WorkspaceStore(...)` locals inside check functions. In particular the review-sidecar sites at 13217/13221/13222 use a concrete `let store = ProjectStore(projectRoot:)` (declared a few lines above, at ~13202) and stay concrete — they are **not** the same as the migrated computed `projectStore` at 3095.
- `ZoneRuntimeController.swift` — lines 500–592 are all on concrete `storeA` / `storeB` / `storeC` / `workspaceStore` locals created inside the `seedProject`-based check function; the stored `projectStore` property (line 8) is never reached via `.layout` in any method body (its only uses are `saveCanvas`, `saveSession`, `loadSession`, `pruneExitedSessions` — all protocol methods).

This audit is the whole point: the implementer does **not** decide anything per-site. Sites 1–4 get the four named methods above; everything else is a concrete local that is left exactly as-is.

## The path-helper methods (`noteFile`, `reviewFile`, `sessionFile`)

`ProjectStoreLayout` exposes three public path-helper *functions* — `noteFile(id:)` (`ProjectStore.swift:55`), `reviewFile(id:)` (line 63), `sessionFile(id:)` (line 71). They are reached only through `.layout` (e.g. `projectStore.layout.noteFile(id:)` at `ContinuumApp.swift:3074`, `store.layout.reviewFile(id:)` at `ContinuumApp.swift:13217/13221/13222`, `store.layout.sessionFile(id:)` internally in `deleteSession`).

**Decision: these path helpers do NOT go on `ProjectStoring`.** They are pure local-path construction — the same "no local paths on a cloud store" reasoning that keeps `layout` off the protocol keeps them off it too. Their call sites resolve as follows, with no ambiguity:

- The two migrated-property sites that used `noteFile`/`reviewFile` for **deletion** (`ContinuumApp.swift:3074` and `:3095`) are resolved by the new `deleteNoteBody(id:)` / `deleteReviewCommentState(reviewId:)` protocol methods above — they no longer reach the path helper at all.
- The review-sidecar sites at `ContinuumApp.swift:13217/13221/13222` are on a **concrete** `store` local (a check function) and keep calling `store.layout.reviewFile(id:)` directly, unchanged.
- `sessionFile(id:)` is only ever called *inside* `ProjectStore` (by `deleteSession`), never through an existential, so it needs no protocol entry.

So `ProjectStoring` carries **no** path-helper functions; the deletion intents that motivated them are carried by named `delete…` methods instead, and every remaining path-helper call site is on a concrete type.

## Where it lives

**Primary seam files:**

- `Sources/ContinuumRevivedCore/ProjectStore.swift` — `ProjectStoreLayout` struct at line 8; `ProjectStore` struct at line 76; `layout` property at line 77; public persistent methods from line 91 onward covering project, canvas, sessions, browser, file tree, notes, and review comments. Add the four new methods (`browserStateFileExists`, `fileTreeStateFileExists`, `deleteNoteBody(id:)`, `deleteReviewCommentState(reviewId:)`) here, next to `deleteSession` (line 150) which is their template.
- `Sources/ContinuumRevivedCore/WorkspaceStore.swift` — `WorkspaceStore` struct at line 29; public methods `save`, `load`, `tryLoad`, `deleteDocument` from line 55 onward.

**New file:**

- `Sources/ContinuumRevivedCore/StoreProtocols.swift` — declare `ProjectStoring` and `WorkspaceStoring` here.

**Call sites requiring migration (concrete type → protocol type):**

- `Sources/ContinuumRevivedCore/SessionPruner.swift:10` — `pruneExitedSessions(in store: ProjectStore)` → `any ProjectStoring`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift:8` — stored property `let projectStore: ProjectStore` → `any ProjectStoring`; construction at line 64 stays concrete; the `init(projectRoot:projectStore:project:)` parameter at line 71 → `any ProjectStoring`
- `Sources/ContinuumRevived/App/TileSpawner.swift:30` — stored property `private let projectStore: ProjectStore` → `any ProjectStoring`; init parameter at line 71 → `any ProjectStoring`. Rewrite the two `.layout` sites (1327, 3823) per the table above.
- `Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift:23` — stored property `private let store: WorkspaceStore` → `any WorkspaceStoring`; init at line 31 → `any WorkspaceStoring`
- `Sources/ContinuumRevived/App/ContinuumApp.swift:2230` — computed forwarding property `private var projectStore: ProjectStore? { workspaceRuntime?.activeController?.projectStore }` → `(any ProjectStoring)?` (follows automatically once `ZoneRuntimeController.projectStore` migrates). Rewrite the two `.layout` sites (3074, 3095) per the table above. All other `projectStore.*` uses in this file (2911, 2984, 2996, 3042, 3058, 3069, …) call protocol methods and just work.
- `Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift:104,213` — local `store` constructions passed onward → the receiving parameter/property is already the protocol; construction stays concrete
- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:362,410,443,697,770,820` — local `WorkspaceStore` and `ProjectStore` constructions; the ones immediately passed to a migrated function/init just work; any local stored in a migrated property needs its annotation set to the protocol
- `Sources/ContinuumRevived/App/ComponentLab.swift:147` — lab construction; stays concrete, receives protocol downstream

## Implementation breadcrumbs

```swift
// StoreProtocols.swift — in ContinuumRevivedCore

// Both concrete structs are already Sendable; this constraint is intentional so a
// future synced implementation must satisfy it explicitly, not by surprise.
public protocol ProjectStoring: Sendable {
    // Project
    func saveProject(_ project: Project) throws
    func loadProject() throws -> Project
    func tryLoadProject() throws -> Project?

    // Canvas
    func saveCanvas(_ canvas: CanvasState) throws
    func loadCanvas() throws -> CanvasState
    func loadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult
    func tryLoadCanvas() throws -> CanvasState?
    func tryLoadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult?

    // Sessions
    func saveSession(_ descriptor: TerminalSessionDescriptor) throws
    func loadSession(id: UUID) throws -> TerminalSessionDescriptor
    func deleteSession(id: UUID) throws
    func listSessions() throws -> [TerminalSessionDescriptor]

    // Browser
    func saveBrowserState(_ state: BrowserState) throws
    func loadBrowserState() throws -> BrowserState
    func tryLoadBrowserState() throws -> BrowserState?
    func browserStateFileExists() -> Bool          // NEW — replaces layout.browserFile probe

    // File tree
    func saveFileTreeState(_ state: FileTreeState) throws
    func loadFileTreeState() throws -> FileTreeState
    func tryLoadFileTreeState() throws -> FileTreeState?
    func fileTreeStateFileExists() -> Bool         // NEW — replaces layout.fileTreeIndexFile probe

    // Notes
    func saveNoteState(_ state: NoteState) throws
    func loadNoteState() throws -> NoteState
    func tryLoadNoteState() throws -> NoteState?
    func saveNoteBody(id: UUID, text: String) throws
    func loadNoteBody(id: UUID) throws -> String
    func tryLoadNoteBody(id: UUID) -> String?
    func deleteNoteBody(id: UUID) throws           // NEW — replaces layout.noteFile removal

    // Reviews
    func saveReviewCommentState(_ state: ReviewCommentState) throws
    func loadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState
    func tryLoadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState?
    func deleteReviewCommentState(reviewId: UUID) throws  // NEW — replaces layout.reviewFile removal

    // NOTE: `layout` and the path helpers (noteFile/reviewFile/sessionFile) are
    // deliberately NOT on this protocol — they are local-JSON path detail.
}

public protocol WorkspaceStoring: Sendable {
    func save(_ document: WorkspaceDocument) throws
    func load() throws -> WorkspaceDocument
    func tryLoad() throws -> WorkspaceDocument?
    func deleteDocument() throws
}
```

```swift
// ProjectStore.swift — add the four named methods next to deleteSession (line 150),
// which is their template. No renames, no changes to existing methods.

public func browserStateFileExists() -> Bool {
    FileManager.default.fileExists(atPath: layout.browserFile.path)
}

public func fileTreeStateFileExists() -> Bool {
    FileManager.default.fileExists(atPath: layout.fileTreeIndexFile.path)
}

public func deleteNoteBody(id: UUID) throws {
    let url = layout.noteFile(id: id)
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
}

public func deleteReviewCommentState(reviewId: UUID) throws {
    let url = layout.reviewFile(id: reviewId)
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
}

// Conformance is satisfied by the existing implementations plus the four above:
extension ProjectStore: ProjectStoring {}
```

```swift
// WorkspaceStore.swift
extension WorkspaceStore: WorkspaceStoring {}
```

```swift
// Migration pattern — ZoneRuntimeController.swift
// Before:
let projectStore: ProjectStore
// After:
let projectStore: any ProjectStoring

// Construction stays concrete at the leaf that knows the URL:
let store = ProjectStore(projectRoot: projectRoot)  // still ProjectStore
someController.init(projectStore: store, ...)        // parameter is `any ProjectStoring`
```

```swift
// Migration pattern — the four rewritten call sites
// TileSpawner.swift:1327 — before:
} catch AtomicWriterError.noValidBackup where !FileManager.default.fileExists(atPath: projectStore.layout.browserFile.path) {
// after:
} catch AtomicWriterError.noValidBackup where !projectStore.browserStateFileExists() {

// TileSpawner.swift:3823 — before:
let kind = FileManager.default.fileExists(atPath: projectStore.layout.fileTreeIndexFile.path) ? "corrupt" : "missing"
// after:
let kind = projectStore.fileTreeStateFileExists() ? "corrupt" : "missing"

// ContinuumApp.swift:3074 — before:
let noteFile = projectStore.layout.noteFile(id: noteId); try? FileManager.default.removeItem(at: noteFile)
// after:
try? projectStore.deleteNoteBody(id: noteId)

// ContinuumApp.swift:3095 — before:
try? FileManager.default.removeItem(at: projectStore.layout.reviewFile(id: reviewId))
// after:
try? projectStore.deleteReviewCommentState(reviewId: reviewId)
```

## How we test it

### Logic (pure Core checks)

Add checks in `Sources/ContinuumRevivedCoreChecks/main.swift` covering:

1. **Protocol conformance is exercised through the protocol type.** Construct a `ProjectStore` into a local typed as `any ProjectStoring`. Call `saveProject`, `loadProject`, `saveCanvas`, `loadCanvas`, `saveSession`, `loadSession`, `listSessions` through the protocol variable. Assert round-trip equality for each. This proves the conformance is real and not an unused `extension` declaration.

2. **The four new named methods work through the protocol type.** On the same `any ProjectStoring` local: (a) assert `browserStateFileExists()` is `false` before any browser save and `true` after `saveBrowserState`; (b) assert `fileTreeStateFileExists()` is `false` before and `true` after `saveFileTreeState`; (c) `saveNoteBody(id:text:)` then `deleteNoteBody(id:)` then assert `tryLoadNoteBody(id:)` returns `nil`; (d) `saveReviewCommentState` then `deleteReviewCommentState(reviewId:)` then assert `tryLoadReviewCommentState(reviewId:)` returns `nil`. This proves the four replacements for the `layout` probes/deletes behave identically to the old inline path logic — and that they are reachable through the existential (the exact thing the four migrated sites need).

3. **`WorkspaceStoring` round-trip.** Construct `WorkspaceStore` as `any WorkspaceStoring`, call `save` then `load`, assert the returned `WorkspaceDocument` equals what was saved.

4. **`pruneExitedSessions` accepts the protocol.** Construct a `ProjectStore` as `any ProjectStoring`, populate it with a mix of exited and live sessions, call `pruneExitedSessions(in:)`, assert only live sessions remain. This is a direct port of the existing check at `Sources/ContinuumRevivedCoreChecks/main.swift:3880` (its `pruneExitedSessions(in: store)` call is at line 3934) — reuse its seed logic, just change the parameter type of the store local to `any ProjectStoring`.

Each check uses a temporary directory via `FileManager.default.temporaryDirectory` and cleans up after itself. No new dependencies, no new test targets — these live alongside the existing checks in the same executable.

### Backend (real-path / integration)

The existing real-path checks embedded in `TileSpawner` and `ZoneRuntimeController` already exercise the full save/load cycle, including the browser/file-tree corruption paths (`TileSpawner.swift` lines ~2243–2342, ~4116–4156) that the two rewritten existence-probe sites participate in. After migration, run the full check suite (the existing `ContinuumRevivedCoreChecks` binary) and confirm zero regressions. The real-path bar here is: the check suite that previously passed with concrete types passes identically after the protocol migration, measured by the same pass/fail manifest format the suite already emits (measured values in the manifest, never `{passed:true}` — D26).

No new real-path checks are needed beyond the four-method Logic check above — the behavioral contract of the stores is unchanged and the four new methods are pure extractions of existing inline logic. The migration is structural; if the suite passes, the real path is proven.

### UX (visual gate + dogfood snippet)

This ticket carries no UX surface — it is a pure structural refactor with no behavioral change visible to the user. There is therefore no visual gate and no dogfood snippet for this ticket itself; per D26, the full three-part UX contract attaches to the first ticket with observable behavior (the op-log apply or the sync transport), not to this one. The correctness criterion here is zero regressions in the check suite, not a visual observation.

## Execution mode

**Autonomous.** This ticket makes no network calls, touches no real cloud infrastructure, requires no human eyes on a running UI, and changes no behavior the user would observe. Every correctness claim is provable by the pure Core checks and the existing real-path check suite. An overnight agent can execute, run the checks, and confirm the work is done entirely without supervision.

## Done when

- [ ] `ProjectStoring` protocol declared in `StoreProtocols.swift`, carrying every existing public persistent-read/write method of `ProjectStore` **plus** the four new named methods `browserStateFileExists()`, `fileTreeStateFileExists()`, `deleteNoteBody(id:)`, `deleteReviewCommentState(reviewId:)`
- [ ] `WorkspaceStoring` protocol declared in the same file, covering `save`, `load`, `tryLoad`, `deleteDocument`
- [ ] The four new methods are implemented on `ProjectStore` (next to `deleteSession`), each constructing its URL from `layout` internally and mirroring `deleteSession`'s existence-checked behavior
- [ ] `extension ProjectStore: ProjectStoring {}` and `extension WorkspaceStore: WorkspaceStoring {}` compile — conformance satisfied by the existing implementations plus the four new methods, with no changes to any pre-existing method
- [ ] `layout` does NOT appear on `ProjectStoring`; the path helpers `noteFile`/`reviewFile`/`sessionFile` do NOT appear on `ProjectStoring`
- [ ] All four migrated-property `.layout` sites are rewritten to the named methods: `TileSpawner.swift:1327` → `browserStateFileExists()`, `TileSpawner.swift:3823` → `fileTreeStateFileExists()`, `ContinuumApp.swift:3074` → `deleteNoteBody(id:)`, `ContinuumApp.swift:3095` → `deleteReviewCommentState(reviewId:)`
- [ ] Every remaining `.layout` access in the codebase is on a concrete local and is left unchanged (verify with a grep that no `.layout` access remains on an `any ProjectStoring`-typed value)
- [ ] `SessionPruner.pruneExitedSessions(in:)` parameter is `any ProjectStoring`
- [ ] `ZoneRuntimeController.projectStore` stored property is typed `any ProjectStoring`; its `init` parameter is too
- [ ] `TileSpawner.projectStore` stored property is typed `any ProjectStoring`; its `init` parameter is too
- [ ] `WorkspaceDocumentSaveController.store` stored property is typed `any WorkspaceStoring`; its `init` parameter is too
- [ ] `ContinuumApp.projectStore` computed forwarding property is typed `(any ProjectStoring)?`
- [ ] All other call sites in `ZoneRuntimeRegistry`, `WorkspaceRuntime`, `ComponentLab`, and `ContinuumApp` compile against the protocol type where they pass the store into a migrated function or store it in a migrated property; concrete construction stays concrete
- [ ] Four Logic checks pass: `ProjectStoring` round-trip, the four-named-methods check, `WorkspaceStoring` round-trip, `pruneExitedSessions` via protocol
- [ ] The full existing `ContinuumRevivedCoreChecks` suite passes with zero regressions (measured manifest, not `{passed:true}`)
- [ ] The app compiles and links with no warnings introduced by this change

## Depends on / unblocks

This ticket has no dependencies — it is the first foundation and can start immediately against `main`.

It unblocks the op-log core directly (D3), because that work needs a `ProjectStoring`-typed injection point to register the logged-op store against. It also unblocks the sync/observation type split (I5), which enforces at the type level that the synced spatial payload and the activity projection are distinct; that enforcement needs a store abstraction to live behind. More broadly, every injectable substrate (D26) — the fake sync transport, the fake clock, the fake `TmuxControl` — assumes the things being tested hold protocol types, not concrete ones. Getting the store protocol in place first keeps all of that work clean.

## Watch out for

**The `layout` property is a trap — and it is already disarmed above.** `ProjectStoreLayout` exposes file paths used directly by callers. A synced implementation (D4) cannot return real local paths, so `layout` is kept off the protocol and the exactly-four migrated call sites that needed it are rewritten to the four named methods. Do NOT take the shortcut of throwing `layout` (or the path helpers) on the protocol to make the build compile — the four named methods are the whole mechanism that lets you avoid that.

**Do not add existence-probe or delete methods beyond the four specified.** The audit above is exhaustive: only four migrated-property sites reach `.layout`. Every other `.layout` access is a concrete local and needs no protocol method. If you find yourself tempted to add a fifth path-based method to the protocol, you are almost certainly looking at a concrete local — leave it alone.

**`any` vs generics.** `any ProjectStoring` (existential) is the right choice on stored properties and function parameters because the concrete type is chosen at runtime (production uses `ProjectStore`; a future test or synced impl uses something else). Do NOT reach for `some ProjectStoring` (opaque) on stored properties — it would lock the concrete type at compile time and defeat the seam. Construction sites that know the concrete type stay concrete.

**`Sendable`.** Both protocols require `: Sendable`; both concrete structs already are. The constraint is called out in a comment in the protocol declaration so a future non-trivially-`Sendable` implementation is forced to satisfy it explicitly rather than being surprised by it.

**Do not change behavior.** No method renames, no new error types, no changed semantics on load/save. The four new methods are pure extractions of existing inline logic (path construction moved from the call site into the store, guarded exactly as `deleteSession` already guards). If a call site has a pre-existing bug (e.g. ignoring an error from a `try` call), leave it — do not fix unrelated issues under cover of this structural change. The diff should read as type-annotation changes, four small new methods, two `extension` declarations, and four one-line call-site rewrites.
