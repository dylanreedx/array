import AppKit
import ContinuumRevivedAgentUI

// Plan: .plans/87-sidebar-liveness/README.md (quick hide/show, Dylan 2026-10-27)
//
// THE TOGGLE PILLS under the sidebar's search field: one per workspace (its
// colour dot) and one per outside source (its app glyph), each with a count of
// the top-level agents it holds. They are the scope popover's workspace set and
// the source set (`InboxSource`) laid side by side — not a second filter. Click
// toggles, Option-click solos; what does not fit on the line folds into `+N`,
// which opens the rest as the shared checklist.

/// One pill's facts, built by `AgentInboxView` from the rows and both filters.
struct InboxFilterPillModel: Equatable {
    enum Kind: Equatable {
        case workspace(UUID)
        case source(String)
    }

    let kind: Kind
    let title: String
    /// A workspace's colour; nil for a source.
    let swatch: NSColor?
    /// A source's app glyph; nil for a workspace.
    let symbol: String?
    /// Top-level live agents (`InboxTally`).
    let count: Int
    let isOn: Bool
    /// Off, and something it hides needs you.
    let attention: Bool

    var id: String {
        switch kind {
        case .workspace(let id): return "workspace:\(id.uuidString.lowercased())"
        case .source(let name): return "source:\(name)"
        }
    }
}

/// One pill. Paints its fill from tokens (`rowSelected` when on, nothing when
/// off, the control ladder's pressed step under a press) and draws its dots.
///
/// A VIEW THAT TRACKS ITS OWN PRESS rather than an `NSButton`: the press acts on
/// mouse-up inside, with the modifier flags of the press, so Option-click is read
/// off the event that made it and never off `NSApp.currentEvent`.
@MainActor
final class InboxFilterPill: NSView, TokenThemed {
    static let height: CGFloat = 24
    static let padding: CGFloat = 8
    private static let dotSide: CGFloat = 8
    private static let attentionSide: CGFloat = 6
    private static let iconSide: CGFloat = 13

    private(set) var model: InboxFilterPillModel?
    /// `+N`: the overflow pill.
    private(set) var moreCount = 0
    private var attention = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private(set) var isPressed = false {
        didSet { if oldValue != isPressed { applyTokens() } }
    }
    private var pressFlags: NSEvent.ModifierFlags = []
    var onPress: ((NSEvent.ModifierFlags) -> Void)?

    init(model: InboxFilterPillModel) {
        self.model = model
        attention = model.attention
        super.init(frame: .zero)
        setUp()
    }

