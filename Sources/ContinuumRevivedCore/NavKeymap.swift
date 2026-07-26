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
        case 21: return "4"
        // 5…9 (P3.10's ⌘5–⌘9 inbox jumps). Without these the catalog rendered
        // "⌘key23" for a binding the user is being told to press.
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 49: return "Space"
        default: return "key\(keyCode)"
        }
    }

    // MARK: Chord <-> string serialization

    /// Parses a chord string like "cmd+ctrl+f", "ctrl+opt+left", or "space".
    /// Single shared parser for the leader, tile keymap overrides, and the
    /// settings editor write path. Accepts letters, digits, arrows, brackets,
    /// comma, and space, with the same modifier tokens `resolve` already reads.
    public init?(parsing value: String) {
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
        guard let keyCode = KeyChord.keyCode(forSerializedName: key) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    /// Round-trips with `init(parsing:)`: emits the modifier tokens then the
    /// canonical key name in the lowercase "cmd+ctrl+f" form `resolve` reads.
    public var serialized: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(KeyChord.serializedName(for: keyCode))
        return parts.joined(separator: "+")
    }

    /// Canonical, parseable name for a key code. Inverse of `keyCode(forSerializedName:)`.
    static func serializedName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 3: return "f"
        case 14: return "e"
        case 15: return "r"
        case 37: return "l"
        case 30: return "]"
        case 33: return "["
        case 40: return "k"
        case 43: return ","
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 49: return "space"
        case 5: return "g"
        default: return "key\(keyCode)"
        }
    }

    static func keyCode(forSerializedName name: String) -> UInt16? {
        switch name {
        case "f": return 3
        case "e": return 14
        case "r": return 15
        case "l": return 37
        case "]", "rightbracket": return 30
        case "[", "leftbracket": return 33
        case ",", "comma": return 43
        case "k": return 40
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25
        case "0": return 29
        case "left", "arrowleft": return 123
        case "right", "arrowright": return 124
        case "down", "arrowdown": return 125
        case "up", "arrowup": return 126
        case "space": return 49
        case "g": return 5
        default: return nil
        }
    }
}

public struct NavKeymap: Equatable, Sendable {
    public var leader: KeyChord
    /// The modifier that, held alone past `leaderDwellMs`, enters the hold-`⌥`
    /// leader (jump/snap). Distinct from `leader` (the legacy `⌃Space` toggle):
    /// this is a held modifier, not a key-down chord. Default `.option`.
    public var leaderHoldModifier: FocusKeyModifiers
    /// Dwell in milliseconds before the held leader activates. Default 0 (instant):
    /// `⌥` held alone is inert, so there's nothing to gate. A positive value
    /// re-introduces the gate (so a quick `⌥`+key tap can slip through to content
    /// before the leader claims it) for anyone who types `⌥`/Alt combos a lot.
    public var leaderDwellMs: Int
    /// The label keys offered to visible tiles in the hold-leader jump HUD, in
    /// priority order. Home-row default (`asdfghjkl`); rebindable. Tiles beyond
    /// this many are unlabeled (single-char labels only).
    public var leaderLabelKeys: String
    /// The auto-ordinal keys offered to zones that have no configured `navKey`, in
    /// priority order. Default `"123456789"` (digits, disjoint from the tile-label
    /// alphabet `asdfghjkl`). Rebindable via UserDefaults.
    public var leaderZoneOrdinalKeys: String
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

    public init(leader: KeyChord, leaderHoldModifier: FocusKeyModifiers = .option, leaderDwellMs: Int = 0, leaderLabelKeys: String = "asdfghjkl", leaderZoneOrdinalKeys: String = "123456789", up: String, down: String, left: String, right: String, nextZone: String, previousZone: String, zonePicker: String, workspacePicker: String, agentCycle: String, agentNeedsAttention: String, focusMode: String, deleteTile: String) {
        self.leader = leader
        self.leaderHoldModifier = leaderHoldModifier
        self.leaderDwellMs = leaderDwellMs
        self.leaderLabelKeys = leaderLabelKeys
        self.leaderZoneOrdinalKeys = leaderZoneOrdinalKeys
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
        leaderHoldModifier: .option,
        leaderDwellMs: 0,
        leaderLabelKeys: "asdfghjkl",
        leaderZoneOrdinalKeys: "123456789",
        up: "k", down: "j", left: "h", right: "l",
        nextZone: "n", previousZone: "p", zonePicker: "z", workspacePicker: "w",
        agentCycle: "a", agentNeedsAttention: "A", focusMode: "f", deleteTile: "x"
    )

