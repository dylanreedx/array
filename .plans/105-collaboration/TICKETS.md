# Collaboration ticket catalogue

29 October 2026. Original ticket-definition baseline, retained with its planning-time bodies. Current status is in [progress](PROGRESS.md) and on the live board: COL-01/03 Done; COL-02/04/05/06/08 Doing. The first 22 define the complete native coworker-alpha path; COL-23–26 are separately scoped later work. Numbers identify workstreams, not a strict topological execution order. Explicit dependencies control pickup.

Target: previously empty **Array feats** board `F54D4170-AB61-4595-A4D4-A400B76364A5`, existing **To Do** column. The other populated board is excluded from writes.

[Implementation plan](IMPLEMENTATION-PLAN.md) · [Implementation studies](implementation/README.md) · [Machine-readable catalogue](tickets.json) · [Created-card receipt](BOARD-RECEIPT.json)

## Index

| Ticket | Phase | Depends on |
| --- | --- | --- |
| COL-01 — Settle shared-area architecture, UX and confidentiality gates | 0 | — |
| COL-02 — Build an isolated three-principal collaboration harness | 0 | COL-01 |
| COL-03 — Define portable shared-area contracts and atomic reducer | 1 | COL-01 |
| COL-04 — Add person/device identity and area invitations with revocation | 1 | COL-01, COL-03 |
| COL-05 — Persist ordered area operations, snapshots and request outcomes | 1 | COL-02, COL-03, COL-04 |
| COL-06 — Implement complete replay, bounded subscriptions and ephemeral presence | 1 | COL-05 |
| COL-07 — Enforce object publication and host-action capability boundaries | 1 | COL-04, COL-05 |
| COL-08 — Store local shared-area bindings and recoverable replicas | 1 | COL-03, COL-07 |
| COL-09 — Capture reviewed tile/layout manifests from selection, zone or workspace | 2 | COL-03, COL-07, COL-08 |
| COL-10 — Mount native shared areas with private cameras and reference views | 2 | COL-08, COL-09 |
| COL-11 — Synchronize shared geometry, atomic groups and semantic undo | 2 | COL-05, COL-10 |
| COL-12 — Add durable area discussion and revisioned working agreements | 2 | COL-05, COL-10 |
| COL-13 — Dispatch reviewed context through the owning host with durable receipts | 2 | COL-07, COL-12, COL-15 |
| COL-14 — Show per-agent context freshness and provenance-linked results | 2 | COL-12, COL-13 |
| COL-15 — Publish sequenced live agent snapshots and truthful capabilities | 2 | COL-06, COL-07, COL-08, COL-10 |
| COL-16 — Publish immutable diff/file artifacts and pinned review references | 2 | COL-05, COL-07, COL-10 |
| COL-17 — Normalize provider usage into an idempotent per-owner ledger | 3 | COL-03, COL-07, COL-15 |
| COL-18 — Add contextual cursors, voluntary following and hover-only usage | 3 | COL-06, COL-10, COL-17 |
| COL-19 — Prove replay, compaction, retention and host-outcome recovery | 3 | COL-05, COL-06, COL-08, COL-13, COL-16 |
| COL-20 — Audit publication, revocation and attachment boundaries end to end | 3 | COL-04, COL-07, COL-13, COL-16, COL-19 |
| COL-21 — Gate the complete two-person workflow in matrix and native QA | 4 | COL-02, COL-09, COL-11, COL-12, COL-14, COL-15, COL-16, COL-18, COL-19, COL-20 |
| COL-22 — Prepare isolated service deployment, restore and coworker-alpha handoff | 4 | COL-21 |
| COL-23 — Design explicit patch or commit import into a recipient checkout | Later | COL-16, COL-19, COL-20, COL-21 |
| COL-24 — Evaluate browser participation against the native shared-area protocol | Later | COL-04, COL-06, COL-07, COL-22 |
| COL-25 — Evaluate scoped live preview sharing beyond static snapshots | Later | COL-16, COL-20, COL-22 |
| COL-26 — Audit richer remote control, terminal and execution-transfer capabilities | Later | COL-13, COL-15, COL-20, COL-22 |

