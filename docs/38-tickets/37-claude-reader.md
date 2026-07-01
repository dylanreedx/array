# Claude reader — link pane pid to session store and derive status from events

## What this delivers

After this ticket lands, every terminal tile whose foreground process is `claude` has its
`AgentDescriptor.status` populated by a real, evidence-backed derivation rooted in Claude
Code's own on-disk session store — not a heuristic, not a title-parse, not a mock. The system
knows the difference between `working` (tool loop active, fresh mtime), `idle` (turn done,
awaiting the user), `done` (process gone, session ended cleanly), and `stale` (file too old to
trust). It uses the cleanest possible link: a pane pid file that Claude Code maintains at
`~/.claude/sessions/<pid>.json`, giving both the `sessionId` and the `cwd` needed to locate the
per-session JSONL event stream without any guessing. The pid file's role is confined to
**location** — it is how `locate` resolves the JSONL path — and status itself is derived
entirely from the JSONL event tail plus the mtime the observer hands in. That single-source
derivation is what makes every status row deterministic and testable.

What this ticket explicitly does **not** do: it does not emit `needsAttention` from file
parsing (that path is blocked until a non-bypass golden fixture exists), and it does not
install a hook into Claude's settings (that is the consent-gated hook ticket that follows).
The reader under-claims honestly — never `needsAttention`, never `working` on stale evidence.

## How it fits

This ticket is one of three parallel concrete readers that together fulfill the reader
registry. It rests on the `AgentStateReader` protocol established by the reader protocol
ticket (the thin per-agent contract: a `kind` property plus `detect`, `locate`, and `read`)
and on the `AgentKind` closed enum introduced by the kind-classifier ticket that replaces the
free `agentKind: String` on `AgentDescriptor`. Both of those are direct prerequisites — the
reader returns `AgentKind.claude`, and its conformance type is meaningless without the
protocol. The protocol's exact shape is fixed by that ticket and shared verbatim by the Pi
and Codex readers, so this reader conforms to it as-is: it does **not** widen `locate`'s
return type or change `read`'s signature. Any richer per-agent input would be a protocol
change owned by the protocol ticket, not this one.

This reader unblocks two things. First, the reader golden-fixture ticket, which replays
recorded stores through all three readers and cannot be complete without the Claude reader
existing. Second, the `SessionObserver` ticket, which drives the reader registry against live
tile pids and writes back to `AgentDescriptor.status` — the observer is the consumer, and it
cannot be built without a reader to drive. The Pi reader and Codex reader are sibling tickets
at the same level; none of them depends on the others, and they can be developed concurrently
once the protocol ticket lands.

## The approach

The reader is a value-type `struct ClaudeAgentStateReader: AgentStateReader`, living in Core,
with zero file-system or async I/O in its body — all I/O is injected through a
`FileSystemClient` protocol (introduced by the injectable substrates), so every logic path is
exercisable by a test that manufactures fake files in memory without touching the real disk.

**Detection.** `detect(processName:)` returns `true` when `processName == "claude"`. That is
the entire classifier — `pane_current_command` reliably shows `claude` because the Claude Code
CLI is a native Mach-O arm64 binary (not a Node shim), so the kernel-reported command name is
always `claude`, never `node`. No secondary probe is needed.

**Location.** `locate(pid:cwd:runId:)` constructs the path
`~/.claude/sessions/<pid>.json` and reads it. Two things come out of that file: the
`sessionId` string (a UUID) and the cwd string. The cwd from the pid file is used — not the
tmux pane's `pane_current_path` — because OSC-7 drift can put the pane's reported cwd slightly
ahead of where Claude actually started. The project directory under
`~/.claude/projects/<encode(cwd)>/<sessionId>.jsonl` is derived from those two values.
`encode(cwd)` is the transform that replaces every `/` and `.` with `-` — verified against the
real on-disk path `-Users-dylan-Documents-personal-continuum-revived`, which confirms that a
leading slash becomes a leading dash, and that the double-dash `--` in worktree paths arises
from adjacent `/` + `.` both mapping to `-`. The function is a one-liner and carries its own
logic check.

