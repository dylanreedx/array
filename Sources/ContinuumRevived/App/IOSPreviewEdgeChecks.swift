import AppKit
import ContinuumRevivedCore

/// Uses the already mounted production scene. These checks deliberately pass
/// window-coordinate events through the real screen handlers, rather than
/// checking a duplicate coordinate formula in isolation.
@MainActor
enum IOSPreviewEdgeChecks {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw IOSPreviewChecks.Failure(description: message) }
    }
    private static func point(_ payload: [String: Any], equals expected: CGPoint) -> Bool {
        guard let x = payload["x"] as? CGFloat, let y = payload["y"] as? CGFloat else { return false }
        return abs(x - expected.x) < 0.001 && abs(y - expected.y) < 0.001
    }
    private static func raw(_ x: CGFloat, _ y: CGFloat, orientation: Int) -> CGPoint {
        switch orientation {
        case 2: return CGPoint(x: 1 - x, y: 1 - y)
        case 3: return CGPoint(x: 1 - y, y: x)
        case 4: return CGPoint(x: y, y: 1 - x)
        default: return CGPoint(x: x, y: y)
        }
    }
    static func input(view: IOSPreviewTileNSView, canvas: CanvasNSView, window: NSWindow,
                      session: IOSPreviewChecks.Session) throws {
        let viewport = canvas.viewport
        let orientation = view.screen.orientation
        defer {
            view.screen.releaseInput()
            view.screen.orientation = orientation
            canvas.setViewport(viewport)
            canvas.layoutSubtreeIfNeeded()
        }
        func event(_ type: NSEvent.EventType, at local: CGPoint) -> NSEvent {
            let location = view.screen.convert(local, to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1)!
        }
        var scenarios = 0
        for zoom in [0.25, 1.0, 2.0] {
            var camera = viewport; camera.zoom = zoom
            canvas.setViewport(camera)
            canvas.layoutSubtreeIfNeeded()
            for angle in [1, 2, 3, 4] {
                view.screen.orientation = angle
                let rect = view.screen.screenRect
                try expect(rect.width > 0 && rect.height > 0, "preview must retain a usable input rectangle at zoom \(zoom)")
                let target = CGPoint(x: rect.minX + rect.width * 0.23, y: rect.minY + rect.height * 0.71)
                let before = session.messages.count
                view.screen.mouseDown(with: event(.leftMouseDown, at: target))
                view.screen.mouseUp(with: event(.leftMouseUp, at: target))
                let delivered = Array(session.messages.dropFirst(before))
                try expect(delivered.count == 2 && delivered.allSatisfy { $0.0 == 3 },
                           "zoom \(zoom), orientation \(angle) must deliver exactly one touch pair")
                let expected = raw(0.23, 0.71, orientation: angle)
                try expect(delivered.allSatisfy { point($0.1, equals: expected) },
                           "zoom \(zoom), orientation \(angle) must map window coordinates through letterboxing")
                try expect(delivered[0].1["type"] as? String == "begin" && delivered[1].1["type"] as? String == "end",
                           "a complete click must retain begin/end ordering")

                // A click in the letterbox must never become a simulator touch.
                let ignoredBefore = session.messages.count
                let margin = CGPoint(x: rect.minX - 2, y: rect.midY)
                view.screen.mouseDown(with: event(.leftMouseDown, at: margin))
                view.screen.mouseUp(with: event(.leftMouseUp, at: margin))
                try expect(session.messages.count == ignoredBefore,
                           "letterbox clicks must be ignored at every zoom and orientation")

                // Real drags routinely leave the device rectangle. Clamp their
                // terminal point, end exactly once, and reject a stray later up.
                let dragBefore = session.messages.count
                let outside = CGPoint(x: rect.maxX + rect.width, y: rect.minY - rect.height)
                view.screen.mouseDown(with: event(.leftMouseDown, at: target))
                view.screen.mouseDragged(with: event(.leftMouseDragged, at: outside))
                view.screen.mouseUp(with: event(.leftMouseUp, at: outside))
                let dragged = Array(session.messages.dropFirst(dragBefore))
                try expect(dragged.count == 3 && dragged[1].1["type"] as? String == "move" && dragged[2].1["type"] as? String == "end",
                           "leaving the screen must preserve move/end ordering")
                try expect(point(dragged[1].1, equals: raw(1, 0, orientation: angle)) &&
                           point(dragged[2].1, equals: raw(1, 0, orientation: angle)),
                           "out-of-screen drag release must clamp in the rotated raw coordinate space")
                view.screen.mouseUp(with: event(.leftMouseUp, at: outside))
                try expect(session.messages.count == dragBefore + 3, "a stray mouse-up must not duplicate an ended touch")
                scenarios += 1
            }
        }
        let rect = view.screen.screenRect
        let target = CGPoint(x: rect.midX, y: rect.midY)
        let beforeLoss = session.messages.count
        view.screen.mouseDown(with: event(.leftMouseDown, at: target))
        _ = view.screen.resignFirstResponder()
        _ = view.screen.resignFirstResponder()
        let lost = Array(session.messages.dropFirst(beforeLoss))
        try expect(lost.count == 2 && lost[0].1["type"] as? String == "begin" && lost[1].1["type"] as? String == "end",
                   "focus loss must end a held touch exactly once")
        print("IOSPreviewEdgeChecks input passed: \(scenarios) zoom/orientation cases, letterbox rejection, clamped drag release and focus-loss release")
    }

    static func selectionRollback(view: IOSPreviewTileNSView, canvas: CanvasNSView,
                                  store: ProjectStore, projectRoot: URL) throws {
        guard let record = canvas.tileRecord(for: view.tile.id), let previousID = record.metadata.iosPreviewDeviceID else {
            throw IOSPreviewChecks.Failure(description: "selection rollback fixture requires a saved device identity")
        }
        let path = projectRoot.appendingPathComponent(".array/canvas.json")
        let bytes = try Data(contentsOf: path)
        let attemptedID = UUID().uuidString
        StoreFileWriter.install(.init(fault: .failFrom(1), scope: projectRoot,
                                     matching: { $0.lastPathComponent == "canvas.json" }))
        defer { StoreFileWriter.uninstall() }
        view.selectDevice(id: attemptedID, name: "Selection that must roll back")
        try expect(canvas.tileRecord(for: view.tile.id) == record,
                   "failed selection persistence must restore the entire canvas record")
        try expect(view.runtime.deviceID == previousID && view.runtime.state == .disconnected,
                   "failed selection persistence must restore exact runtime identity without connecting")
        try expect(view.tile.metadata.iosPreviewDeviceID == previousID,
                   "failed selection persistence must retain the view's saved tile descriptor")
        func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(view)
        let picker = controls.compactMap { $0 as? ChoiceButton }.first { $0.items.contains { $0.id == attemptedID } }
        try expect(picker?.selectedID == previousID,
                   "failed selection persistence must visibly restore the previous chooser value")
        try expect(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Could not save the simulator selection") },
                   "failed selection persistence must show a visible save error")
        let after = try Data(contentsOf: path)
        try expect(bytes == after, "failed selection persistence must leave canvas bytes unchanged")
        let saved = try store.tryLoadCanvas()
        try expect(saved?.tiles.first(where: { $0.id == view.tile.id })?.metadata.iosPreviewDeviceID == previousID,
                   "the owning project store must still resolve the prior simulator")
        print("IOSPreviewEdgeChecks rollback passed: failed selection save retains disk, canvas, runtime and visible chooser identity")
    }
}
