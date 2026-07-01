# Codex reader — recency-plus-cwd linkage with same-cwd under-claim

## What this delivers

After this ticket lands, a terminal tile whose foreground process is Codex produces a
real, file-derived `AgentStatus` instead of the silent no-status it gets today. The
observer locates Codex's session by scanning `~/.codex/sessions/**/rollout-*.jsonl`
newest-file-mtime first, reading only line one of each rollout, and accepting the first
rollout whose embedded `session_meta.payload.cwd` matches the tile's cwd and whose
`session_meta.payload.timestamp` falls after the tile's recorded `paneStartedAt`. That
rollout's tail events map to `working`, `idle`, or `stale` via the status tables below.

When two live tiles share the same cwd and both resolve to the same newest rollout — a
situation that is genuinely indistinguishable from files alone — the reader declares
exactly `codex (running)` and emits `AgentStatus.working` with no per-session detail. It
never attaches a specific status to a possibly-wrong session; I6 (status soundness) holds
in the ambiguous case by honest under-claim rather than fabrication.

The user sees what the system actually knows: Codex tiles light up with real working/idle
state in the sidebar tree and the canvas zone rollup, same-cwd collisions get a clear
"running" signal with no false precision, and the whole derivation is driven by push
(FSEvents on the matched rollout file) rather than polling.

## How it fits

This is one of three concrete `AgentStateReader` implementations that Phase 3 of the
build plan calls for (alongside the Claude reader and the Pi reader). It depends on two
upstream pieces that must already be in place before this work begins.

First, it depends on the **`AgentStateReader` protocol** — the thin per-agent reader
contract (`detect(processName:) -> Bool`, `locate(cwd:paneStartedAt:) -> URL?`,
`read(at:) -> AgentSnapshot`) that the protocol ticket defines. The Codex reader is a
concrete struct conforming to that protocol; it cannot exist without the protocol type.

Second, it depends on **pane-start capture at spawn** — the `paneStartedAt: Date` field
added to `TerminalSessionDescriptor` (or, if that field lives on `AgentDescriptor`,
then on `AgentDescriptor`) by the spawn-timestamp work. The recency heuristic is only
meaningful when the observer can compare a rollout's `session_meta.timestamp` against the
moment the tile was spawned. Without that recorded timestamp, the time-filter step is
skipped, and the reader falls back to cwd-only matching, which degrades to same-cwd
collision handling for any tile that was running before the rollout it spawned. That
fallback is safe but imprecise; the full heuristic requires the recorded timestamp.

This ticket is one of two prerequisites for the **reader golden-fixtures ticket** that
captures redacted real rollout files and replays them through the reader to prove I6 in a
repeatable offline way. Once all three reader implementations land, the golden-fixtures
ticket can wire them all and produce the shared evidence corpus.

It also feeds the **`SessionObserver`** (the per-project observer that drives detection,
calls readers, and writes `AgentDescriptor.status`): the Codex reader is the concrete
implementation the observer dispatches to for any tile classified `codex` by the kind
classifier.

## The approach

Codex keeps no pid-keyed session file. Every rollout lives at
`~/.codex/sessions/YYYY/MM/DD/rollout-<ISO8601>-<uuid>.jsonl` with its first line always
being a `session_meta` object carrying `payload.cwd` and `payload.timestamp`. The spike
confirmed 238 rollouts on a real machine and verified the consistent `{type, timestamp,
payload}` line format. The reader links a tile to its rollout via three ordered filters
applied to the set of rollout files sorted by file mtime descending.

