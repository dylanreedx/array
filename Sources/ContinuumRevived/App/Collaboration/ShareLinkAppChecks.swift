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
        let authority = SharedAreaCheckRig.Authority(document: .init(), members: [(owner, .owner), (receiver, .editor)])
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
        let link = try await sender.shareLinks.createShareLink(selection: selection, slug: "checkout-redesign", lifetime: .once)
        let published = await authority.document
        try expect(link.url.absoluteString == "https://arrayapp.dev/s/checkout-redesign#\(link.token)" && link.lifetime == .once,
            "createShareLink returns the arrayapp.dev/s/<slug>#<token> link with its lifetime")
        try expect(Set(published.items.map(\.kind)) == [.agentObservation, .discussion] && published.positions.count == 2,
            "the selected agent publishes as a live observation and the note as discussion, without a review window")
        try expect(sender.qaSharedAreaCaptureWindows.isEmpty && sender.qaSharedAreaWindows.contains { $0.controller.document?.id == published.id },
            "the sender's area opens through the same path as the hub")
        do {
            _ = try await sender.shareLinks.newLink(area: published.id.rawValue, slug: "checkout-redesign", lifetime: .untilRevoked)
            _ = try await sender.shareLinks.newLink(area: published.id.rawValue, slug: "checkout-redesign", lifetime: .untilRevoked)
            throw Failure(message: "a taken slug was minted")
        } catch ShareLinkFailure.slugTaken {}
        try expect(true, "a relay slug collision surfaces as ShareLinkFailure.slugTaken")
        for window in sender.qaSharedAreaWindows { window.window.close() }

        // Receiver: AppKit hands the URL to the delegate.
        let receiving = AppDelegate()
        let canvasWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        canvasWindow.isReleasedWhenClosed = false
        receiving.qaAttachWindowForOfflineCheck(canvasWindow)
        canvasWindow.orderFrontOffscreenForChecks()
        defer { canvasWindow.orderOut(nil) }
        let receiverAccount = try account(root: root.appendingPathComponent("receiver"), identity: receiver, authority: authority, links: links)
        receiving.qaAdoptCollaborationAccount(receiverAccount)
        func deliver(_ url: URL) async throws -> ShareLinkOpenOutcome? {
            let before = receiving.shareLinks.openCount
            receiving.application(NSApp, open: [url])
            for _ in 0..<500 {
                if receiving.shareLinks.openCount > before { return receiving.shareLinks.lastOutcome }
                if let hub = receiving.qaCollaborationHub, hub.window.title == "Sign in to open the shared link",
                   receiverAccount.status == .signedOut, !receiverAccount.isBusy {
                    try fill(hub.content, endpoint: "https://share-links.example.test", code: "scripted-receiver-enrollment")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
        let area = published.id.rawValue

        let redeemedBefore = await links.redeemed
        let signedIn = try await deliver(link.url), redeemed = await links.redeemed
        try expect(signedIn == .opened(area: area) && receiverAccount.status == .ready && redeemed == redeemedBefore + 1
            && receiving.qaCollaborationHub?.window.title == "Collaboration",
            "an https://arrayapp.dev/s/ link on a signed-out Mac signs in inline through the hub's enrollment, then admits")
        try await SharedAreaCheckRig.eventually("receiver area open") {
            receiving.qaSharedAreaWindows.contains { $0.controller.document?.id.rawValue == area }
        }
        try expect(receiving.qaSharedAreaWindows.count == 1, "the URL handler opens the admitted area")
        let admitted = await links.admitted
        try expect(admitted == [receiver.person.rawValue], "the receiver was admitted through the link exactly once")
        for window in receiving.qaSharedAreaWindows { window.window.close() }

        let appForm = try await deliver(link.appURL)
        try await SharedAreaCheckRig.eventually("receiver area reopen") {
            receiving.qaSharedAreaWindows.contains { $0.controller.document?.id.rawValue == area }
        }
        try expect(appForm == .opened(area: area),
            "array://s/<slug>#<token> reaches the same entry point and reopens the area")
        for window in receiving.qaSharedAreaWindows { window.window.close() }

        let wrong = try await deliver(URL(string: "array://s/checkout-redesign#\(String(repeating: "x", count: 43))")!)
        let sheet = canvasWindow.attachedSheet
        let shown = sheet.flatMap { allText(in: $0.contentView) } ?? []
        try expect(wrong == .refused(ShareLinkOpener.refusedMessage) && shown.contains(ShareLinkOpener.refusedMessage)
            && receiving.qaSharedAreaWindows.isEmpty, "a wrong token is refused and the refusal is shown on the canvas window")
        if let sheet { canvasWindow.endSheet(sheet) }

        let before = receiving.shareLinks.openCount
        receiving.application(NSApp, open: [URL(string: "array://pair#not-a-share-link")!, URL(string: "https://arrayapp.dev/docs")!])
        try await Task.sleep(for: .milliseconds(100))
        try expect(receiving.shareLinks.openCount == before, "other array:// and arrayapp.dev URLs are not routed as share links")
        receiving.qaCollaborationHub?.window.close()
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

    private static func allText(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { allText(in: $0) }
    }
}
