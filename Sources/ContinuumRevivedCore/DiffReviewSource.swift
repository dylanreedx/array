import Foundation

public enum DiffReviewSourceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case workingTreeVsHEAD
    case branchVsBase
    case worktreeVsBase
}

public struct DiffReviewSource: Equatable, Sendable {
    public var kind: DiffReviewSourceKind
    public var branch: String?
    public var baseBranch: String?

    public init(kind: DiffReviewSourceKind = .workingTreeVsHEAD, branch: String? = nil, baseBranch: String? = nil) {
        self.kind = kind
        self.branch = branch
        self.baseBranch = baseBranch
    }

    public init(metadata: TileMetadata) {
        let kind = DiffReviewSourceKind(rawValue: metadata.diffSource ?? "") ?? .workingTreeVsHEAD
        self.init(kind: kind, branch: metadata.branch, baseBranch: metadata.baseBranch)
    }

    public var displayName: String {
        switch kind {
        case .workingTreeVsHEAD:
            return "Working tree vs HEAD"
        case .branchVsBase:
            return "Branch \(branch ?? "?") vs \(baseBranch ?? "?")"
        case .worktreeVsBase:
            return "This worktree vs \(baseBranch ?? "?")"
        }
    }

    public func applying(to metadata: TileMetadata) -> TileMetadata {
        var next = metadata
        next.diffSource = kind.rawValue
        next.branch = branch
        next.baseBranch = baseBranch
        return next
    }

    public func gitSource(repositoryURL: URL, currentBranchResolver: (URL) throws -> String) throws -> GitDiffEngine.Source {
        switch kind {
        case .workingTreeVsHEAD:
            return .workingTreeVsHEAD
        case .branchVsBase:
            return .branchVsBase(branch: branch ?? "HEAD", base: baseBranch ?? "main")
        case .worktreeVsBase:
            return .branchVsBase(branch: try currentBranchResolver(repositoryURL), base: baseBranch ?? "main")
        }
    }
}
