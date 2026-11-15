import AppKit
import ContinuumRevivedCore
import Foundation

/// `--sidebar-row-reveal-check` — a plain click on an agent's sidebar row moves
/// the camera to that agent's tile and focuses it.
///
/// Reported live on 0.7.51: the row highlighted and the canvas stayed where it
/// was. Drives production only: `mountWorkspaceSceneAtBoot` (via
/// `WorkspaceAPIChecks.makeFixture`), the sidebar exactly as
/// `configureWorkspaceSidebar` wires it, and a real mouse click on the row
/// through `NSApp.sendEvent` in an offscreen window. Asserts the outcome — the
/// camera is the tile's reveal framing and the tile holds focus — never which
/// method ran.
///
/// Variants: a tile in the armed zone, a tile in another zone, after an app
/// switch away and back (the 0.7.51 activation path), and after agent events
/// have streamed (the in-place activity fold).
@MainActor
enum SidebarRowRevealChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "sidebar-row-reveal requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(
            harness: .pi, readiness: .ready, models: [WorkspaceAgentReportChecks.model],
            displayNames: [WorkspaceAgentReportChecks.model: "Fixture"],
            contextWindows: [WorkspaceAgentReportChecks.model: 200_000]))
        var report: [String] = []
        var failures: [String] = []
        // The default scope, then a multi-workspace include of both fixture
        // workspaces — the shape a person's persisted filter takes.
        // Last, the production shape: the sidebar and the canvas in ONE key
        // window, with the app's mouse-up tile-focus monitor installed.
        for (multi, shared) in [(false, false), (true, false), (false, true)] {
            let (lines, failed) = try scenario(multiWorkspaceScope: multi, sharedWindow: shared)
            let tag = shared ? "one window with the canvas" : multi ? "two-workspace scope" : "default scope"
            report += lines.map { "  [\(tag)]" + $0 }
            failures += failed.map { "[\(tag)] " + $0 }
        }
        guard failures.isEmpty else {
            throw Failure(description: "sidebar-row-reveal: \(failures.count) failing:\n  " + failures.joined(separator: "\n  "))
        }
        return report.joined(separator: "\n")
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        // The person's main window is key while they click its sidebar. A check
        // process is never the active app, so the window says so itself rather
        // than activating the app (which would take the screen); without this
        // every click is a first-mouse click AppKit swallows.
        override var isKeyWindow: Bool { true }
    }

    private static func scenario(multiWorkspaceScope: Bool, sharedWindow: Bool) throws -> (report: [String], failures: [String]) {
        guard let settings = QAIsolatedDefaults(isolatedSuiteName: "array.qa.sidebar-row-reveal.\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }

        let f = try WorkspaceAPIChecks.makeFixture(settings: settings)
        defer { f.tearDown() }
        if multiWorkspaceScope {
            settings.set("workspaces:include:\(f.workspaceWA.uuidString.lowercased()),\(f.workspaceWB.uuidString.lowercased())",
                         forKey: "continuum.workspaceSidebar.scope")
        }
        let delegate = f.delegate
        let supervisor = delegate.qaAgentSupervisor
        f.canvas.navigationFlightOverrideForQA = false

        // A second agent whose tile sits in the ARMED zone (zoneA); the fixture's
        // own agent sits in zoneB, which is live but not armed.
        guard let armedTile = f.canvas.tilesInWorldFrames(forZoneId: f.zoneA)?.first?.id else {
            throw Failure(description: "precondition: zoneA has no tile")
        }
        let armedAgent = supervisor.spawn(
            role: nil, prompt: nil, cwd: f.paRoot, harness: .pi,
            model: WorkspaceAgentReportChecks.model, thinking: "high",
            projectId: f.projectPa, projectRoot: f.paRoot, tileId: armedTile)
        _ = supervisor.rename(agentID: armedAgent, to: "Armed zone agent")
        _ = supervisor.rename(agentID: f.agentId, to: "Other zone agent")

        try delegate.reconciledManagedSessionSource.reconcile(
            registry: delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: WorkspaceSidebarConfig.defaultWidth, height: 900))
        delegate.qaInstallWorkspaceSidebar(sidebar)
        let canvasSize = NSSize(width: 1200, height: 900)
        let window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidebar.frame.width + (sharedWindow ? canvasSize.width : 0), height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if sharedWindow {
            let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
            container.addSubview(sidebar)
            f.canvas.frame = NSRect(origin: NSPoint(x: sidebar.frame.maxX, y: 0), size: canvasSize)
            container.addSubview(f.canvas)
            window.contentView = container
        } else {
            window.contentView = sidebar
        }
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        if sharedWindow { delegate.qaInstallTileFocusMonitor() }
        defer { if sharedWindow { delegate.qaRemoveTileFocusMonitor() } }
        delegate.qaRefreshAgentSurfaces()
        spin(0.3)

        let away = CanvasViewport(x: -40_000, y: -40_000, zoom: 0.5)
        var report: [String] = []
        var failures: [String] = []
        if multiWorkspaceScope, case .workspaces = sidebar.agentInbox.scope {} else if multiWorkspaceScope {
            failures.append("precondition: the persisted two-workspace scope did not load (\(sidebar.agentInbox.scope))")
        }
        func variant(_ label: String, agent: AgentID, tile: UUID, flies: Bool = false,
                     before: () -> Void = {}, during: () -> Void = {}, midClick: (() -> Void)? = nil,
                     pressOn: AgentID? = nil) {
            f.canvas.navigationFlightOverrideForQA = flies
            // The camera starts nowhere near either tile, and focus is elsewhere.
            f.canvas.setViewport(away)
            _ = delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
            before()
            spin(0.2)
            do {
                guard let target = f.canvas.framedViewportForTileJump(tile) else {
                    throw Failure(description: "precondition: the tile has no reveal framing")
                }
                try click(row: agent.rawValue, in: sidebar, window: window, betweenDownAndUp: midClick,
                          pressedRow: pressOn?.rawValue)
                during()
                // A flight lands well inside this; a snap is immediate.
                spin(flies ? 2.0 : 0.2)
                let camera = f.canvas.viewport
                let landed = abs(camera.x - target.x) < 1 && abs(camera.y - target.y) < 1
                    && abs(camera.zoom - target.zoom) < 0.001
                let focused = delegate.qaFocusBroker.activeSurface == .tile(tile)
                if !focused, case .tile(let other)? = delegate.qaFocusBroker.activeSurface {
                    let owner = supervisor.records.values.first { $0.tileId == other }
                    failures.append("[\(label)] revealed \(owner?.displayName ?? "an unknown agent")'s tile instead")
                }
                guard landed, focused else {
                    throw Failure(description: "the click did not reveal the tile: camera \(camera) (target \(target), away \(away)), focus \(String(describing: delegate.qaFocusBroker.activeSurface))")
                }
                report.append("  \(label): camera on the tile, tile focused")
            } catch {
                failures.append("[\(label)] \(error)")
            }
        }

        variant("tile in the armed zone", agent: armedAgent, tile: armedTile)
        variant("tile in another zone", agent: f.agentId, tile: f.agentTileB)
        variant("after an app switch away and back", agent: armedAgent, tile: armedTile) {
            delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification, object: NSApp))
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification, object: NSApp))
        }
        variant("after an app switch, other zone", agent: f.agentId, tile: f.agentTileB) {
            delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification, object: NSApp))
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification, object: NSApp))
        }
        variant("after agent events streamed", agent: f.agentId, tile: f.agentTileB) {
            let thread = AgentSupervisor.threadId(for: f.agentId)
            supervisor.qaBindRunnerForCapabilities(ScriptedAgentRunner(script: []), for: f.agentId)
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "reveal"), to: f.agentId)
            spin(0.4)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "reveal", outcome: .completed, errorMessage: nil), to: f.agentId)
            supervisor.qaBindRunnerForCapabilities(nil, for: f.agentId)
            spin(0.4)
        }
        variant("same row clicked again", agent: f.agentId, tile: f.agentTileB)
        // The live app's canvas is on screen, so a reveal FLIES the camera.
        variant("flight, armed zone", agent: armedAgent, tile: armedTile, flies: true)
        variant("flight, other zone", agent: f.agentId, tile: f.agentTileB, flies: true)
        variant("flight, after an app switch", agent: f.agentId, tile: f.agentTileB, flies: true) {
            delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification, object: NSApp))
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification, object: NSApp))
        }
        // A push landing while the button is down: the row's own value changes.
        variant("push mid-click, row value changes", agent: f.agentId, tile: f.agentTileB, midClick: {
            supervisor.qaBindRunnerForCapabilities(ScriptedAgentRunner(script: []), for: f.agentId)
            supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: f.agentId), turnId: "mid"), to: f.agentId)
            delegate.qaPushAgentSurfacesForEvent()
        })
        // A push landing while the button is down: a new row arrives and the
        // list re-renders under the pointer. The default sort re-selects the
        // pressed row by id, so it stays highlighted — the 0.7.51 report.
        var lateArrived = false
        var lateAgent: AgentID?
        variant("push mid-click, a row arrives", agent: armedAgent, tile: armedTile, midClick: {
            let late = supervisor.spawn(
                role: nil, prompt: nil, cwd: f.paRoot, harness: .pi,
                model: WorkspaceAgentReportChecks.model, thinking: "high",
                projectId: f.projectPa, projectRoot: f.paRoot)
            _ = supervisor.rename(agentID: late, to: "Late agent")
            lateAgent = late
            delegate.qaRefreshAgentSurfaces()
            lateArrived = sidebar.agentInbox.qaAllRowsForQA.contains { $0.id == late.rawValue }
        })
        if !lateArrived { failures.append("positive control: no row arrived while the button was down") }
        // An agent streaming while the camera flies: the activity pushes land mid-flight.
        variant("flight while agents stream", agent: armedAgent, tile: armedTile, flies: true, during: {
            for agent in [f.agentId, armedAgent] {
                supervisor.qaBindRunnerForCapabilities(ScriptedAgentRunner(script: []), for: agent)
                supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: agent), turnId: "stream"), to: agent)
            }
            for step in 0..<20 {
                for agent in [f.agentId, armedAgent] {
                    supervisor.qaDeliver(.contentDelta(threadId: AgentSupervisor.threadId(for: agent), turnId: "stream",
                                                       streamKind: .assistant, delta: "word \(step) "), to: agent)
                }
                spin(0.05)
            }
        })

        // AppKit's drag-select: pressed on one row, released on another. The
        // release row is the one the action opens, as it was before the fix.
        // Last: it leaves a multi-row selection behind it.
        variant("pressed on one row, released on another", agent: f.agentId, tile: f.agentTileB, pressOn: armedAgent)

        // Several rows selected by a drag, then a PLAIN click on one of them: as
        // in Finder and Mail, the selection collapses to that row and it opens.
        // AppKit sent no action for this click at all, so the row stayed lit in
        // the selection and the canvas never moved.
        let inbox = sidebar.agentInbox
        func dragSelect(_ label: String) -> Set<UUID>? {
            do { try click(row: f.agentId.rawValue, in: sidebar, window: window, pressedRow: armedAgent.rawValue) } catch {
                failures.append("[\(label)] precondition: \(error)"); return nil
            }
            spin(0.2)
            let selected = Set(inbox.qaSelectedAgentIdsForQA)
            guard selected.count >= 2, selected.contains(armedAgent.rawValue) else {
                failures.append("[\(label)] precondition: the drag selected \(selected.count) row(s), not several"); return nil
            }
            return selected
        }
        do {
            let label = "plain click inside a multi-selection"
            if dragSelect(label) != nil {
                f.canvas.navigationFlightOverrideForQA = false
                f.canvas.setViewport(away)
                _ = delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
                // Every reveal the click asks the host for, through the production hook.
                let host = inbox.onRevealRow
                var reveals: [UUID] = []
                inbox.onRevealRow = { reveals.append($0); host?($0) }
                defer { inbox.onRevealRow = host }
                let target = f.canvas.framedViewportForTileJump(armedTile)
                do { try click(row: armedAgent.rawValue, in: sidebar, window: window) } catch {
                    failures.append("[\(label)] \(error)")
                }
                spin(0.2)
                let prompt = reveals.count
                let promptSelection = inbox.qaSelectedAgentIdsForQA
                let camera = f.canvas.viewport
                let landed = target.map { abs(camera.x - $0.x) < 1 && abs(camera.y - $0.y) < 1 } ?? false
                // AppKit can act on this click later, once the double-click
                // interval has passed: wait it out and count again.
                spin(NSEvent.doubleClickInterval + 0.5)
                if prompt != 1 || promptSelection != [armedAgent.rawValue] || !landed
                    || delegate.qaFocusBroker.activeSurface != .tile(armedTile) {
                    failures.append("[\(label)] within 0.2 s of release: \(prompt) reveal(s), \(promptSelection.count) row(s) selected, camera on the tile \(landed), focus \(String(describing: delegate.qaFocusBroker.activeSurface)); \(reveals.count) reveal(s) by \(String(format: "%.1f", NSEvent.doubleClickInterval + 0.7)) s")
                } else if reveals.count != 1 {
                    failures.append("[\(label)] one click opened the row \(reveals.count) times (the extra after the double-click interval)")
                } else if inbox.qaSelectedAgentIdsForQA != [armedAgent.rawValue] {
                    failures.append("[\(label)] the selection changed after the click: \(inbox.qaSelectedAgentIdsForQA.count) row(s)")
                } else {
                    report.append("  \(label): collapsed to the row, opened once, camera on the tile")
                }
            }
        }

        // ⌘- and ⇧-clicks stay AppKit's selection gestures: they change the
        // selection the way NSTableView does and never move the camera.
        for (label, modifiers) in [("⌘-click inside a multi-selection", NSEvent.ModifierFlags.command),
                                   ("⇧-click inside a multi-selection", NSEvent.ModifierFlags.shift)] {
            guard let target = lateAgent else { failures.append("[\(label)] precondition: no third row"); continue }
            guard let before = dragSelect(label) else { continue }
            f.canvas.setViewport(away)
            do { try click(row: target.rawValue, in: sidebar, window: window, modifiers: modifiers) } catch {
                failures.append("[\(label)] \(error)"); continue
            }
            spin(0.2)
            let after = Set(inbox.qaSelectedAgentIdsForQA)
            let expected = modifiers == .command
                ? before.symmetricDifference([target.rawValue]) : nil
            if f.canvas.viewport != away {
                failures.append("[\(label)] the camera moved: \(f.canvas.viewport)")
            } else if let expected, after != expected {
                failures.append("[\(label)] the selection is \(after.count) row(s), expected \(expected.count): ⌘ toggles the row")
            } else if modifiers == .shift, !(after.contains(target.rawValue) && after.count >= 2) {
                failures.append("[\(label)] the selection is \(after.count) row(s): ⇧ extends a range to the row")
            } else {
                report.append("  \(label): selection \(before.count) → \(after.count) rows, camera stayed")
            }
        }
        return (report, failures)
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A real click on the row's title, through the window: mouse-up queued
    /// first so the table's tracking loop ends, then mouse-down sent.
    /// `pressedRow` presses there and drags to `id` before releasing.
    private static func click(row id: UUID, in sidebar: WorkspaceSidebarView, window: NSWindow,
                              betweenDownAndUp: (() -> Void)? = nil, pressedRow: UUID? = nil,
                              modifiers: NSEvent.ModifierFlags = []) throws {
        let inbox = sidebar.agentInbox
        sidebar.layoutSubtreeIfNeeded()
        inbox.layoutForQA()
        func titlePoint(_ agent: UUID) throws -> NSPoint {
            guard let cell = inbox.qaMaterializedRowCells.compactMap({ $0 as? AgentInbox96CellView })
                .first(where: { $0.qaAgentID == agent }) else {
                throw Failure(description: "no sidebar row for \(agent) (rows: \(inbox.qaMaterializedRowCells.compactMap(\.qaAgentID)))")
            }
            let title = cell.qaTitleFrameForQA
            return cell.convert(NSPoint(x: title.midX, y: title.midY), to: nil)
        }
        let releasePoint = try titlePoint(id)
        let pressPoint = try pressedRow.map(titlePoint) ?? releasePoint
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: type == .leftMouseDown ? pressPoint : releasePoint, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "could not synthesise \(type)") }
            return event
        }
        let up = try mouse(.leftMouseUp)
        if let betweenDownAndUp {
            // The table tracks the press in its own loop; main-queue work runs
            // inside it, so this lands while the button is still down.
            DispatchQueue.main.async {
                betweenDownAndUp()
                NSApp.postEvent(up, atStart: false)
            }
        } else {
            if pressPoint != releasePoint { NSApp.postEvent(try mouse(.leftMouseDragged), atStart: false) }
            NSApp.postEvent(up, atStart: false)
        }
        NSApp.sendEvent(try mouse(.leftMouseDown))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }
}
