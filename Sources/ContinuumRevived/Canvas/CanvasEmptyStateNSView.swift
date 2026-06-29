import AppKit

@MainActor
struct CanvasEmptyStateActions {
    struct RecentProject {
        let title: String
        let action: () -> Void
    }

    let spawnClaude: () -> Void
    let spawnShell: () -> Void
    let spawnBrowser: () -> Void
    let openInEditor: () -> Void
    let addProjectToCanvas: (() -> Void)?
    let recentProjects: [RecentProject]

    init(
        spawnClaude: @escaping () -> Void,
        spawnShell: @escaping () -> Void,
        spawnBrowser: @escaping () -> Void,
        openInEditor: @escaping () -> Void,
        addProjectToCanvas: (() -> Void)? = nil,
        recentProjects: [RecentProject] = []
    ) {
        self.spawnClaude = spawnClaude
        self.spawnShell = spawnShell
        self.spawnBrowser = spawnBrowser
        self.openInEditor = openInEditor
        self.addProjectToCanvas = addProjectToCanvas
        self.recentProjects = recentProjects
    }
}

@MainActor
final class CanvasEmptyStateNSView: NSView {
    var actions: CanvasEmptyStateActions? {
        didSet { rebuildStack() }
    }
    var projectPath: String? {
        didSet { projectPathLabel.stringValue = projectPath ?? "" }
    }

    private let stack = NSStackView()
    private let card = NSView()
    private let projectPathLabel = NSTextField(labelWithString: "")
    private var recentProjectButtons: [NSButton] = []

    private static let cardInset: CGFloat = 30

