# Agent Orchestration & the Distributed Canvas

Status: **settled direction — ticket-ready.** This is the canonical front door for the
distributed-canvas program: the durable, observable, remote-and-multi-device home for
Continuum's agents. Every fork is closed; the companion docs carry the deep detail and
the ticket map at the end carries the build order. If you are new to this work, read this
document top to bottom — it is meant to make the whole program legible in one pass.

The supporting documents:

- **`38-locked-decisions.md`** — the same decisions stated one-per-section with rationale,
  reversibility, and a concrete trigger to revisit. This overview folds their conclusions
  inline; that doc is where you go for "why exactly, and when would we change our mind."
- **`2026-06-30-orchestration-spikes/`** — three grounded spikes (session topology, sync
  model, agent readers) that pressure-tested the risky pieces against the real codebase and
  the real on-disk agent stores.
- **`2026-06-30-t3code-steal/`** — six code-grounded studies mining `pingdotgg/t3code` for
  the remote-reach, transport, managed-agent, and approvals patterns.
- **`38-cloud-devops-and-hosting.md`** — the money-and-plumbing guide: what each remote
  piece costs and which vendor box it runs in.
- **`38-ux-analysis.md`** — the UX layer: what the human sees and how each UX ticket proves
  it works.
- **`38-background/`** — the earlier, exploratory draft of this document, preserved for
  provenance. Nothing here needs to be read against it.

---

## Vision & the problem

Continuum is an infinite-canvas terminal and agent workspace. Tiles are meant to be cheap,
infinite panes; zones group them; a workspace is a fleet you glance at and steer. We want
that fleet to be **durable** (survives quits and restarts), **observable** (the app knows,
live, what every agent is doing without anyone telling it), **remote-capable** (agents can
run on a VPS, not just the laptop), and **multi-device** (observe and approve from an
iPhone). "Remote or local, everything tied together."

We got here by intertwining tmux deeply, which was the right substrate — but the *mapping*
between tmux and the canvas grew a few welds that now hurt:

1. **A tile is a tmux session, one-to-one.** Every new tile spins up a brand-new session:
   re-`cd` the directory, no shared environment, ceremony every time. Tiles were supposed
   to be light; instead each one is a heavyweight session.
2. **Two tiles can't share a session without mirroring.** Because tiles attach as ordinary
   tmux clients, two clients on one session show the *same* active window. The spatial
   "split" a user wants becomes a literal mirrored view.
3. **Not all shell tiles are agents — and we can't tell which are.** Some tiles run a plain
   shell; some run Claude Code, Codex, or Pi. The tile doesn't know what it's running, and
   the agent status the whole UI consumes is set by hand or mocked. We want detection that
   is automatic and effortless.
4. **No workspace-level knowledge of what's happening.** A workspace should know, as a live
   tree, what each tile is doing. The model for this already exists (`SidebarTree`) but is
   never rendered or fed.
5. **Everything is local.** No remote execution, no sync, no iOS.

The thesis of this program: these are not five problems. They are **three layers fused
together**, plus an observation gap, plus a sync gap. Separate the layers and the rest
falls out — including remote and iOS. This is **reshaping, not rebuilding**: the data model
already has the right seams. Only two lines of philosophy are wrong.

---

## The three-layer architecture, and the two welds

Continuum conflates three layers that want to be distinct:

1. **Spatial / canvas layer** — tiles, zones, positions, membership. Continuum's own model,
   pure Swift, nothing to do with tmux. *It wants to sync across devices.*
2. **Session / execution layer** — tmux sessions, windows, panes; the ptys; the running
   processes and agents. Persistent. *It wants to live local or remote.*
3. **View / binding layer** — which tile renders which pane (the ghostty surface ↔ pane
   binding). *Local to each client.*

Almost every pain above is two of these layers welded together:

- **Weld 1 — session identity *is* the tile id.** `TmuxSession.sessionName(tileId:)` yields
  `"continuum-<tileId>"`: one tile, one session, forever. This is the source of "new tile =
  new session = re-cd." It fuses Spatial to Session.
- **Weld 2 — ghostty attaches as a plain tmux client.** The wrap runs `tmux new-session -A`
  and ghostty forks the pty for it; tmux's renderer decides what an attached client sees, so
  two clients on one session mirror. It fuses Session to View.

The encouraging part is that the model already carries the correct seams beneath those two
bad lines: `Tile.runtimeRef` points *at* a runtime rather than being one;
`TerminalSessionDescriptor` has its own identity distinct from the tile id; and
`ZoneRuntimeController` already owns runtimes **per project**, ref-counted by `projectId` —
a natural home for "one session per project." Unwelding is a surgical change to the two
lines of philosophy, not a rewrite of the model.

**Unwelding weld 1 (the topology change).** A tmux **session belongs to a project**, and
each terminal tile is a **window** in that session; windows stay single-pane, always. A new
tile becomes `tmux new-window` in the project's session, inheriting the directory and shared
environment for free — the re-`cd` pain dies. The infinite canvas *replaces* tmux's
pane-splitting entirely: the gesture that in plain tmux splits a pane becomes, in Continuum,
"spawn a new tile." We never call `split-window`. tmux becomes a process host, a persistence
layer, and an observation surface — never a window manager.

**Unwelding weld 2 (de-mirror).** Each tile's ghostty surface attaches via a **grouped
session** that shares the project's windows but tracks its *own* active window, then pins
itself to that tile's window. Same attach mechanism ghostty already uses; the result is N
tiles → N distinct active windows → no mirroring, without ever touching tmux control mode.

