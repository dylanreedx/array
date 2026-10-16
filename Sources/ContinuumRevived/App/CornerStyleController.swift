import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// A view whose corner radii are not re-derived by `applyTokens()`, `layout()`
/// or `draw(_:)`. The corner-style walk calls this so it re-applies them.
@MainActor
protocol CornerStyled: NSView {
    /// Assign every corner radius this view owns, from `CornerRole`, from scratch.
    func applyCornerStyle()
}

/// The one writer of `CornerStyle.current`, and the live re-render that makes a
/// new style land on everything already on screen without a restart.
///
/// It rides the same invalidation the appearance flip uses: every view in every
/// window has `applyTokens()` re-run (where `TokenThemed` views assign their
/// radii alongside their colours), `applyCornerStyle()` for the views that keep
/// radii elsewhere, and a fresh layout and display pass for the rest (radii set
/// in `layout()` and paths drawn in `draw(_:)`). SwiftUI content and the few
/// controllers that cache geometry observe `didChangeNotification`.
@MainActor
enum CornerStyleController {
    static let didChangeNotification = Notification.Name("array.appearance.cornerStyle.changed")

    /// Boot: adopt the saved style before any surface is built. Checks never
    /// boot, so every `--*-check` sees `.standard` unless it sets a style.
    static func adoptSavedStyle(defaults: UserDefaults = .standard) {
        CornerStyle.current = CornerStyle.resolve(defaults.string(forKey: CornerStyle.defaultsKey))
    }

    /// Follow the setting: whenever Settings writes Corner style, re-render.
    /// The app installs this once at launch; the returned token keeps it alive.
    static func observeSetting(defaults: UserDefaults) -> NSObjectProtocol {
        // Read only on the main actor, where Settings writes it.
        nonisolated(unsafe) let defaults = defaults
        return NotificationCenter.default.addObserver(
            forName: SettingChangeEvent.name(for: SettingID(rawValue: CornerStyle.defaultsKey)),
            object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                _ = apply(CornerStyle.resolve(defaults.string(forKey: CornerStyle.defaultsKey)))
            }
        }
    }

    /// Switch the app to `style` and re-render every window. Returns how many
    /// views the walk reached — the positive control for a check asserting that
    /// something changed (or did not).
    @discardableResult
    static func apply(_ style: CornerStyle) -> Int {
        CornerStyle.current = style
        var visited = 0
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            visited += refresh(root)
            root.layoutSubtreeIfNeeded()
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return visited
    }

    /// Re-apply corners across `root`'s subtree.
    @discardableResult
    static func refresh(_ root: NSView) -> Int {
        var count = 1
        if let layer = root.layer { reapplyRememberedCorners(in: layer, skipping: root) }
        if let styled = root as? CornerStyled { styled.applyCornerStyle() }
        if let themed = root as? TokenThemed { themed.applyTokens() }
        root.needsLayout = true
        root.needsDisplay = true
        for subview in root.subviews { count += refresh(subview) }
        return count
    }

    /// The view's own layer and the sublayers it created (a subview's layer is
    /// visited with that subview).
    private static func reapplyRememberedCorners(in layer: CALayer, skipping view: NSView) {
        let subviewLayers = Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
        func visit(_ layer: CALayer) {
            layer.reapplyRememberedCorner()
            for sublayer in layer.sublayers ?? [] where !subviewLayers.contains(ObjectIdentifier(sublayer)) {
                visit(sublayer)
            }
        }
        visit(layer)
    }
}

extension CALayer {
    fileprivate static let cornerBaseKey = "array.corner.base"
    fileprivate static let cornerZoomKey = "array.corner.zoomPercent"

    /// Round this layer for `role` in the current corner style, at a page zoom.
    ///
    /// The layer remembers what it was asked for, so the corner-style walk can
    /// re-resolve it on its own: a view that rounds its layers through here
    /// needs no hook of its own to follow a live style change.
    func applyCorner(_ role: CornerRole, zoom: AgentPageZoom = .default) {
        applyCorner(base: role.base, zoom: zoom)
    }

    /// The same for a surface whose Default radius is `base`.
    func applyCorner(base: Double, zoom: AgentPageZoom = .default) {
        setValue(base, forKey: Self.cornerBaseKey)
        setValue(zoom.percent, forKey: Self.cornerZoomKey)
        cornerRadius = CGFloat(zoom.scaled(CornerStyle.current.radius(base)))
    }

    /// Re-resolve a corner set through `applyCorner` in the current style.
    fileprivate func reapplyRememberedCorner() {
        guard let base = value(forKey: Self.cornerBaseKey) as? Double else { return }
        let percent = value(forKey: Self.cornerZoomKey) as? Int ?? AgentPageZoom.default.percent
        cornerRadius = CGFloat(AgentPageZoom(percent: percent).scaled(CornerStyle.current.radius(base)))
    }

    /// A capsule in Default and Rounded (half the shorter side), square-cornered
    /// in Sharp. Call from `layout()`: it follows the layer's own bounds.
    func applyCapsule() {
        cornerRadius = CornerStyle.current == .sharp ? 0 : min(bounds.width, bounds.height) / 2
    }
}

extension CornerRole {
    /// This role's radius as a `CGFloat`, at a page zoom.
    func cgRadius(zoom: AgentPageZoom = .default) -> CGFloat { CGFloat(zoom.scaled(radius)) }
}

/// A rounded-rect path's corner radius, measured from the path itself.
///
/// For a corner of radius r, the point on the corner's diagonal at distance t
/// from the bounding box's corner is inside the shape exactly when
/// t ≥ r·(1 − 1/√2). A binary search on `contains` finds that t, so the radius
/// is read from geometry Core Animation will fill or stroke, never from a
/// number the drawing code also computed.
enum PathCornerRadius {
    static func measure(_ path: CGPath) -> CGFloat? {
        let box = path.boundingBoxOfPath
        guard box.width > 1, box.height > 1,
              path.contains(CGPoint(x: box.midX, y: box.midY)) else { return nil }
        let limit = min(box.width, box.height) / 2
        var low: CGFloat = 0, high = limit
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if path.contains(CGPoint(x: box.minX + mid, y: box.minY + mid)) { high = mid } else { low = mid }
        }
        let radius = high / (1 - 1 / sqrt(2))
        return min(radius, limit)
    }
}
