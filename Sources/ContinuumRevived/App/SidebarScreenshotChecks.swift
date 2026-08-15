import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Program 96 / P0.2 — the offscreen half of the screenshot harness.
///
/// P0.1 proved what the sidebar renders in TEXT. This turns the same production
/// rows into images at the widths and appearances §6/P0.2 declares, with a manifest
/// traceable per §3.3, so a density judgement can be made against pixels instead of
/// prose. It also renders the three density proposals gate S0 asks Dylan to rule on.
///
/// It asserts MECHANICS only — every planned image exists, the manifest and the
/// directory agree, no field is blank, no image is blank, and the two appearances
/// really differ. It deliberately makes no aesthetic claim: a check that could fail on
/// taste teaches people to fix screenshots instead of bugs (the rationale
/// `UITourCheck` records for staying advisory).
///
/// The file is named `…Checks.swift` on purpose — `scripts/check-color-hygiene.sh`
/// excludes that suffix, and the proposal mock below draws a scrim in raw colours the
/// way the shipped nav-mode HUD does.
@MainActor
enum SidebarScreenshotChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    // `nonisolated` because the live check reads these from inside a @Sendable
    // closure; they are immutable strings with no actor state behind them.
    nonisolated static let checkName = "sidebar-96-screenshots"
    nonisolated static let flag = "--sidebar-screenshot-check"
    nonisolated static let liveCheckName = "sidebar-96-live"
    nonisolated static let liveFlag = "--sidebar-live-capture-check"
    /// §8.1's required height: "at least nine complete active rows in 662 pt".
    static let denseViewportHeight: CGFloat = 662
    static let widths: [CGFloat] = [220, 280, 320, 360]
    static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    // MARK: - Manifest (§3.3)

    struct Manifest: Codable {
        /// `check` and `verdict` are read by `QARunManifestReader.latest(…)`, so this
        /// run surfaces in the QA UI the app already has.
        let check: String
        let verdict: String
        let program: String
        let generatedAt: Date
        let commit: String
        let dirtyTracked: [String]
        let dirtyUntracked: [String]
        let binaryPath: String
        let binarySHA256: String
        let bundleVersion: String
        let buildChannel: String
        let scratchProjectRoot: String
        let appSupportRoot: String
        let entries: [Entry]
    }

    struct Entry: Codable {
        let png: String
        let fixture: String
        let widthRequestedPt: Double
        let widthMeasuredPt: Double
        let heightPt: Double
        let appearance: String
        let reduceMotion: String
        let increaseContrast: String
        let scale: Double
        /// `offscreen-probe` here. The live half writes `live-window` and
        /// `live-view-cache`, and §3.3 requires the distinction to be recorded rather
        /// than inferred: an offscreen probe is a geometry gate, not proof of the
        /// shipped product.
        let captureType: String
        let checkFlag: String
        let digest: String
        let rowsRendered: Int
        /// Complete rows whose painted frame fits inside a 662 pt viewport — the
        /// number §8.1 puts a floor under, measured rather than divided out.
        let completeRowsIn662pt: Int?
        let cardHeightPt: Double?
        let pitchPt: Double?
    }

    // MARK: - Output location

    /// One timestamped directory per process, so every image from a run lands
    /// together. Same shape as `UITourCheck.tourDirectory()`, memoized the way
    /// `UIProbeBaseline` memoizes its artifact directory.
    private static var cachedDirectory: URL?

    static func outputDirectory() throws -> URL {
        if let cachedDirectory { return cachedDirectory }
        let root: URL
        if let override = ProcessInfo.processInfo.environment["CONTINUUM_QA_CAPTURE"],
           !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "")
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("qa-runs", isDirectory: true)
                .appendingPathComponent(timestamp, isDirectory: true)
                .appendingPathComponent("sidebar-96", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cachedDirectory = root
        return root
    }

    // MARK: - Provenance

    private static func shell(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tracked and untracked dirt, separately, because §3.3 asks for both and they
    /// mean different things: a dirty tracked file changes what was built, while an
    /// untracked one usually belongs to another stream.
    private static func gitDirt() -> (tracked: [String], untracked: [String]) {
        let porcelain = shell("/usr/bin/git", ["status", "--porcelain"])
        guard !porcelain.isEmpty else { return ([], []) }
        var tracked: [String] = []
        var untracked: [String] = []
        for line in porcelain.components(separatedBy: .newlines) where line.count > 3 {
            let path = String(line.dropFirst(3))
            if line.hasPrefix("??") { untracked.append(path) } else { tracked.append(path) }
        }
        return (tracked, untracked)
    }

    // MARK: - Rendering

    private struct Host {
        let window: NSWindow
        let container: NSView
        let inbox: AgentInboxView
    }

    /// A sized host in a real window with an EDGE-PINNED inbox.
    ///
    /// Both halves matter and both were learned the hard way. The window is what gives
    /// an offscreen `NSTableView` a viewport to materialize cells in; edge-pinning is
    /// why a 220 pt assertion cannot quietly measure the 280 pt default once a
    /// conditional overlay changes the fitting size. This is
    /// `UIProbeGeometry.makeSidebarProbeHost`'s arrangement, reproduced here because
    /// that one is private to its own leg.
    private static func makeHost(
        width: CGFloat,
        height: CGFloat,
        appearance: NSAppearance,
        reduceMotion: Bool,
        increaseContrast: Bool
    ) throws -> Host {
        let size = NSSize(width: width, height: height)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = container
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)

        let inbox = AgentInboxView(frame: container.bounds)
        inbox.autoresizingMask = [.width, .height]
        container.addSubview(inbox)
        container.layoutSubtreeIfNeeded()
        guard abs(container.bounds.width - width) <= 0.5,
              inbox.bounds.width > 0, inbox.bounds.height > 0 else {
            throw Failure(description: String(
                format: "%@: sized host gave the inbox no live viewport (host %.1fx%.1f, inbox %.1fx%.1f)",
                checkName, container.bounds.width, container.bounds.height,
                inbox.bounds.width, inbox.bounds.height))
        }
        // Pin the scroller before content arrives: a legacy scroller takes a lane and
        // would make every measured width depend on whether a mouse is plugged in.
        inbox.pinScrollerStyleForQA()
        inbox.prefersReducedMotion = { reduceMotion }
        inbox.prefersIncreasedContrast = { increaseContrast }
        return Host(window: window, container: container, inbox: inbox)
    }

    /// How much of a 662 pt SIDEBAR the inbox actually gets.
    ///
    /// The shipped `WorkspaceSidebarView` pins the inbox below an "Agents" title and a
    /// (hidden but still constrained) management message: `10 + titleH + 4 + msgH + 8`.
    /// A row-count claim measured on a bare inbox handed the whole 662 pt therefore
    /// over-counts, and it over-counts most for the tightest pitch — i.e. in the
    /// direction that flatters the densest proposal. Measured, not derived.
    static func measureSidebarInboxHeight(
        sidebarHeight: CGFloat, width: CGFloat, appearance: NSAppearance
    ) -> (inbox: CGFloat, chrome: CGFloat) {
        let size = NSSize(width: width, height: sidebarHeight)
        let sidebar = WorkspaceSidebarView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = sidebar
        sidebar.layoutSubtreeIfNeeded()
        let inbox = sidebar.inboxForQA.bounds.height
        return (inbox, sidebarHeight - inbox)
    }

    /// Rows whose painted frame sits entirely inside the first 662 pt of the list.
    /// Read off the cells rather than divided out of a pitch constant, so a row that
    /// changes height changes this number.
    private static func completeRows(in host: Host, viewportHeight: CGFloat) -> Int {
        host.inbox.qaMaterializedRowCells.reduce(into: 0) { count, cell in
            guard cell.qaAgentID != nil else { return }
            let frame = cell.convert(cell.bounds, to: host.inbox)
            if frame.minY >= -0.5, frame.maxY <= viewportHeight + 0.5 { count += 1 }
        }
    }

    /// The measured card height and pitch of the rendered list: the first two agent
    /// rows' painted frames. This is how S0's proposal C anchor stays measured.
    private static func measuredGeometry(in host: Host) -> (card: CGFloat, pitch: CGFloat)? {
        // FULL CARDS only, and two ADJACENT ones. A settled row is slim (35 pt), so
        // sampling the first two painted rows of a mixed list reported a 35 pt card on a
        // 78 pt pitch — which the proposal-C teeth check caught. Card pitch is a claim
        // about card rows.
        let frames = host.inbox.qaMaterializedRowCells
            .filter { $0.qaAgentID != nil && $0.qaVariant == .card }
            .map { $0.convert($0.bounds, to: host.inbox) }
            .sorted { $0.minY < $1.minY }
        guard frames.count >= 2 else { return nil }
        for (first, second) in zip(frames, frames.dropFirst()) {
            let pitch = second.minY - first.minY
            // Adjacent means the gap is a row gap, not a slim row wedged between.
            if pitch > 0, pitch < first.height * 1.5 { return (first.height, pitch) }
        }
        return nil
    }

    private static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure(description: "\(url.lastPathComponent): could not encode PNG")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func shortName(_ appearance: NSAppearance.Name) -> String {
        appearance == .aqua ? "aqua" : "darkAqua"
    }

    /// `performAsCurrentDrawingAppearance` takes a non-throwing closure, and every
    /// render below can fail. Ferry the result out rather than swallowing errors
    /// inside the drawing block.
    private static func drawing<T>(
        _ appearance: NSAppearance, _ body: () throws -> T
    ) throws -> T {
        var result: Result<T, Error>?
        appearance.performAsCurrentDrawingAppearance {
            result = Result { try body() }
        }
        guard let result else {
            throw Failure(description: "\(checkName): drawing block never ran")
        }
        return try result.get()
    }

    // MARK: - The run

    static func run() async throws {
        let directory = try outputDirectory()
        let now = Date(timeIntervalSince1970: 1_900_600_000)
        let world = try AppDelegate.makeSidebarCorpusWorld(now: now)
        defer { world.tearDown() }
        _ = try await SidebarProductionCorpus.runFlows(in: world)
        let rows = world.productionRows()
        guard rows.count >= 9 else {
            throw Failure(description:
                "\(checkName): the corpus produced \(rows.count) rows; §8.1's density "
                + "fixture needs at least nine to say anything about a 662 pt viewport")
        }

        // The 50 `fiftyActiveWithHistory` agents are created last and sort newest-first,
        // so they filled the entire 662 pt fixture and the "dense baseline" showed one
        // row shape repeated seven times. The density artifact uses the
        // product-interesting rows; the bulk agents still exist in the taller `corpus`
        // sweep, where scale is the point.
        let bulkPrefix = "Bulk agent"
        let denseRows = rows.filter { !$0.displayTitle.hasPrefix(bulkPrefix) }
        guard denseRows.count >= 9 else {
            throw Failure(description:
                "\(checkName): only \(denseRows.count) non-bulk rows; §8.1's density "
                + "fixture needs nine or it cannot speak to a 662 pt viewport")
        }
        print("SidebarScreenshotChecks: density fixture uses \(denseRows.count) "
              + "product rows (\(rows.count - denseRows.count) bulk rows kept for the "
              + "corpus sweep only)")

        var entries: [Entry] = []
        let previousAppAppearance = NSApp?.appearance
        defer { NSApp?.appearance = previousAppAppearance }

        // Every combination that is NOT rendered is named here rather than silently
        // dropped: accessibility variants are swept at 280 pt only, because the
        // question they answer (does the cue survive) is not width-dependent, while
        // density and truncation are.
        var skipped: [String] = [
            "reduceMotion and increaseContrast as still images — both have numeric "
                + "witnesses in --sidebar-ux-check (crossfade count; resolved fill and "
                + "contrast ratio per role), which a PNG diff cannot improve on",
        ]
        for width in widths where width != 280 {
            skipped.append("interaction fills@\(Int(width))pt")
        }

        for appearanceName in appearances {
            guard let appearance = NSAppearance(named: appearanceName) else {
                throw Failure(description: "\(checkName): no NSAppearance named '\(appearanceName.rawValue)'")
            }
            // Both the window AND NSApp: dynamic colours resolve against
            // `NSApp.effectiveAppearance`, so a window-only flip renders Aqua text on
            // a Dark Aqua palette.
            NSApp?.appearance = appearance

            for width in widths {
                // The full corpus, tall enough that every row is painted — this is the
                // density and truncation artifact.
                let tall = max(denseViewportHeight, CGFloat(rows.count + 2) * 90)
                try drawing(appearance) {
                    let host = try makeHost(
                        width: width, height: tall, appearance: appearance,
                        reduceMotion: false, increaseContrast: false)
                    host.inbox.reload(rows: rows)
                    host.inbox.layoutForQA()
                    let geometry = measuredGeometry(in: host)
                    let rep = try UIProbe.bitmap(of: host.container, id: "corpus-\(Int(width))")
                    let name = "corpus-\(Int(width))x\(Int(tall))-\(shortName(appearanceName)).png"
                    try writePNG(rep, to: directory.appendingPathComponent(name))
                    entries.append(Entry(
                        png: name, fixture: "corpus",
                        widthRequestedPt: Double(width),
                        widthMeasuredPt: Double(host.inbox.bounds.width),
                        heightPt: Double(tall),
                        appearance: shortName(appearanceName),
                        reduceMotion: "forced-off", increaseContrast: "forced-off",
                        scale: Double(UIProbe.renderScale),
                        captureType: "offscreen-probe", checkFlag: flag,
                        digest: UIProbe.digest(of: rep),
                        rowsRendered: host.inbox.qaMaterializedRowCells.count,
                        completeRowsIn662pt: nil,
                        cardHeightPt: geometry.map { Double($0.card) },
                        pitchPt: geometry.map { Double($0.pitch) }))
                }

                // §8.1's dense fixture: the real 662 pt viewport, where "how many rows
                // can I see" is a number and not an opinion.
                try drawing(appearance) {
                    let host = try makeHost(
                        width: width, height: denseViewportHeight, appearance: appearance,
                        reduceMotion: false, increaseContrast: false)
                    host.inbox.reload(rows: denseRows)
                    host.inbox.layoutForQA()
                    let geometry = measuredGeometry(in: host)
                    let rep = try UIProbe.bitmap(of: host.container, id: "dense-\(Int(width))")
                    let name = "dense662-\(Int(width))x\(Int(denseViewportHeight))-\(shortName(appearanceName)).png"
                    try writePNG(rep, to: directory.appendingPathComponent(name))
                    entries.append(Entry(
                        png: name, fixture: "dense662",
                        widthRequestedPt: Double(width),
                        widthMeasuredPt: Double(host.inbox.bounds.width),
                        heightPt: Double(denseViewportHeight),
                        appearance: shortName(appearanceName),
                        reduceMotion: "forced-off", increaseContrast: "forced-off",
                        scale: Double(UIProbe.renderScale),
                        captureType: "offscreen-probe", checkFlag: flag,
                        digest: UIProbe.digest(of: rep),
                        rowsRendered: host.inbox.qaMaterializedRowCells.count,
                        completeRowsIn662pt: completeRows(in: host, viewportHeight: denseViewportHeight),
                        cardHeightPt: geometry.map { Double($0.card) },
                        pitchPt: geometry.map { Double($0.pitch) }))
                }
            }

            // The REAL list rendering the REAL rows through the redesigned cell.
            //
            // Every other 96 image is a mock: `SidebarDensityProposalView` paints
            // chosen strings, so it can only ever show the design at its best. This
            // one is `AgentInboxView` — the shipped list, the shipped join, the
            // production corpus — with `cardStyleOverride` set. It is therefore the
            // only image in the set that answers the question that matters: what
            // does the new row look like carrying what the app ACTUALLY produces?
            //
            // The answer is worth looking at: production rows have no branch and no
            // model, so band 3 is empty on almost every one. The redesign does not
            // fix that by itself — Phases 1–3 do — and this image is what stops the
            // mock's good data from being mistaken for evidence that they have.
            // TWO row sets through the same live cell, and the pair is the point.
            //
            // `production` is what the app makes. `capability` is queue-94's fixture
            // set — a branch, a model and a real state on every row — which is also
            // what the Component Lab's live sidebar shows and therefore what Dylan
            // is looking at when he compares it against the mock. Rendering only one
            // of them cannot separate "the cell draws the design badly" from "the
            // data is impoverished", and those need completely different fixes.
            let liveRowSets: [(id: String, rows: [AgentInboxRow])] = [
                ("production", denseRows),
                ("capability", LabFixtures.inboxRows()),
                ("rules", AgentInbox96Fixtures.rows(now: now)),
            ]
            for (rowSetID, liveRows) in liveRowSets {
                let proposal = SidebarDensityProposal.a
                try drawing(appearance) {
                    let host = try makeHost(
                        width: 280, height: denseViewportHeight, appearance: appearance,
                        reduceMotion: false, increaseContrast: false)
                    // The list hands `now` to every cell from its OWN clock, which
                    // defaults to the wall clock. Rule 2 is an age comparison, so a
                    // fixture dated against `now` while the cell is told the real time
                    // measures nothing — both escalation rungs came out identical
                    // because the fixture's timestamps were in 2030.
                    host.inbox.clock = { now }
                    host.inbox.cardStyleOverride = AgentInboxCardStyleOverride(
                        makeCell: {
                            AgentInbox96CellView(
                                proposal: proposal,
                                anatomy: SidebarRowAnatomy(
                                    id: "live", label: "live", border: .none,
                                    iconPlacement: .leading, showsModelText: false))
                        },
                        cardHeight: { _ in AgentInbox96CellView.rowHeight(for: proposal) })
                    host.inbox.reload(rows: liveRows)
                    host.inbox.layoutForQA()
                    // An offscreen table defers its incremental reload indefinitely,
                    // and setting the override goes through exactly that path.
                    host.inbox.rebuildRowsForQA()
                    host.inbox.layoutForQA()
                    let geometry = measuredGeometry(in: host)
                    // What the redesigned cell actually gave each band, read off the
                    // live cells. A row whose state column is narrower than the word
                    // it holds is a truncation nobody would spot in a thumbnail.
                    if appearanceName == .darkAqua, rowSetID == "rules" {
                        for cell in host.inbox.qaMaterializedRowCells.prefix(8)
                        where cell.qaAgentID != nil {
                            let frames = cell.qaGeometry.elementFrames
                            print(String(
                                format: "SidebarScreenshotChecks: live96 '%@' — state '%@' "
                                    + "in %.1fpt, glyph '%@', pulsing %@, provider '%@'",
                                cell.qaTitle.prefix(28).description, cell.qaStateLabel,
                                frames["state"]?.width ?? -1,
                                cell.qaGlyph,
                                ((cell as? AgentInbox96CellView)?.qaIsPulsingForQA ?? false)
                                    ? "YES" : "no",
                                cell.qaProviderGlyph))
                        }
                    }
                    if appearanceName == .darkAqua, rowSetID == "rules" {
                        try assertHoverCardCarriesWhatTheRowCannot(inbox: host.inbox, rows: liveRows)
                    }
                    let rep = try UIProbe.bitmap(
                        of: host.container, id: "live96-\(rowSetID)")
                    let name = "live96-\(rowSetID)-280x\(Int(denseViewportHeight))-\(shortName(appearanceName)).png"
                    try writePNG(rep, to: directory.appendingPathComponent(name))
                    entries.append(Entry(
                        png: name, fixture: "live96-\(rowSetID)",
                        widthRequestedPt: 280,
                        widthMeasuredPt: Double(host.inbox.bounds.width),
                        heightPt: Double(denseViewportHeight),
                        appearance: shortName(appearanceName),
                        reduceMotion: "forced-off", increaseContrast: "forced-off",
                        scale: Double(UIProbe.renderScale),
                        captureType: "offscreen-probe", checkFlag: flag,
                        digest: UIProbe.digest(of: rep),
                        rowsRendered: host.inbox.qaMaterializedRowCells.count,
                        completeRowsIn662pt: completeRows(
                            in: host, viewportHeight: denseViewportHeight),
                        cardHeightPt: geometry.map { Double($0.card) },
                        pitchPt: geometry.map { Double($0.pitch) }))
                }
            }

            // ONE interaction reference: a selected row, so the review can see the fill
            // and gutter §4.4 talks about.
            //
            // Neither accessibility setting gets a still image, and that is deliberate
            // rather than an omission. Reduce Motion gates the crossfade, so two stills
            // of a settled list are the same picture. Increase Contrast is a ≤1.5%
            // alpha step on an interaction fill (`interactionFill`), which a PNG diff is
            // a poor instrument for. Both already have BETTER, numeric witnesses in
            // `--sidebar-ux-check`: it drives `prefersReducedMotion` both ways and
            // asserts `crossfadingRowCountForQA` 0 vs 1, and it drives
            // `prefersIncreasedContrast` both ways and asserts the resolved fill and its
            // measured contrast ratio per interaction role. Shipping a relabelled
            // duplicate here would claim coverage those checks actually provide.
            for variant in ["interaction"] {
                try drawing(appearance) {
                    let host = try makeHost(
                        width: 280, height: denseViewportHeight, appearance: appearance,
                        reduceMotion: false,
                        increaseContrast: false)
                    host.inbox.reload(rows: denseRows)
                    host.inbox.layoutForQA()
                    // Increase Contrast strengthens INTERACTION fills, so a resting list
                    // paints nothing different and the variant image came out
                    // byte-identical to the baseline. Select a row so the setting has a
                    // surface to act on — the same thing the geometry probe's contrast
                    // sweep does.
                    if let first = denseRows.first {
                        _ = host.inbox.selectRowForQA(id: first.id)
                        // `rebuildRowsForQA`, not `layoutForQA`: selection re-applies
                        // through an incremental reload, and an offscreen window defers
                        // that indefinitely — the cells would read back as resting rows.
                        // That is the trap written on `rebuildRowsForQA` itself.
                        host.inbox.rebuildRowsForQA()
                    }
                    // `cacheDisplay`, not `UIProbe.bitmap`: interaction fills are LAYER
                    // background colours that Core Animation composites, and
                    // `displayIgnoringOpacity` drives AppKit's draw path, so a selected
                    // row came out byte-identical to a resting one. The geometry fixtures
                    // keep the display-independent path; these interaction fixtures
                    // need the compositing one, and say so in `captureType`.
                    guard let rep = host.container
                        .bitmapImageRepForCachingDisplay(in: host.container.bounds) else {
                        throw Failure(description: "\(checkName): no cache rep for a11y")
                    }
                    host.container.cacheDisplay(in: host.container.bounds, to: rep)
                    let suffix = "selected"
                    let name = "interaction-280x\(Int(denseViewportHeight))-\(shortName(appearanceName))-\(suffix).png"
                    try writePNG(rep, to: directory.appendingPathComponent(name))
                    entries.append(Entry(
                        png: name, fixture: variant,
                        widthRequestedPt: 280,
                        widthMeasuredPt: Double(host.inbox.bounds.width),
                        heightPt: Double(denseViewportHeight),
                        appearance: shortName(appearanceName),
                        reduceMotion: "forced-off",
                        increaseContrast: "forced-off (numeric witness in --sidebar-ux-check)",
                        scale: Double(rep.pixelsWide) / max(Double(host.container.bounds.width), 1),
                        captureType: "offscreen-view-cache", checkFlag: flag,
                        digest: UIProbe.digest(of: rep),
                        rowsRendered: host.inbox.qaMaterializedRowCells.count,
                        completeRowsIn662pt: completeRows(in: host, viewportHeight: denseViewportHeight),
                        cardHeightPt: nil, pitchPt: nil))
                }
            }

            // One mock renderer, driven twice: once across PITCHES with a fixed anatomy,
            // once across ANATOMIES at a fixed pitch. Two sweeps, one variable each.
            func renderMock(
                proposal: SidebarDensityProposal, anatomy: SidebarRowAnatomy,
                width: CGFloat, subdirectory: String, name: String, fixture: String
            ) throws {
                try drawing(appearance) {
                    let view = SidebarDensityProposalView(
                        proposal: proposal, anatomy: anatomy,
                        frame: NSRect(x: 0, y: 0, width: width, height: denseViewportHeight))
                    let window = NSWindow(
                        contentRect: view.frame, styleMask: [.borderless],
                        backing: .buffered, defer: false)
                    window.appearance = appearance
                    window.contentView = view
                    view.layoutSubtreeIfNeeded()
                    let rep = try UIProbe.bitmap(of: view, id: fixture)
                    let subdir = directory.appendingPathComponent(
                        subdirectory, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: subdir, withIntermediateDirectories: true)
                    try writePNG(rep, to: subdir.appendingPathComponent(name))
                    entries.append(Entry(
                        png: "\(subdirectory)/\(name)", fixture: fixture,
                        widthRequestedPt: Double(width),
                        widthMeasuredPt: Double(view.bounds.width),
                        heightPt: Double(denseViewportHeight),
                        appearance: shortName(appearanceName),
                        reduceMotion: "n/a (static mock)",
                        increaseContrast: "n/a (static mock)",
                        scale: Double(UIProbe.renderScale),
                        captureType: "offscreen-probe", checkFlag: flag,
                        digest: UIProbe.digest(of: rep),
                        rowsRendered: view.drawnRowCount,
                        completeRowsIn662pt: proposal.completeRows(in: denseViewportHeight),
                        cardHeightPt: Double(proposal.cardHeight),
                        pitchPt: Double(proposal.pitch)))
                }
            }

            // The three density proposals S0 rules on — all at the same anatomy, so the
            // only thing that differs between them is pitch.
            for proposal in SidebarDensityProposal.all {
                for width in [CGFloat(220), 280, 360] {
                    try renderMock(
                        proposal: proposal, anatomy: .markOnly, width: width,
                        subdirectory: "proposals",
                        name: "proposal\(proposal.id)-\(Int(width))x\(Int(denseViewportHeight))-\(shortName(appearanceName)).png",
                        fixture: "proposal-\(proposal.id)")
                }
            }

            // The status-emphasis sweep, all at proposal A's pitch and 280 pt.
            //
            // A deliberately, not the roomiest option: a treatment that only works at C's
            // 83 pt pitch would be chosen here and then break under whatever S0 rules.
            // Judging it at the TIGHTEST proposed pitch cannot make that mistake.
            // The control is `proposals/proposalA-280x662-*.png` — same pitch, same
            // width, same content, `trailingText`.
            for anatomy in SidebarRowAnatomy.statusExperiments {
                try renderMock(
                    proposal: .a, anatomy: anatomy, width: 280,
                    subdirectory: "status",
                    name: "status-\(anatomy.id)-280x\(Int(denseViewportHeight))-\(shortName(appearanceName)).png",
                    fixture: "status-\(anatomy.id)")
            }
        }

        // MARK: Provenance + manifest

        let dirt = gitDirt()
        let executable = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        let sha = executable.isEmpty
            ? "unavailable"
            : (shell("/usr/bin/shasum", ["-a", "256", executable])
                .components(separatedBy: " ").first ?? "unavailable")
        // Written AFTER the gate, with the real outcome. An earlier version wrote
        // `verdict: "PASS"` before asserting anything, so a failing run left a manifest
        // on disk claiming success — and `QARunManifestReader` reads exactly that field.
        func makeManifest(verdict: String) -> Manifest { Manifest(
            check: checkName,
            verdict: verdict,
            program: "96-P0.2",
            generatedAt: Date(),
            commit: shell("/usr/bin/git", ["rev-parse", "HEAD"]),
            dirtyTracked: dirt.tracked,
            dirtyUntracked: dirt.untracked,
            binaryPath: executable,
            binarySHA256: sha,
            // A CLI binary carries no app version; saying so beats an empty field.
            bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                ?? "n/a (cli binary)",
            buildChannel: AppChannel.applicationSupportDirectoryName(
                bundleIdentifier: Bundle.main.bundleIdentifier),
            scratchProjectRoot: world.projectRoot.path,
            appSupportRoot: world.appSupport.path,
            entries: entries) }

        func writeManifest(verdict: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(makeManifest(verdict: verdict))
                .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        }
        let manifest = makeManifest(verdict: "PASS")

        // MARK: Gate — mechanics only

        // Any assertion below that throws records the failure in the manifest before
        // propagating, so what is on disk always matches what happened.
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                try? writeManifest(verdict: "FAIL")
                throw Failure(description: "\(checkName): \(message)")
            }
        }

        for field in [
            ("commit", manifest.commit), ("binaryPath", manifest.binaryPath),
            ("binarySHA256", manifest.binarySHA256), ("bundleVersion", manifest.bundleVersion),
            ("buildChannel", manifest.buildChannel),
            ("scratchProjectRoot", manifest.scratchProjectRoot),
            ("appSupportRoot", manifest.appSupportRoot),
        ] {
            try expect(!field.1.isEmpty, "§3.3 field '\(field.0)' is empty — an artifact "
                       + "nobody can trace back to a build is not evidence")
        }

        // Every planned image exists, and the directory holds nothing the manifest
        // does not claim. Both directions: a missing file is a lie, an extra file is
        // an unrecorded artifact.
        let onDisk = Set(
            (try FileManager.default.subpathsOfDirectory(atPath: directory.path))
                .filter { $0.hasSuffix(".png") })
        let claimed = Set(entries.map(\.png))
        try expect(onDisk == claimed,
                   "manifest and directory disagree — only in manifest: "
                   + "\(claimed.subtracting(onDisk).sorted()), only on disk: "
                   + "\(onDisk.subtracting(claimed).sorted())")

        // No image may be blank. This is the non-vacuity floor `ComponentLab` applies
        // to every card before it gates: a harness that writes 32 empty rectangles
        // would otherwise report a clean run.
        for entry in entries {
            let url = directory.appendingPathComponent(entry.png)
            guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                throw Failure(description: "\(checkName): \(entry.png) is not a readable PNG")
            }
            let metrics = VisualSnapshot.metrics(of: rep)
            try expect(!metrics.isBlank,
                       "\(entry.png) rendered blank (\(metrics.distinctSampledColors) "
                       + "distinct colours) — the harness wrote an image of nothing")
        }

        // No two images may be byte-identical. The four accessibility variants were
        // relabelled copies of the baseline and of each other, and the gate could not
        // see it: `isBlank` passes on a fully-painted list and the appearance check only
        // compares within one fixture. A manifest listing 38 images of which 4 are
        // duplicates claims coverage it does not have.
        var digestOwners: [String: [String]] = [:]
        for entry in entries { digestOwners[entry.digest, default: []].append(entry.png) }
        let duplicates = digestOwners.filter { $0.value.count > 1 }
        try expect(duplicates.isEmpty,
                   "byte-identical images under different names: "
                   + duplicates.values.map { $0.sorted().joined(separator: " == ") }
                       .sorted().joined(separator: "; ")
                   + " — a variant that renders the same as its baseline is not a variant "
                   + "shown, and §6/P0.2 requires the accessibility variants to be shown")

        // Aqua and Dark Aqua must actually differ per fixture+width, or the appearance
        // sweep is decoration.
        var byFixture: [String: [String: String]] = [:]
        for entry in entries {
            let key = "\(entry.fixture)@\(Int(entry.widthRequestedPt))"
            byFixture[key, default: [:]][entry.appearance] = entry.digest
        }
        for (key, digests) in byFixture.sorted(by: { $0.key < $1.key }) {
            guard let aqua = digests["aqua"], let dark = digests["darkAqua"] else { continue }
            try expect(aqua != dark,
                       "\(key) rendered byte-identical in Aqua and Dark Aqua — the "
                       + "appearance was not actually applied")
        }

        // TEETH: proposal C is today's geometry, so its computed row count must equal
        // the count measured off the real sidebar's painted cells at the same viewport.
        // If these drift, the proposal arithmetic S0 is asked to trust is fiction.
        if let measured = entries.first(where: {
            $0.fixture == "dense662" && $0.appearance == "darkAqua"
                && $0.widthRequestedPt == 280
        }) {
            let measuredCard = measured.cardHeightPt ?? 0
            let measuredPitch = measured.pitchPt ?? 0
            try expect(abs(measuredCard - Double(SidebarDensityProposal.c.cardHeight)) <= 0.5
                       && abs(measuredPitch - Double(SidebarDensityProposal.c.pitch)) <= 0.5,
                       "proposal C claims \(SidebarDensityProposal.c.cardHeight)/"
                       + "\(SidebarDensityProposal.c.pitch)pt but the shipped sidebar "
                       + "measures \(measuredCard)/\(measuredPitch)pt — C is supposed to BE "
                       + "today's geometry, so fix C rather than the comparison")
            try expect(measured.completeRowsIn662pt
                       == SidebarDensityProposal.c.completeRows(in: denseViewportHeight),
                       "proposal C computes "
                       + "\(SidebarDensityProposal.c.completeRows(in: denseViewportHeight)) "
                       + "rows in \(Int(denseViewportHeight))pt but the real sidebar paints "
                       + "\(measured.completeRowsIn662pt ?? -1) at the same geometry — the "
                       + "row-count arithmetic every proposal reports is wrong")
        }

        // TEETH: the leading-icon column claims its glyphs are optically aligned. Prove
        // it by painting each one through the real draw path and re-measuring the ink,
        // rather than by re-deriving the same arithmetic that placed it.
        //
        // Dylan's report was "they are too different to look properly aligned because of
        // the various shapes", and the raw numbers below say why: SF Symbols share a
        // bounding box, not an optical size.
        let statusSymbols = SidebarDensityProposalView.statusSymbolsInUse
        try expect(statusSymbols.count >= 2,
                   "the mock draws \(statusSymbols.count) distinct status symbols; with "
                   + "fewer than two there is no column to align and this witness is "
                   + "measuring nothing")
        let slot = NSRect(x: 0, y: 0, width: 16, height: 16)
        var alignedInk: [(name: String, raw: NSRect, painted: NSRect)] = []
        try drawing(NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()) {
            for name in statusSymbols {
                guard let raw = SidebarDensityProposalView.symbolInk(name),
                      let image = SidebarDensityProposalView.symbolImage(name) else {
                    throw Failure(description:
                        "\(checkName): no SF Symbol '\(name)' — the mock's status glyph "
                        + "set cannot be measured, so the alignment claim is unwitnessed")
                }
                // Paint into a slot-sized canvas exactly as the row does, then measure.
                let side = 64
                let scale = CGFloat(side) / slot.width
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: rep) else {
                    throw Failure(description: "\(checkName): no alignment probe bitmap")
                }
                let placed = SidebarDensityProposalView.alignedRect(
                    slot: slot, ink: raw, alignment: .leadingEdge)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                NSColor.black.setFill()
                image.draw(
                    in: NSRect(x: placed.minX * scale, y: placed.minY * scale,
                               width: placed.width * scale, height: placed.height * scale),
                    from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                guard let painted = SidebarDensityProposalView.inkBounds(of: rep) else {
                    throw Failure(description:
                        "\(checkName): '\(name)' painted no ink into its slot")
                }
                alignedInk.append((name, raw, NSRect(
                    x: painted.minX * slot.width, y: painted.minY * slot.height,
                    width: painted.width * slot.width, height: painted.height * slot.height)))
            }
        }
        for entry in alignedInk {
            print(String(
                format: "SidebarScreenshotChecks: %@ — raw ink %.0f%% wide x %.0f%% tall, "
                    + "raw left edge %.1f%%; painted %.2fx%.2fpt, left edge %.2fpt, "
                    + "vertical centre %.2fpt",
                entry.name, entry.raw.width * 100, entry.raw.height * 100,
                entry.raw.minX * 100, entry.painted.width, entry.painted.height,
                entry.painted.minX, entry.painted.midY))
        }
        // The claim being witnessed: in a leading column every glyph starts on ONE line,
        // sits on ONE centre line, and reaches ONE extent.
        let target = slot.width * SidebarDensityProposalView.inkTargetFraction
        for entry in alignedInk {
            let extent = max(entry.painted.width, entry.painted.height)
            try expect(abs(extent - target) <= 0.75,
                       "'\(entry.name)' paints \(String(format: "%.2f", extent))pt of ink "
                       + "in a \(Int(slot.width))pt slot, not the \(target)pt every other "
                       + "status glyph paints")
            try expect(abs(entry.painted.minX - slot.minX) <= 0.75,
                       "'\(entry.name)' starts its ink at "
                       + String(format: "%.2f", entry.painted.minX)
                       + "pt, not the slot's leading edge — a leading column with a ragged "
                       + "left margin is the defect this alignment exists to fix")
            try expect(abs(entry.painted.midY - slot.midY) <= 0.75,
                       "'\(entry.name)' sits on centre line "
                       + String(format: "%.2f", entry.painted.midY)
                       + "pt rather than \(slot.midY)pt")
        }
        // A floor under the fix itself, and one that has already earned its place: the
        // FIRST version of this normalisation equalised each glyph's largest dimension,
        // and this check proved that corrects essentially nothing — SF Symbols agree on
        // that dimension to within 5%. What actually varies is width, and therefore the
        // left edge of a centred glyph. If that spread ever collapses, the alignment is
        // no longer doing work and this witness would be theatre.
        let rawLeftEdges = alignedInk.map { (1 - $0.raw.width) / 2 }
        if let low = rawLeftEdges.min(), let high = rawLeftEdges.max() {
            let spreadPt = (high - low) * slot.width
            print(String(
                format: "SidebarScreenshotChecks: centring these glyphs instead would "
                    + "scatter their left edges over %.2fpt of a %.0fpt slot",
                spreadPt, slot.width))
            try expect(spreadPt > 0.75,
                       "centring would scatter the glyphs' left edges by only "
                       + String(format: "%.2f", spreadPt)
                       + "pt — below the tolerance this check asserts, so the alignment "
                       + "is correcting nothing and the glyph set must have changed")
        }

        try writeManifest(verdict: "PASS")

        if !skipped.isEmpty {
            print("SidebarScreenshotChecks: NOT rendered (deliberate): \(skipped.joined(separator: ", "))")
        }
        let dense = entries.filter { $0.fixture == "dense662" && $0.appearance == "darkAqua" }
        for entry in dense.sorted(by: { $0.widthRequestedPt < $1.widthRequestedPt }) {
            print(String(
                format: "SidebarScreenshotChecks: %.0fpt dark — card %.1fpt, pitch %.1fpt, "
                    + "%d complete rows in %.0fpt",
                entry.widthRequestedPt, entry.cardHeightPt ?? 0, entry.pitchPt ?? 0,
                entry.completeRowsIn662pt ?? 0, entry.heightPt))
        }
        // Report BOTH numbers. The bare-inbox figure is what a probe measures; the
        // in-sidebar figure is what a person sees, because the shipped sidebar spends
        // part of the viewport on its own header.
        let chrome = measureSidebarInboxHeight(
            sidebarHeight: denseViewportHeight, width: 280,
            appearance: NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing())
        print(String(
            format: "SidebarScreenshotChecks: a %.0fpt sidebar gives the inbox %.1fpt "
                + "(%.1fpt of chrome)",
            denseViewportHeight, chrome.inbox, chrome.chrome))
        for proposal in SidebarDensityProposal.all {
            print(String(
                format: "SidebarScreenshotChecks: proposal %@ — card %.0fpt, pitch %.0fpt, "
                    + "%d rows in a bare %.0fpt inbox, %d rows inside a %.0fpt SIDEBAR",
                proposal.id, proposal.cardHeight, proposal.pitch,
                proposal.completeRows(in: denseViewportHeight), denseViewportHeight,
                proposal.completeRows(in: chrome.inbox), denseViewportHeight))
        }
        print("SidebarScreenshotChecks passed: \(entries.count) images, "
              + "\(widths.count) widths x \(appearances.count) appearances, "
              + "manifest at \(directory.appendingPathComponent("manifest.json").path)")
    }
}

