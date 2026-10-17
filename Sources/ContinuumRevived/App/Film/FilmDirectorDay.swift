// Film harness: the director's "day" verbs (.plans/68-launch-film/research/18-full-day).
//
//  - gesture, key, hold, type: real input through the app's own event queue
//    (FilmInput.swift), recorded in frames.json `events` and `keys`;
//  - menu: the NSMenu production built, chosen through NSMenu's own action dispatch;
//  - adopt: names a tile or zone production created during the take;
//  - write, browser: a project file changes on disk, a browser tile reloads;
//  - setting: a preference changed off camera (the palette's agent harness);
//  - child: a claude subagent's own frames (`parent_tool_use_id`);
//  - codex: a codex agent's turn as app-server JSON-RPC notifications through the
//    production `CodexAppServerEventTranslator`;
//  - the film clock: per-take `clock`, and production waits (`filmDelay`) that end on
//    film time.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ContinuumRevivedCore
import WebKit

extension FilmDirector {
    // MARK: Gesture (real mouse drag)

    struct GesturePlan { var start: CGPoint; var window: NSWindow; var modifiers: NSEvent.ModifierFlags }

    /// Press at the pointer, one leftMouseDragged per frame along the eased path to the
    /// (live) target, release on the last frame, all through the app's queue: AppKit
    /// hit-tests the press and keeps the drag on the view that took it.
    func applyGesture(_ gesture: FilmAction.Gesture, action: FilmAction, key: String, local: Int) throws {
        if local == 0 {
            let plan = GesturePlan(start: pointer.point, window: targetWindow(),
                                   modifiers: (FilmInput.modifiers(action.mods) ?? []).union(heldModifiers))
            actionState[key] = plan
            pointer.down = true
            pointer.placed = true
            frameEvents += ["press", "dragStart"]
            if ProcessInfo.processInfo.environment["FILM_INPUT_DEBUG"] != nil, let content = plan.window.contentView {
                let local = plan.window.convertPoint(fromScreen: screenPoint(fromTopLeft: pointer.point))
                let hit = (content.superview ?? content).hitTest(local)
                log("gesture press at \(pointer.point): hit \(hit.map { "\(Swift.type(of: $0))" } ?? "nil") canvas \(canvas.convert(local, from: nil))")
            }
            postMouse(.leftMouseDown, clickCount: 1, modifiers: plan.modifiers, window: plan.window)
            return
        }
        guard let plan = actionState[key] as? GesturePlan else { return }
        let relative = gesture.to.by.map { CGPoint(x: Double(plan.start.x) + $0[0], y: Double(plan.start.y) + $0[1]) }
        guard let end = relative ?? resolve(gesture.to) else {
            warn(key, "gesture target \(gesture.to) is not rendered"); return
        }
        let curve = FilmCurve.pointer(spring: gesture.spring, ease: gesture.ease) ?? .bezier(.inOut)
        let eased = curve.value(Double(local) / Double(max(action.duration, 1)), duration: Double(action.duration) / fps)
        pointer.point = FilmPointerMath.path(from: plan.start, to: end, e: eased, arc: gesture.arc ?? FilmPointerMath.defaultArc)
        postMouse(.leftMouseDragged, clickCount: 1, modifiers: plan.modifiers, window: plan.window)
        if local >= action.duration {
            postMouse(.leftMouseUp, clickCount: 1, modifiers: plan.modifiers, window: plan.window)
            pointer.down = false
            frameEvents += ["drop", "release"]
        }
    }

    // MARK: Keys

