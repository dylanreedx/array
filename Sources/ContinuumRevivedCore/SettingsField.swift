import Foundation

/// A typed, UserDefaults-bound preference descriptor. Adding a new preference to
/// the settings surface is a one-line `SettingsField` in `SettingsSchema` — the
/// generic renderer (docs/24 S4/S5) draws each field by its `kind`, so no UI
/// surgery is needed. Bound preference fields carry the EXACT UserDefaults key
/// of the existing resolver they drive (e.g. the zone-chrome toggle writes
/// `continuum.zoneChrome.enabled`, which `ZoneChromeFeature` already reads);
/// static `.info` rows are copy-only and intentionally have no key.
public enum SettingsField: Equatable, Sendable {
    /// A boolean preference (rendered as a switch).
    case toggle(key: String, label: String, default: Bool)
    /// A free-text preference (rendered as a text field).
    case text(key: String, label: String, default: String)
    /// A URL with inline validation. Invalid input remains visible and is not
    /// persisted until it becomes a URL with a scheme.
    case url(key: String, label: String, default: String)
    /// A directory selected through the native folder permission surface.
    case directory(key: String, label: String, default: String)
    /// A bounded numeric value with an explicit unit and stepper.
    case number(key: String, label: String, range: ClosedRange<Double>, default: Double, unit: String, step: Double)
    /// A fixed-options preference (rendered as a menu). `setValue` rejects any
    /// value not in `options`, falling back to `default`. `titles` maps a stored
    /// option to the words a person reads; the stored value never changes, and an
    /// option without a title is shown as itself (only correct when the stored
    /// value is already plain words, e.g. "Claude Code").
    case choice(key: String, label: String, options: [String], default: String, titles: [String: String] = [:])
    /// A bounded numeric preference rendered as a slider with its value shown in
    /// `format`. An optional condition keeps advanced controls out of the pane
    /// until their owning choice is selected.
    case slider(key: String, label: String, range: ClosedRange<Double>, default: Double, visibleWhen: SettingsVisibility? = nil, format: SettingsValueFormat = .percent)
    /// Static explanatory copy rendered in a settings section without binding a
    /// UserDefaults key.
    case info(label: String)
    /// The keybindings editor/guide, which renders `ShortcutCatalog` rather than
    /// binding a single key.
    case shortcuts(label: String)
    /// Rich agent-sound rule editor and import library. It owns several stable
    /// AgentSoundConfig keys rather than pretending to be one scalar setting.
    case agentSounds(label: String)
    /// A button that performs an app action (`id` names it); binds no key.
    case action(id: String, label: String, buttonTitle: String)
    /// Bespoke content the app supplies by `id` (a status list, an embedded
    /// editor). Binds no single key; its searchable rows are declared in
    /// `SettingsSchema.customEntries(for:)`.
    case custom(id: String, label: String)

    /// The UserDefaults key this field reads/writes, or `nil` for static fields.
    public var key: String? {
        switch self {
        case .toggle(let key, _, _): return key
        case .text(let key, _, _): return key
        case .url(let key, _, _): return key
        case .directory(let key, _, _): return key
        case .number(let key, _, _, _, _, _): return key
        case .choice(let key, _, _, _, _): return key
        case .slider(let key, _, _, _, _, _): return key
        case .info: return nil
        case .shortcuts: return nil
        case .agentSounds: return nil
        case .action, .custom: return nil
        }
    }

    /// The human-readable label for this field.
    public var label: String {
        switch self {
        case .toggle(_, let label, _): return label
        case .text(_, let label, _): return label
        case .url(_, let label, _): return label
        case .directory(_, let label, _): return label
        case .number(_, let label, _, _, _, _): return label
        case .choice(_, let label, _, _, _): return label
        case .slider(_, let label, _, _, _, _): return label
        case .info(let label): return label
        case .shortcuts(let label): return label
        case .agentSounds(let label): return label
        case .action(_, let label, _): return label
        case .custom(_, let label): return label
        }
    }

