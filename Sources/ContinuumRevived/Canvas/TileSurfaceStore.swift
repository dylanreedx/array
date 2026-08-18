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
    func bake(tileId: UUID, body: NSView, revision: TileSurfaceRevision) -> TileSurface? {
        let bounds = body.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = body.bitmapImageRepForCachingDisplay(in: bounds),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            qaBakeFailureCount += 1
            return nil
        }
        body.cacheDisplay(in: bounds, to: rep)
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
        let surface = TileSurface(image: image, revision: revision, bakedScale: scale)
        surfaces[tileId] = surface
        qaBakeCount += 1
        return surface
    }

    func qaResetCounters() {
        qaBakeCount = 0
        qaBakeFailureCount = 0
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
