import AppKit
import ContinuumRevivedCore

/// Real tile gestures on a production-mounted, isolated workspace.
@MainActor
enum TileMultiselectChecks {
    static func run() throws {
        try selectionHoverAndPlacement()
        try groupPlacementInteractions()
        for zoom in [1.0, 0.35] {
            for autoLayout in [false, true] { try exercise(zoom: zoom, autoLayout: autoLayout) }
        }
        try adaptiveOutlineSpacing()
        try crossProject()
    }

    /// Selection lifts and separates the real tile views, while their persisted
    /// geometry stays put until a move/resize gesture commits a placement.
    private static func selectionHoverAndPlacement() throws {
        let fixture = try TileInsertSlideChecks.makeFixture("selection-hover")
        defer { fixture.dispose() }
        try fixture.mount()
        let mounted = try fixture.requireMounted("selection hover")
        let canvas = mounted.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: false)
        let suite = "selection-hover-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FocusBorderConfig.enabledKey)
        defaults.set(8, forKey: FocusBorderConfig.gapKey)
        canvas.focusBorderDefaults = defaults
        let window = ZoneTruthChecks.hostInWindow(canvas)
        defer { window.orderOut(nil) }
        let a = TileInsertSlideChecks.tileA, b = TileInsertSlideChecks.tileB
        let baseline = TileInsertSlideChecks.frames(canvas)
        let project = ProjectStore(projectRoot: fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!)
        let diskBaseline = try project.loadCanvas().tiles
        for zoom in [1.0, 0.35] {
            canvas.tileSelection.clear()
            canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: zoom))
            for id in [a, b] {
                guard let view = canvas.tileView(for: id) else {
                    throw TileInsertSlideChecks.Failure(message: "selection hover tile is missing")
                }
                let y = (view.resizeMarginInLocalCoordinates + view.grabHeightInLocalCoordinates) / 2
                let point = view.convert(NSPoint(x: view.bounds.midX, y: y), to: nil)
                func event(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.shift],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                view.mouseDown(with: event(.leftMouseDown))
                view.mouseUp(with: event(.leftMouseUp))
            }
            canvas.layoutSubtreeIfNeeded()
            try TileInsertSlideChecks.expect(canvas.tileSelection.ids == [a, b], "hover fixture selection failed")
            let visible = try [a, b].map { id -> CGRect in
                guard let view = canvas.tileView(for: id) else {
                    throw TileInsertSlideChecks.Failure(message: "selected hover view disappeared")
                }
                return view.convert(view.bounds, to: canvas)
            }
            for (index, id) in [a, b].enumerated() {
                let rect = visible[index]
                let headerPoint = NSPoint(x: rect.minX + 1, y: rect.minY + 12)
                try TileInsertSlideChecks.expect(canvas.tileId(at: headerPoint) == id,
                                                 "hovered protruding header must hit its displayed tile")
            }
            try TileInsertSlideChecks.expect(visible[1].minX - visible[0].maxX >= 18 - 0.01,
                                             "selection hover zoom=\(zoom): tile bodies must separate by 18 screen points, got \(visible)")
            let modelRects = [a, b].map { CanvasEngine.tileScreenFrame(baseline[$0]!, viewport: canvas.viewport) }
            let expectedY = modelRects.map(\.midY).reduce(0, +) / 2 - 4
            let actualY = visible.map(\.midY).reduce(0, +) / 2
            try TileInsertSlideChecks.expect(abs(actualY - expectedY) < 0.01,
                                             "selection hover zoom=\(zoom): selected bodies must lift 4 screen points, expected \(expectedY), got \(actualY)")
            try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == baseline,
                                             "temporary selection hover must not move tile models")
            let diskAfter = try project.loadCanvas().tiles
            try TileInsertSlideChecks.expect(diskAfter == diskBaseline,
                                             "temporary selection hover must not write tile geometry")
        }
        canvas.tileSelection.clear()
        print("selection hover: real views separated with a 4pt lift at zoom 1/0.35, models and disk unchanged")
    }

    private static func groupPlacementInteractions() throws {
        for autoLayout in [false, true] {
            let fixture = try TileInsertSlideChecks.makeFixture("group-placement")
            defer { fixture.dispose() }
            try fixture.mount()
            let canvas = try fixture.requireMounted("group placement").canvas
            TileInsertSlideChecks.pin(canvas, autoLayout: autoLayout)
            canvas.dragMagnetizeDefaults.set(!autoLayout, forKey: DragMagnetizeConfig.enabledKey)
            canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: 1))
            let window = ZoneTruthChecks.hostInWindow(canvas)
            defer { window.orderOut(nil) }
            let a = TileInsertSlideChecks.tileA, b = TileInsertSlideChecks.tileB
            func event(_ type: NSEvent.EventType, _ point: NSPoint, shift: Bool = false) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            func header(_ id: UUID) -> (TileNSView, NSPoint) {
                let view = canvas.tileView(for: id)!
                let y = (view.resizeMarginInLocalCoordinates + view.grabHeightInLocalCoordinates) / 2
                return (view, view.convert(NSPoint(x: view.bounds.midX, y: y), to: nil))
            }
            for id in [a, b] {
                let (view, point) = header(id)
                view.mouseDown(with: event(.leftMouseDown, point, shift: true))
                view.mouseUp(with: event(.leftMouseUp, point, shift: true))
            }
            let baseline = TileInsertSlideChecks.frames(canvas)
            let (view, start) = header(a)
            let delta = autoLayout ? NSPoint(x: 300, y: 0) : NSPoint(x: 561, y: 193)
            let end = NSPoint(x: start.x + delta.x, y: start.y - delta.y)
            view.mouseDown(with: event(.leftMouseDown, start))
            view.mouseDragged(with: event(.leftMouseDragged, end))
            if autoLayout {
                let preview = TileInsertSlideChecks.frames(canvas)
                try TileInsertSlideChecks.expect(preview[TileInsertSlideChecks.tileC] != baseline[TileInsertSlideChecks.tileC],
                                                 "group collision must push an unselected resident during preview")
                canvas.cancelOperation(nil)
                view.mouseUp(with: event(.leftMouseUp, end))
                try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == baseline,
                                                 "Escape must restore selected and pushed resident geometry")
                let (retryView, retryStart) = header(a)
                let retryEnd = NSPoint(x: retryStart.x + delta.x, y: retryStart.y - delta.y)
                retryView.mouseDown(with: event(.leftMouseDown, retryStart))
                retryView.mouseDragged(with: event(.leftMouseDragged, retryEnd))
                retryView.mouseUp(with: event(.leftMouseUp, retryEnd))
            } else {
                guard let ghost = canvas.qaDragGhostFrame else {
                    throw TileInsertSlideChecks.Failure(message: "group near resident C must show its magnetic destination")
                }
                view.mouseUp(with: event(.leftMouseUp, end))
                let result = TileInsertSlideChecks.frames(canvas)
                let committed = [a, b].map { CanvasEngine.tileScreenFrame(result[$0]!, viewport: canvas.viewport) }
                    .reduce(CGRect.null) { $0.union($1) }
                try TileInsertSlideChecks.expect(committed == ghost,
                                                 "group must commit exactly the magnetic ghost envelope")
                try TileInsertSlideChecks.expect(result[TileInsertSlideChecks.tileC] == baseline[TileInsertSlideChecks.tileC],
                                                 "magnetic group placement must leave resident geometry unchanged when auto layout is off")
            }
            let placed = TileInsertSlideChecks.frames(canvas)
            let dx = placed[a]!.x - baseline[a]!.x, dy = placed[a]!.y - baseline[a]!.y
            try TileInsertSlideChecks.expect(abs(placed[b]!.x - baseline[b]!.x - dx) < 0.001
                                             && abs(placed[b]!.y - baseline[b]!.y - dy) < 0.001,
                                             "group placement must preserve internal offsets")
            canvas.undo(nil)
            try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == baseline,
                                             "one undo must restore group and resident placement")
            canvas.redo(nil)
            try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == placed,
                                             "one redo must restore group and resident placement")
        }
        print("group placement: magnetic ghost commit, resident pushing, Escape and single undo/redo passed")
    }

    /// The rendered focus and selection paths must leave breathing room without
    /// selecting, zooming, or focusing becoming a layout/persistence operation.
    private static func adaptiveOutlineSpacing() throws {
        let fixture = try TileInsertSlideChecks.makeFixture("outline-spacing")
        defer { fixture.dispose() }
        let project = ProjectStore(projectRoot: fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!)
        var seed = try project.loadCanvas()
        seed.tiles.removeAll { $0.id == TileInsertSlideChecks.tileC || $0.id == TileInsertSlideChecks.tileD }
        try project.saveCanvas(seed)
        try fixture.mount()
        let mounted = try fixture.requireMounted("outline spacing")
        let canvas = mounted.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: false)
        let suite = "outline-spacing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FocusBorderConfig.enabledKey)
        defaults.set(8, forKey: FocusBorderConfig.gapKey)
        canvas.focusBorderDefaults = defaults
        let window = ZoneTruthChecks.hostInWindow(canvas)
        defer { window.orderOut(nil) }
        let a = TileInsertSlideChecks.tileA, b = TileInsertSlideChecks.tileB
        let baseline = TileInsertSlideChecks.frames(canvas)
        let diskBaseline = try project.loadCanvas().tiles
        func header(_ id: UUID) throws -> (TileNSView, NSPoint) {
            guard let view = canvas.tileView(for: id) else {
                throw TileInsertSlideChecks.Failure(message: "outline spacing tile missing")
            }
            let y = (view.resizeMarginInLocalCoordinates + view.grabHeightInLocalCoordinates) / 2
            return (view, view.convert(NSPoint(x: view.bounds.midX, y: y), to: nil))
        }
        func shiftSelect(_ id: UUID) throws {
            let (view, point) = try header(id)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.shift],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown))
            view.mouseUp(with: event(.leftMouseUp))
        }
        func focus(_ id: UUID) throws {
            AppDelegate.routeTileClickFocus(at: try header(id).1, in: canvas,
                                           focusBroker: mounted.delegate.qaFocusBroker)
            canvas.layoutSubtreeIfNeeded()
        }
        func bounds() throws -> [CGRect] {
            guard let focus = canvas.qaFocusBorderFrame,
                  let overlay = canvas.tileSelection.qaOverlay,
                  overlay.qaMemberRingBounds.count == 1 else {
                throw TileInsertSlideChecks.Failure(message: "group must show one focus and one member outline")
            }
            return ([focus] + overlay.qaMemberRingBounds).sorted { $0.minX < $1.minX }
        }
        func separated(_ label: String) throws {
            let rings = try bounds()
            try TileInsertSlideChecks.expect(rings[1].minX - rings[0].maxX >= 2 - 0.01,
                                             "\(label): rendered outline bounds cross or lose their 2pt gutter: \(rings)")
        }
        func capture(_ label: String) throws {
            let directory = URL(fileURLWithPath: "qa-runs/tile-multiselect", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            canvas.qaFreezeFocusBorder()
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                canvas.layoutSubtreeIfNeeded()
                canvas.displayIfNeeded()
                guard let image = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                    throw TileInsertSlideChecks.Failure(message: "outline spacing capture failed")
                }
                canvas.cacheDisplay(in: canvas.bounds, to: image)
                try image.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("outline-\(label)-\(name).png"))
            }
            window.appearance = nil
        }
        for zoom in [1.0, 0.35] {
            canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: zoom))
            canvas.tileSelection.clear()
            try focus(a)
            canvas.tileSelection.selectOnly(a)
            try shiftSelect(b)
            try TileInsertSlideChecks.expect(canvas.tileSelection.ids == [a, b], "outline fixture selection failed")
            try separated("close gap zoom=\(zoom)")
            try focus(b)
            try separated("focus moved zoom=\(zoom)")
            try capture("close-zoom\(zoom)")
            try TileInsertSlideChecks.expect(TileInsertSlideChecks.frames(canvas) == baseline,
                                             "selection/focus/zoom must not move tile models")
            let diskAfterSelection = try project.loadCanvas().tiles
            try TileInsertSlideChecks.expect(diskAfterSelection == diskBaseline,
                                             "selection/focus/zoom must not write tile frames")
        }
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: 1))
        guard var tile = canvas.tileRecord(for: b), let initial = baseline[b] else {
            throw TileInsertSlideChecks.Failure(message: "outline spacing B missing")
        }
        var wide = initial
        wide.x += 100
        tile.frame = canvas.tileFrame(fromWorldFrame: wide, tileId: b)
        canvas.updateTile(tile, recalculateZoneBounds: false, notifyChange: false)
        canvas.tileSelection.refresh()
        try focus(a)
        let wideBounds = try bounds()
        let bodyA = canvas.tileView(for: a)!.convert(canvas.tileView(for: a)!.bounds, to: canvas)
        let bodyB = canvas.tileView(for: b)!.convert(canvas.tileView(for: b)!.bounds, to: canvas)
        try TileInsertSlideChecks.expect(abs(wideBounds[0].maxX - bodyA.maxX - 8) < 0.01
                                         && abs(bodyB.minX - wideBounds[1].minX - 8) < 0.01,
                                         "distant tiles must recover their configured 8pt outline gap")
        var touching = initial
        touching.x = baseline[a]!.x + baseline[a]!.width
        tile.frame = canvas.tileFrame(fromWorldFrame: touching, tileId: b)
        canvas.updateTile(tile, recalculateZoneBounds: false, notifyChange: false)
        canvas.tileSelection.refresh()
        try focus(a)
        try separated("touching bodies")
        try capture("touching")

        func disjointVisibleStrokes(_ label: String, attention: UUID? = nil) throws {
            let primary = attention.flatMap { canvas.qaAttentionBorderVisibleStrokePath(for: $0) }
                ?? canvas.qaFocusBorderVisibleStrokePath
            guard let primary, let overlay = canvas.tileSelection.qaOverlay,
                  overlay.qaVisibleStrokePaths.count == 1 else {
                throw TileInsertSlideChecks.Failure(message: "\(label): expected one primary and one selected stroke")
            }
            try TileInsertSlideChecks.expect(primary.intersection(overlay.qaVisibleStrokePaths[0]).isEmpty,
                                             "\(label): visible outline strokes overlap after masking")
        }
        func placeB(_ world: TileFrame) {
            tile.frame = canvas.tileFrame(fromWorldFrame: world, tileId: b)
            canvas.updateTile(tile, recalculateZoneBounds: false, notifyChange: false)
            canvas.tileSelection.refresh()
        }
        let aFrame = baseline[a]!
        let overlap = TileFrame(x: aFrame.x + 120, y: aFrame.y + 40,
                                width: initial.width, height: initial.height)
        let nested = TileFrame(x: aFrame.x + 30, y: aFrame.y + 35, width: 100, height: 80)
        for (name, arrangement) in [
            ("vertical", TileFrame(x: aFrame.x + 40, y: aFrame.y + aFrame.height + 8,
                                   width: initial.width, height: initial.height)),
            ("diagonal", TileFrame(x: aFrame.x + aFrame.width + 3, y: aFrame.y + aFrame.height + 4,
                                   width: initial.width, height: initial.height))
        ] {
            placeB(arrangement)
            try focus(a)
            try disjointVisibleStrokes(name)
        }
        for (name, arrangement) in [("overlap", overlap), ("nested", nested)] {
            placeB(arrangement)
            try focus(a)
            try disjointVisibleStrokes("\(name) focus A")
            try focus(b)
            try disjointVisibleStrokes("\(name) focus B")
            try capture(name)
            canvas.updateAttentionBorder(for: b, status: .needsAttention)
            try TileInsertSlideChecks.expect(canvas.qaFocusBorderVisibleStrokePath == nil,
                                             "attention must replace the focused tile's ants")
            try disjointVisibleStrokes("\(name) attention B", attention: b)
            canvas.updateAttentionBorder(for: b, status: nil)
            try TileInsertSlideChecks.expect(canvas.qaAttentionBorderVisibleStrokePath(for: b) == nil,
                                             "cleared attention must remove its visible outline")
            try disjointVisibleStrokes("\(name) attention cleared")
        }
        // Removing group presentation restores the focused tile's configured
        // outset even if the unselected tile beneath it overlaps its body.
        canvas.tileSelection.clear()
        let ungroupedBody = CanvasEngine.tileScreenFrame(nested, viewport: canvas.viewport)
        try TileInsertSlideChecks.expect(canvas.qaFocusBorderFrame == ungroupedBody.insetBy(dx: -8, dy: -8),
                                         "clearing selection must restore the full focus outset")
        try TileInsertSlideChecks.expect(canvas.tileSelection.qaOverlay?.qaVisibleStrokePaths.isEmpty == true,
                                         "clearing selection must remove all member strokes")
        print("adaptive outline spacing: focus/member clearance, zoom, focus transfer, touching, overlap/nested masking, attention ownership, selection restoration, configured-gap recovery and unchanged selection geometry/disk passed")
    }

    private static func exercise(zoom: Double, autoLayout: Bool) throws {
        let fixture = try TileInsertSlideChecks.makeFixture("multiselect")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("multiselect")
        let canvas = m.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: autoLayout)
        canvas.dragMagnetizeDefaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
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
        try TileInsertSlideChecks.expect(canvas.qaCameraLayoutStats.tilesLaidOut <= (autoLayout ? 8 : 4),
                                         "group move plus hover normalization must keep presentation bounded")
        try TileInsertSlideChecks.expect(canvas.qaCameraLayoutStats.boundsWrites == 0,
                                         "group move must not resize native content")
        view.mouseUp(with: event(.leftMouseUp, destination))
        let after = TileInsertSlideChecks.frames(canvas)
        for id in [a, b] {
            let start = before[id]!, end = after[id]!
            let expectedDX = autoLayout ? after[a]!.x - before[a]!.x : 57
            let expectedDY = autoLayout ? after[a]!.y - before[a]!.y : 43
            try TileInsertSlideChecks.expect(abs(end.x - start.x - expectedDX) < 0.001
                                             && abs(end.y - start.y - expectedDY) < 0.001
                                             && end.width == start.width && end.height == start.height,
                                             "Shift-selected tile \(id) did not preserve shared placement: \(start) -> \(end)")
        }
        if !autoLayout {
            for id in [TileInsertSlideChecks.tileC, TileInsertSlideChecks.tileD] {
                try TileInsertSlideChecks.expect(before[id] == after[id], "unselected tile moved with auto layout disabled")
            }
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
            let sharedScale = resized[a]!.width / after[a]!.width
            let expectedX = after[a]!.x + (initial.x - after[a]!.x) * sharedScale
            try TileInsertSlideChecks.expect(sharedScale > 1
                                             && abs(actual.x - expectedX) < 0.001
                                             && abs(actual.width - initial.width * sharedScale) < 0.001
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
        TileInsertSlideChecks.pin(canvas, autoLayout: false)
        canvas.dragMagnetizeDefaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
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