---

## The decisions, settled

Six decision areas, ordered by dependency. A (topology) and C (agent awareness) are the
heart. Everything below is settled; the companion `38-locked-decisions.md` carries the
per-decision rationale and revisit triggers.

### A. Session topology — project = session, tile = window

A tmux session belongs to a **project**, keyed by project identity, owned by the existing
per-project `ZoneRuntimeController`. Each terminal tile is a single-pane window in that
session. The lifecycle rules are exact:

- **New tile** → `new-window` in the project session, with cwd set to the **focused tile's
  current directory**, falling back to the project root. This is a setting
  (`newTileCwd = inheritFocus | projectRoot | lastUsed`, default `inheritFocus`) that the
  owner may override.
- **Close one tile** → `kill-window` for that tile's window. A session dies when its window
  count hits zero.
- **App quit / restart** → the session survives; the client reattaches.
- **Project release** (its runtime ref-count reaches zero) → **detach, never kill.** Projects
  are shared across workspaces, so killing on release would silently reap live agents on a
  mere workspace switch. The idle reaper likewise reaps by detach, never kill, and never on
  disconnect.

**The make-or-break seam.** Once N tiles share one session, nothing implicit identifies
*which* window belongs to a given tile — the old `new-session -A` rebind collapses. So we add
a durable `tmuxWindowTarget` (the tmux `%pane_id`) to the session descriptor, **captured and
persisted synchronously at spawn**, with a dead-target → `new-window` fallback. Done lazily,
restarts silently re-create windows and the binding invariants break. There is no production
tmux-query code today, so this seam is built fresh and carefully.

**Ambient / group-zone tiles** (those with no project) live in a **per-workspace session**,
shipped behind the existing tested per-tile fallback for the first phase. Per-zone sessions
were rejected: they would depend on a group-zone membership write-path that does not exist in
production today. Membership is instead re-modeled as a property of the tile (see E), which is
what makes the per-workspace home clean.

**Migration.** On upgrade we do not try to fold live per-tile sessions into windows — that
path is fragile and the spike found no clean version of it. We **start fresh project
sessions**, accept a one-time agent restart, and show a one-time explanatory note. All new
binding flows through the captured-at-spawn window target.

Rebinding tmux's in-tile split keys to "spawn a new tile" is deliberately **not** done in the
first landing — if a user or program splits manually inside a tile it renders nested and is
their choice. That rebind is optional additive polish later.

### B. View binding — de-mirror with grouped sessions

Each tile's ghostty surface attaches with a grouped session named `continuum-view-<tileId>`,
grouped onto the project session `continuum-proj-<projectId>`, then `select-window` pins it to
that tile's window. A view session owns no windows of its own, so it is safe to kill on tile
close — cleanup never reaps project windows. The observer never drives `select-window` (it
reads, it never steers), so there is no race with per-view pinning.

Two tiles may **deliberately** view the same window — a shared view, like two OS windows on
one document. That is a feature, explicitly exempt from the no-mirror invariant, which only
governs *distinct* tiles that should show *distinct* windows. The default spawn still creates
a new window per tile; shared-view only results from a user pointing two tiles at one window
on purpose.

### C. Agent awareness — detect, don't declare (the heart)

**Every tile is observed identically; agent-ness is detected, never configured.** A tile's
kind stays `.terminal`; whether it is an agent, and which, is a runtime property the system
derives. This program ships agent awareness in **two additive tiers**, both feeding one status
vocabulary and one derivation function.

**The base tier — dotfile readers (ships first).** Because every tile is now a window in a
session, tmux cheaply tells us *what a tile is running* (`pane_current_command` → `zsh`,
`claude`, `codex`, `pi`) and *whether it's alive* (pane pid + `pane_current_path`). For *what
an agent is doing*, we do **not** scrape the terminal — agents already persist authoritative
session state on disk, so a thin per-agent `AgentStateReader` reads that store:

- **Claude Code** — the link is exact: pane pid → `~/.claude/sessions/<pid>.json` →
  `sessionId` → the events JSONL. Status from last event type, permission mode, title, mtime.
- **Pi** — the link is exact: `runId` is the run-dir basename under
  `<projectRoot>/.pi/agent-runs/`, already carried on the descriptor; an explicit
  `status.json` gives status directly. Reuse the existing run-artifacts watcher pattern.
- **Codex** — there is **no** pid or tty link. Link by newest-mtime rollout whose line-1
  `session_meta.cwd` matches the tile and whose timestamp is after the tile's recorded
  pane-start. If two live tiles share a cwd and resolve to the same rollout, show
  "codex (running)" with no deep status — never guess. If Codex ever exposes a session-id or
  env handle at launch, capture it at spawn like Pi's `runId` and skip the heuristic.

Readers extract **metadata only** — event type, mode, title, timestamps — never message
bodies. Detection prefers push (FSEvents) over polling, runs on explicit budgets (starting
defaults, owner-overridable: 250 ms debounce per file, 10 status-changes/min/tile, remote ssh
poll no more than every 5 s), and keeps tmux out of the status hot path. An agent with no
reader still appears — as `shell`/`unknown`, running-vs-idle from the process signal alone —
never a fabricated deep status. `agentKind` becomes a **closed enum**
(`shell | claude | codex | pi | managed | unknown`) so readers, adapters, and UI agree.

