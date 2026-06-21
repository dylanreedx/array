import Foundation

public struct BrowserDOMNodeSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var tagName: String
    public var nodeName: String
    public var idAttribute: String?
    public var className: String?
    public var textPreview: String?
    public var childCount: Int
    public var depth: Int

    public init(
        id: String,
        tagName: String,
        nodeName: String,
        idAttribute: String?,
        className: String?,
        textPreview: String?,
        childCount: Int,
        depth: Int
    ) {
        self.id = id
        self.tagName = tagName
        self.nodeName = nodeName
        self.idAttribute = idAttribute
        self.className = className
        self.textPreview = textPreview
        self.childCount = childCount
        self.depth = depth
    }
}

public struct BrowserDOMSnapshot: Codable, Equatable, Sendable {
    public var nodes: [BrowserDOMNodeSnapshot]
    public var truncated: Bool
    public var maxNodes: Int
    public var maxDepth: Int

    public init(nodes: [BrowserDOMNodeSnapshot], truncated: Bool, maxNodes: Int = 800, maxDepth: Int = 32) {
        self.nodes = nodes
        self.truncated = truncated
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
    }
}
