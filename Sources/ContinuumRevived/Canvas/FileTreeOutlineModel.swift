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
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let nodeByPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.relativePath, $0) })
        var included = Set<String>()

        for node in nodes where terms.allSatisfy({ fuzzyMatchScore(query: $0, candidate: node.relativePath) != nil }) {
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

    /// Scores a case-insensitive fuzzy subsequence. Contiguous characters and
    /// path/word boundaries win, so `ftom` finds `FileTreeOutlineModel.swift`
    /// while exact fragments still rank naturally. Nil means no match.
    public static func fuzzyMatchScore(query: String, candidate: String) -> Int? {
        let query = Array(query.lowercased())
        let candidate = Array(candidate.lowercased())
        guard !query.isEmpty else { return 0 }
        guard query.count <= candidate.count else { return nil }

        var queryIndex = 0
        var score = 0
        var previousMatch: Int?
        for (index, character) in candidate.enumerated() where queryIndex < query.count {
            guard character == query[queryIndex] else { continue }
            let isBoundary = index == 0 || "/_- .".contains(candidate[index - 1])
            if let previousMatch {
                score += index == previousMatch + 1 ? 12 : max(1, 6 - (index - previousMatch))
            } else {
                score += max(1, 8 - index / 3)
            }
            if isBoundary { score += 10 }
            previousMatch = index
            queryIndex += 1
        }
        guard queryIndex == query.count else { return nil }
        if candidate.count == query.count { score += 30 }
        return score
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
