import AppKit
import ContinuumRevivedCore
import Foundation
import Observation

/// WS7 — the `Canvas background` rows of Settings ▸ Appearance.
///
/// The editor's state and every action, separated from how it is drawn: the rows
/// (`CanvasBackgroundSections`) bind straight to these methods, and the check
/// drives the same methods the rows call. Scope, exact colours, an image import
/// and a live preview are not independent UserDefaults keys, so the precedence
/// rule lives here, once, rather than in a set of `SettingsField`s.
///
/// Everything the editor needs from the app arrives through `Environment`, so a
/// check drives the real editor with no app and no file picker.
@MainActor
@Observable
final class CanvasBackgroundEditor {

    /// Which half of the precedence the editor is currently writing.
    enum Scope: Int, CaseIterable {
        case global
        case workspace

        var title: String {
            switch self {
            case .global: return "All Workspaces"
            case .workspace: return "This Workspace"
            }
        }
    }

    struct Environment {
        var loadGlobal: () -> CanvasBackgroundConfiguration
        var saveGlobal: (CanvasBackgroundConfiguration) -> Void
        var loadWorkspace: () -> WorkspaceCanvasBackground
        var saveWorkspace: (WorkspaceCanvasBackground) -> Void
        /// Import returns the deterministic managed id. Production copies into
        /// the channel's managed directory; the picker never reaches config.
        var importImage: (URL) throws -> CanvasBackgroundAssetID
        /// Production shows an `NSOpenPanel`. `nil` means the user cancelled,
        /// and cancelling must change NOTHING.
        var chooseImageURL: () -> URL?
        /// Non-nil when a workspace is mounted; the workspace scope is disabled
        /// otherwise rather than silently writing nowhere.
        var hasWorkspace: Bool = true
    }

    /// A control's identity, as drawn: the identifier is its row anchor and its
    /// accessibility identifier; label and help are what VoiceOver reads.
    struct Control: Equatable {
        let identifier: String
        let label: String
        let help: String
    }

    static let scopeIdentifier = "canvasBackground.scope"
    static let inheritIdentifier = "canvasBackground.inherit"
    static let patternIdentifier = "canvasBackground.pattern"
    static let baseSystemIdentifier = "canvasBackground.base"
    static let baseColorIdentifier = "canvasBackground.baseColor"
    static let patternColorIdentifier = "canvasBackground.patternColor"
    static let spacingIdentifier = "canvasBackground.spacing"
    static let imageIdentifier = "canvasBackground.image"
    static let opacityIdentifier = "canvasBackground.opacity"
    static let modeIdentifier = "canvasBackground.mode"
    static let resetIdentifier = "canvasBackground.reset"
    static let previewIdentifier = "canvasBackground.preview"

    static let controls: [Control] = [
        Control(identifier: scopeIdentifier, label: "Background scope",
                help: "Whether edits apply to every workspace or only to this one."),
        Control(identifier: inheritIdentifier, label: "Use the global background",
                help: "When on, this workspace follows the background set for all workspaces."),
        Control(identifier: patternIdentifier, label: "Pattern",
                help: "Solid colour, a line grid, or a dot grid."),
        Control(identifier: baseSystemIdentifier, label: "Use the system canvas colour",
                help: "When on, the base colour follows Light and Dark appearance. When off, your exact colour is used in both."),
        Control(identifier: baseColorIdentifier, label: "Base colour",
                help: "The colour behind everything on the canvas."),
        Control(identifier: patternColorIdentifier, label: "Grid colour",
                help: "The colour of the grid lines or dots."),
        Control(identifier: spacingIdentifier, label: "Grid spacing",
                help: "Distance between grid lines, in canvas units, before zoom."),
        Control(identifier: imageIdentifier, label: "Background image",
                help: "Copy an image into Array's own storage and use it as the canvas background."),
        Control(identifier: opacityIdentifier, label: "Image opacity",
                help: "How strongly the image shows through."),
        Control(identifier: modeIdentifier, label: "Image fit",
                help: "Fill crops to cover the canvas; Fit shows the whole image."),
        Control(identifier: resetIdentifier, label: "Reset background",
                help: "Return the current scope to Array's default background."),
    ]

