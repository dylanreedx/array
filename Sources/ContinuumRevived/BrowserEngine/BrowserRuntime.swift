import AppKit
import ContinuumRevivedCore
import Foundation

typealias BrowserRuntimeID = UUID

enum BrowserLoadingState: Equatable {
    case idle
    case loading(progress: Double)
    case failed(message: String)
}

enum BrowserFindDirection: Equatable {
    case forward
    case backward
}

@MainActor
protocol BrowserRuntime: AnyObject {
    var id: BrowserRuntimeID { get }
    var tileId: TileID { get }
    var url: String { get }
    var title: String { get }
    var faviconURL: String? { get }
    var loadingState: BrowserLoadingState { get }

    var onStateChange: (() -> Void)? { get set }

    /// Fires after a `find(_:direction:)` completes with the WebKit result's
    /// `matchFound`. `true` = at least one match; `false` = none. WebKit's public
    /// `WKFindResult` exposes only `matchFound` (no count), so an "N of M" total
    /// is not available here — see `WKWebViewBrowserRuntime.find`.
    var onFindResult: ((Bool) -> Void)? { get set }

    func attach(to hostView: BrowserHostView)
    func detach()
    func loadURL(_ urlString: String)
    func goBack()
    func goForward()
    func reload()
    func stop()
    var capturedInteractionState: Data? { get }
    func restoreInteractionState(_ data: Data)
    func find(_ query: String, direction: BrowserFindDirection)
    func focus()
    func blur()
    func isSemanticContentResponder(_ responder: NSResponder?) -> Bool
    func terminate(policy: TerminationPolicy)
}

final class BrowserHostView: NSView {
    private let rippleOverlay = BrowserRippleOverlay()
    private(set) var qaAgentRippleCount = 0
    private(set) var qaLastAgentRipplePoint: NSPoint?

    func showAgentRipple(at point: NSPoint, colour: NSColor) {
        guard bounds.contains(point) else { return }
        if rippleOverlay.superview == nil {
            rippleOverlay.frame = bounds
            rippleOverlay.autoresizingMask = [.width, .height]
            addSubview(rippleOverlay, positioned: .above, relativeTo: nil)
        }
        qaAgentRippleCount += 1
        qaLastAgentRipplePoint = point
        rippleOverlay.show(at: point, colour: colour)
    }
    private weak var runtime: BrowserRuntime?
    var reservedShortcutHandler: ((NSEvent) -> Bool)?
    var browserFindShortcutHandler: (() -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attach(runtime: BrowserRuntime) {
        self.runtime = runtime
        runtime.attach(to: self)
    }

    func detachRuntime() {
        runtime?.detach()
        runtime = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 3, flags == .command, browserFindShortcutHandler?() == true {
            return true
        }
        if reservedShortcutHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One non-interactive overlay per browser host. Short-lived layers mark
/// agent clicks without intercepting the user's pointer or keyboard.
private final class BrowserRippleOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(at point: NSPoint, colour: NSColor) {
        guard let layer else { return }
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        ring.position = point
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = colour.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer.addSublayer(ring)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6
        scale.toValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.6 : 2.0
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = 0.55
        ring.add(group, forKey: "agent-click")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak ring] in ring?.removeFromSuperlayer() }
    }
}
