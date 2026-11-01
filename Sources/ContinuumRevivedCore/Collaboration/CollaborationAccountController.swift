import Foundation
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

public protocol CollaborationAccountTransport: Sendable {
    func redeem(code: String, deviceLabel: String) async throws -> Collaboration.Credential
    func identity() async throws -> Collaboration.Identity
    func createArea() async throws -> Collaboration.State
    func state(area: UUID) async throws -> Collaboration.State
    func accept(code: String) async throws -> Collaboration.Scope
    func invite(area: UUID, person: SharedArea.ID<SharedArea.Person>, role: Collaboration.Role) async throws -> Collaboration.Invitation
    func registerHost() async throws -> Collaboration.Host
    func createShareLink(area: UUID, request: Collaboration.ShareLinkRequest) async throws -> Collaboration.ShareLink
    func acceptShareLink(slug: String, token: String) async throws -> Collaboration.Scope
    func shareLinks(area: UUID) async throws -> [Collaboration.ShareLinkAccess]
    func revokeShareLink(area: UUID, link: UUID) async throws
    func removeShareLinkPerson(area: UUID, link: UUID, person: UUID) async throws
    func joinShareLink(_ request: Collaboration.JoinShareLink) async throws -> Collaboration.ShareLinkJoin
    func selfEnroll(_ request: Collaboration.SelfEnroll) async throws -> Collaboration.Credential
}

/// Fakes written before share links existed refuse them like an old relay.
public extension CollaborationAccountTransport {
    func createShareLink(area: UUID, request: Collaboration.ShareLinkRequest) async throws -> Collaboration.ShareLink { throw CollaborationClientError.server(status: 404, code: "notFound") }
    func acceptShareLink(slug: String, token: String) async throws -> Collaboration.Scope { throw CollaborationClientError.server(status: 404, code: "notFound") }
    func shareLinks(area: UUID) async throws -> [Collaboration.ShareLinkAccess] { throw CollaborationClientError.server(status: 404, code: "notFound") }
    func revokeShareLink(area: UUID, link: UUID) async throws { throw CollaborationClientError.server(status: 404, code: "notFound") }
    func removeShareLinkPerson(area: UUID, link: UUID, person: UUID) async throws { throw CollaborationClientError.server(status: 404, code: "notFound") }
    func joinShareLink(_ request: Collaboration.JoinShareLink) async throws -> Collaboration.ShareLinkJoin { throw CollaborationClientError.server(status: 404, code: "notFound") }
    func selfEnroll(_ request: Collaboration.SelfEnroll) async throws -> Collaboration.Credential { throw CollaborationClientError.server(status: 404, code: "notFound") }
}

public struct CollaborationAccountAPITransport: CollaborationAccountTransport {
    private let api: CollaborationAPI
    public init(endpoint: CollaborationServiceEndpoint, credential: Collaboration.Credential?) throws {
        api = try CollaborationAPI(baseURL: endpoint.canonicalURL, credential: credential?.token,
            allowsInsecureLoopback: endpoint.canonicalURL.scheme == "http")
    }
    public func redeem(code: String, deviceLabel: String) async throws -> Collaboration.Credential { try await api.redeem(code: code, deviceLabel: deviceLabel) }
    public func identity() async throws -> Collaboration.Identity { try await api.identity() }
    public func createArea() async throws -> Collaboration.State { try await api.createArea() }
    public func state(area: UUID) async throws -> Collaboration.State { try await api.state(area: area) }
    public func accept(code: String) async throws -> Collaboration.Scope { try await api.accept(code: code) }
    public func invite(area: UUID, person: SharedArea.ID<SharedArea.Person>, role: Collaboration.Role) async throws -> Collaboration.Invitation {
        try await api.invite(area: area, request: .init(person: person, role: role))
    }
    public func registerHost() async throws -> Collaboration.Host { try await api.registerHost() }
    public func createShareLink(area: UUID, request: Collaboration.ShareLinkRequest) async throws -> Collaboration.ShareLink {
        try await api.createShareLink(area: area, request: request)
    }
    public func acceptShareLink(slug: String, token: String) async throws -> Collaboration.Scope { try await api.acceptShareLink(slug: slug, token: token) }
    public func shareLinks(area: UUID) async throws -> [Collaboration.ShareLinkAccess] { try await api.shareLinks(area: area) }
    public func revokeShareLink(area: UUID, link: UUID) async throws { try await api.revokeShareLink(area: area, link: link) }
    public func removeShareLinkPerson(area: UUID, link: UUID, person: UUID) async throws {
        try await api.removeShareLinkPerson(area: area, link: link, person: person)
    }
    public func joinShareLink(_ request: Collaboration.JoinShareLink) async throws -> Collaboration.ShareLinkJoin { try await api.joinShareLink(request) }
    public func selfEnroll(_ request: Collaboration.SelfEnroll) async throws -> Collaboration.Credential { try await api.selfEnroll(request) }
}

