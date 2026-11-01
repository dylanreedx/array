import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private final class ShareLinkVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}
private func shareLinkCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw CheckFailure(label: "share links: " + label) }
    print("PASS share links: \(label)")
}
private func serverStatus(_ error: any Error) -> (Int, String)? {
    guard let client = error as? CollaborationClientError, case let .server(status, code) = client else { return nil }
    return (status, code)
}

/// Bearer links through the production account controller, the production
/// ShareLinkOpener and the real NIO routes. Every person, credential and store
/// is disposable.
@MainActor
func runShareLinkChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-share-links-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 53, count: 32)
    let store = try CollaborationStore(path: root.appendingPathComponent("collaboration.sqlite").path, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let url = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        let endpoint = try CollaborationServiceEndpoint(url, allowsInsecureLoopback: true)
        let credentials = CollaborationCredentialStore(vault: ShareLinkVault(), bundleIdentifier: AppChannel.devBundleIdentifier)
        func signedOut() throws -> CollaborationAccountController {
            try CollaborationAccountController(store: CollaborationAccountStore(applicationSupportRoot: root.appendingPathComponent("account-\(UUID())"),
                bundleIdentifier: AppChannel.devBundleIdentifier), credentialStore: credentials, bundleIdentifier: AppChannel.devBundleIdentifier)
        }
        func enroll(_ model: CollaborationAccountController, _ label: String) async throws {
            let code = try await store.provisionPerson(label: label)
            _ = try await model.enroll(endpoint: endpoint, code: code.code, deviceLabel: label, accountLabel: label)
        }
        func person(_ label: String) async throws -> CollaborationAccountController {
            let model = try signedOut(); try await enroll(model, label); return model
        }
        var opened: [UUID] = []
        func opener(_ model: CollaborationAccountController, signIn: @escaping ShareLinkOpener.SignIn = { _ in false },
                    askName: @escaping ShareLinkOpener.AskName = { _, _ in nil }) -> ShareLinkOpener {
            ShareLinkOpener(account: model, signIn: signIn, askName: askName, open: { state, _ in opened.append(state.document.id.rawValue) },
                            deviceLabel: "Check Mac", allowsInsecureLoopback: true)
        }
        func canRead(_ model: CollaborationAccountController, _ area: UUID) async -> Bool {
            (try? await model.openArea(id: area)) != nil
        }

        let owner = try await person("Dylan"), sam = try await person("Sam"), priya = try await person("Priya")
        let quinn = try await person("Quinn"), other = try await person("Other owner")
        let area = try await owner.createArea(label: "Checkout redesign").document.id.rawValue

        // Works once: the first accept spends it.
        let once = try await owner.createShareLink(area: area, slug: "checkout-redesign", lifetime: .once)
        let relay = endpoint.shareLinkRelay
        try shareLinkCheck(once.url.absoluteString == "https://arrayapp.dev/s/checkout-redesign?r=\(relay)#\(once.token)"
            && ShareLinkURL.parse(once.url)?.token == once.token && ShareLinkURL.parse(once.appURL)?.slug == "checkout-redesign"
            && ShareLinkURL.parse(once.appURL)?.relay == relay,
            "the link is arrayapp.dev/s/<slug>?r=<relay>#<token>, carries its relay, and parses in both forms")
        let samOutcome = await opener(sam).open(once.url), samReads = await canRead(sam, area)
        try shareLinkCheck(samOutcome == .opened(area: area) && opened.last == area && samReads,
            "a valid token admits whoever holds it and the area opens")
        let priyaSpent = await opener(priya).open(once.appURL), priyaReads = await canRead(priya, area)
        try shareLinkCheck(priyaSpent == .refused(ShareLinkOpener.refusedMessage) && !priyaReads,
            "a single-use link is spent after one accept: a second person is refused")
        try shareLinkCheck(await opener(sam).open(once.url) == .opened(area: area),
            "the person a spent link admitted can reopen it to reconnect")
        var access = try await owner.shareLinks(area: area)
        try shareLinkCheck(access.count == 1 && access[0].status == .used && access[0].people.map(\.label) == ["Sam"]
            && access[0].people.allSatisfy(\.active), "listAccess shows the spent link as used, with Sam")
        let samRole = try await sam.openArea(id: area).scope.role
        try shareLinkCheck(samRole == .editor, "whoever opens a link gets the full-access editor role")

        // Slugs: unique per relay among live links; a spent link frees its slug.
        let reusable = try await owner.createShareLink(area: area, slug: "payment-retry", lifetime: .untilRevoked)
        let otherArea = try await other.createArea(label: "Elsewhere").document.id.rawValue
        do {
            _ = try await other.createShareLink(area: otherArea, slug: "payment-retry", lifetime: .once)
            throw CheckFailure(label: "share links: a slug collision was accepted")
        } catch where serverStatus(error)?.0 == 409 && serverStatus(error)?.1 == "slugTaken" {}
        try shareLinkCheck(true, "a slug collision is refused, across areas and owners on one relay")
        let renewed = try await owner.createShareLink(area: area, slug: "checkout-redesign", lifetime: .once)
        try shareLinkCheck(renewed.token != once.token, "a spent link's slug is free for New link")

        // Until revoked: admits two people.
        let priyaIn = await opener(priya).open(reusable.url), quinnIn = await opener(quinn).open(reusable.appURL)
        let priyaReadsNow = await canRead(priya, area), quinnReadsNow = await canRead(quinn, area)
        let bothRead = priyaReadsNow && quinnReadsNow
        try shareLinkCheck(priyaIn == .opened(area: area) && quinnIn == .opened(area: area) && bothRead,
            "an until-revoked link admits two people")
        access = try await owner.shareLinks(area: area)
        let reusableRow = access.first { $0.id == reusable.id }
        try shareLinkCheck(reusableRow?.status == .active && reusableRow?.people.map(\.label) == ["Priya", "Quinn"],
            "listAccess lists both people on the reusable link")

        // A wrong token is refused and admits nobody.
        let stranger = try await person("Stranger")
        let forged = URL(string: "array://s/payment-retry#\(String(reusable.token.reversed()))")!
        let forgedOutcome = await opener(stranger).open(forged), strangerReads = await canRead(stranger, area)
        try shareLinkCheck(forgedOutcome == .refused(ShareLinkOpener.refusedMessage) && !strangerReads,
            "a wrong token is refused and shows as refused")
        try shareLinkCheck(await opener(stranger).open(URL(string: "https://arrayapp.dev/s/payment-retry")!) == .refused(ShareLinkOpener.incompleteMessage),
            "a link without its token is refused as incomplete")

        // Only someone who may share can make or see links.
        do {
            _ = try await sam.createShareLink(area: area, slug: "sam-made-this", lifetime: .untilRevoked)
            throw CheckFailure(label: "share links: an editor minted a link")
        } catch where serverStatus(error)?.0 == 403 {}
        try shareLinkCheck(true, "an editor admitted by a link cannot mint links")

        // Revoke cuts everyone the link admitted, and the link stops working.
        try await owner.revokeShareLink(area: area, link: reusable.id)
        let afterRevoke = (await canRead(priya, area), await canRead(quinn, area), await canRead(sam, area))
        try shareLinkCheck(!afterRevoke.0 && !afterRevoke.1 && afterRevoke.2,
            "revoke cuts both people admitted through that link and nobody else")
        try shareLinkCheck(await opener(stranger).open(reusable.url) == .refused(ShareLinkOpener.refusedMessage),
            "a revoked link refuses a newcomer")
        try shareLinkCheck(await opener(priya).open(reusable.url) == .refused(ShareLinkOpener.refusedMessage),
            "a revoked link does not readmit the people it admitted")
        access = try await owner.shareLinks(area: area)
        let revokedRow = access.first { $0.id == reusable.id }
        try shareLinkCheck(revokedRow?.status == .revoked && revokedRow?.people.allSatisfy { !$0.active } == true,
            "listAccess shows the revoked link and its people without access")

        // Remove one person; the link keeps working for others.
        let team = try await owner.createShareLink(area: area, slug: "team", lifetime: .untilRevoked)
        _ = await opener(priya).open(team.url)
        try await owner.removeShareLinkPerson(area: area, link: team.id, person: priya.activeAccount!.identity.person)
        let removedReads = await canRead(priya, area), removedReopen = await opener(priya).open(team.url)
        try shareLinkCheck(!removedReads && removedReopen == .refused(ShareLinkOpener.refusedMessage),
            "a removed person loses access and cannot reopen the same link")
        try shareLinkCheck(await opener(quinn).open(team.url) == .opened(area: area), "removing one person leaves the link working for others")

        // A brand-new person joins from the link alone: no account, no operator
        // code, no key. The link names the relay; they only give a name.
        let fresh = try signedOut()
        var asked: [(String, String)] = []
        let joined = await opener(fresh, askName: { relay, slug in asked.append((relay, slug)); return "Newcomer" }).open(team.url)
        let freshReads = await canRead(fresh, area)
        try shareLinkCheck(joined == .opened(area: area) && freshReads && asked.count == 1 && asked[0] == (relay, "team")
            && fresh.status == .ready && fresh.accounts.count == 1 && fresh.activeAccount?.label == "Newcomer"
            && fresh.activeAccount?.endpoint == endpoint.canonicalString
            && fresh.activeAccount?.knownAreas.contains(where: { $0.id == area && $0.label == "team" }) == true,
            "a fresh client with no account joins through the link alone, picking only a display name")
        let freshRole = try await fresh.openArea(id: area).scope.role
        access = try await owner.shareLinks(area: area)
        try shareLinkCheck(freshRole == .editor && access.first(where: { $0.id == team.id })?.people.contains(where: { $0.label == "Newcomer" && $0.active }) == true,
            "the joined newcomer is an editor and listed on the link")
        try shareLinkCheck(await opener(fresh).open(team.url) == .opened(area: area) && asked.count == 1,
            "reopening the link uses the newcomer's saved device instead of joining again")
        try await owner.revokeShareLink(area: area, link: team.id)
        let freshCut = await canRead(fresh, area)
        try shareLinkCheck(!freshCut, "revoking the link cuts a person who joined through it")

        let lateOnce = try await owner.createShareLink(area: area, slug: "late-once", lifetime: .once)
        let firstJoiner = try signedOut(), lateJoiner = try signedOut()
        _ = await opener(firstJoiner, askName: { _, _ in "First" }).open(lateOnce.url)
        let lateOutcome = await opener(lateJoiner, askName: { _, _ in "Late" }).open(lateOnce.url)
        try shareLinkCheck(lateOutcome == .refused(ShareLinkOpener.refusedMessage) && lateJoiner.accounts.isEmpty && lateJoiner.status != .ready,
            "joining through a spent single-use link is refused and saves no account")
        let liveTeam = try await owner.createShareLink(area: area, slug: "team-two", lifetime: .untilRevoked)
        let forger = try signedOut()
        let forgedJoin = await opener(forger, askName: { _, _ in "Forger" }).open(
            ShareLinkURL.app(slug: "team-two", token: String(liveTeam.token.reversed()), relay: relay))
        try shareLinkCheck(forgedJoin == .refused(ShareLinkOpener.refusedMessage) && forger.accounts.isEmpty,
            "joining with a wrong token is refused and saves no account")
        let shy = try signedOut()
        let shyOutcome = await opener(shy).open(liveTeam.url)
        try shareLinkCheck(shyOutcome == .cancelled && shy.accounts.isEmpty && shy.status == .signedOut,
            "dismissing the name prompt joins nothing")

        // A link without a relay still works for a Mac signed in elsewhere first.
        let legacy = ShareLinkURL.web(slug: "team-two", token: liveTeam.token)
        let newcomer = try signedOut()
        var signIns = 0
        let invited = await opener(newcomer, signIn: { model in
            signIns += 1; try await enroll(model, "Enrolled newcomer"); return true
        }).open(legacy)
        let newcomerReads = await canRead(newcomer, area)
        try shareLinkCheck(invited == .opened(area: area) && signIns == 1 && newcomerReads,
            "a link without a relay falls back to the existing relay sign-in, then admits")

        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
    try await runShareLinkJoinLimitChecks(root: root)
    try await runFirstUseShareChecks(root: root)
}

