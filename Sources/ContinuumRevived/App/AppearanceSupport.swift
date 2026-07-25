import AppKit

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
//
// AppKit trap: `NSColor.windowBackgroundColor.cgColor` does NOT resolve against
// the view's (or the app's) appearance — it resolves against
// `NSAppearance.current`, which outside a draw cycle is the SYSTEM appearance.
// So on a light-mode Mac, every layer background assigned this way came out
// light while NSTextField colors (resolved by AppKit at draw time) came out
// correct — producing white-on-white chrome once the app pinned dark.
//
// Always route dynamic colors through here when assigning to a CALayer.
extension NSColor {
    /// This color resolved in the app's effective appearance, safe for CALayer.
    var appResolvedCGColor: CGColor {
        var resolved = cgColor
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.cgColor
        }
        return resolved
    }
}
