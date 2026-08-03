# Sidebar unification + status truthfulness — findings

Drafted 2026-08-03 at the P5.5 supervised gate from three read-only audits (loop progress,
inbox row UI, inbox status data-flow). **Findings only — nothing changed.** Companion to
`plan-P5.5-review-corrections.md` and `plan-P5.5-composer-action-consolidation.md`; the owner's
screenshot showed the sidebar exhibiting the same defect *classes* those plans fixed on the
canvas, plus a status-staleness problem the canvas fixes cannot reach.

---

## Part 0 — where the program stands

- **Queue 91: 48 done / 1 blocked / 1 pending (of 50).** Pending: `P5.5-final-supervised-acceptance.md`
  (state cell literally `pending`; the guard forbids in-progress rows with commits). Blocked:
  `P5.3-provider-current-work-projection.md`.
- **P5.5 remaining close-out** (packet steps 5–6): after explicit owner approval — flip the v2
  default, prove no old view callers, delete the legacy card path/flag in the packet's removal
  order, re-run every visual + I5 gate, focused checks ×5, full headless matrix, **supervised
  surface matrix** (`CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh` leg has not been
  run this session), ledger row → `done | this commit | <UTC>`, heartbeat rewrite, one local
  commit (`feat(agent-tile): …`, owner identity, never push), program guard green.
- **P5.3 unblock:** requires work that does not exist yet anywhere in the repo — the compiled
  boundary still carries only `itemStarted/itemCompleted` with no todo/plan snapshot payloads;
  `PiEventTranslator` maps no plan/todo; Queue 90 is 82/82 done with nothing queued that adds
  the capability. Unblocking means authoring new runtime-side work (a Queue 90 successor), not
  re-running the loop.
- **The loop is stopped** (`supervised-required:P5.5-final-supervised-acceptance.md`, no
  loop.pid, STOP file absent). It cannot restart today because the tree is dirty with this
  gate's work (only `website/`, logos, and the 92-relay files are allowlisted). After P5.5
  closes, a restart immediately reports `queue-drained` — P5.3 is never auto-retried — so
  restarting is a formality.
- **After 91:** Queue 92 (`92-small-team-relay/`, 50 packets fully authored, 0 started; gated
  on 91 reaching a clean committed stop and its own separately-committed preparation) and
  ticket 93 (`93-global-border-audit.md`, all borders ≤ 0.5 pt + a named width token,
  explicitly sequenced after P5.5 acceptance). A preserved queue-91 dirty candidate from
  `run-20260730T225228` (P4.6) is named in 92's pre-arm checklist as needing resolution.

## Part 1 — sidebar row UI (`AgentInboxView.swift`, ~4,200 lines, in NO packet's fence)

The load-bearing process finding first: **P3.12's owner correction — "sidebar/inbox rows
without grey perimeter borders around every idle surface" — was recorded against packets
whose file fences cannot touch `AgentInboxView.swift`.** The correction is locked into
P5.5's "done when" text, but no packet in Queue 90 or 91 fences the file that draws the rows.
That is how the sidebar was left behind while the canvas moved.

### (a) Title truncation ("openai-codex/g…")

Three compounding causes (`AgentInboxView.swift`):

