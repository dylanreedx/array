# Share redesign: one agent, or a portal

1 November 2026. Design round and feasibility read. No production code.
Bench `.worktrees/mp-share-design`, branch `array/mp-share-design`, on
`origin/array/integration` 2af6fdd8 (the 0.7.37 release).

## What Dylan said about 0.7.37

- Sharing makes a new isolated zone with a discussion panel down its right
  side ("Select an object / Workspace / Post"). He does not want that panel.
- He shared an agent and a browser, and only the agent arrived. Another
  agent is fixing that bug. The cause is noted below so this design does not
  repeat it.
- What he wants: "quickly share an agent and its context to someone". That
  means one shared agent tile on their canvas, with no special zone.
- He also likes "a tile that was like a portal into someone else's canvas",
  but isn't sure it can work.

## Recommendation

Build **(A) Share one agent** first, then **(B) the portal tile**. Delete the
discussion panel now. Delete the shared-zone flow once B ships.

**(A) is mostly a re-wire.**
- The relay, the area-as-permission-container, links, admission, remote
  prompting, the host's projection and the host session already exist.
- The new pieces:
  - Copy stops moving the host's tile into a zone.
  - The guest gets one new tile kind.
  - The agent projection learns to carry prompts and who sent them.

**(B) works if it re-draws and never streams pixels.**
- The portal re-draws the host's agents, notes, files and diffs from synced
  data, at the positions they hold on the host's canvas.
- A browser can only be re-loaded from a public URL, or shown as a still.
- Terminals stay private.
- There is no pixel transport, and the relay could not carry one: it is
  HTTP long-polling with a 256 KiB request cap.

**Nothing is typed at portal scale.** To act on an agent in the portal, Sam
presses "Open beside". That lifts the agent out as the same tile as in (A).
So B reuses A, and A has to come first.

## Stills

In `share-redesign/`, light and dark:

- `share-agent-dark.png`, `share-agent-light.png`: (A), four panels.
- `portal-tile-dark.png`, `portal-tile-light.png`: (B), four panels.

**What is real and what is drawn.**
- Real: the production canvas, mounted through `WorkspaceInvariantsFixture` →
  `mountWorkspaceSceneAtBoot`. That covers real zone chrome, managed-agent
  tiles fed through `ingest`, note tiles, the real header Share button and
  the real `ShareLinkPopoverView`, run on a fake link service.
- Drawn on top in Array's tokens:
  - the owner tab
  - the person outline
  - the per-prompt author tags
  - the arrival banner
  - the offline footer
  - the portal's chrome
  - the browser and terminal tiles (the fixture cannot mount live WebKit or
    Ghostty offscreen)
- The portal's body is a real capture of the host's canvas, scaled into the
  tile.

**Fixture artefacts to ignore.**
- Each agent opens with "Notice · Previous session", because the fixture's
  records restore as idle.
- The composer's location row says "Alder", the fixture directory's name.
  On a real guest's shared tile it should name the host's checkout and Mac.
  That is part of slice A2.

**To regenerate.** The renderer is a throwaway, uncommitted in the bench:
`CollabShareRedesignMockSheet.swift` on top of the earlier round's
`CollabInCanvasMockSheet`.

```sh
.worktrees/.locks/app-build.sh swift build --product Array
T=$(mktemp -d /tmp/share-redesign-XXXX); mkdir -p $T/tmux; unset TMUX TMUX_PANE
TMUX_TMPDIR=$T/tmux CONTINUUM_APP_SUPPORT=$T/support \
  .build/debug/Array --share-redesign-mock-sheet qa-runs/share-redesign
```

Windows are off-screen and never take focus.

### (A) panels

1. **Dylan shares from the header.** The real 0.7.37 Share button and
   popover. What changes is what Copy does: the agent stays where it is, no
   zone is made, and no tile moves.
2. **Sam's canvas.**
   - The link lands one agent tile in Sam's own zone, beside his work.
   - Dylan's colour edges it, and a tab on the top edge says "Dylan's · runs
     on Dylan's Mac".
   - A banner says what arrived, with Show.
   - Sam prompts it from the normal composer.
   - Both prompts carry a name: "Dylan · 10:40" and "You · 10:52".
