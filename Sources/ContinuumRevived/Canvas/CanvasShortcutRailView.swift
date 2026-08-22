import AppKit
import ContinuumRevivedCore

/// A compact, permanent recognition-over-recall surface. It shows only the
/// canvas controls a new user needs; the complete editable list stays in
/// Settings → Keybindings.
@MainActor
final class CanvasShortcutRailView: NSView {
    var onOpenCommandCenter: (() -> Void)?
    var onOpenKeybindings: (() -> Void)?

    private let stack = NSStackView()
    private let commandButton = NSButton()
    private let quickJumpLabel = NSTextField(labelWithString: "")
    private let navModeLabel = NSTextField(labelWithString: "")
    private let shortcutsButton = NSButton(title: "Settings › Shortcuts", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("ArrayCanvasShortcutRail")

        for label in [quickJumpLabel, navModeLabel] {
            label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        for button in [commandButton, shortcutsButton] {
            button.isBordered = false
            button.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
        }
        commandButton.target = self
        commandButton.action = #selector(openCommandCenter(_:))
        shortcutsButton.target = self
        shortcutsButton.action = #selector(openKeybindings(_:))
        shortcutsButton.image = CanvasSymbolImage.image(named: "gearshape")
        shortcutsButton.imagePosition = .imageLeading
        shortcutsButton.imageScaling = .scaleProportionallyDown
        shortcutsButton.toolTip = "Open Settings → Keybindings"
        shortcutsButton.setAccessibilityLabel("Open shortcuts in Settings")
        shortcutsButton.setAccessibilityHelp("Opens Settings → Keybindings")

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [commandButton, quickJumpLabel, navModeLabel, shortcutsButton] {
            stack.addArrangedSubview(view)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyAppearance()
        reloadBindings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func reloadBindings(defaults: UserDefaults = .standard, navKeymap: NavKeymap = .resolve()) {
        let commandDisplay: String?
        if let registry = try? CommandRegistry.productRegistry(),
           let definition = registry.shortcuts.first(where: { $0.commandID == "app.commandCenter" }) {
            let gestures = ShortcutBindingStore(defaults: defaults).gestures(for: definition)
            commandDisplay = gestures.first?.displayString
        } else {
            commandDisplay = "⌘K"
        }
        commandButton.title = commandDisplay.map { "\($0)  Add" } ?? "Add"
        commandButton.toolTip = commandDisplay.map { "Open Command Center (\($0))" }
            ?? "Open Command Center"
        commandButton.setAccessibilityLabel(commandDisplay.map { "Add with \($0)" } ?? "Add")

        let hold = Self.modifierDisplay(navKeymap.leaderHoldModifier)
        quickJumpLabel.stringValue = "\(hold)  Quick Jump"
        quickJumpLabel.setAccessibilityLabel("Hold \(hold) for Quick Jump")
        navModeLabel.stringValue = "\(navKeymap.leader.displayString)  Navigate"
        navModeLabel.setAccessibilityLabel("\(navKeymap.leader.displayString) Navigation Mode")
        isHidden = !CanvasShortcutRailConfig.isVisible(defaults: defaults)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        stack.fittingSize
    }

    private func applyAppearance() {
        // The rail is deliberately uncontained canvas annotation: no panel fill,
        // perimeter, separators, or accent color competing with the workspace.
        layer?.backgroundColor = nil
        layer?.borderWidth = 0
        for label in [quickJumpLabel, navModeLabel] {
            label.textColor = .secondaryLabelColor
        }
        for button in [commandButton, shortcutsButton] {
            button.contentTintColor = .secondaryLabelColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private static func modifierDisplay(_ modifiers: FocusKeyModifiers) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result.isEmpty ? "key" : result
    }

    @objc private func openCommandCenter(_ sender: NSButton) { onOpenCommandCenter?() }
    @objc private func openKeybindings(_ sender: NSButton) { onOpenKeybindings?() }
}
