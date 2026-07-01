# Observer over ssh: reading remote agent stores through the same channel

## What this delivers

When a project's host is a remote machine reached via the `sshForward` path, the
`SessionObserver` reads agent stores — Claude's `sessions/<pid>.json` and event JSONL,
Codex rollouts, Pi run directories — exactly as it would for a local project, but over
the same ssh channel that already carries the tmux attach. The remote poll budget enforces
at least a 5-second gap between consecutive store reads on a given tile, so a fleet of
remote tiles cannot flood the VPS with ssh subprocesses.

From the user's perspective, a tile whose agent lives on the Hetzner CX32 shows the same
status vocabulary as a local tile — blue working pulse, orange attention diamond, green
done check — updating in the background at a human-readable cadence. The sidebar row reads
"claude · working" or "pi · done" without any manual refresh. If the ssh link drops, the
tile degrades to the grey stale hollow ring and holds that state until connectivity
returns; it never invents a working or done status out of thin air.

From the system's perspective, this ticket extends the per-tile observation path in
`SessionObserver` with a `RemoteStoreReader` that shells out `ssh <host> cat <path>` or
`ssh <host> tmux display-message …` for each store operation, enforces the 5-second
minimum poll interval per tile (a named `remotePollBudget` property, user-configurable,
default 5.0 seconds), and feeds the resulting bytes into the same reader pipeline (Claude,
Codex, Pi) that processes local files. The ssh invocations are fire-and-forget
subprocesses — they never hold a persistent connection of their own, they reuse the same
`ssh -G`-resolved host config the attach wrap uses, and they are subject to the same
`ServerAliveInterval=15`/`ServerAliveCountMax=3` keepalive flags so a dropped link is
detected promptly rather than hanging indefinitely.

## How it fits

This ticket builds directly on two completed pieces. The session observer (the
`SessionObserver` with budgets ticket) is the component being extended: its per-tile
`TileObservation` already tracks `detectedKind`, the FSEvents watcher URL, and the budget
counters; remote tiles add a `RemoteStoreReader` in place of the local FSEvents path. The
remote attach real path ticket (which proves a real `sshForward` session attaches and
survives a link drop as stale-not-wrong) is the prerequisite substrate: without it there
is no proven `Host` model, no resolved ssh config, and no baseline that remote tmux
sessions exist and are reachable. This ticket assumes both are done.

What this ticket unblocks is the full remote-observation story. The ssh reconnect and
backoff degradation ticket (which handles dropped links and backoff schedules) depends on
the observer already issuing remote reads — it needs a client to degrade. The Tailscale
discovery ticket can add Tailscale peers as `sshForward` hosts once the observer proves the
observation path is correct for any ssh-reachable host. The iOS observer ultimately
consumes the same `AgentDescriptor.status` field that the remote observer writes, so it
benefits transitively from this ticket.

## The approach

The `SessionObserver` learns about a tile's `Host`. When a tile's host is `localhost`, the
existing FSEvents path is used unchanged. When the host is a `sshForward` target, the
observer skips FSEvents entirely — there is no local filesystem to watch — and instead
schedules a polling loop on a per-tile `DispatchSourceTimer` that fires every
`remotePollBudget` seconds (default 5.0, minimum enforced at the timer level, never
shortened by observer logic). On each fire, the observer issues ssh commands to read the
relevant store files for the detected agent kind, feeds the result bytes into the local
reader, derives a status, and writes `AgentDescriptor.status` exactly as the local path
does.

The ssh reads use two primitives, both modeled as injected closures so tests can replace
them with in-memory fakes:

- `remoteCat`: executes `ssh [options] <host> cat <absolutePath>`, returns `Data` or
  throws on non-zero exit. Used for store files: Claude's pid JSON and event JSONL tail,
  Codex rollout lines, Pi run.json and status.json.
- `remoteTmuxDisplay`: executes `ssh [options] <host> tmux display-message -p -t <target>
  '#{pane_current_command}'`, returns a trimmed `String`. Used for the slow-cadence kind
  re-detection step, which already fires on the 5-second budget timer for remote tiles
  (there is no separate slow-poll timer; the remote budget timer serves both purposes).

Both closures share a set of hardened ssh flags assembled once from the resolved host
config: host alias or `100.x` address from `ssh -G`, identity file, and the keepalive
flags (`-o ServerAliveInterval=15 -o ServerAliveCountMax=3`). The flag set is a value type
assembled by the existing host model at the point where the observer is handed the tile.

