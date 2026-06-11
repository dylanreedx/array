import AppKit
import ContinuumRevivedCore
import Foundation

/// Top-level canvas view: hosts tile subviews, owns the viewport, translates
/// world-space tile frames into AppKit subview frames, and routes pan/zoom
/// gestures to the underlying viewport. Flipped so the y-axis matches the
/// world-space convention (positive y = down).
@MainActor
final class CanvasNSView: NSView {
    weak var delegate: CanvasNSViewDelegate?
    var onFileURLDrop: ((String, CGPoint) -> Void)?
    /// Single-point hook for the app's tile-delete orchestrator. The canvas
    /// wires every installed tile's `onClose` to call this, so the app sets
    /// this once at startup rather than at every TileSpawner install site.
    var onTileCloseRequested: ((UUID) -> Void)?

    private(set) var canvasState: CanvasState
    private var tileViews: [UUID: TileNSView] = [:]
    private var emptyStateView: CanvasEmptyStateNSView?
    private var emptyStateActions: CanvasEmptyStateActions?
    private var emptyStateProjectPath: String?
    private(set) var emptyStateInstalled = false

    private var spaceHeld = false
    private var spaceDragLastWindowPoint: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(canvasState: CanvasState) {
        self.canvasState = canvasState
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        registerForDraggedTypes([.fileURL])
        updateEmptyStateVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Tile management

    func install(tileView: TileNSView, for tile: Tile) {
        // Replacing an existing tile (e.g. restart placeholder → live terminal)
        // must remove the old NSView; otherwise the prior view stays on top
        // of the new one and intercepts hits.
        if let existing = tileViews[tile.id] {
            existing.removeFromSuperview()
        }
        tileViews[tile.id] = tileView
        tileView.canvas = self
        let tileId = tile.id
        tileView.onClose = { [weak self] in
            self?.onTileCloseRequested?(tileId)
        }
        addSubview(tileView)
        layoutTile(tile)
        if let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) {
            canvasState.tiles[idx] = tile
        } else {
            canvasState.tiles.append(tile)
        }
        updateEmptyStateVisibility()
        reorderTileSubviewsByZIndex()
    }

    func configureEmptyStateActions(_ actions: CanvasEmptyStateActions, projectPath: String? = nil) {
        emptyStateActions = actions
        emptyStateProjectPath = projectPath
        emptyStateView?.actions = actions
        emptyStateView?.projectPath = projectPath
    }

    /// Returns the NSView currently registered for `tileId`, or nil. Intended
    /// for tests / smoke-test assertions that need to inspect tile-view kind
    /// (e.g. checking that a runtime-exit handler swapped to a placeholder).
    /// Callers must NOT retain the returned reference — the canvas may swap
    /// the underlying view at any time and a cached pointer will go stale.
    func tileView(for tileId: UUID) -> TileNSView? {
        tileViews[tileId]
    }

    func updateTile(_ tile: Tile) {
        guard let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        canvasState.tiles[idx] = tile
        layoutTile(tile)
        delegate?.canvasDidChange(self)
    }

    /// Remove a tile from the canvas: drops the NSView, the dictionary entry,
    /// and the model-side tile. Per-runtime cleanup (terminate PTY, kill
    /// WKWebView, flush note save, purge descriptor) is the caller's
    /// responsibility — `removeTile` is the canvas-side teardown only.
    func removeTile(id: UUID) {
        if let view = tileViews[id] {
            view.removeFromSuperview()
            tileViews.removeValue(forKey: id)
        }
        canvasState.tiles.removeAll { $0.id == id }
        if canvasState.lastActiveTileId == id {
            canvasState.lastActiveTileId = nil
        }
        updateEmptyStateVisibility()
        delegate?.canvasDidChange(self)
    }

    func markActive(tileId: UUID) {
        canvasState.lastActiveTileId = tileId
        delegate?.canvasDidChange(self)
    }

