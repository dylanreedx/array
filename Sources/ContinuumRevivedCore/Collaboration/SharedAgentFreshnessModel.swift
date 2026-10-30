import Foundation
import ContinuumRevivedCollaborationProtocol

/// The shared scene's read model over the per-area freshness ledger. It looks
/// up each agent's current host generation and each artifact's latest revision
/// so stale markers and excerpt labels speak only for what was confirmed. It
/// holds no dispatch path: reading, refreshing and relabelling send nothing.
@MainActor
public final class SharedAgentFreshnessModel {
    public typealias Lookup = @Sendable (SharedArea.ID<SharedArea.Object>) async throws -> UUID?
    public let ledger: SharedAgentFreshnessLedger
    public private(set) var generations: [SharedArea.ID<SharedArea.Object>: UUID] = [:]
    public private(set) var artifactRevisions: [SharedArea.ID<SharedArea.Object>: UUID] = [:]
    public private(set) var refreshedRevision: UInt64?
    public var onChange: (@MainActor () -> Void)?
    private let generation: Lookup
    private let artifactRevision: Lookup
    private var refreshing: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private var lastDocument: SharedArea.Document?

    public init(ledger: SharedAgentFreshnessLedger, generation: @escaping Lookup, artifactRevision: @escaping Lookup) {
        self.ledger = ledger; self.generation = generation; self.artifactRevision = artifactRevision
    }
    /// The ledger the handoff client records receipts into:
    /// `<handoff area directory>/freshness`.
    public static func ledgerDirectory(areaDirectory: URL) -> URL { areaDirectory.appendingPathComponent("freshness", isDirectory: true) }

    public convenience init(handoff: SharedAgentHandoffController) throws {
        let transport = handoff.transport
        let api = transport as? SharedAgentHandoffAPI
        try self.init(ledger: .init(directory: Self.ledgerDirectory(areaDirectory: handoff.areaDirectory)),
            generation: { object in try await transport.control(object: object.rawValue).hostGeneration },
            artifactRevision: { object in
                guard let api else { return nil }
                return try await api.api.artifactState(area: api.area, object: object.rawValue).latest?.manifest.id.rawValue
            })
    }

    /// Notices receipts recorded by another connection, and re-reads host
    /// identities every `identityEvery` polls so a rebind shows without an edit.
    public func startWatchingLedger(every interval: Duration = .seconds(2), identityEvery: Int = 15) {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            var token = (try? self?.ledger.changeToken()) ?? 0, polls = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                polls += 1
                if polls % max(1, identityEvery) == 0, let document = lastDocument { refreshedRevision = nil; refreshIfNeeded(document) }
                let next = (try? ledger.changeToken()) ?? token
                if next != token { token = next; onChange?() }
            }
        }
    }
    public func stopWatchingLedger() { watching?.cancel(); watching = nil }

    /// Re-reads identities once per document revision.
    public func refreshIfNeeded(_ document: SharedArea.Document) {
        lastDocument = document
        guard refreshedRevision != document.revision, refreshing == nil else { return }
        refreshing = Task { [weak self] in
            await self?.refresh(document)
            self?.refreshing = nil
        }
    }
    public func refresh(_ document: SharedArea.Document) async {
        var nextGenerations: [SharedArea.ID<SharedArea.Object>: UUID] = [:]
        var nextArtifacts: [SharedArea.ID<SharedArea.Object>: UUID] = [:]
        for item in document.items {
            switch item.kind {
            case .agentObservation: nextGenerations[item.id] = try? await generation(item.id)
            case .artifact: nextArtifacts[item.id] = try? await artifactRevision(item.id)
            case .discussion, .agreement: break
            }
        }
        generations = nextGenerations; artifactRevisions = nextArtifacts; refreshedRevision = document.revision
        onChange?()
    }

    public func incarnation(of object: SharedArea.ID<SharedArea.Object>) -> Collaboration.AgentIncarnation? {
        generations[object].map { .init(object: object, hostGeneration: $0) }
    }
    /// One entry per agreement in the area, for the agent's confirmed
    /// incarnation only. Nil when the host has not confirmed one.
    public func freshness(agent: SharedArea.ID<SharedArea.Object>, in document: SharedArea.Document)
        -> [(agreement: SharedArea.ID<SharedArea.Object>, freshness: SharedAgentContextFreshness)]? {
        guard let incarnation = incarnation(of: agent) else { return nil }
        return document.items.filter { $0.kind == .agreement }.compactMap { item in
            (try? ledger.freshness(of: incarnation, agreement: item.id, in: document)).map { (item.id, $0) }
        }
    }
    public func availability(of excerpt: Collaboration.ResultExcerpt, in document: SharedArea.Document) -> Collaboration.ResultExcerpt.Availability {
        excerpt.availability(in: document, currentGeneration: generations[excerpt.source.incarnation.object],
                             currentArtifactRevision: { self.artifactRevisions[$0] })
    }
}