    /// The declared keyboard (and reading) order: the rows draw top to bottom in
    /// exactly this order, which the check asserts against the rendered frames.
    static var keyboardOrder: [String] { controls.map(\.identifier) }

    static func control(_ identifier: String) -> Control {
        controls.first { $0.identifier == identifier } ?? Control(identifier: identifier, label: identifier, help: "")
    }

    @ObservationIgnored let environment: Environment
    private(set) var scope: Scope = .global
    /// Bumped on every write, so rows re-read the stores.
    private(set) var revision = 0
    /// Import failures surfaced to the user, and the last message.
    private(set) var lastImportError: String?
    /// Every write this editor made, by target. A check uses it to prove that
    /// cancelling a picker, or selecting a scope, wrote nothing.
    private(set) var globalWrites = 0
    private(set) var workspaceWrites = 0

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - State

    /// The configuration the editor is currently showing. For the workspace
    /// scope with no override yet, this is the INHERITED global value — the
    /// starting point an edit would fork from. Reading it writes nothing.
    var configuration: CanvasBackgroundConfiguration {
        _ = revision
        switch scope {
        case .global:
            return environment.loadGlobal()
        case .workspace:
            return environment.loadWorkspace().overrideConfiguration ?? environment.loadGlobal()
        }
    }

    var workspaceState: WorkspaceCanvasBackground {
        _ = revision
        return environment.loadWorkspace()
    }

    var usesSystemBase: Bool { configuration.base == .systemDefault }

    /// The workspace is following the global background (only meaningful in the
    /// workspace scope).
    var inheritsGlobal: Bool { !workspaceState.isOverride }

    /// Whether a control is on screen right now. Rows that cannot do anything in
    /// the current state are not drawn, rather than drawn disabled.
    func isPresent(_ identifier: String) -> Bool {
        let config = configuration
        switch identifier {
        case Self.inheritIdentifier: return scope == .workspace && environment.hasWorkspace
        case Self.baseColorIdentifier: return config.base != .systemDefault
        case Self.patternColorIdentifier, Self.spacingIdentifier: return config.pattern.drawsGrid
        case Self.opacityIdentifier, Self.modeIdentifier: return config.image != nil
        default: return Self.controls.contains { $0.identifier == identifier }
        }
    }

    var presentControls: [String] { Self.keyboardOrder.filter(isPresent) }

    /// Apply an edit to whichever scope is selected. Selecting the workspace
    /// scope alone establishes nothing; the first EDIT does, which is what makes
    /// "override" an explicit act.
    private func commit(_ transform: (inout CanvasBackgroundConfiguration) -> Void) {
        var config = configuration
        transform(&config)
        switch scope {
        case .global:
            globalWrites += 1
            environment.saveGlobal(config)
        case .workspace:
            guard environment.hasWorkspace else { return }
            workspaceWrites += 1
            environment.saveWorkspace(.override(config))
        }
        revision += 1
    }

    /// The textual equivalent of the preview — the thing VoiceOver actually
    /// reads. It states the effective scope, not merely the selected one.
    var summary: String {
        let config = configuration
        let workspace = workspaceState
        var parts: [String] = []
        switch scope {
        case .global:
            parts.append("Editing the background for all workspaces.")
        case .workspace:
            parts.append(workspace.isOverride
                ? "This workspace overrides the global background."
                : "This workspace inherits the global background; editing here will create an override.")
        }
        parts.append("Pattern \(config.pattern.displayName).")
        switch config.base {
        case .systemDefault: parts.append("Base colour follows the system appearance.")
        case .custom(let rgba):
            let c = rgba.rgba8
            parts.append("Base colour red \(c.r), green \(c.g), blue \(c.b), alpha \(c.a).")
        }
        if config.pattern.drawsGrid {
            parts.append("Grid spacing \(Int(config.spacing.rounded())) canvas units.")
        }
        if let image = config.image {
            parts.append("Background image \(image.assetID.shortDescription), \(image.mode.displayName), opacity \(image.opacity.displayName).")
        } else {
            parts.append("No background image.")
        }
        if let error = lastImportError { parts.append(error) }
        return parts.joined(separator: " ")
    }

