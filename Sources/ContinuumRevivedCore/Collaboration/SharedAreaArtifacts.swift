import Foundation
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// Artifact routes for one admitted area (COL-16). Reads return verified bytes
/// in memory; nothing here accepts a path on the reading machine.
/// An upload pass that could not run: not connected, or no artifact transport.
public struct SharedAreaArtifactUploadDeferral: Error, Equatable {
    public let status: SharedAreaController.Status
    public let hasTransport: Bool
}

public protocol SharedAreaArtifactTransport: Sendable {
    func artifactState(object: UUID) async throws -> Collaboration.Artifact.State
    func readArtifact(object: UUID, revision: UUID?) async throws -> CollaborationArtifactContents
    func publishArtifact(epoch: Int64, capture: Collaboration.Artifact.Capture) async throws -> Collaboration.Artifact.PublishReceipt
    func reviewArtifact(object: UUID, request: Collaboration.Artifact.ReviewRequest) async throws -> Collaboration.Artifact.Review
}

extension SharedAreaAPITransport: SharedAreaArtifactTransport {
    public func artifactState(object: UUID) async throws -> Collaboration.Artifact.State {
        try await api.artifactState(area: area, object: object)
    }
    public func readArtifact(object: UUID, revision: UUID?) async throws -> CollaborationArtifactContents {
        try await api.readArtifact(area: area, object: object, revision: revision)
    }
    public func publishArtifact(epoch: Int64, capture: Collaboration.Artifact.Capture) async throws -> Collaboration.Artifact.PublishReceipt {
        try await api.publishArtifact(area: area, epoch: epoch, capture: capture)
    }
    public func reviewArtifact(object: UUID, request: Collaboration.Artifact.ReviewRequest) async throws -> Collaboration.Artifact.Review {
        try await api.reviewArtifact(area: area, object: object, request: request)
    }
}

#if os(macOS)
/// What a diff or file tile would publish, resolved from the persisted tile
/// alone. Capturing it runs git off the main thread.
public enum SharedArtifactSource: Equatable, Sendable {
    case diff(root: URL, source: DiffReviewSource, includeUntracked: Bool)
    case file(root: URL, path: String)

    /// A file outside the project root, or any other tile kind, has no source.
    public static func resolve(tile: Tile, projectRoot: URL, includeUntracked: Bool = false) -> SharedArtifactSource? {
        switch tile.kind {
        case .diffReview:
            return .diff(root: projectRoot, source: DiffReviewSource(metadata: tile.metadata), includeUntracked: includeUntracked)
        case .file:
            guard let path = tile.metadata.documentLocation?.path ?? tile.metadata.filePath else { return nil }
            let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
            let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard file.hasPrefix(root + "/") else { return nil }
            let relative = String(file.dropFirst(root.count + 1))
            return Collaboration.Artifact.isPortablePath(relative) ? .file(root: projectRoot, path: relative) : nil
        default: return nil
        }
    }

    public func draft(producer: SharedArtifactProducer = .init(), now: Date = Date()) throws -> SharedArtifactProducer.Draft {
        switch self {
        case let .file(root, path):
            return try producer.draft(root: root, selection: .files([path]), now: now)
        case let .diff(root, source, includeUntracked):
            let untracked = includeUntracked ? try producer.untrackedPaths(root: root) : []
            switch source.kind {
            case .workingTreeVsHEAD:
                return try producer.draft(root: root, selection: .diff(.workingTree, paths: nil, untracked: untracked), now: now)
            case .branchVsBase, .worktreeVsBase:
                // The producer diffs the checkout's HEAD. A tile showing some
                // other branch would publish bytes it never displayed.
                if let branch = source.branch, branch != "HEAD", try producer.currentBranch(root: root) != branch {
                    throw SharedArtifactProducer.Failure.unsupportedSource
                }
                return try producer.draft(root: root, selection: .diff(.branch(base: source.baseBranch ?? "main"), paths: nil, untracked: []), now: now)
            }
        }
    }

    /// Off-main capture of several sources; each result stands alone.
    public static func drafts<Key: Hashable & Sendable>(_ sources: [Key: SharedArtifactSource],
                                                         producer: SharedArtifactProducer = .init()) async -> [Key: Result<SharedArtifactProducer.Draft, any Error>] {
        await Task.detached(priority: .userInitiated) {
            var results: [Key: Result<SharedArtifactProducer.Draft, any Error>] = [:]
            for (key, source) in sources { results[key] = Result { try source.draft(producer: producer) } }
            return results
        }.value
    }
}
#endif
