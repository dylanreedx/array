import AppKit
import ContinuumRevivedCore
import Foundation

/// WS7 — the `Canvas Background` Settings section.
///
/// A custom section view rather than `SettingsField` rows (`SettingsPanel`'s
/// `customSectionViews` seam, the same one Companion uses): scope, exact colour
/// wells, an image import and a live preview are not independent UserDefaults
/// keys, and pretending they are would put the precedence rule in two places.
///
/// Everything the view needs from the app arrives through `Environment`, so a
/// check drives the REAL controls with no app, no panel and no file picker.
@MainActor
final class CanvasBackgroundSettingsView: NSView {

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

    // Accessibility identifiers are the keyboard order, in order.
    static let scopeIdentifier = "ContinuumCanvasBackgroundScope"
    static let inheritIdentifier = "ContinuumCanvasBackgroundInherit"
    static let presetIdentifier = "ContinuumCanvasBackgroundPreset"
    static let baseSystemIdentifier = "ContinuumCanvasBackgroundBaseSystemDefault"
    static let baseColorIdentifier = "ContinuumCanvasBackgroundBaseColor"
    static let patternColorIdentifier = "ContinuumCanvasBackgroundPatternColor"
    static let spacingIdentifier = "ContinuumCanvasBackgroundSpacing"
    static let chooseImageIdentifier = "ContinuumCanvasBackgroundChooseImage"
    static let removeImageIdentifier = "ContinuumCanvasBackgroundRemoveImage"
    static let opacityIdentifier = "ContinuumCanvasBackgroundOpacity"
    static let modeIdentifier = "ContinuumCanvasBackgroundMode"
    static let resetIdentifier = "ContinuumCanvasBackgroundReset"
    static let summaryIdentifier = "ContinuumCanvasBackgroundSummary"
    static let previewIdentifier = "ContinuumCanvasBackgroundPreview"

    /// The declared keyboard traversal order, asserted by the self-check against
    /// the real `nextKeyView` chain rather than against this list alone.
    static let keyboardOrder = [
        scopeIdentifier, inheritIdentifier, presetIdentifier,
        baseSystemIdentifier, baseColorIdentifier, patternColorIdentifier,
        spacingIdentifier, chooseImageIdentifier, removeImageIdentifier,
        opacityIdentifier, modeIdentifier, resetIdentifier,
    ]

    private let environment: Environment
    private(set) var scope: Scope = .global

    private let scopePopUp = NSPopUpButton()
    private let inheritButton = NSButton()
    private let presetPopUp = NSPopUpButton()
    private let baseSystemCheckbox = NSButton()
    private let baseColorWell = NSColorWell()
    private let patternColorWell = NSColorWell()
    private let spacingSlider = NSSlider()
    private let spacingLabel = NSTextField(labelWithString: "")
    private let chooseImageButton = NSButton()
    private let removeImageButton = NSButton()
    private let opacityPopUp = NSPopUpButton()
    private let modePopUp = NSPopUpButton()
    private let resetButton = NSButton()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let preview: CanvasBackgroundRendererView

    /// QA: import failures surfaced to the user, and the last message.
    private(set) var qaLastImportError: String?
    /// QA: every write this view made, by target. A check uses it to prove that
    /// cancelling a picker, or selecting a scope, wrote nothing.
    private(set) var qaGlobalWrites = 0
    private(set) var qaWorkspaceWrites = 0

