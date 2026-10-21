# 79 — Session handoff: every agent session on the Mac, one tile with two faces

Design recorded 2026-10-20. Implementation is collected locally on
`array/session-handoff`; the design and its original proof notes below are
historical. See [verification and remaining scope](VERIFICATION.md) for the
2026-10-21 review, fixes and check results. The feature has not been released.

## Why

A colleague who uses cmux could not find his terminal tiles in Array. He also
trusted a terminal running `claude` more than Array's native agent tile.
That's two problems:

1. **Finding sessions.** Terminals, and Claude/Codex sessions running in other
   apps, don't appear in the sidebar.
2. **Trust.** The agent tile feels like Array's own version of Claude, with no
   way out of it.

The answer to both: every Claude and Codex session on the Mac appears in the
sidebar. A session can be watched, moved into Array, or copied. And an agent
tile can flip between Array's native UI and the real CLI running in a
terminal, without the tile ever going away.

## What Dylan decided

- **Sidebar.** Sessions from other apps are ordinary inbox rows. A quiet "where"
  marker after the project name says where each one lives: `cmux`,
  `Claude app`, `Codex app`, `Ghostty`, `Terminal` (an Array tile in Terminal
  face) or `Shell 2` (claude typed into an Array shell tile). No marker means
  an Array tile.
  - **No drawer and no collapsible.** "Elsewhere on this Mac" was rejected.
    See `mocks/4-sidebar-inline.png`.
  - By default the list shows only sessions that are live or waiting on you,
    in this workspace's projects. The existing scope menu gets one more entry,
    **This Mac**, which adds quiet sessions and folders that aren't projects.
  - Still open: Claude suggested swapping the generic glyphs for each app's
    real icon (`NSWorkspace` gives Array those). Not decided yet.
- **Scope.** All Claude and Codex sessions, from the CLIs and the desktop apps.
- **Verbs.** "Import" is wrong. Use **Move here**, which continues the same
  session here once the other one closes, and **Copy**, which forks it with
  Claude's `--fork-session` while the original keeps running. Clicking an
  "elsewhere" row first opens it read-only in a watch tile.
- **One tile, two faces.** A compact Terminal icon toggle in the tile's title
  band. Chat is the default. Settings → Agents can hide the icon; the menu
  and ⌃⌘T remain available, and Terminal retains a visible return toggle.
  - The Terminal face runs `claude --resume <id>` in a Ghostty surface inside
    the same tile, with the same name, colour and sidebar row.
  - The tile never disappears.
  - `/exit` in the Terminal face flips the tile back. It never closes the tile.
    Closing the agent is still the ×.
  - See `mocks/2-one-tile-two-faces.png`.
- **The switch must be clickable at every tile size and zoom.** Dylan raised
  this because tile chrome has had clickability bugs before. See the "Switch"
  section.
- **Agents messaging each other needs its own transcript UI** (added at the
  end of the session). See the "Agent-to-agent messages" section.

## The ownership rule (what makes the edge cases go away)

Every session has exactly one owner at a time:

- the Array face;
- the Terminal face;
- an Array shell tile;
- another app.

Sidebar rows are keyed by **session id**, so one session can never show as two
rows. The loop Dylan worried about (`claude` typed in a shell tile showing up,
switching, showing up again) can't happen.

How Array recognises its own processes: a Claude that Array starts carries
Array's agent tag (`ARRAY_AGENT_ID`, the same tag the 0.7.30 process tracker
uses), so it's never listed as "elsewhere".

## Edge cases (all must be handled)

Ownership:

1. **Someone resumes a tile's session in another app.** The tile pauses until
   that process exits, so the two never overwrite each other
   (`mocks/3-moving-sessions.png`, bottom left).
2. **Move here on a session Array already owns.** The button becomes Show tile.
3. **`/clear` or `/resume` inside the Terminal face changes the session id.**
   The tile must follow the new id. *Unverified:* whether
   `~/.claude/sessions/<pid>.json` updates its `sessionId` when that happens.
4. **`claude` in a shell tile.** "Open as agent tile" puts a tile beside the
   shell and waits for that claude to exit. Array owns that terminal, so it
   could type `/exit` itself; Claude recommended it would. **Decision pending
   from Dylan.**

Lifetime:

5. **Quitting Array while a tile is in Terminal face.** Array terminals live in
   tmux, so claude survives and the tile reattaches on relaunch. If the tmux
   session is gone, the tile comes back in the Array face.
6. **× in Terminal face.** Closes the agent as today, and confirms first if it
   is busy.
7. **A watched session ends in the other app.** The watch tile says "Ended in
   cmux" and offers Continue here.
8. **Move here, and the other app never closes its session.** The tile keeps
   waiting. Cancel removes it; Copy instead forks the session.

Mid-turn:

9. **Flip while busy.** Waits for the turn to end; "Stop now" interrupts.
10. **A pending approval.** Must be answered first, because it belongs to the
    face that asked.
11. **Composer draft and queued messages.** The draft stays in the Array face.
    Queued messages either send first or block the flip.
12. **`/model` changed in the terminal.** After flipping back, the model picker
    shows what actually ran.

