import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// Share links through the production app seams: `AppDelegate.shareLinks`
/// creating an area from a mounted workspace selection, and AppKit's
/// `application(_:open:)` admitting, signing in inline and opening the area.
/// The relay's own link rules are witnessed over real HTTP in
/// ContinuumRevivedCollaborationChecks; here a scripted account authority
/// keeps a token, its lifetime and who it admitted.
@MainActor
enum ShareLinkAppChecks {
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(message: label) }
        print("PASS share links (app): \(label)")
    }

    private actor Links {
        var minted: [(slug: String, lifetime: Collaboration.ShareLinkLifetime, token: String)] = []
        var admitted: [UUID] = []
        var redeemed = 0
        func mint(_ request: Collaboration.ShareLinkRequest) throws -> String {
            guard !minted.contains(where: { $0.slug == request.slug && $0.lifetime == .untilRevoked }) else {
                throw CollaborationClientError.server(status: 409, code: "slugTaken")
            }
            let token = String(repeating: "k", count: 43)
            minted.append((request.slug, request.lifetime, token)); return token
        }
        func accept(slug: String, token: String, person: UUID) throws {
            guard let link = minted.first(where: { $0.slug == slug && $0.token == token }) else {
                throw CollaborationClientError.server(status: 410, code: "invalidInvitation")
            }
            if link.lifetime == .once, let first = admitted.first, first != person {
                throw CollaborationClientError.server(status: 410, code: "invalidInvitation")
            }
            if !admitted.contains(person) { admitted.append(person) }
        }
        func redeem() { redeemed += 1 }
        var joinedNames: [String] = []
        func join(_ name: String) { joinedNames.append(name) }
    }

    private struct AccountTransport: CollaborationAccountTransport {
        let identityValue: Collaboration.Identity
        let authority: SharedAreaCheckRig.Authority
        let links: Links
        func redeem(code: String, deviceLabel: String) async throws -> Collaboration.Credential {
            await links.redeem(); return .init(identity: identityValue, token: "scripted-share-link-device")
        }
        func identity() async throws -> Collaboration.Identity { identityValue }
        func createArea() async throws -> Collaboration.State { try await authority.state(identityValue) }
        func state(area: UUID) async throws -> Collaboration.State { try await authority.state(identityValue) }
        func accept(code: String) async throws -> Collaboration.Scope { throw Failure(message: "unexpected invitation") }
        func invite(area: UUID, person: SharedArea.ID<SharedArea.Person>, role: Collaboration.Role) async throws -> Collaboration.Invitation {
            throw Failure(message: "unexpected invitation")
        }
        func registerHost() async throws -> Collaboration.Host { .init(id: .init()) }
        func createShareLink(area: UUID, request: Collaboration.ShareLinkRequest) async throws -> Collaboration.ShareLink {
            let token = try await links.mint(request)
            return .init(id: UUID(), area: .init(area), slug: request.slug, token: token, lifetime: request.lifetime, createdAt: Date())
        }
        func joinShareLink(_ request: Collaboration.JoinShareLink) async throws -> Collaboration.ShareLinkJoin {
            try await links.accept(slug: request.slug, token: request.token, person: identityValue.person.rawValue)
            await links.join(request.displayName)
            return .init(credential: .init(identity: identityValue, token: "scripted-joined-device"),
                         scope: try await authority.state(identityValue).scope)
        }
        func acceptShareLink(slug: String, token: String) async throws -> Collaboration.Scope {
            try await links.accept(slug: slug, token: token, person: identityValue.person.rawValue)
            return try await authority.state(identityValue).scope
        }
    }

    private static func account(root: URL, identity: Collaboration.Identity, authority: SharedAreaCheckRig.Authority,
                                links: Links) throws -> CollaborationAccountController {
        try CollaborationAccountController(store: .init(applicationSupportRoot: root, bundleIdentifier: nil),
            credentialStore: .init(vault: SharedAreaCheckRig.MemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil,
            transportFactory: { _, _ in AccountTransport(identityValue: identity, authority: authority, links: links) },
            areaTransportFactory: { _, _, _ in SharedAreaCheckRig.Transport(identityValue: identity, label: "Share link", authority: authority) })
    }

    static func run() async throws {
        let root = try SharedAreaCheckRig.root("share-links")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = Collaboration.Identity(person: .init(), device: UUID())
        let receiver = Collaboration.Identity(person: .init(), device: UUID())
        let enrolled = Collaboration.Identity(person: .init(), device: UUID())
        let authority = SharedAreaCheckRig.Authority(document: .init(), members: [(owner, .owner), (receiver, .editor), (enrolled, .editor)])
        let links = Links()
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://share-links.example.test")!)

        // Sender: a selection becomes a published area and a link, with no review window.
        let noteID = UUID()
        let fixture = try WorkspaceAPIChecks.makeFixture(beforeMount: { delegate, directory in
            let source = ProjectStore(projectRoot: directory.appendingPathComponent("Pb"))
            var canvas = try source.loadCanvas()
            let record = delegate.qaAgentSupervisor.records.values.first(where: { $0.projectRoot == directory.appendingPathComponent("Pb").path && $0.tileId != nil })
            guard let index = canvas.tiles.firstIndex(where: { $0.id == record?.tileId }), let zone = canvas.tiles[index].zoneId else {
                throw Failure(message: "share-link source agent tile absent")
            }
            canvas.tiles[index].kind = .managedAgent; canvas.tiles[index].title = "Map the checkout state machine"
            canvas.tiles.append(.init(id: noteID, kind: .note, title: "Retry rules",
                frame: .init(x: 3050, y: 680, width: 260, height: 180), zPosition: .fromLegacyRank(5),
                zoneId: zone, runtimeRef: nil, metadata: .init(noteId: noteID)))
            try source.saveCanvas(canvas)
            try source.saveNoteBody(id: noteID, text: "Card declined: no retry.")
        })
        defer { fixture.runtime.closeAll(); fixture.tearDown() }
        let sender = fixture.delegate
        let ownerAccount = try account(root: root.appendingPathComponent("owner"), identity: owner, authority: authority, links: links)
        _ = try await ownerAccount.enroll(endpoint: endpoint, code: "scripted-owner-enrollment", deviceLabel: "Dylan's Mac", accountLabel: "Dylan")
        sender.qaAdoptCollaborationAccount(ownerAccount)
        let selection = SharedAreaPublication.Selection.tiles([.init(projectID: fixture.projectPb, tileID: fixture.agentTileB),
                                                              .init(projectID: fixture.projectPb, tileID: noteID)])
        _ = selection
        // The whole sender side in one call (part 2): create the area, publish
        // by kind, open its zone here, lend the tiles to it and bind them.
        let agentView = fixture.canvas.tileView(for: fixture.agentTileB), noteView = fixture.canvas.tileView(for: noteID)
        let sourceFile = ProjectStore(projectRoot: fixture.tempRoot.appendingPathComponent("Pb")).layout.canvasFile
        try fixture.runtime.flushMountedWorkspaceState()
        let sourceBytes = try Data(contentsOf: sourceFile)
        let share = try await sender.createSharedZone(fromTiles: [fixture.agentTileB, noteID], name: "Checkout redesign")
        let area = share.areaId, objects = share.objects
        let published = await authority.document
        let zone = fixture.runtime.sharedAreaZone(for: area)
        guard let session = sender.qaSharedAreaZoneSessions.first(where: { $0.areaId == area }), let zone else {
            throw Failure(message: "createSharedZone opened no zone")
        }
        let agentLent = fixture.canvas.lentTile(fixture.agentTileB)?.tile
        try expect(zone.projectId == nil && zone.zoneId == share.zoneId && session.scene.isZone
            && fixture.canvas.tileView(for: fixture.agentTileB) === agentView && fixture.canvas.tileView(for: noteID) === noteView
            && agentLent?.object == objects[fixture.agentTileB]?.rawValue && fixture.canvas.lentTile(noteID) != nil
            && objects[fixture.agentTileB].map { session.scene.locallyShownObjects.contains($0) } == true,
            "createSharedZone opens a projectless zone and lends both tiles to it, same views, the agent bound to its object")
        try expect(objects[fixture.agentTileB].flatMap { object in published.positions.last(where: { $0.object == object })?.rect }
            == agentLent.map { SharedArea.Rect(x: $0.areaFrame.x, y: $0.areaFrame.y, width: $0.areaFrame.width, height: $0.areaFrame.height) },
            "the agent's shared position is where its tile now sits in the zone")
        try fixture.runtime.flushMountedWorkspaceState()
        try expect(try Data(contentsOf: sourceFile) == sourceBytes,
            "lending the tiles to the area writes nothing to their project's canvas.json")
        let sessionsAfterShare = sender.qaSharedAreaZoneSessions.count
        try expect(Set(published.items.map(\.kind)) == [.agentObservation, .discussion] && published.positions.count == 2
            && objects[fixture.agentTileB].map { object in published.items.contains { $0.id == object } } == true,
            "publish-by-kind shares the agent as a live observation and the note as discussion, without a review window, and maps the agent tile to its object")
        let link = try await sender.shareLinks.createShareLink(area: area, slug: "checkout-redesign", lifetime: .once)
        let afterMint = await authority.document
        try expect(link.url.absoluteString == "https://arrayapp.dev/s/checkout-redesign?r=share-links.example.test#\(link.token)"
            && link.lifetime == .once && sender.qaSharedAreaZoneSessions.count == sessionsAfterShare && sender.qaSharedAreaCaptureWindows.isEmpty
            && afterMint == published,
            "createShareLink(area:) only mints a link carrying the relay; it creates, publishes and opens nothing")
        do {
            _ = try await sender.shareLinks.newLink(area: area, slug: "checkout-redesign", lifetime: .untilRevoked)
            _ = try await sender.shareLinks.newLink(area: area, slug: "checkout-redesign", lifetime: .untilRevoked)
            throw Failure(message: "a taken slug was minted")
        } catch ShareLinkFailure.slugTaken {}
        try expect(true, "a relay slug collision surfaces as ShareLinkFailure.slugTaken")

        // Receivers: AppKit hands the URL to the delegate.
        // A receiver is a Mac with a workspace open: the link lands the area
        // as a zone on that canvas.
        typealias Receiver = (AppDelegate, NSWindow, CollaborationAccountController, WorkspaceInvariantsFixture)
        func receiverMac(_ identity: Collaboration.Identity, _ name: String) throws -> Receiver {
            let workspace = try WorkspaceInvariantsFixture(label: "share-link-\(name)")
            try workspace.mount()
            let mounted = try workspace.requireMounted("share-link receiver")
            let delegate = mounted.delegate
            mounted.canvas.frame = .init(x: 0, y: 0, width: 1400, height: 900)
            let window = NSWindow(contentRect: mounted.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = mounted.canvas
            delegate.qaAttachWindowForOfflineCheck(window)
            window.orderFrontOffscreenForChecks()
            let model = try account(root: root.appendingPathComponent(name), identity: identity, authority: authority, links: links)
            delegate.qaAdoptCollaborationAccount(model)
            return (delegate, window, model, workspace)
        }
        func openZones(_ mac: Receiver) -> [SharedAreaZoneSession] {
            mac.0.qaSharedAreaZoneSessions.filter { !$0.isClosed && $0.controller.document?.id.rawValue == area }
        }
        func deliver(_ url: URL, to mac: Receiver, name: String? = nil) async throws -> ShareLinkOpenOutcome? {
            let (delegate, window, model, _) = mac
            let before = delegate.shareLinks.openCount
            delegate.application(NSApp, open: [url])
            for _ in 0..<500 {
                if delegate.shareLinks.openCount > before { return delegate.shareLinks.lastOutcome }
                if let name, let sheet = window.attachedSheet, let field = textFields(in: sheet.contentView).first(where: { $0.accessibilityLabel() == "Your name" }) {
                    field.stringValue = name
                    guard let join = buttons(in: sheet.contentView).first(where: { $0.title == "Join" }) else { throw Failure(message: "name sheet has no Join") }
                    join.performClick(nil)
                }
                if let hub = delegate.qaCollaborationHub, hub.window.title == "Sign in to open the shared link", model.status == .signedOut, !model.isBusy {
                    try fill(hub.content, endpoint: "https://share-links.example.test", code: "scripted-receiver-enrollment")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        // A brand-new person, no account anywhere: the link alone.
        let newcomer = try receiverMac(receiver, "receiver")
        defer { newcomer.1.orderOut(nil); newcomer.3.dispose() }
        let redeemedBefore = await links.redeemed
        let joined = try await deliver(link.url, to: newcomer, name: "Sam")
        let redeemed = await links.redeemed, names = await links.joinedNames
        try expect(joined == .opened(area: area) && newcomer.2.status == .ready && newcomer.2.activeAccount?.label == "Sam"
            && names == ["Sam"] && redeemed == redeemedBefore && newcomer.0.qaCollaborationHub == nil,
            "a signed-out Mac joins from an https://arrayapp.dev/s/ link alone: one name sheet, no hub, no enrollment code")
        try await SharedAreaCheckRig.eventually("receiver area open") { !openZones(newcomer).isEmpty }
        let landed = newcomer.3.mounted?.runtime.sharedAreaZone(for: area)
        try expect(openZones(newcomer).count == 1 && landed?.projectId == nil
            && openZones(newcomer).first?.scene.superview === newcomer.3.mounted?.canvas.worldPlane,
            "the URL handler opens the admitted area as a zone on the receiver's canvas")
        for session in openZones(newcomer) { session.close() }

        let appForm = try await deliver(link.appURL, to: newcomer)
        try await SharedAreaCheckRig.eventually("receiver area reopen") { !openZones(newcomer).isEmpty }
        try expect(newcomer.3.mounted?.runtime.sharedAreaZone(for: area)?.zoneId == landed?.zoneId,
            "reopening lands the area in the same zone, at the receiver's own place for it")
        let devForm = try await deliver(ShareLinkURL.app(slug: link.slug, token: link.token, relay: link.relay, scheme: ShareLinkURL.devAppScheme), to: newcomer)
        let namesAfter = await links.joinedNames
        try expect(appForm == .opened(area: area) && devForm == .opened(area: area) && namesAfter == ["Sam"],
            "array:// and array-dev:// reach the same entry point and reopen with the saved account")
        for session in openZones(newcomer) { session.close() }

        let wrong = try await deliver(URL(string: "array://s/checkout-redesign?r=share-links.example.test#\(String(repeating: "x", count: 43))")!, to: newcomer)
        let sheet = newcomer.1.attachedSheet
        let shown = sheet.map { textFields(in: $0.contentView).map(\.stringValue) } ?? []
        try expect(wrong == .refused(ShareLinkOpener.refusedMessage) && shown.contains(ShareLinkOpener.refusedMessage)
            && openZones(newcomer).isEmpty, "a wrong token is refused and the refusal is shown on the canvas window")
        if let sheet { newcomer.1.endSheet(sheet) }

        let before = newcomer.0.shareLinks.openCount
        newcomer.0.application(NSApp, open: [URL(string: "array://pair#not-a-share-link")!, URL(string: "https://arrayapp.dev/docs")!])
        try await Task.sleep(for: .milliseconds(100))
        try expect(newcomer.0.shareLinks.openCount == before, "other array:// and arrayapp.dev URLs are not routed as share links")

        // A link without a relay still signs in through the hub's Connect.
        let reusable = try await sender.shareLinks.newLink(area: area, slug: "checkout-team", lifetime: .untilRevoked)
        let legacyMac = try receiverMac(enrolled, "enrolled")
        defer { legacyMac.1.orderOut(nil); legacyMac.3.dispose() }
        let legacy = try await deliver(ShareLinkURL.web(slug: reusable.slug, token: reusable.token), to: legacyMac)
        let redeemedAfter = await links.redeemed
        try expect(legacy == .opened(area: area) && legacyMac.2.status == .ready && redeemedAfter == redeemedBefore + 1
            && legacyMac.0.qaCollaborationHub?.window.title == "Collaboration",
            "a link without a relay on a signed-out Mac signs in inline through the hub's Connect, then admits")
        for session in openZones(legacyMac) { session.close() }
        legacyMac.0.qaCollaborationHub?.window.close()

        // Undo the share: what it published leaves the area, the tiles go home
        // with their own views, and the zone leaves the sender's canvas.
        await sender.cancelSharedZone(areaId: area)
        let afterCancel = await authority.document
        try expect(fixture.canvas.lentTile(fixture.agentTileB) == nil && fixture.canvas.lentTile(noteID) == nil
            && fixture.canvas.tileView(for: fixture.agentTileB) === agentView && fixture.canvas.tileView(for: noteID) === noteView
            && fixture.canvas.zoneId(containing: fixture.agentTileB) != nil && fixture.runtime.sharedAreaZone(for: area) == nil
            && objects.values.allSatisfy { object in !afterCancel.items.contains { $0.id == object } },
            "cancelSharedZone takes the published items back out, returns the tiles home with their views and removes the zone")
        try fixture.runtime.flushMountedWorkspaceState()
        try expect(try Data(contentsOf: sourceFile) == sourceBytes, "after the undo, the project's canvas.json is as it was")
    }

    private static func fill(_ view: CollaborationHubView, endpoint: String, code: String) throws {
        func field(_ label: String) -> NSTextField? {
            view.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label }
        }
        guard let url = field("Collaboration service URL"), let enrollment = field("One-time Array enrollment code"),
              let connect = view.subviews.compactMap({ $0 as? NSControl }).first(where: { $0.accessibilityLabel() == "Connect" }) else {
            throw Failure(message: "inline sign-in fields absent")
        }
        guard url.stringValue.isEmpty else { return }
        url.stringValue = endpoint; enrollment.stringValue = code
        guard connect.isEnabled, connect.sendAction(connect.action, to: connect.target) else { throw Failure(message: "inline Connect not wired") }
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        return ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }
    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }
}
