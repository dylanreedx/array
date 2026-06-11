import ContinuumRevivedCore
import Foundation

public struct FileTreeSnapshot: Equatable, Sendable {
    public var root: URL
    public var nodes: [FileTreeNode]
    public var isTruncated: Bool
    public var nodeLimit: Int?

    public init(root: URL, nodes: [FileTreeNode], isTruncated: Bool = false, nodeLimit: Int? = nil) {
        self.root = root
        self.nodes = nodes
        self.isTruncated = isTruncated
        self.nodeLimit = nodeLimit
    }
}

public struct FileTreeScanner: Sendable {
    public static let defaultIgnoredNames: Set<String> = [
        ".git",
        "node_modules",
        "target",
        ".build",
        "DerivedData",
        "Pods",
        "vendor",
        ".next",
        ".cache"
    ]

    public static let defaultNodeLimit = 50_000

    private let batchSize: Int
    private let nodeLimit: Int

    public init(batchSize: Int = 512, nodeLimit: Int = FileTreeScanner.defaultNodeLimit) {
        self.batchSize = max(1, batchSize)
        self.nodeLimit = max(1, nodeLimit)
    }

    public func scan(
        root: URL,
        ignoreList: Set<String>,
        gitStatuses: [String: FileTreeGitStatus]? = nil,
        cancellation: Task<Void, Never>? = nil,
        onSnapshot: @Sendable (FileTreeSnapshot) -> Void
    ) async throws {
        let root = root.standardizedFileURL
        var queue: [URL] = [root]
        var queueIndex = 0
        var nodes: [FileTreeNode] = []
        nodes.reserveCapacity(min(nodeLimit, batchSize * 4))
        var processedSinceSnapshot = 0
        var isTruncated = false

        while queueIndex < queue.count {
            if processedSinceSnapshot >= batchSize {
                try checkCancellation(cancellation)
                onSnapshot(FileTreeSnapshot(root: root, nodes: nodes, isTruncated: false, nodeLimit: nodeLimit))
                processedSinceSnapshot = 0
            }

            let directory = queue[queueIndex]
            queueIndex += 1
            let children = try directoryChildren(at: directory)

            for child in children {
                if nodes.count >= nodeLimit {
                    isTruncated = true
                    queue.removeAll(keepingCapacity: false)
                    break
                }

                let values = try child.resourceValues(forKeys: FileTreeScanner.resourceKeys)
                let name = values.name ?? child.lastPathComponent
                let isIgnored = ignoreList.contains(name)
                let isSymbolicLink = values.isSymbolicLink == true
                let isDirectory = values.isDirectory == true
                let shouldDescend = isDirectory && !isSymbolicLink && !isIgnored
                let childCount = shouldDescend ? try childVisibleCount(at: child, ignoreList: ignoreList) : 0

                let relativePath = relativePath(for: child, root: root)
                nodes.append(
                    FileTreeNode(
                        relativePath: relativePath,
                        displayName: name,
                        isDirectory: isDirectory,
                        childCount: childCount,
                        isIgnored: isIgnored,
                        gitStatus: gitStatuses?[relativePath]
                    )
                )

                if shouldDescend {
                    queue.append(child)
                }

                processedSinceSnapshot += 1
            }
        }

        try checkCancellation(cancellation)
        onSnapshot(FileTreeSnapshot(root: root, nodes: nodes, isTruncated: isTruncated, nodeLimit: nodeLimit))
    }

    private func directoryChildren(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(FileTreeScanner.resourceKeys),
            options: [.skipsPackageDescendants]
        )
        .sorted { $0.path < $1.path }
    }

    private func childVisibleCount(at url: URL, ignoreList: Set<String>) throws -> Int {
        let children = try directoryChildren(at: url)
        return children.reduce(0) { count, child in
            let name = child.lastPathComponent
            return ignoreList.contains(name) ? count : count + 1
        }
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            return url.lastPathComponent
        }

        let start = path.index(path.startIndex, offsetBy: rootPath.count)
        let relative = path[start...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    private func checkCancellation(_ cancellation: Task<Void, Never>?) throws {
        if cancellation?.isCancelled == true {
            throw CancellationError()
        }

        try Task.checkCancellation()
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .nameKey,
        .isSymbolicLinkKey
    ]
}