    /// Canonical UserDefaults keys for the hold-leader config (so Settings binds to
    /// the EXACT keys `resolve`/`persist` read).
    public static let leaderHoldDefaultsKey = "continuum.keymap.leaderHold"
    public static let leaderDwellDefaultsKey = "continuum.keymap.leaderDwellMs"
    public static let leaderLabelKeysDefaultsKey = "continuum.keymap.leaderLabelKeys"
    public static let leaderZoneOrdinalKeysDefaultsKey = "continuum.keymap.leaderZoneOrdinalKeys"
    public static let leaderHoldModifierOptions = ["opt", "ctrl", "cmd", "shift"]

    /// The label keys as an ordered array of single-character strings — the form
    /// `TileArrangement.jumpLabels` and the HUD consume.
    public var leaderLabelAlphabet: [String] {
        leaderLabelKeys.map(String.init)
    }

    /// The zone ordinal keys as an ordered array of single-character strings —
    /// consumed in order by `zoneJumpLabels` when a zone has no configured `navKey`.
    public var leaderZoneOrdinalAlphabet: [String] {
        leaderZoneOrdinalKeys.map(String.init)
    }

    /// Single-modifier token serialization for the hold-leader (`opt`/`ctrl`/`cmd`/`shift`).
    public static func modifierToken(_ modifier: FocusKeyModifiers) -> String {
        if modifier == .control { return "ctrl" }
        if modifier == .command { return "cmd" }
        if modifier == .shift { return "shift" }
        return "opt"
    }

    public static func parseModifierToken(_ value: String) -> FocusKeyModifiers? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "opt", "option", "alt": return .option
        case "ctrl", "control": return .control
        case "cmd", "command": return .command
        case "shift": return .shift
        default: return nil
        }
    }

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
        if let hold = string("leaderHold") {
            if let modifier = parseModifierToken(hold) { map.leaderHoldModifier = modifier } else { warn("Invalid continuum.keymap.leaderHold '\(hold)'; using default opt") }
        }
        if let dwell = string("leaderDwellMs") {
            if let value = Int(dwell), value >= 0 { map.leaderDwellMs = value } else { warn("Invalid continuum.keymap.leaderDwellMs '\(dwell)'; using default 0") }
        }
        if let labelKeys = string("leaderLabelKeys") {
            let cleaned = labelKeys.lowercased()
            if !cleaned.isEmpty, cleaned.allSatisfy({ $0.isLetter && $0.isASCII }), Set(cleaned).count == cleaned.count {
                map.leaderLabelKeys = cleaned
            } else {
                warn("Invalid continuum.keymap.leaderLabelKeys '\(labelKeys)'; using default \(NavKeymap.default.leaderLabelKeys)")
            }
        }
        if let ordinalKeys = string("leaderZoneOrdinalKeys") {
            let cleaned = ordinalKeys.lowercased()
            if !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), Set(cleaned).count == cleaned.count {
                map.leaderZoneOrdinalKeys = cleaned
            } else {
                warn("Invalid continuum.keymap.leaderZoneOrdinalKeys '\(ordinalKeys)'; using default \(NavKeymap.default.leaderZoneOrdinalKeys)")
            }
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
        KeyChord(parsing: value)
    }

    /// Exact inverse of `resolve`: writes every binding to the
    /// `continuum.keymap.*` keys `resolve` reads so that
    /// `resolve(defaults:)` after `persist(to:)` reconstructs an equal map.
    public func persist(to defaults: UserDefaults = .standard) {
        let prefix = "continuum.keymap."
        defaults.set(leader.serialized, forKey: prefix + "leader")
        defaults.set(NavKeymap.modifierToken(leaderHoldModifier), forKey: prefix + "leaderHold")
        defaults.set(String(leaderDwellMs), forKey: prefix + "leaderDwellMs")
        defaults.set(leaderLabelKeys, forKey: prefix + "leaderLabelKeys")
        defaults.set(leaderZoneOrdinalKeys, forKey: prefix + "leaderZoneOrdinalKeys")
        defaults.set(up, forKey: prefix + "up")
        defaults.set(down, forKey: prefix + "down")
        defaults.set(left, forKey: prefix + "left")
        defaults.set(right, forKey: prefix + "right")
        defaults.set(nextZone, forKey: prefix + "nextZone")
        defaults.set(previousZone, forKey: prefix + "previousZone")
        defaults.set(zonePicker, forKey: prefix + "zonePicker")
        defaults.set(workspacePicker, forKey: prefix + "workspacePicker")
        defaults.set(agentCycle, forKey: prefix + "agentCycle")
        defaults.set(agentNeedsAttention, forKey: prefix + "agentNeedsAttention")
        defaults.set(focusMode, forKey: prefix + "focusMode")
        defaults.set(deleteTile, forKey: prefix + "deleteTile")
    }
}

