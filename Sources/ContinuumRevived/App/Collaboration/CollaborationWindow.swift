import AppKit

/// A UI ownership boundary, independent of the personal canvas's armed project.
/// Sheets inherit their parent's scope. No project/API resolver reads this role.
@MainActor
final class CollaborationWindow: NSWindow {
    private static let mountedWindows = NSHashTable<NSWindow>.weakObjects()

    static func mark(_ window: NSWindow) { mountedWindows.add(window) }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if Self.isIsolatedCheck { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    private static var isIsolatedCheck: Bool {
        ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil
            && CommandLine.arguments.contains(where: { $0.hasSuffix("-check") })
    }

    static func present(_ window: NSWindow) {
        if isIsolatedCheck {
            window.orderFrontOffscreenForChecks()
            window.makeKey()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func owns(_ window: NSWindow?) -> Bool {
        var current = window
        while let candidate = current {
            if candidate is CollaborationWindow || mountedWindows.contains(candidate) { return true }
            current = candidate.sheetParent ?? candidate.parent
        }
        return false
    }
}
