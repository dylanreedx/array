# Ticket Authoring Style Guide

Status: adopted guidance

## Purpose
Future tickets must be written so a capable autonomous coding agent can implement them overnight without guessing, overreaching, or falsely claiming success.

A good ticket is not a brainstorm. A good ticket is an implementation contract:

- exact goal;
- exact scope;
- known code seams;
- explicit decisions;
- deterministic checks;
- artifact requirements;
- stop conditions.

If the ticket cannot meet that bar, it should be labeled as a spike/design task and must not be presented as implementation-ready.

## Core rule

> Do not leave important behavior for the implementing agent to decide.

Agents can choose local implementation details. They should not decide product semantics, UX thresholds, persistence policy, security boundaries, or what counts as done.

## Ticket statuses
Use one of these statuses clearly:

- `draft` — brainstorm; not ready for implementation.
- `spike` — research/design only; output is a decision doc or follow-up tickets.
- `implementation-ready` — bounded, testable, and safe for autonomous work.
- `conditional` — implementation-ready only if named prerequisite/guardrail is present.
- `blocked` — do not start until blocker is resolved.

Do not call a ticket implementation-ready if it still has unresolved UX/product questions.

## Required ticket sections

### 1. Goal
State the user-visible or system-visible outcome in one short paragraph.

Bad:

```md
Investigate terminal weirdness.
```

Good:

```md
Make terminal surface resizing idempotent so camera-only pan/zoom does not repeatedly resize the Ghostty grid.
```

### 2. Implementation decision
State the chosen approach. This prevents agents from inventing incompatible solutions.

Example:

```md
Implement the first safe slice: add a pure wheel normalizer, default precise multiplier to 1.0, and wire production scrollWheel through it.
```

### 3. Scope
List what is included.

Use bullets tied to concrete files, systems, or behaviors.

### 4. Out of scope / non-goals
Explicitly prevent drive-by work.

Example:

```md
Out of scope:
- full minimap;
- semantic zoom rendering;
- rewriting tmux mouse behavior;
- changing browser profile storage.
```

### 5. Code seams
Name likely files and symbols.

Example:

```md
Likely files/symbols:
- Sources/ContinuumRevived/Canvas/CanvasNSView.swift
  - setViewport(_:)
  - layoutTile(_:)
- Sources/ContinuumRevivedCore/CanvasEngine.swift
  - fit(...)
```

A ticket does not need to know every line, but it must give agents a starting map.

### 6. Product/UX policy
Include numeric defaults and explicit semantics where relevant.

Examples:

```md
mostlyVisibleAreaRatio = 0.75
tilePaddingScreenPx = 64
maxJumpZoom = 1.25
```

```md
Previous tile uses A↔B toggle semantics, not unbounded stack walk.
```

Never leave ticket text like:

```md
maybe do A or B
figure out whether this should persist
choose a sensible threshold
```

unless the ticket is explicitly a spike.

### 7. Acceptance criteria
Acceptance criteria must be observable and falsifiable.

Bad:

```md
- [ ] Scrolling feels better.
```

Good:

```md
- [ ] Default precise scroll input is not secretly doubled.
- [ ] App check records raw delta -3 and normalized delta -3 ± 0.001.
- [ ] Terminal input still works after synthetic scroll events.
```

### 8. Nightly QA contract
Every implementation-ready ticket needs a QA contract.

Include:

- required pure checks;
- required app/real-path checks;
- required artifact path;
- required manifest fields;
- reviewer rejection rules.

Example:

```md
Required app flag:
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --terminal-scroll-ergonomics-check

Artifact:
qa-runs/<timestamp>/terminal-scroll-ergonomics/manifest.json
```

### 9. Stop conditions
Tell the agent when to stop instead of improvising.

Examples:

```md
Stop / do not mark Done if:
- check bypasses production scrollWheel path;
- artifact omits measured raw/normalized deltas;
- terminal input breaks;
- visual fix is claimed without screenshot/video/manual PENDING.
```

Stop conditions are as important as acceptance criteria.

### 10. Verification commands
List exact commands.

Example:

```bash
swift build
swift run ContinuumRevivedCoreChecks
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --feature-specific-check
./scripts/run-matrix.sh --fast
```

If a check does not exist yet, the ticket should explicitly require adding it.

## Real-path evidence rule
For UI/input/navigation behavior, pure math tests are not enough.

Required pattern:

1. Pure/core test proves the model.
2. Real-path app check proves the user path.
3. Artifact records measured state.

Examples of real paths:

- synthesize real key events through the hotkey/leader path;
- invoke command palette action path;
- use production `scrollWheel(with:)`, not only a helper;
- drive `CanvasNSView.setViewport`, not only `CanvasEngine.fit`.

A reviewer must reject UI tickets that only test a bypassed executor.

## Artifact quality rule
Artifacts must contain measured values, never constants masquerading as evidence.

Good manifest fields:

```json
{
  "startViewport": {"x":0,"y":0,"zoom":0.3},
  "finalViewportErrorScreenPx": 0.2,
  "terminalAppliedResizeDelta": 0,
  "webViewCreationDelta": 0
}
```

Bad:

```json
{
  "passed": true,
  "looksGood": true
}
```

## Manual/PENDING rule
Manual or subjective UX evidence is allowed, but it must be honest.

Use:

```md
Manual PENDING: needs Dylan dogfood on trackpad scroll feel.
```

Do not write:

```md
Feels native now.
```

unless backed by manual notes or visual evidence.

## Security/privacy rule
Security-sensitive tickets must include explicit no-go boundaries.

Example:

```md
Do not read Chrome Login Data.
Do not store credentials in workspace JSON, logs, snapshots, or QA artifacts.
```

A ticket that touches credentials, browser profiles, shell processes, agents, external APIs, or persistence must include a threat/risk section.

## Performance/stability rule
If a ticket adds animation, polling, rendering, hydration, terminal/browser runtime changes, or background loops, it must include counters or budgets.

Examples:

```md
normal jump completes <= 300ms
active transitions <= 1
terminal applied resize delta during camera-only transition = 0
webview creation delta during transition = 0
```

## Dependency rule
If ticket B relies on guardrails from ticket A, say so explicitly.

Example:

```md
T07 animation must not ship until T12 terminal resize stability check exists, unless animation is disabled by default.
```

## Runner/overnight rule
For tickets intended for overnight automation:

- the working tree must be clean or intentionally checkpointed;
- branch/queue must be explicit;
- no scheduled watches should survive between Ralph loop iterations;
- every ticket must end with green checks or a clear stop reason;
- morning report must identify last ticket, stop reason, commits, checks, artifacts, and PENDING items.

## Prohibited wording in implementation-ready tickets
Avoid these unless the ticket is explicitly a spike:

- “investigate”
- “explore”
- “maybe”
- “decide whether”
- “think about”
- “as appropriate”
- “sensible default” without values
- “improve feel” without thresholds/evidence
- “fix flicker” without measurement or visual evidence requirement

Preferred wording:

- “implement first safe slice”
- “default is X”
- “out of scope is Y”
- “stop if Z”
- “required artifact contains…”
- “reviewer must reject if…”

## Implementation-ready checklist
Before sending a ticket to an autonomous agent, verify:

- [ ] Status is `implementation-ready` or clearly conditional.
- [ ] Goal is concrete.
- [ ] Scope and non-goals are listed.
- [ ] Code seams are named.
- [ ] UX/product decisions are made.
- [ ] Numeric thresholds/defaults exist where needed.
- [ ] Acceptance criteria are falsifiable.
- [ ] Required checks are named.
- [ ] Artifact path/schema is specified.
- [ ] Stop conditions are specified.
- [ ] Verification commands are listed.
- [ ] Manual/PENDING gaps are allowed only honestly.
- [ ] Dependencies/blockers are explicit.

## Template

```md
# TXX — Title

Status: implementation-ready
Tag: [area] [risk]
Depends on: —
Blocks: —

## Goal
<User/system outcome.>

## Implementation decision
<Chosen first safe slice. No unresolved behavior choices.>

## Scope
- ...

## Non-goals
- ...

## Code seams
- `path/file.swift`
  - `symbol`

## Policy / defaults
```text
constant = value
```

## Required implementation
1. ...
2. ...
3. ...

## Acceptance criteria
- [ ] ...

## Nightly QA contract
Required checks:

```bash
...
```

Required artifact:

```text
qa-runs/<timestamp>/<check>/manifest.json
```

Minimum manifest fields:

```json
{}
```

## Stop conditions
Do not mark Done if:
- ...

## Verification commands
```bash
swift build
swift run ContinuumRevivedCoreChecks
./scripts/run-matrix.sh --fast
```

## Manual/PENDING
- ...
```