For Claude's `needsAttention`, the spike confirmed there is no file-derivable signal in
`bypassPermissions` mode. The concrete signal for an observed shell Claude is a
`Notification`/`Stop` **hook** installed (with one-time explicit consent) into
`~/.claude/settings.json` that writes a breadcrumb Continuum watches. Without the hook,
under-claim to `working`/`idle`. Read-only file-watching needs no consent; writing any hook
into an agent's config always does.

**The managed tier — driven agents (additive, later).** A second, additive **`.managedAgent`
tile kind** drives agents *headlessly* through structured protocols behind one adapter, ACP
first (one client reaches Cursor, Grok, Gemini, Zed), then `codex app-server`, then the Claude
SDK. It is a card-based structured transcript — message, tool-call, plan, and diff cards with
a status header and an inline approval dock — **not** a ghostty terminal, because these
protocols emit structured events, not a TUI. Shell tiles and readers **stay**; the managed
tier never replaces them, and a project can mix both freely. First landing is scoped to one
adapter (ACP), one provider proven end-to-end, and approvals wired.

The managed tier is what closes the attention gap authoritatively: **a pending approval *is*
`needsAttention`**, checked above "working" in the derivation function. Two approval regimes
never conflate. A managed agent surfaces an actionable dock (Approve / Approve-for-session /
Decline) plus an orange attention border plus a sidebar row plus a zone count; responding
dispatches a **symmetric** respond command identical on Mac and iOS. An observed shell tile
surfaces the same color and urgency but **no dock and no buttons** — the human answers in the
terminal. A permission request gets the dock; an agent *question* gets its own card with a
short answer field; both map to `needsAttention`.

**The activity tree is then almost free** — it is the existing `SidebarTree`, fed by the
observer instead of by mock data. Feed the tree builder from the observer's output, replace
the hardcoded rollup in the canvas zone chrome with the real signal, and render the sidebar.
This one tree is the keystone for three goals: the at-a-glance fleet view on the canvas, the
iOS payload (a phone needs this tree, not the 2D canvas), and the substrate for future
agent-to-agent awareness.

### D. Remote execution — a reach-path menu over SSH

