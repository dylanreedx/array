# Session topology snapshot type

## What this delivers

A `SessionTopologySnapshot` struct and its parser give the rest of the program a clean,
Codable picture of what tmux actually holds at any given moment: which sessions exist, which
windows live inside each session, the `%pane_id` for each window's single pane, the pane's
current working directory, and the foreground command running in it. This is the
**reconciliation oracle** — the measured ground truth against which Continuum's persisted
descriptors can be diffed to catch drift, prove invariants, and drive a deterministic
manifest. Without it, every claim like "I spawned a window at `%7` in `continuum-proj-X`"
is unfalsifiable; with it, the check harness can run `snapshot.window(target: "%7")` and
get either a populated entry or a clear miss.

The snapshot type is purely definitional: no daemon, no side effects, no UI. What it enables
is a battery of invariant checks — I1, I3, I7, I8 in particular — that later topology and
lifecycle tickets depend on as their test substrate.

## How it fits

This ticket builds on nothing — it is a standalone foundation whose only imports are
`Foundation`. What it unblocks is significant: the injectable substrates ticket (the one
that defines `TmuxControl` with a real impl and an in-memory fake) needs a concrete output
type to return from its read operations; the invariant spine harness ticket needs the
snapshot as the "measured" side of every I1/I3/I8 assertion; and every Phase 1 topology
ticket that proves "we spawned three windows and the session holds exactly three" relies on
this type as the evidence carrier.

The relationship to the existing seams is additive, not modifying. `TmuxSession.swift`
today contains `sessionName`, `wrap`, `killSessionCommand`, and the locator/config helpers —
none of which are touched here. `TerminalSessionDescriptor.swift` carries the persisted
Continuum view of a session — also untouched. This ticket adds a companion type,
`SessionTopologySnapshot`, that carries the **tmux view** of the same reality, enabling
callers to diff the two.

## The approach

Define `SessionTopologySnapshot` and its nested types as `Codable`, `Equatable`, and
`Sendable` structs in `ContinuumRevivedCore`, covering exactly the fields that `tmux
list-windows -a -F '...'` can emit in one pass. Parse by splitting the format string output
on record and field separators. Write a round-trip test and a parse-from-fixture test. Ship
nothing else.

The format string for the tmux query is fixed:

```
tmux list-windows -a -F '#{session_name}\t#{window_id}\t#{pane_id}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_pid}'
```

Each output line maps to one `WindowEntry`. Lines from the same `session_name` are grouped
into one `SessionEntry`. The complete set of `SessionEntry` values is the snapshot. There is
no wall-clock timestamp stored on the snapshot itself — callers that need a capture time
stamp it externally, because the snapshot type is pure data and must not import wall-clock.

`pane_pid` is captured as an `Int32` (matching the platform pid type) and stored as-is.
`window_id` is the `@N`-prefixed window identity from tmux; `pane_id` is the `%N`-prefixed
pane identity. Both are stored as `String` because their prefix is load-bearing (a bare
`Int` would lose the sigil and make the values opaque). `pane_current_path` is a `String`;
`pane_current_command` is a `String`. No fields are optional — every field is required in the
format string, so a line missing any field is a parse error, not a nil.

The parser is a static pure function — `SessionTopologySnapshot.parse(tmuxOutput: String) throws -> SessionTopologySnapshot` — that takes the raw multi-line string tmux emits and
returns the snapshot or throws a typed `ParseError`. No `Process`, no shell, no `UserDefaults`
access inside the parser. The format string constant lives on the type as a `public static let`
so callers and the injectable tmux control substrate can use it without repeating it.

## Where it lives

**New file:** `Sources/ContinuumRevivedCore/SessionTopologySnapshot.swift`

This is the only file created by this ticket. No existing files are modified.

The public surface of the new file:

- `public struct SessionTopologySnapshot: Codable, Equatable, Sendable` — the top-level type
- `public struct SessionEntry: Codable, Equatable, Sendable` — one tmux session; fields:
  `sessionName: String`, `windows: [WindowEntry]`
