# Agent handoff for expanded file tiles

Updated 2026-10-24. Read this before executing any slice.

## Active bench — 2026-10-24 transfer

Work now lives in the real Git worktree `.worktrees/file-tile-previews`, branch `array/file-tile-previews`, based on `fe734156`. The scoped delta from research baseline `81bb3717` was transferred; the incoming `farParkableBody` method was preserved and matrix inventory regenerated with the existing multiselect legs. Continue only in this bench. The research archive is retained until Dylan confirms removal. Historical archive warnings below describe the earlier environment, not this active worktree.

The release coordinator owns commits under Dylan’s identity. Prepare `qa-runs/file-tile-previews/landing.patch`, verify `git apply --cached --check`, and report the proposed subject. Do not stage, commit or push here. The intended subject is `feat(files): add bounded image and spreadsheet previews`. Historical passing logs are copied under `qa-runs/file-tile-previews/research-base-evidence`; these do not establish a passing build on the new base.

## Exception-handler isolation — required immediately

Dylan’s performance session reported three host Array exits caused by inherited Ghostty/Breakpad task exception handlers in our test descendants. Every build and native test must now run through `/tmp/exc-probe/noexc`. Read [SAFE-EXECUTION](SAFE-EXECUTION.md) before executing or delegating. Do not retry a trapping witness without diagnosing its failure. Snapshot fixture canonicalization and the ZIP fixture central-header length were identified as concrete causes; these are test defects, not a reason to weaken production validation.

## Objective and authority

Dylan wants richer file/editor tiles, especially broad image viewing and spreadsheets/CSV, built with clean architecture, efficient lasting tests and coordination with incoming performance work for a near release. Eight focused investigations produced the [proposal](README.md) and [research](README.md#research-index). The implementation and its evidence are described in CURRENT-IMPLEMENTATION and verification.json; research notes preserve the earlier alternatives. Publication remains coordinator-owned.

Follow the current chat and the live checkout's AGENTS.md first. Then use this reading order:

1. [CURRENT IMPLEMENTATION](CURRENT-IMPLEMENTATION.md) and [ARCHITECTURE](ARCHITECTURE.md): ownership, data flow, lifecycle and extension contract.
2. [EXECUTION](EXECUTION.md): dependency order, source map, tasks and exit criteria.
3. [TESTING](TESTING.md): reusable harnesses, fixtures, evidence and release gates.
4. [README](README.md): scope, rationale and future formats.
5. The research note for the slice being implemented; reading every note is unnecessary for a parser-only change.

## Actual workspace status

Active work is in `.worktrees/file-tile-previews`, branch `array/file-tile-previews`, based on integration `fe734156`. The coordinator created this real worktree after Git metadata writes were denied to the implementation session. Forty-eight scoped paths were transferred from the research archive: new files matched byte-for-byte, tracked source matched a three-way merge against its original baseline, and the matrix inventory was regenerated rather than overwriting newer multiselect entries. The incoming `farParkableBody` method remains intact.

The research archive at `.worktrees/file-tile-research` began at `81bb3717eec92bde6c987662d2771db57f591b0e` and still has no `.git`. It remains intact until Dylan explicitly confirms removal. Git commands there discover the canonical parent, so never mutate Git there. Earlier qualification records in IMPLEMENTATION and LOCAL-QUALIFICATION describe that historical source/base. New-base results are recorded separately under `active_bench` in verification.json and `qa-runs/file-tile-previews/`.

The canonical main checkout contains other owners' work. Do not clean, overwrite or copy it wholesale. The release coordinator reviews `landing.patch`, applies it cached and commits under Dylan's identity; this agent does not stage, commit or push.

## Pickup checklist

- Read current instructions and `.plans/82-release-0731/README.md` in the canonical checkout; run `scripts/benches.sh` without cleaning other work.
- Verify `git rev-parse --show-toplevel`, `git branch --show-current` and `git status` in the real bench before edits. Its root must be `.worktrees/file-tile-previews`.
- Locate live performance interfaces with `rg`. Preserve the integrated far-parking and multiselect work; historical research line numbers are not current source locations.
- Read CURRENT-IMPLEMENTATION, verification.json and the latest bench logs to distinguish new-base results from historical archive qualification.
- Rebuild only affected products with `/tmp/exc-probe/noexc`, use disposable project/app-support roots, and register substantive witnesses in the matrix. Never guess app flags.
- Regenerate the own-hunks `qa-runs/file-tile-previews/landing.patch` after source/document updates and verify `git apply --cached --check`. Report the subject to the coordinator; leave the index unchanged.
- Preserve the research copy until Dylan confirms it can go. Revalidate any material scope change against the current conversation.

## Scope and open decisions

| Decision | Recommended default | Must establish before shipping |
| --- | --- | --- |
| Required near-release formats | Images, CSV/TSV, qualified workbook previews | Fixture-backed support table on supported macOS |
| Workbook experience | Bounded native XLSX data grid; other workbook formats external-only | Implemented decision in CURRENT-IMPLEMENTATION; provider boundary could not establish required resource isolation |
| CSV editing | Read-only grid plus existing safe small-file source editing | Same draft across views; no encoding conversion or data loss |
| SVG | Source now; embedded static view only after isolated prototype passes | No active content or unauthorized resource reads |
| PDF | First optional addition | Required slices pass before expanding release scope |
| Format/resource limits | Implemented per-format limits and shared accounting in CURRENT-IMPLEMENTATION | Broader release/OS measurements remain distinct from enforced code limits |
| Native grid implementation | One custom drawing view with both-axis projected pages | Bounded cache, selection, keyboard, copy, full-value inspection and accessibility labels |
| Persisted view state | Existing file identity only; view choices remain runtime-local | No new coding keys or schema migration |

The current implementation follows Dylan’s instruction to proceed locally: read-only data viewing, including native XLSX, is the selected scope. Spreadsheet cell write-back and Excel layout reproduction are outside this version. CURRENT-IMPLEMENTATION supersedes the original Quick Look proposal.

## Nonnegotiable implementation boundaries

Retain one persisted `.file` tile and the current production open/API routes. Binary viewers do not instantiate a text editing session. No source/Markdown save, recovery or language-service regression is acceptable. Respect project/zone ownership, WORLD versus ZONE-LOCAL frames and persistence coverage. Follow the existing residency system rather than adding another visibility owner.

QA uses temporary project roots as well as isolated app support. Never point another install at Dylan's live project root, operate `/Applications/Array.app`, use the default tmux socket, override the managed-agent marker, or update visual baselines to hide failures. Use the documented dev-app script for preview work. Read live AGENTS.md for the complete requirements.

## Maintaining this handoff

After each completed slice, update EXECUTION's status/evidence table and the affected architecture or support decisions. Keep proposals, implemented behavior and verified behavior distinct. Record command, build/base, result and evidence path; record skips and blockers. Do not leave multiple incompatible designs described as current.

A final report includes completed scope, tests actually run, remaining unsupported cases, resource results and bench disposition. Transfer the plan into the real reviewable change before returning its bench. Follow live repository cleanup rules; preserve any unlanded work and never force-remove someone else's dirty bench.