Reading a Claude event JSONL remotely does not fetch the entire file. The observer tracks
the last-seen byte offset for each remote tile in a `remoteReadOffsets: [UUID: [URL:
Int64]]` dictionary. On each poll cycle it issues `ssh <host> tail -c <N> <path>` (where
N is a configurable `remoteTailBytes` defaulting to 4096) to fetch only the last chunk,
then appends it to any unparsed remainder from the previous cycle. This keeps each poll
bounded to a fixed number of bytes regardless of how long an agent has been running. The
Pi `run.json` and `status.json` are small fixed-size files; they are fetched in full with
`cat` each cycle. The Codex rollout is also fetched with a tail, using the same offset
tracking.

If a `remoteCat` or `remoteTmuxDisplay` call throws — non-zero ssh exit, timeout, broken
pipe — the observer does not update `AgentDescriptor.status`. It increments an internal
`consecutiveFailureCount` for that tile. After 3 consecutive failures the observer calls
`engine.ingest(.explicit(.stale), at: now)` to transition the tile to stale, then
continues polling at the same budget interval. When a subsequent poll succeeds, the failure
count resets and normal status derivation resumes. This is the "stale, never wrong"
contract that the remote attach real path ticket establishes at the attach level, now
applied at the observation level.

The per-tile `remotePollBudget` timer is cancelled in `tileDidClose(tileId:)` alongside
the existing budget cleanup. For remote tiles, `tileDidClose` also cancels any in-flight
ssh subprocess for that tile by cancelling its `Task`.

## Where it lives

**Primary changes are in `SessionObserver`**, which does not exist as a file yet when this
ticket lands — it is introduced by the `SessionObserver` with budgets ticket. This ticket
adds to that file. All new types go into `Sources/ContinuumRevivedCore/` so they are
testable without the app layer.

**`RemoteStoreReader`** — a new `struct` in
`Sources/ContinuumRevivedCore/RemoteStoreReader.swift`. It owns the two injected closures
(`remoteCat` and `remoteTmuxDisplay`), the ssh flag assembly logic, the offset dictionary,
and the `consecutiveFailureCount` per-tile state. It exposes one async method:

```swift
// RemoteStoreReader.swift
public struct RemoteStoreReader: Sendable {
    public typealias RemoteCat    = @Sendable (String, String) async throws -> Data
    //                                          ^host   ^path
    public typealias RemoteDisplay = @Sendable (String, String) async throws -> String
    //                                           ^host   ^tmuxCmd

    public var remoteCat: RemoteCat
    public var remoteDisplay: RemoteDisplay
    public var remoteTailBytes: Int = 4096           // user-configurable; default 4096
    public var remotePollBudget: TimeInterval = 5.0  // user-configurable; minimum enforced
    // ... offset tracking omitted from this sketch
}
```

**`AgentStatusEngine.swift`** (`Sources/ContinuumRevivedCore/AgentStatusEngine.swift:3`) —
no changes. The engine's `ingest(_:at:)` and `tick(at:)` are already the right interface;
the remote path calls them identically to the local path.

**`TmuxSession.swift`** (`Sources/ContinuumRevivedCore/TmuxSession.swift:7`) — no changes
to existing symbols. This ticket does not touch `TmuxSession.sessionName(tileId:)`,
`TmuxSession.wrap(profile:tileId:tmuxPath:)`, or `TmuxLocator`. The ssh command assembly
for remote reads lives in `RemoteStoreReader`, not in `TmuxSession`, because it is an
observation concern, not a launch-profile concern.

**`SessionObserver` additions** — within the `TileObservation` struct (defined by the
session observer ticket), add:

```swift
var host: Host                          // .localhost or .sshForward(alias:resolvedFlags:)
var remoteReader: RemoteStoreReader?    // non-nil iff host != .localhost
var remotePollTimer: DispatchSourceTimer?
var consecutiveFailureCount: Int = 0
var remoteOffsets: [String: Int64] = [:]   // path → last-read byte offset
```

The `start(tiles:)` method branches on `tile.host` to either register an FSEvents watcher
(local) or start a `remotePollTimer` (remote). The two paths share everything downstream:
the reader call, signal assembly, `deriveAgentStatus`, and the `applyDerivedStatus` write
to `AgentDescriptor`.

