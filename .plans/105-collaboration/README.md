# Collaboration: shared workspaces, zones and captured areas

Captured **29 October 2026**, continued **30 October**. Dylan authorized starting multiplayer on 29 October. Core, membership service, live transport, review preparation, scoped accounts and an initial native shared-scene UI are implemented in part. Source capture/review UI, agent handoffs and hover-only usage remain open. See [implementation progress](PROGRESS.md) and [initial implementation decisions](DECISIONS.md).

**Working direction: a shared place for people and their agents to coordinate work, exchange context, discuss ideas and inspect results while preserving explicit execution and code ownership.**

Dylan's latest direction favors **Share a workspace**, **Share a zone**, and a drag-to-select **Capture area to share** interaction that preserves selected tiles and their layout. Sharing a single session remains a possible capability inside this experience; it is not the adopted product center or a prerequisite MVP.

## Read this packet

- [Implementation plan](IMPLEMENTATION-PLAN.md): feasibility, recommended architecture, phased delivery, dependencies and scope gates.
- [Ticket catalogue](TICKETS.md): actionable planned work, acceptance criteria and witnesses; mirrored to the explicitly selected board.
- [Twelve implementation studies](implementation/README.md): source-grounded follow-up to the initial twelve-perspective product research.
- [Origin and decisions](ORIGIN.md): actual motivating workflows, latest preferences, and corrections to the first brainstorm. Internal context only.
- [Shared-area journeys](WORKFLOWS.md): isolated agents with coordinated boundaries; discussion interleaved with agent work; capture and invite.
- [What sharing means](SHARING-MODEL.md): local files, shared execution, patches, shared layout, permissions and unresolved choices.
- [Presence and live tokens](PRESENCE.md): live teammate usage on hover, with no permanent usage overlay.
- [Research synthesis](RESEARCH.md): all twelve research perspectives, competitive evidence, naming and lessons for Array.
- [Source register](SOURCES.md): primary links, local source references and evidence qualifications.
- [Verification record](VERIFICATION.md): what was inspected, checked and left unverified.

Related: [professional software direction](../97-trustworthy-professional-software/README.md), [agent awareness and artifact feedback](../98-colour-and-agent-awareness/README.md), and [existing multi-selection interaction](../../docs/internals/tile-multiselect.md).

## Latest preferences and what remains open

| Item | Status |
| --- | --- |
| Start multiplayer from the board above this agent | Latest explicit scope; implementation authorized |
| Shared workspace, shared zone and captured-area sharing | Explicit positive direction; explore all three |
| Live teammate token usage on cursor hover or similar | Explicit preference; no constant usage overlay |
| Coordinate people and their separately running agents | Concrete motivating workflow |
| Human discussion interleaved with deliberate agent prompts | Concrete motivating workflow |
| Names and work-specific details from the origin story | Internal research context; never proposed app/demo copy |
| Make single-session sharing the first product milestone | Earlier assistant suggestion; not adopted and now challenged |
| Initial scope, layout ownership and captured-area membership | Reviewed portable projections, jointly arranged inner geometry and private cameras; [decision record](DECISIONS.md) |
| Local checkouts versus a common remote environment | Initial implementation preserves separate checkouts; explicit code import and richer execution sharing remain later work |
| Final feature name | Unresolved |

## What changes when a workspace is shared?

Several independent things can be shared: layout, live agent activity, conversation, artifact revisions, code access and execution control. An invitation must make the actual combination understandable.

If one developer's agent edits local files, collaborators can potentially **see the changes live** through explicitly shared diff/file views, or **operate that same host** if granted control. Their independent checkout does **not automatically acquire those changes**. Bringing code into another checkout needs a separate mechanism such as an explicit patch, commit/branch exchange, file synchronization, or a common execution environment. Those mechanisms are product choices, not current Array capabilities.

For the motivating workflow, separate checkouts may be desirable: both developers continue their own work while the shared area carries plans, boundaries, decisions, prompts and reviewable changes. The key research question is whether that shared context removes the repeated packaging and explanation currently happening in chat.

## Candidate sharing actions

| Action | Candidate experience |
| --- | --- |
| **Share workspace…** | Invite people into a durable collaborative canvas containing multiple owners' work. |
| **Share zone…** | Share a bounded work area and its deliberately included surfaces. |
| **Capture area to share…** | Drag a region or select tiles, review included content, preserve their relative arrangement, then create a shared area or snapshot. |
| **Share session…** | Share an individual agent as one object; useful within the broader work area. |

Capture is a selection gesture. The implementation now connects source workspace/zone/area actions to a reviewed portable projection in an ordered shared area; source tile geometry and executor ownership stay local. Native capture, shared scenes and private cameras are wired. Live observations, shared drag/undo, agent context dispatch, hover usage, durable delivery recovery, frozen artifacts and code import remain open. See [current progress and evidence](PROGRESS.md).

## Naming direction

Use **Collaboration** as a provisional umbrella, with **workspace**, **zone**, **shared area**, **invite**, **join** and **follow** for concrete concepts. **Multiplayer** remains credible launch language; Figma and Zed demonstrate professional use of that vocabulary. **Co-prompting** describes one activity rather than the whole shared environment. No final name has been chosen.

Professional quality here means truthful ownership, dependable interaction, preserved work and understandable state. It does not require eliminating memorable language.

## Research questions for the next conversation

1. What must travel with a captured area for a colleague to contribute: live sessions, selected history, plans, files, diffs, previews, discussion, or all of these?
2. Should both people author the shared arrangement, or can it initially be a shared area placed inside each personal canvas?
3. How do shared boundaries reach each participant's agents, and how do people know an agent has actually received the current revision?
4. When does a human message become agent input, and how is the target chosen?
5. Do participants want to review code remotely, bring a revision into their own checkout, or work in the same environment?
6. What remains accessible when a collaborator closes their laptop?
7. What should cursor-hover usage mean by default: the current shared area, all shared work, or an explicitly shared personal aggregate?

These remain product questions to resolve in the planning gates. The later [implementation plan](IMPLEMENTATION-PLAN.md) and [tickets](TICKETS.md) propose a concrete path; creating them does not authorize executing the feature work.
