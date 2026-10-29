import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
func runBrowserLeaseCheck() throws {
    guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
          Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw WorkspaceAPIChecks.Failure(message: "browser lease check requires isolated app support and a dev binary")
    }
    guard BrowserLeaseLedger.duration == 600 else {
        throw WorkspaceAPIChecks.Failure(message: "browser lease must last ten minutes")
    }
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    let spawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
    guard let controller = f.runtime.controller(for: f.projectPb) else {
        throw WorkspaceAPIChecks.Failure(message: "missing owning project controller")
    }
    defer { controller.browserRuntimes.forEach { $0.terminate(policy: .force) } }
    func spawn(agent: Bool) throws -> WKWebViewBrowserRuntime {
        let result = agent
            ? spawner.spawnAgentBrowser(url: "about:blank", owner: f.agentId, anchorTileId: f.agentTileB, targetZoneId: f.zoneB)
            : spawner.spawnBrowser(url: "about:blank", beside: f.agentTileB, targetZoneId: f.zoneB)
        guard case let .spawned(browser) = result else { throw WorkspaceAPIChecks.Failure(message: "browser spawn failed: \(result)") }
        controller.browserRuntimes.append(browser)
        f.runtime.registerLiveBrowser(tileId: browser.tileId)
        return browser
    }
    let first = try spawn(agent: true)
    var currentTime = Date()
    var running = false
    var expiries: [(TimeInterval, @MainActor () -> Void)] = []
    let ledger = BrowserLeaseLedger(
        runtime: { [weak controller] id in controller?.browserRuntimes.first(where: { $0.tileId == id }) },
        isRunning: { _ in running }, now: { currentTime }, scheduleExpiry: { delay, callback in expiries.append((delay, callback)) })
    guard f.api.installBrowserLeaseLedger(ledger) else {
        throw WorkspaceAPIChecks.Failure(message: "could not attach lease protection to the mounted workspace")
    }
    guard ledger.touch(tileId: first.tileId, owner: f.agentId), first.automation.isEngaged else {
        throw WorkspaceAPIChecks.Failure(message: "agent action must engage its live browser")
    }
    for _ in 0..<6 { _ = try spawn(agent: false) }
    f.runtime.qaSetBrowserRuntimeMaxLive(6)
    f.runtime.enforceBrowserRuntimeBudget()
    guard controller.browserRuntimes.count == 6,
          controller.browserRuntimes.contains(where: { $0.id == first.id }),
          f.canvas.tileView(for: first.tileId) is BrowserTileNSView else {
        throw WorkspaceAPIChecks.Failure(message: "leased browser was evicted when the seventh browser opened")
    }
    guard expiries.count == 1 else { throw WorkspaceAPIChecks.Failure(message: "lease must schedule expiry") }
    let oldExpiry = expiries[0].1
    currentTime.addTimeInterval(BrowserLeaseLedger.duration / 2)
    guard ledger.touch(tileId: first.tileId, owner: f.agentId), expiries.count == 1 else {
        throw WorkspaceAPIChecks.Failure(message: "renewing a lease must not schedule a second timer")
    }
    currentTime.addTimeInterval(BrowserLeaseLedger.duration / 2 + 1)
    oldExpiry()
    guard ledger.protectedTileIds().contains(first.tileId), first.automation.isEngaged else {
        throw WorkspaceAPIChecks.Failure(message: "old expiry must not end a renewed lease")
    }
    guard expiries.count == 2 && abs(expiries[1].0 - (BrowserLeaseLedger.duration / 2 - 1)) < 0.01 else {
        throw WorkspaceAPIChecks.Failure(message: "renewed lease must schedule its remaining duration")
    }
    currentTime.addTimeInterval(BrowserLeaseLedger.duration / 2)
    running = true
    expiries[1].1()
    guard ledger.protectedTileIds().contains(first.tileId), first.automation.isEngaged else {
        throw WorkspaceAPIChecks.Failure(message: "mid-turn lease must outlive idle expiration")
    }
    running = false
    ledger.agentStatusChanged(f.agentId)
    guard !ledger.protectedTileIds().contains(first.tileId), !first.automation.isEngaged else {
        throw WorkspaceAPIChecks.Failure(message: "expired idle lease must release engagement")
    }
    guard ledger.touch(tileId: first.tileId, owner: f.agentId), first.automation.isEngaged else {
        throw WorkspaceAPIChecks.Failure(message: "a fresh action must renew the lease")
    }
    guard !ledger.touch(tileId: first.tileId, owner: AgentID(rawValue: UUID())) else {
        throw WorkspaceAPIChecks.Failure(message: "another agent must not take an existing lease")
    }
    ledger.release(tileId: first.tileId)
    guard !first.automation.isEngaged && !ledger.protectedTileIds().contains(first.tileId) else {
        throw WorkspaceAPIChecks.Failure(message: "release must clear engagement and budget protection")
    }
    running = true
    guard ledger.track(tileId: first.tileId, owner: f.agentId), first.automation.isEngaged,
          ledger.protectedTileIds().contains(first.tileId) else {
        throw WorkspaceAPIChecks.Failure(message: "a hydrated browser of a running agent must hold a lease")
    }
    running = false
    ledger.agentStatusChanged(f.agentId)
    guard !first.automation.isEngaged && !ledger.protectedTileIds().contains(first.tileId) else {
        throw WorkspaceAPIChecks.Failure(message: "an idle browser with no action must release its lease")
    }
    // Drive the supervisor's production event fan-out, rather than only
    // calling the ledger's reconciliation method from the check.
    let supervisor = f.delegate.qaAgentSupervisor
    supervisor.qaDeliver(.turnStarted(threadId: "lease-thread", turnId: "lease-turn"), to: f.agentId)
    guard first.automation.isEngaged && ledger.protectedTileIds().contains(first.tileId) else {
        throw WorkspaceAPIChecks.Failure(message: "agent turn start must engage a tracked owned browser")
    }
    supervisor.qaDeliver(.turnCompleted(threadId: "lease-thread", turnId: "lease-turn", outcome: .completed, errorMessage: nil), to: f.agentId)
    guard !first.automation.isEngaged && !ledger.protectedTileIds().contains(first.tileId) else {
        throw WorkspaceAPIChecks.Failure(message: "agent turn end must release an idle tracked browser")
    }
    first.terminate(policy: .force)
    guard !ledger.touch(tileId: first.tileId, owner: f.agentId), !ledger.protectedTileIds().contains(first.tileId) else {
        throw WorkspaceAPIChecks.Failure(message: "dead browser cannot be leased")
    }
    try runBrowserZoomPerformanceCheck()
    try runBrowserControlPresentationCheck()
    try runBrowserIdleSweepCheck()
    try runRunningBrowserZonePinCheck()
    try runHydratedOwnedBrowserLeaseCheck()
    try runOwnedBrowserRestoreGateCheck()
    print("Browser lease: seventh-browser budget, scheduled expiry, running owner, renewal, hydration, owner conflict, dead browser and release passed")
}

