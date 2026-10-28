import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `.plans/79-session-handoff` — agents messaging each other, through the
/// production path end to end.
///
/// A parent pi agent (its tile on the canvas, mounted by
/// `mountWorkspaceSceneAtBoot`) delegates a child through the real
/// `WorkspaceAPIService`, then messages it: its (fake) pi calls
/// `array_message_agent` over the real host-tool bridge, exactly as the bundled
/// extension does, and the host delivers through `AgentSupervisor`. The leg
/// asserts what each tile DRAWS:
///
/// - the child shows the delegated task and the message as cards FROM the
///   parent — its name, its identity colour, a button that reveals its tile —
///   and no user prompt carrying either text;
/// - the child's runner received the envelope, so its model knows the sender;
/// - the parent's row reads "Messaged <child>" with the text;
/// - clicking the card's sender reveals the parent through the sidebar's path;
/// - the child's turns, written into a pi session file the way pi records
///   what it was sent and restored through the production reader and the
///   supervisor's rehydration seam, draw the identical cards.
///
/// Red with the envelope removed (`AgentSupervisor.agentMessageText` returning
/// the bare text): both turns draw as user prompts with no sender.
@MainActor
func runAgentMessageCardChecks() async throws {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    guard let appSupportPath = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
        throw Failure(message: "refusing to run without CONTINUUM_APP_SUPPORT — this leg mints durable agent records and must never write a real store")
    }
    guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw Failure(message: "refusing to run from the PROD bundle — dev channel only")
    }

    let fileManager = FileManager.default
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let tempRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-agent-message-card-\(UUID().uuidString)", isDirectory: true)
    let projectRoot = tempRoot.appendingPathComponent("Pm", isDirectory: true)
    let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
    let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
    for dir in [projectRoot, appSupport, binDir] {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? fileManager.removeItem(at: tempRoot) }

    let executable = binDir.appendingPathComponent("pi")
    try ("#!/usr/bin/env python3\n" + agentMessageFakePiSource).write(to: executable, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(binDir.path):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .pi, readiness: .ready, models: ["fixture-model"],
        displayNames: ["fixture-model": "Fixture"], contextWindows: ["fixture-model": 1]))

    // MARK: Fixture — one project, one zone in view, the parent's agent tile in it.

    let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-0000000AE301")!
    let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000AE302")!
    let zoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000AE303")!
    let parentTile = UUID(uuidString: "00000000-0000-0000-0000-0000000AE304")!
    let project = Project(
        id: projectId, name: "Pm", rootPath: projectRoot.path, createdAt: now, updatedAt: now,
        defaultLaunchProfileId: "shell", editorPreference: .auto,
        settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                  terminalClosePolicy: .askWhenRunning))
    let projectStore = ProjectStore(projectRoot: projectRoot)
    try projectStore.saveProject(project)
    var parentTileModel = Tile(
        id: parentTile, kind: .managedAgent, title: "Lead",
        frame: TileFrame(x: 40, y: 40, width: 560, height: 620), zPosition: .fromLegacyRank(1), runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
    parentTileModel.zoneId = zoneId
    try projectStore.saveCanvas(CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [parentTileModel], groups: [], lastActiveTileId: nil))
    let zone = ZonePlacement(
        zoneId: zoneId, projectId: projectId, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 1900, height: 1100),
        color: "blue", collapsed: false, hydrationPolicy: .pinnedLive)
    let document = WorkspaceDocument(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1), zones: [zone], zoneZOrder: [zoneId], lastActiveZoneId: zoneId)
    try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)
    var registry = Registry.empty()
    registry.lastActiveWorkspaceId = workspaceId
    registry.workspaces = [WorkspaceEntry(id: workspaceId, name: "W", projectIds: [projectId], createdAt: now, updatedAt: now)]
    registry.projects = [ProjectEntry(id: projectId, name: "Pm", rootPath: projectRoot.path, workspaceId: workspaceId,
                                      lastOpenedAt: now, pinned: false, missing: false)]
    let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
    try registryStore.save(registry)

    let browserEngine = BrowserEngineContext()
    defer { browserEngine.shutdown() }
    let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { requested in
        guard requested == projectId else { throw Failure(message: "unexpected projectId \(requested)") }
        return ZoneRuntimeController(projectRoot: projectRoot, projectStore: projectStore, project: project)
    })
    let bootCanvasState = try projectStore.loadCanvas()
    let canvas = CanvasNSView(
        canvasState: bootCanvasState, activeZone: zone,
        zoneRenderModels: [CanvasNSView.ZoneRenderModel(placement: zone, displayName: "Zone")])
    canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = canvas
    window.orderFrontOffscreenForChecks()
    defer { window.orderOut(nil) }

    let delegate = AppDelegate()
    // A real supervisor over an isolated store, WITH the transcript store
    // production injects: the child's delegated turn reaches its tile through
    // the supervisor's own projection.
    let agentsRoot = URL(fileURLWithPath: appSupportPath, isDirectory: true)
        .appendingPathComponent("agent-message-card-check", isDirectory: true)
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: agentsRoot),
        transcriptStore: AgentTranscriptStore(root: agentsRoot.appendingPathComponent("transcripts", isDirectory: true)))
    delegate.agentSupervisor = supervisor
    supervisor.workspaceToolsPermission = { .off }
    let runtime = WorkspaceRuntime(
        boot: try zoneRegistry.acquire(projectId: projectId),
        workspaceId: workspaceId, document: document, registry: zoneRegistry,
        focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
        ghostty: nil, browserEngine: browserEngine)
    delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
    let bootSpawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
                                  projectStore: projectStore, project: project)

    let parentId = supervisor.spawn(
        role: nil, prompt: nil, cwd: projectRoot, harness: .pi, model: "fixture-model", thinking: "low",
        projectId: projectId, projectRoot: projectRoot, tileId: parentTile, displayName: "Lead")
    try expect(supervisor.setWorkspaceToolsEnabled(agentID: parentId, true), "enabling workspace tools must change the parent record")
    try expect(supervisor.setIdentityColor(agentID: parentId, "purple"), "the parent must take its identity colour")

    try delegate.mountWorkspaceSceneAtBoot(
        canvasView: canvas, spawner: bootSpawner, projectStore: projectStore,
        canvasState: bootCanvasState, installsGlobalEventMonitors: false)
    canvas.layoutSubtreeIfNeeded()
    supervisor.workspaceToolsPermission = { .off }
    defer { supervisor.stopAll() }
    guard let parentView = canvas.tileView(for: parentTile) as? ManagedAgentTileNSView else {
        throw Failure(message: "the parent's managed-agent tile was not hydrated by the mount")
    }
    if parentView.attachedAgentID != parentId { delegate.wireManagedAgentTile(parentTile, agentID: parentId) }
    try expect(parentView.attachedAgentID == parentId, "the parent's tile must follow the parent agent")

    let api = delegate.qaWorkspaceAPI
    api.approvalHandler = { _ in .allowForSession }

    // MARK: Drawn-transcript helpers

    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func settle(_ view: ManagedAgentTileNSView) throws -> [NSView] {
        if let canvas = view.qaCanvasTranscript {
            canvas.flushPendingVisualUpdate()
            view.layoutSubtreeIfNeeded()
            if let error = canvas.qaRenderingErrorDescription { throw Failure(message: "the transcript failed to render: \(error)") }
            return [canvas]
        }
        guard let transcript = view.qaTranscriptForChecks else { throw Failure(message: "a tile has no transcript list") }
        view.layoutSubtreeIfNeeded()
        transcript.flushPendingVisualUpdate()
        if let error = transcript.qaRenderingErrorDescription { throw Failure(message: "the transcript failed to render: \(error)") }
        transcript.layoutSubtreeIfNeeded()
        transcript.collectionView.layout()
        transcript.collectionView.layoutSubtreeIfNeeded()
        return descendants(transcript)
    }
    func cards(_ view: ManagedAgentTileNSView) throws -> [AgentMessageCardView] {
        try settle(view).compactMap { $0 as? AgentMessageCardView }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }
    func userProse(_ view: ManagedAgentTileNSView) throws -> String {
        if let canvas = view.qaCanvasTranscript {
            _ = try settle(view)
            return canvas.qaUserText
        }
        return try settle(view).compactMap { $0 as? UserPromptView }
            .flatMap { $0.proseView.textFields.map(\.string) }.joined(separator: "\n")
    }
    /// One card as the tile draws it, from either renderer. `press` presses its
    /// sender the way a click does; `fits` says no body line is clipped.
    struct DrawnCard: Equatable {
        var payload: AgentMessagePayload?
        var header: String
        var body: String
        var accent: CGColor?
        var revealable: Bool
        var fits: Bool
        static func == (a: DrawnCard, b: DrawnCard) -> Bool {
            a.payload == b.payload && a.header == b.header && a.body == b.body && a.accent == b.accent
                && a.revealable == b.revealable
        }
    }
    func drawnCards(_ view: ManagedAgentTileNSView) throws -> [(card: DrawnCard, press: () -> Void)] {
        if let canvas = view.qaCanvasTranscript {
            _ = try settle(view)
            let blocks = view.qaDocumentForChecks.entries.flatMap(\.blocks)
            return canvas.qaPlacedBlockIDs.compactMap { id -> (card: DrawnCard, press: () -> Void)? in
                guard let block = blocks.first(where: { $0.id == id }), case let .agentMessage(payload) = block.payload,
                      let card = canvas.qaMessageCard(for: id) else { return nil }
                let press = {
                    // A press on the drawn sender: hit-tested, then its own action.
                    if let point = card.revealPoint, let hit = canvas.control(at: point) { canvas.perform(hit.control.action) }
                }
                return (DrawnCard(payload: payload, header: card.header, body: card.body, accent: card.accent,
                                  revealable: card.revealPoint != nil, fits: card.bodyFits), press)
            }
        }
        return try cards(view).map { card in
            let label = card.bodyLabel
            let needed = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)).height ?? 0
            return (DrawnCard(payload: card.payload, header: card.senderButton.nameLabel.stringValue,
                              body: card.bodyLabel.stringValue, accent: card.accentColor?.cgColor,
                              revealable: card.senderButton.isRevealable,
                              fits: label.frame.width > 40 && needed <= label.frame.height + 0.5),
                    { card.senderButton.performClick(nil) })
        }
    }
    let purple = ZoneChromeNSView.color(named: "purple")
    func expectFromParent(_ card: DrawnCard, text: String, _ what: String) throws {
        try expect(card.payload == AgentMessagePayload(origin: .array, senderAgentID: parentId.rawValue, senderName: "Lead", text: text),
                   "\(what): the card must be the parent's message, got \(String(describing: card.payload))")
        try expect(card.header.hasPrefix("Lead"), "\(what): the card's header must name the parent, got '\(card.header)'")
        try expect(card.body == text, "\(what): the card's body must be the parent's words, got '\(card.body)'")
        try expect(card.accent == purple.cgColor, "\(what): the card must wear the parent's identity colour, got \(String(describing: card.accent))")
        try expect(card.revealable, "\(what): the parent has a tile, so its name must open it")
    }

    // MARK: A — a delegated child's task is the parent's message, not the user's prompt

    let task = "Audit the parser.\nList every unescaped attribute you find."
    guard case let .result(created) = api.dispatch(
        agentId: parentId, requestId: "am-delegate", op: "agent.delegate",
        payload: ["task": task, "idempotencyKey": "am-d1", "presentation": ["camera": "preserve"]],
        isCancelled: { false }),
          let childString = created["childAgentId"]?.string, let childUUID = UUID(uuidString: childString),
          let childTileString = created["tileId"]?.string, let childTile = UUID(uuidString: childTileString) else {
        throw Failure(message: "the delegation must create a child with a tile")
    }
    let childId = AgentID(rawValue: childUUID)
    // A delegated child is named from its first prompt; that prompt is now an
    // envelope, and the name must still be the words, never the markup.
    let childName = supervisor.records[childId]?.humanDisplayName ?? ""
    try expect(childName.hasPrefix("Audit the parser") && !childName.contains("<") && !childName.contains("array-agent"),
               "the child must be named by its task's words, not by the envelope: \(childName)")
    let messagedRow = ArrayWorkspaceTool.messageLine(targetName: childName)
    guard let childView = canvas.tileView(for: childTile) as? ManagedAgentTileNSView else {
        throw Failure(message: "the child's tile is not a managed-agent tile")
    }
    let promptsLog = projectRoot.appendingPathComponent("prompts.log")
    func received() -> [String] {
        ((try? String(contentsOf: promptsLog, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed)) as? String
        }
    }
    let taskArrived = await waitUntil(timeout: 30, pollInterval: 0.1) { received().contains { $0.contains("Audit the parser.") } }
    try expect(taskArrived, "the child's runner never received its task")
    let childIdle = await waitUntil(timeout: 30, pollInterval: 0.1) { !supervisor.isRunning(childId) }
    try expect(childIdle, "the child must settle after its task")
    let taskCards = try drawnCards(childView).map(\.card)
    try expect(taskCards.count == 1, "the child must draw exactly one card for its task, got \(taskCards.count)")
    try expectFromParent(taskCards[0], text: task, "delegated task")

    // MARK: B — agent.message over the real bridge, live

    let message = "Rerun the failing leg.\nThen report the diff, \"verbatim\" & short."
    try JSONSerialization.data(withJSONObject: ["agentId": childString, "text": message])
        .write(to: projectRoot.appendingPathComponent("message-target.json"))
    try expect(supervisor.send("__MESSAGE_CHILD__ tell the parser child to rerun", to: parentId),
               "the parent must accept the prompt that makes it message its child")
    let messageArrived = await waitUntil(timeout: 30, pollInterval: 0.1) { received().contains { $0.contains("Rerun the failing leg.") } }
    try expect(messageArrived, "the child's runner never received the message (prompts: \(received()))")
    // What the child's MODEL was given: the sender, then the words.
    let delivered = received().first { $0.contains("Rerun the failing leg.") } ?? ""
    try expect(delivered == AgentMessageEnvelope.wrap(message, senderID: parentId.rawValue, senderName: "Lead"),
               "the child's model must receive the message inside the envelope naming the parent, got \(delivered)")
    let bothSettled = await waitUntil(timeout: 30, pollInterval: 0.1) {
        !supervisor.isRunning(childId) && !supervisor.isRunning(parentId)
    }
    try expect(bothSettled, "both agents must settle after the message")
    let liveCards = try drawnCards(childView).map(\.card)
    // Drawn at the height it was measured: no body line clipped by the row.
    for card in liveCards {
        try expect(card.fits, "a card's body is clipped: '\(card.body)'")
    }
    try expect(liveCards.count == 2, "the child must draw a card for the task and one for the message, got \(liveCards.count)")
    try expectFromParent(liveCards[1], text: message, "agent.message")
    let prose = try userProse(childView)
    for (label, text) in [("task", "Audit the parser."), ("message", "Rerun the failing leg.")] {
        try expect(!prose.contains(text), "the child also drew the parent's \(label) as a user prompt: \(prose)")
    }
    try expect(!prose.contains("array-agent-message"), "the raw envelope drew in the child's transcript: \(prose)")

    // MARK: C — the parent's row says who it messaged, and what

    /// The tool rows a tile draws: title and the summary line under it.
    func toolRows(_ view: ManagedAgentTileNSView) throws -> [(title: String, summary: String)] {
        if let canvas = view.qaCanvasTranscript {
            _ = try settle(view)
            let tools = Set(view.qaDocumentForChecks.entries.flatMap(\.blocks).filter { $0.kind == .toolCall }.map(\.id))
            return canvas.qaPlacedBlockIDs.filter(tools.contains).map { id in
                let rows = canvas.qaRowStrings(of: id)
                return (rows.first ?? "", rows.dropFirst().first ?? "")
            }
        }
        return try settle(view).compactMap { $0 as? ToolCallView }
            .map { ($0.titleLabel.stringValue, $0.summaryLabel.stringValue) }
    }
    let parentRowsDrawn = await waitUntil(timeout: 10, pollInterval: 0.1) {
        ((try? toolRows(parentView)) ?? []).contains { $0.title == messagedRow }
    }
    let parentTitles = try toolRows(parentView).map(\.title)
    try expect(parentRowsDrawn && messagedRow.hasPrefix("Messaged Audit the parser"),
               "the parent's row must read '\(messagedRow)', got \(parentTitles)")
    let messageRow = try toolRows(parentView).first { $0.title == messagedRow }
    try expect(messageRow?.summary.hasPrefix("Rerun the failing leg.") == true,
               "the parent's row must carry the message it sent, got '\(messageRow?.summary ?? "")'")

    // MARK: D — the sender's name opens the sender's tile (the sidebar's reveal path)

    supervisor.focus(agentID: childId)
    try drawnCards(childView)[1].press()
    try expect(supervisor.focusedAgentID == parentId,
               "clicking the sender must reveal and focus the parent, focused: \(String(describing: supervisor.focusedAgentID))")

    // MARK: E — restored from the child's session file, the same cards

    // pi records what it was sent as the user turn. The session file is built
    // from exactly the text the child's runner received.
    let deliveredTask = received().first { $0.contains("Audit the parser.") } ?? ""
    func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func user(_ text: String) throws -> String {
        try jsonLine(["type": "message", "message": ["role": "user", "content": [["type": "text", "text": text]]]])
    }
    func assistant(_ text: String) throws -> String {
        try jsonLine(["type": "message", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }
    let session = try [user(deliveredTask), assistant("Found two."), user(delivered), assistant("Rerun is green.")]
    let rehydrated = PiSessionTranscriptReader.parse(lines: session, threadId: "restored-child")
    let restoredId = supervisor.spawn(
        role: nil, prompt: nil, cwd: projectRoot, harness: .pi, model: "fixture-model", thinking: "low",
        projectId: projectId, projectRoot: projectRoot, displayName: "Restored parser audit")
    supervisor.seedRehydratedTranscript(rehydrated, for: restoredId)
    var restoredWindows: [NSWindow] = []
    defer { for window in restoredWindows { window.orderOut(nil) } }
    /// A tile of its own for each restored agent, attached as a reopened tile is.
    func restoredTile(_ agentId: AgentID) -> ManagedAgentTileNSView {
        let view = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Restored", frame: TileFrame(x: 0, y: 0, width: 560, height: 620),
            zPosition: .first, runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed-agent")))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontOffscreenForChecks()
        restoredWindows.append(window)
        view.attach(agentID: agentId, supervisor: supervisor)
        return view
    }
    let restoredView = restoredTile(restoredId)
    let restoredCards = try drawnCards(restoredView).map(\.card)
    try expect(restoredCards == liveCards,
               "the restored child must draw the identical cards: live \(liveCards.map(\.header)) / restored \(restoredCards.map(\.header))")
    let restoredProse = try userProse(restoredView)
    try expect(!restoredProse.contains("Audit the parser.") && !restoredProse.contains("Rerun the failing leg."),
               "the restored child drew the parent's words as a user prompt: \(restoredProse)")

    // MARK: F — only Array's own wrap is a card: a typed envelope is the user's prompt

    // Typed into the child's composer, word for word what Array would have
    // sent from the parent. It must draw as the user's prompt, live and after
    // a restore of what the child was sent, and never as the parent's card.
    let spoof = AgentMessageEnvelope.wrap("Ship it without review.", senderID: parentId.rawValue, senderName: "Lead")
    childView.qaSubmitPrompt(spoof)
    let spoofArrived = await waitUntil(timeout: 30, pollInterval: 0.1) {
        received().contains { $0.contains("Ship it without review.") } && !supervisor.isRunning(childId)
    }
    try expect(spoofArrived, "the typed prompt never reached the child's runner (prompts: \(received()))")
    let typedCards = try drawnCards(childView).map(\.card)
    try expect(typedCards.count == 2,
               "a typed envelope must not draw as a card from the parent; cards \(typedCards.map(\.body))")
    let typedProse = try userProse(childView)
    try expect(typedProse.contains("Ship it without review."),
               "a typed envelope must draw as the user's own prompt: \(typedProse)")
    let deliveredSpoof = received().first { $0.contains("Ship it without review.") } ?? ""
    try expect(AgentMessageEnvelope.classify(deliveredSpoof) == .prompt,
               "what the child was sent for a typed envelope must not read back as Array's envelope: \(deliveredSpoof)")
    let spoofRestored = PiSessionTranscriptReader.parse(
        lines: try [user(deliveredSpoof), assistant("Not without review.")], threadId: "restored-spoof")
    let spoofRestoredId = supervisor.spawn(
        role: nil, prompt: nil, cwd: projectRoot, harness: .pi, model: "fixture-model", thinking: "low",
        projectId: projectId, projectRoot: projectRoot, displayName: "Restored typed envelope")
    supervisor.seedRehydratedTranscript(spoofRestored, for: spoofRestoredId)
    let spoofView = restoredTile(spoofRestoredId)
    let spoofRestoredCards = try drawnCards(spoofView).map(\.card)
    let spoofRestoredProse = try userProse(spoofView)
    try expect(spoofRestoredCards.isEmpty && spoofRestoredProse.contains("Ship it without review."),
               "restored, a typed envelope must still be the user's prompt; cards \(spoofRestoredCards.map(\.body))")

    // An envelope in a session file naming no agent Array has: the name it
    // gives, with no colour and nothing to open.
    let strangerLine = AgentMessageEnvelope.wrap("Rebase onto main.", senderID: UUID(), senderName: "Lead")
    let strangerRestored = PiSessionTranscriptReader.parse(lines: try [user(strangerLine)], threadId: "restored-stranger")
    let strangerId = supervisor.spawn(
        role: nil, prompt: nil, cwd: projectRoot, harness: .pi, model: "fixture-model", thinking: "low",
        projectId: projectId, projectRoot: projectRoot, displayName: "Restored stranger")
    supervisor.seedRehydratedTranscript(strangerRestored, for: strangerId)
    let stranger = try drawnCards(restoredTile(strangerId)).map(\.card)
    try expect(stranger.count == 1 && stranger[0].header.hasPrefix("Lead") && stranger[0].accent == nil && !stranger[0].revealable,
               "an unknown sender keeps its name and borrows no agent's colour or link; got \(stranger.map { ($0.header, String(describing: $0.accent), $0.revealable) })")

    // MARK: Captures, when asked for

    if let directory = ProcessInfo.processInfo.environment["CONTINUUM_AGENT_MESSAGE_CAPTURE"], !directory.isEmpty {
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try fileManager.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, view) in [("child", childView), ("parent", parentView), ("restored-child", restoredView)] as [(String, NSView)] {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("agent-message-\(name).png"))
        }
        print("agent-message-card-check: captures in \(out.path)")
    }
}