A `Host` field on the project/workspace and a `RemoteReach` menu — `localhost | sshForward |
tailscale | tunnel` — model "how to reach a box plus a revival recipe," all converging on one
attach target. Continuum's twist versus a web app: we forward a **tmux attach**, which *is*
an interactive SSH command, so `sshForward` is `ssh -t <host> 'tmux new-session -A -s …'` with
**no `-L`/`-N`** — the attach is the remote command. Resolve hosts via `ssh -G` (reusing the
user's `~/.ssh/config` verbatim), harden with `ServerAliveInterval=15` /
`ServerAliveCountMax=3` to detect dropped links fast. Model the full menu but wire only
`localhost` + `sshForward` first.

Ghostty still forks a **local** pty (the ssh client); the session lives on the VPS, survives,
and is observed by the *same* reader mechanism as C, over the same ssh channel (`ssh <host>
tmux display`, `ssh <host> cat <store>`). Ship this as an **ssh-wrap first** — no Continuum
host daemon and no port-forwarding on the box yet; a daemon is cleaner long-term but is real
surface area a solo owner shouldn't carry until remote is load-bearing. A dropped link
degrades to **stale, never wrong**. Add **Tailscale Personal** (free) the moment iOS joins —
a tailnet peer is just an SSH host by its `100.x` name, folding into the `sshForward` path and
killing the public SSH port. Cloudflare Tunnel is not needed now (a VPS already has a public
IP). Auth runs on **every** path including loopback (never `if (localhost) skip`) so local,
remote, and iOS share one code path.

### E. Sync — make the spatial layer device-portable (gates iOS)

Put the project and workspace stores behind a **protocol** now, while the surface area is
small, so the backing can become a synced store without touching call sites. This ships no
visible feature but is the one retrofit-hostile piece and gates the entire multi-device story;
do it first for that reason.

**Sync only layer 1** — tiles, zones, positions, membership. Do **not** sync runtime bindings
or live pane state; a second device re-binds to panes locally. That separation is exactly what
makes "observe from iPhone" clean.

The sync **model** is a **hand-rolled deterministic op-log** (pure Swift, Lamport +
replicaId total order) — not an off-the-shelf CRDT. This makes convergence a theorem you can
fuzz and makes sync-boundary purity a *type-level* guarantee, because runtime handles are
simply not representable in the op enum. It re-models the spatial state accordingly:
**membership → a tile-level last-write-wins register** (not a separate group-zone list),
**z-order → a fractional index**, **delete → a tombstone**. Ordering is always logical, never
wall-clock. **Loro 1.x** (MIT, native movable list) is the documented fallback if contention
rises or iOS becomes a true concurrent editor — but it is not adopted speculatively: before
any reversal we measure the *real linked* app-size delta, not the FFI zip. The tripwire is
firm: write the convergence fuzz RED→GREEN *first*, before the real transport.

Sync and observation are split and enforced by a **type**: spatial state syncs bidirectionally
via the op-log; the activity tree is a **one-way projection** (host → observers,
snapshot-then-tail). A private, host-local **managed-agent session record** (keyed by tile id,
carrying the opaque resume cursor and the runtime payload — the natural **home for the
`tmuxWindowTarget`**) never syncs or projects; only the derived `AgentStatus` does.

The **transport** is **CloudKit private database first** — Swift-native, no server, no auth
code, a free offline queue and change-push, riding the owner's own iCloud quota. Map one
CloudKit record per logged op (idempotent upsert keyed by op id) plus a second record type for
the activity projection; use the private DB with no share so we never touch CloudKit's 2026
sharing bugs. A self-hosted WebSocket relay on the VPS is the documented upgrade behind the
transport seam, for when sub-second sync or a non-Apple client is needed. Commercial realtime
SaaS is rejected as wrong-fit.

**Identity** rides two channels. The sync leg leans entirely on the **iCloud account** — no
accounts, no session store to build. The control leg (typing into a remote pane, approving
from iOS, spawning on the VPS) uses **account-less device pairing**: a one-time pairing token
exchanged for a scoped bearer session, every message authorized against a `Scope` OptionSet.
Build the `Scope` enum in full now, grant the iPhone `.observe` only (a type-level guarantee it
cannot mutate spatial state), and defer the full pairing/ticket machinery until a control
channel ships. No user accounts until *different people* share a workspace.

**iOS scope** is **observer + approvals only** — a thin observer over the synced spatial +
activity projection, no 2D canvas, no spatial mutation (enforced by the scope type). It may
answer approvals via the symmetric respond command. **Push** is **APNS via a token `.p8` key**
(ES256 JWT over HTTP/2) sent directly from the host that detects attention (the VPS for remote
agents, the Mac for local) — no push service. It fires on *entry* into an interruptive or
terminal phase (`needsAttention`, `done`, `failed`), deduped by state identity, with a
metadata-only payload (no transcript bodies), a deep link validated on receipt, and four
user-toggleable categories (approval / input / completion / failure).

### F. Agent-to-agent communication — later, on the shared session

Deferred until the core loop is reliable. When it comes, it is an **app-level message bus**
keyed off the session/runtime layer — agents post structured messages, tiles and agents
subscribe, with the activity tree providing "who is doing what." It is never built on
screen-scraping. This program names the seam and stops there.

---

## Verification philosophy

Testability is an architectural property, not a later test suite — sync especially cannot be
retrofit-tested, and the store-protocol seam is retrofit-hostile. The doctrine already in
force holds: the matrix is **necessary but not sufficient**; every behavior change needs a
real-path check driving the true event path (never a happy-path bypass); every UI change adds
a non-degenerate visual gate (never "bytes > 0") and a dogfood snippet; every manifest carries
**measured values**, never `{passed:true}`.

Three primitives are designed into the layers from phase 0:

1. **A serializable snapshot at every seam.** Spatial state is already a Codable snapshot. A
   new `SessionTopologySnapshot` (read back from tmux: sessions, window/pane targets, cwd,
   foreground command) is the **reconciliation oracle** — what Continuum thinks it spawned vs.
   what tmux actually holds; most tmux bugs are drift between the two. An
   `ActivityTreeSnapshot` carries the tree *plus the evidence* behind each status, not just
   the verdict.
2. **Injectable substrate.** A `TmuxControl` protocol (real impl + in-memory fake) so logic
   tests need no daemon; a fake clock (wall-clock is banned in the core, as in workflow
   scripts, or time-based tests flake); a fake `Host` and a fake `SyncTransport`.
3. **The invariant spine — reused across every tier.** These survive refactors:

| # | Invariant | Where checked |
|---|---|---|
| I1 | Binding bijection: tile ↔ window one-to-one; no orphan window, no tile pointing at a dead target | core + real-path |
| I2 | No-mirror: distinct tiles map to distinct active-window targets (except a deliberate shared view) | real-path |
| I3 | No session leak: live sessions ⊆ live projects/zones; last-tile-close kills the session | real-path + topology snapshot |
| I4 | Sync convergence: any op order, any replica count → byte-identical state | core fuzz |
| I5 | Sync-boundary purity: the synced/projected payload carries no pid, pane target, host-local handle, or transcript body | core taint scan + type-level |
| I6 | Status soundness: every `working`/`done`/`needsAttention` is backed by fresh evidence; unknown ⇒ `unknown`, never a fabricated status | core golden + real-path |
| I7 | Snapshot round-trip: serialize → deserialize → equal, every layer | core |
| I8 | Restart survival: pid + window target + cwd preserved across a ghostty-client teardown | gated real-tmux |

**Logic** is proven by core checks (the status derivation table, the convergence fuzz, the
taint scan, the reader goldens). **Backend/topology** is proven by real-path checks against a
real tmux daemon (spawn a tile, run a sentinel long-lived process, tear down the ghostty
client, re-run the spawn path, assert same window target, same pid alive, cwd preserved) and by
the topology reconciliation snapshot; the sync layer additionally gets a transport fake that
can partition, reorder, delay, drop, and duplicate messages, plus a nightly soak that asserts
convergence over many random-op/random-network iterations. **UX** is proven by the three-part
contract from the UX doc — real event path, non-degenerate visual gate (the Component Lab is
the home for these), and a dogfood snippet — with the managed/iOS tickets additionally bound
by I5 (no bodies on the wire) and I6 (no fabricated status).

The single most important tripwire: **write the convergence fuzz RED→GREEN before the real
transport.** If the op-log cannot be made to converge cheaply, that is the signal to switch to
the Loro fallback — and it fires before any transport code is committed.

---

## Cloud, remote, sync, push & cost

The remote and multi-device half of this program is deliberately built so that **every
genuinely hard piece is free at a solo owner's scale**, and the only recurring costs are a
small VPS and the Apple Developer membership. The deep treatment — verified 2026 pricing,
ergonomics, and the reasoning behind each vendor choice — is in `38-cloud-devops-and-hosting.md`.
The story in brief:

- **The VPS.** The remote host's job is humble: a box you SSH into that runs tmux plus coding
  agents for hours and survives disconnects. RAM, not CPU, is the binding constraint (agents
  spawn language servers and test suites). The default is a **Hetzner CX32** (4 vCPU / 8 GB /
  80 GB, EU, ~$7.34/mo) — the price-performance leader with comfortable headroom. A US-based
  owner who dislikes the ~100 ms EU attach latency may override to a DigitalOcean 8 GB droplet
  (~$48, US region). Fly.io and Lightsail are wrong-fit or overpriced for a pet tmux box.
- **Reaching the box.** Plain hardened SSH is the phase-1 answer and needs no new software; the
  tmux attach *is* the SSH command, so no port-forwarding is involved. Tailscale Personal is
  free and is the single highest-leverage upgrade the moment iOS joins — it makes
  Mac ↔ VPS ↔ iPhone one private mesh and removes the public SSH port, folding into the same
  `sshForward` code path.
- **Sync transport.** CloudKit's private database is $0 to the developer (it rides the user's
  iCloud quota), needs no server and no auth code, and gives a free offline queue and
  change-push. Its seconds-latency is acceptable precisely because the *urgent* signal rides
  APNS, not sync. The self-hosted relay on the same VPS ($0 marginal) is the documented upgrade
  for sub-second sync or a non-Apple client. Ably/Pusher/Liveblocks are built for many-user web
  apps and lose to "$0 CloudKit."