/// A real controller dehydration/rehydration through the production mount must
/// restore lease protection before the browser budget is enforced.
@MainActor
private func runHydratedOwnedBrowserLeaseCheck() throws {
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    let spawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
    guard let controller = f.runtime.controller(for: f.projectPb), controller.hydrationTier == .live,
          case let .spawned(browser) = spawner.spawnAgentBrowser(url: "about:blank", owner: f.agentId,
              anchorTileId: f.agentTileB, targetZoneId: f.zoneB) else {
        throw WorkspaceAPIChecks.Failure(message: "could not prepare an owned browser for hydration")
    }
    controller.browserRuntimes.append(browser)
    defer { controller.browserRuntimes.forEach { $0.terminate(policy: .force) } }
    let ledger = BrowserLeaseLedger(runtime: { [weak controller] id in
        controller?.browserRuntimes.first(where: { $0.tileId == id && !$0.isTerminated })
    }, isRunning: { _ in true })
    guard f.api.installBrowserLeaseLedger(ledger) else { throw WorkspaceAPIChecks.Failure(message: "could not attach hydration lease") }
    try controller.setTier(.snapshot, allowDehydratingFocusedZone: true)
    try controller.setTier(.live)
    guard let restored = controller.browserRuntimes.first(where: { $0.tileId == browser.tileId }),
          restored.id != browser.id, restored.automation.isEngaged, ledger.protectedTileIds().contains(browser.tileId) else {
        throw WorkspaceAPIChecks.Failure(message: "production hydration must restore a running owner's browser lease")
    }
}

