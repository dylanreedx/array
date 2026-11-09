import Foundation

public extension CanvasEngine {
    /// The tiles to write into one project's `canvas.json`, given what is currently
    /// installed and what is already on disk.
    ///
    /// M1.0 (`.plans/46`). Persistence used to *replace* the persisted tile list
    /// with whatever happened to be installed — `state.tiles = tiles` in
    /// `TileSpawner.persistProjectCanvas`, and the whole flat `canvasState` in
    /// `ZoneRuntimeController.flushCanvasSave`. Both are wrong once ZoneLayers own
    /// the scene: the installed set covers only the zones that are live right now,
    /// so anything in a zone at a lower hydration tier — or in another workspace —
    /// was silently dropped from the file.
    ///
    /// The rule is *cover, then replace*. A persisted tile is only allowed to
    /// disappear when the caller can prove it was deleted, which means its own zone
    /// was installed and it is nonetheless absent from that zone. A tile whose zone
    /// is not installed is not evidence of anything and is carried through
    /// untouched. `CanvasNSView.tiles(forProjectId:)` already promises this in its
    /// doc comment — *"persistence must never replace the project canvas with only
    /// the last zone that changed"* — and this is the function that keeps it.
    ///
    /// Persisted order is preserved so a save produces a minimal diff; genuinely new
    /// tiles append in installed order.
    ///
    /// - Parameters:
    ///   - persisted: the project's tiles as they currently exist on disk.
    ///   - installed: the tiles this project's installed ZoneLayers hold right now.
    ///   - coveredZoneIds: the zoneIds of THIS project's installed layers. Only
    ///     these zones may delete a tile. Passing an empty set makes the merge
    ///     purely additive, which is the correct behaviour when nothing of this
    ///     project is on screen.
    static func mergeProjectTilesForPersistence(
        persisted: [Tile],
        installed: [Tile],
        coveredZoneIds: Set<UUID>
    ) -> [Tile] {
        let installedByID = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var emitted = Set<UUID>()
        var result: [Tile] = []
        result.reserveCapacity(max(persisted.count, installed.count))

        for tile in persisted {
            if let live = installedByID[tile.id] {
                result.append(live)
                emitted.insert(tile.id)
                continue
            }
            // Absent from the installed set. Only a zone that is actually installed
            // is allowed to say "this tile is gone"; every other absence is just a
            // zone we cannot see from here.
            if let zoneId = tile.zoneId, coveredZoneIds.contains(zoneId) {
                continue
            }
            result.append(tile)
            emitted.insert(tile.id)
        }

        for tile in installed where !emitted.contains(tile.id) {
            result.append(tile)
            emitted.insert(tile.id)
        }

        return result
    }
}