- **Push.** The Apple Developer Program ($99/yr) is the unavoidable gate for push and
  distribution. Given that, a token-based `.p8` APNS key (never expires, one key for all your
  apps) sent directly over HTTP/2 from the host that already detects attention is a few dozen
  lines and $0 marginal — no push service needed for two devices.
- **Node sidecar.** The observe tier needs no Node at all (pure-Swift readers, $0). Node enters
  only when we drive the managed tier: bundle a Node runtime via SEA and reuse t3code's TS ACP
  / `codex app-server` / Claude-SDK drivers verbatim rather than re-implementing three
  evolving protocols in Swift. Cost is roughly +50–90 MB of app size and one documented
  sign/notarize step; on a remote agent the sidecar runs on the VPS you already pay for.
- **CI/CD & auto-update.** GitHub Actions free tier plus `notarytool` plus Sparkle (free) with
  the appcast on GitHub Releases; TestFlight for the iOS companion. The only variable cost is
  the macOS runner's 10× multiplier beyond ~10–20 builds/mo, with a free local-notarize escape
  hatch.

The headline: the whole solo stack is **≈ $15.6/mo all-in** (VPS ~$7.3 + Apple ~$8.25
amortized), with sync, push, auto-update, and identity all $0 — by design, not by accident. A
small team lands around $50–90/mo, dominated by choices (Tailscale per-user, VPS concurrency
headroom, CI volume) rather than necessities.

---

## The UX story

The UX layer is treated in full in `38-ux-analysis.md`; the essential shape:

- **One status vocabulary everywhere.** Six states — `working` (blue pulse), `needsAttention`
  (orange diamond, marching-ants border), `done` (green check), `stale` (gray hollow),
  `configuring` (teal), `idle` (ring) — render the *same* way on the canvas tile, the zone
  rollup, the sidebar, the iOS list, and the push. A glance means the same thing everywhere.
  The priority ladder is fixed: `needsAttention` wins over everything, and an unknown signal
  never fabricates `working`/`done` — this single rule is why the whole UX is trustworthy
  (orange never hides behind blue).
- **The activity surface is a persistent, resizable left dock**, default-visible and
  toggleable, width persisted. It is the render of the already-built sidebar view, fed by real
  observer data — the current workspace expanded, all workspaces shown, per-tile status rows
  and per-zone rollups. Clicking a row reuses the *existing* focus plumbing to pan the canvas
  to the tile; there is one "go to" story, not three.
- **The managed-agent tile is a structured transcript**, not a terminal — message, tool-call,
  plan, and diff cards, a persistent status header, and an inline approval dock. It reads as
  "an app view" even zoomed to a thumbnail, which is how a user tells managed from
  shell-running-claude at a distance. It is designed and visually gated in the Component Lab
  first, against a scripted fixture transcript.
- **Approvals are the loudest state.** A managed agent's pending approval surfaces as the
  actionable dock plus an orange attention border on the tile (a new trigger and color on the
  existing focus overlay) plus a sidebar row plus an ambient zone count. Responding is the one
  symmetric command shared by Mac and iOS. Shell tiles show the same urgency without buttons.
- **The iOS observer is a fleet list, not a canvas** — grouped `workspace → zone → agent`,
  sorted attention-first, tap into a read-only structured transcript, approve from the phone,
  and deep-link straight to the waiting agent from a push. It never hosts a session, and its
  observer scope makes "cannot mutate spatial state" a type-level guarantee.
- **Every UX ticket ships all three checks** — a real-path check driving the true event path,
  a non-degenerate visual gate (Component Lab is the home), and a concrete dogfood snippet
  ("open the app → do X → see exactly Y").

---

## The build plan, as phases

The program builds in dependency order. Earlier phases unblock later ones; foundations and the
retrofit-hostile seams come first.

