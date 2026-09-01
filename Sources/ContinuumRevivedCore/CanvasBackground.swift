import CoreGraphics
import Foundation

/// WS7 — the canvas background model.
///
/// Platform-neutral and versioned. Everything a background needs to be drawn is
/// here except the two things Core cannot own: the *system-derived* base colour
/// (a `DesignTokens` surface, which lives above Core) and the decoded image
/// bitmap (AppKit/ImageIO).
///
/// Three rules this file exists to make mechanical:
///
/// 1. **A custom colour is EXACT.** `CanvasBackgroundRGBA` stores sRGB
///    components verbatim. Nothing here quantises, contrast-adjusts or
///    re-resolves them per appearance — only `.systemDefault` adapts.
/// 2. **Malformed input degrades to a typed default, it never crashes and never
///    silently half-applies.** Every decode of a component container is
///    all-or-nothing: an invalid RGBA/spacing/opacity/enum falls back to the
///    documented default for that field, and the rest of the configuration is
///    preserved.
/// 3. **No path is ever persisted.** An image is referenced by a deterministic
///    content-digest asset id resolved against the channel's managed directory.
///    See `CanvasBackgroundAssetStore`.

// MARK: - Colour

/// An exact sRGB colour. Components are validated finite and within `0...1` at
/// every construction site; there is no way to build an out-of-range value.
public struct CanvasBackgroundRGBA: Equatable, Sendable, Hashable {
    /// Bumped only if the component encoding itself changes. Decoders accept a
    /// missing version (pre-versioned payloads) and reject a greater one.
    public static let currentVersion = 1

    public let version: Int
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// The only initialiser. `nil` for any non-finite or out-of-range
    /// component — callers choose a documented fallback rather than receiving a
    /// silently clamped colour.
    public init?(red: Double, green: Double, blue: Double, alpha: Double, version: Int = CanvasBackgroundRGBA.currentVersion) {
        guard version >= 1, version <= CanvasBackgroundRGBA.currentVersion else { return nil }
        for component in [red, green, blue, alpha] {
            guard component.isFinite, component >= 0, component <= 1 else { return nil }
        }
        self.version = version
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Opaque grey helper used by the frozen defaults below.
    public static func opaque(_ red: Double, _ green: Double, _ blue: Double) -> CanvasBackgroundRGBA {
        // Force-unwrap is safe for the literal call sites in this file only; the
        // public surface is the failable initialiser.
        CanvasBackgroundRGBA(red: red, green: green, blue: blue, alpha: 1)!
    }

    /// sRGB `CGColor`. Kept in Core deliberately: `scripts/check-color-hygiene.sh`
    /// forbids raw colour construction under `Sources/ContinuumRevived/{App,Canvas}`,
    /// and a user's exact colour is not a token. One conversion, one place.
    public var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]
        ) ?? CGColor(gray: 0, alpha: 1)
    }

    /// Stable 8-bit rendering of the colour, for pixel witnesses and manifests.
    public var rgba8: (r: Int, g: Int, b: Int, a: Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()),
         Int((blue * 255).rounded()), Int((alpha * 255).rounded()))
    }
}

extension CanvasBackgroundRGBA: Codable {
    private enum CodingKeys: String, CodingKey { case version, red, green, blue, alpha }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let red = try container.decode(Double.self, forKey: .red)
        let green = try container.decode(Double.self, forKey: .green)
        let blue = try container.decode(Double.self, forKey: .blue)
        let alpha = try container.decode(Double.self, forKey: .alpha)
        guard let value = CanvasBackgroundRGBA(red: red, green: green, blue: blue, alpha: alpha, version: version) else {
            throw CanvasBackgroundDecodeError.invalidColor
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(red, forKey: .red)
        try container.encode(green, forKey: .green)
        try container.encode(blue, forKey: .blue)
        try container.encode(alpha, forKey: .alpha)
    }
}

public enum CanvasBackgroundDecodeError: Error, Equatable {
    case invalidColor
    case unknownFutureSchema(version: Int, supported: Int)
}

/// A colour slot that may defer to the app's `SurfaceToken.canvas` (which is the
/// only value allowed to differ between Aqua and Dark).
public enum CanvasBackgroundColorSource: Equatable, Sendable, Hashable {
    case systemDefault
    case custom(CanvasBackgroundRGBA)

    public var customColor: CanvasBackgroundRGBA? {
        if case .custom(let value) = self { return value }
        return nil
    }
}

extension CanvasBackgroundColorSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, color }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "systemDefault":
            self = .systemDefault
        case "custom":
            self = .custom(try container.decode(CanvasBackgroundRGBA.self, forKey: .color))
        default:
            throw CanvasBackgroundDecodeError.invalidColor
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemDefault:
            try container.encode("systemDefault", forKey: .kind)
        case .custom(let color):
            try container.encode("custom", forKey: .kind)
            try container.encode(color, forKey: .color)
        }
    }
}

// MARK: - Pattern

public enum CanvasBackgroundPattern: String, Codable, CaseIterable, Sendable {
    case solid
    case lines
    case dots