/// A Mac with no collaboration account shares out of the box: it signs up at
/// the default relay with only a name (no operator code, no key), shares an
/// agent, gets a link, and a second fresh Mac joins through it. Then the
/// per-address self-enroll limit.
@MainActor
private func runFirstUseShareChecks(root: URL) async throws {
    let store = try CollaborationStore(path: root.appendingPathComponent("first-use.sqlite").path, masterKey: Data(repeating: 61, count: 32),
                                       joinLimits: .init(enrollPerAddress: 3))
    let companion = try RelayStore(path: root.appendingPathComponent("first-use-companion.sqlite").path, masterKey: Data(repeating: 61, count: 32))
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0,
                                                                     clientAddressHeader: "X-Check-Client"), collaboration: store)
    try await server.start()
    do {
        let url = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        let endpoint = try CollaborationServiceEndpoint(url, allowsInsecureLoopback: true)
        let credentials = CollaborationCredentialStore(vault: ShareLinkVault(), bundleIdentifier: AppChannel.devBundleIdentifier)
        func mac(_ name: String) throws -> CollaborationAccountController {
            try CollaborationAccountController(store: CollaborationAccountStore(applicationSupportRoot: root.appendingPathComponent("first-use-\(name)"),
                bundleIdentifier: AppChannel.devBundleIdentifier), credentialStore: credentials, bundleIdentifier: AppChannel.devBundleIdentifier)
        }
        try shareLinkCheck(CollaborationServiceEndpoint.channelDefault(bundleIdentifier: AppChannel.prodBundleIdentifier, environment: [:])?.canonicalString == "https://relay.arrayapp.dev"
            && CollaborationServiceEndpoint.channelDefault(bundleIdentifier: AppChannel.devBundleIdentifier, environment: [:])?.canonicalString == "https://arrayapp-relay-staging.fly.dev"
            && CollaborationServiceEndpoint.channelDefault(bundleIdentifier: nil, environment: [:])?.canonicalString == "https://arrayapp-relay-staging.fly.dev"
            && CollaborationServiceEndpoint.channelDefault(bundleIdentifier: AppChannel.prodBundleIdentifier,
                environment: ["CONTINUUM_COLLABORATION_ENDPOINT": url.absoluteString])?.canonicalString == endpoint.canonicalString,
            "Prod builds default to relay.arrayapp.dev, every other build to staging, and CONTINUUM_COLLABORATION_ENDPOINT overrides both")

        let peopleBefore = try await store.operatorPeople().count
        let sender = try mac("sender")
        var asked: [String] = []
        let ready = try await sender.ensureAccount(defaultEndpoint: endpoint, deviceLabel: "Sender Mac", askName: { relay in asked.append(relay); return "Dylan" })
        let peopleAfter = try await store.operatorPeople().count
        try shareLinkCheck(ready && sender.status == .ready && sender.activeAccount?.label == "Dylan" && asked == [endpoint.shareLinkRelay]
            && sender.activeAccount?.endpoint == endpoint.canonicalString && peopleAfter == peopleBefore + 1,
            "a Mac with no account signs up at the default relay with only a name: no operator code, no key")
        let relaunched = try mac("sender")
        let reused = try await relaunched.ensureAccount(defaultEndpoint: endpoint, deviceLabel: "Sender Mac", askName: { relay in asked.append(relay); return "Again" })
        let peopleReused = try await store.operatorPeople().count
        try shareLinkCheck(reused && relaunched.status == .ready && relaunched.activeAccount?.identity == sender.activeAccount?.identity
            && asked.count == 1 && peopleReused == peopleAfter, "a Mac with an account reuses it after a relaunch, asking nothing")

        // Share an agent from the new account, then mint its link.
        let area = try await relaunched.createArea(label: "Checkout").document
        let host = try await relaunched.registerHost()
        let controller = try relaunched.makeSharedAreaController(area: area.id.rawValue)
        await controller.open()
        let agentTile = Tile(id: UUID(), kind: .managedAgent, title: "Map the checkout state machine", frame: .init(x: 40, y: 80, width: 640, height: 480),
            zPosition: .fromLegacyRank(0), zoneId: UUID(), runtimeRef: .init(kind: .terminalSession, id: UUID()), metadata: .init())
        let source = SharedAreaPublication.SourceTile(projectID: UUID(), tile: agentTile, agentID: .init(rawValue: UUID()))
        let inventory = SharedAreaPublication.Inventory(workspaceID: UUID(), coverage: .completeWorkspace, sources: [source])
        let choices: [SharedAreaPublication.Choice] = [.init(source: source.key, content: .agentObservation)]
        let review = try SharedAreaPublication.prepare(inventory: inventory, selection: .tiles([source.key]), choices: choices,
            area: area.id, author: relaunched.activeAccount!.identity.person, host: host, expectedRevision: area.revision)
        let published = await controller.submitPublication(try SharedAreaPublication.confirm(review, expectedDigest: review.digest, inventory: inventory, choices: choices))
        await controller.close()
        guard case .accepted = published else { throw CheckFailure(label: "share links: the first-use sender's agent was not published: \(published)") }
        let link = try await relaunched.createShareLink(area: area.id.rawValue, slug: "first-use", lifetime: .untilRevoked)

        let receiver = try mac("receiver")
        let joined = await ShareLinkOpener(account: receiver, signIn: { _ in false }, askName: { _, _ in "Sam" }, open: { _, _ in },
                                           allowsInsecureLoopback: true).open(link.url)
        let seen = try await receiver.openArea(id: area.id.rawValue).document
        try shareLinkCheck(joined == .opened(area: area.id.rawValue) && seen.items.contains { $0.kind == .agentObservation }
            && receiver.activeAccount?.label == "Sam",
            "the new sender's shared agent reaches a second fresh Mac through the link alone")

        // Self-enroll is limited per address, and over the limit creates nothing.
        let session = URLSession(configuration: .ephemeral)
        func enroll(from address: String?) async throws -> Int {
            var request = URLRequest(url: url.appendingPathComponent("collaboration/v1/self-enroll"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if let address { request.setValue(address, forHTTPHeaderField: "X-Check-Client") }
            request.httpBody = try JSONEncoder().encode(Collaboration.SelfEnroll(displayName: "Visitor", deviceLabel: "Mac"))
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        var statuses: [Int] = []
        for _ in 1...3 { statuses.append(try await enroll(from: "203.0.113.7")) }
        let beforeOver = try await store.operatorPeople().count
        let over = try await enroll(from: "203.0.113.7"), elsewhere = try await enroll(from: "203.0.113.8")
        let afterOver = try await store.operatorPeople().count
        try shareLinkCheck(statuses == [201, 201, 201] && over == 429 && elsewhere == 201 && afterOver == beforeOver + 1,
            "self-enroll answers 429 past the per-address limit, creates nothing, and leaves other addresses alone")
        // The loopback address already signed the sender up; use up the rest.
        for _ in 1...2 { _ = try await enroll(from: nil) }
        let limited = try mac("limited")
        do {
            _ = try await limited.ensureAccount(defaultEndpoint: endpoint, deviceLabel: "Mac", askName: { _ in "Late" })
            throw CheckFailure(label: "share links: a rate-limited first use signed up")
        } catch let error as CollaborationClientError where error == .server(status: 429, code: "rateLimited") {}
        try shareLinkCheck(limited.accounts.isEmpty && limited.status != .ready, "a rate-limited first use saves no account")
        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
}

/// Joins are limited per link and per client address. A second relay with
/// small limits, behind a test header standing in for Fly's `fly-client-ip`.
@MainActor
private func runShareLinkJoinLimitChecks(root: URL) async throws {
    let store = try CollaborationStore(path: root.appendingPathComponent("limits.sqlite").path, masterKey: Data(repeating: 59, count: 32),
                                       joinLimits: .init(perLink: 3, perAddress: 5, window: 3600))
    let companion = try RelayStore(path: root.appendingPathComponent("limits-companion.sqlite").path, masterKey: Data(repeating: 59, count: 32))
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0,
                                                                     clientAddressHeader: "X-Check-Client"), collaboration: store)
    try await server.start()
    do {
        let url = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        let endpoint = try CollaborationServiceEndpoint(url, allowsInsecureLoopback: true)
        let credentials = CollaborationCredentialStore(vault: ShareLinkVault(), bundleIdentifier: AppChannel.devBundleIdentifier)
        func signedOut() throws -> CollaborationAccountController {
            try CollaborationAccountController(store: CollaborationAccountStore(applicationSupportRoot: root.appendingPathComponent("limits-\(UUID())"),
                bundleIdentifier: AppChannel.devBundleIdentifier), credentialStore: credentials, bundleIdentifier: AppChannel.devBundleIdentifier)
        }
        let owner = try signedOut()
        _ = try await owner.enroll(endpoint: endpoint, code: try await store.provisionPerson(label: "Dylan").code, deviceLabel: "Dylan", accountLabel: "Dylan")
        let area = try await owner.createArea(label: "Limits").document.id.rawValue
        let first = try await owner.createShareLink(area: area, slug: "limit-one", lifetime: .untilRevoked)
        let second = try await owner.createShareLink(area: area, slug: "limit-two", lifetime: .untilRevoked)
        let session = URLSession(configuration: .ephemeral)
        func join(_ link: Collaboration.ShareLink, as name: String, from address: String) async throws -> Int {
            var request = URLRequest(url: url.appendingPathComponent("collaboration/v1/links/join"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(address, forHTTPHeaderField: "X-Check-Client")
            request.httpBody = try JSONEncoder().encode(Collaboration.JoinShareLink(slug: link.slug, token: link.token, displayName: name, deviceLabel: "Mac"))
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        func people(_ link: Collaboration.ShareLink) async throws -> Int {
            try await owner.shareLinks(area: area).first { $0.id == link.id }?.people.count ?? -1
        }
        var statuses: [Int] = []
        for index in 1...3 { statuses.append(try await join(first, as: "Guest \(index)", from: "198.51.100.1")) }
        let peopleBefore = try await store.operatorPeople().count
        let overLink = try await join(first, as: "Guest 4", from: "198.51.100.9")
        let peopleAfter = try await store.operatorPeople().count, admittedFirst = try await people(first)
        try shareLinkCheck(statuses == [201, 201, 201] && overLink == 429 && peopleAfter == peopleBefore && admittedFirst == 3,
            "a link's join limit answers 429 from any address and creates no person or admission")
        statuses = []
        for index in 1...2 { statuses.append(try await join(second, as: "Visitor \(index)", from: "198.51.100.1")) }
        let overAddress = try await join(second, as: "Visitor 3", from: "198.51.100.1")
        let otherAddress = try await join(second, as: "Visitor 4", from: "198.51.100.2")
        let admittedSecond = try await people(second)
        try shareLinkCheck(statuses == [201, 201] && overAddress == 429 && otherAddress == 201 && admittedSecond == 3,
            "an address's join limit spans links and leaves other addresses alone")

        var asked = 0
        let newcomer = try signedOut()
        let outcome = await ShareLinkOpener(account: newcomer, signIn: { _ in false }, askName: { _, _ in asked += 1; return "Late" },
                                            open: { _, _ in }, allowsInsecureLoopback: true).open(first.url)
        try shareLinkCheck(outcome == .refused(ShareLinkOpener.rateLimitedMessage) && asked == 1 && newcomer.accounts.isEmpty,
            "a rate-limited newcomer sees the limit in plain words and no account is saved")
        try await server.stop()
    } catch {
        try? await server.stop()
        throw error
    }
}