// MARK: - Program 96 fixtures

/// Rows that exercise what program 96 ADDS, which neither existing corpus can.
///
/// The production corpus shows what the app makes — impoverished, on purpose. The
/// queue-94 capability corpus shows every state queue 94 knows about. Neither has a
/// finished-and-unlooked-at row, because until rule 2 there was no such thing: a
/// completed turn and a completed turn you walked away from rendered identically,
/// which is the whole problem.
///
/// A FIXTURE, and named one. Nothing here is evidence about the product — it is the
/// set of rows the new design has to have an answer for.
/// The hover card earns its place only if it says things the ROW does not.
///
/// §4.3 lets a narrowing row drop facts on the stated condition that they survive
/// in the tooltip. So the assertion is not "a card appeared" — it is that the card
/// carries zone, harness and a branch mismatch, three facts the sidebar has never
/// rendered anywhere, and that the row beside it is still not rendering them.
///
/// Also witnesses `withUnconfirmed`, which rebuilds a row by hand on the live path
/// and would silently drop every one of those fields.
@MainActor
private func assertHoverCardCarriesWhatTheRowCannot(
    inbox: AgentInboxView, rows: [AgentInboxRow]
) throws {
    guard let subject = rows.first(where: { $0.checkedOutBranch != nil }) else {
        throw SidebarScreenshotChecks.Failure(description:
            "the 96 fixture no longer contains a branch-mismatch row — the card's "
            + "only warning line is untested")
    }
    let frozen = subject.withUnconfirmed(true)
    guard frozen.zoneName == subject.zoneName, frozen.harness == subject.harness,
          frozen.checkedOutBranch == subject.checkedOutBranch else {
        throw SidebarScreenshotChecks.Failure(description:
            "withUnconfirmed dropped the card's fields (zone \(frozen.zoneName ?? "nil"), "
            + "harness \(frozen.harness ?? "nil"), checkout \(frozen.checkedOutBranch ?? "nil")) "
            + "— it rebuilds the row by hand and runs on the live path")
    }

    inbox.hoverCardEnabled = true
    // Fire the dwell instead of sleeping through it.
    inbox.hoverCardScheduler = { _, work in work(); return {} }
    defer {
        inbox.hoverCardEnabled = false
        inbox.hoverCardScheduler = nil
    }
    guard inbox.hoverRowForQA(id: subject.id) else {
        throw SidebarScreenshotChecks.Failure(description:
            "could not hover the mismatch row — it is not on screen, so the card "
            + "below would be measuring a row nobody can point at")
    }
    guard inbox.isHoverCardVisibleForQA else {
        throw SidebarScreenshotChecks.Failure(description: "hovering a row did not open the card")
    }
    let lines = inbox.hoverCardLinesForQA
    for expected in ["Review", "Codex", "Checked out on main"] {
        guard lines.contains(where: { $0.contains(expected) }) else {
            throw SidebarScreenshotChecks.Failure(description:
                "the hover card does not carry '\(expected)' — it said \(lines)")
        }
    }
    // The other half of the claim: the ROW still does not say these, which is why
    // the card has to. If a future row starts printing them, this fires and the
    // duplication gets decided deliberately.
    let rowText = inbox.qaMaterializedRowCells
        .filter { $0.qaAgentID == subject.id }
        .flatMap { [$0.qaTitle, $0.qaStateLabel, $0.qaMeta, $0.qaBranch, $0.qaProject] }
    for hidden in ["Review", "Codex"] {
        guard !rowText.contains(where: { $0.contains(hidden) }) else {
            throw SidebarScreenshotChecks.Failure(description:
                "the row now prints '\(hidden)' as well as the card — decide which "
                + "owns it rather than saying it twice")
        }
    }
    inbox.hoverRowForQA(id: nil)
    guard !inbox.isHoverCardVisibleForQA else {
        throw SidebarScreenshotChecks.Failure(description: "the card outlived the hover that opened it")
    }
    print(
        "SidebarScreenshotChecks: hover card carries \(lines.count) lines the row cannot "
        + "— zone, harness and the branch mismatch, and withUnconfirmed keeps all three")
}

