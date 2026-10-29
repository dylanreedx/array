import Foundation

/// Browser calls always name their tile, except for open. This decoder is the
/// common validation boundary for all transports; the host still owns scope,
/// permissions, URL policy and execution.
public enum BrowserToolRequest: Equatable, Sendable {
    case open(url: String, key: String?)
    case navigate(tile: UUID, destination: BrowserNavigation, key: String?)
    case snapshot(tile: UUID, key: String?)
    case click(tile: UUID, target: BrowserClickTarget, key: String?)
    case type(tile: UUID, text: String, ref: String?, clear: Bool, submit: Bool, key: String?)
    case pressKey(tile: UUID, keyName: String, key: String?)
    case scroll(tile: UUID, ref: String?, dx: Double, dy: Double, key: String?)
    case waitFor(tile: UUID, condition: BrowserWaitCondition, timeout: Double, key: String?)
    case screenshot(tile: UUID, ref: String?, key: String?)
    case evaluate(tile: UUID, script: String, key: String?)
    case console(tile: UUID, level: String?, key: String?)

    public static func decode(operation: String, data: Data) throws -> BrowserToolRequest {
        func fail(_ message: String) -> BrowserRequestError { .invalid(message) }
        guard data.count <= 70_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw fail("Browser request must be a bounded JSON object.")
        }
        let input: Input
        do { input = try JSONDecoder().decode(Input.self, from: data) }
        catch { throw fail("Browser request contains an invalid field.") }
        func nonempty(_ value: String?, _ name: String, max: Int = 16_384) throws -> String {
            guard let value, !value.isEmpty, value.utf8.count <= max else { throw fail("Invalid or missing \(name).") }
            return value
        }
        let key = try input.idempotencyKey.map { try nonempty($0, "idempotencyKey", max: 128) }
        func tile() throws -> UUID {
            guard let id = input.tileId else { throw fail("tileId is required.") }
            return id
        }
        func ref() throws -> String? { try input.ref.map { try nonempty($0, "ref", max: 128) } }
        func fields(_ names: Set<String>) throws {
            guard Set(object.keys).isSubset(of: names.union(["idempotencyKey"])) else {
                throw fail("Unexpected browser request field.")
            }
        }
        switch operation {
        case "browser.open":
            try fields(["url"])
            return .open(url: try nonempty(input.url, "url", max: 8192), key: key)
        case "browser.navigate":
            try fields(["tileId", "url", "action"])
            let destination: BrowserNavigation
            if let url = input.url, input.action == nil { destination = .url(try nonempty(url, "url", max: 8192)) }
            else if input.url == nil {
                switch input.action { case "back": destination = .back; case "forward": destination = .forward
                case "reload": destination = .reload; default: throw fail("Specify one URL or navigation action.") }
            } else { throw fail("Specify one URL or navigation action.") }
            return .navigate(tile: try tile(), destination: destination, key: key)
        case "browser.snapshot":
            try fields(["tileId"]); return .snapshot(tile: try tile(), key: key)
        case "browser.click":
            try fields(["tileId", "ref", "x", "y"])
            let target: BrowserClickTarget
            if let element = try ref(), input.x == nil, input.y == nil { target = .ref(element) }
            else if input.ref == nil, let x = input.x, let y = input.y, x.isFinite, y.isFinite, x >= 0, y >= 0 { target = .point(x, y) }
            else { throw fail("Specify a ref or non-negative x and y, not both.") }
            return .click(tile: try tile(), target: target, key: key)
        case "browser.type":
            try fields(["tileId", "text", "ref", "clear", "submit"])
            guard let text = input.text, text.utf8.count <= 16_384 else { throw fail("Invalid or missing text.") }
            return .type(tile: try tile(), text: text, ref: try ref(), clear: input.clear ?? false, submit: input.submit ?? false, key: key)
        case "browser.press_key":
            try fields(["tileId", "keyName"])
            return .pressKey(tile: try tile(), keyName: try nonempty(input.keyName, "keyName", max: 128), key: key)
        case "browser.scroll":
            try fields(["tileId", "ref", "dx", "dy"])
            let dx = input.dx ?? 0, dy = input.dy ?? 0
            guard dx.isFinite, dy.isFinite, abs(dx) <= 100_000, abs(dy) <= 100_000 else { throw fail("Invalid scroll distance.") }
            return .scroll(tile: try tile(), ref: try ref(), dx: dx, dy: dy, key: key)
        case "browser.wait_for":
            try fields(["tileId", "condition", "value", "timeout"])
            let condition: BrowserWaitCondition
            switch input.condition {
            case "idle": guard input.value == nil else { throw fail("Idle does not take a value.") }; condition = .idle
            case "textAppears": condition = .textAppears(try nonempty(input.value, "value"))
            case "textGone": condition = .textGone(try nonempty(input.value, "value"))
            case "refAppears": condition = .refAppears(try nonempty(input.value, "value", max: 128))
            case "refGone": condition = .refGone(try nonempty(input.value, "value", max: 128))
            default: throw fail("Unknown wait condition.")
            }
            let timeout = input.timeout ?? 15
            guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw fail("Timeout must be between 0 and 30 seconds.") }
            return .waitFor(tile: try tile(), condition: condition, timeout: timeout, key: key)
        case "browser.take_screenshot":
            try fields(["tileId", "ref"]); return .screenshot(tile: try tile(), ref: try ref(), key: key)
        case "browser.evaluate":
            try fields(["tileId", "script"]); return .evaluate(tile: try tile(), script: try nonempty(input.script, "script", max: 65_536), key: key)
        case "browser.console":
            try fields(["tileId", "level"])
            if let level = input.level, !["log", "info", "warn", "error", "debug"].contains(level) { throw fail("Unknown console level.") }
            return .console(tile: try tile(), level: input.level, key: key)
        default: throw fail("Unknown browser operation.")
        }
    }
}

public enum BrowserNavigation: Equatable, Sendable { case url(String), back, forward, reload }
public enum BrowserClickTarget: Equatable, Sendable { case ref(String), point(Double, Double) }
public enum BrowserWaitCondition: Equatable, Sendable { case textAppears(String), textGone(String), refAppears(String), refGone(String), idle }
public enum BrowserRequestError: Error, Equatable, Sendable { case invalid(String) }

private struct Input: Decodable {
    var tileId: UUID?
    var idempotencyKey: String?
    var url: String?
    var action: String?
    var ref: String?
    var x: Double?
    var y: Double?
    var text: String?
    var clear: Bool?
    var submit: Bool?
    var keyName: String?
    var dx: Double?
    var dy: Double?
    var condition: String?
    var value: String?
    var timeout: Double?
    var script: String?
    var level: String?
}