Discovery:

13. **Claude desktop sessions** live in the same files. To move one, the user
    closes it in the Claude app.
14. **Codex.** There is no file per running process. Codex CLI sessions show up
    in a process scan. The Codex app runs every thread inside one
    `codex app-server`, so Array can't tell which threads are open; list
    recently active threads instead ("Codex app · 4m ago").
15. **A session whose folder isn't an Array project.** Move here asks which
    project to use, or offers to add the folder.
16. **Array's own agents** (`entrypoint: sdk-cli`) appear in Claude's list.
    Filter them out by Array's tag.
17. **Claude's session files are undocumented.** If they stop parsing, the
    section hides itself rather than showing wrong rows.
18. **A stale session file can point at a reused pid.** See the facts below.

## Facts proven (2026-10-20, on Dylan's machine)

### Live Claude sessions

`~/.claude/sessions/<pid>.json` holds `sessionId`, `cwd`, `name` (the session
title), `status` (`idle`/`busy`), `kind` (`interactive`/`bg`), `entrypoint`
(`cli`, `claude-desktop`, `sdk-cli`), `procStart`, `startedAt`, and sometimes
`tmux`. The files are undocumented, and the folder also holds `.key` files:
don't read them.

### The app a session runs in

Walk the process ancestry; the first `.app` ancestor names the app.

- Sessions inside tmux end at the tmux server, so the terminal app showing
  them isn't in the chain.
- Array's own shells are tmux sessions with names Array knows, so those can be
  matched exactly. Anyone else's tmux is labelled "tmux".
- `kind: bg` processes (`claude bg-spare`) are Claude's own background host.
  Skip them.

### Telling a dead session from a live one

A session file can outlive its process, and macOS reuses pids: one pointed at
Spotify.

- `procStart` is written in **UTC**. For every live claude it matched `ps -o
  lstart` to the second.
- The Spotify one recorded a time before the Mac's last boot.
- Rule: compare `procStart` with the real start time of the process at that
  pid; on a mismatch, drop the file.

### Restoring a session into a tile already works

`ClaudeSessionTranscriptReader` / `CodexSessionTranscriptReader` and
`ManagedAgentTileNSView.renderRehydratedPreviousSession` rebuild a tile from
the CLI's own session file. Real interactive TUI sessions render natively
(68 ms), as do Codex desktop threads.

### Flipping back is proven

The test restored the first part of a real session, then replayed the rest
through the same step loop, and compared the result with one full restore.

- The transcript text and entry counts were identical, with no duplicate ids,
  on two real sessions.
- Production needs the replay half split out of
  `renderRehydratedPreviousSession`. Today the method runs once per tile,
  guarded by `hasRenderedRehydratedSession`. The split exists as
  `replayRehydratedSteps` in the mock bench only.
- Splitting mid-turn adds one extra turn boundary. A real flip waits for idle,
  so it never happens.

### Codex desktop threads are ordinary rollouts

They're written to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` with
`originator: "Codex Desktop"`. The other originators seen were `array` and
`codex_exec`.

### The TUI's `!` shell mode

It logs `<bash-input>cmd</bash-input>` and
`<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>` as plain user
messages. This was captured from a real run in a sandboxed tmux; the
folder-trust prompt defaults to "No, exit", so press Down, then Enter.

### Clickability of the title band

`TitleBarView` (`Sources/ContinuumRevived/Canvas/TileNSView.swift:1324`) owns
the band.

- **Click routing is by hand.** Its `hitTest` (`:1603`) checks ×, then ⋯, then
  one accessory slot. Anything else in the band starts a tile drag.
- **Only × and ⋯ are protected at low zoom.** They have 22px on-screen floors;
  the accessory slot has none, and ⋯ grows over it as you zoom out.
- **Existing bug:** at zoom 0.1 on a 320pt tile, ⋯ overlaps × by about 14pt.
- **No passing check really clicks band controls on an agent tile.** The only
  real-click band check (`--file-tile-zoom-check`) is KNOWN-RED and stops
  before its click assertions.
- **History** of chrome click bugs: `cd9171b9`, `541f8c26`, `9e3c4ac9`,
  `083d7ba6` (a segmented control in the accessory became a tile drag),
  `ec259e74`, `0f84caa9`, `f1a60801`, `f151c05a`, `10c49c25`.

## Landed (array/integration, local, not pushed)

1. `65e5fd77` **fix(agents): keep task notices and app reminders out of restored
   prompts.** It drops user lines whose `origin.kind` is `task-notification`
   and strips `<system-reminder>` spans. Both showed as raw XML bubbles,
   including for Array's own agents after a relaunch.