    public var drawsGrid: Bool { self != .solid }

    public var displayName: String {
        switch self {
        case .solid: return "Solid"
        case .lines: return "Line Grid"
        case .dots: return "Dot Grid"
        }
    }
}

// MARK: - Image

public enum CanvasBackgroundImageMode: String, Codable, CaseIterable, Sendable {
    case fill
    case fit

    public var displayName: String { self == .fill ? "Fill" : "Fit" }
}

/// The three shipped opacities. Modelled as an enum rather than a free Double so
/// there is no representable out-of-range value and the Settings control, the
/// encoded form and the renderer cannot disagree.
public enum CanvasBackgroundImageOpacity: String, Codable, CaseIterable, Sendable {
    case hidden
    case muted
    case full

    public var value: Double {
        switch self {
        case .hidden: return 0
        case .muted: return 0.35
        case .full: return 1
        }
    }

    public var displayName: String {
        switch self {
        case .hidden: return "0%"
        case .muted: return "35%"
        case .full: return "100%"
        }
    }

    public static func nearest(to value: Double) -> CanvasBackgroundImageOpacity {
        guard value.isFinite else { return .full }
        return allCases.min(by: { abs($0.value - value) < abs($1.value - value) }) ?? .full
    }
}

/// A reference to a managed asset. **Never a URL, path or bookmark.**
public struct CanvasBackgroundImageSpec: Equatable, Sendable, Hashable, Codable {
    public let assetID: CanvasBackgroundAssetID
    public var opacity: CanvasBackgroundImageOpacity
    public var mode: CanvasBackgroundImageMode

    public init(assetID: CanvasBackgroundAssetID,
                opacity: CanvasBackgroundImageOpacity = .full,
                mode: CanvasBackgroundImageMode = .fill) {
        self.assetID = assetID
        self.opacity = opacity
        self.mode = mode
    }
}

/// A deterministic, path-free asset identifier: `<sha256 hex>.<ext>`.
public struct CanvasBackgroundAssetID: Equatable, Sendable, Hashable, Codable, CustomStringConvertible {
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    public let digest: String
    public let fileExtension: String

    public init?(digest: String, fileExtension: String) {
        let lowerDigest = digest.lowercased()
        let lowerExt = fileExtension.lowercased()
        guard lowerDigest.count == 64,
              lowerDigest.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }),
              Self.allowedExtensions.contains(lowerExt) else { return nil }
        self.digest = lowerDigest
        self.fileExtension = lowerExt
    }

    /// The managed FILE NAME. This is the only string that ever names a file, it
    /// is derived, and it can contain no separator (both halves are validated).
    public var fileName: String { "\(digest).\(fileExtension)" }
    public var description: String { fileName }

    /// A short, privacy-safe form for warning text — no path, no user filename.
    public var shortDescription: String { String(digest.prefix(12)) }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let parts = raw.split(separator: ".")
        guard parts.count == 2,
              let value = CanvasBackgroundAssetID(digest: String(parts[0]), fileExtension: String(parts[1])) else {
            throw CanvasBackgroundDecodeError.invalidColor
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fileName)
    }
}

// MARK: - Configuration

public struct CanvasBackgroundConfiguration: Equatable, Sendable, Hashable {
    /// v1: base colour source, pattern, pattern colour source, world spacing,
    /// optional managed image.
    public static let currentSchemaVersion = 1

    /// Bounded world spacing. A grid coarser or finer than this is neither
    /// useful nor safe (the primitive bound is `viewport / (spacing * zoom)`).
    public static let spacingRange: ClosedRange<Double> = 8...512
    public static let defaultSpacing: Double = 64

    public static let defaultPatternColor = CanvasBackgroundRGBA(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.28)!

    public var schemaVersion: Int
    public var base: CanvasBackgroundColorSource
    public var pattern: CanvasBackgroundPattern
    public var patternColor: CanvasBackgroundColorSource
    /// World points between grid lines/dots, before the adaptive multiplier.
    public var spacing: Double
    public var image: CanvasBackgroundImageSpec?

    public init(
        schemaVersion: Int = CanvasBackgroundConfiguration.currentSchemaVersion,
        base: CanvasBackgroundColorSource = .systemDefault,
        pattern: CanvasBackgroundPattern = .solid,
        patternColor: CanvasBackgroundColorSource = .custom(CanvasBackgroundConfiguration.defaultPatternColor),
        spacing: Double = CanvasBackgroundConfiguration.defaultSpacing,
        image: CanvasBackgroundImageSpec? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.base = base
        self.pattern = pattern
        self.patternColor = patternColor
        self.spacing = Self.clampedSpacing(spacing)
        self.image = image
    }

    public static let systemDefault = CanvasBackgroundConfiguration()

    /// Bounded, never rejected: spacing arrives from a slider and a stored
    /// double, and a value outside the range is a bug in the writer, not a
    /// reason to lose the whole configuration.
    public static func clampedSpacing(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSpacing }
        return Swift.min(Swift.max(value, spacingRange.lowerBound), spacingRange.upperBound)
    }
}

