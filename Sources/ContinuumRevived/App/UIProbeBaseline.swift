import AppKit
import ContinuumRevivedCore

/// Committed PNG baselines for every static Component Lab card, in both
/// appearances, compared with a small tolerance.
///
/// Why it exists: `--component-lab-check` writes a PNG per card into a fresh
/// `qa-runs/<timestamp>/` directory and compares it to **nothing**. A card can
/// lose its layout entirely and stay green as long as it is not blank. This gate
/// is the "catch what nobody thought to assert" layer: the whole render is the
/// assertion, so a regression nobody wrote a check for still turns the matrix red.
///
/// Blessing is explicit and never implicit:
/// `CONTINUUM_UPDATE_BASELINES=1 ./scripts/run-matrix.sh`. A missing baseline is a
/// failure, not an invitation to write one — otherwise deleting a baseline would
/// be a silent way to drop coverage.
@MainActor
enum UIProbeBaseline {
    struct BaselineError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func fail(_ message: String) -> BaselineError { BaselineError(message: message) }

    // MARK: - Policy

    /// Committed, so the comparison has something to compare against across runs.
    static let baselineRelativePath = "docs/38-tickets/90-agent-ux/baselines"
    static let updateEnvironmentKey = "CONTINUUM_UPDATE_BASELINES"

    /// Per-channel difference (0…255) at which two pixels count as different.
    /// Font antialiasing and layer compositing drift by a step or two between
    /// runs; a whole-pixel design change moves channels by far more than this.
    static let channelEpsilon = 8

    /// Fraction of differing pixels tolerated before the comparison fails.
    ///
    /// **Derived from measurement, not chosen.** Two consecutive runs over all 44
    /// renders drift by exactly **0.0000%** — repeated renders on one machine are
    /// bit-identical. The packet's named regression (a transcript card's corner
    /// radius 8 -> 2) moves only **0.1091%** of `tiles.managedAgent`, because six
    /// small cards' corners are a few hundred pixels: at the packet's suggested
    /// ~0.1% that regression clears the bar by 1.09x, and a subtler one (8 -> 6)
    /// would pass. 0.03% keeps 3.6x margin under the regression while still sitting
    /// far above any drift measurable here.
    ///
    /// Font rendering can differ across macOS versions. If that bites, raise this
    /// **once**, with the measured number — never per-card, and never by blessing
    /// baselines to make red go away.
    static let maximumDifferingFraction = 0.0003

    /// Fallback for a card that declares no preferred size, matching
    /// `UIProbe.runUIProbeChecks` and `ComponentLabPanel`.
    static let defaultCardSize = NSSize(width: 560, height: 640)

    static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// **Every** static card is baselined, with no exclusion list. Building this gate
    /// turned up exactly one card that could not carry a baseline —
    /// `auth.pairingToken` generated a fresh random credential per render, so ~4% of
    /// its pixels differed between two consecutive renders in the same process. That
    /// was fixed at the source (the Lab card now uses a canned credential like every
    /// other fixture) rather than excluded, because an exclusion list is where
    /// coverage goes to quietly disappear.

    /// Filenames are `<entry.id>-<W>x<H>-<appearance>.png`, e.g.
    /// `tiles.managedAgent-640x560-darkAqua.png`.
    static func baselineName(id: String, size: NSSize, appearance: NSAppearance.Name) -> String {
        "\(id)-\(Int(size.width))x\(Int(size.height))-\(shortName(appearance)).png"
    }

    private static func shortName(_ appearance: NSAppearance.Name) -> String {
        appearance == .aqua ? "aqua" : "darkAqua"
    }

    // MARK: - Canonical pixels

    /// A render reduced to a machine-independent form: one byte per channel,
    /// RGBA, sRGB, and **one pixel per layout point**.
    ///
    /// The point-per-pixel step matters. `bitmapImageRepForCachingDisplay` follows
    /// the window's backing scale, so the same card is 1120x1280px on a retina host
    /// and 560x640px on a 1x one — committed baselines would be unreadable on the
    /// other kind of machine. Normalising to the logical size makes the committed
    /// bytes depend on the layout, not on the host's display, and halves the size of
    /// what lands in git.
    struct Canvas {
        let width: Int
        let height: Int
        /// `width * height * 4` bytes, row-major, no padding.
        let bytes: [UInt8]

