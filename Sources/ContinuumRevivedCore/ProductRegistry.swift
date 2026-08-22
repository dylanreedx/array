import Foundation

public struct FeatureID: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct CommandID: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct ShortcutID: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct SettingID: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct SettingConsumerID: RawRepresentable, Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

/// Process-local delivery for an exact setting identity. A distinct notification
/// name per ID means consumers cannot accidentally rerun for unrelated writes.
public enum SettingChangeEvent {
    public static func name(for id: SettingID) -> Notification.Name {
        Notification.Name("array.setting.changed.\(id.rawValue)")
    }

    public static func post(
        _ id: SettingID,
        center: NotificationCenter = .default
    ) {
        center.post(name: name(for: id), object: nil)
    }
}

public enum ShortcutContext: Codable, Equatable, Hashable, Sendable {
    case global
    case canvas
    case navigationMode
    case tile(TileKind)
    case agentInbox
}

public struct ShortcutGesture: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiersRawValue: UInt

    public init(keyCode: UInt16, modifiers: FocusKeyModifiers) {
        self.keyCode = keyCode
        modifiersRawValue = modifiers.rawValue
    }

    public init(_ chord: KeyChord) {
        self.init(keyCode: chord.keyCode, modifiers: chord.modifiers)
    }

    public var chord: KeyChord {
        KeyChord(keyCode: keyCode, modifiers: FocusKeyModifiers(rawValue: modifiersRawValue))
    }

    public var displayString: String { chord.displayString }
    public var serialized: String { chord.serialized }
}

public enum ShortcutEditability: String, Codable, Equatable, Sendable {
    case userEditable
    case fixedSystem
}

public enum ShortcutConflictDomain: Codable, Equatable, Hashable, Sendable {
    /// Conflicts with every context that can be active while the app is frontmost.
    case global
    /// Conflicts only when the listed contexts can be simultaneously active.
    case contexts(Set<ShortcutContext>)
}

public enum ShortcutPresentationPriority: Int, Codable, Equatable, Comparable, Sendable {
    case hidden = 0
    case settings = 1
    case commandAccessory = 2
    case canvasRail = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ShortcutDefinition: Codable, Equatable, Sendable {
    public let id: ShortcutID
    public let commandID: CommandID
    public let contexts: Set<ShortcutContext>
    public let defaultGestures: [ShortcutGesture]
    public let editability: ShortcutEditability
    public let conflictDomain: ShortcutConflictDomain
    public let presentationPriority: ShortcutPresentationPriority

    public init(
        id: ShortcutID,
        commandID: CommandID,
        contexts: Set<ShortcutContext>,
        defaultGestures: [ShortcutGesture] = [],
        editability: ShortcutEditability = .userEditable,
        conflictDomain: ShortcutConflictDomain,
        presentationPriority: ShortcutPresentationPriority = .settings
    ) {
        self.id = id
        self.commandID = commandID
        self.contexts = contexts
        self.defaultGestures = defaultGestures
        self.editability = editability
        self.conflictDomain = conflictDomain
        self.presentationPriority = presentationPriority
    }
}

public enum CommandMenuPlacement: String, Codable, Equatable, Sendable {
    case application
    case file
    case view
    case window
    case help
}

/// Stable Core identity and presentation. App owns execution closures; the
/// optional palette action is a platform-neutral dispatch token only.
public struct CommandDefinition: Equatable, Sendable {
    public let id: CommandID
    public let title: String
    public let subtitle: String?
    public let aliases: [String]
    public let paletteAction: LaunchPaletteAction?
    public let paletteVisible: Bool
    public let menuPlacement: CommandMenuPlacement?
    public let shortcuts: [ShortcutDefinition]
    public let helpKeywords: [String]

    public init(
        id: CommandID,
        title: String,
        subtitle: String? = nil,
        aliases: [String] = [],
        paletteAction: LaunchPaletteAction? = nil,
        paletteVisible: Bool = true,
        menuPlacement: CommandMenuPlacement? = nil,
        shortcuts: [ShortcutDefinition] = [],
        helpKeywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.aliases = aliases
        self.paletteAction = paletteAction
        self.paletteVisible = paletteVisible
        self.menuPlacement = menuPlacement
        self.shortcuts = shortcuts
        self.helpKeywords = helpKeywords
    }
}

public enum SettingsCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case general
    case appearance
    case canvasAndZones
    case navigation
    case keybindings
    case agents
    case terminal
    case browser
    case activityAndNotifications
    case advanced
}