@MainActor
enum AgentInbox96Fixtures {
    static func rows(now: Date) -> [AgentInboxRow] {
        func row(
            _ index: Int, _ title: String, state: InboxState,
            attention: InboxAttention = .none, branch: String? = nil,
            model: String? = "anthropic/claude-opus-4-6", elapsed: TimeInterval? = nil,
            lastActive: TimeInterval? = nil,
            // The hover card's half of the row. None of it is drawn in the band —
            // that is the point: §4.3 lets the row drop facts only because the
            // tooltip keeps them, so the fixture has to carry facts the row does
            // NOT show or the card would be demonstrating nothing.
            zone: String? = nil, harness: String? = nil, checkedOut: String? = nil
        ) -> AgentInboxRow {
            AgentInboxRow(
                id: UUID(uuidString: String(format: "00000096-0000-0000-0000-%012d", index))!,
                title: title, projectName: "Array", state: state, attention: attention,
                model: model, branch: branch, elapsed: elapsed,
                lastActiveAt: lastActive.map { now.addingTimeInterval(-$0) },
                createdAt: now.addingTimeInterval(-Double(index) * 600),
                zoneName: zone, harness: harness, checkedOutBranch: checkedOut)
        }
        let nudgeDelay = AgentInbox96CellView.settleNudgeDelay
        return [
            row(1, "Stop the camera resizing every tile view", state: .working,
                branch: "agent/retained-world-plane", model: "openai-codex/gpt-5.6-sol",
                elapsed: 84, zone: "Canvas", harness: "Codex"),
            row(2, "Apply the measured-fit sacrifice order", state: .approval,
                branch: "agent/measured-fit", zone: "Sidebar", harness: "Claude Code"),
            // The three harnesses side by side. On the ROW these are three identical
            // agents — P3.1's complaint that a Pi agent is indistinguishable from
            // the others is a fact about the row, and the card is where it stops
            // being true.
            row(3, "Choose the provider mark set", state: .input,
                branch: "agent/brand-marks", model: "google/gemini-3-pro",
                zone: "Sidebar", harness: "Pi"),
            // The mismatch: assigned agent/terminal-outcomes, checkout sitting on
            // main. The row prints one branch and cannot say they disagree.
            row(4, "Persist an honest terminal event", state: .failed,
                attention: .unread, branch: "agent/terminal-outcomes",
                model: "xai/grok-4-2", elapsed: 720,
                zone: "Review", harness: "Codex", checkedOut: "main"),
            // A finished row's whole life, in four rows. Step one, twice: DONE and
            // unread. Same word, same mint, same check — only the number differs,
            // which is the only thing that actually differs.
            row(5, "Write the S0 density review", state: .ready, attention: .unread,
                branch: "agent/s0-review", model: "mistralai/mistral-large-3",
                lastActive: 90, zone: "Review", harness: "Pi"),
            row(6, "Budget chrome repaints per camera step", state: .ready,
                attention: .unread, branch: "agent/perf-budgets",
                lastActive: nudgeDelay + 3600, zone: "Canvas", harness: "Claude Code"),
            // Step two: you looked at it. No word, no mark, no colour — looking is
            // the acknowledgement and silence is the reward. It keeps its age,
            // because "when did this land" is still a fair question.
            row(7, "Bound restore concurrency", state: .ready,
                branch: "agent/restore-bounds", model: "openai/gpt-5.6-sol",
                lastActive: 1_320),
            // Step three: read, silent, and left lying there. This is the row the
            // settle nudge is for — the graveyard you read past to find live work.
            row(8, "تحديث الشريط الجانبي · סוכן עם שם ארוך", state: .ready,
                branch: "agent/rtl-truncation", model: "xai/grok-4-2",
                lastActive: 9_600),
        ]
    }
}

