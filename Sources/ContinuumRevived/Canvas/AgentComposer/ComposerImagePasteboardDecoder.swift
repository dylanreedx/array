import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// AppKit-only image intake seam for the composer. It inspects paste/drop data
/// directly and deliberately avoids `NSAttributedString`/`NSTextAttachment`
/// import paths, so pasted images never become opaque TextKit attachments.
struct ComposerImagePasteboardDecoder {
    static let jpegPasteboardType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    static let pngPasteboardType = NSPasteboard.PasteboardType.png
    static let tiffPasteboardType = NSPasteboard.PasteboardType.tiff

    static let acceptedContentTypes: Set<String> = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.tiff.identifier,
    ]

    static func decodedItems(from pasteboard: NSPasteboard) -> [ComposerDecodedImagePasteboardItem] {
        var results: [ComposerDecodedImagePasteboardItem] = []
        var seenFileURLs = Set<URL>()

        for url in localFileURLs(from: pasteboard) where !seenFileURLs.contains(url) {
            seenFileURLs.insert(url)
            guard let item = ComposerDecodedImagePasteboardItem(fileURL: url) else { continue }
            results.append(item)
        }

        for item in pasteboard.pasteboardItems ?? [] {
            for candidate in dataCandidates(in: item) {
                guard let decoded = ComposerDecodedImagePasteboardItem(
                    data: candidate.data,
                    contentType: candidate.contentType,
                    suggestedFilename: candidate.suggestedFilename
                ) else { continue }
                results.append(decoded)
            }
        }

        return results
    }

    static func canDecode(_ pasteboard: NSPasteboard) -> Bool {
        !decodedItems(from: pasteboard).isEmpty
    }

    private static func localFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            guard let url = object as? URL, url.isFileURL else { return nil }
            return url
        }
    }

    private static func dataCandidates(in item: NSPasteboardItem) -> [(data: Data, contentType: String, suggestedFilename: String)] {
        [
            (pngPasteboardType, UTType.png.identifier, "Pasted image.png"),
            (jpegPasteboardType, UTType.jpeg.identifier, "Pasted image.jpg"),
            (tiffPasteboardType, UTType.tiff.identifier, "Pasted image.tiff"),
        ].compactMap { pasteboardType, contentType, filename in
            guard let data = item.data(forType: pasteboardType), !data.isEmpty else { return nil }
            return (data, contentType, filename)
        }
    }
}

struct ComposerDecodedImagePasteboardItem: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case fileURL(URL)
        case data(Data)
    }

    var source: Source
    var suggestedFilename: String
    var contentType: String
    var byteCount: UInt64?
    var pixelWidth: UInt?
    var pixelHeight: UInt?

    init?(
        data: Data,
        contentType: String,
        suggestedFilename: String
    ) {
        guard ComposerImagePasteboardDecoder.acceptedContentTypes.contains(contentType),
              let metadata = ComposerImageMetadataReader.metadata(for: data),
              metadata.isSupportedImage
        else { return nil }
        source = .data(data)
        self.suggestedFilename = ComposerImageDisplay.sanitizedFilename(suggestedFilename)
        self.contentType = metadata.contentType ?? contentType
        byteCount = UInt64(data.count)
        pixelWidth = metadata.pixelWidth
        pixelHeight = metadata.pixelHeight
    }

    init?(fileURL: URL) {
        guard fileURL.isFileURL,
              let metadata = ComposerImageMetadataReader.metadata(for: fileURL),
              metadata.isSupportedImage
        else { return nil }
        source = .fileURL(fileURL)
        suggestedFilename = ComposerImageDisplay.sanitizedFilename(fileURL.lastPathComponent)
        contentType = metadata.contentType ?? Self.contentType(fromExtensionOf: fileURL)
        byteCount = metadata.byteCount
        pixelWidth = metadata.pixelWidth
        pixelHeight = metadata.pixelHeight
    }

    private static func contentType(fromExtensionOf url: URL) -> String {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return UTType.png.identifier }
        return type.identifier
    }
}

struct ComposerImageAttachmentImportPipeline: Sendable {
    struct ImportActions: Sendable {
        /// Persists pasted image bytes into Lane A's local/private attachment
        /// store and returns the local provider-capability URL. This is injected
        /// so reusable UI never chooses storage, sync, or import policy.
        var storePastedImageData: @Sendable (Data, ComposerDecodedImagePasteboardItem) async throws -> URL
        /// Adopts or copies a local image file into Lane A storage. The default
        /// preserves the local file capability exactly as dropped/pasted.
        var adoptImageFileURL: @Sendable (URL, ComposerDecodedImagePasteboardItem) async throws -> URL
        var makeAttachmentID: @Sendable () -> AgentImageAttachmentID

