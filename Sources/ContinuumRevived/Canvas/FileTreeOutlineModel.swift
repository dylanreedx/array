import ContinuumRevivedCore
import Foundation

public struct FileTreeOutlineItem: Hashable, Sendable {
    public var node: FileTreeNode
    public var depth: Int

    public init(node: FileTreeNode, depth: Int) {
        self.node = node
        self.depth = depth
    }
}

public struct FileTreeOutlineModel: Hashable, Sendable {
    public private(set) var rootItems: [FileTreeOutlineItem]
    private var childrenByPath: [String: [FileTreeOutlineItem]]

    public init(snapshot: FileTreeSnapshot, query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleNodes = trimmedQuery.isEmpty
            ? snapshot.nodes
            : Self.filteredNodes(snapshot.nodes, query: trimmedQuery)

        var roots: [FileTreeOutlineItem] = []
        var children: [String: [FileTreeOutlineItem]] = [:]

        for node in visibleNodes {
            let parent = Self.parentPath(for: node.relativePath)
            let item = FileTreeOutlineItem(node: node, depth: Self.depth(for: node.relativePath))
            if let parent {
                children[parent, default: []].append(item)
            } else {
                roots.append(item)
            }
        }

        self.rootItems = roots
        self.childrenByPath = children
    }

    public func children(of item: FileTreeOutlineItem?) -> [FileTreeOutlineItem] {
        guard let item else {
            return rootItems
        }
        return childrenByPath[item.node.relativePath] ?? []
    }

    public func isExpandable(_ item: FileTreeOutlineItem) -> Bool {
        item.node.isDirectory && !children(of: item).isEmpty
    }

    public static func absolutePath(for relativePath: String, root: URL) -> String {
        root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL.path
    }

    private static func filteredNodes(_ nodes: [FileTreeNode], query: String) -> [FileTreeNode] {
        let lowerQuery = query.lowercased()
        let nodeByPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.relativePath, $0) })
        var included = Set<String>()

        for node in nodes where node.displayName.lowercased().contains(lowerQuery)
            || node.relativePath.lowercased().contains(lowerQuery) {
            included.insert(node.relativePath)
            var parent = parentPath(for: node.relativePath)
            while let path = parent {
                if nodeByPath[path] != nil {
                    included.insert(path)
                }
                parent = parentPath(for: path)
            }
        }

        return nodes.filter { included.contains($0.relativePath) }
    }

    private static func parentPath(for relativePath: String) -> String? {
        guard let slash = relativePath.lastIndex(of: "/") else {
            return nil
        }
        return String(relativePath[..<slash])
    }

    private static func depth(for relativePath: String) -> Int {
        relativePath.reduce(0) { count, character in
            character == "/" ? count + 1 : count
        }
    }
}
