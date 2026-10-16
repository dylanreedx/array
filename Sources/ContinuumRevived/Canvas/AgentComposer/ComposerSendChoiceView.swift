import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// 2026-10-13 owner review — how a typed draft goes in while the agent works.
///
/// Replaces the permanent "↩ steer  ⌥↩ queue  ⌘↩ force send" line under the
/// draft. It exists only while there is a draft and a turn is working: Send
/// becomes the primary action for plain ↩'s default (steer, or queue on a
/// runtime that cannot steer), and a chevron beside it opens a menu naming
/// every way to send with its chord. Every route resolves through the same
/// `AgentComposerView.composerRequestedSend(_:modifier:)` the keys use, so a
/// click and a chord can never disagree.
///
/// A plain container: the primary is a `ComposerActionButton` (its own token
/// owner) and the chevron a `ComposerMenuChevronButton`.
@MainActor
final class ComposerSendChoiceView: NSView, AgentPageZoomScalable {
    struct Choice: Equatable {
        let modifier: AgentComposerSubmitModifier
        /// The primary's title when this choice is the default.
        let title: String
        /// The menu row, e.g. "Queue — after this turn".
        let menuTitle: String
        /// The chord as shown, e.g. "⌥↩".
        let chord: String
    }

    /// The choices a working turn's capabilities allow, default first — the
    /// same resolution `AgentComposerIntentState.workingDraftIntent` makes for
    /// each Return. Empty when plain ↩ would do nothing.
    static func choices(for capabilities: AgentTurnCapabilities) -> [Choice] {
        let steer = Choice(modifier: .plain, title: "Steer",
                           menuTitle: "Steer \u{2014} after the next tool call", chord: "\u{21A9}")
        let queue = Choice(modifier: capabilities.canSteer ? .queue : .plain, title: "Queue",
                           menuTitle: "Queue \u{2014} after this turn",
                           chord: capabilities.canSteer ? "\u{2325}\u{21A9}" : "\u{21A9}")
        let force = Choice(modifier: .forceSend, title: "Send now",
                           menuTitle: "Interrupt and send now", chord: "\u{2318}\u{21A9}")
        var result: [Choice] = []
        if capabilities.canSteer { result.append(steer) }
        if capabilities.canQueue { result.append(queue) }
        guard !result.isEmpty else { return [] }
        if capabilities.canStop { result.append(force) }
        return result
    }

    private(set) var choices: [Choice] = []
    private(set) var pageZoom: AgentPageZoom = .default
    let primaryButton: ComposerActionButton
    let menuButton = ComposerMenuChevronButton(frame: .zero)
    private let choiceMenu = NSMenu()
    /// Called with the Return the user picked; the owner submits the draft.
    var onChoose: ((AgentComposerSubmitModifier) -> Void)?

