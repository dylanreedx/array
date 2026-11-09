import AppKit
import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-agent-chrome-check [dir]`: the other person's tile for a shared
/// agent shows the host tile's chrome, from the host's facts.
///
/// Host: a production supervisor, the production projection host (which starts
/// the transcript publisher and its chrome builder), and a real
/// `ManagedAgentTileNSView`. Relay: the lane's own `Log`. Guest: a
/// `SharedAgentTileNSView` with a `SharedAgentLiveView` polling the lane.
/// Asserted, read off both tiles' views: title, provider mark, status, identity
/// tint, under-bar header, status row, harness/model/effort chips, the primary
/// action, a read-only composer with its reason, the ⋯ menu's disabled items;
/// the host's own character set reaches the guest pixel for pixel, survives a
/// guest set with the same id, and an invalid, oversized or missing set falls
/// back to the built-in one. Light and dark stills go to `dir`.
@MainActor
enum SharedAgentChromeChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    typealias Lane = Collaboration.AgentTranscript
    typealias Wire = SharedAgentTranscriptWire

    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: label) }
        print("PASS shared agent chrome: \(label)")
    }

    /// The facts both tiles must agree on.
    static let comparedFacts = [
        "title", "title.providerModel", "title.providerMark", "title.status", "title.statusLabel", "title.tint",
        "title.character", "header.state", "header.branch", "header.managed", "status.accessibility",
        "footer.harness", "footer.model", "footer.thinking", "action.kind", "action.title",
    ]

    static func setFile(id: String, bodyColour: String) throws -> Data {
        guard let url = AgentCharacterBundled.themeURL else { throw Failure(description: "no built-in set") }
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"id\":\"ducks-classic\"", with: "\"id\":\"\(id)\"")
        // The eye: no character overrides it, so every character changes.
        text = text.replacingOccurrences(of: "\"k\":\"#2B1A10\"", with: "\"k\":\"\(bodyColour)\"")
        return Data(text.utf8)
    }

    /// What the character layer draws now: its atlas's pixels and the frame it shows.
    static func drawn(_ layer: CharacterSpriteLayer?) -> (pixels: [UInt8], frame: CGRect)? {
        guard let layer, let sprite = layer.sprite else { return nil }
        return (sprite.atlas.pixels, layer.contentsRect)
    }

    static func run(directory: URL) async throws {
        let root = try SharedAreaCheckRig.root("shared-agent-chrome")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Characters on, with the host's own set selected (never `.standard`).
        let imports = root.appendingPathComponent("characters", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let suite = "ArraySharedAgentChromeChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let characters = AgentCharacterController.shared
        characters.reduceMotion = { true }
        characters.windowIsVisible = { _ in true }
        characters.importsDirectory = imports
        let setID = "chrome-check-set"
        let hostSet = try setFile(id: setID, bodyColour: "#3B6BFF")
        try hostSet.write(to: imports.appendingPathComponent("\(setID).theme.json"))
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        defaults.set(setID, forKey: AgentCharacterConfig.themeKey)
        characters.adopt(defaults: defaults)
        try expect(characters.theme?.id == setID, "the host draws its own set (\(characters.theme?.id ?? "none"))")
        SharedAgentCharacterSets.qaReset()

        // Host: supervisor, record, a turn in flight with a context reading.
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID(), agent = AgentID(rawValue: UUID())
        var record = AgentRecord(id: agent, displayName: "Map the checkout states", harness: .claudeCode, model: "fixture/chrome",
                                 thinking: "medium", cwd: root.path, projectId: project, createdAt: Date(), lastActivityAt: Date())
        record.identityColor = "purple"
        try store.upsert(record)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { print("supervisor: \($0)") }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        supervisor.publishCharacterPacks()
        let thread = AgentSupervisor.threadId(for: agent)
        func deliver(_ event: AgentRuntimeEvent) { supervisor.qaDeliver(event, to: agent) }

        let hostID = SharedArea.ID<SharedArea.Host>(), object = SharedArea.ID<SharedArea.Object>()
        let lane = SharedAgentTranscriptParityChecks.LaneSink(host: hostID)
        let projection = SharedAgentTranscriptParityChecks.ProjectionSink()
        let projectionHost = SharedAreaAgentProjectionHost(supervisor: supervisor, directory: root, makeSink: { _ in projection },
                                                           makeTranscriptSink: { _, _ in lane })
        projectionHost.sync([.init(object: object, binding: .init(), host: hostID, projectID: project, agentID: agent)])
        guard let publisher = projectionHost.transcripts[object] else { throw Failure(description: "no transcript publisher") }
        publisher.stop()
        defer { projectionHost.stop() }

        // The host's tile is on its canvas while the agent runs, as in production.
        let size = NSSize(width: 520, height: 640)
        let hostTile = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Map the checkout states",
            frame: .init(x: 0, y: 0, width: Double(size.width), height: Double(size.height)), zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent")), threadId: thread)
        hostTile.frame = NSRect(origin: .zero, size: size)
        hostTile.attach(agentID: agent, supervisor: supervisor)
        // A provider-started turn: the presence opens its own submission.
        deliver(.turnStarted(threadId: thread, turnId: "t1"))
        deliver(.contextWindowUpdated(threadId: thread, snapshot: AgentContextWindowSnapshot(
            usedTokens: 92_000, maxTokens: 200_000, observedAt: Date(), source: .claudeAssistantUsage, freshness: .live)))
        deliver(.itemStarted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, title: "Bash: swift test --filter Checkout"))
        deliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant, delta: "Mapping the states first."))
        for _ in 0..<20 { await Task.yield() }


        // Guest: the tile and its live view, reading the relay's lane.
        let me = Collaboration.Identity(person: .init(), device: UUID()), owner = Collaboration.Identity(person: .init(), device: UUID())
        let item = SharedArea.Item(id: object, kind: .agentObservation, source: .init(owner: owner.person, host: hostID, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 520, height: 640), z: 1))]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (owner, .owner)])
        try await authority.setMemberLabel(owner.person, "Dylan")
        let controller = try SharedAreaCheckRig.controller(root: root.appendingPathComponent("guest"), identity: me, label: "Sam",
                                                           authority: authority, seed: (document, .editor))
        func makeGuest(read: SharedAgentLiveView.TranscriptReader? = nil) -> (SharedAgentTileNSView, SharedAgentLiveView) {
            let reference = SharedAgentTileReference(areaId: document.id.rawValue, objectId: object.rawValue, hostName: "Dylan",
                                                     hostPerson: owner.person.rawValue)
            let tile = SharedAgentTileNSView(tile: Tile(id: UUID(), kind: .sharedAgent, title: "Map the checkout states",
                frame: .init(x: 0, y: 0, width: Double(size.width), height: Double(size.height)), zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: .init(sharedAgent: reference)))
            tile.frame = NSRect(origin: .zero, size: size)
            let live = SharedAgentLiveView(controller: controller,
                read: { _, cursor in
                    guard let log = projection.log else { throw Failure(description: "no projection") }
                    return log.read(after: cursor)
                },
                readTranscript: read ?? { _, request in try lane.read(request) })
            tile.install(live: live)
            tile.apply(SharedAgentTileNSView.State.live, hostName: "Dylan", colour: NSColor.systemOrange)
            live.show(object: object, in: document)
            live.stop()
            return (tile, live)
        }
        let (guestTile, guest) = makeGuest()

        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        canvas.wantsLayer = true
        hostTile.frame.origin = NSPoint(x: 20, y: 30); guestTile.frame.origin = NSPoint(x: 560, y: 30)
        canvas.addSubview(hostTile); canvas.addSubview(guestTile)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        func paint() async throws {
            for _ in 0..<3 {
                canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded(); CATransaction.flush()
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        func sync() async throws {
            for _ in 0..<10 { await Task.yield() }
            await publisher.tick()
            _ = await guest.pollTranscript(object, ticket: guest.qaTicket, waitMilliseconds: 0)
            await guest.poll(object, ticket: guest.qaTicket)
            try await paint()
        }

        // Negative control: before the host's chrome arrives, the guest tile
        // shows its own placeholder chrome, not the host's.
        try await paint()
        try expect(guestTile.qaChromeFacts["title"] != hostTile.qaChromeFacts["title"],
                   "before the chrome op the guest's title is not the host's (\(guestTile.qaChromeFacts["title"] ?? ""))")

        try await sync()
        try expect(guest.chrome != nil && publisher.publishedChrome != nil, "the host's chrome travels on the transcript lane")
        func compareFacts(_ label: String) throws {
            let host = hostTile.qaChromeFacts, shown = guestTile.qaChromeFacts
            let differing = comparedFacts.filter { host[$0] != shown[$0] }
            try expect(differing.isEmpty, "\(label): the guest tile's chrome is the host's, fact for fact"
                       + (differing.isEmpty ? " (\(comparedFacts.count) facts)" : ": " + differing.map { "\($0) host \(host[$0] ?? "nil") guest \(shown[$0] ?? "nil")" }.joined(separator: "; ")))
        }
        try compareFacts("working")
        let hostFacts = hostTile.qaChromeFacts
        try expect(hostFacts["title"] == "Map the checkout states" && hostFacts["title.tint"] != "" && hostFacts["header.state"] == "Working"
                   && hostFacts["action.title"] == "Working" && hostFacts["footer.model"] == "fixture/chrome"
                   && hostFacts["status.accessibility"]?.contains("46 percent") == true && hostFacts["title.character"] == "shown",
                   "the compared facts are live: name, purple wash, Working, model chip, a 46% meter and a character")
        try expect(!guest.strip.action.presentation.isEnabled,
                   "the guest's primary action is the host's, and nothing here can act on the host's turn")
        try expect(guest.strip.composer.readOnlyReason?.isEmpty == false && !guest.offersComposer && !guest.strip.composer.textView.isEditable,
                   "a guest who may not prompt from here gets a read-only composer that says why (\(guest.strip.composer.readOnlyReason ?? "nil"))")
        let action = guest.strip.action
        try expect(!action.isEnabled && action.alphaValue == ComposerActionButton.disabledAlpha
                   && action.toolTip == guest.strip.composer.readOnlyReason && action.accessibilityHelp() == guest.strip.composer.readOnlyReason,
                   "a view-only guest's action looks disabled, like the provider chips, and gives the composer's reason (alpha \(action.alphaValue), \(action.toolTip ?? "no tooltip"))")
        try expect(hostTile.qaPageZoomActionButton?.alphaValue == 1,
                   "control: the host's own resting action keeps full strength")

        // The ⋯ menu: the host's items, each disabled with a reason; Stop too.
        let menu = guestTile.qaTileContextMenu()?.items ?? []
        let named = ["Rename", "Color", AgentCharacterCopy.menu, "Sounds", "Workspace Tools", "Stop agent run"]
        let shownItems = menu.filter { named.contains($0.title) }
        try expect(shownItems.count == named.count && shownItems.allSatisfy {
            !$0.isEnabled && (($0 as? ChoiceDetailMenuItem)?.detail?.isEmpty == false)
        }, "the guest's ⋯ menu offers the host's actions disabled, each with a reason")
        // Compact: the host's control, which nothing on the guest can run.
        let guestRow = guest.strip.statusRow
        var compactRequests = 0
        guestRow.onCompactContextRequested = { compactRequests += 1 }
        guestRow.qaPerformCompactContextAction()
        guestRow.onCompactContextRequested = nil
        // Whether it shows depends on the row's width; disabled and inert it must always be.
        try expect(!guestRow.qaCompactContextButtonEnabled && compactRequests == 0,
                   "the guest's Compact is disabled and pressing it asks for nothing (visible \(guestRow.qaCompactContextButtonVisible), enabled \(guestRow.qaCompactContextButtonEnabled), requests \(compactRequests))")

        // The character: the host's own set, pixel for pixel.
        guard let hostDrawn = drawn(hostTile.qaCharacterLayer), let guestDrawn = drawn(guestTile.qaCharacterLayer) else {
            throw Failure(description: "a title bar shows no character (host \(hostTile.qaCharacterLayer?.sprite != nil), guest \(guestTile.qaCharacterLayer?.sprite != nil))")
        }
        try expect(guest.characterSet?.fallbackReason == nil && guest.characterSet?.key.hasPrefix("shared:") == true,
                   "the guest validated the host's set and keys it by hash (\(guest.characterSet?.key ?? "none"))")
        try expect(hostDrawn.pixels == guestDrawn.pixels && hostDrawn.frame == guestDrawn.frame,
                   "the guest draws the host's character in the host's set, pixel for pixel")
        let builtIn = AgentCharacterBundled.theme()!
        let assignment = characters.assignment(for: agent.rawValue)!
        let duck = AgentCharacterAtlas(theme: builtIn, character: assignment.index,
                                       appearance: AgentCharacterController.appearance(of: guestTile))
        try expect(duck.pixels != guestDrawn.pixels, "control: the built-in set's character differs, so the set really travelled")

        // A guest set with the same id cannot stand in for the host's.
        try setFile(id: setID, bodyColour: "#FF2E88").write(to: imports.appendingPathComponent("\(setID).theme.json"))
        characters.userThemesChangedOnDisk()
        guestTile.applyHostChrome(); hostTile.applyTokens()
        try await paint()
        let local = characters.atlas(for: agent.rawValue, appearance: AgentCharacterController.appearance(of: guestTile))
        try expect(local != nil && local!.atlas.pixels != hostDrawn.pixels,
                   "control: this Mac's own set with the same id now draws different pixels (the pre-fix guest path)")
        try expect(drawn(guestTile.qaCharacterLayer)?.pixels == hostDrawn.pixels,
                   "the guest still draws the host's set, not its own set with the same id")
        try hostSet.write(to: imports.appendingPathComponent("\(setID).theme.json"))
        characters.userThemesChangedOnDisk()

        // Turn ends: status, Stop and tail follow, and still agree.
        let checkpointsBefore = publisher.checkpoints, framesBefore = guest.transcriptView.appliedFrames
        deliver(.itemCompleted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, status: .completed))
        deliver(.turnCompleted(threadId: thread, turnId: "t1", outcome: .completed, errorMessage: nil))
        try await sync()
        print("after the turn: published \(publisher.publishedChrome?.header.stateLabel ?? "nil"), guest \(guest.chrome?.header.stateLabel ?? "nil"), supervisor \(String(describing: supervisor.turnSnapshot(for: agent)?.state)), error \(String(describing: publisher.lastError)), chrome ops \(publisher.chromeOps)")
        try compareFacts("after the turn")
        try expect(guestTile.qaChromeFacts["action.kind"] != "stop", "the Stop goes when the host's turn ends")
        try expect(publisher.checkpoints == checkpointsBefore && guest.transcriptView.appliedFrames > framesBefore,
                   "the turn's end reached the guest's chrome in streamed frames, not a new checkpoint (\(publisher.checkpoints - checkpointsBefore) checkpoints, \(guest.transcriptView.appliedFrames - framesBefore) frames)")

        // A late joiner and a resnapshot get the chrome and the set from the checkpoint alone.
        SharedAgentCharacterSets.qaReset()
        let (lateTile, late) = makeGuest()
        canvas.addSubview(lateTile); lateTile.frame.origin = NSPoint(x: 0, y: 700)
        _ = await late.pollTranscript(object, ticket: late.qaTicket, waitMilliseconds: 0)
        await late.poll(object, ticket: late.qaTicket)
        try await paint()
        try expect(late.characterSet?.fallbackReason == nil && drawn(lateTile.qaCharacterLayer)?.pixels == hostDrawn.pixels,
                   "a late joiner draws the host's set from the checkpoint")
        lateTile.removeFromSuperview()

        // Stills, before the fallback cases change the set.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            canvas.layer?.backgroundColor = SurfaceToken.canvas.color.nsColor(for: appearance == .aqua ? .light : .dark).cgColor
            try await paint()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw Failure(description: "no bitmap") }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            let url = directory.appendingPathComponent("agent-chrome-\(appearance == .aqua ? "light" : "dark").png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("WROTE \(url.path)")
        }
        window.appearance = NSAppearance(named: .aqua)

        // A large set: a Duckherd-shaped set (scale 4, 16 helpers) deflates past
        // the 32 KiB one op may carry, so it follows a checkpoint in parts. The
        // guest, and a late joiner, draw it pixel for pixel. A real shared set
        // named by CONTINUUM_DUCKHERD_THEME_FILE is tried the same way (local runs).
        var large: [(label: String, data: Data)] = [("duckherd-shaped", Data(AgentCharacterDuckherdFixture.text().utf8))]
        if let path = ProcessInfo.processInfo.environment["CONTINUUM_DUCKHERD_THEME_FILE"], !path.isEmpty {
            large.append(("local-file", try Data(contentsOf: URL(fileURLWithPath: path))))
        }
        for (label, data) in large {
            guard case let .success(parsed) = AgentCharacterThemeParser.parse(data: data) else {
                throw Failure(description: "\(label): the large set does not parse")
            }
            try data.write(to: imports.appendingPathComponent("\(parsed.id).theme.json"))
            characters.userThemesChangedOnDisk()
            defaults.set(parsed.id, forKey: AgentCharacterConfig.themeKey)
            characters.reload()
            try expect(characters.theme?.id == parsed.id, "\(label): the host draws the large set")
            SharedAgentCharacterSets.qaReset()
            hostTile.applyTokens()
            let checkpoints = publisher.checkpoints
            try await sync()
            let hash = Wire.CharacterTheme.hash(data)
            try expect(guest.characterSet?.fallbackReason == nil && guest.characterSet?.key == "shared:" + hash,
                       "\(label): the guest draws the host's large set, not a fallback (\(guest.characterSet?.fallbackReason ?? guest.characterSet?.key ?? "none"))")
            try expect(publisher.checkpoints > checkpoints, "\(label): the large set followed a checkpoint")
            guard let hostLarge = drawn(hostTile.qaCharacterLayer), let guestLarge = drawn(guestTile.qaCharacterLayer) else {
                throw Failure(description: "\(label): a title bar shows no character")
            }
            try expect(hostLarge.pixels == guestLarge.pixels && hostLarge.frame == guestLarge.frame
                       && guestLarge.pixels != hostDrawn.pixels,
                       "\(label): the guest draws the host's large-set character, pixel for pixel")
            SharedAgentCharacterSets.qaReset()
            let (lateTile, late) = makeGuest()
            canvas.addSubview(lateTile); lateTile.frame.origin = NSPoint(x: 0, y: 700)
            _ = await late.pollTranscript(object, ticket: late.qaTicket, waitMilliseconds: 0)
            await late.poll(object, ticket: late.qaTicket)
            try await paint()
            try expect(late.characterSet?.key == "shared:" + hash && drawn(lateTile.qaCharacterLayer)?.pixels == hostLarge.pixels,
                       "\(label): a late joiner draws the large set from the checkpoint and its parts")
            lateTile.removeFromSuperview()
            if label == "duckherd-shaped" {
                // Paced: the parts ride one checkpoint, not every checkpoint. A
                // later checkpoint inside the interval carries none (guests keep
                // the set); one past the interval carries them again.
                func partFrames() throws -> Int {
                    try (lane.log?.frames ?? []).reduce(0) { count, frame in
                        count + (try JSONDecoder().decode(Wire.Patch.self, from: frame.body).ops
                            .filter { if case .characterThemePart = $0 { return true }; return false }.count)
                    }
                }
                let sentParts = try partFrames()
                try expect(sentParts > 1, "\(label): the checkpoint after the set changed carried its \(sentParts) parts")
                publisher.qaRequestCheckpoint()
                let before = publisher.checkpoints
                try await sync()
                let resent = try partFrames()
                try expect(publisher.checkpoints == before + 1 && resent == 0
                           && guest.characterSet?.key == "shared:" + hash && drawn(guestTile.qaCharacterLayer)?.pixels == hostLarge.pixels,
                           "\(label): a later checkpoint inside \(Int(SharedAgentTranscriptPublisher.themePartsResendInterval)) s re-sends no parts (\(resent)) and the guest keeps drawing the set")
                SharedAgentCharacterSets.qaReset()
                let (earlyTile, early) = makeGuest()
                _ = await early.pollTranscript(object, ticket: early.qaTicket, waitMilliseconds: 0)
                await early.poll(object, ticket: early.qaTicket)
                try expect(early.characterSet?.key.hasPrefix("builtin:") == true && early.characterSet?.fallbackReason != nil,
                           "\(label): a joiner after that checkpoint draws the built-in set until the parts are due again (\(early.characterSet?.fallbackReason ?? "none"))")
                earlyTile.removeFromSuperview()
                let later = Date().addingTimeInterval(SharedAgentTranscriptPublisher.themePartsResendInterval + 1)
                publisher.qaNow = { later }
                publisher.qaRequestCheckpoint()
                try await sync()
                let due = try partFrames()
                SharedAgentCharacterSets.qaReset()
                let (dueTile, dueGuest) = makeGuest()
                canvas.addSubview(dueTile); dueTile.frame.origin = NSPoint(x: 0, y: 700)
                _ = await dueGuest.pollTranscript(object, ticket: dueGuest.qaTicket, waitMilliseconds: 0)
                await dueGuest.poll(object, ticket: dueGuest.qaTicket)
                try await paint()
                try expect(due == sentParts && dueGuest.characterSet?.key == "shared:" + hash
                           && drawn(dueTile.qaCharacterLayer)?.pixels == hostLarge.pixels,
                           "\(label): past the interval the next checkpoint carries the \(sentParts) parts again and a late joiner draws the set (\(due))")
                dueTile.removeFromSuperview()
                publisher.qaNow = Date.init
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                canvas.layer?.backgroundColor = SurfaceToken.canvas.color.nsColor(for: appearance == .aqua ? .light : .dark).cgColor
                try await paint()
                guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw Failure(description: "no bitmap") }
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
                let url = directory.appendingPathComponent("agent-chrome-large-\(label)-\(appearance == .aqua ? "light" : "dark").png")
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                print("WROTE \(url.path)")
            }
            window.appearance = NSAppearance(named: .aqua)
        }
        // Back to the small set for the fallbacks.
        defaults.set(setID, forKey: AgentCharacterConfig.themeKey)
        characters.reload()
        SharedAgentCharacterSets.qaReset()
        try await sync()
        try expect(guest.characterSet?.fallbackReason == nil && drawn(guestTile.qaCharacterLayer)?.pixels == hostDrawn.pixels,
                   "switching back, the guest draws the small set again")

        // Fallbacks: an invalid, an oversized and a missing set draw the built-in one.
        guard let chrome = guest.chrome, let reference = chrome.character?.theme else { throw Failure(description: "no chrome") }
        // The upper theme bound beside the maximum image payload must still
        // leave a replayable checkpoint (base64 metadata counts too).
        let attachment = AgentImageAttachmentID(rawValue: "theme-budget-image")!
        let block = AgentBlock(id: AgentNodeID(rawValue: "theme-budget-block")!, kind: .imageGallery,
            payload: .imageGallery(.init(images: [.init(attachment: .init(id: attachment))])))
        let entry = AgentEntry(id: AgentNodeID(rawValue: "theme-budget-entry")!, role: .user,
            provenance: .localNotice(reason: "budget fixture"), lifecycle: .finished, blocks: [block])
        let maxTheme = Wire.CharacterTheme(hash: String(repeating: "a", count: 64),
                                           deflated: Data(count: Wire.CharacterTheme.maximumSharedDeflatedBytes))
        let budgetState = SharedAgentTranscriptPublisher.State(current: .init(version: 1, entries: [entry]),
            roster: nil, details: [:], images: [attachment: Data(count: SharedAgentTranscriptImages.maxTotalBytes)],
            budget: SharedAgentTranscriptSafeBudget(), published: [], publishedDetails: [:], publishedImages: [:],
            publishedHelpers: nil, lastVersion: nil, needsCheckpoint: true, bytesSinceCheckpoint: 0,
            chrome: (chrome: chrome, theme: maxTheme), chromeChanged: true, sentThemes: [])
        guard case let .checkpoint(budgetPlan) = try SharedAgentTranscriptPublisher.plan(budgetState) else {
            throw Failure(description: "maximum budget did not checkpoint")
        }
        try expect(budgetPlan.imageBodies.reduce(0, { $0 + $1.count }) <= Lane.maxRetainedBytes
                   && budgetPlan.imageBodies.allSatisfy { $0.count <= Lane.maxFrameBytes },
                   "maximum theme plus image payload respects the lane retention and frame limits")
        let themeOps = try budgetPlan.imageBodies.flatMap { try JSONDecoder().decode(Wire.Patch.self, from: $0).ops }
        try expect(themeOps.filter { if case .characterThemePart = $0 { return true }; return false }.count == 16,
                   "budget pressure retains all sixteen theme parts")
        // Past even the parts' limit (256 KiB deflated): noise does not deflate.
        var noise = [UInt8](repeating: 0, count: 300 * 1024)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for index in noise.indices { seed = seed &* 6364136223846793005 &+ 1; noise[index] = UInt8(truncatingIfNeeded: seed >> 33) }
        // Large-set parts as a guest may receive them: in order (the control),
        // out of order, with a gap, and with corrupted bytes. Every bad case
        // draws the built-in set; none fails the frame.
        guard let largeWire = Wire.CharacterTheme(file: Data(AgentCharacterDuckherdFixture.text().utf8)), !largeWire.isInline else {
            throw Failure(description: "the Duckherd-shaped set is not a large shared set")
        }
        let largeParts = largeWire.parts()
        var corrupted = largeParts
        corrupted[0] = .init(hash: largeParts[0].hash, total: largeParts[0].total, offset: 0, bytes: Data(largeParts[0].bytes.reversed()))
        typealias Case = (name: String, inline: Wire.CharacterTheme?, id: String, hash: String?, parts: [Wire.CharacterTheme.Part], falls: Bool)
        let cases: [Case] = [
            ("invalid", Wire.CharacterTheme(file: Data("{\"duckherdTheme\":1,\"id\":\"\(setID)\"}".utf8)), reference.id, nil, [], true),
            ("oversized", Wire.CharacterTheme(hash: String(repeating: "a", count: 64), deflated: Data(noise)), reference.id, nil, [], true),
            ("missing", nil, reference.id, nil, [], true),
            ("in-order parts", nil, AgentCharacterDuckherdFixture.id, largeWire.hash, largeParts, false),
            ("out-of-order parts", nil, AgentCharacterDuckherdFixture.id, largeWire.hash, largeParts.reversed(), true),
            ("parts with a gap", nil, AgentCharacterDuckherdFixture.id, largeWire.hash, largeParts.enumerated().filter { $0.offset != 1 }.map(\.element), true),
            ("corrupted parts", nil, AgentCharacterDuckherdFixture.id, largeWire.hash, corrupted, true),
        ]
        for item in cases {
            SharedAgentCharacterSets.qaReset()
            var bad = chrome
            bad.character?.theme = .init(id: item.id, hash: item.hash ?? item.inline?.hash ?? String(repeating: "b", count: 64))
            let body = try Wire.encode(Wire.Checkpoint(entries: [], omittedEntries: 0, chrome: bad, characterTheme: item.inline))
            let frames = try item.parts.enumerated().map { index, part in
                Lane.Frame(generation: 1, sequence: UInt64(2 + index), body: try Wire.encode(Wire.Patch(ops: [.characterThemePart(part)])))
            }
            let (tile, live) = makeGuest(read: { _, _ in
                .resnapshot(.init(generation: 1, through: 1, body: body), frames: frames, more: false)
            })
            canvas.addSubview(tile)
            _ = await live.pollTranscript(object, ticket: live.qaTicket, waitMilliseconds: 0)
            try await paint()
            if item.falls {
                let fallback = AgentCharacterAtlas(theme: builtIn, character: live.characterSet.map {
                    $0.assignment(for: agent.rawValue, shipped: chrome.character?.assignment, name: nil)?.index ?? -1 } ?? -1,
                    appearance: AgentCharacterController.appearance(of: tile))
                try expect(live.characterSet?.key == "builtin:\(builtIn.id)" && live.characterSet?.fallbackReason != nil
                           && drawn(tile.qaCharacterLayer)?.pixels == fallback.pixels
                           && live.transcriptView.appliedFrames == frames.count,
                           "\(item.name): the guest falls back to the built-in set, every frame applied (\(live.characterSet?.fallbackReason ?? "no reason"))")
            } else {
                try expect(live.characterSet?.key == "shared:" + largeWire.hash && live.characterSet?.fallbackReason == nil,
                           "\(item.name): control, the guest draws the set (\(live.characterSet?.fallbackReason ?? live.characterSet?.key ?? "none"))")
            }
            tile.removeFromSuperview()
        }
        let tooBig = Wire.CharacterTheme(file: Data(noise))
        try expect(tooBig == nil, "a host never ships a set that deflates past \(Wire.CharacterTheme.maximumSharedDeflatedBytes) bytes")
    }
}
