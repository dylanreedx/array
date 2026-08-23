import Foundation

public extension CanvasEngine {
    /// Which of a project's zones each of its tiles belongs to — repairing stamps
    /// that name a zone the project does not own. M1.10 (`.plans/46`).
    ///
    /// **Why a repair is needed at all.** A tile's persisted `zoneId` can name a
    /// zone belonging to a *different* project, and that is the normal outcome of
    /// ordinary use rather than an exotic corruption: `reevaluateZoneMembership`
    /// stamps a dragged tile with whatever live zone contains it, and the live zone
    /// set at boot is seeded from **every** zone in the workspace document,
    /// including other projects'. One real store had all 89 tiles of one project
    /// stamped with another project's zone. A membership filter of the form
    /// `tile.zoneId == zone.zoneId || (tile.zoneId == nil && …)` renders every one
    /// of those tiles **nowhere** — indistinguishable, to the person looking at it,
    /// from losing them.
    ///
    /// **The rule.**
    /// 1. A stamp naming one of this project's zones is authoritative. Untouched.
    /// 2. A nil stamp, or one naming a zone THIS DOCUMENT owns under a different
    ///    project, is *rescued*: into whichever of this project's zones
    ///    geometrically contains the tile's centre, and failing that into
    ///    `homeZoneId`.
    /// 2b. A stamp naming a zone that is not in this document at all is **left
    ///    alone** and reported as deferred. It belongs to a zone another workspace
    ///    owns, and rescuing it here would drag the tile out of that workspace —
    ///    the same "absence is not evidence" doctrine the persistence merge
    ///    follows. Caught by `--zone-runtime-duplication-check`, whose fixture
    ///    shares one project across two workspaces.
    /// 3. Never into another project's zone: `projectZones` only ever contains this
    ///    project's, so a rescue cannot move a tile across a project boundary.
    /// 4. **Never drop a tile.** Every input appears in exactly one output bucket.
    /// 5. **Never move a tile.** Frames in and out are WORLD frames, and the caller
    ///    converts to zone-local against the *rescuing* zone's origin — so
    ///    `local + origin == world` and the tile paints on exactly the pixel it
    ///    already occupied. Membership changes; position does not.
    ///
    /// The result is durable (callers persist it), which is why it is a pure
    /// function with its own witnesses rather than a branch inside the runtime.
    ///
    /// - Parameters:
    ///   - tiles: the project's persisted tiles, in WORLD frames.
    ///   - projectZones: every zone in THIS workspace document owned by this
    ///     project, in document order.
    ///   - documentZoneIds: every zone id in this document, whoever owns it. A
    ///     stamp naming a zone that is not here at all belongs to a zone this
    ///     document cannot see — another workspace's — and is left alone.
    ///   - homeZoneId: where a rescued tile lands when no zone contains it.
    /// - Returns: tiles bucketed by zone with `zoneId` stamped, the ids whose stamp
    ///   changed, and the ids deferred to a zone outside this document.
    static func resolveZoneMembership(
        tiles: [Tile],
        projectZones: [ZonePlacement],
        documentZoneIds: Set<UUID>,
        homeZoneId: UUID
    ) -> (byZone: [UUID: [Tile]], restamped: [UUID], deferred: [UUID]) {
        guard !projectZones.isEmpty else { return ([:], [], tiles.map(\.id)) }
        let owned = Set(projectZones.map(\.zoneId))
        let home = owned.contains(homeZoneId) ? homeZoneId : projectZones[0].zoneId

        var byZone: [UUID: [Tile]] = [:]
        var restamped: [UUID] = []
        var deferred: [UUID] = []

        for tile in tiles {
            if let stamped = tile.zoneId {
                if owned.contains(stamped) {
                    byZone[stamped, default: []].append(tile)
                    continue
                }
                if !documentZoneIds.contains(stamped) {
                    // A zone this document cannot see. The same doctrine the
                    // persistence merge follows: absence is not evidence. The tile
                    // lives in another workspace's zone and is none of our business
                    // — rescuing it here would drag it out of that workspace.
                    deferred.append(tile.id)
                    continue
                }
                // Present in this document but owned by a DIFFERENT project. That
                // stamp is provably wrong, and it is the one ordinary dragging
                // produces.
            }
            let centreX = tile.frame.x + tile.frame.width / 2
            let centreY = tile.frame.y + tile.frame.height / 2
            let containing = projectZones.first { zone in
                let frame = zoneWorldFrame(zone)
                return centreX >= frame.x && centreX <= frame.x + frame.width
                    && centreY >= frame.y && centreY <= frame.y + frame.height
            }
            let destination = containing?.zoneId ?? home
            restamped.append(tile.id)
            var placed = tile
            placed.zoneId = destination
            byZone[destination, default: []].append(placed)
        }

        return (byZone, restamped, deferred)
    }
}
