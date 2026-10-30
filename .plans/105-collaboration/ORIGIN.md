# Origin, private scenarios and decision history

29 October 2026. **Internal product research.** The people, project and domain details below explain the need. Do not reuse them in app strings, screenshots, sample workspaces, public documentation, demos or marketing. This file belongs in the internal plan, not `docs/user/` or the website.

## Initial thought

Dylan proposed multiplayer or co-prompting: share an agent, tile or session so it appears on the recipient's machine, either on Array's canvas or possibly through general Claude/Codex sessions. He also proposed Figma-like workspace invitations, collaborator cursors and teammate status with running-agent counts, token usage and current activity.

T3 Code and Amp were the principal inspirations. Other collaborative infinite canvases were to inform the interaction rather than dictate Array's architecture. Dylan explicitly requested at least twelve research agents and explicitly did not want implementation started.

## Latest clarification takes priority

Dylan wants **live token usage from teammates on hover**, potentially by hovering their cursor. There must be no constant usage overlay. Earlier advice to place tokens only in a usage details screen is superseded by that preference. Scope, freshness, accounting and an equivalent keyboard interaction still need design.

He questions the usefulness of sharing only a session while he continues editing local files. He likes all of:

- **Share a workspace**.
- **Share a zone**.
- **Capture area to share**, by dragging/selecting tiles and their layout; perhaps creating a sharing zone.

The assistant's original recommendation to lead with one shared session was a hypothesis, not a decision. The revised exploration centers a shared work area that can contain several people's agents and coordination material.

## Scenario A: isolated execution, coordinated boundaries

Dylan and Kevin are working on Harmony, building the canonical model and integrating DEID rules. They want to work in isolated areas. They have previously sent prompt Markdown files through Slack for each person to give their agents: defining boundaries, what code each agent touches, and what the other person and their agents plan to do.

The need is not necessarily to let both developers type into one agent. It is to coordinate distinct workers and checkouts without repeatedly producing and forwarding handoff files. Shared intent and boundaries matter even when no source files are synchronized.

Do not infer any actual sensitive data, credential handling, production system access, regulatory requirements or particular repository structure from the scenario. None was supplied.

## Scenario B: people thinking together, agents contributing

Dylan and Kevin work through a problem by sending prompts back and forth, giving selected prompts to their respective agents, then exchanging their own thoughts between agent results. The work crosses human conversation and independent agent sessions repeatedly.

The desired improvement is continuity: retain the discussion, prompts, context and results together without cluttering Slack with handoff attachments. Human thoughts need room to remain human discussion until deliberately addressed to an agent.

## How the scenarios change the product thesis

| Earlier framing | Revised exploration |
| --- | --- |
| Invite someone into my one running agent | Share a place where our agents and thinking meet |
| Teammate watches or suggests my next prompt | Both participants retain their own work and coordinate contributions |
| Session link as the main object | Workspace, zone or captured collection as the invitation target |
| Presence as supporting decoration | Presence helps identify who is thinking, reviewing, running work or available |
| Tokens only in a usage drilldown | Live tokens available directly on hover, without persistent overlay |
| Copying an agent may bring code with it | Shared visibility, checkout transfer and execution ownership must be explained independently |

## Product success to investigate

- Both people can find the current agreement, rather than the latest of several attachments.
- Each can identify which person/agent owns a workstream and which checkout it affects.
- A deliberate action sends a specific revision of context to a specific agent.
- Discussion can continue without accidentally starting agent work.
- Agent results can be brought into that discussion with their provenance.
- A colleague can inspect useful changes without assuming those files exist locally.
- The shared canvas preserves helpful relationships among the material.

These are proposed outcomes to observe, not evidence that the feature is effective or implemented.

## Implementation-planning follow-up

Dylan subsequently asked whether the feature can be built, requested **twelve more research agents** focused on implementation, and authorized adding tickets to the empty board above this agent. This authorizes source investigation, a concrete implementation plan and board writes; it does not start the product implementation. The implementation studies and consolidated backlog are linked from the packet README.

The board was resolved through the workspace API using both position and contents, rather than its ambiguous title. The target was `F54D4170-AB61-4595-A4D4-A400B76364A5`, initially empty and directly above agent tile `0E6EB40A-24C4-4978-ACFE-3A3C4FFE799A`. The separate populated board was excluded from writes.