// MARK: - Density proposals (gate S0)

/// The three static row densities S0 asks Dylan to choose between. Geometry only —
/// these are proposals about pitch, not about content.
struct SidebarDensityProposal: Sendable {
    let id: String
    let title: String
    /// Top inset, first-band height, gap, title height, gap, third-band height, bottom
    /// inset — the arithmetic the design states, kept as data so the drawing and the
    /// reported numbers cannot disagree.
    let insetV: CGFloat
    let bandTop: CGFloat
    let gapTop: CGFloat
    let bandTitle: CGFloat
    let gapBottom: CGFloat
    let bandDetail: CGFloat
    let gapBetweenRows: CGFloat
    let rationale: String

    var cardHeight: CGFloat {
        insetV + bandTop + gapTop + bandTitle + gapBottom + bandDetail + insetV
    }
    var pitch: CGFloat { cardHeight + gapBetweenRows }

    /// The list opens with an outer gutter before the first card, so the rows that fit
    /// are `(viewport - gutter) / pitch` — NOT `(viewport + gap) / pitch`, which
    /// over-counts by one. The difference is caught by a teeth check: proposal C is
    /// today's geometry, so this must agree with the count measured off the real
    /// sidebar's painted cells, and the first version of this formula did not.
    static let outerGutter: CGFloat = 4

