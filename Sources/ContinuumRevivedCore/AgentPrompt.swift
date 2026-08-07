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

/// Provider-neutral prompt submitted to an agent adapter. Text is the only
/// visible prose. Attachments are local, non-sync transport capabilities; only
/// their path-free metadata can be copied into persisted transcript content.
public struct AgentPrompt: Equatable, Sendable {
    public var text: String
    public var imageAttachments: [AgentPromptImageAttachment]

    public init(text: String = "", imageAttachments: [AgentPromptImageAttachment] = []) {
        self.text = text
        self.imageAttachments = imageAttachments
    }

    public init(_ text: String) {
        self.init(text: text, imageAttachments: [])
    }

    /// Whitespace-only prose is not a sendable prompt; a local attachment is.
    /// Keep this provider-neutral predicate in one place so keyboard, composer,
    /// and supervisor routes agree on image-only sends.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imageAttachments.isEmpty
    }
}