## COL-01 — Settle shared-area architecture, UX and confidentiality gates

**Status:** Planned; not started. **Phase:** 0.

**Outcome and scope**

Write decision records for portable area identity, jointly arranged geometry/private cameras, supported publication kinds, person/device/host ownership, and trusted-relay versus real group encryption. Compare embedded mount with a dedicated shared scene without migrating source zones.

**Dependencies:** None; resolve before dependent feature work.

**Acceptance criteria**

- All three share entry points use one membership/manifest model; unsupported tile kinds are explicit.
- Document server-visible content, retention, key lifecycle and revocation. Preserve companion ciphertext. If group E2EE is required, expand blocking key-admission/rotation/history tickets before proceeding.
- Record native-first and separate-checkout scope; distinguish observation, source publication and execution rights.

**Behavioral witness / validation**

Review concrete payload/coordinate examples and ADRs; the COL-02 fixture must exercise the selected boundaries. This ticket closes decisions, not production behavior.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/01-domain.md`
- `.plans/105-collaboration/implementation/02-transport.md`
- `.plans/105-collaboration/implementation/04-canvas.md`
- `.plans/105-collaboration/implementation/10-security.md`
- `.plans/105-collaboration/implementation/12-delivery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-02 — Build an isolated three-principal collaboration harness

**Status:** Planned; not started. **Phase:** 0.

**Outcome and scope**

Create independent invited A/B and excluded C identities, temporary service/client databases, separate app support/default suites/project roots and scripted host runner transports. Exercise actual service routes and production scene/dispatch seams.

**Dependencies:** COL-01

**Acceptance criteria**

- No test uses the default tmux socket, production relay, real CLI login, or live project state.
- Inject clocks, dropped/duplicated/reordered frames, host restarts and transaction failures reproducibly.
- Assertions inspect delivered bytes, mounted frames, source files, runner counts and actual command outcomes.

**Behavioral witness / validation**

An intentionally unauthorized or lost-operation fixture is RED before the enforcement fix and GREEN after; register the harness in the matrix and confirm its leg runs.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/11-verification-performance.md`
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-03 — Define portable shared-area contracts and atomic reducer

**Status:** Planned; not started. **Phase:** 1.

**Outcome and scope**

Add schema-versioned area/object/placement/source-binding identities and typed operations for admission, geometry, discussion references and immutable context. Keep source-local records, camera and creation pointers out of shared payloads.

**Dependencies:** COL-01

**Acceptance criteria**

- Multi-project capture preserves source ownership and area-relative geometry.
- Atomic group operations either apply entirely or leave state unchanged; invalid/nonfinite frames and dangling references refuse.
- Stable operation ID plus payload digest distinguishes identical retry from changed intent; stale deleted IDs cannot resurrect.

**Behavioral witness / validation**

Core reducer fixtures verify canonical state from accepted-event replay, conflict/rollback, duplicate operations and schema refusal; encoded sentinels prove host records/pointers do not cross.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/01-domain.md`
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-04 — Add person/device identity and area invitations with revocation

**Status:** Planned; not started. **Phase:** 1.

**Outcome and scope**

Introduce real human principals, separately authenticated devices/hosts, durable membership and object/action capabilities. Implement atomic expiring invitations and access removal without pairing teammates as personal companion devices.

**Dependencies:** COL-01, COL-03

**Acceptance criteria**

- Two humans with independent hosts join the same area; a third cannot enumerate or fetch it.
- Expired/consumed invitations, forged authorship and cross-area IDs refuse; history-on-join policy is explicit.
- Removal invalidates future reads/writes and pending unadmitted actions on active clients; account/subscription scaffolding is not treated as implemented identity.

**Behavioral witness / validation**

Actual auth/store/route fixtures cover invitation races, stolen-scope IDs, active-stream removal and epoch changes using disposable principals.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/03-identity.md`
- `.plans/105-collaboration/implementation/10-security.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-05 — Persist ordered area operations, snapshots and request outcomes

**Status:** Planned; not started. **Phase:** 1.

**Outcome and scope**

Add collaboration-scoped service storage/routes using existing relay plumbing. Persist area sequence, members, operations, snapshots and payload-bound idempotency atomically while preserving companion v2 behavior.