**Step 1 — cwd filter.** Read only line one of each rollout (never seek into the file).
Accept the rollout only if `payload.cwd` equals the tile's cwd (the `OSC-7
pane_current_path` at the moment the observer fires). Same comparison, no normalization —
`/Users/dylan/selectus-ms` and `/Users/dylan/selectus-ms` match;
`/Users/dylan/selectus-ms` and `/Users/dylan/selectus-ms/` do not. If the string is the
same, it is a candidate.

**Step 2 — time filter.** Among candidates, prefer the rollout whose
`session_meta.payload.timestamp` (an ISO-8601 string in the rollout; parse it to `Date`)
falls strictly after the tile's `paneStartedAt`. A rollout that predates the tile's spawn
belongs to a prior session in the same directory and must be skipped. If no candidate
passes the time filter (the tile is very new and Codex has not yet written a rollout),
the reader returns `nil` from `locate` — the observer leaves the tile at its prior status
or at `idle` if it just detected Codex.

**Step 3 — collision detection.** After `locate` returns a rollout URL, the observer
checks whether any other live Codex tile has resolved to the same rollout URL. If yes, no
tile gets deep status for that rollout — both show `AgentStatus.working` from the process
signal alone (Codex is running; we just cannot tell which tile it is). If only one tile
resolved to the rollout, that tile gets the full status derivation below.

**Status derivation from the rollout tail.** The reader reads the last 50 lines of the
matched rollout (streaming from the end; never loading the full file into memory). It
finds the **last meaningful event** in that tail (the newest line that decodes to a
`response_item` or `event_msg`; `session_meta` and `turn_context` lines are not
"meaningful" for status) and classifies it. **This prose and the pseudo-code in the
Implementation breadcrumbs are the same algorithm — where they could diverge, the rule
here is authoritative and the pseudo-code is written to match it exactly.** The
single decision that all the tables below rest on: **`working` requires a fresh mtime;
a stale file never yields `working`, whatever the last event was.** The classification:

- Last meaningful event is `response_item/function_call` with no paired
  `function_call_output` after it in the tail (tool call in flight) **and** file mtime
  within `freshWorkingWindow` (default 30 s) → `working`. If the same in-flight call is
  present but mtime is beyond `freshWorkingWindow`, the call is stalled → `idle` (the
  reader does not report `working` on a stale in-flight call).
- Last meaningful event is `response_item/function_call_output` (a tool loop that just
  produced output), file mtime within `freshWorkingWindow` → `working` (active tool
  loop). Beyond `freshWorkingWindow` → `idle`.
- Last meaningful event is `event_msg/task_started`, file mtime within
  `freshWorkingWindow` → `working` (a turn just began; if a later `response_item`
  existed it would be the last meaningful event and one of the branches above would fire
  instead, so `task_started` being last with a fresh mtime is itself the working signal
  — there is no separate "subsequent response_item" condition). Beyond
  `freshWorkingWindow` → `idle`.
- Last meaningful event is `event_msg/agent_message` (turn produced output, awaiting
  user) → `idle`. There is no distinct freshness gate on this branch: an
  `agent_message` tail is `idle` at any age up to `staleWindow`; beyond `staleWindow`
  the stale override below applies.
- Last meaningful event is `event_msg/turn_aborted` → `idle`.
- File mtime older than `staleWindow` (default 900 s) — this override runs **after** the
  branches above and supersedes them: with process alive → `idle`; with process gone →
  `done`.
- Unparseable tail, unknown event types, or no rollout matched → `idle` (never
  fabricate `working`).

Only two windows govern this reader: `freshWorkingWindow` (the `working` cutoff) and
`staleWindow` (the alive→`idle` / dead→`done` cutoff). There is deliberately **no**
`idleWindow`: the AGENT-READERS spike listed a 120 s `idleWindow` as a recommended
default, but for Codex it has no distinct behavior — an `agent_message` tail is already
`idle` at every age below `staleWindow`, so a third threshold between `freshWorkingWindow`
and `staleWindow` would change nothing. Adding it would be an unfalsifiable knob. It is
omitted on purpose; if a future fixture proves a real behavioral seam between "recently
idle" and "long idle" (e.g. a `done`-vs-`idle` distinction for a quiescent tail before
`staleWindow`), reintroduce it then with a test that fails without it.

`needsAttention` for Codex is not emitted by file derivation. The spike found no
confirmed pending-approval event pattern for Codex (the `turn_context.payload.approval_policy`
field exists but no fixture with a pending tool approval was observed). The reader never
emits `needsAttention` from file evidence until a golden fixture captured during a real
approval-requiring session proves the signal. Until then, under-claim to `working`/`idle`.

**Push via FSEvents.** The observer wraps the matched rollout path in a file-system event
watch using the same `RunArtifactsWatcher` debounce and budget discipline already in the
codebase (`RunArtifactsWatcher.swift:64–119`): 250 ms debounce per file, 10
status-changes per minute per tile. Because Codex appends to the rollout on every action,
FSEvents fires frequently while Codex is active; the debounce absorbs burst. When `locate`
changes the matched rollout (a new session started), the observer tears down the old watch
and creates a new one on the new rollout path. The mtime check inside the debounced
callback drives the freshness windows; no poll timer is needed.

**`mode` and `title` come only from bytes already read — no extra scan.** The reader's
read discipline is fixed: it reads exactly two regions of the rollout — **line 1**
(`session_meta`, for cwd/timestamp during `locate`) and the **bounded 50-line tail**
(for status). It never seeks anywhere else in the file. `mode` and `title` are derived
strictly from those same two regions, so they cost no additional I/O:

- **`mode`** (Codex's approval regime, the analog of Claude's permission-mode) is read
  from `turn_context.payload.approval_policy`. A `turn_context` line is not line 1 (line
  1 is always `session_meta`), and the reader is forbidden from scanning the middle of
  the file to find one. So `mode` is populated **only if a `turn_context` line happens to
  fall within the 50-line tail already read** (the newest such line wins, since
  `approval_policy` can change across turns). If no `turn_context` appears in the tail,
  `mode` is `nil`. This is honest under-claim, not a bug: the tail is where the live
  turn's context sits, so an active session's current `approval_policy` is almost always
  present; a long-quiescent session may legitimately report `mode == nil`. The reader
  does **not** widen its read to guarantee a `mode`.
- **`title`** is `session_index.jsonl` `.thread_name` **if** the reader is already
  consulting the index for display (see below), else the **cwd basename** (from the
  `session_meta` on line 1), truncated to 80 chars. Never a rollout body field.

**The `session_index.jsonl` file is not used for the active session link.** The spike
confirmed it is stale by 16 days and missing 110 of 238 rollouts. The reader may consult
it for a human-readable `thread_name` title (display only, truncated to 80 chars), but
never for linkage.

**The `node` ambiguity.** Because Codex is a Node script, `pane_current_command` may
return `node` rather than `codex`, depending on whether the Codex CLI sets
`process.title`. The kind classifier (the preceding ticket) handles this: when it sees
`node`, it runs the locate probe — if `locate` returns a rollout, the tile is
`AgentKind.codex`; if not, it stays `AgentKind.unknown`. The Codex reader's `detect`
method therefore returns `true` for both `"codex"` and `"node"` as foreground commands,
and the observer relies on a successful `locate` to confirm classification.

## Where it lives

**`Sources/ContinuumRevivedCore/AgentStatusEngine.swift`** — this is the existing file
(113 lines, `AgentStatusEngine` struct at line 3). The Codex reader lives alongside it
or in a peer file in the same module. The new `CodexAgentStateReader` struct conforms to
the `AgentStateReader` protocol. `AgentStatusEngine` itself is not modified by this
ticket; the reader is an independent type that feeds evidence into it.

**`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`** — `AgentDescriptor`
is defined here at line 94. The `paneStartedAt: Date` field needed by the time filter
must be present on this type (or on `TerminalSessionDescriptor` as `lastStartedAt`,
already present at line 16 and set to `now` at spawn in `TileSpawner`). The reader
receives the tile's cwd and pane-start timestamp as parameters to `locate`; it does not
read the descriptor itself.

**`Sources/ContinuumRevived/App/TileSpawner.swift`** — `spawnTerminal` at line 108 sets
`createdAt: now` and `lastStartedAt: now` on the new `TerminalSessionDescriptor` (lines
202–203). `lastStartedAt` is the canonical pane-start timestamp that the observer passes
as `paneStartedAt` when calling `locate(cwd:paneStartedAt:)`. No change to `TileSpawner`
is needed if `lastStartedAt` is sufficient; if the pane-start capture ticket adds a
distinct `paneStartedAt` field, the observer reads that field instead. The key constraint
is that the timestamp is recorded synchronously at spawn, not lazily.

**`Tests/Fixtures/agent-readers/codex/`** — the golden-fixture directory for Codex
scenarios, created as part of the reader-golden-fixtures ticket. The Codex reader checks
exercise the reader against recorded rollout files stored here; this ticket creates the
reader logic and the checks but the fixture files themselves are the golden-fixtures
ticket's output.

**`Sources/ContinuumRevivedCoreChecks/main.swift`** — the existing pure-check harness.
The new Codex reader logic checks are added here, following the existing pattern.

## Implementation breadcrumbs

```swift
// In Sources/ContinuumRevivedCore/ — new file CodexAgentStateReader.swift