`locate` returns `nil` (not a crash) if the pid file does not exist — this is the normal case
when the process has exited and the pid file has been cleaned up. The reader treats a missing
pid file as the primary `done` signal (combined with a clean last event in the JSONL).

**Reading — single source: the JSONL tail.** `read(storeURL:asOf:)` takes the JSONL file URL
returned by `locate` and the `asOf` mtime the **observer** already measured, and returns an
`AgentSnapshot`. Status is derived from exactly one source: the JSONL event tail cross-checked
against `asOf`. There is deliberately **no pid-file tier** in the read path.

Why the pid file is not a read-path status source (the seam this ticket closes): the protocol
(reader protocol ticket) fixes `read` as `read(storeURL:asOf:)` — the reader is handed only the
JSONL URL and is contractually forbidden from opening any file outside that store's logical
tree, and the reader is a stateless value type so it cannot carry the pid-file path across from
`locate`. The pid file lives at `~/.claude/sessions/<pid>.json`, keyed by pid, and the JSONL
path encodes only `cwd`+`sessionId` — so the pid-file path is **not** derivable from the JSONL
URL. Rather than smuggle it through hidden state or widen the shared protocol (which would fork
the Pi and Codex readers), this ticket drops the pid-file `.status` tier entirely. It is a
lossless drop: the AGENT-READERS spike ranked the pid file's `.status` (`busy`/`idle`) as only
a *coarse* redundant signal, and D11 makes the JSONL the authoritative source for detail. Every
status this reader emits is already fully derivable from the tail + `asOf`, so nothing is lost
by not reading the pid file for status.

The pid file's *only* job in this reader is **location** — `locate` reads it to recover
`sessionId`+`cwd` and build the JSONL path (see Location above). After `locate` returns, the
pid file is never touched again.

**The read.** Read only the **last `tailBytes`** (default 8 KB) of the JSONL file (a
`FileHandle` seek to `max(0, size - tailBytes)`, then decode complete lines, discarding the
first partial line). This gives the last several events without loading the full file. From
those lines, find the last **meaningful** event — skipping the timestamp-less control lines
`mode`, `permission-mode`, and `ai-title` for the purpose of status, since they carry no
timestamp and can appear out of band. The meaningful events that drive status are `assistant`
and `user`. The last `ai-title` event in the tail (not skipped — only skipped for status, still
used for the title field) provides the `title` value; the last `permission-mode` event provides
`mode`.

**Presence of the JSONL file encodes the `done` signal.** `locate` returns the JSONL URL by way
of the pid file; when the process has exited and Claude Code has cleaned up the pid file,
`locate` returns `nil` and `read` is never called — the observer records `done`/`shell` for that
pane from the process signal, per the protocol ticket's `unknown`/dead-process fallback. So
`done` is not a JSONL-parse verdict in this reader; it is the observer's response to
`locate == nil` (no live pid file). When `read` *is* called, a live session exists, and the tail
+ `asOf` decide between `working`, `idle`, and `stale`.

**Status mapping (from the JSONL tail + `asOf`, where `age = observer_now − asOf` arrives as
`evidence.mtimeAgeSeconds`; the reader compares `age` to its configured windows):**

- Last meaningful event is `assistant` with `stop_reason == "tool_use"` and there is no later
  `user` event (i.e., the tool loop is open) → `working`, provided `age` is within
  `freshWorkingWindow`.
- Trailing `assistant(stop_reason: "tool_use")` → `user(toolUseResult present)` pairs, `age`
  within `freshWorkingWindow` → `working` (active tool loop, tool results arriving).
- Last meaningful event is `assistant` with `stop_reason == "end_turn"`, `age` within
  `idleWindow` (default 120 s) → `idle`.
- `age` beyond `staleWindow` (default 900 s), any tail → `idle` (never `working` on old
  evidence; I6 is the law here). The process is known-alive because `locate` found a live pid
  file; a live-but-stale session under-claims to `idle`.
