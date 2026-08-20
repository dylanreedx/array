import AppKit
import Foundation
import ImageIO

/// Bounded, local-only project identity lookup. Roots arrive from the registry;
/// paths never enter the row model and no network fallback exists.
@MainActor
final class ProjectFaviconResolver {
    private struct Entry { let root: URL; let revision: Date }
    private var sources: [UUID: Entry] = [:]
    private var images: [UUID: NSImage] = [:]
    private var resolvedRevision: [UUID: Date] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var waiters: [UUID: [(NSImage?) -> Void]] = [:]

    func update(_ roots: [UUID: URL]) {
        let ids = Set(roots.keys)
        sources = roots.reduce(into: [:]) { result, pair in
            let values = try? pair.value.resourceValues(forKeys: [.contentModificationDateKey])
            result[pair.key] = Entry(
                root: pair.value, revision: values?.contentModificationDate ?? .distantPast)
        }
        tasks.keys.filter { !ids.contains($0) }.forEach { tasks.removeValue(forKey: $0)?.cancel() }
        waiters.keys.filter { !ids.contains($0) }.forEach { waiters.removeValue(forKey: $0) }
        images.keys.filter { !ids.contains($0) }.forEach { images.removeValue(forKey: $0) }
    }

    func image(for projectID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard let source = sources[projectID] else { completion(nil); return }
        if let image = images[projectID], resolvedRevision[projectID] == source.revision {
            completion(image)
            return
        }
        // Keep the last successful image visible while a changed root is decoded.
        if let image = images[projectID] { completion(image) }
        waiters[projectID, default: []].append(completion)
        guard tasks[projectID] == nil else { return }
        tasks[projectID] = Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                Self.load(root: source.root)
            }.value
            guard let self else { return }
            self.tasks[projectID] = nil
            let completions = self.waiters.removeValue(forKey: projectID) ?? []
            guard self.sources[projectID]?.revision == source.revision else { return }
            if let image {
                self.images[projectID] = image
                self.resolvedRevision[projectID] = source.revision
                completions.forEach { $0(image) }
            } else if self.images[projectID] == nil {
                completions.forEach { $0(nil) }
            }
        }
    }

    nonisolated private static let candidates = [
        "favicon.svg", "favicon.ico", "favicon.png",
        "public/favicon.svg", "public/favicon.ico", "public/favicon.png",
        "app/favicon.svg", "app/favicon.ico", "app/favicon.png",
        "src/favicon.svg", "src/favicon.ico", "src/favicon.png",
        "src/app/favicon.svg", "src/app/favicon.ico", "src/app/favicon.png",
        "assets/icon.svg", "assets/icon.png", "assets/logo.svg", "assets/logo.png",
        ".idea/icon.svg",
    ]
    nonisolated private static let maximumBytes = 2 * 1024 * 1024

    nonisolated private static func load(root: URL) -> NSImage? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        for relative in candidates {
            let candidate = root.appendingPathComponent(relative)
            if let image = load(candidate: candidate, inside: resolvedRoot) { return image }
        }
        for document in ["index.html", "src/__root.tsx", "src/root.tsx", "app/root.tsx"] {
            let file = root.appendingPathComponent(document)
            guard let data = boundedData(at: file),
                  let text = String(data: data, encoding: .utf8),
                  let href = iconHref(in: text) else { continue }
            let candidate = file.deletingLastPathComponent().appendingPathComponent(href)
            if let image = load(candidate: candidate, inside: resolvedRoot) { return image }
        }
        return nil
    }

    nonisolated private static func load(candidate: URL, inside root: URL) -> NSImage? {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(prefix),
              let data = boundedData(at: resolved) else { return nil }
        // ImageIO sniffs bytes rather than trusting the suffix (real .ico files
        // are often PNG). NSImage is retained as the SVG-capable fallback.
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 28,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: 14, height: 14))
        }
        guard let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 14, height: 14)
        return image
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
}