public struct CodexAgentStateReader: AgentStateReader {

    // Where Codex stores sessions. Injected for testability; real value is
    // FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    let sessionsRoot: URL

    // Windows — both user-configurable; these are the starting defaults.
    // NOTE: only two windows. There is intentionally no idleWindow — see
    // "Status derivation" prose: it would have no distinct behavioral effect for Codex.
    let freshWorkingWindow: TimeInterval  // 30  — the `working` cutoff
    let staleWindow: TimeInterval         // 900 — alive→idle / dead→done cutoff

    // MARK: - AgentStateReader

    public func detect(processName: String) -> Bool {
        // Both "codex" and "node" are possible; confirmed by AGENT-READERS spike.
        processName == "codex" || processName == "node"
    }

    public func locate(cwd: String, paneStartedAt: Date) -> URL? {
        // 1. Collect all rollout-*.jsonl files under sessionsRoot, sorted by file
        //    mtime descending. Use FileManager with .skipsHiddenFiles = false.
        //    Only files matching "rollout-*.jsonl" in the three-level YYYY/MM/DD
        //    tree are candidates.
        let candidates = rolloutFiles(under: sessionsRoot)  // sorted newest-first by mtime

        for rolloutURL in candidates {
            // 2. Read only line 1; bail immediately after the first newline.
            guard let meta = readSessionMeta(from: rolloutURL) else { continue }

            // 3. cwd filter — exact string equality.
            guard meta.cwd == cwd else { continue }

            // 4. Time filter — rollout must have started after the tile spawned.
            //    If paneStartedAt is .distantPast (unrecorded), accept any cwd match.
            if paneStartedAt > .distantPast, meta.timestamp <= paneStartedAt { continue }

            return rolloutURL
        }
        return nil
    }