public enum SettingsLevel: String, Codable, Equatable, Sendable {
    case standard
    case advanced
}

public enum SettingApplicationPolicy: String, Codable, Equatable, Sendable {
    case live
    case nextCreation
    case nextLaunch
}

public enum SettingControl: Equatable, Sendable {
    case toggle
    case labeledEnum(options: [String: String])
    case boundedNumber(range: ClosedRange<Double>, unit: String, step: Double)
    case url
    case directory
    case colorPalette([String])
    case shortcutCapture
    case text
    case action
    case status
}

public struct SettingMigration: Equatable, Sendable {
    public let legacyKeys: [String]
    public init(legacyKeys: [String]) { self.legacyKeys = legacyKeys }
}

public struct SettingValidation<Value>: @unchecked Sendable {
    private let body: (Value) -> String?

    public init(_ body: @escaping (Value) -> String?) { self.body = body }
    public func error(for value: Value) -> String? { body(value) }
    public static var none: SettingValidation<Value> { SettingValidation { _ in nil } }
}

public struct SettingDefinition<Value: Codable & Equatable>: @unchecked Sendable {
    public let id: SettingID
    public let category: SettingsCategory
    public let level: SettingsLevel
    public let title: String
    public let description: String
    public let defaultValue: Value
    public let control: SettingControl
    public let validation: SettingValidation<Value>
    public let applicationPolicy: SettingApplicationPolicy
    public let keywords: [String]
    public let migration: SettingMigration?
    public let consumerID: SettingConsumerID

    public init(
        id: SettingID,
        category: SettingsCategory,
        level: SettingsLevel = .standard,
        title: String,
        description: String,
        defaultValue: Value,
        control: SettingControl,
        validation: SettingValidation<Value> = .none,
        applicationPolicy: SettingApplicationPolicy,
        keywords: [String] = [],
        migration: SettingMigration? = nil,
        consumerID: SettingConsumerID
    ) {
        self.id = id
        self.category = category
        self.level = level
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
        self.control = control
        self.validation = validation
        self.applicationPolicy = applicationPolicy
        self.keywords = keywords
        self.migration = migration
        self.consumerID = consumerID
    }

    public var erased: AnySettingDefinition { AnySettingDefinition(self) }
}

public struct AnySettingDefinition: Equatable, Sendable {
    public let id: SettingID
    public let category: SettingsCategory
    public let level: SettingsLevel
    public let title: String
    public let description: String
    public let applicationPolicy: SettingApplicationPolicy
    public let keywords: [String]
    public let consumerID: SettingConsumerID

    public init<Value>(_ definition: SettingDefinition<Value>) where Value: Codable & Equatable {
        id = definition.id
        category = definition.category
        level = definition.level
        title = definition.title
        description = definition.description
        applicationPolicy = definition.applicationPolicy
        keywords = definition.keywords
        consumerID = definition.consumerID
    }

    public init(
        id: SettingID,
        category: SettingsCategory,
        level: SettingsLevel,
        title: String,
        description: String,
        applicationPolicy: SettingApplicationPolicy,
        keywords: [String],
        consumerID: SettingConsumerID
    ) {
        self.id = id
        self.category = category
        self.level = level
        self.title = title
        self.description = description
        self.applicationPolicy = applicationPolicy
        self.keywords = keywords
        self.consumerID = consumerID
    }
}

public struct FeatureRegistration: Equatable, Sendable {
    public let id: FeatureID
    public let commands: [CommandDefinition]
    public let settings: [AnySettingDefinition]

    public init(id: FeatureID, commands: [CommandDefinition], settings: [AnySettingDefinition]) {
        self.id = id
        self.commands = commands
        self.settings = settings
    }
}