- **Phase 0 — Foundations.** The store-protocol seam, the op-log core (with the convergence
  fuzz written RED→GREEN first), the sync/observation type split, the snapshot types, the
  injectable substrates, and the I1–I8 invariant spine — stood up before any behavior change,
  while the surface area is small.
- **Phase 1 — Session topology (A).** Project = session, tile = window; the `tmuxWindowTarget`
  capture-at-spawn seam; the private managed-agent session record; membership re-modeled as a
  tile register; migration; the reattach-and-replay acceptance contract.
- **Phase 2 — De-mirror (B).** Grouped view sessions, per-tile pinning, cleanup, and the
  deliberate shared-view exemption.
- **Phase 3 — Agent awareness base (C).** The pure status-derivation function, the observer, the
  reader registry, the concrete Claude/Pi/Codex readers, and the consent-gated Claude hook —
  replacing the mock rollup with real signal.
- **Phase 4 — Activity surface (C + the sidebar).** Render the live dock from the observer, jump
  reusing the existing focus resolver, configurable-first.
- **Phase 5 — Remote (D).** The `Host`/`RemoteReach` model, `sshForward`, and the observer over
  the ssh channel — later, Tailscale discovery.
- **Phase 6 — Sync & multi-device (E).** The CloudKit transport, the activity projection over
  it, the pairing/scope model, the iOS observer, APNS push, and the connection supervisor.
- **Phase 7 — Managed tier (C drive).** The adapter protocol and ACP driver, approvals →
  `needsAttention`, and the managed transcript tile — additive, above everything else.
- **Phase 8 — Agent bus (F).** Last, only once the core loop is reliable; the app-level bus
  seam.

---

## The ticket map

Every ticket in the program, grouped by phase, one friendly line each. Execution mode is one
of **autonomous** (a pure or real-path check fully proves it with no human eyes and no real
cloud or device — the overnight coder runs only these), **supervised** (needs a human eye on
the result — a visual gate, a UX judgment, a dogfood pass), or **needs-substrate** (needs a
real VPS, a real device, a real iCloud/APNS account, or a live agent to prove out).
Dependencies are stated in prose by name.

### Phase 0 — Foundations

1. **Store protocol seam.** Put the project and workspace stores behind a protocol so the
   backing can become synced later. *Autonomous.* Foundational; unblocks the sync work.
2. **Op enum & logged-op envelope.** Define the spatial op enum and the self-contained logged-op
   with a Lamport + replicaId clock. *Autonomous.* Depends on the store protocol seam.
3. **Membership as a tile-level register.** Re-model group-zone membership from a separate list
   to a last-write-wins register on the tile. *Autonomous.* Depends on the op enum.
4. **Z-order as a fractional index.** Re-model z-order from an array position to a fractional
   index so concurrent reorders converge. *Autonomous.* Depends on the op enum.
5. **Delete as a tombstone.** Re-model deletion as a tombstone rather than a removal. *Autonomous.*
   Depends on the op enum.
6. **Op-log apply & compaction.** Apply logged ops to spatial state and compact to a snapshot.
   *Autonomous.* Depends on the register/index/tombstone re-models.
7. **Convergence fuzz (RED→GREEN first).** The N-replica random-order convergence fuzz asserting
   byte-identical state — written before the transport. *Autonomous.* Depends on op-log apply.
8. **Sync/observation type split.** Distinct spatial-op vs activity-event types so neither can
   carry the other's payload; the activity store append/materialize. *Autonomous.* Depends on the
   op enum and the store protocol seam.
9. **Taint scan for sync-boundary purity.** A core check proving no pid, pane target, handle, or
   body appears in a synced or projected payload. *Autonomous.* Depends on the type split.
10. **Session topology snapshot type.** The reconciliation-oracle snapshot read back from tmux
    (sessions, window/pane targets, cwd, foreground command). *Autonomous.* Standalone foundation.
11. **Activity tree snapshot type.** The activity tree plus the evidence behind each status.
    *Autonomous.* Depends on the sync/observation type split.
12. **Injectable substrates.** A `TmuxControl` protocol with a real impl and an in-memory fake, a
    fake clock, a fake host, and a fake sync transport. *Autonomous.* Standalone foundation.
13. **Invariant spine harness.** Wire I1–I8 into the check harness with measured-value manifests so
    every later phase asserts against it. *Autonomous.* Depends on the snapshot types and substrates.

### Phase 1 — Session topology (A)

14. **Project session naming & ownership.** Key session names off project identity and give the
    per-project runtime controller lifecycle ownership. *Autonomous.* Depends on the store seam.
15. **New tile = new-window.** Spawn a terminal tile as a window in the project session instead of a
    new session. *Autonomous.* Depends on project session naming and injectable tmux control.
16. **Capture `tmuxWindowTarget` at spawn.** Add the durable window target to the descriptor and
    persist it synchronously at spawn — the make-or-break seam. *Autonomous.* Depends on new-window.
17. **Dead-target → new-window fallback.** When a persisted target is dead on rebind, fall back to
    creating a new window rather than silently orphaning. *Autonomous.* Depends on target capture.
18. **cwd inheritance policy.** New tile takes the focused tile's current path, else project root;
    behind the `newTileCwd` setting, default `inheritFocus`. *Autonomous.* Depends on new-window.
19. **Close tile = kill-window.** Closing one tile kills its window; the session dies at zero
    windows. *Autonomous.* Depends on target capture.
20. **Project release = detach, never kill.** Releasing a project detaches its session; it stays
    alive because projects span workspaces. *Autonomous.* Depends on close-tile lifecycle.
