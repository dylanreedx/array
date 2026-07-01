# FSEvents push watch for agent stores

## What this delivers

The `SessionObserver` (built in the preceding ticket) drives the agent readers on a timer by default — it polls. This ticket converts that polling into an event-driven push model using macOS FSEvents for every locally-watched agent store: Claude's session JSONL, Pi's `run.json`/`events.jsonl`/`status.json`, and Codex's matched rollout file. When a store file changes on disk, FSEvents fires an event, the observer debounces it at 250 ms per file (the budget locked in D13), and a read is dispatched immediately — no 250 ms tick-wait. Polling is not removed; it becomes the explicit fallback for remote stores and any edge case where a watch cannot be established. The outcome is that local agent status updates are instantaneous from the human perspective (a Claude turn ending shows `idle` within a quarter second of the file landing), while CPU and I/O cost stay bounded by the same budget/debounce logic the observer already enforces.

## How it fits

This ticket builds directly on the `SessionObserver` with budgets (the preceding work in the agent-awareness base phase). That observer already holds the per-tile reader registry, the `deriveAgentStatus` function, and the budget counters. This ticket adds one thing: instead of the observer's poll timer being the only thing that triggers a read, an `AgentStoreWatcher` fires an `.explicit` signal into the same path the timer already uses. The watcher reuses the discipline already proven in `RunArtifactsWatcher` — debounce, rate cap, a private serial queue — so the pattern is not invented; it is applied to a wider set of store paths.

This work unblocks the Claude notification hook and consent ticket (the next supervised item): that ticket writes a hook breadcrumb file, and the breadcrumb is only useful if the observer can respond to it within a perceptible latency window. It also makes the "replace the mock rollup" ticket meaningful to dogfood — a rollup that updates within a second of a real event feels live; one that updates on a 5-second timer does not.

## The approach

For each tile whose observer is active and whose agent store is local (not over SSH), the observer registers a file-level FSEvents watch via `DispatchSource.makeFileSystemObjectSource` on every store file it has successfully located. The watcher is created on a private serial queue shared with the observer's existing work, keeping all signalling single-threaded. When the source fires, the handler records the tile as dirty, resets the debounce window, and schedules a read after 250 ms — exactly the same dirty-set / debounce-window / read-cap logic `RunArtifactsWatcher` uses for its poll-detected dirtiness.

The observer's existing poll timer is kept and continues to run at its configured interval, but its effective job narrows: it catches any store that did not get a watcher (file did not exist at start, watch source failed to arm) and catches remote stores unconditionally. This means the fallback is structural rather than conditional — the poll loop is always live, so no `if remote { poll } else { watch }` branch needs to be maintained.

When a tile's store URL changes (a Pi runId advances to a new run directory, or a Claude session rotates its JSONL) the observer cancels the old watch sources and arms new ones. This lifecycle is tied to the existing path where the observer re-locates a store after a reader returns `nil`.

Watch sources are cancelled and `nil`-ed when the tile is removed from the observer, or when the observer itself stops.

## Where it lives

**`Sources/ContinuumRevivedCore/AgentStatusEngine.swift`** — `AgentStatusEngine` (`line 3`) is the pure derivation type the observer calls. This ticket does not modify it; it is listed as a primary seam because the watcher's output feeds the engine through the same `.explicit(AgentStatus)` signal path already used by the poll loop.

**`Sources/ContinuumRevived/Canvas/RunArtifactsTileNSView.swift`** — `RunArtifactsTileNSView` (`line 7`) calls `RunArtifactsReader.read(runDirectory:)` synchronously on load (`line 63`). This tile currently has no live-update path. As part of this ticket, the view subscribes to the observer's output for its tile id and calls `loadRunArtifacts()` again when a status change arrives — giving the run-artifacts tile live refresh without a new watcher.

**`Sources/ContinuumRevivedCore/RunArtifactsWatcher.swift`** — `RunArtifactsWatcher` (`line 25`). The debounce/rate-cap discipline here (`lines 91–122`) is the exact pattern to replicate. The new `AgentStoreWatcher` is not a subclass or extension; it is a separate type modelled on this one, operating on a flat list of file URLs rather than a directory tree.

**New file: `Sources/ContinuumRevivedCore/AgentStoreWatcher.swift`** — The new watcher type. Holds a `[URL: DispatchSourceFileSystemObject]` keyed by watched file URL, a dirty set, a debounce timestamp, and the budget counters transcribed from `RunArtifactsWatcherConfig`. Public API: `init(config:queue:)`, `watch(url:tileId:onChange:)`, `unwatch(url:)`, `unwatchAll(for:)`, `stop()`.

