import Foundation

public struct BrowserComputedStyleProperty: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct BrowserComputedStyleRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct BrowserComputedStyleSnapshot: Codable, Equatable, Sendable {
    public var nodeId: String
    public var boundingRect: BrowserComputedStyleRect
    public var properties: [BrowserComputedStyleProperty]

    public init(nodeId: String, boundingRect: BrowserComputedStyleRect, properties: [BrowserComputedStyleProperty]) {
        self.nodeId = nodeId
        self.boundingRect = boundingRect
        self.properties = properties
    }

    public func value(for propertyName: String) -> String? {
        properties.first { $0.name == propertyName }?.value
    }
}
