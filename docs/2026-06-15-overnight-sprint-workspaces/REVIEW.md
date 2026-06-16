# Morning Review — workspaces/zones sprint

**Open this first.** Single entry point for reviewing the overnight run. Changes are triaged
by ATTENTION, not by build order. Tick each `[ ]` as you review. Ask me for the **guided
walkthrough** and I'll drive it highest-risk first, carrying the context so you don't have to
reconstruct it.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing is merged to `main` — that's your call.**
Review commit-by-commit: `git log --oneline main..overnight/workspaces-zones` — each task is one commit, tagged `(Tnn)` in its subject.

## Status (updated as each task lands)
- Committed: **1** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks (T01–T19; T09 last session's exemplar pending build)
- Fast matrix on branch HEAD: **green** (after T01)
- Spec foundation: 17 task specs (T02–T19) committed — 5 adversarially reviewed, 12 first-draft (each gets a reviewer pass at build time).

## 🔴 Decide / eyeball — read these (tests could not prove them)
_Design calls deferred, visual/feel gates, anything unverified. The un-missable list._
- [ ] **T01 · navKey configurable-first split** — `navKey` ships in T01 as per-zone *document data* only; its Settings entry + conflict-guard are owned by **T18** (which depends on `T01.navKey`). The reviewer judged this an intentional split, not a config-first violation — **confirm you agree.** · `runs/T01/review.md`

## 🟡 Pass with risks — review carefully
_Committed + verified, but the reviewer named a specific risk._
- _(none yet)_

## 🟢 Verified routine — skim or trust
_Committed, test-guarded, reviewer clean._
- [ ] **T01 — zone model** · `ZonePlacement.projectId` → optional (nil = group zone), `name` + `navKey` added, custom `Codable` (`decodeIfPresent`) backward-compat, `schemaVersion` 1→2 · guards: ContinuumRevivedCoreChecks T01 table (v2 round-trips, v1→v2 migration from a hand-written JSON literal, mixed-doc) · `runs/T01/{build,review}.md`
  - _by-design notes:_ check uses `JSONCodec` (the same codec the on-disk path uses) rather than a full `ProjectStore` save/load round-trip (T12 owns that); group-zone `name` is empty until set (project-zone backfill comes in T06).

## ⛔ Blocked / needs-human
_Couldn't reach a clean PASS in the retry budget; reason recorded._
- _(none yet)_

---
Each entry reads: `[ ] Tnn — what it does · guards: <check> · runs/Tnn/{build,review}.md`
Per-task evidence lives in `runs/<task>/` (see `runs/README.md`) — the source of truth.
