import AppKit
import ContinuumRevivedCore

/// Real tile gestures on a production-mounted, isolated workspace.
@MainActor
enum TileMultiselectChecks {
    static func run() throws {
        for zoom in [1.0, 0.35] {
            for autoLayout in [false, true] { try exercise(zoom: zoom, autoLayout: autoLayout) }
        }
        try crossProject()
    }

    private static func exercise(zoom: Double, autoLayout: Bool) throws {
        let fixture = try TileInsertSlideChecks.makeFixture("multiselect")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("multiselect")
        let canvas = m.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: autoLayout)
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: zoom))
        let window = ZoneTruthChecks.hostInWindow(canvas)
        defer { window.orderOut(nil) }
        let a = TileInsertSlideChecks.tileA, b = TileInsertSlideChecks.tileB
        func event(_ type: NSEvent.EventType, _ p: NSPoint, shift: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: shift ? [.shift] : [],
                              timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: window.windowNumber, context: nil,
                              eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func header(_ id: UUID) throws -> (TileNSView, NSPoint) {
            guard let view = canvas.tileView(for: id) else {
                throw TileInsertSlideChecks.Failure(message: "missing tile \(id)")
            }
            let grabY = (view.resizeMarginInLocalCoordinates + view.grabHeightInLocalCoordinates) / 2
            return (view, view.convert(NSPoint(x: view.bounds.midX, y: grabY), to: nil))
        }
        let before = TileInsertSlideChecks.frames(canvas)
        for id in [a, b] {
            let (view, p) = try header(id)
            view.mouseDown(with: event(.leftMouseDown, p, shift: true))
            try TileInsertSlideChecks.expect(canvas.tileSelection.consumeFocusRouting(for: event(.leftMouseUp, p, shift: true)),
                                             "Shift selection must suppress mouse-up focus routing")
            view.mouseUp(with: event(.leftMouseUp, p, shift: true))
        }
        try TileInsertSlideChecks.expect(canvas.tileSelection.ids == [a, b], "Shift headers must toggle selection")
        let (view, p) = try header(a)
        let destination = NSPoint(x: p.x + 57 * zoom, y: p.y - 43 * zoom)
        view.mouseDown(with: event(.leftMouseDown, p))
        canvas.qaResetCameraLayoutStats()
        let batchesBefore = canvas.tileSelection.batchUpdates
        view.mouseDragged(with: event(.leftMouseDragged, destination))
        try TileInsertSlideChecks.expect(canvas.tileSelection.batchUpdates == batchesBefore + 1,
                                         "one pointer sample must produce one group batch")
        try TileInsertSlideChecks.expect(canvas.qaCameraLayoutStats.tilesLaidOut == 2,
                                         "group move must present only the two changed tiles")
        try TileInsertSlideChecks.expect(canvas.qaCameraLayoutStats.boundsWrites == 0,
                                         "group move must not resize native content")
        view.mouseUp(with: event(.leftMouseUp, destination))
        let after = TileInsertSlideChecks.frames(canvas)
        for id in [a, b] {
            let start = before[id]!, end = after[id]!
            try TileInsertSlideChecks.expect(abs(end.x - start.x - 57) < 0.001 && abs(end.y - start.y - 43) < 0.001,
                                             "Shift-selected tile \(id) did not move with the group: \(start) -> \(end)")
        }
        for id in [TileInsertSlideChecks.tileC, TileInsertSlideChecks.tileD] {
            try TileInsertSlideChecks.expect(before[id] == after[id], "unselected tile moved")
        }
        canvas.undo(nil)
        try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == before, "one undo must restore the entire group")
        canvas.redo(nil)
        try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == after, "one redo must restore the entire group")

        // The actual outer right handle, reached through AppKit hit-testing.
        guard let overlay = canvas.tileSelection.qaOverlay,
              let handle = overlay.handles.first(where: { $0.0 == .right }) else {
            throw TileInsertSlideChecks.Failure(message: "selection has no outer right handle")
        }
        let handlePoint = overlay.convert(NSPoint(x: handle.1.midX, y: handle.1.midY), to: nil)
        // A root content view's superview space is the window base, not its
        // own flipped canvas coordinates. AppKit starts hit-testing there.
        let hit = canvas.hitTest(handlePoint)
        try TileInsertSlideChecks.expect(hit === overlay, "outer handle must be the hit target; got \(String(describing: hit))")
        let resizeEnd = NSPoint(x: handlePoint.x + 137 * zoom, y: handlePoint.y)
        overlay.mouseDown(with: event(.leftMouseDown, handlePoint))
        overlay.mouseDragged(with: event(.leftMouseDragged, resizeEnd))
        overlay.mouseUp(with: event(.leftMouseUp, resizeEnd))
        let resized = TileInsertSlideChecks.frames(canvas)
        for id in [a, b] {
            let initial = after[id]!, actual = resized[id]!
            let expectedX = after[a]!.x + (initial.x - after[a]!.x) * 1.25
            try TileInsertSlideChecks.expect(abs(actual.x - expectedX) < 0.001
                                             && abs(actual.width - initial.width * 1.25) < 0.001
                                             && actual.y == initial.y && actual.height == initial.height,
                                             "right handle must resize the arrangement by one shared scale")
            guard let installed = canvas.tileView(for: id) else { fatalError("missing installed tile") }
            try TileInsertSlideChecks.expect(abs(installed.frame.width - actual.width) < 0.001,
                                             "resize must reach the real view bounds")
            try TileInsertSlideChecks.expect(abs(installed.bounds.width - actual.width) < 0.001
                                             && abs(installed.bounds.height - actual.height) < 0.001,
                                             "resize must reflow native bounds rather than stretch old content")
        }
        canvas.undo(nil)
        try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == after, "resize is one undo step")
        canvas.redo(nil)

        let (cancelView, cancelPoint) = try header(a)
        cancelView.mouseDown(with: event(.leftMouseDown, cancelPoint))
        cancelView.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: cancelPoint.x + 60, y: cancelPoint.y)))
        canvas.cancelOperation(nil)
        cancelView.mouseUp(with: event(.leftMouseUp, cancelPoint))
        try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == resized, "Escape must cancel every member")

        // Failure of the production persistence callback restores every member.
        let persist = canvas.onLayoutCommitted
        canvas.onLayoutCommitted = { _ in false }
        let (failedView, failedPoint) = try header(a)
        failedView.mouseDown(with: event(.leftMouseDown, failedPoint))
        failedView.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: failedPoint.x + 60, y: failedPoint.y)))
        failedView.mouseUp(with: event(.leftMouseUp, NSPoint(x: failedPoint.x + 60, y: failedPoint.y)))
        canvas.onLayoutCommitted = persist
        try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == resized, "failed save must roll back the entire group")

        try TileInsertSlideChecks.expect(canvas.tileSelection.ids == [a, b], "geometry must preserve selection")
        // A cancelled drag may lose its mouse-up. The next Cmd-pan must still
        // own its entire stream, including after Cmd is released before mouse-up.
        let (panView, panStart) = try header(a)
        panView.mouseDown(with: event(.leftMouseDown, panStart))
        panView.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: panStart.x + 30, y: panStart.y)))
        canvas.cancelOperation(nil)
        let panDown = NSEvent.mouseEvent(with: .leftMouseDown, location: panStart, modifierFlags: [.command],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1)!
        panView.mouseDown(with: panDown)
        panView.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: panStart.x + 30, y: panStart.y)))
        let panUp = event(.leftMouseUp, NSPoint(x: panStart.x + 30, y: panStart.y))
        try TileInsertSlideChecks.expect(canvas.tileSelection.consumeFocusRouting(for: panUp), "pan ownership survives modifier release")
        panView.mouseUp(with: panUp)
        try TileInsertSlideChecks.expect(!canvas.isPointerPanActive && canvas.tileSelection.ids == [a, b],
                                         "fresh pan after cancellation must finish and preserve selection")
        try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == resized, "camera pan must not move models")
        if zoom == 1, !autoLayout { try capture(canvas) }
        try TileInsertSlideChecks.expectDurable(fixture, resized, "multiselect zoom=\(zoom) auto=\(autoLayout)")
        let remounted = try fixture.requireMounted("selection remount").canvas
        try TileInsertSlideChecks.expect(remounted.tileSelection.ids.isEmpty, "selection is ephemeral across remounts")
        print("multiselect move/resize/undo/cancel/rollback/reload zoom=\(zoom) auto=\(autoLayout) passed")
    }

    private static func capture(_ canvas: CanvasNSView) throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/tile-multiselect", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            canvas.appearance = NSAppearance(named: appearance)
            canvas.layoutSubtreeIfNeeded()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                throw TileInsertSlideChecks.Failure(message: "could not allocate \(name) capture")
            }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw TileInsertSlideChecks.Failure(message: "could not encode \(name) capture")
            }
            try data.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private static func crossProject() throws {
        typealias F = WorkspaceInvariantsFixture
        let fixture = try F(label: "multiselect-cross-project")
        defer { fixture.dispose() }
        try fixture.mount()
        let canvas = try fixture.requireMounted("cross-project").canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: true)
        canvas.setViewport(CanvasViewport(x: 400, y: 100, zoom: 0.5))
        let window = ZoneTruthChecks.hostInWindow(canvas)
        defer { window.orderOut(nil) }
        let ids: Set<UUID> = [F.noteA1a, F.noteA2a, F.noteA3a]
        func frames() -> [UUID: TileFrame] {
            Dictionary(uniqueKeysWithValues: canvas.allTilesInWorldFrames().map { ($0.id, $0.frame) })
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, shift: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func header(_ id: UUID) throws -> (TileNSView, NSPoint) {
            guard let view = canvas.tileView(for: id) else { throw F.Failure(message: "cross-project tile is not mounted") }
            let grabY = (view.resizeMarginInLocalCoordinates + view.grabHeightInLocalCoordinates) / 2
            return (view, view.convert(NSPoint(x: view.bounds.midX, y: grabY), to: nil))
        }
        let before = frames()
        for id in ids {
            let (view, p) = try header(id)
            view.mouseDown(with: mouse(.leftMouseDown, p, shift: true))
            view.mouseUp(with: mouse(.leftMouseUp, p, shift: true))
        }
        let (view, start) = try header(F.noteA1a)
        let end = NSPoint(x: start.x + 31.5, y: start.y - 14.5)
        view.mouseDown(with: mouse(.leftMouseDown, start))
        view.mouseDragged(with: mouse(.leftMouseDragged, end))
        view.mouseUp(with: mouse(.leftMouseUp, end))
        let moved = frames()
        for (id, original) in before {
            if ids.contains(id) {
                try TileInsertSlideChecks.expect(moved[id]?.x == original.x + 63 && moved[id]?.y == original.y + 29,
                                                 "cross-project group must preserve shared WORLD delta")
                try TileInsertSlideChecks.expect(canvas.installedZoneIds(containing: id) == [F.seed.tileZone[id]!],
                                                 "group move must keep source zone/project ownership")
            } else {
                try TileInsertSlideChecks.expect(moved[id] == original, "cross-project bystander must not move")
            }
        }
        fixture.drain()
        for project in [F.projectA1, F.projectA2] {
            guard let disk = fixture.readProjectFile(project).canvas?.tiles else {
                throw F.Failure(message: "project canvas is missing after group save")
            }
            let expectedIDs = ids.filter { F.seed.tileProject[$0] == project }
            let savedIDs = Set(disk.filter { ids.contains($0.id) }.map(\.id))
            try TileInsertSlideChecks.expect(savedIDs == expectedIDs, "group save must retain every selected project tile")
            for tile in disk where ids.contains(tile.id) {
                try TileInsertSlideChecks.expect(tile.frame == moved[tile.id], "each project store must persist WORLD frames")
            }
        }
        canvas.undo(nil)
        try TileInsertSlideChecks.expect(frames() == before, "one undo spans projects and zones")
        canvas.redo(nil)
        try TileInsertSlideChecks.expect(frames() == moved, "one redo spans projects and zones")

        canvas.setZoneCollapsed(true, zoneId: F.zoneA2)
        try TileInsertSlideChecks.expect(canvas.tileSelection.ids == [F.noteA1a, F.noteA3a],
                                         "collapsed members must leave the selection and its handles")

        // Deactivation cancels the model and the gesture owner together.
        let (cancelView, cancelStart) = try header(F.noteA1a)
        let cancelEnd = NSPoint(x: cancelStart.x + 40, y: cancelStart.y)
        cancelView.mouseDown(with: mouse(.leftMouseDown, cancelStart))
        cancelView.mouseDragged(with: mouse(.leftMouseDragged, cancelEnd))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        cancelView.mouseUp(with: mouse(.leftMouseUp, cancelEnd))
        try TileInsertSlideChecks.expect(frames() == moved, "deactivation must not let mouse-up recommit cancelled geometry")
        try fixture.switchTo(F.workspaceB)
        try TileInsertSlideChecks.expect(canvas.tileSelection.ids.isEmpty, "workspace switch clears ephemeral selection")
        print("multiselect cross-project/zone persistence, undo/redo, deactivation and workspace switch passed")
    }
}
