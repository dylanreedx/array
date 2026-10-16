import AppKit
import ContinuumRevivedCore

/// The film's RST-42 shot: a card dragged out of a lane and released on an agent
/// tile that overlaps the board. The agent is ON TOP there, and the user is
/// dropping onto it, but `agentTile(under:)` refused any point inside the
/// board's bounds — so the release committed a lane move into the column hidden
/// behind the agent, no assignment happened, the composer never got its task,
/// and the Send that followed sent nothing at all.
///
/// Real views and real mouse events on the card; no window is ordered front.
@MainActor
enum BoardTaskDropChecks {
    static func run() throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "BoardTaskDrop", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            print("board-task-drop: PASS " + message)
        }
        let todo = BoardColumn(id: UUID(), name: "To Do", position: .fromLegacyRank(0))
        let doing = BoardColumn(id: UUID(), name: "Doing", position: .fromLegacyRank(1))
        let card = BoardCard(id: UUID(), columnId: todo.id, position: .fromLegacyRank(0),
                             title: "RST-42 Cart total is off by a cent", createdAt: Date(), updatedAt: Date())
        let board = Board(id: UUID(), title: "Storefront", columns: [todo, doing], cards: [card])
        func tile(_ kind: TileKind, x: Double, y: Double, width: Double, height: Double, z: Int) -> Tile {
            Tile(id: UUID(), kind: kind, title: "Fixture", frame: TileFrame(x: x, y: y, width: width, height: height),
                 zPosition: .fromLegacyRank(z), runtimeRef: nil, metadata: TileMetadata())
        }
        // The board's second lane sits UNDER the agent tile, as in the film.
        let boardTile = tile(.kanban, x: 30, y: 120, width: 700, height: 460, z: 1)
        let agentTile = tile(.managedAgent, x: 300, y: 40, width: 560, height: 460, z: 2)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                                          tiles: [], groups: [], lastActiveTileId: nil))
        let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        canvas.frame = NSRect(x: 40, y: 30, width: 1300, height: 820)
        host.addSubview(canvas)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let view = KanbanTileNSView(tile: boardTile, board: board)
        let agent = ManagedAgentTileNSView(tile: agentTile)
        canvas.install(tileView: view, for: boardTile)
        canvas.install(tileView: agent, for: agentTile)
        canvas.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        var assignments: [(UUID, UUID)] = []
        var commands: [BoardCommand] = []
        view.onAssignToAgent = { assignments.append(($0, $1)) }
        view.onCommand = { commands.append($0) }

        guard let rendered = view.cardView(for: card.id) else { throw NSError(domain: "BoardTaskDrop", code: 2) }
        rendered.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: TimeInterval(number),
                               windowNumber: window.windowNumber, context: nil, eventNumber: number,
                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let start = rendered.convert(NSPoint(x: 15, y: 15), to: nil)
        // The agent tile's centre: inside the board's bounds, with the agent on top.
        let centre = agent.convert(NSPoint(x: agent.bounds.midX, y: agent.bounds.midY), to: nil)
        try require(view.bounds.contains(view.convert(centre, from: nil)),
                    "fixture: the drop point lies inside the board's own bounds")
        var hit: NSView? = canvas.hitTest(canvas.superview!.convert(centre, from: nil))
        while let current = hit, !(current is ManagedAgentTileNSView) { hit = current.superview }
        try require(hit === agent, "fixture: the agent tile is the topmost view at the drop point")

        rendered.mouseDown(with: event(.leftMouseDown, start, 1))
        rendered.mouseDragged(with: event(.leftMouseDragged, centre, 2))
        try require(view.dragSession?.hoveredAgentTileId == agentTile.id,
                    "a card carried onto an agent tile that overlaps the board targets the agent")
        rendered.mouseUp(with: event(.leftMouseUp, centre, 3))
        try require(assignments.count == 1 && assignments[0] == (card.id, agentTile.id) && commands.isEmpty,
                    "releasing it there assigns the task and moves no card (assignments \(assignments.count), commands \(commands))")

        // Negative control: a point inside the board that no agent covers is
        // still a lane move, never an assignment.
        let lanePoint = view.convert(NSPoint(x: 60, y: view.bounds.height * 0.5), to: nil)
        rendered.mouseDown(with: event(.leftMouseDown, start, 4))
        rendered.mouseDragged(with: event(.leftMouseDragged, lanePoint, 5))
        try require(view.dragSession?.hoveredAgentTileId == nil,
                    "a point on the board that no agent covers does not target an agent")
        view.cancelCardDrag()
        try require(assignments.count == 1, "the lane drag assigned nothing")
    }
}
