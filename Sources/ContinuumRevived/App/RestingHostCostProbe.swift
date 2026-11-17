import AppKit
import ContinuumRevivedCore
import Darwin
import Foundation

/// `--resting-host-cost-probe`: what resting agent tiles cost, at 24 and 72
/// tiles. Diagnosis for the per-tile resting host (`RestingHost`): attach,
/// rest, wake and detach time per tile, malloc bytes per resting tile, and
/// main-thread time per pan and zoom step with every tile resting.
///
/// Driven through production: a real `AppDelegate`, supervisor and
/// `ManagedAgentTileNSView`s wired by `wireManagedAgentTile`, rested by
/// `restChromeIfIdle`, moved by `CanvasNSView.setViewport`, closed by
/// `AppDelegate.deleteTile`. Prints numbers; asserts nothing.
@MainActor
enum RestingHostCostProbe {
    private static func ms(_ seconds: Double) -> String { String(format: "%.3f ms", seconds * 1000) }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func run() async throws -> String {
        var lines: [String] = []
        for count in [24, 72] {
            lines.append(try await measure(tiles: count))
        }
        return lines.joined(separator: "\n")
    }

    private static func measure(tiles count: Int) async throws -> String {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("array-resting-host-cost-\(UUID().uuidString)", isDirectory: true)
        let appSupport = temporary.appendingPathComponent("support", isDirectory: true)
        let agentsSupport = temporary.appendingPathComponent("agents", isDirectory: true)
        let projectRoot = temporary.appendingPathComponent("checkout", isDirectory: true)
        for dir in [appSupport, agentsSupport, projectRoot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: temporary) }

        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 0.2), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        let delegate = AppDelegate()
        canvas.focusBroker = delegate.focusBroker
        delegate.canvasView = canvas
        delegate.registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: agentsSupport),
            makeRunner: { _ in ScriptedAgentRunner(script: []) })
        let supervisor = delegate.agentSupervisor
        ManagedAgentTileNSView.qaPointerInside = { _ in false }
        defer { ManagedAgentTileNSView.qaPointerInside = nil }

        func settle() async { _ = await waitUntil(timeout: 0.3, pollInterval: 0.1) { false } }

        await settle()
        let baseline = LongSessionMemoryChecks.mallocBytesInUse()
        // Attach.
        var views: [ManagedAgentTileNSView] = []
        var attach = 0.0
        for index in 0..<count {
            let tile = Tile(
                id: UUID(), kind: .managedAgent, title: "agent \(index)",
                frame: TileFrame(x: Double(40 + (index % 12) * 560), y: Double(40 + (index / 12) * 460),
                                 width: 520, height: 420),
                zPosition: .fromLegacyRank(index + 1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
            let start = now()
            let view = ManagedAgentTileNSView(tile: tile)
            canvas.install(tileView: view, for: tile)
            let agent = supervisor.spawn(
                role: nil, prompt: nil, cwd: projectRoot, harness: .claudeCode,
                model: "anthropic/claude-sonnet-5-5", thinking: "medium", tileId: tile.id,
                displayName: "Host cost \(index)")
            delegate.wireManagedAgentTile(tile.id, agentID: agent)
            canvas.layoutSubtreeIfNeeded()
            attach += now() - start
            views.append(view)
        }
        window.makeFirstResponder(nil)
        await settle()

        // Wake everything first, so every rest below is a real move to the host.
        for view in views { view.wakeChrome() }
        canvas.layoutSubtreeIfNeeded()
        await settle()

        // Rest.
        var rest = 0.0
        var rested = 0
        for view in views {
            let start = now()
            if view.restChromeIfIdle() { rested += 1 }
            rest += now() - start
        }
        canvas.layoutSubtreeIfNeeded()
        await settle()
        // Everything the resting tiles hold, from before the first attached.
        let restBytes = LongSessionMemoryChecks.mallocBytesInUse() - baseline

        // Pan and zoom with every tile resting.
        func cameraStep(_ viewport: CanvasViewport) -> Double {
            let start = now()
            canvas.setViewport(viewport)
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            return now() - start
        }
        var pan: [Double] = []
        var zoom: [Double] = []
        for step in 0..<120 {
            pan.append(cameraStep(CanvasViewport(x: Double(step) * 24, y: Double(step) * 12, zoom: 0.2)))
        }
        for step in 0..<120 {
            let t = Double(step) / 119
            zoom.append(cameraStep(CanvasViewport(x: 0, y: 0, zoom: 0.15 + 0.35 * (0.5 - 0.5 * cos(t * .pi * 4)))))
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }

        // Wake.
        var wake = 0.0
        for view in views {
            let start = now()
            view.wakeChrome()
            wake += now() - start
        }
        canvas.layoutSubtreeIfNeeded()
        // Rest again, then detach the way the tile's × does.
        for view in views { _ = view.restChromeIfIdle() }
        await settle()
        var detach = 0.0
        for view in views {
            let start = now()
            delegate.deleteTile(id: view.tile.id)
            detach += now() - start
        }
        views.removeAll()
        await settle()

        let n = Double(count)
        return "\(count) tiles: attach \(ms(attach / n))/tile, rest \(ms(rest / n))/tile (\(rested) rested, \(restBytes / count / 1024) KB/tile held at rest), wake \(ms(wake / n))/tile, detach \(ms(detach / n))/tile; pan median \(ms(median(pan))) p95 \(ms(p95(pan))), zoom median \(ms(median(zoom))) p95 \(ms(p95(zoom)))"
    }
}