public enum CollaborationAccountFailure: Error, Sendable, Equatable, LocalizedError {
    case busy, superseded, accountMissing, credentialsMissing, notConnected, identityMismatch, invalidInput, invalidState
    case credentialPersistenceFailed, credentialRetainedVerificationFailure, credentialRetainedMetadataFailure
    case areaRetainedMetadataFailure(UUID), invitationAcceptedStateUnavailable(UUID)
    public var errorDescription: String? {
        switch self {
        case .busy: return "Another collaboration action is still running."
        case .superseded: return "The collaboration account changed before this action finished."
        case .accountMissing: return "This collaboration account is no longer remembered on this Mac."
        case .credentialsMissing: return "This device's collaboration credential is missing. Enroll this device again with a new enrollment code."
        case .notConnected: return "Connect to a collaboration account first."
        case .identityMismatch: return "The service identity does not match the saved collaboration account."
        case .invalidInput: return "Check the collaboration code, name or identifier."
        case .invalidState: return "The service returned an incompatible shared workspace."
        case .credentialPersistenceFailed: return "Enrollment completed, but the device credential could not be saved. The enrollment code may already be consumed; request a new device enrollment."
        case .credentialRetainedVerificationFailure: return "The new device credential is saved, but online verification did not finish. Remember the retained account and reconnect; do not reuse the enrollment code."
        case .credentialRetainedMetadataFailure: return "The device credential is saved, but the local account list could not be updated. Retry remembering the retained account; do not reuse the enrollment code."
        case .areaRetainedMetadataFailure(let area):
            return "The shared workspace is available, but its local record could not be saved. Open workspace \(area.uuidString) to retry saving it; do not create another workspace."
        case .invitationAcceptedStateUnavailable(let area):
            return "The invitation was accepted for workspace \(area.uuidString), but its state could not be loaded. Open this workspace by ID to reconnect; do not reuse the invitation code."
        }
    }
}

/// Account selection is local navigation. Every online operation still uses the
/// service's own device credential and current membership. No CLI auth is read.
@MainActor
public final class CollaborationAccountController {
    public enum Status: Equatable, Sendable { case signedOut, connecting, ready, missingCredential, unavailable }
    public typealias TransportFactory = @Sendable (CollaborationServiceEndpoint, Collaboration.Credential?) throws -> any CollaborationAccountTransport
    public private(set) var status: Status = .signedOut
    public private(set) var isBusy = false
    public private(set) var lastError: (any Error)?
    /// Safe metadata for a successfully saved credential whose enrollment was
    /// interrupted before the metadata commit. It contains no credential bytes.
    public private(set) var pendingAccounts: [CollaborationLocalAccount] = []
    public var pendingAccount: CollaborationLocalAccount? { pendingAccounts.first }
    public var onChange: (@MainActor () -> Void)?
    public var accounts: [CollaborationLocalAccount] { registry.accounts }
    public var selectedAccountID: String? { registry.selectedAccountID }
    public var activeAccount: CollaborationLocalAccount? { active?.account }

    private struct Active {
        var account: CollaborationLocalAccount
        let transport: any CollaborationAccountTransport
    }
    private let store: CollaborationAccountStore
    private let credentials: CollaborationCredentialStore
    private let bundleIdentifier: String?
    private let transportFactory: TransportFactory
    private let areaTransportFactory: SharedAreaController.TransportFactory
    private var registry: CollaborationAccountRegistry
    private var active: Active?
    private var operation: UUID?