    /// The words shown for a stored choice value: its title, or the value itself.
    public func displayTitle(forOption option: String) -> String {
        guard case .choice(_, _, _, _, let titles) = self else { return option }
        return titles[option] ?? option
    }

    /// The current value (typed) for this field, or its declared default when the
    /// key is absent. `nil` for static fields.
    public func currentValue(in defaults: UserDefaults) -> SettingsValue? {
        switch self {
        case .toggle(let key, _, let fallback):
            guard defaults.object(forKey: key) != nil else { return .bool(fallback) }
            return .bool(defaults.bool(forKey: key))
        case .text(let key, _, let fallback):
            return .string(defaults.string(forKey: key) ?? fallback)
        case .url(let key, _, let fallback), .directory(let key, _, let fallback):
            return .string(defaults.string(forKey: key) ?? fallback)
        case .number(let key, _, let range, let fallback, _, _):
            let raw = defaults.object(forKey: key)
            let decoded = (raw as? NSNumber)?.doubleValue
                ?? (raw as? String).flatMap(Double.init)
                ?? fallback
            return .double(min(range.upperBound, max(range.lowerBound, decoded)))
        case .choice(let key, _, let options, let fallback, _):
            let raw = defaults.string(forKey: key)
            if let raw, options.contains(raw) { return .string(raw) }
            return .string(fallback)
        case .slider(let key, _, let range, let fallback, _, _):
            let raw = defaults.object(forKey: key)
            let decoded = (raw as? NSNumber)?.doubleValue
                ?? (raw as? String).flatMap(Double.init)
                ?? fallback
            return .double(min(range.upperBound, max(range.lowerBound, decoded)))
        case .info:
            return nil
        case .shortcuts:
            return nil
        case .agentSounds, .action, .custom:
            return nil
        }
    }

    /// Persists `value` to UserDefaults. A `.choice` value outside `options`, or a
    /// value whose type does not match the field, falls back to the declared
    /// default. No-op for static fields.
    public func setValue(_ value: SettingsValue, in defaults: UserDefaults) {
        switch self {
        case .toggle(let key, _, let fallback):
            guard case .bool(let flag) = value else { defaults.set(fallback, forKey: key); return }
            defaults.set(flag, forKey: key)
        case .text(let key, _, let fallback):
            guard case .string(let text) = value else { defaults.set(fallback, forKey: key); return }
            defaults.set(text, forKey: key)
        case .url(let key, _, let fallback):
            guard case .string(let text) = value else { defaults.set(fallback, forKey: key); return }
            guard let url = URL(string: text), url.scheme != nil else { return }
            defaults.set(text, forKey: key)
        case .directory(let key, _, let fallback):
            guard case .string(let text) = value else { defaults.set(fallback, forKey: key); return }
            defaults.set(text, forKey: key)
        case .number(let key, _, let range, let fallback, _, _):
            guard case .double(let raw) = value else { defaults.set(fallback, forKey: key); return }
            defaults.set(min(range.upperBound, max(range.lowerBound, raw)), forKey: key)
        case .choice(let key, _, let options, let fallback, _):
            guard case .string(let raw) = value, options.contains(raw) else {
                defaults.set(fallback, forKey: key)
                return
            }
            defaults.set(raw, forKey: key)
        case .slider(let key, _, let range, let fallback, _, _):
            guard case .double(let raw) = value else { defaults.set(fallback, forKey: key); return }
            defaults.set(min(range.upperBound, max(range.lowerBound, raw)), forKey: key)
        case .info, .shortcuts, .agentSounds, .action, .custom:
            break
        }
    }

    public func isVisible(in defaults: UserDefaults) -> Bool {
        guard case .slider(_, _, _, _, let condition, _) = self, let condition else { return true }
        return defaults.string(forKey: condition.key) == condition.equals
    }