- `public struct WindowEntry: Codable, Equatable, Sendable` — one window/pane pair; fields:
  `windowId: String`, `paneId: String`, `paneCurrentPath: String`,
  `paneCurrentCommand: String`, `panePid: Int32`
- `public static let tmuxFormatString: String` — the `-F` argument shown above, owned by the
  type
- `public static func parse(tmuxOutput: String) throws -> SessionTopologySnapshot` — the
  pure parser
- `public enum ParseError: Error, Equatable` — `malformedLine(String)`, `invalidPid(String)`
  (the `emptyInput` case is REMOVED — see ruling below)

> **RULING (2026-07-01 — supersedes the empty-input handling everywhere in this ticket):**
> Empty or whitespace-only input is NOT an error — it is a valid **empty (zero-session)
> snapshot** (the normal "nothing running" case). `parse("")` and `parse("\n\n")` return a
> snapshot with zero sessions; they do NOT throw. Concretely: remove the `ParseError.emptyInput`
> case and the `guard !lines.isEmpty else { throw … }`; when there are zero non-empty lines,
> return an empty snapshot. `ParseError` now covers only a genuinely malformed *non-empty line*
> (`malformedLine` = wrong field count, `invalidPid` = non-numeric pid). The two
> "`parse("")` / `parse("\n\n")` throws `ParseError.emptyInput`" assertions in the tests below
> are replaced by: assert each returns a **zero-session snapshot**.
- `public func window(paneId: String) -> WindowEntry?` — convenience lookup used by invariant
  checks; scans all sessions

The existing seams that are named but **not modified**:

- `Sources/ContinuumRevivedCore/TmuxSession.swift:8` — `sessionName(tileId:)` — lives here
  for reference; this ticket does not touch it
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:3` — the persisted
  descriptor that the snapshot will be diffed against in later tickets

## Implementation breadcrumbs

```swift
// SessionTopologySnapshot.swift

public struct SessionTopologySnapshot: Codable, Equatable, Sendable {

    public static let tmuxFormatString =
        "#{session_name}\t#{window_id}\t#{pane_id}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_pid}"

    public struct WindowEntry: Codable, Equatable, Sendable {
        public let windowId: String         // "@N" form
        public let paneId: String           // "%N" form
        public let paneCurrentPath: String
        public let paneCurrentCommand: String
        public let panePid: Int32
    }

    public struct SessionEntry: Codable, Equatable, Sendable {
        public let sessionName: String
        public let windows: [WindowEntry]
    }

    public let sessions: [SessionEntry]

    // Convenience: find any window across all sessions by its pane id.
    public func window(paneId: String) -> WindowEntry? {
        sessions.lazy.flatMap(\.windows).first { $0.paneId == paneId }
    }

    // Convenience: find all windows in a named session.
    public func session(named name: String) -> SessionEntry? {
        sessions.first { $0.sessionName == name }
    }
}

public extension SessionTopologySnapshot {
    enum ParseError: Error, Equatable {
        case emptyInput
        case malformedLine(String)
        case invalidPid(String)
    }

    static func parse(tmuxOutput: String) throws -> SessionTopologySnapshot {
        let lines = tmuxOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        guard !lines.isEmpty else { throw ParseError.emptyInput }

        // Group by session name while preserving insertion order.
        var order: [String] = []
        var grouped: [String: [WindowEntry]] = [:]

        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6 else { throw ParseError.malformedLine(line) }

            let (sessionName, windowId, paneId, path, command, pidStr) =
                (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])

            guard let pid = Int32(pidStr) else { throw ParseError.invalidPid(pidStr) }

            let entry = WindowEntry(
                windowId: windowId,
                paneId: paneId,
                paneCurrentPath: path,
                paneCurrentCommand: command,
                panePid: pid
            )

