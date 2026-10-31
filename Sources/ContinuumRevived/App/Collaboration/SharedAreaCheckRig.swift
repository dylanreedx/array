import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// A scripted authority for checks that need documents, roles, presence and
/// remote edits together. It runs the real document reducer, and every frame it
/// sends carries the current presence, as the service's update pages do. No
/// Keychain, network, provider or executor is involved.
@MainActor
enum SharedAreaCheckRig {
    struct Failure: Error, CustomStringConvertible { let description: String }

    actor Authority {
        nonisolated let area: SharedArea.ID<SharedArea.Area>
        private(set) var document: SharedArea.Document
        private var roles: [UUID: (identity: Collaboration.Identity, role: Collaboration.Role)] = [:]
        private var connections: [(Collaboration.Identity, Connection)] = []
        private var presence: [UUID: Collaboration.Presence] = [:]
        private(set) var applies = 0
        private(set) var usageReports = 0
        private(set) var presencePublishes = 0
        private(set) var lastInput: [UUID: Collaboration.PresenceInput] = [:]

        init(document: SharedArea.Document, members: [(Collaboration.Identity, Collaboration.Role)]) {
            self.document = document; area = document.id
            for (identity, role) in members { roles[identity.device] = (identity, role) }
        }
        private func scope(_ identity: Collaboration.Identity) throws -> Collaboration.Scope {
            guard let member = roles[identity.device], member.identity == identity else {
                throw CollaborationClientError.server(status: 404, code: "notFound")
            }
            return .init(area: area, epoch: 1, role: member.role)
        }
        func state(_ identity: Collaboration.Identity) throws -> Collaboration.State { .init(scope: try scope(identity), document: document) }
        func connection(_ identity: Collaboration.Identity) throws -> Connection {
            _ = try scope(identity); let value = Connection(); connections.append((identity, value)); return value
        }
        func apply(_ mutation: Collaboration.Mutation, from identity: Collaboration.Identity) async throws -> Collaboration.Receipt {
            let current = try scope(identity)
            guard current.canSubmit(mutation.command), mutation.epoch == current.epoch else {
                throw CollaborationClientError.server(status: 403, code: "forbidden")
            }
            applies += 1
            let outcome: SharedArea.Outcome
            do { outcome = try document.apply(mutation.command) }
            catch SharedArea.Failure.conflict { throw CollaborationClientError.server(status: 409, code: "conflict") }
            try await broadcast()
            switch outcome {
            case .applied(let revision): return .init(revision: revision, duplicate: false)
            case .duplicate(let revision): return .init(revision: revision, duplicate: true)
            }
        }
        /// A teammate's edit made elsewhere: it reaches every subscriber as a frame.
        func remote(_ edits: [SharedArea.Edit]) async throws {
            _ = try document.apply(.init(area: area, expectedRevision: document.revision, edits: edits))
            try await broadcast()
        }
        func publish(_ input: Collaboration.PresenceInput, from identity: Collaboration.Identity, label: String) async throws {
            presencePublishes += 1; lastInput[identity.device] = input
            presence[identity.device] = .init(identity: identity, cursor: input.cursor, viewport: input.viewport,
                expiresAt: Date().addingTimeInterval(30), label: label)
            try await broadcast()
        }
        /// Sets a teammate's presence directly, as the service would relay it.
        func setPresence(_ value: Collaboration.Presence) async throws {
            presence[value.identity.device] = value
            try await broadcast()
        }
        func end(_ identity: Collaboration.Identity) async throws {
            presence.removeValue(forKey: identity.device); try await broadcast()
        }
        func reported() { usageReports += 1 }
        /// Host liveness as the service relays it with every frame.
        private var hosts: [Collaboration.HostLiveness] = []
        /// Members' recorded names, relayed with every frame as the relay does.
        private var memberLabels: [SharedArea.ID<SharedArea.Person>: String] = [:]
        func setMemberLabel(_ person: SharedArea.ID<SharedArea.Person>, _ label: String) async throws {
            memberLabels[person] = label; try await broadcast()
        }
        /// Removes someone from the area: their subscription is told access ended.
        func endAccess(_ identity: Collaboration.Identity) async {
            roles.removeValue(forKey: identity.device)
            for (member, connection) in connections where member == identity { await connection.revoke() }
            connections.removeAll { $0.0 == identity }
        }
        func setHosts(_ value: [Collaboration.HostLiveness]) async throws { hosts = value; try await broadcast() }
        private func broadcast() async throws {
            let everyone = Array(presence.values)
            let members = memberLabels.isEmpty ? nil : memberLabels.map { Collaboration.Member(person: $0.key, label: $0.value) }
            for (identity, connection) in connections {
                let scope = try scope(identity)
                var replica = try CollaborationReplica(state: .init(scope: scope, document: document))
                try replica.receive(.init(scope: scope, after: document.revision, through: document.revision, events: [],
                    nextCursor: document.revision, presenceVersion: UUID(), presence: everyone, serverTime: Date(),
                    hosts: hosts.isEmpty ? nil : hosts, members: members))
                await connection.emit(replica)
            }
        }
    }

    actor Connection: SharedAreaControllerConnection {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
        func stop() async { pair.continuation.finish() }
        func emit(_ replica: CollaborationReplica) { pair.continuation.yield(.connected(replica)) }
        func revoke() { pair.continuation.yield(.unavailable) }
    }

    struct Transport: SharedAreaControllerTransport {
        let identityValue: Collaboration.Identity
        let label: String
        let authority: Authority
        func identity() async throws -> Collaboration.Identity { identityValue }
        func state() async throws -> Collaboration.State { try await authority.state(identityValue) }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { try await authority.connection(identityValue) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { try await authority.apply(mutation, from: identityValue) }
        func beginPresence() async throws -> Collaboration.PresenceSession { .init(id: UUID()) }
        func publishPresence(_ input: Collaboration.PresenceInput) async throws { try await authority.publish(input, from: identityValue, label: label) }
        func endPresence(_ session: UUID) async throws { try await authority.end(identityValue) }
        func reportUsage(_ report: Collaboration.UsageReport) async throws { await authority.reported() }
    }

    final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock(); var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }

    static func controller(root: URL, identity: Collaboration.Identity, label: String, authority: Authority,
                           seed: (SharedArea.Document, Collaboration.Role)? = nil) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://rig.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-rig-device"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint,
            person: identity.person, area: authority.area)
        // A seeded cache paints its document before any connection, as a
        // reopened shared window does.
        if let (document, _) = seed { try cache.save(.init(scope: cache.scope, document: document, observedMembershipEpoch: 1)) }
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in Transport(identityValue: identity, label: label, authority: authority) })
    }

    /// A disposable directory under the isolated app support root.
    static func root(_ name: String) throws -> URL {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "\(name) requires isolated app support")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func eventually(_ label: String, attempts: Int = 400, _ value: @MainActor () async -> Bool) async throws {
        for _ in 0..<attempts {
            if await value() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(description: "Timed out: \(label)")
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

/// A fixture host that removes its disposable directory when released.
final class OwnedRootHost: NSView {
    let ownedRoot: URL
    init(root: URL, size: NSSize) { ownedRoot = root; super.init(frame: .init(origin: .zero, size: size)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { try? FileManager.default.removeItem(at: ownedRoot) }
}