public enum ProductRegistryError: Error, Equatable, LocalizedError {
    case duplicateFeature(FeatureID)
    case duplicateCommand(CommandID)
    case duplicateShortcut(ShortcutID)
    case duplicateSetting(SettingID)
    case shortcutReferencesUnknownCommand(ShortcutID, CommandID)
    case missingSettingConsumer(SettingID)

    public var errorDescription: String? {
        switch self {
        case .duplicateFeature(let id): return "Feature is registered twice: \(id.rawValue)"
        case .duplicateCommand(let id): return "Command is registered twice: \(id.rawValue)"
        case .duplicateShortcut(let id): return "Shortcut is registered twice: \(id.rawValue)"
        case .duplicateSetting(let id): return "Setting is registered twice: \(id.rawValue)"
        case .shortcutReferencesUnknownCommand(let shortcut, let command):
            return "Shortcut \(shortcut.rawValue) references unknown command \(command.rawValue)"
        case .missingSettingConsumer(let id): return "Live setting has no registered consumer: \(id.rawValue)"
        }
    }
}

public struct ProductRegistry: Sendable {
    public let features: [FeatureRegistration]
    public let commands: [CommandDefinition]
    public let shortcuts: [ShortcutDefinition]
    public let settings: [AnySettingDefinition]

    public init(features: [FeatureRegistration]) throws {
        var featureIDs = Set<FeatureID>()
        var commandIDs = Set<CommandID>()
        var shortcutIDs = Set<ShortcutID>()
        var settingIDs = Set<SettingID>()

        for feature in features {
            guard featureIDs.insert(feature.id).inserted else { throw ProductRegistryError.duplicateFeature(feature.id) }
            for command in feature.commands {
                guard commandIDs.insert(command.id).inserted else { throw ProductRegistryError.duplicateCommand(command.id) }
            }
            for setting in feature.settings {
                guard settingIDs.insert(setting.id).inserted else { throw ProductRegistryError.duplicateSetting(setting.id) }
                if setting.applicationPolicy == .live && setting.consumerID.rawValue.isEmpty {
                    throw ProductRegistryError.missingSettingConsumer(setting.id)
                }
            }
        }

        let allCommands = features.flatMap(\.commands)
        let allShortcuts = allCommands.flatMap(\.shortcuts)
        for shortcut in allShortcuts {
            guard shortcutIDs.insert(shortcut.id).inserted else { throw ProductRegistryError.duplicateShortcut(shortcut.id) }
            guard commandIDs.contains(shortcut.commandID) else {
                throw ProductRegistryError.shortcutReferencesUnknownCommand(shortcut.id, shortcut.commandID)
            }
        }

        self.features = features
        commands = allCommands
        shortcuts = allShortcuts
        settings = features.flatMap(\.settings)
    }
}

public enum ShortcutConflictResolver {
    public static func conflicts(_ lhs: ShortcutDefinition, _ rhs: ShortcutDefinition) -> Bool {
        switch (lhs.conflictDomain, rhs.conflictDomain) {
        case (.global, _), (_, .global): return true
        case let (.contexts(left), .contexts(right)): return !left.isDisjoint(with: right)
        }
    }
}

public enum ShortcutBindingError: Error, Equatable, LocalizedError, Sendable {
    case fixed(ShortcutID)
    case systemReserved(String)
    case conflict(ShortcutID)

    public var errorDescription: String? {
        switch self {
        case .fixed(let id): return "\(id.rawValue) is fixed by the system."
        case .systemReserved(let explanation): return explanation
        case .conflict(let id): return "This gesture conflicts with \(id.rawValue) in an active context."
        }
    }
}

/// User overrides for registered shortcuts. Absence means registered defaults;
/// a persisted empty array means deliberately Unassigned.
public final class ShortcutBindingStore: @unchecked Sendable {
    public static let keyPrefix = "array.shortcut.binding."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func gestures(for definition: ShortcutDefinition) -> [ShortcutGesture] {
        guard let data = defaults.data(forKey: Self.keyPrefix + definition.id.rawValue),
              let decoded = try? JSONDecoder().decode([ShortcutGesture].self, from: data) else {
            return definition.defaultGestures
        }
        return decoded
    }

