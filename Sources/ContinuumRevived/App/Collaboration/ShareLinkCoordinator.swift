import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

enum ShareLinkOpenOutcome: Equatable {
    case opened(area: UUID)
    case refused(String)
    case cancelled
}

enum ShareLinkFailure: Error, Equatable, LocalizedError {
    case invalidSlug, slugTaken, nothingToShare, notSignedIn, noWorkspace, unavailableArea
    case publishFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidSlug: return "Use lowercase letters, numbers and single hyphens for the link name."
        case .slugTaken: return "Another live link already uses this name. Choose a different one."
        case .nothingToShare: return "Nothing in this selection can be shared. Terminals stay private."
        case .notSignedIn: return "Sign in to collaboration to share a link."
        case .noWorkspace: return "Open a workspace before sharing."
        case .unavailableArea: return "The shared area is not reachable. Reconnect and try again."
        case .publishFailed(let message): return message
        }
    }
}

/// The share-link controller (IN-CANVAS.md, Round 2). The owner side mints and
/// manages links on an area that already exists (part 2's shared zone makes
/// it); the receiving side is the one entry point for array:// and
/// arrayapp.dev/s/ links. The popover (part 3) and the URL handler both come
/// through here.
@MainActor
final class ShareLinkCoordinator {
    typealias AccountProvider = @MainActor () throws -> CollaborationAccountController
    typealias SignIn = ShareLinkOpener.SignIn
    typealias AskName = ShareLinkOpener.AskName
    typealias OpenArea = @MainActor (SharedAreaController, SharedArea.ID<SharedArea.Person>, UUID, CollaborationAccountController) throws -> Void
    /// Mode A: a link to one agent lands as one tile, not a zone.
    typealias OpenAgent = @MainActor (CollaborationAccountController, UUID, SharedArea.Item) async throws -> Void
    typealias InventoryProvider = @MainActor (SharedAreaPublication.Selection) throws -> SharedAreaInventory.Snapshot

    private let accountProvider: AccountProvider
    private let signIn: SignIn
    private let askName: AskName
    private let openArea: OpenArea
    /// Nil keeps every link on the zone path (checks that predate mode A).
    var openAgent: OpenAgent?
    /// Mode B: any other link lands as one portal tile, never a zone. Nil
    /// keeps those links on the zone path (checks that predate mode B).
    typealias OpenPortal = @MainActor (CollaborationAccountController, UUID, SharedArea.Document) async throws -> Void
    var openPortal: OpenPortal?
    /// A link to one note, file, diff, browser or terminal lands as one tile too.
    var openTile: OpenAgent?
    private let inventory: InventoryProvider
    /// Shows a refusal to the person. Production presents it on the canvas window.
    var presentRefusal: @MainActor (String) -> Void
    private(set) var lastOutcome: ShareLinkOpenOutcome?
    /// Completed opens, so a caller can tell a repeated outcome from a stale one.
    private(set) var openCount = 0

    /// Local checks reach a loopback relay over plain http.
    var allowsInsecureLoopback = false
    /// Where a Mac with no account signs up on first use: the channel's relay,
    /// or `CONTINUUM_COLLABORATION_ENDPOINT`. Nil falls back to the hub.
    var defaultEndpoint: @MainActor () -> CollaborationServiceEndpoint? = {
        CollaborationServiceEndpoint.channelDefault(bundleIdentifier: Bundle.main.bundleIdentifier,
                                                    environment: ProcessInfo.processInfo.environment)
    }
    /// Asks a first-time sender for the name teammates see: relay -> name, or
    /// nil if they dismissed it. Production shows a sheet on the canvas window.
    var askSignUpName: @MainActor (String) async -> String? = { _ in nil }

    init(account: @escaping AccountProvider, signIn: @escaping SignIn, askName: @escaping AskName, openArea: @escaping OpenArea,
         inventory: @escaping InventoryProvider, presentRefusal: @escaping @MainActor (String) -> Void) {
        accountProvider = account; self.signIn = signIn; self.askName = askName; self.openArea = openArea
        self.inventory = inventory; self.presentRefusal = presentRefusal
    }

    // MARK: Receiving