            if grouped[sessionName] == nil {
                order.append(sessionName)
                grouped[sessionName] = []
            }
            grouped[sessionName]!.append(entry)
        }

        let sessionEntries = order.map { name in
            SessionEntry(sessionName: name, windows: grouped[name]!)
        }
        return SessionTopologySnapshot(sessions: sessionEntries)
    }
}
```

Key pattern notes: `split(omittingEmptySubsequences: false)` is required on the tab-split
so an empty `pane_current_command` (which tmux emits as two adjacent tabs) does not silently
collapse a field and cause an off-by-one. The `order` array preserves session insertion order
so `Equatable` comparisons on snapshots taken at different times are stable and deterministic.
The `ParseError.emptyInput` case fires only when the entire string is blank — a real tmux with
zero sessions still emits zero lines, and that is a valid (empty) snapshot, not an error. The
distinction matters: zero lines from tmux means zero sessions; a blank string passed by a
caller is a usage error.

## How we test it

### Logic (pure Core checks)

All logic checks live in `ContinuumRevivedCoreChecks` and require no daemon, no filesystem,
and no `UserDefaults`.

**Parse fixture test.** Feed the parser a hard-coded multi-line string that looks exactly
like `tmux list-windows -a -F '...'` output — two sessions, three windows total, including
one session with a single window and one with two — and assert field-by-field equality on the
returned snapshot. This is the primary correctness check; every field in `WindowEntry` must be
asserted, including `panePid` as an `Int32`.

**Round-trip test (I7).** Construct a `SessionTopologySnapshot` in code, encode it to JSON
with `JSONEncoder`, decode it with `JSONDecoder`, and assert the decoded value equals the
original. This covers I7 directly. Parameterize over at least: an empty snapshot (zero
sessions), a snapshot with one session/one window, and a snapshot with two sessions.

**Parse error tests.** Assert `parse("")` throws `ParseError.emptyInput`. Assert that a line
with five tab-separated fields (missing the pid) throws `ParseError.malformedLine`. Assert
that a line with a non-numeric pid field throws `ParseError.invalidPid`. Assert that a line
with a valid pid of `"0"` parses successfully (pid zero is a real value for some system
processes and must not be treated as invalid).

**Empty-tmux test.** Assert `parse("\n\n")` (whitespace-only input that splits to zero
non-empty lines) throws `ParseError.emptyInput`. This confirms the empty-string guard also
fires for effectively-empty inputs, not just a literal `""`.

**Window lookup test.** Build a multi-session snapshot and assert `window(paneId: "%3")`
returns the correct entry; assert `window(paneId: "%99")` returns `nil`.

**Order stability test.** Parse a fixture where sessions appear in a known order, then
assert `snapshot.sessions.map(\.sessionName)` equals that order exactly. This guards the
insertion-order requirement needed for deterministic manifest diffs.

### Backend (real-path/integration)

This ticket's scope is intentionally a pure type plus parser — there is no daemon call in
the code itself. The real-path integration check belongs to the injectable substrates ticket,
which wraps a real `tmux list-windows` invocation and asserts the output parses without error
into a non-empty snapshot. That check is the proof that the format string constant matches
what a real tmux binary emits.

However, this ticket must ship a **format string self-check** in the `ContinuumRevivedCoreChecks`
target: assert that `SessionTopologySnapshot.tmuxFormatString` contains exactly the six
format variables `#{session_name}`, `#{window_id}`, `#{pane_id}`, `#{pane_current_path}`,
`#{pane_current_command}`, and `#{pane_pid}`, in that order, tab-separated — so if someone
edits the constant without updating the parser's field-index assumptions, the check fails
immediately rather than causing a silent parse error on the first real tmux invocation.

### UX (visual gate + dogfood snippet)

This ticket adds no visible UI. There is no UX gate here. The UX contract is instead picked
up by the invariant spine harness ticket, which renders measured snapshot values in a manifest
the human can read after an overnight run. The dogfood moment for this type arrives when the
harness ticket prints a line like:

```
topology: 2 sessions — continuum-proj-<id> (3 windows), continuum-ws-<id> (1 window)
```

