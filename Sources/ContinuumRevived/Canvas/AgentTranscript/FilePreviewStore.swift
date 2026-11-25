import AppKit
import CoreImage
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import PDFKit
import QuickLookThumbnailing

/// What kind of one-off file earns a preview in a transcript's Changes card.
/// Source edits never do: a card of code diffs is the transcript's job already,
/// and a preview per edited file would fill it with thumbnails.
enum FilePreviewKind: Equatable {
    case image, pdf, web, document, code

    /// `action` is how the operation touched the file. Documents and code are
    /// previewed only when the operation created them; an edit to a repo file
    /// stays a plain row.
    init?(url: URL, action: AgentDiffFileAction?) {
        let created = action == nil || action == .add || action == .write
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": self = .image
        case "pdf": self = .pdf
        case "html", "htm", "svg": self = .web
        case "md", "markdown": guard created else { return nil }; self = .document
        case "swift", "ts", "py", "js", "json", "sh": guard action == .add else { return nil }; self = .code
        default: return nil
        }
    }

    /// Whether the picture depends on the appearance (drawn text) or not.
    var dependsOnTheme: Bool { self == .document || self == .code }
}

/// One finished preview: the picture and a pre-blurred copy of it, so the hover
/// fade never blurs on the main thread.
struct FilePreviewPicture {
    let image: CGImage
    let blurred: CGImage
    /// The file's size on disk, read with the picture (off the main actor).
    var byteCount: Int? = nil
    /// An image's own pixel size, from its header (ImageIO properties, no decode).
    var pixelSize: CGSize? = nil
    /// Width over height of the picture.
    var aspect: CGFloat { CGFloat(image.width) / max(1, CGFloat(image.height)) }
}

/// Thumbnails for the Changes card, made off the main thread and cached by
/// path and modification time (and appearance, for drawn text). Bounded, so a
/// long session cannot grow it: 32 pictures or about 20 MB, whichever first.
///
/// Least recently used goes first, and every request counts as a use, so the
/// pictures a card is showing are the last to go. It was an `NSCache`, which
/// may evict whatever it likes: once a session had made a few dozen pictures it
/// dropped the ones on screen, each re-layout asked for them again, and a
/// card's thumbnails churned through regeneration and could stay blank.
///
/// `preview(...)` returns what is cached and otherwise starts the work and
/// returns nil; `onReady` fires on the main actor when a picture lands, so the
/// card shows a quiet placeholder until then. A web page snapshot is the slow
/// one (QuickLook, about a quarter second); everything else is a few ms.
@MainActor
final class FilePreviewStore {
    static let shared = FilePreviewStore()
    /// Logical height every picture is generated at; the card draws it smaller.
    nonisolated static let sourceHeight: CGFloat = 112
    nonisolated static let scale: CGFloat = 2

    static let countLimit = 32
    static let costLimit = 20 * 1_048_576
    private var entries: [String: (picture: FilePreviewPicture, cost: Int)] = [:]
    /// Keys, least recently used first.
    private var recency: [String] = []
    private var totalCost = 0
    private var pending: [String: [() -> Void]] = [:]
    /// Keys whose picture could not be made (the file is gone, or unreadable).
    /// The key carries the modification time, so a file that changes is tried
    /// again; one that does not is not. Retrying it on every layout, and
    /// re-laying the card out on every failure, was a loop that never ended.
    private var failed: Set<String> = []
    private var failedOrder: [String] = []
    private(set) var generationCount = 0
    private(set) var failureCount = 0

    init() {}

    func resetForChecks() {
        entries = [:]; recency = []; totalCost = 0; pending = [:]; generationCount = 0
        failed = []; failedOrder = []; failureCount = 0
    }