    /// keyDown + keyUp wrapped in the chord's modifier transitions (those `hold` is not
    /// already keeping down), to the key window. With `dur`, a jump production makes
    /// while handling the key (a ⌥ jump letter or zone key: `navigateViewport`) is
    /// handed over through `filmNavigationCamera` and glided over the following frames
    /// (`advanceNavigationGlide`) instead of cut.
    func applyKey(_ name: String, action: FilmAction, key: String, local: Int) {
        guard local == 0, let pressed = FilmInput.key(named: name) else { return }
        let chord = FilmInput.modifiers(action.allMods) ?? []
        let target = NSApp.keyWindow ?? window
        var flags = heldModifiers
        let added = [NSEvent.ModifierFlags.control, .option, .shift, .command].filter { chord.contains($0) && !flags.contains($0) }
        for modifier in added {
            flags.insert(modifier)
            if let code = FilmInput.modifierKeyCodes[modifier.rawValue],
               let event = input.flagsEvent(code: code, flags: flags, window: target) { input.post(event) }
        }
        if let down = input.keyEvent(.keyDown, key: pressed, modifiers: flags, window: target) { input.post(down) }
        if let up = input.keyEvent(.keyUp, key: pressed, modifiers: flags, window: target) { input.post(up) }
        for modifier in added.reversed() {
            flags.remove(modifier)
            if let code = FilmInput.modifierKeyCodes[modifier.rawValue],
               let event = input.flagsEvent(code: code, flags: flags, window: target) { input.post(event) }
        }
        let label = FilmInput.modifierSymbols(chord.union(heldModifiers)) + pressed.cap
        frameKeys.append(["label": label, "kind": "press"])
    }

    /// Production opens the hold-⌥ leader after a dwell timed on the WALL clock
    /// (`AppDelegate.scheduleLeaderActivation`). A film steps frames faster or slower
    /// than real time, so a jump key a scene presses a few frames after ⌥ could reach
    /// the app before the leader opened (and type into whatever had focus). Wait,
    /// bounded, for production to open it; the frame does not advance meanwhile.
    func waitForLeader(_ key: String, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !canvas.navModeOverlayQASnapshot().isInstalled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !canvas.navModeOverlayQASnapshot().isInstalled { warn(key, "the hold-⌥ leader did not open within \(timeout)s") }
    }

    /// The jump letter production's leader assigned `tileKey` right now, pressed as
    /// a real key (so `handleLeaderKey` does the jump); the reveal glides as for `key`.
    func applyJump(_ tileKey: String, action: FilmAction, key: String, local: Int) {
        if local == 0 {
            let target = tileId(forKey: tileKey)
            let assignments = canvas.leaderJumpAssignments()
            guard let label = assignments.first(where: { $0.tileId == target })?.label else {
                warn(key, "jump \(tileKey): no jump label (is ⌥ held, the leader open, the tile visible and not the focused one?); labels: \(assignments.map(\.label))")
                return
            }
            actionState[key + "/label"] = label
            actionState[key + "/expected"] = canvas.framedViewportForTileJump(target)
            log("jump \(tileKey): label \(label)")
        }
        guard let label = actionState[key + "/label"] as? String else { return }
        applyKey(label, action: action, key: key, local: local)
    }

    /// The key production's leader assigned `zoneKey`'s zone right now (its digit, or
    /// its configured nav key), pressed as a real key while ⌥ is held, so
    /// `handleLeaderKey` makes the zone jump; the framing glides as for `key`.
    func applyJumpZone(_ zoneKey: String, action: FilmAction, key: String, local: Int) {
        if local == 0 {
            let zoneId = zoneId(forKey: zoneKey)
            let assignments = canvas.leaderZoneJumpAssignments()
            guard let label = assignments.first(where: { $0.zoneId == zoneId })?.key else {
                warn(key, "jumpZone \(zoneKey): no zone key (is ⌥ held and the leader open?); keys: \(assignments.map(\.key))")
                return
            }
            actionState[key + "/label"] = label
            actionState[key + "/expected"] = canvas.fitZoneToViewport(zoneId: zoneId)
            log("jumpZone \(zoneKey): key \(label)")
        }
        guard let label = actionState[key + "/label"] as? String else { return }
        applyKey(label, action: action, key: key, local: local)
    }

    /// A modifier held from `at` to `at + dur` (a flagsChanged each way): ⌥ arms the
    /// jump-label leader after its dwell.
    func applyHold(_ name: String, action: FilmAction, local: Int) {
        guard let flag = FilmInput.modifierNames[name.lowercased()], let code = FilmInput.modifierKeyCodes[flag.rawValue] else { return }
        let target = NSApp.keyWindow ?? window
        if local == 0 {
            heldModifiers.insert(flag)
            if let event = input.flagsEvent(code: code, flags: heldModifiers, window: target) { input.post(event) }
            frameKeys.append(["label": FilmInput.modifierSymbols(flag), "kind": "holdStart"])
        } else if local == action.duration {
            heldModifiers.remove(flag)
            if let event = input.flagsEvent(code: code, flags: heldModifiers, window: target) { input.post(event) }
            frameKeys.append(["label": FilmInput.modifierSymbols(flag), "kind": "holdEnd"])
        }
    }

