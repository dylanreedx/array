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
}
