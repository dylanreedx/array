import AppKit
import ContinuumRevivedCore

/// What a surface has to match to be admissible for a tile.
///
/// Deliberately the smallest vector that can go stale: the content version the
/// body was showing, the size it was laid out at, and the appearance it was drawn
/// in. `.plans/34` B1 describes the full `RevisionVector` this grows into
/// (resource and style epochs, scene generation); slice 1 needs three fields and
/// gains nothing from the other three.
struct TileSurfaceRevision: Equatable {
    /// The family's own fingerprint of what its body renders — for an agent tile, a
    /// mix of `AgentDocument.version` and a counter over ingested events, because the
    /// document version alone misses the compact status row moving between "Working"
    /// and "Done". Equality is the whole freshness test.
    let contentVersion: UInt64
    let bodySize: CGSize
    let appearanceName: String
}

/// One tile's baked pixels plus the revision they represent.
struct TileSurface {
    let image: CGImage
    let revision: TileSurfaceRevision
    /// Device pixels per world point the image actually carries. Compared against
    /// what the screen needs — never assumed.
    let bakedScale: CGFloat
    /// Where the body's scrollable content sat when this picture was taken.
    ///
    /// Deliberately NOT part of `TileSurfaceRevision`. Scrolling changes no
    /// CONTENT, so a family's fingerprint does not move, and a surface baked
    /// before a scroll still matched the revision afterwards — the residency pass
    /// skipped the bake and handed the tile a faithful picture of a position the
    /// body had already left (`.plans/39` mechanism 1). But it cannot go in the
    /// revision either: the revision is recomputed for SURFACED tiles too, whose
    /// bodies are parked, and a parked body's clip geometry is degenerate — that
    /// comparison never settles and every tile thrashes. Measured: a witness that
    /// had passed for weeks ("a tile that fell quiet must surface again") went red
    /// the moment scroll offsets entered the revision.
    ///
    /// So it lives here and is compared in exactly one place — `surfaceIfAdmissible`,
    /// which only ever runs on a NATIVE tile, whose body is in the plane and whose
    /// scroll position is therefore real.
    let bakedScrollOffsets: [CGPoint]

    /// Every sampled pixel identical: a flat rectangle. Correct for an empty
    /// note, never correct for a tile that always paints chrome of its own — the
    /// canvas decides which case it has.
    let isUniform: Bool

    var byteCount: Int { image.width * image.height * 4 }

    /// **The rule that keeps a surfaced tile from ever looking softer than the
    /// native body would.** Zooming out lowers the requirement, so a surface baked
    /// at rest stays admissible all the way down; zooming in raises it past what
    /// the image carries, and those tiles stay native instead of going blurry.
    /// Since zooming in also shrinks the visible set, that is cheap.
    func isSharpEnough(forZoom zoom: Double, backingScale: CGFloat) -> Bool {
        let needed = CGFloat(max(0.0001, zoom)) * backingScale
        return bakedScale + 0.0001 >= needed
    }
}

/// Holds one surface per tile and produces them from live bodies.
///
/// The producer is `cacheDisplay` of a body that is parked outside the world
/// plane — `.plans/34`'s `AppKitCaptureProducer`, and the interim stand-in for
/// I2's per-block display list. `canvas.surface-host-slope`'s parked arm proved
/// both halves it depends on: a clipped-out view still yields real pixels, and
/// those pixels change when one streaming event arrives.
@MainActor
final class TileSurfaceStore {
    private var surfaces: [UUID: TileSurface] = [:]

    private(set) var qaBakeCount = 0
    private(set) var qaBakeFailureCount = 0

    var count: Int { surfaces.count }
    var totalBytes: Int { surfaces.values.reduce(0) { $0 + $1.byteCount } }

    func surface(for tileId: UUID) -> TileSurface? { surfaces[tileId] }

    func drop(_ tileId: UUID) { surfaces.removeValue(forKey: tileId) }

    /// Forget every surface for a tile that is no longer on the canvas. Called on
    /// zone/project switch: a surface is per-tile state and a departed project's
    /// tiles are not coming back into this canvas.
    func prune(keeping liveTileIds: Set<UUID>) {
        for id in surfaces.keys where !liveTileIds.contains(id) {
            surfaces.removeValue(forKey: id)
        }
    }

    func removeAll() { surfaces.removeAll() }

