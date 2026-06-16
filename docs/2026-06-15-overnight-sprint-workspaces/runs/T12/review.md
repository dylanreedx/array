# T12 Review — Bulletproof restore (durable atomic autosave + crash-safe reload + configurable debounce)

Reviewer: adversarial / read-only. Branch `overnight/workspaces-zones`, uncommitted.
Verdict: **PASS WITH RISKS** (committable; one acknowledged bypass-by-design + one minor contract gap).

## What I ran (evidence)
- `swift build` → clean.
- `swift run ContinuumRevivedCoreChecks` → passed (clamp/resolver table green).
- `--persistence-crash-safe-check` (isolated CONTINUUM_APP_SUPPORT) → passed (exit 0). Manifest: `recoveredViewportZoom: 1.5`, `backupDelta: 1`, `coalesceCount: 1`, `postCoalesceViewportX: 14`, `flushViewportX: 15`.
- `./scripts/run-matrix.sh --fast` → "Fast matrix passed." Confirmed the new check AND all five persistence regression checks ran green in-matrix: `--zone-save-isolation-check`, `--browser-restore-state-check`, `--browser-profile-persistence-check`, `--file-tree-boot-persistence-check`, `--viewport-sanitize-check`.

## Bypass audit (gate #1) — re-ran with each change reverted
The check drives the REAL `WorkspaceStore.save/load` + REAL `WorkspaceDocumentSaveController.scheduleZoneLayoutSave`/`flushPendingSave` (no direct `AtomicWriter.write` poke, no hand-rolled timer). Verified by source. I empirically reverted each of the three real-path changes:

1. **Durable write (fsync) — BYPASSABLE, by design & acknowledged.** Reverted `atomicDurableWrite` → `Data.write(to:url,options:.atomic)`, rebuilt, ran → **still exit 0 (PASS).** The durable-write change has NO discriminating observable assertion: assertion 3 (no `.canvas.json.tmp-*` leftover) passes under `.atomic` too (Foundation names+cleans its own temp differently), and assertion 7 (stray temp ignored) passes regardless of the writer because temps are dot-prefixed and excluded by the backup scanner + `.skipsHiddenFiles`. The fsync/durability guarantee is genuinely not observable in a normal process exit. This is exactly what the spec's Review rubric says to "acknowledge," and the builder/manifest do. The durable path is therefore verified only by **code review** (which I did — see below), not by a RED-able assertion.
2. **Configurable debounce — RED CONFIRMED.** Reverted controller to hardcoded `0.2`, rebuilt, ran → **FAIL: "E14: controller with 0ms config must flush on next runloop (x=99), got 15.0", exit 1.** Genuine behavioral RED through the real controller.
3. **Clamp/resolver table — RED CONFIRMED.** Stubbed `AutosaveConfig.debounceMs` to always return 200, rebuilt, ran CoreChecks → **FAIL: "autosave debounce: '750' reads back 750".** Matches builder's reported E13a RED.

After all reverts I restored the tree; `git diff --stat` is byte-identical to the builder's report (6 modified + AutosaveConfig.swift untracked), and a final re-run is GREEN.

## Right-reason re-derivation (assertion 6 — recovery target)
Re-derived the backup set by hand from the real `backupExistingFile`/`read` logic:
- A1 `save(D1)`: no prior primary → 0 backups. primary=D1.
- B4 `save(D2)`: D1 backed up → backups={D1}. primary=D2.
- B5: garbage overwrites primary out-of-band → backups still {D1}.
- B6 `load()`: primary garbage fails decode (caught by `try?`) → newest backup = D1 → returns D1, zoom 1.5.
The check asserts the SPECIFIC doc (`== D1` AND `viewport.zoom == 1.5`), not "didn't throw" — D2 lived only in the destroyed primary and was never backed up, so recovery to D1 (not D2) is correct and is the half-written-doc guard the rubric demands. Manifest `recoveredViewportZoom: 1.5` confirms. Coalescing (assertion 10) is proven by backup-count delta == 1 with `retainedBackups: 64` (pruning trap addressed), not by final value alone.

