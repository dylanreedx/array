# Array docs

## Using Array

Public documentation is served at `/docs/` on the website. The Markdown in
[`user/`](./user/) is the single source; Astro renders it directly.

- [Start here](./user/overview.md)
- [Install and connect](./user/install.md)
- [Everyday workflows](./user/workflows.md)
- [Navigation](./user/navigation.md)
- [Every tile](./user/tiles.md)
- [Boards and task handoff](./user/boards.md)
- [Settings and customization](./user/settings.md)
- [Managed agents](./user/agents.md)
- [CLI connections](./user/cli-connections.md)
- [Canvas tools and prompting](./user/canvas-tools.md)
- [Compaction](./user/compaction.md)
- [Storage](./user/storage.md)
- [Troubleshooting](./user/troubleshooting.md)
- [Companion (coming soon)](./user/companion.md)

Authoring and source verification: [Website documentation](./internals/public-documentation.md).

## Working on Array

Orientation and non-negotiables: [AGENTS.md](../AGENTS.md) (root). Policy-level
hard rules are the same file — `CLAUDE.md` symlinks to it.

- [Architecture overview](./internals/architecture-overview.md)
- [Agent providers (pi, claude, codex)](./internals/providers.md)
- [QA: the matrix, self-checks, witnesses](./internals/qa.md)
- Workspace API v1 (CX-01) — the frozen contracts are the header of
  `Sources/ContinuumRevivedCore/WorkspaceAPI/WorkspaceAPIContracts.swift`; the
  host service is `Sources/ContinuumRevived/App/WorkspaceAPIService.swift`; the
  pi bridge is `Sources/ContinuumRevivedCore/AgentProviders/PiHostToolBridge.swift`
  plus `Resources/PiExtensions/continuum-workspace-tools.ts`. Design and status:
  `.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`.
- [Performance on the canvas](./internals/performance.md) — the traps that froze
  the Markdown tile, and how to get evidence instead of theories
- [Performance budgets](./internals/performance-budgets.md) — deterministic work
  counters, synthetic stress scenarios, and real-gesture frame statistics
- [Scalability TDD](./internals/scalability-tdd.md) — regression ratchets,
  complexity witnesses, hardware validation, and the staged canvas/agent plan
- [Infinite-canvas rendering research](./internals/infinite-canvas-rendering-research.md)
  — transferable Figma/game/map/Apple techniques and the AppKit-to-hybrid
  escalation ladder

### Runbooks

- [Release](../RELEASE.md) (repo root)
- [Versioning + release ledger](./VERSIONING.md)

### Program history

- [`38-tickets/`](./38-tickets/) — the ticket/program system every change is
  developed under. Stable paths (code comments cite them); the go-live program
  record is [`38-tickets/95-go-live.md`](./38-tickets/95-go-live.md).

### Forward plans

- [`.plans/`](../.plans/) — numbered plans for work that is designed but not
  started.
