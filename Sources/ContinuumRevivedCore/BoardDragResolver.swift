import Foundation

// KB-01: the jelly. Plan: .plans/60-kanban-board.md
//
// The canvas already solved this shape for tiles and the board reuses the
// PRINCIPLE, never the geometry solver as board-data authority:
//
//   free layer     the raw pointer, accumulated un-snapped, zero smoothing
//                  (`TileNSView.mouseDragged`'s `moveFreeWorldFrame`)
//   preview layer  recomputed FROM SCRATCH every event with hysteresis
//                  (`MagneticPlacement.resolve`'s acquire/release bands)
//   model layer    untouched until mouse-up, then exactly the previewed target
//                  ("Commit exactly the previewed world destination")
//
// Recomputing per event rather than latching at mouse-down is what makes
// displacement genuinely interruptible: a card the canvas API moves mid-drag is
// absorbed on the very next pointer event, because the caller rebuilds `slots`
// from the live model each time.
//
// Two bands, not one. A single threshold makes the preview flicker at the
// boundary; that is the defect this file exists to prevent.

/// Tuning. Screen points, divided by canvas zoom at the call site so the catch
/// distance FEELS constant at any zoom — the same reasoning as
/// `DragMagnetizeConfig`, at card scale rather than tile scale.
public enum BoardDragConfig {
    /// A new slot this close to the pointer steals the target immediately. The
    /// early-commit override: when the pointer is unambiguously ON a slot, the
    /// preview follows without waiting out the boundary margin.
    public static let acquireScreenPoints: Double = 18

    /// How far PAST the boundary between the held slot and its challenger the
    /// pointer must travel before the preview retargets.
    ///
    /// Expressed against the boundary, not as a radius around the held slot's
    /// centre, and that distinction is the whole point. A radius only has an
    /// effect while it exceeds half the slot spacing — so a "release radius" of
    /// 28pt does precisely nothing for ordinary 80pt cards, where the nearest
    /// slot and the held slot only disagree beyond 40pt. The resolver then
    /// degenerates to nearest-slot and flickers at the midpoint, which is exactly
    /// the feel this file exists to prevent. A boundary margin bites at every
    /// spacing.
    public static let boundaryMarginScreenPoints: Double = 10
    /// How far past a held column's edge the pointer must travel to leave it,
    /// as a fraction of that column's width. Asymmetric on purpose: entering is
    /// free, leaving costs, so a card resting on a boundary does not oscillate.
    public static let columnReleaseFraction: Double = 0.15

    /// Presentation-only durations, seconds. Zero under reduced motion.
    public static let displacementDuration: Double = 0.16
    /// Verbatim `CanvasNSView.animateSnapLanding`.
    public static let settleDuration: Double = 0.11
}

/// One candidate insertion position: the gap above card `before`, below card
/// `after`. A column with n cards has n+1 slots, including the empty column's
/// single slot. Frames are BOARD-LOCAL points supplied by the view.
public struct BoardSlot: Equatable, Sendable {
    public let columnId: UUID
    /// 0-based insertion index within the column.
    public let index: Int
    public let after: UUID?
    public let before: UUID?
    /// Vertical centre of the gap.
    public let centerY: Double
    public let columnMinX: Double
    public let columnMaxX: Double

    public init(
        columnId: UUID, index: Int, after: UUID?, before: UUID?,
        centerY: Double, columnMinX: Double, columnMaxX: Double
    ) {
        self.columnId = columnId
        self.index = index
        self.after = after
        self.before = before
        self.centerY = centerY
        self.columnMinX = columnMinX
        self.columnMaxX = columnMaxX
    }

    public var columnWidth: Double { max(0, columnMaxX - columnMinX) }
}

/// What the preview is showing, and — unchanged — what mouse-up commits.
public struct BoardDragTarget: Equatable, Sendable {
    public let columnId: UUID
    public let index: Int
    public let after: UUID?
    public let before: UUID?

    public init(columnId: UUID, index: Int, after: UUID?, before: UUID?) {
        self.columnId = columnId
        self.index = index
        self.after = after
        self.before = before
    }

    public init(slot: BoardSlot) {
        self.init(columnId: slot.columnId, index: slot.index, after: slot.after, before: slot.before)
    }

    /// The command that commits this exact preview. The only way a drag reaches
    /// the model — so "the card lands where the preview said" is structural, not
    /// a thing the view has to remember to do.
    public func moveCommand(for cardId: UUID) -> BoardCommand {
        .moveCard(id: cardId, toColumn: columnId, after: after, before: before)
    }
}