    private func use(_ key: String) -> FilePreviewPicture? {
        guard let entry = entries[key] else { return nil }
        if recency.last != key, let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
            recency.append(key)
        }
        return entry.picture
    }

    private func insert(_ picture: FilePreviewPicture, key: String) {
        let cost = picture.image.bytesPerRow * picture.image.height + picture.blurred.bytesPerRow * picture.blurred.height
        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
            recency.removeAll { $0 == key }
        }
        entries[key] = (picture, cost)
        recency.append(key)
        totalCost += cost
        // The newest is never evicted for its own arrival.
        while recency.count > 1, recency.count > Self.countLimit || totalCost > Self.costLimit {
            let oldest = recency.removeFirst()
            totalCost -= entries.removeValue(forKey: oldest)?.cost ?? 0
        }
    }

    private func recordFailure(_ key: String) {
        failureCount += 1
        guard failed.insert(key).inserted else { return }
        failedOrder.append(key)
        if failedOrder.count > 256 { failed.remove(failedOrder.removeFirst()) }
    }

    private func key(_ url: URL, kind: FilePreviewKind, dark: Bool) -> String {
        // Not `URL.resourceValues`: a URL value caches what it read.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .flatMap { $0 }?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.path)|\(modified)|\(kind.dependsOnTheme ? (dark ? "d" : "l") : "-")"
    }

    func cached(_ url: URL, kind: FilePreviewKind, dark: Bool) -> FilePreviewPicture? {
        use(key(url, kind: kind, dark: dark))
    }

    func preview(_ url: URL, kind: FilePreviewKind, dark: Bool, onReady: @escaping () -> Void) -> FilePreviewPicture? {
        let key = key(url, kind: kind, dark: dark)
        if let hit = use(key) { return hit }
        if failed.contains(key) { return nil }
        if pending[key] != nil { pending[key]?.append(onReady); return nil }
        pending[key] = [onReady]
        generationCount += 1
        Task.detached(priority: .utility) {
            let made = await Self.generate(url, kind: kind, dark: dark)
            await MainActor.run {
                let store = FilePreviewStore.shared
                let waiting = store.pending.removeValue(forKey: key) ?? []
                guard let made else {
                    // Nothing changed for the card: it keeps its placeholder.
                    store.recordFailure(key)
                    return
                }
                store.insert(made, key: key)
                waiting.forEach { $0() }
            }
        }
        return nil
    }

    // MARK: generation (off the main actor)

    nonisolated private static func generate(_ url: URL, kind: FilePreviewKind, dark: Bool) async -> FilePreviewPicture? {
        let pixelHeight = Int(sourceHeight * scale)
        // The thumbnail's type is the house text colours, resolved for the theme
        // the picture is made in (the bridge is main-actor; the drawing is not).
        let (ink, dim) = await MainActor.run { () -> (NSColor, NSColor) in
            let theme: TokenTheme = dark ? .dark : .light
            return (TextToken.textPrimary.color.nsColor(for: theme), TextToken.textSecondary.color.nsColor(for: theme))
        }
        let picture: CGImage?
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // The widest a thumbnail draws is 240pt, 480px at 2x.
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        case .pdf:
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let box = page.bounds(for: .cropBox)
            let width = 200 * Int(scale)
            picture = bitmap(width: width, height: pixelHeight) { ctx in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: pixelHeight))
                let factor = CGFloat(width) / box.width   // top-aligned crop of the first page
                ctx.translateBy(x: 0, y: CGFloat(pixelHeight) - box.height * factor)
                ctx.scaleBy(x: factor, y: factor)
                page.draw(with: .cropBox, to: ctx)
            }
        case .web:
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 360, height: 224), scale: scale, representationTypes: .thumbnail)
            let rendered: CGImage? = await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    continuation.resume(returning: rep?.cgImage)
                }
            }
            picture = rendered
        case .document, .code:
            guard let text = readHead(url) else { return nil }
            let width = (kind == .document ? 220 : 260) * Int(scale)
            picture = bitmap(width: width, height: pixelHeight) { ctx in
                ctx.setFillColor(dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: pixelHeight))
                ctx.translateBy(x: 0, y: CGFloat(pixelHeight)); ctx.scaleBy(x: scale, y: -scale)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                drawText(text, kind: kind, rect: CGRect(x: 10, y: 8, width: CGFloat(width) / scale - 20, height: sourceHeight - 16), ink: ink, dim: dim)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let picture, let blurred = blurredCopy(of: picture) else { return nil }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
        return FilePreviewPicture(image: picture, blurred: blurred, byteCount: bytes,
                                  pixelSize: kind == .image ? pixelSize(of: url) : nil)
    }

    /// Width and height from the image's header, upright (EXIF orientations 5–8 swap them).
    nonisolated private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    nonisolated private static func readHead(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 4096) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func bitmap(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx)
        return ctx.makeImage()
    }

    nonisolated private static func blurredCopy(of image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: 9]),
              let out = blur.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(out, from: input.extent)
    }

    /// The first lines as type: a markdown title that wraps to two lines at
    /// most, then body lines; code as plain mono. Every line ends at an
    /// ellipsis rather than mid-glyph.
    nonisolated private static func drawText(_ text: String, kind: FilePreviewKind, rect: CGRect, ink: NSColor, dim: NSColor) {
        let tail = NSMutableParagraphStyle(); tail.lineBreakMode = .byTruncatingTail
        let wrap = NSMutableParagraphStyle(); wrap.lineBreakMode = .byWordWrapping
        var y = rect.minY
        func put(_ line: String, font: NSFont, color: NSColor, style: NSParagraphStyle, lines: Int) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            let room = font.pointSize * 1.45 * CGFloat(lines)
            guard y + font.pointSize * 1.45 <= rect.maxY else { return }
            let bounds = (line as NSString).boundingRect(
                with: CGSize(width: rect.width, height: room), options: [.usesLineFragmentOrigin], attributes: attrs)
            let height = min(room, ceil(bounds.height))
            (line as NSString).draw(
                with: CGRect(x: rect.minX, y: y, width: rect.width, height: height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            y += height + 2
        }
        if kind == .code {
            let mono = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).filter({ !$0.hasPrefix("//") }).prefix(10) {
                put(String(line), font: mono, color: ink, style: tail, lines: 1)
            }
            return
        }
        var titled = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(14) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("---") { continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                line = String(line.drop(while: { $0 == "#" || $0 == " " }))
                put(line, font: .systemFont(ofSize: level == 1 ? 12 : 10, weight: .semibold), color: ink, style: wrap, lines: level == 1 && !titled ? 2 : 1)
                titled = true
            } else {
                if line.hasPrefix("- ") { line = "•  " + line.dropFirst(2) }
                line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                put(line, font: .systemFont(ofSize: 9), color: dim, style: tail, lines: 1)
            }
        }
    }
}