- Anything unparseable, an empty tail, or any exception → `idle`, never `working`. I6 states:
  unknown ⇒ never fabricated `working`; under-claim always.

(`stale` as an `AgentStatus` value is produced by the boot-restore path — `restoredForBoot()` —
not by this reader; a live session whose evidence is old maps to `idle`, per the row above.)

**`needsAttention` is not emitted by this reader.** The AGENT-READERS spike confirmed that
this machine runs Claude in `bypassPermissions` mode, so there is no observable file-based
signal for a pending permission prompt. The D11 decision locks this: file-derived
`needsAttention` stays unimplemented until a golden fixture captured in default (non-bypass)
permission mode proves the signal. Until then, the reader will never set `needsAttention` —
that state waits for the hook ticket.

**Clock.** `asOf` in the returned `AgentSnapshot` is the `asOf` value the observer **hands in**
to `read(storeURL:asOf:)` — the JSONL file's mtime, measured by the observer before the call.
The reader echoes it back unchanged; it never calls `Date()` and never re-stats the file for the
clock. This is mandatory — the wall-clock ban from the configurable-first doctrine means the
observer owns the clock, computes `age = now − asOf`, and passes that age to the reader as
`evidence.mtimeAgeSeconds` for the freshness-window comparison. The reader does not know what
`now` is; it only knows the `asOf` and the `age` the observer gave it.

**Privacy.** The reader reads `type`, `stop_reason`, `aiTitle`, and `permissionMode` — enum
values and a short label. It never reads `.message.content`, `toolUseResult` bodies, tool
input/output arguments, or any free-text field. The `AgentSnapshot` it produces carries
`{kind, status, title?, mode?, asOf, detail?, evidence}` and nothing else — no pid, no path,
no transcript fragment. This satisfies I5 by shape.

All three windows (`freshWorkingWindow`, `idleWindow`, `staleWindow`) are stored in a
`ClaudeReaderConfig` struct with the defaults above and are user-configurable — a Settings
entry and a persisted default per the configurable-first doctrine. No threshold is hardcoded.

## Where it lives

**`Sources/ContinuumRevivedCore/AgentStatusEngine.swift`** — the existing file at line 1
(verified). This is where `AgentStatusEngine`, `AgentStatus`, and `AgentDescriptor` live.
The new `ClaudeAgentStateReader` struct and `ClaudeReaderConfig` struct are added here (or in
a new file `Sources/ContinuumRevivedCore/ClaudeAgentStateReader.swift` if the file grows large
— either is fine, both are in Core).

**`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`** — the `AgentDescriptor`
struct at line 94 and `AgentStatus` enum at line 85 (both verified). The reader writes back to
`AgentDescriptor.status` (line 97) and `AgentDescriptor.statusUpdatedAt` (line 98). No new
fields are added to `AgentDescriptor` in this ticket.

**`Sources/ContinuumRevivedCore/RunArtifactsWatcher.swift`** — studied but not modified. The
debounce/budget pattern (`RunArtifactsWatcherConfig` at line 3, the scan-and-debounce loop at
lines 91–122) is the direct model for how the `SessionObserver` will drive this reader. The
reader itself is stateless; the budgeting lives in the observer.

**Test fixtures directory** — `Tests/Fixtures/agent-readers/claude/` (new directory). Each
scenario is a subdirectory containing a synthesized `sessions/<pid>.json` and a
`projects/<encode(cwd)>/<sessionId>.jsonl`. All free-text fields are scrubbed to a fixed
placeholder; only type enums, timestamps, and the `aiTitle` (set to a short label like
`"Implement login page"`) remain.

## Implementation breadcrumbs

