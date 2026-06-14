import Foundation

public struct KeyChord: Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: FocusKeyModifiers

    public init(keyCode: UInt16, modifiers: FocusKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Human-readable chord like "⌘⌃F" for hints and the settings catalog.
    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += KeyChord.keyName(for: keyCode)
        return result
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 3: return "F"
        case 14: return "E"
        case 15: return "R"
        case 37: return "L"
        case 30: return "]"
        case 33: return "["
        case 40: return "K"
        case 43: return ","
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 29: return "0"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 49: return "Space"
        default: return "key\(keyCode)"
        }
    }
}

public struct NavKeymap: Equatable, Sendable {
    public var leader: KeyChord
    public var up: String
    public var down: String
    public var left: String
    public var right: String
    public var nextZone: String
    public var previousZone: String
    public var zonePicker: String
    public var workspacePicker: String
    public var agentCycle: String
    public var agentNeedsAttention: String
    public var focusMode: String
    public var deleteTile: String

    public init(leader: KeyChord, up: String, down: String, left: String, right: String, nextZone: String, previousZone: String, zonePicker: String, workspacePicker: String, agentCycle: String, agentNeedsAttention: String, focusMode: String, deleteTile: String) {
        self.leader = leader
        self.up = up
        self.down = down
        self.left = left
        self.right = right
        self.nextZone = nextZone
        self.previousZone = previousZone
        self.zonePicker = zonePicker
        self.workspacePicker = workspacePicker
        self.agentCycle = agentCycle
        self.agentNeedsAttention = agentNeedsAttention
        self.focusMode = focusMode
        self.deleteTile = deleteTile
    }

    public static let `default` = NavKeymap(
        leader: KeyChord(keyCode: 49, modifiers: .control),
        up: "k", down: "j", left: "h", right: "l",
        nextZone: "n", previousZone: "p", zonePicker: "z", workspacePicker: "w",
        agentCycle: "a", agentNeedsAttention: "A", focusMode: "f", deleteTile: "x"
    )

    public var hintLine: String {
        "\(left)\(down)\(up)\(right) move · \(agentCycle) agents · \(agentNeedsAttention) needs you · 1-9 zone · 0 fit all · \(zonePicker)/\(workspacePicker) pick · ⏎ focus · esc exit"
    }

    public func direction(for key: String) -> TileArrangement.Direction? {
        let normalized = key.normalizedNavKey
        if normalized == up.normalizedNavKey || normalized == "arrowup" || normalized == "up" { return .up }
        if normalized == down.normalizedNavKey || normalized == "arrowdown" || normalized == "down" { return .down }
        if normalized == left.normalizedNavKey || normalized == "arrowleft" || normalized == "left" { return .left }
        if normalized == right.normalizedNavKey || normalized == "arrowright" || normalized == "right" { return .right }
        return nil
    }

    public func keyMatches(_ input: String, _ binding: String) -> Bool {
        if binding.contains(where: { $0.isUppercase }) { return input == binding }
        return input.normalizedNavKey == binding.normalizedNavKey
    }

    public static func resolve(defaults: UserDefaults = .standard, warn: (String) -> Void = { fputs($0 + "\n", stderr) }) -> NavKeymap {
        var map = NavKeymap.default
        let prefix = "continuum.keymap."
        func string(_ name: String) -> String? {
            defaults.string(forKey: prefix + name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let leader = string("leader") {
            if let chord = parseLeaderChord(leader) { map.leader = chord } else { warn("Invalid continuum.keymap.leader '\(leader)'; using default control+space") }
        }
        func apply(_ name: String, _ set: (String) -> Void) {
            guard let value = string(name) else { return }
            guard value.count == 1 else { warn("Invalid continuum.keymap.\(name) '\(value)'; using default"); return }
            set(value)
        }
        apply("up") { map.up = $0 }; apply("down") { map.down = $0 }; apply("left") { map.left = $0 }; apply("right") { map.right = $0 }
        apply("nextZone") { map.nextZone = $0 }; apply("previousZone") { map.previousZone = $0 }
        apply("zonePicker") { map.zonePicker = $0 }; apply("workspacePicker") { map.workspacePicker = $0 }
        apply("agentCycle") { map.agentCycle = $0 }; apply("agentNeedsAttention") { map.agentNeedsAttention = $0 }
        apply("focusMode") { map.focusMode = $0 }; apply("deleteTile") { map.deleteTile = $0 }
        return map
    }

    public static func parseLeaderChord(_ value: String) -> KeyChord? {
        let parts = value.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last else { return nil }
        var modifiers: FocusKeyModifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            default: return nil
            }
        }
        let keyCode: UInt16?
        switch key {
        case "space": keyCode = 49
        case "g": keyCode = 5
        default: keyCode = nil
        }
        guard let keyCode else { return nil }
        return KeyChord(keyCode: keyCode, modifiers: modifiers)
    }
}

private extension String {
    var normalizedNavKey: String { trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