    public func read(at rolloutURL: URL, processAlive: Bool, now: Date) -> AgentSnapshot {
        // Read exactly two regions and nothing else: line 1 (session_meta, for cwd) and
        // the bounded 50-line tail (for status + mode). Never seek the file middle.
        let cwdBasename = (readSessionMeta(from: rolloutURL)?.cwd as NSString?)?
            .lastPathComponent
        let tailLines = readTail(url: rolloutURL, maxLines: 50)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: rolloutURL.path))?
            [.modificationDate] as? Date ?? now

        let mtimeAge = now.timeIntervalSince(mtime)

        // Classify from the tail.
        let status: AgentStatus
        let lastEventType: String?

        // Each branch mirrors the "Status derivation" prose exactly. The single rule:
        // `working` requires mtimeAge < freshWorkingWindow; otherwise the tail is idle.
        if let lastMeaningful = lastMeaningfulEvent(in: tailLines) {
            lastEventType = lastMeaningful.payloadType
            let fresh = mtimeAge < freshWorkingWindow
            switch lastMeaningful.type {
            case "response_item" where lastMeaningful.payloadType == "function_call"
                    && !hasPairedOutput(after: lastMeaningful, in: tailLines):
                // Tool call with no output yet — in flight if fresh, else stalled → idle.
                status = fresh ? .working : .idle
            case "response_item" where lastMeaningful.payloadType == "function_call_output":
                // Active tool loop if fresh, else idle.
                status = fresh ? .working : .idle
            case "event_msg" where lastMeaningful.payloadType == "task_started":
                // Turn just began. If a later response_item existed it would be the last
                // meaningful event and a branch above would fire; task_started being last
                // with a fresh mtime IS the working signal. No "subsequent activity" check.
                status = fresh ? .working : .idle
            case "event_msg" where lastMeaningful.payloadType == "agent_message":
                // Turn produced output, awaiting user. Idle at any age below staleWindow;
                // the stale override below handles beyond. No freshness gate here.
                status = .idle
            case "event_msg" where lastMeaningful.payloadType == "turn_aborted":
                status = .idle
            default:
                status = .idle
            }
        } else {
            lastEventType = nil
            status = .idle
        }

        // Stale override: if mtime is beyond staleWindow and process is dead → done.
        // If mtime is beyond staleWindow and process is alive → idle (not working).
        let resolvedStatus: AgentStatus
        if mtimeAge >= staleWindow {
            resolvedStatus = processAlive ? .idle : .done
        } else {
            resolvedStatus = status
        }

        // Title: session_index thread_name (display only; may be missing) else cwd
        // basename. Truncate to 80 chars. I5-safe (a label, not a body). No extra
        // seek into the rollout — cwd comes from line 1 (session_meta), already read.
        let title: String? = derivedTitle(cwdBasename: cwdBasename, rolloutURL: rolloutURL)

        // Mode: approval_policy from a turn_context line — but ONLY if one falls within
        // the 50-line tail already read. The reader NEVER scans the file middle to find
        // turn_context (that would break the "line 1 + bounded tail, never seek" rule).
        // Newest turn_context in the tail wins; if none is in the tail, mode == nil.
        let mode: String? = approvalPolicy(inTail: tailLines)  // nil if no turn_context in tail

        return AgentSnapshot(
            kind: .codex,
            status: resolvedStatus,
            title: title,
            mode: mode,
            asOf: mtime,   // evidence clock = file mtime, never Date.now()
            detail: nil,   // no confirmed Codex detail signals yet
            evidence: AgentSnapshot.Evidence(
                source: "codex:rollout-tail",
                lastEventType: lastEventType,
                mtimeAgeSeconds: mtimeAge
            )
        )
    }

    // MARK: - Collision verdict (called by SessionObserver, not by the reader itself)
    //
    // When locate() returns the same rolloutURL for two tiles, the observer sets
    // status to .working with a special "codex (running)" title and nil detail for
    // both tiles. It does not call read() on the rollout for either tile. This
    // logic lives in the observer, not here, because the observer is the only place
    // that has the full set of live Codex tiles.
}
```

```swift
// In SessionObserver — the dispatch path for Codex tiles:

func updateCodexStatus(for tile: TileContext, now: Date) {
    guard codexReader.detect(processName: tile.foregroundCommand) else { return }

    // locate returns nil if no rollout matches cwd+paneStart.
    guard let rolloutURL = codexReader.locate(
        cwd: tile.cwd,
        paneStartedAt: tile.paneStartedAt
    ) else {
        // No rollout matched. Codex may be starting up or in an unrecognised path.
        // Leave status at .configuring if the tile just spawned, else .idle.
        return
    }

    // Collision check: is any other live Codex tile already using this rollout?
    if activeCodexRollouts[rolloutURL, default: 0] > 1 {
        // Same-cwd collision — honest under-claim.
        tile.updateStatus(.working, title: "codex (running)", detail: nil)
        return
    }

    // Unique match: derive real status.
    let snapshot = codexReader.read(
        at: rolloutURL,
        processAlive: tile.isProcessAlive,
        now: now
    )
    tile.updateStatus(snapshot.status, title: snapshot.title, detail: snapshot.detail)

    // Register the FSEvents watch on rolloutURL if not already watching.
    ensureWatch(for: rolloutURL, tileId: tile.id)
}
```

```swift
// Tail reading — read the last N lines without loading the full file:
private func readTail(url: URL, maxLines: Int) -> [RolloutLine] {
    // Open with FileHandle, seek near the end, read a bounded chunk.
    // A Codex rollout line is at most a few KB; 50 lines × 4 KB = 200 KB max read.
    // Decode only enum-valued metadata from each line — never body text (function args,
    // agent_message content, user_message content). Captured per line:
    //   .type                          ("response_item" | "event_msg" | "turn_context" | …)
    //   .payloadType                   (payload.type enum value)
    //   .approvalPolicy                (turn_context.payload.approval_policy, enum value)
    // approval_policy is an enum value (I5-safe), not a body — see Privacy spec.
    // Parsing is pure JSON; any line that fails to decode is skipped silently.
}

