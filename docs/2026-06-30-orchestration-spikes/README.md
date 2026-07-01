# Orchestration Spikes — 2026-06-30

Three grounded design spikes feeding
[`../38-agent-orchestration-architecture.md`](../38-agent-orchestration-architecture.md).
Each resolves one of doc 38's open forks for a future implementing agent. The verdicts
are folded back into doc 38's decisions (see its **"Update — 2026-06-30 spike results"**
block near the top); these docs are the detailed backing.

- **[SYNC-MODEL.md](SYNC-MODEL.md)** — CRDT vs deterministic op-log for the spatial
  layer. **Verdict:** a hand-rolled op-log (pure-Swift, Lamport + replicaId), *contingent*
  on low contention + the I4 fuzz going green early; **Loro 1.x** is the fallback. Makes
  I5 a type-level guarantee; re-models membership / z-order / delete.
- **[TOPOLOGY.md](TOPOLOGY.md)** — project = session / tile = window pressure-test.
  **Verdicts:** ambient tiles → per-workspace session (+ per-tile fallback, phase 1);
  project-release → **detach, never kill**; capturing `tmuxWindowTarget` (`%pane_id`) at
  spawn is the **make-or-break** seam (no production tmux-query code exists today).
- **[AGENT-READERS.md](AGENT-READERS.md)** — grounded `AgentStateReader` spec from the
  real `~/.claude` / `~/.codex` / `<projectRoot>/.pi` stores. **Verdicts:** Claude & Pi
  links are exact; **Codex has no pid link** (recency-by-mtime + cwd, collision risk);
  Claude `needsAttention` is **hook-only** until a non-bypass golden fixture proves a
  file signal. Privacy: metadata-only, never transcript bodies (I5).

Status: spike output — research / decisions, not implementation-ready. To be locked
with Dylan, then authored into tickets per `docs/37`.
