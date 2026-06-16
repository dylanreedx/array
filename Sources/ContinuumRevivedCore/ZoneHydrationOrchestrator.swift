import CoreGraphics
import Foundation

/// The pure result of planning hydration across every zone in a workspace at once:
/// each known zone mapped to the tier its controller SHOULD hold. Total over the input
/// zones (every input zoneId appears exactly once); deterministic for a given input.
public struct ZoneHydrationPlan: Equatable, Sendable {
    /// zoneId -> assigned tier. Total over the input zone set.
    public let tiers: [UUID: HydrationTier]
    /// The input zones in the same order they were supplied, for stable iteration in
    /// callers/tests. (A dictionary has no order; this preserves the caller's.)
    public let order: [UUID]

    public init(tiers: [UUID: HydrationTier], order: [UUID]) {
        self.tiers = tiers
        self.order = order
    }

    public func tier(for zoneId: UUID) -> HydrationTier? { tiers[zoneId] }
}

/// Pure cross-zone hydration planner (docs/23 S1, CON-51). Composes the per-zone
/// visibility/pin/focus verdict (`CanvasEngine.hydrationTier`) with a global cap on how
/// many zones may be `.live` at once, demoting overflow to `.snapshot`. No AppKit, no
/// state — applying the plan (spinning/teardown of controllers) is T06/T10.
public enum ZoneHydrationOrchestrator {
    /// Compute the tier for every zone.
    ///
    /// - zones: the workspace's placements (order is preserved into the plan).
    /// - viewport / visibleSize: the live canvas view, forwarded verbatim to
    ///   `CanvasEngine.hydrationTier` (Y-down world coords; visibleSize is screen px,
    ///   converted to world by that fn via `/ viewport.zoom`).
    /// - focusedTileZone: the zone whose focused tile forces `.live` (forwarded).
    /// - maxLiveZones: the live budget; when more zones than this resolve to `.live`,
    ///   the lowest-priority overflow zones demote to `.snapshot`. `<= 0` is clamped to
    ///   1 (at least the highest-priority zone stays live).
    /// - snapshotMargin: forwarded to `CanvasEngine.hydrationTier` (default matches it).
    public static func plan(
        zones: [ZonePlacement],
        viewport: CanvasViewport,
        visibleSize: CGSize,
        focusedTileZone: UUID?,
        maxLiveZones: Int,
        snapshotMargin: Double = CanvasEngine.defaultHydrationSnapshotMargin
    ) -> ZoneHydrationPlan {
        // Step 1: compute base verdict for every zone.
        let bases: [(ZonePlacement, Int, HydrationTier)] = zones.enumerated().map { (index, zone) in
            let tier = CanvasEngine.hydrationTier(
                zone: zone,
                viewport: viewport,
                visibleSize: visibleSize,
                focusedTileZone: focusedTileZone,
                snapshotMargin: snapshotMargin
            )
            return (zone, index, tier)
        }

        // Step 2: partition live zones into hard-pinned vs. budget-eligible.
        // Hard-pinned: pinnedLive policy OR is the focusedTileZone.
        let hardPinnedLive = bases.filter { (zone, _, tier) in
            tier == .live && (zone.hydrationPolicy == .pinnedLive || zone.zoneId == focusedTileZone)
        }
        let budgetEligibleLive = bases.filter { (zone, _, tier) in
            tier == .live && zone.hydrationPolicy != .pinnedLive && zone.zoneId != focusedTileZone
        }

        // Step 3: budget math.
        let B = max(1, maxLiveZones)
        let P = hardPinnedLive.count
        let keep = max(0, B - P)

        // Step 4: sort eligible-live by proximity asc, then input index asc.
        let visibleWorldWidth = Double(visibleSize.width) / viewport.zoom
        let visibleWorldHeight = Double(visibleSize.height) / viewport.zoom
        let centerX = viewport.x + visibleWorldWidth / 2
        let centerY = viewport.y + visibleWorldHeight / 2

        let sortedEligible = budgetEligibleLive.sorted { lhs, rhs in
            let (lhsZone, lhsIndex, _) = lhs
            let (rhsZone, rhsIndex, _) = rhs
            let lhsCx = lhsZone.origin.x + lhsZone.size.width / 2
            let lhsCy = lhsZone.origin.y + lhsZone.size.height / 2
            let rhsCx = rhsZone.origin.x + rhsZone.size.width / 2
            let rhsCy = rhsZone.origin.y + rhsZone.size.height / 2
            let lhsDist2 = (lhsCx - centerX) * (lhsCx - centerX) + (lhsCy - centerY) * (lhsCy - centerY)
            let rhsDist2 = (rhsCx - centerX) * (rhsCx - centerX) + (rhsCy - centerY) * (rhsCy - centerY)
            if lhsDist2 != rhsDist2 { return lhsDist2 < rhsDist2 }
            return lhsIndex < rhsIndex
        }

        // Step 5: demote overflow eligible-live zones to .snapshot.
        let keptEligibleIds = Set(sortedEligible.prefix(keep).map { $0.0.zoneId })

        // Step 6: assemble tiers, iterating input order (not dictionary).
        var tiers: [UUID: HydrationTier] = [:]
        for (zone, _, baseTier) in bases {
            if baseTier == .live {
                if zone.hydrationPolicy == .pinnedLive || zone.zoneId == focusedTileZone {
                    tiers[zone.zoneId] = .live
                } else if keptEligibleIds.contains(zone.zoneId) {
                    tiers[zone.zoneId] = .live
                } else {
                    tiers[zone.zoneId] = .snapshot
                }
            } else {
                tiers[zone.zoneId] = baseTier
            }
        }

        let order = zones.map(\.zoneId)
        return ZoneHydrationPlan(tiers: tiers, order: order)
    }
}