    /// The one entry point for array://s/<slug>#<token> and
    /// https://arrayapp.dev/s/<slug>#<token>.
    @discardableResult
    func open(_ url: URL) async -> ShareLinkOpenOutcome {
        let outcome: ShareLinkOpenOutcome
        do {
            let model = try accountProvider()
            let opener = ShareLinkOpener(account: model, signIn: signIn, askName: askName, open: { [openArea, openAgent, openPortal, openTile] state, model in
                guard let person = model.activeAccount?.identity.person else { throw CollaborationAccountFailure.notConnected }
                let area = state.document.id.rawValue
                // Mode A: a link to one agent lands as one tile, never a zone.
                if let openAgent, let item = AppDelegate.sharedAgentItem(in: state.document, me: person) {
                    try await openAgent(model, area, item)
                    return
                }
                // One note, file, diff, browser or terminal lands as one tile.
                if let openTile, let item = AppDelegate.sharedLiveTileItem(in: state.document, me: person) {
                    try await openTile(model, area, item)
                    return
                }
                // Mode B: a portal, or a 0.7.37 area, lands as one portal tile.
                // No link opens a zone any more.
                if let openPortal {
                    try await openPortal(model, area, state.document)
                    return
                }
                try openArea(try model.makeSharedAreaController(area: area), person, area, model)
            }, deviceLabel: Host.current().localizedName ?? "This Mac", allowsInsecureLoopback: allowsInsecureLoopback)
            let opened = await opener.open(url)
            switch opened {
            case .opened(let area): outcome = .opened(area: area)
            case .refused(let message): outcome = .refused(message)
            case .cancelled: outcome = .cancelled
            }
        } catch {
            outcome = .refused("Collaboration could not start on this Mac. Your local data is unchanged.")
        }
        lastOutcome = outcome; openCount += 1
        if case .refused(let message) = outcome { presentRefusal(message) }
        return outcome
    }

    // MARK: Sharing

