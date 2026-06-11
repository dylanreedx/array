# Overnight Linear Agent Plan — 2026-06-10

Status: planning doc only. Do not start overnight execution until Dylan explicitly approves.

Goal: run a single master/coordinator agent overnight against the Linear `CON` backlog, using Linear as the queue, git commits as checkpoints, and `.pi/agent-runs/*` as evidence. Conductor is optional and not required for this loop.

## 0. Current repo state / constraints

Branch at planning time: `feat/focus-broker`.

Linear API access for future agents is stored in macOS Keychain, not in the repo:

```sh
LINEAR_API_KEY=$(security find-generic-password -a continuum-revived -s continuum.linear.api-key -w)
```

Use that environment variable for `curl` GraphQL calls. Do not print the token in logs, commit it, or paste it into Linear comments. If Dylan rotates the exposed key, update the Keychain item with `security add-generic-password -a continuum-revived -s continuum.linear.api-key -w '<new key>' -U`.

Recent local commits:
- `fc3e9ba test(palette): stabilize browser key capture check`
- `79ff9a0 feat(focus): route reserved shortcuts through broker`
- `b60e132 fix(palette): capture keyboard input while visible`
- `231011d chore: ignore .swiftpm Xcode workspace state`
- `b9061f2 feat(focus): add broker core and shortcut model`
- `f2ccce7 test(focus): add note click focus self-check`
- `e2270cb fix(delete): make cancel the default confirmation action`

Hard constraints:
- The repo still has **no git remote**. This is the top overnight durability risk.
- Do not touch `main`, `backup/*`, `archive/*`, or `.pi/agents/*`.
- One writer per working tree. Scouts/reviewers can run in parallel; implementers must be serialized unless Dylan explicitly authorizes separate worktrees.
- Every commit must keep the matrix green.
- Do not claim manual UI behavior without manual/visual evidence.

Current verification matrix includes:

```sh
swift build
swift run ContinuumRevivedCoreChecks
swift run ContinuumRevivedPaletteChecks
.build/debug/continuum-revived --palette-duplicate-root-check
.build/debug/continuum-revived --palette-first-responder-restore-check
.build/debug/continuum-revived --browser-url-focus-check
.build/debug/continuum-revived --palette-captures-keys-over-browser-check
.build/debug/continuum-revived --zindex-relaunch-hit-test-check
.build/debug/continuum-revived --bring-to-front-focus-check
.build/debug/continuum-revived --note-click-focus-check
.build/debug/continuum-revived --browser-restore-state-check
.build/debug/continuum-revived --note-file-tile-spawn-check
.build/debug/continuum-revived --file-tree-boot-persistence-check
git diff --check
```

## 1. Master-agent operating model

The overnight master agent is the only agent allowed to decide direction, commit, and update Linear. Specialist agents provide evidence only.

Loop per ticket:

1. Query Linear for eligible `CON` issues.
2. Select one ticket by priority and dependency order.
3. Dispatch `code-scout` and, if UI/QA-sensitive, `qa-scout` or `ux-scout`.
4. Master reads artifacts and decides: implement / split / defer / stop.
5. Implement one bounded slice directly or via one `implementer`.
6. Run the full matrix plus any new ticket-specific checks.
7. Dispatch read-only `code-reviewer` and `qa-reviewer`; add `ux-reviewer` for user-facing changes.
8. Fix blocking findings, rerun matrix, and re-review if needed.
9. Commit with `type(scope): summary`.
10. Update Linear with branch, commit, matrix summary, reviewer run IDs, manual PENDINGs, and no-remote warning.
11. Continue only if working tree is clean and no blockers remain.

Stop immediately if:
- matrix fails and the fix would require weakening a check;
- plan/code contradiction appears;
- manual evidence is required but unavailable;
- implementation would broaden beyond ticket scope;
- git state is dirty in unexpected files;
- anything would touch protected refs or `.pi/agents/*`.

## 2. Linear backlog snapshot

Queried Linear organization: `savorofit`; Continuum team key: `CON`.

Relevant projects:
- E1 — Focus & Input Foundation
- E2 — Spawn & Launch Experience
- E3 — Project Registry & Lifecycle
- E10 — Agent Tiles & Live Status
- E11 — Agent Harness Bridge
- E14 — QA Infra & DX
- E15 — Bug Tail

Highest-priority current `CON` issues observed:
- `CON-109` P1 — Create private git remote and push everything (TOP DURABILITY RISK)
- `CON-9` P1 — CanvasEngine.placementFrame: first-fit spawn placement + CoreChecks
- `CON-110` P2 — scripts/run-matrix.sh: one entrypoint for whole verification matrix
- `CON-112` P2 — .app bundle: make-app-bundle.sh, Info.plist, icon, GhosttyKit slimming
- `CON-116` P2 — DD-011 viewport/tile-frame sanitize
- `CON-119` P2 — File-tree search shows matches under collapsed ancestors
- `CON-14` P2 — Empty-state redesign
- `CON-79/80/81/82/83` P2 — agent tile/status foundation
- `CON-88/89` P2 — harness bridge contract + RunArtifactsReader

## 3. Recommended overnight queue

### Phase A — Safety and QA infrastructure first

#### A0. Human gate: remote / backup decision (`CON-109`)

Do **not** let an agent invent remote credentials. If Dylan can provide a remote, do this first. Otherwise the master must record in every Linear update that commits are local-only.