    func completeRows(in viewportHeight: CGFloat) -> Int {
        guard pitch > 0 else { return 0 }
        return Int(((viewportHeight - Self.outerGutter) / pitch).rounded(.down))
    }

    /// A — the documented target: `8 + 14 + 3 + 17 + 2 + 14 + 8 = 66`, 68 pt pitch.
    static let a = SidebarDensityProposal(
        id: "A", title: "66 pt card / 68 pt pitch — documented target",
        insetV: 8, bandTop: 14, gapTop: 3, bandTitle: 17, gapBottom: 2, bandDetail: 14,
        gapBetweenRows: 2,
        rationale: "§4.3 as written. Three bands, every one carrying text.")

    /// B — the comfort midpoint, if A reads cramped at 220 pt.
    static let b = SidebarDensityProposal(
        id: "B", title: "72 pt card / 75 pt pitch — comfort midpoint",
        insetV: 10, bandTop: 14, gapTop: 3, bandTitle: 18, gapBottom: 3, bandDetail: 14,
        gapBetweenRows: 3,
        rationale: "Same anatomy, 10 pt insets and 3 pt band gaps.")

    /// C — today's MEASURED geometry drawn with the intended anatomy, so the
    /// comparison is against what ships rather than against prose. 79/83 comes from
    /// `--agent-inbox-check`'s own output, not from a document.
    static let c = SidebarDensityProposal(
        id: "C", title: "79 pt card / 83 pt pitch — today, measured",
        insetV: 12, bandTop: 14, gapTop: 4, bandTitle: 19, gapBottom: 4, bandDetail: 14,
        gapBetweenRows: 4,
        rationale: "Current shipping pitch, with the bands the design wants filled in.")

    static let all: [SidebarDensityProposal] = [a, b, c]
}

/// What a row CONTAINS and how its state is emphasised — deliberately separate from
/// `SidebarDensityProposal`, which is only about PITCH.
///
/// They were one thing in the first mock, and that made every image change two variables
/// at once. Dylan's feedback after seeing it was about anatomy, not height ("not the
/// biggest fan of the provider text… maybe we can experiment with slightly more visual
/// aid for the status"), so the two now vary independently: the S0 pitch images all use
/// the same anatomy, and the status sweep all uses the same pitch.
struct SidebarRowAnatomy: Sendable {
    /// How the card's own edge marks a state. All of these paint ONLY for the states
    /// that want a person — see `isAttention`.
    enum Border: String, Sendable {
        case none
        /// A 3 pt bar down the leading edge.
        case rail
        /// The same, at 2 pt.
        case railThin
        /// A hairline outline around the whole card.
        case outline
        /// The canvas's own focused-tile language, brought inside the sidebar:
        /// `FocusBorderOverlayView.lineWidth` 1.5 and `dashPattern` [6, 4] at radius 6,
        /// quoted from `CanvasNSView.swift:5891-5892` rather than invented, so a marked
        /// row and a focused tile say the same thing in the same accent.
        case dashed
        /// The leading third of that outline only — a `[` around the card's leading edge,
        /// corners included.
        case bracket
    }

