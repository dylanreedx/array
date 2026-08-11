# 03 — Transcript rehydration on resume

Status: **shipped for Claude/Pi 2026-08-10; Codex source implementation added
2026-08-10 under plan 09, with installed-app smoke intentionally pending.**
Dylan's intent (2026-08-09): on relaunch
a restored agent tile should show the **full prior transcript**, presented as a
**summary that expands** to the whole previous conversation — replacing today's
empty "Previous session — send a prompt to continue." notice
(`ManagedAgentTileNSView.previousSessionNoticeText`).

## Problem

Across an app relaunch the agent RECORD survives (`AgentStore`) and the provider
CONVERSATION survives (pi/claude's own session file — continuity is derived from
the agent id), but the desktop transcript is gone: nothing rehydrates the cards.
The `showPreviousSessionNotice()` placeholder is the stand-in
(`ManagedAgentTileNSView.swift:724-755`; its own doc comment names this feature
as the follow-up). Ticket lineage: `docs/38-tickets/90-agent-ux/P2A.7-restore-on-relaunch.md`
chose the placeholder as option (b) and deferred rehydration (option (a)) to
"its own ticket" — this is that ticket.

## The clean path (why this is tractable)

The tile transcript is DERIVED from an `AgentTranscriptProjection` document; the
only mutators are `ingest(_ event: AgentRuntimeEvent)`, `appendUserPrompt`,
`appendNotice` (`ManagedAgentTranscriptModel.swift:129-174`). So rehydration =
**read the provider session file → reconstruct a sequence of
`AgentRuntimeEvent`s → replay them through the same `ingest` pipeline the live
runner already uses.** No new rendering path for the content itself; it reuses
every existing block renderer. `AgentRuntimeEvent` is `Codable`
(`AgentStatusEngine.swift:469`), so fixtures are checkable exactly like
`Fixtures/managed-session-with-approval.jsonl`.

The session files are COMPLETE messages (not deltas), so the readers synthesize:
`turnStarted` → `contentDelta(.assistant, fullText)` / `contentDelta(.reasoning, …)`
→ `itemStarted`/`itemCompleted` for tool calls → `turnCompleted`, one turn per
prior message-pair. (Deltas carrying whole strings are fine — the projection
concatenates them.)

## Provider session files (verified live 2026-08-09)

Two formats, DIFFERENT cwd encodings — needs two readers:

- **claude**: `~/.claude/projects/<encodeCwd(cwd)>/<sessionId>.jsonl`.
  `encodeCwd` = `/` and `.` → `-` (reuse `ClaudeAgentStateReader.encodeCwd`,
  `ClaudeAgentStateReader.swift:113`). `sessionId` = `AgentSupervisor.claudeSessionId(for:)`
  (the agent UUID, lowercased). Line types: `user` (content str|list),
  `assistant` (content list: `thinking`/`text`/`tool_use`), `system`, plus
  `queue-operation`/`attachment`/`ai-title`/`mode`/`last-prompt` (skip).
  `isSidechain:true` = sub-agent frame → skip. tool_result completions are in
  the following `user` line's `tool_result` blocks (matched by `tool_use_id`).
- **pi**: `~/.pi/agent/sessions/--<cwd with "/"→"-", dots PRESERVED>--/*_<sessionId>.jsonl`.
  `sessionId` = `AgentSupervisor.sessionId(for:)` (`array-agent-<UUID>`). The
  filename has an unknown ISO-timestamp prefix → **glob `*_<sessionId>.jsonl`**
  in the slug dir. Line types: `session`/`model_change`/`thinking_level_change`/
  `message`/`custom_message`/`compaction`. `message.role ∈ {user,assistant,toolResult}`;
  `message.content` parts: `text`/`thinking`/`toolCall`/`image`. NOTE: this is
  NOT the `pi --mode json` stream shape `PiEventTranslator` consumes — it needs
  its own decoder (only the `session` line overlaps).

Neither `ClaudeAgentStateReader` nor `PiAgentStateReader` is reusable for
content — both read tail-only + strip bodies for status summaries (I5). Reuse
only `encodeCwd` and the path-construction shape.

## Backend detection (no record field exists)

`AgentRecord` has no field for which backend last ran (confirmed — the derived-id
design is deliberately stateless). Detect by **file existence**: compute both
candidate paths; the two id formats can't collide, so "whichever file exists"
is sound. If both exist (model switched between launches), tiebreak with
`ClaudeCLIBackend.routesToClaude(model: record.model, claudeCLIAvailable:)`. A
restored agent's `cwd` can't move (`reassignProvisionalHome` refuses once
`restoredIDs.contains(id)`), so the slug is stable.

