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
    /// A fixed-options preference (rendered as a popup). `setValue` rejects any
    /// value not in `options`, falling back to `default`.
    case choice(key: String, label: String, options: [String], default: String)
    /// A bounded numeric preference rendered as a slider. An optional condition
    /// keeps advanced controls out of the panel until their owning choice is
    /// selected.
    case slider(key: String, label: String, range: ClosedRange<Double>, default: Double, visibleWhen: SettingsVisibility? = nil)
    /// Static explanatory copy rendered in a settings section without binding a
    /// UserDefaults key.
    case info(label: String)
    /// The keybindings editor/guide, which renders `ShortcutCatalog` rather than
    /// binding a single key.
    case shortcuts(label: String)

    /// The UserDefaults key this field reads/writes, or `nil` for static fields.
    public var key: String? {
        switch self {
        case .toggle(let key, _, _): return key
        case .text(let key, _, _): return key
        case .choice(let key, _, _, _): return key
        case .slider(let key, _, _, _, _): return key
        case .info: return nil
        case .shortcuts: return nil
        }
    }

    /// The human-readable label for this field.
    public var label: String {
        switch self {
        case .toggle(_, let label, _): return label
        case .text(_, let label, _): return label
        case .choice(_, let label, _, _): return label
        case .slider(_, let label, _, _, _): return label
        case .info(let label): return label
        case .shortcuts(let label): return label
        }
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
        case .choice(let key, _, let options, let fallback):
            let raw = defaults.string(forKey: key)
            if let raw, options.contains(raw) { return .string(raw) }
            return .string(fallback)
        case .slider(let key, _, let range, let fallback, _):
            let raw = defaults.object(forKey: key)
            let decoded = (raw as? NSNumber)?.doubleValue
                ?? (raw as? String).flatMap(Double.init)
                ?? fallback
            return .double(min(range.upperBound, max(range.lowerBound, decoded)))
        case .info:
            return nil
        case .shortcuts:
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
        case .choice(let key, _, let options, let fallback):
            guard case .string(let raw) = value, options.contains(raw) else {
                defaults.set(fallback, forKey: key)
                return
            }
            defaults.set(raw, forKey: key)
        case .slider(let key, _, let range, let fallback, _):
            guard case .double(let raw) = value else { defaults.set(fallback, forKey: key); return }
            defaults.set(min(range.upperBound, max(range.lowerBound, raw)), forKey: key)
        case .info:
            break
        case .shortcuts:
            break
        }
    }

    public func isVisible(in defaults: UserDefaults) -> Bool {
        guard case .slider(_, _, _, _, let condition) = self, let condition else { return true }
        return defaults.string(forKey: condition.key) == condition.equals
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

/// An ordered group of fields shown together in the settings surface.
public struct SettingsSection: Equatable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name shown beside the section title in the sidebar, or nil.
    public let iconSystemName: String?
    public let fields: [SettingsField]

    public init(id: String, title: String, iconSystemName: String? = nil, fields: [SettingsField]) {
        self.id = id
        self.title = title
        self.iconSystemName = iconSystemName
        self.fields = fields
    }
}
