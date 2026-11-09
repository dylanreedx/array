import AppKit
import ContinuumRevivedCore

/// `--undo-toast-placement-check` (`.plans/auto-layout-night`). The undo toast a
/// Tidy shows must never sit under the floating toolbar or the shortcut rail,
/// whichever edge the bar rests on. Drives the PRODUCTION window
/// (`makeWorkspaceWindow`, borderless and offscreen) with the real toolbar
/// (opted in, on an isolated defaults suite) and the real rail, shows the toast
/// through a real Tidy, and compares the views' frames. Also: the bar dragged
/// to another edge while the toast shows, and a narrow window. Writes light and
/// dark renders when given a directory.
@MainActor
enum UndoToastPlacementChecks {
    typealias Fixture = WorkspaceInvariantsFixture
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws {
        let args = CommandLine.arguments
        let renderDir = args.firstIndex(of: "--undo-toast-placement-check").flatMap { i in
            args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? URL(fileURLWithPath: args[i + 1]) : nil
        }
        setenv("CONTINUUM_TOOLBAR_QA", "1", 1)
        let suite = "undo-toast-placement.\(UUID().uuidString)"
        guard let toolbarDefaults = QAIsolatedDefaults(isolatedSuiteName: suite) else {
            throw Failure(description: "could not create the isolated toolbar defaults")
        }
        defer { toolbarDefaults.removePersistentDomain(forName: suite) }

        let fixture = try Fixture(label: "undo-toast")
        defer { fixture.dispose() }
        _ = try AutoLayoutFanoutChecks.reseed(fixture, zoneSize: ZoneSize(width: 2_600, height: 1_800), tiles: [
            ("NoteA", TileFrame(x: 40, y: 90, width: 700, height: 420)),
            ("NoteB", TileFrame(x: 1_100, y: 60, width: 640, height: 520)),
            ("NoteC", TileFrame(x: 80, y: 1_000, width: 560, height: 480)),
            ("NoteD", TileFrame(x: 1_800, y: 1_050, width: 600, height: 500)),
        ])
        try fixture.mount()
        let m = try fixture.requireMounted("undo toast")
        let canvas = m.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: false)
        m.delegate.floatingToolbarDefaults = toolbarDefaults
        let window = m.delegate.makeWorkspaceWindow(canvasView: canvas, title: "Array")
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        guard let toolbar = m.delegate.qaFloatingToolbar, let rail = m.delegate.qaCanvasShortcutRailView,
              let root = window.contentView else {
            throw Failure(description: "the production window mounted no floating toolbar or shortcut rail")
        }
        toolbar.reduceMotion = { true }

        var failures: [String] = []
        var report: [String] = []
        func settle() {
            root.layoutSubtreeIfNeeded()
            canvas.layoutSubtreeIfNeeded()
        }
        /// A Tidy that changes something, so it offers its undo toast: press the
        /// last toast's Undo first (the zone is tidy after the first Tidy).
        func tidyShowingToast() {
            if canvas.qaAutoLayoutUndoToastFrame != nil { canvas.qaClickAutoLayoutUndo() }
            canvas.tidyAutoLayout(zoneId: Fixture.zoneA1)
            settle()
        }
        func checkClear(_ label: String) {
            settle()
            guard let toast = canvas.qaAutoLayoutUndoToastFrame else {
                failures.append("\(label): the tidy showed no undo toast")
                return
            }
            let toastRect = canvas.convert(toast, to: root)
            let bar = toolbar.toolbar.convert(toolbar.toolbar.bounds, to: root)
            let railRect = rail.convert(rail.bounds, to: root)
            let canvasRect = canvas.convert(canvas.bounds, to: root)
            report.append("  \(label): toast \(toastRect.integral) bar \(bar.integral) rail \(railRect.integral)")
            if toastRect.intersects(bar) { failures.append("\(label): the toast \(toastRect) is under the toolbar \(bar)") }
            if toastRect.intersects(railRect) { failures.append("\(label): the toast \(toastRect) overlaps the shortcut rail \(railRect)") }
            if !canvasRect.contains(toastRect) { failures.append("\(label): the toast \(toastRect) leaves the canvas \(canvasRect)") }
            // It hugs its message: never stretched across the canvas, never cut short.
            if let fitting = canvas.qaAutoLayoutUndoToastFittingWidth, abs(toastRect.width - fitting) > 1 {
                failures.append("\(label): the toast is \(toastRect.width) wide, its content \(fitting)")
            }
        }
        func rest(on edge: FloatingToolbarEdge) {
            toolbarDefaults.set(edge.rawValue, forKey: FloatingToolbarConfig.positionEdgeKey)
            toolbar.refreshSettings()
            settle()
        }

        // Every edge the bar can rest on, the toast shown after it landed.
        for edge in [FloatingToolbarEdge.bottom, .top, .left, .right] {
            rest(on: edge)
            if toolbar.edge != edge { failures.append("setup: the bar did not rest on the \(edge) edge") }
            tidyShowingToast()
            checkClear("bar on \(edge)")
        }

        // The bar dragged onto the bottom edge while the toast shows.
        rest(on: .top)
        tidyShowingToast()
        let start = NSPoint(x: toolbar.toolbar.frame.midX, y: toolbar.toolbar.frame.midY)
        toolbar.qaDrag(from: start, to: NSPoint(x: toolbar.bounds.midX, y: toolbar.bounds.minY + 20))
        _ = toolbar.qaRunMotion()
        if toolbar.edge != .bottom { failures.append("setup: the drag did not land the bar on the bottom edge") }
        checkClear("bar dragged to bottom while showing")

        // A narrow window: rail and bar both crowd the bottom.
        window.setContentSize(NSSize(width: 900, height: 620))
        settle()
        rest(on: .bottom)
        tidyShowingToast()
        checkClear("narrow window, bar on bottom")

        if let renderDir {
            window.setContentSize(NSSize(width: 1_280, height: 800))
            try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                rest(on: .bottom)
                tidyShowingToast()
                root.needsDisplay = true
                settle()
                guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { continue }
                root.cacheDisplay(in: root.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: renderDir.appendingPathComponent("undo-toast-bottom-bar-\(name).png"))
            }
        }

        print("undo toast placement:")
        report.forEach { print($0) }
        guard failures.isEmpty else {
            throw Failure(description: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
    }
}