    init(actions: CanvasEmptyStateActions?, projectPath: String? = nil) {
        self.actions = actions
        self.projectPath = projectPath
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        // Scrim: dim whatever is behind so the launch card reads as the single
        // focal element instead of bleeding into the canvas / zones underneath.
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        setAccessibilityIdentifier("ContinuumEmptyState")
        setupStack()
        projectPathLabel.stringValue = projectPath ?? ""
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = Self.cardInset
        let fit = stack.fittingSize
        let cardSize = NSSize(width: fit.width + inset * 2, height: fit.height + inset * 2)
        card.frame = NSRect(
            x: floor((bounds.width - cardSize.width) / 2),
            y: floor((bounds.height - cardSize.height) / 2),
            width: cardSize.width,
            height: cardSize.height
        )
        stack.frame = NSRect(x: inset, y: inset, width: fit.width, height: fit.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Stay click-through everywhere except the action buttons, so the canvas
        // beneath keeps receiving background clicks. Delegate to `super` for the
        // actual resolution: it converts `point` (delivered in this view's
        // superview space) and recurses correctly. The previous hand-rolled
        // conversion double-subtracted the centered stack's origin, shifting
        // every button's hit region off-screen — buttons were unclickable.
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : nil
    }

    private func setupStack() {
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        addSubview(card)

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = true
        card.addSubview(stack)
        rebuildStack()
    }

    private func rebuildStack() {
        guard stack.superview != nil else { return }
        recentProjectButtons = []
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stack.addArrangedSubview(makeIdentityGroup())
        stack.addArrangedSubview(makePaletteHint())
        stack.addArrangedSubview(makeActionGroup())
        stack.addArrangedSubview(makeFooter())
        needsLayout = true
    }

    private func makeIdentityGroup() -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .centerX
        group.spacing = 6
        group.translatesAutoresizingMaskIntoConstraints = false

        let wordmark = NSTextField(labelWithString: "CONTINUUM")
        wordmark.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        wordmark.textColor = NSColor.white.withAlphaComponent(0.9)
        wordmark.alignment = .center

        projectPathLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        projectPathLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        projectPathLabel.alignment = .center
        projectPathLabel.lineBreakMode = .byTruncatingMiddle
        projectPathLabel.maximumNumberOfLines = 1

        group.addArrangedSubview(wordmark)
        group.addArrangedSubview(projectPathLabel)
        NSLayoutConstraint.activate([
            group.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            projectPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        return group
    }

    private func makePaletteHint() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let keycap = NSTextField(labelWithString: "⌘K")
        keycap.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        keycap.textColor = NSColor.white.withAlphaComponent(0.92)
        keycap.alignment = .center
        keycap.wantsLayer = true
        keycap.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        keycap.layer?.borderWidth = 1
        keycap.layer?.cornerRadius = 5
        keycap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        NSLayoutConstraint.activate([
            keycap.widthAnchor.constraint(equalToConstant: 42),
            keycap.heightAnchor.constraint(equalToConstant: 24)
        ])

        let text = NSTextField(labelWithString: "open the command palette")
        text.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        text.textColor = NSColor.white.withAlphaComponent(0.75)

        row.addArrangedSubview(keycap)
        row.addArrangedSubview(text)
        return row
    }

    private func makeActionGroup() -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .centerX
        group.spacing = 8
        group.translatesAutoresizingMaskIntoConstraints = false
        if actions?.addProjectToCanvas != nil || !(actions?.recentProjects.isEmpty ?? true) {
            group.addArrangedSubview(makeButton(title: "Add Project to Canvas", action: #selector(addProjectToCanvas)))
            for (index, project) in (actions?.recentProjects ?? []).prefix(3).enumerated() {
                let button = makeButton(title: "Recent: \(project.title)", action: #selector(openRecentProject(_:)))
                button.tag = index
                recentProjectButtons.append(button)
                group.addArrangedSubview(button)
            }
        }
        group.addArrangedSubview(makeButton(title: "New Claude Terminal   ⌘1", action: #selector(spawnClaude)))
        group.addArrangedSubview(makeButton(title: "New Shell Terminal    ⌘2", action: #selector(spawnShell)))
        group.addArrangedSubview(makeButton(title: "New Browser           ⌘3", action: #selector(spawnBrowser)))
        group.addArrangedSubview(makeButton(title: "Open in Nvim          ⌘4", action: #selector(openInEditor)))
        return group
    }

    private func makeFooter() -> NSView {
        let footer = NSTextField(labelWithString: "notes, files, and projects live in ⌘K")
        footer.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        footer.textColor = NSColor.white.withAlphaComponent(0.35)
        footer.alignment = .center
        return footer
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = LaunchActionButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 320),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
        return button
    }

    struct QASnapshot: Equatable {
        let accessibilityIdentifier: String?
        let buttonTitles: [String]
        let text: [String]
    }

    func qaSnapshot() -> QASnapshot {
        QASnapshot(
            accessibilityIdentifier: accessibilityIdentifier(),
            buttonTitles: collectSubviews(of: self, as: NSButton.self).map { $0.attributedTitle.string },
            text: collectSubviews(of: self, as: NSTextField.self).map(\.stringValue)
        )
    }

    func qaPressButton(titled title: String) -> Bool {
        guard let button = collectSubviews(of: self, as: NSButton.self).first(where: { $0.attributedTitle.string == title }) else { return false }
        button.performClick(nil)
        return true
    }

    /// Real-path check: a click at the visual center of each action button must
    /// resolve — through `hitTest` (the point arrives in the receiver's SUPERVIEW
    /// space, as AppKit delivers it) — to that exact button, and firing it must
    /// run its action. Reproduces the "empty-state buttons are unclickable" bug:
    /// the inner stack is centered, so the old override double-subtracted its
    /// origin and shifted every hit region off the buttons.
    @MainActor
    static func runHitTestSelfCheck() throws {
        func fail(_ message: String) -> Error {
            NSError(domain: "EmptyStateHitTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        final class FlippedHost: NSView { override var isFlipped: Bool { true } }

        var fired: Set<String> = []
        let actions = CanvasEmptyStateActions(
            spawnClaude: { fired.insert("claude") },
            spawnShell: { fired.insert("shell") },
            spawnBrowser: { fired.insert("browser") },
            openInEditor: { fired.insert("editor") },
            addProjectToCanvas: { fired.insert("addProject") },
            recentProjects: [.init(title: "demo", action: { fired.insert("recent") })]
        )
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        let view = CanvasEmptyStateNSView(actions: actions, projectPath: "/tmp/demo")
        view.frame = host.bounds
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        let buttons = view.collectSubviews(of: view, as: NSButton.self)
        guard !buttons.isEmpty else { throw fail("no action buttons rendered") }
        for button in buttons {
            let centerInSelf = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: view)
            // hitTest is delivered a point in the receiver's superview space:
            let pointForHitTest = view.convert(centerInSelf, to: host)
            let hit = view.hitTest(pointForHitTest)
            guard let hitButton = hit as? NSButton, hitButton === button else {
                throw fail("click at center of '\(button.title)' resolved to \(String(describing: hit)) — expected that button (empty-state buttons unclickable)")
            }
            hitButton.performClick(nil)
        }
        guard fired.contains("shell"), fired.contains("claude"), fired.contains("recent") else {
            throw fail("resolved buttons did not fire their actions: \(fired.sorted())")
        }
    }

    private func collectSubviews<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            var matches: [T] = []
            if let typed = subview as? T { matches.append(typed) }
            matches.append(contentsOf: collectSubviews(of: subview, as: type))
            return matches
        }
    }

    @objc private func spawnClaude() {
        actions?.spawnClaude()
    }

    @objc private func spawnShell() {
        actions?.spawnShell()
    }

    @objc private func spawnBrowser() {
        actions?.spawnBrowser()
    }

    @objc private func openInEditor() {
        actions?.openInEditor()
    }

    @objc private func addProjectToCanvas() {
        actions?.addProjectToCanvas?()
    }

    @objc private func openRecentProject(_ sender: NSButton) {
        guard let project = actions?.recentProjects[safe: sender.tag] else { return }
        project.action()
    }
}

/// A legible, command-palette-style action row: monospace label on a subtle
/// fill that brightens on hover. Replaces the default dark rounded bezel, which
/// rendered near-invisible against the dark canvas. The visible string is driven
/// via `attributedTitle` (so its `.string` stays exactly the action label — QA
/// and the empty-state self-check match on it), with left padding from the
/// paragraph indent rather than baked-in spaces.
private final class LaunchActionButton: NSButton {
    private static let resting = NSColor.white.withAlphaComponent(0.06)
    private static let hover = NSColor.white.withAlphaComponent(0.14)

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = Self.resting.cgColor
        focusRingType = .none

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.firstLineHeadIndent = 14
        paragraph.headIndent = 14
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .paragraphStyle: paragraph
        ])
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Act on the first click even when the window isn't key (the empty state
    // often appears on an unfocused canvas).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Self.hover.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = Self.resting.cgColor }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
