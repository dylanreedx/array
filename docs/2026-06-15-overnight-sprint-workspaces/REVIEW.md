# Morning Review — workspaces/zones sprint

**Open this first.** Single entry point for reviewing the overnight run. Changes are triaged
by ATTENTION, not by build order. Tick each `[ ]` as you review. Ask me for the **guided
walkthrough** and I'll drive it highest-risk first, carrying the context so you don't have to
reconstruct it.

Branch: `overnight/workspaces-zones` (off `main`). **Nothing is merged to `main` — that's your call.**
Review commit-by-commit: `git log --oneline main..overnight/workspaces-zones` — each commit is one verified task.

## Status (updated as each task lands)
- Committed: **0** · blocked: **0** · staged-for-morning: **0** · of 17 build tasks (T01–T19; T09 last session's exemplar pending build)
- Fast matrix on branch HEAD: _n/a yet_
- Spec foundation: 17 task specs (T02–T19) committed — 5 adversarially reviewed, 12 first-draft (each gets a reviewer pass at build time).

## 🔴 Decide / eyeball — read these (tests could not prove them)
_Design calls deferred, visual/feel gates, anything unverified. The un-missable list._
- _(none yet)_

## 🟡 Pass with risks — review carefully
_Committed + verified, but the reviewer named a specific risk._
- _(none yet)_

## 🟢 Verified routine — skim or trust
_Committed, test-guarded, reviewer clean._
- _(none yet)_

## ⛔ Blocked / needs-human
_Couldn't reach a clean PASS in the retry budget; reason recorded._
- _(none yet)_

---
Each entry reads: `[ ] Tnn — what it does · commit <sha> · guards: <check> · runs/Tnn/{build,review}.md`
Per-task evidence lives in `runs/<task>/` (see `runs/README.md`) — the source of truth.
