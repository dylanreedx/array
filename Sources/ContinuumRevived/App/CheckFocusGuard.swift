import AppKit
import ObjectiveC

/// A check run must never take Dylan's focus or his screen.
///
/// `orderFrontOffscreenForChecks()` fixed this once for the fixture windows that
/// adopted it, and every check written since had to remember to use it. They did
/// not: the after-launch legs boot the real `applicationDidFinishLaunching`, which
/// calls `makeKeyAndOrderFront` and `NSApp.activate(ignoringOtherApps: true)`, and
/// fixtures built from `makeWorkspaceWindow` order a titled window front at the
/// origin. Any of those makes a background test the frontmost app while Dylan is
/// typing somewhere else.
///
/// So the rule lives at one choke point instead of in every check. `install()`
/// runs first thing in `ContinuumApp.main()` for any QA run and, process-wide:
/// - makes app activation (`NSApplication.activate*`) a no-op, and refuses to
///   activate any OTHER app (`NSRunningApplication.activate*`);
/// - parks any window ordered in on a display far off every screen, the same
///   place `orderFrontOffscreenForChecks()` uses (child windows go transparent
///   in place instead — see `park`), and stops AppKit constraining a titled
///   window back onto a screen.
/// Rendering, layout, key-window bookkeeping and `NSApp.sendEvent` delivery are
/// unchanged, so checks keep exercising the real code.
///
/// Exempt: the display-dependent UI baseline legs (they compare on-screen pixels
/// and are skipped while Dylan works) and `CONTINUUM_QA_HOLD_OPEN=1`, where a
/// human has asked to watch.
///
/// Witness: `--checks-never-take-focus-check`.
@MainActor
enum CheckFocusGuard {
    static let parkedOrigin = CGPoint(x: -60_000, y: -60_000)

    /// Legs that deliberately present on a real display.
    static let displayDependentFlags: Set<String> = ["--ui-baseline-check", "--component-lab-check"]

    private(set) static var isInstalled = false
    /// Activation attempts the guard swallowed, in order (for diagnostics and the witness).
    private(set) static var blockedActivations: [String] = []
    /// Windows the guard kept off the user's displays as they were ordered in.
    private(set) static var parkedWindows = 0

    static func isQARun(arguments: [String] = CommandLine.arguments,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["CONTINUUM_QA_HOLD_OPEN"] == "1" { return false }
        if arguments.contains(where: displayDependentFlags.contains) { return false }
        if arguments.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("-check") }) { return true }
        return ["CONTINUUM_QA_FLOW", "CONTINUUM_QA_CAPTURE", "CONTINUUM_SMOKE_TEST"]
            .contains { environment[$0] != nil }
    }

    static func installIfQARun() {
        if isQARun() { install() }
    }

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        swap(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)),
             #selector(NSApplication.checkFocusGuard_activate(ignoringOtherApps:)))
        if #available(macOS 14.0, *) {
            swap(NSApplication.self, #selector(NSApplication.activate as (NSApplication) -> () -> Void),
                 #selector(NSApplication.checkFocusGuard_activateAll))
            swap(NSRunningApplication.self, #selector(NSRunningApplication.activate(from:options:)),
                 #selector(NSRunningApplication.checkFocusGuard_activate(from:options:)))
        }
        swap(NSRunningApplication.self, #selector(NSRunningApplication.activate(options:)),
             #selector(NSRunningApplication.checkFocusGuard_activate(options:)))
        swap(NSWindow.self, #selector(NSWindow.orderFront(_:)),
             #selector(NSWindow.checkFocusGuard_orderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFrontRegardless),
             #selector(NSWindow.checkFocusGuard_orderFrontRegardless))
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)),
             #selector(NSWindow.checkFocusGuard_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)),
             #selector(NSWindow.checkFocusGuard_order(_:relativeTo:)))
        swap(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:)),
             #selector(NSWindow.checkFocusGuard_constrainFrameRect(_:to:)))
    }

    static func recordBlockedActivation(_ what: String) {
        blockedActivations.append(what)
        if ProcessInfo.processInfo.environment["CONTINUUM_CHECK_FOCUS_TRACE"] == "1" {
            fputs("check-focus-guard: blocked \(what)\n", stderr)
        }
    }

    private static var keepsGeometry: Set<ObjectIdentifier> = []

    /// For a check that must measure placement against a REAL screen (screen-edge
    /// clamping): the guard leaves `window`'s frame alone and makes it transparent
    /// and click-through instead of moving it.
    static func keepScreenGeometry(_ window: NSWindow) {
        keepsGeometry.insert(ObjectIdentifier(window))
    }

    /// Keep `window` off the user's displays if any part of it would land on one.
    ///
    /// A top-level window moves far off every display. A CHILD window (a
    /// `ChoicePanel` dropdown, a completion panel) keeps its frame and goes
    /// transparent and click-through instead: it places itself against its
    /// anchor and clamps to a screen, and checks assert exactly that geometry.
    /// So does a window passed to `keepScreenGeometry`.
    static func park(_ window: NSWindow) {
        let frame = window.frame
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        if window.parent != nil || keepsGeometry.contains(ObjectIdentifier(window)) {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        } else {
            window.setFrameOrigin(parkedOrigin)
        }
        parkedWindows += 1
        if ProcessInfo.processInfo.environment["CONTINUUM_CHECK_FOCUS_TRACE"] == "1" {
            fputs("check-focus-guard: parked\(window.parent == nil ? "" : " (child, transparent)") \(type(of: window)) \"\(window.title)\" from \(frame)\n", stderr)
        }
    }

    private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(cls, original),
              let b = class_getInstanceMethod(cls, replacement) else {
            fatalError("CheckFocusGuard: cannot swizzle \(cls).\(original)")
        }
        method_exchangeImplementations(a, b)
    }
}