3. **Dylan's side after Sam joins.**
   - The same tile, still in Dylan's zone.
   - A tab reads "Yours · shared with Sam".
   - Prompts are tagged "You" and "Sam".
   - The real popover lists Sam ("opened 10:48 · full access") with Remove
     and "Revoke everyone's access".
4. **Dylan's Mac goes offline.**
   - Sam's tile dims, with a dashed edge.
   - The composer gives way to "Dylan's Mac is offline · showing the last
     update, 4 min ago. Prompts wait until Dylan's Mac is back."

### (B) panels

1. **The Share tool over part of Dylan's canvas.**
   - Releasing opens the same popover, retitled "Share this part of your
     canvas", with the slug `checkout`.
   - The terminal inside the marquee is marked "Stays private" and is not
     listed.
   - No tile moves.
2. **Sam's canvas: one portal tile.**
   - The header reads "Dylan's canvas · Checkout · Live · runs on Dylan's
     Mac", with avatars.
   - The body shows Dylan's region with his cursor.
   - Agents and notes are marked Live. The localhost browser is a "Still".
   - The terminal is a "Terminal stays on Dylan's Mac" card.
3. **Acting on something in the portal.**
   - Hovering the agent offers "Open beside".
   - That lifts the agent out as the (A) tile, full size, with its composer
     and author tags.
4. **Dylan's Mac goes offline.** The portal dims to the last update with a
   dashed edge, and its header says so.

## What exists in 0.7.37

All paths are under `Sources/`.

### Share flow

- **Host, entry points.** These are in `ContinuumApp.swift`:
  `shareAgentTile` (12369), `shareAgentFromInbox` (12377), `beginShare`
  (12398) and the Share tool `armShareTool` (12408). Each builds a
  `ShareTarget` in `shareTarget(tileIds:origin:)` (12329), which drops
  terminals only.
- **Host, popover.** `ShareEntryCoordinator.present` shows
  `ShareLinkPopoverView` over a `ShareLinkSession`. Nothing is published
  before the first Copy.
- **Host, Copy.** `ShareLinkSession.copy()` calls
  `createSharedZone(fromTiles:name:)` (`SharedAreaZoneSession.swift:370`).
  That does four things:
  - creates the area;
  - publishes the tiles (`ShareLinkCoordinator.publish`, then the
    publication review and manifest, then `submitPublication`);
  - opens the area's zone on the host's own canvas;
  - **moves the host's real tiles into it** (`lendTilesToSharedArea`,
    `CanvasNSView.swift:7535`).
- **Guest.** `application(_:open:)` → `ShareLinkCoordinator.open` →
  `ShareLinkOpener.open` (join or accept) → `openSharedArea` →
  `ensureSharedAreaZone` (`WorkspaceRuntime.swift:2318`). The last call
  makes a `ZonePlacement(projectId: nil, sharedAreaId:)`. Its body is
  `SharedAreaSceneView` in `.zone` presentation, which contains the dock.
- **Transport.** HTTP JSON under `/collaboration/v1`, with long-poll reads
  held at most 25 s. The request body cap is 256 KiB. Presence is coalesced
  to 20 Hz. Nothing streams pixels anywhere: no ScreenCaptureKit, and no
  image frames over the relay.

### What each tile kind publishes today

The rule is `SharedAreaPublication.disposition`
(`SharedAreaPublication.swift:268`).

| Kind | What the relay gets | What the guest sees |
| --- | --- | --- |
| Agent | An `agentObservation` plus a projection: assistant text, tool kind and status, phase. At most 32 rows and 3 KiB a row. The host pushes every 2 s; the guest polls every 1 s. **No prompt text, reasoning or tool output.** | A `SharedAgentLiveView` inside `SharedAreaZoneAgentView`. It can prompt or queue, but not stop, steer or approve. |
| Note | A one-time snapshot, posted as a `discussion` item | A card with the text, and a thread in the dock |
| File, diff | An `artifact` snapshot: SHA-named blobs, at most 1 MiB a blob and 8 MiB a revision | Revisions in the dock, with Approve or Request changes. The canvas card reads "Artifact content unavailable". |
| Browser | Nothing: `.unsupported(.tileKind)` | Nothing |
| Terminal | Refused before publishing | Nothing |

