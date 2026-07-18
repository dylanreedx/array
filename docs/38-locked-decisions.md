# Locked Decisions — Agent Orchestration & the Distributed Canvas

Status: **locked / ticket-ready — 2026-06-30.** This is the closing document of the
`docs/38` arc. Its one job: **close every open fork so the ~70 tickets have zero
guessing.** Everything upstream (`38-agent-orchestration-architecture.md`, the three
spikes in `2026-06-30-orchestration-spikes/`, the six steal-docs in
`2026-06-30-t3code-steal/`, `38-cloud-devops-and-hosting.md`, `38-ux-analysis.md`) was
*thinking*; this is *deciding*.

**How to read a decision.** Each one states the call, gives a one-paragraph rationale,
marks whether it is **reversible** (can we back out later without a rewrite?), and names
the **trigger to revisit** (the concrete event that should make us re-open it). Some
decisions are genuinely a matter of the owner's taste or a number that only real usage
can set — those are tagged **DEFAULT — owner may override**, and I still pick a sensible
reversible default so **no ticket is blocked waiting on Dylan.**

**The bias, stated once.** Simplest thing that serves *a solo owner first*, reversible
wherever possible, native/offline/Apple over SaaS. Where two paths tie, I pick the one
that ships sooner and can be swapped behind a seam later.

**The one meta-decision that shapes all others: OBSERVE first, DRIVE additive.** We keep
the dotfile **readers** for user-launched shell/terminal agents as the always-on base
tier, and we add the **managed-agent** tier as a *second, additive tile kind* behind an
adapter — not as a replacement. This is decision **D1** below and every other fork
resolves consistently with it.

---

## Reading map — which decision closes which open question

| Open question (from doc 38 "Open questions" + prompt) | Closed by |
|---|---|
| DRIVE vs OBSERVE agents | **D1** |
| Node sidecar vs pure-Swift drivers | **D2** |
| Sync model (CRDT vs op-log) | **D3** (confirms spike) |
| Sync transport (CloudKit vs relay) | **D4** |
| iOS client scope (observe-only vs control) | **D5** |
| Identity / account model | **D6** |
| iOS push mechanism | **D7** |
| Remote hosting tier + default reach path | **D8** |
| Remote: ssh-wrap vs host daemon | **D9** |
| Codex same-cwd collision disambiguation | **D10** |
| Claude `needsAttention` in non-bypass mode | **D11** |
| cwd-inheritance override policy for new tiles | **D12** |
| Observer file-watch budget + debounce; hook-install consent | **D13** |
| `agentKind` enum/registry vs free string | **D14** |
| Ambient/group-zone session ownership | **D15** (confirms spike) |
| Project-release kill vs detach | **D16** (confirms spike) |
| Rebind in-tile split keys to "new tile" | **D17** |
| Loro fallback: measure app-size delta | **D18** |
| Grouped-session naming / cleanup (Decision B open) | **D19** |
| Two tiles viewing the same window | **D20** |
| Activity surface form (dock/slide-over/HUD) | **D21** (confirms UX doc) |
| Managed tile: new kind vs mode | **D22** (confirms UX doc) |
| Approval regimes (managed vs shell affordance) | **D23** |
| `waiting_for_input` vs `waiting_for_approval` split | **D24** |
| Migration on upgrade (per-tile → project sessions) | **D25** |
| Snapshot/invariant harness scope for phase 0 | **D26** |

---

## The central fork

### D1 — DRIVE **and** OBSERVE (readers are the base tier; managed agents are additive)

**Decision.** Ship **both**, in this order and relationship: the **OBSERVE** tier
(per-agent dotfile `AgentStateReader`s over `~/.claude`, `~/.codex`,
`<projectRoot>/.pi`) is the **always-on base** for every user-launched shell/terminal
tile and ships first (phases 3–5). The **DRIVE** tier (a headless **managed-agent tile
kind** behind adapters) is a **second, additive tile kind** layered on top later — it
never replaces shell tiles or readers, and a project can mix both freely. Scope of the
managed tier at first landing: **one adapter (ACP), one provider path proven end-to-end,
approvals wired**, everything else follows.

**Rationale.** The readers are the honest, zero-config, zero-dependency way to light up
the fleet view for the agents Dylan already runs by hand — they need no Node, no
protocol client, no consent-to-install. That is real value *now* and it is the near-term
answer the whole phasing already assumes. The managed tier is where the genuinely new
product lives (structured transcript, **authoritative** status, approvals →
`needsAttention`, iOS-answerable), so it is worth building — but it is *more product than
plumbing* and depends on a Node runtime, so it is additive and later, not a prerequisite.
Doing both, in this order, means Group A tickets ship regardless and Group B is a clean
follow-on.

**Reversible.** Yes — the two tiers are independent tile kinds behind one status
function; either could be paused without touching the other.