1. **Deliberate priority inversion:** `titleLabel` is the ONLY compressible element in the
   headline — its compression resistance is explicitly lowered to 250 (`:3756-3762`, comment
   says truncate the agent's name before the project) while disclosure/state/elapsed are
   `required` and the project chip sits at 750. The title absorbs 100% of any deficit.
2. **Arithmetic:** at the real default sidebar width (280 pt;
   `WorkspaceSidebarConfig.swift:11`) the headline budget left for a 15 pt semibold title is
   ~80–100 pt ≈ 11–13 characters — exactly `openai-codex/g…`. The committed
   `chrome.agentInbox` baselines already contain a truncated title (`claude · child w…`) —
   **the defect is blessed.**
3. **Same class as the composer bug:** `minimumTextWidth` (`:3921-3925`) measures the raw
   string with no `+4` cell inset — the exact under-measure `ComposerActionButton`/
   `ChoiceButton.measuredTitleWidth` fixed. Here it's a floor, so the guaranteed minimum
   itself ellipsizes.

The "free space" in the screenshot is real but unreachable: it lives on the short, hidden-when-
empty meta/branch lines below, and nothing redistributes across lines.

### (b) The agent's "name" is the model id, and the subtitle repeats it

- `AgentSupervisor.makeAgent` seeds `displayName: role ?? model` (`AgentSupervisor.swift:355`);
  production spawn passes `role: nil` (`ContinuumApp.swift:8992-9004`); default model is
  `openai-codex/gpt-5.6-sol`. Title = fully-qualified model id.
- Subtitle: `metaText(role:model:)` (`AgentInboxView.swift:3936-3938`) joins
  `[rollup, role, model]`; with `role == nil` it degenerates to the same string, verbatim.
- Both violate contracts the codebase itself states: `AgentInboxRow.title` — "The agent's
  name, never an identifier" (`AgentInboxRow.swift:348`); `AgentRecord.displayName` —
  "User-facing and renameable. NOT an identifier" (`AgentRecord.swift:58`).
- Trap for the fix: `AgentSupervisor.swift:3227` incidentally pins `displayName == config.model`
  in a clobber check.

### (c) Grey perimeter borders — the correction that never arrived

- Every idle row paints **1 pt `LineToken.border`**; selection is only a colour swap to
  `borderStrong` at the same width (`AgentInboxView.swift:3703, 3713-3717`) — precisely the
  "grey box everywhere + weak selection" the P3.12 review named. The dark selected baseline is
  nearly indistinguishable from idle.
- The corrected idiom exists next door: v2 tile idle `borderWidth = 0`
  (`ManagedAgentTileNSView.swift:709-714`); `ChoiceRowView` "rows never paint a perimeter
  border — state is fill plus checkmark" with `rowHover`/`rowSelected` fills
  (`ChoiceListView.swift:295-315`); `ChoiceButton` idle 0, focus 0.5 pt `focusRing` + glow.
  `AgentSurfaceRole.rowSelected`/`.rowHover` are never referenced anywhere in the inbox.
- Inbox lines are 1 pt literals throughout (`:1384, :2897, :3390, :3580, :3703`) vs the
  corrected 0.5 pt family; no width token exists yet — creating one is ticket 93's scope.
- **Gate that actively resists the fix:** the appearance sweep's floors
  (`UIProbeAppearance.swift:196-197`, `minimumThemedViews = 27` /
  `minimumSentineledSlots = 53`) were measured WITH one outline slot per row, and
  `ownedColorSlots` drops border slots at `borderWidth <= 0` — border removal trips the floor
  unless the floors are re-measured in the same change. All seven `chrome.agentInbox*`
  baseline pairs move; per convention that is legal only inside a supervised visual gate.
- Also against design principle 18: the "All agents" scope dropdown and the bulk bar are raw
  Aqua `NSPopUpButton`s/`NSButton`s (`:518, :3378, :2587, :2683, :3573`) — the same class of
  control P4.8 replaced on the tile with `ChoiceButton`.

### (d) Dead space

- The card is a fixed 79 pt reserving three text lines (`rowHeight`, `:92-97`), but meta and
  branch hide when empty and the inner stack is pinned **top-only** (`:3807-3810`): a
  role-less, branch-less row draws ~49 pt of content in a 79 pt bordered box → ~30 pt of empty
  bordered space, visible in the committed baselines. `heightOfRow` deliberately refuses
  content-varied height; `Metrics.rowHeight(for:lines:insets:)` already supports a lines
  count if that rule is kept as "height varies with content, not importance".
- Horizontally: 12 pt `Inset.card` on all edges + `.leading` stack + short lower lines =
  structurally empty right side under an over-budget headline. Density is also inconsistent
  with the corrected 36 pt choice rows.

### (e) "Working 158h22m" — rendering side

- `elapsedText` is unbounded (`:3957-3964`): 570k seconds renders `158h22m` (7 mono glyphs),
  and the elapsed label's `required` compression takes that width straight out of the title
  budget, per row. No fixed column is reserved.
- Two divergent elapsed vocabularies exist: the tile header would render the same duration as
  `9502m 12s` (`AgentTileHeaderView.swift:147-152`).

### Gate gaps (why none of this is red today)

- `--ui-geometry-check` has **no inbox leg at all**; `--agent-inbox-check` pins the 79 pt
  height as CORRECT; the row-title QA hooks return `stringValue`, vacuous under cell-level
  elision (the same blindness `qaTitleDrawsWithoutTruncation` closed for `ChoiceButton`).
- Every inbox check and baseline renders at **320 pt** — the shipping default sidebar is 280
  and the minimum 220; the truncation regime is literally never gated.
- Lab fixtures cannot express the bugs: human titles, pre-abbreviated models, roles and
  branches present, max elapsed 2h21m. No fixture with `title == provider/model`, nil
  role+branch, or 3-digit-hour elapsed.

## Part 2 — status truthfulness ("Working 158h22m" for ~6 days)

### The mechanism (survives restarts by RE-DERIVATION, not stale memory)

1. `TileSpawner.spawnManagedAgent` writes `ManagedAgentSessionRecord{status: .starting,
   lastSeenAt: <spawn>}` (`TileSpawner.swift:1328-1335`) — and **nothing ever rewrites it**:
   the only writers of `.stopped`/`lastSeenAt` iterate tmux runtimes, which a managed-agent
   tile does not have (`ZoneRuntimeController.swift:183-187, 394-399`).
2. For an agent whose tile is NOT rendering on the active canvas, `agentRowStatus` maps the
   frozen `.starting → .configuring` (`ContinuumApp.swift:4255`) — individually documented as
   correct ("the genuine pre-first-event state").
3. The inbox folds `.configuring → InboxState.working` (`AgentInboxRow.swift:573-574`) —
   individually defensible ("spawning is busy-ish"). **Jointly: "Working", forever.**
4. Elapsed = `now − occurredAt` of the synthetic status draft, whose timestamp is the frozen
   `lastSeenAt` — i.e. **now minus the tile's spawn instant**: 158h22m ≈ 6.6 days,
   monotonically growing across restarts. Only guard is `max(0, …)`.

### Three status arms feed a row (the fix reasoned about the least-used one)

- **Arm A:** if recorded activity drafts exist, the fold takes the status stamped on the LAST
  draft — the `agentRowStatus` derivation is computed and thrown away
  (`AgentInventory.swift:96-104`; `AgentActivityEvent.swift:306-313`).
- **Arm B:** no drafts (every fresh launch) → synthetic draft carrying the derivation.
- **Arm C:** which derivation inputs apply depends on whether a legacy session record exists;
  legacy-record + no live tile view = the `.configuring` trap. Genuinely headless (no legacy
  record) correctly reads `.idle`/Ready.

### What the P5.5 defect-2 fix does and does not cover

- ✅ While a v2 tile is attached and refreshing: tile status, drafts stamped after the fix,
  chip/header/sidebar agreement for that agent.
- ❌ No-tile / inactive-project / headless agents (no liveStatus exists).
- ❌ Every fresh launch until an agent is prompted again (Arm B synthetic).
- ❌ The settle still emits no draft (`ManagedAgentActivityBridge.swift:64-67`), so within a
  session Arm A's last draft can still be `turn.completed`-stamped.
- ❌ `detach()` never resets `descriptor.status`; `attach` doesn't refresh status until first
  ingest/seam fire.
- Note: v2 is still opt-in; the compatibility default path still derives from
  `model.currentStatus` (running-beats-completed). P5.5 close-out (flip default, delete
  legacy) changes that.

### Nothing periodic can clear it

Writers audit: only "tile happens to be on the ACTIVE project's canvas at boot"
(`showPreviousSessionNotice` → `.idle`) or "delete the tile" clear the stale value. The
periodic sweep is a faithful recompute of the same frozen record — it re-writes the stale
status to every surface (inbox row "Working", tree chip "Configuring", phone "Managed agent
configuring" — three different words for the same wrongness; canvas badge and dock happen to
ignore `.configuring`). `unobservedAgentIds` — the flag that already correctly marks these
rows as disk-derived and unconfirmed — is computed (`ContinuumApp.swift:4432`) and rendered
by nobody. The auto-settle lifecycle rung is not wired in production
(`AgentInboxRowBuilder` hardcodes `.active`, `:63`).

### Why the row-status check didn't catch it

The P4.14 fixture uses `status: .running` (maps to `.idle` — fine) and never asserts
`InboxRow.state(for: .starting)`; and because it attaches a tile without wiring
`onIngestedEvent`, it only ever exercises the synthetic arm — Arm A (drafts-win) is untested.

### Candidate ownership rules (owner decision needed — not started)

1. **Row rule:** "no runner in flight and no live view ⇒ never `working`" — the leak is the
   single fold `.configuring → .working`; folding it to ready loses the brief real-spawn
   signal (the code's own principle argues for truthfulness: "a row that self-corrects after
   N seconds is still wrong for N seconds").
2. **Writer rule:** the spawn record saying `.starting` forever is the writer's bug — one-word
   change to `.running` at `TileSpawner.swift:1331` makes stuck rows read Ready with no new
   thresholds, but needs read-side tolerance/migration for records already on disk.
3. **Elapsed rule:** never show a duration anchored to a timestamp older than the app's own
   uptime / not derived from a real turn-start; cap/coarsen the formatter regardless (`>24h`
   reads as days, fixed mono column).
4. **Unconfirmed rendering:** draw `unobservedAgentIds` (already computed, already correct)
   as a muted/unconfirmed row state instead of asserting "Working" off disk.
5. **One arm, not three:** the fold's STATUS should always come from the derivation, drafts
   contributing only the timeline — closes Arm A silently outranking the derivation and makes
   the P4.14 check non-vacuous. Needs an explicit statement for the phone timeline (per-event
   status vs row status).
6. Keep P5.2's "process alive but idle = Ready" untouched; these rules are about agents with
   NO process.

## Part 3 — proposed program shape (for discussion, not started)

1. **Finish P5.5 first** (close-out steps above). The sidebar work must not ride under P5.5's
   fence — `AgentInboxView.swift` is outside it, and the corrections deserve their own
   supervised review (the inbox counterpart of P4.10), with the moved `chrome.agentInbox*`
   baselines blessed at that gate.
2. **New supervised packet(s), owner-fenced on `AgentInboxView.swift` + row builder + tokens:**
   - UI: title-first truncation order + measured-fit tiers (+4 inset everywhere), name-vs-model
     (writer + defensive reader + abbreviated model in meta), border/selection adoption of the
     `ChoiceRowView` idiom via `AgentLineRole` (floors re-measured in the same change),
     content-derived row height / two-line packing, custom scope control replacing the Aqua
     popup, one shared elapsed formatter with a cap.
   - State: pick ownership rules from Part 2 (recommendation: 2 + 1 + 3 + 4, then 5 as its own
     packet since it touches the phone contract).
   - Gates: an inbox leg in `--ui-geometry-check` at 220/280/320 with a
     `qaTitleDrawsWithoutTruncation` analogue and a fixture that can actually express the bugs
     (provider/model title, nil role+branch, 3-digit-hour elapsed); un-pin the 79 pt height
     assertions; re-measure appearance floors.
3. **Sequence against ticket 93** (border-width token): either land the inbox border change as
   the first consumer of 93's token, or do 93 immediately after — both are owner calls.
4. Then Queue 92 pre-arm (its checklist already requires 91 clean-stopped and committed).

## Owner decisions needed

1. Approve P5.5 close-out (flip default + legacy deletion) — everything else sequences after.
2. Sidebar: new supervised packet(s) as sketched — one combined UI+state gate, or UI and state
   separately?
3. Status ownership: which of Part 2's rules (recommendation: 2+1+3+4 now, 5 later).
4. Default agent naming: what should a role-less agent be called (project + ordinal, friendly
   generated name, …)? The current seed is the model id.
5. Ticket 93 sequencing relative to the sidebar packet.
