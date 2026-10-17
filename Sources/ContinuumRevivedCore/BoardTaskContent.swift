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

    /// The text the AGENT receives. Its transcript twin is
    /// `BoardTaskPromptEnvelope.parse`, below: both read the same literals, so
    /// a change to this format cannot leave the user's bubble printing it raw.
    public func promptText(additionalInstructions: String) -> String {
        typealias Format = BoardTaskPromptEnvelope
        var text = Format.titlePrefix + title
        text += "\n\n" + Format.referenceHeading + "\n"
        text += Format.boardIDKey + boardID.uuidString.lowercased() + "\n"
        text += Format.cardIDKey + cardID.uuidString.lowercased() + "\n"
        text += Format.revisionKey + String(revision)
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "\n\n" + body }
        if !additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\n" + Format.instructionsHeading + "\n" + additionalInstructions
        }
        return text
    }
}

/// A sent `BoardTaskContext.promptText`, recognised again on the way into the
/// transcript. Array writes this envelope itself, so the parser accepts exactly
/// that shape — a title line, then the reference block with two UUIDs and a
/// revision — and nothing looser: a user's own "# Task:" prose stays prose.
///
/// Every route a user turn takes into the document goes through it: the live
/// send, and the claude / codex / pi session readers a relaunch rehydrates from,
/// which hand back the same text (claude's with any `@path` lines appended).
public struct BoardTaskPromptEnvelope: Equatable, Sendable {
    static let titlePrefix = "# Task: "
    static let referenceHeading = "# Array task reference"
    static let boardIDKey = "boardId: "
    static let cardIDKey = "cardId: "
    static let revisionKey = "observedRevision: "
    static let instructionsHeading = "# Additional instructions"

    public var title: String
    public var boardID: UUID
    public var cardID: UUID
    public var revision: UInt64
    public var body: String
    public var additionalInstructions: String

    public static func parse(_ text: String) -> BoardTaskPromptEnvelope? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(titlePrefix) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 6,
              lines[1].isEmpty,
              lines[2] == referenceHeading,
              lines[3].hasPrefix(boardIDKey), let boardID = UUID(uuidString: String(lines[3].dropFirst(boardIDKey.count))),
              lines[4].hasPrefix(cardIDKey), let cardID = UUID(uuidString: String(lines[4].dropFirst(cardIDKey.count))),
              lines[5].hasPrefix(revisionKey), let revision = UInt64(lines[5].dropFirst(revisionKey.count))
        else { return nil }
        let title = String(lines[0].dropFirst(titlePrefix.count))
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var rest = lines.count > 6 ? lines[6] : ""
        if lines.count > 6 {
            // The generator puts a blank line between the reference and what follows.
            guard rest.hasPrefix("\n") else { return nil }
            rest.removeFirst()
        }
        // The user's instructions are the LAST section, so the last heading wins:
        // a task body may quote the heading, the user's own words come after it.
        var body = rest
        var instructions = ""
        let marker = instructionsHeading + "\n"
        if rest.hasPrefix(marker) {
            body = ""
            instructions = String(rest.dropFirst(marker.count))
        }
        if let range = rest.range(of: "\n\n" + marker, options: .backwards) {
            body = String(rest[..<range.lowerBound])
            instructions = String(rest[range.upperBound...])
        }
        return BoardTaskPromptEnvelope(
            title: title, boardID: boardID, cardID: cardID, revision: revision,
            body: body, additionalInstructions: instructions
        )
    }

    /// What the user's bubble shows: the title and the body's first line of
    /// prose (a leading Markdown heading is skipped in favour of the sentence
    /// under it; marker characters are stripped). No identifiers.
    public var transcriptReference: AgentTaskReferencePayload {
        AgentTaskReferencePayload(title: title, summary: Self.summary(of: body))
    }

    static func summary(of body: String) -> String? {
        var fallback: String?
        for raw in body.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "---", !line.hasPrefix("```") else { continue }
            let isHeading = line.hasPrefix("#")
            while line.hasPrefix("#") { line.removeFirst() }
            for marker in ["> ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
                line.removeFirst(marker.count)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if isHeading {
                if fallback == nil { fallback = line }
                continue
            }
            return String(line.prefix(240))
        }
        return fallback.map { String($0.prefix(240)) }
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