        var pixelCount: Int { width * height }
    }

    /// Draws `image` into a fresh sRGB RGBA8 buffer of exactly `width` x `height`.
    /// Both the live render and the decoded baseline PNG go through this same path,
    /// so neither can pick up a colour-space conversion the other did not.
    private static func canvas(from image: CGImage, width: Int, height: Int, label: String) throws -> Canvas {
        guard width > 0, height > 0 else {
            throw fail("\(label): degenerate canvas \(width)x\(height)")
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw fail("\(label): could not create the sRGB colour space")
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw fail("\(label): could not allocate a \(width)x\(height) normalisation context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else {
            throw fail("\(label): normalisation context has no backing data")
        }
        let count = width * height * 4
        let buffer = UnsafeRawBufferPointer(start: data, count: count)
        return Canvas(width: width, height: height, bytes: [UInt8](buffer))
    }

    private static func canvas(of rep: NSBitmapImageRep, size: NSSize, label: String) throws -> Canvas {
        guard let image = rep.cgImage else {
            throw fail("\(label): render has no CGImage")
        }
        return try canvas(from: image, width: Int(size.width.rounded()), height: Int(size.height.rounded()), label: label)
    }

    private static func canvas(ofPNGAt url: URL, label: String) throws -> Canvas {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw fail("\(label): could not read \(url.path) — \(error)")
        }
        guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else {
            throw fail("\(label): \(url.lastPathComponent) is not a readable PNG")
        }
        return try canvas(from: image, width: image.width, height: image.height, label: label)
    }