## Implementation breadcrumbs

```swift
// RemoteStoreReader.swift

// The real implementation of remoteCat shells out via Process.
// The injected closure makes it replaceable in tests.
static func makeLiveRemoteCat(sshFlags: [String]) -> RemoteCat {
    return { host, path in
        let result = try await shellOut(
            command: "ssh",
            arguments: sshFlags + [host, "cat", path]
        )
        // shellOut throws on non-zero exit; returns stdout Data
        return result
    }
}

// Tail variant for large files (Claude JSONL, Codex rollout)
static func makeLiveRemoteTail(sshFlags: [String], bytes: Int) -> RemoteCat {
    return { host, path in
        try await shellOut(
            command: "ssh",
            arguments: sshFlags + [host, "tail", "-c", "\(bytes)", path]
        )
    }
}

// Display variant for pane_current_command
static func makeLiveRemoteDisplay(sshFlags: [String]) -> RemoteDisplay {
    return { host, tmuxCmd in
        let raw = try await shellOut(
            command: "ssh",
            arguments: sshFlags + ["-t", host] + tmuxCmd.split(separator: " ").map(String.init)
        )
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// The core read method called by the poll timer handler
func read(
    tileId: UUID,
    host: String,
    kind: AgentKind,
    descriptor: TerminalSessionDescriptor,
    readers: SessionObserver.Readers
) async throws -> AgentSnapshot {
    switch kind {
    case .claude:
        // 1. Fetch sessions/<pid>.json (small; full cat)
        let pidJSON   = try await remoteCat(host, "~/.claude/sessions/\(descriptor.pid).json")
        let pidRecord = try JSONDecoder().decode(ClaudePidRecord.self, from: pidJSON)
        // 2. Tail the event JSONL (offset-tracked)
        let jsonlPath = claudeJSONLPath(from: pidRecord)
        let offset    = remoteOffsets[jsonlPath, default: 0]
        let tailData  = try await remoteTail(host, jsonlPath)
        // Append to unparsed remainder, parse lines, update offset
        let snapshot  = readers.claude.readFromBytes(tailData, pidRecord: pidRecord)
        return snapshot

    case .pi:
        // pi run.json and status.json are small; full cat both if present
        let runPath    = piRunJSONPath(for: descriptor)
        let runData    = try await remoteCat(host, runPath)
        let snapshot   = try readers.pi.readFromBytes(runData, runId: descriptor.agentDescriptor?.runId)
        return snapshot

    case .codex:
        // Locate rollout by scanning session_index or listing newest mtime remotely.
        // Use: ssh <host> ls -t ~/.codex/sessions/ | head -5
        // then tail the matched rollout (offset-tracked).
        let rolloutPath = try await locateCodexRollout(host: host, cwd: descriptor.cwd, paneStartedAt: descriptor.lastStartedAt)
        let tailData    = try await remoteTail(host, rolloutPath)
        let snapshot    = readers.codex.readFromBytes(tailData)
        return snapshot

    case .shell, .unknown, .managed:
        // No store to read; status from process liveness only (already handled by engine tick)
        throw RemoteReadError.noStore
    }
}
```

```swift
// SessionObserver additions — poll timer setup for remote tiles

private func startRemotePollTimer(for obs: inout TileObservation) {
    let budget = max(obs.remoteReader?.remotePollBudget ?? 5.0, 5.0) // floor at 5 s
    let timer  = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + budget, repeating: budget)
    timer.setEventHandler { [weak self] in
        guard let self else { return }
        Task {
            await self.serviceRemoteTile(tileId: obs.tileId)
        }
    }
    timer.resume()
    obs.remotePollTimer = timer
}

private func serviceRemoteTile(tileId: UUID) async {
    guard var obs = observations[tileId],
          let reader = obs.remoteReader,
          let host   = obs.host.sshAlias else { return }

    do {
        let snapshot = try await reader.read(
            tileId: tileId, host: host, kind: obs.detectedKind,
            descriptor: /* fetch descriptor from store */,
            readers: self.readers
        )
        obs.consecutiveFailureCount = 0
        observations[tileId] = obs

        let signals = buildSignals(from: snapshot, obs: obs, at: .now)
        let derived = deriveAgentStatus(signals: signals)
        await MainActor.run {
            self.applyDerivedStatus(derived, snapshot: snapshot, tileId: tileId, at: .now)
        }
    } catch {
        obs.consecutiveFailureCount += 1
        if obs.consecutiveFailureCount >= 3 {
            let staleEngine = obs.engine // captured value type
            await MainActor.run {
                // Transition to stale; holds until next successful poll
                var e = staleEngine
                _ = e.ingest(.explicit(.stale), at: .now)
                self.writeStatus(e.status, tileId: tileId, at: .now)
            }
        }
        observations[tileId] = obs
    }
}
```