// Mode from the tail only — never a middle-of-file seek:
private func approvalPolicy(inTail tail: [RolloutLine]) -> String? {
    // Return the newest turn_context line's approval_policy, or nil if no turn_context
    // fell within the 50-line tail. The reader does NOT widen the read to find one.
    tail.last(where: { $0.type == "turn_context" })?.approvalPolicy
}

// Session-meta reading — read only line 1 of the rollout:
private struct SessionMeta {
    let cwd: String
    let timestamp: Date  // session_meta.payload.timestamp, ISO-8601
}
private func readSessionMeta(from url: URL) -> SessionMeta? {
    // Read up to the first newline only. Decode session_meta.payload.{cwd,timestamp}.
    // Never read further into the file.
}
```

## How we test it

### Logic (pure Core checks)

All checks live in `ContinuumRevivedCoreChecks/main.swift` and use the injected
`sessionsRoot` to point at a temporary fixture directory built inline. No daemon, no
home-directory access.

**Locate — basic match.** Build a fake rollout tree with two files:
`YYYY/MM/DD/rollout-<older>.jsonl` (line 1 cwd = `/repo`, timestamp = T−60 s) and
`YYYY/MM/DD/rollout-<newer>.jsonl` (line 1 cwd = `/repo`, timestamp = T+5 s). Set
`paneStartedAt = T`. Call `locate(cwd: "/repo", paneStartedAt: T)`. Assert it returns the
newer file. Assert it does not return the older file (its timestamp predates T). Manifest
records the returned URL basename.

**Locate — cwd mismatch.** Add a third file with cwd = `/other`. Assert `locate(cwd:
"/repo", ...)` never returns the `/other` file even if it is the newest by mtime.

**Locate — no match returns nil.** With only a rollout whose timestamp precedes
`paneStartedAt`, assert `locate` returns `nil`.

**Locate — paneStartedAt .distantPast accepts any match.** Pass `paneStartedAt =
.distantPast`. Assert `locate` returns the newest cwd-matching rollout regardless of its
timestamp. This validates the degraded mode for tiles whose pane-start was not recorded.

**Status derivation — working, idle, stale, done table.** Drive `read(at:processAlive:now:)`
with synthetic rollout files (written to a temp directory) covering every branch,
including the freshness boundaries that Gap-1/Gap-2 hinge on:
- Tool call in flight (`function_call`, no `function_call_output`, mtime age 10 s <
  `freshWorkingWindow`) → assert `working`.
- **Tool call in flight but stalled** (`function_call`, no output, mtime age 60 s >
  `freshWorkingWindow` 30 s, process alive, still under `staleWindow`) → assert `idle`.
  This is the case the prose/pseudo-code contradiction (Gap 1) resolved to `idle`; the
  check fails if an implementer keeps the old "in flight ⇒ always working" reading.
- Completed tool loop (paired `function_call`/`function_call_output`, mtime age 10 s) →
  assert `working`.
- Completed tool loop, mtime age 60 s > `freshWorkingWindow` → assert `idle`.
- `task_started` as the **last** meaningful event, mtime age 10 s → assert `working`.
  (No `response_item` follows it; per Gap-2's resolution this is `working` on freshness
  alone, with no "subsequent response_item" requirement.)
- `task_started` as the last meaningful event, mtime age 60 s > `freshWorkingWindow` →
  assert `idle`.
- `task_started` **followed by** a fresh `response_item/function_call` (i.e.
  `task_started` is not the last meaningful event) → assert the `function_call` branch
  fires, not the `task_started` branch. Records `lastEventType == "function_call"`.
- `agent_message` tail, mtime age 60 s → assert `idle`.
- `agent_message` tail, mtime age 5 s (well within any hypothetical idle window) →
  assert `idle`. This pins Gap-3: an `agent_message` tail is `idle` at every age below
  `staleWindow`, proving no `idleWindow` knob exists or is needed.
- `turn_aborted` tail → assert `idle`.
- Any tail, mtime age 1000 s > `staleWindow`, process alive → assert `idle` (not
  `working`).
- Any tail, mtime age 1000 s > `staleWindow`, process dead → assert `done`.
- Unparseable file → assert `idle` (never `working`).

Each case records `{status, mtimeAgeSeconds, lastEventType}` as measured values.

**Mode derivation (from the tail only).** Drive `read` with three fixtures:
- A rollout whose 50-line tail **contains** a `turn_context` line with
  `payload.approval_policy == "on-request"` → assert `snapshot.mode == "on-request"`
  (the returned `mode` equals the fixture's approval_policy — this is the falsifiable
  acceptance Gap-5 asked for).
- A rollout with **two** `turn_context` lines in the tail (`"untrusted"` older,
  `"on-failure"` newer) → assert `snapshot.mode == "on-failure"` (newest wins).
- A rollout whose only `turn_context` line sits **before** the 50-line tail (buried in a
  long file) → assert `snapshot.mode == nil` (the reader never seeks the file middle to
  find it). Records the byte offset of that line and the tail-start offset as measured
  values to prove the line was genuinely outside the read window.

**Title derivation.** Drive `read` with two fixtures:
- A `session_index.jsonl` entry present for the rollout with
  `thread_name == "refactor the parser"` → assert `snapshot.title == "refactor the
  parser"`.
