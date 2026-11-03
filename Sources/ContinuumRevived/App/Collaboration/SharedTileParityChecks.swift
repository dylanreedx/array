import AppKit
import WebKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// `--shared-tile-parity-check [dir]`: the host and the guest of one shared
/// tile must see the same thing. For each shareable kind it builds the HOST's
/// tile from a fixture, and the GUEST's tile from the same fixture carried by
/// the production share path: the real publisher (`SharedAreaAgentProjectionHost`
/// for an agent, `makeLiveTileSource` + `LiveTileHost` for every other kind),
/// the real controllers, a loopback at the `SharedAreaControllerTransport` seam
/// that JSON-encodes every crossing exactly as `CollaborationAPI` does (ISO 8601
/// dates), and the real guest session (`SharedAgentTileSession`,
/// `SharedTileSession`). No relay process, no network.
///
/// Per kind it compares, light and dark, off screen:
/// - the view classes under the content region,
/// - the rendered element list (the text each surface lays out, plus markers
///   for pages, stills and images),
/// - a bitmap of the content region (pixel diff within `pixelTolerance`).
///
/// Every kind's host, guest and diff pictures and a `report.txt` go to the run
/// folder. RED when any kind differs; the report names the kind and the
/// differing elements. Terminals are not driven: a host terminal needs a tmux
/// server, and checks must not start one outside an isolated namespace.
@MainActor
enum SharedTileParityChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Share of pixels that may differ (any channel off by more than
    /// `channelTolerance` of 255) before a kind is RED.
    static let pixelTolerance = 0.02
    static let channelTolerance = 24
    static let tileSize = NSSize(width: 520, height: 640)
    /// Kinds whose shared content is a document under the guest's caption.
    static let documentKinds: [Collaboration.LiveTile.Kind] = [.note, .file, .diff]

    // MARK: - Loopback relay

    /// The relay's part, in memory: the projection log and the live-tile lane,
    /// with every value encoded and decoded as it would be on the wire.
    actor Loopback {
        private var logs: [UUID: Collaboration.AgentProjection.Log] = [:]
        private var tiles: [UUID: Collaboration.LiveTile.State] = [:]
        private var events: [UUID: [Collaboration.LiveTile.Event]] = [:]
        /// The agent transcript lane, run by the relay's own `Log`.
        private var transcripts: [String: Collaboration.AgentTranscript.Log] = [:]
        private(set) var crossings = 0

        func wire<T: Codable>(_ value: T) throws -> T {
            crossings += 1
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: encoder.encode(value))
        }

        func publish(object: UUID, report: Collaboration.AgentProjection.PublishReport) throws {
            let batch = try wire(report).batch
            if logs[object] == nil {
                guard let snapshot = batch.snapshot else { throw CollaborationClientError.server(status: 409, code: "resyncRequired") }
                logs[object] = .init(snapshot: snapshot)
            }
            do { try logs[object]!.publish(batch) }
            catch Collaboration.AgentProjection.Log.Failure.staleGeneration { throw CollaborationClientError.server(status: 409, code: "revisionConflict") }
            catch { throw CollaborationClientError.server(status: 409, code: "resyncRequired") }
        }
        func read(object: UUID, cursor: Collaboration.AgentProjection.Cursor?) throws -> Collaboration.AgentProjection.Read {
            guard let log = logs[object] else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return try wire(log.read(after: cursor))
        }

        func publishTranscript(object: UUID, report: Collaboration.AgentTranscript.Publish) throws {
            let report = try wire(report)
            let key = object.uuidString + "/" + report.stream
            do { transcripts[key] = try Collaboration.AgentTranscript.Log.publish(report, onto: transcripts[key]) }
            catch .stale { throw CollaborationClientError.server(status: 409, code: "revisionConflict") }
            catch .checkpointRequired { throw CollaborationClientError.server(status: 409, code: "resyncRequired") }
            catch { throw CollaborationClientError.server(status: 400, code: "invalidRequest") }
        }
        func readTranscript(object: UUID, request: Collaboration.AgentTranscript.ReadRequest) async throws -> Collaboration.AgentTranscript.Read {
            let request = try wire(request)
            let key = object.uuidString + "/" + request.stream
            // A short long-poll, as the relay holds a current reader.
            var waited = 0
            while waited < min(request.waitMilliseconds, 250) {
                guard let log = transcripts[key] else { break }
                if case let .frames(_, frames, _) = log.read(after: request.cursor), frames.isEmpty {
                    try await Task.sleep(for: .milliseconds(25)); waited += 25
                } else { break }
            }
            guard let log = transcripts[key] else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            return try wire(log.read(after: request.cursor))
        }

        func publishTile(object: UUID, report: Collaboration.LiveTile.PublishState) throws {
            tiles[object] = try wire(report).state
        }
        func append(object: UUID, body: Collaboration.LiveTile.EventBody, author: SharedArea.ID<SharedArea.Person>) throws -> Collaboration.LiveTile.Appended {
            let sequence = (events[object]?.last?.sequence ?? 0) + 1
            events[object, default: []].append(.init(sequence: sequence, author: author, at: Date(), body: try wire(body)))
            return .init(sequence: sequence)
        }
        func readTile(object: UUID, request: Collaboration.LiveTile.ReadRequest) async throws -> Collaboration.LiveTile.Read {
            let request = try wire(request)
            func current() -> Bool {
                guard let state = tiles[object] else { return false }
                return state.generation == request.generation && state.revision == request.revision
            }
            func pending() -> Bool { (events[object]?.last?.sequence ?? 0) > (request.eventsAfter ?? 0) }
            // A short long-poll: enough that readers never spin.
            var waited = 0
            while current(), !pending(), waited < min(request.waitMilliseconds, 250) {
                try await Task.sleep(for: .milliseconds(25)); waited += 25
            }
            let after = request.eventsAfter ?? 0
            return try wire(Collaboration.LiveTile.Read(state: current() ? nil : tiles[object],
                events: (events[object] ?? []).filter { $0.sequence > after },
                eventHead: events[object]?.last?.sequence ?? 0, eventFloor: 0))
        }
    }

    struct Transport: SharedAreaControllerTransport {
        let base: SharedAreaCheckRig.Transport
        let loop: Loopback
        func identity() async throws -> Collaboration.Identity { try await base.identity() }
        func state() async throws -> Collaboration.State { try await base.state() }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await base.connection(initial: initial) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { try await base.apply(mutation) }
        func beginPresence() async throws -> Collaboration.PresenceSession { try await base.beginPresence() }
        func publishPresence(_ input: Collaboration.PresenceInput) async throws { try await base.publishPresence(input) }
        func endPresence(_ session: UUID) async throws { try await base.endPresence(session) }
        func reportUsage(_ report: Collaboration.UsageReport) async throws { try await base.reportUsage(report) }
        func publishAgentProjection(object: UUID, report: Collaboration.AgentProjection.PublishReport) async throws {
            try await loop.publish(object: object, report: report)
        }
        func readAgentProjection(object: UUID, cursor: Collaboration.AgentProjection.Cursor?) async throws -> Collaboration.AgentProjection.Read {
            try await loop.read(object: object, cursor: cursor)
        }
        func publishLiveTileState(object: UUID, report: Collaboration.LiveTile.PublishState) async throws {
            try await loop.publishTile(object: object, report: report)
        }
        func publishAgentTranscript(object: UUID, report: Collaboration.AgentTranscript.Publish) async throws {
            try await loop.publishTranscript(object: object, report: report)
        }
        func readAgentTranscript(object: UUID, request: Collaboration.AgentTranscript.ReadRequest) async throws -> Collaboration.AgentTranscript.Read {
            try await loop.readTranscript(object: object, request: request)
        }
        func appendLiveTileEvent(object: UUID, body: Collaboration.LiveTile.EventBody) async throws -> Collaboration.LiveTile.Appended {
            try await loop.append(object: object, body: body, author: base.identityValue.person)
        }
        func readLiveTile(object: UUID, request: Collaboration.LiveTile.ReadRequest) async throws -> Collaboration.LiveTile.Read {
            try await loop.readTile(object: object, request: request)
        }
    }

    static func controller(root: URL, identity: Collaboration.Identity, label: String, authority: SharedAreaCheckRig.Authority,
                           loop: Loopback, document: SharedArea.Document) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://parity.example.test")!)
        let credentials = CollaborationCredentialStore(vault: SharedAreaCheckRig.MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "parity-loopback-device"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint,
                                             person: identity.person, area: authority.area)
        try cache.save(.init(scope: cache.scope, document: document, observedMembershipEpoch: 1))
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope, bundleIdentifier: nil,
            transportFactory: { _, _, _ in
                Transport(base: .init(identityValue: identity, label: label, authority: authority), loop: loop)
            })
    }

    private struct NoRoute: SharedAgentHandoffTransport {
        struct Unused: Error {}
        func state() async throws -> Collaboration.State { throw Unused() }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { throw Unused() }
        func control(object: UUID) async throws -> Collaboration.AgentControlState { throw Unused() }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { throw Unused() }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { throw Unused() }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
    }

    // MARK: - One kind's pair

    struct Pair {
        let kind: String
        let host: TileNSView
        let guest: TileNSView
        /// The part of each tile that shows the shared content.
        let hostRegion: () -> NSView?
        let guestRegion: () -> NSView?
        /// Extra facts for the report (block kinds the host drew, and so on).
        var notes: [String] = []
        /// Element endings BOTH sides must lay out: a state the share must
        /// carry truthfully, not merely carry the same on both Macs.
        var mustShow: [String] = []
        /// Chrome facts the two tiles disagree on (agent-chrome), checked
        /// beside the content region; RED when any.
        var chromeDifferences: [String] = []
    }

    struct Comparison {
        var kind: String
        var lines: [String] = []
        var red = false
    }

    // MARK: - Run

    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try ShareEntryChecks.mountScene("shared-tile-parity")
        defer { scene.close() }
        let app = scene.app, canvas = scene.canvas
        guard let projectRoot = scene.fixture.projectRoots[WorkspaceInvariantsFixture.projectA1],
              let spawner = app.spawnerForFilesystemCreation() else { throw Failure(description: "no project to spawn into") }
        let rigRoot = try SharedAreaCheckRig.root("shared-tile-parity")
        defer { try? FileManager.default.removeItem(at: rigRoot) }

        // One area holding every kind, hosted by Dylan, opened by Sam.
        let dylan = Collaboration.Identity(person: .init(), device: UUID())
        let sam = Collaboration.Identity(person: .init(), device: UUID())
        let hostID = SharedArea.ID<SharedArea.Host>()
        let kinds: [Collaboration.LiveTile.Kind] = [.note, .file, .diff, .browser]
        let agentItem = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: dylan.person, host: hostID, binding: .init()))
        var tileItems: [Collaboration.LiveTile.Kind: SharedArea.Item] = [:]
        for kind in kinds {
            tileItems[kind] = SharedArea.Item(id: .init(), kind: .liveTile, source: .init(owner: dylan.person, host: hostID, binding: .init()))
        }
        let markdownItem = SharedArea.Item(id: .init(), kind: .liveTile, source: .init(owner: dylan.person, host: hostID, binding: .init()))
        var document = SharedArea.Document()
        var edits: [SharedArea.Edit] = [.admit(agentItem, .init(id: .init(), object: agentItem.id, rect: .init(x: 0, y: 0, width: 520, height: 640), z: 1))]
        for (index, kind) in kinds.enumerated() {
            let item = tileItems[kind]!
            edits.append(.admit(item, .init(id: .init(), object: item.id, rect: .init(x: Double(index + 1) * 560, y: 0, width: 520, height: 640), z: 1)))
        }
        edits.append(.admit(markdownItem, .init(id: .init(), object: markdownItem.id, rect: .init(x: 2800, y: 0, width: 520, height: 640), z: 1)))
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: edits))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(dylan, .owner), (sam, .editor)])
        try await authority.setMemberLabel(dylan.person, "Dylan")
        let loop = Loopback()
        let hostController = try controller(root: rigRoot.appendingPathComponent("host"), identity: dylan, label: "Dylan",
                                            authority: authority, loop: loop, document: document)
        await hostController.open()
        try await SharedAreaCheckRig.eventually("the host's controller connects") { hostController.status == .connected }
        defer { Task { await hostController.close() } }

        var pairs: [Pair] = []
        var windows: [NSWindow] = []
        defer { for window in windows { window.orderOut(nil) } }
        func window(for view: NSView) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontOffscreenForChecks()
            windows.append(window)
            return window
        }
        var guestSessions: [() -> Void] = []
        defer { for close in guestSessions { close() } }

        // MARK: Agent

        let agentPair = try await agentPair(root: rigRoot, item: agentItem, hostID: hostID, dylan: dylan, sam: sam,
                                            authority: authority, loop: loop, document: document, hostController: hostController,
                                            window: { window(for: $0) }, sessions: &guestSessions)
        pairs.append(agentPair)

        // MARK: Note, file, diff, browser on the mounted host canvas

        let readme = projectRoot.appendingPathComponent("CheckoutState.swift")
        try "enum CheckoutState {\n    case cart, address, payment\n    case authorising, paid\n}\n".write(to: readme, atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "CheckoutState.swift"],
                          ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "commit", "-q", "-m", "start"]] {
            guard DiffLiveSource.git(arguments, root: projectRoot) != nil else { throw Failure(description: "git \(arguments[0]) failed") }
        }
        try "enum CheckoutState {\n    case cart, address, payment\n    case wallet\n    case authorising, paid\n    case declined, abandoned\n}\n"
            .write(to: readme, atomically: true, encoding: .utf8)
        guard case .spawned(_, let note) = spawner.spawnNote(title: "Checkout plan"),
              case .spawned(let file) = spawner.spawnFile(path: readme.path),
              case .spawned(let diff) = spawner.spawnDiffReview(sendCommentsToAgent: { _ in }),
              case .spawned(let browserRuntime) = spawner.spawnBrowser(url: "http://127.0.0.1:9/checkout") else {
            throw Failure(description: "a host tile did not spawn")
        }
        canvas.layoutSubtreeIfNeeded()
        guard let noteView = canvas.tileView(for: note) as? NoteTileNSView else { throw Failure(description: "no host note view") }
        noteView.textView.insertText("Checkout plan\n\n- Wallets get their own path\n- Declined goes back to Payment",
                                     replacementRange: NSRange(location: 0, length: 0))
        browserRuntime.webView.loadHTMLString(
            "<html><body style='font-family:-apple-system;background:#fff;margin:24px'><h1>Checkout</h1><p>Cart · Address · Payment</p><button>Pay now</button></body></html>",
            baseURL: URL(string: "http://127.0.0.1:9/checkout"))
        for _ in 0..<100 where browserRuntime.webView.isLoading || browserRuntime.webView.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(400))
        let markdownURL = projectRoot.appendingPathComponent("Plan.md")
        try "# Checkout\n\n- Wallets\n- Payment\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        guard case .spawned(let markdownTile) = spawner.spawnFile(path: markdownURL.path) else { throw Failure(description: "no markdown tile") }
        let tilesByKind: [Collaboration.LiveTile.Kind: UUID] = [.note: note, .file: file, .diff: diff, .browser: browserRuntime.tileId]
        let storage = rigRoot.appendingPathComponent("host-storage")
        var hosts: [LiveTileHost] = []
        defer { for host in hosts { host.stop() } }
        let fixtures = kinds.map { ($0, tileItems[$0]!, tilesByKind[$0]!, $0.rawValue) } + [(.file, markdownItem, markdownTile, "markdown-file")]
        for (kind, item, tileID, label) in fixtures {
            guard let hostTile = canvas.tileView(for: tileID) else { throw Failure(description: "\(kind) host tile has no view") }
            let binding = SharedAreaLocalSourceBinding(object: item.id, binding: item.source!.binding, host: hostID,
                                                       projectID: WorkspaceInvariantsFixture.projectA1, tileID: tileID)
            guard let source = app.makeLiveTileSource(binding, storage: storage) else {
                throw Failure(description: "\(kind): the production factory made no source for the host tile")
            }
            let host = LiveTileHost(binding: binding, source: source, controller: hostController)
            host.start(); hosts.append(host)

            let reference = SharedAgentTileReference(areaId: document.id.rawValue, objectId: item.id.rawValue, hostName: "Dylan",
                                                     hostPerson: dylan.person.rawValue, liveKind: kind.rawValue)
            let guestTile = SharedTileNSView(tile: Tile(id: UUID(), kind: .sharedTile, title: hostTile.tile.title,
                frame: .init(x: 0, y: 0, width: hostTile.frame.width, height: hostTile.frame.height), zPosition: .fromLegacyRank(1),
                runtimeRef: nil, metadata: .init(sharedTile: reference)))
            guestTile.frame = NSRect(origin: .zero, size: hostTile.frame.size)
            _ = window(for: guestTile)
            let guestController = try controller(root: rigRoot.appendingPathComponent("guest-\(label)"), identity: sam,
                                                 label: "Sam", authority: authority, loop: loop, document: document)
            let session = SharedTileSession(view: guestTile, reference: reference, controller: guestController)
            session.start()
            guestSessions.append { session.close() }
            // A document kind is compared document to document: the host's
            // body (a file's document, without the editor shell's sidebar)
            // with the guest's content under its caption.
            let document = documentKinds.contains(kind)
            pairs.append(Pair(kind: label, host: hostTile, guest: guestTile,
                              hostRegion: { [weak hostTile] in
                                  if document, let file = hostTile as? FileTileNSView { return file.qaDocumentBody }
                                  return hostTile?.contentView
                              },
                              guestRegion: { [weak guestTile] in
                                  if document, let surface = guestTile?.body?.qaContentSurface { return surface }
                                  return guestTile?.contentView
                              }))
        }

        // MARK: Board, through the portal (a board shares only inside one)

        guard case .spawned(let boardID, let boardTile) = spawner.spawnBoard(title: "Checkout launch") else {
            throw Failure(description: "the board did not spawn")
        }
        canvas.layoutSubtreeIfNeeded()
        guard let hostBoard = canvas.tileView(for: boardTile) as? KanbanTileNSView, let boards = hostBoard.boardRuntime,
              let lanes = boards.board(id: boardID)?.orderedColumns.map(\.id), lanes.count == 3 else {
            throw Failure(description: "no host board with three lanes")
        }
        for command in [
            BoardCommand.createTask(id: UUID(), columnId: lanes[0], title: "Wallets first", body: "## Plan\n\n- **Apple Pay** first",
                                    links: [.url("https://example.com/pr/12"), .agent(scene.agents[0])], assignee: scene.agents[0], after: nil, before: nil),
            .createTask(id: UUID(), columnId: lanes[1], title: "Receipt email", body: "", links: [], assignee: scene.agents[1], after: nil, before: nil),
            .createCard(id: UUID(), columnId: lanes[2], title: "Polish the toggle", after: nil, before: nil),
        ] {
            guard case .applied = boards.apply(command, to: boardID) else { throw Failure(description: "the host reducer refused a board fixture") }
        }
        let portalHost = SharedPortalHostContext(app: app, area: UUID())
        let boardKind = SharedPortalKinds.kind(for: .board)
        guard let boardRecord = portalHost.tile(boardTile), let boardDraft = try await boardKind.snapshot(tile: boardRecord, host: portalHost) else {
            throw Failure(description: "board: the portal kind published nothing")
        }
        let boardObject = SharedArea.ID<SharedArea.Object>()
        let capture = try boardDraft.capture(object: boardObject, parent: nil)
        var boardBytes: [String: Data] = [:]
        for entry in capture.manifest.entries where entry.coverage == .included {
            if let digest = entry.blob, let data = capture.blobs[digest] { boardBytes[entry.path] = data }
        }
        let boardRevision = Collaboration.Artifact.Record(manifest: capture.manifest, sequence: 1, publisher: dylan.person, host: hostID,
                                                          publishedAt: Date(), contentDigest: boardDraft.contentDigest)
        let boardGuestController = try controller(root: rigRoot.appendingPathComponent("guest-board"), identity: sam, label: "Sam",
                                                  authority: authority, loop: loop, document: document)
        let portalGuest = SharedPortalGuestContext(controller: boardGuestController, hostName: "Dylan", hostColour: .systemPurple)
        guard let boardItem = boardKind.makeView(entry: .init(object: boardObject, kind: .board, title: hostBoard.tile.title),
                                                 guest: portalGuest) as? SharedPortalBoardItemView else {
            throw Failure(description: "board: the guest draws a fallback card")
        }
        boardItem.frame = NSRect(origin: .zero, size: hostBoard.frame.size)
        boardItem.apply(contents: .init(record: try await loop.wire(boardRevision), bytes: try await loop.wire(boardBytes)))
        _ = window(for: boardItem)
        boardItem.layoutSubtreeIfNeeded()
        pairs.append(Pair(kind: "board", host: hostBoard, guest: boardItem.board,
                          hostRegion: { [weak hostBoard] in hostBoard?.contentView },
                          guestRegion: { [weak boardItem] in boardItem?.board.contentView },
                          notes: ["guest is a portal item: the host's KanbanTileNSView, read only (no add row, grip, chip menu glyph; hint says read only)"]))

        // Let every lane deliver: the guest bodies show their first state.
        try await SharedAreaCheckRig.eventually("every guest tile shows the host's content", attempts: 1600) {
            pairs.allSatisfy { pair in
                if let shared = pair.guest as? SharedTileNSView, let body = shared.body {
                    return shared.liveKind == .browser ? body.qaFrameSequence > 0 || body.browserMode == .follow : !body.qaText.isEmpty
                }
                return true
            }
        }
        // One content size on both sides. The guest's tile carries its own
        // chrome above the shared content (the ownership strip, the caption),
        // so its tile is grown by exactly that much; the report says by how much.
        for index in pairs.indices where pairs[index].kind == "markdown-file" || documentKinds.contains(where: { $0.rawValue == pairs[index].kind }) {
            let pair = pairs[index]
            pair.host.layoutSubtreeIfNeeded(); pair.guest.layoutSubtreeIfNeeded()
            guard let host = pair.hostRegion(), let guest = pair.guestRegion(), let window = pair.guest.window else { continue }
            let grow = NSSize(width: host.bounds.width - guest.bounds.width, height: host.bounds.height - guest.bounds.height)
            guard grow != .zero else { continue }
            window.setContentSize(NSSize(width: pair.guest.frame.width + grow.width, height: pair.guest.frame.height + grow.height))
            pair.guest.layoutSubtreeIfNeeded()
            pairs[index].notes.append(String(format: "guest tile grown by %.0f×%.0f pt for its own chrome, so both content regions are %.0f×%.0f pt",
                                             grow.width, grow.height, host.bounds.width, host.bounds.height))
        }
        try await Task.sleep(for: .milliseconds(600))

        // MARK: Compare

        var report: [String] = ["Shared tile parity: host vs guest, through the production share path (loopback relay, \(await loop.crossings) wire crossings).",
                                "Tolerance: \(Int(pixelTolerance * 100))% of pixels, \(channelTolerance)/255 per channel.", ""]
        var redKinds: [String] = []
        for pair in pairs {
            let result = try await compare(pair, directory: directory)
            report += result.lines + [""]
            for line in result.lines { print("PARITY \(line)") }
            if result.red { redKinds.append(pair.kind) }
        }
        let skipped = "terminal SKIPPED: a host terminal needs a tmux server and a Ghostty surface; this offline check never starts one (see HOW-TO-MERGE.md)"
        print("PARITY \(skipped)")
        report.append(skipped)
        try report.joined(separator: "\n").write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print("WROTE \(directory.appendingPathComponent("report.txt").path)")
        guard redKinds.isEmpty else {
            throw Failure(description: "host and guest differ for: \(redKinds.joined(separator: ", ")). Pictures and report in \(directory.path)")
        }
        print("PASS shared tile parity: every driven kind looks and reads the same on the guest as on the host, in light and dark")
    }

    // MARK: - The agent pair

    private static func agentPair(root: URL, item: SharedArea.Item, hostID: SharedArea.ID<SharedArea.Host>,
                                  dylan: Collaboration.Identity, sam: Collaboration.Identity,
                                  authority: SharedAreaCheckRig.Authority, loop: Loopback, document: SharedArea.Document,
                                  hostController: SharedAreaController, window: (NSView) -> NSWindow,
                                  sessions: inout [() -> Void]) async throws -> Pair {
        let agentRoot = root.appendingPathComponent("agents")
        let store = AgentStore(applicationSupportDirectory: agentRoot)
        let project = UUID(), agent = AgentID(rawValue: UUID())
        try store.upsert(AgentRecord(id: agent, displayName: "Map the checkout state machine", harness: .claudeCode,
                                     model: "fixture/parity", thinking: "medium", cwd: agentRoot.path, projectId: project,
                                     createdAt: Date(), lastActivityAt: Date()))
        // One attachment store for the supervisor and the tile, as the app has:
        // the screenshot the supervisor stores is the file the host tile shows.
        let attachments = AgentComposerAttachmentStore(applicationSupportDirectory: agentRoot)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil },
                                         attachmentStore: attachments,
                                         transcriptStore: AgentTranscriptStore(root: agentRoot.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()

        // The host's own tile, as the canvas wires it.
        let hostTile = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Map the checkout state machine",
            frame: .init(x: 0, y: 0, width: tileSize.width, height: tileSize.height), zPosition: .first, runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent")))
        hostTile.frame = NSRect(origin: .zero, size: tileSize)
        _ = window(hostTile)
        hostTile.bindV2ComposerState(draftStore: AgentComposerDraftStore(applicationSupportDirectory: agentRoot, attachmentStore: attachments),
                                     promptHistory: AgentPromptHistory(), attachmentStore: attachments)
        hostTile.attach(agentID: agent, supervisor: supervisor)

        // Published before the turn, as mode A does: what follows is live.
        let projection = SharedAreaAgentProjectionHost(supervisor: supervisor, controller: hostController)
        projection.sync([SharedAreaLocalSourceBinding(object: item.id, binding: item.source!.binding, host: hostID,
                                                      projectID: project, agentID: agent)])
        guard projection.projectors[item.id] != nil else {
            throw Failure(description: "agent: the production projection host made no projector (\(String(describing: projection.lastError)))")
        }

        let thread = AgentSupervisor.threadId(for: agent)
        func deliver(_ event: AgentRuntimeEvent) { supervisor.qaDeliver(event, to: agent) }
        deliver(.turnStarted(threadId: thread, turnId: "t1"))
        deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .reasoning, delta: "Find where checkout state lives before editing."))
        for chunk in ["I'll map the checkout ", "states first, ", "then add the wallet path."] {
            deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant, delta: chunk))
            await Task.yield()
        }
        deliver(.itemStarted(threadId: thread, itemId: "bash-1", kind: .commandExecution, title: "Bash: swift test --filter Checkout"))
        deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .commandOutput, delta: "Test Suite 'Checkout' passed\n"))
        deliver(.itemCompleted(threadId: thread, itemId: "bash-1", kind: .commandExecution, status: .completed))
        deliver(.itemStarted(threadId: thread, itemId: "read-1", kind: .commandExecution, title: "Read: Sources/Checkout/CheckoutState.swift"))
        deliver(.itemCompleted(threadId: thread, itemId: "read-1", kind: .commandExecution, status: .completed))
        deliver(.itemStarted(threadId: thread, itemId: "edit-1", kind: .fileChange, title: "Edit: Sources/Checkout/CheckoutState.swift"))
        deliver(.itemCompleted(threadId: thread, itemId: "edit-1", kind: .fileChange, status: .completed))
        deliver(.itemStarted(threadId: thread, itemId: "agent-1", kind: .subagent, title: "Agent: Audit the receipt email path"))
        deliver(.itemCompleted(threadId: thread, itemId: "agent-1", kind: .subagent, status: .completed))
        deliver(.itemStarted(threadId: thread, itemId: "agent-2", kind: .subagent, title: "Agent: Check the saved-card toggle"))
        deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant,
                              delta: "Wallet is in. One helper is still checking the saved-card toggle."))
        // An image in the transcript: the production browser-screenshot path.
        var notes: [String] = []
        do {
            let staged = try await supervisor.stageBrowserScreenshot(screenshotPNG(), for: agent)
            await supervisor.commitBrowserScreenshot(staged.manifest.metadata.id, for: agent)
            try supervisor.publishBrowserScreenshot(staged.manifest.metadata, for: agent)
        } catch {
            notes.append("fixture: the screenshot image could not be added (\(error))")
        }
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        await projection.flush()

        // The guest's tile, through the guest's own session.
        let reference = SharedAgentTileReference(areaId: document.id.rawValue, objectId: item.id.rawValue, hostName: "Dylan",
                                                 hostPerson: dylan.person.rawValue)
        let guestTile = SharedAgentTileNSView(tile: Tile(id: UUID(), kind: .sharedAgent, title: "Map the checkout state machine",
            frame: .init(x: 0, y: 0, width: tileSize.width, height: tileSize.height), zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: .init(sharedAgent: reference)))
        guestTile.frame = NSRect(origin: .zero, size: tileSize)
        _ = window(guestTile)
        let guestController = try controller(root: root.appendingPathComponent("guest-agent"), identity: sam, label: "Sam",
                                             authority: authority, loop: loop, document: document)
        let prompter = try SharedAgentHandoffController(identity: sam, transport: NoRoute(), directory: root.appendingPathComponent("handoff"))
        let session = SharedAgentTileSession(view: guestTile, reference: reference, controller: guestController, prompter: prompter)
        session.start()
        sessions.append { session.close(); projection.stop() }
        let head = projection.projectors[item.id]?.log.head
        try await SharedAreaCheckRig.eventually("the guest's agent view holds the host's projection", attempts: 1600) {
            session.live.replica.state != nil && session.live.replica.state == head
        }
        // The whole transcript, on its own lane: the guest holds the owner's document.
        let ownDocument = { supervisor.transcriptDocument(for: agent)?.entries.map(\.id) ?? [] }
        do {
            try await SharedAreaCheckRig.eventually("the guest's transcript lane holds the owner's document", attempts: 1600) {
                session.live.transcriptLive && session.live.transcriptView.qaMirrorDocument.entries.map(\.id) == ownDocument()
            }
        } catch {
            notes.append("transcript lane: guest \(session.live.transcriptView.qaMirrorDocument.entries.count) entries, owner \(ownDocument().count), live \(session.live.transcriptLive)")
        }

        // The tile's chrome, read off both tiles' views (agent-chrome).
        try? await SharedAreaCheckRig.eventually("the guest's tile shows the host's chrome", attempts: 400) {
            session.live.chrome != nil
        }
        guestTile.applyHostChrome()
        let hostFacts = hostTile.qaChromeFacts, guestFacts = guestTile.qaChromeFacts
        let chromeDifferences = SharedAgentChromeChecks.comparedFacts.filter { hostFacts[$0] != guestFacts[$0] }
            .map { "\($0): host \(hostFacts[$0] ?? "nil") · guest \(guestFacts[$0] ?? "nil")" }
        notes.append("chrome: \(SharedAgentChromeChecks.comparedFacts.count - chromeDifferences.count) of \(SharedAgentChromeChecks.comparedFacts.count) facts match")
        let blocks = hostTile.qaDocumentForChecks.entries.flatMap { entry in entry.blocks.map { "\(entry.role)/\($0.kind)" } }
        notes.append("host blocks: " + blocks.joined(separator: ", "))
        return Pair(kind: "agent", host: hostTile, guest: guestTile,
                    hostRegion: { [weak hostTile] in hostTile?.qaTranscriptSurface.map { $0 as NSView } ?? hostTile?.contentView },
                    guestRegion: { [weak guestTile] in
                        guard let guestTile else { return nil }
                        let all = SharedAreaCheckRig.descendants(guestTile)
                        if let surface = all.first(where: { $0 is any AgentTranscriptSurface && !$0.isHiddenOrHasHiddenAncestor }) { return surface }
                        // Today's guest: a plain text view inside the live view.
                        return all.first { $0 is SharedAgentLiveView }.flatMap { live in
                            SharedAreaCheckRig.descendants(live).first { $0 is NSScrollView }
                        }
                    },
                    notes: notes,
                    // The host stored the screenshot and the guest received its
                    // bytes: both Macs hold the picture, so both must say so.
                    mustShow: ["· Available locally"], chromeDifferences: chromeDifferences)
    }

    /// A small picture for the transcript's image block: the production
    /// screenshot path takes PNG bytes.
    static func screenshotPNG() -> Data {
        let image = NSImage(size: NSSize(width: 320, height: 200), flipped: true) { rect in
            NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill(); rect.fill()
            NSColor(srgbRed: 0.49, green: 0.76, blue: 0.86, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 24, y: 120, width: 140, height: 44), xRadius: 8, yRadius: 8).fill()
            ("Checkout" as NSString).draw(at: NSPoint(x: 24, y: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold)])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: - Comparison

    static func compare(_ pair: Pair, directory: URL) async throws -> Comparison {
        var result = Comparison(kind: pair.kind)
        guard let host = pair.hostRegion(), let guest = pair.guestRegion() else {
            result.red = true
            result.lines = ["\(pair.kind) RED: no content region (host \(pair.hostRegion().map { "\(type(of: $0))" } ?? "none"), guest \(pair.guestRegion().map { "\(type(of: $0))" } ?? "none"))"]
            return result
        }
        var lines: [String] = []

        // View classes.
        let hostClasses = classes(host), guestClasses = classes(guest)
        let classesMatch = hostClasses == guestClasses
        lines.append("  view class: host \(type(of: host)) · guest \(type(of: guest))" + (classesMatch ? " (same subtree classes)" : ""))
        if !classesMatch {
            lines.append("    host only: \(hostClasses.subtracting(guestClasses).sorted().joined(separator: ", "))")
            lines.append("    guest only: \(guestClasses.subtracting(hostClasses).sorted().joined(separator: ", "))")
        }

        // Elements.
        let hostElements = elements(host), guestElements = elements(guest)
        let missing = subtract(hostElements, guestElements), extra = subtract(guestElements, hostElements)
        let elementsMatch = missing.isEmpty && extra.isEmpty
        lines.append("  elements: host \(hostElements.count) · guest \(guestElements.count)" + (elementsMatch ? " (same)" : ""))
        for line in missing.prefix(16) { lines.append("    missing on guest: \(quoted(line))") }
        if missing.count > 16 { lines.append("    … \(missing.count - 16) more missing") }
        for line in extra.prefix(16) { lines.append("    only on guest: \(quoted(line))") }
        if extra.count > 16 { lines.append("    … \(extra.count - 16) more only on guest") }

        var shown = true
        for ending in pair.mustShow {
            for (side, list) in [("host", hostElements), ("guest", guestElements)] {
                let found = list.first { $0.hasSuffix(ending) }
                lines.append("  must show \(quoted(ending)): \(side) " + (found.map { "shows \(quoted($0))" } ?? "does not RED"))
                if found == nil { shown = false }
            }
        }

        // Pixels, light and dark.
        var pixelsMatch = true
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let name = appearance == .aqua ? "light" : "dark"
            // The app's appearance too: the code editor follows it, as it
            // does for a person who switches their Mac to dark.
            NSApp.appearance = NSAppearance(named: appearance)
            for view in [pair.host, pair.guest] { view.window?.appearance = NSAppearance(named: appearance) }
            // Offscreen windows can defer appearance notifications. Resolve the
            // owners' normal token hooks before taking the document still.
            pair.host.applyTokens()
            (pair.guest as? SharedTileNSView)?.body?.viewDidChangeEffectiveAppearance()
            try await Task.sleep(for: .milliseconds(200))
            guard let hostPicture = await picture(host), let guestPicture = await picture(guest) else {
                lines.append("  pixels \(name): no bitmap"); pixelsMatch = false; continue
            }
            // Control: the host pictured again must match itself, or a RED
            // below could be the capture, not the share.
            if let again = await picture(host), diff(hostPicture, again).0 > pixelTolerance {
                throw Failure(description: "\(pair.kind) \(name): the host region does not render stably; the witness cannot judge it")
            }
            let (fraction, diffPicture) = diff(hostPicture, guestPicture)
            let stem = "\(pair.kind)-\(name)"
            for (suffix, rep) in [("host", hostPicture), ("guest", guestPicture), ("diff", diffPicture)] {
                try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(stem)-\(suffix).png"))
            }
            let ok = fraction <= pixelTolerance
            if !ok { pixelsMatch = false }
            lines.append(String(format: "  pixels %@: %.1f%% differ (host %dx%d, guest %dx%d)%@ → %@-{host,guest,diff}.png", name, fraction * 100,
                                hostPicture.pixelsWide, hostPicture.pixelsHigh, guestPicture.pixelsWide, guestPicture.pixelsHigh,
                                ok ? "" : " RED", stem))
        }
        NSApp.appearance = nil
        for note in pair.notes { lines.append("  note: \(note)") }
        for difference in pair.chromeDifferences { lines.append("  chrome differs: \(difference)") }
        result.red = !(classesMatch && elementsMatch && shown && pixelsMatch) || !pair.chromeDifferences.isEmpty
        result.lines = ["\(pair.kind) \(result.red ? "RED" : "GREEN")"] + lines
        return result
    }

    /// Distinct Array-owned view classes under `root`, visible ones only.
    /// AppKit's own (scrollers, clip views) are the same machinery either way.
    static func classes(_ root: NSView) -> Set<String> {
        var names: Set<String> = [String(describing: type(of: root))]
        for view in SharedAreaCheckRig.descendants(root) where !view.isHiddenOrHasHiddenAncestor {
            let name = String(describing: type(of: view))
            if name.hasPrefix("NS") || name.hasPrefix("_") || name.hasPrefix("WK") { continue }
            names.insert(name)
        }
        return names
    }

    /// What each surface lays out, in reading order: text lines, and a marker
    /// for each page, still or picture.
    static func elements(_ root: NSView) -> [String] {
        var out: [String] = []
        func add(_ text: String) {
            for line in text.split(whereSeparator: \.isNewline) {
                let clean = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !clean.isEmpty { out.append(clean) }
            }
        }
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            switch view {
            case let canvas as AgentTranscriptCanvasView: add(canvas.qaLaidOutText)
            case let text as NSTextView: add(text.string); return
            case let field as NSTextField: add(field.stringValue)
            case let image as NSImageView where image.image != nil: out.append("[image]")
            case is WKWebView: out.append("[page]"); return
            case let frame as LiveTileFrameView: out.append("[still]"); _ = frame
            default: break
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return out
    }

    /// `a` minus `b`, as multisets, keeping `a`'s order.
    static func subtract(_ a: [String], _ b: [String]) -> [String] {
        var remaining: [String: Int] = [:]
        for line in b { remaining[line, default: 0] += 1 }
        return a.filter { line in
            guard let count = remaining[line], count > 0 else { return true }
            remaining[line] = count - 1
            return false
        }
    }

    static func quoted(_ line: String) -> String {
        "\"" + (line.count > 100 ? String(line.prefix(99)) + "…" : line) + "\""
    }

    /// The region as drawn, off screen. A web view paints out of process, so
    /// its own snapshot is laid over the cached display.
    static func picture(_ view: NSView) async -> NSBitmapImageRep? {
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        CATransaction.begin(); view.display(); CATransaction.commit(); CATransaction.flush()
        guard view.bounds.width > 0, view.bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        // A document can be transparent over its tile. Include that backing
        // colour in the still, as it appears on the canvas.
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            SurfaceToken.tileBody.color.nsColor(in: view).setFill()
            NSRect(origin: .zero, size: rep.size).fill(using: .destinationOver)
            NSGraphicsContext.restoreGraphicsState()
        }
        let webs = SharedAreaCheckRig.descendants(view).compactMap { $0 as? WKWebView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        guard !webs.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
        for web in webs {
            guard let image = try? await web.takeSnapshot(configuration: nil) else { continue }
            var rect = web.convert(web.bounds, to: view)
            if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep
    }

    /// Share of differing pixels over the larger of the two pictures (area only
    /// one covers counts as differing), and a picture of where: red differs,
    /// grey is the host's picture dimmed.
    static func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Double, NSBitmapImageRep) {
        let width = max(a.pixelsWide, b.pixelsWide), height = max(a.pixelsHigh, b.pixelsHigh)
        func canvas(_ source: NSBitmapImageRep?) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: width * 4, bitsPerPixel: 32)!
            rep.size = NSSize(width: width, height: height)
            if let source, let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
                source.draw(in: NSRect(x: 0, y: height - source.pixelsHigh, width: source.pixelsWide, height: source.pixelsHigh))
                NSGraphicsContext.restoreGraphicsState()
            }
            return rep
        }
        let left = canvas(a), right = canvas(b), out = canvas(nil)
        guard let l = left.bitmapData, let r = right.bitmapData, let o = out.bitmapData else { return (1, out) }
        var differing = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            var differs = false
            for channel in 0..<3 where abs(Int(l[index + channel]) - Int(r[index + channel])) > channelTolerance { differs = true }
            if differs {
                differing += 1
                o[index] = 255; o[index + 1] = 0; o[index + 2] = 0; o[index + 3] = 255
            } else {
                let grey = UInt8((Int(l[index]) + Int(l[index + 1]) + Int(l[index + 2])) / 9)
                o[index] = grey; o[index + 1] = grey; o[index + 2] = grey; o[index + 3] = 255
            }
        }
        return (Double(differing) / Double(max(1, width * height)), out)
    }
}