    init(environment: Environment) {
        self.environment = environment
        self.preview = CanvasBackgroundRendererView(
            imageCache: CanvasBackgroundImageCache(store: CanvasBackgroundAssetStore()))
        super.init(frame: NSRect(x: 0, y: 0, width: 510, height: 460))
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Construction

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        configure(scopePopUp, identifier: Self.scopeIdentifier,
                  label: "Background scope",
                  help: "Whether edits apply to every workspace or only to this one.",
                  titles: Scope.allCases.map(\.title), action: #selector(scopeChanged))
        scopePopUp.item(at: Scope.workspace.rawValue)?.isEnabled = environment.hasWorkspace

        inheritButton.title = "Inherit Global"
        inheritButton.bezelStyle = .rounded
        inheritButton.target = self
        inheritButton.action = #selector(inheritTapped)
        register(inheritButton, identifier: Self.inheritIdentifier,
                 label: "Inherit global background",
                 help: "Remove this workspace's override and follow the global background again.")

        configure(presetPopUp, identifier: Self.presetIdentifier,
                  label: "Pattern",
                  help: "Solid colour, a line grid, or a dot grid.",
                  titles: CanvasBackgroundPattern.allCases.map(\.displayName),
                  action: #selector(presetChanged))

        baseSystemCheckbox.setButtonType(.switch)
        baseSystemCheckbox.title = "Use the system canvas colour"
        baseSystemCheckbox.target = self
        baseSystemCheckbox.action = #selector(baseSystemChanged)
        register(baseSystemCheckbox, identifier: Self.baseSystemIdentifier,
                 label: "Use the system canvas colour",
                 help: "When on, the base colour follows Light and Dark appearance. When off, your exact colour is used in both.")

        baseColorWell.target = self
        baseColorWell.action = #selector(baseColorChanged)
        register(baseColorWell, identifier: Self.baseColorIdentifier,
                 label: "Base colour", help: "The colour behind everything on the canvas.")

        patternColorWell.target = self
        patternColorWell.action = #selector(patternColorChanged)
        register(patternColorWell, identifier: Self.patternColorIdentifier,
                 label: "Grid colour", help: "The colour of the grid lines or dots.")

        spacingSlider.minValue = CanvasBackgroundConfiguration.spacingRange.lowerBound
        spacingSlider.maxValue = CanvasBackgroundConfiguration.spacingRange.upperBound
        spacingSlider.target = self
        spacingSlider.action = #selector(spacingChanged)
        spacingSlider.isContinuous = true
        register(spacingSlider, identifier: Self.spacingIdentifier,
                 label: "Grid spacing",
                 help: "Distance between grid lines, in canvas units, before zoom.")

        chooseImageButton.title = "Choose Image…"
        chooseImageButton.bezelStyle = .rounded
        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseImageTapped)
        register(chooseImageButton, identifier: Self.chooseImageIdentifier,
                 label: "Choose background image",
                 help: "Copy an image into Array's own storage and use it as the canvas background.")

        removeImageButton.title = "Remove Image"
        removeImageButton.bezelStyle = .rounded
        removeImageButton.target = self
        removeImageButton.action = #selector(removeImageTapped)
        register(removeImageButton, identifier: Self.removeImageIdentifier,
                 label: "Remove background image",
                 help: "Stop using a background image. The stored copy is cleaned up later if nothing else uses it.")

        configure(opacityPopUp, identifier: Self.opacityIdentifier,
                  label: "Image opacity", help: "How strongly the image shows through.",
                  titles: CanvasBackgroundImageOpacity.allCases.map(\.displayName),
                  action: #selector(opacityChanged))

        configure(modePopUp, identifier: Self.modeIdentifier,
                  label: "Image fit", help: "Fill crops to cover the canvas; Fit shows the whole image.",
                  titles: CanvasBackgroundImageMode.allCases.map(\.displayName),
                  action: #selector(modeChanged))

        resetButton.title = "Reset Background"
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        register(resetButton, identifier: Self.resetIdentifier,
                 label: "Reset background",
                 help: "Return the current scope to Array's default background.")

        spacingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        spacingLabel.setAccessibilityElement(false)

        // The preview is DECORATION: it repeats, in pixels, what the summary
        // already says in words, so it is hidden from accessibility rather than
        // read out as an unlabelled image.
        preview.setAccessibilityElement(false)
        preview.identifier = NSUserInterfaceItemIdentifier(Self.previewIdentifier)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 120).isActive = true

        summaryLabel.setAccessibilityIdentifier(Self.summaryIdentifier)
        summaryLabel.setAccessibilityLabel("Effective background")
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 4

        let stack = NSStackView(views: [
            row("Scope", scopePopUp, inheritButton),
            row("Pattern", presetPopUp),
            row("Base", baseSystemCheckbox),
            row("", baseColorWell),
            row("Grid colour", patternColorWell),
            row("Spacing", spacingSlider, spacingLabel),
            row("Image", chooseImageButton, removeImageButton),
            row("Opacity", opacityPopUp),
            row("Fit", modePopUp),
            preview,
            summaryLabel,
            row("", resetButton),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            preview.widthAnchor.constraint(equalToConstant: 320),
        ])

        // Explicit key loop. AppKit's automatic ordering follows geometry, and
        // two controls sharing a row would otherwise be traversed in whatever
        // order the layout happened to produce.
        let chain: [NSView] = [
            scopePopUp, inheritButton, presetPopUp, baseSystemCheckbox, baseColorWell,
            patternColorWell, spacingSlider, chooseImageButton, removeImageButton,
            opacityPopUp, modePopUp, resetButton,
        ]
        for (index, view) in chain.enumerated() {
            view.nextKeyView = chain[(index + 1) % chain.count]
        }
    }

    private func configure(_ popUp: NSPopUpButton, identifier: String, label: String,
                           help: String, titles: [String], action: Selector) {
        popUp.removeAllItems()
        popUp.addItems(withTitles: titles)
        popUp.target = self
        popUp.action = action
        register(popUp, identifier: identifier, label: label, help: help)
    }

    private func register(_ control: NSView, identifier: String, label: String, help: String) {
        control.setAccessibilityIdentifier(identifier)
        control.setAccessibilityLabel(label)
        control.setAccessibilityHelp(help)
        control.setAccessibilityElement(true)
    }

    private func row(_ title: String, _ views: NSView...) -> NSView {
        var members: [NSView] = []
        if !title.isEmpty {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.setAccessibilityElement(false)
            label.widthAnchor.constraint(equalToConstant: 96).isActive = true
            members.append(label)
        } else {
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: 96).isActive = true
            members.append(spacer)
        }
        members.append(contentsOf: views)
        let stack = NSStackView(views: members)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    // MARK: - State

    /// The configuration the editor is currently showing. For the workspace
    /// scope with no override yet, this is the INHERITED global value — the
    /// starting point an edit would fork from. Reading it writes nothing.
    var editedConfiguration: CanvasBackgroundConfiguration {
        switch scope {
        case .global:
            return environment.loadGlobal()
        case .workspace:
            return environment.loadWorkspace().overrideConfiguration ?? environment.loadGlobal()
        }
    }

    var workspaceState: WorkspaceCanvasBackground { environment.loadWorkspace() }

    /// Apply an edit to whichever scope is selected. Selecting the workspace
    /// scope alone establishes nothing; the first EDIT does, which is what makes
    /// "override" an explicit act.
    private func commit(_ transform: (inout CanvasBackgroundConfiguration) -> Void) {
        var config = editedConfiguration
        transform(&config)
        switch scope {
        case .global:
            qaGlobalWrites += 1
            environment.saveGlobal(config)
        case .workspace:
            guard environment.hasWorkspace else { return }
            qaWorkspaceWrites += 1
            environment.saveWorkspace(.override(config))
        }
        reload()
    }

    func reload() {
        let config = editedConfiguration
        let workspace = environment.loadWorkspace()

        scopePopUp.selectItem(at: scope.rawValue)
        inheritButton.isEnabled = scope == .workspace && workspace.isOverride && environment.hasWorkspace
        presetPopUp.selectItem(at: CanvasBackgroundPattern.allCases.firstIndex(of: config.pattern) ?? 0)

        let usesSystemBase = config.base == .systemDefault
        baseSystemCheckbox.state = usesSystemBase ? .on : .off
        baseColorWell.isEnabled = !usesSystemBase
        if let custom = config.base.customColor {
            baseColorWell.color = NSColor(cgColor: custom.cgColor) ?? baseColorWell.color
        }
        if let patternCustom = config.patternColor.customColor {
            patternColorWell.color = NSColor(cgColor: patternCustom.cgColor) ?? patternColorWell.color
        }
        patternColorWell.isEnabled = config.pattern.drawsGrid
        spacingSlider.isEnabled = config.pattern.drawsGrid
        spacingSlider.doubleValue = config.spacing
        spacingLabel.stringValue = "\(Int(config.spacing.rounded())) pt"

        let hasImage = config.image != nil
        removeImageButton.isEnabled = hasImage
        opacityPopUp.isEnabled = hasImage
        modePopUp.isEnabled = hasImage
        if let image = config.image {
            opacityPopUp.selectItem(at: CanvasBackgroundImageOpacity.allCases.firstIndex(of: image.opacity) ?? 2)
            modePopUp.selectItem(at: CanvasBackgroundImageMode.allCases.firstIndex(of: image.mode) ?? 0)
        }

        preview.setConfiguration(config)
        preview.updateCamera(viewport: CanvasViewport(x: 0, y: 0, zoom: 1))
        summaryLabel.stringValue = summaryText(config: config, workspace: workspace)
        summaryLabel.setAccessibilityValue(summaryLabel.stringValue)
    }

    /// The textual equivalent of the preview — the thing VoiceOver actually
    /// reads. It states the effective scope, not merely the selected one.
    func summaryText(config: CanvasBackgroundConfiguration, workspace: WorkspaceCanvasBackground) -> String {
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
        if let error = qaLastImportError { parts.append(error) }
        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    @objc private func scopeChanged() {
        scope = Scope(rawValue: scopePopUp.indexOfSelectedItem) ?? .global
        if scope == .workspace, !environment.hasWorkspace {
            scope = .global
            scopePopUp.selectItem(at: Scope.global.rawValue)
        }
        // Deliberately no write: changing what you are looking at is not an edit.
        reload()
    }

    @objc private func inheritTapped() {
        guard environment.hasWorkspace else { return }
        qaWorkspaceWrites += 1
        environment.saveWorkspace(.inherit)
        reload()
    }

    @objc private func presetChanged() {
        let pattern = CanvasBackgroundPattern.allCases[
            min(max(presetPopUp.indexOfSelectedItem, 0), CanvasBackgroundPattern.allCases.count - 1)]
        commit { $0.pattern = pattern }
    }

    @objc private func baseSystemChanged() {
        let useSystem = baseSystemCheckbox.state == .on
        let picked = exactRGBA(from: baseColorWell.color)
        commit { $0.base = useSystem ? .systemDefault : (picked.map { CanvasBackgroundColorSource.custom($0) } ?? .systemDefault) }
    }

    @objc private func baseColorChanged() {
        guard let rgba = exactRGBA(from: baseColorWell.color) else { return }
        commit { $0.base = .custom(rgba) }
    }

    @objc private func patternColorChanged() {
        guard let rgba = exactRGBA(from: patternColorWell.color) else { return }
        commit { $0.patternColor = .custom(rgba) }
    }

    @objc private func spacingChanged() {
        let value = spacingSlider.doubleValue
        commit { $0.spacing = CanvasBackgroundConfiguration.clampedSpacing(value) }
    }

    @objc private func chooseImageTapped() {
        qaLastImportError = nil
        // Cancel changes NOTHING — not the configuration, not the scope, not the
        // workspace's inherit/override state.
        guard let url = environment.chooseImageURL() else { reload(); return }
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
            qaLastImportError = "That image could not be used: \(error)."
            reload()
        }
    }

    @objc private func removeImageTapped() {
        // Clears the REFERENCE only. The managed file is left for the
        // reference-aware deferred sweep, because another workspace may still
        // name it and an undo may want it back.
        commit { $0.image = nil }
    }

    @objc private func opacityChanged() {
        let opacity = CanvasBackgroundImageOpacity.allCases[
            min(max(opacityPopUp.indexOfSelectedItem, 0), CanvasBackgroundImageOpacity.allCases.count - 1)]
        commit { $0.image?.opacity = opacity }
    }

    @objc private func modeChanged() {
        let mode = CanvasBackgroundImageMode.allCases[
            min(max(modePopUp.indexOfSelectedItem, 0), CanvasBackgroundImageMode.allCases.count - 1)]
        commit { $0.image?.mode = mode }
    }

    @objc private func resetTapped() {
        switch scope {
        case .global:
            qaGlobalWrites += 1
            environment.saveGlobal(.systemDefault)
        case .workspace:
            guard environment.hasWorkspace else { return }
            // Reset of a WORKSPACE is `.inherit`, not "an override that happens
            // to equal the default": the user asked for no local decision.
            qaWorkspaceWrites += 1
            environment.saveWorkspace(.inherit)
        }
        reload()
    }

    /// Exact sRGB components. `NSColorWell` can hand back a colour in any space
    /// (a catalogue colour, a P3 pick); converting once, here, is what makes
    /// "the colour you chose is the colour that is stored" true.
    private func exactRGBA(from color: NSColor) -> CanvasBackgroundRGBA? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return CanvasBackgroundRGBA(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent))
    }

