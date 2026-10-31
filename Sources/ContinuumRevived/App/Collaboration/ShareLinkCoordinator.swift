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
    typealias InventoryProvider = @MainActor (SharedAreaPublication.Selection) throws -> SharedAreaInventory.Snapshot

    private let accountProvider: AccountProvider
    private let signIn: SignIn
    private let askName: AskName
    private let openArea: OpenArea
    private let inventory: InventoryProvider
    /// Shows a refusal to the person. Production presents it on the canvas window.
    var presentRefusal: @MainActor (String) -> Void
    private(set) var lastOutcome: ShareLinkOpenOutcome?
    /// Completed opens, so a caller can tell a repeated outcome from a stale one.
    private(set) var openCount = 0

    /// Local checks reach a loopback relay over plain http.
    var allowsInsecureLoopback = false

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
            let opener = ShareLinkOpener(account: model, signIn: signIn, askName: askName, open: { [openArea] state, model in
                guard let person = model.activeAccount?.identity.person else { throw CollaborationAccountFailure.notConnected }
                let area = state.document.id.rawValue
                try openArea(try model.makeSharedAreaController(area: area), person, area, model)
            }, deviceLabel: Host.current().localizedName ?? "This Mac", allowsInsecureLoopback: allowsInsecureLoopback)
            switch await opener.open(url) {
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
        return try await mint(try await signedInAccount(), area: area, slug: slug, lifetime: lifetime)
    }

    /// "New link" for an area that is already shared. Same as createShareLink;
    /// kept as its own name for the popover.
    func newLink(area: UUID, slug: String, lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink {
        guard ShareLinkURL.isValidSlug(slug) else { throw ShareLinkFailure.invalidSlug }
        return try await mint(try await signedInAccount(), area: area, slug: slug, lifetime: lifetime)
    }
    func revokeLink(area: UUID, link: UUID) async throws {
        try await signedInAccount().revokeShareLink(area: area, link: link)
    }
    func removeAccess(area: UUID, link: UUID, person: SharedArea.ID<SharedArea.Person>) async throws {
        try await signedInAccount().removeShareLinkPerson(area: area, link: link, person: person)
    }
    func listAccess(area: UUID) async throws -> [Collaboration.ShareLinkAccess] {
        try await signedInAccount().shareLinks(area: area)
    }

    /// The signed-in account, signing in first if needed. The shared zone
    /// (part 2) creates its area with it before publishing.
    func readyAccount() async throws -> CollaborationAccountController { try await signedInAccount() }

    // MARK: Internals

    private func signedInAccount() async throws -> CollaborationAccountController {
        let model = try accountProvider()
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
    @discardableResult
    func publish(selection: SharedAreaPublication.Selection, intoArea area: UUID) async throws -> [UUID: SharedArea.ID<SharedArea.Object>] {
        let model = try await signedInAccount()
        let snapshot = try inventory(selection)
        guard snapshot.inventory.sources.contains(where: { Self.mode(for: $0.tile.kind) != nil }) else { throw ShareLinkFailure.nothingToShare }
        guard let person = model.activeAccount?.identity.person else { throw ShareLinkFailure.notSignedIn }
        let host = try await model.registerHost()
        let controller = try model.makeSharedAreaController(area: area)
        await controller.open()
        do {
            guard controller.canSubmit else { throw ShareLinkFailure.unavailableArea }
            let coordinator = try SharedAreaCaptureCoordinator(selection: selection, controller: controller, person: person, host: host,
                inventoryProvider: { [inventory] in try inventory(selection) },
                submitter: { await controller.submitPublication($0) })
            for row in coordinator.review.rows where row.disposition == .needsReview {
                try coordinator.setMode(Self.mode(for: row.tileKind) ?? .omit, for: row.source)
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
