import AppKit
import ContinuumRevivedCore

/// Exercises real view geometry and pointer routes, without starting an agent.
@MainActor
enum BoardInteractionChecks {
    struct Failure: Error { let messages: [String] }

    static func run() throws {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            print("board-interaction: \(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures.append(message) }
        }
        let column = BoardColumn(id: UUID(), name: "To do", position: .fromLegacyRank(0))
        let secondColumn = BoardColumn(id: UUID(), name: "Doing", position: .fromLegacyRank(1))
        let card = BoardCard(id: UUID(), columnId: column.id, position: .fromLegacyRank(0),
                             title: "A task with enough context to wrap onto multiple lines in its lane",
                             body: "Task instructions", createdAt: Date(), updatedAt: Date())
        let board = Board(id: UUID(), title: "Tasks", columns: [column, secondColumn], cards: [card])
        func tile(_ kind: TileKind, _ x: Double, _ width: Double) -> Tile {
            Tile(id: UUID(), kind: kind, title: "Fixture", frame: TileFrame(x: x, y: 50, width: width, height: 450),
                 zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        }
        let boardTile = tile(.kanban, 30, 320)
        let agentTile = tile(.managedAgent, 450, 320)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                                          tiles: [], groups: [], lastActiveTileId: nil))
        let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 1800, height: 1100))
        // A large offset makes confusing canvas-local and parent coordinates observable.
        canvas.frame = NSRect(x: 210, y: 130, width: 1400, height: 850)
        host.addSubview(canvas)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let view = KanbanTileNSView(tile: boardTile, board: board)
        let agent = ManagedAgentTileNSView(tile: agentTile)
        canvas.install(tileView: view, for: boardTile)
        canvas.install(tileView: agent, for: agentTile)
        var assignments: [(UUID, UUID)] = []
        var menuAssignments: [(UUID, AgentID?)] = []
        var commands: [BoardCommand] = []
        view.onAssignToAgent = { assignments.append(($0, $1)) }
        let menuAgent = AgentID(rawValue: UUID())
        view.taskAgents = { [BoardAgentChoice(id: menuAgent, name: "Build agent", detail: "Current zone", tileID: agentTile.id)] }
        view.onTaskAssign = { menuAssignments.append(($0, $1)); return nil }
        view.onCommand = { commands.append($0) }

        for zoom in [1.0, 0.35] {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            let lane = view.allColumnViews[0]
            lane.layoutSubtreeIfNeeded()
            let rendered = view.cardView(for: card.id)!
            rendered.layoutSubtreeIfNeeded()
            let label = rendered.subviews.compactMap { $0 as? NSTextField }.first!
            let titlePoint = rendered.convert(NSPoint(x: label.frame.midX, y: label.frame.midY), to: rendered.superview)
            let assign = rendered.subviews.compactMap { $0 as? NSButton }.first!
            let assignPoint = rendered.convert(NSPoint(x: assign.frame.midX, y: assign.frame.midY), to: rendered.superview)
            expect(rendered.hitTest(assignPoint) === assign && assign.title.contains("Assign agent"), "unassigned control is visible and independently clickable at zoom \(zoom)")
            expect(rendered.qaAssigneeImageScaling == .scaleProportionallyDown && abs(rendered.qaAssigneeImageAspectRatio - 1) < 0.05,
                   "assignee symbol stays proportional at zoom \(zoom)")
            if zoom == 1 {
                let menu = rendered.qaContextItems
                expect(menu.map(\.title) == ["Open Details", "Move to…", "Assign to…", "Delete Task"] && menu.last?.destructive == true,
                       "right click exposes the complete custom task action menu")
                expect(rendered.qaMoveItems.map(\.title) == ["Task actions", "To do", "Doing"],
                       "move opens a custom destination menu")
                expect(rendered.qaAssignmentItems.map(\.title) == ["Task actions", "Unassigned", "Build agent"],
                       "assign opens a custom agent menu")
                window.orderFront(nil)
                let contextEvent = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: rendered.convert(NSPoint(x: 20, y: 20), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 40, clickCount: 1, pressure: 1)!
                rendered.rightMouseDown(with: contextEvent)
                expect(rendered.qaContextMenuIsPresented && rendered.qaPresentedContextItems.map(\.id) == ["open", "move", "assign", "delete"],
                       "a real right click presents Array's custom command surface")
                rendered.qaDismissContextMenu()
                rendered.qaPerformContextChoice("move:\(secondColumn.id.uuidString)")
                expect(commands.last == .moveCard(id: card.id, toColumn: secondColumn.id, after: nil, before: nil), "context menu moves task to the selected column")
                commands.removeAll()
                rendered.qaPerformContextChoice("assign:\(menuAgent.rawValue.uuidString)")
                expect(menuAssignments.last?.0 == card.id && menuAssignments.last?.1 == menuAgent, "context menu assigns task to the selected agent")
                rendered.qaPerformContextChoice("delete")
                expect(commands.last == .deleteCard(id: card.id), "context menu delete uses the undoable board command")
                commands.removeAll()
            }
            expect(rendered.hitTest(titlePoint) === rendered, "title click reaches card at zoom \(zoom)")
            expect(rendered.frame.height > KanbanCardView.minimumHeight, "wrapped title and metadata have room at zoom \(zoom)")
            let laneTop = lane.convert(lane.bounds, to: view).minY
            expect(abs(laneTop - max(view.contentTopInsetWorldHeight, view.grabHeightInLocalCoordinates)) < 1,
                   "lane starts below exactly one grab strip at zoom \(zoom)")
            let start = rendered.convert(NSPoint(x: 15, y: 15), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            rendered.mouseDown(with: down)
            expect(view.dragSession?.liftedView.isHidden == true && !rendered.isHidden,
                   "press selects without lifting or displacing the lane at zoom \(zoom)")
            let destination = agent.convert(NSPoint(x: 100, y: 150), to: nil)
            let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: destination, modifierFlags: [], timestamp: 1,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
            rendered.mouseDragged(with: drag)
            expect(view.dragSession?.hoveredAgentTileId == agentTile.id, "drag resolves agent through offset canvas at zoom \(zoom)")
            if let lifted = view.dragSession?.liftedView {
                expect(lifted.superview !== view && lifted.superview != nil, "carried card escapes tile clipping at zoom \(zoom)")
                let expected = view.convert(view.dragSession!.freePoint, to: canvas)
                let actual = lifted.convert(view.dragSession!.grabOffset, to: canvas)
                expect(hypot(expected.x - actual.x, expected.y - actual.y) < 1, "carried card keeps pointer offset at zoom \(zoom)")
            }
            let release = NSEvent.mouseEvent(with: .leftMouseUp, location: destination, modifierFlags: [], timestamp: 2,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
            NSApp.sendEvent(release)
            expect(assignments.last?.0 == card.id && assignments.last?.1 == agentTile.id && assignments.count == (zoom == 1 ? 1 : 2),
                   "release assigns once at zoom \(zoom)")
            expect(commands.isEmpty, "assignment does not reorder task at zoom \(zoom)")
            expect(view.dragSession == nil, "release cleans up drag at zoom \(zoom)")
            view.setFocusState(.none)
            rendered.mouseDown(with: down)
            view.cancelCardDrag()
            expect(view.dragSession == nil && assignments.count == (zoom == 1 ? 1 : 2) && commands.isEmpty,
                   "cancel has no assignment or model write at zoom \(zoom)")
            lane.layoutSubtreeIfNeeded()
            expect(!rendered.isHidden, "cancel restores source card at zoom \(zoom)")
            view.setFocusState(.none)
            rendered.mouseDown(with: down)
            rendered.mouseDragged(with: drag)
            view.updateDragPreview(freePoint: CGPoint(x: -500, y: -500))
            expect(view.dragSession?.target == nil && view.dragSession?.hoveredAgentTileId == nil,
                   "empty canvas offers no accidental lane move at zoom \(zoom)")
            NSApp.sendEvent(release)
            expect(commands.isEmpty && assignments.count == (zoom == 1 ? 1 : 2),
                   "dropping on empty canvas preserves task at zoom \(zoom)")
            view.setFocusState(.none)
        }
        var movedBoard = board
        movedBoard.cards[0].columnId = secondColumn.id
        view.setFocusState(.selected(card.id))
        view.render(movedBoard)
        expect(view.cardView(for: card.id)?.isSelected == true, "selection survives a move into a rebuilt lane")
        if !failures.isEmpty { throw Failure(messages: failures) }
    }
}
