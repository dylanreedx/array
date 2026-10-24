import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `--project-icon-check`. The sidebar's project icon, through the resolver the
/// inbox owns (`update` then `image(for:)`, as `AgentInboxView` calls it), over
/// fixture roots holding each source kind. Every source paints its own colour,
/// so "which file won" is asserted on the pixels the cell would draw, and the
/// winning path is asserted beside it.
@MainActor
enum ProjectIconChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private enum Ink: String { case red, green, blue }

    static func run() throws -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-icon-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var lines: [String] = []
        var failed = 0
        func expect(_ condition: Bool, _ label: String) {
            lines.append("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failed += 1 }
        }

        func root(_ name: String, _ files: [String: Data]) throws -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            for (relative, data) in files { try write(data, to: url.appendingPathComponent(relative)) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let appIcon = """
            {"images":[
              {"filename":"small.png","idiom":"mac","scale":"1x","size":"16x16"},
              {"idiom":"mac","scale":"2x","size":"512x512"},
              {"filename":"big.png","idiom":"mac","scale":"2x","size":"256x256"}
            ],"info":{"author":"xcode","version":1}}
            """
        let roots: [(name: String, url: URL, winner: String?, ink: Ink?)] = [
            ("override beats public/favicon.ico", try root("override", [
                "public/favicon.ico": try raster(.red, 32, type: .ico),
                ".array/icon.svg": svg(.blue),
            ]), ".array/icon.svg", .blue),
            ("static/favicon.svg", try root("static", ["static/favicon.svg": svg(.green)]),
             "static/favicon.svg", .green),
            ("website/public/favicon.svg", try root("website", ["website/public/favicon.svg": svg(.blue)]),
             "website/public/favicon.svg", .blue),
            ("Packaging/*.icns, largest representation", try root("icns", [
                "Packaging/App.icns": try icns(),
            ]), "Packaging/App.icns", .blue),
            ("xcassets AppIcon, largest listed PNG", try root("xcassets", [
                "App/Assets.xcassets/AppIcon.appiconset/Contents.json": Data(appIcon.utf8),
                "App/Assets.xcassets/AppIcon.appiconset/small.png": try raster(.red, 16, type: .png),
                "App/Assets.xcassets/AppIcon.appiconset/big.png": try raster(.blue, 64, type: .png),
            ]), "App/Assets.xcassets/AppIcon.appiconset/big.png", .blue),
            ("no icon anywhere", try root("none", ["README.md": Data("x".utf8)]), nil, nil),
        ]

        let resolver = ProjectFaviconResolver()
        var ids: [UUID: URL] = [:]
        let cases = roots.map { entry -> (UUID, String, URL, String?, Ink?) in
            let id = UUID()
            ids[id] = entry.url
            return (id, entry.name, entry.url, entry.winner, entry.ink)
        }
        resolver.update(ids)

        for (id, name, url, winner, ink) in cases {
            let image = try settle(resolver, id)
            let won = resolver.winningFileForQA(id).map { relative($0, to: url) }
            expect(won == winner, "\(name): winner \(won ?? "none"), wanted \(winner ?? "none")")
            let seen = image.flatMap(inkColour)
            expect(seen?.ink == ink,
                   "\(name): ink \(seen.map { "\($0.ink?.rawValue ?? "mixed") (\($0.pixels) px)" } ?? "none"), wanted \(ink?.rawValue ?? "none")")
        }

        // A settled project — hit or miss — answers from the cache: no probe.
        let settledProbes = resolver.probeCountForQA
        for _ in 0..<3 { for (id, _, _, _, _) in cases { resolver.image(for: id) { _ in } } }
        expect(resolver.probeCountForQA == settledProbes,
               "repeat configures probe nothing (\(resolver.probeCountForQA - settledProbes) probes, wanted 0)")

        // A canvas save renames into `.array/` — that is not a new icon.
        let override = cases[0], miss = cases[5], nested = cases[1]
        try write(Data("{}".utf8), to: override.2.appendingPathComponent(".array/canvas.json"))
        let beforeSave = resolver.probeCountForQA
        resolver.image(for: override.0) { _ in }
        expect(resolver.probeCountForQA == beforeSave,
               "an unrelated .array/ write re-probes nothing (\(resolver.probeCountForQA - beforeSave) probes)")

        // An override added after a miss shows without a restart.
        try write(svg(.green), to: miss.2.appendingPathComponent(".array/icon.svg"))
        let late = try settle(resolver, miss.0)
        expect(resolver.winningFileForQA(miss.0).map { relative($0, to: miss.2) } == ".array/icon.svg"
                && late.flatMap(inkColour)?.ink == .green,
               "an override added after a cached miss is picked up")

        // An override added over a resolved favicon replaces it.
        try write(try raster(.red, 32, type: .png), to: nested.2.appendingPathComponent(".array/icon.png"))
        let replaced = try settle(resolver, nested.0)
        expect(resolver.winningFileForQA(nested.0).map { relative($0, to: nested.2) } == ".array/icon.png"
                && replaced.flatMap(inkColour)?.ink == .red,
               "an override added after a resolved favicon replaces it")

        // Editing the winning nested file — the root's mtime never moves.
        let website = cases[2]
        try write(svg(.red), to: website.2.appendingPathComponent("website/public/favicon.svg"))
        let edited = try settle(resolver, website.0)
        expect(edited.flatMap(inkColour)?.ink == .red, "editing the nested winning file refreshes it")

        let report = lines.joined(separator: "\n")
        if failed > 0 { throw Failure(message: "\(failed) failed\n\(report)") }
        return report + "\nPASS: project-icon-check"
    }

    /// Ask once, and take the last answer once any probe it started is done.
    private static func settle(_ resolver: ProjectFaviconResolver, _ id: UUID) throws -> NSImage? {
        var answers: [NSImage?] = []
        resolver.image(for: id) { answers.append($0) }
        let deadline = Date().addingTimeInterval(10)
        while resolver.isProbingForQA(id), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard !resolver.isProbingForQA(id) else { throw Failure(message: "the resolver never settled") }
        return answers.last ?? nil
    }

    /// Directory listings answer under `/private/var`, the fixture root is `/var`.
    private static func relative(_ file: URL, to root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        return String(file.resolvingSymlinksInPath().path.dropFirst(rootPath.count + 1))
    }

    /// Which primary dominates the image's visible pixels, drawn at the 28px
    /// the cell's 14pt icon backs.
    private static func inkColour(_ image: NSImage) -> (ink: Ink?, pixels: Int)? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 28, height: 28))
        NSGraphicsContext.restoreGraphicsState()
        var sums = [0.0, 0.0, 0.0], pixels = 0
        for x in 0..<28 { for y in 0..<28 {
            guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
            pixels += 1
            sums[0] += colour.redComponent; sums[1] += colour.greenComponent; sums[2] += colour.blueComponent
        } }
        guard pixels > 0 else { return nil }
        let top = sums.indices.max { sums[$0] < sums[$1] }!
        let dominant = sums[top] > 2 * sums.enumerated().filter { $0.offset != top }.map(\.element).max()!
        return (dominant ? [Ink.red, .green, .blue][top] : nil, pixels)
    }

    private static func hex(_ ink: Ink) -> String {
        switch ink { case .red: "#ff0000"; case .green: "#00c000"; case .blue: "#0000ff" }
    }

    private static func cgColour(_ ink: Ink) -> CGColor {
        switch ink {
        case .red: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        case .green: CGColor(red: 0, green: 0.75, blue: 0, alpha: 1)
        case .blue: CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        }
    }

    private static func svg(_ ink: Ink) -> Data {
        Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\
            <circle cx="50" cy="50" r="45" fill="\(hex(ink))"/></svg>
            """.utf8)
    }

    private static func image(_ ink: Ink, _ side: Int) -> CGImage? {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(cgColour(ink))
        context?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context?.makeImage()
    }

    private static func raster(_ ink: Ink, _ side: Int, type: UTType) throws -> Data {
        try encode([(ink, side)], type: type)
    }

    /// A small red representation ahead of a large blue one.
    private static func icns() throws -> Data {
        try encode([(.red, 16), (.blue, 256)], type: .icns)
    }

    private static func encode(_ images: [(Ink, Int)], type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, images.count, nil) else {
            throw Failure(message: "ImageIO cannot write \(type.identifier)")
        }
        for (ink, side) in images {
            guard let cg = image(ink, side) else { throw Failure(message: "could not draw a fixture image") }
            CGImageDestinationAddImage(destination, cg, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(message: "could not encode \(type.identifier)")
        }
        return data as Data
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