    public func isModified(_ definition: ShortcutDefinition) -> Bool {
        defaults.object(forKey: Self.keyPrefix + definition.id.rawValue) != nil
    }

    public func matches(
        keyCode: UInt16,
        modifiers: FocusKeyModifiers,
        definition: ShortcutDefinition
    ) -> Bool {
        gestures(for: definition).contains {
            $0.keyCode == keyCode && $0.modifiersRawValue == modifiers.rawValue
        }
    }

    public func set(
        _ gestures: [ShortcutGesture],
        for definition: ShortcutDefinition,
        registry: ProductRegistry
    ) throws {
        guard definition.editability == .userEditable else { throw ShortcutBindingError.fixed(definition.id) }
        var seen = Set<ShortcutGesture>()
        let unique = gestures.filter { seen.insert($0).inserted }
        for gesture in unique {
            if let conflict = KnownChordConflicts.conflict(for: gesture.chord) {
                throw ShortcutBindingError.systemReserved("\(conflict.note) is reserved by \(conflict.source.rawValue).")
            }
            for other in registry.shortcuts where other.id != definition.id
                && ShortcutConflictResolver.conflicts(definition, other)
                && self.gestures(for: other).contains(gesture) {
                throw ShortcutBindingError.conflict(other.id)
            }
        }
        let data = try JSONEncoder().encode(unique)
        defaults.set(data, forKey: Self.keyPrefix + definition.id.rawValue)
    }

    public func unassign(_ definition: ShortcutDefinition, registry: ProductRegistry) throws {
        try set([], for: definition, registry: registry)
    }

    public func reset(_ definition: ShortcutDefinition) {
        defaults.removeObject(forKey: Self.keyPrefix + definition.id.rawValue)
    }
}

/// Typed writes with validation and exact-ID observation. Primitive values are
/// persisted in their native UserDefaults representation so existing consumers
/// continue to read byte-for-byte equivalent values during migration.
public final class UserSettingsStore: @unchecked Sendable {
    public typealias Observer = @Sendable (SettingID) -> Void

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var observers: [UUID: (SettingID, Observer)] = [:]

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func value<Value>(for definition: SettingDefinition<Value>) -> Value where Value: Codable & Equatable {
        guard let object = defaults.object(forKey: definition.id.rawValue) else { return definition.defaultValue }
        if let value = object as? Value { return value }
        if let data = object as? Data, let value = try? JSONDecoder().decode(Value.self, from: data) { return value }
        return definition.defaultValue
    }

    @discardableResult
    public func set<Value>(_ value: Value, for definition: SettingDefinition<Value>) -> String? where Value: Codable & Equatable {
        if let error = definition.validation.error(for: value) { return error }
        switch value {
        case let primitive as Bool: defaults.set(primitive, forKey: definition.id.rawValue)
        case let primitive as String: defaults.set(primitive, forKey: definition.id.rawValue)
        case let primitive as Int: defaults.set(primitive, forKey: definition.id.rawValue)
        case let primitive as Double: defaults.set(primitive, forKey: definition.id.rawValue)
        default:
            guard let data = try? JSONEncoder().encode(value) else { return "This value could not be saved." }
            defaults.set(data, forKey: definition.id.rawValue)
        }
        notify(definition.id)
        return nil
    }

    public func reset<Value>(_ definition: SettingDefinition<Value>) where Value: Codable & Equatable {
        defaults.removeObject(forKey: definition.id.rawValue)
        notify(definition.id)
    }

    public func isModified<Value>(_ definition: SettingDefinition<Value>) -> Bool where Value: Codable & Equatable {
        defaults.object(forKey: definition.id.rawValue) != nil && value(for: definition) != definition.defaultValue
    }

    @discardableResult
    public func observe(_ id: SettingID, _ observer: @escaping Observer) -> UUID {
        let token = UUID()
        lock.lock(); observers[token] = (id, observer); lock.unlock()
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock(); observers.removeValue(forKey: token); lock.unlock()
    }

    private func notify(_ id: SettingID) {
        lock.lock()
        let callbacks = observers.values.filter { $0.0 == id }.map(\.1)
        lock.unlock()
        for callback in callbacks { callback(id) }
        SettingChangeEvent.post(id)
    }
}
