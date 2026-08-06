import ContinuumRevivedAgentUI
import Foundation

public enum WorkspaceSidebarConfig {
    public static let visibleKey = "continuum.workspaceSidebar.visible"
    public static let widthKey = "continuum.workspaceSidebar.width"
    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    public static let scopeKey = "continuum.workspaceSidebar.scope"

    public static let defaultVisible = true
    public static let defaultWidth: Double = 280
    public static let minWidth: Double = 220
    public static let maxWidth: Double = 420
    /// The detail pane must retain this floor while the sidebar grows.
    public static let contentMinimumWidth: Double = 640
    /// AppKit's thin divider consumes part of the window, so it is included by
    /// the view owner when deriving the available content width.

    public static func resolveVisible(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: visibleKey) != nil else { return defaultVisible }
        return defaults.bool(forKey: visibleKey)
    }

    public static func setVisible(_ visible: Bool, defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: visibleKey)
    }

    public static func resolveWidth(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: widthKey) != nil else { return defaultWidth }
        if let stringValue = defaults.string(forKey: widthKey),
           let width = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return clampedWidth(width)
        }
        return clampedWidth(defaults.double(forKey: widthKey))
    }

    public static func setWidth(_ width: Double, defaults: UserDefaults = .standard) {
        // Persistence has no window context. Never resurrect the old 420 pt
        // ceiling here; the live split view applies its computed growth veto.
        defaults.set(clampedWidth(width), forKey: widthKey)
    }

    public static func maximumWidth(forWindowWidth windowWidth: Double, dividerThickness: Double = 0) -> Double {
        max(minWidth, floor(windowWidth) - contentMinimumWidth - dividerThickness)
    }

    /// Shrinking is always accepted, including when the current width is over
    /// a newly-derived ceiling. Only growth is vetoed by the content floor.
    public static func constrainedWidth(proposed: Double, current: Double, windowWidth: Double, dividerThickness: Double = 0) -> Double {
        let candidate = max(minWidth, proposed)
        guard candidate > current else { return candidate }
        let maximum = maximumWidth(
            forWindowWidth: windowWidth, dividerThickness: dividerThickness)
        // If a window resize put the current divider beyond the new ceiling, a
        // growth gesture is vetoed in place. Never snap backward to the ceiling;
        // any later proposed shrink remains free to follow the pointer.
        guard current < maximum else { return current }
        return min(candidate, maximum)
    }

    public static func clampedWidth(_ width: Double) -> Double {
        max(minWidth, width)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
    /// The inbox scope the sidebar was last left on.
    ///
    /// The same key/default/clamp shape as the two above, where "clamp" for a scope
    /// is: anything this version cannot decode reads as `defaultScope`. A scope is
    /// the one setting here that can HIDE rows, so an unreadable value must open the
    /// list up rather than narrow it — never fail closed on a filter.
    ///
    /// Storing the NAME rather than a project id is deliberate and follows the row:
    /// `AgentInboxRow` carries names (it is the shared, Core-free vocabulary), so an
    /// id here would have to be resolved back to a name on every filter.
    ///
    /// THE COST, stated accurately (the first version of this comment claimed a
    /// fallback that does not happen, and cross-review was right to call it): renaming
    /// or removing the scoped project does NOT reset this to `.all`. The old name
    /// decodes fine, `InboxScope.entries` keeps it in the menu as the selected entry
    /// (see the reasoning there), and the inbox opens on an empty list that says "No
    /// agents in this scope" with that stale name showing in the popup. That is one
    /// click from fixed and never hides an agent silently, which is the property worth
    /// protecting; the alternative — dropping a scope the moment no row matches it —
    /// would also drop it at launch, before the first push has arrived.
    public static let defaultScope = InboxScope.all

    public static func resolveScope(defaults: UserDefaults = .standard) -> InboxScope {
        guard let raw = defaults.string(forKey: scopeKey),
              let scope = InboxScope(storageValue: raw) else { return defaultScope }
        return scope
    }

    public static func setScope(_ scope: InboxScope, defaults: UserDefaults = .standard) {
        defaults.set(scope.storageValue, forKey: scopeKey)
    }
}