The key control-flow invariant: `max(budget, 5.0)` is applied at the timer setup site,
not in the configuration property, so even if a user persists a value below 5 seconds via
Settings, the floor is enforced at runtime without rejecting the stored preference. The
user-facing Settings entry accepts any positive value but the timer silently clamps to 5.0
at the lower bound.

For the pane-kind re-detection step on remote tiles, `remoteTmuxDisplay` is called inside
`serviceRemoteTile` before the store read — if the detected kind has changed (e.g. the
user stopped Claude and started a plain shell), the observation entry is updated in place
and the store read is skipped for this cycle. This mirrors the local slow-cadence detection
poll, collapsed into the same budget timer rather than a separate timer.

## How we test it

### Logic (pure Core checks)

Write `RemoteStoreReaderTests` in `ContinuumRevivedCoreTests/`. All three tests inject
in-memory fakes for `remoteCat` and `remoteDisplay` — no actual ssh subprocess is started.

The first test covers the 5-second floor. Create a `RemoteStoreReader` configured with
`remotePollBudget = 1.0` (below the floor). Start a mock poll loop that calls
`max(reader.remotePollBudget, 5.0)` and record the effective interval. Assert it is 5.0,
not 1.0. This is a pure arithmetic check on a value type.

The second test covers stale-after-3-failures. Inject a `remoteCat` that always throws.
Drive `serviceRemoteTile` three times via the testing hook, supplying a controllable `now`
date. After the third call, assert `AgentDescriptor.status == .stale`. After a fourth call
where `remoteCat` succeeds (swap the closure to return valid Pi `run.json` bytes with
`status = "done"`), assert `consecutiveFailureCount == 0` and `AgentDescriptor.status ==
.done`. The clock is fully injected; no real timer fires.

The third test covers the byte-offset tracking for the Claude JSONL tail. Inject a
`remoteCat` that on the first call returns 200 bytes representing two Claude events (one
`assistant(end_turn)`, one `ai-title`), and on the second call returns 100 bytes
representing one new `assistant(tool_use)` event. Assert that after the first poll the
derived status is `.idle`, and after the second poll the derived status is `.working`.
Assert the `remoteOffsets` dictionary advanced by the correct byte count after each call.
The in-memory bytes feed into the real Claude reader (`ClaudeAgentStateReader`) so that
the parsing logic is also exercised, not mocked out.

All three tests run with `swift test --filter RemoteStoreReaderTests`, zero network
access, zero real filesystem beyond any test fixture files.

### Backend (real-path / integration, not bypassed)

The integration check requires a real ssh-reachable host — the Hetzner CX32 VPS or any
machine the developer can reach by hostname alias in `~/.ssh/config`. It is gated by an
environment variable (`CONTINUUM_TEST_SSH_HOST`) that must be set for the test to run;
without it, `XCTSkip("CONTINUUM_TEST_SSH_HOST not set")` is thrown.

The test proceeds in three steps. First, it ssh-es to the host, creates a temporary
directory, and writes a synthetic Claude `sessions/<pid>.json` (with a known sessionId and
status `busy`) and a corresponding minimal JSONL (one `assistant` event with `stop_reason
= tool_use`) using a `here-doc` command over the same ssh channel. Second, it instantiates
a `RemoteStoreReader` configured with the real `remoteCat` and `remoteDisplay` closures,
pointing at the temp path, and calls `read(...)` directly. It asserts the returned
`AgentSnapshot.status == .working` and `AgentSnapshot.evidence.source` contains
`"claude:sessions"`. Third, it overwrites the JSONL with a new event (`assistant` with
`stop_reason = end_turn`) and calls `read(...)` again; it asserts the status transitions
to `.idle`. Finally, it ssh-es to the host to remove the temp directory.

The whole integration test tolerates a 10-second wall-clock timeout on each ssh command.
It does not test the poll timer's cadence — that is a logic test — it tests only that
`remoteCat` retrieves real bytes from a real remote path and that the reader parses them
correctly into the expected `AgentSnapshot`.

