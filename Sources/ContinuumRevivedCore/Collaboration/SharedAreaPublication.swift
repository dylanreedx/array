import CryptoKit
import Foundation
import ContinuumRevivedCollaborationProtocol

/// Host-side review preparation, never a publication grant. Inventory must come
/// from the owning document/controllers in WORLD coordinates. A complete scope
/// cannot be assembled from just the currently hydrated canvas views.
public enum SharedAreaPublication {
    public struct SourceKey: Hashable, Sendable {
        public let projectID: UUID
        public let tileID: UUID
        public init(projectID: UUID, tileID: UUID) { self.projectID = projectID; self.tileID = tileID }
    }
    /// Private input only; deliberately not Encodable as a public projection.
    public struct SourceTile: Sendable {
        public let projectID: UUID
        public let tile: Tile
        /// Already resolved through the real local owner; this helper never
        /// mints an agent or attempts to resolve an arbitrary runtime reference.
        public let agentID: AgentID?
        /// A caller-captured content generation/digest, not a filesystem path.
        /// Required and freshly re-read from the owner for note content. This
        /// helper cannot establish freshness if a caller supplies stale values.
        public let contentRevision: String?
        public var key: SourceKey { .init(projectID: projectID, tileID: tile.id) }
        public init(projectID: UUID, tile: Tile, agentID: AgentID? = nil, contentRevision: String? = nil) {
            self.projectID = projectID; self.tile = tile; self.agentID = agentID; self.contentRevision = contentRevision
        }
    }
    public enum Coverage: Equatable, Sendable {
        case completeWorkspace
        case zones(Set<UUID>)
        case partial
    }
    public struct Inventory: Sendable {
        public let workspaceID: UUID
        public let coverage: Coverage
        public let sources: [SourceTile]
        public init(workspaceID: UUID, coverage: Coverage, sources: [SourceTile]) {
            self.workspaceID = workspaceID; self.coverage = coverage; self.sources = sources
        }
    }
    public enum Selection: Equatable, Sendable {
        case workspace
        case zone(UUID)
        case tiles(Set<SourceKey>)
        /// Fully enclosed model frames only; intersecting frames are excluded.
        case enclosed(SharedArea.Rect)
    }
    public enum Content: Codable, Equatable, Sendable {
        /// Opaque observation source only. No transcript history is included.
        case agentObservation
        /// Explicit captured text; never an implicit live note subscription.
        case agreement(text: String)
        case discussion(text: String)
        /// A diff/file snapshot captured off main by the owner host. `digest`
        /// is `SharedArtifactProducer.Draft.contentDigest`; confirmation
        /// re-captures, so changed bytes refuse instead of publishing.
        case artifact(digest: String)
        /// A note, file, diff, browser or terminal shared live through its
        /// own lane (`Collaboration.LiveTile`); its owner's host publishes
        /// what it shows. A terminal reaches here only after its own warning.
        case liveTile
        case omit
    }
    public struct Choice: Equatable, Sendable {
        public let source: SourceKey
        public let content: Content
        public init(source: SourceKey, content: Content) { self.source = source; self.content = content }
    }
    public enum Unsupported: String, Sendable {
        case tileKind, requiresManagedAgent, unavailableAgent, requiresNote, unavailableContentRevision, requiresDiffOrFile, unavailableArtifact
        case requiresLiveKind
    }
    public enum Disposition: Equatable, Sendable {
        case ready(SharedArea.Kind)
        case needsReview
        case unsupported(Unsupported)
        case omitted
    }
    public struct Row: Sendable {
        public let source: SourceKey
        public let localTitle: String
        public let tileKind: TileKind
        public let disposition: Disposition
        public let previewText: String?
        /// UI must truthfully label an agent source as excluding history.
        public var includesAgentHistory: Bool { false }
    }
    /// The only Codable publication projection. No Tile, source path, local
    /// project/agent/tile ID, metadata, camera or source title is represented.
    public struct Manifest: Codable, Equatable, Sendable {
        public let area: SharedArea.ID<SharedArea.Area>
        public let author: SharedArea.ID<SharedArea.Person>
        public let host: SharedArea.ID<SharedArea.Host>
        public let expectedRevision: UInt64
        public let edits: [SharedArea.Edit]
    }
    public struct Review: Sendable {
        public let rows: [Row]
        public let manifest: Manifest
        /// This detects drift; it is not a secret, permission, or service grant.
        public let digest: String
        public var readyToConfirm: Bool {
            !manifest.edits.isEmpty && !rows.contains { $0.disposition == .needsReview }
        }
        fileprivate let configuration: Configuration
        fileprivate let allocations: [SourceKey: Allocation]
        fileprivate init(rows: [Row], manifest: Manifest, digest: String,
                         configuration: Configuration, allocations: [SourceKey: Allocation]) {
            self.rows = rows; self.manifest = manifest; self.digest = digest
            self.configuration = configuration; self.allocations = allocations
        }
    }
    /// Constructible only by an exact fresh review comparison. This local
    /// witness cannot bypass service auth/membership or host action admission.
    public struct Confirmed: Sendable {
        public let command: SharedArea.Command
        public let sourceBindings: [SharedAreaLocalSourceBinding]
        public let reviewDigest: String
        public let author: SharedArea.ID<SharedArea.Person>
        public let host: SharedArea.ID<SharedArea.Host>
        /// Each admitted artifact and the revision ID its first capture takes.
        /// The bytes stay with the caller that captured them.
        public let artifacts: [ArtifactPublication]
        fileprivate init(command: SharedArea.Command, sourceBindings: [SharedAreaLocalSourceBinding], reviewDigest: String,
                         author: SharedArea.ID<SharedArea.Person>, host: SharedArea.ID<SharedArea.Host>, artifacts: [ArtifactPublication]) {
            self.command = command; self.sourceBindings = sourceBindings; self.reviewDigest = reviewDigest
            self.author = author; self.host = host; self.artifacts = artifacts
        }
    }
    public struct ArtifactPublication: Equatable, Sendable {
        public let source: SourceKey
        public let object: SharedArea.ID<SharedArea.Object>
        public let revision: SharedArea.ID<Collaboration.Artifact.RevisionTag>
        public let contentDigest: String
    }
    public enum Failure: Error, Equatable {
        case incompleteCoverage, duplicateSource, missingSource, invalidSelection
        case duplicateChoice, choiceOutsideSelection, invalidContent, publicationTooLarge
        case reviewChanged, reviewIncomplete, nothingToPublish
    }
    fileprivate struct Configuration: Sendable {
        let workspaceID: UUID
        let selection: Selection
        let area: SharedArea.ID<SharedArea.Area>
        let author: SharedArea.ID<SharedArea.Person>
        let host: SharedArea.ID<SharedArea.Host>
        let expectedRevision: UInt64
        let operation: SharedArea.ID<SharedArea.Operation>
    }
    fileprivate struct Allocation: Sendable {
        let object = SharedArea.ID<SharedArea.Object>()
        let placement = SharedArea.ID<SharedArea.Placement>()
        let binding = SharedArea.ID<SharedArea.Binding>()
        let context = SharedArea.ID<SharedArea.Revision>()
        let post = SharedArea.ID<SharedArea.Message>()
        let revision = SharedArea.ID<Collaboration.Artifact.RevisionTag>()
    }
    private struct PrivateFingerprint: Encodable {
        let key: String
        let tile: Tile
        let agentID: AgentID?
        let contentRevision: String?
        let choice: Content?
    }
    private struct DigestInput: Encodable {
        let workspaceID: UUID
        let selection: String
        let privateSources: [PrivateFingerprint]
        let manifest: Manifest
    }