    /// Where the status glyph sits.
    enum IconPlacement: String, Sendable {
        /// Beside the state word at the right of band 1. What the mock has always done.
        case trailing
        /// At the FRONT of band 1 on every row, forming a column you can scan without
        /// reading. Requires the ink alignment below or the shapes do not line up.
        case leading
    }

    let id: String
    let label: String
    let border: Border
    let iconPlacement: IconPlacement
    /// §4.3's width-sacrifice ladder *ends* by dropping model text and keeping the mark.
    /// Dylan asked to start there — T3 Code carries no model name at all. The exact
    /// model id must still be reachable in tooltip and accessibility detail (§4.3); a
    /// static mock cannot show that, so it is called out in the review instead.
    let showsModelText: Bool

    /// The first mock drew the status icon at 11 pt, at which Array's own gyro throbber
    /// reduces to a couple of dots — Dylan said so. 14 pt is the smallest size at which
    /// the two planes are separable.
    var statusIconSide: CGFloat { iconPlacement == .leading ? 16 : 14 }

    var borderWidth: CGFloat {
        switch border {
        case .none: return 0
        case .rail: return 3
        case .railThin: return 2
        case .outline: return 1
        case .dashed, .bracket: return 1.5
        }
    }
    /// The throbber gets its OWN slot, at the size it was drawn for.
    /// `DualPlaneGyroTiltedThinkingIndicatorView.Metrics.side` is 18 pt, its guide rings
    /// are `side * 0.036` wide at 30% alpha, and its orbit radius is `side * 0.296`. At
    /// 11 pt — the first mock — that is a 0.55 pt invisible ring around a 3.3 pt orbit,
    /// which is why Dylan saw a couple of dots. Shrinking it further is not a size
    /// choice, it is a different glyph.
    var workingIconSide: CGFloat { 18 }
    /// A leading edge treatment reserves its lane on EVERY row, not only the ones that
    /// paint it, or the text jitters row to row. That reserved width is a real cost and
    /// should be visible in the image. An outline or a dash sits on the card's own edge,
    /// inside the 10 pt inset, and costs nothing.
    var leadingGutter: CGFloat {
        switch border {
        case .rail, .railThin, .bracket: return borderWidth + 3
        case .none, .outline, .dashed: return 0
        }
    }

    /// The anatomy every S0 pitch image uses: provider mark alone, no model text.
    static let markOnly = SidebarRowAnatomy(
        id: "markOnly", label: "mark only, state at the right",
        border: .none, iconPlacement: .trailing, showsModelText: false)

    /// Round four, and the sweep gets smaller because the decisions got made.
    ///
    /// Settled: the leading column stays, the glyph set is down to three, and the pill is
    /// gone. What is left open is whether the card still needs an EDGE treatment now that
    /// the column already marks the rows that matter — so all three carry the identical
    /// row content and differ only in what they draw at the card's leading edge.
    ///
    /// `outline` and `dashed` are dropped rather than re-rendered: `outline` was the
    /// heaviest of the five and its job is done better by `bracket`, and `dashed` reuses
    /// the canvas's focused-tile language, which already means something else on a screen
    /// where both surfaces are visible at once. Both remain in
    /// `qa-runs/2026-08-14T195203Z/` if they want another look.
    ///
    /// The control is still `proposals/proposalA-280x662-*`: same pitch, same width, no
    /// edge treatment, glyph beside its word instead of leading. It is deliberately not
    /// re-emitted here; a byte-identical image under a second name is the
    /// relabelled-duplicate trap.
    static let statusExperiments: [SidebarRowAnatomy] = [
        SidebarRowAnatomy(
            id: "attentionColumn", label: "attention column only, no card border",
            border: .none, iconPlacement: .leading, showsModelText: false),
        SidebarRowAnatomy(
            id: "attentionRail", label: "attention column + 2 pt rail",
            border: .railThin, iconPlacement: .leading, showsModelText: false),
        SidebarRowAnatomy(
            id: "attentionBracket", label: "attention column + leading bracket",
            border: .bracket, iconPlacement: .leading, showsModelText: false),
    ]
}

/// A throwaway mock of the §1 intended row anatomy at one proposed density.
///
/// Deliberately a plain `NSView` and NOT `TokenThemed`: it is not production, it must
/// not enter the ui-probe census, and it exists only to be looked at once at gate S0.
@MainActor
final class SidebarDensityProposalView: NSView {
    private let proposal: SidebarDensityProposal
    private let anatomy: SidebarRowAnatomy
    private(set) var drawnRowCount = 0

    /// The states that are asking for a person, as opposed to reporting one.
    ///
    /// The single loudest thing about the T3 Code reference is that most rows carry no
    /// state at all, so the few that do are impossible to miss. Both conditional
    /// treatments below use this one predicate, so the sweep varies only HOW attention
    /// is drawn, never WHEN.
    private static func isAttention(_ state: String) -> Bool {
        state.hasPrefix("Working") || state.hasPrefix("Approval")
            || state.hasPrefix("Input") || state.hasPrefix("Failed")
    }

    /// Content chosen so the comparison is honest at 220 pt: a long title, a bidi
    /// title, a middle-truncating branch, and the terminal outcomes §4.6 wants
    /// distinguished.
    /// §8.2 forbids state read by colour alone, so every state carries a symbol as
    /// well as its word. SF Symbols here rather than bundled art: these are Apple's
    /// own glyphs, they need no provenance review, and the mock's job is to show the
    /// SHAPE of the row. Vendor provider logos are a different problem — see P3.1.
    /// Three glyphs, and most rows get none.
    ///
    /// Ruled 2026-08-14, and it is a better rule than the one it replaced. Earlier rounds
    /// gave every state its own icon; the leading column then ran a solid line of ticks
    /// down the list, so the rows that were *finished* drew as much of the eye as the rows
    /// that were *broken*. The icon's job is not to name the state — the word beside it
    /// already does that — it is to answer one question at a glance: **is anything
    /// happening here that concerns me?**
    ///
    /// So the set collapses to the three answers worth interrupting for:
    ///
    /// - **running** — the app's own throbber, drawn by `drawWorkingIndicator`
    /// - **wants you** — one raised hand, for BOTH approval and input
    /// - **broke** — the error triangle
    ///
    /// Done, Stopped and Cancelled draw nothing. The state word and its colour still
    /// carry them, for the glance that comes after the first one.
    ///
    /// **Approval and input deliberately share this glyph, and that is not the defect
    /// P0.1 found.** That defect was the two sharing a *word* — the row said "Blocked" and
    /// you could not tell which. Here the icon says "you are needed" and the word still
    /// says which kind, so the two layers each carry something.
    private static func stateSymbol(_ state: String) -> String? {
        // Working draws the app's OWN throbber, not a symbol — see `drawWorkingIndicator`.
        if state.hasPrefix("Working") { return nil }
        if state.hasPrefix("Approval") || state.hasPrefix("Input") { return "hand.raised.fill" }
        if state.hasPrefix("Failed") { return "exclamationmark.triangle.fill" }
        return nil
    }

    /// The real vendor marks, read from the ticket's `brand-marks/` directory at render
    /// time. DESIGN-TIME ONLY: nothing here is bundled into the `.app` and the shipped
    /// sidebar does not read them — that pipeline, with its offline bundle witness, is
    /// P3.1. §10 forbids runtime fetching and nothing here fetches; the files are on
    /// disk with a provenance manifest beside them.
    ///
    /// **These are drawn as flat template marks in the theme's own colour**, at Dylan's
    /// direction after the T3 Code reference, whose trailing icons are all one muted
    /// monochrome. Only the mark's alpha coverage is used; the file's own colours are
    /// discarded.
    ///
    /// §4.5 says the opposite — *"do not tint vendor marks unless the brand rules
    /// explicitly permit template treatment"* — so this is a **design-time mock choice,
    /// not a settled one**. Anthropic's file carries its own `#D97757` and several
    /// vendors publish monochrome rules that a blanket recolour may or may not satisfy.
    /// Resolving it is the first gate of P3.1, per-vendor, and `brand-marks/PROVENANCE.md`
    /// records it as open.
    ///
    /// Because the colour now comes from the theme, the per-appearance *files* no longer
    /// carry information: one canonical file per vendor is loaded for its silhouette.
    private static func providerMark(_ model: String) -> NSImage? {
        let key: String
        if model.hasPrefix("GPT") { key = "openai-light" }
        else if model.hasPrefix("Opus") || model.hasPrefix("Sonnet") { key = "anthropic" }
        else if model.hasPrefix("Grok") { key = "xai-light" }
        else if model.hasPrefix("Gemini") { key = "gemini" }
        else { return nil }
        if let cached = markCache[key] { return cached }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // ContinuumRevived
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(
                "docs/38-tickets/96-agent-sidebar-product-redesign/brand-marks/\(key).svg")
        let image = NSImage(contentsOf: url)
        markCache[key] = image
        return image
    }

    /// Parsed once, not once per row per image.
    private static var markCache: [String: NSImage?] = [:]