## Code-review gate for the un-RED-able durable path (verified by reading source)
`AtomicWriter.atomicDurableWrite` (Sources/ContinuumRevivedCore/AtomicWriter.swift:81-98): temp = `dir.appendingPathComponent(".<name>.tmp-<uuid>")` where `dir = url.deletingLastPathComponent()` → SAME directory as `url` (= same volume → `rename(2)` is atomic). Sequence is exactly: write temp → `fsync(temp fd)` → `rename(tmp,url)` → `fsync(dir fd)`. On `rename` failure it removes the temp and rethrows a POSIXError, leaving `url` intact. `read`/backup/prune/backupName untouched. This matches the spec's load-bearing requirement.

## Scope
Exactly the 7 spec-scoped files; nothing adjacent refactored. AtomicWriter diff is `import Darwin` + the one write-line swap + the private helper only — `read`/backup/prune untouched. ProjectStore/RegistryStore NOT in the diff (they inherit the durable write — the confirmed NEEDS-HUMAN decision (a), regression-gated by the green matrix checks). SettingsSchema: one `.text` appended to "general" mirroring `leaderDwellMs`. CoreChecks: key added to `expectedKeys` + 5-row clamp table. No commit made; no co-author footer anywhere.

## Confirmed defects
None blocking.

## Risks (committable, but named)
- **R1 (by-design bypass, acknowledged):** The fsync/durable-write change is not covered by any RED-able assertion — reverting it to `Data.write(.atomic)` leaves the check GREEN (empirically proven). The change is verified by code review only. This is consistent with the spec rubric ("would the check go RED if you reverted the fsync line? No — acknowledge this") and the manifest note. Net: the *crash-left-corrupt-primary recovery* (the user-visible guarantee) IS asserted; the *power-loss durability* is not headless-simulable.
- **R2 (minor contract gap vs spec):** `atomicDurableWrite` only removes the leftover temp when `rename(2)` fails. If `data.write(to: tmp)` (line 85) or the temp fsync throws/aborts, the dot-prefixed temp is NOT cleaned up — contradicting the spec's stated contract "if the temp write or fsync throws, the leftover temp is removed." Practical impact is LOW: a stray temp is dot-prefixed and excluded from the backup scanner and `.skipsHiddenFiles`, so it never corrupts load (assertion 7 proves this); the only effect is orphaned hidden temp files accumulating on repeated write failures. Not blocking; flag for cleanup.
- **R3 (D10 spin-time deviation, documented):** Builder changed the assertion-10 runloop spin from the spec's 0.05s to 0.30s so the count-based coalescing assertion holds even against the pre-fix hardcoded 0.2s timer. This is a defensible widening (coalescing is a write-count property, not a timing property) and is documented in build.md. No correctness impact; the post-fix 10ms timer fires well within 0.30s.

## Unverified
- True power-loss / mid-rename crash durability (fsync efficacy) — not headless-simulable; only the corrupt-primary recovery path is exercised (per spec).
- Cross-volume rename behavior is not exercised, but the temp is provably same-dir, so the atomic-rename precondition holds by construction.

## Needs human
- **NH1:** Confirm the intended scope decision (a) was accepted: fsync now lives in the SHARED `AtomicWriter`, so EVERY persisted JSON (Workspace/Project/Registry) gets the durable write. Matrix regression checks are green, but this widens T12's blast radius beyond "WorkspaceStore" as the spec flagged.
- **NH2:** Confirm there is intentionally NO live drag/resize/move autosave caller wired in T12 (spec decision (a)). Coalescing is proven only at the controller level by the check; no production path currently fires a debounced autosave. This is a deliberate gap deferred to T05/T11/T19, per spec — confirm it is tracked.
- **NH3 (optional):** Decide whether R2 (clean up the temp on temp-write/fsync failure) is worth a follow-up given the low impact.