### UX (visual gate + dogfood snippet)

**Visual gate.** In the running app, navigate to a project whose host is set to the VPS
(`sshForward` reach path). Open the Component Lab (Developer menu) and navigate to the
Sidebar Tile fixture. Confirm the fixture renders without crash and that the mock-data rows
still show (the visual gate is a non-regression check — no mock data is removed by this
ticket). With a real remote agent running, confirm the sidebar row for that tile shows a
status badge (any status, including grey stale) rather than a crash or an empty label.

**Dogfood snippet.** Open the app with the project host set to the VPS. Start a Claude
session in a terminal tile attached to the VPS via the `sshForward` path. In the Claude
session, run any Bash tool (e.g. `bash ls`) so Claude appends an `assistant` event with
`stop_reason = tool_use` to its remote JSONL. Within 10 seconds — one remote poll cycle
plus processing — the sidebar row for that tile should flip from the grey idle ring to the
blue working pulse. No manual refresh, no app restart. When Claude finishes and appends an
`end_turn` event, the sidebar should return to the grey idle ring within 10 seconds of the
next poll cycle. The 10-second window is deliberately generous given the 5-second poll
floor; if the transition takes longer than 15 seconds, something is wrong with the poll
timer or the ssh subprocess.

## Execution mode

**Needs-substrate.** The logic tests are fully autonomous and run with no network access.
The integration test and the UX dogfood snippet require a real ssh-reachable host with
tmux and at least one agent store on disk. The integration test is gated behind an
environment variable and skipped without it. The dogfood snippet requires a live Claude
session producing tool calls on the remote host. Neither can be satisfied by in-memory
fakes or a local tmux session alone; a real VPS (or equivalent remote host reachable by
ssh) is necessary to prove the ssh subprocess path, the byte-offset tracking under real
network latency, and the status vocabulary update cadence at the stated poll floor.

## Done when

- [ ] `RemoteStoreReader.swift` exists in `Sources/ContinuumRevivedCore/`, compiles
  cleanly, and exposes the `remoteCat`, `remoteDisplay`, `remoteTailBytes`, and
  `remotePollBudget` properties.
- [ ] `remotePollBudget` is user-configurable: it is a stored property on
  `RemoteStoreReader` with a persisted default of 5.0 seconds, a corresponding Settings
  entry, and a runtime floor of 5.0 seconds enforced at the timer setup site via
  `max(budget, 5.0)`.
- [ ] The `SessionObserver`'s `TileObservation` struct carries `host`, `remoteReader`,
  `remotePollTimer`, `consecutiveFailureCount`, and `remoteOffsets` fields.
- [ ] For a tile whose host is `sshForward`, the observer starts a `remotePollTimer` on
  `tileDidSpawn` and cancels it on `tileDidClose`; no FSEvents source is registered for
  remote tiles.
- [ ] The poll timer fires at the effective interval (`max(remotePollBudget, 5.0)`) and
  calls `serviceRemoteTile` on the observer's serial queue.
- [ ] `serviceRemoteTile` issues `remoteCat` (or `remoteTail` for offset-tracked files)
  for the detected agent kind, feeds the bytes into the correct reader, derives status via
  `deriveAgentStatus`, and writes `AgentDescriptor.status` via `applyDerivedStatus` on the
  main actor.
- [ ] After 3 consecutive `remoteCat`/`remoteDisplay` failures, the tile transitions to
  `.stale` via `engine.ingest(.explicit(.stale), at: now)`. `consecutiveFailureCount`
  resets to 0 on the next successful poll.
- [ ] The pane-kind re-detection step (calling `remoteDisplay` for
  `pane_current_command`) runs inside `serviceRemoteTile` before the store read, updating
  the detected kind if it has changed.
- [ ] The Claude JSONL tail is offset-tracked: `remoteOffsets` advances by the byte count
  returned each cycle; the reader receives only the new tail bytes plus any unparsed
  remainder.
- [ ] The 5-second floor logic test passes: a `remotePollBudget` of 1.0 produces an
  effective interval of 5.0.
- [ ] The stale-after-3-failures logic test passes: three injected failures → `.stale`;
  next successful poll → correct derived status and `consecutiveFailureCount == 0`.
