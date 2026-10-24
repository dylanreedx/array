import AppKit
import Darwin
import Foundation
import ImageIO

/// Bounded, local-only project identity lookup. Roots arrive from the registry;
/// paths never enter the row model and no network fallback exists.
///
/// A result — hit OR miss — is cached against a stamp of the files that decide
/// it: the two `.array/icon.*` overrides and the winning file. Re-validating
/// costs two or three `stat`s per configure; the full probe runs only when one
/// of those changed.
@MainActor
final class ProjectFaviconResolver {
    struct FileStamp: Equatable {
        let mtime: timespec
        let size: off_t
        let inode: ino_t
        static func == (a: Self, b: Self) -> Bool {
            a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
                && a.size == b.size && a.inode == b.inode
        }
    }
    struct Stamp: Equatable { let overrides: [FileStamp?]; let winner: FileStamp? }
    struct Resolution { let file: URL?; let image: NSImage?; let stamp: Stamp }

    private var roots: [UUID: URL] = [:]
    private var resolutions: [UUID: (root: URL, resolution: Resolution)] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var waiters: [UUID: [(NSImage?) -> Void]] = [:]
    /// Full probes started — the QA witness that a cached miss stays cached.
    private(set) var probeCountForQA = 0

    func update(_ roots: [UUID: URL]) {
        self.roots = roots
        let ids = Set(roots.keys)
        tasks.keys.filter { !ids.contains($0) }.forEach { tasks.removeValue(forKey: $0)?.cancel() }
        waiters.keys.filter { !ids.contains($0) }.forEach { waiters.removeValue(forKey: $0) }
        resolutions.keys.filter { roots[$0] != resolutions[$0]?.root }
            .forEach { resolutions.removeValue(forKey: $0) }
    }

    func image(for projectID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard let root = roots[projectID] else { completion(nil); return }
        if let cached = resolutions[projectID]?.resolution {
            if Self.stamp(root: root, winner: cached.file) == cached.stamp {
                completion(cached.image)
                return
            }
            // Keep the last image visible while the changed source is decoded.
            if let image = cached.image { completion(image) }
        }
        waiters[projectID, default: []].append(completion)
        guard tasks[projectID] == nil else { return }
        probeCountForQA += 1
        tasks[projectID] = Task { [weak self] in
            let resolution = await Task.detached(priority: .utility) {
                Self.resolve(root: root)
            }.value
            guard let self else { return }
            self.tasks[projectID] = nil
            let completions = self.waiters.removeValue(forKey: projectID) ?? []
            guard self.roots[projectID] == root else { return }
            self.resolutions[projectID] = (root, resolution)
            completions.forEach { $0(resolution.image) }
        }
    }

    func winningFileForQA(_ projectID: UUID) -> URL? {
        resolutions[projectID]?.resolution.file
    }

    func isProbingForQA(_ projectID: UUID) -> Bool { tasks[projectID] != nil }

    // MARK: Resolution

    /// A project's own choice, ahead of anything it ships.
    nonisolated private static let overrides = [".array/icon.svg", ".array/icon.png"]
    nonisolated private static let candidates = [
        "favicon.svg", "favicon.ico", "favicon.png",
        "public/favicon.svg", "public/favicon.ico", "public/favicon.png",
        "app/favicon.svg", "app/favicon.ico", "app/favicon.png",
        "src/favicon.svg", "src/favicon.ico", "src/favicon.png",
        "src/app/favicon.svg", "src/app/favicon.ico", "src/app/favicon.png",
        "static/favicon.svg", "static/favicon.ico", "static/favicon.png",
        "website/public/favicon.svg", "website/public/favicon.ico", "website/public/favicon.png",
        "assets/icon.svg", "assets/icon.png", "assets/logo.svg", "assets/logo.png",
        ".idea/icon.svg",
    ]
    nonisolated private static let maximumBytes = 2 * 1024 * 1024
    nonisolated private static let pixelSize = 28

    nonisolated static func resolve(root: URL) -> Resolution {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let found = winner(root: root, inside: resolvedRoot)
        return Resolution(file: found?.file, image: found?.image,
                          stamp: stamp(root: root, winner: found?.file))
    }