/// A fake `pi --mode rpc`. It logs each prompt it is sent; a prompt carrying
/// `__MESSAGE_CHILD__` makes it call `array_message_agent` over the host-tool
/// bridge — `extension_ui_request` with an `array.workspace.v1` envelope, the
/// shape `continuum-workspace-tools.ts` sends — with the target and text the
/// check left in `message-target.json`, and report the host's reply as the tool
/// result. No model, no auth, no network.
private let agentMessageFakePiSource = #"""
import json, os, sys, threading, time, uuid

cwd = os.getcwd()
emit_lock = threading.Lock()
state_lock = threading.Lock()
pending = {}


def emit(obj):
    with emit_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def log(name, line):
    with state_lock:
        with open(os.path.join(cwd, name), "a") as f:
            f.write(line + "\n")


def wait_dialog(req_id, timeout_s):
    ev = threading.Event()
    with state_lock:
        pending[req_id] = {"event": ev, "value": None}
    ev.wait(timeout_s)
    with state_lock:
        entry = pending.pop(req_id, None)
    return None if entry is None else entry["value"]


def message_child():
    with open(os.path.join(cwd, "message-target.json")) as f:
        target = json.load(f)
    call_id = "tc-message-" + str(uuid.uuid4())[:8]
    args = {"agentId": target["agentId"], "text": target["text"], "idempotencyKey": call_id}
    emit({"type": "tool_execution_start", "toolCallId": call_id, "toolName": "array_message_agent", "args": args})
    req_id = str(uuid.uuid4())
    envelope = json.dumps({"schema": "array.workspace.v1", "kind": "request", "requestId": call_id,
                           "op": "agent.message", "payload": args})
    emit({"type": "extension_ui_request", "id": req_id, "method": "input", "title": envelope, "timeout": 45000})
    value = wait_dialog(req_id, 45.0) or json.dumps({"schema": "array.workspace.v1", "requestId": call_id,
                                                      "status": "error", "error": {"code": "outcome_unknown", "message": "bridge timeout"}})
    emit({"type": "tool_execution_end", "toolCallId": call_id, "toolName": "array_message_agent",
          "result": {"content": [{"type": "text", "text": value}]}, "isError": False})


