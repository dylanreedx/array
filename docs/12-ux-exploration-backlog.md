# UX Exploration Backlog

**Status:** Draft
**Date:** 2026-06-05
**Purpose:** Capture rough UX issues and define an autonomous exploration phase before implementation.

## Current Read

The app is in a better base state than expected: Ghostty/terminal feel is promising, core smoke passes, and the roughness is mostly canvas/tile UX, browser input, sizing, and rendering polish.

Do **not** jump straight to autonomous implementation. First run an autonomous/manual exploration phase that produces evidence-backed tickets.

## Reported Issues

### UX-001: Resize handles/cursors are finicky and misleading

**User report:** Resize is inconsistent. Cursor changes, but often appears vertical-only. Dragging top corners can resize properly, bottom corners do not behave reliably.

**Likely area:**

- `Sources/ContinuumRevived/Canvas/TileNSView.swift`
- resize hit testing
- cursor rects
- bottom/corner drag math
- canvas coordinate transforms

**Exploration questions:**

- Which handles are recognized: top-left, top-right, bottom-left, bottom-right, edges?
- Does hit testing match cursor state?
- Are bottom corners covered by another view/overlay?
- Does viewport zoom affect handle math?
- Does tile content intercept bottom-edge events?

**Ticket target:** Make resize handles predictable, with correct cursor per edge/corner and symmetric behavior on all corners.

---

### UX-002: Default tile sizes / canvas scale are awkward

**User report:** Default tiles are too small/awkward. User is repeatedly resizing, zooming out, and resizing again to make windows sufficiently big. Need defaults based on realistic web page / terminal / file sizes.

**Likely area:**

- tile spawn defaults
- `CanvasState` seed defaults
- `TileSpawner`
- browser/note/file/file-tree default frames
- initial viewport/zoom

**Exploration questions:**

- What are current default sizes by tile kind?
- What dimensions feel right for terminal, browser, note, file, file tree?
- Should browser default closer to 1024×720 world units?
- Should terminal default target 100×30 chars?
- Should initial viewport zoom fit the default workspace better?
- Should new tiles spawn near viewport center with larger frames?

**Ticket target:** Define and implement per-kind default tile geometry and initial canvas scale.

---

### UX-003: Cannot type in forms in web/browser tiles

**User report:** Web tile forms do not accept typing.

**Likely area:**

- `BrowserTileNSView`
- `WKWebViewBrowserRuntime`
- focus routing
- event monitors in `ContinuumApp.swift`
- tile focus/z-order monitor
- command/global hotkey interception

**Exploration questions:**

- Does clicking inside WKWebView make it first responder?
- Are key events intercepted by canvas/app monitors?
- Does URL field accept typing while page form inputs do not?
- Does this fail for all web pages or only seeded/data pages?
- Is WebKit focus lost after tile bring-to-front reparenting?

**Ticket target:** Browser tile content inputs accept normal text typing after click/focus.

---

### UX-004: Terminal tile has weird click/dragging state persistence after defocus

**User report:** Terminal tile seems to retain weird click/dragging state after defocusing.

**Likely area:**

- `TileNSView.mouseDown/mouseDragged/mouseUp`
- `CanvasNSView`
- Ghostty terminal focus/blur
- local mouse monitor added for z-order/focus
- cursor push/pop state

**Exploration questions:**

- Does drag state remain active after mouseUp outside tile?
- Does cursor remain as drag/resize cursor after defocus?
- Does terminal still receive mouse events after another tile is focused?
- Is `mouseUp` missed when tile is reordered or window loses focus?
- Does the new tile-focus monitor on mouseUp interact with drag state?

**Ticket target:** Tile interaction state always resets on mouseUp, window resign, and focus change.

---

### UX-005: File tile does not render contents properly

**User report:** File tile content appears wrong/not properly rendered.

**Likely area:**

- `FileTileNSView`
- file loading cap / binary detection
- text view constraints
- scroll view/document view layout
- metadata path handling

**Exploration questions:**

- Is file content loaded but clipped/zero-height?
- Is font/color making text invisible?
- Is path wrong or relative path unresolved?
- Does this happen for all files or specific file types?
- Does smoke fixture file render correctly while real files fail?

**Ticket target:** File tiles reliably show readable text contents for supported plain-text files.

## Autonomous Exploration Phase

### Goal

Produce a clean backlog of tickets with evidence before implementation.

### Agent roles

#### `continuum-ux-scout`

Explores one UX area. Produces observations, reproduction steps, likely files, and proposed ticket.

#### `continuum-code-scout`

Reads code for one issue area. Produces probable root causes and minimal-risk fix options. Does not edit.

#### `continuum-qa-scout`

Finds or proposes a test oracle for one issue. Produces how to prove the bug and how to avoid false positives.

#### `continuum-triage-lead`

Combines scout outputs into prioritized tickets.

## Exploration Output Contract

Each issue exploration should produce:

```text
Issue ID:
User symptom:
Repro steps:
Observed evidence:
Expected behavior:
Likely files:
Hypotheses:
False-positive risks:
Suggested test oracle:
Suggested implementation ticket:
Priority:
```

## Prioritization

Suggested priority:

1. **UX-003 Browser form typing** — core browser usability blocker.
2. **UX-001 Resize handles/cursors** — core canvas manipulation blocker.
3. **UX-004 Terminal drag/focus state** — affects trust/feel of Ghostty surface.
4. **UX-005 File tile rendering** — core file surface correctness.
5. **UX-002 Default sizes/scale** — broad polish, should be informed by fixes above.

## Proposed Next Step

Run exploration agents in parallel, read-only:

```text
Agent A: investigate resize/cursor code paths
Agent B: investigate browser typing/focus code paths
Agent C: investigate terminal drag/focus state
Agent D: investigate file tile rendering
Agent E: survey default tile geometry and propose sizing system
```

No implementation until triage lead consolidates findings into tickets.

## Ticket Template

```text
[ux-finding][severity] Title

Symptom:
Evidence:
Repro:
Expected:
Likely root cause:
Acceptance criteria:
QA oracle:
Files likely touched:
Out of scope:
```