```swift
// ClaudeReaderConfig — all thresholds configurable, never hardcoded
public struct ClaudeReaderConfig: Equatable, Sendable {
    public var freshWorkingWindow: TimeInterval  // default 30 s
    public var idleWindow: TimeInterval           // default 120 s
    public var staleWindow: TimeInterval          // default 900 s
    public var tailBytes: Int                     // default 8192

    public init(freshWorkingWindow: TimeInterval = 30,
                idleWindow: TimeInterval = 120,
                staleWindow: TimeInterval = 900,
                tailBytes: Int = 8192) { … }
}

// AgentStateReader protocol (from the reader protocol ticket — conform to it verbatim):
// protocol AgentStateReader: Sendable {
//     var kind: AgentKind { get }
//     func detect(processName: String) -> Bool
//     func locate(pid: pid_t?, cwd: String, runId: String?) -> URL?
//     func read(storeURL: URL, asOf: Date) -> AgentSnapshot
// }
// NOTE: read receives only storeURL (the JSONL URL) + asOf (observer-measured mtime).
// It must not open any file outside storeURL's tree — so the pid file is NOT reachable
// from read(). Status is derived from the JSONL tail alone. See "Reading" above.

public struct ClaudeAgentStateReader: AgentStateReader {
    public let kind: AgentKind = .claude
    private let homeURL: URL           // injectable: URL(fileURLWithPath: NSHomeDirectory())
    private let fs: FileSystemClient   // injectable fake for tests
    private let clock: () -> Date      // injectable clock (fake in tests) — the ONLY now source;
                                       // never a bare Date() literal, satisfies the wall-clock ban
    private let config: ClaudeReaderConfig

    public func detect(processName: String) -> Bool {
        processName == "claude"
    }

    // locate is the ONLY place the pid file is read — to recover sessionId + cwd and
    // build the JSONL path. After this returns, the pid file is never touched again.
    public func locate(pid: pid_t?, cwd: String, runId: String?) -> URL? {
        guard let pid else { return nil }
        let pidFile = homeURL
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = fs.contents(at: pidFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["sessionId"] as? String,
              let pidCwd = json["cwd"] as? String
        else { return nil }   // no live pid file ⇒ observer records done/shell, read() not called

        let encoded = Self.encodeCwd(pidCwd)
        return homeURL
            .appendingPathComponent(".claude/projects/\(encoded)/\(sessionId).jsonl")
    }

    // encode(cwd): replace every '/' and '.' with '-'
    static func encodeCwd(_ cwd: String) -> String {
        cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 }
           .reduce("", { $0 + String($1) })
    }

    // read receives the JSONL URL + the observer's asOf. NO pid file, NO mtime stat,
    // NO Date() — asOf is echoed straight through; age is computed from asOf by the observer
    // and could equally be recomputed here from asOf if the reader is given a clock-free age.
    public func read(storeURL jsonlURL: URL, asOf: Date) -> AgentSnapshot {
        // JSONL tail — last tailBytes bytes, decode complete lines (drop first partial)
        let lines = readTailLines(at: jsonlURL, maxBytes: config.tailBytes)
        let ageSeconds = clock().timeIntervalSince(asOf)  // now − observer's asOf; injected clock
        let status = deriveStatus(from: lines, ageSeconds: ageSeconds)
        let title = extractTitle(from: lines)       // last ai-title event's aiTitle
        let mode = extractMode(from: lines)          // last permission-mode event's permissionMode

        return AgentSnapshot(
            kind: .claude,
            status: status,
            title: title.map { String($0.prefix(80)) },  // truncated, I5-safe
            mode: mode,
            asOf: asOf,     // echoed unchanged — the observer's mtime, never Date()
            detail: nil,    // no needsAttention detail without hook
            evidence: .init(
                source: "claude:jsonl-tail",
                lastEventType: lastMeaningfulType(from: lines),
                mtimeAgeSeconds: ageSeconds
            )
        )
    }

    // deriveStatus: the pure function, no I/O, drives the golden table.
    // Inputs: decoded event array (type + stop_reason + toolUseResult presence) + age seconds.
    // Outputs: AgentStatus — never needsAttention (no hook), never done (that is locate==nil),
    //          never working on stale evidence.
    func deriveStatus(from events: [ClaudeEvent], ageSeconds: Double) -> AgentStatus {
        // … implement the mapping table from The approach section, comparing ageSeconds
        //     to config.freshWorkingWindow / idleWindow / staleWindow …
        // unknown / unparseable / empty → .idle  (I6: never fabricate .working)
    }
}
```

