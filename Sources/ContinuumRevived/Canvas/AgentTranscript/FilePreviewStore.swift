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
    /// Width over height of the picture.
    var aspect: CGFloat { CGFloat(image.width) / max(1, CGFloat(image.height)) }
}

/// Thumbnails for the Changes card, made off the main thread and cached by
/// path and modification time (and appearance, for drawn text). Bounded, so a
/// long session cannot grow it: 32 pictures or about 20 MB, whichever first.
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

    private let cache = NSCache<NSString, Box>()
    private var pending: [String: [() -> Void]] = [:]
    private(set) var generationCount = 0
    private final class Box { let value: FilePreviewPicture; init(_ value: FilePreviewPicture) { self.value = value } }

    init() { cache.countLimit = 32; cache.totalCostLimit = 20 * 1_048_576 }

    func resetForChecks() { cache.removeAllObjects(); pending = [:]; generationCount = 0 }

    private func key(_ url: URL, kind: FilePreviewKind, dark: Bool) -> String {
        // Not `URL.resourceValues`: a URL value caches what it read.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .flatMap { $0 }?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.path)|\(modified)|\(kind.dependsOnTheme ? (dark ? "d" : "l") : "-")"
    }

    func cached(_ url: URL, kind: FilePreviewKind, dark: Bool) -> FilePreviewPicture? {
        cache.object(forKey: key(url, kind: kind, dark: dark) as NSString)?.value
    }

    func preview(_ url: URL, kind: FilePreviewKind, dark: Bool, onReady: @escaping () -> Void) -> FilePreviewPicture? {
        let key = key(url, kind: kind, dark: dark)
        if let hit = cache.object(forKey: key as NSString) { return hit.value }
        if pending[key] != nil { pending[key]?.append(onReady); return nil }
        pending[key] = [onReady]
        generationCount += 1
        Task.detached(priority: .utility) {
            let made = await Self.generate(url, kind: kind, dark: dark)
            await MainActor.run {
                if let made {
                    let cost = made.image.bytesPerRow * made.image.height * 2
                    FilePreviewStore.shared.cache.setObject(Box(made), forKey: key as NSString, cost: cost)
                }
                let waiting = FilePreviewStore.shared.pending.removeValue(forKey: key) ?? []
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
                kCGImageSourceThumbnailMaxPixelSize: 720,
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
        return FilePreviewPicture(image: picture, blurred: blurred)
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
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: 5]),
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