    public static func prepare(inventory: Inventory, selection: Selection, choices: [Choice],
                               area: SharedArea.ID<SharedArea.Area>, author: SharedArea.ID<SharedArea.Person>,
                               host: SharedArea.ID<SharedArea.Host>, expectedRevision: UInt64) throws -> Review {
        let configuration = Configuration(workspaceID: inventory.workspaceID, selection: selection,
            area: area, author: author, host: host, expectedRevision: expectedRevision, operation: .init())
        return try build(inventory: inventory, choices: choices, configuration: configuration, allocations: [:]).review
    }

    /// Call only after an explicit UI confirmation of this digest. Fresh model
    /// inventory AND fresh captured content choices are required. A changed note,
    /// title, frame, selected member, source binding or content generation refuses
    /// instead of silently approving new bytes. Callers must re-read inventory
    /// and content through the owning controllers; this helper cannot prove that
    /// caller-supplied snapshots are fresh. Nothing is sent by this method.
    public static func confirm(_ review: Review, expectedDigest: String, inventory: Inventory, choices: [Choice]) throws -> Confirmed {
        guard expectedDigest == review.digest else { throw Failure.reviewChanged }
        guard review.readyToConfirm else {
            throw review.manifest.edits.isEmpty ? Failure.nothingToPublish : Failure.reviewIncomplete
        }
        let fresh = try build(inventory: inventory, choices: choices,
            configuration: review.configuration, allocations: review.allocations)
        guard fresh.review.digest == review.digest else { throw Failure.reviewChanged }
        let artifacts: [ArtifactPublication] = choices.compactMap { choice in
            guard case .artifact(let digest) = choice.content, let allocation = review.allocations[choice.source],
                  review.manifest.edits.contains(where: { if case .admit(let item, _) = $0 { return item.id == allocation.object }; return false })
            else { return nil }
            return .init(source: choice.source, object: allocation.object, revision: allocation.revision, contentDigest: digest)
        }
        return Confirmed(command: .init(area: review.manifest.area, id: review.configuration.operation,
            expectedRevision: review.manifest.expectedRevision, edits: review.manifest.edits),
            sourceBindings: fresh.bindings, reviewDigest: review.digest,
            author: review.manifest.author, host: review.manifest.host, artifacts: artifacts)
    }

