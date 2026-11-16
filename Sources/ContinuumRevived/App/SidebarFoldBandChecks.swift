import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

extension SidebarOwnershipChecks {
    /// Open one nested fanout, then another below it. The first fold line keeps
    /// its identity while the shared card grows: its light must keep joining its
    /// neighbours. A single expansion recreates its own remainder and misses this.
    /// Runs inside the registered --sidebar-fold-expand-check leg.
    static func checkFoldBand(outputDirectory: URL?) throws -> String {
        let previous = AppTheme.current
        AppTheme.current = .black
        defer { AppTheme.current = previous }
        let env = ProcessInfo.processInfo.environment
        let mode = env["CONTINUUM_FOLD_BAND_CONTROL"] ?? "production"
        let lead = uuid(0xD00), parent = uuid(0xD01)
        func row(_ id: Int, _ title: String, parent: UUID? = nil, working: Bool = false,
                 failed: Bool = false, minutes: Double = 2) -> AgentInboxRow {
            AgentInboxRow(id: uuid(id), title: title, projectName: "savoro", state: working ? .working : failed ? .failed : .ready,
                elapsed: working ? 64 : nil, lastActiveAt: now.addingTimeInterval(-minutes * 60),
                depth: parent == nil ? 0 : 1, createdAt: now.addingTimeInterval(-36000), parentId: parent,
                terminalEvent: working ? nil : AgentTerminalEvent(sequence: 1, turnID: nil,
                    outcome: failed ? .failed : .succeeded, endedAt: now.addingTimeInterval(-minutes * 60)),
                terminalIsUnread: false, identityColor: parent == nil ? "red" : nil)
        }
        let rows = [row(0xD00, "Savoro Development", failed: true),
                    row(0xD02, "Complete iOS search flow", parent: lead, working: true),
                    row(0xD01, "Expand search with USDA", parent: lead)]
            + (0..<9).map { row(0xD10 + $0, "Search review \($0 + 1)", parent: parent, failed: $0 == 7,
                                minutes: $0 < 3 ? Double(3 + $0) : Double(40 + $0)) }
            + (0..<15).map { row(0xD40 + $0, "Review migration \($0 + 1)", parent: lead, minutes: 10 + Double($0)) }
            + (0..<12).map { row(0xD80 + $0, "Migration helper \($0 + 1)", parent: uuid(0xD40), minutes: 60 + Double($0)) }
        var failures: [String] = []
        var worst = 0
        for dark in [true, false] {
            for style in SidebarActiveIndicatorStyle.allCases {
                try autoreleasepool {
                    let caption = "\(dark ? "dark" : "light")/\(style.rawValue)/\(mode)"
                    let suite = "array.fold-band.\(UUID().uuidString)"
                    let defaults = QAIsolatedDefaults(isolatedSuiteName: suite)!
                    defer { defaults.removePersistentDomain(forName: suite) }
                    defaults.set(style.rawValue, forKey: SidebarActiveIndicatorStyle.defaultsKey)
                    defaults.set(SidebarActiveIndicatorScope.working.rawValue, forKey: SidebarActiveIndicatorScope.defaultsKey)
                    let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 486, height: 1100), indicatorDefaults: defaults)
                    inbox.clock = { now }
                    inbox.foldsUntouchedGroups = false
                    inbox.hoverCardEnabled = false
                    inbox.prefersReducedMotion = { true }
                    let window = KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = inbox
                    window.orderFrontOffscreenForChecks()
                    inbox.pinScrollerStyleForQA()
                    inbox.setScope(.all)
                    inbox.restoreParentFolds([lead: true, parent: true])
                    inbox.reload(rows: rows)
                    inbox.layoutForQA()
                    defer { window.orderOut(nil); window.contentView = nil; window.close() }
                    guard inbox.clickFanoutRemainderForQA(parentId: parent) else {
                        throw Failure(description: "\(caption): no nested remainder")
                    }
                    inbox.layoutForQA()
                    guard let survivor = inbox.ownershipRemaindersForQA.first(where: { $0.qaParentID == parent }) else {
                        throw Failure(description: "\(caption): no expanded fold line")
                    }
                    guard inbox.clickFanoutRemainderForQA(parentId: uuid(0xD40)) else {
                        throw Failure(description: "\(caption): no lower parent's remainder")
                    }
                    inbox.layoutForQA()
                    guard let line = inbox.ownershipRemaindersForQA.first(where: { $0.qaParentID == parent }),
                          line === survivor, line.qaTitle == "Show less" else {
                        throw Failure(description: "\(caption): expanded fold line did not survive")
                    }
                    @MainActor func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
                        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
                    }
                    descendants(inbox, InboxExpandedGroupLight.self).forEach { $0.reducesMotionForChecks = true }
                    if mode == "refresh-ownership" { inbox.openAgentId = lead; inbox.layoutForQA() }
                    if mode == "backed" { line.wantsLayer = true }
                    if mode == "no-sheet" { descendants(line, InboxGroupBackgroundView.self).forEach { $0.isHidden = true } }
                    if mode == "no-fill" { descendants(line, AgentInboxCardView.self).forEach { $0.isHidden = true } }
                    if mode == "no-button" { descendants(line, NSButton.self).forEach { $0.isHidden = true } }
                    if mode == "no-light" { descendants(line, InboxExpandedGroupLight.self).forEach { $0.isHidden = true } }
                    line.isHovered = false
                    guard line.qaFillRole == .resting, line.qaFillColor == nil else {
                        throw Failure(description: "\(caption): fold line paints a resting interaction fill")
                    }
                    inbox.layoutSubtreeIfNeeded()
                    inbox.displayIfNeeded()
                    CATransaction.flush()
                    guard let rep = inbox.bitmapImageRepForCachingDisplay(in: inbox.bounds) else {
                        throw Failure(description: "\(caption): no bitmap")
                    }
                    inbox.cacheDisplay(in: inbox.bounds, to: rep)
                    @MainActor func rect(_ view: NSView) -> NSRect {
                        var r = view.convert(view.bounds, to: inbox)
                        if !inbox.isFlipped { r.origin.y = inbox.bounds.height - r.maxY }
                        return r
                    }
                    let fold = rect(line)
                    let paintedCard = descendants(line, InboxExpandedGroupLight.self).first?.layer?.sublayers?.first?.frame ?? .zero
                    print("Fold band \(caption): painted card=\(paintedCard), live groupHeight=\(inbox.ownershipSliceForQA(id: lead)?.groupHeight ?? 0)")
                    let cells = inbox.qaMaterializedRowCells.map { rect($0) }.sorted { $0.minY < $1.minY }
                    guard let above = cells.last(where: { $0.maxY <= fold.minY + 0.5 }),
                          let below = cells.first(where: { $0.minY >= fold.maxY - 0.5 }) else {
                        throw Failure(description: "\(caption): missing adjacent rows")
                    }
                    let sx = CGFloat(rep.pixelsWide) / inbox.bounds.width
                    let sy = CGFloat(rep.pixelsHigh) / inbox.bounds.height
                    func rgb(_ x: CGFloat, _ y: CGFloat) throws -> [Int] {
                        guard let c = rep.colorAt(x: Int(x * sx), y: Int(y * sy))?.usingColorSpace(.deviceRGB),
                              c.alphaComponent > 0.99 else {
                            throw Failure(description: "\(caption): empty fold capture")
                        }
                        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
                    }
                    if style != .classic, let header = inbox.ownershipCellForQA(id: lead) {
                        let tint = try rgb(10, rect(header).minY + 18)
                        guard tint[0] > tint[1] + 2 else {
                            throw Failure(description: "\(caption): failed lead's red glow did not render")
                        }
                    }
                    var discontinuity = 0
                    var samples: [String] = []
                    for x in [CGFloat(10), 243, 472] {
                        let a = try rgb(x, above.minY + 9), f = try rgb(x, fold.minY + 9), b = try rgb(x, below.minY + 9)
                        for c in 0..<3 { discontinuity = max(discontinuity, min(a[c], b[c]) - f[c], f[c] - max(a[c], b[c])) }
                        samples.append("x=\(Int(x)) above=\(a) fold=\(f) below=\(b)")
                    }
                    worst = max(worst, discontinuity)
                    print("Fold band \(caption): y=\(fold.minY) delta=\(discontinuity); " + samples.joined(separator: "; "))
                    if let outputDirectory {
                        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                        try rep.representation(using: .png, properties: [:])!.write(to:
                            outputDirectory.appendingPathComponent("\(mode)-\(dark ? "dark" : "light")-\(style.rawValue).png"))
                    }
                    if discontinuity > 3 { failures.append("\(caption): fold band delta \(discontinuity)") }
                }
            }
        }
        let summary = "Fold band: \(8 - failures.count)/8 expanded cards continuous; Black theme, four styles, both appearances; max delta \(worst)/255"
        print(summary)
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "\n")) }
        return summary
    }
}
