# Host-owned agent handoff and deliberate context dispatch

Implementation notes for the collaboration-finish bench. Verification receipts
belong in PROGRESS.md after the registered suites and paired app harness run.
This note does not claim those checks have passed.

An agent observation keeps its original source owner, device-registered host,
opaque source binding and local AgentID. Handoff changes the human who may send
the next reviewed prompt. It does not transfer a checkout, CLI login, private
transcript history or provider process. Area editor permission alone never grants
execution. Only the source owner can offer/reclaim; only the named current member
can accept; control revisions and source generations serialize competing changes.

The service stores control snapshots, idempotency receipts and dispatch commands
in the separate encrypted collaboration database. Every route authenticates the
device and current area membership inside its transaction. Prompt admission also
requires the current controller, control revision, source generation, active
requesting device and latest immutable agreement revision. A membership epoch
change requires renewed handoff consent. An old receipt can recover its original
result but cannot restore old control. Context and human identity come from
authenticated state, not client-provided display names or local file paths.

Client control/prompt intents are saved in a per-device local journal before
transport. Acknowledging a queued prompt and replacing its pending record with a
recent receipt is one transaction, so a relaunch can recover the same request and
display its original result. No repeated click allocates a new ID while delivery
is unresolved. Permission/revision refusals are definitive only on these routes
because their durable request lookup precedes those refusal checks; lost network
and removed-membership outcomes retain uncertainty.

The source host has a separate local journal. A claim is durable remotely; the
host writes an irreversible attempt marker before fresh service admission and
before the actual AgentSupervisor intent. Local persistence failure sends
nothing. A previously accepted local outcome can be reported again after a lost
network reply without repeating the intent. An interrupted marker from an older
process becomes uncertain, never an automatic executable retry. Accepted means
Array took responsibility, not that the provider turn completed.

AgentID/project ownership resolves the local executor. TileID is a view binding:
closing or reattaching a tile neither changes logical host generation nor mints
an executor. The app retains a host coordinator independently of shared windows;
closing a dialog/view does not stop the original runner. Removing a published
source removes its local admission hooks; a transient disconnect preserves them
and fails closed. Unpublishing resolves queued/claimed receipts as refused in
the same service document transaction, without depending on a later host poll;
already admitted/accepted outcomes are preserved. Ordinary source-owner input uses fresh current control before
handoff and refuses after control is accepted by a teammate. Emergency local Stop
remains available. Remote input has per-call admission rather than a global flag
that another task could borrow across an await.

Synchronous legacy send paths cannot perform fresh network admission and refuse
for published agents. The asynchronous composer and explicit shared controls own
checked sends. Source queue entries retain a typed command mapping in the host
journal; human text is never parsed into an execution grant. Queue drain checks
current control/context again, including after relaunch. A changed or edited
queued payload cannot borrow an older command's authority. The provider remains
owned by the normal strict harness and its CLI-owned auth/readiness policy.

The native handoff dialog saves recipient, exact agreement selection, timing and
unsent prompt in a private per-object draft. Close flushes that draft; a failed
write keeps the window and copyable text. An older acknowledgement only clears
the exact text submitted, preserving edits made while its response was pending.
Startup-held source input keeps its complete text when control cannot be checked.
Held steers and queued compaction recheck authority at their eventual provider
boundary. Shared interrupt-then-send refuses before interrupting a busy provider;
explicit queueing is the supported delayed operation. This avoids inventing an
unrecorded delayed execution grant.

Witness entry points: runCollaborationHandoffChecks covers actual A/B/C HTTP,
exclusive control, current context, duplicate and changed intents, source-host
impersonation, revocation and service reconstruction. runSharedAgentHostDispatchChecks
covers a failed attempt-marker transaction, lost host reporting, client/host
reconstruction, tile reattachment and interrupted-attempt uncertainty through
the production Core dispatcher and real local HTTP. The separate paired native
process harness drives the real supervisor adapter and source/recipient executor
census. Removing the pre-effect attempt marker must make the latter Core witness
RED; removing the shared-input admission hook must make the native ordinary-local
post-handoff refusal witness RED.

SharedAreaHandoffViewChecks drives native Offer/Send controls, exact context and
timing, private draft reconstruction, injected save refusal and newer edits during
a delayed response, and emits light/dark renders. Its supervisor section exercises
late control loss during startup, steer handover, queued compaction and force send
against scripted provider call counts and retained durable work. Successful
restoration cases ensure those negative results do not pass by disabling delivery.

Provider approval, terminal writing, live transcript export and cross-host
provider-session migration are not grants created by this handoff contract.
Actual network partitions can leave provider acceptance unknowable; that result
is surfaced rather than relabeled as an unsent or completed turn.