/// A tracked browser's automatic zone must stay live during its owner's turn
/// even after the camera leaves; the persisted zone policy stays automatic.
@MainActor
private func runRunningBrowserZonePinCheck() throws {
    typealias Fixture = WorkspaceInvariantsFixture
    let fixture = try Fixture(label: "browser-lease-zone")
    defer { fixture.dispose() }
    try fixture.mount()
    let mounted = try fixture.requireMounted("browser lease zone")
    guard let root = fixture.projectRoots[Fixture.projectA2],
          mounted.runtime.document.zones.first(where: { $0.zoneId == Fixture.zoneA2 })?.hydrationPolicy == .automatic else {
        throw WorkspaceAPIChecks.Failure(message: "lease zone fixture must start automatic")
    }
    let supervisor = mounted.delegate.qaAgentSupervisor
    let owner = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .pi,
        model: "openai-codex/gpt-5.6-sol", thinking: "high", projectId: Fixture.projectA2,
        projectRoot: root, tileId: Fixture.noteA2a)
    let spawner = try mounted.runtime.ensureSpawner(forProjectId: Fixture.projectA2)
    guard let controller = mounted.runtime.controller(for: Fixture.projectA2),
          case let .spawned(browser) = spawner.spawnAgentBrowser(url: "about:blank", owner: owner,
              anchorTileId: Fixture.noteA2a, targetZoneId: Fixture.zoneA2) else {
        throw WorkspaceAPIChecks.Failure(message: "could not open owned browser in automatic zone")
    }
    controller.browserRuntimes.append(browser)
    mounted.runtime.registerLiveBrowser(tileId: browser.tileId)
    let ledger = BrowserLeaseLedger(
        runtime: { [weak runtime = mounted.runtime] id in runtime?.liveControllers.flatMap(\.browserRuntimes).first(where: { $0.tileId == id }) },
        isRunning: { [weak supervisor] id in supervisor?.isRunning(id) ?? false })
    guard mounted.delegate.qaWorkspaceAPI.installBrowserLeaseLedger(ledger),
          ledger.track(tileId: browser.tileId, owner: owner) else {
        throw WorkspaceAPIChecks.Failure(message: "could not track browser in zone fixture")
    }
    // A turn event must re-plan without treating an earlier programmatic camera
    // change as a user pan and arming the zone beneath it.
    let armedBeforeEvent = mounted.canvas.armedZoneId
    guard let otherZone = mounted.canvas.renderedZonesInZOrder.first(where: { $0.projectId != nil && $0.zoneId != armedBeforeEvent }) else {
        throw WorkspaceAPIChecks.Failure(message: "expected a second zone for the camera preservation check")
    }
    let viewportSize = mounted.canvas.bounds.size
    mounted.canvas.setViewport(CanvasViewport(x: otherZone.origin.x + otherZone.size.width / 2 - viewportSize.width / 2,
                                             y: otherZone.origin.y + otherZone.size.height / 2 - viewportSize.height / 2, zoom: 1))
    guard CanvasEngine.cameraArmedZone(zones: mounted.canvas.renderedZonesInZOrder, viewport: mounted.canvas.viewport,
                                       visibleSize: viewportSize) == otherZone.zoneId else {
        throw WorkspaceAPIChecks.Failure(message: "camera fixture must point at another zone")
    }
    let reconcilesBeforeEvent = mounted.runtime.reconcileCount
    supervisor.qaDeliver(.turnStarted(threadId: "zone-lease", turnId: "turn"), to: owner)
    let deadline = Date().addingTimeInterval(0.15)
    while mounted.runtime.reconcileCount == reconcilesBeforeEvent && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    guard mounted.runtime.reconcileCount > reconcilesBeforeEvent, mounted.canvas.armedZoneId == armedBeforeEvent else {
        throw WorkspaceAPIChecks.Failure(message: "turn-event hydration must not arm the zone under the camera")
    }
    guard ledger.protectedTileIds().contains(browser.tileId) else {
        throw WorkspaceAPIChecks.Failure(message: "turn start must lease the owned browser")
    }
    let beforeGeneration = mounted.runtime.interactionGeneration
    mounted.canvas.setViewport(CanvasViewport(x: -10000, y: -10000, zoom: 1))
    mounted.runtime.flushPendingHydrationReconcile()
    guard mounted.canvas.installedZonePlacement(for: Fixture.zoneA2) != nil,
          controller.browserRuntimes.contains(where: { $0.id == browser.id }), !browser.isTerminated else {
        throw WorkspaceAPIChecks.Failure(message: "a running agent browser's automatic zone must remain live off-camera")
    }
    guard mounted.runtime.document.zones.first(where: { $0.zoneId == Fixture.zoneA2 })?.hydrationPolicy == .automatic,
          mounted.runtime.interactionGeneration == beforeGeneration else {
        throw WorkspaceAPIChecks.Failure(message: "transient lease pin must not persist or register as user interaction")
    }
    supervisor.qaDeliver(.turnCompleted(threadId: "zone-lease", turnId: "turn", outcome: .completed, errorMessage: nil), to: owner)
    mounted.runtime.flushPendingHydrationReconcile()
    guard ledger.runningTileIds().isEmpty else {
        throw WorkspaceAPIChecks.Failure(message: "turn completion must remove the transient running-zone pin")
    }
}