## The "summary that expands" UI

Reuse the existing disclosure precedent — `CompletedReasoningDisclosurePresenter`
("Thought" → collapsed, expands to full body;
`Canvas/AgentTranscript/Renderers/CompletedReasoningDisclosurePresenter.swift`,
disclosure state via `DisclosureStateStore` keyed on `entryID`). Wrap the
rehydrated cards in a collapsed disclosure group headed e.g. "Previous session ·
N messages" that expands to reveal the full prior transcript. Default collapsed
(`collapsedDefaultExpanded = false` precedent). Live turns append below it as
normal.

MVP option if the grouping proves heavy: append the rehydrated cards directly
(no group) but lead with a notice entry "Previous session — N messages restored"
so the boundary is legible; add the collapse group as a fast-follow.

## Critical constraint — display-only, never re-sync (I5)

The translators drop bodies because their output crosses the companion SYNC
boundary. Rehydration deliberately RESTORES bodies — so the rehydrated events
must be **display-only** and must NOT be republished to the syncable activity
timeline (`managedAgentActivityByAgent` in ContinuumApp / `ManagedAgentActivityBridge`).
This is the sharpest risk: seeding them through the normal `deliver` path would
re-emit them to the companion. The rehydration seam must bypass activity
publication. Witness this explicitly (assert the activity timeline is unchanged
by a rehydrate).

## Where the events go — seam decision

Two options (`AgentSupervisor.history` has no public seed seam today):
1. **View-local** (like `showPreviousSessionNotice`): simplest, but a second
   tile on the same agent won't see it and `needsPreviousSessionNotice` stays
   true. 
2. **Supervisor-seeded** (preferred): add `AgentSupervisor.seedRehydratedTranscript(_ events:for:)`
   that fills `history[id]` WITHOUT going through `deliver` (so no activity
   publication, no subscriber double-emit), making any attaching tile rehydrate
   and flipping `needsPreviousSessionNotice` to false (history non-empty). Call
   it from `restore()` or lazily on first `wireManagedAgentTile`.

Recommend (2). Do the read lazily/bounded off the main thread (session files run
to hundreds of messages).

## Bounded, no silent caps

Session files reach 180+ messages. Cap rehydration (last N messages or a byte
budget) and, per the AGENTS.md "no silent caps" footgun, surface what was
dropped ("… earlier history not shown"). Read off the main thread.

## Files (rough)

1. `Sources/ContinuumRevivedCore/AgentProviders/ClaudeSessionTranscriptReader.swift`
   — pure parse of the claude session .jsonl → `[AgentRuntimeEvent]` (+ macOS
   locate). Sub-agent frames skipped; tool_use/tool_result paired.
2. `Sources/ContinuumRevivedCore/AgentProviders/PiSessionTranscriptReader.swift`
   — same over pi's session .jsonl (its own decoder + glob locate).
3. A dispatcher (`ManagedTranscriptRehydrator`?) that picks the reader by file
   existence and returns the bounded event list + a "dropped" marker.
4. `AgentSupervisor.seedRehydratedTranscript(_:for:)` seam (option 2 above).
5. Wire into restore/`wireManagedAgentTile` (`ContinuumApp.swift:10019-10029`),
   replacing the bare `showPreviousSessionNotice()` with: rehydrate if a session
   file exists, else fall back to the notice.
6. The collapse-group presenter/renderer for the "Previous session" boundary.

## Witnesses

- Extend `--agent-restore-check` section 4 (`AgentSupervisor.swift:7081-7142`):
  write a claude session .jsonl AND a pi session .jsonl fixture into a temp
  `$HOME` (pattern: `ClaudeAgentStateReaderTests.writeScenario`), restore, assert
  the tile transcript rehydrates (cards contain known planted content), assert
  the disclosure collapses/expands, assert `needsPreviousSessionNotice` flips to
  false, and assert the syncable activity timeline is UNCHANGED (the I5
  display-only guard). Update section 9's source scan (`:7255-7273`) — it asserts
  the `wireManagedAgentTile` branch text, which this changes.
- Core-side pure reader checks: claude/pi session .jsonl fixture →
  `[AgentRuntimeEvent]` equality (new `*Checks` section registered in
  `ContinuumRevivedCoreChecks/main.swift`; re-bless matrix inventory).
- RED-verify each with a teeth mutation before calling it done.

## Open questions

- Collapse group vs flat append for the MVP (UI weight).
- Bound size + how to phrase the "earlier history" cap.
- Whether to rehydrate eagerly at `restore()` (cost for many agents) or lazily
  on first tile attach (preferred).
