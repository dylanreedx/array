import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The production tile has one identity/status bar; checkout context lives by
/// the composer in both renderers, appearances, and narrow/wide layouts.
@MainActor
enum AgentTileChromeConsolidationChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func run() throws {
        let key = AgentTranscriptCanvasView.rendererEnvironmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        let pointer = ManagedAgentTileNSView.qaPointerInside
        ManagedAgentTileNSView.qaPointerInside = { _ in false }
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
            ManagedAgentTileNSView.qaPointerInside = pointer
        }
        var failures: [String] = []
        var cases = 0
        for renderer in ["canvas", "list"] {
            setenv(key, renderer, 1)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for width: CGFloat in [320, 900] {
                    let (tile, window) = TileChromeCanvasChecks.makeTile(width: width, height: 640, appearance: appearance)
                    defer { window.orderOut(nil) }
                    tile.appendUserPrompt("Inspect the session context layout.")
                    tile.applyBranchContext(AgentRowContext(agentKind: .managed, checkedOutBranch: "array/integration"))
                    tile.ingest(.turnStarted(threadId: "chrome", turnId: "consolidation"))
                    try expect(!tile.qaPageZoomHeaderView.qaTimerIsActive,
                               "the session context must not duplicate the compact activity clock")
                    tile.ingest(.turnCompleted(threadId: "chrome", turnId: "consolidation", outcome: .completed, errorMessage: nil))
                    // Same public property the session observer / status sweep
                    // writes: it used to change only the outer bar, leaving a
                    // visible Configuring label and duplicate title underneath.
                    tile.agentStatus = .done
                    tile.setTitleBarIdentity(title: "Agent · \(tile.qaAgentHeaderName)", providerModel: tile.chromeSnapshot?.providerModel)
                    tile.wakeChrome()
                    tile.layoutSubtreeIfNeeded()
                    let context = tile.qaPageZoomHeaderView
                    let label = "\(renderer) \(appearance.rawValue) \(width)pt"
                    if context.isDescendant(of: tile.qaPageZoomComposeBackdrop) {
                        failures.append("\(label): session context is crowding the composer")
                    }
                    let root = tile.qaPageZoomContentRoot
                    let contextFrame = context.convert(context.bounds, to: root)
                    let composerFrame = tile.qaPageZoomComposeBackdrop.convert(
                        tile.qaPageZoomComposeBackdrop.bounds, to: root)
                    let contextAboveComposer = root.isFlipped
                        ? contextFrame.maxY <= composerFrame.minY : contextFrame.minY >= composerFrame.maxY
                    if !contextAboveComposer {
                        failures.append("\(label): session context is not under the title bar: \(contextFrame) vs composer \(composerFrame)")
                    }
                    if context.qaBranchFrame.midX <= context.bounds.midX {
                        failures.append("\(label): branch is not on the right: \(context.qaBranchFrame) in \(context.bounds)")
                    }
                    let fields = textFields(in: tile.qaPageZoomContentRoot)
                    if fields.contains(where: { $0.stringValue == tile.qaAgentHeaderName || $0.stringValue == "Configuring" }) {
                        failures.append("\(label): duplicate identity or stale Configuring label is still visible")
                    }
                    try expect(tile.chromeSnapshot?.agentStatus == .done, "\(label): the outer bar ignored the status update")
                    try expect(context.qaBranch?.contains("array/integration") == true
                        && context.qaBranch?.contains("shared") == true, "\(label): shared branch context was lost")
                    for zoom in [AgentPageZoom.default, AgentPageZoom(percent: 150)] {
                        tile.setPageZoom(zoom)
                        tile.layoutSubtreeIfNeeded()
                        let branch = context.qaBranchFrame
                        try expect(context.bounds.insetBy(dx: -1, dy: -1).contains(branch),
                                   "\(label) @\(zoom.percent)%: the branch escaped the context strip: \(branch) in \(context.bounds)")
                    }
                    tile.applyBranchContext(AgentRowContext(agentKind: .managed,
                        worktreeBranch: "agent/assigned", checkedOutBranch: "agent/moved"))
                    try expect(tile.chromeSnapshot?.agentStatusLabel == "Done",
                               "\(label): a branch refresh restored a stale operational label")
                    try expect(context.qaBranchIsWarning && context.qaBranch?.contains("agent/moved") == true,
                               "\(label): checkout mismatch warning was lost")
                    tile.applyBranchContext(nil)
                    try expect(context.qaBranch == nil, "\(label): unknown branch must hide the chip")
                    tile.applyAwarenessSignal(AgentSignal(id: "consolidation-push", kind: .gitPushSucceeded,
                        agentID: nil, tileID: tile.tile.id, threadID: nil, occurredAt: Date(), source: .managedRuntime))
                    tile.layoutSubtreeIfNeeded()
                    let badge = context.subviews.flatMap(\.subviews).compactMap { $0 as? AgentSignalBadgeView }.first
                    try expect(!context.isHidden && badge?.isHidden == false && badge?.signal?.kind == .gitPushSucceeded,
                               "\(label): awareness signal was lost when there was no branch")
                    tile.applyAwarenessSignal(nil)
                    try expect(context.isHidden, "\(label): an empty context strip must reclaim its space")
                    if let directory = ProcessInfo.processInfo.environment["AGENT_CHROME_CONSOLIDATION_PNG_DIR"] {
                        // The crowded case: a long branch beside a live status badge.
                        tile.applyBranchContext(AgentRowContext(agentKind: .managed,
                            checkedOutBranch: "agent/investigate-notifications-and-header-layout"))
                        tile.applyAwarenessSignal(AgentSignal(id: "consolidation-capture", kind: .actionRequired,
                            agentID: nil, tileID: tile.tile.id, threadID: nil, occurredAt: Date(), source: .managedRuntime))
                        let url = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        for zoom in [AgentPageZoom(percent: 150), AgentPageZoom.default] {
                            tile.setPageZoom(zoom)
                            tile.layoutSubtreeIfNeeded()
                            let image = try TranscriptViewportClippingChecks.render(tile).image
                            let name = "chrome-\(renderer)-\(appearance == .aqua ? "light" : "dark")-\(Int(width))pt-\(zoom.percent).png"
                            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                                .write(to: url.appendingPathComponent(name))
                        }
                    }
                    cases += 1
                }
            }
        }
        try expect(failures.isEmpty, failures.joined(separator: "\n"))
        print("agent chrome consolidation: \(cases) renderer/appearance/width cases; one identity/status, checkout context under the title bar")
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        guard !view.isHidden else { return [] }
        return (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
}
