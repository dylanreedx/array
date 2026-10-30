# Shared discussion, agreements and deliberate agent delivery

29 October 2026. Implementation planning only. Source inspection, no product changes or runtime tests. This memo addresses two people coordinating their own agents in independent checkouts; standalone shared-session access is not its assumed first milestone. All examples are generic.

## Feasibility and the reusable seams

This is feasible without sharing either checkout or implementing a general chat application. A shared area can own durable discussion and agreement objects while each host remains responsible for accepting work into its local agents.

| Inspected source | Existing behavior and relevance | Boundary |
| --- | --- | --- |
| [`BoardTaskContent.swift`](../../../Sources/ContinuumRevivedCore/BoardTaskContent.swift), `BoardTaskContext` and `BoardTaskPromptEnvelope` | Freezes title/body, board/card identity and observed revision; generates exact prompt material and recognizes it again in transcripts. Images are imported into agent attachment ownership. | Local board context, not a shared agreement document or multi-human identity model. |
| [`AgentComposerView.swift`](../../../Sources/ContinuumRevived/Canvas/AgentComposer/AgentComposerView.swift), `dispatch` around lines 1400–1510 | Captures the submitted task context; acquires a durable draft submission lease; transfers outcome ownership to the action sink; runs `onAcceptedBoardTask` only after acceptance. Refusal restores the lease. | Acceptance is an existing local action outcome, not proof that a provider read, understood or obeyed context; no multi-host receipt ledger here. |
| [`ManagedAgentTileNSView.swift`](../../../Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift), `prepareBoardTask`, `onAcceptedBoardTask` | UI prepares frozen context separately from the user's independent composer instructions. | Preparing context is not sending it; existing editor state must survive failed/rejected imports. |
| [`BoardRuntime.swift`](../../../Sources/ContinuumRevived/App/BoardRuntime.swift), `apply` | One authority applies reducer commands, persists before publishing, rolls back failed persistence, and broadcasts accepted revisions. | Project-local runtime, not a shared service; its reducer architecture is a pattern to reuse, not a ready remote store. |
| [`NoteState.swift`](../../../Sources/ContinuumRevivedCore/NoteState.swift), [`ProjectStore.swift`](../../../Sources/ContinuumRevivedCore/ProjectStore.swift), note methods around lines 352–390 | Stores note metadata separately from a body written atomically to a local project file. | No collaborative revision identity, author attribution, history or per-agent delivery state. Do not synchronize these files as the collaboration mechanism. |
| [`WorkspaceAPIService+Delegation.swift`](../../../Sources/ContinuumRevived/App/WorkspaceAPIService+Delegation.swift), `message` around lines 435–694 | Reserves an idempotent operation before effect, rejects changed payloads under one key, rechecks grants, reports delivery separately from answers and refuses busy targets. | Agent-principal, same-project API, text bounded to 8 KB. Cannot be exposed as the human/cross-host sharing API. Its cache/tombstone semantics are not a durable network outbox. |
| [`AgentSupervisor.swift`](../../../Sources/ContinuumRevived/App/AgentSupervisor.swift), `sendAgentMessage` around line 3542 | Goes through the existing supervisor send path and wraps actual agent authorship. | A human collaborator must not be forged as an existing local agent sender. Add authenticated human attribution separately, keeping strict runner ownership. |
| [`BoardTaskSendChecks.swift`](../../../Sources/ContinuumRevived/App/BoardTaskSendChecks.swift) | Scripted Claude/Codex/Pi event fixtures drive prepared task-only input through the mounted composer, capture received revision and rendered reply. | Inspected only, not executed. Useful model for new production-path witnesses. |

Line numbers describe the inspected working tree and can move. The files contain pre-existing local changes; this is not a released-build capability claim.

## Recommended data and event model

Keep shared-area objects in the collaboration domain rather than copying a local note/card's storage wholesale. Names below are conceptual, not approved public API types.

