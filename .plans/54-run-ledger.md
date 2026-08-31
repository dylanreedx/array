# Array 0.8.0 overnight run ledger

**Goal:** one morning-testable minor release candidate with all WS1–WS7 changes.
**Starting SHA:** `d41598dd`
**Starting branch:** `array/integration`
**Run ID:** `20260831T011923Z-080`
**Current checkpoint:** P0 `569209c7` complete; three disjoint Wave-0 implementation slices active
**Publication authority:** not granted; local candidate only

This table is the compactable run state. Root updates it immediately after each role finishes and after every promotion/checkpoint.

| Workstream | Base | Lead | Candidate | Reviewer | Tester | Evidence | Promotion | Status |
|---|---|---|---|---|---|---|---|---|
| Plan control P0 | `d41598dd` | root | `569209c7` | n/a | n/a | reviewed packet | local commit | complete |
| Evidence/GUI harness | `569209c7` | W0 evidence + GUI + perf leads active | — | pending | pending | prompt hashes under run root | pending | in progress |
| Baseline preflight | E0 pending | testing role | — | — | — | pending | — | pending |
| WS1 zones/HUD/layout | E0 pending | pending | — | pending | pending | pending | pending | pending |
| WS2 persistence | E0 pending | pending | — | pending | pending | pending | pending | pending |
| WS6 transcript parity | E0 pending | pending | — | pending | pending | pending | pending | pending |
| I1 | — | root | — | — | — | pending | — | pending |
| WS3 performance | I1 | pending | — | pending | pending | pending | pending | pending |
| WS4 awareness | I1 | pending | — | pending | pending | pending | pending | pending |
| I2A | — | root | — | — | — | pending | — | pending |
| WS5 tile page zoom | I2A | pending | — | pending | pending | pending | pending | pending |
| I2 | — | root | — | — | — | pending | — | pending |
| WS7 backgrounds | I2 | pending | — | pending | pending | pending | pending | pending |
| I3 | — | root | — | — | — | pending | — | pending |
| WS8 release candidate | I3 | pending | — | pending | pending | pending | — | pending |

## Blocking issues

- Independent critical-path audit estimates roughly 24–58 hours for the full evidence standard. The overnight boundary is a checkpoint, not permission to collapse gates or label incomplete work READY.

## Planning validation

- Prompt/role/token/phase contract: independent adversarial review PASS.
- Repository paths, current flags/targets, future-producer gates, shell commands, debug/release/channel truth, and canonical artifact commands: independent literal dry-run PASS.
- Screenshot/performance/evidence schemas, source-to-DMG identity chain, post-artifact ordering, and test matrix alignment: independent audit PASS.
- Representative rendered dispatch smoke: WS1 lead, WS3 reviewer, WS5 tester, baseline tester, WS8 auditor, WS8 pre/post reviewers, and WS8 artifact tester all substitute with zero unresolved uppercase tokens.

## Active dispatches

- W0 evidence CLI/canonical identity lead: `wave0-evidence-lead.md`, SHA-256 `f87c2f56d74225006fd462cb253aac026977fdb986494e7da376e9575318264c`.
- W0 native GUI preflight lead: `wave0-gui-lead.md`, SHA-256 `1e565169c66d961e2df877b30782c9fd18a981e989230e596b9ef77a8ac46507`.
- W0 release-aware perf runner lead: `wave0-perf-lead.md`, SHA-256 `c204dc73872cc40f6c8a3da214ac80c590a38be7aec0a198e6afd09567463517`.

## Decisions and waivers

- Target proposed as 0.8.0/build 56; no shipped ledger/appcast mutation before Dylan's test and explicit publication approval.
- Per-agent-tile page zoom is temporary and non-persistent in this release.
- Custom images are screen-fixed; grids are world-aligned.
- Current auto-layout checks that require passive tile shrinking or resize-driven zone/peer reflow are false-green expectations to replace, not compatibility requirements.
- No visual baseline is blessed autonomously.
- P0 will be a local plan-only commit so isolated worktrees contain the reviewed packet; it will not change product code or be pushed during the unpublished RC run.

## Last known-good integration SHA

`569209c7` (P0; product source still `d41598dd`) until E0 is promoted and green.
