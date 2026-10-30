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
    public enum Edit: Codable, Equatable, Sendable {
        case admit(Item, Position)
        case place(Position)
        case remove(ID<Object>)
        case context(Context)
        case post(Post)
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
        public private(set) var contexts: [Context] = []
        public private(set) var posts: [Post] = []
        private var deletedObjects: [ID<Object>] = []
        private var deletedPlacements: [ID<Placement>] = []
        private var receipts: [Receipt] = []
        public init(id: ID<Area> = ID()) { self.id = id }

        private enum CodingKeys: String, CodingKey {
            case schema, id, revision, items, positions, contexts, posts
            case deletedObjects, deletedPlacements, receipts
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
            contexts = try c.decode([Context].self, forKey: .contexts)
            posts = try c.decode([Post].self, forKey: .posts)
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
                  items.allSatisfy({ !deletedObjects.contains($0.id) }),
                  positions.allSatisfy({ !deletedPlacements.contains($0.id) })
            else { throw Failure.duplicateIdentity }
            guard positions.allSatisfy({ $0.rect.valid }) else { throw Failure.invalidGeometry }
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
            for edit in command.edits { try next.reduce(edit) }
            next.revision += 1
            next.receipts.append(Receipt(id: command.id, digest: digest, revision: next.revision))
            self = next
            return .applied(revision)
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