- No matching `session_index` entry, `session_meta.payload.cwd == "/Users/x/selectus-ms"`
  → assert `snapshot.title == "selectus-ms"` (cwd-basename fallback).
- An 84-char `thread_name` → assert `snapshot.title` is exactly 80 chars (truncation).

**Taint check (I5 inline).** For every fixture above, assert that `AgentSnapshot.title`
and `AgentSnapshot.detail` do not contain any string from the set of body-field
placeholders (`"<agent_message_body>"`, `"<user_message>"`, `"<function_args>"`). This
proves the reader never reads those fields into the snapshot. The placeholder strings are
injected into the fixture's body fields explicitly so a leak would be detectable.

**`session_index.jsonl` stale-index test.** Build a `session_index.jsonl` whose newest
`updated_at` is 16 days before the matching rollout's mtime. Assert `locate` returns the
rollout (from mtime scan), not `nil`. Assert the reader does not require a matching index
entry.

**Detect — node ambiguity.** Assert `detect(processName: "node")` returns `true` and
`detect(processName: "codex")` returns `true`. Assert `detect(processName: "zsh")`
returns `false`.

**Round-trip (I7).** For each `AgentSnapshot` produced in the status table above, encode
to JSON and decode back; assert `snapshot == decodedSnapshot`.

### Backend (real-path / integration)

This check exercises the locate-and-read pipeline against a real `~/.codex/sessions`
tree. It requires the home directory to contain at least one rollout and must not write,
modify, or delete any Codex file.

The check:

1. Resolves `~/.codex/sessions`. If the directory does not exist, skips explicitly with a
   logged message — never passes silently.
2. Calls `locate(cwd: actualCwd, paneStartedAt: Date.distantPast)` where `actualCwd` is
   any cwd found in the newest rollout on disk (read from line 1). Assert it returns a
   non-nil URL. Assert the returned URL exists on disk. Assert the URL path contains
   `rollout-` in its basename.
3. Calls `read(at: returnedURL, processAlive: false, now: Date())`. Assert the returned
   snapshot has a non-`.configuring` status (i.e., the reader produced a real
   classification, not the default). Assert `snapshot.asOf` equals the file's mtime
   within one second (the evidence clock is mtime, not wall-clock).
4. Confirms that none of the fields in the snapshot contain raw body text. The check
   reads the first 200 bytes of the matched rollout's `event_msg` payload body (if any)
   and asserts that that string does not appear anywhere in `snapshot.title`,
   `snapshot.detail`, or `snapshot.evidence`.

The manifest records: `rolloutPath`, `snapshotStatus`, `asOfAge` (seconds since mtime).
These are measured values, not `{passed: true}`.

### UX (visual gate + dogfood snippet)

**Visual gate.** In the Component Lab sandbox, create a terminal tile whose launch profile
command is a shell script that writes a fake rollout to a temp `sessionsRoot` injected
into the reader. The script writes a two-line rollout: `session_meta` with
`payload.cwd == <tile's cwd>` and `payload.timestamp` one second after the tile's
`paneStartedAt`, then an `event_msg` with `payload.type == task_started`. The tile must
display status badge `working` (blue pulse) within one debounce cycle (≤ 250 ms after the
file is written). After the script writes a second line with `event_msg/agent_message`, the
badge must transition to `idle` (ring) on the next debounce cycle (the `agent_message`
branch is `idle` immediately — there is no idle-window wait). The Component Lab
affordance inspector must show `evidence.source == "codex:rollout-tail"` and
`lastEventType == "task_started"` in the tile's live status panel.

**Dogfood snippet.** Launch the real app with a project zone. Open a new terminal tile and
run `codex` in it on any coding task. Within a few seconds of Codex writing its first
rollout line, the tile's sidebar entry must change from the default `idle` ring to the
`working` blue pulse — no restart required, no manual configuration. In the sidebar dock,
the tile's row must show "codex" as the kind label. If two Codex processes are running in
the same directory simultaneously, both rows must show "codex (running)" without a
transition to any other status derived from the shared rollout. Close one Codex process;
the surviving tile must transition to `idle` within two debounce cycles (≤ 500 ms after
the process exits and the rollout mtime settles).

## Execution mode

**Mostly autonomous, with one human-observed dogfood step — stated honestly rather than
claimed away.**

**Autonomous (the whole matrix that gates merge).** Everything the reader itself owns is
verifiable without a human eye or a live agent:
- The **logic checks** are pure functions against injected file paths and a fake clock —
  no daemon, no live agent, no display. Every status branch, both freshness boundaries,
  the `mode`-from-tail cases, and the `title` cases are table-driven synthetic fixtures.
- The **backend real-path check** reads the user's real `~/.codex/sessions` tree but
  writes nothing; gate it in CI behind `ENABLE_CODEX_READER_REALPATH=1` so it skips on
  machines without a Codex history (explicit skip, never a silent pass).
- The **Component Lab visual gate** uses a *scripted fixture* rollout (not a live agent)
  and is evaluated by reading the affordance inspector's `evidence.source` /
  `lastEventType` text output — machine-checkable, no human review required.

