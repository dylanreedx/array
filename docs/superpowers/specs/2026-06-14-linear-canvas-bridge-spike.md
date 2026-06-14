# Linear ↔ canvas bridge spike (CON-97)

Status: spike finding, 2026-06-14

## Question

Can Continuum surface the Linear CON backlog in-app, and later dispatch an agent from a ticket row, without turning Linear into an unsafe second queue or leaking credentials?

## Findings

### Native Linear access

Use a Linear personal/API key for v1, stored outside project data:

- Preferred native credential: macOS Keychain service `continuum.linear.api-key`, account `continuum-revived` (already referenced by the product/ADR direction for the native app).
- Development fallback may read `LINEAR_API_KEY` from the process environment for self-checks and local dogfood, but the key must never be serialized to `canvas.json`, registry entries, qa artifacts, or logs.
- OAuth is not justified for v1. It adds callback handling, token refresh, consent UI, and a larger secret lifecycle before the tile has proven value. Keep OAuth as a follow-up only if this becomes a multi-user/distributed app need.

The repo already has an extension-side precedent for Linear access at `.pi/extensions/linear/index.ts`, but it uses a different keychain convention (`pi-linear-api-key`). The native app should not silently couple to that implementation detail; either migrate to the native service above or support both names explicitly with the native service winning.

### Existing canvas seams

The bridge is partly implemented already:

- `Sources/ContinuumRevivedCore/CanvasState.swift` has `TileKind.ticketQueue` metadata (`linearTeamKey`, `linearTeamId`, `linearQuery`).
- `Sources/ContinuumRevivedCore/LinearTicketQueue.swift` defines `LinearTicketQueueConfig`; `Sources/ContinuumRevivedCore/Registry.swift` persists it on `ProjectEntry.linearTicketQueue` for per-project team/filter mapping.
- `Sources/ContinuumRevivedCore/LinearTicketQueue.swift` maps fixture JSON into rows and sorts by Linear priority (`1` urgent before `4` low) then identifier.
- `Sources/ContinuumRevived/Canvas/TicketQueueTileNSView.swift` renders injected rows and an honest no-key/empty state.
- `Sources/ContinuumRevived/App/ContinuumApp.swift` materializes the queue tile when configured and has a row dispatch hook.

The main missing piece is live fetching: there is no native Linear GraphQL client or Keychain-backed loader feeding `TicketQueueTileNSView`.

### Read-only queue tile v1

Recommended v1 query shape:

- team: configured by `teamId` when available, falling back to `teamKey` only for display;
- states: Todo/In Progress/Done display is useful, but the autonomous-pool default should emphasize unstarted Todo and optionally In Progress;
- filters: project/epic, labels, text query, and blocked/unblocked status;
- fields: `identifier`, `title`, `priority`, `state { name type }`, `labels`, `project { id name }`, `assignee`, and blocking relations.

The current model lacks project/epic and dependency fields, so it cannot yet implement "unblocked highest-priority Todo" faithfully. Add those before claiming the queue tile is an autonomous source of truth.

No-key/offline behavior should remain a normal empty state: "No Linear API key configured" or "Linear unavailable" with no modal error and no launch failure.

### Dispatching an agent from a ticket row

The dispatch concept is viable and should reuse existing seams rather than invent a scheduler:

- `Sources/ContinuumRevivedCore/AgentKickoffPrompt.swift` already builds a docs/21/docs/22 kickoff prompt from a ticket identifier/title.
- `Sources/ContinuumRevived/App/ContinuumApp.swift` dispatches a row by spawning the `claude` terminal profile and sending the generated prompt.
- `Sources/ContinuumRevived/App/TileSpawner.swift` is the terminal spawn seam.

V1 dispatch should be single-ticket only, explicit user action only. Multi-select fan-out, Linear mutation/status syncing, model/role selection, and automatic Done transitions stay out of scope.

## Proposed follow-up tickets

1. **Native read-only Linear client** — Keychain/env credential resolution, GraphQL fetch, no-key/offline empty state, token redaction tests.
2. **Queue row eligibility model** — project/epic, assignee, label, blockedBy metadata; pure fixture checks for unblocked Todo sorting by priority and dependency depth.
3. **Wire live rows into ticketQueue tile** — async refresh with debounce/backoff, visible stale/error state, no launch blocking.
4. **Dispatch hardening** — visible spawn/send failure state; deterministic check that a rendered row produces the exact docs/21 kickoff prompt and targets one agent terminal.
5. **Optional OAuth research** — only after API-key dogfood proves the feature valuable.

## Security story

- Secrets live in Keychain or environment only.
- Tile metadata and registry config may store team/filter IDs, never tokens.
- Logs/artifacts record credential presence/absence and HTTP status classes only, not Authorization headers or raw GraphQL variables containing secrets.
- Fixture JSON should be committed for mapper tests; live Linear responses should be redacted before attaching as evidence.

## Recommended QA oracles

- Core mapper fixture: mixed priorities, states, projects, labels, assignees, and blockers maps to only eligible rows in deterministic order.
- Credential fixture: missing key returns an empty/no-key state without throwing through the UI path.
- Serialization check: saved canvas/registry files never contain `Linear API` token-shaped values.
- Dispatch prompt check: row → exact `AgentKickoffPrompt` payload includes docs/21/docs/22 instructions and the ticket identifier.

## Decision

Proceed with an API-key + Keychain read-only tile first. Treat OAuth, editing Linear, multi-agent fan-out, and automatic Linear status updates as follow-ups. The existing tile/prompt/spawn seams are sufficient for the spike recommendation; live fetch and eligibility metadata are the real gaps.

## Evidence inspected

- `Sources/ContinuumRevivedCore/LinearTicketQueue.swift`
- `Sources/ContinuumRevivedCore/AgentKickoffPrompt.swift`
- `Sources/ContinuumRevivedCore/CanvasState.swift`
- `Sources/ContinuumRevivedCore/Registry.swift`
- `Sources/ContinuumRevived/Canvas/TicketQueueTileNSView.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `.pi/extensions/linear/index.ts`
- `docs/21-agent-workflow.md`
- `docs/22-linear-master-overnight-workflow.md`
- scout artifact: `.pi/agent-runs/code-scout-20260614T023725Z-cc68fc/final.md`