**Dependencies:** COL-02, COL-03, COL-04

**Acceptance criteria**

- Discussion/layout survives service restart and remains area-isolated.
- Identical retry returns the original outcome; reusing an ID for changed content refuses.
- Snapshot replacement is scoped to one area and stream; no globally replaced instance snapshot erases other shared state.

**Behavioral witness / validation**

Disposable SQLite plus actual HTTP route tests cover concurrent writes, transaction failure, restart, migration rollback and companion regression fixtures.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/02-transport.md`
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-06 — Implement complete replay, bounded subscriptions and ephemeral presence

**Status:** Planned; not started. **Phase:** 1.

**Outcome and scope**

Provide authenticated area subscriptions with consistent snapshot-to-live handoff, paged catch-up, backpressure and a separate coalesced presence lane.

**Dependencies:** COL-05

**Acceptance criteria**

- More than 500 retained operations replay completely with no handshake gap or duplicate application.
- Slow subscribers resynchronize durable content; only ephemeral presence may drop.
- Access removal closes delivery on already-open streams; host liveness and pointer TTL expire independently.

**Behavioral witness / validation**

Localhost multi-client route/socket fixtures inject backlog, handshake races, partitions, slow consumers and midstream revocation under an injected clock.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/02-transport.md`
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-07 — Enforce object publication and host-action capability boundaries

**Status:** Planned; not started. **Phase:** 1.

**Outcome and scope**

Create allowlisted portable projections and explicit source publication grants. Enforce scope before bytes leave the host/service and recheck current permission at host action admission.

**Dependencies:** COL-04, COL-05

**Acceptance criteria**

- Sharing a region exposes only reviewed members/history, including attachment and nested artifact lookups.
- A pointer, source ID or client-supplied principal never grants access; private host records and credentials remain local.
- View/discuss/layout/prompt/stop/approval/terminal/sharing rights are distinguishable; actual agent policy can cause effects without a new approval.

**Behavioral witness / validation**

A/B/C fixtures assert prohibited data is absent from transport bytes, forged grants refuse, and stale queued actions fail closed after removal.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/03-identity.md`
- `.plans/105-collaboration/implementation/05-runners.md`
- `.plans/105-collaboration/implementation/10-security.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-08 — Store local shared-area bindings and recoverable replicas

**Status:** Planned; not started. **Phase:** 1.

**Outcome and scope**

Persist channel-isolated area replica, local anchor, private drafts and opaque source bindings without importing remote projects or syncing host-bound AgentRecord values.

**Dependencies:** COL-03, COL-07

**Acceptance criteria**

- Join/remount preserves local registry exclusive ownership and source canvas bytes.
- One source can have multiple views while owning exactly one runner.
- Missing remote objects render explicit unavailable state; removing a view neither deletes the source nor kills execution; incompatible schema preserves the prior store.

**Behavioral witness / validation**