    private static let rows: [(placement: String, state: String, title: String,
                               branch: String, model: String)] = [
        ("Array › Sidebar", "Done · 4m", "Replace sidebar identity and completion UX",
         "agent/sidebar-redesign", "GPT-5.6 Sol"),
        ("Array › Canvas", "Working · 1m 24s", "Stop the camera resizing every tile view",
         "agent/retained-world-plane", "Opus"),
        ("Array › Sidebar", "Approval", "Apply the measured-fit sacrifice order",
         "agent/measured-fit", "GPT-5.6 Sol"),
        ("Array › Agents", "Failed · 12m", "Persist an honest terminal event",
         "agent/terminal-outcomes", "Opus"),
        // Fifth row, not tenth: the last row is clipped by the caption at 662 pt, and
        // this is the row the "mark only" decision has to be judged on.
        ("Array › Agents", "Stopped · 30m", "Wire acknowledgement to effective focus",
         "agent/ack-watermark", "Gemini 3 Pro"),
        // A vendor whose mark exists but whose name never appears, and one whose mark
        // does NOT exist. With the model text dropped, that second row is the whole
        // tradeoff in one line: the agent becomes anonymous except for a two-letter
        // badge. Keep both in view so the cost of "mark only" is looked at, not assumed.
        ("array-scratch", "Cancelled · 1h", "تحديث الشريط الجانبي · סוכן עם שם ארוך",
         "agent/rtl-truncation", "Grok 4.2"),
        ("Array › Sidebar", "Input", "Choose the provider mark set",
         "agent/brand-marks", "Opus"),
        // Gemini has a mark now, so the no-mark fallback moves here rather than
        // disappearing from the artifact. §4.5's list still leaves OpenRouter, Mistral,
        // Groq and Cerebras unbundled, and the review has to keep showing what one of
        // those rows looks like.
        ("Array › Docs", "Done · 3h", "Write the S0 density review",
         "agent/s0-review", "Mistral Large 3"),
        ("Array › Canvas", "Done · 5h", "Budget chrome repaints per camera step",
         "agent/perf-budgets", "Opus"),
        ("Array › Agents", "Done · 1d", "Bound restore concurrency",
         "agent/restore-bounds", "Sonnet"),
    ]

    /// Every distinct status symbol the mock actually draws, derived from its own rows.
    ///
    /// The alignment witness reads this rather than a list of its own, so it can never
    /// end up measuring a glyph the mock stopped drawing — or, worse, silently skip one
    /// it started drawing. The set shrank from six to two the moment Dylan cut the icon
    /// list, and this is what keeps the check honest about that.
    static var statusSymbolsInUse: [String] {
        var seen: [String] = []
        for row in rows {
            guard let symbol = stateSymbol(row.state), !seen.contains(symbol) else { continue }
            seen.append(symbol)
        }
        return seen
    }

    init(proposal: SidebarDensityProposal, anatomy: SidebarRowAnatomy, frame: NSRect) {
        self.proposal = proposal
        self.anatomy = anatomy
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = isDark
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
        background.setFill()
        bounds.fill()

        let primary = isDark ? NSColor.white : NSColor.black
        let secondary = primary.withAlphaComponent(0.62)
        let card = isDark
            ? NSColor(calibratedWhite: 1, alpha: 0.06)
            : NSColor(calibratedWhite: 0, alpha: 0.05)

        // §4.3: a 4 pt outer gutter each side, so a selected fill never reads as a
        // full-width slab.
        let gutter: CGFloat = 4
        let insetH: CGFloat = 10
        var y: CGFloat = gutter
        drawnRowCount = 0

        for (index, row) in Self.rows.enumerated() {
            let cardRect = NSRect(
                x: gutter, y: y,
                width: bounds.width - gutter * 2, height: proposal.cardHeight)
            guard cardRect.minY < bounds.height else { break }
            // The second row stands in for "route-active": the interaction ladder is
            // §4.4's business, but a density judgement needs to see one filled row.
            if index == 1 {
                card.setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 6, yRadius: 6).fill()
            }

            // The rail's lane is reserved on every row so text never jitters; only
            // attention rows paint into it.
            let textLeft = cardRect.minX + insetH + anatomy.leadingGutter
            let textRight = cardRect.maxX - insetH
            let contentWidth = textRight - textLeft
            var bandY = cardRect.minY + proposal.insetV

            let accent = stateColor(row.state, primary: primary)
            if Self.isAttention(row.state) {
                drawBorder(anatomy.border, in: cardRect, width: anatomy.borderWidth,
                           color: accent)
            }

            // Band 1 — placement on the left, state and time on the right (or leading,
            // depending on the treatment under review).
            let isWorking = row.state.hasPrefix("Working")
            let iconSide = isWorking ? anatomy.workingIconSide : anatomy.statusIconSide
            let iconGap: CGFloat = 4
            let symbol = Self.stateSymbol(row.state)
            let hasIcon = symbol != nil || isWorking
            let stateTextWidth = min(
                contentWidth * 0.55, measure(row.state, size: 11).width + 2)
            let bandTop = proposal.bandTop
            // A leading column lines up left EDGES; a glyph sitting beside its own word
            // centres. See `InkAlignment`.
            let inkAlignment: SidebarDensityProposalView.InkAlignment =
                anatomy.iconPlacement == .leading ? .leadingEdge : .centred
            func paintStatusIcon(in rect: NSRect) {
                if isWorking {
                    drawWorkingIndicator(in: rect)
                } else if let symbol {
                    drawAlignedSymbol(
                        symbol, in: rect, color: accent, alignment: inkAlignment)
                }
            }
            func drawPlacement(from left: CGFloat, to right: CGFloat) {
                draw(row.placement, at: NSRect(
                    x: left, y: bandY, width: max(0, right - left), height: bandTop),
                     size: 11, color: secondary, alignment: .left)
            }
            func drawStateText(rightEdge: CGFloat) {
                draw(row.state, at: NSRect(
                    x: rightEdge - stateTextWidth, y: bandY,
                    width: stateTextWidth, height: bandTop),
                     size: 11, color: accent, alignment: .right)
            }

            switch anatomy.iconPlacement {
            case .leading:
                // The slot is NOT reserved when nothing is drawn in it.
                //
                // It was, on the theory that a reserved lane keeps the column straight.
                // It does not need to: the ICONS are the column, and they are pinned to
                // `textLeft` and ink-aligned to each other, so the column is straight
                // whether or not the text beside them moves. Reserving the lane only
                // indented band 1 away from the title and branch below it — on seven rows
                // out of ten, for nothing. A row with no icon now runs all three bands
                // flush; a row with one indents band 1 by exactly the space the icon
                // fills, which reads as the icon occupying it rather than as a margin.
                if hasIcon {
                    paintStatusIcon(in: NSRect(
                        x: textLeft, y: bandY + (bandTop - iconSide) / 2,
                        width: iconSide, height: iconSide))
                }
                let after = textLeft + (hasIcon ? iconSide + iconGap : 0)
                drawPlacement(from: after, to: textRight - stateTextWidth - 6)
                drawStateText(rightEdge: textRight)

            case .trailing:
                let stateWidth = stateTextWidth + (hasIcon ? iconSide + iconGap : 0)
                drawPlacement(from: textLeft, to: textRight - stateWidth - 6)
                if hasIcon {
                    paintStatusIcon(in: NSRect(
                        x: textRight - stateWidth, y: bandY + (bandTop - iconSide) / 2,
                        width: iconSide, height: iconSide))
                }
                drawStateText(rightEdge: textRight)
            }
            bandY += proposal.bandTop + proposal.gapTop

            // Band 2 — the subject, on its own line, never sacrificed.
            draw(row.title, at: NSRect(
                x: textLeft, y: bandY, width: contentWidth, height: proposal.bandTitle),
                 size: 13, color: primary, alignment: .left, semibold: true)
            bandY += proposal.bandTitle + proposal.gapBottom

            // Band 3 — branch left (middle-truncating), provider mark right.
            //
            // The model NAME is drawn only when the anatomy asks for it. Dropping it is
            // Dylan's ask after the T3 Code reference, and the consequence is deliberately
            // visible in the last row: a provider with no bundled mark falls back to a
            // two-letter badge and the agent's model becomes unreadable on the surface.
            //
            // When there is NO mark, the row falls back to the model's NAME rather than
            // to §4.5's two-character badge. The badge was in the mock and Dylan's
            // reaction to it was "what is this supposed to be" — which is the answer.
            // `GE` identifies nothing; a monogram only works once you already know the
            // set it is drawn from, and a person meeting a new provider does not. Mark or
            // name, never a cipher. See the review for what this asks of §4.5.
            let mark = Self.providerMark(row.model)
            let chipSide: CGFloat = 14
            let chipGap: CGFloat = 6
            let showsName = anatomy.showsModelText || mark == nil
            let modelTextWidth = showsName
                ? min(contentWidth * 0.45, measure(row.model, size: 11).width + 2)
                : 0
            let trailingWidth = (mark == nil ? 0 : chipSide)
                + (showsName ? modelTextWidth + (mark == nil ? 0 : chipGap) : 0)
            let branchGlyph: CGFloat = 11
            let branchGlyphGap: CGFloat = 4
            drawSymbol("arrow.triangle.branch", in: NSRect(
                x: textLeft, y: bandY + (proposal.bandDetail - branchGlyph) / 2,
                width: branchGlyph, height: branchGlyph), color: secondary)
            let branchLeft = textLeft + branchGlyph + branchGlyphGap
            draw(row.branch, at: NSRect(
                x: branchLeft, y: bandY,
                width: max(0, textRight - trailingWidth - 6 - branchLeft),
                height: proposal.bandDetail),
                 size: 11, color: secondary, alignment: .left, middleTruncating: true)
            let chipRect = NSRect(
                x: textRight - trailingWidth,
                y: bandY + (proposal.bandDetail - chipSide) / 2,
                width: chipSide, height: chipSide)
            if let mark {
                // Flat, in the theme's colour — see `providerMark`, and the §4.5 caveat
                // that makes this a mock choice rather than a shipping one.
                drawImage(mark, in: chipRect, tint: primary.withAlphaComponent(0.72))
            }
            if showsName {
                draw(row.model, at: NSRect(
                    x: textRight - modelTextWidth, y: bandY,
                    width: modelTextWidth, height: proposal.bandDetail),
                     size: 11, color: secondary, alignment: .right)
            }

            drawnRowCount += 1
            y += proposal.pitch
        }

