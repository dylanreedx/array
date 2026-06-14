import Foundation

/// Per-kind map from chord to tile-local action. Defaults live in code and are
/// overridable through `continuum.tileKeymap.*` UserDefaults, mirroring
/// `NavKeymap.resolve`: invalid entries warn and fall back; partial maps merge.
public enum TileActionCatalog {
    public static func actions(
        for kind: TileKind,
        defaults: UserDefaults = .standard,
        warn: (String) -> Void = { fputs($0 + "\n", stderr) }
    ) -> [TileChord: TileAction] {
        var map = defaultActions(for: kind)
        let prefix = "continuum.tileKeymap."
        for (name, action) in map.overridableEntries() {
            guard let raw = defaults.string(forKey: prefix + name)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
            else { continue }
            guard let chord = parseChord(raw) else {
                warn("Invalid \(prefix)\(name) '\(raw)'; using default")
                continue
            }
            map.replaceChord(for: action, with: chord)
        }
        return map.entries
    }

    // MARK: Defaults

    static func defaultActions(for kind: TileKind) -> CatalogMap {
        var map = CatalogMap()
        // Universal sizing.
        map["sizeCompact"] = (TileChord(keyCode: 18, modifiers: [.command, .control]), .resizeToPreset(.compact))
        map["sizeDefault"] = (TileChord(keyCode: 19, modifiers: [.command, .control]), .resizeToPreset(.default))
        map["sizeLarge"] = (TileChord(keyCode: 20, modifiers: [.command, .control]), .resizeToPreset(.large))
        map["sizeFill"] = (TileChord(keyCode: 29, modifiers: [.command, .control]), .resizeToPreset(.fillViewport))
        // Universal positioning. Arrow keyCodes: 123 left, 124 right, 125 down, 126 up.
        map["nudgeLeft"] = (TileChord(keyCode: 123, modifiers: [.control, .option]), .nudge(.left))
        map["nudgeRight"] = (TileChord(keyCode: 124, modifiers: [.control, .option]), .nudge(.right))
        map["nudgeDown"] = (TileChord(keyCode: 125, modifiers: [.control, .option]), .nudge(.down))
        map["nudgeUp"] = (TileChord(keyCode: 126, modifiers: [.control, .option]), .nudge(.up))
        map["throwLeft"] = (TileChord(keyCode: 123, modifiers: [.control, .option, .command]), .throwToNeighbor(.left))
        map["throwRight"] = (TileChord(keyCode: 124, modifiers: [.control, .option, .command]), .throwToNeighbor(.right))
        map["throwDown"] = (TileChord(keyCode: 125, modifiers: [.control, .option, .command]), .throwToNeighbor(.down))
        map["throwUp"] = (TileChord(keyCode: 126, modifiers: [.control, .option, .command]), .throwToNeighbor(.up))

        switch kind {
        case .browser:
            map["browserFind"] = (TileChord(keyCode: 3, modifiers: .command), .browserFind)
            map["browserFocusURL"] = (TileChord(keyCode: 37, modifiers: .command), .browserFocusURL)
            map["browserReload"] = (TileChord(keyCode: 15, modifiers: .command), .browserReload)
            map["browserBack"] = (TileChord(keyCode: 33, modifiers: .command), .browserBack)
            map["browserForward"] = (TileChord(keyCode: 30, modifiers: .command), .browserForward)
        case .note:
            map["noteExport"] = (TileChord(keyCode: 14, modifiers: .command), .noteExport)
        case .terminal, .file, .fileTree, .ticketQueue, .conductorQueue, .diffReview, .runArtifacts:
            break
        }
        return map
    }

    // MARK: Chord parsing

    /// Parses a chord string like "cmd+ctrl+1" or "ctrl+opt+left".
    static func parseChord(_ value: String) -> TileChord? {
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
        guard let keyCode = keyCode(forName: key) else { return nil }
        return TileChord(keyCode: keyCode, modifiers: modifiers)
    }

    private static func keyCode(forName name: String) -> UInt16? {
        switch name {
        case "f": return 3
        case "e": return 14
        case "r": return 15
        case "l": return 37
        case "]", "rightbracket": return 30
        case "[", "leftbracket": return 33
        case ",", "comma": return 43
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "0": return 29
        case "left", "arrowleft": return 123
        case "right", "arrowright": return 124
        case "down", "arrowdown": return 125
        case "up", "arrowup": return 126
        default: return nil
        }
    }

    /// Ordered chord→action map keyed by stable override names so overrides can
    /// rebind a known action without losing per-kind ordering.
    struct CatalogMap {
        private var order: [String] = []
        private var byName: [String: (chord: TileChord, action: TileAction)] = [:]

        subscript(name: String) -> (chord: TileChord, action: TileAction)? {
            get { byName[name] }
            set {
                if let newValue {
                    if byName[name] == nil { order.append(name) }
                    byName[name] = newValue
                } else {
                    byName[name] = nil
                    order.removeAll { $0 == name }
                }
            }
        }

        func overridableEntries() -> [(name: String, action: TileAction)] {
            order.map { ($0, byName[$0]!.action) }
        }

        mutating func replaceChord(for action: TileAction, with chord: TileChord) {
            guard let name = order.first(where: { byName[$0]?.action == action }) else { return }
            byName[name]?.chord = chord
        }

        var entries: [TileChord: TileAction] {
            var result: [TileChord: TileAction] = [:]
            for name in order {
                let pair = byName[name]!
                result[pair.chord] = pair.action
            }
            return result
        }
    }
}