    public init(store: CollaborationAccountStore, credentialStore: CollaborationCredentialStore,
                bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                transportFactory: @escaping TransportFactory = CollaborationAccountController.liveTransport,
                areaTransportFactory: @escaping SharedAreaController.TransportFactory = SharedAreaController.liveTransport) throws {
        guard store.channelNamespace == AppChannel.bundledDefaultsDomain(bundleIdentifier: bundleIdentifier),
              credentialStore.namespace == CollaborationCredentialStore.namespace(bundleIdentifier: bundleIdentifier) else {
            throw CollaborationCredentialStoreError.scopeMismatch
        }
        self.store = store; credentials = credentialStore; self.bundleIdentifier = bundleIdentifier
        self.transportFactory = transportFactory; self.areaTransportFactory = areaTransportFactory
        registry = try store.load()
    }
    public nonisolated static func liveTransport(endpoint: CollaborationServiceEndpoint, credential: Collaboration.Credential?) throws -> any CollaborationAccountTransport {
        try CollaborationAccountAPITransport(endpoint: endpoint, credential: credential)
    }

    /// Disconnect this account coordinator, retaining the saved device login.
    /// Existing area windows own their own subscriptions and close separately.
    public func signOut() {
        operation = nil; isBusy = false; active = nil; status = .signedOut; lastError = nil
        changed()
    }
    public func reload() throws { registry = try store.load(); changed() }

    @discardableResult
    public func enroll(endpoint: CollaborationServiceEndpoint, code: String, deviceLabel: String,
                       accountLabel: String) async throws -> CollaborationLocalAccount {
        guard validCode(code), CollaborationLocalAccount.validLabel(deviceLabel), deviceLabel.utf8.count <= 120,
              CollaborationLocalAccount.validLabel(accountLabel) else { throw CollaborationAccountFailure.invalidInput }
        let ticket = try begin(selecting: true)
        defer { finish(ticket) }
        do {
            let unauthenticated = try transportFactory(endpoint, nil)
            let credential = try await unauthenticated.redeem(code: code, deviceLabel: deviceLabel)
            // Redemption can have committed even if a user disconnects while its
            // response is in flight. Preserve that credential before discarding
            // the late UI completion; never automatically reuse the code.
            let account = CollaborationLocalAccount(endpoint: endpoint, identity: credential.identity, label: accountLabel)
            do { try credentials.save(credential, for: .init(endpoint: endpoint, identity: credential.identity)) }
            catch { lastError = error; throw CollaborationAccountFailure.credentialPersistenceFailed }
            if !pendingAccounts.contains(where: { $0.id == account.id }) { pendingAccounts.append(account) }
            try current(ticket)
            let authenticated = try transportFactory(endpoint, credential)
            let identity: Collaboration.Identity
            do { identity = try await authenticated.identity() }
            catch { throw CollaborationAccountFailure.credentialRetainedVerificationFailure }
            try current(ticket)
            guard identity == credential.identity else { throw CollaborationAccountFailure.identityMismatch }
            do { try remember(account, selected: true) }
            catch { lastError = error; throw CollaborationAccountFailure.credentialRetainedMetadataFailure }
            pendingAccounts.removeAll { $0.id == account.id }
            active = .init(account: account, transport: authenticated); status = .ready; lastError = nil; changed()
            return account
        } catch {
            if operation == ticket { active = nil; status = .unavailable; lastError = error; changed() }
            throw error
        }
    }

    /// Explicit local repair after a credential was already saved. This neither
    /// redeems a code nor grants online authority; selecting revalidates it.
    @discardableResult
    public func rememberRetainedCredential() throws -> CollaborationLocalAccount {
        guard !isBusy, let account = pendingAccount else { throw CollaborationAccountFailure.accountMissing }
        let endpoint = try account.endpointValue
        guard try credentials.load(for: .init(endpoint: endpoint, identity: account.identity)) != nil else { throw CollaborationAccountFailure.credentialsMissing }
        try remember(account, selected: true)
        pendingAccounts.removeAll { $0.id == account.id }; lastError = nil; changed()
        return account
    }

