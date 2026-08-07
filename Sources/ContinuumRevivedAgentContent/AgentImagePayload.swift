import Foundation

/// Sync-safe identity for one image attachment. It is deliberately opaque: it
/// must not be derived from or interpreted as a local file path.
public struct AgentImageAttachmentID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 160 else { return nil }
        guard rawValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let id = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AgentImageAttachmentID must be nonempty, bounded, and contain no control characters"
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Provider-neutral, sync-safe metadata for an image attachment. No local file
/// URL/path lives here; provider adapters keep that capability in their own
/// local transport representation.
public struct AgentImageAttachmentMetadata: Codable, Equatable, Sendable {
    public var id: AgentImageAttachmentID
    public var displayName: String?
    public var contentType: String?
    public var byteCount: UInt64?
    public var pixelWidth: UInt?
    public var pixelHeight: UInt?

    public init(
        id: AgentImageAttachmentID,
        displayName: String? = nil,
        contentType: String? = nil,
        byteCount: UInt64? = nil,
        pixelWidth: UInt? = nil,
        pixelHeight: UInt? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.contentType = contentType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, contentType, byteCount, pixelWidth, pixelHeight
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(AgentImageAttachmentID.self, forKey: .id)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType)
        byteCount = try values.decodeIfPresent(UInt64.self, forKey: .byteCount)
        pixelWidth = try values.decodeIfPresent(UInt.self, forKey: .pixelWidth)
        pixelHeight = try values.decodeIfPresent(UInt.self, forKey: .pixelHeight)
    }
}

public struct AgentImagePayload: Codable, Equatable, Sendable {
    public var attachment: AgentImageAttachmentMetadata
    public var caption: [AgentInline]

    public init(attachment: AgentImageAttachmentMetadata, caption: [AgentInline] = []) {
        self.attachment = attachment
        self.caption = caption
    }

    private enum CodingKeys: String, CodingKey { case attachment, caption }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attachment = try values.decode(AgentImageAttachmentMetadata.self, forKey: .attachment)
        caption = try values.decodeIfPresent([AgentInline].self, forKey: .caption) ?? []
    }
}

public struct AgentImageGalleryPayload: Codable, Equatable, Sendable {
    public var images: [AgentImagePayload]

    /// No product cap is enforced here. Composer/provider policy may validate
    /// capabilities later, but the semantic contract must preserve every local
    /// draft attachment it is given.
    public init(images: [AgentImagePayload]) {
        self.images = images
    }

    private enum CodingKeys: String, CodingKey { case images }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        images = try values.decodeIfPresent([AgentImagePayload].self, forKey: .images) ?? []
    }
}