extension CanvasBackgroundConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, base, pattern, patternColor, spacing, image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? CanvasBackgroundConfiguration.currentSchemaVersion
        guard version <= CanvasBackgroundConfiguration.currentSchemaVersion else {
            // A FUTURE configuration is an error, never a downgrade — the same
            // rule `WorkspaceDocument.validateSchema` applies.
            throw CanvasBackgroundDecodeError.unknownFutureSchema(
                version: version, supported: CanvasBackgroundConfiguration.currentSchemaVersion)
        }
        // Per-field tolerance: a malformed field falls back, the siblings survive.
        let base = (try? container.decodeIfPresent(CanvasBackgroundColorSource.self, forKey: .base)) ?? nil
        let pattern = (try? container.decodeIfPresent(CanvasBackgroundPattern.self, forKey: .pattern)) ?? nil
        let patternColor = (try? container.decodeIfPresent(CanvasBackgroundColorSource.self, forKey: .patternColor)) ?? nil
        let spacing = (try? container.decodeIfPresent(Double.self, forKey: .spacing)) ?? nil
        let image = (try? container.decodeIfPresent(CanvasBackgroundImageSpec.self, forKey: .image)) ?? nil
        self.init(
            schemaVersion: CanvasBackgroundConfiguration.currentSchemaVersion,
            base: base ?? .systemDefault,
            pattern: pattern ?? .solid,
            patternColor: patternColor ?? .custom(CanvasBackgroundConfiguration.defaultPatternColor),
            spacing: spacing.map(CanvasBackgroundConfiguration.clampedSpacing) ?? CanvasBackgroundConfiguration.defaultSpacing,
            image: image
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Swift.max(schemaVersion, CanvasBackgroundConfiguration.currentSchemaVersion), forKey: .schemaVersion)
        try container.encode(base, forKey: .base)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(patternColor, forKey: .patternColor)
        try container.encode(spacing, forKey: .spacing)
        try container.encodeIfPresent(image, forKey: .image)
    }
}

// MARK: - Per-workspace inherit / override

/// EXPLICIT. `.inherit` is a stored decision, not the absence of one, and it is
/// never materialised into a copy of the global value — that collapse is the
/// defect the model is shaped to prevent (a later global edit would stop
/// reaching the workspace).
public enum WorkspaceCanvasBackground: Equatable, Sendable, Hashable {
    case inherit
    case override(CanvasBackgroundConfiguration)

    public var overrideConfiguration: CanvasBackgroundConfiguration? {
        if case .override(let config) = self { return config }
        return nil
    }

    public var isOverride: Bool { overrideConfiguration != nil }
}

extension WorkspaceCanvasBackground: Codable {
    private enum CodingKeys: String, CodingKey { case scope, configuration }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "inherit"
        switch scope {
        case "override":
            guard let config = try? container.decode(CanvasBackgroundConfiguration.self, forKey: .configuration) else {
                // An override whose payload cannot be read is not an excuse to
                // silently adopt the global: it degrades to the typed default
                // configuration, which is still an override, so the user's
                // explicit scope decision survives.
                self = .override(.systemDefault)
                return
            }
            self = .override(config)
        default:
            self = .inherit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit:
            try container.encode("inherit", forKey: .scope)
        case .override(let config):
            try container.encode("override", forKey: .scope)
            try container.encode(config, forKey: .configuration)
        }
    }
}

/// The whole precedence rule, in one pure function.
public enum CanvasBackgroundResolver {
    public static func effective(
        workspace: WorkspaceCanvasBackground,
        global: CanvasBackgroundConfiguration
    ) -> CanvasBackgroundConfiguration {
        switch workspace {
        case .inherit: return global
        case .override(let config): return config
        }
    }

    /// Which side an effective value came from — recorded by the witness so
    /// "inherit that happens to equal the global" cannot pass as "override".
    public enum Source: String, Equatable, Sendable { case global, workspaceOverride }

    public static func source(for workspace: WorkspaceCanvasBackground) -> Source {
        workspace.isOverride ? .workspaceOverride : .global
    }
}

// MARK: - Channel-local global store

/// The GLOBAL configuration, as ONE atomic encoded value in the channel's own
/// defaults domain.
///
/// One key, not one key per field: independent keys tear — a crash between two
/// writes leaves a configuration that was never chosen. (And the channel split
/// is the only isolation that works here; see hazard 3.)
public enum CanvasBackgroundGlobalStore {
    public static let key = "continuum.canvasBackground.global"

    public static func load(defaults: UserDefaults = .standard) -> CanvasBackgroundConfiguration {
        guard let data = defaults.data(forKey: key) else { return .systemDefault }
        guard let config = try? JSONCodec.makeCanvasDecoder().decode(CanvasBackgroundConfiguration.self, from: data) else {
            return .systemDefault
        }
        return config
    }

    @discardableResult
    public static func save(_ configuration: CanvasBackgroundConfiguration, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONCodec.makeEncoder().encode(configuration) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
