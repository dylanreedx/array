# Implementation + Testing + Observability Loop

**Status:** Draft
**Date:** 2026-06-05
**Purpose:** Define how implementation agents, test agents, and reviewers work together on UX fixes without false positives.

## Core Principle

Implementation and testing are coupled, but they should not collapse into self-belief.

Every implementation task should include:

1. a code change,
2. a deterministic QA oracle,
3. observable artifacts,
4. an independent review pass,
5. explicit remaining manual/visual checks.

The implementer may create tests, but another agent or the master session must verify that the tests actually prove the user-facing behavior.

## Agent Loop

```text
master session
  ↓ creates ticket + oracle expectation
implementer
  ↓ changes code + adds/updates QA
qa-reviewer
  ↓ runs tests, reads artifacts, challenges false positives
code-reviewer
  ↓ reviews diff and lifecycle/regression risk
ux-reviewer
  ↓ reviews UX evidence, says what is/isn't proven
human
  ↓ spot-checks or approves next step
```

## Observability Requirements

Agents need to know what is happening at any moment. Since screenshot capture may be unavailable until Screen Recording permission is granted, observability has two layers.

### Permission-free observability now

Use app-side and harness-side artifacts:

- QA run manifests: `qa-runs/<id>/manifest.json`
- verdicts: `qa-runs/<id>/verdict.md`
- stdout/stderr logs per gate
- app state snapshots:
  - canvas JSON
  - tile frames
  - active tile ID
  - first responder class
  - browser DOM state via JS evaluation where appropriate
  - text view layout/frame/visible glyph metrics
- event traces:
  - simulated click/key event names
  - responder chain target
  - before/after tile frames
  - before/after focus state
  - before/after tile counts
- crash diffs

This lets agents observe behavior without relying on screenshots.

### Visual/native observability later

Once Screen Recording/Accessibility are available:

- screenshots before/after actions
- AX tree dumps
- cursor/hover screenshots where possible
- `cliclick`/AX real-click flows
- optional OCR/visual diff for text rendering

## UX Issue Oracles

### Browser form typing

Proof required:

- browser tile seeded with deterministic form page,
- click/focus path executes through app/responder chain,
- normal key events are sent, not JavaScript value assignment,
- DOM `activeElement` is the input,
- input value equals sentinel text,
- JS event log contains `focus`, `keydown`, `beforeinput`, `input`,
- first responder class is recorded,
- palette/global shortcuts did not fire,
- tile count/frame did not unexpectedly change.

### Resize handles/cursors

Proof required:

- hit-test matrix over all corners/edges,
- visible corner affordance points map to corner resize intent,
- simulated drags mutate frame correctly:
  - bottom-right increases width/height,
  - bottom-left increases width/height and moves x left,
  - top corners are symmetric,
- non-handle body probes do not resize,
- tile content remains clickable outside handle zones.

Cursor proof is weaker without screenshots. Until visual capture works, assert hit zone/action alignment and record cursor rect definitions if inspectable.

### File tile rendering

Proof required:

- file preview loaded string matches fixture,
- text view frame is non-zero,
- scroll view/document view frames are non-zero,
- layout manager used rect is non-zero,
- visible glyph range includes first sentinel after layout,
- scroll-to-bottom reaches last sentinel for multiline file,
- unsupported files show readable error text,
- no stale content after load failure.

### Default sizing / scale

Proof required:

- production `TileSpawner` creates per-kind frames matching documented defaults,
- screen-space frames are recoverable at common viewport sizes,
- content area minimums account for chrome/nav/title bars,
- smoke/test seeded frames do not contradict production defaults unless marked test-only.

## Reviewer Roles To Add

### `implementer`

Can edit code. Must:

- state ticket being implemented,
- add/update QA oracle where feasible,
- run relevant checks,
- produce artifact-backed completion notes,
- explicitly list what remains unproven.

### `qa-reviewer`

Read-only. Must:

- run relevant QA,
- inspect artifacts,
- challenge false positives,
- verify test actually exercises production paths,
- refuse evidence based only on superficial state.

### `code-reviewer`

Read-only. Must:

- review diff,
- check AppKit lifecycle/focus/drag risks,
- compare against ticket scope,
- verify tests cover changed behavior.

### `ux-reviewer`

Read-only for now. Must:

- inspect UX evidence,
- say what user-facing behavior is proven,
- say what still needs human/manual/screenshot validation,
- later inspect screenshots/AX artifacts once available.

## Immediate Platform Tasks

1. Add project roles:
   - `.pi/agents/implementer.md`
   - `.pi/agents/qa-reviewer.md`
   - `.pi/agents/code-reviewer.md`
   - `.pi/agents/ux-reviewer.md`

2. Improve agent-run artifacts:
   - write clean `final.md` from agent stdout JSON,
   - write concise `summary.md`,
   - make `/agent-status` expose final artifact path.

3. Add QA observability helpers:
   - state snapshot writer,
   - first-responder/focus dump,
   - tile-frame dump,
   - browser DOM event-log fixture,
   - file text layout dump.

4. Start first implementation only with paired QA:
   - browser typing + `browser-form-typing`, or
   - file rendering + `file-tile-rendering` for a faster contained win.
