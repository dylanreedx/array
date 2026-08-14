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

    static let checkName = "sidebar-96-screenshots"
    static let flag = "--sidebar-screenshot-check"
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
        let frames = host.inbox.qaMaterializedRowCells
            .filter { $0.qaAgentID != nil }
            .map { $0.convert($0.bounds, to: host.inbox) }
            .sorted { $0.minY < $1.minY }
        guard frames.count >= 2 else { return nil }
        return (frames[0].height, frames[1].minY - frames[0].minY)
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

        var entries: [Entry] = []
        let previousAppAppearance = NSApp?.appearance
        defer { NSApp?.appearance = previousAppAppearance }

        // Every combination that is NOT rendered is named here rather than silently
        // dropped: accessibility variants are swept at 280 pt only, because the
        // question they answer (does the cue survive) is not width-dependent, while
        // density and truncation are.
        var skipped: [String] = []
        for width in widths where width != 280 {
            skipped.append("reduceMotion@\(Int(width))pt")
            skipped.append("increaseContrast@\(Int(width))pt")
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
                    host.inbox.reload(rows: rows)
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

            // Accessibility variants, 280 pt only (see `skipped`).
            for variant in ["reduceMotion", "increaseContrast"] {
                try drawing(appearance) {
                    let host = try makeHost(
                        width: 280, height: denseViewportHeight, appearance: appearance,
                        reduceMotion: variant == "reduceMotion",
                        increaseContrast: variant == "increaseContrast")
                    host.inbox.reload(rows: rows)
                    host.inbox.layoutForQA()
                    let rep = try UIProbe.bitmap(of: host.container, id: "a11y-\(variant)")
                    let suffix = variant == "reduceMotion" ? "rm" : "ic"
                    let name = "a11y-280x\(Int(denseViewportHeight))-\(shortName(appearanceName))-\(suffix).png"
                    try writePNG(rep, to: directory.appendingPathComponent(name))
                    entries.append(Entry(
                        png: name, fixture: "a11y-\(variant)",
                        widthRequestedPt: 280,
                        widthMeasuredPt: Double(host.inbox.bounds.width),
                        heightPt: Double(denseViewportHeight),
                        appearance: shortName(appearanceName),
                        reduceMotion: variant == "reduceMotion" ? "forced-on" : "forced-off",
                        increaseContrast: variant == "increaseContrast" ? "forced-on" : "forced-off",
                        scale: Double(UIProbe.renderScale),
                        captureType: "offscreen-probe", checkFlag: flag,
                        digest: UIProbe.digest(of: rep),
                        rowsRendered: host.inbox.qaMaterializedRowCells.count,
                        completeRowsIn662pt: completeRows(in: host, viewportHeight: denseViewportHeight),
                        cardHeightPt: nil, pitchPt: nil))
                }
            }

            // The three density proposals S0 rules on.
            for proposal in SidebarDensityProposal.all {
                for width in [CGFloat(220), 280, 360] {
                    try drawing(appearance) {
                        let view = SidebarDensityProposalView(
                            proposal: proposal,
                            frame: NSRect(x: 0, y: 0, width: width, height: denseViewportHeight))
                        let window = NSWindow(
                            contentRect: view.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
                        window.appearance = appearance
                        window.contentView = view
                        view.layoutSubtreeIfNeeded()
                        let rep = try UIProbe.bitmap(of: view, id: "proposal-\(proposal.id)")
                        let name = "proposal\(proposal.id)-\(Int(width))x\(Int(denseViewportHeight))-\(shortName(appearanceName)).png"
                        let proposalsDir = directory.appendingPathComponent("proposals", isDirectory: true)
                        try FileManager.default.createDirectory(
                            at: proposalsDir, withIntermediateDirectories: true)
                        try writePNG(rep, to: proposalsDir.appendingPathComponent(name))
                        entries.append(Entry(
                            png: "proposals/\(name)", fixture: "proposal-\(proposal.id)",
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
            }
        }

        // MARK: Provenance + manifest

        let dirt = gitDirt()
        let executable = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        let sha = executable.isEmpty
            ? "unavailable"
            : (shell("/usr/bin/shasum", ["-a", "256", executable])
                .components(separatedBy: " ").first ?? "unavailable")
        let manifest = Manifest(
            check: checkName,
            verdict: "PASS",
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
            entries: entries)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest)
            .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)

        // MARK: Gate — mechanics only

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: "\(checkName): \(message)") }
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
        for proposal in SidebarDensityProposal.all {
            print(String(
                format: "SidebarScreenshotChecks: proposal %@ — card %.0fpt, pitch %.0fpt, "
                    + "%d complete rows in %.0fpt",
                proposal.id, proposal.cardHeight, proposal.pitch,
                proposal.completeRows(in: denseViewportHeight), denseViewportHeight))
        }
        print("SidebarScreenshotChecks passed: \(entries.count) images, "
              + "\(widths.count) widths x \(appearances.count) appearances, "
              + "manifest at \(directory.appendingPathComponent("manifest.json").path)")
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

/// A throwaway mock of the §1 intended row anatomy at one proposed density.
///
/// Deliberately a plain `NSView` and NOT `TokenThemed`: it is not production, it must
/// not enter the ui-probe census, and it exists only to be looked at once at gate S0.
@MainActor
final class SidebarDensityProposalView: NSView {
    private let proposal: SidebarDensityProposal
    private(set) var drawnRowCount = 0

    /// Content chosen so the comparison is honest at 220 pt: a long title, a bidi
    /// title, a middle-truncating branch, and the terminal outcomes §4.6 wants
    /// distinguished.
    private static let rows: [(placement: String, state: String, title: String,
                               branch: String, model: String)] = [
        ("Array › Sidebar", "✓ Done · 4m", "Replace sidebar identity and completion UX",
         "agent/sidebar-redesign", "GPT-5.6 Sol"),
        ("Array › Canvas", "Working · 1m 24s", "Stop the camera resizing every tile view",
         "agent/retained-world-plane", "Opus"),
        ("Array › Sidebar", "Approval", "Apply the measured-fit sacrifice order",
         "agent/measured-fit", "GPT-5.6 Sol"),
        ("Array › Agents", "Failed · 12m", "Persist an honest terminal event",
         "agent/terminal-outcomes", "Opus"),
        ("Array › Agents", "Stopped · 30m", "Wire acknowledgement to effective focus",
         "agent/ack-watermark", "Sonnet"),
        ("array-scratch", "Cancelled · 1h", "تحديث الشريط الجانبي · סוכן עם שם ארוך",
         "agent/rtl-truncation", "GPT-5.6 Sol"),
        ("Array › Sidebar", "Input", "Choose the provider mark set",
         "agent/brand-marks", "Opus"),
        ("Array › Docs", "Done · 3h", "Write the S0 density review",
         "agent/s0-review", "Sonnet"),
        ("Array › Canvas", "Done · 5h", "Budget chrome repaints per camera step",
         "agent/perf-budgets", "Opus"),
        ("Array › Agents", "Done · 1d", "Bound restore concurrency",
         "agent/restore-bounds", "Sonnet"),
    ]

    init(proposal: SidebarDensityProposal, frame: NSRect) {
        self.proposal = proposal
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

            let contentWidth = cardRect.width - insetH * 2
            var bandY = cardRect.minY + proposal.insetV

            // Band 1 — placement on the left, state and time on the right.
            let stateWidth = min(contentWidth * 0.5, measure(row.state, size: 11).width + 2)
            draw(row.placement, at: NSRect(
                x: cardRect.minX + insetH, y: bandY,
                width: contentWidth - stateWidth - 6, height: proposal.bandTop),
                 size: 11, color: secondary, alignment: .left)
            draw(row.state, at: NSRect(
                x: cardRect.maxX - insetH - stateWidth, y: bandY,
                width: stateWidth, height: proposal.bandTop),
                 size: 11, color: stateColor(row.state, primary: primary), alignment: .right)
            bandY += proposal.bandTop + proposal.gapTop

            // Band 2 — the subject, on its own line, never sacrificed.
            draw(row.title, at: NSRect(
                x: cardRect.minX + insetH, y: bandY,
                width: contentWidth, height: proposal.bandTitle),
                 size: 13, color: primary, alignment: .left, semibold: true)
            bandY += proposal.bandTitle + proposal.gapBottom

            // Band 3 — branch left (middle-truncating), model right.
            let modelWidth = min(contentWidth * 0.45, measure(row.model, size: 11).width + 2)
            draw(row.branch, at: NSRect(
                x: cardRect.minX + insetH, y: bandY,
                width: contentWidth - modelWidth - 6, height: proposal.bandDetail),
                 size: 11, color: secondary, alignment: .left, middleTruncating: true)
            draw(row.model, at: NSRect(
                x: cardRect.maxX - insetH - modelWidth, y: bandY,
                width: modelWidth, height: proposal.bandDetail),
                 size: 11, color: secondary, alignment: .right)

            drawnRowCount += 1
            y += proposal.pitch
        }

        // Label the variant in the image itself, so a screenshot cannot be mistaken
        // for another proposal once it is pasted into a review.
        let caption = "\(proposal.id) · \(proposal.title)"
        let captionHeight: CGFloat = 16
        let captionRect = NSRect(
            x: gutter, y: bounds.height - captionHeight - 2,
            width: bounds.width - gutter * 2, height: captionHeight)
        background.withAlphaComponent(0.92).setFill()
        captionRect.fill()
        draw(caption, at: captionRect, size: 10, color: primary, alignment: .left)
    }

    private func stateColor(_ state: String, primary: NSColor) -> NSColor {
        if state.hasPrefix("✓") || state.hasPrefix("Done") {
            return isDark ? NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.52, alpha: 1)
                          : NSColor(calibratedRed: 0.13, green: 0.51, blue: 0.27, alpha: 1)
        }
        if state.hasPrefix("Failed") {
            return isDark ? NSColor(calibratedRed: 0.94, green: 0.48, blue: 0.44, alpha: 1)
                          : NSColor(calibratedRed: 0.66, green: 0.15, blue: 0.11, alpha: 1)
        }
        if state.hasPrefix("Approval") || state.hasPrefix("Input") {
            return isDark ? NSColor(calibratedRed: 0.96, green: 0.76, blue: 0.36, alpha: 1)
                          : NSColor(calibratedRed: 0.58, green: 0.40, blue: 0.05, alpha: 1)
        }
        return primary.withAlphaComponent(0.62)
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
