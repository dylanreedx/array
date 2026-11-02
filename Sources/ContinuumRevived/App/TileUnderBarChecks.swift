import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The tile under-bar, reached by the matrix's existing --tile-chrome-scale-check.
///
/// The title bar grows in world units at low zoom (floored to `minScreenGrabPx`
/// on screen) and draws at `chromeScale`. The row under it — the live
/// collaboration indicator, the agent's branch and managed pills — must be the
/// same scaling unit: it sits BELOW the bar at every zoom (never under it, where
/// the bar clipped it), and its laid-out height keeps a fixed ratio to the bar's.
/// Reads laid-out frames in the tile's world space, and writes stills of the
/// tile's top in light and dark at each zoom.
@MainActor
enum TileUnderBarChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let zooms: [Double] = [0.35, 0.6, 1.0, 1.6]

    static func run(in directory: URL) throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: "under-bar: " + message) }
        }
        let colour = NSColor.systemPurple
        func tile(_ kind: TileKind, x: Double) -> Tile {
            Tile(id: UUID(), kind: kind, title: "Under-bar \(kind.rawValue)",
                 frame: TileFrame(x: x, y: 20, width: 420, height: 600),
                 zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        }
        let terminalShared = tile(.terminal, x: 20)
        let terminalPlain = tile(.terminal, x: 460)
        let agentShared = tile(.managedAgent, x: 900)
        let agentPlain = tile(.managedAgent, x: 1340)
        let browserShared = tile(.browser, x: 1780)
        // Dylan's 0.7.39 screenshot: a shared agent at the default width with
        // a branch, Managed and Complete, its pills cut off under the bar.
        let agentFull = Tile(id: UUID(), kind: .managedAgent, title: "Pioneer Lead Orchestrator 0.7.40",
                             frame: TileFrame(x: 20, y: 660, width: 640, height: 520),
                             zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tiles = [terminalShared, terminalPlain, agentShared, agentPlain, browserShared, agentFull]
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: tiles, groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 3600, height: 2000)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        var views: [(name: String, view: TileNSView, shared: Bool, pills: Bool)] = []
        for (name, model, shared) in [("terminal-shared", terminalShared, true), ("terminal-plain", terminalPlain, false),
                                      ("browser-shared", browserShared, true)] {
            let view = TileNSView(tile: model)
            view.setContentView(NSView(frame: .zero))
            canvas.install(tileView: view, for: model)
            if shared { view.setOwnershipMark(.init(text: "Yours · shared with Sam", colour: colour, outlined: false)) }
            views.append((name, view, shared, false))
        }
        for (name, model, shared) in [("agent-shared", agentShared, true), ("agent-plain", agentPlain, false)] {
            let view = ManagedAgentTileNSView(tile: model)
            canvas.install(tileView: view, for: model)
            view.qaPageZoomHeaderView.showsManaged = true
            if shared { view.setOwnershipMark(.init(text: "Yours · shared with Sam", colour: colour, outlined: false)) }
            views.append((name, view, shared, true))
        }
        let full = ManagedAgentTileNSView(tile: agentFull)
        canvas.install(tileView: full, for: agentFull)
        full.applyBranchContext(AgentRowContext(agentKind: .managed, checkedOutBranch: "array/integration"))
        full.applyAwarenessSignal(AgentSignal(id: "under-bar-complete", kind: .completed, agentID: nil, tileID: agentFull.id,
                                              threadID: nil, occurredAt: Date(), source: .managedRuntime))
        // After the branch: applying it re-derives Managed from the (absent) record.
        full.qaPageZoomHeaderView.showsManaged = true
        full.setOwnershipMark(.init(text: "Yours · shared with Sam", colour: colour, outlined: false))
        views.append(("agent-full", full, true, false))
        // A shared terminal's Live badge rides the same row, at its right.
        let badge = SharedTerminalLiveBadge(frame: .zero)
        views[0].view.installLiveBadge(badge)

        var rows: [[String: Any]] = []
        var ratios: [String: [Double]] = [:]
        var pillRatios: [String: [Double]] = [:]
        var screen: [String: [Double]] = [:]
        var contentTops: [String: Set<Int>] = [:]
        for zoom in zooms {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
            for entry in views {
                let view = entry.view
                view.layoutSubtreeIfNeeded()
                let bar = view.qaTitleBarFrame
                let under = view.qaUnderBarFrame
                let indicator = view.qaLiveIndicatorFrame
                var row: [String: Any] = ["tile": entry.name, "zoom": zoom, "bar": NSStringFromRect(bar)]
                contentTops[entry.name, default: []].insert(Int(((view.contentView?.frame.minY ?? -1) * 100).rounded()))
                if entry.shared {
                    guard let indicator else { throw Failure(description: "under-bar: \(entry.name) zoom \(zoom): shared tile has no live indicator (under-bar \(String(describing: under)), tile \(view.bounds))") }
                    guard let under else { throw Failure(description: "under-bar: \(entry.name) zoom \(zoom): shared tile has no under-bar") }
                    row["underBar"] = NSStringFromRect(under); row["indicator"] = NSStringFromRect(indicator)
                    try expect(under.minY >= bar.maxY - 0.5,
                               "\(entry.name) zoom \(zoom): under-bar top \(under.minY) sits under the title bar (bottom \(bar.maxY))")
                    try expect(under.insetBy(dx: -0.5, dy: -0.5).contains(indicator),
                               "\(entry.name) zoom \(zoom): indicator \(indicator) is outside the under-bar \(under)")
                    try expect(!indicator.intersects(bar),
                               "\(entry.name) zoom \(zoom): indicator \(indicator) clips the title bar \(bar)")
                    try expect(indicator.minX < under.minX + under.width * 0.25,
                               "\(entry.name) zoom \(zoom): indicator \(indicator) is not at the under-bar's far left")
                    // agent-full's row is held to its pills' width instead (below).
                    if entry.name != "agent-full" {
                        ratios[entry.name, default: []].append(Double(under.height / bar.height))
                        screen[entry.name, default: []].append(Double(under.height) * zoom)
                    }
                } else {
                    try expect(indicator == nil, "\(entry.name) zoom \(zoom): an unshared tile shows a live indicator")
                }
                if entry.pills, let agent = view as? ManagedAgentTileNSView {
                    let header = agent.qaPageZoomHeaderView
                    guard let local = header.qaManagedFrame else {
                        throw Failure(description: "under-bar: \(entry.name) zoom \(zoom): managed pill is hidden")
                    }
                    // The tile may be resting: its pills are then drawn, and the
                    // views behind the picture are in the hidden resting host.
                    guard let pill = view.qaUnderBarRect(local, in: header) else {
                        throw Failure(description: "under-bar: \(entry.name) zoom \(zoom): the pills are not on the under-bar")
                    }
                    row["managed"] = NSStringFromRect(pill)
                    try expect(!pill.intersects(bar), "\(entry.name) zoom \(zoom): managed pill \(pill) clips the title bar \(bar)")
                    if let under { try expect(under.insetBy(dx: -0.5, dy: -0.5).contains(pill),
                                              "\(entry.name) zoom \(zoom): managed pill \(pill) is outside the under-bar \(under)") }
                    try expect(pill.maxX <= view.bounds.width - 1,
                               "\(entry.name) zoom \(zoom): managed pill \(pill) runs past the tile's edge \(view.bounds.width)")
                    if let indicator { try expect(!indicator.intersects(pill),
                                                  "\(entry.name) zoom \(zoom): indicator \(indicator) overlaps the managed pill \(pill)") }
                    pillRatios[entry.name, default: []].append(Double(pill.height / bar.height))
                    screen[entry.name + ":managed", default: []].append(Double(pill.height) * zoom)
                }
                if entry.name == "agent-full", let agent = view as? ManagedAgentTileNSView, let under {
                    // Every pill whole: shown, inside the row and the tile, below
                    // the bar, and clear of each other and of the indicator.
                    let header = agent.qaPageZoomHeaderView
                    let status = header.subviews.flatMap(\.subviews).compactMap { $0 as? AgentSignalBadgeView }.first
                    let locals: [(String, NSRect?, NSView)] = [
                        ("branch", header.qaBranch == nil ? nil : header.qaBranchFrame, header),
                        ("managed", header.qaManagedFrame, header),
                        ("status", status.flatMap { $0.isHidden ? nil : $0.bounds }, status ?? header),
                    ]
                    var pills: [(String, NSRect)] = []
                    for (name, local, owner) in locals {
                        guard let local, let rect = view.qaUnderBarRect(local, in: owner) else {
                            throw Failure(description: "under-bar: agent-full zoom \(zoom): the \(name) pill is not shown (header \(header.frame) whole \(header.minimumWholeWidth), row \(String(describing: under)))")
                        }
                        row[name] = NSStringFromRect(rect)
                        try expect(!rect.intersects(bar), "agent-full zoom \(zoom): \(name) pill \(rect) clips the title bar \(bar)")
                        try expect(under.insetBy(dx: -0.5, dy: -0.5).contains(rect),
                                   "agent-full zoom \(zoom): \(name) pill \(rect) is outside the under-bar \(under)")
                        try expect(rect.minX >= 0 && rect.maxX <= view.bounds.width - 1,
                                   "agent-full zoom \(zoom): \(name) pill \(rect) runs past the tile's edge")
                        if let indicator { try expect(!indicator.intersects(rect),
                                                      "agent-full zoom \(zoom): indicator overlaps the \(name) pill") }
                        for (other, frame) in pills {
                            try expect(!frame.intersects(rect), "agent-full zoom \(zoom): \(name) pill overlaps \(other)")
                        }
                        pills.append((name, rect))
                    }
                    // Never smaller on screen than the camera alone would make it.
                    try expect(under.height * CGFloat(zoom) >= view.underBarWorldHeight * CGFloat(zoom) - 0.5,
                               "agent-full zoom \(zoom): the row shrank faster than the camera")
                }
                if entry.name == "terminal-shared" {
                    let frame = badge.convert(badge.bounds, to: view)
                    row["liveBadge"] = NSStringFromRect(frame)
                    try expect(!frame.intersects(bar), "terminal zoom \(zoom): Live badge \(frame) clips the title bar \(bar)")
                    if let under { try expect(under.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                              "terminal zoom \(zoom): Live badge \(frame) is outside the under-bar \(under)") }
                    if let indicator { try expect(!indicator.intersects(frame),
                                                  "terminal zoom \(zoom): indicator overlaps the Live badge") }
                }
                rows.append(row)
            }
            try writeStills(canvas: canvas, window: window, views: views.map { ($0.name, $0.view) }, zoom: zoom, to: directory)
        }
        // One scaling unit: the row's height keeps the bar's ratio (zooms in
        // order 0.35, 0.6, 1.0, 1.6). At 0.35 a 420-wide row is capped by its
        // width so Stop sharing still fits: there it may only fall below the
        // ratio, and must still hold well over half its 100% screen size — before, it
        // shrank with the camera to 35%.
        for (name, values) in ratios.merging(pillRatios.mapKeys { $0 + ":managed" }, uniquingKeysWith: { $0 + $1 }) {
            guard values.count == zooms.count else { continue }
            let scaled = values.dropFirst()
            guard let low = scaled.min(), let high = scaled.max(), low > 0 else { continue }
            // A pill inside the row is pixel-snapped by Auto Layout in the row's
            // scaled space, which moves it by up to a point either way.
            let tolerance = name.hasSuffix(":managed") ? 1.05 : 1.01
            try expect(high / low < tolerance, "\(name): height / title-bar height varies with zoom \(values) — it does not scale with the bar")
            try expect(values[0] <= high * tolerance, "\(name): at 0.35 the row outgrew the bar's ratio \(values)")
        }
        for (name, values) in screen where values.count == zooms.count {
            // 0.6: a 420-wide tile is 147 px wide at 0.35, so the row trades
            // some height to keep every pill whole; the old row kept 0.35.
            try expect(values[0] >= values[2] * 0.6,
                       "\(name): on-screen height at 0.35 is \(values[0]) against \(values[2]) at 1.0 — it shrinks with the camera")
        }
        // The body never reflows with the camera.
        for (name, tops) in contentTops {
            try expect(tops.count == 1, "\(name): content top moves with zoom \(tops.sorted())")
        }
        try expect(views[1].view.contentView?.frame.minY == TileNSView.titleBarHeight,
                   "an unshared terminal's body must start right under the title bar")

        let manifest: [String: Any] = ["check": "tile-under-bar", "zooms": zooms, "rows": rows,
                                       "ratios": ratios, "pillRatios": pillRatios, "screenHeights": screen]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("under-bar.json"), options: .atomic)
    }

    /// The top 160 screen points of each tile, light and dark.
    private static func writeStills(canvas: CanvasNSView, window: NSWindow, views: [(String, TileNSView)], zoom: Double, to directory: URL) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            for (label, view) in views {
                let full = view.convert(view.bounds, to: canvas)
                let rect = NSRect(x: full.minX - 4, y: canvas.isFlipped ? full.minY - 4 : full.maxY - 156,
                                  width: full.width + 8, height: min(full.height + 8, 160)).integral
                guard let rep = canvas.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                canvas.cacheDisplay(in: rect, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = "\(label)-\(zoom)-\(appearance == .aqua ? "light" : "dark").png"
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