1. **Discussion message**: area ID, stable message ID, authenticated human author, accepted timestamp/sequence, body, optional reply/target anchor and bounded attachment references. A human discussion append has no agent execution effect. Edits create a revision; deletion is a tombstone rather than rewriting past agent inputs.
2. **Agreement**: stable ID and title plus immutable revisions containing content, parent revision, content hash, authenticated author and references. Each area identifies its current revision. A draft/publish or compare-and-swap flow is sufficient initially; simultaneous rich text merging is a separate complexity choice.
3. **Agreement endorsement**: person + immutable revision. “Agreed” should mean the required named people endorsed that revision, not merely that one editor clicked publish. An edit makes newer content unendorsed until the chosen approval rule is met. The product must decide whether all members or nominated participants endorse.
4. **Context package**: frozen selected text, agreement revisions, artifact/source-turn anchors and admitted attachment digests, plus recipient set and additional instructions. Package content cannot change after confirmation. Source links are provenance; content delivered to a local agent must be available there without assuming a private remote path resolves.
5. **Delivery request and receipt**: stable request/idempotency key, package hash, requesting person, approving operator if distinct, target host/session identity and membership epoch. Each target gets its own outcome; fan-out is not one all-or-nothing success. Store actual host acceptance/turn identity when available.

Keep discussion reply references and excerpts versioned. A quote from an agent response identifies the session/turn/artifact revision; it does not automatically export all earlier or later transcript content. Retain a permitted frozen excerpt so later source unavailability is honest. Sharing new referenced content must pass the same export rules as any object.

## User flow

The shared work area has one discoverable agreement and a discussion surface (tile or inspector remains a design choice). People edit or discuss normally. From selected content they choose **Send to agent…**, review exactly what travels, select their permitted local or shared agent targets, and confirm.

Default to dispatching into a person's own host under their own current runner policy. A teammate can propose an instruction to another owner's agent without being granted direct execution. A later direct-contributor capability can use the same delivery object after independent authorization.

An `@person` is a discussion reference; an `@agent` is not automatically a provider invocation. Creating/editing discussion, publishing an agreement, changing selection, receiving a remote event and opening an area must not send prompts. If future auto-dispatch is desired, make it an explicit, inspectable policy with separate authorization and witnesses.

Preparing a composer is a distinct outcome from sending. Never overwrite an unrelated unsent draft silently. If the recipient agent is running, initially return **Busy** or prepare a draft; any later queue must have explicit persistence, withdrawal and order semantics. Current `agent.message` busy refusal is a conservative precedent.

## Truthful delivery and change awareness

Use a state machine grounded in actual evidence:

`prepared → requested → host accepted / refused / expired / outcome unknown`

Then associate observed execution events separately: `turn started`, `response observed`, `completed/failed/stopped`, where the runner provides trustworthy identity.

“Host accepted” means the host accepted the exact package under its authorization and ownership rules. “Turn started” means observed provider activity. Neither means “understood boundaries” or “will comply.” A model statement can be stored as **agent acknowledgment**, without upgrading it to enforcement or verification.

For each agent show **Last accepted revision 4 · Current revision 5 · Changed since sent**, with links to both versions and a deliberate prepare/send action. Editing revision 5 must not mutate a queued or executing revision 4 request. Stale context is visible, not silently healed by resending.

Network retries require durable host-side deduplication and recovery, not just UI suppression. Record/reserve the request before effect. If the process crashes between provider acceptance and recording the result, reconcile against a stable runner submission/turn identifier if supported; otherwise return **Outcome unknown** and block blind replay. An exactly-once external effect cannot be claimed merely because a SQLite request row exists.

Membership/grants are rechecked at host acceptance and before any queued effect. Revocation should cancel unaccepted requests or make them refuse; it cannot recall an input already consumed by the provider. Agent/host IDs, request content hashes and attachment authorization must all bind to the accepted request.

## Proposed tickets

### CTX-01 — Durable shared discussion and versioned agreements