    // MARK: - QA seams

    /// The real control chain, read from the view tree — so the declared
    /// `keyboardOrder` is checked against AppKit, not against itself.
    var qaKeyViewLoopIdentifiers: [String] {
        var result: [String] = []
        var cursor: NSView? = scopePopUp
        for _ in 0..<(Self.keyboardOrder.count + 1) {
            guard let view = cursor else { break }
            result.append(view.accessibilityIdentifier())
            cursor = view.nextKeyView
            if cursor === scopePopUp { break }
        }
        return result
    }

    struct ControlSnapshot: Equatable {
        var identifier: String
        var label: String
        var help: String
        var enabled: Bool
    }

    var qaControlSnapshots: [ControlSnapshot] {
        let controls: [NSView] = [
            scopePopUp, inheritButton, presetPopUp, baseSystemCheckbox, baseColorWell,
            patternColorWell, spacingSlider, chooseImageButton, removeImageButton,
            opacityPopUp, modePopUp, resetButton,
        ]
        return controls.map { view in
            ControlSnapshot(
                identifier: view.accessibilityIdentifier(),
                label: view.accessibilityLabel() ?? "",
                help: view.accessibilityHelp() ?? "",
                enabled: (view as? NSControl)?.isEnabled ?? true)
        }
    }

    var qaSummary: String { summaryLabel.stringValue }
    var qaPreviewIsAccessibilityIgnored: Bool { !preview.isAccessibilityElement() }
    var qaPreview: CanvasBackgroundRendererView { preview }

