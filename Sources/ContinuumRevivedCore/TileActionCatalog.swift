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
        // Keyboard tile positioning is intentionally unbound: the one-shot ⌘⌃-arrow
        // "throw" was removed (it felt unpredictable). Snapping is being rebuilt as
        // drag magnetization first, then an interactive leader snap — see docs/30.

        switch kind {
        case .browser:
            map["browserFind"] = (TileChord(keyCode: 3, modifiers: .command), .browserFind)
            map["browserFocusURL"] = (TileChord(keyCode: 37, modifiers: .command), .browserFocusURL)
            map["browserReload"] = (TileChord(keyCode: 15, modifiers: .command), .browserReload)
            map["browserBack"] = (TileChord(keyCode: 33, modifiers: .command), .browserBack)
            map["browserForward"] = (TileChord(keyCode: 30, modifiers: .command), .browserForward)
        case .note:
            map["noteExport"] = (TileChord(keyCode: 14, modifiers: .command), .noteExport)
        case .terminal, .browserInspector, .file, .fileTree, .ticketQueue, .conductorQueue, .diffReview, .runArtifacts:
            break
        }
        return map
    }

    // MARK: Override write path

    /// Inverse of the override read in `actions(for:defaults:)`: writes each
    /// `chord` to the `continuum.tileKeymap.<name>` key for its action, where
    /// `<name>` is the stable override name in `kind`'s default catalog. A
    /// `chord.serialized` round-trips back through `parseChord`, so
    /// `actions(for:kind:defaults:)` reflects the persisted override.
    public static func persist(
        _ overrides: [TileChord: TileAction],
        for kind: TileKind,
        to defaults: UserDefaults = .standard
    ) {
        let map = defaultActions(for: kind)
        let prefix = "continuum.tileKeymap."
        for (chord, action) in overrides {
            guard let name = map.name(for: action) else { continue }
            defaults.set(chord.serialized, forKey: prefix + name)
        }
    }

    /// The stable `continuum.tileKeymap.<name>` override name for `action` in
    /// `kind`'s default catalog, or `nil` if the action is not claimed by that
    /// kind. Used by the settings reset path to clear a single override key.
    public static func overrideName(for action: TileAction, kind: TileKind) -> String? {
        defaultActions(for: kind).name(for: action)
    }

    // MARK: Chord parsing

    /// Parses a chord string like "cmd+ctrl+1" or "ctrl+opt+left".
    static func parseChord(_ value: String) -> TileChord? {
        TileChord(parsing: value)
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
            guard let name = name(for: action) else { return }
            byName[name]?.chord = chord
        }

        func name(for action: TileAction) -> String? {
            order.first(where: { byName[$0]?.action == action })
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
