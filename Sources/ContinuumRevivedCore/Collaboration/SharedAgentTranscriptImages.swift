import CryptoKit
import Foundation
import ContinuumRevivedAgentContent

/// Bounded, content-addressed image transfer. The host sends a manifest for
/// each visible attachment and the bytes once per digest in small frames.
public enum SharedAgentTranscriptImages {
    public static let maxImageBytes = 512 * 1024
    public static let maxTotalBytes = 512 * 1024
    public static let chunkBytes = 16 * 1024

    public struct Manifest: Codable, Equatable, Sendable {
        public let attachment: AgentImageAttachmentID
        public let digest: String
        public let byteCount: Int
        public init(attachment: AgentImageAttachmentID, data: Data) {
            self.attachment = attachment
            digest = SharedAgentTranscriptImages.digest(data)
            byteCount = data.count
        }
    }
    public struct Chunk: Codable, Equatable, Sendable {
        public let digest: String
        public let offset: Int
        public let bytes: Data
        public init(digest: String, offset: Int, bytes: Data) {
            self.digest = digest; self.offset = offset; self.bytes = bytes
        }
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func chunks(_ data: Data) -> [Chunk] {
        guard !data.isEmpty, data.count <= maxImageBytes else { return [] }
        let hash = digest(data)
        return stride(from: 0, to: data.count, by: chunkBytes).map { offset in
            Chunk(digest: hash, offset: offset, bytes: data.subdata(in: offset..<min(offset + chunkBytes, data.count)))
        }
    }

    /// A recipient exposes bytes only after the complete content passes its
    /// digest check. Invalid order, oversized images and excess total retention
    /// are rejected rather than allocating from untrusted lengths.
    public struct Receiver: Equatable, Sendable {
        private var manifests: [AgentImageAttachmentID: Manifest] = [:]
        private var pending: [String: Data] = [:]
        private var complete: [String: Data] = [:]
        public init() {}
        public enum Failure: Error { case invalidManifest, invalidChunk, digestMismatch, overBudget }

        public mutating func register(_ manifest: Manifest) throws {
            guard (manifests[manifest.attachment] != nil || manifests.count < 64),
                  manifest.byteCount > 0, manifest.byteCount <= SharedAgentTranscriptImages.maxImageBytes,
                  manifest.digest.count == 64,
                  manifest.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidManifest
            }
            if let existing = manifests.values.first(where: { $0.digest == manifest.digest }),
               existing.byteCount != manifest.byteCount { throw Failure.invalidManifest }
            let sizes = Dictionary(manifests.values.map { ($0.digest, $0.byteCount) }, uniquingKeysWith: { first, _ in first })
            let extra = sizes[manifest.digest] == nil ? manifest.byteCount : 0
            guard sizes.values.reduce(0, +) + extra <= SharedAgentTranscriptImages.maxTotalBytes else { throw Failure.overBudget }
            manifests[manifest.attachment] = manifest
        }
        public mutating func receive(_ chunk: Chunk) throws {
            guard let manifest = manifests.values.first(where: { $0.digest == chunk.digest }),
                  !chunk.bytes.isEmpty, chunk.bytes.count <= SharedAgentTranscriptImages.chunkBytes,
                  complete[chunk.digest] == nil else { throw Failure.invalidChunk }
            var data = pending[chunk.digest] ?? Data()
            guard chunk.offset == data.count, chunk.bytes.count <= manifest.byteCount - data.count else { throw Failure.invalidChunk }
            data.append(chunk.bytes)
            if data.count == manifest.byteCount {
                guard SharedAgentTranscriptImages.digest(data) == chunk.digest else {
                    pending[chunk.digest] = nil
                    throw Failure.digestMismatch
                }
                pending[chunk.digest] = nil; complete[chunk.digest] = data
            } else { pending[chunk.digest] = data }
        }
        public func data(for attachment: AgentImageAttachmentID) -> Data? {
            manifests[attachment].flatMap { complete[$0.digest] }
        }
    }
}