    /// Characters typed one key at a time, character i on frame i * dur / n.
    func applyType(_ text: String, action: FilmAction, local: Int) {
        let characters = Array(text)
        let indices = characters.indices.filter { action.duration == 0 ? local == 0 : $0 * action.duration / characters.count == local }
        guard !indices.isEmpty else { return }
        let target = NSApp.keyWindow ?? window
        for index in indices {
            guard let pressed = FilmInput.key(for: characters[index]) else { continue }
            if let down = input.keyEvent(.keyDown, key: pressed, modifiers: [], window: target) { input.post(down) }
            if let up = input.keyEvent(.keyUp, key: pressed, modifiers: [], window: target) { input.post(up) }
        }
        let typed = String(characters[...indices.last!])
        frameKeys.append(["label": String(indices.map { characters[$0] }), "kind": "type", "text": typed])
    }

    // MARK: Menus

    /// `FilmMenuHost` hands the director the menu production built instead of running
    /// AppKit's tracking loop (which would draw it on a real display). The menu is
    /// validated as AppKit validates it before showing; its items are recorded for
    /// the overlay to draw at `anchor`.
    func presentMenu(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        menu.update()
        let anchor = topLeft(fromWindow: view.convert(point, to: nil))
        openMenu = (menu, anchor)
        frameMenus.append(["kind": "open", "title": menu.title, "anchor": [Double(anchor.x), Double(anchor.y)],
                           "items": Self.describe(menu)])
        log("menu open \"\(menu.title)\" at \(anchor): \(menu.items.map(\.title).filter { !$0.isEmpty })")
    }

    static func describe(_ menu: NSMenu) -> [[String: Any]] {
        menu.items.map { item in
            if item.isSeparatorItem { return ["separator": true] }
            var entry: [String: Any] = ["title": item.title, "enabled": item.isEnabled, "on": item.state == .on]
            if let submenu = item.submenu { submenu.update(); entry["submenu"] = describe(submenu) }
            return entry
        }
    }

