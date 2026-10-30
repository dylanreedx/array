# Shared-area workflows to explore

29 October 2026. Product hypotheses; no implemented collaboration UI. All examples here use generic project details. The private motivating examples are confined to [ORIGIN.md](ORIGIN.md).

## 1. Work separately with a shared agreement

Two developers join a shared zone for one feature. Each continues running agents against their own checkout. The zone contains their relevant agent views, a shared brief, current boundaries, decisions and reviewable results.

An illustrative agreement could contain:

- Developer A: owns the core data types and public interface.
- Developer B: owns the transformation layer and validation.
- Both: discuss interface changes before updating the agreement.

This is coordination material, not automatically a sandbox or enforced filesystem policy. A note that says “do not edit this directory” cannot guarantee an agent obeys it. Any future hard restriction would need an actual execution mechanism and behavioral evidence.

Proposed journey:

1. Create or capture a shared area and invite a teammate.
2. Add both participants' relevant agent views and a jointly editable agreement.
3. Agree on a revision before dispatching instructions.
4. Each person deliberately sends the relevant context to their own agent.
5. Show delivery state and revision separately for each agent.
6. Discuss proposed changes to the boundaries before sending a new revision.
7. Review each contribution against an identified code revision.

Potential state vocabulary: **Draft**, **Agreed**, **Sent to selected agent**, **Delivery confirmed**, **Agent response received**, **Changed since last sent**. These are proposals, not a schema or a promise that existing CLI protocols expose every acknowledgment. Delivery is not proof of understanding or compliance; an agent's own acknowledgment is not verified enforcement.

The agreement should be one discoverable object. A new edit should not silently rewrite an already executing prompt, and agents should not be described as aware of changes they have not received.

## 2. Discuss, consult agents, discuss again

Two developers investigate a design together. Their discussion includes their own thoughts, selected agent answers, references and proposed next questions.

Candidate interaction:

1. Write a human message in discussion attached to the area or an artifact.
2. Select a passage or compose a proposed instruction.
3. Choose **Send to agent…**, inspect the included context and choose a target.
4. The target's owner or an authorized collaborator sends it under that agent's actual permissions.
5. Bring a selected answer or versioned artifact back into the discussion.
6. Retain links to the source turn and revision, rather than cloning every long transcript into the human conversation.

Sending to multiple agents could be useful, but it should show the recipient set and resulting separate runs. Mentioning a person need not trigger an agent; mentioning an agent need not start work unless the interaction explicitly says so. Automatic dispatch is an open alternative, not a default decision.

The conversation might be an area discussion tile, artifact comments or a side panel. It does not require adding a general Slack replacement to Array. The research question is whether the surrounding context makes this specific development conversation easier.

## 3. Capture an area to share

Candidate flow:

1. Invoke **Capture area to share…** and drag a region, or start from the current tile selection.
2. Highlight the included tiles; allow explicit correction of the set.
3. Review what each included tile shares and whether it is live or frozen.
4. Preserve relative positions, sizes and useful grouping in the proposed area.
5. Name it, choose participants and permitted actions, then share.
6. The recipient opens the shared arrangement in Array, with a browser participation option worth investigating separately.

This is a structured capture, not necessarily an image. A separate **Share snapshot** option could deliberately freeze content and layout for an async handoff.

Important unresolved choices:

| Question | Alternatives to compare |
| --- | --- |
| How are tiles selected? | Fully enclosed by rectangle; any intersection; selection before sharing. Always preview membership. |
| Is a sharing area an existing zone? | Make a zone shared; create a new zone; reference selected tiles without moving them. |
| What if selection spans projects/zones? | Preserve origin ownership through references; split into groups; require a narrower selection. |
| Is layout synchronized? | One jointly arranged area; private placements of shared references; a local container holding a shared internal arrangement. |
| What happens when a tile moves across its border? | Explicit add/remove; geometric inclusion with confirmation. Avoid accidental publication through proximity. |
| What joins later? | Explicitly added objects; never assume every nearby future terminal becomes shared. |
| Can an object belong to multiple areas? | Potentially through references, while retaining one actual runtime owner. |

Existing multi-selection preserves project/zone ownership even across a group transformation. A sharing gesture must not quietly reassign those owners. See [current interaction contract](../../docs/internals/tile-multiselect.md).

## 4. Share an existing zone or whole workspace

Sharing a zone offers a purpose and a visible boundary. Sharing a workspace offers a durable meeting place for several workstreams. Both need a review of included surfaces and inherited access before invitation.

Keep personal cameras independent. Explore **Go to teammate**, **Follow teammate**, **Show this tile** and **Invite to look here**. Ordinary navigation should restore local camera control. Shared layouts make cursor coordinates meaningful; independent layouts need presence attached to content or objects instead.

Durable workspace membership raises a different availability question from a temporary hosted session: can the discussion and last known artifacts remain accessible when an execution host sleeps? What can continue running? These need separate answers.

## 5. Review, integrate or take over

Reviewing a remote diff does not integrate it. Compare explicit actions:

- **Inspect shared changes**: read a particular remote revision.
- **Bring changes into my checkout**: apply a selected patch or Git revision, with actual conflict outcomes.
- **Collaborate on this host**: continue operating the existing environment under granted authority.
- **Continue locally**: establish local code/context/authentication and a distinct or transferred execution owner.

These should not be synonyms for accepting an invitation. The teammate should always know which checkout the next action changes.

## Storyboard evaluation, when requested

Use a realistic two-person task with independent agents. Compare today's prompt-file exchange with a shared zone and with a captured area. Observe whether participants find the current agreement, choose the intended agent, notice stale context, understand code location, and make a useful contribution with less re-explanation.

Include one changed agreement, one contradictory prompt, one code revision changing during review, and one host disconnect. Evaluate useful contributions and preserved understanding rather than cursor count or token volume. No study or prototype was run in this documentation task.