**`SessionObserver` (to be created in the preceding ticket, in `Sources/ContinuumRevivedCore/`)** — This ticket adds `AgentStoreWatcher` as a stored property, wires it in `start()`, and routes its `onChange` callback into the same read path the poll timer uses.

## Implementation breadcrumbs

```swift
// AgentStoreWatcher.swift — the core type
final class AgentStoreWatcher: @unchecked Sendable {
    struct Config: Equatable, Sendable {
        var debounceInterval: TimeInterval = 0.25  // D13 default — owner may override
        var maxReadsPerSecond: Int = 10            // D13: 10 status-changes/min/tile ≈ 10/60s
    }
    typealias ChangeHandler = @Sendable (_ tileId: TileID, _ changedURL: URL) -> Void

    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var tileByURL: [URL: TileID] = [:]
    private var dirtyTiles: Set<TileID> = []
    private var firstDirtyAt: [TileID: Date] = [:]
    private let queue: DispatchQueue  // same queue as SessionObserver's work queue
    private let config: Config

    func watch(url: URL, tileId: TileID, onChange: @escaping ChangeHandler) {
        // open O_EVTONLY — read-only, does not prevent unmount
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }  // file doesn't exist yet → poll fallback covers it
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.fileDidChange(url: url, tileId: tileId, onChange: onChange)
        }
        source.setCancelHandler { close(fd) }
        sources[url] = source
        tileByURL[url] = tileId
        source.resume()
    }

    private func fileDidChange(url: URL, tileId: TileID, onChange: ChangeHandler) {
        // called on the shared queue — no lock needed
        dirtyTiles.insert(tileId)
        if firstDirtyAt[tileId] == nil { firstDirtyAt[tileId] = Date() }
        // debounce: schedule a one-shot dispatch after debounceInterval
        queue.asyncAfter(deadline: .now() + config.debounceInterval) { [weak self] in
            self?.flush(tileId: tileId, changedURL: url, onChange: onChange)
        }
    }

    private func flush(tileId: TileID, changedURL: URL, onChange: ChangeHandler) {
        guard dirtyTiles.contains(tileId) else { return }  // already handled by a later flush
        dirtyTiles.remove(tileId)
        firstDirtyAt[tileId] = nil
        onChange(tileId, changedURL)
    }

    func unwatch(url: URL) {
        sources[url]?.cancel()
        sources[url] = nil
        tileByURL[url] = nil
    }

    func unwatchAll(for tileId: TileID) {
        for (url, tile) in tileByURL where tile == tileId {
            unwatch(url: url)
        }
    }
}
```

```swift
// Inside SessionObserver — wiring the watcher
// (in start(), after readers are located for each tile)
func armWatchers(for tileId: TileID, storeURLs: [URL]) {
    storeWatcher.unwatchAll(for: tileId)  // cancel stale watches first
    for url in storeURLs where isLocal(url) {
        storeWatcher.watch(url: url, tileId: tileId) { [weak self] id, _ in
            // This closure is called on the shared queue, already debounced
            self?.readAndUpdate(tileId: id, reason: .fsevent)
        }
    }
}

// readAndUpdate is the same method the poll timer calls — no duplication of read logic
private func readAndUpdate(tileId: TileID, reason: ReadReason) {
    guard canRead(tileId: tileId) else { return }  // budget check: 10 status-changes/min/tile
    let snapshot = reader(for: tileId)?.read(locatedStore(for: tileId))
    let newStatus = deriveAgentStatus(snapshot: snapshot, engine: &engines[tileId]!)
    publish(tileId: tileId, status: newStatus)
}
```

```swift
// RunArtifactsTileNSView — wiring the live refresh
// Add in the view's setup path, after super.init:
observer.subscribe(tileId: tile.id) { [weak self] _ in
    DispatchQueue.main.async { self?.loadRunArtifacts() }
}
// Cancel subscription in deinit / removeFromCanvas
```

The `isLocal(url:)` check is a one-liner: the URL's host is nil or `localhost`, not an `ssh://` scheme — remote stores skip `watch()` entirely and rely on the poll timer's 5-second remote budget from D13.

## How we test it

### Logic (pure Core checks)

Write a `AgentStoreWatcherTests` suite in `ContinuumRevivedCoreTests`. Use a temp directory and real files — no mocking of `DispatchSource` itself, since the FSEvents integration is the whole point, but keep it on a fast path:

- **Debounce correctness.** Write to a temp file rapidly (10 writes in 50 ms). Assert `onChange` fires exactly once, after the 250 ms debounce window, not ten times. Use `XCTestExpectation(expectedFulfillmentCount: 1)` with `isInverted: false` and a 600 ms timeout.
- **Multi-file, single tile.** Arm two URLs for the same `tileId` (simulating Claude's pid-file + JSONL pair). Write to each. Assert `onChange` fires for the correct `tileId` each time, and that rapid writes to both collapse to one callback per debounce window.
- **Unwatch stops delivery.** Call `unwatch(url:)`, then write to the file. Assert no callback within 400 ms (inverted expectation).
- **Missing file at arm time.** Pass a URL for a file that does not exist. Assert `watch()` returns without crashing. Assert the poll fallback still fires (by verifying the observer's poll-driven update is not suppressed).
- **Rate-cap enforcement.** Arm a watcher and fire 15 change events within one second. Assert `readAndUpdate` is called no more than 10 times (the D13 cap). Measure with a counter in the `onChange` closure.

### Backend (real-path / integration)

These run against real on-disk stores under `Tests/Fixtures/agent-readers/`. No fake executor, no bypassed path — the real `AgentStoreWatcher` and the real `SessionObserver` are exercised together.

- **Claude JSONL append triggers refresh.** Use the `claude-working` fixture directory. Arm the observer + watcher for the fixture tile. Append a synthetic `{"type":"assistant","message":{"stop_reason":"end_turn"}}` line to the JSONL fixture. Assert `AgentDescriptor.status` transitions to `.idle` within 500 ms, driven by the FSEvents path (confirm by checking that no poll tick fired in that window — use a fake clock with no ticks scheduled).
- **Pi `run.json` write triggers refresh.** Use the `pi-working` fixture. Overwrite `run.json.status` to `done`. Assert status becomes `.done` within 500 ms.
- **Store URL rotation.** Simulate a Pi session advancing (rename the run directory, write a new `runId`). Assert the observer cancels the old watcher, arms the new one, and delivers the updated status from the new store within 1 s.
- **Remote path skips watcher.** Configure the observer with a remote `Host`. Assert no `DispatchSource` is created (verify `sources.count == 0`). Assert the poll timer drives the update instead.
- **I6 soundness on push path.** The status emitted via the FSEvents path must pass the same I6 check as the poll path: assert that for every fixture scenario, the emitted `AgentSnapshot.evidence.source` is non-empty and `status == .working` is only emitted when `evidence.mtimeAgeSeconds` is below `freshWorkingWindow`.

### UX (visual gate + dogfood snippet)

This ticket ships no new visual element — the watcher is infrastructure. The visual gate is therefore a live timing check in the Component Lab, not a new component screenshot.

**Visual gate:** In the Component Lab, add a "Observer Latency" fixture: a tile wired to the observer with a temp-directory Claude fixture. The fixture panel shows `AgentDescriptor.status` as a live label (already available in the Lab's tile inspector). A "Simulate Turn End" button appends a synthetic `end_turn` event to the fixture JSONL. The gate passes when the label transitions from `working` to `idle` within one second of the button press, without any manual tick. This is a non-degenerate gate — a mere `bytes > 0` assertion would not catch a watcher that never fires.

**Dogfood snippet:** Open Continuum with a project that has an active Claude Code tile. Make the left dock visible (toggle with the dock keybind). Confirm the tile shows `working` (blue pulse) while Claude is mid-turn. When Claude's turn completes, watch the dock row — within one second of the JSONL file updating, the status badge should flip to `idle` (ring icon, no fill). If it takes more than two seconds, the FSEvents path is not firing and the poll fallback is driving updates instead. Open Activity Monitor and confirm `continuum` CPU is below 1% while idle — the debounce is working.

## Execution mode

Autonomous. The watcher logic, the debounce correctness check, and the real-path integration tests (using fixture files under `Tests/Fixtures/`) are all provable with no human eyes and no real cloud, device, or live agent process. The Component Lab visual gate is a real-path check on a real event path with a non-degenerate outcome assertion; it is automated and does not require a human to judge pass/fail — the label transition either happens within 1 s or it does not. The dogfood snippet above is provided for the human-verification pass that happens after the matrix is green, consistent with the verification doctrine that the matrix is necessary but not sufficient for UI-adjacent work.

## Done when

- [ ] `AgentStoreWatcher` exists in `Sources/ContinuumRevivedCore/AgentStoreWatcher.swift`, compiles cleanly, and passes the Logic suite (debounce, multi-file, unwatch, missing-file, rate-cap).
- [ ] `SessionObserver.armWatchers(for:storeURLs:)` is called after every successful `locate()` call, arming FSEvents sources for all local store URLs returned by the reader.
- [ ] The poll timer is kept active; `isLocal()` determines whether a given URL gets a watch source — remote URLs are never passed to `watch()`.
- [ ] `RunArtifactsTileNSView` subscribes to the observer and calls `loadRunArtifacts()` on status change.
- [ ] Backend/integration suite passes: JSONL-append drives a `.idle` transition within 500 ms; Pi `run.json` write drives `.done` within 500 ms; store URL rotation cancels old watches and arms new ones.
- [ ] Remote-path check passes: no `DispatchSource` is created for a remote `Host`; poll timer drives the update.
- [ ] I6 soundness: no `working` status is emitted on a stale fixture (mtime beyond `freshWorkingWindow`), on either the FSEvents or poll path.
- [ ] Component Lab "Observer Latency" fixture is present and the status label transitions within 1 s of the "Simulate Turn End" button press.
- [ ] CPU while idle (no active agents, no file changes) is below 1% in a real run, confirmed by Activity Monitor during the dogfood pass.
- [ ] `AgentStoreWatcher` passes the rate-cap test: ≤ 10 `onChange` callbacks per second per tile under rapid file writes.

## Depends on / unblocks

This ticket depends entirely on the `SessionObserver` with budgets being in place. The observer is the host: it owns the reader registry, the `AgentStatusEngine` instances per tile, the budget counters, and the publish path. Without it there is no home for `AgentStoreWatcher` and no `readAndUpdate` method to route events into. The existing `RunArtifactsWatcher` and its established debounce/rate-cap discipline are the direct pattern template, so that code should be read carefully before implementing `AgentStoreWatcher`.

This ticket unblocks the Claude notification hook and consent ticket. The hook writes a small breadcrumb file; for `needsAttention` to feel instantaneous when that breadcrumb lands, the FSEvents watch must already be covering the hook's output path. It also makes the "replace the mock rollup" ticket feel live when dogfooded: a rollup driven by push responds to real events immediately, which is the experience that makes the fleet-view trustworthy.

## Watch out for

**The `O_EVTONLY` file descriptor is per-file, not per-directory.** The `DispatchSource.makeFileSystemObjectSource` API watches a single open file descriptor. If the agent writes to a new file (a new Claude session rotates its JSONL, or Pi starts a new run directory), the old `fd` goes stale and events stop. The watcher must be re-armed whenever the observer detects a new `locate()` result differing from the previous one. Missing this means the very first update after a session rotation is silent — the tile goes stale until the next poll tick. This is the single most likely source of a "it works on the first run but stops after a restart" bug.

**Cancelled sources must not fire after `stop()`.** `DispatchSource.cancel()` is asynchronous by default — the `setEventHandler` may fire once after `cancel()` is called. Nil-check `self` in every handler closure and verify the tile is still in the observer's active set before dispatching `readAndUpdate`. Skipping this causes a use-after-free-equivalent: `readAndUpdate` runs on a tile that has been removed and whose `AgentStatusEngine` has been deallocated.

**Do not open a file descriptor for a file that does not yet exist.** When the observer's `locate()` returns `nil` (the agent has not written its store yet), `watch(url:)` must simply return without calling `open()`. The poll fallback covers this window. Attempting to open and watch a non-existent path causes `open()` to return `-1`, which `DispatchSource.makeFileSystemObjectSource` will assert on in debug builds.

**Rate-cap semantics differ between the FSEvents path and the poll path.** The poll timer fires at most once per `pollInterval` by construction. The FSEvents path can fire many times per second if a file is written frequently. The per-tile `maxReadsPerSecond` budget (10, per D13) must be enforced in `AgentStoreWatcher.flush()`, not assumed from the timer. The `readsInWindow` / `readWindowStartedAt` pattern from `RunArtifactsWatcher` (lines 107–109, 124–134) is the right model; replicate it rather than inventing a new rate-limiting strategy.

**The Component Lab fixture is the stop condition for the UX gate.** If the lab fixture is added but the label transition takes more than one second consistently, do not merge and call it "good enough." Either the FSEvents path is not wired into the observer's publish step, or the debounce is set too long. Debug by adding a `print` in `fileDidChange` and confirming it fires within milliseconds of the "Simulate Turn End" button press.
