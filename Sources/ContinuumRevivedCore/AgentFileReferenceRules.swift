import Foundation
import UniformTypeIdentifiers

/// The allowlist that decides which dropped/pasted files the composer turns into
/// `@/path` references (reference-not-embed: the agent's own Read tool fetches
/// the bytes). Kept pure and in Core so the security-relevant decision is
/// witnessed offline, independent of the AppKit pasteboard glue that calls it.
public enum AgentFileReferenceRules {
    private static let knownTextExtensions: Set<String> = [
        "bash", "c", "cc", "cfg", "conf", "cpp", "css", "csv", "fish", "gql", "go",
        "h", "hpp", "htm", "html", "ini", "java", "js", "json", "jsonl", "jsx", "kt",
        "kts", "less", "log", "m", "md", "mdx", "mm", "pbxproj", "plist", "proto",
        "ps1", "py", "rb", "rs", "scss", "sh", "sql", "strings", "swift", "text", "toml",
        "ts", "tsv", "tsx", "txt", "xcconfig", "xml", "yaml", "yml", "zsh",
    ]

    /// A file is referenceable when the agent's Read tool can consume it: any
    /// text/source/markup document, or a PDF. Images are deliberately NOT
    /// referenceable here — they take the embedding image-attachment path so a
    /// vision model receives the bytes. Everything else (archives, binaries,
    /// audio/video, unknown types) is rejected.
    public static func isReferenceableContentType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return isReferenceable(type)
    }

    public static func isReferenceable(_ type: UTType) -> Bool {
        // An image is never a reference — the image path embeds it instead.
        if type.conforms(to: .image) { return false }
        return type.conforms(to: .text) || type.conforms(to: .pdf)
    }

    /// Resolves the content type shared by drag/drop and indexed `@` acceptance.
    /// Launch Services can return a dynamic, non-conforming UTI in headless or
    /// newly-created-file contexts, so known text/code extensions receive a
    /// conservative text fallback while unknown/binary/image extensions do not.
    public static func referenceableContentType(for url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           isReferenceable(type) { return type }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if knownTextExtensions.contains(ext) { return .plainText }
        let conventional = Set(["README", "LICENSE", "NOTICE", "Makefile", "Dockerfile"])
        if conventional.contains(url.deletingPathExtension().lastPathComponent) { return .plainText }
        return nil
    }
}
