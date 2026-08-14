import Foundation

/// Sync-safe display metadata for one local file reference submitted with a
/// prompt. The local path is a transport capability and must never enter this
/// transcript representation.
public struct AgentFileReferenceMetadata: Codable, Equatable, Sendable {
    public var displayName: String
    public var contentType: String

    public init(displayName: String, contentType: String) {
        self.displayName = displayName
        self.contentType = contentType
    }
}

/// The path-free file references shown with one submitted user message.
public struct AgentFileReferencePayload: Codable, Equatable, Sendable {
    public var files: [AgentFileReferenceMetadata]

    public init(files: [AgentFileReferenceMetadata]) {
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case files }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        files = try values.decodeIfPresent([AgentFileReferenceMetadata].self, forKey: .files) ?? []
    }
}