extension NavKeymap {
    /// Deterministic key→zone assignment for the leader zone-jump.
    ///
    /// - Parameters:
    ///   - zoneIds: The zone IDs in render order.
    ///   - configuredKeys: Each zone's explicit navKey in render order (nil or "" = auto).
    ///   - ordinalAlphabet: The auto-ordinal pool (e.g. ["1".."9"]), consumed in order.
    ///   - tileLabels: The tile-jump labels live this session (the conflict set).
    ///
    /// Precedence:
    ///   1. A zone's CONFIGURED navKey always wins for that zone, even if a tile also
    ///      carries that label this session — the tile loses the key, the zone owns it.
    ///   2. AUTO ordinals skip any key already taken by (a) a configured zone navKey or
    ///      (b) a live tile label, so an auto-assigned zone never shadows a tile jump.
    ///   3. A zone whose configured navKey is empty/blank is treated as auto.
    ///
    /// Returns assignments in input zone order; zones that get no key are omitted.
    public static func zoneJumpLabels(
        zoneIds: [UUID],
        configuredKeys: [String?],
        ordinalAlphabet: [String],
        tileLabels: Set<String>
    ) -> [(zoneId: UUID, key: String)] {
        // Collect all explicitly-configured keys (non-empty, lowercased) to build the
        // auto-skip set BEFORE iterating, so auto ordinals never collide with them.
        var takenKeys: Set<String> = tileLabels.map { $0.lowercased() }.reduce(into: Set()) { $0.insert($1) }
        for k in configuredKeys {
            if let k = k, !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                takenKeys.insert(k.lowercased())
            }
        }

        var result: [(zoneId: UUID, key: String)] = []
        // Build the ordered pool of auto-ordinals that are not already taken by a
        // configured zone navKey or a live tile label.
        let availableOrdinals: [String] = ordinalAlphabet.filter { !takenKeys.contains($0.lowercased()) }
        var ordinalIndex = 0

        for (zoneId, configuredKey) in zip(zoneIds, configuredKeys) {
            let trimmed = configuredKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                // Configured key — always assigned (rule 1).
                result.append((zoneId: zoneId, key: trimmed.lowercased()))
            } else {
                // Auto ordinal — take the next available one.
                if ordinalIndex < availableOrdinals.count {
                    result.append((zoneId: zoneId, key: availableOrdinals[ordinalIndex]))
                    ordinalIndex += 1
                }
                // else: pool exhausted — zone gets no label (omitted per spec).
            }
        }
        return result
    }
}

private extension String {
    var normalizedNavKey: String { trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
