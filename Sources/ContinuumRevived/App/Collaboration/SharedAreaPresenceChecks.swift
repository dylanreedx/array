import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

@MainActor
enum SharedAreaPresenceChecks {
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        print("PASS cursor usage: \(message)")
    }
    static func run() async throws {
        let host = try SharedAreaSceneChecks.makeAppearanceFixture()
        func scene(in view: NSView) -> SharedAreaSceneView? {
            if let value = view as? SharedAreaSceneView { return value }
            return view.subviews.lazy.compactMap { scene(in: $0) }.first
        }
        guard let scene = scene(in: host) else { throw Failure(message: "missing production scene fixture") }
        let overlay = SharedAreaPresenceOverlay(scene: scene)
        scene.areaCanvasView.addSubview(overlay)
        let identity = Collaboration.Identity(person: .init(), device: UUID())
        let now = Date(), area = scene.areaPoint(forScreenPoint: .init(x: 210, y: 210))
        let usage = Collaboration.UsageSnapshot(host: .init(), sequence: 1, inputTokens: 100, outputTokens: 20,
            todayInputTokens: 60, todayOutputTokens: 10, dayUTC: SharedAreaUsageLedger.dayUTC(now),
            observedSince: now, measuredAt: now, coveredAgents: 2, runningAgents: 1, partial: true)
        let peer = Collaboration.Presence(identity: identity, cursor: .init(x: area.x, y: area.y), viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A", usage: usage)
        overlay.peers = [peer]
        let point = overlay.convert(scene.screenPoint(forAreaPoint: area), from: scene)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            overlay.inspect(device: nil)
            _ = try UIProbe.render(.init(id: "collaboration.presence.rest.\(appearance.rawValue)", size: .init(width: 960, height: 680), appearance: appearance), make: { host })
            try expect(overlay.renderedUsageText == nil && overlay.inspectedDevice == nil,
                "\(appearance.rawValue) resting cursor paints no persistent usage overlay")
            overlay.pointerMoved(to: point)
            let probe = try UIProbe.render(.init(id: "collaboration.presence.hover.\(appearance.rawValue)", size: .init(width: 960, height: 680), appearance: appearance), make: { host })
            try expect(overlay.inspectedDevice == identity.device && overlay.renderedUsageText?.contains("120 tokens") == true
                && overlay.renderedUsageText?.contains("Observed today (UTC): 70") == true
                && overlay.renderedUsageText?.contains("Partial coverage") == true,
                "\(appearance.rawValue) hovering the actual cursor reveals measured totals, UTC day and honest coverage")
            if let path = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"],
               let data = probe.hostRep.representation(using: .png, properties: [:]) {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("cursor-hover-\(appearance == .aqua ? "light" : "dark").png"))
            }
            overlay.pointerMoved(to: nil)
            try expect(overlay.renderedUsageText == nil && overlay.inspectedDevice == nil,
                "leaving the cursor removes its usage immediately")
        }
        overlay.peers = [peer]; overlay.pointerMoved(to: point)
        overlay.peers = [.init(identity: identity, cursor: .init(x: area.x + 1000, y: area.y + 1000), viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A", usage: usage)]
        try expect(overlay.inspectedDevice == nil && overlay.renderedUsageText == nil,
            "a teammate moving away dismisses hover without another local mouse event")
        overlay.peers = [peer]; overlay.pointerMoved(to: point)
        _ = try UIProbe.render(.init(id: "collaboration.presence.stationary", size: .init(width: 960, height: 680), appearance: .aqua), make: { host })
        let zoom = scene.localViewCamera.zoom
        overlay.peers = [.init(identity: identity, cursor: .init(x: area.x - 80 / zoom, y: area.y - 80 / zoom), viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A", usage: usage)]
        try expect(overlay.inspectedDevice == nil,
            "a moving cursor cannot create a new clamped card underneath a stationary pointer")
        overlay.peers = [peer]; overlay.pointerMoved(to: point)
        let camera = scene.localViewCamera
        try scene.setCamera(.init(x: camera.x + 1000, y: camera.y + 1000, zoom: camera.zoom))
        overlay.refreshGeometry()
        try expect(overlay.inspectedDevice == nil,
            "camera navigation rechecks a stationary hover against the transformed cursor")
        try scene.setCamera(camera)
        overlay.pointerMoved(to: point); overlay.updateTrackingAreas()
        guard let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else {
            throw Failure(message: "could not construct native cursor exit")
        }
        var publishedExit = false
        overlay.onPointerExit = { publishedExit = true }
        overlay.mouseExited(with: exit)
        try expect(publishedExit && overlay.inspectedDevice == nil && overlay.renderedUsageText == nil,
            "the native tracking exit clears hover and informs cursor publication")
        overlay.peers = [peer]
        guard let accessible = overlay.accessibilityChildren()?.first as? NSAccessibilityElement else {
            throw Failure(message: "cursor has no accessibility inspection target")
        }
        try expect(accessible.accessibilityPerformPress() && overlay.inspectedDevice == identity.device,
            "accessibility focus exposes the same transient teammate inspection without a constant counter")
        overlay.peers = [.init(identity: identity, cursor: peer.cursor, viewport: nil,
            expiresAt: now.addingTimeInterval(-1), label: "Peer A", usage: usage)]
        try expect(overlay.visiblePeers.isEmpty && overlay.inspectedDevice == nil && overlay.renderedUsageText == nil,
            "expired cursor/usage disappears even without another local mouse event")
        let unknown = Collaboration.Presence(identity: identity, cursor: peer.cursor, viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A")
        try expect(SharedAreaPresenceOverlay.usageLines(unknown).contains("Usage has not been reported"),
            "missing telemetry is unavailable rather than a fabricated zero")
        let invalidUsage = Collaboration.UsageSnapshot(host: .init(), sequence: 1, inputTokens: .max, outputTokens: .max,
            todayInputTokens: .max, todayOutputTokens: .max, dayUTC: usage.dayUTC,
            observedSince: now, measuredAt: now, coveredAgents: 1, runningAgents: 1, partial: true)
        let malformed = Collaboration.Presence(identity: identity, cursor: peer.cursor, viewport: nil,
            expiresAt: now.addingTimeInterval(60), label: "Peer A", usage: invalidUsage)
        try expect(SharedAreaPresenceOverlay.usageLines(malformed).contains("Token usage unavailable"),
            "invalid maximum counters render unavailable without integer overflow")
        overlay.removeFromSuperview(); scene.unmount(); await scene.controller.close()
        try await SharedAreaHostSessionChecks.run()
    }
}