    nonisolated private static func winner(root: URL, inside resolvedRoot: URL) -> (file: URL, image: NSImage)? {
        func attempt(_ file: URL) -> (file: URL, image: NSImage)? {
            load(candidate: file, inside: resolvedRoot).map { (file, $0) }
        }
        for relative in overrides + candidates {
            if let hit = attempt(root.appendingPathComponent(relative)) { return hit }
        }
        for document in ["index.html", "src/__root.tsx", "src/root.tsx", "app/root.tsx"] {
            let file = root.appendingPathComponent(document)
            guard let data = boundedData(at: file),
                  let text = String(data: data, encoding: .utf8),
                  let href = iconHref(in: text) else { continue }
            if let hit = attempt(file.deletingLastPathComponent().appendingPathComponent(href)) { return hit }
        }
        let packaging = root.appendingPathComponent("Packaging", isDirectory: true)
        for icns in children(of: packaging).filter({ $0.pathExtension == "icns" }) {
            if let hit = attempt(icns) { return hit }
        }
        for iconSet in appIconSets(root: root) {
            for file in appIconFiles(in: iconSet) {
                if let hit = attempt(file) { return hit }
            }
        }
        return nil
    }

    /// `AppIcon.appiconset` inside a `.xcassets` at the root or one directory
    /// down — the layout Xcode creates. Deeper would hand an umbrella folder
    /// some nested project's icon.
    nonisolated private static func appIconSets(root: URL) -> [URL] {
        let skipped: Set<String> = ["node_modules", "build", "DerivedData", "Pods", "vendor", "dist"]
        let topLevel = children(of: root)
        let nested = topLevel.filter { !skipped.contains($0.lastPathComponent) && $0.pathExtension != "xcassets" }
            .flatMap { children(of: $0) }
        return (topLevel + nested)
            .filter { $0.pathExtension == "xcassets" }
            .map { $0.appendingPathComponent("AppIcon.appiconset", isDirectory: true) }
    }

    /// The set's images, largest first, as `Contents.json` lists them.
    nonisolated private static func appIconFiles(in iconSet: URL) -> [URL] {
        struct Contents: Decodable {
            struct Image: Decodable { let filename: String?; let size: String?; let scale: String? }
            let images: [Image]
        }
        guard let data = boundedData(at: iconSet.appendingPathComponent("Contents.json")),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return [] }
        func pixels(_ image: Contents.Image) -> Double {
            let points = Double(image.size?.split(separator: "x").first ?? "") ?? 0
            let scale = Double(image.scale?.dropLast() ?? "") ?? 1
            return points * scale
        }
        return contents.images.filter { $0.filename != nil }
            .sorted { pixels($0) > pixels($1) }
            .compactMap { $0.filename.map { iconSet.appendingPathComponent($0) } }
    }

    nonisolated private static func children(of directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static func load(candidate: URL, inside root: URL) -> NSImage? {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(prefix),
              let data = boundedData(at: resolved) else { return nil }
        // ImageIO sniffs bytes rather than trusting the suffix (real .ico files
        // are often PNG), and decodes the LARGEST representation of a
        // multi-image .ico/.icns rather than whichever happens to come first.
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0 {
            let largest = (0..<CGImageSourceGetCount(source)).max { lhs, rhs in
                pixelWidth(source, lhs) < pixelWidth(source, rhs)
            } ?? 0
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, largest, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: 14, height: 14))
            }
        }
        // NSImage is the SVG decoder. Rasterize it here, off the main thread,
        // so the cell draws a bitmap and not a vector document.
        guard let vector = NSImage(data: data), vector.size.width > 0, vector.size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let side = CGFloat(pixelSize)
        let scale = min(side / vector.size.width, side / vector.size.height)
        let drawn = NSSize(width: vector.size.width * scale, height: vector.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        vector.draw(in: NSRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                               width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = bitmap.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 14, height: 14))
    }

    nonisolated private static func pixelWidth(_ source: CGImageSource, _ index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }

    nonisolated private static func boundedData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumBytes else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    nonisolated private static func iconHref(in text: String) -> String? {
        let pattern = #"(?is)<link[^>]*rel\s*=\s*[\"'][^\"']*icon[^\"']*[\"'][^>]*href\s*=\s*[\"']([^\"'#?]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let href = String(text[range])
        guard !href.contains("://"), !href.hasPrefix("data:") else { return nil }
        return href
    }

    // MARK: Validation

    /// `stat`, not `URL.resourceValues`: a URL caches its resource values, and
    /// this answer must be fresh on every configure.
    nonisolated private static func fileStamp(_ url: URL) -> FileStamp? {
        var info = Darwin.stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileStamp(mtime: info.st_mtimespec, size: info.st_size, inode: info.st_ino)
    }

    /// The overrides are stamped by path, not through `.array/`'s own mtime:
    /// every atomic canvas save renames into that directory, and would make
    /// each save look like a new icon.
    nonisolated static func stamp(root: URL, winner: URL?) -> Stamp {
        let overrideFiles = overrides.map { root.appendingPathComponent($0) }
        return Stamp(overrides: overrideFiles.map(fileStamp),
                     winner: winner.flatMap { overrideFiles.contains($0) ? nil : fileStamp($0) })
    }
}
