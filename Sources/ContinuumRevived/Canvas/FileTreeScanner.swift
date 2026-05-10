import ContinuumRevivedCore
import Foundation

public struct FileTreeSnapshot: Equatable, Sendable {
    public var root: URL
    public var nodes: [FileTreeNode]

    public init(root: URL, nodes: [FileTreeNode]) {
        self.root = root
        self.nodes = nodes
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

    private let batchSize: Int

    public init(batchSize: Int = 32) {
        self.batchSize = batchSize
    }

    public func scan(
        root: URL,
        ignoreList: Set<String>,
        cancellation: Task<Void, Never>? = nil,
        onSnapshot: @Sendable (FileTreeSnapshot) -> Void
    ) async throws {
        let root = root.standardizedFileURL
        var queue: [URL] = [root]
        var nodes: [FileTreeNode] = []
        var processedSinceSnapshot = 0

        while !queue.isEmpty {
            if processedSinceSnapshot >= batchSize {
                try checkCancellation(cancellation)
                onSnapshot(FileTreeSnapshot(root: root, nodes: nodes))
                processedSinceSnapshot = 0
            }

            let directory = queue.removeFirst()
            let children = try directoryChildren(at: directory)

            for child in children {
                let values = try child.resourceValues(forKeys: FileTreeScanner.resourceKeys)
                let name = values.name ?? child.lastPathComponent
                let isIgnored = ignoreList.contains(name)
                let isSymbolicLink = values.isSymbolicLink == true
                let isDirectory = values.isDirectory == true
                let shouldDescend = isDirectory && !isSymbolicLink && !isIgnored
                let childCount = shouldDescend ? try childVisibleCount(at: child, ignoreList: ignoreList) : 0

                nodes.append(
                    FileTreeNode(
                        relativePath: relativePath(for: child, root: root),
                        displayName: name,
                        isDirectory: isDirectory,
                        childCount: childCount,
                        isIgnored: isIgnored,
                        gitStatus: nil
                    )
                )

                if shouldDescend {
                    queue.append(child)
                }

                processedSinceSnapshot += 1
            }
        }

        try checkCancellation(cancellation)
        onSnapshot(FileTreeSnapshot(root: root, nodes: nodes))
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