2. `af4fc0b2` **fix(agents): restore Codex prompts and replies from current
   rollouts.** Codex 0.159+ writes what was said as `event_msg` `item_completed`
   lines with `UserMessage`/`AgentMessage` items. Before the fix, every
   restored Codex transcript (Array's own Codex agents included) showed
   commands and no words.
3. `6c1d7e8f` **fix(agents): restore a TUI shell command as typed, without its
   output.**

Each has a CoreChecks witness in `TranscriptRehydrationChecks.swift`, shown red
before the fix and green after. Run it with `.build/debug/ContinuumRevivedCoreChecks
--transcript-rehydration-check` (safe: no tmux).

## The switch (design and witness)

- **Build it as a third band control**, like × and ⋯: manual frames, the 22px
  on-screen floor, and its own branch in `TitleBarView.hitTest` ahead of the
  drag fallback. **Not** the accessory slot.
- **Width budget.** The ×, ⋯ and switch are placed first and never overlap.
  The switch uses one square icon slot, never labels or paired segments.
  As the band narrows, the title truncates, the status pill goes (the in-body
  header still shows the status), then the toggle leaves the band. Its 22px
  screen-space hit floor and the title's grab area are preserved.

  The earlier mock `mocks/5-switch-at-every-width.png` shows the superseded
  segmented version.
- **Always reachable.** "Switch to Terminal / Array" is also in the ⋯ menu, on
  a keyboard shortcut, and an accessibility action.
- **Fix the ⋯/× overlap in the same budget.**
- **Active toggle** uses the app's neutral selected fill. Clicking it again
  returns to chat; while waiting for a turn to end, it cancels the pending flip.
- **Witness.** A real agent tile in a real canvas, at widths 320, 480 and 900,
  canvas zoom 0.1, 0.3, 1 and 2, and page zoom 80% and 150%. The check must:
  - send a real mouse down/up to the centre of every visible control and
    assert the right action fires;
  - assert no two controls overlap;
  - assert a hidden switch is still reachable from the ⋯ menu;
  - go red when the switch's `hitTest` branch is removed.

## Agent-to-agent messages in the transcript (new, not designed yet)

Dylan: "we need to handle agent messaging each other UI in the transcript."

What exists today:

- **Array's own `agent.message`** (`WorkspaceAPIContracts+Delegation.swift:237`,
  `WorkspaceAPIService+Delegation.swift:633`). It delivers a parent's text
  through `supervisor.send`, the same path as a user's message.
  - The receiving tile shows it as a **user prompt bubble, as if you typed
    it, with no sender**.
  - Only parent → child is allowed (siblings, the parent itself and unrelated
    agents are refused).
  - The reply comes back to the parent through `wait_agents` / spawn results.
  - *To check on screen:* exactly how the child tile renders it, and how the
    parent's transcript shows the reply.
- **The Claude desktop app** logs messages between its sessions as user lines:
  - `<cross-session-message from="local_…" name="<session title>">…`
  - `<side-sessions-event>…`
  - background notes ("Background (from the session that started this one)").

  They are not `isMeta`, so a restored desktop session would show them raw
  today. They were left alone deliberately in `65e5fd77`, pending this design.
- **Claude Code peer messages** (`origin.kind: "peer"`) are logged `isMeta`, so
  the reader already hides them. That may itself be wrong once there's a UI
  for them.
- **Codex** records `CollabAgentToolCall` items (`sender_thread_id`,
  `receiver_thread_ids`) and `SubAgentActivity` items in rollouts. The reader
  doesn't render either.

What the UI needs:

- An inbound message from another agent reads as **from that agent** (name and
  identity colour, linked to its tile), never as a user bubble.
- An outbound message the agent sent reads as an action, "Messaged
  <agent>", with the text.
- The same presentation whether it arrives live or is restored from a session
  file, and the same for Claude, Codex and Pi.
- Restored desktop-app cross-session messages use this same presentation,
  with the session title as the sender.
- Witness: live and restored paths render the same card. A check asserts no
  agent-sent text renders as a user prompt.

## Next steps, in order

1. Design the agent-to-agent message UI (mock it in the bench first, as with
   the sidebar).
2. Codex restore window: rollouts reach 52 MB, so the 512 KB tail can miss
   a long turn's prompt. Look back by messages, not bytes.
3. Implementation plan for the feature itself:
   - session discovery (Claude files + `procStart` check + ancestry, plus a
     Codex process scan);
   - sidebar rows;
   - the watch tile;
   - Move/Copy;
   - the face switch and its witness;
   - the flip-back append path.
4. Decide with Dylan: the real app icons for markers, and whether Array types
   `/exit` into a shell tile.

## Where things are

- Mockups: `mocks/1`–`5` in this folder (dark appearance, real components where
  they exist; new pieces drawn with tokens; the terminal face is a drawing).
- Mockup and proof code: bench `.worktrees/session-handoff-mocks`, branch
  `array/session-handoff-mocks`, commit `chore(session-handoff): keep the
  throwaway mockups and proof harnesses`. **Never merge it.** Flags:
  - `Array --session-handoff-mocks <out dir>` renders the sheets;
  - `Array --session-handoff-render <session.jsonl> <out.png>` renders a real
    Claude or Codex session into a tile and prints what came through;
  - `Array --session-handoff-append <session.jsonl> <out prefix>` runs the
    flip-back proof.

  Always run with `CONTINUUM_APP_SUPPORT` set to a temporary directory.
- The shell-mode probe script: the scratchpad `bashmode/run.sh` from that
  session. It's disposable, and its recipe is under "The TUI's `!` shell
  mode" above.
- Memory: `session-handoff-design.md`.