    /// Mints a link on an area that already exists. Creating the area,
    /// publishing into it and opening the zone are the shared zone's job.
    func createShareLink(area: UUID, slug: String, lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink {
        guard ShareLinkURL.isValidSlug(slug) else { throw ShareLinkFailure.invalidSlug }
        return try await Self.waitingOutBusy { try await self.mint(try await self.signedInAccount(), area: area, slug: slug, lifetime: lifetime) }
    }

    /// The account runs one request at a time and refuses a second with
    /// `.busy` before anything is sent. The open popover re-reads who has
    /// access every 2 s, so a press could meet that read in flight; it waits
    /// its turn instead of failing.
    static func waitingOutBusy<T>(_ body: () async throws -> T) async throws -> T {
        for _ in 0..<40 {
            do { return try await body() }
            catch CollaborationAccountFailure.busy { try await Task.sleep(for: .milliseconds(100)) }
        }
        return try await body()
    }

    /// "New link" for an area that is already shared. Same as createShareLink;
    /// kept as its own name for the popover.
    func newLink(area: UUID, slug: String, lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink {
        guard ShareLinkURL.isValidSlug(slug) else { throw ShareLinkFailure.invalidSlug }
        return try await Self.waitingOutBusy { try await self.mint(try await self.signedInAccount(), area: area, slug: slug, lifetime: lifetime) }
    }
    func revokeLink(area: UUID, link: UUID) async throws {
        try await Self.waitingOutBusy { try await self.signedInAccount().revokeShareLink(area: area, link: link) }
    }
    func removeAccess(area: UUID, link: UUID, person: SharedArea.ID<SharedArea.Person>) async throws {
        try await Self.waitingOutBusy { try await self.signedInAccount().removeShareLinkPerson(area: area, link: link, person: person) }
    }
    func listAccess(area: UUID) async throws -> [Collaboration.ShareLinkAccess] {
        try await Self.waitingOutBusy { try await self.signedInAccount().shareLinks(area: area) }
    }

    /// The signed-in account, signing in first if needed. The shared zone
    /// (part 2) creates its area with it before publishing.
    func readyAccount() async throws -> CollaborationAccountController { try await signedInAccount() }

    // MARK: Internals

    /// The signed-in account. A Mac that has one reuses it; a Mac with none
    /// signs up inline at the default relay with only a display name. No
    /// operator code and no key.
    private func signedInAccount() async throws -> CollaborationAccountController {
        let model = try accountProvider()
        if let endpoint = defaultEndpoint() {
            guard try await model.ensureAccount(defaultEndpoint: endpoint, deviceLabel: Host.current().localizedName ?? "This Mac",
                                                askName: askSignUpName) else { throw ShareLinkFailure.notSignedIn }
            return model
        }
        if model.status != .ready, let remembered = model.selectedAccountID ?? (model.accounts.count == 1 ? model.accounts.first?.id : nil) {
            _ = try? await model.select(accountID: remembered)
        }
        if model.status != .ready {
            guard try await signIn(model), model.status == .ready else { throw ShareLinkFailure.notSignedIn }
        }
        return model
    }

    private func mint(_ model: CollaborationAccountController, area: UUID, slug: String,
                      lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink {
        do { return try await model.createShareLink(area: area, slug: slug, lifetime: lifetime) }
        catch let error as CollaborationClientError {
            if case .server(409, "slugTaken") = error { throw ShareLinkFailure.slugTaken }
            throw error
        }
    }

    static func mode(for kind: TileKind) -> SharedAreaInventory.Mode? {
        switch kind {
        case .managedAgent: return .agentObservation
        case .note: return .discussion
        case .diffReview, .file: return .artifact
        default: return nil
        }
    }

    /// Publish-by-kind, for the shared zone (part 2) to call after it creates
    /// the area. The selection was chosen explicitly, so every row the review
    /// would ask about is decided by its kind instead of by a window: agents
    /// as live observations, notes as discussion, diffs and files as
    /// snapshots; terminals and other kinds stay private. Returns the source
    /// tile -> published object for every source-bound item (agents and
    /// snapshots). Discussion items carry no source binding in the domain.
    /// `live`: the share-kinds path (`.plans/105-collaboration/SHARE-KINDS.md`).
    /// Agents still go as observations; notes, files, diffs, browsers and
    /// terminals go as live tiles their host keeps publishing. The portal and
    /// a single tile's Share use it; the 0.7.37 shared zone does not.
    static func liveMode(for kind: TileKind) -> SharedAreaInventory.Mode? {
        if kind == .managedAgent { return .agentObservation }
        return SharedAreaPublication.liveKind(for: kind) != nil ? .liveTile : nil
    }

    @discardableResult
    func publish(selection: SharedAreaPublication.Selection, intoArea area: UUID, live: Bool = false) async throws -> [UUID: SharedArea.ID<SharedArea.Object>] {
        let model = try await signedInAccount()
        let snapshot = try inventory(selection)
        let modeFor: (TileKind) -> SharedAreaInventory.Mode? = live ? Self.liveMode(for:) : Self.mode(for:)
        guard snapshot.inventory.sources.contains(where: { modeFor($0.tile.kind) != nil }) else { throw ShareLinkFailure.nothingToShare }
        guard let person = model.activeAccount?.identity.person else { throw ShareLinkFailure.notSignedIn }
        let host = try await model.registerHost()
        let controller = try model.makeSharedAreaController(area: area)
        await controller.open()
        do {
            guard controller.canSubmit else { throw ShareLinkFailure.unavailableArea }
            let coordinator = try SharedAreaCaptureCoordinator(selection: selection, controller: controller, person: person, host: host,
                inventoryProvider: { [inventory] in try inventory(selection) },
                submitter: { await controller.submitPublication($0) })
            for row in coordinator.review.rows where row.disposition == .needsReview || live {
                try coordinator.setMode(modeFor(row.tileKind) ?? .omit, for: row.source)
            }
            for _ in 0..<1500 where !coordinator.capturing.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            guard coordinator.canConfirm else { throw ShareLinkFailure.publishFailed(coordinator.message) }
            await coordinator.confirm()
            guard coordinator.state == .published else { throw ShareLinkFailure.publishFailed(coordinator.message) }
        } catch {
            await controller.close()
            throw error
        }
        var objects: [UUID: SharedArea.ID<SharedArea.Object>] = [:]
        for binding in controller.sourceBindings { if let tile = binding.tileID { objects[tile] = binding.object } }
        await controller.close()
        return objects
    }
}