public enum BoardDragResolver {
    /// The preview for this pointer position.
    ///
    /// - Parameters:
    ///   - freePoint: the raw, un-snapped pointer in board-local coordinates.
    ///   - slots: every candidate slot, rebuilt from the LIVE model this event.
    ///   - previous: last event's target, or nil at gesture start.
    ///   - zoom: canvas zoom, so the bands stay constant in screen points.
    /// - Returns: nil only when there is nowhere to drop (a board with no
    ///   columns). Otherwise a drag always previews a real destination.
    public static func resolve(
        freePoint: CGPoint,
        slots: [BoardSlot],
        previous: BoardDragTarget?,
        zoom: Double
    ) -> BoardDragTarget? {
        guard !slots.isEmpty else { return nil }
        let scale = (zoom.isFinite && zoom > 0) ? zoom : 1
        let acquire = BoardDragConfig.acquireScreenPoints / scale
        let margin = BoardDragConfig.boundaryMarginScreenPoints / scale

        let columnId = resolveColumn(freeX: freePoint.x, slots: slots, previous: previous)
        let candidates = slots.filter { $0.columnId == columnId }
        guard !candidates.isEmpty else { return nil }

        guard let nearest = candidates.min(by: {
            distance($0, freePoint.y) < distance($1, freePoint.y)
        }) else { return nil }

        // A held slot keeps the preview stable through small movements and
        // direction reversals: the challenger only wins once the pointer is
        // `margin` past the midpoint between them, so the boundary a reversal
        // re-crosses is not the boundary that just fired.
        if let previous, previous.columnId == columnId,
           let held = candidates.first(where: { $0.index == previous.index }) {
            if nearest.index == held.index {
                // Re-emit from the CURRENT slot, not the stored target: the model
                // may have changed under the drag, so the held index's anchors can
                // differ from last event's. This is the interruptibility seam.
                return BoardDragTarget(slot: held)
            }
            let boundary = (held.centerY + nearest.centerY) / 2
            let crossed = nearest.centerY > held.centerY
                ? freePoint.y > boundary + margin
                : freePoint.y < boundary - margin
            let earlyCommit = distance(nearest, freePoint.y) <= acquire
            if !crossed, !earlyCommit {
                return BoardDragTarget(slot: held)
            }
        }
        return BoardDragTarget(slot: nearest)
    }

    private static func distance(_ slot: BoardSlot, _ y: Double) -> Double {
        abs(slot.centerY - y)
    }

    /// Which column the pointer is in, with leave-hysteresis on the held one.
    private static func resolveColumn(freeX: Double, slots: [BoardSlot], previous: BoardDragTarget?) -> UUID {
        if let previous, let held = slots.first(where: { $0.columnId == previous.columnId }) {
            let slack = held.columnWidth * BoardDragConfig.columnReleaseFraction
            if freeX >= held.columnMinX - slack, freeX <= held.columnMaxX + slack {
                return held.columnId
            }
        }
        // Containment first, then nearest edge — so the gutter between two
        // columns resolves to the closer one instead of to nothing.
        if let containing = slots.first(where: { freeX >= $0.columnMinX && freeX <= $0.columnMaxX }) {
            return containing.columnId
        }
        let nearest = slots.min { lhs, rhs in
            edgeDistance(freeX, lhs) < edgeDistance(freeX, rhs)
        }
        return nearest?.columnId ?? slots[0].columnId
    }

    private static func edgeDistance(_ x: Double, _ slot: BoardSlot) -> Double {
        if x < slot.columnMinX { return slot.columnMinX - x }
        if x > slot.columnMaxX { return x - slot.columnMaxX }
        return 0
    }

    /// Build the slot set for one column from its card frames, top to bottom.
    /// `cardCenters` must be in the same order as `cardIds`. An empty column
    /// still yields one slot — an empty column is a drop target, not a dead
    /// region.
    public static func slots(
        columnId: UUID,
        cardIds: [UUID],
        cardCenters: [Double],
        cardTops: [Double],
        cardBottoms: [Double],
        emptyCenterY: Double,
        columnMinX: Double,
        columnMaxX: Double
    ) -> [BoardSlot] {
        guard !cardIds.isEmpty else {
            return [BoardSlot(
                columnId: columnId, index: 0, after: nil, before: nil,
                centerY: emptyCenterY, columnMinX: columnMinX, columnMaxX: columnMaxX)]
        }
        var result: [BoardSlot] = []
        // The first and last slots sit at the outer EDGES of the end cards, not
        // half a card beyond them, so the ends are no harder to hit than the
        // middle. Edge targets were an explicit requirement.
        result.append(BoardSlot(
            columnId: columnId, index: 0, after: nil, before: cardIds[0],
            centerY: cardTops.first ?? emptyCenterY,
            columnMinX: columnMinX, columnMaxX: columnMaxX))
        for index in 1..<cardIds.count {
            let midpoint = (cardCenters[index - 1] + cardCenters[index]) / 2
            result.append(BoardSlot(
                columnId: columnId, index: index,
                after: cardIds[index - 1], before: cardIds[index],
                centerY: midpoint, columnMinX: columnMinX, columnMaxX: columnMaxX))
        }
        result.append(BoardSlot(
            columnId: columnId, index: cardIds.count, after: cardIds[cardIds.count - 1], before: nil,
            centerY: cardBottoms.last ?? emptyCenterY,
            columnMinX: columnMinX, columnMaxX: columnMaxX))
        return result
    }
}