    /// Produce a surface from a live body, at whatever density the window's backing
    /// store already uses. Returns nil rather than storing anything questionable —
    /// the caller's contract is that a failed bake leaves the tile native.
    @discardableResult
    func bake(
        tileId: UUID, body: NSView, revision: TileSurfaceRevision, scrollOffsets: [CGPoint] = []
    ) -> TileSurface? {
        let bounds = body.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = body.bitmapImageRepForCachingDisplay(in: bounds),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            qaBakeFailureCount += 1
            return nil
        }
        body.cacheDisplay(in: bounds, to: rep)
        // Measured HERE because this is where the rep is; judged by the canvas,
        // which is the only place that knows whether a flat rectangle is a
        // legitimate picture of this tile. An empty note bakes uniform and is
        // perfectly correct; an agent tile — composer, status line, transcript —
        // never is, and a uniform bake of one is the blank body users reported.
        let scanStart = ProcessInfo.processInfo.systemUptime
        let uniform = Self.isUniform(rep)
        Self.qaBakeScanMsTotal += (ProcessInfo.processInfo.systemUptime - scanStart) * 1_000
        Self.qaBakeScanCount += 1
        if uniform { qaUniformBakeCount += 1 }
        guard let produced = rep.cgImage else {
            qaBakeFailureCount += 1
            return nil
        }
        let image = TileSurfaceResidencyConfig.degradesBakes()
            ? (Self.halved(produced) ?? produced)
            : produced
        // Read the density off the rep instead of assuming the backing scale: a
        // window on a 1x display, or none at all, produces a different rep, and a
        // surface that claims a sharpness it does not have would be shown when it
        // should have been refused.
        let scale = CGFloat(rep.pixelsWide) / max(1, bounds.width)
        let surface = TileSurface(
            image: image, revision: revision, bakedScale: scale,
            bakedScrollOffsets: scrollOffsets, isUniform: uniform
        )
        surfaces[tileId] = surface
        qaBakeCount += 1
        return surface
    }

    func qaResetCounters() {
        qaBakeCount = 0
        qaBakeFailureCount = 0
        qaUniformBakeCount = 0
    }

    /// Cost of the uniformity scan, accumulated statically so the bake-cost
    /// instrument can attribute it: an unattributed millisecond turns a published
    /// number into fiction, which is the guard that caught this scan in the first
    /// place.
    private(set) static var qaBakeScanMsTotal: Double = 0
    private(set) static var qaBakeScanCount = 0

    static func qaResetBakeScanTiming() {
        qaBakeScanMsTotal = 0
        qaBakeScanCount = 0
    }

    /// Bakes that came out as a flat rectangle. Not a failure by itself — an
    /// empty note legitimately bakes uniform — but a canvas producing them in
    /// bulk for content-bearing tiles is a bug upstream of this store.
    private(set) var qaUniformBakeCount = 0

    /// Is every sampled pixel identical — i.e. would a user see a flat rectangle?
    ///
    /// Reads `bitmapData` on a coarse stride (about 24x24 samples, bounded) so the
    /// cost is a few hundred pointer reads per bake rather than `colorAt`'s
    /// per-pixel object allocation. Any single differing byte answers "not
    /// uniform" and returns immediately, so a real tile costs almost nothing.
    private static func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return false }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow
        let sample = max(1, rep.bitsPerPixel / 8)
        guard width > 0, height > 0, rowBytes > 0, sample >= 1 else { return false }
        let strideX = max(1, width / 24)
        let strideY = max(1, height / 24)
        let first = data[0]
        var y = 0
        while y < height {
            var x = 0
            let row = y * rowBytes
            while x < width {
                let offset = row + x * sample
                guard offset < rowBytes * height else { break }
                if data[offset] != first { return false }
                x += strideX
            }
            y += strideY
        }
        return true
    }

    /// Round-trip through a half-size bitmap: the negative witness for the
    /// pixel-equivalence gate. A fidelity gate that cannot be made to fail proves
    /// nothing, and `--tile-surface-residency-check` must go red under
    /// `TILE_SURFACE_HALF_SCALE=1`.
    private static func halved(_ image: CGImage) -> CGImage? {
        func context(width: Int, height: Int) -> CGContext? {
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        let halfWidth = max(1, image.width / 2)
        let halfHeight = max(1, image.height / 2)
        guard let down = context(width: halfWidth, height: halfHeight) else { return nil }
        down.interpolationQuality = .low
        down.draw(image, in: CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
        guard let small = down.makeImage(),
              let up = context(width: image.width, height: image.height) else { return nil }
        up.interpolationQuality = .low
        up.draw(small, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return up.makeImage()
    }
}