    init(more count: Int, attention: Bool) {
        moreCount = count
        self.attention = attention
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    private var isOn: Bool { model?.isOn ?? true }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        let size = NSFont.token(.caption).pointSize
        titleLabel.font = .systemFont(ofSize: size, weight: .medium)
        countLabel.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        titleLabel.stringValue = model?.title ?? "+\(moreCount)"
        countLabel.stringValue = model.map { "\($0.count)" } ?? ""
        countLabel.isHidden = model == nil
        if let symbol = model?.symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        }
        icon.isHidden = model?.symbol == nil
        icon.imageScaling = .scaleProportionallyDown
        for view in [icon, titleLabel, countLabel] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if let model {
            setAccessibilityIdentifier("ContinuumAgentInboxPill:\(model.id)")
            setAccessibilityLabel("\(model.title), \(model.count == 1 ? "1 agent" : "\(model.count) agents")")
            setAccessibilityHelp("Click shows or hides; Option-click shows only this")
        } else {
            setAccessibilityIdentifier("ContinuumAgentInboxPill:more")
            setAccessibilityLabel("\(moreCount) more")
            setAccessibilityHelp("Lists the rest")
        }
        setAccessibilityValue((isOn ? "on" : "off") + (attention ? ", needs you" : ""))
        toolTip = model.map { $0.isOn ? "Hide \($0.title)" : "Show \($0.title)" }
        applyTokens()
    }

    private var leadWidth: CGFloat {
        if model?.swatch != nil { return Self.dotSide + 5 }
        if model?.symbol != nil { return Self.iconSide + 4 }
        return 0
    }

    var fittingWidth: CGFloat {
        var width = Self.padding + leadWidth + ceil(titleLabel.intrinsicContentSize.width) + 2
        if model != nil { width += 4 + ceil(countLabel.intrinsicContentSize.width) + 2 }
        if attention { width += 4 + Self.attentionSide }
        return width + Self.padding
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = Self.padding
        if model?.symbol != nil {
            icon.frame = NSRect(x: x, y: (h - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
        }
        x += leadWidth
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: x, y: floor((h - titleSize.height) / 2),
                                  width: ceil(titleSize.width) + 2, height: titleSize.height)
        x += ceil(titleSize.width) + 2 + 4
        let countSize = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(x: x, y: floor((h - countSize.height) / 2),
                                  width: ceil(countSize.width) + 2, height: countSize.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// On wears the selected-row fill; off is bare, faded text. Resting off
    /// paints nil, never `.clear`.
    func applyTokens() {
        layer?.cornerRadius = Self.height / 2
        if isPressed {
            layer?.backgroundColor = SidebarControlRole.pressed.color.cgColor(in: self)
        } else {
            layer?.backgroundColor = isOn ? AgentSurfaceRole.rowSelected.color.cgColor(in: self) : nil
        }
        let secondary = TextToken.textSecondary.color.nsColor(in: self)
        titleLabel.textColor = isOn ? TextToken.textPrimary.color.nsColor(in: self) : secondary
        countLabel.textColor = secondary
        icon.contentTintColor = secondary
        let faded: CGFloat = isOn ? 1 : 0.55
        for view in [titleLabel, countLabel, icon] as [NSView] { view.alphaValue = faded }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let h = bounds.height
        if let dot = model?.swatch {
            let rect = NSRect(x: Self.padding, y: (h - Self.dotSide) / 2, width: Self.dotSide, height: Self.dotSide)
            if isOn {
                dot.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                // Off: the workspace's colour as a hollow ring.
                dot.withAlphaComponent(0.7).setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
        if attention {
            AccentToken.accentApproval.color.nsColor(in: self).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - Self.padding - Self.attentionSide,
                                        y: (h - Self.attentionSide) / 2,
                                        width: Self.attentionSide, height: Self.attentionSide)).fill()
        }
    }

    // MARK: Press

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressFlags = event.modifierFlags
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onPress?(pressFlags.union(event.modifierFlags.intersection(.option))) }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?([])
        return onPress != nil
    }
}

/// The pills on ONE line, in the order they are given; what does not fit folds
/// into a trailing `+N`. Paints nothing itself.
@MainActor
final class InboxFilterPillStrip: NSView {
    static let gap: CGFloat = 4

    var pills: [InboxFilterPillModel] = [] {
        didSet { if pills != oldValue { needsRebuild = true; needsLayout = true } }
    }
    var onPress: ((InboxFilterPillModel, NSEvent.ModifierFlags) -> Void)?
    /// `+N` was pressed; the rect is the pill's, in this view.
    var onMore: ((NSRect) -> Void)?

    /// The pills that did not fit, in order.
    private(set) var overflowed: [InboxFilterPillModel] = []
    private(set) var pillViews: [InboxFilterPill] = []
    private(set) var moreView: InboxFilterPill?
    private var needsRebuild = true
    private var builtWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard needsRebuild || builtWidth != bounds.width else { return }
        needsRebuild = false
        builtWidth = bounds.width
        (pillViews + [moreView].compactMap { $0 }).forEach { $0.removeFromSuperview() }
        let all = pills.map(InboxFilterPill.init(model:))
        let widths = all.map(\.fittingWidth)
        func moreWidth(_ rest: ArraySlice<InboxFilterPillModel>) -> CGFloat {
            InboxFilterPill(more: rest.count, attention: rest.contains(where: \.attention)).fittingWidth
        }
        func total(_ count: Int) -> CGFloat {
            var sum = widths.prefix(count).reduce(0, +) + CGFloat(max(0, count - 1)) * Self.gap
            if count < all.count { sum += Self.gap + moreWidth(pills[count...]) }
            return sum
        }
        var shown = all.count
        while shown > 0 && total(shown) > bounds.width { shown -= 1 }
        overflowed = Array(pills[shown...])
        var x: CGFloat = 0
        pillViews = []
        for (index, view) in all.prefix(shown).enumerated() {
            view.frame = NSRect(x: x, y: 0, width: widths[index], height: InboxFilterPill.height)
            let model = pills[index]
            view.onPress = { [weak self] flags in self?.onPress?(model, flags) }
            addSubview(view)
            pillViews.append(view)
            x += widths[index] + Self.gap
        }
        moreView = nil
        if !overflowed.isEmpty {
            let more = InboxFilterPill(more: overflowed.count, attention: overflowed.contains(where: \.attention))
            more.frame = NSRect(x: x, y: 0, width: more.fittingWidth, height: InboxFilterPill.height)
            more.onPress = { [weak self, weak more] _ in
                guard let self, let more else { return }
                self.onMore?(more.frame)
            }
            addSubview(more)
            moreView = more
        }
        setAccessibilityChildren((pillViews + [moreView].compactMap { $0 }) as [Any])
    }
}

