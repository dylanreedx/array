import Foundation
import ContinuumRevivedCollaborationProtocol

/// A pure geometry adapter. The caller supplies reviewed publications and WORLD
/// model tiles, including persisted tiles outside the current hydration tier.
/// Reading content, approving publication and complete selection are COL-09.
public enum SharedAreaCapture {
    public struct Entry: Sendable {
        public let tile: Tile
        public let publication: SharedArea.Item
        public let placement: SharedArea.ID<SharedArea.Placement>
        public init(tile: Tile, publication: SharedArea.Item, placement: SharedArea.ID<SharedArea.Placement>) {
            self.tile = tile; self.publication = publication; self.placement = placement
        }
    }
    public static func edits(entries: [Entry], originX: Double, originY: Double) throws -> [SharedArea.Edit] {
        guard originX.isFinite, originY.isFinite else { throw SharedArea.Failure.invalidGeometry }
        // A capture's z-order is independent of private fractional-index values.
        let ordered = entries.sorted {
            if $0.tile.zPosition != $1.tile.zPosition { return $0.tile.zPosition < $1.tile.zPosition }
            return $0.tile.id.uuidString < $1.tile.id.uuidString
        }
        return try ordered.enumerated().map { index, entry in
            let frame = entry.tile.frame
            let rect = SharedArea.Rect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
                .relative(toX: originX, y: originY)
            guard rect.valid else { throw SharedArea.Failure.invalidGeometry }
            return .admit(entry.publication, SharedArea.Position(id: entry.placement,
                object: entry.publication.id, rect: rect, z: index))
        }
    }
}