**Why the browser never arrived.** `shareTarget` and `lendableTile` reject
only terminals. So the host's browser is moved into the shared zone, but
`disposition` publishes nothing for it. The guest never gets it, and after a
relaunch `relendBoundTiles` drops it from the host's zone as well. The fix
belongs to the other agent. This design avoids the trap by never moving host
tiles at all.

### Who sent a prompt

- `AgentSupervisor.acceptSharedAgentPrompt` (`AgentSupervisor.swift:7696`)
  records the requester only in `lastPromptAuthors`.
- `recordTranscriptUserPrompt` (:8752) stores the prompt text with no author.
- The only attribution anywhere is one "last prompt" line, built by
  `SharedPromptAuthorship.label`.
- The guest never sees anyone's prompt text: the projection's allowlist
  leaves prompts out on purpose
  (`CollaborationAgentProjection.swift:4-8`).

## (A) Share one agent: feasibility

**Verdict: feasible.** Roughly two thirds is reuse.

### What can be reused

- Area creation, `registerHost`, `ShareLinkCoordinator.publish` with the
  agent in observation mode, links (`createShareLink`, `listAccess`,
  `revokeLink`, `removeAccess`), link opening and admission.
  - The area stays as the permission and membership container. It becomes
    invisible: no zone, no name on screen.
- `SharedAreaHostSession`, `SharedAreaAgentProjectionHost`,
  `SharedAgentProjector`: the host streams the agent.
- `SharedAreaHandoffCoordinator`, `SharedAgentControlAdmission`,
  `SharedAgentHandoffController.prompt`: remote prompting, including part 4's
  full access, with receipts. The prompt still runs once, on the host.
