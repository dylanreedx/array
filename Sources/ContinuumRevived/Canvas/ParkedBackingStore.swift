import AppKit

/// Backing stores of a far-parked tile body.
///
/// A far-parked body is not on screen and receives no events, but its
/// drawRect-drawn layers keep the pixels they last drew: width x height x scale^2
/// x 4 bytes each, for as long as the tile stays parked. Parking is what the tile
/// does for most of a big canvas, so those bytes grow with tiles ever shown rather
/// than tiles on screen.
///
/// Release drops only AppKit-owned backing stores (a view's own layer whose
/// delegate is the view, drawn by `draw(_:)`). It never touches layers a family
/// fills itself with a `CGImage` or `IOSurface` (sprites, symbols), nor
/// `updateLayer` views, whose pixels may not be reproducible by a redraw.
/// Returning the body marks exactly the released views dirty, so the next display
/// pass, before the commit that shows the tile, redraws them: no placeholder frame.
enum ParkedBackingStore {
    /// `CONTINUUM_LEGACY_PARKED_BACKING=1` restores the old behaviour (keep every
    /// backing store while parked): the RED arm of the witness.
    nonisolated(unsafe) static var releaseEnabled =
        ProcessInfo.processInfo.environment["CONTINUUM_LEGACY_PARKED_BACKING"] == nil

    struct Census {
        var layers = 0
        var bytes = 0
        var byClass: [String: Int] = [:]
    }

    private static func isOwnedBackingStore(_ contents: Any?) -> Bool {
        guard let contents else { return false }
        let object = contents as CFTypeRef
        let type = CFGetTypeID(object)
        return type != CGImage.typeID && type != IOSurfaceGetTypeID()
    }

    private static func bytes(of layer: CALayer) -> Int {
        let scale = max(layer.contentsScale, 1)
        return Int(layer.bounds.width * scale) * Int(layer.bounds.height * scale) * 4
    }

    /// Every view layer under `root` that currently holds an AppKit backing store.
    static func census(in root: NSView) -> Census {
        var result = Census()
        visit(root) { view, layer in
            guard isOwnedBackingStore(layer.contents) else { return }
            let size = bytes(of: layer)
            result.layers += 1
            result.bytes += size
            result.byClass[String(describing: type(of: view)), default: 0] += size
        }
        return result
    }

    /// Drop the backing stores; returns the views to mark dirty on return.
    static func release(in root: NSView) -> [Weak] {
        var released: [Weak] = []
        visit(root) { view, layer in
            guard !view.wantsUpdateLayer, isOwnedBackingStore(layer.contents) else { return }
            layer.contents = nil
            released.append(Weak(view))
        }
        return released
    }

    static func restore(_ released: [Weak]) {
        for entry in released { entry.view?.needsDisplay = true }
    }

    struct Weak {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private static func visit(_ view: NSView, _ body: (NSView, CALayer) -> Void) {
        if let layer = view.layer, layer.delegate === view { body(view, layer) }
        for sub in view.subviews { visit(sub, body) }
    }
}