@MainActor
private func runBrowserIdleSweepCheck() throws {
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    let spawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
    guard let controller = f.runtime.controller(for: f.projectPb),
          case let .spawned(browser) = spawner.spawnAgentBrowser(url: "about:blank", owner: f.agentId,
              anchorTileId: f.agentTileB, targetZoneId: f.zoneB) else {
        throw WorkspaceAPIChecks.Failure(message: "could not open browser for idle sweep")
    }
    controller.browserRuntimes.append(browser)
    f.runtime.registerLiveBrowser(tileId: browser.tileId)
    defer { controller.browserRuntimes.forEach { $0.terminate(policy: .force) } }
    guard case let .spawned(userBrowser) = spawner.spawnBrowser(url: "about:blank", beside: f.agentTileB, targetZoneId: f.zoneB) else {
        throw WorkspaceAPIChecks.Failure(message: "could not open user browser for sweep guard")
    }
    controller.browserRuntimes.append(userBrowser)
    guard f.api.browserIdleClose?(userBrowser.tileId, f.agentId) == false,
          f.canvas.tileRecord(for: userBrowser.tileId) != nil else {
        throw WorkspaceAPIChecks.Failure(message: "idle sweep must never remove a user-owned browser")
    }
    _ = f.focusBroker.requestFocus(.tile(browser.tileId), reason: .userClick)
    guard f.focusBroker.activeSurface == .tile(browser.tileId),
          f.api.browserIdleClose?(browser.tileId, f.agentId) == false,
          f.canvas.tileRecord(for: browser.tileId) != nil else {
        throw WorkspaceAPIChecks.Failure(message: "idle sweep must preserve a focused browser")
    }
    _ = f.focusBroker.requestFocus(.canvas, reason: .userClick)
    var time = Date()
    var running = false
    var timers: [(TimeInterval, @MainActor () -> Void)] = []
    let ledger = BrowserLeaseLedger(runtime: { [weak controller] id in
        controller?.browserRuntimes.first(where: { $0.tileId == id && !$0.isTerminated })
    }, isRunning: { _ in running }, now: { time }, scheduleSweep: { delay, callback in
        timers.append((delay, callback))
    }, closeIdle: { id, owner in f.api.browserIdleClose?(id, owner) ?? false })
    guard f.api.installBrowserLeaseLedger(ledger),
          ledger.touch(tileId: browser.tileId, owner: f.agentId, sweepEligible: true), timers.count == 1 else {
        throw WorkspaceAPIChecks.Failure(message: "owned browser must start its idle sweep timer")
    }
    time.addTimeInterval(900)
    _ = ledger.touch(tileId: browser.tileId, owner: f.agentId, sweepEligible: true)
    guard timers.count == 1 else { throw WorkspaceAPIChecks.Failure(message: "idle timer must coalesce on renewal") }
    time.addTimeInterval(900)
    timers[0].1()
    guard f.canvas.tileRecord(for: browser.tileId) != nil, timers.count == 2, abs(timers[1].0 - 900) < 0.01 else {
        throw WorkspaceAPIChecks.Failure(message: "recent action must defer the idle sweep")
    }
    time.addTimeInterval(900)
    running = true
    timers[1].1()
    guard f.canvas.tileRecord(for: browser.tileId) != nil else {
        throw WorkspaceAPIChecks.Failure(message: "idle sweep removed a running agent's browser")
    }
    running = false
    ledger.agentStatusChanged(f.agentId)
    guard timers.count == 3 else { throw WorkspaceAPIChecks.Failure(message: "turn completion must reschedule overdue sweep") }
    let viewport = f.canvas.viewport
    let armed = f.canvas.armedZoneId
    let focus = f.focusBroker.activeSurface
    let sibling = f.canvas.navigationTileSnapshot(for: f.agentTileB)?.worldFrame
    timers[2].1()
    guard f.canvas.tileRecord(for: browser.tileId) == nil,
          !(try f.storePb.loadCanvas()).tiles.contains(where: { $0.id == browser.tileId }),
          f.canvas.viewport == viewport, f.canvas.armedZoneId == armed,
          f.focusBroker.activeSurface == focus,
          f.canvas.navigationTileSnapshot(for: f.agentTileB)?.worldFrame == sibling else {
        throw WorkspaceAPIChecks.Failure(message: "idle sweep must persist removal without changing canvas, focus or sibling geometry")
    }
}