These are the gate. A CI run with no human present can pass or fail all of them.

**Human-observed (the dogfood snippet only — NOT part of the automated gate).** The
dogfood snippet is deliberately a live, human-in-the-loop confidence step and is honestly
outside the autonomous envelope: it requires launching the real app, running a real
external `codex` install on a live coding task, watching the sidebar badge change color,
and (for the collision case) running two `codex` processes in one directory at once. None
of that is scriptable here, and the same-cwd collision + FSEvents-teardown behavior it
exercises is owned by the **`SessionObserver` ticket**, not this one. So the dogfood step
is scoped as a *manual acceptance* Dylan runs by hand after both this reader and the
observer have landed — it is listed in "Done when" as a human step, and merging this
ticket's code is gated by the autonomous matrix above, not by the dogfood run.

## Done when

- [ ] `CodexAgentStateReader` exists in `ContinuumRevivedCore`, conforms to
  `AgentStateReader`, and compiles with no warnings.
- [ ] `detect(processName:)` returns `true` for both `"codex"` and `"node"`, and `false`
  for all other process names.
- [ ] `locate(cwd:paneStartedAt:)` scans rollout files newest-mtime-first, reads only
  line 1 of each, and returns the first rollout whose `payload.cwd` matches and whose
  `payload.timestamp` is after `paneStartedAt`. The logic check fixtures confirm this.
- [ ] `locate` returns `nil` when no rollout matches both filters. The no-match check
  passes with a measured return value of `nil`.
- [ ] When `paneStartedAt == .distantPast`, `locate` accepts any cwd-matching rollout
  regardless of its timestamp. The distantPast check passes.
- [ ] `read(at:processAlive:now:)` produces the correct `AgentStatus` for every cell in
  the status-derivation table, and prose and pseudo-code agree on each: working (fresh
  tool in flight), **idle (stalled tool in flight, mtime past `freshWorkingWindow`)**,
  working (fresh tool loop), idle (stale tool loop), **working (`task_started` last +
  fresh)**, idle (`task_started` last + stale), working (`task_started` followed by a
  fresh `response_item`, via the response_item branch), idle (agent_message at any
  sub-`staleWindow` age), idle (turn_aborted), idle (stale process alive), done (stale
  process dead), idle (unparseable). All variants pass with measured values.
- [ ] There is exactly one authoritative status algorithm: the pseudo-code in
  Implementation breadcrumbs produces the same result as the "Status derivation" prose
  for every table row above (no branch where an implementer must choose between them).
- [ ] Only `freshWorkingWindow` and `staleWindow` govern the reader; there is no
  `idleWindow`. The two `agent_message` checks (age 5 s and 60 s) both return `idle`,
  demonstrating no third threshold has a distinct effect.
- [ ] `read` returns `mode` equal to the fixture's `turn_context.payload.approval_policy`
  when a `turn_context` line is inside the 50-line tail (single- and multi-`turn_context`
  cases, newest-wins), and `mode == nil` when the only `turn_context` line sits before
  the tail. The mode-derivation checks pass with measured `mode` values and the recorded
  byte offsets proving the nil case's line was outside the read window.
- [ ] `read` returns `title` equal to the `session_index` `thread_name` when present,
  else the cwd basename, truncated to 80 chars. The title-derivation checks pass with
  measured `title` values (including the 84→80 truncation case).
- [ ] Neither `read` nor `locate` ever seeks the middle of a rollout: they read only
  line 1 and the bounded 50-line tail. The `mode == nil` offset check is the falsifiable
  proof of this discipline.
- [ ] `AgentSnapshot.asOf` equals the rollout's file mtime (not `Date.now()`). The
  backend real-path check confirms this within one second.
- [ ] The taint check passes: no body-field placeholder from any fixture rollout appears in
  `title`, `detail`, or `evidence` for any fixture scenario.
- [ ] The I7 round-trip check passes for every snapshot produced in the status table
  (each snapshot carries its derived `mode` and `title`, so the round-trip also covers
  those two returned fields).
- [ ] The `session_index.jsonl` stale-index check passes: the reader finds the rollout via
  mtime scan even when the index is absent or out of date.
- [ ] The backend real-path check passes with a non-nil rollout URL, a non-`.configuring`
  status, and a measured `asOfAge` in the manifest.
- [ ] The Component Lab visual gate passes: `working` badge appears within 250 ms of the
  fake rollout write; `idle` appears on the next debounce cycle after the `agent_message`
  line is written (no idle-window wait); the affordance inspector shows
  `evidence.source == "codex:rollout-tail"`.
- [ ] `session_index.jsonl` is never consulted for the linkage decision (only optionally
  for a display title).
- [ ] `~/.codex/auth.json` and `~/.codex/config.toml` are never opened.

**Owned by the `SessionObserver` ticket, not this one** (this reader only provides the
seam — a `locate` that returns a stable per-rollout URL and a `read` that is never called
in the collision case; the observer builds the collision verdict and the watch lifecycle).
These are listed for traceability but are **not** acceptance criteria for merging this
ticket, and this ticket must not stub observer logic to satisfy them:
- [ ] (observer ticket) Same-cwd collision: when two Codex tiles resolve to the same
  rollout URL, both receive `AgentStatus.working` / title `"codex (running)"` / nil
  detail and neither calls `read()`.
