import AppKit
import ContinuumRevivedCore
import QuartzCore

/// `--tidy-offscreen-defer-check` (overnight auto-layout program).
///
/// An 89-tile tidy resizes every tile, and resizing a real body re-tiles its
/// scroll views. With the camera showing about 12 of them, the rest are
/// far-parked by production's own parking pass. A resize must leave a parked
/// body parked: only the tiles in view (plus the parking margin) re-lay out
/// inside the commit that starts the movement, a parked tile re-lays out exactly
/// once, when the camera brings it back, and it is already at its new size the
/// first time it can be seen.
@MainActor
enum TidyOffscreenDeferChecks {
    typealias Fixture = WorkspaceInvariantsFixture
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func run() throws {
        let m = try AutoLayoutTidyLatencyChecks.mount(count: 89)
        defer {
            m.mounted.delegate.qaRemoveTileFocusMonitor()
            m.window.orderOut(nil)
            m.fixture.dispose()
        }
        let canvas = m.mounted.canvas
        func view(_ id: UUID) throws -> TileNSView {
            guard let view = canvas.tileView(for: id) else { throw Failure(message: "tile \(id) has no view") }
            return view
        }
        func settle() { canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded(); CATransaction.flush() }
        func visibleWorld() -> CGRect {
            let v = canvas.viewport
            return CGRect(x: v.x, y: v.y, width: Double(canvas.bounds.width) / v.zoom, height: Double(canvas.bounds.height) / v.zoom)
        }

        // The camera on the zone's top-left corner at 1.5x: about a dozen tiles.
        guard let zone = canvas.qaLiveZonePlacement(Fixture.zoneA1) else { throw Failure(message: "zone A1 is not live") }
        canvas.setViewport(CanvasViewport(x: zone.origin.x - 20, y: zone.origin.y - 20, zoom: 1.5))
        settle()
        let visibleBefore = try m.ids.filter { try view($0).frame.intersects(visibleWorld()) }.count
        // Production's settled parking pass, run to completion.
        var passes = 0
        while canvas.qaRunFarParkingPass(), passes < 100 { passes += 1 }
        settle()
        let parked = try Set(m.ids.filter { try view($0).isFarParked })
        guard parked.count >= 50 else {
            throw Failure(message: "fixture: only \(parked.count) of 89 tiles far-parked with \(visibleBefore) in view")
        }

        // Tidy, dispatched as the zone menu dispatches it.
        let world = CGPoint(x: zone.origin.x + 60, y: zone.origin.y + Double(ZoneChromeNSView.headerHeight) / 2)
        let point = canvas.convert(CanvasEngine.worldToScreen(world, viewport: canvas.viewport), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: m.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let item = canvas.menu(for: event)?.items.first(where: { $0.title == "Tidy Zone Now" }) else {
            throw Failure(message: "the zone header menu has no Tidy Zone Now")
        }
        let resizesBefore = try Dictionary(uniqueKeysWithValues: m.ids.map { ($0, try view($0).qaBodyResizeCount) })
        let framesBefore = try Dictionary(uniqueKeysWithValues: m.ids.map { ($0, try view($0).frame) })
        canvas.qaAutoLayoutStageTimes = .init()
        let triggerAt = CACurrentMediaTime()
        NSApp.sendAction(item.action!, to: item.target, from: item)
        let triggerMs = (CACurrentMediaTime() - triggerAt) * 1000
        settle()
        var firstBegin = Double.infinity
        for id in m.ids {
            guard let layer = try view(id).layer else { continue }
            for key in layer.animationKeys() ?? [] {
                if let a = layer.animation(forKey: key) as? CABasicAnimation, a.beginTime > 0 {
                    firstBegin = min(firstBegin, layer.convertTime(a.beginTime, to: nil))
                }
            }
        }
        let movementStartMs = firstBegin.isFinite ? (firstBegin - triggerAt) * 1000 : -1
        let stages = canvas.qaAutoLayoutStageTimes

        var failures: [String] = []
        let resized = try m.ids.filter { try view($0).frame.size != framesBefore[$0]!.size }
        let relaidInCommit = try m.ids.filter { try view($0).qaBodyResizeCount > resizesBefore[$0]! }
        let stillParked = try m.ids.filter { try view($0).isFarParked }
        let returned = parked.filter { !stillParked.contains($0) }
        if resized.count < 80 { failures.append("fixture: tidy resized only \(resized.count) of 89 tiles") }
        // Parked bodies stay parked and untouched.
        for id in stillParked where try view(id).qaBodyResizeCount != resizesBefore[id]! {
            failures.append("parked tile \(id) re-laid out its body inside the commit")
        }
        // A parked tile the tidy left outside the return margin must still be parked:
        // resizing it is no reason to bring a body nobody can see back into the tree.
        let lead = visibleWorld().insetBy(dx: -visibleWorld().width * CanvasNSView.farReturnMargin,
                                          dy: -visibleWorld().height * CanvasNSView.farReturnMargin)
        let unparked = try parked.filter { id in
            let v = try view(id)
            return !v.frame.intersects(lead) && !v.isFarParked
        }
        if !unparked.isEmpty {
            failures.append("\(unparked.count) parked tiles still outside the return margin were unparked by the resize")
        }
        // Everything in view is a real, laid-out body at its new size.
        for id in m.ids {
            let v = try view(id)
            guard v.frame.intersects(visibleWorld()) else { continue }
            if v.isFarParked { failures.append("tile \(id) is in view with its body parked (blank)") }
            if let body = v.qaContentViewFrame, abs(body.width - v.bounds.width) > 0.5 {
                failures.append("tile \(id) is in view with a stale body width \(body.width) in a \(v.bounds.width) tile")
            }
        }
        // Positive control: tiles that were not parked and resized did re-lay out.
        let nativeResized = resized.filter { !parked.contains($0) }
        if !nativeResized.isEmpty && relaidInCommit.isEmpty {
            failures.append("positive control: no body re-laid out at all; the counter is dead")
        }

        // Pan to a tile that is still parked: it comes back laid out at its new
        // size, once, before it is on screen.
        if let target = try stillParked.max(by: { try view($0).frame.minY + view($0).frame.minX < view($1).frame.minY + view($1).frame.minX }) {
            let v = try view(target)
            let before = v.qaBodyResizeCount
            let zoom = canvas.viewport.zoom
            let w = Double(canvas.bounds.width) / zoom, h = Double(canvas.bounds.height) / zoom
            canvas.setViewport(CanvasViewport(x: Double(v.frame.midX) - w / 2, y: Double(v.frame.midY) - h / 2, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
            // Before anything is drawn: the body is back, and already new-sized.
            if v.isFarParked { failures.append("panning onto parked tile \(target) left its body parked") }
            if let body = v.qaContentViewFrame, abs(body.width - v.bounds.width) > 0.5 {
                failures.append("panned-to tile \(target) shows a stale body width \(body.width) in a \(v.bounds.width) tile")
            }
            if v.qaBodyResizeCount - before != 1 {
                failures.append("panned-to tile \(target) re-laid out \(v.qaBodyResizeCount - before) times on return, expected exactly 1")
            }
            settle()
            canvas.setViewport(CanvasViewport(x: canvas.viewport.x + 40, y: canvas.viewport.y, zoom: zoom))
            settle()
            if v.qaBodyResizeCount - before != 1 {
                failures.append("panned-to tile \(target) re-laid out again on a later pan")
            }
        } else {
            failures.append("fixture: no tile stayed parked through the tidy, so the return path went untested")
        }

        print(String(format: "tidy-offscreen-defer: %d of 89 in view, %d parked; tidy resized %d, re-laid out %d in the commit (%d returned into view); motion start %.1f ms (trigger %.1f, solve %.1f, present layout %.1f, flush %.1f)",
                     visibleBefore, parked.count, resized.count, relaidInCommit.count, returned.count,
                     movementStartMs, triggerMs, stages.solve, stages.presentLayout, stages.presentFlush))
        guard failures.isEmpty else {
            throw Failure(message: "\(failures.count) failed:\n  " + failures.prefix(12).joined(separator: "\n  "))
        }
    }
}
