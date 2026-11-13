import AppKit
import Foundation
import ObjectiveC

/// `--markdown-frame-observer-check`. With visible-rows Markdown on, does a frame
/// change anywhere in the window pay for the text views in rows that are built
/// but not attached?
///
/// AppKit registers every `NSTextView` whose superview is not a clip view as an
/// observer of frame changes from ANY view, when it is added to that superview.
/// A visible-rows document builds every row and attaches only the ones near the
/// clip, so most of its text views join a superview outside any window and stay
/// registered. On screen that made `-[NSView _postFrameChangeNotification]` 69% of
/// the main thread during zoom.
///
/// The scene is the motion workload's (`CanvasMotionWorkload`, production boot
/// mount, 24 Markdown + 8 agents) with the switch on from boot, as
/// `-markdownVisibleRows YES` runs it. It times one unrelated frame change at rest
/// and after a production zoom, and counts any-view frame registrations the zoom
/// makes. The positive control prices one stock text view outside a window on
/// this machine, so the bar does not depend on the Mac.
@MainActor
enum MarkdownFrameObserverChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    nonisolated(unsafe) static var counting = false
    nonisolated(unsafe) static var anyViewFrameRegistrations: [String: Int] = [:]

    /// Counts `addObserver:selector:name:object:` calls for frame changes from any view.
    static func installRegistrationCounter() {
        typealias AddIMP = @convention(c) (AnyObject, Selector, AnyObject, Selector, NSString?, AnyObject?) -> Void
        let selector = #selector(NotificationCenter.addObserver(_:selector:name:object:))
        guard let method = class_getInstanceMethod(NotificationCenter.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: AddIMP.self)
        let frameName = NSView.frameDidChangeNotification.rawValue as NSString
        let block: @convention(block) (AnyObject, AnyObject, Selector, NSString?, AnyObject?) -> Void = { center, observer, action, name, object in
            if counting, object == nil, let name, name.isEqual(to: frameName as String) {
                anyViewFrameRegistrations[String(describing: type(of: observer)), default: 0] += 1
            }
            original(center, selector, observer, action, name, object)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Text views outside a clip view, under `root`, attached or not.
    static func unclippedTextViews(under roots: [NSView]) -> [NSTextView] {
        var found: [NSTextView] = []
        func walk(_ view: NSView) {
            if let text = view as? NSTextView, !(text.superview is NSClipView) { found.append(text) }
            view.subviews.forEach(walk)
        }
        roots.forEach(walk)
        return found
    }

    /// Mean microseconds for one frame change of a view nothing observes.
    static func frameChangeMicroseconds(_ probe: NSView, changes: Int = 2_000) -> Double {
        _ = (0..<200).map { probe.setFrameSize(NSSize(width: 10 + CGFloat($0 % 7), height: 10)) }
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<changes { probe.setFrameSize(NSSize(width: 10 + CGFloat(index % 7), height: 10)) }
        return (ProcessInfo.processInfo.systemUptime - start) / Double(changes) * 1e6
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["CONTINUUM_PROJECT_ROOT"], let supportPath = env["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "requires isolated CONTINUUM_PROJECT_ROOT and CONTINUUM_APP_SUPPORT")
        }
        installRegistrationCounter()
        MarkdownVisibleRowsConfig.qaOverride = true
        defer { MarkdownVisibleRowsConfig.qaOverride = nil }
        let fixture = try CanvasMotionWorkload(root: URL(fileURLWithPath: rootPath),
            support: URL(fileURLWithPath: supportPath), markdownCount: 24, agentCount: 8, offscreen: true)
        defer { fixture.close() }
        let canvas = fixture.canvas
        await CanvasZoomStepCostChecks.spin(3)
        guard let content = fixture.window.contentView else { throw Failure(description: "scene window has no content view") }

        let documents = CanvasZoomStepCostChecks.markdownDocuments(in: canvas)
        guard documents.count >= 4, documents.allSatisfy(\.virtualizesRows) else {
            throw Failure(description: "positive control: expected visible-rows Markdown documents, found \(documents.count)")
        }
        let rowTextViews = unclippedTextViews(under: documents.flatMap(\.qaRowViews))
        let detached = rowTextViews.filter { $0.window == nil }
        guard detached.count >= 100 else {
            throw Failure(description: "positive control: expected the scene's unattached Markdown rows to hold text views, found \(detached.count)")
        }
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        content.addSubview(probe)
        let rest = frameChangeMicroseconds(probe)

        counting = true
        _ = await CanvasZoomStepCostChecks.measure(canvas, posts: 48) { ($0 / 8) % 2 == 0 ? 1.03 : 1 / 1.03 }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while canvas.isCameraInMotion, ProcessInfo.processInfo.systemUptime < deadline { await CanvasZoomStepCostChecks.spin(0.05) }
        await CanvasZoomStepCostChecks.spin(0.5)
        counting = false
        let afterZoom = frameChangeMicroseconds(probe)
        let zoomRegistrations = anyViewFrameRegistrations.values.reduce(0, +)
        let zoomRegistrars = anyViewFrameRegistrations

        // Positive control: stock text views in a container outside any window.
        let controlCount = 300
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let stock = (0..<controlCount).map { _ in NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)) }
        anyViewFrameRegistrations = [:]
        counting = true
        stock.forEach(host.addSubview)
        counting = false
        let controlRegistrations = anyViewFrameRegistrations["NSTextView", default: 0]
        let withControl = frameChangeMicroseconds(probe)
        stock.forEach { NotificationCenter.default.removeObserver($0) }
        let perStockView = (withControl - afterZoom) / Double(controlCount)
        let unfixedEstimate = perStockView * Double(detached.count)
        let f = { (value: Double) in String(format: "%.2f", value) }
        print("[markdown-frame-observer] documents=\(documents.count) rowTextViews=\(rowTextViews.count) unattached=\(detached.count) "
              + "restUs=\(f(rest)) afterZoomUs=\(f(afterZoom)) withControlUs=\(f(withControl)) perStockViewUs=\(f(perStockView)) "
              + "unfixedEstimateUs=\(f(unfixedEstimate)) zoomAnyFrameRegistrations=\(zoomRegistrations) controlRegistrations=\(controlRegistrations)")

        guard controlRegistrations == controlCount else {
            throw Failure(description: "positive control: adding \(controlCount) stock text views counted \(controlRegistrations) any-view frame registrations; the counter cannot see AppKit's")
        }
        guard perStockView > 0.02 else {
            throw Failure(description: "positive control: \(controlCount) stock text views added only \(f(withControl - afterZoom)) µs per frame change; the measurement cannot see the observer")
        }
        guard rest < unfixedEstimate / 4 else {
            throw Failure(description: "one unrelated frame change costs \(f(rest)) µs at rest with \(detached.count) unattached Markdown text views; unobserved they add almost nothing, observed they add about \(f(unfixedEstimate)) µs")
        }
        guard zoomRegistrations == 0, afterZoom < unfixedEstimate / 4 else {
            throw Failure(description: "the zoom made \(zoomRegistrations) any-view frame registrations \(zoomRegistrars) and a frame change costs \(f(afterZoom)) µs after it")
        }
    }
}
