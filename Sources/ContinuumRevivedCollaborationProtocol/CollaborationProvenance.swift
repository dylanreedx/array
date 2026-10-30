import Foundation
import Crypto

extension Collaboration {
    /// One host-side runner incarnation of a published agent. A replaced local
    /// binding mints a new `hostGeneration`, so it never inherits a receipt.
    public struct AgentIncarnation: Codable, Hashable, Sendable {
        public let object: SharedArea.ID<SharedArea.Object>
        public let hostGeneration: UUID
        public init(object: SharedArea.ID<SharedArea.Object>, hostGeneration: UUID) {
            self.object = object; self.hostGeneration = hostGeneration
        }
    }

    /// An immutable artifact revision a result refers to: the pinned
    /// `Artifact.Manifest.id.rawValue` and its `contentDigest` (COL-16).
    public struct ArtifactRevisionRef: Codable, Equatable, Sendable {
        public let object: SharedArea.ID<SharedArea.Object>
        public let revision: UUID
        public let contentDigest: String
        public init(object: SharedArea.ID<SharedArea.Object>, revision: UUID, contentDigest: String) {
            self.object = object; self.revision = revision; self.contentDigest = contentDigest
        }
    }

    /// A frozen, bounded quote of an agent result. It names exactly where it
    /// came from and never carries the surrounding transcript.
    public struct ResultExcerpt: Codable, Equatable, Sendable {
        public struct Source: Codable, Equatable, Sendable {
            public let incarnation: AgentIncarnation
            public let host: SharedArea.ID<SharedArea.Host>
            /// Opaque turn identity from the live projection (`AgentProjection.Row.turn`).
            public let turn: String
            /// The quoted row's projection generation and sequence, if quoted
            /// from the live tail (`AgentProjection.Snapshot.position(of:)`).
            public let position: AgentProjection.Position?
            /// The dispatch this result answers, when the host associated one.
            public let command: UUID?
            public let artifact: ArtifactRevisionRef?
            public init(incarnation: AgentIncarnation, host: SharedArea.ID<SharedArea.Host>, turn: String,
                        position: AgentProjection.Position? = nil, command: UUID? = nil, artifact: ArtifactRevisionRef? = nil) {
                self.incarnation = incarnation; self.host = host; self.turn = turn; self.position = position
                self.command = command; self.artifact = artifact
            }
        }
        public static let maximumTextBytes = 8 * 1024
        public let id: UUID
        public let area: SharedArea.ID<SharedArea.Area>
        public let capturedBy: SharedArea.ID<SharedArea.Person>
        public let source: Source
        public let text: String
        public let textDigest: String
        public init(id: UUID = UUID(), area: SharedArea.ID<SharedArea.Area>, capturedBy: SharedArea.ID<SharedArea.Person>,
                    source: Source, text: String) {
            self.id = id; self.area = area; self.capturedBy = capturedBy; self.source = source; self.text = text
            textDigest = Self.digest(text)
        }
        public var isWellFormed: Bool {
            !text.isEmpty && text.utf8.count <= Self.maximumTextBytes && textDigest == Self.digest(text) && !source.turn.isEmpty
        }
        public static func digest(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// What can honestly be said about the original right now. The frozen
        /// text stays readable whatever this returns. `nil` lookups mean "not
        /// checked", never "gone".
        public enum Availability: Equatable, Sendable {
            case linked
            /// The published agent left the area.
            case sourceRemoved
            /// The agent's host binding was replaced; this turn belongs to an
            /// earlier incarnation and cannot be opened through the current one.
            case sourceReplaced
            /// The agent's current incarnation could not be confirmed.
            case sourceUnchecked
            /// The artifact's latest revision is not the one quoted.
            case artifactChanged(current: UUID)
            /// The quoted artifact is no longer published.
            case artifactRemoved
            /// The artifact's latest revision could not be confirmed.
            case artifactUnchecked
        }
        public func availability(in document: SharedArea.Document, currentGeneration: UUID?,
                                 /// The artifact's live `State.latest.manifest.id.rawValue`.
                                 currentArtifactRevision: (SharedArea.ID<SharedArea.Object>) -> UUID?) -> Availability {
            guard document.items.contains(where: { $0.id == source.incarnation.object }) else { return .sourceRemoved }
            guard let currentGeneration else { return .sourceUnchecked }
            guard currentGeneration == source.incarnation.hostGeneration else { return .sourceReplaced }
            if let artifact = source.artifact {
                guard document.items.contains(where: { $0.id == artifact.object }) else { return .artifactRemoved }
                guard let current = currentArtifactRevision(artifact.object) else { return .artifactUnchecked }
                if current != artifact.revision { return .artifactChanged(current: current) }
            }
            return .linked
        }
    }
}
