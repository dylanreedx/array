import Foundation
import Crypto

/// Portable shared state only. Authenticated service routes must authorize a
/// command before applying it; this reducer does not establish caller identity.
public enum SharedArea {
    public struct ID<Kind>: Codable, Hashable, Sendable {
        public let rawValue: UUID
        public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    }
    public enum Area: Sendable {}
    public enum Person: Sendable {}
    public enum Host: Sendable {}
    public enum Object: Sendable {}
    public enum Placement: Sendable {}
    public enum Binding: Sendable {}
    public enum Operation: Sendable {}
    public enum Revision: Sendable {}
    public enum Message: Sendable {}
    public enum Kind: String, Codable, Sendable { case agentObservation, artifact, discussion, agreement }
    public struct Rect: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var valid: Bool {
            [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite)
                && width > 0 && height > 0
        }
        public func relative(toX x: Double, y: Double) -> Rect {
            Rect(x: self.x - x, y: self.y - y, width: width, height: height)
        }
    }
    public struct Source: Codable, Equatable, Sendable {
        public let owner: ID<Person>
        public let host: ID<Host>
        public let binding: ID<Binding>
        public init(owner: ID<Person>, host: ID<Host>, binding: ID<Binding>) {
            self.owner = owner; self.host = host; self.binding = binding
        }
    }
    public struct Item: Codable, Equatable, Sendable {
        public let id: ID<Object>
        public let kind: Kind
        public let source: Source?
        public init(id: ID<Object>, kind: Kind, source: Source? = nil) {
            self.id = id; self.kind = kind; self.source = source
        }
    }
    public struct Position: Codable, Equatable, Sendable {
        public let id: ID<Placement>
        public let object: ID<Object>
        public var rect: Rect
        public var z: Int
        public init(id: ID<Placement>, object: ID<Object>, rect: Rect, z: Int = 0) {
            self.id = id; self.object = object; self.rect = rect; self.z = z
        }
    }
    /// Reducer-owned causal identity of a placement write. Equal frames do not
    /// imply equal intent: a teammate can move away and back before Undo.
    public struct PlacementWrite: Codable, Equatable, Sendable {
        public let placement: ID<Placement>
        public let operation: ID<Operation>
        public let revision: UInt64
        public init(placement: ID<Placement>, operation: ID<Operation>, revision: UInt64) {
            self.placement = placement; self.operation = operation; self.revision = revision
        }
    }
    public struct Context: Codable, Equatable, Sendable {
        public let id: ID<Revision>
        public let object: ID<Object>
        public let parent: ID<Revision>?
        public let author: ID<Person>
        public let text: String
        public init(id: ID<Revision>, object: ID<Object>, parent: ID<Revision>?, author: ID<Person>, text: String) {
            self.id = id; self.object = object; self.parent = parent; self.author = author; self.text = text
        }
    }
    public struct Post: Codable, Equatable, Sendable {
        public let id: ID<Message>
        public let object: ID<Object>
        public let author: ID<Person>
        public let text: String
        public let context: ID<Revision>?
        public init(id: ID<Message>, object: ID<Object>, author: ID<Person>, text: String, context: ID<Revision>? = nil) {
            self.id = id; self.object = object; self.author = author; self.text = text; self.context = context
        }
    }
    /// One authenticated person's endorsement of one immutable agreement
    /// revision. A later revision starts with none; nothing carries forward.
    public struct Endorsement: Codable, Equatable, Sendable {
        public let revision: ID<Revision>
        public let person: ID<Person>
        public init(revision: ID<Revision>, person: ID<Person>) { self.revision = revision; self.person = person }
    }
    public enum Edit: Codable, Equatable, Sendable {
        case admit(Item, Position)
        case place(Position)
        case remove(ID<Object>)
        case context(Context)
        case post(Post)
        case endorse(Endorsement)
    }
    public struct Command: Codable, Equatable, Sendable {
        public let schema: Int
        public let area: ID<Area>
        public let id: ID<Operation>
        public let expectedRevision: UInt64
        public let edits: [Edit]
        public init(schema: Int = 1, area: ID<Area>, id: ID<Operation> = ID(), expectedRevision: UInt64, edits: [Edit]) {
            self.schema = schema; self.area = area; self.id = id
            self.expectedRevision = expectedRevision; self.edits = edits
        }
    }
    public enum Failure: Error, Equatable {
        case unsupportedSchema, wrongArea, conflict, changedIntent, invalidGeometry
        case duplicateIdentity, missingObject, invalidReference, emptyCommand, exhaustedRevision
    }
    public enum Outcome: Equatable { case applied(UInt64), duplicate(UInt64) }
    struct Receipt: Codable, Equatable, Sendable {
        let id: ID<Operation>
        let digest: String
        let revision: UInt64
    }
    public struct Document: Codable, Equatable, Sendable {
        public private(set) var schema = 1
        public let id: ID<Area>
        public private(set) var revision: UInt64 = 0
        public private(set) var items: [Item] = []
        public private(set) var positions: [Position] = []
        public private(set) var placementWrites: [PlacementWrite] = []
        public private(set) var contexts: [Context] = []
        public private(set) var posts: [Post] = []
        public private(set) var endorsements: [Endorsement] = []
        private var deletedObjects: [ID<Object>] = []
        private var deletedPlacements: [ID<Placement>] = []
        private var receipts: [Receipt] = []
        public init(id: ID<Area> = ID()) { self.id = id }

        private enum CodingKeys: String, CodingKey {
            case schema, id, revision, items, positions, contexts, posts, endorsements
            case deletedObjects, deletedPlacements, receipts, placementWrites
        }
        /// Additive field: a document with no endorsements keeps its exact
        /// pre-endorsement canonical bytes, and older snapshots still decode.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schema, forKey: .schema); try c.encode(id, forKey: .id)
            try c.encode(revision, forKey: .revision); try c.encode(items, forKey: .items)
            try c.encode(positions, forKey: .positions); try c.encode(placementWrites, forKey: .placementWrites)
            try c.encode(contexts, forKey: .contexts); try c.encode(posts, forKey: .posts)
            if !endorsements.isEmpty { try c.encode(endorsements, forKey: .endorsements) }
            try c.encode(deletedObjects, forKey: .deletedObjects); try c.encode(deletedPlacements, forKey: .deletedPlacements)
            try c.encode(receipts, forKey: .receipts)
        }
        /// Network and disk snapshots take the same strict validation path.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schema = try c.decode(Int.self, forKey: .schema)
            guard schema == 1 else { throw Failure.unsupportedSchema }
            id = try c.decode(ID<Area>.self, forKey: .id)
            revision = try c.decode(UInt64.self, forKey: .revision)
            items = try c.decode([Item].self, forKey: .items)
            positions = try c.decode([Position].self, forKey: .positions)
            // Unreleased v1 snapshots may predate causal geometry metadata.
            // Absence stays unknown; it never fabricates a safe Undo stamp.
            placementWrites = try c.decodeIfPresent([PlacementWrite].self, forKey: .placementWrites) ?? []
            contexts = try c.decode([Context].self, forKey: .contexts)
            posts = try c.decode([Post].self, forKey: .posts)
            endorsements = try c.decodeIfPresent([Endorsement].self, forKey: .endorsements) ?? []
            deletedObjects = try c.decode([ID<Object>].self, forKey: .deletedObjects)
            deletedPlacements = try c.decode([ID<Placement>].self, forKey: .deletedPlacements)
            receipts = try c.decode([Receipt].self, forKey: .receipts)
            guard Set(items.map(\.id)).count == items.count,
                  Set(positions.map(\.id)).count == positions.count,
                  Set(contexts.map(\.id)).count == contexts.count,
                  Set(posts.map(\.id)).count == posts.count,
                  Set(receipts.map(\.id)).count == receipts.count,
                  Set(deletedObjects).count == deletedObjects.count,
                  Set(deletedPlacements).count == deletedPlacements.count,
                  Set(placementWrites.map(\.placement)).count == placementWrites.count,
                  items.allSatisfy({ !deletedObjects.contains($0.id) }),
                  positions.allSatisfy({ !deletedPlacements.contains($0.id) })
            else { throw Failure.duplicateIdentity }
            guard positions.allSatisfy({ $0.rect.valid }) else { throw Failure.invalidGeometry }
            let positionIDs = Set(positions.map(\.id))
            let receiptRevisions = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, $0.revision) })
            guard placementWrites.allSatisfy({ write in
                positionIDs.contains(write.placement) && write.revision > 0
                    && write.revision <= revision && receiptRevisions[write.operation] == write.revision
            }) else { throw Failure.invalidReference }
            guard positions.allSatisfy({ p in items.contains { $0.id == p.object } }),
                  items.allSatisfy({ item in positions.contains { $0.object == item.id } }),
                  UInt64(receipts.count) == revision,
                  receipts.enumerated().allSatisfy({ index, receipt in
                      receipt.revision == UInt64(index) + 1 && receipt.digest.count == 64
                          && receipt.digest.allSatisfy { "0123456789abcdef".contains($0) }
                  }) else { throw Failure.invalidReference }
            var heads: [ID<Object>: ID<Revision>] = [:]
            for context in contexts {
                guard items.contains(where: { $0.id == context.object && $0.kind == .agreement })
                        || deletedObjects.contains(context.object),
                      heads[context.object] == context.parent else { throw Failure.invalidReference }
                heads[context.object] = context.id
            }
            for post in posts {
                guard items.contains(where: { $0.id == post.object && $0.kind == .discussion })
                        || deletedObjects.contains(post.object),
                      post.context == nil || contexts.contains(where: { $0.id == post.context })
                else { throw Failure.invalidReference }
            }
            // Same rules as the reducer: a known revision, once per person.
            var endorsed = Set<String>()
            for endorsement in endorsements {
                guard contexts.contains(where: { $0.id == endorsement.revision }),
                      endorsed.insert(endorsement.revision.rawValue.uuidString + endorsement.person.rawValue.uuidString).inserted
                else { throw Failure.invalidReference }
            }
        }

        /// Copy/validate/commit: even the last edit failing leaves no changes.
        @discardableResult public mutating func apply(_ command: Command) throws -> Outcome {
            guard schema == 1, command.schema == 1 else { throw Failure.unsupportedSchema }
            guard command.area == id else { throw Failure.wrongArea }
            for edit in command.edits {
                switch edit {
                case let .admit(_, position), let .place(position):
                    guard position.rect.valid else { throw Failure.invalidGeometry }
                default: break
                }
            }
            let digest = SHA256.hash(data: try Self.encode(command)).map { String(format: "%02x", $0) }.joined()
            if let old = receipts.first(where: { $0.id == command.id }) {
                guard old.digest == digest else { throw Failure.changedIntent }
                return .duplicate(old.revision)
            }
            guard command.expectedRevision == revision else { throw Failure.conflict }
            guard !command.edits.isEmpty else { throw Failure.emptyCommand }
            guard revision < UInt64.max else { throw Failure.exhaustedRevision }
            var next = self
            for edit in command.edits {
                try next.reduce(edit)
                switch edit {
                case .admit(_, let position), .place(let position):
                    next.placementWrites.removeAll { $0.placement == position.id }
                    next.placementWrites.append(.init(placement: position.id, operation: command.id, revision: revision + 1))
                case .remove:
                    let retained = Set(next.positions.map(\.id))
                    next.placementWrites.removeAll { !retained.contains($0.placement) }
                default: break
                }
            }
            next.revision += 1
            next.receipts.append(Receipt(id: command.id, digest: digest, revision: next.revision))
            self = next
            return .applied(revision)
        }
        /// The agreement's current immutable revision, if it has one.
        public func currentRevision(of agreement: ID<Object>) -> Context? {
            contexts.last { $0.object == agreement }
        }
        /// Endorsements of exactly this revision; never of its parent or child.
        public func endorsements(of revision: ID<Revision>) -> [Endorsement] {
            endorsements.filter { $0.revision == revision }
        }
        public func placementWrite(for placement: ID<Placement>) -> PlacementWrite? {
            placementWrites.first { $0.placement == placement }
        }
        private mutating func reduce(_ edit: Edit) throws {
            switch edit {
            case let .admit(item, position):
                guard !deletedObjects.contains(item.id), !items.contains(where: { $0.id == item.id }) else { throw Failure.duplicateIdentity }
                guard position.object == item.id else { throw Failure.invalidReference }
                items.append(item)
                try setPosition(position)
            case let .place(position): try setPosition(position)
            case let .remove(object):
                guard items.contains(where: { $0.id == object }) else { throw Failure.missingObject }
                deletedObjects.append(object)
                deletedPlacements += positions.filter { $0.object == object }.map(\.id)
                items.removeAll { $0.id == object }
                positions.removeAll { $0.object == object }
                // Immutable history remains addressable for pinned references.
            case let .context(context):
                guard items.contains(where: { $0.id == context.object && $0.kind == .agreement }) else { throw Failure.missingObject }
                guard !contexts.contains(where: { $0.id == context.id }) else { throw Failure.duplicateIdentity }
                guard contexts.last(where: { $0.object == context.object })?.id == context.parent else { throw Failure.conflict }
                contexts.append(context)
            case let .post(post):
                guard items.contains(where: { $0.id == post.object && $0.kind == .discussion }) else { throw Failure.missingObject }
                guard !posts.contains(where: { $0.id == post.id }) else { throw Failure.duplicateIdentity }
                if let context = post.context, !contexts.contains(where: { $0.id == context }) { throw Failure.invalidReference }
                posts.append(post)
            case let .endorse(endorsement):
                guard let context = contexts.first(where: { $0.id == endorsement.revision }) else { throw Failure.invalidReference }
                guard items.contains(where: { $0.id == context.object && $0.kind == .agreement }) else { throw Failure.missingObject }
                // Endorsing text someone has since revised would endorse words
                // the endorser may not have read. Refuse; the client re-reads.
                guard currentRevision(of: context.object)?.id == context.id else { throw Failure.conflict }
                guard !endorsements.contains(endorsement) else { throw Failure.duplicateIdentity }
                endorsements.append(endorsement)
            }
        }
        private mutating func setPosition(_ position: Position) throws {
            guard position.rect.valid else { throw Failure.invalidGeometry }
            guard items.contains(where: { $0.id == position.object }) else { throw Failure.missingObject }
            guard !deletedPlacements.contains(position.id) else { throw Failure.duplicateIdentity }
            if let index = positions.firstIndex(where: { $0.id == position.id }) {
                guard positions[index].object == position.object else { throw Failure.invalidReference }
                positions[index] = position
            } else { positions.append(position) }
        }
        public func canonicalData() throws -> Data {
            guard schema == 1 else { throw Failure.unsupportedSchema }
            return try Self.encode(self)
        }
        private static func encode<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        }
    }
}