    /// The chosen item's own action, dispatched by its menu (`performActionForItem`),
    /// exactly the message a click on it sends.
    func applyMenu(_ op: FilmAction.Menu) throws {
        guard let (root, anchor) = openMenu else { throw FilmError("menu: no menu is open") }
        openMenu = nil
        if op.dismiss == true {
            frameMenus.append(["kind": "dismiss", "anchor": [Double(anchor.x), Double(anchor.y)]])
            return
        }
        let path = op.choose ?? []
        var menu = root
        for (depth, title) in path.enumerated() {
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                throw FilmError("menu: no item \"\(title)\" in \"\(menu.title)\" (\(menu.items.map(\.title).filter { !$0.isEmpty }))")
            }
            let item = menu.items[index]
            if depth < path.count - 1 {
                guard let submenu = item.submenu else { throw FilmError("menu: \"\(title)\" has no submenu") }
                submenu.update()
                menu = submenu
                continue
            }
            guard item.isEnabled else { throw FilmError("menu: \"\(title)\" is disabled") }
            frameMenus.append(["kind": "choose", "anchor": [Double(anchor.x), Double(anchor.y)], "path": path])
            menu.performActionForItem(at: index)
            log("menu choose \(path.joined(separator: " > "))")
        }
    }

    // MARK: Adopt

    func applyAdopt(_ adopt: FilmAction.Adopt) throws {
        if let toolUseId = adopt.child, let of = adopt.of {
            guard let parent = agents[of] else { throw FilmError("adopt \(adopt.as): unknown agent \(of)") }
            let childId = AgentID(rawValue: AgentRecord.observedChildID(parentAgentID: parent.agentId.rawValue, toolUseID: toolUseId))
            guard let record = supervisor.records[childId] else { throw FilmError("adopt \(adopt.as): \(of) spawned no child for \(toolUseId)") }
            guard let tileId = record.tileId, canvas.tileView(for: tileId) != nil else {
                throw FilmError("adopt \(adopt.as): child \(toolUseId) has no tile yet (open it: click its chip)")
            }
            try registerAgent(adopt.as, tileId: tileId)
        } else if adopt.kind == "zone" {
            var known = Set(scene.zones.map { scene.zoneId($0.key) }).union(adoptedZones.values)
            known.formUnion(adoptedZones.values)
            guard let zone = delegate.filmWorkspaceRuntime?.document.zones.last(where: { !known.contains($0.zoneId) }) else {
                throw FilmError("adopt \(adopt.as): no new zone on the canvas")
            }
            adoptedZones[adopt.as] = zone.zoneId
            log("adopt \(adopt.as): zone \"\(zone.name)\" \(zone.zoneId) at \(zoneWorldRect(adopt.as).map { "\($0)" } ?? "?")")
            return
        } else if let kind = adopt.kind {
            let tileKind: TileKind = kind == "agent" ? .managedAgent : (TileKind(rawValue: kind) ?? .terminal)
            var known = Set(scene.tiles.map { scene.tileId($0.key) })
            known.formUnion(agents.values.map(\.tileId))
            known.formUnion(openedTiles.values)
            known.formUnion(adoptedTiles.values)
            let candidates = liveTiles().filter { $0.kind == tileKind && !known.contains($0.id) }
            // A spawn focuses its tile; otherwise the newest (topmost) one.
            let focused = canvas.canvasState.lastActiveTileId
            guard let tile = candidates.first(where: { $0.id == focused }) ?? candidates.max(by: { $0.zPosition < $1.zPosition }) else {
                let runtime = delegate.filmWorkspaceRuntime
                let zones = runtime?.document.zones.map { zone in
                    "\(zone.name) project \(zone.projectId.map { "\($0)" } ?? "nil") controller \(zone.projectId.flatMap { runtime?.controller(for: $0) } != nil)"
                } ?? []
                throw FilmError("adopt \(adopt.as): no new \(kind) tile on the canvas (active zone \(runtime?.document.lastActiveZoneId.map { "\($0)" } ?? "nil"); zones \(zones))")
            }
            if tileKind == .managedAgent {
                try registerAgent(adopt.as, tileId: tile.id)
            } else {
                adoptedTiles[adopt.as] = tile.id
                log("adopt \(adopt.as): \(kind) \"\(tile.title)\" \(tile.id) at \(tile.frame)\(adoptZoneNote(tile))")
                return
            }
        }
        guard let handle = agents[adopt.as] else { return }
        if let name = adopt.name, !delegate.renameAgentFromInbox(handle.agentId.rawValue, to: name) {
            throw FilmError("adopt \(adopt.as): rename to \(name) refused")
        }
        if adopt.workspaceTools == true { _ = supervisor.setWorkspaceToolsEnabled(agentID: handle.agentId, true) }
        delegate.filmRefreshAgentSurfaces()
    }

    /// The adopted tile's zone, for the adopt log: where a spawn landed and what it did
    /// to its zone is what a scene's later camera framing depends on.
    func adoptZoneNote(_ tile: Tile) -> String {
        guard let zoneId = tile.zoneId,
              let zone = delegate.filmWorkspaceRuntime?.document.zones.first(where: { $0.zoneId == zoneId }) else { return "" }
        return "; zone \"\(zone.name)\" now \(CanvasEngine.zoneWorldFrame(zone))"
    }

    /// Every tile with a live view on the canvas, whichever model (flat scene or a
    /// zone layer) owns it.
    func liveTiles() -> [Tile] {
        var tiles: [Tile] = []
        func walk(_ view: NSView) {
            if let tile = view as? TileNSView { tiles.append(tile.tile); return }
            view.subviews.forEach(walk)
        }
        walk(canvas)
        var seen = Set<UUID>()
        return tiles.filter { seen.insert($0.id).inserted }
    }

    /// A tile production made for an agent becomes a director agent handle.
    func registerAgent(_ key: String, tileId: UUID) throws {
        guard let view = canvas.tileView(for: tileId) as? ManagedAgentTileNSView else {
            throw FilmError("adopt \(key): tile \(tileId) is not a live agent tile")
        }
        guard let agentId = supervisor.agent(forTile: tileId) else {
            throw FilmError("adopt \(key): tile \(tileId) has no agent record (records \(supervisor.records.count))")
        }
        let zoneId = canvas.navigationTileSnapshot(for: tileId)?.zoneId ?? UUID()
        agents[key] = AgentHandle(tileId: tileId, agentId: agentId, zoneId: zoneId, threadId: view.wiringThreadId)
        log("adopt \(key): agent \(agentId.rawValue) \"\(supervisor.records[agentId]?.humanDisplayName ?? "")\" "
            + "(\(supervisor.records[agentId]?.harness?.rawValue ?? "?")) tile \(tileId)"
            + (liveTiles().first { $0.id == tileId }.map { " at \($0.frame)\(adoptZoneNote($0))" } ?? ""))
    }

    // MARK: Files and browser

    func applyWrite(_ write: FilmAction.Write) throws {
        guard let root = roots.projects[write.project] else { throw FilmError("write: no root for \(write.project)") }
        let target = root.appendingPathComponent(write.path)
        let fm = FileManager.default
        let old = (try? fm.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: scene.resolve(write.from)).write(to: target)
        // Last-Modified has whole-second precision: 2 s past the old stamp means a
        // conditional GET never gets a 304 for the new bytes.
        let stamp = max(Date(), (old ?? .distantPast).addingTimeInterval(2))
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: target.path)
        // An open editor on the file reloads the way its 1 s disk poll would, now.
        var refreshed = 0
        let resolved = target.resolvingSymlinksInPath().path
        for tile in liveTiles() where tile.kind == .file {
            let path = tile.metadata.documentLocation?.path ?? tile.metadata.filePath
            guard let path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path == resolved,
                  let view = canvas.tileView(for: tile.id) as? FileTileNSView else { continue }
            view.refreshFromDisk()
            refreshed += 1
        }
        log("write \(write.project)/\(write.path) <- \(write.from) (mtime \(stamp)); \(refreshed) open editor(s) refreshed")
    }

    func applyBrowser(_ op: FilmAction.Browser) throws {
        guard let view = canvas.tileView(for: tileId(forKey: op.tile)) as? BrowserTileNSView else {
            throw FilmError("browser: \(op.tile) is not a live browser tile")
        }
        if op.reload == true {
            view.performReloadAction()
        } else if let url = op.url {
            // ⌘L's focus, then the user's typing and Return through the field editor.
            view.focusURLField()
            let target = NSApp.keyWindow ?? window
            for character in url + "\n" {
                guard let pressed = FilmInput.key(for: character) else { continue }
                if let down = input.keyEvent(.keyDown, key: pressed, modifiers: [], window: target) { input.post(down) }
                if let up = input.keyEvent(.keyUp, key: pressed, modifiers: [], window: target) { input.post(up) }
            }
            frameKeys.append(["label": "⌘L", "kind": "press"])
        }
        pendingBrowserLoads[op.tile] = Date()
    }

    /// A frame that reloaded or navigated a browser waits (bounded) for the load to
    /// finish and paint, as `waitForTerminals` waits for Ghostty.
    func waitForBrowsers() async {
        guard !pendingBrowserLoads.isEmpty else { return }
        for (key, started) in pendingBrowserLoads {
            guard let web = browserWebView(key) else { continue }
            let deadline = started.addingTimeInterval(5)
            var sawLoading = web.isLoading
            while Date() < deadline {
                if web.isLoading { sawLoading = true }
                if !web.isLoading, sawLoading || Date().timeIntervalSince(started) > 0.5 { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if web.isLoading { log("WARN browser \(key): still loading after 5s") }
            // WebKit paints in its own process; give the new page two refreshes.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        pendingBrowserLoads.removeAll()
    }

    // MARK: Settings

    /// Written to the launch's volatile argument domain, where every
    /// `UserDefaults.standard` read sees it first and nothing persists.
    func applySetting(_ setting: FilmAction.Setting) {
        guard let name = setting.agentHarness, let harness = FilmScene.harness(named: name) else { return }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[AgentHarnessConfig.key] = harness.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        log("setting \(AgentHarnessConfig.key) = \(harness.rawValue) (now \(AgentHarnessConfig.resolved().rawValue))")
    }

    // MARK: Placeholders and bound cards

    /// A tool's input with `{agent:..}`, `{card:..}`, `{board:..}`, `{column:..}` and
    /// `"expectedRevision": "auto"` resolved against the live canvas.
    func resolvedInput(_ tool: FilmAction.Tool) throws -> [String: Any] {
        guard let input = tool.input else { return [:] }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any] ?? [:]
        func walk(_ value: Any) throws -> Any {
            if let text = value as? String { return try FilmPlaceholders.substitute(text, placeholder) }
            if let list = value as? [Any] { return try list.map(walk) }
            if let fields = value as? [String: Any] { return try fields.mapValues(walk) }
            return value
        }
        var resolved = try object.mapValues(walk)
        if (resolved["expectedRevision"] as? String) == "auto" {
            guard let raw = resolved["boardId"] as? String, let boardId = UUID(uuidString: raw), let view = boardView(boardId: boardId) else {
                throw FilmError("tool \(tool.id): expectedRevision auto needs a live boardId")
            }
            let revision = boardRuntime(for: view)?.board(id: boardId)?.revision ?? view.board.revision
            resolved["expectedRevision"] = Int(revision)
        }
        return resolved
    }

    func placeholder(_ kind: String, _ key: String) throws -> String {
        switch kind {
        case "agent":
            guard let agent = agents[key] else { throw FilmError("{agent:\(key)}: no such agent yet") }
            return agent.agentId.rawValue.uuidString
        case "card":
            return try boardContext(cardKey: key).cardId.uuidString
        case "board":
            guard let view = boardView(key: key) else { throw FilmError("{board:\(key)}: no live board") }
            return view.board.id.uuidString
        case "column":
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let view = boardView(key: parts[0]),
                  let column = view.board.orderedColumns.first(where: { $0.name == parts[1] }) else {
                throw FilmError("{column:\(key)}: no such column on a live board")
            }
            return column.id.uuidString
        default:
            throw FilmError("placeholder {\(kind):\(key)}")
        }
    }

    /// The card a `board_apply` create made, from the workspace API's reply.
    func bindCreatedCard(_ key: String, answer: [String: Any], input: [String: Any]) throws {
        let result = answer["result"] as? [String: Any]
        guard let card = (result?["cardId"] as? String).flatMap(UUID.init(uuidString:)),
              let board = ((result?["boardId"] as? String) ?? (input["boardId"] as? String)).flatMap(UUID.init(uuidString:)) else {
            throw FilmError("bind \(key): the reply names no created card: \(answer)")
        }
        boundCards[key] = (board, card)
        log("bind card \(key) = \(card)")
    }

    // MARK: Subagents (claude child frames)

    /// A child's work as claude streams it: whole `assistant`/`user` frames carrying
    /// `parent_tool_use_id`, through the parent's translator and the child channel.
    func applyChild(_ toolUseId: String, parentKey: String, parent: AgentHandle, action: FilmAction, key: String, local: Int) throws {
        guard local == 0 else { return }
        if let text = action.say {
            try feedClaude(["type": "assistant", "parent_tool_use_id": toolUseId,
                            "message": ["content": [["type": "text", "text": text]]]], agentKey: parentKey, agent: parent)
        } else if let tool = action.tool, let name = tool.name {
            try feedClaude(["type": "assistant", "parent_tool_use_id": toolUseId, "message": ["content": [[
                "type": "tool_use", "id": tool.id, "name": name, "input": try resolvedInput(tool),
            ]]]], agentKey: parentKey, agent: parent)
            actionState["childTool/\(parentKey)/\(tool.id)"] = tool.output ?? ""
        } else if let toolId = action.toolDone {
            let reply = actionState["childTool/\(parentKey)/\(toolId)"] as? String ?? ""
            try feedClaude(["type": "user", "parent_tool_use_id": toolUseId, "message": ["content": [[
                "type": "tool_result", "tool_use_id": toolId, "is_error": action.status == "failed",
                "content": [["type": "text", "text": reply]],
            ]]]], agentKey: parentKey, agent: parent)
        }
        delegate.filmRefreshAgentSurfaces()
    }

    // MARK: Codex (app-server notifications)

    /// A codex agent's turn as the JSON-RPC notifications `codex app-server` sends,
    /// through the production translator: `turn/started`, `item/agentMessage/delta`,
    /// `item/started` / `item/completed` (commandExecution, fileChange), `turn/completed`.
    func applyCodex(_ agentKey: String, action: FilmAction, key: String, local: Int) throws {
        guard var agent = agents[agentKey] else { throw FilmError("unknown agent \(agentKey)") }
        defer { agents[agentKey] = agent }
        let thread = "film-codex-\(agentKey)"
        let turnId = agent.turnId ?? "film-codex-turn"
        if let text = action.say {
            if local == 0 { actionState["\(key)/item"] = "msg-\(agentKey)-\(action.at)-\(globalFrame)" }
            let item = actionState["\(key)/item"] as? String ?? "msg"
            let characters = Array(text)
            let sent = (actionState[key] as? Int) ?? 0
            guard let target = streamTarget(characters, action: action, local: local, sent: sent) else { return }
            try feedCodex(["method": "item/agentMessage/delta", "params": [
                "threadId": thread, "turnId": turnId, "itemId": item, "delta": String(characters[sent..<target]),
            ]], agentKey: agentKey, agent: agent)
            actionState[key] = target
            return
        }
        guard local == 0 else { return }
        if let prompt = action.prompt {
            agentView(agentKey)?.appendUserPrompt(prompt)
        } else if let turn = action.turn {
            switch turn {
            case "start":
                if agent.turnCount == 0 {
                    try feedCodex(["method": "thread/started", "params": ["thread": ["id": thread]]], agentKey: agentKey, agent: agent)
                }
                agent.turnCount += 1
                let id = "film-codex-\(agentKey)-\(agent.turnCount)"
                agent.turnId = id
                deliver(.sessionStateChanged(.running), to: agent, ago: action.ago ?? 0)
                try feedCodex(["method": "turn/started", "params": ["threadId": thread, "turn": ["id": id]]],
                              agentKey: agentKey, agent: agent, ago: action.ago ?? 0)
            case "done", "failed":
                try feedCodex(["method": "turn/completed", "params": [
                    "threadId": thread, "turn": ["id": turnId, "status": turn == "done" ? "completed" : "failed"],
                ]], agentKey: agentKey, agent: agent, through: FilmAgentRunner.inFlight(for: agent.agentId))
                if !(FilmAgentRunner.inFlight(for: agent.agentId) == nil && !supervisor.isRunning(agent.agentId)) {
                    pendingRunnerCompletions.insert(agentKey)
                }
            default:
                throw FilmError("turn \(turn)")
            }
        } else if let tool = action.tool {
            let item = codexItem(tool, completed: false, failed: false)
            actionState["codexTool/\(agentKey)/\(tool.id)"] = tool
            try feedCodex(["method": "item/started", "params": ["threadId": thread, "turnId": turnId, "item": item]],
                          agentKey: agentKey, agent: agent)
        } else if let toolId = action.toolDone, let tool = actionState["codexTool/\(agentKey)/\(toolId)"] as? FilmAction.Tool {
            let item = codexItem(tool, completed: true, failed: action.status == "failed")
            try feedCodex(["method": "item/completed", "params": ["threadId": thread, "turnId": turnId, "item": item]],
                          agentKey: agentKey, agent: agent)
        }
        delegate.filmRefreshAgentSurfaces()
    }

    /// The app-server `item` for a scene tool. A fileChange carries only `path` and
    /// `kind`: no live capture pins a codex diff body, so no line counts are invented.
    func codexItem(_ tool: FilmAction.Tool, completed: Bool, failed: Bool) -> [String: Any] {
        if tool.kind == "fileChange" {
            var item: [String: Any] = ["id": tool.id, "type": "fileChange",
                                       "changes": [["path": tool.path ?? tool.title ?? "", "kind": tool.action ?? "update"]]]
            if completed { item["status"] = failed ? "failed" : "completed" }
            return item
        }
        var item: [String: Any] = ["id": tool.id, "type": "commandExecution", "command": tool.command ?? tool.title ?? ""]
        if completed {
            item["exitCode"] = failed ? 1 : 0
            item["aggregatedOutput"] = tool.output ?? ""
        }
        return item
    }

    /// `through`: a real composer send's runner, which reports these events (the
    /// turn's end) the way the codex process would, then exits.
    func feedCodex(_ object: [String: Any], agentKey: String, agent: AgentHandle, ago: Double = 0,
                   through runner: FilmAgentRunner? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let epoch = filmEpoch, shift = Self.filmWallShift
        var translator = codexTranslators[agentKey] ?? CodexAppServerEventTranslator(
            workingDirectory: supervisor.records[agent.agentId].map { URL(fileURLWithPath: $0.checkoutRoot, isDirectory: true) },
            now: { epoch.addingTimeInterval(shift + FilmDirector.filmSeconds) })
        let box = FilmObservationBox()
        translator.onRuntimeObservation = box.append
        let events = translator.translate(line: String(decoding: data, as: UTF8.self))
        translator.onRuntimeObservation = nil
        codexTranslators[agentKey] = translator
        for observation in box.drain() where !Self.isProviderThreadObservation(observation) {
            supervisor.qaObserve(observation, for: agent.agentId)
        }
        if let runner {
            runner.complete(with: events.map { $0.withThreadId(agent.threadId) })
            return
        }
        for event in events { deliver(event.withThreadId(agent.threadId), to: agent, ago: ago) }
    }

    /// The provider's thread id is the runner's resume handle, not film content.
    static func isProviderThreadObservation(_ observation: AgentRuntimeObservation) -> Bool {
        if case .threadId = observation { return true }
        return false
    }

    // MARK: The film clock

    /// Midnight of the film's day: TOMORROW. Production stamps some facts with the wall
    /// clock (a spawn's `createdAt`/`lastActivityAt`, a send's activity, a visit), and
    /// folds them with `max`. On a day that has already passed those wall stamps would sit
    /// in the film's future: an agent finished at a film 8:45 would read as last active at
    /// the real 17:43, and the close nudge's "five minutes since you read it" would never
    /// come. On tomorrow, every wall stamp is in the film's past, so the film clock wins.
    var filmDay: Date {
        let today = Calendar.current.startOfDay(for: filmEpoch)
        return Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    /// The wall shift that puts the first take with a `clock` at that time of day.
    func prepareClock() {
        _ = filmEpoch
        Self.filmWallShift = 0
        clockJump = 0
        guard let index = scene.takes.firstIndex(where: { $0.clock != nil }),
              let seconds = scene.takes[index].clock.flatMap(FilmScene.clockSeconds) else { return }
        let before = scene.takes[..<index].reduce(0) { $0 + $1.frames }
        let desired = filmDay.addingTimeInterval(seconds)
        Self.filmWallShift = desired.timeIntervalSince(filmEpoch) - Double(before) / fps
        log("clock: take \(scene.takes[index].name) starts at \(scene.takes[index].clock!) (wall shift \(Int(Self.filmWallShift)) s)")
    }

    /// A later take's `clock`: the film clock jumps forward to it.
    func advanceClock(to clock: String, take: String) {
        guard let seconds = FilmScene.clockSeconds(clock) else { return }
        let desired = filmDay.addingTimeInterval(seconds)
        let jump = desired.timeIntervalSince(filmDate)
        if jump > 1e-6 { clockJump += jump }
        log("clock: take \(take) at \(clock) (+\(Int(max(jump, 0))) s)")
    }

    /// A production wait on the film clock (`AgentSignalCenter.filmDelay`): resumed by
    /// the first frame whose film time reaches it.
    func filmDelay(_ seconds: TimeInterval) async {
        let deadline = Self.filmSeconds + seconds
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            filmTimers.append((deadline, resume))
        }
    }

    func fireFilmTimers() async {
        let now = Self.filmSeconds + 1e-9
        // Scheduled callbacks (`filmSchedule`: the sidebar hover card's dwell), oldest first.
        let callbacks = filmCallbacks.filter { $0.deadline <= now }.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
        filmCallbacks.removeAll { $0.deadline <= now }
        for callback in callbacks { callback.run() }
        let due = filmTimers.filter { $0.deadline <= now }
        guard !due.isEmpty else { return }
        filmTimers.removeAll { $0.deadline <= now }
        for timer in due { timer.resume.resume() }
        for _ in 0..<4 { await Task.yield() }
    }
}

/// Film runs only: where production would run an NSMenu's tracking loop (a zone's ⋯
/// button, "Color This Zone…"), the director takes the menu instead. AppKit draws a
/// popped-up menu on a real display (a menu is constrained onto a screen; the film
/// window is parked off every one), and its modal tracking would block the take.
@MainActor
enum FilmMenuHost {
    static var present: ((NSMenu, NSPoint, NSView) -> Void)?

    static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
        if let present { present(menu, point, view) } else { menu.popUp(positioning: nil, at: point, in: view) }
    }
}
#endif