        // Label the variant in the image itself, so a screenshot cannot be mistaken
        // for another proposal once it is pasted into a review.
        let caption = anatomy.id == SidebarRowAnatomy.markOnly.id
            ? "\(proposal.id) · \(proposal.title)"
            : "\(proposal.id) pitch · \(anatomy.label)"
        let captionHeight: CGFloat = 16
        let captionRect = NSRect(
            x: gutter, y: bounds.height - captionHeight - 2,
            width: bounds.width - gutter * 2, height: captionHeight)
        background.withAlphaComponent(0.92).setFill()
        captionRect.fill()
        draw(caption, at: captionRect, size: 10, color: primary, alignment: .left)
    }

    /// The card-edge treatments. `FocusBorderOverlayView` supplies the dash language and
    /// the 6 pt radius so a marked row and a focused tile are recognisably the same idea.
    private func drawBorder(
        _ border: SidebarRowAnatomy.Border, in cardRect: NSRect, width: CGFloat,
        color: NSColor
    ) {
        let radius: CGFloat = 6
        switch border {
        case .none:
            return

        case .rail, .railThin:
            let rail = NSRect(
                x: cardRect.minX + 3, y: cardRect.minY + 6,
                width: width, height: cardRect.height - 12)
            color.setFill()
            NSBezierPath(roundedRect: rail, xRadius: width / 2, yRadius: width / 2).fill()

        case .outline, .dashed:
            // Stroke on the pixel centre, or half the line falls outside the card.
            let rect = cardRect.insetBy(dx: width / 2, dy: width / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = width
            if border == .dashed {
                var pattern = FocusBorderOverlayView.dashPattern.map { CGFloat($0.doubleValue) }
                path.setLineDash(&pattern, count: pattern.count, phase: 0)
            }
            color.setStroke()
            path.stroke()

        case .bracket:
            // The leading third of the same outline: clip to a strip at the leading edge
            // and stroke the whole rounded rect through it, so the two corners curve
            // exactly as the outline's do.
            let rect = cardRect.insetBy(dx: width / 2, dy: width / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = width
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(
                x: cardRect.minX - width, y: cardRect.minY - width,
                width: radius + 8, height: cardRect.height + width * 2)).setClip()
            color.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func stateColor(_ state: String, primary: NSColor) -> NSColor {
        if state.hasPrefix("Done") {
            return isDark ? NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.52, alpha: 1)
                          : NSColor(calibratedRed: 0.13, green: 0.51, blue: 0.27, alpha: 1)
        }
        if state.hasPrefix("Failed") {
            return isDark ? NSColor(calibratedRed: 0.94, green: 0.48, blue: 0.44, alpha: 1)
                          : NSColor(calibratedRed: 0.66, green: 0.15, blue: 0.11, alpha: 1)
        }
        // Working had no colour of its own in the first mock, so a rail or a pill on a
        // running agent came out grey — the treatment said "this row is notable" and the
        // colour said "this row is idle". Running is its own thing: not finished, not
        // blocked, not broken.
        if state.hasPrefix("Working") {
            return isDark ? NSColor(calibratedRed: 0.40, green: 0.68, blue: 0.96, alpha: 1)
                          : NSColor(calibratedRed: 0.10, green: 0.40, blue: 0.72, alpha: 1)
        }
        if state.hasPrefix("Approval") || state.hasPrefix("Input") {
            return isDark ? NSColor(calibratedRed: 0.96, green: 0.76, blue: 0.36, alpha: 1)
                          : NSColor(calibratedRed: 0.58, green: 0.40, blue: 0.05, alpha: 1)
        }
        return primary.withAlphaComponent(0.62)
    }

    /// Draw an image the right way up inside a FLIPPED view.
    ///
    /// The first version built its tinted copy with `NSImage(size:flipped: true)` and
    /// then drew it into this view, which is itself flipped — two flips, so every icon
    /// came out upside down. The tinted copy is now built unflipped and drawn with
    /// `respectFlipped: true`, which is the one place the flip belongs.
    private func drawImage(_ image: NSImage, in rect: NSRect, tint: NSColor?) {
        let drawable: NSImage
        // A translucent `sourceAtop` fill BLENDS with the source's own colour instead of
        // replacing it: Anthropic's `#D97757` under a 72%-black tint came out maroon in
        // Aqua rather than grey. Flatten with an opaque fill and apply the opacity at
        // draw time, so a mark's own palette can never leak through.
        let fraction = tint?.alphaComponent ?? 1
        if let tint = tint?.withAlphaComponent(1) {
            // Build the tinted copy at the DESTINATION size (×3 for crispness), not at
            // the source's own size: the vendor SVGs report 256 and 1024 pt, and a
            // 1024×1024 locked-focus bitmap per mark per row per image is a lot of
            // pixels to throw away on the way into a 14 pt slot.
            let scale: CGFloat = 3
            let size = NSSize(
                width: max(1, rect.width * scale), height: max(1, rect.height * scale))
            let copy = NSImage(size: size)
            copy.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            tint.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            copy.unlockFocus()
            drawable = copy
        } else {
            drawable = image
        }
        drawable.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: fraction,
            respectFlipped: true, hints: nil)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let image = Self.symbolImage(name) else { return }
        drawImage(image, in: rect, tint: color)
    }

    /// The same glyph, placed by its INK rather than by its bounding box.
    ///
    /// SF Symbols do not share an optical size. `exclamationmark.triangle.fill` is short
    /// and wide and sits low in its box; `stop.fill` fills nearly all of it;
    /// `slash.circle` is a thin ring with a large margin. Dropped into one fixed rect
    /// they land at visibly different sizes on visibly different centre lines — which is
    /// exactly what Dylan saw in the leading-icon column: "they are too different to look
    /// properly aligned because of the various shapes."
    ///
    /// So the placement is computed from each glyph's measured ink extent: scale the ink
    /// to one common target, then centre the ink — not the box — on the slot. The
    /// measurements are printed by the gate and the result is verified end-to-end by
    /// re-measuring what this method actually paints.
    private func drawAlignedSymbol(
        _ name: String, in slot: NSRect, color: NSColor,
        alignment: SidebarDensityProposalView.InkAlignment = .centred
    ) {
        guard let image = Self.symbolImage(name), let ink = Self.symbolInk(name) else {
            drawSymbol(name, in: slot, color: color)
            return
        }
        drawImage(
            image, in: Self.alignedRect(slot: slot, ink: ink, alignment: alignment),
            tint: color)
    }

    /// Which edge of the ink to line up.
    ///
    /// Measuring the glyph set answered a question I had guessed at wrongly. Their
    /// LARGEST dimensions already agree to within 5% — SF Symbols are normalised on that.
    /// What differs is **width**: 68% of the box for `hand.raised.fill` against 86% for
    /// the circles. Centre those in one slot and their left edges land ~1.4 pt apart at
    /// 16 pt, which in a left-aligned column reads as a ragged margin — Dylan's "they
    /// seem all a little off". A leading column therefore aligns LEFT EDGES; a trailing
    /// glyph beside its word still centres.
    enum InkAlignment { case centred, leadingEdge }

    /// Where to draw the unit-square glyph image so its ink lands correctly on `slot` at
    /// a common extent. Pure arithmetic, so the gate can drive it directly.
    static func alignedRect(
        slot: NSRect, ink: NSRect, alignment: InkAlignment = .centred
    ) -> NSRect {
        let target = slot.width * Self.inkTargetFraction
        let side = target / max(max(ink.width, ink.height), 0.0001)
        let x = alignment == .leadingEdge
            ? slot.minX - (ink.minX * side)
            : slot.midX - (ink.midX * side)
        return NSRect(x: x, y: slot.midY - (ink.midY * side), width: side, height: side)
    }

    /// How much of the slot the ink fills. 0.82 leaves the glyph room to breathe beside
    /// 11 pt text without the slot itself changing size.
    static let inkTargetFraction: CGFloat = 0.82

    private static var symbolImageCache: [String: NSImage?] = [:]

    static func symbolImage(_ name: String) -> NSImage? {
        if let cached = symbolImageCache[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        symbolImageCache[name] = image
        return image
    }

    private static var symbolInkCache: [String: NSRect?] = [:]

    /// The glyph's ink extent as a fraction of a unit square, measured top-down so it
    /// composes with `respectFlipped:` drawing without a second flip.
    static func symbolInk(_ name: String) -> NSRect? {
        if let cached = symbolInkCache[name] { return cached }
        let ink = symbolImage(name).flatMap { measureInk(of: $0) }
        symbolInkCache[name] = ink
        return ink
    }

    /// Render into a square bitmap and find the alpha extent.
    static func measureInk(of image: NSImage, side: Int = 128) -> NSRect? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let box = NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // A template image draws in the current fill colour; force an opaque one so the
        // alpha scan measures the glyph and not a stroke's antialiased ghost.
        NSColor.black.setFill()
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return inkBounds(of: rep)
    }

    /// Alpha extent of a bitmap, normalised to its own size, measured top-down.
    static func inkBounds(of rep: NSBitmapImageRep, threshold: Int = 24) -> NSRect? {
        guard let data = rep.bitmapData else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow, pixelBytes = rep.bitsPerPixel / 8
        // Alpha is the last sample of each pixel in the RGBA reps built above and in the
        // premultiplied reps `bitmapImageRepForCachingDisplay` hands back.
        let alphaOffset = pixelBytes - 1
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * rowBytes
            for x in 0..<width where Int(data[row + x * pixelBytes + alphaOffset]) > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(
            x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height))
    }

    /// Array's OWN thinking indicator, posed at a fixed phase rather than imitated. The
    /// working row should show the glyph the app already uses while an agent responds,
    /// and `AgentThinkingIndicatorAnimating.setSnapshotPhase` exists precisely so a
    /// still can be taken of it.
    private func drawWorkingIndicator(in rect: NSRect) {
        let indicator = DualPlaneGyroTiltedThinkingIndicatorView(
            frame: NSRect(origin: .zero, size: rect.size))
        indicator.appearance = effectiveAppearance
        indicator.setReducedMotion(true)
        indicator.setSnapshotPhase(0.32)
        indicator.layoutSubtreeIfNeeded()
        guard let rep = indicator.bitmapImageRepForCachingDisplay(in: indicator.bounds)
        else { return }
        indicator.cacheDisplay(in: indicator.bounds, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        drawImage(image, in: rect, tint: nil)
    }

    private func measure(_ text: String, size: CGFloat) -> NSSize {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)])
    }

    private func draw(
        _ text: String, at rect: NSRect, size: CGFloat, color: NSColor,
        alignment: NSTextAlignment, semibold: Bool = false, middleTruncating: Bool = false
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = middleTruncating ? .byTruncatingMiddle : .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: semibold
                ? NSFont.systemFont(ofSize: size, weight: .semibold)
                : NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        // Vertically centre inside the band so the reported band heights are what the
        // eye actually sees.
        let textHeight = (text as NSString).size(withAttributes: attributes).height
        let y = rect.minY + max(0, (rect.height - textHeight) / 2)
        (text as NSString).draw(
            in: NSRect(x: rect.minX, y: y, width: rect.width, height: rect.height),
            withAttributes: attributes)
    }
}
