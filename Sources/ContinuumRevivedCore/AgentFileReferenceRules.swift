import Foundation
import UniformTypeIdentifiers

/// The allowlist that decides which dropped/pasted files the composer turns into
/// `@/path` references (reference-not-embed: the agent's own Read tool fetches
/// the bytes). Kept pure and in Core so the security-relevant decision is
/// witnessed offline, independent of the AppKit pasteboard glue that calls it.
public enum AgentFileReferenceRules {
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
}
