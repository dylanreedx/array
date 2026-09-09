import Foundation
import ContinuumRevivedAgentContent

public struct BoardAttachment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var filename: String
    public var contentType: String
    public var pixelWidth: UInt
    public var pixelHeight: UInt
    public var byteCount: UInt64

    public init(id: UUID = UUID(), filename: String, contentType: String, pixelWidth: UInt, pixelHeight: UInt, byteCount: UInt64) {
        self.id = id; self.filename = filename; self.contentType = contentType
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.byteCount = byteCount
    }
    public var imageURL: String { "array-task-image://" + id.uuidString.lowercased() }
}

public struct BoardTaskContent: Equatable, Codable, Sendable {
    public var title: String
    public var body: String
    public var attachments: [BoardAttachment]
    public init(card: BoardCard) {
        title = card.title; body = card.body; attachments = card.attachments
    }
}

/// Frozen context kept alongside the user's independent instructions in a composer.
public struct BoardTaskContext: Codable, Equatable, Sendable {
    public var boardID: UUID
    public var cardID: UUID
    public var revision: UInt64
    public var title: String
    public var body: String
    public var imageAttachmentIDs: [AgentImageAttachmentID]

    public init(boardID: UUID, card: BoardCard, revision: UInt64, imageAttachmentIDs: [AgentImageAttachmentID]) {
        self.boardID = boardID; cardID = card.id; self.revision = revision
        title = card.title
        body = card.body
        for image in card.attachments {
            body = body.replacingOccurrences(of: image.imageURL, with: "attached-image:" + image.filename)
        }
        self.imageAttachmentIDs = imageAttachmentIDs
    }

    public func promptText(additionalInstructions: String) -> String {
        var text = "# Task: " + title
        text += "\n\n# Array task reference\n"
        text += "boardId: \(boardID.uuidString.lowercased())\n"
        text += "cardId: \(cardID.uuidString.lowercased())\n"
        text += "observedRevision: \(revision)"
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n\n" + body }
        if !additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\n# Additional instructions\n" + additionalInstructions
        }
        return text
    }
}

/// Immutable project-owned originals. Agent assignment never transfers ownership.
public actor BoardAttachmentStore {
    public let root: URL
    public init(projectRoot: URL) {
        root = projectRoot.appendingPathComponent(".array/boards/assets", isDirectory: true)
    }
    public nonisolated func fileURL(boardID: UUID, attachmentID: UUID) -> URL {
        root.appendingPathComponent(boardID.uuidString, isDirectory: true).appendingPathComponent(attachmentID.uuidString)
    }
    public func importImage(_ data: Data, filename: String, validation: AgentComposerImageValidation, boardID: UUID) throws -> BoardAttachment {
        guard !data.isEmpty, let width = validation.pixelWidth, let height = validation.pixelHeight else {
            throw AgentComposerAttachmentStoreError.imageInputNotValidated("missing image dimensions")
        }
        let attachment = BoardAttachment(filename: filename, contentType: validation.contentType,
                                         pixelWidth: width, pixelHeight: height, byteCount: UInt64(data.count))
        let url = fileURL(boardID: boardID, attachmentID: attachment.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return attachment
    }
    public func read(boardID: UUID, attachmentID: UUID) throws -> Data {
        try Data(contentsOf: fileURL(boardID: boardID, attachmentID: attachmentID))
    }
}