// After `install()` each `checkFocusGuard_*` name points at the ORIGINAL
// implementation, so calling it from inside the replacement calls through.

extension NSApplication {
    @objc dynamic func checkFocusGuard_activate(ignoringOtherApps flag: Bool) {
        MainActor.assumeIsolated { CheckFocusGuard.recordBlockedActivation("NSApp.activate(ignoringOtherApps:)") }
    }

    @objc dynamic func checkFocusGuard_activateAll() {
        MainActor.assumeIsolated { CheckFocusGuard.recordBlockedActivation("NSApp.activate()") }
    }
}

extension NSRunningApplication {
    @objc dynamic func checkFocusGuard_activate(options: NSApplication.ActivationOptions = []) -> Bool {
        let name = localizedName ?? bundleIdentifier ?? "pid \(processIdentifier)"
        MainActor.assumeIsolated { CheckFocusGuard.recordBlockedActivation("activate \(name)") }
        return false
    }

    @objc dynamic func checkFocusGuard_activate(from application: NSRunningApplication,
                                                options: NSApplication.ActivationOptions = []) -> Bool {
        let name = localizedName ?? bundleIdentifier ?? "pid \(processIdentifier)"
        MainActor.assumeIsolated { CheckFocusGuard.recordBlockedActivation("activate \(name)") }
        return false
    }
}

extension NSWindow {
    @objc dynamic func checkFocusGuard_orderFront(_ sender: Any?) {
        MainActor.assumeIsolated { CheckFocusGuard.park(self) }
        checkFocusGuard_orderFront(sender)
    }

    @objc dynamic func checkFocusGuard_orderFrontRegardless() {
        MainActor.assumeIsolated { CheckFocusGuard.park(self) }
        checkFocusGuard_orderFrontRegardless()
    }

    @objc dynamic func checkFocusGuard_makeKeyAndOrderFront(_ sender: Any?) {
        MainActor.assumeIsolated { CheckFocusGuard.park(self) }
        checkFocusGuard_makeKeyAndOrderFront(sender)
    }

    @objc dynamic func checkFocusGuard_order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { MainActor.assumeIsolated { CheckFocusGuard.park(self) } }
        checkFocusGuard_order(place, relativeTo: otherWin)
    }

    @objc dynamic func checkFocusGuard_constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