- [ ] The byte-offset tracking logic test passes: two sequential polls with known byte
  payloads produce the correct `AgentSnapshot.status` sequence and the correct offset
  advancement.
- [ ] The integration test (gated behind `CONTINUUM_TEST_SSH_HOST`) passes: a synthetic
  remote store produces `AgentSnapshot.status == .working` on the first read and `.idle`
  on the second.
- [ ] The dogfood snippet produces the described sidebar transition within 10 seconds of
  a real Claude tool-call event appearing on the remote host.
- [ ] `swift build` passes with no new warnings. No existing tests are broken.

## Depends on / unblocks

This ticket depends on the session observer with budgets ticket being complete — the
`SessionObserver`, `TileObservation`, `applyDerivedStatus`, the budget counters, and the
`AgentStateReader` dispatch are all prerequisites that this ticket extends rather than
rebuilds. It also depends on the remote attach real path ticket being complete: the `Host`
model, the ssh flag assembly from `ssh -G`, and the `sshForward` path concept must exist
before this ticket can reference them.

The readers (Claude reader, Codex reader, Pi reader) must be present and conform to the
`AgentStateReader` protocol. This ticket introduces a `readFromBytes(_:...)` variant (or
equivalent) on each reader to accept raw `Data` rather than a local `URL` — a small
additive change to the reader protocol rather than a replacement of the existing interface.
If the reader tickets have already shipped `readFromBytes` as part of their API, this
ticket reuses it directly; if not, this ticket adds it as a targeted extension.

This ticket unblocks the ssh reconnect and backoff degradation ticket (which can now
degrade an already-observing remote tile) and, transitively, the Tailscale discovery
ticket (which adds new ssh-reachable peers that the observer will pick up automatically
once `Host` carries a Tailscale-resolved `100.x` address). The iOS observer ultimately
consumes `AgentDescriptor.status` values that this ticket populates for remote tiles.

## Watch out for

**The hardest thing to get right is the byte-offset tracking for the Claude JSONL tail.**
The JSONL is append-only and can grow to megabytes over a long session. Fetching the full
file on every 5-second poll is not acceptable; the tail approach is necessary. But `tail
-c N` on a remote file that has grown since the last poll may not align cleanly on a JSON
line boundary — the new bytes may begin mid-line. The reader must buffer the unparsed
remainder from the previous cycle and prepend it to the fresh tail bytes before parsing.
If the buffer grows unboundedly (because the remote file stopped appending new complete
lines), it must be capped and the reader must discard the partial prefix rather than
accumulating indefinitely. A concurrency bug here — where `remoteOffsets` is read and
written from both the poll timer queue and a cancellation path — is the second most likely
failure mode; all mutation of `remoteOffsets` must happen on the observer's serial queue
with no escape to the main actor.

**Never block the poll timer on a stalled ssh subprocess.** The `Process` API on macOS
does not enforce a timeout by itself. If the remote host stops responding without closing
the TCP connection — a common failure mode when a VPS is under load — the ssh subprocess
will hang until the `ServerAliveCountMax=3` keepalive fires (45 seconds at the default
`ServerAliveInterval=15`). The poll timer will queue up a new `serviceRemoteTile` Task
during that hang. Guard against this by cancelling any in-flight Task for a tile before
starting the next poll cycle, so at most one ssh subprocess per tile is outstanding at any
time. Track the in-flight Task in `TileObservation` and cancel it at the start of each
`serviceRemoteTile` invocation.

**The Codex remote linkage inherits the same collision risk as the local case.** On a
remote host, the observer cannot walk `~/.codex/sessions/` with FSEvents, so it must
issue `ssh <host> ls -t ~/.codex/sessions/<year>/<month>/<day>/` and scan by mtime to
find the correct rollout. If two Codex sessions share the same cwd on the remote host,
the same "show codex (running) without deep status" fallback applies — never guess which
rollout belongs to which tile. The mtime scan must compare the rollout's mtime against the
tile's `lastStartedAt` (captured at spawn) to prefer rollouts created after the pane
opened, exactly as the local Codex reader does.

**Auth must run on every path including loopback.** Per the settled architecture, the
bootstrap auth grant applies to `localhost` and `sshForward` identically — there is no
code path that skips authentication for a local host. The `RemoteStoreReader` closures are
assembled from the `Host` model regardless of whether the host alias resolves to a loopback
address; this is a design constraint, not a performance optimization target.