**Outcome:** Two members can discuss and maintain one current boundary agreement in a shared area, with attributable revisions and revision-specific endorsements. Depends on area identity, membership enforcement, durable event persistence and object/blob authorization.

**Scope:** Append/reply/edit/tombstone discussion, immutable agreement revisions, explicit current-revision pointer, initial compare-and-swap conflict handling, optional nominated endorsement set, and area-scoped UI using existing typography/choice components. No automatic agent dispatch and no general direct messages.

**Acceptance/witness:** A production-route two-client fixture publishes revision 1, endorses it, races two edits and sees deterministic accepted/conflict outcomes; revision 2 does not inherit revision-1 endorsements. Reconnect/relaunch retains current content and author identities. Write failure publishes no committed revision. Posting/editing 100 human messages starts zero runner calls. Private source references cannot export unauthorized content. App witness drives actual shared-area surface mount and persisted store, not a tests-only install path; matrix reports the new leg. Native light/dark QA covers discussion, editor, conflict and missing-source states.

### CTX-02 — Deliberate frozen context delivery to owned agents

**Outcome:** A member selects a specific discussion/agreement revision, previews a package and sends it once to an explicitly chosen agent through that agent's owning host. Depends on CTX-01, human capabilities, authenticated host/session routing, the runner projection/control contract and durable idempotent transport.

**Scope:** Frozen package and attachment admission, human proposer/operator attribution, draft-preserving composer preparation, idle-target send, accepted/refused/unknown receipts, host dedupe and event association. Multiple recipients get separate results. Initial scope may allow only owned agents, with owner-mediated proposals to teammates' agents; direct remote prompting remains separately granted.

**Acceptance/witness:** Scripted Claude/Codex/Pi fixtures record the exact reviewed package hash/revision, target and author; a newer agreement edit during confirmation cannot substitute content. An uncertain reply/retry does not deliver twice; changed payload under one key conflicts. Busy target is visibly refused or prepared without interrupting. Revoke/retarget/rebind before acceptance prevents dispatch. A failed send preserves the pre-existing draft. A crash in the effect/result gap recovers the known turn or presents unknown, never falsely “delivered.” Mounted app witness traverses real confirmation→action sink→supervisor and matrix reports it. Unknown approval/queue provider capabilities remain unavailable.

### CTX-03 — Per-agent context freshness and artifact-linked replies

**Outcome:** Participants can see which agreement revision reached which agent, what changed since then, and bring a selected agent result back into human discussion without copying the full transcript. Depends on CTX-01/02, scoped transcript/artifact projections and version identities.

**Scope:** Receipt/read model keyed by exact agent/session incarnation, changed-since-sent comparison, provenance-preserving selected answer/excerpt, distinct delivery/start/response states, and missing/offline source behavior. Never label a sent boundary as enforced.

**Acceptance/witness:** Two agents on independent hosts receive revisions 2 and 3; advancing the agreement to 4 correctly shows each target's baseline. A failed delivery does not advance either baseline. A runner restart/session replacement cannot inherit a different incarnation's receipt accidentally. Quoting an answer retains the admitted source revision; a later edit/revocation prevents new unauthorized reads while preserved admitted history is represented truthfully. Agent output alone cannot endorse a human agreement. State display persists across reconnect and remains consistent on both clients; matrix reports the mounted behavioral leg.

## Sequencing and remaining decisions

Build durable human coordination before broad cross-person agent operation. A first coherent shared-area slice can contain both people's projected agent state, current agreement and discussion, with each person explicitly sending context to their own agent. That directly targets the motivating workflow without pretending the checkouts share files.

Decide endorsement rules, edit conflict UX, discussion placement, attachment types/retention, per-package size bounds, whether accepted content survives member removal, and whether queued delivery is needed. New invitations/mentions/receipts that trigger notifications require stable path classification and behavior witnesses in the maintained notification map; do not introduce them implicitly through this work.

No fixture, app, provider CLI, tmux server or production service was run. No feature code or live board state was changed by this memo.