- `SharedAreaPersonColour` (avatars, initials, the host's colour) and the
  last-prompt pill in `AgentCompactStatusRowView`.
- The popover itself, unchanged for one agent.

### What changes on the host

1. **Copy no longer converts.** `ShareLinkSession` gets a "share agent"
   creator in place of `createSharedZone` for `origin == .agent`. It creates
   the area, publishes the one agent and registers the host. It does not
   call `openSharedArea`'s zone path or `lendTilesToSharedArea`. The tile
   keeps its zone, its frame and its runner.
2. **The header mark.** A "Yours · shared with Sam" tab on the tile's top
   edge, with people from `listAccess`. The header band has no room left: in
   the stills, a chip in the header covered the title.
3. **Per-prompt authors.**
   - `acceptSharedAgentPrompt` passes the requester into
     `recordTranscriptUserPrompt`.
   - The user node in AgentContent gets an optional author.
   - The renderer draws the tag.
   - Local prompts read "You".

### What changes on the guest

1. **A new tile kind, `sharedAgent`.**
   - It lives in an ordinary project `ZoneLayer`, Sam's active zone.
   - It is persisted in that project's `canvas.json` as a reference only:
     area ID, object ID and host label. It never stores a path, a record or
     a credential.
   - It is built by `makeHydratedTileView`.
   - It needs a `WorkspaceAPIExposure` classification.
   - **Hazard 10:** another install on the same root, with no account or a
     different account, shows a "Shared by Dylan · sign in to see it"
     placeholder. It must never treat the tile as a broken managed agent.
   - It must not be `.managedAgent`. A managed-agent tile with no
     `AgentRecord` reads as `agentUnavailable`, and stale-tile handling
     could act on it.
2. **Landing.**
   - The link opens into Sam's armed zone at camera-following placement,
     through `installProjectTile`.
   - One `targetZoneId` covers placement, siblings, z-order and the
     install, per hazard 9 and `.plans/47`.
   - No zone is made.
3. **The body.**
   - First cut: `SharedAgentLiveView` in standard agent-tile chrome. It is
     cheap, but it reads unlike a real agent.
   - Target: the guest turns projection frames into an `AgentDocument` and
     hands it to the real transcript renderer. The tile then looks exactly
     like a local agent, as in the stills.
   - Either way, the composer submits `AgentPromptRequest`.
4. **The projection grows** to carry user prompts and their author labels.
   - This reverses a deliberate privacy line ("prompts … have no field to
     travel in"). That needs Dylan's yes (question 1).
   - Size stays bounded by the same 32-row, 3 KiB caps.
5. **Offline.** The host's liveness is already known (`w5-liveness`). Use
   the footer in panel 4 in place of the composer. Queued prompts follow the
   existing handoff rules.

**Stays host-only:** stop, steer and provider approvals. No cross-host route
exists, and IN-CANVAS round 2 recommended keeping approvals with the owner.
Terminal input stays off.

## (B) Portal tile: per tile kind

The portal is one tile, `sharedPortal`, persisted like `sharedAgent` with
the same hazard-10 placeholder.

**Body.** It shows the tiles the host chose, at their host world positions
relative to each other, fitted to the tile. There is no inner pan or zoom:
Dylan rejected a second camera. Hovering a tile offers "Open beside".

**Membership is explicit.**
- The portal holds the tiles that were inside the Share-tool marquee when
  the link was made.
- It is not a live rectangle. A tile Dylan later drags into that region of
  his canvas is not shared.
- This keeps DECISIONS.md's rule: "dragging a private tile across an area
  boundary does not publish it".

**Positions follow the host.** When Dylan moves a shared tile, the portal
follows through the existing `.place` edit.

| Kind | How it reaches Sam | Exists today? | What Sam can do | Honest limits |
| --- | --- | --- | --- | --- |
| Agent | **Mirrored.** The projection is re-drawn. | Yes: `agentObservation` and the projection | Watch in the portal. "Open beside" gives the (A) tile: prompt and queue. | The projection is a summary: 32 rows, and no tool output. No stop, steer or approve from afar. Prompts and authors need A's projection change. |
| Note | **Mirrored.** The text is re-sent on save. | Partly: a one-time snapshot today | Read it live | Editing from both sides needs merge rules; there is no CRDT. v1: only the host edits. |
| File | **Mirrored.** An artifact revision, re-uploaded on save (debounced) | Partly: snapshot artifacts | Read it, and follow its revisions | 1 MiB per blob. Large or binary files show a placeholder. Every save costs an upload. |
| Diff review | **Mirrored.** An artifact revision | Yes: snapshot, with Approve and Request changes | Read it; approve or request changes | Must show "reviewed revision" apart from "latest" (SHARING-MODEL.md) |
| Browser | **Re-loaded URL** when the URL is public. **Still frame** when it is localhost or private. | No: dropped today | Public: a real browser on Sam's Mac, with Sam's cookies. Private: look only. | Sam's session is not Dylan's, so a signed-in page differs. Sam cannot reach Dylan's localhost. A still needs a WebKit snapshot uploaded as an artifact, which is new. Nothing is live. |
| Terminal | **Not supported** | Refused today | Sees a "stays on Dylan's Mac" card | A read-only text mirror is possible later, but output leaks secrets and env. Input never. |
| Anything as pixels | **Not supported** | No transport | — | Needs a new streaming transport (WebRTC or similar, plus ScreenCaptureKit) and a security review. It does not fit the relay. |

**Reuse.** `SharedAreaSceneView`'s canvas already lays area items out at
area-local positions, with presence and cursors. Restyled with no dock, it is
the portal's body. The difference from today: the host's tiles stay home, so
the area's positions come from the host's world frames, not from lent tiles.

## What to delete

### The discussion panel, now

- `SharedAreaZoneDockView`, plus the dock fields and layout in
  `SharedAreaSceneView`: `detailLabel` "Select an object", the "Workspace"
  actions, `postButton` "Post", and `refreshReader`.
- `SharedAreaAgreementView`, `SharedAreaAgentFreshnessView`,
  `SharedAreaExcerptPresentation`. In Core: `SharedAgentFreshnessModel` and
  `SharedAgentContextFreshness`.
- The dock-hosted `SharedAreaArtifactView`. Its renderer moves into the
  portal's file and diff cards.
- Stop producing the `context`, `post` and `endorse` edits and
  `ResultExcerpt`. **Keep decoding them**: relay storage and 0.7.37 clients
  already hold them.
- Checks: `SharedAreaAgreementSceneChecks`,
  `SharedAreaFreshnessSceneChecks`, and the dock assertions in
  `SharedAreaZoneChecks`.

### The shared-zone flow, once B ships

- `ZonePlacement.sharedAreaId` zones, `SharedAreaZoneSession`, and the
  header and agent layer in `SharedAreaZoneViews.swift`.
- Tile lending: `CanvasNSView` 7376-7644, `WorkspaceRuntime` 2311-2443,
  `relendBoundTiles`, and the lent-tile drag in `TileNSView`.
- `SharedAreaGeometryHistory` and `SharedAreaGeometryLedger`, if Sam cannot
  rearrange Dylan's tiles (question 3).
- Windows already off the user path: `SharedAreaWindowController`,
  `SharedAreaHandoffView` and its window, `SharedAreaCaptureView` and
  `SharedAreaCaptureCoordinator`, and the File-menu share items.
- **Migration.** 0.7.37 users have `sharedAreaId` zones in their workspace
  documents. On load, turn each into a portal tile in the nearest project
  zone, or drop it with a notice. It must have a witness.
- Keep `SharedAreaPeerRuntime` for the pair scripts.

## Build plan

**Slice size.** The checks cost far more than the code. Each slice ends
with the named witness, reported by the matrix's `--collaboration` block.

### (A) slices

**A1. Share an agent without a zone (host).**
- Change: Copy publishes one agent, adds no zone and lends nothing; adds
  the header tab.
- Witness: a real header Share click through `NSApp.sendEvent`, on a local
  relay. Assert three things: no `ZonePlacement` is created, the tile's
  world frame and zone are unchanged, and the area holds exactly one
  `agentObservation`.

**A2. The guest's shared agent tile.**
- Change:
  - `sharedAgent` tile kind;
  - opening a link lands it in the armed zone;
  - `SharedAgentLiveView` as its body, with the composer and the offline
    footer;
  - the `WorkspaceAPIExposure` classification;
  - the hazard-10 placeholder.
- Witness: open the link through `application(_:open:)`. Assert the tile's
  WORLD frame against Sam's zone. A pair script confirms the prompt runs
  once, on the host.

**A3. Prompts and authors in both transcripts.**
- Change:
  - an optional author on the user node;
  - the projection carries prompts and authors (needs question 1);
  - the guest body switches to the real transcript renderer.
- Witness: the pair script. Both names appear on both Macs, in order, and
  a prompt sent twice runs once.

**A4. Delete the discussion panel and single-agent zones.**
- Change: remove the panel and the one-agent zone path, and migrate 0.7.37
  shared zones.
- Witness: a migration check over a 0.7.37 workspace document, plus the
  retired checks removed from `run-matrix.sh` and the inventory in the same
  change.

### (B) slices

**B1. The portal tile.**
- Change:
  - `sharedPortal` tile kind;
  - the Share tool's Copy publishes the selection without lending;
  - the body is the restyled scene canvas (agents, notes as snapshots,
    files, diffs);
  - "Open beside" gives an A2 tile;
  - the offline state.
- Witness: the portal tile's item frames match the host's relative world
  frames, and a `.place` on the host moves the item in the portal.

**B2. Live notes and files.**
- Change: re-publish on save, debounced, so the host's edits show live.
- Witness: a host edit appears on the guest within the poll window, and
  edits from the guest are refused in v1.

**B3. Browsers.**
- Change: a public URL re-loads; localhost and private URLs show a still,
  as an artifact.
- Witness: classify a URL and assert what the guest renders for each case.

**B4. Retire the zone flow.**
- Change: remove what is listed under "The shared-zone flow".
- Witness: a full `--collaboration` gate run with the zone checks retired.

A1 and A2 together are a usable release. B is worth starting only after
Dylan has used A, because A answers part of what the portal is for.

## Open questions for Dylan

1. **Should prompt text travel to the guest?** Today it deliberately does
   not. "Both people's prompts show with names" needs it, and full access
   arguably already implies it.
2. **What does the portal hold?** The tiles chosen when sharing
   (recommended), or a live rectangle where anything Dylan drags in becomes
   shared?
3. **Can Sam move tiles inside the portal?** That would move Dylan's real
   tiles on Dylan's canvas. Recommended: no; positions are the host's.
4. **Can Sam edit a note through the portal?** Recommended: not in v1.
5. **Browsers that Sam cannot reach** (localhost, or signed in): show a
   still, or leave them out of the portal?
6. **Order.** Ship A (A1–A4) first and try it before committing to B?
   Recommended.
7. **Stop and approvals stay with the owner.** Confirm, as IN-CANVAS
   round 2 recommended.
