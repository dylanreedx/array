# Research synthesis: twelve perspectives

Research date: 29 October 2026. Consolidates the twelve-agent investigation from this conversation. Product documentation establishes documented behavior; source inspection establishes code and intent. Neither substitutes for a hands-on test. Array proposals are marked as interpretations. Links and qualifications are maintained in [SOURCES.md](SOURCES.md).

## 1. T3 Code: local source

Clone: `/Users/dylan/Documents/personal/t3code`. Checked-out `main` is `3563521130`, dated 21 August 2026. Cached `origin/main` was `d14ace8`, dated 23 October. Cached `origin/feat/guest-share` ends at `4f5a0fbe8c`, 23 October, with seven commits absent from that cached main.

The guest branch contains concrete contracts, server/orchestration logic, web/mobile controls and tests: 52 changed files, approximately 2,600 added lines in the initial inspection. Relevant paths include `docs/user/guest-links.md`, `packages/contracts/src/guestShare.ts`, `apps/server/src/guest/GuestShareService.ts`, `apps/server/src/orchestration-v2/GuestShareDecider.ts`, `apps/web/src/components/guest/GuestPage.tsx` and `apps/web/src/components/chat/GuestShareControls.tsx`.

The branch's guide describes a narrower early experiment: three pre-invite turns, tool labels with omitted command detail, one-time redemption, and limited pending suggestions. **That guide is stale relative to the released feature.** Branch presence alone did not establish shipping status. Generated Codex `collaborationMode` references describe plan/default behavior and were false positives for human multiplayer. T3 Connect device/environment access is also distinct from inviting a teammate.

## 2. T3 Code: upstream shipping evidence

Guest links entered nightly `v0.1.3-nightly.20261025.3655`; PR #24104 merged 25 October at 01:48 UTC. Stable `v0.1.5` was published 29 October at 13:08 UTC. The feature remains a Labs beta. [Nightly](https://github.com/pingdotgg/t3code/releases/tag/v0.1.3-nightly.20261025.3655), [PR](https://github.com/pingdotgg/t3code/pull/24104), [stable](https://github.com/pingdotgg/t3code/releases/tag/v0.1.5).