21. **Idle reaper = detach.** A reaper detaches stale, no-active-turn sessions — never kills, never
    on disconnect. *Autonomous.* Depends on project-release detach and the fake clock.
22. **Per-workspace session for ambient tiles.** Ambient/group-zone tiles live in a per-workspace
    session behind the tested per-tile fallback. *Autonomous.* Depends on project session naming and
    the membership register.
23. **Private managed-agent session record.** A host-local record keyed by tile id carrying the
    resume cursor and runtime payload (home for the window target), never synced. *Autonomous.*
    Depends on target capture and the type split.
24. **Lazy resume on focus.** On focusing a tile, adopt → resume from cursor → fail honestly, no
    eager re-spawn. *Autonomous.* Depends on the private record.
25. **Reattach-by-target + replay scrollback.** The I1/I8 acceptance contract: reattach by window
    target and replay persisted scrollback on-screen (implement the deferred no-op). *Needs-substrate.*
    Depends on the private record and target capture.
26. **Upgrade migration.** Start fresh project sessions on upgrade with a one-time restart and note;
    all binding via the captured target. *Supervised.* Depends on project session naming and target
    capture.

### Phase 2 — De-mirror (B)

27. **Grouped view session per tile.** Attach each ghostty surface via a `continuum-view-<tileId>`
    grouped session and pin it with select-window. *Autonomous.* Depends on project session naming.
28. **View-session cleanup on tile close.** Kill the view session when its tile closes; it owns no
    windows, so project windows are safe. *Autonomous.* Depends on grouped view sessions.
29. **No-mirror real-path check (I2).** Prove two tiles render two distinct windows of one session,
    not a mirror. *Needs-substrate.* Depends on grouped view sessions.
30. **Deliberate shared-view exemption.** Allow two tiles to view one window on purpose, exempt from
    the no-mirror invariant. *Autonomous.* Depends on the no-mirror check.

### Phase 3 — Agent awareness base (C: readers)

31. **`agentKind` closed enum.** Replace the free-typed kind with a closed enum
    (`shell | claude | codex | pi | managed | unknown`). *Autonomous.* Standalone.
32. **Pure status-derivation function.** One `deriveAgentStatus(signals)` with attention checked
    above working and unknown never fabricating a status. *Autonomous.* Depends on the enum.
33. **Status-derivation golden table (I6).** A table-driven core check binding each signal-set to its
    expected status, including attention-beats-running. *Autonomous.* Depends on the derivation fn.
34. **Kind classifier from tmux.** Classify a tile's foreground command into an `agentKind` via
    `pane_current_command`. *Autonomous.* Depends on the enum and injectable tmux control.
35. **`AgentStateReader` protocol.** The thin per-agent reader contract (kind / detect / locate /
    read). *Autonomous.* Depends on the enum.
36. **Pi reader.** Locate by `runId` under the project-local runs dir and read the explicit
    `status.json`. *Autonomous.* Depends on the reader protocol.
37. **Claude reader.** Link pane pid → session json → events JSONL; derive status from event type,
    mode, title, mtime. *Autonomous.* Depends on the reader protocol.
38. **Codex reader (recency + cwd).** Link by newest-mtime rollout matching cwd and after pane-start;
    show running-without-deep-status on same-cwd collision. *Autonomous.* Depends on the reader
    protocol and pane-start capture.
39. **Reader golden fixtures.** Recorded real stores for shell/claude/codex/pi replayed through the
    readers to decouple reader logic from live agents. *Autonomous.* Depends on the three readers.
40. **`SessionObserver` with budgets.** A per-project observer that runs detection, drives readers,
    writes `AgentStatus`, and enforces counters/debounce. *Autonomous.* Depends on the readers and
    the derivation fn.
41. **FSEvents push watch.** Prefer push over polling for the agent stores, reusing the run-artifacts
    watch pattern. *Autonomous.* Depends on the observer.
42. **Claude notification hook + consent.** Install (with one-time explicit consent) a hook that
    writes an attention breadcrumb the observer watches; under-claim without it. *Supervised.* Depends
    on the observer.
43. **Replace the mock rollup.** Swap the hardcoded zone-chrome rollup for the observer's real
    signal. *Supervised.* Depends on the observer.

### Phase 4 — Activity surface (C: the dock)

44. **Feed the sidebar tree from the observer.** Drive the tree builder's per-tile statuses from the
    observer output instead of mock data. *Supervised.* Depends on the observer.
45. **Render the left dock.** Show the persistent, resizable, default-visible left dock rendering the
    live tree. *Supervised.* Depends on feeding the tree.
46. **Dock toggle & width persistence.** A conflict-guarded keybind toggle and a persisted width,
    configurable-first. *Supervised.* Depends on rendering the dock.
47. **Jump-to-tile via existing focus.** Wire a sidebar row click into the existing focus resolver so
    the canvas pans to the tile. *Supervised.* Depends on rendering the dock.

### Phase 5 — Remote execution (D)

48. **`Host` / `RemoteReach` model.** The host field plus the reach menu (`localhost | sshForward |
    tailscale | tunnel`) modeling launch ⊥ access. *Autonomous.* Depends on project session naming.
49. **`sshForward` attach wrap.** Wrap the tmux attach as `ssh -t 'tmux …'` (no `-L`/`-N`), resolved
    via `ssh -G`, with keepalive flags. *Autonomous.* Depends on the host model.