- [ ] (observer ticket) FSEvents watch registered on the matched rollout when `locate`
  succeeds and torn down when `locate` returns a different URL next cycle.

**Human acceptance (manual, run after this reader AND the observer have landed — outside
the automated merge gate; see Execution mode):**
- [ ] Dogfood: launching the real app and running a real `codex` on a coding task
  transitions the tile badge from `idle` to `working` without restart, and same-cwd
  dual-Codex shows `"codex (running)"` on both tiles. Dylan runs this by hand and
  confirms visually.

## Depends on / unblocks

This ticket depends on the **`AgentStateReader` protocol ticket** having shipped the
`AgentStateReader` protocol type, the `AgentSnapshot` struct (with `kind`, `status`,
`title`, `mode`, `asOf`, `detail`, and `Evidence`), and the `AgentKind` closed enum
(`shell | claude | codex | pi | managed | unknown`). Without those types, `CodexAgentStateReader` has no protocol to conform to and no snapshot to return.

It depends on **pane-start capture at spawn** having added a `paneStartedAt` timestamp to
the descriptor — specifically the guarantee that `lastStartedAt` (already set to `now`
at spawn in `TileSpawner.spawnTerminal`) is the authoritative pane-start value, or that a
dedicated `paneStartedAt` field is present on `AgentDescriptor`. The observer must be
able to read this value when calling `locate`.

It unblocks the **reader golden-fixtures ticket**, which records redacted real rollout
files and replays them through the three readers together. The Codex reader must exist
before that ticket can exercise it.

It feeds the **`SessionObserver` ticket**, which dispatches to this reader when it detects
a `codex` or `node` foreground command, registers the FSEvents watch, and applies the
collision check. The observer cannot handle Codex status without this reader in place.

## Watch out for

**The recency heuristic is the hardest thing to get right.** Codex has 238 rollouts on a
real machine, 21 of which share a single cwd. The only thing that separates a tile's
session from a prior session in the same directory is the `session_meta.payload.timestamp`
comparison against `paneStartedAt`. If `paneStartedAt` is wall-clock at spawn time and
the rollout's `session_meta.timestamp` is in the agent's own time zone or format, an
off-by-one or timezone error silently attaches the wrong rollout. Verify that
`session_meta.payload.timestamp` is parsed as UTC (Codex uses ISO-8601 with a `Z` suffix
in the observed samples), and that `paneStartedAt` is recorded in the same epoch. The
locate check fixture must cover the case where the rollout timestamp is exactly equal to
`paneStartedAt` — that rollout predates the tile's first line and must be rejected (use
strict `<` not `<=`). A wrong linkage is worse than `nil` because it emits a false status
from a different agent's session.

**`session_index.jsonl` is stale and partial — never use it for linkage.** The spike
confirmed the index was 16 days behind and missing 110 of 238 rollouts. If any linkage
code path falls back to the index as a secondary source, it will silently fail for the
most-recent sessions, which are exactly the active ones. Read the index only for the
optional `thread_name` display title; if the title lookup fails, use the cwd basename
fallback. Never skip `locate` because the index claims to have a match.

**The tail read must be bounded.** Rollout files can be large (the spike saw files in the
megabyte range for long sessions). Reading the full file into memory to get the last 50
lines defeats the lightweight purpose of the reader. Use `FileHandle.seekToEndOfFile` and
read backward in chunks of at most 200 KB. If the file is smaller, reading it fully is
fine. The test fixtures should include a synthetic large file (1 000 lines) where the
reader must correctly identify the last meaningful event without a measurable memory spike.

**The `node` ambiguity must not cause false positives.** `detect(processName: "node")`
returns `true`, which means the observer will attempt `locate` for any tile running
Node — including non-Codex Node scripts, a Node server, or an npm command. If `locate`
returns `nil`, the observer must leave the tile classified as `AgentKind.unknown`, not
`AgentKind.codex`. The reader must never be registered as the handler for a tile simply
because `detect` returned `true`; the observer confirms classification only when `locate`
succeeds. This is not a defense the reader can enforce alone — it is a contract the
observer must uphold — but the reader's `detect` returning `true` for `node` is the root
of the risk, so it should be clearly documented in the reader's source.

**The observer, not the reader, owns collision detection.** The reader has no visibility
into other live tiles; it returns an `AgentSnapshot` for a single rollout URL. The
collision check — whether two tile contexts have resolved to the same URL — must run in
the observer after both `locate` calls complete, not inside `read`. If the reader tried to
detect collisions itself (by scanning all tiles), it would need global state that violates
the protocol's per-agent design. The reader contract is: given a URL, describe what you
see. The observer decides what to do with two tiles claiming the same URL.

**No status fabrication on ambiguity.** When two tiles collide on the same rollout, the
output is `AgentStatus.working` (from the process liveness signal — Codex is running,
that much is known) and title `"codex (running)"`. It is never `idle` (the process is
alive), never `done` (the session is active), and never `needsAttention` (there is no
attention signal). The `"codex (running)"` title is a specific, concrete string — not a
format string, not a dynamic label — so that it is visually distinguishable from a fully-
resolved Codex status at a glance.
