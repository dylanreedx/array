import Foundation
import ContinuumRevivedCollaborationProtocol

/// Human geometry history stores inverse intent, never a document snapshot.
/// Every compensation checks the exact placement write it intends to replace.
public struct SharedAreaGeometryHistory: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case move, resize, undo, redo }
    public enum Failure: Error, Equatable {
        case emptySelection, missingPlacement, invalidGeometry, unchanged
        case unavailable, changedByCollaborator, staleHistory, invalidReceipt
    }
    public struct Change: Codable, Sendable {
        public let before: SharedArea.Position
        public let after: SharedArea.Position
        fileprivate var beforeWrite: SharedArea.PlacementWrite?
        fileprivate var afterWrite: SharedArea.PlacementWrite?
    }
    public struct Mutation: Codable, Sendable {
        public let command: SharedArea.Command
        public let kind: Kind
        public let changes: [Change]
        fileprivate let entryID: UUID
        public func validate(area: SharedArea.ID<SharedArea.Area>) throws {
            guard command.schema == 1, command.area == area, command.expectedRevision < UInt64.max,
                  !changes.isEmpty, changes.count <= 128,
                  Set(changes.map { $0.before.id }).count == changes.count,
                  changes.allSatisfy({ change in
                      change.before.id == change.after.id && change.before.object == change.after.object
                          && change.before.rect.valid && change.after.rect.valid && change.before != change.after
                          && (change.beforeWrite == nil || change.beforeWrite?.placement == change.before.id)
                          && (change.afterWrite == nil || change.afterWrite?.placement == change.after.id)
                  }), command.edits == changes.map({ .place(kind == .undo ? $0.before : $0.after) }) else {
                throw Failure.invalidGeometry
            }
        }
    }
    private struct Entry: Codable, Sendable { let id: UUID; let area: SharedArea.ID<SharedArea.Area>; var changes: [Change] }
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var acknowledged: [SharedArea.ID<SharedArea.Operation>: UInt64] = [:]
    private var acknowledgementOrder: [SharedArea.ID<SharedArea.Operation>] = []
    private let limit: Int

    public init(limit: Int = 100) { self.limit = max(1, min(1000, limit)) }
    public var undoCount: Int { undoEntries.count }
    public var redoCount: Int { redoEntries.count }
    public func acknowledgedRevision(for operation: SharedArea.ID<SharedArea.Operation>) -> UInt64? { acknowledged[operation] }
    public func validate(area: SharedArea.ID<SharedArea.Area>) throws {
        guard limit > 0 && limit <= 1000, undoEntries.count <= limit, redoEntries.count <= limit,
              acknowledgementOrder.count <= limit * 8,
              Set(acknowledgementOrder).count == acknowledgementOrder.count,
              Set(acknowledged.keys) == Set(acknowledgementOrder), acknowledged.values.allSatisfy({ $0 > 0 }) else { throw Failure.staleHistory }
        for entry in undoEntries + redoEntries {
            guard entry.area == area, !entry.changes.isEmpty, entry.changes.count <= 128,
                  Set(entry.changes.map { $0.before.id }).count == entry.changes.count,
                  entry.changes.allSatisfy({ change in
                      change.before.id == change.after.id && change.before.object == change.after.object
                          && change.before.rect.valid && change.after.rect.valid && change.before != change.after
                          && change.afterWrite?.placement == change.after.id
                          && (change.afterWrite?.revision ?? 0) > 0
                          && (change.beforeWrite == nil || (change.beforeWrite?.placement == change.before.id && (change.beforeWrite?.revision ?? 0) > 0))
                  }) else { throw Failure.staleHistory }
        }
    }

    public func move(in document: SharedArea.Document,
                     frames: [SharedArea.ID<SharedArea.Placement>: SharedArea.Rect],
                     kind: Kind = .move) throws -> Mutation {
        guard kind == .move || kind == .resize, !frames.isEmpty else { throw Failure.emptySelection }
        var changes: [Change] = []
        for id in frames.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let before = document.positions.first(where: { $0.id == id }), let rect = frames[id] else { throw Failure.missingPlacement }
            guard rect.valid else { throw Failure.invalidGeometry }
            var after = before; after.rect = rect
            if before != after {
                changes.append(.init(before: before, after: after, beforeWrite: document.placementWrite(for: id), afterWrite: nil))
            }
        }
        guard !changes.isEmpty else { throw Failure.unchanged }
        return .init(command: .init(area: document.id, expectedRevision: document.revision, edits: changes.map { .place($0.after) }),
                     kind: kind, changes: changes, entryID: UUID())
    }

    public func undo(in document: SharedArea.Document) throws -> Mutation {
        guard let entry = undoEntries.last, entry.area == document.id else { throw Failure.unavailable }
        try validate(entry.changes, in: document, after: true)
        return .init(command: .init(area: document.id, expectedRevision: document.revision, edits: entry.changes.map { .place($0.before) }),
                     kind: .undo, changes: entry.changes, entryID: entry.id)
    }
    public func redo(in document: SharedArea.Document) throws -> Mutation {
        guard let entry = redoEntries.last, entry.area == document.id else { throw Failure.unavailable }
        try validate(entry.changes, in: document, after: false)
        return .init(command: .init(area: document.id, expectedRevision: document.revision, edits: entry.changes.map { .place($0.after) }),
                     kind: .redo, changes: entry.changes, entryID: entry.id)
    }
    public func canUndo(in document: SharedArea.Document) -> Bool {
        guard let entry = undoEntries.last, entry.area == document.id else { return false }
        return (try? validate(entry.changes, in: document, after: true)) != nil
    }
    public func canRedo(in document: SharedArea.Document) -> Bool {
        guard let entry = redoEntries.last, entry.area == document.id else { return false }
        return (try? validate(entry.changes, in: document, after: false)) != nil
    }

    /// Call only with an authoritative accepted/duplicate receipt. A lost reply
    /// must retain the original Mutation until its durable receipt is recovered.
    public mutating func acknowledge(_ mutation: Mutation, revision: UInt64) throws {
        guard mutation.command.expectedRevision < UInt64.max, revision == mutation.command.expectedRevision + 1 else { throw Failure.invalidReceipt }
        if let previous = acknowledged[mutation.command.id] {
            guard previous == revision else { throw Failure.invalidReceipt }
            return
        }
        func write(_ change: Change) -> SharedArea.PlacementWrite {
            .init(placement: change.before.id, operation: mutation.command.id, revision: revision)
        }
        switch mutation.kind {
        case .move, .resize:
            let changes = mutation.changes.map { change in
                var value = change; value.afterWrite = write(change); return value
            }
            undoEntries.append(.init(id: mutation.entryID, area: mutation.command.area, changes: changes))
            if undoEntries.count > limit { undoEntries.removeFirst(undoEntries.count - limit) }
            redoEntries.removeAll()
        case .undo:
            guard var entry = undoEntries.last, entry.id == mutation.entryID else { throw Failure.staleHistory }
            undoEntries.removeLast()
            for index in entry.changes.indices {
                let change = entry.changes[index], nextWrite = write(change)
                // Only a proven local lineage can become eligible again. A
                // teammate's equal-looking ABA write never matches this stamp.
                replaceLineage(position: change.before, previous: change.beforeWrite, next: nextWrite)
                entry.changes[index].beforeWrite = nextWrite
            }
            redoEntries.append(entry)
        case .redo:
            guard var entry = redoEntries.last, entry.id == mutation.entryID else { throw Failure.staleHistory }
            redoEntries.removeLast()
            for index in entry.changes.indices {
                let change = entry.changes[index], nextWrite = write(change)
                replaceLineage(position: change.after, previous: change.afterWrite, next: nextWrite)
                entry.changes[index].afterWrite = nextWrite
            }
            undoEntries.append(entry)
        }
        acknowledged[mutation.command.id] = revision
        acknowledgementOrder.append(mutation.command.id)
        if acknowledgementOrder.count > limit * 8 {
            acknowledged.removeValue(forKey: acknowledgementOrder.removeFirst())
        }
    }
    private func validate(_ changes: [Change], in document: SharedArea.Document, after: Bool) throws {
        for change in changes {
            let expected = after ? change.after : change.before
            let write = after ? change.afterWrite : change.beforeWrite
            guard let write,
                  document.positions.first(where: { $0.id == expected.id }) == expected,
                  document.placementWrite(for: expected.id) == write else { throw Failure.changedByCollaborator }
        }
    }
    private mutating func replaceLineage(position: SharedArea.Position, previous: SharedArea.PlacementWrite?, next: SharedArea.PlacementWrite) {
        guard let previous else { return }
        for index in undoEntries.indices {
            for change in undoEntries[index].changes.indices {
                if undoEntries[index].changes[change].after == position && undoEntries[index].changes[change].afterWrite == previous {
                    undoEntries[index].changes[change].afterWrite = next
                }
            }
        }
        for index in redoEntries.indices {
            for change in redoEntries[index].changes.indices {
                if redoEntries[index].changes[change].before == position && redoEntries[index].changes[change].beforeWrite == previous {
                    redoEntries[index].changes[change].beforeWrite = next
                }
            }
        }
    }
}
