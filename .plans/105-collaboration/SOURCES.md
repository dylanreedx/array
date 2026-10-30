# Source register

Research date: 29 October 2026. Links below were consulted during the twelve-agent research pass; core T3/Amp/Warp guides were reopened during documentation. Most product guides and `main`/`master` links are mutable. Treat the date as the evidence boundary and recheck before implementation or competitive claims. Vendor documentation is not independent comparative validation.

## T3 Code

- [Nightly 25 October `.3655`](https://github.com/pingdotgg/t3code/releases/tag/v0.1.3-nightly.20261025.3655): first release evidence identified for guest sharing.
- [PR #24104](https://github.com/pingdotgg/t3code/pull/24104): introducing scope and merge evidence.
- [Stable v0.1.5](https://github.com/pingdotgg/t3code/releases/tag/v0.1.5): 29 October shipping evidence.
- [Guest guide pinned to v0.1.5](https://raw.githubusercontent.com/pingdotgg/t3code/v0.1.5/docs/user/guest-links.md): released feature behavior.
- [Current guest guide](https://github.com/pingdotgg/t3code/blob/main/docs/user/guest-links.md): mutable upstream reference.
- [Guest data exposure fix #26538](https://github.com/pingdotgg/t3code/pull/26538): data boundary failure despite hidden UI.
- [Cached experimental guide at `4f5a0fbe`](https://github.com/pingdotgg/t3code/blob/4f5a0fbe8c2f2e43207529ba616c00591a46d2b6/docs/user/guest-links.md): historical, narrower behavior; not current truth.
- [Cached guest contracts](https://github.com/pingdotgg/t3code/blob/4f5a0fbe8c2f2e43207529ba616c00591a46d2b6/packages/contracts/src/guestShare.ts): historical limits.
- [Multiuser proposal #12283](https://github.com/pingdotgg/t3code/discussions/12283) and [snapshot proposal #6914](https://github.com/pingdotgg/t3code/discussions/6914): proposals, not shipped feature evidence.
- [Remote access](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md): environment/device access context.
- [Campfire](https://campfire.markets/): separately maintained fork; self-described capabilities and limitations, not T3 upstream.

Local clone `/Users/dylan/Documents/personal/t3code` was inspected with read-only Git queries. Checked-out main: `35635211304cfe59d9786a489b105a9b422c5e37` (21 August); cached main: `d14ace8233ad3cf7856b6b834824f888240d67a1` (23 October); cached guest branch: `4f5a0fbe8c2f2e43207529ba616c00591a46d2b6` (23 October). No fetch or checkout was performed. Tests were inspected in the first research pass, not executed.

## Amp

- [Multiplayer docs](https://ampcode.com/docs/collaborate/multiplayer): current participation, host authority, duration and billing.
- [Threads](https://ampcode.com/docs/threads): visibility, contribution, links and exports.
- [Workspaces](https://ampcode.com/docs/collaborate/workspaces): membership and administrative/accounting scope.
- [Runners](https://ampcode.com/docs/cli/runners): machine sharing and execution authority.
- [Multiplayer launch, 22 July 2026](https://ampcode.com/news/multiplayer).
- [Mentions/invitations, 19 August 2026](https://ampcode.com/news/pass-the-orb-to-the-left-hand-side).
- [Usage exploration, 21 August 2026](https://ampcode.com/news/explain-usage).
- [Space, 31 August 2026](https://ampcode.com/news/space): thread-attached calling.
- [Shared runners, 24 September 2026](https://ampcode.com/news/shared-runners).
- [Claude integration, 10 October 2026](https://ampcode.app/news/use-your-claude-plan): not arbitrary external-session interoperability proof.
- [Handoff, 23 October 2025](https://ampcode.com/news/handoff) and [ask to handoff, 13 January 2026](https://ampcode.com/news/ask-to-handoff): context transfer terminology.

## Figma and FigJam

- [Share files](https://help.figma.com/hc/en-us/articles/360040531773-Share-files-and-prototypes).
- [Guests](https://help.figma.com/hc/en-us/articles/4410795216791-Invite-guests-to-organization-resources).
- [Follow/spotlight](https://help.figma.com/hc/en-us/articles/360040322673-Present-to-collaborators-using-spotlight).
- [View options and cursors](https://help.figma.com/hc/en-us/articles/360041065034-Adjust-your-zoom-and-view-options).
- [Viewer history](https://help.figma.com/hc/en-us/articles/29638316371479-See-viewer-history-for-your-files).
- [Version history](https://help.figma.com/hc/en-us/articles/360038006754-View-a-file-s-version-history).
- [Organization security/activity](https://help.figma.com/hc/en-us/articles/360040056294-Privacy-and-security-in-organizations).
- [Branching](https://www.figma.com/best-practices/branching-in-figma/): conceptual precedent; agent runtime merging is a separate problem.
- [Internal profiles](https://help.figma.com/hc/en-us/articles/360039957614-View-internal-profiles): permission-scoped resource visibility.
- [Accessible FigJam](https://help.figma.com/hc/en-us/articles/14477101678359-Create-accessible-FigJam-boards): transient cursor chat limitations.
- [Open sessions](https://help.figma.com/hc/en-us/articles/4410786053911-Invite-visitors-to-an-open-session).
- [Pricing](https://www.figma.com/pricing/): multiplayer terminology, not a recommendation about pricing.
- [Historical multiplayer architecture](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/): historical design evidence, not a current complete specification.

## Excalidraw

- [Official capabilities](https://github.com/excalidraw/excalidraw#excalidrawcom).
- [Room-link construction](https://github.com/excalidraw/excalidraw/blob/master/excalidraw-app/data/index.ts).
- [Presence messages](https://github.com/excalidraw/excalidraw/blob/master/excalidraw-app/collab/Portal.tsx).
- [Collaboration/follow logic](https://github.com/excalidraw/excalidraw/blob/master/excalidraw-app/collab/Collab.tsx).
- [Encrypted persistence](https://github.com/excalidraw/excalidraw/blob/master/excalidraw-app/data/firebase.ts).
- [UI copy: stop, offline, export](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/locales/en.json).
- [Storage rules](https://github.com/excalidraw/excalidraw/blob/master/firebase-project/firestore.rules).
- [Historical room persistence discussion](https://github.com/excalidraw/excalidraw/discussions/2787): not an indefinite retention guarantee.

## Other canvases

- tldraw: [presence](https://tldraw.dev/sdk-features/collaboration), [following](https://tldraw.dev/sdk-features/user-following), [sync](https://tldraw.dev/docs/sync), [commenting](https://tldraw.dev/sdk-features/commenting), [licensing context](https://tldraw.dev/faq).
- Miro: [attention management](https://help.miro.com/hc/en-us/articles/360013358479-Attention-management), [frames](https://help.miro.com/hc/en-us/articles/360018261813-Frames), [Private mode](https://help.miro.com/hc/en-us/articles/9794413310482-Private-mode), [Talktrack](https://help.miro.com/hc/en-us/articles/35405180333202-Talktrack).
- Allume: [updates](https://allume.com/updates/), [FAQ](https://allume.com/allume-faq/). Insufficient detailed evidence for a permission/presence comparison.
- ALLO: [online presence](https://allo.io/help/en/collaboration/use-online-presence): supplementary distinction between live presence and activity history.

## Developer collaboration

- Live Share: [features](https://learn.microsoft.com/en-us/visualstudio/liveshare/overview/features), [security](https://learn.microsoft.com/en-us/visualstudio/liveshare/reference/security), [maintenance status](https://learn.microsoft.com/en-us/visualstudio/liveshare/maintenance-mode).
- Code With Me: [permissions guide](https://www.jetbrains.com/help/ide-services-cloud/getting-started-with-codewithme-for-business.html), [sunset announcement](https://blog.jetbrains.com/platform/2026/03/sunsetting-code-with-me/).
- Zed: [overview](https://zed.dev/docs/collaboration/overview), [channels](https://zed.dev/docs/collaboration/channels), [remote development](https://zed.dev/docs/remote-development).
- Warp: [third-party agent Remote Control](https://docs.warp.dev/agents/cli-agents/remote-control).

## Presence and usage

- [Slack status/availability](https://slack.com/intl/en-gb/help/articles/201864558-Set-your-Slack-status-and-availability/).
- [GitHub profile/status](https://docs.github.com/en/account-and-profile/tutorials/personalize-your-profile).
- [Claude prompt-cache accounting](https://platform.claude.com/docs/en/build-with-claude/prompt-caching): accounting reference, not a live Array telemetry coverage claim.

## Array source and prior direction

- [Agent identity and host-bound record](../../Sources/ContinuumRevivedCore/Agents/AgentRecord.swift).
- [Agent store](../../Sources/ContinuumRevivedCore/Agents/AgentStore.swift).
- [Execution supervisor](../../Sources/ContinuumRevived/App/AgentSupervisor.swift).
- [External-session ownership](../../Sources/ContinuumRevivedCore/ExternalSessions/ExternalSessionHandoff.swift).
- [Project lock](../../Sources/ContinuumRevivedCore/ProjectLock.swift).
- [Workspace API service](../../Sources/ContinuumRevived/App/WorkspaceAPIService.swift).
- [Companion provisioning](../../Sources/ContinuumRevived/App/CompanionRelayProvisioning.swift), [service wiring](../../Sources/ContinuumRevived/App/ContinuumApp.swift), [scopes](../../Sources/ContinuumRevivedCore/Scope.swift), [companion settings](../../Sources/ContinuumRevived/App/CompanionSettingsView.swift).
- [Tile documentation](../../docs/user/tiles.md), [CLI distinctions](../../docs/user/cli-connections.md), [tile multi-selection](../../docs/internals/tile-multiselect.md).
- [Professional software exploration](../97-trustworthy-professional-software/README.md), [agent-awareness exploration](../98-colour-and-agent-awareness/README.md), [neutral design artifacts](../99-neutral-platform-direction/index.html).

Local references point to the working tree, including pre-existing uncommitted work. They are not pinned release claims. The initial attempt to read a README in the neutral-direction folder failed because that folder has design artifacts rather than a README; no prose strategy was inferred from a nonexistent file.

## Implementation follow-up

- [Twelve implementation memos](implementation/README.md): exact current source references and observed gaps by subsystem, including the in-repository relay server, protocol/client, stores, deployment packaging and check products.
- [Yjs official documentation](https://docs.yjs.dev/): shared types, update merging and network independence; no benchmark, native editor binding or library selection was performed.
- [SwiftNIO official repository](https://github.com/apple/swift-nio): networking framework context; not a measured capacity claim for Array's service.
- [Board creation receipt](BOARD-RECEIPT.json): actual card IDs, committed revisions, target board identity and readback results. The companion workspace API was used for authorized live board interaction, not tested as a multiplayer implementation.