Temporary store migration/restart fixtures and production scene mount assert disk bytes, bindings, local pointer preservation and runner count.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/01-domain.md`
- `.plans/105-collaboration/implementation/04-canvas.md`
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-09 — Capture reviewed tile/layout manifests from selection, zone or workspace

**Status:** Planned; not started. **Phase:** 2.

**Outcome and scope**

Implement the three sharing entry points through one structured manifest: selected objects, exact publication modes and area-relative model geometry. Reuse styled choice components and existing selection contracts.

**Dependencies:** COL-03, COL-07, COL-08

**Acceptance criteria**

- Drag selection previews included tiles and permits correction; cancel changes nothing.
- Selection hover lift is excluded; negative/nonzero origins and multi-project ownership remain correct.
- Whole-zone/workspace capture resolves persisted coverage below hydration tier or explicitly names unavailable/unsupported members; later border crossing never silently publishes.

**Behavioral witness / validation**

Pure manifest/geometry checks plus production-mounted pointer journey compare exact layout and original persisted source bytes before/after capture.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/04-canvas.md`
- `.plans/105-collaboration/implementation/01-domain.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-10 — Mount native shared areas with private cameras and reference views

**Status:** Planned; not started. **Phase:** 2.

**Outcome and scope**

Add a shared scene/container owner for area-local geometry with local anchor and independent camera. Render remote objects through data-source projections rather than local agent construction.

**Dependencies:** COL-08, COL-09

**Acceptance criteria**

- Participants at different world origins see the same internal arrangement.
- Mount/hydrate/reopen/close and removal never spawn a recipient executor or retidy source zones.
- Shared clicks/creation cannot fall back to an unrelated active local project; source private and below-live-tier tiles survive persistence.

**Behavioral witness / validation**

Two isolated client mounts through mountWorkspaceSceneAtBoot assert actual visible world frames, focus/armed pointers, source bytes and source/recipient runner counts.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/04-canvas.md`
- `.plans/105-collaboration/implementation/01-domain.md`
- `.plans/105-collaboration/implementation/05-runners.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-11 — Synchronize shared geometry, atomic groups and semantic undo

**Status:** Planned; not started. **Phase:** 2.

**Outcome and scope**

Route shared moves/resizes through typed authoritative commands while keeping source canvas and personal anchor/camera changes local. Resolve remote edits during a drag deliberately.

**Dependencies:** COL-05, COL-10

**Acceptance criteria**

- A group action cannot partially commit or split frames across concurrent drags.
- Undo reverses the applicable local action without restoring a stale whole document over peer edits.
- Permission loss mid-gesture cancels commit; placement does not run divergent local automatic-layout pushes on peers.

**Behavioral witness / validation**

Two mounted clients with delayed events, concurrent group drag, revocation and failed saves converge on exact frames while preserving intervening peer actions.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/01-domain.md`
- `.plans/105-collaboration/implementation/04-canvas.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-12 — Add durable area discussion and revisioned working agreements

**Status:** Planned; not started. **Phase:** 2.

**Outcome and scope**

Keep human discussion, shared brief/boundaries, decisions and immutable agreement revisions in the area. Begin with explicit revision conflicts and retained drafts rather than pretending whole-string LWW merges text.

**Dependencies:** COL-05, COL-10

**Acceptance criteria**

- Human discussion or @mention never dispatches to an agent by accident.
- Concurrent agreement edits preserve both drafts and surface a conflict; endorsements identify the revision.
- Both participants can read accepted discussion after an execution host sleeps; task boundaries are described as instructions, not enforced filesystem restrictions.

**Behavioral witness / validation**

Two-client durable-state fixtures exercise concurrent edits, restart/late join, author validation and zero runner commands from ordinary discussion.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/06-context-discussion.md`
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-13 — Dispatch reviewed context through the owning host with durable receipts

**Status:** Planned; not started. **Phase:** 2.

**Outcome and scope**

Add deliberate send/queue with target agent, frozen context/artifact revision, authenticated author/operator and stable command identity. Use host prompt preparation and supervisor acceptance, not direct remote runner creation.

**Dependencies:** COL-07, COL-12, COL-15

**Acceptance criteria**

- Own-agent dispatch and owner-accepted teammate suggestions retain provenance and exact reviewed content.
- Host rejects removed membership, stale generation/turn and invalid content; remote local-path attachments cannot bypass materialization.
- Dropped replies/restart never cause blind resubmission. Separate requested, host accepted, queued, provider observed and outcome unknown; do not promise exactly-once external effects.

**Behavioral witness / validation**