50. **Remote attach real path.** Prove a real ssh path attaches a remote tmux session and survives a
    drop as stale-not-wrong. *Needs-substrate.* Depends on the `sshForward` wrap.
51. **Observer over ssh.** Read remote agent stores over the same ssh channel with the ≥5 s poll
    budget. *Needs-substrate.* Depends on the observer and the remote attach.
52. **ssh reconnect/backoff degradation.** Handle dropped links with keepalive detection and a
    graceful stale state. *Needs-substrate.* Depends on the remote attach.
53. **Tailscale discovery.** Discover tailnet peers via status json, cache 60 s, spawn on demand,
    folding into the `sshForward` path. *Needs-substrate.* Depends on the host model and remote attach.
54. **Bootstrap auth on every path.** Enforce auth on every reach path including loopback via a seeded
    bootstrap grant (never skip on localhost). *Autonomous.* Depends on the host model and the scope
    model.

### Phase 6 — Sync & multi-device (E)

55. **`SyncTransport` seam.** The transport protocol plus a fake that can partition, reorder, delay,
    drop, and duplicate. *Autonomous.* Depends on the op-log core.
56. **Transport fuzz & soak.** Drive convergence through the fake transport and a nightly random
    random-network soak recording max convergence latency. *Autonomous.* Depends on the transport seam
    and the convergence fuzz.
57. **CloudKit transport impl.** One record per logged op (idempotent upsert by op id) plus an
    activity record type; live tail via subscription; private DB, no share. *Needs-substrate.* Depends
    on the transport seam.
58. **Activity projection over transport.** Deliver the activity tree as a one-way snapshot-then-tail
    projection to observers. *Autonomous.* Depends on the type split and the transport seam.
59. **`Scope` OptionSet model.** The full scope enum such that an observe token cannot represent a
    mutation. *Autonomous.* Standalone.
60. **Pairing-token model.** A one-time, TTL, single-use pairing token exchanged for a scoped session,
    down-scope-only. *Autonomous.* Depends on the scope model.
61. **iOS observer app.** A thin observer over the projection rendering the attention-first fleet list
    and read-only transcripts. *Needs-substrate.* Depends on the projection and the scope model.
62. **iOS approve action.** The symmetric respond command answering approvals from the phone.
    *Needs-substrate.* Depends on the iOS observer and managed approvals.
63. **APNS push service.** A `.p8`-signed sender firing on entry into interruptive/terminal phases,
    deduped, metadata-only. *Needs-substrate.* Depends on the observer and the scope model.
64. **Deep-link validation.** Validate a `continuum://agent/<tileId>` link on receipt before
    navigating to the agent detail. *Needs-substrate.* Depends on the iOS observer and push.
65. **Notify categories setting.** Four user-toggleable notify categories, configurable-first.
    *Supervised.* Depends on the push service.
66. **Connection supervisor.** The reconnect state machine — connected only after socket-open and an
    initial config RPC, backoff schedule, offline snapshot cache, durable subscriptions. *Autonomous.*
    Depends on the transport seam or the iOS observer.

### Phase 7 — Managed tier (C: drive)

67. **`AgentAdapter` protocol + canonical event union.** The adapter contract
    (start/sendTurn/interrupt/respond/stop/streamEvents) and the canonical runtime event type.
    *Autonomous.* Depends on the derivation fn and the enum.
68. **Node sidecar bundling.** Bundle a Node runtime via SEA and reuse t3code's TS drivers, signed and
    notarized. *Needs-substrate.* Depends on the adapter protocol.
69. **ACP driver.** The first adapter implementation (ACP), starting a session and streaming turns
    into the derivation fn. *Needs-substrate.* Depends on the adapter protocol and the sidecar.
70. **Approvals → `needsAttention` (managed).** A pending approval becomes authoritative attention
    above working; a requestId-keyed pending store; the symmetric respond command. *Autonomous.*
    Depends on the ACP driver and the derivation fn.
71. **`.managedAgent` tile kind & transcript.** The new tile kind rendering the card-based structured
    transcript and status header. *Supervised.* Depends on the ACP driver; designed in the Component Lab.
72. **Approval dock & attention border.** The inline dock (Approve / Approve-for-session / Decline)
    and the orange attention variant of the focus border. *Supervised.* Depends on managed approvals
    and the transcript tile.
73. **Distinct waiting-for-input card.** A separate answer-field card for agent questions vs the
    approval dock, both mapping to attention. *Supervised.* Depends on the approval dock.

### Phase 8 — Agent bus (F)

74. **Agent message-bus seam.** Name and stub the app-level bus keyed off the session/runtime layer —
    seam only, no comms built. *Autonomous.* Depends on the observer and the activity tree; deferred
    until the core loop is reliable.

---

## Relationship to existing docs

- **`docs/34` (tmux shell persistence)** — revised here. Its "session = tile" decision is
  superseded by project = session / tile = window; "close = kill" is refined to kill-window;
  its no-control-mode decision and persistence machinery are kept.
- **`docs/35` (observability sidebar)** — subsumed and fed here. The activity tree *is* that
  sidebar; the missing source it called out is the observer. Render the tree, don't redesign it.
- **`docs/36` (browser deep-state)** — a sibling; unaffected, but benefits from the same store
  seam.
- **`docs/23` (multi-controller runtime)** — the per-project runtime controller is the home for
  both the project session and the observer; align there.
- **`docs/26` / `docs/37` / `docs/29`** — the visual-harness, real-path, and keybind doctrines
  that the verification philosophy and the UX contract enforce here.