    private static func build(inventory: Inventory, choices: [Choice], configuration: Configuration,
                              allocations existing: [SourceKey: Allocation]) throws -> (review: Review, bindings: [SharedAreaLocalSourceBinding]) {
        guard inventory.workspaceID == configuration.workspaceID else { throw Failure.reviewChanged }
        guard Set(inventory.sources.map(\.key)).count == inventory.sources.count else { throw Failure.duplicateSource }
        let selected = try select(inventory, configuration.selection).sorted { lhs, rhs in
            if lhs.projectID != rhs.projectID { return lhs.projectID.uuidString < rhs.projectID.uuidString }
            return lhs.tile.id.uuidString < rhs.tile.id.uuidString
        }
        guard !selected.isEmpty else { throw Failure.invalidSelection }
        guard Set(choices.map(\.source)).count == choices.count else { throw Failure.duplicateChoice }
        let selectedKeys = Set(selected.map(\.key))
        guard choices.allSatisfy({ selectedKeys.contains($0.source) }) else { throw Failure.choiceOutsideSelection }
        let choiceBySource = Dictionary(uniqueKeysWithValues: choices.map { ($0.source, $0.content) })
        var allocations = existing
        var rows: [Row] = [], entries: [SharedAreaCapture.Entry] = [], contentEdits: [SharedArea.Edit] = []
        var bindings: [SharedAreaLocalSourceBinding] = []
        for source in selected {
            let tile = source.tile
            guard SharedArea.Rect(x: tile.frame.x, y: tile.frame.y, width: tile.frame.width, height: tile.frame.height).valid else {
                throw SharedArea.Failure.invalidGeometry
            }
            let content = choiceBySource[source.key]
            let disposition = disposition(for: source, content: content)
            let preview: String?
            switch content {
            case .agreement(let text), .discussion(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65_536 else { throw Failure.invalidContent }
                preview = text
            default: preview = nil
            }
            rows.append(Row(source: source.key, localTitle: tile.title, tileKind: tile.kind, disposition: disposition, previewText: preview))
            guard case .ready(let kind) = disposition else { continue }
            let allocation = allocations[source.key] ?? Allocation(); allocations[source.key] = allocation
            let publishedSource: SharedArea.Source? = kind == .agentObservation || kind == .artifact || kind == .liveTile
                ? .init(owner: configuration.author, host: configuration.host, binding: allocation.binding) : nil
            let item = SharedArea.Item(id: allocation.object, kind: kind, source: publishedSource)
            entries.append(.init(tile: tile, publication: item, placement: allocation.placement))
            switch content {
            case .agreement(let text):
                contentEdits.append(.context(.init(id: allocation.context, object: item.id, parent: nil, author: configuration.author, text: text)))
            case .discussion(let text):
                contentEdits.append(.post(.init(id: allocation.post, object: item.id, author: configuration.author, text: text)))
            case .agentObservation, .artifact, .liveTile:
                bindings.append(.init(object: item.id, binding: allocation.binding, host: configuration.host,
                    projectID: source.projectID, tileID: tile.id, agentID: source.agentID))
            default: break
            }
        }
        // Omitted/unsupported source geometry remains private. It must not
        // shift admitted objects or disclose a hidden member through offsets.
        let originX = entries.map(\.tile.frame.x).min() ?? 0
        let originY = entries.map(\.tile.frame.y).min() ?? 0
        let edits = try SharedAreaCapture.edits(entries: entries, originX: originX, originY: originY) + contentEdits
        let manifest = Manifest(area: configuration.area, author: configuration.author, host: configuration.host,
            expectedRevision: configuration.expectedRevision, edits: edits)
        let wireData = try encode(manifest)
        // Leave headroom for mutation/auth envelope under the route's 256 KiB cap.
        guard wireData.count <= 192 * 1024 else { throw Failure.publicationTooLarge }
        let fingerprint = DigestInput(workspaceID: inventory.workspaceID, selection: selectionKey(configuration.selection),
            privateSources: selected.map { .init(key: "\($0.projectID.uuidString)/\($0.tile.id.uuidString)", tile: $0.tile, agentID: $0.agentID,
                contentRevision: $0.contentRevision, choice: choiceBySource[$0.key]) }, manifest: manifest)
        let digest = SHA256.hash(data: try encode(fingerprint)).map { String(format: "%02x", $0) }.joined()
        return (Review(rows: rows, manifest: manifest, digest: digest, configuration: configuration, allocations: allocations), bindings)
    }

    private static func disposition(for source: SourceTile, content: Content?) -> Disposition {
        guard let content else {
            switch source.tile.kind {
            case .managedAgent, .note, .diffReview, .file: return .needsReview
            default: return .unsupported(.tileKind)
            }
        }
        switch content {
        case .omit: return .omitted
        case .liveTile:
            guard liveKind(for: source.tile.kind) != nil else { return .unsupported(.requiresLiveKind) }
            return .ready(.liveTile)
        case .artifact(let digest):
            guard source.tile.kind == .diffReview || source.tile.kind == .file else { return .unsupported(.requiresDiffOrFile) }
            guard Collaboration.Artifact.isDigest(digest) else { return .unsupported(.unavailableArtifact) }
            return .ready(.artifact)
        case .agentObservation:
            guard source.tile.kind == .managedAgent else { return .unsupported(.requiresManagedAgent) }
            guard source.agentID != nil else { return .unsupported(.unavailableAgent) }
            return .ready(.agentObservation)
        case .agreement:
            guard source.tile.kind == .note else { return .unsupported(.requiresNote) }
            guard validContentRevision(source.contentRevision) else { return .unsupported(.unavailableContentRevision) }
            return .ready(.agreement)
        case .discussion:
            guard source.tile.kind == .note else { return .unsupported(.requiresNote) }
            guard validContentRevision(source.contentRevision) else { return .unsupported(.unavailableContentRevision) }
            return .ready(.discussion)
        }
    }
    /// Which tile kinds share live, and as what. Everything else is listed in
    /// the Share popover as not shareable yet, with its reason.
    public static func liveKind(for kind: TileKind) -> Collaboration.LiveTile.Kind? {
        switch kind {
        case .note: .note
        case .file: .file
        case .diffReview: .diff
        case .browser: .browser
        case .terminal: .terminal
        default: nil
        }
    }
    private static func validContentRevision(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4096
    }
    private static func select(_ inventory: Inventory, _ selection: Selection) throws -> [SourceTile] {
        switch selection {
        case .workspace:
            guard inventory.coverage == .completeWorkspace else { throw Failure.incompleteCoverage }
            return inventory.sources
        case .zone(let id):
            switch inventory.coverage {
            case .completeWorkspace: break
            case .zones(let zones) where zones.contains(id): break
            default: throw Failure.incompleteCoverage
            }
            return inventory.sources.filter { $0.tile.zoneId == id }
        case .tiles(let keys):
            guard !keys.isEmpty else { throw Failure.invalidSelection }
            let sources = inventory.sources.filter { keys.contains($0.key) }
            guard sources.count == keys.count else { throw Failure.missingSource }
            return sources
        case .enclosed(let rect):
            guard rect.valid else { throw Failure.invalidSelection }
            guard inventory.coverage == .completeWorkspace else { throw Failure.incompleteCoverage }
            guard inventory.sources.allSatisfy({ source in
                let f = source.tile.frame
                return SharedArea.Rect(x: f.x, y: f.y, width: f.width, height: f.height).valid
            }) else { throw SharedArea.Failure.invalidGeometry }
            return inventory.sources.filter { source in
                let f = source.tile.frame
                return f.x >= rect.x && f.y >= rect.y && f.x + f.width <= rect.x + rect.width && f.y + f.height <= rect.y + rect.height
            }
        }
    }
    private static func selectionKey(_ selection: Selection) -> String {
        switch selection {
        case .workspace: return "workspace"
        case .zone(let id): return "zone:\(id.uuidString)"
        case .tiles(let ids): return "tiles:" + ids.map { "\($0.projectID.uuidString)/\($0.tileID.uuidString)" }.sorted().joined(separator: ",")
        case .enclosed(let rect): return "enclosed:\(rect.x),\(rect.y),\(rect.width),\(rect.height)"
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