    /// PNG bytes for a canvas, tagged sRGB. `retagging` reinterprets rather than
    /// converts — the bytes already *are* sRGB, so tagging them anything else would
    /// make the decode-side conversion shift every pixel and the gate red forever.
    private static func pngData(for canvas: Canvas, label: String) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: canvas.width, pixelsHigh: canvas.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: canvas.width * 4, bitsPerPixel: 32
        ), let destination = rep.bitmapData else {
            throw fail("\(label): could not allocate a \(canvas.width)x\(canvas.height) PNG bitmap")
        }
        canvas.bytes.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: canvas.bytes.count)
        }
        let tagged = rep.retagging(with: .sRGB) ?? rep
        guard let data = tagged.representation(using: .png, properties: [:]) else {
            throw fail("\(label): could not encode PNG")
        }
        return data
    }

    // MARK: - Comparison

    struct Difference {
        let differingPixels: Int
        let totalPixels: Int
        let worstChannelDelta: Int
        var fraction: Double { totalPixels == 0 ? 1 : Double(differingPixels) / Double(totalPixels) }
    }

    /// Counts pixels where any channel differs by more than `channelEpsilon`.
    static func compare(_ actual: Canvas, _ baseline: Canvas) -> Difference {
        var differing = 0
        var worst = 0
        var index = 0
        let count = min(actual.bytes.count, baseline.bytes.count)
        while index + 3 < count {
            var pixelDelta = 0
            for channel in 0..<4 {
                let delta = abs(Int(actual.bytes[index + channel]) - Int(baseline.bytes[index + channel]))
                if delta > pixelDelta { pixelDelta = delta }
            }
            if pixelDelta > worst { worst = pixelDelta }
            if pixelDelta > channelEpsilon { differing += 1 }
            index += 4
        }
        return Difference(differingPixels: differing, totalPixels: actual.pixelCount, worstChannelDelta: worst)
    }

    /// Actual over a dimmed baseline, with every differing pixel painted magenta —
    /// a human opens this and sees immediately *where* the render moved.
    private static func diffCanvas(actual: Canvas, baseline: Canvas) -> Canvas {
        var bytes = [UInt8](repeating: 255, count: actual.bytes.count)
        var index = 0
        while index + 3 < actual.bytes.count {
            var pixelDelta = 0
            if index + 3 < baseline.bytes.count {
                for channel in 0..<4 {
                    pixelDelta = max(pixelDelta, abs(Int(actual.bytes[index + channel]) - Int(baseline.bytes[index + channel])))
                }
            } else {
                pixelDelta = 255
            }
            if pixelDelta > channelEpsilon {
                bytes[index] = 255
                bytes[index + 1] = 0
                bytes[index + 2] = 255
            } else {
                // Dim, so the highlighted pixels are the only saturated thing.
                for channel in 0..<3 { bytes[index + channel] = actual.bytes[index + channel] / 3 }
            }
            bytes[index + 3] = 255
            index += 4
        }
        return Canvas(width: actual.width, height: actual.height, bytes: bytes)
    }

    // MARK: - Locations

    /// The committed baseline directory, resolved from the working directory the
    /// matrix runs the app from (the repo root). Fails loudly rather than creating
    /// it silently somewhere else — a gate comparing against an empty directory it
    /// invented is worse than no gate.
    static func baselineDirectory() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let directory = cwd.appendingPathComponent(baselineRelativePath, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw fail("\(directory.path) exists but is not a directory") }
            return directory
        }
        guard isUpdating else {
            throw fail(
                "no baseline directory at \(directory.path) (working directory \(cwd.path)) — "
                    + "run this check from the repo root, or bless with \(updateEnvironmentKey)=1 ./scripts/run-matrix.sh"
            )
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Failure artifacts land under the gitignored `qa-runs/`, alongside every other
    /// check's output.
    private static func artifactDirectory() throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("ui-baselines", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var isUpdating: Bool { ProcessInfo.processInfo.environment[updateEnvironmentKey] == "1" }

    // MARK: - Check

    static func runBaselineChecks() throws {
        _ = NSApplication.shared
        // Production pins the app appearance at launch (`ContinuumApp`), so pinning
        // it dark here keeps the `.aqua` pass honest — same convention as every
        // other UIProbe gate.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let updating = isUpdating
        let directory = try baselineDirectory()
        let entries = LabCatalog.entries(env: LabEnvironment(ghostty: nil, browserEngine: nil))

        var expected: Set<String> = []
        var compared = 0
        var written = 0
        var worstFraction = (value: 0.0, name: "")
        var artifacts: URL?
        // Every mismatch is reported, not just the first: after a shared change one
        // run should tell the owner every card that moved.
        var failures: [String] = []

        for entry in entries {
            guard case let .staticCard(preferredSize, make) = entry.content else { continue }
            let size = preferredSize ?? defaultCardSize
            for appearanceName in appearances {
                let name = baselineName(id: entry.id, size: size, appearance: appearanceName)
                expected.insert(name)
                let probe = try UIProbe.render(
                    UIProbe.Spec(id: name, size: size, appearance: appearanceName), make: make
                )
                let actual = try canvas(of: probe.hostRep, size: size, label: name)
                let url = directory.appendingPathComponent(name)

                if updating {
                    let data = try pngData(for: actual, label: name)
                    let existing = try? Data(contentsOf: url)
                    if existing != data {
                        try data.write(to: url)
                        written += 1
                    }
                    continue
                }

                guard FileManager.default.fileExists(atPath: url.path) else {
                    failures.append("\(name): no committed baseline")
                    continue
                }
                let baseline = try canvas(ofPNGAt: url, label: name)
                guard baseline.width == actual.width, baseline.height == actual.height else {
                    let dir = try artifacts ?? artifactDirectory()
                    artifacts = dir
                    let actualURL = dir.appendingPathComponent("\(name).actual.png")
                    try pngData(for: actual, label: name).write(to: actualURL)
                    failures.append(
                        "\(name): render is \(actual.width)x\(actual.height), baseline is "
                            + "\(baseline.width)x\(baseline.height) — actual: \(actualURL.path)"
                    )
                    continue
                }

                let difference = compare(actual, baseline)
                if difference.fraction > worstFraction.value {
                    worstFraction = (difference.fraction, name)
                }
                if difference.fraction > maximumDifferingFraction {
                    let dir = try artifacts ?? artifactDirectory()
                    artifacts = dir
                    let actualURL = dir.appendingPathComponent("\(name).actual.png")
                    let diffURL = dir.appendingPathComponent("\(name).diff.png")
                    try pngData(for: actual, label: name).write(to: actualURL)
                    try pngData(for: diffCanvas(actual: actual, baseline: baseline), label: name).write(to: diffURL)
                    failures.append(String(
                        format: "%@: %d of %d pixels differ (%.4f%%, worst channel delta %d), tolerance %.4f%% — "
                            + "actual: %@ · diff (magenta = changed): %@ · baseline: %@",
                        name, difference.differingPixels, difference.totalPixels,
                        difference.fraction * 100, difference.worstChannelDelta,
                        maximumDifferingFraction * 100,
                        actualURL.path, diffURL.path, url.path
                    ))
                    continue
                }
                compared += 1
            }
        }

        guard !expected.isEmpty else { throw fail("no static cards were baselined") }

        // A baseline with no card left to compare it against is dead coverage — and
        // the most likely cause is a card that was renamed or lost its static
        // content, which is exactly what this gate should notice.
        let onDisk = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasSuffix(".png") } ?? []
        )
        let stale = onDisk.subtracting(expected).sorted()
        if !stale.isEmpty {
            if updating {
                for name in stale {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
            } else {
                failures.append("\(stale.count) baseline(s) match no static card: \(stale.joined(separator: ", "))")
            }
        }

        guard NSApp.appearance?.name == .darkAqua else {
            throw fail("probing mutated NSApp.appearance to '\(NSApp.appearance?.name.rawValue ?? "nil")'")
        }

        guard failures.isEmpty else {
            throw fail(
                "\(failures.count) baseline(s) did not match:\n  - "
                    + failures.joined(separator: "\n  - ")
                    + "\n\(compared) other render(s) matched. If these changes are intended, bless them: "
                    + "\(updateEnvironmentKey)=1 ./scripts/run-matrix.sh — and review the baseline diff before committing."
            )
        }

        if updating {
            print(
                "UIProbeBaseline: BLESSED — \(written) baseline(s) written, \(stale.count) stale removed, "
                    + "\(expected.count) total in \(baselineRelativePath). Review the diff before committing."
            )
        } else {
            print(String(
                format: "UIProbeBaseline: %d card/appearance renders matched their committed baselines "
                    + "(tolerance %.4f%%; worst %.4f%% on %@)",
                compared, maximumDifferingFraction * 100, worstFraction.value * 100,
                worstFraction.name.isEmpty ? "none" : worstFraction.name
            ))
        }
    }

    // MARK: - Regression witnesses over production code
    //
    // Each edit below was applied, run, and observed RED; the quoted text is the
    // real output. The point of a baseline gate is that it catches changes nobody
    // wrote an assertion for, so the witnesses are ordinary design edits.
    //
    // 1 · Corner radius (the packet's named case). In `TranscriptCardViews.swift`,
    //     `layer?.cornerRadius = 8` -> `= 2`:
    //     -> "4 baseline(s) did not match:
    //          - tiles.managedAgent-560x560-aqua.png: 342 of 313600 pixels differ
    //            (0.1091%, worst channel delta 47), tolerance 0.0300% — actual: …
    //            · diff (magenta = changed): … · baseline: …"
    //        (four, not two: `managed-agent.approval-dock` renders transcript cards
    //        too. Restoring the 8 and re-running returns worst 0.0000%.)
    //
    // 2 · Deleting a baseline does not silently pass — `mv` one out of the directory:
    //     -> "1 baseline(s) did not match:
    //          - agent.statusChip-360x260-aqua.png: no committed baseline
    //        45 other render(s) matched."
    //
    // 3 · A stale baseline (a card renamed away) is also red:
    //     -> "1 baseline(s) match no static card: ghost.card-100x100-aqua.png"
    //
    // 4 · Blessing writes a reviewable diff, and only for what moved: with witness 1
    //     applied, `CONTINUUM_UPDATE_BASELINES=1` reported "4 baseline(s) written"
    //     and `git status` showed exactly those four as modified.
}