**Trigger to revisit.** If the managed tier proves so much better that shell-tile
observation feels vestigial, consider making managed the default *spawn* for a
recognized agent (still keeping readers for anything launched outside Continuum). Or if
adapter maintenance becomes a tax with no payoff, freeze DRIVE at ACP-only and lean on
OBSERVE.

### D2 — Node sidecar (bundled via SEA) for drivers, **when** we drive; pure Swift until then

**Decision.** While observe-first (phases 3–5): **no Node, pure Swift readers** — this is
$0 and sidesteps bundling entirely. When we commit to the managed tier (D1's DRIVE half):
**bundle a Node runtime via SEA and reuse t3code's TypeScript ACP / `codex app-server` /
Claude-SDK drivers verbatim** — do **not** reimplement the protocols in Swift. On a
remote agent the sidecar runs on the VPS (where the agent + tmux already live), so it is
$0 extra hosting either way.

**Rationale.** The three drive-protocols (ACP, `codex app-server`, Claude SDK) are all
Node/TS and independently evolving; reimplementing them in Swift is a permanent
protocol-parity tax to save ~50–90 MB of app size and one documented sign/notarize step.
The break-even is clearly on the *bundle* side the moment we drive at all. ACP first is
the highest-ROI integration (one client → Cursor/Grok/Gemini/Zed). Cost analysis:
`38-cloud-devops-and-hosting.md` §5.

**Reversible.** Partially. The `AgentAdapter` protocol seam (T3C-03) is Swift; swapping a
Node-backed adapter impl for a Swift-native one later is possible per-provider, but the
decision to bundle Node at all is a real packaging change to unwind.

**Trigger to revisit.** If a first-class Swift ACP client appears (Apple or community),
or if the JIT entitlement / notarization friction becomes unacceptable, reimplement
ACP-only in Swift and keep Node for the long-tail protocols. Also revisit if app-size
becomes a distribution problem.

---

## Sync & multi-device

### D3 — Sync model = deterministic op-log (pure Swift, Lamport + replicaId)

**Decision.** Confirm the SYNC-MODEL spike verdict: a **hand-rolled deterministic op-log**
for the spatial layer — self-contained `LoggedOp`s + occasional compacted snapshots,
totally ordered by a logical (Lamport + replicaId) clock. This re-models the spatial
state: **membership → tile-level LWW register** (not the `groupZoneTiles` list),
**z-order → fractional index**, **delete → tombstone**. Never wall-clock ordering.
**Fallback:** Loro 1.x (MIT, native MovableList) if contention rises or iOS becomes a
true concurrent editor.

**Rationale.** An op-log makes **I4 (convergence) a theorem you can fuzz** and **I5
(sync-boundary purity) a type-level guarantee** (runtime handles are simply not
representable in the `Op` enum). Both are the difference between provable sync and
perpetual flakiness. It is contingent on low single-user contention — true for a solo
owner — and the tripwire is written into the phasing: **write the I4 convergence fuzz
RED→GREEN first**, before the real transport; switch to Loro if it can't go green cheaply.

**Reversible.** Yes, deliberately — the whole point of the `Op`/snapshot design plus the
`SyncTransport` seam is that Loro is a documented drop-in fallback.

**Trigger to revisit.** The I4 fuzz can't be made to converge cheaply; OR contention
rises (real concurrent multi-device editing); OR iOS becomes a writer rather than an
observer. Any of these → measure the Loro linked-app-size delta (D18) and switch.

### D4 — Sync transport = CloudKit private DB first; relay-on-VPS as the documented upgrade

**Decision.** **CloudKit private database** is the phase-1 transport (`$0`, rides the
user's iCloud). Map **one `CKRecord` per `LoggedOp`** (idempotent upsert keyed by `OpId`)
plus a second record type for the activity projection; deliver the live tail via
`CKSubscription` silent pushes. Use the **private DB with no `CKShare`** so we never touch
CloudKit's 2026 sharing bugs. Keep everything behind the Decision-E `SyncTransport` seam.
**Upgrade path (documented, not built):** a self-hosted WebSocket relay on the §1 VPS
(`$0` marginal) implementing the `02-transport-auth-pairing.md` pairing/scope model.

**Rationale.** CloudKit is Swift-native, needs **no server and no auth code**, gives a
**free offline queue + change-push**, and uses the owner's own iCloud quota. Its
seconds-latency is acceptable precisely because the *urgent* signal rides APNS (D7), not
sync. The op-log is deliberately transport-indifferent, so this is a reversible bet. Full
comparison (incl. why Ably/Pusher/Liveblocks are wrong-fit): `38-cloud-devops...` §3.

**Reversible.** Yes — the `SyncTransport` seam keeps the relay one refactor away.

**Trigger to revisit.** You need genuine sub-second sync (real concurrent multi-device
editing); OR you add a **non-Apple client**; OR you want the op-log authoritative +
replayable on a server you control. Then build the relay on the VPS you already pay for.

**REVISED 2026-07-18 (D4-R1) — relay promoted to the active transport.** The third
trigger fired, by owner decision: Dylan wants the op-log authoritative on a server he
controls and explicitly does NOT want device sync to require iCloud sign-in (raised
during phone-sync dogfood; see `_PHONE_SYNC_HANDOFF.md`). The deciding operational
evidence: an entire week of dogfood time went to Apple-stack friction — provisioning
profiles, entitlement wildcards, TCC, `CKAccountStatus` gating, and the private-DB
same-Apple-ID requirement — before our sync code ever executed end-to-end on a phone.
New shape: **self-owned relay** (D4's own documented upgrade path) becomes phase-1;
develop against localhost first (also fixes the simulator loop: no iCloud sign-in
anywhere), deploy to the §1 VPS once proven. Auth = the already-built pairing-token +
`Scope` model (the D6 control-leg machinery). APNS remains the urgent-signal channel
per D7 (no user sign-in involved). **CloudKit transport is PARKED, not deleted**: code
and checks stay behind the seam as the documented fallback; no further investment.
Plan and slices: `38-tickets/86-relay-sync-transport.md`.

### D5 — iOS client scope = **observer + approvals only** (never a spatial writer)

**Decision.** The iOS app is a **thin observer** over the synced spatial + activity
projection with **no 2D canvas**. It may **answer approvals** via the symmetric
`respondToApproval` command, but it **cannot mutate spatial state** (no move/resize/
create tiles, no drive-the-canvas). This is enforced by the **`Scope` OptionSet type**
(D6): an `.observe` token literally cannot represent a spatial mutation; approving is a
scoped control action on the *agent* channel, granted by the pairing.

**Rationale.** A phone's job is triage — *which agent needs me, let me act* — which is a
list, not a pinch-zoom canvas (`38-ux-analysis.md` §4). Observer + approve is the
smallest surface that delivers the payoff ("approve from your phone") while keeping the
sync model single-writer-simple (helps D3's low-contention assumption). Making it
type-level, not a runtime `if`, is what makes it trustworthy.

**Reversible.** Yes — "send a turn from the phone" or "steer" can be added later as an
additional scope without redesigning the observer.

**Trigger to revisit.** After the observer+approve loop is dogfooded and stable, if Dylan
wants to *steer* agents from the phone. Add a `.steer` scope then; keep spatial mutation
off iOS unless a real need appears.

### D6 — Identity = iCloud for the sync leg + account-less pairing/scopes for the control leg; **no user accounts** until multi-person

**Decision.** Two channels, each authorized by what fits it. **Sync leg (CloudKit):** lean
entirely on the iCloud account as identity — **build no `SessionStore`, no accounts**.
**Control leg (type into a remote pane, approve from iOS, spawn on the VPS):**
account-less **device pairing** — a one-time `PairingToken` (TTL, single-use) exchanged
for a **scoped bearer session**, every message authorized against a `Scope` OptionSet.
**Build the `Scope` OptionSet in full now**, grant the iPhone **`.observe` only**, and
**defer the full pairing-token / `wsTicket` machinery** until a control channel actually
ships. Auth on **every** path including loopback (never `if (localhost) skipAuth`). **No
Sign-in-with-Apple / user accounts** until *different people* share a workspace.

**Rationale.** For one person's own Apple devices, Apple *is* the identity provider and
you build nothing for sync. CloudKit can't carry control-channel capability, so the
t3code pairing/scope model covers that leg — and its scope *table* survives even if the
token machinery is deferred, so building the `Scope` enum now (cheap) makes iOS
observer-only a type-level guarantee (D5) from day one. Full synthesis:
`38-cloud-devops...` §7, `02-transport-auth-pairing.md`.

**Reversible.** Yes — adding Sign-in-with-Apple + CloudKit sharing later is additive; the
scope model is transport-agnostic.

**Trigger to revisit.** A **second person** needs to share a workspace across a different
iCloud account. Then add Sign-in-with-Apple + CloudKit sharing (and budget for the 2026
`CKShare` rough edges).

### D7 — iOS push = APNS via a token `.p8`, sent directly from the host that detects attention

**Decision.** Use **APNS** with a **token-based `.p8` auth key** (ES256 JWT over HTTP/2),
sent **directly from the host that already knows an agent needs you** (the VPS for remote
agents, the Mac for local) — **no push service** (no OneSignal/SNS/Firebase). Push fires
**on entry** into an interruptive/terminal phase (`needsAttention` for approval/input,
and `done`/`failed`), **deduped by state identity** (fire only on meaningful change).
**Payload is metadata only** (sanitized `phase` / `headline` / `detail` ≤160 chars with
failure text redacted / `deepLink`) — I5-clean, no transcript bodies. **Deep link
validated on receipt** before navigating; `continuum://agent/<tileId>` resolves to the
agent detail screen. Four user-toggleable notify categories (approval / input /
completion / failure), configurable-first.

**Rationale.** For a single user's two devices, a push *service* is pure overhead + a new
bill; a `.p8` never expires, covers all apps under the account, and the sender is a few
dozen lines living exactly where attention is detected (the SessionObserver /
managed-adapter). This is the urgent path that makes CloudKit's seconds-latency sync
acceptable. Setup checklist and JWT details: `38-cloud-devops...` §4.

**Reversible.** Yes — a push service could be introduced later if device-token
bookkeeping ever grows; the payload shape and dedup logic are unaffected.

**Trigger to revisit.** Many devices / users needing segmentation, or per-device token
management getting painful. Then wrap APNS with a service.

---

## Remote execution

### D8 — Remote host tier = Hetzner CX32; default reach path = `localhost`, then hardened SSH; Tailscale the moment iOS joins

**Decision.** **Default remote host: Hetzner CX32** (4 vCPU / 8 GB / 80 GB, EU,
~$7.34/mo) — **DEFAULT — owner may override** to a DigitalOcean 8 GB droplet ($48, US
region) if the ~100 ms EU attach latency annoys a US-based owner. **Default reach path:
`localhost`** for everything local; **hardened plain SSH** (`sshForward`) for the first
remote path — the tmux attach *is* an interactive SSH command, so **no `-L`/`-N`**:
`ssh -t <host> 'tmux new-session -A -s <session> …'`, resolved via `ssh -G`, with
`ServerAliveInterval=15` / `ServerAliveCountMax=3`. Model the full menu (`RemoteReach =
localhost | sshForward | tailscale | tunnel`) but **wire only `localhost` + `sshForward`
first**. **Add Tailscale Personal (free) the moment iOS enters** — it kills the public
SSH port and folds into the `sshForward` path (a tailnet peer is just an SSH host by its
`100.x` name; discover via `tailscale status --json`, cache 60 s, spawn on demand).
**Cloudflare Tunnel: not now** (a VPS already has a public IP — nothing to punch).

**Rationale.** RAM (not CPU) is the binding constraint for agents spawning language
servers + test suites; CX32's 8 GB is the comfortable solo target at the best €/GB, and
tmux-on-Ubuntu is exactly the ergonomic the reach layer assumes. Auth-on-every-path
(including loopback) via a seeded bootstrap grant is what lets local / remote / iOS share
one code path. Full option analysis: `38-cloud-devops...` §1–2.

**Reversible.** Yes — `Host` is a field on the model and the reach menu is an enum;
switching providers or adding Tailscale/tunnel is additive.

**Trigger to revisit.** iOS ships → add Tailscale. US latency bites → switch host region.
A NAT'd host with no public IP appears (e.g. agent on a home box) → add Cloudflare Tunnel.

### D9 — Remote transport = **ssh-wrap first**, Continuum host daemon deferred

**Decision.** Ship remote execution as an **ssh-wrapped tmux attach** (D8) first. The
**observer reads the remote agent's files over the same ssh channel** (`ssh <host> tmux
display …`, `ssh <host> cat <store>`). **Do not** build a Continuum host daemon on the VPS
yet, and **do not** add port-forwarding (`-L`/`-N`) — it only re-enters under tmux
control-mode or a host daemon, neither of which we're building now.

**Rationale.** ssh-wrap is faster to ship and needs zero new software on the box; a daemon
is cleaner long-term but is real surface area (its own auth, uptime, versioning) that a
solo owner shouldn't carry until remote is actually load-bearing. Degrade gracefully:
a dropped link makes status **stale, never wrong** (D8 keepalives detect it fast).

**Reversible.** Yes — the observer/transport is behind a seam; a daemon can replace the
ssh-wrap later without touching call sites.

**Trigger to revisit.** ssh observer-poll latency over the link becomes a UX problem at
scale, OR you want a control-mode socket / HTTP surface on the host. Then build the
daemon and revisit port-forwarding.

---

## Agent awareness (readers)

### D10 — Codex same-cwd collision: **spawn-time mtime capture wins; else show `codex (running)` without deep status; never guess**

**Decision.** Concrete rule for the no-pid-link Codex reader, applied in order:
1. **At tile spawn, record the pane-start timestamp.** When linking, scan
   `~/.codex/sessions/**/rollout-*.jsonl` newest-first by **file mtime**, read only line 1
   (`session_meta`), match `payload.cwd == tile.cwd`, and **prefer the rollout whose
   `session_meta.timestamp` is *after* this tile's pane-start** — that is the tile's
   session.
2. **If two live tiles share a cwd and both resolve to the same newest rollout**
   (indistinguishable from files alone): **accept one-of-N ambiguity** — show
   `codex (running)` from the process signal, **without per-session deep status**. Never
   attach a specific status to a possibly-wrong session.
3. **If Codex ever gains a `--session-id`/env handle at launch**, capture it at spawn like
   Pi's `runId` and skip the heuristic entirely.

**Rationale.** The AGENT-READERS spike verified there is *no* pid/tty link for Codex and
that same-cwd collisions are real (21 rollouts shared one cwd on the test machine).
Spawn-time capture disambiguates the common case; honest under-claiming (rule 2) upholds
I6 (never a fabricated status) for the rare simultaneous-same-cwd case. Rule 3 is the
clean exit if upstream ever helps.

**Reversible.** Yes — rule 3 supersedes 1–2 the day Codex exposes a handle.

**Trigger to revisit.** Codex ships a session-id/env handle at launch → adopt rule 3.

### D11 — Claude `needsAttention` in non-bypass mode: **hook-driven signal now; file-derivation only after a golden fixture proves it**

**Decision.** The **authoritative** `needsAttention` for a *managed* Claude agent is a
pending **approval** (D23) — always available in the managed tier. For an **observed
shell** Claude tile, the concrete signal is the **`Notification` hook**: install (with
consent, D13) a Claude `Notification`/`Stop` hook into `~/.claude/settings.json` that
writes a small breadcrumb file Continuum watches; that breadcrumb is the `needsAttention`
trigger. In **`bypassPermissions` mode the spike confirmed there is no file-derivable
attention signal**, so **without the hook, under-claim to `working`/`idle`** — never
fabricate `needsAttention` or `done`. A file-derived non-bypass signal is added **only
after** a recorded non-bypass golden fixture proves a reliable file marker exists.

**Rationale.** Fabricated attention is the worst failure (orange that isn't real destroys
trust). The hook is the one concrete, agent-blessed breadcrumb we can rely on across
modes; everything else under-claims honestly per I6. This closes the AGENT-READERS TBD
with a real signal (the hook), not a deferral.

**Reversible.** Yes — if a golden fixture later proves a file signal, add it as an
additional evidence source; the hook stays as the belt-and-suspenders path.

**Trigger to revisit.** A recorded non-bypass fixture demonstrates a stable file marker
for attention → add file-derivation alongside the hook.

### D12 — New-tile cwd inheritance: **focused tile's `pane_current_path`, else project root; owner-overridable default**

**Decision.** A new terminal tile's cwd is the **focused tile's `pane_current_path`**
(OSC-7), falling back to **project root** when there is no focused tile or its path is
unavailable. **DEFAULT — owner may override:** expose a setting `newTileCwd = inheritFocus
| projectRoot | lastUsed` (default `inheritFocus`), configurable-first (persisted default
+ Settings entry).

**Rationale.** Inheriting the focused tile's directory is what kills the re-`cd` pain that
motivated the whole topology change (a new tile lands where you were working). Project
root is the safe fallback. Making it a setting costs almost nothing and respects the
configurable-first doctrine.

**Reversible.** Yes — pure policy, changeable per-invocation.

**Trigger to revisit.** Dogfooding shows a different default feels better; flip the setting.

### D13 — Observer budget + hook-install consent: **explicit budgets, debounce, FSEvents push; one-time consent prompt before writing any dotfile**

**Decision.** The `SessionObserver` runs with **explicit counters/budgets** (events/sec,
status-changes/min) so it cannot thrash, **debounces** file-watch bursts, and **prefers
FSEvents push over polling** (reuse `RunArtifactsWatcher`'s pattern; tmux stays out of the
status hot path — detection/liveness is *occasional*, not per-tick). Concrete starting
budgets — **DEFAULT — owner may override**: debounce **250 ms** per watched file; cap
**10 status-changes/min/tile**; remote ssh observer-poll **no more than every 5 s**.
**Installing** any hook into `~/.claude/settings.json` (D11) requires a **one-time explicit
consent prompt** ("Continuum wants to add a notification hook to Claude so it can tell
when an agent needs you — Allow / Not now"); **read-only file-watching needs no consent**
(we only *read* the stores). Never write to an agent's config without consent.

**Rationale.** Polling N windows × ssh latency taxes every workspace if unbudgeted;
push + debounce + budgets keep it cheap and un-thrashy. Writing into another tool's config
is a trust boundary — consent once, then remember. Read-only watching touches nothing, so
it's free.

**Reversible.** Yes — budgets are numbers behind settings; consent is revocable (uninstall
the hook).

**Trigger to revisit.** Real-path perf checks show budgets are too tight (missed updates)
or too loose (CPU cost); tune. If Claude adds a first-class attention API, drop the hook
install entirely.

### D14 — `agentKind` = a closed enum/registry, not a free string

**Decision.** Replace the free-typed `agentKind: String` with a **closed enum / registry
key**: `shell | claude | codex | pi | managed | unknown`. Adapters, readers, and UI all
key off this enum. `unknown` is a first-class value (a detected agent with no reader shows
as `shell`/`unknown`, running-vs-idle from the process signal alone, never a guessed deep
status).

**Rationale.** A free string lets readers and UI silently disagree; an enum makes the
"which agent" contract explicit and exhaustively switchable, and gives `unknown` a real
home so under-claiming (I6) is representable. Adding a provider is one enum case + one
reader/adapter.

**Reversible.** Yes — adding a case is additive; the registry is designed for extension.

**Trigger to revisit.** A new agent type appears → add an enum case + its reader/adapter.

---

## Session topology (confirming the spikes, closing their sub-forks)

### D15 — Ambient / group-zone tiles → per-workspace session `continuum-ws-<id>`, behind a per-tile fallback for phase 1

**Decision.** Confirm TOPOLOGY: ambient/group-zone tiles (`ZonePlacement.projectId ==
nil`) live in a **per-workspace session `continuum-ws-<workspaceId>`**, shipped **behind
the existing per-tile fallback** for phase 1 (the tested kill-on-delete path). **Per-zone
sessions are rejected** — they'd depend on a `groupZoneTiles` membership write-path that
doesn't exist in production (`setTiles` is clear-only). Membership is re-modeled as a
tile-level LWW register per D3, which is what makes per-workspace clean.

**Rationale.** Per-workspace has a real owner and a real write-path; per-zone does not.
The per-tile fallback de-risks phase 1 (we keep the tested path while the new one proves
out).

**Reversible.** Yes — the fallback flag lets us stay on per-tile if the per-workspace path
misbehaves.

**Trigger to revisit.** If ambient tiles want zone-scoped shared env, revisit per-zone
*after* the membership register (D3) has a production write-path.

### D16 — Close tile = `kill-window`; session dies at 0 windows; **project release = DETACH, never kill**

**Decision.** Confirm TOPOLOGY / doc-38 #2: closing one tile → **`kill-window`** for that
tile's window; a session dies when its window count hits 0; app quit/restart leaves the
session alive (reattach). **Project release** (`ZoneRuntimeRegistry` → 0) → **DETACH, the
session stays alive** — projects are shared across workspaces, so killing here would reap
live agents on a mere workspace switch. The **idle reaper** (D-E) also reaps by **detach,
never kill**, and never on disconnect.

**Rationale.** Detach-not-kill is the only safe rule when projects span workspaces; killing
on release silently murders running agents. This is already the spike verdict; locking it
removes the last "kill vs detach" ambiguity from the tickets.

**Reversible.** Yes — lifecycle policy behind the runtime controller.

**Trigger to revisit.** If detached sessions accumulate and leak resources on the VPS, add
an explicit user-driven "reap detached" action (still never automatic-on-disconnect).

### D17 — Rebind in-tile split keys to "new tile": **not now (deferred, additive later)**

**Decision.** **Do not** rebind tmux split keys to "spawn a new tile" in the first
landing. The canvas replaces splitting (we never call `split-window`); if a *user or
program* splits manually inside a tile, it renders nested and is their deliberate choice.
Rebinding split-keys → new-tile is an **optional later polish**, additive when it comes.

**Rationale.** The core topology change (project=session, tile=window) stands on its own;
key-rebinding is ergonomics, not correctness, and shipping it early risks surprising users
mid-migration. Keep the first landing surgical.

**Reversible.** Yes — purely additive later.

**Trigger to revisit.** After the topology ships and is dogfooded, if manual in-tile splits
turn out to be a common accidental footgun.

### D18 — Loro fallback: **measure the real linked app-size delta before any op-log→Loro reversal**

**Decision.** The Loro fallback (D3) is documented but **not adopted speculatively**.
Before ever reversing from the op-log to Loro, **measure the real linked app-size delta**
(not the ~54–124 MB FFI zip — the actual linked binary contribution) as a gate on the
switch.

**Rationale.** The FFI zip size is misleading; the linked delta is what ships to users.
Measuring first prevents trading a solvable convergence bug for an unnecessary binary bloat.

**Reversible.** N/A — this is a measurement gate, not a shipped behavior.

**Trigger to revisit.** The moment D3's revisit-trigger fires (I4 won't converge, or iOS
becomes a writer) — measure, then decide.

### D19 — Grouped-session naming & cleanup: `continuum-view-<tileId>` off `continuum-proj-<projectId>`; cleaned on tile close

**Decision.** De-mirror (doc-38 B) via grouped sessions: each tile's ghostty surface
attaches with `tmux new-session -t <projectSession> -s continuum-view-<tileId>`, then
`select-window` pins it to that tile's window. **Naming:** view sessions are
`continuum-view-<tileId>`, grouped onto `continuum-proj-<projectId>`. **Cleanup:** the view
session is killed when its tile closes (it holds no windows of its own — killing it never
reaps project windows). The observer never drives `select-window` (it reads, it doesn't
steer), so no race with per-view pinning.

**Rationale.** A deterministic name keyed by `tileId` makes cleanup and reattach
unambiguous; grouped sessions give N tiles → N different active windows (no mirror) with
the same attach mechanism ghostty already uses. Killing a view session is safe because it
owns no windows.

**Reversible.** Yes — naming/cleanup is local wrap-layer policy.

**Trigger to revisit.** If grouped-session cleanup ever races the observer in practice,
serialize view-session ops through the runtime controller.

### D20 — Two tiles viewing the same window: **allowed, as a deliberate shared view**

**Decision.** Two tiles may intentionally view the **same** window of one session — treated
as a **deliberate mirror** (like two OS windows on one document), and **explicitly exempt
from I2** (the no-mirror invariant applies to *distinct* tiles that should show *distinct*
windows). The default spawn still creates a new window per tile (D-A); shared-view is only
what you get if a user deliberately points two tiles at one window.

**Rationale.** Accidental mirroring is the bug; intentional shared viewing is a feature.
Encoding the exemption in I2 keeps the invariant honest without forbidding a legitimate use.

**Reversible.** Yes — policy, not structure.

**Trigger to revisit.** If shared-view causes confusion, add a subtle "shared view" chrome
badge; no need to forbid it.

---

## UX (confirming `38-ux-analysis.md`, closing its flagged sub-questions)

### D21 — Activity surface = persistent, resizable **left dock**, default-visible, toggleable

**Decision.** Confirm the UX doc: a **persistent, resizable left dock** rendering the live
`workspace → zone → tile` tree (the already-built `WorkspaceSidebarView` fed by real
observer data, not the mock). **Default-visible** on first run, toggleable via a keybind
folded into the existing nav/leader scheme, **width persisted**. On a truly narrow window
it may *behave* as a slide-over (overlay) but its identity/default is a dock. Show **all
workspaces with the current one expanded** (cross-workspace attention matters for a fleet).
Jump-to-tile reuses the **existing `focus(tileId:)`** plumbing — one resolver for sidebar
click, leader-jump, and palette-jump. Configurable-first (default + Settings entry +
conflict-guarded binding).

**Rationale.** A HUD you must summon defeats "at a glance"; a slide-over occludes the
canvas you jump into; a dock matches Dylan's mental model and is the exact form already
implemented — choosing otherwise throws that away. This is the render of `SidebarTree`, not
a redesign.

**Reversible.** Yes — the toggle/width/expansion are all settings.

**Trigger to revisit.** If a workspace-level rollup glyph is wanted, add one
`SidebarAgentStatusRollup.make` over the workspace's tiles (already flagged as a cheap
later add).

### D22 — Managed-agent tile = a **new `Tile.kind` (`.managedAgent`)**, structured transcript, not a terminal

**Decision.** Confirm the UX doc: the managed-agent tile is a **new `Tile.kind`
(`.managedAgent`)** rendering a card-based structured transcript (message / tool-call /
plan / diff cards) with a persistent status header and an inline approval dock — **not** a
ghostty terminal surface. It is gated on the DRIVE fork (D1/D2) and is what that fork
produces. `.terminal` stays pristine for observed agents. Design and visually-gate it in
the **Component Lab** first, seeded with a scripted fixture transcript.

**Rationale.** Managed agents are headless and emit *structured events*, not a TUI — piping
JSON-RPC into ghostty would render frame noise and throw away the one thing the managed tier
buys you (structure you can label, collapse, and attach an approve button to). A new kind
keeps every `.terminal` code path off a boolean fork, and the AppKit card view is
snapshottable for the visual gate (unlike a live terminal).

**Reversible.** Partially — it's a real new view + input path; but it's additive (doesn't
touch `.terminal`).

**Trigger to revisit.** N/A for the kind choice; card typography/spacing is designed in the
Lab and iterates freely.

### D23 — Approvals: two regimes, never conflated — **managed = authoritative dock; shell = badge/border only, answer in the terminal**

**Decision.** A pending approval is the **authoritative** `needsAttention` source **for
managed agents only**, checked **above `working`** in the pure `deriveAgentStatus` fn.
**Two regimes, kept separate:**
- **Managed agent** (adapter, structured approval): `needsAttention` = pending approval,
  authoritative; surfaces an **actionable approval dock** (Approve / Approve-for-session /
  Decline) + orange marching-ants border + sidebar `needs you` row + zone-rollup count.
  Responding dispatches the **symmetric `respondToApproval(requestId:, decision:)`** —
  identical on Mac and iOS.
- **Observed shell tile** (user typed `claude`/`codex`/`pi`): `needsAttention` = the
  best-effort hook/file heuristic (D11), **no dock, no buttons** — same color/urgency, but
  the human answers **in the terminal**.

**Rationale.** Same color, same urgency, different affordance — because one can be answered
structurally and one can't. This closes the AGENT-READERS attention gap *for managed agents*
by owning the approval channel, while honestly limiting shell tiles to a signal, not a
control. The symmetric respond command is what makes "approve from your phone" one code
path, not a parallel implementation.

**Reversible.** Yes — the two regimes are independent; either affordance can evolve alone.

**Trigger to revisit.** If a shell agent ever exposes a structured approval channel (some
future CLI), promote its tile to the actionable-dock affordance.

### D24 — `waiting_for_input` gets a **distinct card** from `waiting_for_approval`

**Decision.** Keep the two waiting states **visually distinct**: a permission request
(`request.opened`) uses the **approval dock** (decision buttons); an agent *question*
(`user-input.requested`) gets its **own card style with a short answer field**. **Both** map
to `needsAttention` (same urgency, same push category-ish handling — see D7's four
categories, which already separate approval vs input).

**Rationale.** t3code keeps them separate and it's the better UX — "may I run this?" and
"what should I name it?" want different affordances (buttons vs a text field), especially on
the phone. Collapsing them would make one of the two feel wrong.

**Reversible.** Yes — pure view-layer distinction.

**Trigger to revisit.** If the distinction proves confusing in practice, unify under the
dock with an inline field.

---

## Migration & verification

### D25 — Upgrade migration: **start fresh project sessions; one-time agent restart with a note; bind via `tmuxWindowTarget`**

**Decision.** On upgrade to the project=session topology, **do not** try to fold live
`continuum-<tileId>` sessions into windows — **start fresh project sessions**, accept a
**one-time agent restart**, and show a **one-time note** explaining it. All new binding
goes through the captured-at-spawn **`tmuxWindowTarget` (`%pane_id`)** (the make-or-break
seam), with a dead-target → `new-window` fallback. Never silently orphan.

**Rationale.** Folding existing per-tile sessions into windows is fragile and the spike
found no clean path; a communicated one-time restart is honest and simple. Capturing
`%pane_id` at spawn is the seam that keeps I1/I8 intact — done lazily, restarts silently
re-create windows.

**Reversible.** N/A — it's a one-time migration; the note makes it non-surprising.

**Trigger to revisit.** N/A.

### D26 — Phase-0 harness: **snapshot at every seam + injectable substrates + the I1–I8 spine, stood up first**

**Decision.** Stand up the test primitives in **phase 0**, before any behavior change:
serializable snapshots at every seam (`SessionTopologySnapshot` as the tmux reconciliation
oracle, `ActivityTreeSnapshot` with the *evidence* behind each status, the existing Codable
`CanvasState`/`WorkspaceDocument`); injectable substrates (`TmuxControl` fake, fake clock,
fake `Host`, fake `SyncTransport`); and the **I1–I8 invariant spine** wired into the harness
so every later phase asserts against it. **Write the I4 convergence fuzz RED→GREEN first**
(the sync tripwire). Every UX-touching ticket additionally ships the **UX-testing contract**
(`38-ux-analysis.md` §5): a real-path check (no bypass) + a non-degenerate visual gate
(never `bytes>0`) + a dogfood snippet. Manifests carry **measured values**, never
`{passed:true}`.

**Rationale.** Testability is an architectural property, not a later suite — sync especially
cannot be retrofit-tested, and the store-protocol seam is retrofit-hostile. Standing the
harness up first is what makes every subsequent decision verifiable, and it's cheap to do
while the surface area is small.

**Reversible.** N/A — this is the foundation; it only grows.

**Trigger to revisit.** N/A — add invariants as new seams appear.

---

## What is explicitly out of scope (named so no ticket wanders in)

- **Agent-to-agent message bus (Decision F).** Deferred until the core loop is reliable.
  When it comes it is an app-level bus keyed off the session/runtime layer, **not**
  screen-scraping. Named only; no ticket beyond the seam.
- **Centralizing / event-sourcing the *spatial* layer** — rejected (op-log + offline-first
  win; a server-owned canvas kills the native feel).
- **A 60-method RPC surface** — rejected (our transport is narrow: op-log push/pull +
  activity projection stream + a few control messages).
- **Streaming pty *bytes* to a web renderer for the local path** — rejected; Continuum
  renders ghostty natively. The byte-stream pipeline applies **only to the iOS observer**.
- **Commercial realtime SaaS (Ably/Pusher/Liveblocks), push services, Fly/Lightsail for the
  VPS role** — rejected as wrong-fit/overpriced for a solo Apple-native tool
  (`38-cloud-devops...`).

---

## Relationship to the other docs

- **`38-agent-orchestration-architecture.md`** — the parent; this doc *locks* its
  Decisions 1–10 and closes its master "Open questions" list.
- **`2026-06-30-orchestration-spikes/`** (SYNC-MODEL, TOPOLOGY, AGENT-READERS) — the
  grounded backing this doc confirms (D3, D10, D11, D15, D16, D25).
- **`2026-06-30-t3code-steal/`** (6 area docs + `TICKETS.md`) — the managed-tier / reach /
  transport / approvals prior art this doc locks (D1, D2, D5–D9, D22–D24). The Group A / B
  ticket split there is unblocked by D1 (Group A ships regardless; Group B follows the
  DRIVE decision, now locked).
- **`38-cloud-devops-and-hosting.md`** — the money/plumbing backing for D2, D4, D6, D7, D8.
- **`38-ux-analysis.md`** — the UX backing this doc confirms (D5, D21–D24, D26's UX
  contract).

Every fork above is now closed. Tickets should cite the decision id (D#) they rest on;
none should need to guess.