/// Rehydration must not load a stored forbidden URL before an agent gate exists.
@MainActor
private func runOwnedBrowserRestoreGateCheck() throws {
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    let spawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
    guard let controller = f.runtime.controller(for: f.projectPb),
          case let .spawned(browser) = spawner.spawnAgentBrowser(url: "about:blank", owner: f.agentId,
              anchorTileId: f.agentTileB, targetZoneId: f.zoneB) else {
        throw WorkspaceAPIChecks.Failure(message: "could not prepare restore policy fixture")
    }
    controller.browserRuntimes.append(browser)
    defer { controller.browserRuntimes.forEach { $0.terminate(policy: .force) } }
    try controller.setTier(.snapshot, allowDehydratingFocusedZone: true)
    var state = try controller.projectStore.loadBrowserState()
    guard let index = state.tiles.firstIndex(where: { $0.tileId == browser.tileId }) else {
        throw WorkspaceAPIChecks.Failure(message: "missing persisted browser")
    }
    state.tiles[index].url = "data:text/html,<title>ForbiddenRestore</title>"
    state.tiles[index].interactionState = nil
    guard let active = state.tiles[index].tabs.firstIndex(where: { $0.id == state.tiles[index].activeTabId }) else {
        throw WorkspaceAPIChecks.Failure(message: "missing active persisted browser tab")
    }
    state.tiles[index].tabs[active].url = state.tiles[index].url
    state.tiles[index].tabs[active].interactionState = nil
    try controller.projectStore.saveBrowserState(state)
    try controller.setTier(.live)
    guard let restored = controller.browserRuntimes.first(where: { $0.tileId == browser.tileId }) else {
        throw WorkspaceAPIChecks.Failure(message: "restore did not create a browser")
    }
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard restored.webView.url?.scheme != "data", restored.webView.title != "ForbiddenRestore" else {
        throw WorkspaceAPIChecks.Failure(message: "owned browser restored a forbidden URL before its domain gate")
    }
}