The `encodeCwd` function is pure and has its own mini-check asserting the double-dash
behavior: `encodeCwd("/Users/dylan/.claude/worktrees/foo")` →
`"-Users-dylan--claude-worktrees-foo"` (the `/.` becomes `--`). This is the exact case from
the spike and must not regress.

`ClaudeEvent` is a small local struct (`type: String, stopReason: String?, hasToolUseResult:
Bool, aiTitle: String?, permissionMode: String?, timestamp: String?`) that decodes only the
fields this reader cares about, via `decodeIfPresent` for everything optional. Unknown `type`
values are preserved as strings — the reader switches on them exhaustively and falls to `idle`
for anything not in the known set. Never crash on an unknown event type; this format is
version-unstable.

## How we test it

### Logic (pure Core checks)

A table-driven check in `ContinuumRevivedCoreChecks` (following the same pattern as the
invariant spine) feeds synthesized `[ClaudeEvent]` arrays and an `ageSeconds` value into
`ClaudeAgentStateReader.deriveStatus(from:ageSeconds:)` and asserts the exact `AgentStatus`
output. The function under test is pure — no I/O, no clock — so these checks are instant and
deterministic. (`done` is not a `deriveStatus` output: it is the observer's response to
`locate == nil`, and is covered by the `claude-done` fixture below, not here.)

Required rows (manifests carry the actual vs expected value, never `{passed:true}`):

1. Last event `assistant(stop_reason: "tool_use")`, no later `user`, age 10 s → `working`.
2. Trailing `assistant(tool_use)` → `user(toolUseResult: true)` → `assistant(tool_use)`,
   age 10 s → `working` (tool loop still open).