    func bringToFront(tileId: UUID) {
        let previousActiveTileId = canvasState.lastActiveTileId
        guard let target = canvasState.tiles.first(where: { $0.id == tileId }) else { return }
        let alreadyFrontmost = canvasState.tiles.allSatisfy { tile in
            tile.id == tileId || target.zIndex > tile.zIndex
        }

        canvasState.lastActiveTileId = tileId
        if alreadyFrontmost {
            if previousActiveTileId != tileId {
                delegate?.canvasDidChange(self)
            }
            return
        }

        canvasState.tiles = CanvasEngine.bringToFront(tileId: tileId, in: canvasState.tiles)
        for tile in canvasState.tiles {
            tileViews[tile.id]?.tile = tile
        }
        reorderTileSubviewsByZIndex()
        delegate?.canvasDidChange(self)
    }

    func setViewport(_ viewport: CanvasViewport) {
        canvasState.viewport = viewport
        layoutAllTiles()
        delegate?.canvasDidChange(self)
    }

    /// Returns the topmost tile id at a screen-space point according to the
    /// semantic canvas model, not AppKit subview insertion order.
    func tileId(at screenPoint: CGPoint) -> UUID? {
        CanvasEngine.hitTest(screenPoint: screenPoint, viewport: canvasState.viewport, tiles: canvasState.tiles)?.id
    }

    var viewport: CanvasViewport { canvasState.viewport }

    func emptyStateQASnapshot() -> CanvasEmptyStateNSView.QASnapshot? {
        emptyStateView?.qaSnapshot()
    }

    private func reorderTileSubviewsByZIndex() {
        let ordering = NSMutableDictionary()
        for (index, tile) in canvasState.tiles.enumerated() {
            ordering[tile.id.uuidString] = [tile.zIndex, index]
        }
        sortSubviews({ lhs, rhs, context in
            guard
                let ordering = context.map({ Unmanaged<NSMutableDictionary>.fromOpaque($0).takeUnretainedValue() }),
                let lhs = lhs as? TileNSView,
                let rhs = rhs as? TileNSView,
                let lhsInfo = ordering[lhs.tile.id.uuidString] as? [Int],
                let rhsInfo = ordering[rhs.tile.id.uuidString] as? [Int]
            else {
                return .orderedSame
            }
            let lhsZ = lhsInfo[0]
            let rhsZ = rhsInfo[0]
            if lhsZ != rhsZ { return lhsZ < rhsZ ? .orderedAscending : .orderedDescending }
            let lhsOrder = lhsInfo[1]
            let rhsOrder = rhsInfo[1]
            if lhsOrder == rhsOrder { return .orderedSame }
            return lhsOrder < rhsOrder ? .orderedAscending : .orderedDescending
        }, context: Unmanaged.passUnretained(ordering).toOpaque())
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutAllTiles()
        layoutEmptyState()
    }

    private func layoutAllTiles() {
        for tile in canvasState.tiles {
            layoutTile(tile)
        }
    }

    private func layoutTile(_ tile: Tile) {
        guard let view = tileViews[tile.id] else { return }
        let rect = CanvasEngine.tileScreenFrame(tile.frame, viewport: canvasState.viewport)
        view.frame = rect
        view.tile = tile
    }

    private func updateEmptyStateVisibility() {
        if canvasState.tiles.isEmpty {
            installEmptyStateIfNeeded()
        } else {
            uninstallEmptyStateIfNeeded()
        }
    }

    private func installEmptyStateIfNeeded() {
        guard emptyStateView == nil else { return }
        let view = CanvasEmptyStateNSView(actions: emptyStateActions, projectPath: emptyStateProjectPath)
        emptyStateView = view
        addSubview(view, positioned: .above, relativeTo: nil)
        emptyStateInstalled = true
        layoutEmptyState()
    }