    // MARK: - Actions (the rows call exactly these)

    func selectScope(_ newScope: Scope) {
        // Deliberately no write: changing what you are looking at is not an edit.
        scope = newScope == .workspace && !environment.hasWorkspace ? .global : newScope
        revision += 1
    }

    /// The Inherit switch. On: drop this workspace's override. Off: fork an
    /// override from the inherited global — an explicit act, so it is a write.
    func setInheritsGlobal(_ inherit: Bool) {
        guard scope == .workspace, environment.hasWorkspace else { return }
        if inherit {
            workspaceWrites += 1
            environment.saveWorkspace(.inherit)
            revision += 1
        } else if inheritsGlobal {
            commit { _ in }
        }
    }

    func selectPattern(_ pattern: CanvasBackgroundPattern) {
        commit { $0.pattern = pattern }
    }

    func setUsesSystemBase(_ useSystem: Bool) {
        let current = configuration.base.customColor ?? CanvasBackgroundRGBA.opaque(0.11, 0.12, 0.14)
        commit { $0.base = useSystem ? .systemDefault : .custom(current) }
    }

    func setBaseColor(_ color: NSColor) {
        guard let rgba = Self.exactRGBA(from: color) else { return }
        commit { $0.base = .custom(rgba) }
    }

    func setPatternColor(_ color: NSColor) {
        guard let rgba = Self.exactRGBA(from: color) else { return }
        commit { $0.patternColor = .custom(rgba) }
    }

    func setSpacing(_ value: Double) {
        commit { $0.spacing = CanvasBackgroundConfiguration.clampedSpacing(value) }
    }

    func chooseImage() {
        lastImportError = nil
        // Cancel changes NOTHING — not the configuration, not the scope, not the
        // workspace's inherit/override state.
        guard let url = environment.chooseImageURL() else { revision += 1; return }
        do {
            let id = try environment.importImage(url)
            commit { config in
                let existing = config.image
                config.image = CanvasBackgroundImageSpec(
                    assetID: id,
                    opacity: existing?.opacity ?? .full,
                    mode: existing?.mode ?? .fill)
            }
        } catch {
            lastImportError = "That image could not be used: \(error)."
            revision += 1
        }
    }

    /// Clears the REFERENCE only. The managed file is left for the
    /// reference-aware deferred sweep, because another workspace may still name
    /// it and an undo may want it back.
    func removeImage() {
        commit { $0.image = nil }
    }

    func setOpacity(_ opacity: CanvasBackgroundImageOpacity) {
        commit { $0.image?.opacity = opacity }
    }

    func setMode(_ mode: CanvasBackgroundImageMode) {
        commit { $0.image?.mode = mode }
    }

    func reset() {
        switch scope {
        case .global:
            globalWrites += 1
            environment.saveGlobal(.systemDefault)
        case .workspace:
            guard environment.hasWorkspace else { return }
            // Reset of a WORKSPACE is `.inherit`, not "an override that happens
            // to equal the default": the user asked for no local decision.
            workspaceWrites += 1
            environment.saveWorkspace(.inherit)
        }
        revision += 1
    }

    /// Exact sRGB components. A colour picker can hand back a colour in any space
    /// (a catalogue colour, a P3 pick); converting once, here, is what makes
    /// "the colour you chose is the colour that is stored" true.
    static func exactRGBA(from color: NSColor) -> CanvasBackgroundRGBA? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return CanvasBackgroundRGBA(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent))
    }
}
