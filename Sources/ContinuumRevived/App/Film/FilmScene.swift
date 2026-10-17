// Film harness (.plans/68-launch-film/research/07-real-footage.md): the scene file.
//
// A scene is a staged workspace (projects, zones, tiles, all as WORLD geometry the
// stager writes before boot) plus a list of takes, each a timeline of actions on a
// fixed 60 fps film clock. Paths inside the scene resolve against the scene file's
// directory. Every UUID is derived from `scene.id + key`, so reruns are byte-stable.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ContinuumRevivedCore
import CryptoKit

struct FilmScene: Decodable {
    struct Window: Decodable { var width: Double; var height: Double }
    /// One CLI's frozen model catalogue. `catalog` is one of these (a claude entry, the
    /// original form) or a list, one per harness, so the palette's Agent rows and
    /// staged agents can be claude, codex AND pi. `harness`: "claude" (default) | "codex" | "pi".
    struct Catalog: Decodable {
        var harness: String?
        var model: String
        var displayName: String
        var contextWindow: Int?

        var agentHarness: AgentHarness? { FilmScene.harness(named: harness) }
    }
    struct Catalogs: Decodable {
        var entries: [Catalog]
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([Catalog].self) { entries = list; return }
            entries = [try container.decode(Catalog.self)]
        }
    }
    struct GitSetup: Decodable {
        /// Files overwritten AFTER the initial commit, so `git status` reports them
        /// modified: repo-relative path -> scene-relative source file.
        var modify: [String: String]?
    }
    struct Project: Decodable {
        var key: String
        var name: String
        /// Scene-relative directory copied into the project root.
        var files: String?
        var git: GitSetup?
        /// false: REGISTERED in the workspace (so the home-folder picker a marquee opens
        /// offers it) but placed in no zone; the scene draws its zone during a take.
        /// No staged zone may name it, and it cannot be the first (boot) project.
        var placed: Bool?
    }
    /// The static site on localhost:3000 (read by `scripts/film-capture.sh`): a path
    /// relative to the scene file (the original form), or a staged project's
    /// subfolder `{"project": "web", "path": "public"}`, served from the run's copy so
    /// a `write` into it is what the browser loads.
    enum Site: Decodable {
        case path(String)
        case project(key: String, path: String)

        private struct ProjectForm: Decodable { var project: String; var path: String? }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let path = try? container.decode(String.self) { self = .path(path); return }
            let form = try container.decode(ProjectForm.self)
            self = .project(key: form.project, path: form.path ?? ".")
        }
    }
    struct Zone: Decodable {
        var key: String
        var project: String
        var name: String
        /// WORLD rect [x, y, w, h].
        var rect: [Double]
        var color: String
    }
    struct Card: Decodable {
        var key: String
        var column: String
        var title: String
        var body: String?
    }
    struct BoardSpec: Decodable {
        var title: String?
        var columns: [String]
        var cards: [Card]
    }
    struct Tile: Decodable {
        var key: String
        /// terminal | browser | note | file | fileTree | kanban | agent
        var kind: String
        var zone: String
        /// ZONE-LOCAL [x, y, w, h]: offset from the zone's origin. The stager writes
        /// world = zone origin + this, because that is what `canvas.json` holds.
        var frame: [Double]
        var title: String?
        var path: String?
        var url: String?
        var body: String?
        var expanded: [String]?
        var board: BoardSpec?
        /// Agent tiles: the name the supervisor gives the agent.
        var name: String?
        /// Agent tiles: turn Array's workspace tools on for the agent after spawn,
        /// through the setter the tile menu's "Workspace Tools" item uses. Required by
        /// the `open` verb.
        var workspaceTools: Bool?
        /// Agent tiles: "claude" (default) | "codex" | "pi", the harness the agent is spawned
        /// on (its model is that harness's `catalog` entry). A codex agent's turns go
        /// through the production codex app-server translator as JSON-RPC
        /// notifications; it takes prompt, turn, say and `kind`/`title` tools
        /// (commandExecution, fileChange), never `think` (app-server maps no
        /// reasoning) or a runner-spelled `name`.
        var harness: String?
    }
    /// End state the witness (`--film-scene-check`) asserts after the last take.
    struct Expect: Decodable {
        /// card key -> column name.
        var cards: [String: String]?
        /// card key -> agent tile key.
        var assignees: [String: String]?
        /// agent tile key -> AgentStatus raw value.
        var agentStatus: [String: String]?
    }
    struct Take: Decodable {
        var name: String
        var frames: Int
        /// false: run lock-step but write nothing (off-camera setup).
        var capture: Bool?
        /// Time of day at the take's first frame, "H:MM" 24-hour ("8:45", "18:00").
        /// The film clock (`filmDate`, `filmSeconds`: elapsed readouts, turn stamps,
        /// transcript times, transient badges) jumps FORWARD to it; frame numbers and
        /// the capture never see the jump. Earlier takes run up to it, takes without a
        /// clock carry on from the one before, and a clock may never go backwards.
        var clock: String?
        var actions: [FilmAction]
    }

    var schema: String
    var id: String
    var window: Window
    var fps: Int?
    var video: String?
    /// "all", "none", or an integer N meaning every Nth frame (plus first/last).
    var png: FilmPNGPolicy?
    var catalog: Catalogs
    var site: Site?
    /// true: canvas auto-layout on (`-continuum.canvas.autoLayout.enabled YES`, and
    /// staged zones inherit it); absent/false: off, every staged frame is the shot.
    var autoLayout: Bool?
    var workspace: String
    /// Show the real workspace sidebar ("All agents" inbox) in the take. Absent: hidden.
    /// `scripts/film-capture.sh` turns it into `-continuum.workspaceSidebar.visible`.
    var sidebar: Bool?
    /// Sidebar width in points (default 300, clamped 220...420 like the app), applied as
    /// `-continuum.workspaceSidebar.width`, the production preference.
    var sidebarWidth: Double?
    /// "v2": camera, pan and zoom default to the `pan` curve, and a zoom pivots on its
    /// target (FilmCameraMath). Absent or "v1": the original defaults, unchanged.
    var cameraModel: String?
    var projects: [Project]
    var zones: [Zone]
    var tiles: [Tile]
    var takes: [Take]
    var expect: Expect?
    /// Streaming cadence: a `say`/`think` with a `dur` sends a delta every
    /// `fps / streamHz` frames, cut where the text has reached (token deltas, as a
    /// provider streams), instead of a whole word on every frame. 30 is production's
    /// presentation rate. Absent: the original word-per-frame stream.
    var streamHz: Int?
    /// true: every frame waits for the transcripts' host-local tool details (an actor
    /// hop away) to land before it is drawn, so a tool row's detail lands on its
    /// event's frame and the take is the same from capture to capture.
    var settleToolDetails: Bool?
    /// Every camera target except `all` must frame at least this zoom. Below 1x the
    /// app floors tile chrome at a screen-constant size, so a mid zoom reads as
    /// giant title bars over tiny content.
    var closeUpMinZoom: Double?

    /// Absolute directory the scene was loaded from.
    var directory: URL = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case schema, id, window, fps, video, png, catalog, site, autoLayout, workspace, sidebar, sidebarWidth, cameraModel, projects, zones, tiles, takes, expect, closeUpMinZoom, streamHz, settleToolDetails
    }

    static let schemaV1 = "array.film.scene.v1"

    static func load(_ url: URL) throws -> FilmScene {
        let data = try Data(contentsOf: url)
        var scene = try JSONDecoder().decode(FilmScene.self, from: data)
        guard scene.schema == schemaV1 else { throw FilmError("scene schema \(scene.schema) != \(schemaV1)") }
        scene.directory = url.deletingLastPathComponent().standardizedFileURL
        try scene.validate()
        return scene
    }

    func validate() throws {
        guard cameraModel == nil || ["v1", "v2"].contains(cameraModel!) else { throw FilmError("cameraModel \(cameraModel!)") }
        if let streamHz { guard streamHz > 0, streamHz <= framesPerSecond else { throw FilmError("streamHz \(streamHz): 1...\(framesPerSecond)") } }
        guard !catalog.entries.isEmpty else { throw FilmError("catalog is empty") }
        var harnesses = Set<AgentHarness>()
        for entry in catalog.entries {
            guard let harness = entry.agentHarness else { throw FilmError("catalog: unknown harness \(entry.harness ?? "")") }
            guard harnesses.insert(harness).inserted else { throw FilmError("catalog: two entries for \(harness.rawValue)") }
        }
        let projectKeys = Set(projects.map(\.key))
        let zoneKeys = Set(zones.map(\.key))
        for zone in zones where !projectKeys.contains(zone.project) || zone.rect.count != 4 {
            throw FilmError("zone \(zone.key): unknown project or bad rect")
        }
        for project in projects where project.placed == false {
            guard project.key != projects.first?.key else {
                throw FilmError("project \(project.key): the first project boots the canvas, so it must be placed")
            }
            if let zone = zones.first(where: { $0.project == project.key }) {
                throw FilmError("project \(project.key) is \"placed\": false, but zone \(zone.key) places it")
            }
        }
        if case let .project(key, path)? = site {
            guard project(key) != nil else { throw FilmError("site: unknown project \(key)") }
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw FilmError("site: path \(path) must be project-relative") }
        }
        var seen = Set<String>()
        for tile in tiles {
            guard seen.insert(tile.key).inserted else { throw FilmError("duplicate tile key \(tile.key)") }
            guard zoneKeys.contains(tile.zone), tile.frame.count == 4 else {
                throw FilmError("tile \(tile.key): unknown zone or bad frame")
            }
            guard FilmScene.tileKinds.contains(tile.kind) else { throw FilmError("tile \(tile.key): unknown kind \(tile.kind)") }
            if tile.workspaceTools != nil, tile.kind != "agent" { throw FilmError("tile \(tile.key): workspaceTools is for agent tiles") }
            if tile.harness != nil, tile.kind != "agent" { throw FilmError("tile \(tile.key): harness is for agent tiles") }
            if tile.kind == "agent" {
                guard let harness = FilmScene.harness(named: tile.harness) else { throw FilmError("tile \(tile.key): harness \(tile.harness ?? "")") }
                guard catalogEntry(harness) != nil else { throw FilmError("tile \(tile.key): no catalog entry for \(harness.rawValue)") }
                if harness != .claudeCode, tile.workspaceTools == true { throw FilmError("tile \(tile.key): workspace tools are staged for claude agents only") }
            }
        }
        // An opened or adopted tile's key names it for camera and pointer targets and
        // in `rects`, so it must be unique and must not shadow a staged tile or zone.
        // A bound card key must not shadow a staged card.
        var registered = Set<String>(), toolIds = Set<String>(), binds = Set<String>()
        let staged = stagedCardKeys
        for take in takes {
            for open in take.actions.compactMap(\.open) {
                guard registered.insert(open.as).inserted else { throw FilmError("take \(take.name): two actions register \(open.as)") }
                guard toolIds.insert(open.toolId).inserted else { throw FilmError("take \(take.name): toolId \(open.toolId) is reused") }
            }
            for adopt in take.actions.compactMap(\.adopt) {
                guard registered.insert(adopt.as).inserted else { throw FilmError("take \(take.name): two actions register \(adopt.as)") }
                guard tile(adopt.as) == nil, zone(adopt.as) == nil else { throw FilmError("take \(take.name): adopt as \(adopt.as) names a staged tile or zone") }
            }
            for bind in take.actions.compactMap({ $0.tool?.bind }) {
                guard binds.insert(bind).inserted, !staged.contains(bind) else { throw FilmError("take \(take.name): card key \(bind) is bound twice or names a staged card") }
            }
        }
        // The clock only moves forward: a take's clock is no earlier than the clock
        // the takes before it ran up to.
        var clockNow: Double?
        for take in takes {
            if let clock = take.clock {
                guard let seconds = FilmScene.clockSeconds(clock) else { throw FilmError("take \(take.name): clock \(clock) is not H:MM") }
                if let now = clockNow, seconds < now - 1e-6 {
                    throw FilmError("take \(take.name): clock \(clock) is earlier than the \(FilmScene.clockText(now)) the takes before it reach")
                }
                clockNow = seconds
            }
            if clockNow != nil { clockNow! += Double(take.frames) / Double(framesPerSecond) }
        }
        for take in takes {
            for action in take.actions {
                do { try action.validate(in: self) } catch {
                    throw FilmError("take \(take.name) action at \(action.at): \(error)")
                }
            }
            // One owner for the pointer per frame: two moves (or a move during a pinch,
            // a drag or a pan) would fight, and the later one silently wins.
            let owners = take.actions.filter(\.ownsPointer).sorted { $0.at < $1.at }
            for (a, b) in zip(owners, owners.dropFirst()) where b.at <= a.at + a.duration {
                throw FilmError("take \(take.name): \(b.verb) at \(b.at) overlaps \(a.verb) at \(a.at)-\(a.at + a.duration)")
            }
        }
    }

    /// A take drives the keyboard or the hover path (keys, ⌥ jumps, typing, hover,
    /// Settings, the bulk bar). `--film-scene-check` then boots it as the app boots: with
    /// its local event monitors installed and a window that can be key.
    var drivesRealInput: Bool {
        takes.contains { take in
            take.actions.contains { a in
                a.key != nil || a.hold != nil || a.type != nil || a.jump != nil || a.jumpZone != nil
                    || a.pointer?.hover == true || a.pointer?.to?.settings != nil || a.pointer?.to?.bulk != nil
                    || a.click?.mods != nil
            }
        }
    }

    var stagedCardKeys: Set<String> { Set(tiles.flatMap { $0.board?.cards.map(\.key) ?? [] }) }

    /// Staged cards plus the cards an agent's `array_board_apply` creates, bound under
    /// the tool's `bind` key.
    var cardKeys: Set<String> { stagedCardKeys.union(takes.flatMap { $0.actions.compactMap { $0.tool?.bind } }) }

    /// Keys the `open` verb registers for tiles production opens during the film.
    var openedKeys: Set<String> { Set(takes.flatMap { $0.actions.compactMap { $0.open?.as } }) }

    /// Every `adopt`, in timeline order.
    var adopts: [FilmAction.Adopt] { takes.flatMap { $0.actions.compactMap(\.adopt) } }

    /// What an adopted key names: a tile kind, "zone", or "agent" for an opened child.
    func adoptedKind(_ key: String) -> String? {
        adopts.first { $0.as == key }.map { $0.child != nil ? "agent" : ($0.kind ?? "") }
    }

    /// A staged tile or one an `open` or `adopt` registers.
    func knowsTile(_ key: String) -> Bool {
        tile(key) != nil || openedKeys.contains(key) || (adoptedKind(key).map { $0 != "zone" } ?? false)
    }

    func knowsZone(_ key: String) -> Bool { zone(key) != nil || adoptedKind(key) == "zone" }
    func knowsAgent(_ key: String) -> Bool { tile(key)?.kind == "agent" || adoptedKind(key) == "agent" }
    func knowsBoard(_ key: String) -> Bool { tile(key)?.kind == "kanban" || adoptedKind(key) == "kanban" }

    /// The harness an agent key runs on (staged `harness`, or the adopt's).
    func agentHarness(_ key: String) -> AgentHarness {
        let name = tile(key)?.harness ?? adopts.first { $0.as == key }?.harness
        return FilmScene.harness(named: name) ?? .claudeCode
    }

    func agentHasWorkspaceTools(_ key: String) -> Bool {
        tile(key)?.workspaceTools == true || adopts.first { $0.as == key }?.workspaceTools == true
    }

    static let tileKinds: Set<String> = ["terminal", "browser", "note", "file", "fileTree", "kanban", "agent"]

    /// "claude" (or absent) | "codex" | "pi".
    static func harness(named name: String?) -> AgentHarness? {
        switch name?.lowercased() {
        case nil, "claude", "claude code", "claudecode": return .claudeCode
        case "codex": return .codex
        case "pi": return .pi
        default: return nil
        }
    }

    func catalogEntry(_ harness: AgentHarness) -> Catalog? { catalog.entries.first { $0.agentHarness == harness } }

    /// "H:MM" (24-hour) -> seconds after midnight.
    static func clockSeconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m),
              parts[1].count == 2 else { return nil }
        return Double(h * 3600 + m * 60)
    }

    static func clockText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 3600 % 24, total / 60 % 60)
    }

    var framesPerSecond: Int { fps ?? 60 }

    var isCameraV2: Bool { cameraModel == "v2" }
    var showsSidebar: Bool { sidebar == true }
    /// The width the app is launched with (`WorkspaceSidebarConfig`'s clamp range).
    var resolvedSidebarWidth: Double {
        min(max(sidebarWidth ?? 300, WorkspaceSidebarConfig.minWidth), WorkspaceSidebarConfig.maxWidth)
    }

    /// The easing of a camera, pan, zoom or reveal action. An explicit `ease` always
    /// wins; otherwise cameraModel v2 uses `pan` everywhere, and v1 keeps its original
    /// defaults (`cam`; a drag pan `inOut`; a scroll pan `momentum`).
    func cameraCurve(for action: FilmAction) -> FilmCurve {
        if let explicit = action.zoom?.ease ?? action.pan?.ease ?? action.ease {
            return FilmCurve.named(explicit) ?? .bezier(.cam)
        }
        if isCameraV2 { return .bezier(.pan) }
        if let pan = action.pan { return pan.style == "drag" ? .bezier(.inOut) : .momentum }
        return .bezier(.cam)
    }

    /// One frozen snapshot per catalogued harness (`AgentModelCatalog.resetForQA`).
    var catalogSnapshots: [AgentHarnessCatalogSnapshot] {
        catalog.entries.compactMap { entry in
            entry.agentHarness.map { harness in
                AgentHarnessCatalogSnapshot(
                    harness: harness, readiness: .ready, models: [entry.model],
                    displayNames: [entry.model: entry.displayName],
                    contextWindows: entry.contextWindow.map { [entry.model: $0] } ?? [:],
                    defaultModel: entry.model)
            }
        }
    }

    func resolve(_ relative: String) -> URL {
        relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : directory.appendingPathComponent(relative)
    }

    func zone(_ key: String) -> Zone? { zones.first { $0.key == key } }
    func tile(_ key: String) -> Tile? { tiles.first { $0.key == key } }
    func project(_ key: String) -> Project? { projects.first { $0.key == key } }

    /// The world frame a tile is staged at.
    func worldFrame(of tile: Tile) -> TileFrame {
        let origin = zone(tile.zone).map { ($0.rect[0], $0.rect[1]) } ?? (0, 0)
        return TileFrame(x: origin.0 + tile.frame[0], y: origin.1 + tile.frame[1],
                         width: tile.frame[2], height: tile.frame[3])
    }

    func zoneRect(_ key: String) -> CGRect? {
        zone(key).map { CGRect(x: $0.rect[0], y: $0.rect[1], width: $0.rect[2], height: $0.rect[3]) }
    }

    // MARK: Deterministic ids

    /// RFC 4122 version-5 UUID over `scene.id/kind/key`.
    func uuid(_ kind: String, _ key: String) -> UUID {
        var bytes = Array(Insecure.SHA1.hash(data: Data("array.film/\(id)/\(kind)/\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    var workspaceId: UUID { uuid("workspace", "main") }
    func projectId(_ key: String) -> UUID { uuid("project", key) }
    func zoneId(_ key: String) -> UUID { uuid("zone", key) }
    func tileId(_ key: String) -> UUID { uuid("tile", key) }

    // MARK: Launch request

    /// `--film <scene.json>`; nil when the flag is absent.
    static var requestedPath: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--film"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// A film process: `--film`, or the `--film-scene-check` child (which stages a
    /// scene and drives it the same way), so every film-only production seam (the menu
    /// and picker hosts, the frozen web pages, the stub runner) is the film's in both.
    static var isRequested: Bool {
        requestedPath != nil || ProcessInfo.processInfo.environment["ARRAY_FILM_CHECK_ROOT"] != nil
    }

    static var requestedOutput: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--film-out"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

enum FilmPNGPolicy: Decodable, Equatable {
    case all, none, every(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Int.self) { self = n <= 1 ? .all : .every(n); return }
        switch try container.decode(String.self) {
        case "all": self = .all
        case "none": self = .none
        case let other: throw FilmError("png policy \(other)")
        }
    }

    func writes(frame: Int, last: Int) -> Bool {
        switch self {
        case .all: return true
        case .none: return false
        case let .every(n): return frame == 0 || frame == last || frame % n == 0
        }
    }
}

/// One timeline action. `at`/`dur` are frames relative to the take's start. Exactly
/// one verb field is set; `FilmDirector` owns their meaning.
struct FilmAction: Decodable {
    struct CameraTarget: Decodable {
        var zone: String?
        var zones: [String]?
        var tiles: [String]?
        var all: Bool?
        var rect: [Double]?
        var padding: Double?
    }
    struct Tool: Decodable {
        var id: String
        /// ItemKind raw value (commandExecution, fileChange, mcpToolCall, ...).
        var kind: String?
        var title: String?
        /// The RAW tool name a claude runner reports (`Read`, `Bash`,
        /// `mcp__array_workspace__array_canvas_query`). With it, the call is the
        /// runner's own stream-json `tool_use {name, input}` fed through the production
        /// claude translator, so the row is built from exactly what a live call carries;
        /// `kind`/`title`/`path`/... are then not used. An Array workspace tool is also
        /// really called through the host's MCP handler, and its reply is the
        /// tool_result `toolDone` reports.
        ///
        /// `input` strings may carry placeholders, substituted with the live ids when
        /// the call fires: `{agent:<key>}` (agent id), `{card:<key>}` (a staged or bound
        /// card), `{board:<key>}` (a staged or adopted kanban tile's board),
        /// `{column:<boardKey>/<Column name>}`; and `"expectedRevision": "auto"` becomes
        /// the current revision of the input's `boardId`.
        var name: String?
        var input: [String: WorkspaceMCPJSON]?
        /// `array_board_apply` with `op: create` only: the card the call created
        /// (the reply's `cardId`) is bound under this key, for later `{card:<key>}`
        /// placeholders, pointer `card` targets and `drag`s.
        var bind: String?
        var path: String?
        var action: String?
        var added: UInt?
        var removed: UInt?
        var command: String?
        var pattern: String?
        var output: String?
    }
    /// The board's own drag, driven BY the pointer: it presses where the pointer
    /// already is (move it onto the card first), carries the card along the pointer's
    /// eased path (`spring`/`ease`/`arc` as for `pointer`) and releases on the target.
    struct Drag: Decodable {
        var card: String
        var toAgent: String?
        var toColumn: String?
        var spring: String?
        var ease: String?
        var arc: Double?
    }
    /// A real mouse gesture (FilmInput.swift): leftMouseDown at the pointer's current
    /// position, one leftMouseDragged per frame as the pointer rides its eased path
    /// (`spring`/`ease`/`arc` as for `pointer`) to `to`, leftMouseUp there on the last
    /// frame. The events go through the app's own queue, so AppKit hit-tests the view
    /// exactly as for a user: on empty canvas a marquee (New Zone ghost past 24 pt, the
    /// home-folder picker on release), on a zone edge/corner band (`at`: right, bottom,
    /// bottomRight, ...) a resize with its size HUD, on a tile's title strip (`at`:
    /// header) a move. The action's `mods` are held throughout. Logs press + dragStart
    /// and drop + release.
    ///
    ///     {"at": 0, "dur": 50, "gesture": {"to": {"world": [2600, 900]}, "ease": "aim"}}
    struct Gesture: Decodable {
        var to: PointerTarget
        var spring: String?
        var ease: String?
        var arc: Double?
    }
    /// Where a pointer move ends. World-anchored targets (`tile`, `card`, `zone`,
    /// `world`) are re-resolved from the live views EVERY frame, so the pointer stays
    /// on them while the camera moves. `window` is [x, y] in top-left window points.
    struct PointerTarget: Decodable {
        var tile: String?
        var card: String?
        /// A staged or adopted zone, measured from its LIVE placement (it may have been
        /// resized or grown). `at`: header | center | [fx, fy] | an edge or corner
        /// (left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight: ON the
        /// border line, inside the 8 pt resize band) | overflow (the ⋯ button) | close.
        var zone: String?
        /// An agent tile key: that agent's row in the workspace sidebar, measured from
        /// the live cell every frame (`at`: center, [fx, fy], or nudge: the row's
        /// "Close" settle nudge, only while it shows); or "history": the History (N)
        /// heading (a delivered click opens or closes it). A closed agent's row is in
        /// History, so open History first. "<agent>/<toolUseId>" is a subagent's row
        /// that never got a tile of its own (a tile-less child cannot be adopted).
        var sidebar: String?
        /// A control in the open Settings panel (a child of the film window, see
        /// `FilmPanelHost`): "section.<Title>" (a sidebar section row, "section.Agents"),
        /// "agentSounds.master", or "agentSounds.<AgentSignalKind>.enabled|sound|preview"
        /// ("agentSounds.gitPushSucceeded.enabled": the Pushed checkbox).
        var settings: String?
        /// The sidebar's bulk-selection bar: "menu" (its actions button, which opens the
        /// command list), or an `InboxBulkAction` raw value ("archive"): that row in the
        /// open command list.
        var bulk: String?
        var window: [Double]?
        /// [x, y] WORLD point through the live camera (empty canvas, a marquee corner).
        var world: [Double]?
        /// The row titled exactly this in the open choice panel (the home-folder
        /// picker a marquee opens: a project name, "Add Project…").
        var choice: String?
        /// A subagent's chip in its parent's transcript: the parent's `Agent` tool_use id.
        var chip: String?
        /// [dx, dy] window points from where the pointer is when the move starts
        /// (small drifts during holds).
        var by: [Double]?
        /// "center" | "header" | "body" | [fx, fy] (fractions from the top-left); a tile
        /// also takes the edge/corner names (its resize ring) and "close" (title ✕); an
        /// agent tile "composer" (its prompt field: click, then `type`) and "send" (its
        /// Send button: a delivered click sends through production).
        var at: FilmAnchor?
    }
    /// `{"to": target, "spring"|"ease", "arc"}` moves over the action's `dur`;
    /// `{"mode": m}` sets the pointer's look (arrow|hand|grab|pinch|scroll).
    struct Pointer: Decodable {
        var to: PointerTarget?
        var spring: String?
        var ease: String?
        var arc: Double?
        var mode: String?
        /// Real `mouseMoved` events at the pointer on every frame of the move, so the
        /// app's tracking areas see it (the sidebar's row hover and hover card). After
        /// the first hover the pointer counts as inside the window, and every later
        /// `pointer` move sends them too.
        var hover: Bool?
        /// Frames to stay on the (live, re-resolved) target after the move, owning the
        /// pointer: `{"to": {"sidebar": "dark"}, "hover": true, "dwell": 40}`.
        var dwell: Int?
    }
    /// Press + release at the pointer over 6 frames. `deliver: true` also performs it:
    /// real leftMouseDown/leftMouseUp through the app's event queue (the window under
    /// the pointer, child panels first). `count: 2` is a double-click: down/up at
    /// frames 0/2 with clickCount 1, down/up at 3/5 with clickCount 2 (a zone header
    /// double-click starts its rename). The action's `mods` are held.
    ///
    /// With `dur` (> 5), a jump the click makes production navigate (a sidebar row
    /// click's reveal) glides over the rest of `dur` instead of cutting. `mods` here
    /// is the same as the action's own `mods` (⇧/⌘-click: the sidebar's multi-select).
    struct Click: Decodable {
        var deliver: Bool?
        var count: Int?
        var mods: [String]?
    }
    /// A pan never zooms: it centres `to` at the current zoom. `drag` is a hand grab
    /// through the canvas's own pointer-pan lifecycle; `scroll` is a trackpad pan
    /// (pointer still, camera on the momentum curve unless `ease` says otherwise).
    struct Pan: Decodable {
        var to: CameraTarget
        var style: String?
        var ease: String?
    }
    /// A pinch to `to`, interpolated in log-zoom about the transform's fixed point,
    /// where the pointer goes.
    struct Zoom: Decodable {
        var to: CameraTarget
        var ease: String?
    }
    /// The agent opens a checkout-relative file beside itself through Array's own
    /// workspace tool, as a claude runner does: `mcp__array_workspace__array_open_document`
    /// with `{relativePath: path}`. The tool row comes from the production claude
    /// translator, the tile from the production workspace API (placement included).
    /// `as` names the opened tile for later targets and in `rects`; the tool completes
    /// on the action's last frame (`dur`, default 0: the frame it opens).
    struct Open: Decodable {
        var path: String
        var `as`: String
        var toolId: String
    }
    struct BoardOp: Decodable {
        /// Advance an assigned card the way an accepted send does.
        var advance: String?
        var agent: String?
        var move: String?
        var column: String?
    }
    /// The menu production built and handed to `FilmMenuHost` instead of AppKit's
    /// tracking loop (a zone's ⋯ button, the palette's "Color This Zone…"): `choose` a
    /// title path (["Color", "Orange"]) and NSMenu performs that item's own action, or
    /// `dismiss` it. Recorded in frames.json `menus` for the overlay to draw.
    struct Menu: Decodable {
        var choose: [String]?
        var dismiss: Bool?
    }
    /// Names a tile production created during the take, for every later target, verb
    /// and `rects` entry. `kind` (a tile kind, or "zone"): the newest one of that kind
    /// no key names yet. `child` + `of`: the tile of the subagent the `of` agent's
    /// `Agent` tool_use `child` spawned (open it first: a chip click). An agent may
    /// also get its `name` (the inbox rename, `renameAgentFromInbox`) and
    /// `workspaceTools` (the tile menu's setter); `harness` declares a palette agent's
    /// harness for validation (default claude).
    ///
    ///     {"at": 0, "adopt": {"as": "planner", "kind": "agent", "name": "Planner", "workspaceTools": true}}
    struct Adopt: Decodable {
        var `as`: String
        var kind: String?
        var child: String?
        var of: String?
        var name: String?
        var workspaceTools: Bool?
        var harness: String?
    }
    /// Copies a scene file over a path in a staged project's root (the run's copy),
    /// with its mtime pushed ≥ 2 s past the old one (http.server never answers 304);
    /// an open file tile on that path reloads through its own `refreshFromDisk`.
    ///
    ///     {"at": 0, "write": {"project": "web", "path": "public/theme.css", "from": "edits/theme.css"}}
    struct Write: Decodable {
        var project: String
        var path: String
        var from: String
    }
    /// A browser tile: `reload` through `performReloadAction` (the ⌘R action), or
    /// `url` typed into its URL field (⌘L focus, real key events, Return); either
    /// waits (bounded) for the page to finish loading.
    struct Browser: Decodable {
        var tile: String
        var reload: Bool?
        var url: String?
    }
    /// Real scroll-wheel events at the pointer, to the window under it (its scroll view
    /// scrolls: the Settings panel's detail, the sidebar list), `by` [dx, dy] pixels in
    /// total over `dur` frames on the pointer's `ease` (positive dy shows what is above,
    /// negative what is below, as `scrollingDeltaY` reads). The pointer shows `scroll`.
    ///
    ///     {"at": 0, "dur": 24, "scroll": {"by": [0, -360]}}
    struct Scroll: Decodable {
        var by: [Double]
        var ease: String?
    }
    /// A setting the user changed off camera, written where Settings writes it (the
    /// launch's volatile argument domain: nothing persists). `agentHarness`: "claude" |
    /// "codex", the harness the ⌘K palette's Agent rows offer.
    struct Setting: Decodable {
        var agentHarness: String?
    }

    var at: Int
    var dur: Int?
    var mark: String?
    var ease: String?

    var camera: CameraTarget?
    var agent: String?
    /// With `agent`: route `say`/`tool`/`toolDone` to the subagent this agent's
    /// `Agent` tool_use `child` spawned, as claude stream-json frames carrying
    /// `parent_tool_use_id` (a child's prose arrives whole, as claude sends it).
    var child: String?
    var prompt: String?
    var turn: String?
    /// `turn: "start"` only: back-date the turn's start by this many seconds.
    var ago: Double?
    var say: String?
    var think: String?
    var tool: Tool?
    var open: Open?
    var toolDone: String?
    var status: String?
    var request: String?
    var requestKind: String?
    var resolve: String?
    var decision: String?
    var drag: Drag?
    var gesture: Gesture?
    var pointer: Pointer?
    var click: Click?
    /// A key press (keyDown + keyUp, wrapped in the modifiers' flagsChanged): one
    /// character ("k", "3", "K") or a name (Return, Escape, Tab, Space, Delete, up,
    /// down, left, right, Home, End). Held modifiers (`hold`) join `mods`. With `dur`,
    /// a reveal production makes while handling it (a ⌥ jump letter) is a v2 glide
    /// over `dur` instead of a cut.
    ///
    ///     {"at": 0, "key": "k", "mods": ["cmd"]}
    var key: String?
    /// A tile key: while ⌥ is held (`hold`), press the jump letter production's leader
    /// assigned THAT tile at that moment (`leaderJumpAssignments`), as a real key; with
    /// `dur`, production's reveal glides as for `key`.  `{"at": 40, "dur": 70, "jump": "subs"}`
    var jump: String?
    /// A zone key: while ⌥ is held, press the key production's leader assigned THAT
    /// zone (`leaderZoneJumpAssignments`: its digit, or its configured nav key), as a
    /// real key; with `dur`, the zone framing glides as for `jump`.
    /// `{"at": 30, "dur": 70, "jumpZone": "apiZone"}`
    var jumpZone: String?
    /// cmd | shift | option | control, for `key`, `gesture` and `click`.
    var mods: [String]?
    /// A modifier held from `at` to `at + dur` (flagsChanged down/up): "option" shows
    /// the jump labels.  `{"at": 0, "dur": 80, "hold": "option"}`
    var hold: String?
    /// Text typed one key at a time, spread over `dur` ("\n" is Return).
    /// `{"at": 0, "dur": 40, "type": "Storefront"}`
    var type: String?
    var menu: Menu?
    var adopt: Adopt?
    var write: Write?
    var browser: Browser?
    var scroll: Scroll?
    var setting: Setting?
    var pan: Pan?
    var zoom: Zoom?
    var board: BoardOp?
    var terminal: String?
    var text: String?
    var file: String?
    /// An agent tile key: what clicking its sidebar row does in production (selection,
    /// focus, read state), with the camera cut replaced by a cameraModel-v2 glide over
    /// `dur` to the viewport production would cut to. Author a pointer move onto the
    /// row and a `click` first, and put this on the click's release frame.
    var reveal: String?

    /// A click spans press (frame 0) to release (frame 5), or its `dur` when longer
    /// (a glide after it); a pointer move with `dwell` holds its target that long more.
    var duration: Int {
        if click != nil { return max(5, dur ?? 0) }
        return max(dur ?? 0, 0) + max(pointer?.dwell ?? 0, 0)
    }

    /// The modifiers a key, gesture or click holds: the action's `mods` plus a click's own.
    var allMods: [String]? {
        guard let own = click?.mods else { return mods }
        return (mods ?? []) + own
    }

    /// Pointer and input verbs run after every other verb on a frame, so a
    /// world-anchored target is resolved against the camera this frame commits.
    var isPointerVerb: Bool {
        pointer != nil || click != nil || drag != nil || gesture != nil || key != nil || jump != nil || jumpZone != nil
            || hold != nil || type != nil || menu != nil || scroll != nil
    }

    /// An input verb whose `dur` turns a jump it makes production navigate into a glide.
    var ownsNavigation: Bool { duration > 0 && (key != nil || jump != nil || jumpZone != nil || click?.deliver == true) }

    /// Moves (or pins) the pointer for its whole duration.
    var ownsPointer: Bool { pointer?.to != nil || drag != nil || zoom != nil || pan != nil || gesture != nil }

    var verbs: [String] {
        var all: [String] = []
        if camera != nil { all.append("camera") }
        if pan != nil { all.append("pan") }
        if zoom != nil { all.append("zoom") }
        if pointer != nil { all.append("pointer") }
        if click != nil { all.append("click") }
        if drag != nil { all.append("drag") }
        if gesture != nil { all.append("gesture") }
        if key != nil { all.append("key") }
        if jump != nil { all.append("jump") }
        if jumpZone != nil { all.append("jumpZone") }
        if hold != nil { all.append("hold") }
        if type != nil { all.append("type") }
        if menu != nil { all.append("menu") }
        if adopt != nil { all.append("adopt") }
        if write != nil { all.append("write") }
        if browser != nil { all.append("browser") }
        if scroll != nil { all.append("scroll") }
        if setting != nil { all.append("setting") }
        if board != nil { all.append("board") }
        if terminal != nil { all.append("terminal") }
        if prompt != nil { all.append("prompt") }
        if turn != nil { all.append("turn") }
        if say != nil { all.append("say") }
        if think != nil { all.append("think") }
        if tool != nil { all.append("tool") }
        if open != nil { all.append("open") }
        if toolDone != nil { all.append("toolDone") }
        if request != nil { all.append("request") }
        if resolve != nil { all.append("resolve") }
        if reveal != nil { all.append("reveal") }
        return all
    }

    var verb: String { verbs.first ?? "hold" }

    var label: String {
        var text = verb
        if let key { text += ":" + FilmInput.modifierSymbols(FilmInput.modifiers(allMods) ?? []) + key }
        if let hold { text += ":" + hold }
        if let jump { text += ":" + jump }
        if let jumpZone { text += ":" + jumpZone }
        if let agent { text += ":" + agent }
        if let child { text += "/" + child }
        if let terminal { text += ":" + terminal }
        if let reveal { text += ":" + reveal }
        if let adopt { text += ":" + adopt.as }
        return text
    }
}

enum FilmAnchor: Decodable, Equatable {
    case center, header, body
    /// An edge or corner of a zone or tile: ON its border line, inside the resize band.
    case edge(ResizeEdgeName)
    /// A zone's ⋯ button.
    case overflow
    /// A zone's ✕, or a tile's title-bar ✕.
    case close
    /// An agent tile's composer text field / its Send (Stop) button.
    case composer, send
    /// A browser tile's address field.
    case address
    /// A sidebar row's settle nudge ("Close").
    case nudge
    case fraction(Double, Double)

    enum ResizeEdgeName: String, CaseIterable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        /// The point on `rect`'s border (top-left space) this edge names.
        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let pair = try? container.decode([Double].self) {
            guard pair.count == 2 else { throw FilmError("anchor [fx, fy] needs two numbers") }
            self = .fraction(pair[0], pair[1]); return
        }
        let name = try container.decode(String.self)
        switch name {
        case "center": self = .center
        case "header": self = .header
        case "body": self = .body
        case "overflow": self = .overflow
        case "close": self = .close
        case "composer": self = .composer
        case "send": self = .send
        case "address": self = .address
        case "nudge": self = .nudge
        default:
            guard let edge = ResizeEdgeName(rawValue: name) else { throw FilmError("anchor \(name)") }
            self = .edge(edge)
        }
    }
}

extension FilmAction {
    /// Rejects anything the director could only half-perform: unknown keys, curves,
    /// modes or styles, two verbs on one action, a timed verb with no duration.
    func validate(in scene: FilmScene) throws {
        let verbs = self.verbs
        guard verbs.count <= 1 else { throw FilmError("one verb per action, got \(verbs.joined(separator: "+"))") }
        if ease != nil, FilmCurve.named(ease) == nil { throw FilmError("unknown ease \(ease!)") }
        guard FilmInput.modifiers(allMods) != nil else { throw FilmError("mods \(allMods ?? []): use cmd, shift, option, control") }
        if mods != nil, key == nil, gesture == nil, click == nil { throw FilmError("mods go with key, gesture or click") }
        if let dwell = pointer?.dwell, dwell < 0 || pointer?.to == nil { throw FilmError("pointer: dwell needs a target and dwell >= 0") }
        if pointer?.hover != nil, pointer?.to == nil { throw FilmError("pointer: hover needs a target") }
        if let camera { try FilmAction.validate(camera, in: scene) }
        if let pan {
            try FilmAction.validate(pan.to, in: scene)
            guard ["drag", "scroll"].contains(pan.style ?? "scroll") else { throw FilmError("pan style \(pan.style!)") }
            if pan.ease != nil, FilmCurve.named(pan.ease) == nil { throw FilmError("unknown ease \(pan.ease!)") }
            guard duration > 0 else { throw FilmError("pan needs dur > 0") }
        }
        if let zoom {
            try FilmAction.validate(zoom.to, in: scene)
            if zoom.ease != nil, FilmCurve.named(zoom.ease) == nil { throw FilmError("unknown ease \(zoom.ease!)") }
            guard duration > 0 else { throw FilmError("zoom needs dur > 0") }
        }
        if let pointer {
            guard (pointer.to != nil) != (pointer.mode != nil) else { throw FilmError("pointer takes exactly one of to/mode") }
            if let mode = pointer.mode, !FilmPointerMath.modes.contains(mode) { throw FilmError("pointer mode \(mode)") }
            if let target = pointer.to { try FilmAction.validate(target, in: scene) }
            guard FilmCurve.pointer(spring: pointer.spring, ease: pointer.ease) != nil else {
                throw FilmError("pointer curve \(pointer.spring ?? pointer.ease ?? "")")
            }
        }
        if let gesture {
            try FilmAction.validate(gesture.to, in: scene)
            guard FilmCurve.pointer(spring: gesture.spring, ease: gesture.ease) != nil else {
                throw FilmError("gesture curve \(gesture.spring ?? gesture.ease ?? "")")
            }
            guard duration > 0 else { throw FilmError("gesture needs dur > 0") }
        }
        if let click {
            guard [1, 2].contains(click.count ?? 1) else { throw FilmError("click count \(click.count!): 1 or 2") }
            if click.count == 2, click.deliver != true { throw FilmError("a double-click must deliver") }
        }
        if let key {
            guard FilmInput.key(named: key) != nil else { throw FilmError("key \(key)") }
        }
        if let hold {
            guard FilmInput.modifierNames[hold.lowercased()] != nil else { throw FilmError("hold \(hold): a modifier (cmd, shift, option, control)") }
            guard duration > 0 else { throw FilmError("hold needs dur > 0") }
        }
        if let type, type.isEmpty { throw FilmError("type: empty text") }
        if let scroll {
            guard scroll.by.count == 2 else { throw FilmError("scroll: by needs [dx, dy]") }
            guard FilmCurve.pointer(spring: nil, ease: scroll.ease) != nil else { throw FilmError("scroll: ease \(scroll.ease ?? "")") }
        }
        if let jump, !scene.knowsTile(jump) { throw FilmError("jump: unknown tile \(jump)") }
        if let jumpZone, !scene.knowsZone(jumpZone) { throw FilmError("jumpZone: unknown zone \(jumpZone)") }
        if let menu {
            guard (menu.choose != nil) != (menu.dismiss == true) else { throw FilmError("menu takes exactly one of choose/dismiss") }
            if let path = menu.choose, path.isEmpty || path.contains(where: \.isEmpty) { throw FilmError("menu: choose needs a title path") }
        }
        if let adopt {
            guard (adopt.kind != nil) != (adopt.child != nil) else { throw FilmError("adopt \(adopt.as): exactly one of kind / child") }
            if let kind = adopt.kind {
                guard FilmScene.tileKinds.contains(kind) || kind == "zone" else { throw FilmError("adopt \(adopt.as): kind \(kind)") }
                if kind != "agent", adopt.name != nil || adopt.workspaceTools != nil || adopt.harness != nil {
                    throw FilmError("adopt \(adopt.as): name/workspaceTools/harness are for agents")
                }
            }
            if adopt.child != nil {
                guard let of = adopt.of, scene.knowsAgent(of) else { throw FilmError("adopt \(adopt.as): child needs \"of\": an agent key") }
            }
            if let harness = adopt.harness {
                guard let named = FilmScene.harness(named: harness), scene.catalogEntry(named) != nil else {
                    throw FilmError("adopt \(adopt.as): harness \(harness) has no catalog entry")
                }
            }
        }
        if let write {
            guard let project = scene.project(write.project) else { throw FilmError("write: unknown project \(write.project)") }
            try FilmAction.checkoutRelative(write.path, "write")
            guard FileManager.default.fileExists(atPath: scene.resolve(write.from).path) else {
                throw FilmError("write: no file at \(write.from) for project \(project.key)")
            }
        }
        if let browser {
            guard scene.knowsTile(browser.tile) else { throw FilmError("browser: unknown tile \(browser.tile)") }
            if let kind = scene.tile(browser.tile)?.kind ?? scene.adoptedKind(browser.tile), kind != "browser" {
                throw FilmError("browser: \(browser.tile) is a \(kind) tile")
            }
            guard (browser.reload == true) != (browser.url != nil) else { throw FilmError("browser takes exactly one of reload/url") }
            if let url = browser.url, URL(string: url)?.scheme == nil { throw FilmError("browser: url \(url) needs a scheme") }
        }
        if let setting {
            guard let name = setting.agentHarness else { throw FilmError("setting: nothing to set") }
            guard let harness = FilmScene.harness(named: name), scene.catalogEntry(harness) != nil else {
                throw FilmError("setting: agentHarness \(name) has no catalog entry")
            }
        }
        // Agent verbs: the agent must exist, and a codex agent or a subagent child takes
        // only what its production stream can carry.
        let agentVerbs = ["prompt", "turn", "say", "think", "tool", "open", "toolDone", "request", "resolve"]
        if let key = agent, verbs.contains(where: agentVerbs.contains) {
            guard scene.knowsAgent(key) else { throw FilmError("\(verb): \(key) is not an agent") }
            if scene.agentHarness(key) == .pi {
                if open != nil { throw FilmError("open: \(key) is a pi agent; open is claude's workspace tool") }
                if let tool, tool.name == nil || tool.name!.hasPrefix(ArrayWorkspaceTool.mcpPrefix) {
                    throw FilmError("tool: \(key) is a pi agent; use a pi tool name (read, edit, write, bash, grep) with input")
                }
                if child != nil { throw FilmError("child: subagent routing is claude's") }
            }
            if scene.agentHarness(key) == .codex {
                if think != nil { throw FilmError("think: codex's app-server stream maps no reasoning, so \(key) cannot show it") }
                if tool?.name != nil || open != nil { throw FilmError("\(verb): \(key) is a codex agent; use kind/title tools") }
                if let kind = tool?.kind, !["commandExecution", "fileChange"].contains(kind) {
                    throw FilmError("tool: codex rows are commandExecution or fileChange, not \(kind)")
                }
            }
            if child != nil {
                guard say != nil || tool != nil || toolDone != nil else { throw FilmError("child: only say, tool and toolDone reach a subagent") }
                if tool != nil, tool?.name == nil { throw FilmError("child tool: needs a runner-spelled name") }
                if scene.agentHarness(key) == .codex { throw FilmError("child: subagent routing is claude's") }
            }
        } else if child != nil {
            throw FilmError("child needs an agent verb on its parent agent")
        }
        if ago != nil, turn != "start" { throw FilmError("ago goes with turn: start") }
        if let tool {
            if let name = tool.name {
                guard !name.isEmpty, tool.kind == nil, tool.title == nil else { throw FilmError("tool: name excludes kind/title") }
                guard let key = agent, scene.knowsAgent(key) else { throw FilmError("tool: name needs an agent tile") }
                if name.hasPrefix(ArrayWorkspaceTool.mcpPrefix) {
                    guard let bare = ArrayWorkspaceTool(toolName: name)?.rawValue, WorkspaceMCPToolCatalog.tool(named: bare) != nil else {
                        throw FilmError("tool: \(name) is not a tool the workspace MCP server offers")
                    }
                    guard scene.agentHasWorkspaceTools(key) else { throw FilmError("tool: agent \(key) needs \"workspaceTools\": true for \(name)") }
                }
                if tool.bind != nil {
                    guard ArrayWorkspaceTool(toolName: name) == .boardApply, case .string("create")? = tool.input?["op"] else {
                        throw FilmError("tool: bind goes with array_board_apply op create")
                    }
                }
                try FilmAction.validatePlaceholders(tool.input ?? [:], in: scene)
            } else {
                guard tool.kind != nil, tool.title != nil else { throw FilmError("tool: needs name, or kind and title") }
                guard tool.input == nil, tool.bind == nil else { throw FilmError("tool: input/bind need name") }
            }
        }
        if let open {
            guard let key = agent, scene.knowsAgent(key) else {
                throw FilmError("open needs \"agent\": an agent tile key")
            }
            guard scene.agentHasWorkspaceTools(key) else { throw FilmError("open: agent \(key) needs \"workspaceTools\": true") }
            try FilmAction.checkoutRelative(open.path, "open")
            guard !open.as.isEmpty, scene.tile(open.as) == nil else { throw FilmError("open: as \(open.as) is empty or names a staged tile") }
            guard !open.toolId.isEmpty else { throw FilmError("open: toolId is empty") }
            // The file must exist in the agent's checkout, or production refuses the open.
            if let spec = scene.tile(key), let project = scene.zone(spec.zone).flatMap({ scene.project($0.project) }),
               project.git?.modify?[open.path] == nil {
                guard let files = project.files,
                      FileManager.default.fileExists(atPath: scene.resolve(files).appendingPathComponent(open.path).path) else {
                    throw FilmError("open: \(open.path) is not in project \(project.key)'s files")
                }
            }
        }
        if let key = reveal {
            guard scene.knowsAgent(key) else { throw FilmError("reveal: \(key) is not an agent tile") }
            guard scene.showsSidebar else { throw FilmError("reveal needs \"sidebar\": true") }
            guard duration > 0 else { throw FilmError("reveal needs dur > 0") }
        }
        if let drag {
            guard scene.cardKeys.contains(drag.card) else { throw FilmError("drag: unknown card \(drag.card)") }
            guard (drag.toAgent != nil) != (drag.toColumn != nil) else { throw FilmError("drag takes exactly one of toAgent/toColumn") }
            if let agent = drag.toAgent, !scene.knowsAgent(agent) { throw FilmError("drag: \(agent) is not an agent tile") }
            guard FilmCurve.pointer(spring: drag.spring, ease: drag.ease) != nil else {
                throw FilmError("drag curve \(drag.spring ?? drag.ease ?? "")")
            }
            guard duration > 0 else { throw FilmError("drag needs dur > 0") }
        }
    }

    static func checkoutRelative(_ path: String, _ verb: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(".."), !components.contains("") else {
            throw FilmError("\(verb): path \(path) must be checkout-relative")
        }
    }

    /// Placeholders in a tool's input must name keys the scene has.
    static func validatePlaceholders(_ input: [String: WorkspaceMCPJSON], in scene: FilmScene) throws {
        func walk(_ value: WorkspaceMCPJSON) throws {
            switch value {
            case let .string(text):
                for (kind, key) in FilmPlaceholders.references(in: text) {
                    switch kind {
                    case "agent": guard scene.knowsAgent(key) else { throw FilmError("placeholder {agent:\(key)}: unknown agent") }
                    case "card": guard scene.cardKeys.contains(key) else { throw FilmError("placeholder {card:\(key)}: unknown card") }
                    case "board": guard scene.knowsBoard(key) else { throw FilmError("placeholder {board:\(key)}: unknown board") }
                    case "column":
                        let board = key.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                        guard key.contains("/"), scene.knowsBoard(board) else { throw FilmError("placeholder {column:\(key)}: needs <boardKey>/<Column name>") }
                    default: throw FilmError("placeholder {\(kind):\(key)}: unknown kind")
                    }
                }
            case let .array(items): for item in items { try walk(item) }
            case let .object(fields): for item in fields.values { try walk(item) }
            default: break
            }
        }
        for value in input.values { try walk(value) }
        if case let .string(text)? = input["expectedRevision"], text != "auto" {
            throw FilmError("expectedRevision: a number or \"auto\"")
        }
    }

    static func validate(_ target: CameraTarget, in scene: FilmScene) throws {
        for key in (target.zones ?? []) + (target.zone.map { [$0] } ?? []) where !scene.knowsZone(key) {
            throw FilmError("camera: unknown zone \(key)")
        }
        for key in target.tiles ?? [] where !scene.knowsTile(key) { throw FilmError("camera: unknown tile \(key)") }
        if let rect = target.rect, rect.count != 4 { throw FilmError("camera: rect needs four numbers") }
        guard target.all == true || target.zone != nil || !(target.zones ?? []).isEmpty
                || !(target.tiles ?? []).isEmpty || target.rect != nil else { throw FilmError("camera: empty target") }
    }

    static func validate(_ target: PointerTarget, in scene: FilmScene) throws {
        let set = [target.tile != nil, target.card != nil, target.zone != nil, target.sidebar != nil, target.window != nil,
                   target.by != nil, target.world != nil, target.choice != nil, target.chip != nil, target.settings != nil,
                   target.bulk != nil].filter { $0 }.count
        guard set == 1 else { throw FilmError("pointer target takes exactly one of tile/card/zone/sidebar/window/world/choice/chip/settings/bulk/by") }
        if let settings = target.settings {
            guard FilmSettingsTarget(settings) != nil else {
                throw FilmError("pointer: settings \(settings): section.<Title> | agentSounds.master | agentSounds.<kind>.enabled|sound|preview")
            }
        }
        if let bulk = target.bulk {
            guard scene.showsSidebar else { throw FilmError("pointer: a bulk target needs \"sidebar\": true") }
            guard bulk == "menu" || InboxBulkAction(rawValue: bulk) != nil else {
                throw FilmError("pointer: bulk \(bulk): menu | \(InboxBulkAction.allCases.map(\.rawValue).joined(separator: " | "))")
            }
        }
        if let key = target.sidebar {
            let parent = key.split(separator: "/", maxSplits: 1).first.map(String.init) ?? key
            guard scene.knowsAgent(parent) || key == "history" else { throw FilmError("pointer: sidebar \(key) is not an agent tile, <agent>/<toolUseId> or history") }
            guard scene.showsSidebar else { throw FilmError("pointer: a sidebar target needs \"sidebar\": true") }
            switch target.at ?? .center {
            case .center, .fraction: break
            case .nudge where key != "history": break
            default: throw FilmError("pointer: a sidebar row anchors at center|[fx, fy]|nudge")
            }
        }
        if let delta = target.by, delta.count != 2 { throw FilmError("pointer: by needs [dx, dy]") }
        if let point = target.world, point.count != 2 { throw FilmError("pointer: world needs [x, y]") }
        if let key = target.tile {
            guard scene.knowsTile(key) else { throw FilmError("pointer: unknown tile \(key)") }
            if case .overflow? = target.at { throw FilmError("pointer: overflow is a zone's") }
            if target.at == .nudge { throw FilmError("pointer: nudge is a sidebar row's") }
            if target.at == .composer || target.at == .send, !scene.knowsAgent(key) {
                throw FilmError("pointer: \(key) has no composer (not an agent tile)")
            }
            if target.at == .address, (scene.tile(key)?.kind ?? scene.adoptedKind(key)) != "browser" {
                throw FilmError("pointer: \(key) has no address field (not a browser tile)")
            }
        }
        if let key = target.card, !scene.cardKeys.contains(key) { throw FilmError("pointer: unknown card \(key)") }
        if let key = target.zone {
            guard scene.knowsZone(key) else { throw FilmError("pointer: unknown zone \(key)") }
            if target.at == .body || target.at == .composer || target.at == .send || target.at == .address || target.at == .nudge {
                throw FilmError("pointer: a zone anchors at header|center|an edge|overflow|close")
            }
        }
        if target.choice?.isEmpty == true || target.chip?.isEmpty == true { throw FilmError("pointer: empty choice/chip") }
        if target.at == .nudge, target.sidebar == nil { throw FilmError("pointer: nudge is a sidebar row's") }
        if target.at != nil, target.choice != nil || target.chip != nil || target.world != nil || target.window != nil || target.by != nil
            || target.settings != nil || target.bulk != nil {
            throw FilmError("pointer: at goes with tile, card, zone or sidebar")
        }
        if let point = target.window, point.count != 2 { throw FilmError("pointer: window needs [x, y]") }
    }
}

/// `{kind:key}` placeholders in tool input strings (`FilmAction.Tool.input`).
enum FilmPlaceholders {
    static let pattern = try! NSRegularExpression(pattern: #"\{(agent|card|board|column):([^{}]+)\}"#)

    static func references(in text: String) -> [(kind: String, key: String)] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let kind = Range(match.range(at: 1), in: text), let key = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[kind]), String(text[key]))
        }
    }

    /// Every placeholder in `text` replaced by `resolve(kind, key)`.
    static func substitute(_ text: String, _ resolve: (String, String) throws -> String) rethrows -> String {
        var result = ""
        var cursor = text.startIndex
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), let kind = Range(match.range(at: 1), in: text),
                  let key = Range(match.range(at: 2), in: text) else { continue }
            result += text[cursor..<whole.lowerBound]
            result += try resolve(String(text[kind]), String(text[key]))
            cursor = whole.upperBound
        }
        return result + text[cursor...]
    }
}

/// A `settings` pointer target, parsed: a Settings sidebar section row, or one of the
/// Agents → Sounds controls (`AgentSoundSettingsView`, identified by the signal kind).
enum FilmSettingsTarget: Equatable {
    case section(String)
    case soundsMaster
    case sound(AgentSignalKind, Part)

    enum Part: String { case enabled, sound, preview }

    init?(_ text: String) {
        if text.hasPrefix("section.") {
            let title = String(text.dropFirst("section.".count))
            guard !title.isEmpty else { return nil }
            self = .section(title); return
        }
        if text == "agentSounds.master" { self = .soundsMaster; return }
        let parts = text.split(separator: ".").map(String.init)
        guard parts.count == 3, parts[0] == "agentSounds", let kind = AgentSignalKind(rawValue: parts[1]),
              let part = Part(rawValue: parts[2]) else { return nil }
        self = .sound(kind, part)
    }
}

struct FilmError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
