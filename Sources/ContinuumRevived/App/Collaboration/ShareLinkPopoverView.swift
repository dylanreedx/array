import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// The one share popover (IN-CANVAS.md round 2, panels 1, 4 and 5): what goes,
/// the link with its editable slug, Copy, how long the link lives, who has
/// access, and Revoke. Hosted by `ChoicePopoverController.presentContent`.
///
/// The surface and the avatar dots are drawn, not layer colours: every colour
/// here resolves from a token at draw time.
@MainActor
final class ShareLinkPopoverView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 360
    private static let inset = CGFloat(Space.xl)
    private static let maxListedItems = 5

    let session: ShareLinkSession
    /// The popover asks its host to refit after the content changes height.
    var onResize: ((NSSize) -> Void)?
    var onDismiss: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var itemLabels: [NSTextField] = []
    private var itemIcons: [NSImageView] = []
    private let prefixLabel = NSTextField(labelWithString: ShareLinkURL.webPrefix)
    let slugField = NSTextField(string: "")
    private let usedLabel = NSTextField(labelWithString: "Used")
    let copyButton = ComposerActionButton(presentation: ShareLinkPopoverView.copyPresentation(title: "Copy link", symbol: "link", enabled: true))
    private let lifetimeLabel = NSTextField(labelWithString: "Link")
    let lifetimeChoice = ChoiceButton(title: Collaboration.ShareLinkLifetime.once.title)
    private let lifetimeDetail = NSTextField(wrappingLabelWithString: "")
    private let peopleHeader = NSTextField(labelWithString: "PEOPLE WITH ACCESS")
    private var personLabels: [(name: NSTextField, detail: NSTextField)] = []
    private(set) var removeButtons: [ChoiceAccessoryButton] = []
    var titleLabelText: String { titleLabel.stringValue }
    /// Each person row as drawn: "Sam · opened 10:48 · full access".
    var qaItemRows: [String] { itemLabels.map(\.stringValue) }
    var qaPeopleRows: [String] { personLabels.map { $0.name.stringValue + " · " + $0.detail.stringValue } }
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// "Revoke link" until someone has access, then "Revoke everyone's access".
    let revokeButton = ChoiceAccessoryButton(accessory: .init(id: "revoke", title: "Revoke link", symbol: nil, accessibilityLabel: "Revoke link"))
    let revokeEveryoneButton = ChoiceAccessoryButton(accessory: .init(id: "revokeEveryone", title: "Revoke everyone's access",
                                                                      symbol: nil, accessibilityLabel: "Revoke everyone's access"))
    private var fieldRect: NSRect = .zero
    private var avatarRects: [NSRect] = []

    init(session: ShareLinkSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.container)
        layer?.masksToBounds = true
        titleLabel.font = .token(.title)
        subtitleLabel.font = .token(.caption)
        subtitleLabel.maximumNumberOfLines = 3
        prefixLabel.font = .token(.label)
        slugField.font = .token(.label)
        slugField.isBordered = false
        slugField.drawsBackground = false
        slugField.focusRingType = .none
        slugField.lineBreakMode = .byTruncatingTail
        slugField.cell?.isScrollable = true
        slugField.delegate = self
        slugField.setAccessibilityLabel("Link name")
        usedLabel.font = .token(.caption)
        copyButton.target = self
        copyButton.action = #selector(copyPressed(_:))
        lifetimeLabel.font = .token(.caption)
        lifetimeChoice.items = Collaboration.ShareLinkLifetime.allCases.map { ChoiceItem(id: $0.rawValue, title: $0.title, detail: $0.detail) }
        lifetimeChoice.selectedID = session.lifetime.rawValue
        lifetimeChoice.setAccessibilityLabel("Link lifetime")
        lifetimeChoice.onSelection = { [weak self] item in
            guard let self, let lifetime = Collaboration.ShareLinkLifetime(rawValue: item.id) else { return }
            Task { await self.session.setLifetime(lifetime) }
        }
        lifetimeDetail.font = .token(.caption)
        lifetimeDetail.maximumNumberOfLines = 2
        peopleHeader.font = .token(.caption)
        messageLabel.font = .token(.caption)
        messageLabel.maximumNumberOfLines = 3
        for button in [revokeButton, revokeEveryoneButton] {
            button.isDestructive = true
            button.onPress = { [weak self] _ in
                guard let self else { return }
                Task { await self.session.revoke() }
            }
        }
        for view: NSView in [titleLabel, subtitleLabel, prefixLabel, slugField, usedLabel, copyButton, lifetimeLabel,
                             lifetimeChoice, lifetimeDetail, peopleHeader, messageLabel, revokeButton, revokeEveryoneButton] {
            addSubview(view)
        }
        buildItems()
        setAccessibilityRole(.group)
        session.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private static func copyPresentation(title: String, symbol: String, enabled: Bool, loading: Bool = false) -> AgentComposerPresentation {
        .init(primaryAction: .send, title: title, symbolName: symbol, accessibilityLabel: title,
              isEnabled: enabled, isLoading: loading, secondaryActions: [])
    }

    var preferredSize: NSSize { NSSize(width: Self.width, height: layoutContent(apply: false)) }

    // MARK: State

    func render() {
        let target = session.target
        let count = target.items.count
        _ = count
        titleLabel.stringValue = target.origin == .agent ? "Share this agent" : "Share this part of your canvas"
        subtitleLabel.stringValue = target.origin == .agent
            ? "Anyone who opens the link can prompt it and move it. It keeps running on this Mac."
            : "Whoever opens the link sees these tiles live, where they sit on your canvas. Nothing here moves, and everything keeps running on this Mac."
        if slugField.currentEditor() == nil { slugField.stringValue = session.slug }
        let phase = session.phase
        slugField.isEditable = phase != .working
        usedLabel.isHidden = { if case .used = phase { return false }; return true }()
        switch phase {
        case .used:
            copyButton.presentation = Self.copyPresentation(title: "New link", symbol: "plus", enabled: true)
        case .working:
            copyButton.presentation = Self.copyPresentation(title: "Sharing…", symbol: "hourglass", enabled: false, loading: true)
        case .revoked, .existing:
            copyButton.presentation = Self.copyPresentation(title: "New link", symbol: "plus", enabled: true)
        default:
            copyButton.presentation = session.copied
                ? Self.copyPresentation(title: "Copied", symbol: "checkmark", enabled: true)
                : Self.copyPresentation(title: "Copy link", symbol: "link", enabled: true)
        }
        lifetimeChoice.selectedID = session.lifetime.rawValue
        lifetimeChoice.isEnabled = phase != .working
        lifetimeDetail.stringValue = session.lifetime.detail
        buildPeople()
        peopleHeader.isHidden = session.people.isEmpty
        // A link in hand, or on an already-shared area any link that still
        // admits or holds someone.
        let revocable = session.link != nil
            || { if case .existing = phase { return session.accessRows.contains { $0.status != .revoked } }; return false }()
        revokeButton.isHidden = !revocable || !session.people.isEmpty
        revokeEveryoneButton.isHidden = !revocable || session.people.isEmpty
        if let failure = session.failure {
            messageLabel.stringValue = failure
        } else if case .revoked = phase {
            messageLabel.stringValue = "The link no longer works, and nobody it let in has access."
        } else if case .existing = phase {
            let live = session.liveRows.map { ShareLinkURL.webPrefix + $0.slug }
            messageLabel.stringValue = live.isEmpty
                ? "Already shared. No link is live; New link makes one."
                : "Already shared. Live: \(live.joined(separator: ", ")). Its secret stays with whoever copied it; New link makes another."
        } else if case .used = phase {
            let name = session.people.first?.label ?? "The person who opened it"
            messageLabel.stringValue = "The link was used, so it no longer works. \(name) keeps full access until you remove them."
        } else {
            messageLabel.stringValue = ""
        }
        messageLabel.isHidden = messageLabel.stringValue.isEmpty
        applyTokens()
        let size = preferredSize
        if frame.size != size { setFrameSize(size); onResize?(size) }
        needsLayout = true
        needsDisplay = true
    }

    /// The Revoke control on show.
    var currentRevokeButton: ChoiceAccessoryButton { revokeButton.isHidden ? revokeEveryoneButton : revokeButton }

    private func buildItems() {
        guard session.target.origin == .area else { return }
        // A terminal is always listed, marked private: the person sees it
        // goes as a card with nothing of it, however long the list is.
        let all = session.target.items
        let items = all.filter { $0.kind != .terminal }.prefix(Self.maxListedItems) + all.filter { $0.kind == .terminal }
        for item in items {
            let label = NSTextField(labelWithString: "\(item.kind.displayName) · \(item.title)" + (item.badge.map { " · \($0)" } ?? ""))
            label.font = .token(.caption)
            label.lineBreakMode = .byTruncatingTail
            let icon = NSImageView(image: CanvasSymbolImage.image(named: Self.symbol(for: item.kind)) ?? NSImage())
            icon.imageScaling = .scaleProportionallyDown
            itemLabels.append(label); itemIcons.append(icon)
            addSubview(icon); addSubview(label)
        }
        if all.count > items.count {
            let more = NSTextField(labelWithString: "and \(all.count - items.count) more")
            more.font = .token(.caption)
            itemLabels.append(more)
            addSubview(more)
        }
    }

    private static func symbol(for kind: TileKind) -> String {
        switch kind {
        case .managedAgent: return "sparkles"
        case .note: return "note.text"
        case .diffReview: return "plusminus"
        case .file: return "doc.text"
        case .browser: return "globe"
        case .terminal: return "lock"
        default: return "square"
        }
    }

    private func buildPeople() {
        for pair in personLabels { pair.name.removeFromSuperview(); pair.detail.removeFromSuperview() }
        for button in removeButtons { button.removeFromSuperview() }
        personLabels = []; removeButtons = []
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        for person in session.people {
            let name = NSTextField(labelWithString: person.label)
            name.font = .token(.label)
            let detail = NSTextField(labelWithString: "opened \(formatter.string(from: person.admittedAt)) · full access")
            detail.font = .token(.caption)
            let remove = ChoiceAccessoryButton(accessory: .init(id: person.person.rawValue.uuidString, title: "Remove", symbol: nil,
                                                                accessibilityLabel: "Remove \(person.label)"))
            remove.onPress = { [weak self] _ in
                guard let self else { return }
                Task { await self.session.remove(person) }
            }
            for view in [name, detail, remove] as [NSView] { addSubview(view) }
            personLabels.append((name, detail)); removeButtons.append(remove)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        _ = layoutContent(apply: true)
    }

    /// One pass for both measuring and placing, so they cannot disagree.
    @discardableResult
    private func layoutContent(apply: Bool) -> CGFloat {
        let inset = Self.inset
        let width = Self.width - inset * 2
        var y = inset
        func place(_ view: NSView, _ rect: NSRect) { if apply { view.frame = rect } }
        func wrappedHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
            ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 16)
        }
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        place(titleLabel, NSRect(x: inset, y: y, width: width, height: titleHeight))
        y += titleHeight + CGFloat(Space.xs)
        let subtitleHeight = wrappedHeight(subtitleLabel, width: width)
        place(subtitleLabel, NSRect(x: inset, y: y, width: width, height: subtitleHeight))
        y += subtitleHeight + CGFloat(Space.l)

        if !itemLabels.isEmpty {
            let row: CGFloat = 18, glyph: CGFloat = 12
            for (index, label) in itemLabels.enumerated() {
                let hasIcon = index < itemIcons.count
                if hasIcon { place(itemIcons[index], NSRect(x: inset, y: y + (row - glyph) / 2, width: glyph, height: glyph)) }
                let x = inset + glyph + CGFloat(Space.m)
                place(label, NSRect(x: x, y: y, width: width - (x - inset), height: row))
                y += row
            }
            y += CGFloat(Space.l)
        }

        let controlHeight = ComposerActionButton.controlHeight
        let buttonWidth = max(96, copyButton.intrinsicContentSize.width)
        let field = NSRect(x: inset, y: y, width: width - buttonWidth - CGFloat(Space.m), height: controlHeight)
        if apply { fieldRect = field }
        let textHeight = ceil(slugField.intrinsicContentSize.height)
        let prefixWidth = ceil(prefixLabel.cell?.cellSize.width ?? prefixLabel.intrinsicContentSize.width)
        let textY = field.minY + (controlHeight - textHeight) / 2
        let usedWidth = usedLabel.isHidden ? 0 : ceil(usedLabel.intrinsicContentSize.width) + CGFloat(Space.m)
        place(prefixLabel, NSRect(x: field.minX + CGFloat(Space.m), y: textY, width: prefixWidth, height: textHeight))
        place(slugField, NSRect(x: field.minX + CGFloat(Space.m) + prefixWidth, y: textY,
                                width: max(40, field.width - CGFloat(Space.m) * 2 - prefixWidth - usedWidth), height: textHeight))
        place(usedLabel, NSRect(x: field.maxX - usedWidth, y: textY, width: usedWidth - CGFloat(Space.m), height: textHeight))
        place(copyButton, NSRect(x: field.maxX + CGFloat(Space.m), y: y, width: buttonWidth, height: controlHeight))
        y += controlHeight + CGFloat(Space.m)

        let labelWidth: CGFloat = 32
        let choiceWidth: CGFloat = 128
        place(lifetimeLabel, NSRect(x: inset, y: y + (ChoiceButton.controlHeight - 16) / 2, width: labelWidth, height: 16))
        place(lifetimeChoice, NSRect(x: inset + labelWidth, y: y, width: choiceWidth, height: ChoiceButton.controlHeight))
        let detailX = inset + labelWidth + choiceWidth + CGFloat(Space.m)
        let detailWidth = Self.width - inset - detailX
        let detailHeight = wrappedHeight(lifetimeDetail, width: detailWidth)
        place(lifetimeDetail, NSRect(x: detailX, y: y + max(0, (ChoiceButton.controlHeight - detailHeight) / 2),
                                     width: detailWidth, height: detailHeight))
        y += ChoiceButton.controlHeight

        var avatars: [NSRect] = []
        if !personLabels.isEmpty {
            y += CGFloat(Space.l)
            place(peopleHeader, NSRect(x: inset, y: y, width: width, height: 16))
            y += 16 + CGFloat(Space.s)
            let row: CGFloat = 36, avatar: CGFloat = 24
            for (index, pair) in personLabels.enumerated() {
                avatars.append(NSRect(x: inset, y: y + (row - avatar) / 2, width: avatar, height: avatar))
                let x = inset + avatar + CGFloat(Space.m)
                let removeWidth = ChoiceAccessoryButton.width(for: removeButtons[index].accessory, zoom: .default)
                let textWidth = width - (x - inset) - removeWidth - CGFloat(Space.m)
                place(pair.name, NSRect(x: x, y: y + 2, width: textWidth, height: 17))
                place(pair.detail, NSRect(x: x, y: y + 19, width: textWidth, height: 15))
                place(removeButtons[index], NSRect(x: Self.width - inset - removeWidth, y: y + (row - 22) / 2, width: removeWidth, height: 22))
                y += row
            }
        }
        if apply { avatarRects = avatars }

        if !messageLabel.isHidden {
            y += CGFloat(Space.l)
            let height = wrappedHeight(messageLabel, width: width)
            place(messageLabel, NSRect(x: inset, y: y, width: width, height: height))
            y += height
        }
        let revoke = currentRevokeButton
        if !revoke.isHidden {
            y += CGFloat(Space.m)
            let revokeWidth = ChoiceAccessoryButton.width(for: revoke.accessory, zoom: .default)
            place(revoke, NSRect(x: inset - CGFloat(Space.s), y: y, width: revokeWidth, height: 22))
            y += 22
        }
        return ceil(y + inset)
    }

    // MARK: Drawing

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func applyTokens() {
        let theme = effectiveTokenTheme
        let primary = TextToken.textPrimary.color.nsColor(for: theme)
        let secondary = TextToken.textSecondary.color.nsColor(for: theme)
        titleLabel.textColor = primary
        slugField.textColor = primary
        for pair in personLabels { pair.name.textColor = primary; pair.detail.textColor = secondary }
        for label in itemLabels { label.textColor = primary }
        for icon in itemIcons { icon.contentTintColor = secondary }
        for label in [subtitleLabel, prefixLabel, usedLabel, lifetimeLabel, lifetimeDetail, peopleHeader] { label.textColor = secondary }
        messageLabel.textColor = session.failure == nil ? secondary : AccentToken.accentFailed.color.nsColor(for: theme)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let radius = CGFloat(Radius.container)
        let surface = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        SurfaceToken.overlay.color.nsColor(for: theme).setFill()
        surface.fill()
        AgentLineRole.decorativeHairline.color.nsColor(for: theme).setStroke()
        surface.lineWidth = CGFloat(LineWidth.hairline)
        surface.stroke()
        let fieldRadius = CGFloat(Radius.card)
        let field = NSBezierPath(roundedRect: fieldRect, xRadius: fieldRadius, yRadius: fieldRadius)
        AgentSurfaceRole.composer.color.nsColor(for: theme).setFill()
        field.fill()
        let focused = slugField.currentEditor() != nil
        (focused ? AgentLineRole.focusRing : .controlBoundary).color.nsColor(for: theme).setStroke()
        field.lineWidth = CGFloat(LineWidth.hairline)
        field.stroke()
        for (index, rect) in avatarRects.enumerated() where index < session.people.count {
            AccentToken.accentInput.color.nsColor(for: theme).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let initials = String(session.people[index].label.prefix(1)).uppercased()
            let text = NSAttributedString(string: initials, attributes: [
                .font: NSFont.token(.label), .foregroundColor: TextToken.textOnAccent.color.nsColor(for: theme)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    // MARK: Actions

    @objc private func copyPressed(_ sender: Any?) {
        commitSlug()
        Task {
            switch session.phase {
            case .used, .revoked, .existing: await session.newLink()
            default: await session.copy()
            }
        }
    }

    private func commitSlug() { session.setSlug(slugField.stringValue) }

    func controlTextDidEndEditing(_ obj: Notification) { commitSlug(); needsDisplay = true }
    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) { onDismiss?(); return true }
        if selector == #selector(insertNewline(_:)) { copyPressed(nil); return true }
        return false
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