Allowed automated fallback if no remote is available:
- create no new remote;
- do not push;
- optionally make a local safety branch/tag only if Dylan explicitly authorizes.

#### A1. `CON-110` — `scripts/run-matrix.sh`

Why first: reduces overnight false positives and repeated command drift.

Scope:
- Add a single script that runs the current matrix.
- Include `--palette-captures-keys-over-browser-check` and `--note-click-focus-check`.
- Do not remove existing checks.
- No semantic changes to app behavior.

Suggested checks:
- `bash scripts/run-matrix.sh` exits 0.
- Existing manual matrix also exits 0 once after script lands.

Review needed: code + QA.

### Phase B — Highest-value small product fixes

#### B1. `CON-9` — Spawn placement / DD-009

Why: first-five-minutes issue, pure logic heavy, already specified in `docs/19 §3`.

Scope:
- `CanvasEngine.placementFrame(...)` pure first-fit placement.
- Wire `TileSpawner.spawn*` default positions.
- Add CoreChecks tables and `--spawn-placement-check`.

Risks:
- Must not reposition boot-restored tiles.
- Need full matrix after adding new check.

Review needed: code + QA.

#### B2. `CON-14` — Empty state redesign / DD-010

Why: Dylan is currently seeing confusing first-open UI. User-facing but bounded.

Scope:
- Improve `CanvasEmptyStateNSView` copy/layout per `docs/19 §4`.
- Clarify browser entry: button already says Spawn Browser; label with shortcut `⌘3`.
- Add `⌘K` hint and project path.
- Capture before/after screenshots.

Risks:
- Visual/manual evidence required.
- Do not implement recent-projects here.

Review needed: code + UX + QA.

#### B3. DD-004 / palette browser row (likely missing Linear issue or part of E2)

Why: Dylan explicitly asked “how do I get the browser tile?” Cmd-K lacks browser row.

Scope from `docs/19 §2`:
- Add `LaunchPaletteAction.newBrowser`.
- Palette row “New Browser”.
- Wire selection to `spawnBrowser`.
- Add/extend palette checks and app self-check.

Do **not** include full Open URL/default URL if time is low; split if needed.

Review needed: code + QA + UX.

### Phase C — App launch / PATH / first-click issues

These are high user pain but riskier than Phase B.

#### C1. Project/root launch state (`docs/18`, DD-005)

Symptoms observed:
- Finder/Dock launches likely have wrong cwd/PATH.
- Agent harness executables appear “not found” from app palette.

Scope should be scouted first. Do not implement blind.

Likely tickets:
- `CON-113` app menu/defaults-domain migration overlaps bundled app polish.
- E3 project registry/lifecycle issues may contain root picker work but were not in the top 100 query excerpt.

First overnight action here should be `code-scout` only.

#### C2. First-click activation / empty-state buttons

Symptom: “can’t click when I first open the app.”

Likely AppKit first-click activation / `acceptsFirstMouse` issue. Scout before code.

Do not fold into note DD-002 unless evidence shows shared root cause.

### Phase D — Agent harness bridge track

If Dylan wants overnight work to move toward “agents running all night in-app,” prioritize E11/E10 after the small daily-driver fixes.

Recommended order:
1. `CON-88` — Harness bridge contract doc.
2. `CON-89` — `RunArtifactsReader` in Core.
3. `CON-91` — FSEvents watcher.
4. `CON-92` — Run artifacts viewer tile.
5. `CON-94` — Spawn harness runs from palette.

Why: this creates read-only observability before launching/killing live agent processes.

## 4. Tickets to avoid overnight unless specifically assigned

Avoid without human availability:
- DD-002 note body click-focus: manual real-mouse repro still pending; lower priority per Dylan.
- Project lifecycle picker / locking if no clear plan read-through.
- `.app` bundling (`CON-112`, `CON-113`) if code signing/bundle behavior requires manual Finder testing.
- Multi-zone/workspace projects (E5–E8): larger architectural work, not a good overnight first pass.
- Agent process kill/spawn controls (`CON-94`, `CON-96`) until read-only artifact/status pieces land.

## 5. Linear update template

For every completed or stopped ticket, master should comment:

```md
Branch: feat/<topic>
Commit(s): <hash> <subject>

What changed:
- <files / behavior>

Verification:
```sh
<paste relevant matrix/script output summary>
```

Agent evidence:
- scout: <run-id>
- code review: <run-id>
- QA review: <run-id>
- UX review/manual: <run-id or PENDING>

Manual PENDINGs:
- <none or list>

Risks:
- Repo has no remote; commits are local only unless Dylan has pushed/backed up.
```

State transition suggestion:
- Move to “In Progress” when implementation starts.
- Move to “In Review” after matrix green and reviewers dispatched.
- Move to “Done” only after blockers resolved and commit exists.
- Leave in “Backlog” with comment if scouted/deferred only.

## 6. First-night recommended execution

If Dylan says “go,” recommended first night is:

1. Start with `CON-110` (`scripts/run-matrix.sh`).
2. Then `CON-9` spawn placement.
3. Then DD-004 palette browser row / browser spawn access.
4. If time remains, `CON-14` empty state redesign with screenshots.
5. If UI/manual evidence is unavailable, switch to `CON-89` RunArtifactsReader instead of visual work.

This sequence maximizes safety, fixes issues Dylan hit tonight, and builds toward autonomous agent visibility without jumping into the largest architecture tracks.
