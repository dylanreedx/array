# Agent orchestration — implementation tickets

This folder is the buildable decomposition of the agent-orchestration program described in
[`../38-agent-orchestration-architecture.md`](../38-agent-orchestration-architecture.md).
Seventy-four tickets, each self-contained and grounded in real code seams, take Continuum
from today's single-session terminal canvas to a synced, observable, remotely-reachable,
agent-aware workspace. Read the overview first for the why; each ticket here is the how.

Every ticket carries an **execution mode**:
- **Autonomous** — provable by pure Core checks, real-path checks, and the matrix, with no
  human eyes and no real cloud/device. These are what the overnight loop runs unattended.
- **Supervised** — needs a human eye on a running UI (a visual gate / dogfood pass).
- **Needs-substrate** — needs a real VPS, a real device, a live agent, or an iCloud/APNS
  account to prove out.

Counts: **43 autonomous · 17 supervised · 11 needs-substrate · 3 unclassified** (see below).

## The phases

- **Phase 0 — Foundations** (`01`–`13`): the op-log core, the sync/observation type split,
  snapshot types, injectable substrates, and the I1–I8 invariant harness.
- **Phase 1 — Session topology** (`14`–`26`): project = tmux session, tile = window;
  capture the window target at spawn; detach-not-kill lifecycle; the private session record.
- **Phase 2 — De-mirror** (`27`–`30`): grouped view sessions so two tiles are two windows,
  not a mirror.
- **Phase 3 — Agent awareness (readers)** (`31`–`43`): the closed `agentKind` enum, the pure
  status-derivation function, per-agent dotfile readers, the observer, the activity feed.
- **Phase 4 — Activity surface** (`44`–`47`): the live left dock.
- **Phase 5 — Remote execution** (`48`–`54`): the `Host`/`RemoteReach` model, `sshForward`
  attach, observer-over-ssh, bootstrap auth on every path.
- **Phase 6 — Sync & multi-device** (`55`–`65`): the transport seam, CloudKit impl, activity
  projection, the scope + pairing-token model, the iOS observer, APNS push.
- **Phase 7 — Managed agents & bus** (`66`–`74`): the connection supervisor, the agent
  adapter + ACP driver, the managed-agent tile, approvals→needsAttention, the agent bus seam.

## Overnight-executable set (autonomous, in dependency order)

This is the queue the overnight loop works, top to bottom. A `[gaps]` tag marks a ticket whose
adversarial-review revise pass was cut short by a session limit during authoring — the ticket
is complete but may want a closer review eye when it comes up.

```
01-store-protocol-seam.md
02-op-enum-logged-op-envelope.md
03-membership-tile-register.md
04-zorder-fractional-index.md
05-delete-tombstone.md
06-oplog-apply-compaction.md
07-convergence-fuzz-red-green.md
08-sync-observation-type-split.md
09-taint-scan-i5.md
10-session-topology-snapshot.md
11-activity-tree-snapshot.md
12-injectable-substrates.md
13-invariant-spine-harness.md
14-project-session-naming.md
15-new-tile-new-window.md
16-capture-tmux-window-target.md
19-close-tile-kill-window.md
20-project-release-detach.md
21-idle-reaper-detach.md
22-per-workspace-ambient-session.md
23-private-managed-session-record.md
24-lazy-resume-on-focus.md
28-view-session-cleanup.md
30-shared-view-exemption.md          [gaps]
31-agentkind-closed-enum.md
32-derive-agent-status-fn.md
33-status-derivation-golden.md
34-kind-classifier-tmux.md
35-agent-state-reader-protocol.md
36-pi-reader.md
37-claude-reader.md                  [gaps]
39-reader-golden-fixtures.md         [gaps]
41-fsevents-push-watch.md            [gaps]
48-host-remotereach-model.md         [gaps]
54-bootstrap-auth-every-path.md      [gaps]
55-synctransport-seam.md             [gaps]
56-transport-fuzz-soak.md            [gaps]
58-activity-projection-transport.md  [gaps]
59-scope-optionset-model.md          [gaps]
66-connection-supervisor.md          [gaps]
67-agent-adapter-protocol.md         [gaps]
70-approvals-needsattention.md       [gaps]
74-agent-message-bus-seam.md         [gaps]
```

**Unclassified (excluded from the auto-queue pending a mode check):**
`25-reattach-replay-scrollback.md`, `38-codex-reader.md`, `68-node-sidecar-bundling.md` — their
execution-mode section didn't start with a recognizable tag; confirm the mode by hand before
adding to the queue (`38-codex-reader` is likely autonomous; `25` needs a real terminal; `68`
is a bundling spike).

How the loop runs this queue lives in [`_OVERNIGHT-RUNBOOK.md`](_OVERNIGHT-RUNBOOK.md);
progress is tracked in [`_PROGRESS.md`](_PROGRESS.md).