Released behavior: one browser guest, no guest account, 24-hour invitation, host online through T3 Connect. Guests see recent/live messages, attachments, reasoning and command output; they submit text/files for the host to send or dismiss. They cannot independently answer approvals, change model, browse host files or see diffs. Sharing can be revoked. [Tagged guide](https://raw.githubusercontent.com/pingdotgg/t3code/v0.1.5/docs/user/guest-links.md).

A subsequent API exposure fix is especially instructive: patches reached guests even though the UI did not display them. Permissions must constrain delivered data. [Fix #26538](https://github.com/pingdotgg/t3code/pull/26538).

Separate ideas: multiuser self-hosting [#12283](https://github.com/pingdotgg/t3code/discussions/12283), snapshot sharing [#6914](https://github.com/pingdotgg/t3code/discussions/6914), and the cached `t3code/peer/handoff` experiment do not establish shipped workspace multiplayer. [Campfire](https://campfire.markets/) describes a separate, unaffiliated multiplayer fork with shared runs, discussion and catch-up; the research found source-only distribution and broader permission boundaries still on its roadmap. Do not attribute its claims to upstream T3.

**Array interpretation:** T3 is a strong reference for owner-mediated consultation, but Dylan's two-person/multiple-agent coordination needs a broader shared object.

## 3. Amp: shared live work

Amp documents same-thread joint prompting on orbs or explicitly shared runners, with environment/files/terminal access. Default activation lasts seven days; mentions can invite teammates and activate multiplayer. The owner pays agent/orb costs; remote MCP tools may operate under the owner's credentials with contributor restrictions. [Multiplayer](https://ampcode.com/docs/collaborate/multiplayer).

Dated developments: [Multiplayer launch, 22 July](https://ampcode.com/news/multiplayer), [teammate invitations, 19 August](https://ampcode.com/news/pass-the-orb-to-the-left-hand-side), [thread calls, 31 August](https://ampcode.com/news/space), and [shared runners, 24 September](https://ampcode.com/news/shared-runners), all 2026.

Amp's thread visibility and contribution controls, persistent URLs and exports offer asynchronous value too. [Threads](https://ampcode.com/docs/threads). Workspace membership, policy and usage accounting live at another scope. [Workspaces](https://ampcode.com/docs/collaborate/workspaces), [usage exploration](https://ampcode.com/news/explain-usage).

Amp's handoff terminology can mean carrying selected context into a new thread, not transferring execution to a colleague. [Handoff](https://ampcode.com/news/handoff). Its Claude-powered integration does not prove support for arbitrary external CLI-session import. [Claude integration](https://ampcode.app/news/use-your-claude-plan).

**Array interpretation:** keep the conversation, artifacts and execution context connected; choose authority more deliberately than copying Amp's broad workspace access wholesale. Message ordering and owner-offline behavior were not established by the inspected documentation.

## 4. Figma: collaboration around an understandable object

Figma separates share audience, inherited/direct access and view/edit abilities. Guests can be limited to particular resources. Independent navigation, explicit following and spotlight focus attention without requiring identical personal navigation. [Sharing](https://help.figma.com/hc/en-us/articles/360040531773-Share-files-and-prototypes), [guests](https://help.figma.com/hc/en-us/articles/4410795216791-Invite-guests-to-organization-resources), [spotlight](https://help.figma.com/hc/en-us/articles/360040322673-Present-to-collaborators-using-spotlight).

Cursor visibility, historical visits, version history and administrative logs serve different purposes. A live presence marker is not a durable review record. [View options](https://help.figma.com/hc/en-us/articles/360041065034-Adjust-your-zoom-and-view-options), [viewer history](https://help.figma.com/hc/en-us/articles/29638316371479-See-viewer-history-for-your-files), [versions](https://help.figma.com/hc/en-us/articles/360038006754-View-a-file-s-version-history).

**Array interpretation:** workspace/zone membership, personal camera, shared arrangement, operation rights and review evidence should have consistent but distinct meanings. Figma's simple editing roles do not cover running shell commands through an agent. Its historical multiplayer architecture article is useful background, not a specification for Array or proof of every current Figma implementation detail.

## 5. Excalidraw: instant rooms and precise exit semantics

Official source separates read-only export from live room sharing. Rooms combine a room identifier and encryption key in the URL fragment; volatile presence includes pointer, selection and idle state. Source includes follow handling and encrypted scene persistence. [App/data](https://github.com/excalidraw/excalidraw/blob/master/excalidraw-app/data/index.ts), [portal](https://github.com/excalidraw/excalidraw/blob/master/excalidraw-app/collab/Portal.tsx), [persistence](https://github.com/excalidraw/excalidraw/blob/master/excalidraw-app/data/firebase.ts).

The UI explicitly says stopping a collaboration session leaves others collaborating, and warns offline room edits will not be saved. Offline standalone support is a different promise. A secret encrypted room does not supply named viewer/operator roles; open-source storage rules permit room access without account-based membership. [UI copy](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/locales/en.json), [rules](https://github.com/excalidraw/excalidraw/blob/master/firebase-project/firestore.rules).

**Array interpretation:** borrow low-friction entry and shared attention. Distinguish leaving, revoking access and stopping execution; encryption alone is not an agent control policy.

## 6. Other canvases: tldraw, Miro, FigJam and Allume

tldraw distinguishes shared records and presence, supports custom presence visibility, and differentiates jumping from following. Its sync documentation describes one authoritative room per document and schema evolution. Its comment controls require server-side authorization and authenticated attribution. [Presence](https://tldraw.dev/sdk-features/collaboration), [following](https://tldraw.dev/sdk-features/user-following), [sync](https://tldraw.dev/docs/sync), [comments](https://tldraw.dev/sdk-features/commenting). This is a licensed React SDK, not a recommendation to replace Array's native canvas.

Miro offers following and attention tools; hidden-frame titles/comments may remain visible, and Private mode is explicitly not data protection. [Attention](https://help.miro.com/hc/en-us/articles/360013358479-Attention-management), [frames](https://help.miro.com/hc/en-us/articles/360018261813-Frames), [Private mode](https://help.miro.com/hc/en-us/articles/9794413310482-Private-mode).

FigJam distinguishes temporary, account-free open sessions from lasting membership. Miro Talktrack offers contextual asynchronous walkthroughs. [Open sessions](https://help.figma.com/hc/en-us/articles/4410786053911-Invite-visitors-to-an-open-session), [Talktrack](https://help.miro.com/hc/en-us/articles/35405180333202-Talktrack).

The Muse/Allume investigation found a rename and collaboration references but insufficient primary detail to assert precise current permission/presence semantics. Keep it secondary. [Updates](https://allume.com/updates/), [FAQ](https://allume.com/allume-faq/).

**Array interpretation:** capture and share purposeful content with explicit membership. Live presence, persistent discussion and executable authority are different systems. Async return and catch-up matter alongside live cursors.

## 7. Developer collaboration: hosted execution and market caveats

VS Code Live Share hosts files and execution on one machine with selectively shared code, terminals and servers. Read/write terminal permission is separate from observation. [Features](https://learn.microsoft.com/en-us/visualstudio/liveshare/overview/features), [security](https://learn.microsoft.com/en-us/visualstudio/liveshare/reference/security).

Code With Me offers view/edit/full/custom permissions and escalation. Zed combines persistent channels and separately shared hosted projects; following is pane-specific and terminal following is documented as unsupported. [Code With Me](https://www.jetbrains.com/help/ide-services-cloud/getting-started-with-codewithme-for-business.html), [Zed channels](https://zed.dev/docs/collaboration/channels).

Warp documents third-party agent sharing across browser/mobile/desktop, with viewing versus input/approval control and publisher revocation. It does not establish process migration to a recipient. [Remote Control](https://docs.warp.dev/agents/cli-agents/remote-control).

Current-status caveats: Microsoft documents Live Share in maintenance mode as of 27 May 2026. JetBrains announced Code With Me's sunset on 16 March 2026, with public relay shutdown planned for Q1 2027. These are design precedents, not evidence that synchronous pairing alone is a growing market. [Microsoft](https://learn.microsoft.com/en-us/visualstudio/liveshare/maintenance-mode), [JetBrains](https://blog.jetbrains.com/platform/2026/03/sunsetting-code-with-me/).

**Array interpretation:** prioritize the recurring work of coordination, review and handoff alongside synchronous pairing. Being able to join from a browser may lower invitation friction, but remains an option to evaluate.

## 8. Array architecture: existing foundations, not existing multiplayer

Stable agent identity is separate from the tile view; persisted records remain host-bound. Supervisor execution ownership, project locks, explicit workspace API grants, external-session watching/moving and multi-selection provide relevant contracts. Hosted companion relay wiring exists in current source, qualifying stale blanket descriptions of all sync as disabled. None establishes a multiuser collaborative canvas. [Detailed source-grounded model](SHARING-MODEL.md).

**Array interpretation:** a person, agent session, tile view, shared area, permission grant and execution checkout are separate conceptual objects. Do not copy host-bound records or share `.array/` files as a shortcut to collaboration.

## 9. Naming and professional positioning

Figma and Zed use multiplayer language in professional products; Amp uses it directly for shared prompting. The word is compatible with serious software, though less distinctive in this category now. [Figma](https://www.figma.com/pricing/), [Zed](https://zed.dev/docs/collaboration/overview).

| Candidate | Potential role | Limitation |
| --- | --- | --- |
| Collaboration | Umbrella/navigation | Broad but clear |
| Shared workspace / shared zone | Concrete invitation object | Must match actual data/layout scope |
| Shared area | Captured collection | Must not add a confusing parallel container |
| Multiplayer | Launch language | Already widely used |
| Co-prompting | Joint agent direction | Too narrow for shared thinking and isolated agents |
| Array Live | Optional synchronous brand | Too narrow for async collaboration |
| Pair session | Temporary activity | Suggests two people; human–AI ambiguity |
| Room / teamspace | Social container | Duplicates existing workspace/zone vocabulary |
| Players / lobby / party / squad | Strong game metaphor | Larger personality change than Dylan has chosen |

Candidate copy: **Share workspace…**, **Share zone…**, **Capture area to share…**, **Invite**, **Join**, **Follow**, **Leave**, **Stop sharing**. Potential positioning: **Work together, with your agents.** No final naming decision or trademark clearance was performed.

## 10. Presence and teammate status

Separate human availability, attention and agent execution. Slack/GitHub provide precedents for chosen status, scope and expiration; Zed and Amp provide contextual collaborator presence. Live presence should not masquerade as historical review or a productivity metric. [Status references and detailed proposal](PRESENCE.md).

The first research recommendation put tokens in a separate details view. **Dylan explicitly superseded that with live token usage on hover, no constant overlay.** The proposal now preserves that requested interaction and leaves measurement/scope questions explicit.

## 11. Control, trust and concurrency

Observation, human discussion, suggested prompts, direct prompting, stopping, approvals, terminal input and sharing management affect different things. T3's mediated input and Amp's broad shared environment are useful endpoints. An Array policy should explain real authority and which host/account executes work.

Promising hypotheses: one authoritative executor per session; attributed ordered inputs; idempotent reconnect; separate pending suggestions; explicit interruption; revocation distinct from undo. No competitor's exact concurrency implementation was verified. See [sharing model](SHARING-MODEL.md).

## 12. Product scenarios and the revised center

The first scenario study favored bringing an individual remote agent into a personal canvas, with independent placement. It also identified shared work areas, durable workspaces, async handoff and artifact-based review.

**Latest correction:** Dylan's examples center two people coordinating their own agents and thinking together. Preserve standalone session sharing as a component, while investigating workspace/zone/captured-area sharing as the primary experience. [Origin](ORIGIN.md), [journeys](WORKFLOWS.md).

The strongest hypothesis is that Array can keep shared intent, current boundaries, human discussion, selected agent context and versioned results together. It should reduce re-packaging without pretending isolated checkouts are automatically synchronized. This fits the existing professional direction's emphasis on understandable, steerable work rather than a social layer added for its own sake.