Script real runner transport seams for all managed harnesses, inject crashes around submission and verify original-operation recovery or honest ambiguity, with no duplicate authorized dispatch.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/05-runners.md`
- `.plans/105-collaboration/implementation/06-context-discussion.md`
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-14 — Show per-agent context freshness and provenance-linked results

**Status:** Planned; not started. **Phase:** 2.

**Outcome and scope**

Track which immutable agreement revision was actually delivered to each agent and bring selected agent answers/artifact references back into human discussion.

**Dependencies:** COL-12, COL-13

**Acceptance criteria**

- Changed-since-sent is per agent and cannot imply receipt, understanding or compliance.
- Editing the shared agreement never rewrites already accepted execution input.
- Result excerpts retain source turn, host and artifact revision; unavailable originals remain honestly labeled.

**Behavioral witness / validation**

Two agents receive different revisions; edit/resend/restart fixtures verify correct independent receipts, stale markers, exact source links and no automatic extra dispatch.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/06-context-discussion.md`
- `.plans/105-collaboration/implementation/05-runners.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-15 — Publish sequenced live agent snapshots and truthful capabilities

**Status:** Planned; not started. **Phase:** 2.

**Outcome and scope**

Bridge supervisor atomic transcriptAttachment snapshot/tail into authorized shared projections with host/session generation, stable sequence and remote-only view lifecycle.

**Dependencies:** COL-06, COL-07, COL-08, COL-10

**Acceptance criteria**

- Late join receives permitted snapshot plus every allowed tail event or an explicit resnapshot.
- Private history/raw side channels do not cross; attach/remount creates no duplicate executor.
- Actual bound-runner capabilities govern controls. Current unwired provider approval responses and watched external sessions remain unavailable; interrupt is not teardown kill.

**Behavioral witness / validation**

Production supervisor/transport fixtures cover snapshot-tail races, gaps, background turns, stale generation, all three harnesses and QA-only capability false positives.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/05-runners.md`
- `.plans/105-collaboration/implementation/07-usage-presence.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-16 — Publish immutable diff/file artifacts and pinned review references

**Status:** Planned; not started. **Phase:** 2.

**Outcome and scope**

Add scoped artifact storage and snapshot producers with content digest, base/revision identity, coverage and publication limits. Reuse read-only rendering without assuming branch diffs include current worktree/untracked changes.

**Dependencies:** COL-05, COL-07, COL-10

**Acceptance criteria**

- Selected bytes and explicitly included untracked/working/branch changes have accurate coverage; excluded content never uploads.
- Live latest and the revision under review remain distinct; source changes invalidate applicability rather than silently carry approval forward.
- Recipient local checkout stays byte-identical; large blobs use bounded authorized storage rather than the event stream.

**Behavioral witness / validation**

Fixture repositories and artifact routes cover changed-during-review, inaccessible blobs, hash mismatch, oversized content and precise original/recipient file-state assertions.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/08-artifacts-code.md`
- `.plans/105-collaboration/implementation/10-security.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-17 — Normalize provider usage into an idempotent per-owner ledger

**Status:** Planned; not started. **Phase:** 3.

**Outcome and scope**

Define accounting events with provider/source identity, period, timestamp, delta/cumulative basis, cache semantics and coverage. Aggregate usage once per actual source run, independently from view count or prompt author.

**Dependencies:** COL-03, COL-07, COL-15

**Acceptance criteria**

- Claude run/request observations are not double-counted; Codex cumulative totals are differenced; Pi message duplicates/cache semantics have fixture-backed definitions.
- Reconnect, subagent overlap, forks and repeated views do not inflate totals; missing telemetry remains partial/unavailable.
- Daily boundaries/timezone and shared-area versus optional wider aggregate scope are explicit; freshest reported updates are not mislabeled token-by-token streaming.

**Behavioral witness / validation**

Offline translator/ledger fixture matrix asserts exact totals for duplicates, counter reset, cached subsets, timezone rollover, late reports and unavailable sources.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/07-usage-presence.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-18 — Add contextual cursors, voluntary following and hover-only usage

**Status:** Planned; not started. **Phase:** 3.

**Outcome and scope**

Render area-local cursor/selection/viewport presence with bounded updates, optional following and a stable teammate hover card. Provide avatar and keyboard equivalents.

**Dependencies:** COL-06, COL-10, COL-17

**Acceptance criteria**

- Different anchors/zooms point at the same shared content; local navigation exits follow without feedback loops.
- Freshest reported token period/scope/coverage and agent activity appear on hover/focus; no permanent usage overlay.
- Offscreen/away/stale states are usable; pointer traffic causes zero transcript measurements, canvas saves or model calls.

**Behavioral witness / validation**

Injected presence/clock traces plus production camera and hover input assert exact positions, stale expiry, card appearance/disappearance, keyboard parity and bounded work counters; inspect native light/dark.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/04-canvas.md`
- `.plans/105-collaboration/implementation/07-usage-presence.md`
- `.plans/105-collaboration/implementation/11-verification-performance.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-19 — Prove replay, compaction, retention and host-outcome recovery

**Status:** Planned; not started. **Phase:** 3.

**Outcome and scope**

Complete persistent replica/outbox transactions, snapshot coverage, tombstones, migration compatibility and command reconciliation. Define separate retention for discussion/artifacts/deleted IDs/idempotency and unknown outcomes.

**Dependencies:** COL-05, COL-06, COL-08, COL-13, COL-16

**Acceptance criteria**

- Over-500-event and post-compaction reconnect loses no durable object and resurrects no deletion.
- Revocation/epoch and operation receipts survive compaction; unsupported schemas retain recoverable state.
- Offline executable actions expire/reconfirm under current authority; relay receipt is not execution completion and ambiguous submission never silently repeats.

**Behavioral witness / validation**

Crash each durable boundary, restore to replacement directories, replay ancient clients and recover pending commands through actual stores/routes/host adapters.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`
- `.plans/105-collaboration/implementation/02-transport.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-20 — Audit publication, revocation and attachment boundaries end to end

**Status:** Planned; not started. **Phase:** 3.

**Outcome and scope**

Run adversarial A/B/C schedules against real subscriptions, artifact routes and host dispatch. Cover nested IDs, raw payloads, retained history and removed-member queues; review diagnostics and selected confidentiality implementation.

**Dependencies:** COL-04, COL-07, COL-13, COL-16, COL-19

**Acceptance criteria**

- Excluded participant never gets private object bytes or scope metadata through guessed IDs, history, previews or cached routes.
- Removed member loses future socket/blob/action access; stale queued work cannot regain authority after reconnect.
- Logs avoid content/credentials; actual storage/key/retention behavior matches the adopted trust contract; no unsupported E2EE claim.

**Behavioral witness / validation**

Offline negative integration suite asserts transport payload absence and command non-effects, with explicit before/after counterexamples and production-path enforcement.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/10-security.md`
- `.plans/105-collaboration/implementation/03-identity.md`
- `.plans/105-collaboration/implementation/08-artifacts-code.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-21 — Gate the complete two-person workflow in matrix and native QA

**Status:** Planned; not started. **Phase:** 4.

**Outcome and scope**

Connect the real shared-area workflow and register behavioral witnesses in the full matrix. Verify professional interaction, accessibility, performance and source preservation across both participants.

**Dependencies:** COL-02, COL-09, COL-11, COL-12, COL-14, COL-15, COL-16, COL-18, COL-19, COL-20

**Acceptance criteria**

- Two participants replace prompt-file exchange using discussion/agreement/own-agent delivery and pinned review artifacts; excluded C stays excluded.
- Actual production mount and visible frames are asserted; no checks-only install path or source-string test substitutes.
- Native light/dark, token-owner census, keyboard/Reduce Motion and count-based presence/transcript budgets pass; matrix summary reports new legs and known-red outcomes.

**Behavioral witness / validation**

Full production-path deterministic harness plus native appearance sweeps and bounded soak; preserve existing scene/camera/companion gates and record remaining manual/live-provider limits.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/11-verification-performance.md`
- `.plans/105-collaboration/implementation/12-delivery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-22 — Prepare isolated service deployment, restore and coworker-alpha handoff

**Status:** Planned; not started. **Phase:** 4.

**Outcome and scope**

Package collaboration service/client compatibility in isolated staging, including backup/restore, quotas, retention, rate limits, redacted diagnostics and observed operating budgets. Prepare a concrete reviewed release/deployment proposal.

**Dependencies:** COL-21

**Acceptance criteria**

- Disposable multi-area dataset restores with membership, artifacts and outcomes intact; old revoked credentials remain invalid.
- Linux packaging and companion regression checks pass; no production instance is silently migrated.
- Measure usage/storage/fanout before capacity/cost claims; update maintained notification IDs if implementing actual invite/activity delivery; follow release runbook before shipping.

**Behavioral witness / validation**

Offline container/integration restore harness and staged operational rehearsal under separately authorized deployment. Ticket is not permission to deploy during planning.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/02-transport.md`
- `.plans/105-collaboration/implementation/11-verification-performance.md`
- `.plans/105-collaboration/implementation/12-delivery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-23 — Design explicit patch or commit import into a recipient checkout

**Status:** Planned; not started. **Phase:** Later.

**Outcome and scope**

Investigate and then implement only a selected, reviewed code-transfer contract. Keep shared observation separate from applying code locally; do not add continuous file synchronization by default.

**Dependencies:** COL-16, COL-19, COL-20, COL-21

**Acceptance criteria**

- Identify source/base/content and recipient checkout explicitly; preflight dirty files, conflicts and untracked paths.
- No write occurs before explicit application; failed/partial application has a documented recoverable outcome.
- Review comments/checks remain attached to their original revision rather than pretending imported content is identical after conflicts.

**Behavioral witness / validation**

Disposable repositories with divergent commits, dirty files, rename/conflict and failed-write schedules verify exact filesystem outcomes and original revision provenance.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/08-artifacts-code.md`
- `.plans/105-collaboration/implementation/09-persistence-recovery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-24 — Evaluate browser participation against the native shared-area protocol

**Status:** Planned; not started. **Phase:** Later.

**Outcome and scope**

Scope a lightweight browser client for invites, permitted area content, discussion and suggestions. Keep existing authorization and artifact/command policy instead of building a second inconsistent service.

**Dependencies:** COL-04, COL-06, COL-07, COL-22

**Acceptance criteria**

- Document no-account versus authenticated guest tradeoffs, identity/history access and revocation.
- Browser render/attachments preserve native publication boundaries and human attribution; provider login remains on the host.
- A concrete browser prototype demonstrates the selected scope before wider implementation; no browser requirement blocks the native milestone.

**Behavioral witness / validation**

Protocol conformance/negative auth fixtures and browser-native mixed-client journey including removal, missing host, unsupported surfaces and accessible controls.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/02-transport.md`
- `.plans/105-collaboration/implementation/03-identity.md`
- `.plans/105-collaboration/implementation/12-delivery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-25 — Evaluate scoped live preview sharing beyond static snapshots

**Status:** Planned; not started. **Phase:** Later.

**Outcome and scope**

Compare authenticated preview forwarding, stream/snapshot and externally reachable links. Explicitly separate host localhost reachability and browser session credentials from a shared tile URL.

**Dependencies:** COL-16, COL-20, COL-22

**Acceptance criteria**

- First capability labels snapshot, link and live interactive preview truthfully.
- Forwarding has object-specific admission/revocation and cannot expose arbitrary host ports/cookies/headers or permit unauthorized interaction.
- Choose one bounded preview use case and record operating/payload limits before implementing a generic remote browser.

**Behavioral witness / validation**

Isolated local preview servers with redirects, cookie/header sentinels, URL rebinding and revoke schedules assert actual reachable content and permitted interactions.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/08-artifacts-code.md`
- `.plans/105-collaboration/implementation/10-security.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.


## COL-26 — Audit richer remote control, terminal and execution-transfer capabilities

**Status:** Planned; not started. **Phase:** Later.

**Outcome and scope**

Produce separate capability contracts and scoped follow-up tickets for direct teammate prompting, provider approvals, terminal control and cross-host execution transfer. Do not claim one generic editor role enables these.

**Dependencies:** COL-13, COL-15, COL-20, COL-22

**Acceptance criteria**

- Audit actual production bound-runner support and current approval policy; a protocol or QA responder alone is insufficient.
- Terminal command authority and shared common environment are explicitly distinct from agent transcript visibility.
- Transfer proves old-owner release, code/environment readiness and recipient CLI auth before any new executor; unknown ownership refuses.

**Behavioral witness / validation**

Provider-specific scripted transport and isolated ownership fixtures establish each chosen action. No default tmux or live external session may be probed to satisfy the audit.

**Planning references**

Plan: `.plans/105-collaboration/IMPLEMENTATION-PLAN.md`.
- `.plans/105-collaboration/implementation/05-runners.md`
- `.plans/105-collaboration/implementation/10-security.md`
- `.plans/105-collaboration/implementation/12-delivery.md`

Creating this card does not start implementation. Keep private originating people/project details out of product copy. CLI authentication stays CLI-owned; never use production state for QA.