    @discardableResult
    public func select(accountID: String) async throws -> CollaborationLocalAccount {
        let ticket = try begin(selecting: true)
        defer { finish(ticket) }
        do {
            registry = try store.load()
            guard let account = registry.accounts.first(where: { $0.id == accountID }) else { throw CollaborationAccountFailure.accountMissing }
            let endpoint = try account.endpointValue
            guard let credential = try credentials.load(for: .init(endpoint: endpoint, identity: account.identity)) else {
                throw CollaborationAccountFailure.credentialsMissing
            }
            let transport = try transportFactory(endpoint, credential)
            let identity = try await transport.identity()
            try current(ticket)
            guard identity == account.identity else { throw CollaborationAccountFailure.identityMismatch }
            try updateRegistry { $0.selectedAccountID = accountID }
            active = .init(account: account, transport: transport); status = .ready; lastError = nil; changed()
            return account
        } catch {
            if operation == ticket {
                active = nil
                status = (error as? CollaborationAccountFailure) == .credentialsMissing ? .missingCredential : .unavailable
                lastError = error; changed()
            }
            throw error
        }
    }

    public func createArea(label: String = "Shared workspace") async throws -> Collaboration.State {
        try await withAccount { active, ticket in
            guard CollaborationLocalAccount.validLabel(label) else { throw CollaborationAccountFailure.invalidInput }
            let state = try await active.transport.createArea()
            try self.current(ticket)
            try self.validate(state, expected: nil)
            try self.rememberAdmittedArea(state.scope.area.rawValue, label: label, account: active.account.id)
            return state
        }
    }
    public func acceptInvitation(code: String, label: String = "Shared workspace") async throws -> Collaboration.State {
        try await withAccount { active, ticket in
            guard self.validCode(code), CollaborationLocalAccount.validLabel(label) else { throw CollaborationAccountFailure.invalidInput }
            let scope = try await active.transport.accept(code: code)
            try self.current(ticket)
            let state: Collaboration.State
            do { state = try await active.transport.state(area: scope.area.rawValue) }
            catch {
                try self.current(ticket)
                if self.isCredentialFailure(error) { self.active = nil; self.status = .unavailable }
                throw CollaborationAccountFailure.invitationAcceptedStateUnavailable(scope.area.rawValue)
            }
            try self.current(ticket)
            try self.validate(state, expected: scope.area.rawValue)
            try self.rememberAdmittedArea(scope.area.rawValue, label: label, account: active.account.id)
            return state
        }
    }
    public func openArea(id: UUID, label: String? = nil) async throws -> Collaboration.State {
        try await withAccount { active, ticket in
            if let label, !CollaborationLocalAccount.validLabel(label) { throw CollaborationAccountFailure.invalidInput }
            let state = try await active.transport.state(area: id)
            try self.current(ticket)
            try self.validate(state, expected: id)
            let name = label ?? active.account.knownAreas.first(where: { $0.id == id })?.label ?? "Shared workspace"
            try self.rememberAdmittedArea(id, label: name, account: active.account.id)
            return state
        }
    }
    public func invite(area: UUID, person: SharedArea.ID<SharedArea.Person>, role: Collaboration.Role = .editor) async throws -> Collaboration.Invitation {
        try await withAccount { active, ticket in
            guard role != .owner else { throw CollaborationAccountFailure.invalidInput }
            let result = try await active.transport.invite(area: area, person: person, role: role)
            try self.current(ticket)
            return result
        }
    }
    /// Owner side of a bearer link. The service refuses a slug that a live
    /// link on the relay already uses.
    public func createShareLink(area: UUID, slug: String, lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink {
        try await withAccount { active, ticket in
            guard ShareLinkURL.isValidSlug(slug) else { throw CollaborationAccountFailure.invalidInput }
            let link = try await active.transport.createShareLink(area: area, request: .init(slug: slug, lifetime: lifetime))
            try self.current(ticket)
            guard link.area.rawValue == area, link.slug == slug, ShareLinkURL.isValidToken(link.token) else { throw CollaborationAccountFailure.invalidState }
            return link.with(relay: try active.account.endpointValue.shareLinkRelay)
        }
    }
    /// Admits this account through a link, loads the area and remembers it
    /// under the link's slug, the same way an accepted invitation is kept.
    public func acceptShareLink(slug: String, token: String) async throws -> Collaboration.State {
        try await withAccount { active, ticket in
            guard ShareLinkURL.isValidSlug(slug), ShareLinkURL.isValidToken(token) else { throw CollaborationAccountFailure.invalidInput }
            let scope = try await active.transport.acceptShareLink(slug: slug, token: token)
            try self.current(ticket)
            let state: Collaboration.State
            do { state = try await active.transport.state(area: scope.area.rawValue) }
            catch {
                try self.current(ticket)
                if self.isCredentialFailure(error) { self.active = nil; self.status = .unavailable }
                throw CollaborationAccountFailure.invitationAcceptedStateUnavailable(scope.area.rawValue)
            }
            try self.current(ticket)
            try self.validate(state, expected: scope.area.rawValue)
            let known = active.account.knownAreas.first(where: { $0.id == scope.area.rawValue })?.label
            try self.rememberAdmittedArea(scope.area.rawValue, label: known ?? slug, account: active.account.id)
            return state
        }
    }
    /// Joins through a link on a relay this Mac has no account on: the link's
    /// token is the enrollment, so the person only gives a display name. The
    /// new device credential is saved and the account selected, as `enroll`
    /// does, then the area is loaded and remembered under the slug.
    public func joinShareLink(endpoint: CollaborationServiceEndpoint, slug: String, token: String,
                              displayName: String, deviceLabel: String) async throws -> Collaboration.State {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ShareLinkURL.isValidSlug(slug), ShareLinkURL.isValidToken(token), CollaborationLocalAccount.validLabel(name),
              name.utf8.count <= 120, CollaborationLocalAccount.validLabel(deviceLabel), deviceLabel.utf8.count <= 120 else {
            throw CollaborationAccountFailure.invalidInput
        }
        let ticket = try begin(selecting: true)
        defer { finish(ticket) }
        do {
            let joined = try await transportFactory(endpoint, nil).joinShareLink(.init(slug: slug, token: token, displayName: name, deviceLabel: deviceLabel))
            let account = try await adoptNewCredential(joined.credential, endpoint: endpoint, label: name, ticket: ticket)
            guard let authenticated = active?.transport else { throw CollaborationAccountFailure.notConnected }
            let area = joined.scope.area.rawValue
            let state: Collaboration.State
            do { state = try await authenticated.state(area: area) }
            catch { throw CollaborationAccountFailure.invitationAcceptedStateUnavailable(area) }
            try current(ticket)
            try validate(state, expected: area)
            try rememberAdmittedArea(area, label: slug, account: account.id)
            return state
        } catch {
            if operation == ticket, status != .ready { active = nil; status = .unavailable; lastError = error; changed() }
            throw error
        }
    }
    /// First use on a Mac with no account: sign this person up on `endpoint`
    /// with only a display name. The relay creates the person and this device,
    /// and grants no area. The credential is kept and the account selected
    /// exactly as `enroll` does.
    @discardableResult
    public func selfEnroll(endpoint: CollaborationServiceEndpoint, displayName: String, deviceLabel: String) async throws -> CollaborationLocalAccount {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CollaborationLocalAccount.validLabel(name), name.utf8.count <= 120,
              CollaborationLocalAccount.validLabel(deviceLabel), deviceLabel.utf8.count <= 120 else { throw CollaborationAccountFailure.invalidInput }
        let ticket = try begin(selecting: true)
        defer { finish(ticket) }
        do {
            let credential = try await transportFactory(endpoint, nil).selfEnroll(.init(displayName: name, deviceLabel: deviceLabel))
            return try await adoptNewCredential(credential, endpoint: endpoint, label: name, ticket: ticket)
        } catch {
            if operation == ticket, status != .ready { active = nil; status = .unavailable; lastError = error; changed() }
            throw error
        }
    }

    /// The relay has committed a new person and device: keep the credential
    /// before anything else can fail, verify it, remember the account and make
    /// it active. Shared by self-enrollment and joining through a link.
    private func adoptNewCredential(_ credential: Collaboration.Credential, endpoint: CollaborationServiceEndpoint,
                                    label: String, ticket: UUID) async throws -> CollaborationLocalAccount {
        let account = CollaborationLocalAccount(endpoint: endpoint, identity: credential.identity, label: label)
        do { try credentials.save(credential, for: .init(endpoint: endpoint, identity: credential.identity)) }
        catch { lastError = error; throw CollaborationAccountFailure.credentialPersistenceFailed }
        if !pendingAccounts.contains(where: { $0.id == account.id }) { pendingAccounts.append(account) }
        try current(ticket)
        let authenticated = try transportFactory(endpoint, credential)
        let identity: Collaboration.Identity
        do { identity = try await authenticated.identity() }
        catch { throw CollaborationAccountFailure.credentialRetainedVerificationFailure }
        try current(ticket)
        guard identity == credential.identity else { throw CollaborationAccountFailure.identityMismatch }
        do { try remember(account, selected: true) }
        catch { lastError = error; throw CollaborationAccountFailure.credentialRetainedMetadataFailure }
        pendingAccounts.removeAll { $0.id == account.id }
        active = .init(account: account, transport: authenticated); status = .ready; lastError = nil; changed()
        return account
    }

    /// Any collaboration entry on this Mac: reuse a remembered account, or, on
    /// a Mac with none that can connect, sign up at `defaultEndpoint` with the
    /// name `askName` returns (nil means the person dismissed it). Returns
    /// false only when they dismissed it.
    public func ensureAccount(defaultEndpoint: CollaborationServiceEndpoint, deviceLabel: String,
                              askName: @MainActor (String) async -> String?) async throws -> Bool {
        if status == .ready { return true }
        let remembered = selectedAccountID ?? accounts.first(where: { $0.endpoint == defaultEndpoint.canonicalString })?.id
            ?? (accounts.count == 1 ? accounts.first?.id : nil)
        if let remembered, (try? await select(accountID: remembered)) != nil, status == .ready { return true }
        guard let name = await askName(defaultEndpoint.shareLinkRelay) else { return false }
        try await selfEnroll(endpoint: defaultEndpoint, displayName: name, deviceLabel: deviceLabel)
        return status == .ready
    }

    public func shareLinks(area: UUID) async throws -> [Collaboration.ShareLinkAccess] {
        try await withAccount { active, ticket in
            let links = try await active.transport.shareLinks(area: area)
            try self.current(ticket)
            return links
        }
    }
    public func revokeShareLink(area: UUID, link: UUID) async throws {
        try await withAccount { active, ticket in
            try await active.transport.revokeShareLink(area: area, link: link)
            try self.current(ticket)
        }
    }
    public func removeShareLinkPerson(area: UUID, link: UUID, person: SharedArea.ID<SharedArea.Person>) async throws {
        try await withAccount { active, ticket in
            try await active.transport.removeShareLinkPerson(area: area, link: link, person: person.rawValue)
            try self.current(ticket)
        }
    }
    public func registerHost() async throws -> SharedArea.ID<SharedArea.Host> {
        try await withAccount { active, ticket in
            if let id = active.account.hostID { return id }
            let host = try await active.transport.registerHost()
            try self.current(ticket)
            try self.updateRegistry { registry in
                guard let index = registry.accounts.firstIndex(where: { $0.id == active.account.id }) else { throw CollaborationAccountFailure.accountMissing }
                registry.accounts[index].hostID = host.id
            }
            self.refreshActiveMetadata()
            return host.id
        }
    }
    public func makeSharedAreaController(area: UUID) throws -> SharedAreaController {
        guard status == .ready, let account = active?.account else { throw CollaborationAccountFailure.notConnected }
        let endpoint = try account.endpointValue
        let local = try SharedAreaLocalStore(applicationSupportRoot: store.applicationSupportRoot, bundleIdentifier: bundleIdentifier,
            endpoint: endpoint, person: account.identity.person, area: .init(area))
        return try SharedAreaController(localStore: local, credentialStore: credentials,
            credentialScope: .init(endpoint: endpoint, identity: account.identity), bundleIdentifier: bundleIdentifier,
            transportFactory: areaTransportFactory)
    }
    public func makeAgentHandoffController(area: UUID) throws -> SharedAgentHandoffController {
        guard status == .ready, let account = active?.account else { throw CollaborationAccountFailure.notConnected }
        let endpoint = try account.endpointValue
        guard let credential = try credentials.load(for: .init(endpoint: endpoint, identity: account.identity)) else {
            throw CollaborationAccountFailure.credentialsMissing
        }
        let api = try CollaborationAPI(baseURL: endpoint.canonicalURL, credential: credential.token,
            allowsInsecureLoopback: endpoint.canonicalURL.scheme == "http")
        let local = try SharedAreaLocalStore(applicationSupportRoot: store.applicationSupportRoot, bundleIdentifier: bundleIdentifier,
            endpoint: endpoint, person: account.identity.person, area: .init(area))
        return try SharedAgentHandoffController(identity: account.identity,
            transport: SharedAgentHandoffAPI(api: api, area: area), directory: local.layout.areaDirectory)
    }

    private func withAccount<T>(_ action: @MainActor (Active, UUID) async throws -> T) async throws -> T {
        guard status == .ready, let active else { throw CollaborationAccountFailure.notConnected }
        let ticket = try begin(selecting: false)
        defer { finish(ticket) }
        do {
            let identity = try await active.transport.identity()
            try current(ticket)
            guard identity == active.account.identity else { throw CollaborationAccountFailure.identityMismatch }
            let result = try await action(active, ticket)
            try current(ticket)
            lastError = nil; changed()
            return result
        } catch {
            if operation == ticket {
                if (error as? CollaborationAccountFailure) == .identityMismatch || isCredentialFailure(error) { self.active = nil; status = .unavailable }
                lastError = error; changed()
            }
            throw error
        }
    }
    private func begin(selecting: Bool) throws -> UUID {
        guard !isBusy else { throw CollaborationAccountFailure.busy }
        let ticket = UUID(); operation = ticket; isBusy = true
        if selecting { active = nil; status = .connecting }
        lastError = nil; changed(); return ticket
    }
    private func current(_ ticket: UUID) throws {
        guard operation == ticket else { throw CollaborationAccountFailure.superseded }
    }
    private func finish(_ ticket: UUID) {
        guard operation == ticket else { return }
        operation = nil; isBusy = false; changed()
    }
    private func validate(_ state: Collaboration.State, expected: UUID?) throws {
        guard state.scope.area == state.document.id, state.scope.epoch > 0,
              expected == nil || expected == state.document.id.rawValue else { throw CollaborationAccountFailure.invalidState }
    }
    private func remember(_ account: CollaborationLocalAccount, selected: Bool) throws {
        try updateRegistry { registry in
            if let index = registry.accounts.firstIndex(where: { $0.id == account.id }) {
                // Keep any destinations another view remembered for this device.
                registry.accounts[index].label = account.label
            } else { registry.accounts.append(account) }
            if selected { registry.selectedAccountID = account.id }
        }
    }
    private func rememberArea(_ id: UUID, label: String, account: String) throws {
        try updateRegistry { registry in
            guard let index = registry.accounts.firstIndex(where: { $0.id == account }) else { throw CollaborationAccountFailure.accountMissing }
            if let area = registry.accounts[index].knownAreas.firstIndex(where: { $0.id == id }) {
                registry.accounts[index].knownAreas[area].label = label
            } else { registry.accounts[index].knownAreas.append(.init(id: id, label: label)) }
        }
        refreshActiveMetadata()
    }
    private func rememberAdmittedArea(_ id: UUID, label: String, account: String) throws {
        do { try rememberArea(id, label: label, account: account) }
        catch { throw CollaborationAccountFailure.areaRetainedMetadataFailure(id) }
    }
    private func refreshActiveMetadata() {
        guard var active, let current = registry.accounts.first(where: { $0.id == active.account.id }) else { return }
        active.account = current; self.active = active
    }
    private func updateRegistry(_ edit: (inout CollaborationAccountRegistry) throws -> Void) throws {
        for attempt in 0..<3 {
            var current = try store.load()
            try edit(&current)
            do { registry = try store.save(current); return }
            catch CollaborationAccountStoreError.staleGeneration where attempt < 2 { continue }
        }
        throw CollaborationAccountStoreError.staleGeneration
    }
    private func validCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7f }
    }
    private func isCredentialFailure(_ error: any Error) -> Bool {
        if let error = error as? CollaborationClientError, case .server(status: 401, code: _) = error { return true }
        return false
    }
    private func changed() { onChange?() }
}
