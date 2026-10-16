import Foundation

/// One searchable, navigable thing in Settings: a pane, a field row, an action
/// row, or a row inside bespoke content. `SettingsRegistry` derives every entry
/// from `SettingsSchema`, and the renderer draws from the same registry, so a row
/// cannot exist without an entry or an entry without a row (the drift guard in
/// `--settings-search-check` holds both directions).
public struct SettingsEntry: Equatable, Sendable, Identifiable {
    public enum Reveal: Equatable, Sendable {
        /// Navigate to the pane only.
        case pane
        /// Navigate to the pane and scroll to the row carrying this anchor.
        case anchor(String)
    }

    public let id: String
    public let paneID: String
    public let paneTitle: String
    public let groupID: String?
    public let groupTitle: String?
    public let label: String
    public let keywords: [String]
    public let optionTitles: [String]
    public let reveal: Reveal
    /// The field this entry renders, when it is a field row.
    public let field: SettingsField?

    public var anchor: String? {
        if case let .anchor(anchor) = reveal { return anchor }
        return nil
    }
}

public enum SettingsRegistry {
    /// The anchor a field row carries: its defaults key, or its action/custom id.
    public static func anchor(for field: SettingsField) -> String? {
        switch field {
        case .info: return nil
        case let .action(id, _, _): return "action.\(id)"
        case let .custom(id, _): return "custom.\(id)"
        case .shortcuts: return "shortcuts"
        case .agentSounds: return "sounds"
        default: return field.key.map { "field.\($0)" }
        }
    }

    /// Every entry, in sidebar-then-schema order. `defaults` decides conditional
    /// rows (a slider that only exists for one choice); `paneIDs` limits the set to
    /// the panes actually shown (the iPhone pane is conditional).
    public static func entries(
        sections: [SettingsSection] = SettingsSchema.sections(),
        defaults: UserDefaults,
        paneIDs: Set<String>? = nil
    ) -> [SettingsEntry] {
        var result: [SettingsEntry] = []
        for section in sections where paneIDs?.contains(section.id) ?? true {
            result.append(SettingsEntry(
                id: "pane.\(section.id)", paneID: section.id, paneTitle: section.title,
                groupID: nil, groupTitle: nil, label: section.title, keywords: section.keywords,
                optionTitles: [], reveal: .pane, field: nil))
            for group in section.groups {
                for row in group.rows where row.field.isVisible(in: defaults) {
                    let field = row.field
                    let custom = SettingsSchema.customEntries(for: field)
                    if !custom.isEmpty {
                        for (index, entry) in custom.enumerated() {
                            result.append(SettingsEntry(
                                id: "\(entry.anchor)#\(index)", paneID: section.id, paneTitle: section.title,
                                groupID: group.id, groupTitle: group.title, label: entry.label,
                                keywords: entry.keywords + row.keywords, optionTitles: [],
                                reveal: .anchor(entry.anchor), field: nil))
                        }
                        continue
                    }
                    guard let anchor = anchor(for: field) else { continue }
                    var options: [String] = []
                    if case let .choice(key, _, values, _, _) = field, key != AgentModelConfig.modelKey {
                        options = values.map(field.displayTitle(forOption:))
                    }
                    result.append(SettingsEntry(
                        id: anchor, paneID: section.id, paneTitle: section.title,
                        groupID: group.id, groupTitle: group.title, label: field.label,
                        keywords: row.keywords, optionTitles: options,
                        reveal: .anchor(anchor), field: field))
                }
            }
        }
        return result
    }
}

/// Word-prefix search over the registry. A query token matches a word when the
/// word STARTS with it — never a raw defaults key, never mid-word — so "on" finds
/// "On" and "Only" but not "Notifications". Every token must match. Ranking: a
/// label match beats a keyword or option match, which beats a pane-title match.
public enum SettingsSearch {
    /// Words a person types that the schema spells differently.
    public static let synonyms: [String: [String]] = [
        "theme": ["appearance"],
        "dark": ["appearance"],
        "light": ["appearance"],
        "bell": ["sound"],
        "chime": ["sound"],
        "volume": ["sound"],
        "wallpaper": ["background"],
        "hotkey": ["shortcut"],
        "keybinding": ["shortcut"],
        "phone": ["iphone"],
    ]

    public struct Result: Equatable, Sendable {
        public let entry: SettingsEntry
        public let score: Int
    }

    public struct PaneResults: Equatable, Sendable {
        public let paneID: String
        public let paneTitle: String
        public let results: [Result]
    }

    /// Lowercased word tokens: letters and digits, split on everything else.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    public static func search(_ query: String, in entries: [SettingsEntry]) -> [Result] {
        let tokens = words(query)
        guard !tokens.isEmpty else { return [] }
        var scored: [(Int, Int, Result)] = []
        for (order, entry) in entries.enumerated() {
            let label = words(entry.label)
            let group = words(entry.groupTitle ?? "")
            let keywords = entry.keywords.flatMap(words)
            let options = entry.optionTitles.flatMap(words)
            let pane = words(entry.paneTitle)
            let isPane = entry.reveal == .pane
            var total = 0
            var matchedOwnWords = false
            var allMatched = true
            for token in tokens {
                let alternates = [token] + (synonyms[token] ?? [])
                func hits(_ list: [String]) -> Bool {
                    list.contains { word in alternates.contains { word.hasPrefix($0) } }
                }
                func direct(_ list: [String]) -> Bool { list.contains { $0.hasPrefix(token) } }
                var best = 0
                if hits(label) {
                    best = max(best, (direct(label) ? 100 : 80) + (label.first.map { $0.hasPrefix(token) } == true ? 20 : 0))
                    if !isPane { matchedOwnWords = true }
                }
                if !isPane, hits(group) { best = max(best, direct(group) ? 60 : 48); matchedOwnWords = true }
                if hits(keywords) { best = max(best, direct(keywords) ? 50 : 40); if !isPane { matchedOwnWords = true } }
                if !isPane, hits(options) { best = max(best, direct(options) ? 45 : 36); matchedOwnWords = true }
                if !isPane, hits(pane) { best = max(best, 10) }
                guard best > 0 else { allMatched = false; break }
                total += best
            }
            // A row never matches on its pane's title alone: that would return every
            // row in the pane; the pane entry itself answers that query.
            guard allMatched, isPane || matchedOwnWords else { continue }
            scored.append((total, order, Result(entry: entry, score: total)))
        }
        return scored
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }

    /// Results grouped by pane, panes ordered by their best result.
    public static func grouped(_ results: [Result]) -> [PaneResults] {
        var order: [String] = []
        var buckets: [String: [Result]] = [:]
        var titles: [String: String] = [:]
        for result in results {
            if buckets[result.entry.paneID] == nil { order.append(result.entry.paneID) }
            buckets[result.entry.paneID, default: []].append(result)
            titles[result.entry.paneID] = result.entry.paneTitle
        }
        return order.map { PaneResults(paneID: $0, paneTitle: titles[$0] ?? $0, results: buckets[$0] ?? []) }
    }
}
