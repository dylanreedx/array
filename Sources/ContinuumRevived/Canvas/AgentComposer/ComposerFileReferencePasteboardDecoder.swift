import AppKit
import ContinuumRevivedCore
import Foundation
import UniformTypeIdentifiers

/// AppKit intake for dropped/pasted NON-image files. Mirrors the image decoder's
/// role but produces reference-only capabilities: no bytes are read or copied,
/// only a validated `@/path` the agent's own Read tool will fetch on demand.
/// Images are deliberately not decoded here — they fail the Core allowlist and
/// take the embedding image-attachment path so a vision model gets the bytes.
enum ComposerFileReferencePasteboardDecoder {
    static func decodedReferences(from pasteboard: NSPasteboard) -> [AgentPromptFileReference] {
        var results: [AgentPromptFileReference] = []
        var seen = Set<URL>()
        for url in localFileURLs(from: pasteboard) where !seen.contains(url) {
            seen.insert(url)
            guard let reference = fileReference(for: url) else { continue }
            results.append(reference)
        }
        return results
    }

    static func canDecode(_ pasteboard: NSPasteboard) -> Bool {
        !decodedReferences(from: pasteboard).isEmpty
    }

    /// Validates one URL into a reference: a readable regular file whose resolved
    /// content type is on the Core allowlist. Pure file I/O — witnessable with
    /// real temp files, no pasteboard required.
    static func fileReference(for url: URL) -> AgentPromptFileReference? {
        guard url.isFileURL else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isReadableKey, .contentTypeKey, .nameKey]
        let values = ComposerImageSecurityScopedURLAccess.withAccess(to: url) {
            try? url.resourceValues(forKeys: keys)
        }
        guard let values,
              values.isRegularFile == true,
              values.isReadable == true,
              let type = values.contentType,
              AgentFileReferenceRules.isReferenceable(type)
        else { return nil }
        let name = ComposerImageDisplay.sanitizedFilename(values.name ?? url.lastPathComponent)
        return AgentPromptFileReference(displayName: name, contentType: type.identifier, fileURL: url)
    }

    private static func localFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            guard let url = object as? URL, url.isFileURL else { return nil }
            return url
        }
    }
}
