# T3 Code — Steal Docs & Synthesis (2026-06-30)

Six focused agents mined **`pingdotgg/t3code`** (cloned read-only — "a minimal web GUI
for coding agents": Codex, Claude, Cursor, OpenCode, Grok) for patterns Continuum can
adopt, each compared against [`../38-agent-orchestration-architecture.md`](../38-agent-orchestration-architecture.md).

t3code is the architectural **inverse** of Continuum: one server owns *all* runtime;
thin clients speak **one authed WebSocket-RPC** and render pushed projections. So we do
**not** copy it wholesale — Continuum keeps native ghostty, the spatial canvas, and
offline-first. We steal specific, code-grounded mechanisms. Every area doc cites
`file:line` and separates verified-from-code from inferred.

## Area docs
1. [`01-remote-reach-paths.md`](01-remote-reach-paths.md) — the four reach paths + the *launch ⊥ access* decomposition → Decision **D**.
2. [`02-transport-auth-pairing.md`](02-transport-auth-pairing.md) — one authed WS-RPC, `wsTicket`, one-time pairing tokens, per-method capability scopes, DPoP → Decision **D/E** security.
3. [`03-provider-adapters-protocols.md`](03-provider-adapters-protocols.md) — `ProviderAdapterShape`, the 47-variant event union, Claude-SDK / Codex `app-server` / **ACP** / OpenCode drivers → Decision **C** (managed tier).
4. [`04-orchestration-sessions-projections.md`](04-orchestration-sessions-projections.md) — event-sourced CQRS, the private session record, lazy resume, the reaper → Decision **E**.
5. [`05-resilience-terminals-reconnect.md`](05-resilience-terminals-reconnect.md) — the `ConnectionSupervisor` + server-side pty attach/scrollback → Decisions **A/D** resilience.
6. [`06-agent-ux-approvals-mobile-push.md`](06-agent-ux-approvals-mobile-push.md) — status phases, approvals-as-`needsAttention`, the thin mobile observer, APNS push → Decision **C/E**.

**Tickets:** [`TICKETS.md`](TICKETS.md). **Folded into** `../38` (§ "t3code prior-art & refinements").

---

## The synthesis — one coherent picture

The stealable patterns cohere into a way to build Continuum's **remote + multi-device +
managed-agent** half *without* abandoning its native/offline/canvas core:

**1. Two data planes, separated by a *type*.** Spatial = op-log (bidirectional, syncs).
Activity/observation = **one-way projection** (host→observers), snapshot-then-tail. t3
enforces write-authority with types (client vs internal commands; only runtime ingestion
writes agent state), which makes **I5 type-level three ways**: scopes keep *capability*
off the device (02), command-type keeps *forged agent-state* out (04), event-body
exclusion keeps *transcripts* off the wire (03). → refines **Decision E**.

**2. Local ⊥ remote symmetry.** A reach-path *menu* — `RemoteReach = localhost |
sshForward | tailscale | tunnel`, modeled as "how to reach + a revival recipe," all
converging on one attach target — plus **auth on every path including loopback** via a
seeded bootstrap grant (never `if (localhost) skip`) = **one code path** for local,
remote, and iOS. Continuum's twist vs t3: we forward a **tmux attach**, not a WebSocket,
so `sshForward` = `ssh -t 'tmux attach -t <session>'` with **no `-L`/`-N`** (the attach
*is* the remote command; port-forwarding returns only under tmux control-mode or a host
daemon). → refines **Decision D**.

**3. Two session stores.** A private, host-local **`ManagedAgentSessionRecord`** (PK
`tileId`; opaque `resumeCursor` + `runtimePayload`) that **never syncs/projects** — the
natural **home for the `tmuxWindowTarget %pane_id`** that TOPOLOGY flagged as
make-or-break — separate from the derived, observable `AgentStatus` that *does* project.
Plus **lazy-resume-on-focus** (adopt → resume-from-cursor → fail-honestly, no eager
re-spawn) and an **idle reaper** (stale *and* no active turn, never on disconnect —
Continuum's twist: reap = **detach**, per TOPOLOGY). → refines **Decision E + A**.

**4. A managed-agent tier — additive, headless, a new tile kind.** t3 drives agents
headlessly via structured protocols (Claude SDK / `codex app-server` JSON-RPC / **ACP**
for Cursor+Grok / OpenCode HTTP) behind one `ProviderAdapterShape` + a canonical event
union + a **pure status function** (satisfies I6 by construction). For Continuum this is
a **new tile kind** (structured transcript + approval affordances), *not* "claude in a
terminal" — shell/terminal tiles + the dotfile readers **stay**. **Approvals are the
authoritative `needsAttention`** (a pending approval, checked *above* "running") — which
**closes the AGENT-READERS `needsAttention` gap, for managed agents only** (two regimes:
managed = approvals, shell = hook/file). **ACP is the highest-ROI integration** (one
client → Cursor/Grok/Gemini/Zed). Feeds the same iOS **APNS "your agent needs you"**
push. → extends **Decision C**.

**5. Resilience contracts.** Port t3's **`ConnectionSupervisor`** — `connected` only
after socket-open **and** an initial config RPC; backoff `[1,2,4,8,16]s`; offline
snapshot cache; `switchMap`-over-current-session durable subscriptions — for the iOS
observer + remote-attach control. And adopt "**reattach by stable id + replay persisted
scrollback**" as the *checkable acceptance contract* for Decision A's tmux binding,
turning I1/I8 from prose into a test (on-screen replay is currently the deferred no-op at
`TileSpawner.swift:354-355`). → refines **Decisions A/D**.

## The central fork (needs Dylan)

**DRIVE vs OBSERVE.** Driving agents (the managed tier) unlocks authoritative status +
approvals→`needsAttention` + push + the whole structured surface. Observing keeps us on
the dotfile readers + the Claude `Notification` hook. **Sub-fork if drive:** a **Node
sidecar** (reuse t3's TS drivers verbatim) vs. **pure-Swift** protocol clients (the
SDKs/ACP/app-server clients are all TS/Node). This gates the managed-agent tickets
(T3C-02…04, T3E-03). Shell tiles + readers ship regardless.

## What does NOT transfer

- **Don't event-source or centralize the *spatial* layer** — op-log + offline-first win;
  centralizing the canvas on a server kills the native feel.
- **No 60-method RPC surface** — Continuum's transport is *narrow* (op-log push/pull +
  activity projection stream + a few control messages), not a thin-client RPC API.
- **t3 streams pty *bytes* to a web renderer**; Continuum renders **ghostty natively**
  attached to tmux — the byte-stream pipeline + server-owned pty table apply only to the
  **iOS observer**, never the local path.
- Effect / SQL / Electron / Expo machinery is incidental.
