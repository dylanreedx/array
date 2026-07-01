# Tickets — t3code steals (2026-06-30)

Authored to the `docs/37` contract style. Detail + code snippets live in the sibling
area docs (cited per ticket); these are bounded implementation contracts. Statuses are
honest: **implementation-ready** (buildable now), **conditional** (needs a named
prerequisite), **spike** (research/decision, output = a decision + follow-ups).

**The gating fork:** *DRIVE vs OBSERVE* agents. Group A ships **regardless** of it.
Group B is **fork-gated** on **T3C-02**.

---

## Group A — ready now (fork-independent)

### T3C-01 — Pure agent status-derivation function
Status: **implementation-ready** · Depends: — · Doc: `06`, `03` (`agentAwareness.ts:61/88`)

- **Goal:** one pure `deriveAgentStatus(signals) -> AgentStatus` that is the *single*
  source feeding the fleet view (and later push), so status is computed one way for both
  readers and (future) adapters.
- **Decision:** pure Core function; **attention/approval checked ABOVE `working`**
  (priority order, mirroring t3's `projectThreadAwareness`); unknown → `unknown`, never a
  fabricated `working`/`done`.
- **Seams:** new `Sources/ContinuumRevivedCore/AgentStatusDerivation.swift`; `AgentStatus`
  (`TerminalSessionDescriptor.swift:85`); wire `SidebarTreeBuilder(…, agentStatusesByTileId:)`
  (`SidebarTree.swift:134`) through it.
- **Acceptance (I6):** table-driven Core check — each signal-set → expected `AgentStatus`;
  a pending-attention signal beats a running signal; no input yields a fabricated status.
- **Stop:** do not ship if any path can emit `working`/`done` without a backing signal.

### T3E-01 — Split sync from observation (ActivityProjection), enforced by type
Status: **implementation-ready** (design contract for phase 0) · Depends: phase-0 store seam · Doc: `04`

- **Goal:** spatial state syncs via the op-log (bidirectional); the **activity tree is a
  one-way projection** (host→observers), snapshot-then-tail. Neither type can carry the
  other's payload.
- **Decision:** distinct `SpatialOp` vs `ActivityEvent` types; an `ActivityStore`
  (append → materialize activity read model). **I5 is type-level:** a runtime handle is
  unrepresentable in a `SpatialOp`; an `ActivityEvent` is unrepresentable in the synced
  op stream.
- **Seams:** Core (`ActivityStore`/`ActivityProjection`); the Decision-E store-protocol
  seam; `SidebarTree`.
- **Acceptance:** compile-level — synced op cannot hold `runtimeRef`/pane target;
  projection round-trips; snapshot-then-tail delivers gap-free; taint scan finds nothing.
- **Stop:** do not merge if the activity type and the spatial op type share a channel.

### T3E-02 — Two session stores: private `ManagedAgentSessionRecord` (home for `tmuxWindowTarget`)
Status: **implementation-ready** (folds into phase 1) · Depends: TOPOLOGY `tmuxWindowTarget` seam · Doc: `04`

- **Goal:** a private, host-local session record (PK `tileId`; opaque `resumeCursor` +
  `runtimePayload` incl. the `tmuxWindowTarget %pane_id`) that **never syncs/projects**,
  separate from the derived `AgentStatus` that does.
- **Decision:** capture `%pane_id` **synchronously at spawn**; lazy-resume-on-focus
  (adopt → resume → fail); idle reaper reaps stale-and-no-active-turn by **detach, never
  kill** (per TOPOLOGY).
- **Seams:** `TerminalSessionDescriptor` / new record; `TileSpawner` spawn/restart;
  `ZoneRuntimeController` (hosts resume + reaper).
- **Acceptance (I1/I8/I5):** `%pane_id` persisted before any teardown; restart rebinds by
  target (not by re-deriving a session name); reaper detaches; the private record never
  appears in a synced/projected payload.
- **Stop:** do not ship if binding still relies on `new-session -A` name re-derivation.

### T3A-01 — Reattach-by-stable-id + replay-scrollback acceptance contract
Status: **implementation-ready** · Depends: T3E-02 · Doc: `05`

- **Goal:** turn I1/I8 into a checkable contract modeled on t3's `(threadId,terminalId)`
  attach: reattach by `tmuxWindowTarget` + replay persisted scrollback on-screen.
- **Decision:** implement the deferred on-screen replay (`GhosttyTerminalRuntime.replayScrollback`,
  the no-op at `TileSpawner.swift:354-355`).
- **Seams:** `TileSpawner.restartTerminalTile`; `GhosttyTerminalRuntime.replayScrollback`.
- **Acceptance:** real-path check — spawn → sentinel process → teardown → reattach by
  target → manifest asserts `targetBefore==After`, `pidBefore==After`, cwd preserved,
  scrollback replayed.
- **Stop:** do not claim done on a bypassed executor or without the replay assertion.

### T3D-01 — `RemoteReach`/`Host` model + `sshForward` (tmux attach)
Status: **conditional** (on Decision A landing) · Depends: project=session (A) · Doc: `01`

- **Goal:** a `Host`/`RemoteReach` enum (`localhost | sshForward | tailscale | tunnel`)
  as "how to reach + optional revival recipe"; `sshForward` = `ssh -t 'tmux attach -t
  <session>'` (**no `-L`/`-N`**).
- **Decision:** model launch ⊥ access converging on one attach target; resolve hosts via
  `ssh -G`; set `ServerAliveInterval=15`/`ServerAliveCountMax=3`; `localhost` + `sshForward`
  first, `tailscale`/`tunnel` as follow-ons.
- **Seams:** `TmuxSession.wrap` (`TmuxSession.swift:12`); new `Host` type; the Decision-A
  attach target.
- **Acceptance:** `wrap` argv correct for `localhost` + `sshForward`; a real ssh path
  attaches a remote tmux session; keepalive flags present.
- **Stop:** do not add `-L`/`-N` unless a control-mode/daemon design lands first.

### T3SEC-01 — Pairing-token + `Scope` model (observer-only iOS = type-level)
Status: **implementation-ready** (model) / **conditional** (wiring) · Depends: — (model) · Doc: `02`

- **Goal:** a `PairingToken` (TTL, one-time) + `Scope` OptionSet (`.observe`, `.control`)
  such that an observer token *cannot represent* a mutation; auth on every path via a
  bootstrap grant.
- **Decision:** down-scope-only exchange (`requested ⊆ granted`); pairing token delivered
  as a URL **fragment** (never logged); wiring to a channel is deferred until an
  observer/control channel exists.
- **Seams:** new Core auth module; the control channel (later).
- **Acceptance:** exchange only down-scopes; an `.observe` session rejects any control op
  (enforced as far up the type system as Swift allows) + a runtime authorize check.
- **Stop:** do not add an `if (localhost) skipAuth` branch anywhere.

---

## Group B — fork-gated (pending T3C-02)

### T3C-02 — SPIKE: managed-agent tier + build fork
Status: **spike** · Depends: — · Doc: `03`, `06`

- **Goal:** decide (a) whether Continuum adds a **managed-agent tile kind** (drive)
  alongside terminal tiles (observe), and (b) if so, **Node sidecar** (reuse t3's TS
  drivers) vs **pure-Swift** protocol clients.
- **Output:** a decision + follow-on tickets; unblocks T3C-03/04, T3E-03.
- **Decide with:** ACP/`app-server`/SDK effort in Swift vs. bundling Node; process model;
  update cadence; how a managed tile renders (transcript view).

### T3C-03 — `AgentAdapter` protocol + ACP driver (ACP first)
Status: **conditional** (T3C-02 = drive) · Depends: T3C-02 · Doc: `03`

- **Goal:** port `ProviderAdapterShape` → `AgentAdapter` (`startSession/sendTurn/interrupt/
  respond/stop/streamEvents`) + a canonical `AgentRuntimeEvent`; implement **ACP first**
  (one client → Cursor/Grok/Gemini/Zed), then `codex app-server`, then Claude SDK.
- **Seams:** new managed-agent subsystem; events → `deriveAgentStatus` (T3C-01) → `AgentStatus`.
- **Acceptance:** an ACP agent starts, streams turns, and drives `AgentStatus` through the
  pure fn; interrupt/stop work; **only derived status/metadata** crosses the sync boundary
  (I5 — event bodies stay host-local).

### T3C-04 — Approvals → `needsAttention` (managed) + `AgentApprovalRequest`
Status: **conditional** (T3C-03) · Depends: T3C-03 · Doc: `06`

- **Goal:** a pending approval ⇒ `AgentStatus.needsAttention` (authoritative, managed-only),
  checked above `working`; the *same* status fn feeds the fleet view and push.
- **Seams:** `AgentApprovalRequest` type; requestId-keyed pending store; `deriveAgentStatus`
  (T3C-01); the approval respond command (symmetric across Mac/iOS).
- **Acceptance:** an approval request flips status to `needsAttention` above running;
  responding clears it; **shell-tile `needsAttention` is unaffected** (two regimes stay
  separate).

### T3E-03 — iOS observer (thin) + APNS push
Status: **conditional** (T3E-01 projection + T3C-04 for approval-push) · Depends: T3E-01, T3C-04, T3SEC-01 · Doc: `06`, `02`

- **Goal:** an iOS app that is a **thin observer** over the activity projection (not the
  canvas, not `runtimeRef`) with a **symmetric** `respondToApproval`; APNS push on entry
  into `needsAttention`/`done` (deduped, I5-redacted).
- **Seams:** iOS target; `AgentPushService`; T3E-01 projection; T3SEC-01 `.observe` scope.
- **Acceptance:** iOS renders the live activity tree; push fires only on status *entry*
  into the interruptive/terminal phases; an observer token cannot mutate.

### T3D-02 — `ConnectionSupervisor` for observers / remote-attach
Status: **conditional** (a remote/observer channel exists) · Depends: T3D-01 or T3E-03 · Doc: `05`

- **Goal:** port the supervisor state machine — `connected` only after socket-open **and**
  an initial config RPC; backoff `[1,2,4,8,16]s`; offline snapshot cache;
  `switchMap`-over-session durable subscriptions.
- **Seams:** the observer/remote transport client.
- **Acceptance:** drop/restore the link → auto-reconnect + re-subscribe; a stale cache
  never overwrites fresher live data (monotonic version guard).