def handle_prompt(cmd):
    message = cmd.get("message") or cmd.get("prompt") or ""
    log("prompts.log", json.dumps(message))
    emit({"type": "response", "id": cmd.get("id"), "command": "prompt", "success": True})
    emit({"type": "agent_start"})
    emit({"type": "turn_start"})
    if "__MESSAGE_CHILD__" in message:
        # A model takes a moment before its first tool call. Without it the
        # call's observation can reach the tile before the turn's start does,
        # which no real provider produces.
        time.sleep(0.5)
        message_child()
    emit({"type": "turn_end"})
    emit({"type": "agent_end", "willRetry": False})
    emit({"type": "agent_settled"})


def handle(cmd):
    kind = cmd.get("type")
    if kind == "extension_ui_response":
        with state_lock:
            entry = pending.get(cmd.get("id"))
            if entry is not None:
                entry["value"] = cmd.get("value")
                entry["event"].set()
        return
    if kind == "prompt":
        handle_prompt(cmd)
    elif kind == "abort":
        emit({"type": "response", "id": cmd.get("id"), "command": "abort", "success": True})
    else:
        emit({"type": "response", "id": cmd.get("id"), "command": kind, "success": True, "data": {}})


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    threading.Thread(target=handle, args=(obj,), daemon=True).start()

time.sleep(0.3)
"""#