extension AgentInboxView {
    /// The inbox with its pill row showing, for the appearance census: two
    /// workspaces (on, painting `rowSelected`) and an outside source turned off
    /// (painting nothing). Fixed clock and ids, so the render never flaps.
    static func pillsPreviewForProbe() -> AgentInboxView {
        let view = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        view.clock = { LabFixtures.inboxNow }
        let array = UUID(uuidString: "00000000-0000-0000-0000-00000000A701")!
        let film = UUID(uuidString: "00000000-0000-0000-0000-00000000A702")!
        view.scopeCatalog = [.workspaceID(array, "Array"), .workspaceID(film, "Film")]
        view.workspaceColourNames = [array: "blue", film: "orange"]
        view.reload(rows: [
            AgentInboxRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A711")!,
                          title: "Make sidebar subagents live", projectName: "Array", workspaceName: "Array",
                          workspaceId: array, state: .working, createdAt: LabFixtures.inboxNow),
            AgentInboxRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A712")!,
                          title: "Render the dictation film master", projectName: "film", workspaceName: "Film",
                          workspaceId: film, state: .ready, createdAt: LabFixtures.inboxNow),
            AgentInboxRow(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A713")!,
                          title: "Bump GRDB and fix warnings", projectName: "Array", workspaceName: "Array",
                          workspaceId: array, state: .input, createdAt: LabFixtures.inboxNow,
                          whereMarker: InboxWhereMarker(symbol: "terminal", text: "cmux"),
                          externalSession: InboxExternalSession(sessionKey: "probe:cmux", isProminent: true,
                                                                canMoveHere: false, canCopy: false, source: "cmux")),
        ])
        view.setHiddenSources(["cmux"])
        view.layoutForQA()
        return view
    }
}

/// `Hidden (N)` pinned under the sidebar's list (.plans/87): the shelf heading's
/// own view, and — while open — a `Show all` pill at the trailing edge. Paints
/// nothing itself; the heading and the pill are already on the census.
@MainActor
final class InboxHiddenFooter: NSView {
    static let height: CGFloat = 36
    private let header = AgentInboxShelfHeaderView()
    private let showAll = InboxSettleNudgeButton(frame: .zero)
    var onToggle: (() -> Void)?
    var onShowAll: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Hidden sessions")
        setAccessibilityIdentifier("ContinuumAgentInboxHiddenFooter")
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onToggle = { [weak self] in self?.onToggle?() }
        showAll.translatesAutoresizingMaskIntoConstraints = false
        showAll.title = "Show all"
        showAll.font = .systemFont(ofSize: Typography.style(for: .label).size, weight: .medium)
        showAll.target = self
        showAll.action = #selector(showAllPressed)
        showAll.setAccessibilityLabel("Show all")
        showAll.setAccessibilityIdentifier("ContinuumAgentInboxHiddenShowAll")
        showAll.isHidden = true
        addSubview(header)
        addSubview(showAll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.bottomAnchor.constraint(equalTo: bottomAnchor),
            showAll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Inset.row.right - 4),
            showAll.centerYAnchor.constraint(equalTo: centerYAnchor),
            showAll.heightAnchor.constraint(equalToConstant: InboxSettleNudgeButton.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(count: Int, expanded: Bool) {
        header.apply(section: .hidden, count: count, isExpanded: expanded)
        showAll.isHidden = !expanded
        setAccessibilityChildren(expanded ? [header, showAll] : [header])
    }

    @objc private func showAllPressed() { onShowAll?() }

    var titleForQA: String { header.qaTitle }
}