        init(
            storePastedImageData: @escaping @Sendable (Data, ComposerDecodedImagePasteboardItem) async throws -> URL,
            adoptImageFileURL: @escaping @Sendable (URL, ComposerDecodedImagePasteboardItem) async throws -> URL = { url, _ in url },
            makeAttachmentID: @escaping @Sendable () -> AgentImageAttachmentID = {
                AgentImageAttachmentID(rawValue: UUID().uuidString)!
            }
        ) {
            self.storePastedImageData = storePastedImageData
            self.adoptImageFileURL = adoptImageFileURL
            self.makeAttachmentID = makeAttachmentID
        }
    }

    var actions: ImportActions

    init(actions: ImportActions) {
        self.actions = actions
    }

    func importAttachments(
        from decodedItems: [ComposerDecodedImagePasteboardItem]
    ) async -> [Result<AgentPromptImageAttachment, Error>] {
        var results: [Result<AgentPromptImageAttachment, Error>] = []
        results.reserveCapacity(decodedItems.count)
        for item in decodedItems {
            do {
                let fileURL: URL
                switch item.source {
                case .fileURL(let url):
                    fileURL = try await actions.adoptImageFileURL(url, item)
                case .data(let data):
                    fileURL = try await actions.storePastedImageData(data, item)
                }
                guard fileURL.isFileURL else { throw ComposerImageImportError.nonFileURL }
                let metadata = AgentImageAttachmentMetadata(
                    id: actions.makeAttachmentID(),
                    displayName: item.suggestedFilename,
                    contentType: item.contentType,
                    byteCount: item.byteCount,
                    pixelWidth: item.pixelWidth,
                    pixelHeight: item.pixelHeight
                )
                results.append(.success(AgentPromptImageAttachment(metadata: metadata, fileURL: fileURL)))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }
}

enum ComposerImageImportError: Error, Equatable, CustomStringConvertible {
    case nonFileURL

    var description: String {
        switch self {
        case .nonFileURL: return "composer image import returned a non-file URL"
        }
    }
}

struct ComposerImageMetadata: Equatable, Sendable {
    var contentType: String?
    var byteCount: UInt64?
    var pixelWidth: UInt?
    var pixelHeight: UInt?

    var isSupportedImage: Bool {
        guard let contentType, ComposerImagePasteboardDecoder.acceptedContentTypes.contains(contentType) else {
            return false
        }
        return pixelWidth.map { $0 > 0 } ?? true
            && pixelHeight.map { $0 > 0 } ?? true
    }
}

enum ComposerImageMetadataReader {
    static func metadata(for fileURL: URL) -> ComposerImageMetadata? {
        guard fileURL.isFileURL else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else { return nil }
        var metadata = metadata(from: source)
        if metadata.byteCount == nil {
            metadata.byteCount = byteCount(for: fileURL)
        }
        return metadata
    }

    static func metadata(for data: Data) -> ComposerImageMetadata? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        var metadata = metadata(from: source)
        metadata.byteCount = UInt64(data.count)
        return metadata
    }

    private static func metadata(from source: CGImageSource) -> ComposerImageMetadata {
        let type = CGImageSourceGetType(source) as String?
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any]
        let width = unsigned(properties?[kCGImagePropertyPixelWidth])
        let height = unsigned(properties?[kCGImagePropertyPixelHeight])
        return ComposerImageMetadata(contentType: type, byteCount: nil, pixelWidth: width, pixelHeight: height)
    }

    private static func unsigned(_ value: Any?) -> UInt? {
        switch value {
        case let number as NSNumber:
            let intValue = number.intValue
            return intValue > 0 ? UInt(intValue) : nil
        case let int as Int:
            return int > 0 ? UInt(int) : nil
        default:
            return nil
        }
    }

    private static func byteCount(for url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize, size >= 0 else {
            return nil
        }
        return UInt64(size)
    }
}

enum ComposerImageDisplay {
    static func sanitizedFilename(_ value: String?, fallback: String = "Image") -> String {
        let trimmed = (value ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
        let scalars = trimmed.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = collapsed.isEmpty ? fallback : collapsed
        if candidate.count <= 80 { return candidate }
        let prefix = candidate.prefix(72)
        return "\(prefix)…"
    }

    static func typeLabel(_ contentType: String?) -> String {
        guard let contentType, let type = UTType(contentType) else { return "Image" }
        if type == .png { return "PNG" }
        if type == .jpeg { return "JPEG" }
        if type == .tiff { return "TIFF" }
        return type.localizedDescription ?? contentType
    }

    static func dimensionsLabel(width: UInt?, height: UInt?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    static func detailLabel(contentType: String?, width: UInt?, height: UInt?) -> String {
        [typeLabel(contentType), dimensionsLabel(width: width, height: height)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    static func accessibilityLabel(
        filename: String?,
        contentType: String?,
        width: UInt?,
        height: UInt?,
        state: ComposerImageAttachmentState
    ) -> String {
        let name = sanitizedFilename(filename)
        let detail = detailLabel(contentType: contentType, width: width, height: height)
        return "Image attachment, \(name), \(detail), \(state.accessibilityLabel)"
    }
}