    // Test drivers — they invoke the SAME actions the controls do.
    func qaSelectScope(_ newScope: Scope) {
        scopePopUp.selectItem(at: newScope.rawValue)
        scopeChanged()
    }

    func qaSelectPattern(_ pattern: CanvasBackgroundPattern) {
        presetPopUp.selectItem(at: CanvasBackgroundPattern.allCases.firstIndex(of: pattern) ?? 0)
        presetChanged()
    }

    func qaSetBaseColor(_ color: NSColor) {
        baseSystemCheckbox.state = .off
        baseColorWell.color = color
        baseColorChanged()
    }

    func qaSetSpacing(_ value: Double) {
        spacingSlider.doubleValue = value
        spacingChanged()
    }

    func qaChooseImage() { chooseImageTapped() }
    func qaRemoveImage() { removeImageTapped() }
    func qaSetOpacity(_ opacity: CanvasBackgroundImageOpacity) {
        opacityPopUp.selectItem(at: CanvasBackgroundImageOpacity.allCases.firstIndex(of: opacity) ?? 2)
        opacityChanged()
    }
    func qaSetMode(_ mode: CanvasBackgroundImageMode) {
        modePopUp.selectItem(at: CanvasBackgroundImageMode.allCases.firstIndex(of: mode) ?? 0)
        modeChanged()
    }
    func qaInherit() { inheritTapped() }
    func qaReset() { resetTapped() }
}
