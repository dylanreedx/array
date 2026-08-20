# 98 — Sidebar location and transcript observability

## Live findings

The 0.5.3 production sidebar knew each managed agent's working directory through
`AgentRecord.cwd`, but `AgentContextIndex` deliberately discarded it. Rows only
painted `projectName`, so agents whose project join was absent had a blank
placement band even while the tile correctly reported its Home.

The production semantic transcript exposed four related failures during the same
live inspection:

- collapsed tool calls hid their only useful summary, leaving repeated `bash` or
  `read` strips with a terminal state but no observable action;
- a top-level tool disclosure persisted its state but the collection only
  remeasured disclosures owned by completed reasoning, so expansion could be a
  visual no-op;
- expanding a completed Thought near the bottom invoked stick-to-bottom policy
  and moved the reader away from the row they had just opened;
- native buttons were explicitly inserted into parent accessibility children
  without suppressing their internal accessibility child, producing duplicate
  disclosure, copy, and Jump-to-latest controls. A completed code block could
  consequently appear to expose a stale `Streaming` child even though the label
  was visually hidden.

## 0.5.4 resolution

- Carry only `URL(...).lastPathComponent` as `directoryName` through the local
  context and shared row. The full host path remains forbidden. The 96pt row
  prefers this working-directory identity and the hover card keeps project and
  directory as separate facts when both exist.
- Show a safe one-line compact tool summary while collapsed and up to four lines
  while expanded. Provider-local detail still passes through
  `AgentToolDetailPresenter.sanitizedProviderRecord`; opaque semantic arguments
  remain unavailable to the renderer.
- Route disclosure invalidation back to every top-level semantic owner, not only
  completed-reasoning owners, and preserve the current reader anchor regardless
  of near-bottom state for explicit disclosure actions.
- Make leaf AppKit buttons accessibility leaves and keep the parent semantic
  groups responsible for ordering them.

## Release gates

- Core context and inbox-builder checks assert directory basename propagation,
  absence of the full path, and terminal/project-less fallback.
- UI geometry asserts a visible collapsed summary, expanded line budget,
  top-level collection-row growth, disclosure-state persistence, and safe copy /
  accessibility output.
- The full Core, AgentUI, UI geometry, sidebar screenshot, production corpus,
  app-bundle, and release notarization gates must pass before publishing 0.5.4.