    override init(frame frameRect: NSRect) {
        primaryButton = ComposerActionButton(presentation: Self.presentation(for: nil))
        super.init(frame: frameRect)
        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed(_:))
        primaryButton.setContentHuggingPriority(.required, for: .horizontal)
        primaryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        menuButton.target = self
        menuButton.action = #selector(menuPressed(_:))
        choiceMenu.autoenablesItems = false
        addSubview(primaryButton)
        addSubview(menuButton)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setChoices(_ newChoices: [Choice]) {
        guard newChoices != choices else { return }
        choices = newChoices
        primaryButton.presentation = Self.presentation(for: newChoices.first)
        if let first = newChoices.first {
            primaryButton.toolTip = "\(first.menuTitle) (\(first.chord))"
        }
        choiceMenu.removeAllItems()
        for (index, choice) in newChoices.enumerated() {
            let item = NSMenuItem(title: choice.menuTitle, action: #selector(menuItemChosen(_:)), keyEquivalent: "\r")
            item.keyEquivalentModifierMask = switch choice.chord {
            case "\u{2325}\u{21A9}": [.option]
            case "\u{2318}\u{21A9}": [.command]
            default: []
            }
            item.target = self
            item.tag = index
            choiceMenu.addItem(item)
        }
        menuButton.isHidden = newChoices.count < 2
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private static func presentation(for choice: Choice?) -> AgentComposerPresentation {
        AgentComposerPresentation(
            primaryAction: .send,
            title: choice?.title ?? "Send",
            symbolName: "arrow.up",
            accessibilityLabel: choice.map { "\($0.menuTitle), \($0.chord == "\u{21A9}" ? "Return" : $0.chord)" } ?? "Send prompt",
            isEnabled: choice != nil,
            isLoading: false,
            secondaryActions: [])
    }

    private var gap: CGFloat { CGFloat(pageZoom.scaled(Space.xs)) }

    override var intrinsicContentSize: NSSize {
        let primary = primaryButton.intrinsicContentSize
        let menuWidth = menuButton.isHidden ? 0 : menuButton.intrinsicContentSize.width + gap
        return NSSize(width: primary.width + menuWidth, height: primary.height)
    }

    /// No measurement here (performance.md): the chevron is a square of the
    /// row height and the primary takes the rest of the width Auto Layout gave.
    override func layout() {
        super.layout()
        let menuWidth = menuButton.isHidden ? 0 : bounds.height
        let primaryWidth = max(0, bounds.width - (menuButton.isHidden ? 0 : menuWidth + gap))
        primaryButton.frame = NSRect(x: 0, y: 0, width: primaryWidth, height: bounds.height)
        menuButton.frame = NSRect(x: primaryWidth + gap, y: 0, width: menuWidth, height: bounds.height)
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func primaryPressed(_ sender: Any?) {
        guard let first = choices.first else { return }
        onChoose?(first.modifier)
    }

    @objc private func menuPressed(_ sender: Any?) {
        guard choices.count > 1 else { return }
        choiceMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.height + gap), in: menuButton)
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard choices.indices.contains(sender.tag) else { return }
        onChoose?(choices[sender.tag].modifier)
    }

    // MARK: - QA seams

    /// The primary's title and each menu row as "title  chord".
    var qaPrimaryTitle: String { primaryButton.presentation.title }
    var qaMenuRows: [String] {
        choiceMenu.items.enumerated().map { index, item in
            "\(item.title)  \(choices.indices.contains(index) ? choices[index].chord : "?")"
        }
    }

    /// Picks `modifier` through the real control: the primary button's own
    /// action when it is the default, else the menu item's own action.
    func qaChoose(_ modifier: AgentComposerSubmitModifier) -> Bool {
        if choices.first?.modifier == modifier {
            return primaryButton.sendAction(primaryButton.action, to: primaryButton.target)
        }
        guard let index = choices.firstIndex(where: { $0.modifier == modifier }),
              index < choiceMenu.items.count else { return false }
        choiceMenu.performActionForItem(at: index)
        return true
    }
}

/// The chevron half of the busy send choice: a quiet square in the composer's
/// own fill and control boundary, so the accent stays on the default action.
@MainActor
final class ComposerMenuChevronButton: NSControl, TokenThemed, AgentPageZoomScalable {
    private let iconView = NSImageView(frame: .zero)
    private var isPressed = false
    private(set) var pageZoom: AgentPageZoom = .default

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        iconView.imageScaling = .scaleNone
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel("More ways to send")
        toolTip = "More ways to send"
        applyPageZoom(.default)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let side = ComposerActionButton.controlHeight(zoom: pageZoom)
        return NSSize(width: side, height: side)
    }

    override func layout() {
        super.layout()
        let side = CGFloat(pageZoom.scaled(12))
        iconView.frame = NSRect(
            x: floor((bounds.width - side) / 2), y: floor((bounds.height - side) / 2), width: side, height: side)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyTokens()
        defer {
            isPressed = false
            applyTokens()
        }
        _ = sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 125 {
            _ = sendAction(action, to: target)
        } else {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        applyTokens()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        applyTokens()
        return accepted
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        let focused = window?.firstResponder === self
        layer?.backgroundColor = AgentSurfaceRole.composer.color.cgColor(for: theme)
        // One hairline in both states; keyboard focus is the focus-ring colour.
        layer?.borderWidth = CGFloat(LineWidth.hairline)
        layer?.borderColor = (focused ? AgentLineRole.focusRing : .controlBoundary).color.cgColor(for: theme)
        iconView.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        alphaValue = isPressed ? 0.78 : 1
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.cornerRadius = CGFloat(zoom.scaled(Radius.card))
        iconView.image = CanvasSymbolImage.image(named: "chevron.down", pointSize: CGFloat(zoom.scaled(10)), weight: .regular)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}