    private func uninstallEmptyStateIfNeeded() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        emptyStateInstalled = false
    }

    private func layoutEmptyState() {
        emptyStateView?.frame = bounds
    }

    // MARK: - Pan / zoom gestures

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let cursor = convert(event.locationInWindow, from: nil)
            // Roughly +/- 10% per logical line of scroll. Smooth, non-linear.
            let factor = exp(event.scrollingDeltaY * 0.02)
            let next = CanvasEngine.zoom(canvasState.viewport, by: factor, anchorScreen: cursor)
            setViewport(next)
        } else {
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                dx *= 1
                dy *= 1
            } else {
                dx *= 16
                dy *= 16
            }
            var v = canvasState.viewport
            v.x -= Double(dx) / v.zoom
            v.y -= Double(dy) / v.zoom
            setViewport(v)
        }
    }

    /// Trackpad pinch entry point. The window-level magnify monitor in
    /// ContinuumApp routes here so pinches over a tile body still zoom the
    /// canvas (the tile content has no zoom of its own to compete with).
    func handlePinch(_ event: NSEvent) {
        let cursor = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + Double(event.magnification)
        guard factor > 0 else { return }
        let next = CanvasEngine.zoom(canvasState.viewport, by: factor, anchorScreen: cursor)
        setViewport(next)
    }

    override func mouseDown(with event: NSEvent) {
        if spaceHeld {
            // Space + drag pan: openHand → closedHand on press; pop on
            // mouseUp. Cursor stack restores cleanly even if the cursor
            // rect logic of subviews fights for control.
            NSCursor.closedHand.push()
            spaceDragLastWindowPoint = event.locationInWindow
            return
        }
        // Click on canvas background — deselect.
        canvasState.lastActiveTileId = nil
        delegate?.canvasDidChange(self)
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        if spaceHeld {
            let dx = event.locationInWindow.x - spaceDragLastWindowPoint.x
            let dy = event.locationInWindow.y - spaceDragLastWindowPoint.y
            spaceDragLastWindowPoint = event.locationInWindow
            var v = canvasState.viewport
            // Window y goes up, canvas y is flipped (down). Drag-down on the
            // trackpad/mouse should move the viewport down (revealing tiles
            // higher up), matching the trackpad scroll math in scrollWheel.
            v.x -= Double(dx) / v.zoom
            v.y += Double(dy) / v.zoom
            setViewport(v)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if spaceHeld {
            NSCursor.pop()
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Space (keyCode 49) starts hand-pan mode while held. We only see
        // this event when the canvas itself is first responder, so a Space
        // typed inside a note/terminal/url-bar still inserts a literal
        // space — no global hijack.
        if event.keyCode == 49 {
            if !spaceHeld {
                spaceHeld = true
                NSCursor.openHand.push()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceHeld {
            spaceHeld = false
            NSCursor.pop()
            return
        }
        super.keyUp(with: event)
    }

    static func runZIndexRelaunchHitTestSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let midId = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let topId = UUID(uuidString: "00000000-0000-0000-0000-000000000199")!
        let lowId = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let overlap = TileFrame(x: 100, y: 100, width: 300, height: 220)
        let seededTiles = [
            Tile(id: midId, kind: .note, title: "MID_FIRST", frame: overlap, zIndex: 5, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: topId, kind: .note, title: "TOP_MIDDLE", frame: overlap, zIndex: 99, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: lowId, kind: .note, title: "LOW_LAST", frame: overlap, zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        ]
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: viewport, tiles: seededTiles, groups: [], lastActiveTileId: nil))

        for tile in seededTiles {
            canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        }
        // Replacement install must not let the replaced/later low-z view jump above max z.
        canvas.install(tileView: DescriptorTileNSView(tile: seededTiles[2]), for: seededTiles[2])

        let modelOrder = canvas.canvasState.tiles.map(\.id)
        let visualOrder = canvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        let visualTopId = visualOrder.last
        let hitPoint = CGPoint(x: 150, y: 150)
        let semanticHitId = CanvasEngine.hitTest(screenPoint: hitPoint, viewport: viewport, tiles: canvas.canvasState.tiles)?.id
        let canvasHitId = canvas.tileId(at: hitPoint)

        try expect(modelOrder == seededTiles.map(\.id), "self-check must preserve seeded model array order")
        try expect(visualTopId == topId, "top AppKit subview should be max zIndex tile")
        try expect(semanticHitId == topId, "CanvasEngine hit-test should return max zIndex tile")
        try expect(canvasHitId == topId, "CanvasNSView tileId(at:) should return max zIndex tile")

        let manifest: [String: Any] = [
            "check": "zindex-relaunch-hit-test",
            "arrayOrder": seededTiles.map { $0.id.uuidString },
            "zIndices": Dictionary(uniqueKeysWithValues: seededTiles.map { ($0.id.uuidString, $0.zIndex) }),
            "visualSubviewOrder": visualOrder.map { $0.uuidString },
            "hitPoint": ["x": hitPoint.x, "y": hitPoint.y],
            "expectedTopId": topId.uuidString,
            "actualVisualTopId": visualTopId?.uuidString as Any,
            "actualCanvasEngineHitId": semanticHitId?.uuidString as Any,
            "actualCanvasViewHitId": canvasHitId?.uuidString as Any
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zindex-relaunch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBringToFrontFocusSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        final class SemanticTypingProbeView: NSView {
            let owner: String
            var typed = ""
            var mouseDownCount = 0
            var mouseUpCount = 0
            var stealFocusWhenAttached = false

            init(owner: String) {
                self.owner = owner
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) is not supported")
            }

            override var acceptsFirstResponder: Bool { true }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if stealFocusWhenAttached, let window {
                    window.makeFirstResponder(self)
                }
            }

            override func mouseDown(with event: NSEvent) {
                mouseDownCount += 1
                window?.makeFirstResponder(self)
            }

            override func mouseUp(with event: NSEvent) {
                mouseUpCount += 1
            }

            override func keyDown(with event: NSEvent) {
                typed += event.charactersIgnoringModifiers ?? ""
            }
        }

        final class ProbeTileNSView: TileNSView {
            let probe: SemanticTypingProbeView

            init(tile: Tile, owner: String) {
                self.probe = SemanticTypingProbeView(owner: owner)
                super.init(tile: tile)
                setContentView(probe)
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) is not supported")
            }
        }

        func owner(of responder: NSResponder?) -> String {
            (responder as? SemanticTypingProbeView)?.owner ?? String(describing: responder)
        }

        func dispatchMouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, in window: NSWindow) throws {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else {
                throw CheckError.failed("could not create mouse event \(type)")
            }
            window.sendEvent(event)
        }

        func dispatchKey(_ characters: String, in window: NSWindow) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ) else {
                throw CheckError.failed("could not create key event")
            }
            window.sendEvent(event)
        }

        let lowerId = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let upperId = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let lowerFrame = TileFrame(x: 80, y: 80, width: 320, height: 220)
        let upperFrame = TileFrame(x: 140, y: 80, width: 320, height: 220)
        let lower = Tile(id: lowerId, kind: .note, title: "LOWER_PROBE", frame: lowerFrame, zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        let upper = Tile(id: upperId, kind: .note, title: "UPPER_STEALS_ON_REATTACH", frame: upperFrame, zIndex: 10, runtimeRef: nil, metadata: TileMetadata())
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: viewport, tiles: [lower, upper], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 640, height: 480)

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        let lowerView = ProbeTileNSView(tile: lower, owner: "lower")
        let upperView = ProbeTileNSView(tile: upper, owner: "upper")
        canvas.install(tileView: lowerView, for: lower)
        canvas.install(tileView: upperView, for: upper)
        upperView.probe.stealFocusWhenAttached = true

        window.contentView?.layoutSubtreeIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        lowerView.layoutSubtreeIfNeeded()
        upperView.layoutSubtreeIfNeeded()

        let overlappedHitPoint = CGPoint(x: 180, y: 120)
        let lowerFocusWindowPoint = lowerView.convert(NSPoint(x: 20, y: TileNSView.titleBarHeight + 20), to: nil)
        try dispatchMouse(.leftMouseDown, at: lowerFocusWindowPoint, in: window)
        try dispatchMouse(.leftMouseUp, at: lowerFocusWindowPoint, in: window)

        let beforeVisualOrder = canvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        let semanticHitBefore = canvas.tileId(at: overlappedHitPoint)
        try expect(beforeVisualOrder.last == upperId, "precondition: upper tile should start visually top")
        try expect(semanticHitBefore == upperId, "precondition: upper tile should start semantic top at overlap")
        try expect(lowerView.probe.mouseDownCount == 1 && lowerView.probe.mouseUpCount == 1, "precondition: lower focus click should route through AppKit mouse dispatch")
        try expect(window.firstResponder === lowerView.probe, "precondition: lower probe should be first responder before bring-to-front")

        let beforeResponderOwner = owner(of: window.firstResponder)
        let beforeZ = Dictionary(uniqueKeysWithValues: canvas.canvasState.tiles.map { ($0.id.uuidString, $0.zIndex) })

        // Operation under test: production bring-to-front only. Do not call any
        // runtime/probe focus repair after this point; that would mask BUG-004.
        canvas.bringToFront(tileId: lowerId)

        let afterVisualOrder = canvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        let afterZ = Dictionary(uniqueKeysWithValues: canvas.canvasState.tiles.map { ($0.id.uuidString, $0.zIndex) })
        let afterResponderOwner = owner(of: window.firstResponder)
        let semanticHitAfter = canvas.tileId(at: overlappedHitPoint)
        let sentinel = "b"
        try dispatchKey(sentinel, in: window)

        try expect(canvas.canvasState.tiles.first(where: { $0.id == lowerId })?.zIndex == (canvas.canvasState.tiles.map(\.zIndex).max() ?? -1), "lower tile should have max zIndex after bring-to-front")
        try expect(afterVisualOrder.last == lowerId, "lower tile should be top AppKit subview after bring-to-front")
        try expect(semanticHitAfter == lowerId, "lower tile should be semantic hit-test top after bring-to-front")
        try expect(window.firstResponder === lowerView.probe, "first responder should remain lower semantic responder; got \(String(describing: window.firstResponder))")
        try expect(lowerView.probe.typed == sentinel, "typed sentinel should route to lower probe through window.sendEvent; got \(lowerView.probe.typed)")
        try expect(upperView.probe.typed.isEmpty, "upper probe should not receive sentinel; got \(upperView.probe.typed)")

        let manifest: [String: Any] = [
            "check": "bring-to-front-focus",
            "lowerTileId": lowerId.uuidString,
            "upperTileId": upperId.uuidString,
            "zIndicesBefore": beforeZ,
            "zIndicesAfter": afterZ,
            "visualSubviewOrderBefore": beforeVisualOrder.map { $0.uuidString },
            "visualSubviewOrderAfter": afterVisualOrder.map { $0.uuidString },
            "overlappedHitPoint": ["x": overlappedHitPoint.x, "y": overlappedHitPoint.y],
            "semanticHitBefore": semanticHitBefore?.uuidString as Any,
            "semanticHitAfter": semanticHitAfter?.uuidString as Any,
            "firstResponderOwnerBefore": beforeResponderOwner,
            "firstResponderOwnerAfter": afterResponderOwner,
            "preBringToFrontFocusMouseDispatch": [
                "windowPoint": ["x": lowerFocusWindowPoint.x, "y": lowerFocusWindowPoint.y],
                "lowerMouseDownCount": lowerView.probe.mouseDownCount,
                "lowerMouseUpCount": lowerView.probe.mouseUpCount
            ],
            "keyDispatch": "window.sendEvent(keyDown)",
            "sentinel": sentinel,
            "lowerTyped": lowerView.probe.typed,
            "upperTyped": upperView.probe.typed
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("bring-to-front-focus", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedFileURL(from: sender) else {
            return false
        }
        let screenPoint = convert(sender.draggingLocation, from: nil)
        let worldPoint = CanvasEngine.screenToWorld(screenPoint, viewport: canvasState.viewport)
        onFileURLDrop?(url.path, worldPoint)
        return true
    }

    private func draggedFileURL(from sender: NSDraggingInfo) -> URL? {
        guard let raw = sender.draggingPasteboard.string(forType: .fileURL) else {
            return nil
        }
        return URL(string: raw)
    }
}

@MainActor
protocol CanvasNSViewDelegate: AnyObject {
    func canvasDidChange(_ canvas: CanvasNSView)
}