and the owner can read it as a sanity check. That output is tested there, not here.

## Execution mode

**Autonomous.** Every check in this ticket is a pure-Swift assertion over in-memory
fixtures: no tmux daemon, no filesystem, no UI, no cloud account, no device. The
`swift build` + matrix run is sufficient to prove this ticket correct. No human eye is
needed to confirm the result. A future real-tmux integration check (in the substrates ticket)
will exercise the format string against a live daemon, but that check is not authored here.

## Done when

- [ ] `Sources/ContinuumRevivedCore/SessionTopologySnapshot.swift` exists and compiles
      cleanly with `swift build` on `ContinuumRevivedCore`.
- [ ] `SessionTopologySnapshot`, `SessionEntry`, `WindowEntry`, and `ParseError` are all
      `public`, `Codable`, `Equatable`, and `Sendable`.
- [ ] `SessionTopologySnapshot.tmuxFormatString` is a `public static let` containing the
      six-field tab-separated format string exactly as specified in "The approach."
- [ ] `SessionTopologySnapshot.parse(tmuxOutput:)` is a `public static func` that takes a
      `String` and returns `SessionTopologySnapshot` or throws `ParseError`.
- [ ] The parse fixture test passes: a two-session, three-window fixture round-trips
      field-by-field correctly, including `panePid` as `Int32`.
- [ ] The JSON round-trip test passes for empty, single-session, and multi-session snapshots
      (I7 covered).
- [ ] All five parse-error tests pass: empty input, five-field line, non-numeric pid, pid
      `"0"` succeeds, whitespace-only input.
- [ ] The window lookup test passes for a hit and a miss.
- [ ] The order stability test passes.
- [ ] The format string self-check passes: constant contains all six `#{...}` variables
      tab-separated in the documented order.
- [ ] No existing file is modified; no new file other than the one above is created.
- [ ] `./scripts/run-matrix.sh` is green.

## Depends on / unblocks

This ticket depends on nothing — it is a standalone pure type. It unblocks the injectable
substrates ticket (which needs a concrete output type for its `TmuxControl.readTopology()`
method), the invariant spine harness ticket (which needs the snapshot as the measured side of
I1/I3/I8 assertions), and every Phase 1 session topology ticket that must prove "tmux holds
what Continuum thinks it spawned." None of those can author meaningful assertions without a
type that carries the evidence.

## Watch out for

**The `omittingEmptySubsequences: false` flag on the tab split is load-bearing.** If you
use the default (`true`), an empty `pane_current_command` — which tmux renders as two
adjacent tabs — collapses, making the parser see five fields instead of six and throwing
`malformedLine` on valid output. The fixture test catches this only if the fixture includes a
window with an empty command; include one.

**Pid zero.** `Int32("0")` parses successfully to `0`, and that is correct — some system
processes have pid 0 and a tile could theoretically observe one. Do not add a `pid > 0`
guard; `Int32(pidStr) == nil` is the only invalid-pid condition.

**Do not store a capture timestamp on the snapshot.** Wall-clock is banned in Core (matching
the doctrine for the op-log and all other core types). If a caller needs to know when the
snapshot was taken, they stamp it externally. Resist the temptation to add a `capturedAt:
Date` convenience field — it breaks the pure-function parse contract, requires injecting a
clock, and makes equality checks on fixtures fragile.

**`ParseError.emptyInput` fires only on truly empty (or whitespace-only) input, not on
zero-session output.** Zero-session output is zero non-empty lines, which produces an empty
`sessions` array — a valid snapshot. A blank string is a caller bug. The test suite must
cover both cases explicitly or this distinction erodes on the next refactor.

**This ticket does not run `tmux` itself.** Any reviewer who asks "but did you test against
a real tmux?" should be pointed to the injectable substrates ticket, which is the correct
home for the real-path integration check. Conflating the two would make this ticket
needs-substrate, defeating its standalone autonomous classification and its place as a
non-blocking foundation.