    public var defaultValue: SettingsValue? {
        switch self {
        case .toggle(_, _, let value): return .bool(value)
        case .text(_, _, let value), .url(_, _, let value), .directory(_, _, let value): return .string(value)
        case .number(_, _, _, let value, _, _), .slider(_, _, _, let value, _, _): return .double(value)
        case .choice(_, _, _, let value, _): return .string(value)
        case .info, .shortcuts, .agentSounds, .action, .custom: return nil
        }
    }

    public func reset(in defaults: UserDefaults) {
        guard let key else { return }
        defaults.removeObject(forKey: key)
    }
}

/// A typed value carried by a `SettingsField` (toggle → bool, text/choice →
/// string, slider → double).
public enum SettingsValue: Equatable, Sendable {
    case bool(Bool)
    case string(String)
    case double(Double)
}

public struct SettingsVisibility: Equatable, Sendable {
    public let key: String
    public let equals: String

    public init(key: String, equals: String) {
        self.key = key
        self.equals = equals
    }
}

/// How a slider shows its value beside the track.
public enum SettingsValueFormat: Equatable, Sendable {
    /// 0...1 shown as a whole percentage ("70%").
    case percent
    /// The value with `decimals` places and a unit ("12 pt").
    case number(decimals: Int, unit: String)

    public func string(for value: Double) -> String {
        switch self {
        case .percent:
            return "\(Int((value * 100).rounded()))%"
        case let .number(decimals, unit):
            let number = String(format: "%.\(max(0, decimals))f", value)
            return unit.isEmpty ? number : "\(number) \(unit)"
        }
    }
}

/// One rendered row: a field plus the words around it. `help` is the secondary
/// line under the label; `keywords` are extra search words; `zeroTitle` is what a
/// number row shows instead of 0 when 0 means "use the default".
public struct SettingsRow: Equatable, Sendable {
    public let field: SettingsField
    public let help: String?
    public let keywords: [String]
    public let zeroTitle: String?

    public init(_ field: SettingsField, help: String? = nil, keywords: [String] = [], zeroTitle: String? = nil) {
        self.field = field
        self.help = help
        self.keywords = keywords
        self.zeroTitle = zeroTitle
    }
}

/// A titled group of rows inside a pane (a grouped-form section). `footer`
/// carries the honest application note ("Applies to new terminals.").
public struct SettingsGroup: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let footer: String?
    public let rows: [SettingsRow]

    public init(id: String, title: String?, footer: String? = nil, rows: [SettingsRow]) {
        self.id = id
        self.title = title
        self.footer = footer
        self.rows = rows
    }
}

/// One Settings pane: a sidebar entry and the grouped rows it shows.
/// `sidebarHeading` is the small heading drawn ABOVE this entry in the sidebar
/// ("Tiles"), or nil. `fields` flattens the groups for consumers that only need
/// the bound fields.
public struct SettingsSection: Equatable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name shown beside the section title in the sidebar, or nil.
    public let iconSystemName: String?
    public let sidebarHeading: String?
    /// Extra words that find this pane in search ("theme" → Appearance).
    public let keywords: [String]
    public let groups: [SettingsGroup]

    public var fields: [SettingsField] { groups.flatMap { $0.rows.map(\.field) } }
    public var rows: [SettingsRow] { groups.flatMap(\.rows) }

    public init(id: String, title: String, iconSystemName: String? = nil, sidebarHeading: String? = nil,
                keywords: [String] = [], groups: [SettingsGroup]) {
        self.id = id
        self.title = title
        self.iconSystemName = iconSystemName
        self.sidebarHeading = sidebarHeading
        self.keywords = keywords
        self.groups = groups
    }

    /// A single untitled group, for callers that build a flat section.
    public init(id: String, title: String, iconSystemName: String? = nil, fields: [SettingsField]) {
        self.init(id: id, title: title, iconSystemName: iconSystemName,
                  groups: [SettingsGroup(id: id, title: nil, rows: fields.map { SettingsRow($0) })])
    }
}
