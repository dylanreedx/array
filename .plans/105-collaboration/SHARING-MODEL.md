# What is shared, where code lives and who acts

29 October 2026. Conceptual distinctions and unresolved product choices, not an architecture specification.

## Do my local changes come with the invitation?

**They can be visible without becoming files on the recipient's machine.** A live view can show the host's evolving diff, selected file content, preview or terminal output if those surfaces are deliberately included. Whether those views are available is part of the sharing contract.

Accepting an invitation does not by itself update another checkout. Shared execution can also let a colleague operate the original environment, but then the changed files still live there. Neither behavior is implemented as Array multiplayer today.

| Model | What the colleague sees/does | Where code changes live | What needs a separate decision |
| --- | --- | --- | --- |
| Live observation | Watches selected agent/artifact surfaces | Original host | Which artifacts and history are exposed |
| Shared control | Prompts or operates the same host | Original host | Exact action authority and execution attribution |
| Independent work, shared context | Each runs their own agents against an agreed plan | Each developer's checkout | Context distribution and integration boundaries |
| Explicit patch/commit exchange | Reviews and imports a chosen code revision | Recipient after successful application | Base revision, uncommitted changes, conflicts and acknowledgment |
| File synchronization | Receives changing files | Multiple synchronized copies | Conflict handling, generated files and execution isolation |
| Common remote checkout/environment | Both act on one environment | Shared host | Concurrent writers, availability, access and resource ownership |
| Execution transfer | Continues work on a different host | New host after transfer/setup | Code, environment, provider resume support and release of the old owner |

The private scenarios strongly motivate the independent-work model, with live context and optional explicit code exchange. They do not require choosing it exclusively for all collaboration.

If Developer A keeps working while Developer B reviews, distinguish **live latest** from **the revision under review**. Comments and check results should identify their artifact revision. When code advances, show that the review target changed rather than silently carrying an approval onto new content.

## Share several layers independently

| Layer | Examples |
| --- | --- |
| Arrangement | Tile geometry, grouping, shared-zone structure |
| Presence | Cursor, selection, attention, availability |
| Human collaboration | Discussion, decisions, proposed prompts |
| Agent context | Briefs, agreed boundaries, explicitly supplied references |
| Agent events | Attributed prompts, output, queued inputs, observed run state |
| Artifacts | Versioned diffs, files, checks and preview access |
| Authority | Prompt, stop, approve, edit files, control terminal, manage sharing |
| Execution | Host, checkout, runner, CLI authentication and actual processes |

Canvas geometry, discussion edits and irreversible execution events require different conflict/recovery semantics. Synchronizing a document cannot by itself safely duplicate or merge running agent processes.

## Permissions are concrete actions

Possible capabilities include view, discuss, suggest, submit prompts, stop runs, answer tool approvals, control terminal, edit shared arrangement, add/remove shared content and manage invitations. The product may bundle these into understandable roles, but “editor” alone does not explain them.

Prompting can already cause real file changes under an agent's existing permissions. An approval grant is not required for every effect if the agent's current policy permits those effects. UI wording must reflect the actual runner policy.

One authoritative executor and an ordered input queue per running session is a promising model to investigate. Several people can draft, discuss and propose concurrently; accepted execution inputs need stable identity, ordering and authorship. An accepted suggestion should retain the proposer and accepting operator. Interrupting a turn is different from queuing the next one.

Share access must constrain delivered data. Hiding a file row after delivering its contents is not a boundary. A shared region's border must correspond to explicit object/data membership, not merely visual cropping. Excalidraw's secret-room links and Miro's private/hidden presentation controls illustrate why presence and visual hiding are different from execution authorization. See [research](RESEARCH.md).

## Useful independent actions

**Leave area**, **remove participant**, **revoke invitation**, **stop sharing**, **stop agent**, **fork work**, and **transfer execution** have different effects. Ending shared access need not terminate the owner's agent. Already executed changes cannot be undone by revoking a link.

On disconnect, distinguish a person's presence, their host's availability, cached artifacts and confirmed execution state. A disconnected host is not proof that its process stopped. Queuing input offline needs an explicit policy; reconnect must not duplicate a previously accepted request.

Provider authentication stays with its CLI. Collaboration must not require exporting credentials or pasting API keys. Sharing use of an already authenticated host and establishing a recipient's own authenticated runner are separate models.

## Existing Array foundations and constraints

- [AgentRecord](../../Sources/ContinuumRevivedCore/Agents/AgentRecord.swift) separates stable agent identity from its nullable tile binding. It explicitly marks the persisted record as host-bound and unsuitable for sync. A shared view should not simply serialize that record.
- [AgentSupervisor](../../Sources/ContinuumRevived/App/AgentSupervisor.swift) owns active runners and rejects stale ownership. Multiple views must not create multiple executors.
- [ExternalSessionHandoff](../../Sources/ContinuumRevivedCore/ExternalSessions/ExternalSessionHandoff.swift) distinguishes read-only watching from moving execution here. Unknown ownership never counts as released.
- [ProjectLock](../../Sources/ContinuumRevivedCore/ProjectLock.swift) exclusively locks `<root>/.array/lock`. Sharing that directory between live writers is not a collaboration transport.
- [WorkspaceAPIService](../../Sources/ContinuumRevived/App/WorkspaceAPIService.swift) routes through actual owners and host-minted grants. Existing callers are agent identities, not a ready-made human collaboration permission system.
- [Companion relay provisioning](../../Sources/ContinuumRevived/App/CompanionRelayProvisioning.swift) and [boot/service wiring](../../Sources/ContinuumRevived/App/ContinuumApp.swift) provide source-level evidence of hosted relay and scoped companion paths. This qualifies the orientation's blanket description of sync as gated off; it is not proof of deployed multiplayer.
- [Multi-selection](../../docs/internals/tile-multiselect.md) already preserves layout and source ownership across selected tiles. It is relevant interaction precedent; it does not implement captured-area sharing.

## “Any Claude/Codex session” needs its own capability study

Distinguish managed Array sessions, interactive CLI terminal tiles, locally discovered external sessions, remote sessions viewed through a client, and sessions resumed on a new machine. Structured transcript observation does not automatically provide safe concurrent input or portable execution.

For every runner, investigate observation, attachments, prompt submission, cancellation, approval handling, resume ownership and usage telemetry separately. An invitation should not imply universal CLI interoperability. No cross-machine provider compatibility test was performed here.
