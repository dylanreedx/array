import ContinuumRevivedAgentContent
import Foundation

/// Local provider-input contract for one drafted image. The sync-safe metadata
/// may be projected into a transcript; the file URL is a local transport
/// capability and is intentionally not Codable.
public struct AgentPromptImageAttachment: Equatable, Sendable {
    public var metadata: AgentImageAttachmentMetadata
    public var fileURL: URL

    public init(metadata: AgentImageAttachmentMetadata, fileURL: URL) {
        precondition(fileURL.isFileURL, "AgentPromptImageAttachment requires a local file URL")
        self.metadata = metadata
        self.fileURL = fileURL
    }

    public var imagePayload: AgentImagePayload {
        AgentImagePayload(attachment: metadata)
    }

    public var piPathReference: String {
        "@\(fileURL.path)"
    }
}

/// Local provider-input contract for one referenced file (a doc/text/code file
/// dropped or pasted onto the composer). Unlike an image, NO bytes are embedded
/// or copied — the agent's own Read tool fetches the content from the path. Only
/// the path-free metadata may project into a transcript; the file URL is a local
/// transport capability and is intentionally not Codable.
public struct AgentPromptFileReference: Equatable, Sendable {
    public var displayName: String
    public var contentType: String
    public var fileURL: URL

    public init(displayName: String, contentType: String, fileURL: URL) {
        precondition(fileURL.isFileURL, "AgentPromptFileReference requires a local file URL")
        self.displayName = displayName
        self.contentType = contentType
        self.fileURL = fileURL
    }

    /// The `@/local/file` reference handed to a provider CLI — the same contract
    /// as an image attachment's, always materialized as its own argv element (pi)
    /// or a newline-delimited line (claude/codex) so a path with spaces or shell
    /// metacharacters stays a single literal token.
    public var piPathReference: String {
        "@\(fileURL.path)"
    }

    public var transcriptMetadata: AgentFileReferenceMetadata {
        AgentFileReferenceMetadata(displayName: displayName, contentType: contentType)
    }
}

/// Provider-neutral prompt submitted to an agent adapter. Text is the only
/// visible prose. Attachments are local, non-sync transport capabilities; only
/// their path-free metadata can be copied into persisted transcript content.
public struct AgentPrompt: Equatable, Sendable {
    public var text: String
    public var imageAttachments: [AgentPromptImageAttachment]
    public var fileReferences: [AgentPromptFileReference]

    public init(
        text: String = "",
        imageAttachments: [AgentPromptImageAttachment] = [],
        fileReferences: [AgentPromptFileReference] = []
    ) {
        self.text = text
        self.imageAttachments = imageAttachments
        self.fileReferences = fileReferences
    }

    public init(_ text: String) {
        self.init(text: text, imageAttachments: [], fileReferences: [])
    }

    /// Whitespace-only prose is not a sendable prompt; a local attachment or a
    /// file reference is. Keep this provider-neutral predicate in one place so
    /// keyboard, composer, and supervisor routes agree on attachment-only sends.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageAttachments.isEmpty
            && fileReferences.isEmpty
    }
}
