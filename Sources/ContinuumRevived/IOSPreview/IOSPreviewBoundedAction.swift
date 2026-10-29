import Foundation

/// Native-only vocabulary. Workspace exposure remains tap-only until the new
/// kinds have production API and live guest witnesses.
enum IOSPreviewBoundedAction: Equatable, Sendable {
    case tap(x: Double, y: Double)
    case swipe(x: Double, y: Double, endX: Double, endY: Double, milliseconds: Int)
    case text(String)
    case key(String)
    case home
    case rotate(Int)

    static let keys: Set<String> = ["return", "tab", "backspace", "escape", "left", "right", "up", "down"]
    var payload: [String: Any]? {
        func valid(_ values: Double...) -> Bool { values.allSatisfy { $0.isFinite && (0...1).contains($0) } }
        switch self {
        case let .tap(x, y):
            guard valid(x, y) else { return nil }
            return ["kind": "tap", "x": x, "y": y]
        case let .swipe(x, y, endX, endY, milliseconds):
            guard valid(x, y, endX, endY), (100...1500).contains(milliseconds) else { return nil }
            return ["kind": "swipe", "x": x, "y": y, "endX": endX, "endY": endY, "milliseconds": milliseconds]
        case let .text(text):
            guard !text.isEmpty, text.utf8.count <= 16_384 else { return nil }
            return ["kind": "text", "text": text]
        case let .key(name):
            guard Self.keys.contains(name) else { return nil }
            return ["kind": "key", "key": name]
        case .home: return ["kind": "home"]
        case let .rotate(orientation):
            guard (1...4).contains(orientation) else { return nil }
            return ["kind": "rotate", "orientation": orientation]
        }
    }
}