3. Last event `assistant(stop_reason: "end_turn")`, age 60 s → `idle`.
4. Last event `assistant(stop_reason: "end_turn")`, age 200 s (beyond `idleWindow`) →
   `idle` (still `idle`, not `working`; past idle window doesn't fabricate anything).
5. Last event `assistant(stop_reason: "tool_use")`, age 1000 s (beyond `staleWindow`) →
   `idle` (never `working` on old evidence; I6 — an open tool loop with stale mtime under-claims).
6. Empty event array, any age → `idle` (I6: unknown ⇒ never `working`).
7. Array containing only timestamp-less control lines (`mode`, `permission-mode`, `ai-title`),
   no meaningful events → `idle`.
8. Unknown `type` value `"future-event-type"` as the last event, age 10 s → `idle`
   (forward-compat).

A separate check asserts `encodeCwd` behavior:
- `encodeCwd("/Users/dylan/project")` == `"-Users-dylan-project"` (leading slash → dash).
- `encodeCwd("/Users/dylan/.claude/worktrees/x")` == `"-Users-dylan--claude-worktrees-x"`
  (the `/.` yields `--`; this is the double-dash case from the spike).
- `encodeCwd("")` == `""` (empty is safe, not a crash).

A title-extraction check asserts that `extractTitle` returns the `aiTitle` from the last
`ai-title` event, ignores non-`ai-title` events, and returns `nil` when no `ai-title` event is
present. The title is truncated to 80 characters; a test with a 200-character `aiTitle` asserts
the output is exactly 80 chars.

### Backend (real-path / integration)

The reader's `locate` and `read` methods are exercised against the golden fixture files in
`Tests/Fixtures/agent-readers/claude/`. The fixture runner injects a real `FileSystemClient`
backed by the fixture directory tree (not the live `~/.claude` — never depend on the developer's
real agent history in a check) and an injected fixed `clock` so `ageSeconds` is deterministic.
The runner:

1. Constructs a `ClaudeAgentStateReader` with `homeURL` pointing at the fixture's synthetic
   `home/` directory and `clock` returning the scenario's fixed "now".
2. Calls `locate(pid: 38649, cwd: "/Users/dylan/Documents/personal/continuum-revived", runId: nil)`
   and asserts the returned URL points at `home/.claude/projects/-Users-dylan-Documents-personal-continuum-revived/<sessionId>.jsonl` — reading the fixture's `sessions/38649.json` pid file to
   recover `sessionId`+`cwd`. (This is the pid file's only role.)
3. Reads the JSONL mtime from fixture metadata to form `asOf`, then calls
   `read(storeURL: <url>, asOf: <mtime>)` and asserts the returned `AgentSnapshot` matches the
   expected snapshot for the scenario.

Required fixture scenarios (`Tests/Fixtures/agent-readers/claude/<scenario>/`):

- **`claude-working`** — pid file present (used for `locate` only) + JSONL tail ending in
  `assistant(stop_reason: "tool_use")` → `user(toolUseResult)` pair, `asOf` set so the injected
  clock yields `ageSeconds` within `freshWorkingWindow`. Assert `status == .working`,
  `evidence.lastEventType == "assistant"`, `mode` extracted, `title` from `ai-title`. (The pid
  file's `.status` field is irrelevant to the verdict — status comes from the JSONL tail.)
- **`claude-idle`** — pid file present (for `locate`) + JSONL ending in
  `assistant(stop_reason: "end_turn")`, `ageSeconds` within `idleWindow`. Assert
  `status == .idle`. (Again, the verdict is JSONL-driven; the pid `.status` value is not read.)
- **`claude-done`** — pid file absent (not written to fixture). Assert `locate` returns `nil`
  (no crash) — the observer, not this reader, records `done` from the missing pid file, so
  `read` is never called for this scenario. The fixture asserts the `locate == nil` contract.
- **`claude-stale`** — valid JSONL, `asOf` set so the injected clock yields `ageSeconds` beyond
  `staleWindow`. Assert `status == .idle` (never `working` on old evidence).
- **`claude-encode-cwd`** — a pid file with `cwd` containing a `.` segment
  (`/Users/dylan/.claude/worktrees/ticket-37`). Assert `locate` builds the correct double-dash
  path.
- **`claude-unknown-events`** — JSONL containing only events with `type: "attachment"`,
  `type: "file-history-snapshot"`, `type: "queue-operation"`. Assert `status == .idle`
  (I6: no known signal → no fabricated status).

Each fixture check produces a manifest: `{ scenario, expectedStatus, actualStatus,
actualTitle, ageSeconds }`. A mismatch fails with the full manifest printed.

Additionally, the `AgentSnapshot` round-trip invariant (I7): each `read`-producing scenario's
output snapshot is `JSONEncoder`-encoded and `JSONDecoder`-decoded and compared with `==`. This
runs for the five scenarios that call `read` (`claude-done` asserts only the `locate == nil`
contract and produces no snapshot).

A **taint assertion** on every snapshot-producing fixture output (the five that call `read`):
none of the known scrubbed-placeholder strings (the sentinel value used to replace bodies in
fixtures, e.g. `"REDACTED_BODY"`) appears in any field of the returned `AgentSnapshot`. This
proves the reader never read a body field from the fixture. (The fixture creator deliberately
places the sentinel in body fields; the reader's privacy discipline is what keeps it out of the
snapshot.)

### UX (visual gate + dogfood snippet)

This ticket produces no new UI surface by itself — the `SessionObserver` ticket that follows is
what writes `AgentDescriptor.status` into the live tile model and feeds the sidebar. However,
the reader can be exercised against a live Claude session to confirm the linkage is correct.

Visual gate: after the observer is wired (in the observer ticket), the Component Lab's tile
status inspector should show `working`, `idle`, or `done` for a tile running `claude`. Because
this ticket in isolation doesn't wire the observer, the visual gate for this ticket specifically
is an **integration smoke test**: construct a `ClaudeAgentStateReader` in a throwaway XCTest
(or a Component Lab debug action) pointing at the real `~/.claude` (with a real `clock`
returning `Date()` for this smoke test only — this is test scaffolding, not reader code), call
`locate` with the pid of a currently running `claude` process, measure the JSONL mtime for
`asOf`, call `read(storeURL:asOf:)`, and log the resulting `AgentSnapshot`. Assert `locate`
returned non-`nil` and the snapshot's `status` is `working` or `idle` (never `.stale`, since the
process is live and freshly active).

Dogfood snippet (confirms the full link end-to-end, run while a Claude session is open in any
terminal tile):

Open the app -> open a project zone that has a terminal tile running `claude` ->
open the Component Lab -> activate the affordance inspector's "agent reader debug" action
(added in this ticket: a debug-only button that calls `ClaudeAgentStateReader.locate` + `.read`
and prints the `AgentSnapshot` to the inspector panel) ->
see exactly `{ kind: claude, status: working, title: "<last ai-title>", mode: "bypassPermissions", asOf: <recent timestamp> }` in the inspector, with `asOf` matching the JSONL file's mtime within 2 seconds.

If the Claude session is idle (turn complete), `status` is `idle`. If the pid file does not
exist (process exited), `locate` returns `nil` and the debug action reports "no live session"
(the `done` verdict itself is the observer's job, from `locate == nil` — this reader never emits
`done`). Either a `working`/`idle` snapshot or a `nil` locate confirms the link is working
correctly. An `idle` result with a live, actively-working process indicates `asOf`/`age` is
pulling from the wrong file or the JSONL is not being updated (an active tool loop should read
`working`) — that is a stop condition worth investigating before the observer is wired.

## Execution mode

Autonomous. The reader is a pure value type in Core; every I/O path is injectable through
`FileSystemClient`. The logic check is entirely deterministic (synthesized inputs, known
outputs). The golden fixture check uses a fixture directory tree, not the real `~/.claude`,
and can run on CI without any Claude session present. The `encodeCwd` function, the
`deriveStatus` table, and the `extractTitle` extractor are all pure functions with no
external dependencies. The taint and round-trip checks are similarly pure. No human eyes, no
cloud, no running agent are required to validate the full correctness story — the fixtures
carry the real on-disk schema, verified against the actual `~/.claude` store on 2026-06-30,
and the test suite fully exercises all known event shapes.

## Done when

- [ ] `ClaudeAgentStateReader` struct exists in Core, conforms to `AgentStateReader`, and
  compiles without warnings.
- [ ] `ClaudeReaderConfig` struct exists with `freshWorkingWindow`, `idleWindow`,
  `staleWindow`, and `tailBytes` fields, all with the stated defaults. No threshold is
  hardcoded anywhere in the reader body.
- [ ] `detect(processName:)` returns `true` for `"claude"` and `false` for every other string.
- [ ] `encodeCwd` passes its three-case check including the double-dash `/.` case.
- [ ] `locate(pid:cwd:runId:)` returns `nil` when the pid file is absent (no crash, no
  exception propagated to the caller).
- [ ] `read(at:)` returns an `AgentSnapshot` with `asOf` equal to the JSONL file mtime — never
  `Date()`.
- [ ] `read(at:)` never returns `status == .needsAttention` (the hook path is not implemented
  in this ticket; the reader is hardwired to under-claim).
- [ ] All nine Logic derivation-table rows pass with measured-value manifests.
- [ ] All six fixture scenarios pass: `locate` resolves correctly and `read` returns the
  expected status and title.
- [ ] The `claude-encode-cwd` fixture confirms double-dash path construction.
- [ ] Taint assertion: no scrubbed placeholder string appears in any `AgentSnapshot` field for
  any fixture.
- [ ] I7 round-trip: all six fixture snapshots serialize and deserialize to equal values.
- [ ] No change to `AgentDescriptor`, `AgentStatus`, or `TerminalSessionDescriptor` —
  those types are consumed, not modified.
- [ ] `AgentDescriptor.agentKind` is not modified by this ticket; the kind-classifier and
  closed-enum work belongs to its own ticket.

## Depends on / unblocks

This ticket directly depends on the `AgentStateReader` protocol ticket (which defines the
`detect`/`locate`/`read` contract this reader implements) and the `AgentKind` closed-enum
ticket (which provides the `AgentKind.claude` case returned in the snapshot). Without those
two, the reader has no conformance target and no enum case to return.

It also depends on the injectable substrates from Phase 0, specifically the `FileSystemClient`
protocol (which makes the `locate` and `read` methods testable without real disk access). If
the substrates ticket has not landed by the time this reader is implemented, the implementer
should define a minimal local `FileSystemClient` with `contents(at:)` and
`modificationDate(at:)` methods and plan to harmonize it with the substrates version once that
ticket lands.

This reader unblocks the **reader golden-fixture ticket** (which cannot run its full fixture
suite without all three readers existing) and the **`SessionObserver` ticket** (which drives
the reader registry against live pids). The hook-consent ticket also logically follows this
reader, since it adds `needsAttention` breadcrumbs that this reader's `read` method will
eventually interpret — but the hook ticket does not require this reader to be modified, only
that it exists and runs.

## Watch out for

**The hardest thing to get right is the `encodeCwd` transform, specifically the double-dash
case.** The spike verified that the `continuum-revived` project maps to
`-Users-dylan-Documents-personal-continuum-revived` (leading slash → leading dash, all slashes
→ dashes), and that worktree paths containing `/.claude/` produce `--claude` (the adjacent
`/` and `.` both become `-`, yielding two consecutive dashes). If you implement `encodeCwd` by
replacing only `/` with `-` (forgetting the `.`→`-` rule), you will build the wrong directory
path, `locate` will silently return `nil`, and the reader will appear to work on plain project
paths while silently failing for any cwd that contains a dot segment. The `claude-encode-cwd`
fixture is the stop condition for this bug — it must pass before this ticket is considered done.

**The `asOf` field must be the file mtime, not `Date()`** — this is the wall-clock ban from
the configurable-first doctrine, and violating it means the `SessionObserver`'s staleness
calculation will be nonsensical (it compares `now - snapshot.asOf`; if `asOf` is `Date()` at
read time, staleness is always ~0 ms, and a 24-hour-old JSONL will appear fresh). The fixture
checks catch this because the fixture runner sets the file's mtime explicitly and asserts
`asOf` matches it.

**Do not read the JSONL from the beginning.** A long-running Claude session accumulates
megabytes of JSONL; loading the full file for a status check is wasteful and will cause the
`SessionObserver`'s budget to be exhausted in a large workspace. The tail-read approach (seek
to `max(0, size - tailBytes)`, discard the first partial line, decode the rest) is the correct
pattern. The `tailBytes` default of 8192 bytes gives roughly the last 10–30 events for a
typical stream, which is more than enough for status derivation. If you load the whole file in
a `Data(contentsOf:)` call, the fixture check will still pass (fixtures are small), but a
real-path run on a large session will show the budget problem.

**`needsAttention` must not be emitted from this reader's file-parsing path** under any
circumstances in this ticket. The AGENT-READERS spike could not observe a pending-permission
event in the file store (bypass mode), so there is no verified signal to match against. Any
implementer who sees a JSONL event type that looks like it might be a permission prompt and is
tempted to wire it to `needsAttention` must resist: add the event type to a comment in the
reader marking it as a candidate for the future non-bypass fixture, and leave the output as
`idle`. The golden fixture for `needsAttention` does not yet exist; shipping a fabricated
signal before it does violates I6 and destroys the orange-means-real trust invariant.

**The pid file's `cwd` field must be used to build the project directory path — not the tmux
pane's `pane_current_path`.** OSC-7 updates trail slightly behind the process's actual cwd
(especially in a session that has run many turns and changed directories). Using the pane path
risks constructing a `~/.claude/projects/<slightly-wrong-encode>/` path that doesn't match any
real directory and causes `locate` to return `nil` silently. The pid file is authoritative
because Claude Code wrote it at session start.