@MainActor
private func runBrowserControlPresentationCheck() throws {
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    let spawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
    guard let controller = f.runtime.controller(for: f.projectPb),
          case let .spawned(browser) = spawner.spawnAgentBrowser(url: "about:blank", owner: f.agentId,
              anchorTileId: f.agentTileB, targetZoneId: f.zoneB),
          let view = f.canvas.tileView(for: browser.tileId) as? BrowserTileNSView else {
        throw WorkspaceAPIChecks.Failure(message: "could not prepare browser control fixture")
    }
    controller.browserRuntimes.append(browser)
    f.runtime.registerLiveBrowser(tileId: browser.tileId)
    defer { controller.browserRuntimes.forEach { $0.terminate(policy: .force) } }
    let ledger = BrowserLeaseLedger(runtime: { [weak controller] id in
        controller?.browserRuntimes.first(where: { $0.tileId == id && !$0.isTerminated })
    }, isRunning: { _ in false })
    guard f.api.installBrowserLeaseLedger(ledger), ledger.touch(tileId: browser.tileId, owner: f.agentId, sweepEligible: true),
          browser.automation.isEngaged, view.agentControlTitleForQA?.hasPrefix("Driven by ") == true else {
        throw WorkspaceAPIChecks.Failure(message: "a lease must show its agent in the real browser header")
    }
    browser.agentNavigationDecision = { _, reply in reply(true) }
    view.qaChooseAgentControl("take")
    guard !browser.automation.isEngaged, browser.agentNavigationDecision == nil,
          f.api.browserUserTakenOver.contains(browser.tileId), view.agentControlTitleForQA == "You’re driving" else {
        throw WorkspaceAPIChecks.Failure(message: "Take control must release the lease, remove its gate and update the header")
    }
    guard ledger.touch(tileId: browser.tileId, owner: f.agentId, sweepEligible: true),
          view.agentControlTitleForQA?.hasPrefix("Driven by ") == true else {
        throw WorkspaceAPIChecks.Failure(message: "a renewed lease must update the visible browser driver")
    }
}

/// Measure the real canvas zoom cascade with 1, 3 and 6 live WebKit views.
@MainActor
private func runBrowserZoomPerformanceCheck() throws {
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    let spawner = try f.runtime.ensureSpawner(forProjectId: f.projectPb)
    guard let controller = f.runtime.controller(for: f.projectPb) else {
        throw WorkspaceAPIChecks.Failure(message: "browser zoom fixture has no controller")
    }
    defer { controller.browserRuntimes.forEach { $0.terminate(policy: .force) } }
    let window = NSWindow(contentRect: f.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = f.canvas
    window.orderFrontOffscreenForChecks()
    defer { window.close() }
    f.runtime.qaSetBrowserRuntimeMaxLive(6)
    var measurements: [String] = []
    for count in [1, 3, 6] {
        while controller.browserRuntimes.count < count {
            guard case let .spawned(browser) = spawner.spawnAgentBrowser(url: "about:blank", owner: f.agentId,
                    anchorTileId: f.agentTileB, targetZoneId: f.zoneB) else {
                throw WorkspaceAPIChecks.Failure(message: "browser zoom fixture could not spawn \(count) browsers")
            }
            controller.browserRuntimes.append(browser)
            f.runtime.registerLiveBrowser(tileId: browser.tileId)
        }
        f.canvas.layoutSubtreeIfNeeded()
        guard controller.browserRuntimes.count == count,
              controller.browserRuntimes.allSatisfy({ !$0.isTerminated && f.canvas.tileView(for: $0.tileId) is BrowserTileNSView }) else {
            throw WorkspaceAPIChecks.Failure(message: "zoom measurement must have \(count) live mounted browsers")
        }
        var samples: [Double] = []
        for iteration in 0..<35 {
            let started = DispatchTime.now().uptimeNanoseconds
            f.canvas.setViewport(CanvasViewport(x: Double(iteration % 3) * 10, y: Double(iteration % 5) * 10,
                                                zoom: iteration.isMultiple(of: 2) ? 0.8 : 1.2))
            f.canvas.layoutSubtreeIfNeeded()
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if iteration >= 5 { samples.append(milliseconds) }
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        guard samples.count == 30, p95.isFinite else {
            throw WorkspaceAPIChecks.Failure(message: "browser zoom measurement produced invalid samples")
        }
        measurements.append("\(count) live: p95 \(String(format: "%.2f", p95)) ms")
    }
    print("Browser zoom cascade (30 samples each): " + measurements.joined(separator: "; "))
}
