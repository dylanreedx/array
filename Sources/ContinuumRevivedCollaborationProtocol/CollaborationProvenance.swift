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

    /// An immutable artifact revision a result refers to. `revision` is opaque
    /// to this layer; artifact publication owns its meaning and digest.
    public struct ArtifactRevisionRef: Codable, Equatable, Sendable {
        public let object: SharedArea.ID<SharedArea.Object>
        public let revision: String
        public let digest: String
        public init(object: SharedArea.ID<SharedArea.Object>, revision: String, digest: String) {
            self.object = object; self.revision = revision; self.digest = digest
        }
    }

    /// A frozen, bounded quote of an agent result. It names exactly where it
    /// came from and never carries the surrounding transcript.
    public struct ResultExcerpt: Codable, Equatable, Sendable {
        public struct Source: Codable, Equatable, Sendable {
            public let incarnation: AgentIncarnation
            public let host: SharedArea.ID<SharedArea.Host>
            /// Stable turn identity from the live projection.
            public let turn: String
            /// Monotonic projection sequence of the quoted event, if known.
            public let sequence: UInt64?
            /// The dispatch this result answers, when the host associated one.
            public let command: UUID?
            public let artifact: ArtifactRevisionRef?
            public init(incarnation: AgentIncarnation, host: SharedArea.ID<SharedArea.Host>, turn: String, sequence: UInt64? = nil,
                        command: UUID? = nil, artifact: ArtifactRevisionRef? = nil) {
                self.incarnation = incarnation; self.host = host; self.turn = turn; self.sequence = sequence
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
        /// text stays readable whatever this returns.
        public enum Availability: Equatable, Sendable {
            case linked
            /// The published agent left the area.
            case sourceRemoved
            /// The agent's host binding was replaced; this turn belongs to an
            /// earlier incarnation and cannot be opened through the current one.
            case sourceReplaced
            /// The quoted artifact has a newer revision than the one quoted.
            case artifactChanged(current: String)
            /// The quoted artifact is no longer published.
            case artifactRemoved
        }
        public func availability(in document: SharedArea.Document, currentGeneration: UUID?,
                                 currentArtifactRevision: (SharedArea.ID<SharedArea.Object>) -> String?) -> Availability {
            guard document.items.contains(where: { $0.id == source.incarnation.object }) else { return .sourceRemoved }
            guard currentGeneration == source.incarnation.hostGeneration else { return .sourceReplaced }
            if let artifact = source.artifact {
                guard document.items.contains(where: { $0.id == artifact.object }),
                      let current = currentArtifactRevision(artifact.object) else { return .artifactRemoved }
                if current != artifact.revision { return .artifactChanged(current: current) }
            }
            return .linked
        }
    }
}
